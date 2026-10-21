// timbrecastd: streams Timbre's processed system audio to a Chromecast.
//
//   mediaserverd (Timbre tweak) --shared ring--> timbrecastd --HTTP WAV--> Chromecast
//
// Discovery uses mDNS (_googlecast._tcp). Control speaks the Cast v2 protocol directly
// (TLS on the device port, length-prefixed protobuf CastMessage with JSON payloads) and
// loads the Default Media Receiver with a live WAV stream served from this daemon.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <notify.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../CastShared.h"

static NSString *const kConfigPath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
static NSString *const kDevicesPath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.cast-devices.plist";
static NSString *const kStatusPath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.cast-status.plist";
static const char *const kReloadNotification = "com.soum91.timbreaudio.reload";
static const uint16_t kHTTPPort = 8099;
static const uint32_t kOutRate = 48000;
static const double kCushionSeconds = 0.12;  // jitter buffer kept between the tweak's writes and our reads
static NSString *const kDefaultReceiver = @"CC1AD845";

static TBCastHeader *gRing;
static _Atomic int gStreamGeneration;
static _Atomic double gLastClientActivity;  // CFAbsoluteTime of the last byte sent to a client

#pragma mark - Ring

static BOOL setUpRing(void) {
    const int fd = open(TB_CAST_RING_PATH, O_RDWR | O_CREAT, 0666);
    if (fd < 0) { NSLog(@"timbrecastd: cannot open ring: %s", strerror(errno)); return NO; }
    fchmod(fd, 0666);
    if (ftruncate(fd, (off_t)TB_CAST_FILE_SIZE) != 0) { NSLog(@"timbrecastd: ftruncate failed: %s", strerror(errno)); close(fd); return NO; }
    void *m = mmap(NULL, TB_CAST_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) { NSLog(@"timbrecastd: mmap failed: %s", strerror(errno)); return NO; }
    gRing = (TBCastHeader *)m;
    if (gRing->magic != TB_CAST_MAGIC || gRing->version != TB_CAST_VERSION || gRing->capacity != TB_CAST_CAPACITY) {
        memset(gRing, 0, sizeof(TBCastHeader));
        gRing->version = TB_CAST_VERSION;
        gRing->capacity = TB_CAST_CAPACITY;
        gRing->rate = 48000;
        __atomic_store_n(&gRing->magic, TB_CAST_MAGIC, __ATOMIC_RELEASE);
    }
    return YES;
}

#pragma mark - HTTP WAV server

static void putLE32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void putLE16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

static BOOL sendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        const ssize_t n = send(fd, p, len, 0);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return NO; }
        p += n; len -= (size_t)n;
    }
    return YES;
}

static double machSeconds(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// Streams the ring as 48 kHz 16-bit stereo WAV, paced to real time. Keeps a small cushion behind the
// writer, sends silence when nothing is playing, and skips ahead if it ever falls too far behind.
static void streamWAV(int fd) {
    // Readers are independent (the ring is not consumed), so concurrent connections are fine;
    // only a Stop bumps the generation to end every open stream.
    const int generation = atomic_load(&gStreamGeneration);
    uint8_t h[44] = {'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't', ' '};
    putLE32(h + 4, 0x7FFFFFFF);
    putLE32(h + 16, 16); putLE16(h + 20, 1); putLE16(h + 22, 2);
    putLE32(h + 24, kOutRate); putLE32(h + 28, kOutRate * 4); putLE16(h + 32, 4); putLE16(h + 34, 16);
    memcpy(h + 36, "data", 4); putLE32(h + 40, 0x7FFFFFFF - 36);
    if (!sendAll(fd, h, sizeof(h))) return;

    const int16_t *samples = tbCastSamples(gRing);
    double pos = 0;           // read position in ring frames (fractional, ring rate)
    BOOL filling = YES;       // waiting for the cushion to build
    uint64_t sent = 0;
    const double start = machSeconds();
    enum { kMaxChunk = 4800 };
    static __thread int16_t out[kMaxChunk * 2];
    NSLog(@"timbrecastd: stream %d started", generation);
    while (atomic_load(&gStreamGeneration) == generation) {
        const uint64_t target = (uint64_t)((machSeconds() - start) * kOutRate);
        if (target < sent) { usleep(5000); continue; }
        uint64_t want = target - sent;
        if (want > (uint64_t)kOutRate) { sent = target - kMaxChunk; want = kMaxChunk; }  // stalled sender: drop backlog
        if (want > kMaxChunk) want = kMaxChunk;
        if (want == 0) { usleep(5000); continue; }
        const uint32_t rate = gRing->rate >= 8000 && gRing->rate <= 192000 ? gRing->rate : 48000;
        const double step = (double)rate / kOutRate, cushion = kCushionSeconds * rate;
        for (uint64_t i = 0; i < want; i++) {
            const uint64_t w = __atomic_load_n(&gRing->writeFrames, __ATOMIC_ACQUIRE);
            double avail = (double)w - pos;
            if (avail > TB_CAST_CAPACITY * 0.5 || avail > 4 * cushion || avail < -1) { pos = (double)w - cushion; avail = cushion; }
            if (filling && avail >= cushion) filling = NO;
            if (filling || avail < 2) {
                filling = YES;
                out[2 * i] = out[2 * i + 1] = 0;
                continue;
            }
            const uint64_t i0 = (uint64_t)pos;
            const double frac = pos - (double)i0;
            const uint64_t a = (i0 % TB_CAST_CAPACITY) * 2, b = ((i0 + 1) % TB_CAST_CAPACITY) * 2;
            out[2 * i] = (int16_t)lrint(samples[a] + (samples[b] - samples[a]) * frac);
            out[2 * i + 1] = (int16_t)lrint(samples[a + 1] + (samples[b + 1] - samples[a + 1]) * frac);
            pos += step;
        }
        if (!sendAll(fd, out, (size_t)want * 4)) break;
        sent += want;
        atomic_store(&gLastClientActivity, CFAbsoluteTimeGetCurrent());
        usleep(10000);
    }
    NSLog(@"timbrecastd: stream %d ended", generation);
}

static void *clientThread(void *arg) {
    const int fd = (int)(intptr_t)arg;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char req[4096];
    size_t len = 0;
    while (len < sizeof(req) - 1) {
        const ssize_t n = recv(fd, req + len, sizeof(req) - 1 - len, 0);
        if (n <= 0) break;
        len += (size_t)n;
        req[len] = 0;
        if (strstr(req, "\r\n\r\n")) break;
    }
    req[len] = 0;
    const BOOL head = strncmp(req, "HEAD ", 5) == 0, get = strncmp(req, "GET ", 4) == 0;
    const char *path = strchr(req, ' ');
    if ((head || get) && path && strncmp(path + 1, "/timbre.wav", 11) == 0) {
        const char *hdr = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache, no-store\r\n"
                          "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
        if (sendAll(fd, hdr, strlen(hdr)) && get) streamWAV(fd);
    } else {
        const char *nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sendAll(fd, nf, strlen(nf));
    }
    close(fd);
    return NULL;
}

static void *serverThread(void *unused) {
    const int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(kHTTPPort), .sin_addr.s_addr = htonl(INADDR_ANY)};
    while (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) { NSLog(@"timbrecastd: bind failed: %s", strerror(errno)); sleep(2); }
    listen(s, 8);
    NSLog(@"timbrecastd: HTTP on port %u", kHTTPPort);
    for (;;) {
        const int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno != EINTR) usleep(100000); continue; }
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, clientThread, (void *)(intptr_t)c) != 0) close(c);
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

static NSString *localIPv4(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *wifi = nil, *other = nil;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof(buf));
        NSString *ip = @(buf);
        if (!strcmp(i->ifa_name, "en0")) wifi = ip;
        else if (!other && strncmp(i->ifa_name, "pdp_ip", 6) != 0 && strncmp(i->ifa_name, "utun", 4) != 0) other = ip;
    }
    freeifaddrs(list);
    return wifi ?: other;
}

#pragma mark - Cast v2 protocol

static void appendVarint(NSMutableData *d, uint64_t v) {
    do { uint8_t b = v & 0x7f; v >>= 7; if (v) b |= 0x80; [d appendBytes:&b length:1]; } while (v);
}
static void appendField(NSMutableData *d, int field, NSString *s) {
    NSData *u = [s dataUsingEncoding:NSUTF8StringEncoding];
    appendVarint(d, ((uint64_t)field << 3) | 2);
    appendVarint(d, u.length);
    [d appendData:u];
}
static NSData *castFrame(NSString *source, NSString *dest, NSString *ns, NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSMutableData *m = [NSMutableData new];
    appendVarint(m, (1 << 3) | 0); appendVarint(m, 0);  // protocol_version CASTV2_1_0
    appendField(m, 2, source);
    appendField(m, 3, dest);
    appendField(m, 4, ns);
    appendVarint(m, (5 << 3) | 0); appendVarint(m, 0);  // payload_type STRING
    appendField(m, 6, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    NSMutableData *frame = [NSMutableData dataWithLength:4];
    const uint32_t len = htonl((uint32_t)m.length);
    memcpy(frame.mutableBytes, &len, 4);
    [frame appendData:m];
    return frame;
}
static BOOL readVarint(const uint8_t *p, size_t n, size_t *at, uint64_t *out) {
    uint64_t v = 0; int shift = 0;
    while (*at < n && shift < 64) {
        const uint8_t b = p[(*at)++];
        v |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = v; return YES; }
        shift += 7;
    }
    return NO;
}
// Returns @{source, namespace, payload} or nil.
static NSDictionary *parseCastMessage(NSData *msg) {
    const uint8_t *p = msg.bytes;
    const size_t n = msg.length;
    size_t at = 0;
    NSMutableDictionary *out = [NSMutableDictionary new];
    while (at < n) {
        uint64_t key = 0, v = 0;
        if (!readVarint(p, n, &at, &key)) return nil;
        const int field = (int)(key >> 3), type = (int)(key & 7);
        if (type == 0) { if (!readVarint(p, n, &at, &v)) return nil; }
        else if (type == 2) {
            if (!readVarint(p, n, &at, &v) || at + v > n) return nil;
            NSString *s = [[NSString alloc] initWithBytes:p + at length:(NSUInteger)v encoding:NSUTF8StringEncoding];
            at += v;
            if (field == 2 && s) out[@"source"] = s;
            if (field == 4 && s) out[@"namespace"] = s;
            if (field == 6 && s) out[@"payload"] = s;
        } else return nil;
    }
    return out;
}

static NSString *const nsConnection = @"urn:x-cast:com.google.cast.tp.connection";
static NSString *const nsHeartbeat = @"urn:x-cast:com.google.cast.tp.heartbeat";
static NSString *const nsReceiver = @"urn:x-cast:com.google.cast.receiver";
static NSString *const nsMedia = @"urn:x-cast:com.google.cast.media";

@interface TBCastSession : NSObject
@property(nonatomic, copy) NSString *deviceID, *deviceName, *state, *message;
@property(nonatomic) BOOL stoppedByDevice;
@property(nonatomic) CFAbsoluteTime started;
- (instancetype)initWithDevice:(NSDictionary *)device queue:(dispatch_queue_t)queue;
- (void)start;
- (void)stop;
- (void)setVolume:(double)level;
@end

@implementation TBCastSession {
    dispatch_queue_t _q;
    nw_connection_t _conn;
    NSDictionary *_device;
    NSMutableData *_inbox;
    NSString *_transportID, *_sessionID;
    NSInteger _requestID;
    dispatch_source_t _ping;
    BOOL _loaded, _closed;
}
- (instancetype)initWithDevice:(NSDictionary *)device queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _device = device; _q = queue; _inbox = [NSMutableData new];
        _deviceID = device[@"id"]; _deviceName = device[@"name"];
        _state = @"connecting"; _message = @"Connecting";
        _started = CFAbsoluteTimeGetCurrent();
    }
    return self;
}
- (void)send:(NSString *)ns to:(NSString *)dest payload:(NSDictionary *)payload {
    if (!_conn || _closed) return;
    NSData *frame = castFrame(@"sender-timbre", dest, ns, payload);
    dispatch_data_t data = dispatch_data_create(frame.bytes, frame.length, _q, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(_conn, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (error) NSLog(@"timbrecastd: send error %d", nw_error_get_error_code(error));
    });
}
- (NSInteger)nextRequest { return ++_requestID; }
- (void)start {
    NSString *host = _device[@"host"], *port = [_device[@"port"] description];
    if (!host.length || !port.length) { self.state = @"error"; self.message = @"Device address unknown"; return; }
    dispatch_queue_t q = _q;
    nw_parameters_configure_protocol_block_t tls = ^(nw_protocol_options_t options) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(options);
        // Chromecasts present device certificates that do not chain to a public root.
        sec_protocol_options_set_verify_block(sec, ^(sec_protocol_metadata_t md, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
            complete(true);
        }, q);
    };
    nw_parameters_t params = nw_parameters_create_secure_tcp(tls, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    _conn = nw_connection_create(nw_endpoint_create_host(host.UTF8String, port.UTF8String), params);
    nw_connection_set_queue(_conn, _q);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(_conn, ^(nw_connection_state_t st, nw_error_t error) {
        TBCastSession *me = weakSelf;
        if (!me) return;
        if (st == nw_connection_state_ready) [me connected];
        else if (st == nw_connection_state_failed || st == nw_connection_state_cancelled) {
            if (!me->_closed) { me.state = @"error"; me.message = error ? [NSString stringWithFormat:@"Connection lost (%d)", nw_error_get_error_code(error)] : @"Connection closed"; }
            me->_closed = YES;
        }
    });
    nw_connection_start(_conn);
}
- (void)connected {
    self.state = @"launching"; self.message = @"Starting receiver";
    [self send:nsConnection to:@"receiver-0" payload:@{@"type": @"CONNECT", @"origin": @{}}];
    [self send:nsReceiver to:@"receiver-0" payload:@{@"type": @"LAUNCH", @"appId": kDefaultReceiver, @"requestId": @([self nextRequest])}];
    [self receive];
    _ping = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_ping, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_ping, ^{
        TBCastSession *me = weakSelf;
        [me send:nsHeartbeat to:@"receiver-0" payload:@{@"type": @"PING"}];
        if (me->_loaded) [me send:nsReceiver to:@"receiver-0" payload:@{@"type": @"GET_STATUS", @"requestId": @([me nextRequest])}];
    });
    dispatch_resume(_ping);
}
- (void)receive {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(_conn, 1, 65536, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t error) {
        TBCastSession *me = weakSelf;
        if (!me || me->_closed) return;
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                [me->_inbox appendBytes:buffer length:size];
                return true;
            });
            [me drain];
        }
        if (error || complete) { me.state = @"error"; me.message = @"Device closed the connection"; me->_closed = YES; return; }
        [me receive];
    });
}
- (void)drain {
    while (_inbox.length >= 4) {
        uint32_t len;
        memcpy(&len, _inbox.bytes, 4);
        len = ntohl(len);
        if (len > 1 << 20) { _inbox.length = 0; return; }
        if (_inbox.length < 4 + len) return;
        NSDictionary *m = parseCastMessage([_inbox subdataWithRange:NSMakeRange(4, len)]);
        [_inbox replaceBytesInRange:NSMakeRange(0, 4 + len) withBytes:NULL length:0];
        if (m) [self handle:m];
    }
}
- (void)handle:(NSDictionary *)m {
    NSString *ns = m[@"namespace"];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:[m[@"payload"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) return;
    NSString *type = payload[@"type"];
    if ([ns isEqualToString:nsHeartbeat] && [type isEqualToString:@"PING"]) {
        [self send:nsHeartbeat to:m[@"source"] ?: @"receiver-0" payload:@{@"type": @"PONG"}];
    } else if ([ns isEqualToString:nsReceiver] && [type isEqualToString:@"RECEIVER_STATUS"]) {
        NSDictionary *app = nil;
        for (NSDictionary *a in payload[@"status"][@"applications"]) if ([a[@"appId"] isEqualToString:kDefaultReceiver]) app = a;
        if (app && !_transportID) {
            _transportID = app[@"transportId"];
            _sessionID = app[@"sessionId"];
            [self send:nsConnection to:_transportID payload:@{@"type": @"CONNECT", @"origin": @{}}];
            [self load];
        } else if (!app && _loaded) {
            // Someone started something else on the device. Do not fight them for it.
            self.stoppedByDevice = YES;
            self.state = @"stopped"; self.message = @"Stopped on the device";
            [self closeConnection];
        }
    } else if ([ns isEqualToString:nsMedia]) {
        if ([type isEqualToString:@"MEDIA_STATUS"]) {
            NSDictionary *st = [payload[@"status"] firstObject];
            NSString *player = st[@"playerState"];
            if ([player isEqualToString:@"PLAYING"]) { self.state = @"playing"; self.message = @"Casting"; }
            else if ([player isEqualToString:@"BUFFERING"]) { self.state = @"buffering"; self.message = @"Buffering"; }
            else if ([player isEqualToString:@"IDLE"] && [st[@"idleReason"] isEqualToString:@"ERROR"]) { self.state = @"error"; self.message = @"The Chromecast could not play the stream"; }
        } else if ([type isEqualToString:@"LOAD_FAILED"] || [type isEqualToString:@"LOAD_CANCELLED"] || [type isEqualToString:@"INVALID_REQUEST"]) {
            self.state = @"error"; self.message = [NSString stringWithFormat:@"Receiver refused the stream (%@)", type];
        }
    }
}
- (void)load {
    NSString *ip = localIPv4();
    if (!ip) { self.state = @"error"; self.message = @"No Wi-Fi address"; return; }
    NSString *url = [NSString stringWithFormat:@"http://%@:%u/timbre.wav", ip, kHTTPPort];
    self.state = @"loading"; self.message = [NSString stringWithFormat:@"Loading %@", url];
    [self send:nsMedia to:_transportID payload:@{
        @"type": @"LOAD", @"requestId": @([self nextRequest]), @"autoplay": @YES, @"currentTime": @0,
        @"media": @{@"contentId": url, @"contentType": @"audio/wav", @"streamType": @"LIVE",
                    @"metadata": @{@"metadataType": @3, @"title": @"Timbre", @"artist": @"iPhone system audio"}},
    }];
    _loaded = YES;
}
- (void)setVolume:(double)level {
    [self send:nsReceiver to:@"receiver-0" payload:@{@"type": @"SET_VOLUME", @"volume": @{@"level": @(MAX(0.0, MIN(1.0, level)))}, @"requestId": @([self nextRequest])}];
}
- (void)closeConnection {
    if (_ping) { dispatch_source_cancel(_ping); _ping = nil; }
    if (_conn) { nw_connection_cancel(_conn); }
    _closed = YES;
}
- (void)stop {
    if (_sessionID && !_closed) [self send:nsReceiver to:@"receiver-0" payload:@{@"type": @"STOP", @"sessionId": _sessionID, @"requestId": @([self nextRequest])}];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), _q, ^{ [weakSelf closeConnection]; });
    atomic_fetch_add(&gStreamGeneration, 1);  // end any open HTTP stream
}
- (BOOL)isClosed { return _closed; }
@end

#pragma mark - Discovery and control

@interface TBCastController : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation TBCastController {
    dispatch_queue_t _q;
    NSNetServiceBrowser *_browser;
    NSMutableSet<NSNetService *> *_services;
    NSMutableDictionary<NSString *, NSDictionary *> *_devices;  // id -> {id, name, model, host, port}
    TBCastSession *_session;
    NSDictionary *_cast;  // config["cast"]
    double _sentVolume;
    NSString *_blockedDevice;  // device that stopped us; ignored until the config changes
    CFAbsoluteTime _lastAttempt;
}
- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.soum91.timbrecastd.cast", DISPATCH_QUEUE_SERIAL);
        _services = [NSMutableSet new];
        _devices = [NSMutableDictionary new];
        _sentVolume = -1;
    }
    return self;
}
- (void)run {
    _browser = [NSNetServiceBrowser new];
    _browser.delegate = self;
    [_browser searchForServicesOfType:@"_googlecast._tcp." inDomain:@"local."];
    int token;
    notify_register_dispatch(kReloadNotification, &token, dispatch_get_main_queue(), ^(int t) { [self tick]; });
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    // Re-browse now and then: mDNS caches can go stale when devices change networks.
    [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(rebrowse) userInfo:nil repeats:YES];
    [self tick];
}
- (void)rebrowse {
    [_browser stop];
    [_browser searchForServicesOfType:@"_googlecast._tcp." inDomain:@"local."];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didFindService:(NSNetService *)service moreComing:(BOOL)more {
    [_services addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:10];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didRemoveService:(NSNetService *)service moreComing:(BOOL)more {
    [_services removeObject:service];
    NSString *gone = nil;
    for (NSString *k in _devices) if ([_devices[k][@"service"] isEqualToString:service.name]) gone = k;
    if (gone) { [_devices removeObjectForKey:gone]; [self writeDevices]; }
}
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *host = nil;
    for (NSData *a in service.addresses) {
        const struct sockaddr *sa = a.bytes;
        if (sa->sa_family != AF_INET) continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((const struct sockaddr_in *)sa)->sin_addr, buf, sizeof(buf));
        host = @(buf);
        break;
    }
    if (!host) return;
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData];
    NSString *(^field)(NSString *) = ^NSString *(NSString *k) { NSData *d = txt[k]; return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil; };
    NSString *ident = field(@"id") ?: service.name;
    _devices[ident] = @{@"id": ident, @"name": field(@"fn") ?: service.name, @"model": field(@"md") ?: @"Chromecast",
                        @"host": host, @"port": @(service.port), @"service": service.name, @"seen": @(time(NULL))};
    [self writeDevices];
}
- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)error {}
- (void)writeDevices {
    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *k in _devices) out[k] = _devices[k];
    [out writeToFile:kDevicesPath atomically:YES];
}
- (void)writeStatus {
    TBCastSession *s = _session;
    const BOOL enabled = [_cast[@"enabled"] boolValue];
    NSDictionary *st = @{
        @"time": @(time(NULL)),
        @"enabled": @(enabled),
        @"state": s ? s.state : (enabled ? @"idle" : @"off"),
        @"message": s ? s.message : (enabled ? ([_cast[@"device"] length] ? @"Looking for the device" : @"Pick a device") : @"Off"),
        @"device": s.deviceName ?: @"",
        @"streaming": @(CFAbsoluteTimeGetCurrent() - atomic_load(&gLastClientActivity) < 2.5),
        @"ip": localIPv4() ?: @"",
    };
    [st writeToFile:kStatusPath atomically:YES];
}
- (void)tick {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    NSDictionary *cast = [config[@"cast"] isKindOfClass:NSDictionary.class] ? config[@"cast"] : @{};
    if (![cast isEqual:_cast]) { _blockedDevice = nil; }
    _cast = cast;
    const BOOL enabled = [cast[@"enabled"] boolValue];
    NSString *wanted = cast[@"device"];
    const BOOL streaming = CFAbsoluteTimeGetCurrent() - atomic_load(&gLastClientActivity) < 2.5;

    if (gRing) {
        if (enabled) __atomic_store_n(&gRing->readerHeartbeat, (uint64_t)time(NULL), __ATOMIC_RELEASE);
        // Only silence the phone while a Chromecast is actually pulling the stream.
        gRing->muteLocal = enabled && streaming && [cast[@"muteLocal"] boolValue];
    }

    NSDictionary *device = wanted.length ? _devices[wanted] : nil;
    const BOOL want = enabled && device && ![_blockedDevice isEqualToString:wanted];
    dispatch_sync(_q, ^{
        if (self->_session && (!want || ![self->_session.deviceID isEqualToString:wanted])) {
            [self->_session stop];
            self->_session = nil;
            self->_sentVolume = -1;
        }
        if (self->_session.stoppedByDevice) {
            self->_blockedDevice = self->_session.deviceID;
            self->_session = nil;
        } else if (self->_session && ([self->_session isClosed] ||
                   ([self->_session.state isEqualToString:@"error"] && CFAbsoluteTimeGetCurrent() - self->_session.started > 10))) {
            [self->_session stop];
            self->_session = nil;  // retry below, rate-limited
        }
        if (want && !self->_session && CFAbsoluteTimeGetCurrent() - self->_lastAttempt >= 5) {
            self->_lastAttempt = CFAbsoluteTimeGetCurrent();
            self->_session = [[TBCastSession alloc] initWithDevice:device queue:self->_q];
            [self->_session start];
        }
        const double volume = [cast[@"volume"] respondsToSelector:@selector(doubleValue)] ? [cast[@"volume"] doubleValue] : -1;
        if (self->_session && [self->_session.state isEqualToString:@"playing"] && volume >= 0 && fabs(volume - self->_sentVolume) > 0.005) {
            [self->_session setVolume:volume];
            self->_sentVolume = volume;
        }
    });
    [self writeStatus];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSLog(@"timbrecastd: starting");
        while (!setUpRing()) sleep(5);
        pthread_t server;
        pthread_create(&server, NULL, serverThread, NULL);
        pthread_detach(server);
        TBCastController *controller = [TBCastController new];
        [controller run];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
