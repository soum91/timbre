#include "../TimbreDSP.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
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
 std::cout<<"PASS: native DSP tests\n";
}
