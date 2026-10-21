// Timbre controller: EQE-style parametric EQ (gain / frequency / Q fader triplets per band),
// interactive response graph, spatial, reverb, dynamics and presets.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#include <math.h>
#include <notify.h>
#include <spawn.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
extern char **environ;

// Primary copy under the jailbreak root (readable by the sandboxed audio daemon), legacy copy kept in sync.
static NSString *const kConfigPath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
static NSString *const kLegacyConfigPath = @"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
static NSString *const kHelperPath = @"/var/jb/usr/libexec/timbrectl";
static NSString *const kChanged = @"TimbreConfigChanged";
static const char *const kReloadNotification = "com.soum91.timbreaudio.reload";
static const NSInteger kMaxBands = 16;
static const double kGraphRate = 48000;

static double clampd(double x, double lo, double hi) { return fmax(lo, fmin(x, hi)); }
static UIColor *hexColor(unsigned hex, CGFloat a) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255. green:((hex >> 8) & 255) / 255. blue:(hex & 255) / 255. alpha:a];
}
static UIColor *bandColor(NSInteger i) {
    static const unsigned palette[] = {0xFFC23D, 0xFF8F3D, 0xF5E663, 0x7BE0A0, 0x56C8F5, 0x9D8CFF, 0xFF6F91, 0xE9B8FF};
    return hexColor(palette[((i % 8) + 8) % 8], 1);
}
static UIColor *accentColor(void) { return hexColor(0xFFC23D, 1); }
static UIColor *cardColor(void) { return [UIColor colorWithWhite:.085 alpha:1]; }
static UIColor *dimColor(void) { return [UIColor colorWithWhite:.55 alpha:1]; }

#pragma mark - Filter math

static NSArray<NSString *> *typeNames(void) {
    return @[@"Peak", @"Low shelf", @"High shelf", @"Low pass", @"High pass", @"Band pass", @"Notch", @"All pass"];
}
static NSArray<NSString *> *typeCodes(void) { return @[@"PK", @"LS", @"HS", @"LP", @"HP", @"BP", @"NO", @"AP"]; }
static BOOL typeUsesGain(NSInteger t) { return t >= 0 && t <= 2; }

typedef struct { double b0, b1, b2, a1, a2; } TBCoeffs;
static TBCoeffs tbCoeffs(NSInteger type, double f, double gain, double q, double fs) {
    f = clampd(f, 10, fs * .49); q = clampd(q, .05, 40);
    const double A = pow(10, gain / 40), w = 2 * M_PI * f / fs, c = cos(w), s = sin(w), al = s / (2 * q), sA = 2 * sqrt(A) * al;
    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (type) {
        case 0: b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A; break;
        case 1: b0 = A * ((A + 1) - (A - 1) * c + sA); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - sA);
                a0 = (A + 1) + (A - 1) * c + sA; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - sA; break;
        case 2: b0 = A * ((A + 1) + (A - 1) * c + sA); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - sA);
                a0 = (A + 1) - (A - 1) * c + sA; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - sA; break;
        case 3: b0 = (1 - c) / 2; b1 = 1 - c; b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case 4: b0 = (1 + c) / 2; b1 = -(1 + c); b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case 5: b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case 6: b0 = 1; b1 = -2 * c; b2 = 1; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case 7: b0 = 1 - al; b1 = -2 * c; b2 = 1 + al; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        default: break;
    }
    return (TBCoeffs){b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}
static double tbMagnitudeDB(TBCoeffs k, double f, double fs) {
    const double w = 2 * M_PI * f / fs, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    const double nr = k.b0 + k.b1 * c1 + k.b2 * c2, ni = -(k.b1 * s1 + k.b2 * s2);
    const double dr = 1 + k.a1 * c1 + k.a2 * c2, di = -(k.a1 * s1 + k.a2 * s2);
    return 10 * log10(fmax((nr * nr + ni * ni) / fmax(dr * dr + di * di, 1e-30), 1e-18));
}

#pragma mark - Formatting

typedef NS_ENUM(NSInteger, TBUnit) { TBUnitDB, TBUnitHz, TBUnitQ, TBUnitMs, TBUnitSec, TBUnitPct, TBUnitDeg, TBUnitRatio, TBUnitMeters };
static NSString *unitSuffix(TBUnit u) {
    switch (u) {
        case TBUnitDB: return @"dB"; case TBUnitHz: return @"Hz"; case TBUnitQ: return @"Q"; case TBUnitMs: return @"ms";
        case TBUnitSec: return @"s"; case TBUnitPct: return @"%"; case TBUnitDeg: return @"°"; case TBUnitRatio: return @": 1";
        case TBUnitMeters: return @"m";
    }
    return @"";
}
static NSString *formatNumber(double v, TBUnit u) {
    switch (u) {
        case TBUnitDB: return [NSString stringWithFormat:@"%.1f", v];
        case TBUnitHz: return v >= 1000 ? [NSString stringWithFormat:(v >= 10000 ? @"%.1fk" : @"%.2fk"), v / 1000] : [NSString stringWithFormat:@"%.0f", v];
        case TBUnitQ: return [NSString stringWithFormat:@"%.2f", v];
        case TBUnitMs: return [NSString stringWithFormat:(v < 10 ? @"%.1f" : @"%.0f"), v];
        case TBUnitSec: return [NSString stringWithFormat:@"%.2f", v];
        case TBUnitPct: return [NSString stringWithFormat:@"%.0f", v * 100];
        case TBUnitDeg: return [NSString stringWithFormat:@"%.0f", v];
        case TBUnitRatio: return [NSString stringWithFormat:@"%.1f", v];
        case TBUnitMeters: return [NSString stringWithFormat:@"%.1f", v];
    }
    return @"";
}
static NSString *formatValue(double v, TBUnit u) {
    NSString *n = formatNumber(v, u);
    if (u == TBUnitHz && [n hasSuffix:@"k"]) return [n stringByAppendingString:@"Hz"];
    if (u == TBUnitPct || u == TBUnitDeg) return [n stringByAppendingString:unitSuffix(u)];
    return [NSString stringWithFormat:@"%@ %@", n, unitSuffix(u)];
}
static double roundSignificant(double v, int digits) {
    if (v == 0 || !isfinite(v)) return v;
    const double m = pow(10, digits - 1 - (int)floor(log10(fabs(v))));
    return round(v * m) / m;
}

#pragma mark - Store

@interface TBStore : NSObject
+ (instancetype)shared;
@property(nonatomic, strong) NSMutableDictionary *config;
@property(nonatomic, copy) NSString *lastError;
- (NSMutableArray<NSMutableDictionary *> *)bands;
- (id)valueAt:(NSString *)keyPath;
- (void)setValue:(id)value at:(NSString *)keyPath;
- (void)changed;
- (void)commit;
@end

static int runHelper(NSString *command, NSString **output);
@implementation TBStore {
    BOOL _pending, _repaired;
}
+ (instancetype)shared {
    static TBStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TBStore new]; [s load]; });
    return s;
}
+ (NSMutableDictionary *)band:(double)f type:(NSInteger)t gain:(double)g q:(double)q {
    return [@{@"enabled": @YES, @"type": @(t), @"frequency": @(f), @"gain": @(g), @"q": @(q)} mutableCopy];
}
+ (NSArray *)defaultBands {
    NSMutableArray *a = [NSMutableArray new];
    for (NSNumber *f in @[@31, @62, @125, @250, @500, @1000, @2000, @4000, @8000, @16000])
        [a addObject:[self band:f.doubleValue type:0 gain:0 q:1.41]];
    return a;
}
+ (NSDictionary *)defaults {
    return @{
        @"enabled": @NO, @"preamp": @(-3.0), @"output": @0.0,
        @"comp": @{@"on": @NO, @"threshold": @(-24.0), @"knee": @6.0, @"ratio": @3.0, @"attack": @10.0, @"release": @150.0, @"makeup": @0.0},
        @"crossfeed": @{@"on": @NO, @"level": @(-6.0), @"cutoff": @700.0, @"delay": @0.3},
        @"width": @{@"on": @NO, @"width": @1.0, @"balance": @0.0, @"mono": @NO, @"swap": @NO},
        @"spatial": @{@"on": @NO, @"angle": @30.0, @"amount": @0.8, @"distance": @1.0, @"mode": @1, @"surround": @0.5, @"height": @0.3},
        @"routing": @{@"enabled": @NO, @"devices": @{}, @"types": @{}},
        @"reverb": @{@"on": @NO, @"decay": @1.8, @"predelay": @20.0, @"damping": @6000.0, @"width": @1.0, @"mix": @0.25},
        @"limiter": @{@"on": @YES, @"ceiling": @(-1.0)},
        @"presets": @[],
    };
}
static id deepMutable(id plist) {
    if (!plist) return nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
}
- (void)load {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: [NSDictionary dictionaryWithContentsOfFile:kLegacyConfigPath];
    NSMutableDictionary *c = [saved isKindOfClass:NSDictionary.class] ? deepMutable(saved) : [NSMutableDictionary new];
    if (!c) c = [NSMutableDictionary new];
    NSDictionary *defaults = [TBStore defaults];
    for (NSString *key in defaults) {
        id def = defaults[key], have = c[key];
        if (!have) { c[key] = deepMutable(@{@"v": def})[@"v"]; continue; }
        if ([def isKindOfClass:NSDictionary.class] && [have isKindOfClass:NSMutableDictionary.class]) {
            for (NSString *sub in def) if (!have[sub]) ((NSMutableDictionary *)have)[sub] = def[sub];
        }
    }
    if (![c[@"bands"] isKindOfClass:NSArray.class] || [c[@"bands"] count] == 0) c[@"bands"] = deepMutable([TBStore defaultBands]);
    NSMutableArray *bands = c[@"bands"];
    while (bands.count > kMaxBands) [bands removeLastObject];
    self.config = c;
}
- (NSMutableArray<NSMutableDictionary *> *)bands { return self.config[@"bands"]; }
- (id)valueAt:(NSString *)keyPath { return [self.config valueForKeyPath:keyPath]; }
- (void)setValue:(id)value at:(NSString *)keyPath { [self.config setValue:value forKeyPath:keyPath]; }
- (void)changed {
    if (_pending) return;
    _pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(70 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        self->_pending = NO;
        [self commit];
    });
}
- (BOOL)writePrimary {
    [[NSFileManager defaultManager] createDirectoryAtPath:kConfigPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    return [self.config writeToFile:kConfigPath atomically:YES];
}
- (void)commit {
    BOOL ok = [self writePrimary];
    if (!ok && !_repaired) {
        _repaired = YES;
        runHelper(@"fix-prefs", nil);
        ok = [self writePrimary];
    }
    const BOOL legacy = [self.config writeToFile:kLegacyConfigPath atomically:YES];
    self.lastError = ok ? nil : legacy ? @"Saved only to /var/mobile. The audio daemon may not be able to read it." : @"Could not save settings anywhere.";
    if (ok || legacy) notify_post(kReloadNotification);
}
@end


#pragma mark - Root helper and diagnostics

static int runHelper(NSString *command, NSString **output) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    const char *argv[] = {"timbrectl", command.UTF8String, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, kHelperPath.fileSystemRepresentation, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    NSMutableData *data = [NSMutableData new];
    if (rc == 0) {
        char buf[256]; ssize_t n;
        while ((n = read(fds[0], buf, sizeof(buf))) > 0) [data appendBytes:buf length:(NSUInteger)n];
        int status = 0;
        waitpid(pid, &status, 0);
        rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    } else if (output) {
        *output = [NSString stringWithFormat:@"Could not launch %@ (%s)", kHelperPath, strerror(rc)];
    }
    close(fds[0]);
    if (output && data.length) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return rc;
}
static int killNamed(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || !len) return 0;
    len += len / 4;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return 0;
    int killed = 0;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0)
        for (size_t i = 0; i < len / sizeof(struct kinfo_proc); i++)
            if (strncmp(procs[i].kp_proc.p_comm, name, sizeof(procs[i].kp_proc.p_comm)) == 0 && kill(procs[i].kp_proc.p_pid, SIGKILL) == 0) killed++;
    free(procs);
    return killed;
}
static NSString *restartAudio(void) {
    NSString *out = nil;
    if (runHelper(@"restart-audio", &out) == 0) return out ?: @"Audio daemon restarted.";
    const int n = killNamed("mediaserverd") + killNamed("audiomxd");
    if (n > 0) return @"Audio daemon restarted.";
    return [NSString stringWithFormat:@"Could not restart the audio daemon. %@", out ?: @""];
}

static uint64_t statusValue(NSString *process, NSString *field) {
    NSString *name = [NSString stringWithFormat:@"com.soum91.timbreaudio.status.%@.%@", process, field];
    int token = 0;
    uint64_t v = 0;
    if (notify_register_check(name.UTF8String, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &v);
        notify_cancel(token);
    }
    return v;
}
typedef struct {
    BOOL alive, hooked, enabled, effects;
    pid_t pid;
    int source, bands, slots;
    uint64_t calls, nested, frames, format, rate;
} TBDaemonStatus;
// The daemon's sandbox blocks Darwin notify state, so the status file it writes under the jailbreak root
// is the primary source. Notify state is kept as a fallback for setups where it does get through.
static NSDictionary<NSString *, NSString *> *statusFile(NSString *process) {
    for (NSString *dir in @[@"/var/jb/var/mobile/Library/Preferences", @"/var/tmp", @"/tmp"]) {
        NSString *path = [NSString stringWithFormat:@"%@/com.soum91.timbreaudio.status.%@.txt", dir, process];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text.length) continue;
        NSMutableDictionary *d = [NSMutableDictionary new];
        for (NSString *token in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            NSRange eq = [token rangeOfString:@"="];
            if (eq.location != NSNotFound) d[[token substringToIndex:eq.location]] = [token substringFromIndex:eq.location + 1];
        }
        if (d[@"time"]) return d;
    }
    return nil;
}
static uint64_t fileValue(NSDictionary *d, NSString *key) {
    NSString *v = d[key];
    if (!v) return 0;
    if ([v hasPrefix:@"0x"]) return strtoull(v.UTF8String, NULL, 16);
    return strtoull(v.UTF8String, NULL, 10);
}
static TBDaemonStatus daemonStatus(NSString *process) {
    TBDaemonStatus s = {0};
    NSDictionary *f = statusFile(process);
    const long now = (long)time(NULL);
    if (f && labs(now - (long)fileValue(f, @"time")) <= 4) {
        s.alive = YES;
        s.pid = (pid_t)fileValue(f, @"pid");
        s.hooked = fileValue(f, @"hook") != 0;
        s.source = (int)fileValue(f, @"source");
        s.enabled = fileValue(f, @"enabled") != 0;
        s.effects = fileValue(f, @"fx") != 0;
        s.bands = (int)fileValue(f, @"bands");
        s.calls = fileValue(f, @"calls");
        s.nested = fileValue(f, @"nested");
        s.frames = fileValue(f, @"frames");
        s.format = (fileValue(f, @"format_flags") & 0xffffffff) | (fileValue(f, @"channels") & 0xff) << 32 | (fileValue(f, @"bits") & 0xff) << 40 |
                   (fileValue(f, @"buffers") & 0xff) << 48 | (fileValue(f, @"result") & 0xff) << 56;
        s.rate = fileValue(f, @"rate");
        return s;
    }
    const uint64_t info = statusValue(process, @"info"), beat = statusValue(process, @"heartbeat");
    s.alive = beat && labs(now - (long)beat) <= 4;
    s.pid = (pid_t)(info >> 32);
    s.hooked = info & 1;
    s.source = (int)((info >> 2) & 3);
    s.enabled = (info >> 4) & 1;
    s.effects = (info >> 5) & 1;
    s.bands = (int)((info >> 6) & 31);
    s.slots = (int)((info >> 11) & 7);
    s.calls = statusValue(process, @"calls");
    s.nested = statusValue(process, @"nested");
    s.frames = statusValue(process, @"frames");
    s.format = statusValue(process, @"format");
    s.rate = statusValue(process, @"rate");
    return s;
}
static NSString *rejectText(unsigned r) {
    switch (r) {
        case 0: return @"processing";
        case 1: return @"skipped: Timbre is off or settings unreadable";
        case 2: return @"skipped: render returned an error";
        case 3: return @"skipped: empty or short buffers";
        case 4: return @"skipped: could not read stream format";
        case 5: return @"skipped: not linear PCM";
        case 6: return @"skipped: unsupported sample type";
        case 7: return @"skipped: unsupported channel layout";
        case 8: return @"skipped: unsupported sample rate";
    }
    return @"unknown";
}
static NSString *formatText(uint64_t f, uint64_t rate) {
    if (!f && !rate) return @"no audio seen yet";
    const unsigned flags = (unsigned)(f & 0xffffffff), ch = (unsigned)((f >> 32) & 0xff), bits = (unsigned)((f >> 40) & 0xff), bufs = (unsigned)((f >> 48) & 0xff);
    NSString *type = (flags & kAudioFormatFlagIsFloat) ? @"float" : (flags & kAudioFormatFlagIsSignedInteger) ? @"int" : @"fixed";
    NSString *layout = (flags & kAudioFormatFlagIsNonInterleaved) ? @"planar" : @"interleaved";
    return [NSString stringWithFormat:@"%u-bit %@ %@, %u ch, %u buffer%@, %.0f Hz", bits, type, layout, ch, bufs, bufs == 1 ? @"" : @"s", (double)(uint32_t)rate];
}

#pragma mark - Vertical fader

@interface TBFader : UIControl
@property(nonatomic) double value, minimumValue, maximumValue, defaultValue, step;
@property(nonatomic) BOOL logarithmic, accent;
@property(nonatomic, strong) UIColor *color;
@end

@implementation TBFader {
    double _norm, _startValue;
    CGFloat _lastY;
    UISelectionFeedbackGenerator *_haptic;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        _minimumValue = 0; _maximumValue = 1; _color = UIColor.whiteColor;
        _haptic = [UISelectionFeedbackGenerator new];
        UITapGestureRecognizer *reset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetToDefault)];
        reset.numberOfTapsRequired = 2;
        [self addGestureRecognizer:reset];
    }
    return self;
}
- (double)normFor:(double)v {
    const double lo = self.minimumValue, hi = self.maximumValue;
    if (hi <= lo) return 0;
    if (self.logarithmic) return clampd(log(fmax(v, lo) / lo) / log(hi / lo), 0, 1);
    return clampd((v - lo) / (hi - lo), 0, 1);
}
- (double)valueFor:(double)n {
    const double lo = self.minimumValue, hi = self.maximumValue;
    n = clampd(n, 0, 1);
    double v = self.logarithmic ? lo * pow(hi / lo, n) : lo + n * (hi - lo);
    if (self.logarithmic) v = roundSignificant(v, v < 100 ? 2 : 3);
    if (self.step > 0) v = round(v / self.step) * self.step;
    return clampd(v, lo, hi);
}
- (void)setValue:(double)value { _value = value; [self setNeedsDisplay]; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.alpha = enabled ? 1 : .3; }
- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    const CGFloat mid = CGRectGetMidX(self.bounds), top = 14, bottom = self.bounds.size.height - 14;
    const CGFloat y = bottom - (CGFloat)[self normFor:self.value] * (bottom - top);
    UIColor *base = self.accent ? self.color : UIColor.whiteColor;
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(c, [base colorWithAlphaComponent:self.accent ? .2 : .1].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextMoveToPoint(c, mid, top); CGContextAddLineToPoint(c, mid, bottom); CGContextStrokePath(c);
    CGContextSetStrokeColorWithColor(c, [base colorWithAlphaComponent:self.accent ? 1 : .32].CGColor);
    CGContextSetLineWidth(c, self.accent ? 4 : 3);
    CGContextMoveToPoint(c, mid, y); CGContextAddLineToPoint(c, mid, bottom); CGContextStrokePath(c);
    UIBezierPath *thumb = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(mid - 9, y - 12, 18, 24) cornerRadius:5];
    [(self.accent ? self.color : [UIColor colorWithWhite:.93 alpha:1]) setFill];
    [thumb fill];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _lastY = [touch locationInView:self].y;
    _norm = [self normFor:self.value];
    _startValue = self.value;
    [_haptic prepare];
    return YES;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    const CGPoint p = [touch locationInView:self];
    const CGFloat travel = fmax(40, self.bounds.size.height - 28);
    // Slide a finger sideways off the fader for 4x finer control.
    const double scale = fabs(p.x - CGRectGetMidX(self.bounds)) > 70 ? .25 : 1;
    _norm = clampd(_norm - (p.y - _lastY) / travel * scale, 0, 1);
    _lastY = p.y;
    const double v = [self valueFor:_norm], old = self.value;
    if (v != old) {
        if ((old - self.defaultValue) * (v - self.defaultValue) <= 0 && v != old) [_haptic selectionChanged];
        self.value = v;
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    return YES;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    // A horizontal scroll took over; undo any tiny vertical movement.
    if (self.value != _startValue) {
        self.value = _startValue;
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}
- (void)resetToDefault {
    self.value = self.defaultValue;
    [_haptic selectionChanged];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}
@end

#pragma mark - Horizontal scroller that lets vertical fader drags through

@interface TBStripScroller : UIScrollView
@end
@implementation TBStripScroller
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return YES; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.panGestureRecognizer) {
        const CGPoint v = [self.panGestureRecognizer velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return [super gestureRecognizerShouldBegin:g];
}
@end

#pragma mark - Response graph

@interface TBGraph : UIView
@property(nonatomic) NSInteger selected;
@property(nonatomic, copy) void (^onSelect)(NSInteger index);
@property(nonatomic, copy) void (^onEdit)(NSInteger index, BOOL final);
@end

@implementation TBGraph {
    NSInteger _dragging;
    double _pinchStartQ;
}
static const double kGraphDB = 18;
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = cardColor();
        self.layer.cornerRadius = 14;
        self.contentMode = UIViewContentModeRedraw;
        _dragging = -1;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)]];
        [self addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
    }
    return self;
}
- (CGFloat)xForFrequency:(double)f { return (CGFloat)(log(clampd(f, 20, 20000) / 20) / log(1000)) * self.bounds.size.width; }
- (double)frequencyForX:(CGFloat)x { return 20 * pow(1000, clampd(x / self.bounds.size.width, 0, 1)); }
- (CGFloat)yForDB:(double)db { const CGFloat h = self.bounds.size.height; return h / 2 - (CGFloat)(clampd(db, -kGraphDB, kGraphDB) / kGraphDB) * (h / 2 - 12); }
- (double)dbForY:(CGFloat)y { const CGFloat h = self.bounds.size.height; return (h / 2 - y) / (h / 2 - 12) * kGraphDB; }
- (CGPoint)pointForBand:(NSDictionary *)b {
    const NSInteger t = [b[@"type"] integerValue];
    return CGPointMake([self xForFrequency:[b[@"frequency"] doubleValue]], [self yForDB:typeUsesGain(t) ? [b[@"gain"] doubleValue] : 0]);
}
- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (!c) return;
    const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    NSDictionary *gridFont = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium], NSForegroundColorAttributeName: [UIColor colorWithWhite:.4 alpha:1]};
    CGContextSetLineWidth(c, .5);
    for (NSNumber *f in @[@50, @100, @200, @500, @1000, @2000, @5000, @10000]) {
        const CGFloat x = [self xForFrequency:f.doubleValue];
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:.07].CGColor);
        CGContextMoveToPoint(c, x, 0); CGContextAddLineToPoint(c, x, h); CGContextStrokePath(c);
        if (f.intValue == 100 || f.intValue == 1000 || f.intValue == 10000)
            [(f.intValue >= 1000 ? [NSString stringWithFormat:@"%dk", f.intValue / 1000] : f.stringValue) drawAtPoint:CGPointMake(x + 3, h - 13) withAttributes:gridFont];
    }
    for (NSNumber *db in @[@(-12), @(-6), @0, @6, @12]) {
        const CGFloat y = [self yForDB:db.doubleValue];
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1 alpha:db.intValue == 0 ? .2 : .07].CGColor);
        CGContextMoveToPoint(c, 0, y); CGContextAddLineToPoint(c, w, y); CGContextStrokePath(c);
        if (db.intValue) [[NSString stringWithFormat:@"%+d", db.intValue] drawAtPoint:CGPointMake(4, y - 11) withAttributes:gridFont];
    }
    NSArray<NSDictionary *> *bands = [TBStore shared].bands;
    const int n = 180;
    double total[n];
    for (int i = 0; i < n; i++) total[i] = 0;
    NSInteger idx = 0;
    for (NSDictionary *b in bands) {
        const BOOL on = [b[@"enabled"] boolValue];
        if (on) {
            TBCoeffs k = tbCoeffs([b[@"type"] integerValue], [b[@"frequency"] doubleValue], [b[@"gain"] doubleValue], [b[@"q"] doubleValue], kGraphRate);
            CGMutablePathRef fill = CGPathCreateMutable();
            CGPathMoveToPoint(fill, NULL, 0, h / 2);
            for (int i = 0; i < n; i++) {
                const double f = 20 * pow(1000, i / (double)(n - 1)), db = tbMagnitudeDB(k, f, kGraphRate);
                total[i] += db;
                CGPathAddLineToPoint(fill, NULL, i * w / (n - 1), [self yForDB:db]);
            }
            CGPathAddLineToPoint(fill, NULL, w, h / 2);
            CGPathCloseSubpath(fill);
            CGContextAddPath(c, fill);
            CGContextSetFillColorWithColor(c, [bandColor(idx) colorWithAlphaComponent:idx == self.selected ? .22 : .09].CGColor);
            CGContextFillPath(c);
            CGPathRelease(fill);
        }
        idx++;
    }
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:.96 alpha:1].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    for (int i = 0; i < n; i++) {
        const CGFloat x = i * w / (n - 1), y = [self yForDB:total[i]];
        if (!i) CGContextMoveToPoint(c, x, y); else CGContextAddLineToPoint(c, x, y);
    }
    CGContextStrokePath(c);
    idx = 0;
    for (NSDictionary *b in bands) {
        const CGPoint p = [self pointForBand:b];
        const BOOL on = [b[@"enabled"] boolValue];
        UIColor *col = [bandColor(idx) colorWithAlphaComponent:on ? 1 : .35];
        if (idx == self.selected) {
            CGContextSetStrokeColorWithColor(c, col.CGColor); CGContextSetLineWidth(c, 2);
            CGContextStrokeEllipseInRect(c, CGRectMake(p.x - 10, p.y - 10, 20, 20));
        }
        CGContextSetFillColorWithColor(c, col.CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(p.x - 5.5, p.y - 5.5, 11, 11));
        idx++;
    }
}
- (NSInteger)bandNear:(CGPoint)p {
    NSInteger best = -1; CGFloat bestD = 44;
    NSInteger i = 0;
    for (NSDictionary *b in [TBStore shared].bands) {
        const CGPoint q = [self pointForBand:b];
        const CGFloat d = hypot(q.x - p.x, q.y - p.y);
        if (d < bestD) { bestD = d; best = i; }
        i++;
    }
    return best;
}
- (void)tap:(UITapGestureRecognizer *)g {
    const NSInteger i = [self bandNear:[g locationInView:self]];
    if (i >= 0 && self.onSelect) self.onSelect(i);
}
- (void)pan:(UIPanGestureRecognizer *)g {
    const CGPoint p = [g locationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = [self bandNear:p];
        if (_dragging >= 0 && self.onSelect) self.onSelect(_dragging);
    }
    if (_dragging < 0 || _dragging >= (NSInteger)[TBStore shared].bands.count) return;
    NSMutableDictionary *b = [TBStore shared].bands[(NSUInteger)_dragging];
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        b[@"frequency"] = @(roundSignificant(clampd([self frequencyForX:p.x], 20, 20000), 3));
        if (typeUsesGain([b[@"type"] integerValue])) b[@"gain"] = @(round(clampd([self dbForY:p.y], -24, 24) * 10) / 10);
        if (self.onEdit) self.onEdit(_dragging, NO);
    } else {
        if (self.onEdit) self.onEdit(_dragging, YES);
        _dragging = -1;
    }
}
- (void)pinch:(UIPinchGestureRecognizer *)g {
    NSArray *bands = [TBStore shared].bands;
    if (self.selected < 0 || self.selected >= (NSInteger)bands.count) return;
    NSMutableDictionary *b = bands[(NSUInteger)self.selected];
    if (g.state == UIGestureRecognizerStateBegan) _pinchStartQ = [b[@"q"] doubleValue];
    // Spread fingers apart to widen the band (lower Q).
    b[@"q"] = @(roundSignificant(clampd(_pinchStartQ / fmax(g.scale, .05), .2, 10), 2));
    if (self.onEdit) self.onEdit(self.selected, g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled);
}
@end

#pragma mark - Band strip (gain / frequency / Q)

@class TBEQController;
@interface TBBandStrip : UIView
@property(nonatomic) NSInteger index;
@property(nonatomic, strong) UIButton *header;
@property(nonatomic, strong) TBFader *gain, *freq, *q;
@property(nonatomic, strong) UIButton *gainValue, *freqValue, *qValue;
@property(nonatomic, getter=isSelected) BOOL selected;
- (void)refresh;
@end

@interface TBEQController : UIViewController
- (void)stripChanged:(TBBandStrip *)strip final:(BOOL)final;
- (void)stripSelected:(TBBandStrip *)strip;
- (void)editValue:(UIButton *)sender;
- (UIMenu *)menuForBand:(NSInteger)index;
@end

@implementation TBBandStrip {
    __weak TBEQController *_owner;
    UIView *_highlight;
}
- (instancetype)initWithIndex:(NSInteger)index owner:(TBEQController *)owner {
    if ((self = [super initWithFrame:CGRectZero])) {
        _index = index; _owner = owner;
        UIColor *color = bandColor(index);
        _highlight = [UIView new];
        _highlight.translatesAutoresizingMaskIntoConstraints = NO;
        _highlight.layer.cornerRadius = 12;
        _highlight.backgroundColor = [color colorWithAlphaComponent:.07];
        _highlight.hidden = YES;
        [self addSubview:_highlight];

        _header = [UIButton buttonWithType:UIButtonTypeSystem];
        _header.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        _header.tintColor = color;
        _header.showsMenuAsPrimaryAction = YES;
        _header.menu = [owner menuForBand:index];

        _gain = [self fader:-24 :24 def:0 log:NO step:.1]; _gain.accent = YES; _gain.color = color;
        _freq = [self fader:20 :20000 def:1000 log:YES step:0];
        _q = [self fader:.2 :10 def:1.41 log:YES step:0];

        UIStackView *faders = [[UIStackView alloc] initWithArrangedSubviews:@[_gain, _freq, _q]];
        faders.distribution = UIStackViewDistributionFillEqually;
        _gainValue = [self valueButton:color]; _gainValue.tag = 0;
        _freqValue = [self valueButton:UIColor.whiteColor]; _freqValue.tag = 1;
        _qValue = [self valueButton:UIColor.whiteColor]; _qValue.tag = 2;
        UIStackView *values = [[UIStackView alloc] initWithArrangedSubviews:@[_gainValue, _freqValue, _qValue]];
        values.distribution = UIStackViewDistributionFillEqually;
        [values.heightAnchor constraintEqualToConstant:38].active = YES;

        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_header, faders, values]];
        col.axis = UILayoutConstraintAxisVertical;
        col.spacing = 2;
        col.translatesAutoresizingMaskIntoConstraints = NO;
        [_header.heightAnchor constraintEqualToConstant:28].active = YES;
        [self addSubview:col];
        [NSLayoutConstraint activateConstraints:@[
            [col.topAnchor constraintEqualToAnchor:self.topAnchor], [col.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:3], [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-3],
            [_highlight.topAnchor constraintEqualToAnchor:self.topAnchor], [_highlight.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_highlight.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [_highlight.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.widthAnchor constraintEqualToConstant:118],
        ]];
        [self refresh];
    }
    return self;
}
- (TBFader *)fader:(double)lo :(double)hi def:(double)def log:(BOOL)lg step:(double)step {
    TBFader *f = [TBFader new];
    f.minimumValue = lo; f.maximumValue = hi; f.defaultValue = def; f.logarithmic = lg; f.step = step;
    [f addTarget:self action:@selector(moved) forControlEvents:UIControlEventValueChanged];
    [f addTarget:self action:@selector(released) forControlEvents:UIControlEventEditingDidEnd];
    [f addTarget:self action:@selector(touched) forControlEvents:UIControlEventTouchDown];
    return f;
}
- (UIButton *)valueButton:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.tintColor = color;
    [b addTarget:_owner action:@selector(editValue:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (NSMutableDictionary *)band { return [TBStore shared].bands[(NSUInteger)self.index]; }
- (void)setSelected:(BOOL)selected { _selected = selected; _highlight.hidden = !selected; }
- (void)setTitle:(NSString *)value unit:(NSString *)unit on:(UIButton *)button color:(UIColor *)color {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:value attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: color}];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:unit] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium], NSForegroundColorAttributeName: [color colorWithAlphaComponent:.6]}]];
    [UIView performWithoutAnimation:^{ [button setAttributedTitle:s forState:UIControlStateNormal]; [button layoutIfNeeded]; }];
}
- (void)refresh {
    NSDictionary *b = self.band;
    const NSInteger type = [b[@"type"] integerValue];
    const BOOL on = [b[@"enabled"] boolValue];
    UIColor *color = bandColor(self.index);
    [UIView performWithoutAnimation:^{
        [self.header setTitle:[NSString stringWithFormat:@"%ld  %@ ▾", (long)self.index + 1, typeCodes()[(NSUInteger)clampd(type, 0, 7)]] forState:UIControlStateNormal];
        [self.header layoutIfNeeded];
    }];
    self.gain.value = [b[@"gain"] doubleValue];
    self.freq.value = [b[@"frequency"] doubleValue];
    self.q.value = [b[@"q"] doubleValue];
    self.gain.enabled = typeUsesGain(type);
    self.gainValue.enabled = typeUsesGain(type);
    [self setTitle:typeUsesGain(type) ? formatNumber(self.gain.value, TBUnitDB) : @"—" unit:@"dB" on:self.gainValue color:color];
    NSString *hz = formatNumber(self.freq.value, TBUnitHz);
    [self setTitle:[hz hasSuffix:@"k"] ? [hz substringToIndex:hz.length - 1] : hz unit:[hz hasSuffix:@"k"] ? @"kHz" : @"Hz" on:self.freqValue color:UIColor.whiteColor];
    [self setTitle:formatNumber(self.q.value, TBUnitQ) unit:@"Q" on:self.qValue color:UIColor.whiteColor];
    self.alpha = on ? 1 : .45;
}
- (void)touched { [_owner stripSelected:self]; }
- (void)moved {
    NSMutableDictionary *b = self.band;
    b[@"gain"] = @(self.gain.value); b[@"frequency"] = @(self.freq.value); b[@"q"] = @(self.q.value);
    [self refresh];
    [_owner stripChanged:self final:NO];
}
- (void)released { [_owner stripChanged:self final:YES]; }
@end

#pragma mark - Status (EQE-style settings page)

static NSArray<NSString *> *audioDaemons(void) { return @[@"mediaserverd", @"audiomxd"]; }

@interface TBStatusController : UITableViewController
@end
@implementation TBStatusController {
    NSTimer *_timer;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_previous;  // calls, nested, frames
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_rates;
    NSString *_message;
    NSString *_inspect;
}
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Status";
        _inspect = @"Running…";
        _previous = [NSMutableDictionary new];
        _rates = [NSMutableDictionary new];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)runInspect {
    _inspect = @"Running…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = nil;
        const int rc = runHelper(@"inspect", &out);
        dispatch_async(dispatch_get_main_queue(), ^{
            TBStatusController *me = weakSelf;
            if (!me) return;
            me->_inspect = out.length ? [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : [NSString stringWithFormat:@"timbrectl returned %d with no output", rc];
            [me.tableView reloadData];
        });
    });
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self tick];
    [self runInspect];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [_timer invalidate]; _timer = nil; }
- (void)tick {
    for (NSString *d in audioDaemons()) {
        TBDaemonStatus st = daemonStatus(d);
        NSArray *now = @[@(st.calls), @(st.nested), @(st.frames)];
        NSArray *before = _previous[d];
        if (before) {
            NSMutableArray *r = [NSMutableArray new];
            for (NSUInteger i = 0; i < 3; i++) [r addObject:@(MAX(0.0, [now[i] doubleValue] - [before[i] doubleValue]))];
            _rates[d] = r;
        }
        _previous[d] = now;
    }
    [self.tableView reloadData];
}
// Section layout: one per daemon, then deep check, settings file, actions.
- (NSInteger)deepSection { return (NSInteger)audioDaemons().count; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return (NSInteger)audioDaemons().count + 3; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s < (NSInteger)audioDaemons().count) return audioDaemons()[(NSUInteger)s];
    if (s == self.deepSection) return @"Deep check (root)";
    return s == self.deepSection + 1 ? @"Settings file" : @"Actions";
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == self.deepSection)
        return @"Reads the daemons' memory maps as root, so it works even if the sandbox blocks the live status above. Tap to run again.";
    if (s == self.deepSection + 2)
        return _message ?: @"If a daemon shows Not loaded, restart audio. If it still is not loaded, ElleKit is not injecting into it. Turn off EQE's AudioUnitRender hook while testing Timbre so the audio is not processed twice.";
    if (s == 0) return @"Calls are outermost AudioUnitRender calls per second; nested are mixer inputs Timbre leaves alone.";
    return nil;
}
- (NSArray<NSArray<NSString *> *> *)rowsForDaemon:(NSString *)d {
    TBDaemonStatus st = daemonStatus(d);
    if (!st.alive) return @[@[@"Tweak", st.pid ? @"Stopped reporting" : @"Not loaded"]];
    NSArray *r = _rates[d];
    NSString *(^rate)(NSUInteger) = ^NSString *(NSUInteger i) { return r ? [NSString stringWithFormat:@"%.0f /s", [r[i] doubleValue]] : @"…"; };
    NSString *src = @[@"not readable", @"jailbreak root", @"/var/mobile (legacy)", @"?"][(NSUInteger)st.source];
    return @[
        @[@"Tweak", [NSString stringWithFormat:@"Loaded (pid %d)", st.pid]],
        @[@"AudioUnitRender hook", st.hooked ? @"Installed" : @"Failed"],
        @[@"Settings", src],
        @[@"Timbre", st.enabled ? [NSString stringWithFormat:@"On, %d bands%@", st.bands, st.effects ? @" + effects" : @""] : @"Off"],
        @[@"Render calls", rate(0)],
        @[@"Nested calls", rate(1)],
        @[@"Frames processed", rate(2)],
        @[@"Last stream", formatText(st.format, st.rate)],
        @[@"Result", rejectText((unsigned)(st.format >> 56))],
    ];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    const NSInteger n = (NSInteger)audioDaemons().count;
    if (s < n) return (NSInteger)[self rowsForDaemon:audioDaemons()[(NSUInteger)s]].count;
    if (s == self.deepSection) return 1;
    return s == n + 1 ? 2 : 3;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"s"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"s"];
    UIListContentConfiguration *cfg = [UIListContentConfiguration valueCellConfiguration];
    cfg.secondaryTextProperties.numberOfLines = 0;
    const NSInteger n = (NSInteger)audioDaemons().count;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == self.deepSection) {
        UIListContentConfiguration *cell = [UIListContentConfiguration cellConfiguration];
        cell.text = _inspect;
        cell.textProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.textProperties.numberOfLines = 0;
        c.contentConfiguration = cell;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (ip.section < n) {
        NSArray *row = [self rowsForDaemon:audioDaemons()[(NSUInteger)ip.section]][(NSUInteger)ip.row];
        cfg.text = row[0]; cfg.secondaryText = row[1];
    } else if (ip.section == n + 1) {
        NSString *path = ip.row == 0 ? kConfigPath : kLegacyConfigPath;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        cfg.text = ip.row == 0 ? @"Jailbreak root" : @"Legacy";
        cfg.secondaryText = attrs ? [NSString stringWithFormat:@"%@ %@", attrs[NSFileOwnerAccountName], [NSDateFormatter localizedStringFromDate:attrs[NSFileModificationDate] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]] : @"missing";
        if (ip.row == 0 && [TBStore shared].lastError) cfg.secondaryText = [TBStore shared].lastError;
    } else {
        cfg.text = @[@"Restart audio (killall -9 mediaserverd)", @"Save settings again", @"Repair settings permissions"][(NSUInteger)ip.row];
        cfg.textProperties.color = ip.row == 0 ? UIColor.systemRedColor : accentColor();
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    c.contentConfiguration = cfg;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == self.deepSection) { [self runInspect]; return; }
    if (ip.section != self.deepSection + 2) return;
    if (ip.row == 0) {
        [[TBStore shared] commit];
        _message = restartAudio();
        [_previous removeAllObjects]; [_rates removeAllObjects];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf runInspect]; });
    } else if (ip.row == 1) {
        [[TBStore shared] commit];
        _message = [TBStore shared].lastError ?: @"Saved and sent reload notification.";
    } else {
        NSString *out = nil;
        _message = runHelper(@"fix-prefs", &out) == 0 ? @"Permissions repaired." : (out ?: @"Repair failed.");
        [[TBStore shared] commit];
    }
    [t reloadData];
}
@end

#pragma mark - EQ screen

@implementation TBEQController {
    TBGraph *_graph;
    UIStackView *_strips;
    TBStripScroller *_scroller;
    UISwitch *_power;
    UIButton *_preampValue;
    UISlider *_preamp;
    UIButton *_statusPill;
    NSTimer *_statusTimer;
    uint64_t _lastFrames;
    NSInteger _selected;
}
- (TBStore *)store { return [TBStore shared]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _selected = 0;

    UILabel *title = [UILabel new];
    title.text = @"Timbre";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
    title.textColor = UIColor.whiteColor;
    _power = [UISwitch new];
    _power.onTintColor = accentColor();
    [_power addTarget:self action:@selector(powerChanged) forControlEvents:UIControlEventValueChanged];
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    more.tintColor = UIColor.whiteColor;
    more.showsMenuAsPrimaryAction = YES;
    more.menu = [self moreMenu];
    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    [gear setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    gear.tintColor = UIColor.whiteColor;
    [gear addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    _statusPill = [UIButton buttonWithType:UIButtonTypeSystem];
    _statusPill.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _statusPill.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _statusPill.titleLabel.numberOfLines = 2;
    [_statusPill addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    AVRoutePickerView *airplay = [AVRoutePickerView new];
    airplay.tintColor = UIColor.whiteColor;
    airplay.activeTintColor = accentColor();
    airplay.prioritizesVideoDevices = NO;
    [airplay.widthAnchor constraintEqualToConstant:30].active = YES;
    [airplay.heightAnchor constraintEqualToConstant:30].active = YES;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[title, [UIView new], airplay, gear, more, _power]];
    head.spacing = 14; head.alignment = UIStackViewAlignmentCenter;

    UILabel *pre = [UILabel new];
    pre.text = @"PREAMP"; pre.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; pre.textColor = dimColor();
    _preamp = [UISlider new];
    _preamp.minimumValue = -24; _preamp.maximumValue = 0;
    _preamp.minimumTrackTintColor = accentColor();
    [_preamp addTarget:self action:@selector(preampChanged) forControlEvents:UIControlEventValueChanged];
    _preampValue = [UIButton buttonWithType:UIButtonTypeSystem];
    _preampValue.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _preampValue.tintColor = UIColor.whiteColor;
    _preampValue.tag = 100;
    [_preampValue addTarget:self action:@selector(editValue:) forControlEvents:UIControlEventTouchUpInside];
    [_preampValue.widthAnchor constraintEqualToConstant:70].active = YES;
    UIButton *autoGain = [UIButton buttonWithType:UIButtonTypeSystem];
    [autoGain setTitle:@"Auto" forState:UIControlStateNormal];
    autoGain.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    autoGain.tintColor = accentColor();
    [autoGain addTarget:self action:@selector(autoPreamp) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *preRow = [[UIStackView alloc] initWithArrangedSubviews:@[pre, _preamp, _preampValue, autoGain]];
    preRow.spacing = 10; preRow.alignment = UIStackViewAlignmentCenter;

    _graph = [TBGraph new];
    __weak typeof(self) weakSelf = self;
    _graph.onSelect = ^(NSInteger i) { [weakSelf selectBand:i scroll:YES]; };
    _graph.onEdit = ^(NSInteger i, BOOL final) { [weakSelf bandEdited:i final:final]; };

    _scroller = [TBStripScroller new];
    _scroller.delaysContentTouches = NO;
    _scroller.showsHorizontalScrollIndicator = NO;
    _scroller.alwaysBounceHorizontal = YES;
    _strips = [UIStackView new];
    _strips.spacing = 4;
    _strips.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroller addSubview:_strips];
    [NSLayoutConstraint activateConstraints:@[
        [_strips.leadingAnchor constraintEqualToAnchor:_scroller.contentLayoutGuide.leadingAnchor],
        [_strips.trailingAnchor constraintEqualToAnchor:_scroller.contentLayoutGuide.trailingAnchor],
        [_strips.topAnchor constraintEqualToAnchor:_scroller.contentLayoutGuide.topAnchor],
        [_strips.bottomAnchor constraintEqualToAnchor:_scroller.contentLayoutGuide.bottomAnchor],
        [_strips.heightAnchor constraintEqualToAnchor:_scroller.frameLayoutGuide.heightAnchor],
    ]];

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[head, _statusPill, preRow, _graph, _scroller]];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 10;
    [root setCustomSpacing:14 afterView:_graph];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    // Everything hugs its content except the fader strips, which take all remaining height.
    for (UIView *v in @[head, _statusPill, preRow, _graph]) {
        [v setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [v setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    }
    [_scroller setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [_scroller setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [_scroller.heightAnchor constraintGreaterThanOrEqualToConstant:230].active = YES;
    NSLayoutConstraint *graphHeight = [_graph.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:.24];
    graphHeight.priority = UILayoutPriorityDefaultHigh;
    graphHeight.active = YES;
    [self.view addSubview:root];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [root.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6],
        [root.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [root.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_graph.heightAnchor constraintGreaterThanOrEqualToConstant:140],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadAll) name:kChanged object:nil];
    [self reloadAll];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAll];
    [self updateStatus];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [_statusTimer invalidate]; _statusTimer = nil; }
- (void)showOutputs {
    Class c = NSClassFromString(@"TBRoutesController");
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[c new]];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)showStatus {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[TBStatusController new]];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)updateStatus {
    NSString *text = nil; UIColor *color = nil;
    for (NSString *d in audioDaemons()) {
        TBDaemonStatus st = daemonStatus(d);
        if (!st.alive) continue;
        const BOOL flowing = st.frames > _lastFrames && _lastFrames > 0;
        _lastFrames = st.frames;
        const unsigned reject = (unsigned)(st.format >> 56);
        if (!st.hooked) { text = [NSString stringWithFormat:@"● Loaded in %@ but the hook failed", d]; color = UIColor.systemRedColor; }
        else if (st.source == 0) { text = [NSString stringWithFormat:@"● %@ cannot read the settings file. Tap for status", d]; color = UIColor.systemOrangeColor; }
        else if (!st.enabled) { text = [NSString stringWithFormat:@"● Hooked in %@ · Timbre is off", d]; color = dimColor(); }
        else if (flowing) { text = [NSString stringWithFormat:@"● Processing in %@", d]; color = UIColor.systemGreenColor; }
        else if (st.calls == 0 || reject == 0) { text = [NSString stringWithFormat:@"● Hooked in %@ · waiting for audio", d]; color = UIColor.systemYellowColor; }
        else { text = [NSString stringWithFormat:@"● %@", rejectText(reject)]; color = UIColor.systemOrangeColor; }
        break;
    }
    if (!text) { text = @"● Not loaded in mediaserverd · tap to restart audio"; color = UIColor.systemRedColor; }
    else {
        NSDictionary *f = statusFile(@"mediaserverd");
        NSString *route = [f[@"route"] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        if (route.length && ![route isEqualToString:@"unknown"]) {
            NSString *rule = f[@"rule"];
            text = [text stringByAppendingFormat:@"\n%@%@", route, [rule isEqualToString:@"off"] ? @" · off for this output" : [rule isEqualToString:@"preset"] ? @" · using its saved preset" : @""];
        }
    }
    if ([TBStore shared].lastError) { text = [TBStore shared].lastError; color = UIColor.systemRedColor; }
    [UIView performWithoutAnimation:^{
        [self->_statusPill setTitle:text forState:UIControlStateNormal];
        self->_statusPill.tintColor = color;
        [self->_statusPill layoutIfNeeded];
    }];
}
- (void)reloadAll {
    _power.on = [[self.store valueAt:@"enabled"] boolValue];
    _preamp.value = [[self.store valueAt:@"preamp"] floatValue];
    [self updatePreampLabel];
    [self rebuildStrips];
}
- (void)rebuildStrips {
    for (UIView *v in [_strips.arrangedSubviews copy]) { [_strips removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSArray *bands = self.store.bands;
    if (_selected >= (NSInteger)bands.count) _selected = (NSInteger)bands.count - 1;
    for (NSUInteger i = 0; i < bands.count; i++) {
        TBBandStrip *s = [[TBBandStrip alloc] initWithIndex:(NSInteger)i owner:self];
        s.selected = (NSInteger)i == _selected;
        [_strips addArrangedSubview:s];
    }
    if (bands.count < kMaxBands) {
        UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
        [add setImage:[UIImage systemImageNamed:@"plus.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30]] forState:UIControlStateNormal];
        [add setTitle:@"\nAdd band" forState:UIControlStateNormal];
        add.tintColor = dimColor();
        add.titleLabel.numberOfLines = 2;
        add.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [add.widthAnchor constraintEqualToConstant:90].active = YES;
        [add addTarget:self action:@selector(addBand) forControlEvents:UIControlEventTouchUpInside];
        [_strips addArrangedSubview:add];
    }
    _graph.selected = _selected;
    [_graph setNeedsDisplay];
}
- (TBBandStrip *)stripAt:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_strips.arrangedSubviews.count) return nil;
    id v = _strips.arrangedSubviews[(NSUInteger)i];
    return [v isKindOfClass:TBBandStrip.class] ? v : nil;
}
- (void)selectBand:(NSInteger)i scroll:(BOOL)scroll {
    [self stripAt:_selected].selected = NO;
    _selected = i;
    TBBandStrip *s = [self stripAt:i];
    s.selected = YES;
    _graph.selected = i;
    [_graph setNeedsDisplay];
    if (scroll && s) [_scroller scrollRectToVisible:CGRectInset([_scroller convertRect:s.bounds fromView:s], -30, 0) animated:YES];
}
- (void)stripSelected:(TBBandStrip *)strip { if (strip.index != _selected) [self selectBand:strip.index scroll:NO]; }
- (void)stripChanged:(TBBandStrip *)strip final:(BOOL)final {
    [_graph setNeedsDisplay];
    [self.store changed];
}
- (void)bandEdited:(NSInteger)i final:(BOOL)final {
    [[self stripAt:i] refresh];
    [_graph setNeedsDisplay];
    [self.store changed];
}
- (void)powerChanged { [self.store setValue:@(_power.on) at:@"enabled"]; [self.store changed]; }
- (void)updatePreampLabel {
    [UIView performWithoutAnimation:^{
        [self->_preampValue setTitle:formatValue(self->_preamp.value, TBUnitDB) forState:UIControlStateNormal];
        [self->_preampValue layoutIfNeeded];
    }];
}
- (void)preampChanged {
    const double v = round(_preamp.value * 10) / 10;
    [self.store setValue:@(v) at:@"preamp"];
    [self updatePreampLabel];
    [self.store changed];
}
- (void)autoPreamp {
    // Pull the preamp down by the highest boost in the combined curve so nothing clips.
    double peak = 0;
    for (int i = 0; i < 300; i++) {
        const double f = 20 * pow(1000, i / 299.);
        double sum = 0;
        for (NSDictionary *b in self.store.bands) {
            if (![b[@"enabled"] boolValue]) continue;
            sum += tbMagnitudeDB(tbCoeffs([b[@"type"] integerValue], [b[@"frequency"] doubleValue], [b[@"gain"] doubleValue], [b[@"q"] doubleValue], kGraphRate), f, kGraphRate);
        }
        peak = fmax(peak, sum);
    }
    const double v = clampd(-ceil(peak * 10) / 10, -24, 0);
    [self.store setValue:@(v) at:@"preamp"];
    _preamp.value = (float)v;
    [self updatePreampLabel];
    [self.store changed];
}
- (void)addBand {
    NSMutableArray *bands = self.store.bands;
    if (bands.count >= kMaxBands) return;
    [bands addObject:[TBStore band:1000 type:0 gain:0 q:1.41]];
    _selected = (NSInteger)bands.count - 1;
    [self rebuildStrips];
    [self.store changed];
    dispatch_async(dispatch_get_main_queue(), ^{ [self selectBand:self->_selected scroll:YES]; });
}
- (UIMenu *)menuForBand:(NSInteger)index {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *types = [NSMutableArray new];
    NSInteger current = [self.store.bands[(NSUInteger)index][@"type"] integerValue];
    [typeNames() enumerateObjectsUsingBlock:^(NSString *name, NSUInteger t, BOOL *stop) {
        UIAction *a = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(UIAction *x) { [weakSelf setType:(NSInteger)t forBand:index]; }];
        a.state = (NSInteger)t == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [types addObject:a];
    }];
    UIMenu *typeMenu = [UIMenu menuWithTitle:@"Filter type" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:types];
    const BOOL on = [self.store.bands[(NSUInteger)index][@"enabled"] boolValue];
    UIAction *toggle = [UIAction actionWithTitle:on ? @"Bypass band" : @"Enable band" image:[UIImage systemImageNamed:on ? @"speaker.slash" : @"speaker.wave.2"] identifier:nil handler:^(UIAction *x) { [weakSelf toggleBand:index]; }];
    UIAction *reset = [UIAction actionWithTitle:@"Reset gain" image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *x) { [weakSelf resetBand:index]; }];
    UIAction *remove = [UIAction actionWithTitle:@"Delete band" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *x) { [weakSelf removeBand:index]; }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *actions = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[toggle, reset, remove]];
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"Band %ld", (long)index + 1] children:@[typeMenu, actions]];
}
- (void)setType:(NSInteger)t forBand:(NSInteger)i {
    NSMutableDictionary *b = self.store.bands[(NSUInteger)i];
    b[@"type"] = @(t);
    if ((t == 1 || t == 2) && [b[@"q"] doubleValue] > 2) b[@"q"] = @0.71;
    if (t >= 3 && t != 5 && t != 6) b[@"q"] = @0.71;
    [self rebuildStrips];
    [self selectBand:i scroll:NO];
    [self.store changed];
}
- (void)toggleBand:(NSInteger)i {
    NSMutableDictionary *b = self.store.bands[(NSUInteger)i];
    b[@"enabled"] = @(![b[@"enabled"] boolValue]);
    [self rebuildStrips];
    [self.store changed];
}
- (void)resetBand:(NSInteger)i {
    self.store.bands[(NSUInteger)i][@"gain"] = @0;
    [self rebuildStrips];
    [self.store changed];
}
- (void)removeBand:(NSInteger)i {
    NSMutableArray *bands = self.store.bands;
    if (bands.count <= 1) return;
    [bands removeObjectAtIndex:(NSUInteger)i];
    _selected = MIN(i, (NSInteger)bands.count - 1);
    [self rebuildStrips];
    [self.store changed];
}
- (void)editValue:(UIButton *)sender {
    NSString *title; double current; TBUnit unit; double lo, hi;
    NSInteger bandIndex = -1; NSString *key = nil;
    if (sender.tag == 100) {
        title = @"Preamp"; current = [[self.store valueAt:@"preamp"] doubleValue]; unit = TBUnitDB; lo = -24; hi = 0;
    } else {
        UIView *v = sender;
        while (v && ![v isKindOfClass:TBBandStrip.class]) v = v.superview;
        if (!v) return;
        bandIndex = ((TBBandStrip *)v).index;
        NSDictionary *b = self.store.bands[(NSUInteger)bandIndex];
        if (sender.tag == 0) { key = @"gain"; title = @"Gain (dB)"; unit = TBUnitDB; lo = -24; hi = 24; }
        else if (sender.tag == 1) { key = @"frequency"; title = @"Frequency (Hz)"; unit = TBUnitHz; lo = 20; hi = 20000; }
        else { key = @"q"; title = @"Q"; unit = TBUnitQ; lo = .2; hi = 10; }
        current = [b[key] doubleValue];
        title = [NSString stringWithFormat:@"Band %ld %@", (long)bandIndex + 1, title];
        [self selectBand:bandIndex scroll:NO];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:[NSString stringWithFormat:@"%g to %g", lo, hi] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        f.text = [NSString stringWithFormat:@"%g", unit == TBUnitHz ? round(current) : round(current * 100) / 100];
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = [alert.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double v = text.doubleValue;
        if ([text.lowercaseString hasSuffix:@"k"]) v *= 1000;
        if (!isfinite(v)) return;
        v = clampd(v, lo, hi);
        TBEQController *me = weakSelf;
        if (!me) return;
        if (bandIndex < 0) {
            [me.store setValue:@(v) at:@"preamp"];
            me->_preamp.value = (float)v;
            [me updatePreampLabel];
        } else {
            me.store.bands[(NSUInteger)bandIndex][key] = @(v);
            [[me stripAt:bandIndex] refresh];
            [me->_graph setNeedsDisplay];
        }
        [me.store changed];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (UIMenu *)moreMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *flat = [UIAction actionWithTitle:@"Flatten all gains" image:[UIImage systemImageNamed:@"equal"] identifier:nil handler:^(UIAction *a) {
        for (NSMutableDictionary *b in [TBStore shared].bands) b[@"gain"] = @0;
        [weakSelf rebuildStrips]; [[TBStore shared] changed];
    }];
    UIAction *reset = [UIAction actionWithTitle:@"Reset to 10-band layout" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(UIAction *a) {
        [[TBStore shared].config setObject:deepMutable([TBStore defaultBands]) forKey:@"bands"];
        [weakSelf rebuildStrips]; [[TBStore shared] changed];
    }];
    UIAction *help = [UIAction actionWithTitle:@"Gestures" image:[UIImage systemImageNamed:@"hand.draw"] identifier:nil handler:^(UIAction *a) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gestures" message:
            @"Faders: drag up or down. Slide your finger sideways off the fader for fine control. Double-tap a fader to reset it.\n\n"
            @"Values: tap any number to type an exact value.\n\n"
            @"Graph: drag a dot to move frequency and gain, pinch to change Q of the selected band.\n\n"
            @"Band header: tap for filter type, bypass and delete." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
    UIAction *restart = [UIAction actionWithTitle:@"Restart audio daemon" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a) {
        [[TBStore shared] commit];
        NSString *msg = restartAudio();
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Audio" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
    restart.attributes = UIMenuElementAttributesDestructive;
    UIAction *outputs = [UIAction actionWithTitle:@"Output devices" image:[UIImage systemImageNamed:@"hifispeaker.2"] identifier:nil handler:^(UIAction *a) { [weakSelf showOutputs]; }];
    return [UIMenu menuWithTitle:@"" children:@[outputs, flat, reset, help, restart]];
}
@end

#pragma mark - Effect pages

@interface TBParam : NSObject
@property(nonatomic, copy) NSString *keyPath, *title;
@property(nonatomic) double lo, hi, step;
@property(nonatomic) BOOL logarithmic;
@property(nonatomic) TBUnit unit;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) UIButton *valueButton;
@end
@implementation TBParam
- (double)value { return [[[TBStore shared] valueAt:self.keyPath] doubleValue]; }
- (float)sliderFor:(double)v {
    if (self.logarithmic) return (float)(log(clampd(v, self.lo, self.hi) / self.lo) / log(self.hi / self.lo));
    return (float)((clampd(v, self.lo, self.hi) - self.lo) / (self.hi - self.lo));
}
- (double)valueFor:(float)s {
    double v = self.logarithmic ? self.lo * pow(self.hi / self.lo, s) : self.lo + s * (self.hi - self.lo);
    if (self.logarithmic) v = roundSignificant(v, 3);
    if (self.step > 0) v = round(v / self.step) * self.step;
    return clampd(v, self.lo, self.hi);
}
@end

@interface TBEffectsPage : UIViewController
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol builder:(void (^)(TBEffectsPage *page))builder;
- (UIStackView *)section:(NSString *)title toggle:(NSString *)keyPath footer:(NSString *)footer;
- (void)chips:(NSArray<NSDictionary *> *)presets in:(UIStackView *)card;
- (void)param:(NSString *)title key:(NSString *)keyPath lo:(double)lo hi:(double)hi step:(double)step log:(BOOL)lg unit:(TBUnit)unit in:(UIStackView *)card;
- (void)toggle:(NSString *)title key:(NSString *)keyPath in:(UIStackView *)card;
- (void)segment:(NSArray<NSString *> *)options key:(NSString *)keyPath in:(UIStackView *)card;
@end

@implementation TBEffectsPage {
    void (^_builder)(TBEffectsPage *);
    UIStackView *_root;
    NSMutableArray<TBParam *> *_params;
    NSMutableArray *_switches;  // [UISwitch, keyPath]
    NSMutableArray *_segments;  // [UISegmentedControl, keyPath]
    NSMutableArray *_sections;  // [card, keyPath]
}
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol builder:(void (^)(TBEffectsPage *))builder {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = title;
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:[UIImage systemImageNamed:symbol] tag:0];
        _builder = [builder copy];
        _params = [NSMutableArray new]; _switches = [NSMutableArray new]; _sections = [NSMutableArray new]; _segments = [NSMutableArray new];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    _root = [UIStackView new];
    _root.axis = UILayoutConstraintAxisVertical;
    _root.spacing = 14;
    _root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:_root];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [_root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [_root.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:14],
        [_root.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-14],
    ]];
    UILabel *title = [UILabel new];
    title.text = self.title;
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
    title.textColor = UIColor.whiteColor;
    [_root addArrangedSubview:title];
    _builder(self);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:kChanged object:nil];
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text; l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = color; l.numberOfLines = 0;
    return l;
}
- (UIStackView *)section:(NSString *)title toggle:(NSString *)keyPath footer:(NSString *)footer {
    UIStackView *card = [UIStackView new];
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 12;
    card.layoutMargins = UIEdgeInsetsMake(14, 16, 16, 16);
    card.layoutMarginsRelativeArrangement = YES;
    UIView *bg = [UIView new];
    bg.backgroundColor = cardColor();
    bg.layer.cornerRadius = 14;
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    [card insertSubview:bg atIndex:0];
    [NSLayoutConstraint activateConstraints:@[[bg.topAnchor constraintEqualToAnchor:card.topAnchor], [bg.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
                                              [bg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor], [bg.trailingAnchor constraintEqualToAnchor:card.trailingAnchor]]];
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:title size:17 weight:UIFontWeightBold color:UIColor.whiteColor], [UIView new]]];
    head.alignment = UIStackViewAlignmentCenter;
    if (keyPath) {
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = accentColor();
        [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
        [head addArrangedSubview:sw];
        [_switches addObject:@[sw, keyPath]];
    }
    [card addArrangedSubview:head];
    if (footer) [card addArrangedSubview:[self label:footer size:12 weight:UIFontWeightRegular color:dimColor()]];
    [_root addArrangedSubview:card];
    if (keyPath) [_sections addObject:@[card, keyPath]];
    return card;
}
- (void)chips:(NSArray<NSDictionary *> *)presets in:(UIStackView *)card {
    UIScrollView *scroll = [UIScrollView new];
    scroll.showsHorizontalScrollIndicator = NO;
    UIStackView *row = [UIStackView new];
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor], [scroll.heightAnchor constraintEqualToConstant:34],
    ]];
    for (NSDictionary *p in presets) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
        cfg.title = p[@"name"];
        cfg.baseBackgroundColor = [UIColor colorWithWhite:.18 alpha:1];
        cfg.baseForegroundColor = UIColor.whiteColor;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
        b.configuration = cfg;
        NSDictionary *values = p[@"values"];
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
            for (NSString *k in values) [[TBStore shared] setValue:values[k] at:k];
            [[TBStore shared] changed];
            [[NSNotificationCenter defaultCenter] postNotificationName:kChanged object:nil];
        }] forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:b];
    }
    [card addArrangedSubview:scroll];
}
- (void)param:(NSString *)title key:(NSString *)keyPath lo:(double)lo hi:(double)hi step:(double)step log:(BOOL)lg unit:(TBUnit)unit in:(UIStackView *)card {
    TBParam *p = [TBParam new];
    p.title = title; p.keyPath = keyPath; p.lo = lo; p.hi = hi; p.step = step; p.logarithmic = lg; p.unit = unit;
    p.slider = [UISlider new];
    p.slider.minimumTrackTintColor = accentColor();
    p.slider.tag = (NSInteger)_params.count;
    [p.slider addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    p.valueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    p.valueButton.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    p.valueButton.tintColor = accentColor();
    p.valueButton.tag = (NSInteger)_params.count;
    [p.valueButton addTarget:self action:@selector(typeValue:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:title size:14 weight:UIFontWeightMedium color:[UIColor colorWithWhite:.85 alpha:1]], [UIView new], p.valueButton]];
    top.alignment = UIStackViewAlignmentCenter;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[top, p.slider]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 2;
    [card addArrangedSubview:row];
    [_params addObject:p];
}
- (void)segment:(NSArray<NSString *> *)options key:(NSString *)keyPath in:(UIStackView *)card {
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:options];
    seg.selectedSegmentTintColor = accentColor();
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.blackColor} forState:UIControlStateSelected];
    [seg addTarget:self action:@selector(segmented:) forControlEvents:UIControlEventValueChanged];
    [card addArrangedSubview:seg];
    [_segments addObject:@[seg, keyPath]];
}
- (void)segmented:(UISegmentedControl *)seg {
    for (NSArray *pair in _segments) if (pair[0] == seg) [[TBStore shared] setValue:@(seg.selectedSegmentIndex) at:pair[1]];
    [[TBStore shared] changed];
}
- (void)toggle:(NSString *)title key:(NSString *)keyPath in:(UIStackView *)card {
    UISwitch *sw = [UISwitch new];
    sw.onTintColor = accentColor();
    [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:title size:14 weight:UIFontWeightMedium color:[UIColor colorWithWhite:.85 alpha:1]], [UIView new], sw]];
    row.alignment = UIStackViewAlignmentCenter;
    [card addArrangedSubview:row];
    [_switches addObject:@[sw, keyPath]];
}
- (NSString *)textFor:(TBParam *)p value:(double)v {
    if ([p.keyPath isEqualToString:@"width.balance"]) {
        if (fabs(v) < .005) return @"Center";
        return [NSString stringWithFormat:@"%@ %.0f%%", v < 0 ? @"L" : @"R", fabs(v) * 100];
    }
    return formatValue(v, p.unit);
}
- (void)refresh {
    TBStore *store = [TBStore shared];
    for (TBParam *p in _params) {
        const double v = p.value;
        p.slider.value = [p sliderFor:v];
        [UIView performWithoutAnimation:^{ [p.valueButton setTitle:[self textFor:p value:v] forState:UIControlStateNormal]; [p.valueButton layoutIfNeeded]; }];
    }
    for (NSArray *pair in _switches) ((UISwitch *)pair[0]).on = [[store valueAt:pair[1]] boolValue];
    for (NSArray *pair in _segments) ((UISegmentedControl *)pair[0]).selectedSegmentIndex = [[store valueAt:pair[1]] integerValue];
    for (NSArray *pair in _sections) {
        UIStackView *card = pair[0];
        const BOOL on = [[store valueAt:pair[1]] boolValue];
        for (NSUInteger i = 1; i < card.arrangedSubviews.count; i++) card.arrangedSubviews[i].alpha = on ? 1 : .45;
    }
}
- (void)slid:(UISlider *)s {
    TBParam *p = _params[(NSUInteger)s.tag];
    const double v = [p valueFor:s.value];
    [[TBStore shared] setValue:@(v) at:p.keyPath];
    [UIView performWithoutAnimation:^{ [p.valueButton setTitle:[self textFor:p value:v] forState:UIControlStateNormal]; [p.valueButton layoutIfNeeded]; }];
    [[TBStore shared] changed];
}
- (void)switched:(UISwitch *)sw {
    for (NSArray *pair in _switches) if (pair[0] == sw) [[TBStore shared] setValue:@(sw.on) at:pair[1]];
    [[TBStore shared] changed];
    [self refresh];
}
- (void)typeValue:(UIButton *)b {
    TBParam *p = _params[(NSUInteger)b.tag];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:p.title message:[NSString stringWithFormat:@"%g to %g%@", p.unit == TBUnitPct ? p.lo * 100 : p.lo, p.unit == TBUnitPct ? p.hi * 100 : p.hi, p.unit == TBUnitPct ? @" %" : @""] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        f.text = formatNumber(p.value, p.unit);
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = [alert.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double v = text.doubleValue;
        if ([text.lowercaseString hasSuffix:@"k"]) v *= 1000;
        if (p.unit == TBUnitPct) v /= 100;
        if (!isfinite(v)) return;
        [[TBStore shared] setValue:@(clampd(v, p.lo, p.hi)) at:p.keyPath];
        [[TBStore shared] changed];
        [weakSelf refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

#pragma mark - Presets

static NSArray<NSDictionary *> *builtInPresets(void) {
    NSDictionary *(^b)(NSInteger, double, double, double) = ^(NSInteger t, double f, double g, double q) {
        return @{@"enabled": @YES, @"type": @(t), @"frequency": @(f), @"gain": @(g), @"q": @(q)};
    };
    NSMutableArray *flat = [NSMutableArray new];
    for (NSNumber *f in @[@31, @62, @125, @250, @500, @1000, @2000, @4000, @8000, @16000]) [flat addObject:b(0, f.doubleValue, 0, 1.41)];
    return @[
        @{@"name": @"Flat", @"preamp": @0, @"bands": flat},
        @{@"name": @"Bass Boost", @"preamp": @(-6), @"bands": @[b(1, 105, 6, .7), b(0, 40, 1.5, 1)]},
        @{@"name": @"V-Shape", @"preamp": @(-5), @"bands": @[b(1, 120, 5, .7), b(0, 1500, -2.5, .8), b(2, 8000, 4, .7)]},
        @{@"name": @"Vocal Presence", @"preamp": @(-3), @"bands": @[b(4, 60, 0, .71), b(0, 250, -2, 1), b(0, 2500, 3, 1.2), b(0, 5000, 1.5, 2)]},
        @{@"name": @"Treble Boost", @"preamp": @(-4), @"bands": @[b(2, 6000, 4, .7)]},
        @{@"name": @"Late Night Loudness", @"preamp": @(-6), @"bands": @[b(1, 90, 6, .6), b(2, 10000, 4, .7)],
          @"effects": @{@"comp": @{@"on": @YES, @"threshold": @(-30), @"knee": @10, @"ratio": @4, @"attack": @5, @"release": @200, @"makeup": @0}}},
    ];
}
static NSArray<NSString *> *effectKeys(void) { return @[@"output", @"comp", @"crossfeed", @"width", @"spatial", @"reverb", @"limiter"]; }

@interface TBPresetsController : UITableViewController
@end
@implementation TBPresetsController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Presets";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Presets" image:[UIImage systemImageNamed:@"square.stack.3d.up"] tag:0];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"c"];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSMutableArray *)saved {
    NSMutableArray *a = [[TBStore shared] valueAt:@"presets"];
    if (![a isKindOfClass:NSMutableArray.class]) { a = [NSMutableArray new]; [[TBStore shared] setValue:a at:@"presets"]; }
    return a;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"", @"Built-in", @"Saved"][(NSUInteger)s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"Import reads Equalizer APO / AutoEq ParametricEQ.txt text from the clipboard.";
    if (s == 2 && self.saved.count == 0) return @"Saved presets store the EQ plus all effect settings.";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 4 : s == 1 ? (NSInteger)builtInPresets().count : (NSInteger)self.saved.count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    UIListContentConfiguration *cfg = [UIListContentConfiguration valueCellConfiguration];
    if (ip.section == 0) {
        cfg.text = @[@"Save current as preset…", @"Import from clipboard", @"Copy EQ as text", @"Output devices & auto switching"][(NSUInteger)ip.row];
        cfg.image = [UIImage systemImageNamed:@[@"plus.circle", @"doc.on.clipboard", @"square.and.arrow.up", @"hifispeaker.2"][(NSUInteger)ip.row]];
        cfg.textProperties.color = accentColor();
        cfg.imageProperties.tintColor = accentColor();
    } else {
        NSDictionary *p = ip.section == 1 ? builtInPresets()[(NSUInteger)ip.row] : self.saved[(NSUInteger)ip.row];
        cfg.text = p[@"name"];
        cfg.secondaryText = [NSString stringWithFormat:@"%lu bands%@", (unsigned long)[p[@"bands"] count], p[@"effects"] ? @" + fx" : @""];
    }
    c.contentConfiguration = cfg;
    return c;
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 2; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    [self.saved removeObjectAtIndex:(NSUInteger)ip.row];
    [[TBStore shared] changed];
    [t reloadData];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (ip.row == 3) {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NSClassFromString(@"TBRoutesController") new]];
            [self presentViewController:nav animated:YES completion:nil];
            return;
        }
        if (ip.row == 0) [self saveCurrent];
        else if (ip.row == 1) [self importClipboard];
        else [self exportClipboard];
        return;
    }
    [self apply:ip.section == 1 ? builtInPresets()[(NSUInteger)ip.row] : self.saved[(NSUInteger)ip.row]];
}
- (void)apply:(NSDictionary *)p {
    TBStore *store = [TBStore shared];
    NSMutableArray *bands = deepMutable(p[@"bands"]) ?: [NSMutableArray new];
    if (bands.count == 0) [bands addObject:[TBStore band:1000 type:0 gain:0 q:1.41]];
    store.config[@"bands"] = bands;
    store.config[@"preamp"] = p[@"preamp"] ?: @0;
    NSDictionary *fx = p[@"effects"];
    if ([fx isKindOfClass:NSDictionary.class]) for (NSString *k in fx) {
        id v = deepMutable(@{@"v": fx[k]})[@"v"];
        if ([v isKindOfClass:NSMutableDictionary.class] && [store.config[k] isKindOfClass:NSMutableDictionary.class]) [store.config[k] addEntriesFromDictionary:v];
        else if (v) store.config[k] = v;
    }
    [store changed];
    [[NSNotificationCenter defaultCenter] postNotificationName:kChanged object:nil];
    [self toast:[NSString stringWithFormat:@"Applied %@", p[@"name"]]];
}
- (void)toast:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
    }];
}
- (void)saveCurrent {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save preset" message:@"Saves the EQ and every effect setting." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Name"; f.autocapitalizationType = UITextAutocapitalizationTypeWords; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length) name = [NSString stringWithFormat:@"Preset %lu", (unsigned long)weakSelf.saved.count + 1];
        TBStore *store = [TBStore shared];
        NSMutableDictionary *fx = [NSMutableDictionary new];
        for (NSString *k in effectKeys()) if (store.config[k]) fx[k] = store.config[k];
        NSDictionary *preset = deepMutable(@{@"name": name, @"preamp": store.config[@"preamp"] ?: @0, @"bands": store.bands, @"effects": fx});
        [weakSelf.saved addObject:preset];
        [store changed];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importClipboard {
    NSString *text = UIPasteboard.generalPasteboard.string ?: @"";
    NSDictionary *codes = @{@"PK": @0, @"PEQ": @0, @"LS": @1, @"LSC": @1, @"LSQ": @1, @"HS": @2, @"HSC": @2, @"HSQ": @2,
                            @"LP": @3, @"LPQ": @3, @"HP": @4, @"HPQ": @4, @"BP": @5, @"NO": @6, @"AP": @7};
    NSRegularExpression *filter = [NSRegularExpression regularExpressionWithPattern:
        @"Filter\\s*\\d*\\s*:\\s*ON\\s+([A-Z]+)\\s+Fc\\s+([\\d.]+)\\s*Hz(?:\\s+Gain\\s+([-+\\d.]+)\\s*dB)?(?:\\s+Q\\s+([\\d.]+))?"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *preamp = [NSRegularExpression regularExpressionWithPattern:@"Preamp\\s*:\\s*([-+\\d.]+)\\s*dB" options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray *bands = [NSMutableArray new];
    for (NSTextCheckingResult *m in [filter matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        if (bands.count >= kMaxBands) break;
        NSNumber *type = codes[[text substringWithRange:[m rangeAtIndex:1]].uppercaseString];
        if (!type) continue;
        const double f = [text substringWithRange:[m rangeAtIndex:2]].doubleValue;
        const double g = [m rangeAtIndex:3].location != NSNotFound ? [text substringWithRange:[m rangeAtIndex:3]].doubleValue : 0;
        const double q = [m rangeAtIndex:4].location != NSNotFound ? [text substringWithRange:[m rangeAtIndex:4]].doubleValue : .71;
        [bands addObject:@{@"enabled": @YES, @"type": type, @"frequency": @(clampd(f, 20, 20000)), @"gain": @(clampd(g, -24, 24)), @"q": @(clampd(q, .2, 10))}];
    }
    if (bands.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nothing to import" message:@"Copy Equalizer APO / AutoEq text such as\n\nPreamp: -6.2 dB\nFilter 1: ON PK Fc 105 Hz Gain 6.0 dB Q 0.70" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSTextCheckingResult *pm = [preamp firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    const double pre = pm ? clampd([text substringWithRange:[pm rangeAtIndex:1]].doubleValue, -24, 0) : 0;
    [self apply:@{@"name": [NSString stringWithFormat:@"%lu imported bands", (unsigned long)bands.count], @"preamp": @(pre), @"bands": bands}];
}
- (void)exportClipboard {
    TBStore *store = [TBStore shared];
    NSMutableString *s = [NSMutableString stringWithFormat:@"Preamp: %.1f dB\n", [[store valueAt:@"preamp"] doubleValue]];
    NSArray *apo = @[@"PK", @"LSC", @"HSC", @"LPQ", @"HPQ", @"BP", @"NO", @"AP"];
    NSInteger i = 1;
    for (NSDictionary *b in store.bands) {
        const NSInteger t = (NSInteger)clampd([b[@"type"] integerValue], 0, 7);
        [s appendFormat:@"Filter %ld: %@ %@ Fc %.0f Hz", (long)i++, [b[@"enabled"] boolValue] ? @"ON" : @"OFF", apo[(NSUInteger)t], [b[@"frequency"] doubleValue]];
        if (typeUsesGain(t)) [s appendFormat:@" Gain %.1f dB", [b[@"gain"] doubleValue]];
        [s appendFormat:@" Q %.2f\n", [b[@"q"] doubleValue]];
    }
    UIPasteboard.generalPasteboard.string = s;
    [self toast:@"Copied"];
}
@end

#pragma mark - Output devices

static NSString *const kRoutePath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.route.plist";
static NSString *const kKnownRoutesPath = @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.routes.plist";

static NSString *routeGroupFor(NSString *type) {
    if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [type isEqualToString:AVAudioSessionPortBuiltInReceiver]) return @"speaker";
    if ([type isEqualToString:AVAudioSessionPortHeadphones] || [type isEqualToString:AVAudioSessionPortLineOut]) return @"wired";
    if ([type hasPrefix:@"Bluetooth"]) return @"bluetooth";
    if ([type isEqualToString:AVAudioSessionPortAirPlay]) return @"airplay";
    if ([type isEqualToString:AVAudioSessionPortCarAudio]) return @"carplay";
    if ([type isEqualToString:AVAudioSessionPortUSBAudio] || [type isEqualToString:AVAudioSessionPortHDMI]) return @"usb";
    return @"other";
}
static NSArray<NSArray<NSString *> *> *routeGroups(void) {
    return @[@[@"speaker", @"iPhone speaker", @"iphone"], @[@"wired", @"Wired headphones", @"headphones"],
             @[@"bluetooth", @"Any Bluetooth device", @"airpods.gen3"], @[@"airplay", @"AirPlay", @"airplayaudio"],
             @[@"carplay", @"CarPlay", @"car"], @[@"usb", @"USB / HDMI", @"cable.connector"]];
}
// The app also records the route while it is open, so the device list fills in even before SpringBoard sees it.
static void recordCurrentRoute(void) {
    AVAudioSessionPortDescription *port = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject;
    if (!port) return;
    NSDictionary *info = @{@"type": port.portType ?: @"", @"name": port.portName ?: @"", @"uid": port.UID ?: @"", @"group": routeGroupFor(port.portType), @"time": @(time(NULL))};
    [[NSFileManager defaultManager] createDirectoryAtPath:kRoutePath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:kRoutePath];
    if (![existing[@"uid"] isEqual:info[@"uid"]] || ![existing[@"type"] isEqual:info[@"type"]]) [info writeToFile:kRoutePath atomically:YES];
    NSMutableDictionary *known = [[NSDictionary dictionaryWithContentsOfFile:kKnownRoutesPath] mutableCopy] ?: [NSMutableDictionary new];
    if (port.UID.length) { known[port.UID] = info; [known writeToFile:kKnownRoutesPath atomically:YES]; }
}

@interface TBRoutesController : UITableViewController
@end
@implementation TBRoutesController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Output devices";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeChanged) name:AVAudioSessionRouteChangeNotification object:nil];
    recordCurrentRoute();
}
- (void)routeChanged { dispatch_async(dispatch_get_main_queue(), ^{ recordCurrentRoute(); [self.tableView reloadData]; }); }
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSMutableDictionary *)routing {
    NSMutableDictionary *r = [[TBStore shared] valueAt:@"routing"];
    if (![r isKindOfClass:NSMutableDictionary.class]) { r = [@{@"enabled": @NO, @"devices": [NSMutableDictionary new], @"types": [NSMutableDictionary new]} mutableCopy]; [TBStore shared].config[@"routing"] = r; }
    for (NSString *k in @[@"devices", @"types"]) if (![r[k] isKindOfClass:NSMutableDictionary.class]) r[k] = [r[k] isKindOfClass:NSDictionary.class] ? [r[k] mutableCopy] : [NSMutableDictionary new];
    return r;
}
- (NSArray<NSDictionary *> *)knownDevices {
    NSDictionary *known = [NSDictionary dictionaryWithContentsOfFile:kKnownRoutesPath];
    NSMutableArray *list = [NSMutableArray new];
    for (NSString *uid in known) {
        NSDictionary *d = known[uid];
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSString *g = d[@"group"];
        if ([g isEqualToString:@"speaker"]) continue;  // the built-in speaker is covered by its type row
        [list addObject:d];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"time"] compare:a[@"time"]]; }];
    return list;
}
- (NSString *)describe:(NSDictionary *)rule fallback:(NSString *)fallback {
    if (![rule isKindOfClass:NSDictionary.class]) return fallback;
    NSString *mode = rule[@"mode"];
    if ([mode isEqualToString:@"off"]) return @"Timbre off";
    if ([mode isEqualToString:@"preset"]) return [NSString stringWithFormat:@"Preset: %@", rule[@"preset"][@"name"] ?: @"?"];
    return @"Current EQ";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"", @"Output types", @"Devices"][(NSUInteger)s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"When on, Timbre switches by output: a device rule wins over its type rule, and anything without a rule uses your current EQ. Changes apply within a second of switching outputs.";
    if (s == 2) return [self knownDevices].count ? @"Devices appear here once they have been used as the output." : @"Connect a Bluetooth, AirPlay, CarPlay or USB device and it will show up here.";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 2 : s == 1 ? (NSInteger)routeGroups().count : (NSInteger)[self knownDevices].count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"r"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"r"];
    c.accessoryView = nil; c.accessoryType = UITableViewCellAccessoryNone; c.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *cfg = [UIListContentConfiguration valueCellConfiguration];
    NSMutableDictionary *routing = self.routing;
    if (ip.section == 0 && ip.row == 0) {
        cfg.text = @"Switch automatically by output";
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = accentColor();
        sw.on = [routing[@"enabled"] boolValue];
        [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 0) {
        AVAudioSessionPortDescription *port = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject;
        cfg.text = [NSString stringWithFormat:@"Now: %@", port.portName ?: @"unknown"];
        NSDictionary *rule = port.UID ? routing[@"devices"][port.UID] : nil;
        cfg.secondaryText = [self describe:rule ?: routing[@"types"][routeGroupFor(port.portType)] fallback:@"Current EQ"];
        cfg.image = [UIImage systemImageNamed:@"speaker.wave.2.fill"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        NSArray *g = routeGroups()[(NSUInteger)ip.row];
        cfg.text = g[1];
        cfg.image = [UIImage systemImageNamed:g[2]];
        cfg.secondaryText = [self describe:routing[@"types"][g[0]] fallback:@"Current EQ"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSDictionary *d = [self knownDevices][(NSUInteger)ip.row];
        cfg.text = [d[@"name"] length] ? d[@"name"] : d[@"type"];
        NSString *group = d[@"group"];
        for (NSArray *g in routeGroups()) if ([g[0] isEqualToString:group]) cfg.image = [UIImage systemImageNamed:g[2]];
        cfg.secondaryText = [self describe:routing[@"devices"][d[@"uid"]] fallback:@"Follows type"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cfg.imageProperties.tintColor = accentColor();
    c.contentConfiguration = cfg;
    return c;
}
- (void)toggled:(UISwitch *)sw {
    self.routing[@"enabled"] = @(sw.on);
    [[TBStore shared] changed];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) return;
    NSString *bucket, *key, *title;
    if (ip.section == 0) {
        AVAudioSessionPortDescription *port = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject;
        if (!port) return;
        if ([routeGroupFor(port.portType) isEqualToString:@"speaker"] || !port.UID.length) { bucket = @"types"; key = routeGroupFor(port.portType); }
        else { bucket = @"devices"; key = port.UID; }
        title = port.portName;
    } else if (ip.section == 1) {
        bucket = @"types"; key = routeGroups()[(NSUInteger)ip.row][0]; title = routeGroups()[(NSUInteger)ip.row][1];
    } else {
        NSDictionary *d = [self knownDevices][(NSUInteger)ip.row];
        bucket = @"devices"; key = d[@"uid"]; title = d[@"name"];
    }
    [self chooseRuleFor:bucket key:key title:title source:[t cellForRowAtIndexPath:ip]];
}
- (void)chooseRuleFor:(NSString *)bucket key:(NSString *)key title:(NSString *)title source:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:@"What should Timbre do on this output?" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^set)(id) = ^(id rule) {
        TBRoutesController *me = weakSelf;
        if (!me) return;
        NSMutableDictionary *routing = me.routing;
        if (rule) routing[bucket][key] = rule; else [routing[bucket] removeObjectForKey:key];
        if (rule && ![routing[@"enabled"] boolValue]) routing[@"enabled"] = @YES;  // setting a rule implies wanting it applied
        [[TBStore shared] changed];
        [me.tableView reloadData];
    };
    [sheet addAction:[UIAlertAction actionWithTitle:@"Use current EQ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { set(@{@"mode": @"current"}); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Turn Timbre off" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { set(@{@"mode": @"off"}); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save current EQ + effects for this output" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        TBStore *store = [TBStore shared];
        NSMutableDictionary *fx = [NSMutableDictionary new];
        for (NSString *k in effectKeys()) if (store.config[k]) fx[k] = store.config[k];
        set(@{@"mode": @"preset", @"preset": deepMutable(@{@"name": [NSString stringWithFormat:@"%@ snapshot", title ?: @"Output"], @"preamp": store.config[@"preamp"] ?: @0, @"bands": store.bands, @"effects": fx})});
    }]];
    NSMutableArray *presets = [builtInPresets() mutableCopy];
    NSArray *saved = [[TBStore shared] valueAt:@"presets"];
    if ([saved isKindOfClass:NSArray.class]) [presets addObjectsFromArray:saved];
    for (NSDictionary *p in presets)
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Preset: %@", p[@"name"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            set(@{@"mode": @"preset", @"preset": deepMutable(p)});
        }]];
    if ([bucket isEqualToString:@"devices"])
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear (follow type rule)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { set(nil); }]];
    else
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear rule" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { set(nil); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

#pragma mark - App

static UIViewController *spatialPage(void) {
    return [[TBEffectsPage alloc] initWithTitle:@"Spatial" symbol:@"headphones" builder:^(TBEffectsPage *p) {
        UIStackView *s = [p section:@"Spatial" toggle:@"spatial.on" footer:@"Immersive upmixes stereo to nine virtual speakers (centre, front, sides, rears and two heights) and renders them through measured MIT KEMAR head responses. Classic is the lighter interaural delay and head-shadow model. Headphones only. This is not Dolby Atmos decoding; Atmos content arrives already rendered to stereo."];
        [p segment:@[@"Classic", @"Immersive"] key:@"spatial.mode" in:s];
        [p chips:@[@{@"name": @"Front stage", @"values": @{@"spatial.angle": @20, @"spatial.amount": @0.7, @"spatial.surround": @0.2, @"spatial.height": @0.1}},
                   @{@"name": @"Studio", @"values": @{@"spatial.angle": @30, @"spatial.amount": @0.85, @"spatial.surround": @0.4, @"spatial.height": @0.25}},
                   @{@"name": @"Theatre", @"values": @{@"spatial.angle": @40, @"spatial.amount": @1.0, @"spatial.surround": @0.75, @"spatial.height": @0.5}},
                   @{@"name": @"Wide room", @"values": @{@"spatial.angle": @55, @"spatial.amount": @0.9, @"spatial.surround": @0.6, @"spatial.height": @0.35}}] in:s];
        [p param:@"Front speaker angle" key:@"spatial.angle" lo:10 hi:60 step:1 log:NO unit:TBUnitDeg in:s];
        [p param:@"Amount" key:@"spatial.amount" lo:0 hi:1 step:.01 log:NO unit:TBUnitPct in:s];
        [p param:@"Surround (Immersive)" key:@"spatial.surround" lo:0 hi:1 step:.01 log:NO unit:TBUnitPct in:s];
        [p param:@"Height (Immersive)" key:@"spatial.height" lo:0 hi:1 step:.01 log:NO unit:TBUnitPct in:s];
        [p param:@"Distance (Classic)" key:@"spatial.distance" lo:.3 hi:5 step:.1 log:NO unit:TBUnitMeters in:s];
        UIStackView *x = [p section:@"Crossfeed" toggle:@"crossfeed.on" footer:@"Bleeds a little of each channel into the other like speakers do, so hard-panned mixes stop feeling inside your skull."];
        [p chips:@[@{@"name": @"Subtle", @"values": @{@"crossfeed.level": @(-9.5), @"crossfeed.cutoff": @650}},
                   @{@"name": @"Natural", @"values": @{@"crossfeed.level": @(-6), @"crossfeed.cutoff": @700}},
                   @{@"name": @"Speakers", @"values": @{@"crossfeed.level": @(-4.5), @"crossfeed.cutoff": @750}},
                   @{@"name": @"Strong", @"values": @{@"crossfeed.level": @(-3), @"crossfeed.cutoff": @850}}] in:x];
        [p param:@"Level" key:@"crossfeed.level" lo:-20 hi:-1 step:.5 log:NO unit:TBUnitDB in:x];
        [p param:@"Cutoff" key:@"crossfeed.cutoff" lo:300 hi:1500 step:10 log:NO unit:TBUnitHz in:x];
        [p param:@"Delay" key:@"crossfeed.delay" lo:0 hi:.8 step:.01 log:NO unit:TBUnitMs in:x];
        UIStackView *w = [p section:@"Stereo" toggle:@"width.on" footer:nil];
        [p param:@"Width" key:@"width.width" lo:0 hi:2.5 step:.01 log:NO unit:TBUnitPct in:w];
        [p param:@"Balance" key:@"width.balance" lo:-1 hi:1 step:.01 log:NO unit:TBUnitPct in:w];
        [p toggle:@"Mono" key:@"width.mono" in:w];
        [p toggle:@"Swap left / right" key:@"width.swap" in:w];
    }];
}
static UIViewController *reverbPage(void) {
    return [[TBEffectsPage alloc] initWithTitle:@"Reverb" symbol:@"water.waves" builder:^(TBEffectsPage *p) {
        UIStackView *r = [p section:@"Reverb" toggle:@"reverb.on" footer:@"Algorithmic room reverb. Decay is the RT60 time; damping darkens the tail."];
        NSDictionary *(^preset)(NSString *, double, double, double, double) = ^(NSString *n, double decay, double pre, double damp, double mix) {
            return @{@"name": n, @"values": @{@"reverb.decay": @(decay), @"reverb.predelay": @(pre), @"reverb.damping": @(damp), @"reverb.mix": @(mix)}};
        };
        [p chips:@[preset(@"Room", .6, 6, 7000, .2), preset(@"Studio", 1.0, 12, 6000, .2), preset(@"Plate", 1.6, 4, 10000, .25),
                   preset(@"Hall", 2.6, 28, 4500, .25), preset(@"Cathedral", 5.5, 60, 3000, .3)] in:r];
        [p param:@"Mix" key:@"reverb.mix" lo:0 hi:1 step:.01 log:NO unit:TBUnitPct in:r];
        [p param:@"Decay" key:@"reverb.decay" lo:.2 hi:8 step:0 log:YES unit:TBUnitSec in:r];
        [p param:@"Pre-delay" key:@"reverb.predelay" lo:0 hi:200 step:1 log:NO unit:TBUnitMs in:r];
        [p param:@"Damping" key:@"reverb.damping" lo:1000 hi:16000 step:0 log:YES unit:TBUnitHz in:r];
        [p param:@"Stereo width" key:@"reverb.width" lo:0 hi:1 step:.01 log:NO unit:TBUnitPct in:r];
    }];
}
static UIViewController *dynamicsPage(void) {
    return [[TBEffectsPage alloc] initWithTitle:@"Dynamics" symbol:@"speedometer" builder:^(TBEffectsPage *p) {
        UIStackView *c = [p section:@"Compressor" toggle:@"comp.on" footer:@"Evens out loud and quiet parts. Night mode keeps dialogue audible at low volume."];
        [p chips:@[@{@"name": @"Gentle", @"values": @{@"comp.threshold": @(-20), @"comp.ratio": @2, @"comp.knee": @8, @"comp.attack": @20, @"comp.release": @200, @"comp.makeup": @2}},
                   @{@"name": @"Night mode", @"values": @{@"comp.threshold": @(-30), @"comp.ratio": @4, @"comp.knee": @10, @"comp.attack": @5, @"comp.release": @200, @"comp.makeup": @6}},
                   @{@"name": @"Punch", @"values": @{@"comp.threshold": @(-18), @"comp.ratio": @3, @"comp.knee": @4, @"comp.attack": @30, @"comp.release": @120, @"comp.makeup": @3}}] in:c];
        [p param:@"Threshold" key:@"comp.threshold" lo:-60 hi:0 step:.5 log:NO unit:TBUnitDB in:c];
        [p param:@"Ratio" key:@"comp.ratio" lo:1 hi:20 step:0 log:YES unit:TBUnitRatio in:c];
        [p param:@"Knee" key:@"comp.knee" lo:0 hi:40 step:.5 log:NO unit:TBUnitDB in:c];
        [p param:@"Attack" key:@"comp.attack" lo:.1 hi:200 step:0 log:YES unit:TBUnitMs in:c];
        [p param:@"Release" key:@"comp.release" lo:10 hi:1000 step:0 log:YES unit:TBUnitMs in:c];
        [p param:@"Makeup" key:@"comp.makeup" lo:-12 hi:24 step:.1 log:NO unit:TBUnitDB in:c];
        UIStackView *o = [p section:@"Output" toggle:nil footer:@"The limiter catches peaks after every effect so boosts never clip."];
        [p param:@"Output gain" key:@"output" lo:-24 hi:12 step:.1 log:NO unit:TBUnitDB in:o];
        [p toggle:@"Limiter" key:@"limiter.on" in:o];
        [p param:@"Ceiling" key:@"limiter.ceiling" lo:-12 hi:0 step:.1 log:NO unit:TBUnitDB in:o];
    }];
}

@interface TimbreAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation TimbreAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.window.tintColor = accentColor();
    TBEQController *eq = [TBEQController new];
    eq.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"EQ" image:[UIImage systemImageNamed:@"slider.vertical.3"] tag:0];
    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = @[eq, spatialPage(), reverbPage(), dynamicsPage(), [[UINavigationController alloc] initWithRootViewController:[TBPresetsController new]]];
    UITabBarAppearance *appearance = [UITabBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = UIColor.blackColor;
    tabs.tabBar.standardAppearance = appearance;
    tabs.tabBar.scrollEdgeAppearance = appearance;
    tabs.tabBar.tintColor = accentColor();
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    recordCurrentRoute();
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { recordCurrentRoute(); }];
    return YES;
}
- (void)applicationWillResignActive:(UIApplication *)application { [[TBStore shared] commit]; }
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TimbreAppDelegate.class)); }
}
