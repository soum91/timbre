// Experimental rootless audio rendering hook, not validated on iOS 16.1.1 hardware.
#include <AudioToolbox/AudioToolbox.h>
#include <Foundation/Foundation.h>
#include <substrate.h>
#include <os/log.h>
#include <dlfcn.h>
#include <atomic>
#include <cmath>
#include "../NativeDSP/TimbreDSP.hpp"
namespace {
using RenderFn=OSStatus (*)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*);
using UninitFn=OSStatus (*)(AudioUnit);
RenderFn originalRender=nullptr; UninitFn originalUninit=nullptr;
std::atomic<unsigned long long> renderCalls{0},processedFrames{0};
struct Settings {bool enabled=false; double frequency=1000,gain=6,preamp=-6,q=1;};
Settings settings;
struct State { AudioUnit unit=nullptr;double sampleRate=0,z1[2]{},z2[2]{};timbre::Coeffs coeff{};bool ready=false,inHook=false; };
thread_local State tls;
void process(float *data,UInt32 frames,AudioUnit unit,double rate) {
 State &s=tls;
 if(!s.ready||s.unit!=unit||s.sampleRate!=rate){
  timbre::Band b{true,timbre::FilterType::Peaking,settings.frequency,settings.gain,settings.q};
  s.coeff=timbre::coefficients(b,rate);s.unit=unit;s.sampleRate=rate;s.ready=true;
  s.z1[0]=s.z1[1]=s.z2[0]=s.z2[1]=0;
 }
 double gain=std::pow(10.,settings.preamp/20.);
 for(UInt32 i=0;i<frames;i++)for(int c=0;c<2;c++){
  size_t k=size_t(i)*2+c;double x=data[k]*gain;
  double y=s.coeff.b0*x+s.z1[c];s.z1[c]=s.coeff.b1*x-s.coeff.a1*y+s.z2[c];s.z2[c]=s.coeff.b2*x-s.coeff.a2*y;
  data[k]=std::isfinite(y)?static_cast<float>(y):0;
 }
}
OSStatus render(AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers){
 if(!originalRender)return kAudio_ParamError;
 if(tls.inHook)return originalRender(unit,flags,time,bus,frames,buffers);
 tls.inHook=true;OSStatus err=originalRender(unit,flags,time,bus,frames,buffers);
 renderCalls.fetch_add(1,std::memory_order_relaxed);
 if(err==noErr && settings.enabled && buffers && frames && frames<=UINT32_MAX/8 &&
    buffers->mNumberBuffers==1 && buffers->mBuffers[0].mData &&
    buffers->mBuffers[0].mNumberChannels==2 && buffers->mBuffers[0].mDataByteSize>=frames*8){
  AudioStreamBasicDescription fmt{};UInt32 size=sizeof(fmt);
  if(AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,bus,&fmt,&size)==noErr &&
     fmt.mFormatID==kAudioFormatLinearPCM && (fmt.mFormatFlags & kAudioFormatFlagIsFloat) &&
     !(fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && fmt.mBitsPerChannel==32 &&
     fmt.mChannelsPerFrame==2 && fmt.mBytesPerFrame==8 && std::isfinite(fmt.mSampleRate) &&
     fmt.mSampleRate>100 && fmt.mSampleRate<384000){
   process((float*)buffers->mBuffers[0].mData,frames,unit,fmt.mSampleRate);
   processedFrames.fetch_add(frames,std::memory_order_relaxed);
  }
 }
 tls.inHook=false;return err;
}
OSStatus uninit(AudioUnit unit){ if(tls.unit==unit)tls.ready=false;return originalUninit?originalUninit(unit):kAudio_ParamError; }
__attribute__((constructor)) void init(){
 @autoreleasepool {
 NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist"];
 if([d isKindOfClass:[NSDictionary class]]){
  settings.enabled=[d[@"enabled"] boolValue];
  double f=[d[@"frequency"] doubleValue],g=[d[@"gain"] doubleValue],p=[d[@"preamp"] doubleValue],q=[d[@"q"] doubleValue];
  if(std::isfinite(f)&&f>=20&&f<=20000)settings.frequency=f;
  if(std::isfinite(g)&&g>=-12&&g<=12)settings.gain=g;
  if(std::isfinite(p)&&p>=-24&&p<=0)settings.preamp=p;
  if(std::isfinite(q)&&q>=0.2&&q<=10)settings.q=q;
 }
 }
 void *r=dlsym(RTLD_DEFAULT,"AudioUnitRender");if(r)MSHookFunction(r,(void*)&render,(void**)&originalRender);
 void *u=dlsym(RTLD_DEFAULT,"AudioUnitUninitialize");if(u)MSHookFunction(u,(void*)&uninit,(void**)&originalUninit);
 os_log(OS_LOG_DEFAULT,"TimbreAudio loaded enabled=%{public}d render=%{public}d",(int)settings.enabled,(int)(originalRender!=nullptr));
}
}
