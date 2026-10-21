// Timbre experimental system-audio EQ for Dopamine rootless.
// AudioUnitRender interception is not guaranteed to catch every iOS playback route.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <os/log.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include "../NativeDSP/TimbreDSP.hpp"

namespace {
constexpr size_t kMaxBands = 12;
static NSString *const kPrefs = @"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
using RenderFn = OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
using UninitFn = OSStatus (*)(AudioUnit);
RenderFn originalRender = nullptr;
UninitFn originalUninit = nullptr;
struct Config {
    uint64_t generation = 0;
    bool enabled = false;
    double preamp = 1;
    size_t count = 0;
    timbre::Coeffs coefficients[kMaxBands]{};
    double sampleRate = 48000;
    timbre::Band bands[kMaxBands]{};
};
// Snapshots are never freed while the daemon runs: render threads can hold old pointers.
// A typical edit costs < 2 KB. A future implementation should use epoch reclamation.
std::atomic<const Config *> active{nullptr};
std::atomic<uint64_t> sequence{1};
std::atomic<uint64_t> renderCalls{0}, processedFrames{0};
struct FilterState { double z1[2]{}, z2[2]{}; };
struct ThreadState {
    bool inHook = false;
    AudioUnit unit = nullptr;
    const Config *config = nullptr;
    double rate = 0;
    size_t count = 0;
    timbre::Coeffs coefficients[kMaxBands]{};
    FilterState filters[kMaxBands]{};
};
thread_local ThreadState state;

static bool valid(double x, double lo, double hi) {
    return std::isfinite(x) && x >= lo && x <= hi;
}
static void reloadSettings() {
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefs];
        if (![d isKindOfClass:[NSDictionary class]]) d = @{};
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
            if (valid(f,20,20000) && valid(g,-24,24) && valid(q,0.2,10))
                next->bands[next->count++] = timbre::Band{true,timbre::FilterType::Peaking,f,g,q};
        }
        active.store(next, std::memory_order_release);
        os_log(OS_LOG_DEFAULT,"Timbre: configuration loaded enabled=%{public}d bands=%{public}lu",(int)next->enabled,(unsigned long)next->count);
    }
}
static void prepare(ThreadState &s, AudioUnit unit, double rate, const Config *config) {
    if (s.unit == unit && s.rate == rate && s.config == config) return;
    s.unit = unit; s.rate = rate; s.config = config; s.count = 0;
    for (auto &f : s.filters) f = {};
    // No allocations: calculating coefficients on route/config change only.
    for (size_t i=0; i<config->count; ++i) {
        try { s.coefficients[s.count++] = timbre::coefficients(config->bands[i],rate); }
        catch (...) { s.count = 0; return; }
    }
}
static void process(float *samples, UInt32 frames, const Config *config) noexcept {
    for (UInt32 i=0; i<frames; ++i) for (unsigned ch=0; ch<2; ++ch) {
        const size_t at = size_t(i)*2+ch;
        double x = samples[at] * config->preamp;
        for (size_t j=0; j<state.count; ++j) {
            const auto &k=state.coefficients[j]; auto &z=state.filters[j];
            double y=k.b0*x+z.z1[ch];
            z.z1[ch]=k.b1*x-k.a1*y+z.z2[ch];
            z.z2[ch]=k.b2*x-k.a2*y;
            x=y;
        }
        samples[at]=std::isfinite(x)?static_cast<float>(x):0.f;
    }
}
OSStatus hookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                      UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    if (!originalRender) return kAudio_ParamError;
    if (state.inHook) return originalRender(unit,flags,time,bus,frames,buffers);
    state.inHook=true;
    OSStatus result=originalRender(unit,flags,time,bus,frames,buffers);
    renderCalls.fetch_add(1,std::memory_order_relaxed);
    const Config *config=active.load(std::memory_order_acquire);
    if (result==noErr && config && config->enabled && buffers && frames && frames<=UINT32_MAX/8 &&
        buffers->mNumberBuffers==1 && buffers->mBuffers[0].mData &&
        buffers->mBuffers[0].mNumberChannels==2 && buffers->mBuffers[0].mDataByteSize>=frames*8) {
        AudioStreamBasicDescription fmt{}; UInt32 size=sizeof(fmt);
        if (AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,bus,&fmt,&size)==noErr &&
            fmt.mFormatID==kAudioFormatLinearPCM && (fmt.mFormatFlags&kAudioFormatFlagIsFloat) &&
            !(fmt.mFormatFlags&kAudioFormatFlagIsNonInterleaved) && fmt.mBitsPerChannel==32 &&
            fmt.mChannelsPerFrame==2 && fmt.mBytesPerFrame==8 && valid(fmt.mSampleRate,8000,192000)) {
            prepare(state,unit,fmt.mSampleRate,config);
            process(static_cast<float*>(buffers->mBuffers[0].mData),frames,config);
            processedFrames.fetch_add(frames,std::memory_order_relaxed);
        }
    }
    state.inHook=false; return result;
}
OSStatus hookedUninit(AudioUnit unit) {
    if (state.unit==unit) {state.config=nullptr;state.unit=nullptr;}
    return originalUninit ? originalUninit(unit) : kAudio_ParamError;
}
__attribute__((constructor)) void initializeTimbre() {
    reloadSettings();
    // Poll on a non-audio queue; no file access in the render callback.
    dispatch_queue_t queue=dispatch_get_global_queue(QOS_CLASS_UTILITY,0);
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,200*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{
        static NSDate *lastDate=nil;
        NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:kPrefs error:nil];
        NSDate *date=attrs[NSFileModificationDate];
        if ((date && ![date isEqualToDate:lastDate]) || (!date && lastDate)) {
            lastDate=date;
            reloadSettings();
        }
    });
    dispatch_resume(timer);
    // Intentional lifetime for daemon. Capture retains dispatch source.
    static dispatch_source_t retainedTimer;
    retainedTimer=timer;
    void *renderSymbol=dlsym(RTLD_DEFAULT,"AudioUnitRender");
    if(renderSymbol) MSHookFunction(renderSymbol,(void*)&hookedRender,(void**)&originalRender);
    void *uninitSymbol=dlsym(RTLD_DEFAULT,"AudioUnitUninitialize");
    if(uninitSymbol) MSHookFunction(uninitSymbol,(void*)&hookedUninit,(void**)&originalUninit);
    os_log(OS_LOG_DEFAULT,"Timbre loaded: AudioUnitRender hook=%{public}d",originalRender!=nullptr);
}
}
