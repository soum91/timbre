// Experimental iOS 16 mediaserverd hook. Disabled by default for safety.
#include <AudioToolbox/AudioToolbox.h>
#include <substrate.h>
#include <dlfcn.h>
#include <atomic>
#include <memory>
#include <cstring>
#include "../NativeDSP/TimbreDSP.hpp"

static OSStatus (*originalRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *) = nullptr;
static std::atomic<bool> enabled{false};
// A single audio unit may render on multiple threads. Never share biquad history
// between streams. This initial integration uses a thread-local engine.
static thread_local std::unique_ptr<timbre::StereoEQ> engine;
static thread_local double engineRate = 0;
static thread_local bool inHook = false;

static OSStatus timbreRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                             AudioBufferList *buffers) {
  if (!originalRender) return kAudio_ParamError;
  if (inHook) return originalRender(unit, flags, time, bus, frames, buffers);
  inHook = true;
  OSStatus result = originalRender(unit, flags, time, bus, frames, buffers);
  if (result == noErr && enabled.load(std::memory_order_relaxed) && buffers && frames) {
    AudioStreamBasicDescription fmt{};
    UInt32 size = sizeof(fmt);
    // Only handle known stereo interleaved float32 PCM. Other layouts pass through.
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, bus, &fmt, &size) == noErr &&
        fmt.mFormatID == kAudioFormatLinearPCM &&
        (fmt.mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
        fmt.mBitsPerChannel == 32 && fmt.mChannelsPerFrame == 2 &&
        fmt.mBytesPerFrame == 8 && fmt.mSampleRate > 100 &&
        buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mData &&
        buffers->mBuffers[0].mDataByteSize >= frames * 8 &&
        buffers->mBuffers[0].mNumberChannels == 2) {
      // No heap allocations in steady-state processing. First-time initialization
      // still allocates: do not enable until an audio-thread-safe design is ready.
      if (engine && engineRate == fmt.mSampleRate)
        engine->process((float *)buffers->mBuffers[0].mData, frames);
    }
  }
  inHook = false;
  return result;
}

__attribute__((constructor)) static void initTimbre() {
  // Do NOT activate without a verified audio route and stream-lifecycle handling.
  // Constructor intentionally leaves processing disabled.
  void *symbol = dlsym(RTLD_DEFAULT, "AudioUnitRender");
  if (symbol) MSHookFunction(symbol, (void *)&timbreRender, (void **)&originalRender);
}
