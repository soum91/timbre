#include "TimbreDSP.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace timbre {
Coeffs coefficients(const Band& b, double fs) {
  if (!(fs>100) || !std::isfinite(fs)) throw std::invalid_argument("sample rate");
  if (!std::isfinite(b.frequency)||!std::isfinite(b.q)||!std::isfinite(b.gainDB)) throw std::invalid_argument("band");
  const double f=std::clamp(b.frequency,10.0,fs*0.49), q=std::clamp(b.q,0.05,40.0);
  const double A=std::pow(10.0,std::clamp(b.gainDB,-120.0,120.0)/40.0);
  const double w=2*std::acos(-1.0)*f/fs,c=std::cos(w),s=std::sin(w),al=s/(2*q),sA=2*std::sqrt(A)*al;
  double b0,b1,b2,a0,a1,a2;
  switch(b.type) {
    case FilterType::Peaking: b0=1+al*A;b1=-2*c;b2=1-al*A;a0=1+al/A;a1=-2*c;a2=1-al/A;break;
    case FilterType::LowPass: b0=(1-c)/2;b1=1-c;b2=b0;a0=1+al;a1=-2*c;a2=1-al;break;
    case FilterType::HighPass: b0=(1+c)/2;b1=-(1+c);b2=b0;a0=1+al;a1=-2*c;a2=1-al;break;
    case FilterType::BandPass: b0=al;b1=0;b2=-al;a0=1+al;a1=-2*c;a2=1-al;break;
    case FilterType::Notch: b0=1;b1=-2*c;b2=1;a0=1+al;a1=-2*c;a2=1-al;break;
    case FilterType::AllPass: b0=1-al;b1=-2*c;b2=1+al;a0=1+al;a1=-2*c;a2=1-al;break;
    case FilterType::LowShelf: b0=A*((A+1)-(A-1)*c+sA);b1=2*A*((A-1)-(A+1)*c);b2=A*((A+1)-(A-1)*c-sA);a0=(A+1)+(A-1)*c+sA;a1=-2*((A-1)+(A+1)*c);a2=(A+1)+(A-1)*c-sA;break;
    case FilterType::HighShelf: b0=A*((A+1)+(A-1)*c+sA);b1=-2*A*((A-1)+(A+1)*c);b2=A*((A+1)+(A-1)*c-sA);a0=(A+1)-(A-1)*c+sA;a1=2*((A-1)-(A+1)*c);a2=(A+1)-(A-1)*c-sA;break;
    default: throw std::invalid_argument("filter type");
  }
  return {b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}
StereoEQ::StereoEQ(double fs):sampleRate_(fs) { if(!(fs>100)||!std::isfinite(fs)) throw std::invalid_argument("sample rate"); }
void StereoEQ::configure(const std::vector<Band>& bands,double preampDB) {
  if(!std::isfinite(preampDB)) throw std::invalid_argument("preamp");
  std::vector<Stage> next;
  for(const auto& b:bands) if(b.enabled) next.push_back({coefficients(b,sampleRate_),{}});
  stages_=std::move(next);gain_=std::pow(10.0,std::clamp(preampDB,-120.0,24.0)/20.0);
}
void StereoEQ::reset() noexcept { for(auto& stage:stages_) for(auto& st:stage.state) st={}; }
void StereoEQ::process(float* samples,size_t frames) noexcept {
  if(!samples)return;
  for(size_t i=0;i<frames;i++)for(size_t ch=0;ch<2;ch++) {
    double x=static_cast<double>(samples[i*2+ch])*gain_;
    for(auto& stage:stages_) {
      auto& z=stage.state[ch];const auto& k=stage.coeff;
      const double y=k.b0*x+z.z1;
      z.z1=k.b1*x-k.a1*y+z.z2;
      z.z2=k.b2*x-k.a2*y;
      x=y;
    }
    samples[i*2+ch]=std::isfinite(x)?static_cast<float>(x):0.0f;
  }
}
}
