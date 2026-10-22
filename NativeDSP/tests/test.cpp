#include "../TimbreDSP.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
#include <algorithm>
int main() {
 using namespace timbre;
 StereoEQ eq(48000);
 eq.configure({},0);
 float samples[]={0.25f,-0.5f,1.f,-1.f};
 eq.process(samples,2);
 assert(samples[0]==0.25f&&samples[1]==-0.5f&&samples[2]==1.f&&samples[3]==-1.f);
 eq.configure({},-6.020599913279624);
 eq.process(samples,2);
 assert(std::abs(samples[0]-0.125f)<1e-6);
 eq.configure({Band{true,FilterType::Peaking,1000,6,1}},0);
 float impulse[512]={};impulse[0]=1;
 eq.process(impulse,256);
 assert(std::isfinite(impulse[510]));
 for(int i=1;i<512;i+=2)assert(impulse[i]==0);
 for(int i=0;i<8;i++) {Band b{true,static_cast<FilterType>(i),1000,3,0.7};auto c=coefficients(b,48000);assert(std::isfinite(c.b0)&&std::isfinite(c.a2));}
 {
  // Effects: everything off is bit-exact passthrough.
  Effects fx; EffectsParams p; p.limiter.on=false;
  assert(fx.prepare(48000)); fx.configure(p);
  float a[8]={0.1f,-0.2f,0.3f,-0.4f,0.5f,0.6f,-0.7f,0.8f},b[8];
  for(int i=0;i<8;i++)b[i]=a[i];
  fx.process(b,4); for(int i=0;i<8;i++)assert(b[i]==a[i]);
  assert(!fx.prepare(192000)&&!fx.ready()&&fx.prepare(44100));
  // Mono collapses channels.
  p.width.on=true;p.width.mono=true;fx.configure(p);
  float m[4]={1.f,0.f,0.2f,0.6f};fx.process(m,2);assert(m[0]==m[1]&&m[2]==m[3]);
  // Swap.
  p.width.mono=false;p.width.swap=true;fx.configure(p);
  float w[2]={0.25f,-0.5f};fx.process(w,1);assert(std::abs(w[0]+0.5f)<1e-6f&&std::abs(w[1]-0.25f)<1e-6f);
  // Limiter holds the ceiling.
  p=EffectsParams{};p.outputDB=12;p.limiter.ceiling=-3;fx.configure(p);
  std::vector<float> loud(9600);for(size_t i=0;i<loud.size();i++)loud[i]=std::sin(i*0.05f);
  fx.process(loud.data(),loud.size()/2);const float ceil=std::pow(10.f,-3.f/20.f);
  for(float v:loud)assert(std::isfinite(v)&&std::abs(v)<=ceil+1e-6f);
  // Reverb leaves a finite tail after an impulse; spatial, crossfeed and compressor stay finite.
  p=EffectsParams{};p.reverb.on=true;p.reverb.mix=0.5;p.spatial.on=true;p.crossfeed.on=true;p.comp.on=true;
  fx.configure(p);fx.reset();
  std::vector<float> imp(48000*2,0.f);imp[0]=1;imp[1]=1;fx.process(imp.data(),48000);
  double tail=0;for(size_t i=20000;i<imp.size();i++){assert(std::isfinite(imp[i]));tail+=std::abs(imp[i]);}
  assert(tail>1e-4);
  assert(effectsActive(p)&&!effectsActive([]{EffectsParams q;q.limiter.on=false;return q;}()));
 }
 {
  // Immersive: finite, energetic, and a hard-left input lands louder in the left ear.
  Effects fx; EffectsParams p; p.limiter.on=false; p.spatial.on=true; p.spatial.mode=1; p.spatial.amount=1;
  for(double rate:{44100.0,48000.0,96000.0}){
   assert(fx.prepare(rate)); fx.configure(p); fx.reset();
   std::vector<float> buf(4800*2,0.f);
   for(size_t i=0;i<4800;i++){buf[2*i]=std::sin(i*0.07f)*0.5f;buf[2*i+1]=0;}
   fx.process(buf.data(),4800);
   double eL=0,eR=0;for(size_t i=2400;i<4800;i++){assert(std::isfinite(buf[2*i])&&std::isfinite(buf[2*i+1]));eL+=buf[2*i]*buf[2*i];eR+=buf[2*i+1]*buf[2*i+1];}
   assert(eL>1e-3&&eL>eR*1.3);
  }
  // Odd block sizes give the same result as one big block.
  std::vector<float> a(3000*2),b;for(size_t i=0;i<a.size();i++)a[i]=std::sin(i*0.013f)*0.3f;b=a;
  fx.prepare(48000);fx.configure(p);fx.reset();fx.process(a.data(),3000);
  fx.reset();for(size_t off=0;off<3000;){size_t n=std::min<size_t>(37+off%300,3000-off);fx.process(b.data()+2*off,n);off+=n;}
  for(size_t i=0;i<a.size();i++)assert(std::abs(a[i]-b[i])<1e-4f);
 }
 {
  Band b[2]={Band{true,FilterType::Peaking,1000,6,1},Band{true,FilterType::Peaking,10,9,0.7}};
  const double pk=curvePeakDB(b,2,48000); assert(pk>8.5&&pk<9.5);
  Band cut{true,FilterType::Peaking,100,-6,1}; assert(curvePeakDB(&cut,1,48000)<0.01);
  // Sub-20 Hz band produces finite coefficients.
  auto c=coefficients(Band{true,FilterType::LowShelf,5,6,0.7},48000); assert(std::isfinite(c.b0)&&std::isfinite(c.a1));
  // Immersive with the diffused set and room reflections stays finite.
  Effects fx; EffectsParams p; p.spatial.on=true;p.spatial.mode=1;p.spatial.hrtf=0;p.spatial.room=1;p.limiter.on=false;
  fx.prepare(48000);fx.configure(p);std::vector<float> v(9600);for(size_t i=0;i<v.size();i++)v[i]=std::sin(i*0.02f)*0.5f;
  fx.process(v.data(),4800);for(float x:v)assert(std::isfinite(x));
 }
 {
  // Head tracking: a centred (mono) source moves to the left ear when the head turns right.
  auto run=[](double yaw,bool track){
    Effects fx; EffectsParams p; p.limiter.on=false; p.spatial.on=true; p.spatial.mode=1; p.spatial.amount=1;
    p.spatial.surround=0; p.spatial.height=0; p.spatial.room=0; p.spatial.headTracking=track;
    fx.prepare(48000); fx.configure(p); fx.reset();
    std::vector<float> v(4800*2);
    double eL=0,eR=0;
    for(int pass=0;pass<4;pass++){
      for(size_t i=0;i<4800;i++){ float x=std::sin((pass*4800+i)*0.05f)*0.4f; v[2*i]=x; v[2*i+1]=x; }
      fx.setHeadYaw(pass==0?0:yaw,true); fx.process(v.data(),4800);  // start facing forward, then turn
      if(pass==3) for(size_t i=0;i<4800;i++){ assert(std::isfinite(v[2*i])); eL+=v[2*i]*v[2*i]; eR+=v[2*i+1]*v[2*i+1]; }
    }
    return std::make_pair(eL,eR);
  };
  auto still=run(0,true), right=run(70,true), off=run(70,false);
  assert(std::abs(still.first-still.second) < 0.1*still.first);  // centred
  assert(right.first > right.second*1.5);                        // turned right: sound sits to the left
  assert(std::abs(off.first-off.second) < 0.1*off.first);        // tracking off ignores yaw
 }
 std::cout<<"PASS: native DSP tests\n";
}
