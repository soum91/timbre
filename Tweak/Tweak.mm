// Timbre experimental system-audio EQ + effects for Dopamine rootless.
// AudioUnitRender interception is not guaranteed to catch every iOS playback route.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <os/log.h>
#include <dlfcn.h>
#include <notify.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include "../NativeDSP/TimbreDSP.hpp"

namespace {
constexpr size_t kMaxBands = 16;
constexpr size_t kEffectSlots = 4;
// The jailbreak-root copy is readable from sandboxed daemons; the legacy path is a fallback.
static NSString *const kPrefsPaths[] = {
    @"/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist",
    @"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist",
};
constexpr UInt32 kChunk = 512;
static const char *const kReloadNotification = "com.soum91.timbreaudio.reload";
using RenderFn = OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
using UninitFn = OSStatus (*)(AudioUnit);
RenderFn originalRender = nullptr;
UninitFn originalUninit = nullptr;

struct Config {
    uint64_t generation = 0;
    bool enabled = false;
    double preamp = 1;
    size_t count = 0;
    timbre::Band bands[kMaxBands]{};
    timbre::EffectsParams fx{};
    bool fxActive = false;
};
// Replaced snapshots are freed after a grace period; a render callback only holds one for its own duration.
std::atomic<const Config *> active{nullptr};
std::atomic<uint64_t> sequence{1};
dispatch_queue_t reloadQueue;

struct FilterState { double z1[2]{}, z2[2]{}; };
struct ThreadState {
    bool inHook = false;
    AudioUnit unit = nullptr;
    uint64_t generation = 0;
    double rate = 0;
    size_t count = 0;
    timbre::Coeffs coefficients[kMaxBands]{};
    FilterState filters[kMaxBands]{};
};
thread_local ThreadState state;

// Effects carry large delay lines, so they live in a small pool allocated off the audio thread
// and are owned per AudioUnit. A slot idle for more than two seconds can be reclaimed.
struct Slot {
    std::atomic<void *> owner{nullptr};
    std::atomic<uint64_t> lastUsed{0};
    std::atomic<timbre::Effects *> fx{nullptr};
    double rate = 0;
    bool ready = false;
    uint64_t generation = 0;
};
Slot slots[kEffectSlots];
uint64_t staleTicks = 0;

// Diagnostics, published once per second through Darwin notification state so the
// controller can show what the hook sees without a Mac or a log viewer.
enum Reject : uint8_t { kOK = 0, kDisabled, kRenderError, kNoBuffers, kNoFormat, kNotPCM, kSampleType, kLayout, kRate };
std::atomic<uint64_t> statCalls{0}, statNested{0}, statFrames{0}, statFormat{0};
std::atomic<uint32_t> configSource{0};
bool hookedRenderOK = false, hookedUninitOK = false;

static bool valid(double x, double lo, double hi) {
    return std::isfinite(x) && x >= lo && x <= hi;
}
static NSDictionary *section(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSDictionary class]] ? v : @{};
}
static double number(NSDictionary *d, NSString *key, double fallback, double lo, double hi) {
    id v = d[key];
    if (![v isKindOfClass:[NSNumber class]]) return fallback;
    double x = [v doubleValue];
    return valid(x, lo, hi) ? x : fallback;
}
static bool flag(NSDictionary *d, NSString *key, bool fallback) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}
static timbre::EffectsParams parseEffects(NSDictionary *d) {
    timbre::EffectsParams p;
    p.outputDB = number(d, @"output", 0, -24, 12);
    NSDictionary *c = section(d, @"comp");
    p.comp = {flag(c, @"on", false), number(c, @"threshold", -24, -60, 0), number(c, @"knee", 6, 0, 40),
              number(c, @"ratio", 3, 1, 20), number(c, @"attack", 10, 0.1, 200), number(c, @"release", 150, 10, 1000),
              number(c, @"makeup", 0, -12, 24)};
    NSDictionary *x = section(d, @"crossfeed");
    p.crossfeed = {flag(x, @"on", false), number(x, @"level", -6, -20, -1), number(x, @"cutoff", 700, 300, 1500),
                   number(x, @"delay", 0.3, 0, 0.8)};
    NSDictionary *w = section(d, @"width");
    p.width = {flag(w, @"on", false), number(w, @"width", 1, 0, 2.5), number(w, @"balance", 0, -1, 1),
               flag(w, @"mono", false), flag(w, @"swap", false)};
    NSDictionary *s = section(d, @"spatial");
    p.spatial = {flag(s, @"on", false), number(s, @"angle", 30, 5, 90), number(s, @"amount", 0.8, 0, 1),
                 number(s, @"distance", 1, 0.3, 5)};
    NSDictionary *r = section(d, @"reverb");
    p.reverb = {flag(r, @"on", false), number(r, @"decay", 1.8, 0.2, 8), number(r, @"predelay", 20, 0, 200),
                number(r, @"damping", 6000, 1000, 16000), number(r, @"width", 1, 0, 1), number(r, @"mix", 0.25, 0, 1)};
    NSDictionary *l = section(d, @"limiter");
    p.limiter = {flag(l, @"on", true), number(l, @"ceiling", -1, -12, 0)};
    return p;
}
static void ensureEffectSlots() {
    for (auto &slot : slots) {
        if (slot.fx.load(std::memory_order_acquire)) continue;
        try { slot.fx.store(new timbre::Effects, std::memory_order_release); }
        catch (...) { os_log(OS_LOG_DEFAULT, "Timbre: could not allocate effects slot"); return; }
    }
}
static void reloadSettings() {
    @autoreleasepool {
        NSDictionary *d = nil;
        uint32_t source = 0;
        for (uint32_t i = 0; i < sizeof(kPrefsPaths) / sizeof(kPrefsPaths[0]) && !d; i++) {
            NSDictionary *candidate = [NSDictionary dictionaryWithContentsOfFile:kPrefsPaths[i]];
            if ([candidate isKindOfClass:[NSDictionary class]]) { d = candidate; source = i + 1; }
        }
        configSource.store(source, std::memory_order_relaxed);
        if (!d) d = @{};
        Config *next = new Config;
        next->generation = sequence.fetch_add(1, std::memory_order_relaxed);
        next->enabled = [d[@"enabled"] boolValue];
        double preamp = d[@"preamp"] ? [d[@"preamp"] doubleValue] : -6;
        next->preamp = std::pow(10., (valid(preamp, -24, 0) ? preamp : -6) / 20.);
        NSArray *bands = d[@"bands"];
        if ([bands isKindOfClass:[NSArray class]]) {
            for (id item in bands) {
                if (next->count == kMaxBands) break;
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *b = item;
                if (b[@"enabled"] && ![b[@"enabled"] boolValue]) continue;
                double f = [b[@"frequency"] doubleValue];
                double g = [b[@"gain"] doubleValue];
                double q = [b[@"q"] doubleValue];
                NSInteger type = [b[@"type"] integerValue];
                if (!valid(f, 20, 20000) || !valid(g, -24, 24) || !valid(q, 0.2, 10) || type < 0 || type > 7) continue;
                next->bands[next->count++] = timbre::Band{true, static_cast<timbre::FilterType>(type), f, g, q};
            }
        } else {
            // Backward compatibility with the original single-band controller.
            double f = d[@"frequency"] ? [d[@"frequency"] doubleValue] : 1000;
            double g = d[@"gain"] ? [d[@"gain"] doubleValue] : 6;
            double q = d[@"q"] ? [d[@"q"] doubleValue] : 1;
            if (valid(f, 20, 20000) && valid(g, -24, 24) && valid(q, 0.2, 10))
                next->bands[next->count++] = timbre::Band{true, timbre::FilterType::Peaking, f, g, q};
        }
        next->fx = parseEffects(d);
        next->fxActive = timbre::effectsActive(next->fx);
        if (next->enabled && next->fxActive) ensureEffectSlots();
        const Config *old = active.exchange(next, std::memory_order_acq_rel);
        if (old) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), reloadQueue, ^{ delete old; });
        os_log(OS_LOG_DEFAULT, "Timbre: configuration source=%{public}u enabled=%{public}d bands=%{public}lu effects=%{public}d",
               source, (int)next->enabled, (unsigned long)next->count, (int)next->fxActive);
    }
}
static void prepare(ThreadState &s, AudioUnit unit, double rate, const Config *config) {
    if (s.unit == unit && s.rate == rate && s.generation == config->generation) return;
    const bool routeChanged = s.unit != unit || s.rate != rate;
    s.unit = unit; s.rate = rate; s.generation = config->generation;
    const size_t previous = s.count;
    s.count = 0;
    // No allocations: coefficients are recalculated on route/config change only.
    for (size_t i = 0; i < config->count; ++i) {
        try { s.coefficients[s.count++] = timbre::coefficients(config->bands[i], rate); }
        catch (...) { s.count = 0; break; }
    }
    // Keep filter memory across parameter edits so dragging a band does not click.
    if (routeChanged || s.count != previous) for (auto &f : s.filters) f = {};
}
static void process(float *samples, UInt32 frames, const Config *config) noexcept {
    for (UInt32 i = 0; i < frames; ++i) for (unsigned ch = 0; ch < 2; ++ch) {
        const size_t at = size_t(i) * 2 + ch;
        double x = samples[at] * config->preamp;
        for (size_t j = 0; j < state.count; ++j) {
            const auto &k = state.coefficients[j]; auto &z = state.filters[j];
            double y = k.b0 * x + z.z1[ch];
            z.z1[ch] = k.b1 * x - k.a1 * y + z.z2[ch];
            z.z2[ch] = k.b2 * x - k.a2 * y;
            x = y;
        }
        samples[at] = std::isfinite(x) ? static_cast<float>(x) : 0.f;
    }
}
static Slot *slotFor(AudioUnit unit) noexcept {
    const uint64_t now = mach_absolute_time();
    void *u = (void *)unit;
    for (auto &s : slots)
        if (s.owner.load(std::memory_order_acquire) == u) { s.lastUsed.store(now, std::memory_order_relaxed); return &s; }
    for (auto &s : slots) {
        if (!s.fx.load(std::memory_order_acquire)) continue;
        void *current = s.owner.load(std::memory_order_acquire);
        if (current && now - s.lastUsed.load(std::memory_order_relaxed) < staleTicks) continue;
        if (s.owner.compare_exchange_strong(current, u, std::memory_order_acq_rel)) {
            s.rate = 0; s.ready = false; s.generation = 0;
            s.lastUsed.store(now, std::memory_order_relaxed);
            return &s;
        }
    }
    return nullptr;
}
static void applyEffects(AudioUnit unit, double rate, float *samples, UInt32 frames, const Config *config) noexcept {
    Slot *slot = slotFor(unit);
    if (!slot) return;
    timbre::Effects *fx = slot->fx.load(std::memory_order_acquire);
    if (!fx) return;
    if (slot->rate != rate) {
        slot->rate = rate;
        slot->generation = 0;
        slot->ready = fx->prepare(rate);
    }
    if (!slot->ready) return;
    if (slot->generation != config->generation) {
        fx->configure(config->fx);
        slot->generation = config->generation;
    }
    fx->process(samples, frames);
}
static void runChain(AudioUnit unit, double rate, float *interleaved, UInt32 frames, const Config *config) noexcept {
    process(interleaved, frames, config);
    if (config->fxActive) applyEffects(unit, rate, interleaved, frames, config);
}
static uint64_t packFormat(const AudioStreamBasicDescription &f, const AudioBufferList *b, Reject r) {
    return (uint64_t)f.mFormatFlags | ((uint64_t)(f.mChannelsPerFrame & 0xff) << 32) | ((uint64_t)(f.mBitsPerChannel & 0xff) << 40) |
           ((uint64_t)(b ? (b->mNumberBuffers & 0xff) : 0) << 48) | ((uint64_t)r << 56);
}
static uint64_t packRate(double rate, uint32_t formatID) { return ((uint64_t)formatID << 32) | (uint32_t)rate; }
std::atomic<uint64_t> statRate{0};

// Converts any supported layout to interleaved float in fixed-size chunks, so the DSP only sees one format.
static Reject render(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *buffers, const Config *config) noexcept {
    if (!buffers || !frames || frames > (1u << 20) || buffers->mNumberBuffers < 1) return kNoBuffers;
    AudioStreamBasicDescription fmt{}; UInt32 size = sizeof(fmt);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, bus, &fmt, &size) != noErr) return kNoFormat;
    statRate.store(packRate(fmt.mSampleRate, fmt.mFormatID), std::memory_order_relaxed);
    Reject r = kOK;
    const bool isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) && fmt.mBitsPerChannel == 32;
    const bool isInt16 = !(fmt.mFormatFlags & kAudioFormatFlagIsFloat) && (fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) && fmt.mBitsPerChannel == 16;
    const UInt32 sampleBytes = isFloat ? 4 : 2;
    const AudioBuffer &b0 = buffers->mBuffers[0];
    const bool interleaved = buffers->mNumberBuffers == 1 && b0.mNumberChannels == 2;
    const bool planar = buffers->mNumberBuffers == 2 && b0.mNumberChannels == 1 && buffers->mBuffers[1].mNumberChannels == 1;
    if (fmt.mFormatID != kAudioFormatLinearPCM) r = kNotPCM;
    else if (!isFloat && !isInt16) r = kSampleType;
    else if (!interleaved && !planar) r = kLayout;
    else if (!valid(fmt.mSampleRate, 8000, 192000)) r = kRate;
    else if (!config || !config->enabled) r = kDisabled;
    statFormat.store(packFormat(fmt, buffers, r), std::memory_order_relaxed);
    if (r != kOK) return r;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
        const AudioBuffer &b = buffers->mBuffers[i];
        if (!b.mData || b.mDataByteSize < frames * sampleBytes * b.mNumberChannels) return kNoBuffers;
    }
    const double rate = fmt.mSampleRate;
    prepare(state, unit, rate, config);
    if (interleaved && isFloat) {
        runChain(unit, rate, static_cast<float *>(b0.mData), frames, config);
    } else {
        static thread_local float scratch[kChunk * 2];
        for (UInt32 at = 0; at < frames; at += kChunk) {
            const UInt32 n = std::min(kChunk, frames - at);
            if (planar && isFloat) {
                float *L = static_cast<float *>(buffers->mBuffers[0].mData) + at, *R = static_cast<float *>(buffers->mBuffers[1].mData) + at;
                for (UInt32 i = 0; i < n; i++) { scratch[2 * i] = L[i]; scratch[2 * i + 1] = R[i]; }
                runChain(unit, rate, scratch, n, config);
                for (UInt32 i = 0; i < n; i++) { L[i] = scratch[2 * i]; R[i] = scratch[2 * i + 1]; }
            } else {
                SInt16 *L, *R; UInt32 stride;
                if (planar) { L = static_cast<SInt16 *>(buffers->mBuffers[0].mData) + at; R = static_cast<SInt16 *>(buffers->mBuffers[1].mData) + at; stride = 1; }
                else { L = static_cast<SInt16 *>(b0.mData) + 2 * at; R = L + 1; stride = 2; }
                for (UInt32 i = 0; i < n; i++) { scratch[2 * i] = L[i * stride] / 32768.f; scratch[2 * i + 1] = R[i * stride] / 32768.f; }
                runChain(unit, rate, scratch, n, config);
                for (UInt32 i = 0; i < n; i++) {
                    L[i * stride] = (SInt16)std::lrintf(std::clamp(scratch[2 * i], -1.f, 32767.f / 32768.f) * 32768.f);
                    R[i * stride] = (SInt16)std::lrintf(std::clamp(scratch[2 * i + 1], -1.f, 32767.f / 32768.f) * 32768.f);
                }
            }
        }
    }
    statFrames.fetch_add(frames, std::memory_order_relaxed);
    return kOK;
}
OSStatus hookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                      UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    if (!originalRender) return kAudio_ParamError;
    // Mixers pull their inputs with nested AudioUnitRender calls; only the outermost (final mix) is processed.
    if (state.inHook) { statNested.fetch_add(1, std::memory_order_relaxed); return originalRender(unit, flags, time, bus, frames, buffers); }
    state.inHook = true;
    OSStatus result = originalRender(unit, flags, time, bus, frames, buffers);
    statCalls.fetch_add(1, std::memory_order_relaxed);
    const Config *config = active.load(std::memory_order_acquire);
    if (result == noErr) render(unit, bus, frames, buffers, config);
    else statFormat.store((uint64_t)kRenderError << 56, std::memory_order_relaxed);
    state.inHook = false;
    return result;
}
OSStatus hookedUninit(AudioUnit unit) {
    if (state.unit == unit) { state.unit = nullptr; state.generation = 0; }
    for (auto &s : slots) {
        void *expected = (void *)unit;
        s.owner.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
    }
    return originalUninit ? originalUninit(unit) : kAudio_ParamError;
}
static void publish(const char *process, const char *field, uint64_t value) {
    char name[160];
    snprintf(name, sizeof(name), "com.soum91.timbreaudio.status.%s.%s", process, field);
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, value);
    notify_cancel(token);
}
static void startDiagnostics() {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, reloadQueue);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, 250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        const char *process = getprogname();
        const Config *c = active.load(std::memory_order_acquire);
        uint64_t slotsReady = 0;
        for (auto &s : slots) if (s.fx.load(std::memory_order_relaxed)) slotsReady++;
        const uint64_t info = (uint64_t)getpid() << 32 | (hookedRenderOK ? 1 : 0) | (hookedUninitOK ? 2 : 0) |
                              (uint64_t)(configSource.load(std::memory_order_relaxed) & 3) << 2 |
                              (c && c->enabled ? 16 : 0) | (c && c->fxActive ? 32 : 0) | (c ? (uint64_t)(c->count & 31) << 6 : 0) | slotsReady << 11;
        publish(process, "info", info);
        publish(process, "calls", statCalls.load(std::memory_order_relaxed));
        publish(process, "nested", statNested.load(std::memory_order_relaxed));
        publish(process, "frames", statFrames.load(std::memory_order_relaxed));
        publish(process, "format", statFormat.load(std::memory_order_relaxed));
        publish(process, "rate", statRate.load(std::memory_order_relaxed));
        publish(process, "heartbeat", (uint64_t)time(nullptr));
        // Second channel in case the daemon's sandbox blocks notify state: plain text files the root helper reads.
        char text[512];
        const uint64_t fmt = statFormat.load(std::memory_order_relaxed);
        snprintf(text, sizeof(text), "time=%ld pid=%d hook=%d source=%u enabled=%d bands=%lu fx=%d calls=%llu nested=%llu frames=%llu "
                 "format_flags=0x%llx channels=%llu bits=%llu buffers=%llu result=%llu rate=%llu\n",
                 (long)time(nullptr), getpid(), hookedRenderOK ? 1 : 0, configSource.load(std::memory_order_relaxed),
                 c && c->enabled ? 1 : 0, c ? (unsigned long)c->count : 0ul, c && c->fxActive ? 1 : 0,
                 (unsigned long long)statCalls.load(std::memory_order_relaxed), (unsigned long long)statNested.load(std::memory_order_relaxed),
                 (unsigned long long)statFrames.load(std::memory_order_relaxed), (unsigned long long)(fmt & 0xffffffff),
                 (unsigned long long)((fmt >> 32) & 0xff), (unsigned long long)((fmt >> 40) & 0xff), (unsigned long long)((fmt >> 48) & 0xff),
                 (unsigned long long)(fmt >> 56), (unsigned long long)(uint32_t)statRate.load(std::memory_order_relaxed));
        static const char *dirs[] = {"/var/jb/var/mobile/Library/Preferences", "/var/tmp", "/tmp"};
        for (const char *dir : dirs) {
            char path[256];
            snprintf(path, sizeof(path), "%s/com.soum91.timbreaudio.status.%s.txt", dir, process);
            if (FILE *f = fopen(path, "w")) { fputs(text, f); fclose(f); }
        }
    });
    dispatch_resume(t);
    static dispatch_source_t retained;
    retained = t;
    (void)retained;
}
__attribute__((constructor)) void initializeTimbre() {
    os_log(OS_LOG_DEFAULT, "Timbre: injected into %{public}s pid %d", getprogname(), getpid());
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    staleTicks = timebase.numer ? (uint64_t)(2e9 * timebase.denom / timebase.numer) : 2000000000ull;
    reloadQueue = dispatch_queue_create("com.soum91.timbreaudio.reload", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(reloadQueue, ^{ reloadSettings(); });
    // The controller posts a Darwin notification after every save for instant updates.
    int token = 0;
    notify_register_dispatch(kReloadNotification, &token, reloadQueue, ^(int) { reloadSettings(); });
    // Fallback: poll the plist modification date once per second.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, reloadQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        // A plain timestamp: this file is built without ARC, so caching an NSDate would dangle.
        static double lastStamp = -1;
        @autoreleasepool {
            double stamp = 0;
            for (NSString *path : kPrefsPaths) {
                NSDate *date = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
                if (date) stamp += date.timeIntervalSince1970;
            }
            if (stamp != lastStamp) {
                const bool first = lastStamp < 0;
                lastStamp = stamp;
                if (!first) reloadSettings();
            }
        }
    });
    dispatch_resume(timer);
    // Keep the timer alive for the daemon's lifetime.
    static dispatch_source_t retainedTimer;
    retainedTimer = timer;
    (void)retainedTimer;
    void *renderSymbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (renderSymbol) MSHookFunction(renderSymbol, (void *)&hookedRender, (void **)&originalRender);
    hookedRenderOK = originalRender != nullptr;
    void *uninitSymbol = dlsym(RTLD_DEFAULT, "AudioUnitUninitialize");
    if (uninitSymbol) MSHookFunction(uninitSymbol, (void *)&hookedUninit, (void **)&originalUninit);
    hookedUninitOK = originalUninit != nullptr;
    startDiagnostics();
    os_log(OS_LOG_DEFAULT, "Timbre loaded: AudioUnitRender hook=%{public}d", originalRender != nullptr);
}
}
