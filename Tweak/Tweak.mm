// Timbre experimental iOS 16 rootless AudioUnitRender probe.
// IMPORTANT: AudioUnitRender interception is not proof of global output routing.
#include <AudioToolbox/AudioToolbox.h>
#include <substrate.h>
#include <os/log.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "../NativeDSP/TimbreDSP.hpp"

namespace {
using RenderFn = OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
using UninitFn = OSStatus (*)(AudioUnit);
RenderFn originalRender = nullptr;
UninitFn originalUninit = nullptr;
std::atomic<bool> enabled{false};
std::atomic<unsigned long long> renderCalls{0};
std::atomic<unsigned long long> processedFrames{0};
// Each thread owns its biquad state. A unit switch resets the state to avoid bleeding
// filter history across unrelated streams on the same render thread.
struct ThreadState {
  AudioUnit lastUnit = nullptr;
  double lastRate = 0.0;
  timbre::Coeffs coeff{};
  double z1[2]{};
  double z2[2]{};
  bool prepared = false;
  bool inHook = false;
};
thread_local ThreadState tls;

// Deliberately fixed 1 kHz +6 dB peaking band for audible device-level validation.
// Configuration / UI and real-time safe coefficient swapping are later steps.
void process(float *pcm, UInt32 frames, AudioUnit unit, double sampleRate) noexcept {
  ThreadState &s = tls;
  if (s.lastUnit != unit || s.lastRate != sampleRate || !s.prepared) {
    // Done only on format/unit changes. Full production version must precompute
    // coefficients off the realtime audio thread.
    const timbre::Band testBand{true, timbre::FilterType::Peaking, 1000., 6., 1.};
    s.coeff = timbre::coefficients(testBand, sampleRate);
    s.z1[0] = s.z1[1] = s.z2[0] = s.z2[1] = 0.0;
    s.lastUnit = unit;
    s.lastRate = sampleRate;
    s.prepared = true;
  }
  const timbre::Coeffs &k = s.coeff;
  for (UInt32 i = 0; i < frames; ++i) {
    for (unsigned c = 0; c < 2; ++c) {
      const size_t pos = size_t(i)*2+c;
      const double x = pcm[pos] * 0.5011872336272722; // -6 dB headroom
      const double y = k.b0*x+s.z1[c];
      s.z1[c] = k.b1*x-k.a1*y+s.z2[c];
      s.z2[c] = k.b2*x-k.a2*y;
      pcm[pos] = std::isfinite(y) ? static_cast<float>(y) : 0.f;
    }
  }
}

OSStatus hookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                      const AudioTimeStamp *stamp, UInt32 bus, UInt32 frames,
                      AudioBufferList *buffers) {
  if (!originalRender) return kAudio_ParamError;
  if (tls.inHook) return originalRender(unit, flags, stamp, bus, frames, buffers);
  tls.inHook = true;
  const OSStatus result = originalRender(unit, flags, stamp, bus, frames, buffers);
  renderCalls.fetch_add(1, std::memory_order_relaxed);
  if (result == noErr && enabled.load(std::memory_order_relaxed) && buffers && frames &&
      frames <= UINT32_MAX / 8 && buffers->mNumberBuffers == 1 &&
      buffers->mBuffers[0].mData && buffers->mBuffers[0].mNumberChannels == 2 &&
      buffers->mBuffers[0].mDataByteSize >= frames*8) {
    AudioStreamBasicDescription fmt{};
    UInt32 sz = sizeof(fmt);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, bus, &fmt, &sz) == noErr &&
        fmt.mFormatID == kAudioFormatLinearPCM &&
        (fmt.mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
        fmt.mBitsPerChannel == 32 && fmt.mChannelsPerFrame == 2 &&
        fmt.mBytesPerFrame == 8 && std::isfinite(fmt.mSampleRate) &&
        fmt.mSampleRate > 100 && fmt.mSampleRate < 384000) {
      process(static_cast<float*>(buffers->mBuffers[0].mData),frames,unit,fmt.mSampleRate);
      processedFrames.fetch_add(frames, std::memory_order_relaxed);
    }
  }
  tls.inHook = false;
  return result;
}
OSStatus hookedUninit(AudioUnit unit) {
  if (tls.lastUnit == unit) tls.prepared = false;
  return originalUninit ? originalUninit(unit) : kAudio_ParamError;
}

// No audio-thread logging. Optional test enable file is checked only at startup.
// Place exactly the word 'enable' in /var/jb/etc/timbre-audio-test-enable
// and restart the target daemon, or leave absent for passive observation.
__attribute__((constructor)) void init() {
  FILE *f = std::fopen("/var/jb/etc/timbre-audio-test-enable", "r");
  if (f) {
    char buf[32]{};
    if (std::fgets(buf, sizeof(buf), f) && std::strncmp(buf,"enable",6)==0)
      enabled.store(true, std::memory_order_relaxed);
    std::fclose(f);
  }
  if (void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender"))
    MSHookFunction(symbol, reinterpret_cast<void*>(&hookedRender), reinterpret_cast<void**>(&originalRender));
  if (void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitUninitialize"))
    MSHookFunction(symbol, reinterpret_cast<void*>(&hookedUninit), reinterpret_cast<void**>(&originalUninit));
  os_log(OS_LOG_DEFAULT, "TimbreAudio loaded. test_eq_enabled=%{public}d render_hook=%{public}d", int(enabled.load()), int(originalRender != nullptr));
}
}
