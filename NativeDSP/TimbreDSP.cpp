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

// ---------------------------------------------------------------------------
// Effects chain
// ---------------------------------------------------------------------------
namespace timbre {
namespace {
constexpr int kCombTuning[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kAllpassTuning[4] = {556, 441, 341, 225};
constexpr int kStereoSpread = 23;
constexpr double kPi = 3.14159265358979323846;
inline float db2lin(double db) { return static_cast<float>(std::pow(10.0, db / 20.0)); }
inline size_t scaled(int tuning, double fs) { return static_cast<size_t>(std::ceil(tuning * fs / 44100.0)); }
inline float onePoleCoeff(double hz, double fs) {
  return static_cast<float>(1.0 - std::exp(-2.0 * kPi * std::clamp(hz, 10.0, fs * 0.45) / fs));
}
inline float sanitize(float x) { return std::isfinite(x) ? x : 0.0f; }
}

bool effectsActive(const EffectsParams& p) noexcept {
  return p.comp.on || p.crossfeed.on || p.width.on || p.spatial.on || p.reverb.on || p.limiter.on ||
         std::fabs(p.outputDB) > 1e-6;
}

Effects::Effects() {
  const double fs = kMaxSampleRate;
  size_t total = 0;
  for (int ch = 0; ch < 2; ch++) {
    for (int i = 0; i < 8; i++) total += scaled(kCombTuning[i] + ch * kStereoSpread, fs) + 2;
    for (int i = 0; i < 4; i++) total += scaled(kAllpassTuning[i] + ch * kStereoSpread, fs) + 2;
  }
  const size_t preCap = static_cast<size_t>(0.2 * fs) + 2, shortCap = static_cast<size_t>(0.001 * fs) + 2;
  total += preCap + 4 * shortCap;
  memory_.assign(total, 0.0f);
  float* at = memory_.data();
  auto take = [&at](Line& l, size_t cap) { l.buf = at; l.cap = cap; l.len = 1; l.pos = 0; at += cap; };
  for (int ch = 0; ch < 2; ch++) {
    for (int i = 0; i < 8; i++) take(comb_[ch][i].line, scaled(kCombTuning[i] + ch * kStereoSpread, fs) + 2);
    for (int i = 0; i < 4; i++) take(ap_[ch][i], scaled(kAllpassTuning[i] + ch * kStereoSpread, fs) + 2);
    take(xfDelay_[ch], shortCap);
    take(spDelay_[ch], shortCap);
  }
  take(pre_, preCap);
}

float Effects::tick(Line& l, float x) noexcept {
  const float y = l.buf[l.pos];
  l.buf[l.pos] = x;
  if (++l.pos >= l.len) l.pos = 0;
  return y;
}

void Effects::clear(Line& l) noexcept {
  std::fill(l.buf, l.buf + l.cap, 0.0f);
  l.pos = 0;
}

void Effects::clearReverb() noexcept {
  for (auto& row : comb_) for (auto& c : row) { clear(c.line); c.store = 0; }
  for (auto& row : ap_) for (auto& a : row) clear(a);
  clear(pre_);
}

bool Effects::prepare(double sampleRate) noexcept {
  ready_ = false;
  if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > kMaxSampleRate) return false;
  fs_ = sampleRate;
  for (int ch = 0; ch < 2; ch++) {
    for (int i = 0; i < 8; i++) {
      Line& l = comb_[ch][i].line;
      l.len = std::clamp<size_t>(scaled(kCombTuning[i] + ch * kStereoSpread, fs_), 1, l.cap);
    }
    for (int i = 0; i < 4; i++) {
      Line& l = ap_[ch][i];
      l.len = std::clamp<size_t>(scaled(kAllpassTuning[i] + ch * kStereoSpread, fs_), 1, l.cap);
    }
  }
  reset();
  configure(p_);
  ready_ = true;
  return true;
}

void Effects::reset() noexcept {
  clearReverb();
  for (int ch = 0; ch < 2; ch++) {
    clear(xfDelay_[ch]); clear(spDelay_[ch]);
    xfLP_[ch].z = 0; spLP_[ch].z = 0;
  }
  compEnv_ = 0;
  limGain_ = 1;
}

void Effects::configure(const EffectsParams& p) noexcept {
  const EffectsParams old = p_;
  p_ = p;
  if (!(fs_ > 0)) return;
  const double fs = fs_;

  // Compressor
  compAtt_ = static_cast<float>(std::exp(-1.0 / (std::max(0.05, p.comp.attack) * 0.001 * fs)));
  compRel_ = static_cast<float>(std::exp(-1.0 / (std::max(1.0, p.comp.release) * 0.001 * fs)));
  if (p.comp.on && !old.comp.on) compEnv_ = 0;

  // Crossfeed: low-passed, slightly delayed opposite channel.
  xfGain_ = db2lin(std::clamp(p.crossfeed.level, -40.0, 0.0));
  xfNorm_ = 1.0f / (1.0f + xfGain_);
  for (int ch = 0; ch < 2; ch++) {
    xfLP_[ch].a = onePoleCoeff(p.crossfeed.cutoff, fs);
    xfDelay_[ch].len = std::clamp<size_t>(static_cast<size_t>(std::lround(std::clamp(p.crossfeed.delay, 0.0, 1.0) * 0.001 * fs)), 1, xfDelay_[ch].cap);
    if (p.crossfeed.on && !old.crossfeed.on) { clear(xfDelay_[ch]); xfLP_[ch].z = 0; }
  }

  // Spatial: virtual speakers at +/-angle. Interaural delay (Woodworth) plus head-shadow low-pass.
  // This is an ITD/ILD approximation, not a measured HRTF.
  const double theta = std::clamp(p.spatial.angle, 0.0, 90.0) * kPi / 180.0;
  const double itd = 0.0875 / 343.0 * (theta + std::sin(theta));
  const double distance = std::clamp(p.spatial.distance, 0.3, 5.0);
  const double shadowDB = -2.0 - 8.0 * std::sin(theta) + 1.5 * std::log2(distance);
  spGain_ = static_cast<float>(std::clamp(p.spatial.amount, 0.0, 1.0)) * db2lin(std::min(shadowDB, -1.0));
  spNorm_ = 1.0f / (1.0f + spGain_);
  for (int ch = 0; ch < 2; ch++) {
    spLP_[ch].a = onePoleCoeff(8000.0 - 6000.0 * std::sin(theta), fs);
    spDelay_[ch].len = std::clamp<size_t>(static_cast<size_t>(std::lround(itd * fs)), 1, spDelay_[ch].cap);
    if (p.spatial.on && !old.spatial.on) { clear(spDelay_[ch]); spLP_[ch].z = 0; }
  }

  // Stereo tools
  width_ = p.width.mono ? 0.0f : static_cast<float>(std::clamp(p.width.width, 0.0, 2.5));
  const double b = std::clamp(p.width.balance, -1.0, 1.0);
  balL_ = static_cast<float>(b > 0 ? 1 - b : 1);
  balR_ = static_cast<float>(b < 0 ? 1 + b : 1);

  // Reverb (Freeverb topology, feedback derived from the requested RT60).
  const double decay = std::clamp(p.reverb.decay, 0.1, 12.0);
  const float damp = static_cast<float>(std::exp(-2.0 * kPi * std::clamp(p.reverb.damping, 500.0, fs * 0.45) / fs));
  for (auto& row : comb_) for (auto& c : row) {
    c.feedback = static_cast<float>(std::min(0.985, std::pow(10.0, -3.0 * c.line.len / (decay * fs))));
    c.damp1 = damp; c.damp2 = 1.0f - damp;
  }
  pre_.len = std::clamp<size_t>(static_cast<size_t>(std::lround(std::clamp(p.reverb.predelay, 0.0, 200.0) * 0.001 * fs)), 1, pre_.cap);
  const float mix = static_cast<float>(std::clamp(p.reverb.mix, 0.0, 1.0));
  const float width = static_cast<float>(std::clamp(p.reverb.width, 0.0, 1.0));
  const float wet = mix * 3.0f;
  wet1_ = wet * (width / 2 + 0.5f);
  wet2_ = wet * ((1 - width) / 2);
  dry_ = 1.0f - mix;
  if (p.reverb.on && !old.reverb.on) clearReverb();

  // Output + limiter
  outGain_ = db2lin(std::clamp(p.outputDB, -48.0, 24.0));
  ceiling_ = db2lin(std::clamp(p.limiter.ceiling, -24.0, 0.0));
  limRel_ = static_cast<float>(std::exp(-1.0 / (0.08 * fs)));
}

void Effects::process(float* s, size_t frames) noexcept {
  if (!s || !ready_) return;
  const EffectsParams& p = p_;
  const float threshold = static_cast<float>(p.comp.threshold), knee = static_cast<float>(std::max(0.0, p.comp.knee));
  const float slope = static_cast<float>(1.0 / std::max(1.0, p.comp.ratio) - 1.0), makeup = static_cast<float>(p.comp.makeup);
  for (size_t i = 0; i < frames; i++) {
    float L = s[2 * i], R = s[2 * i + 1];

    if (p.comp.on) {
      const float peak = std::max(std::fabs(L), std::fabs(R));
      const float x = 20.0f * std::log10(peak + 1e-9f), over = x - threshold;
      float gr = 0;
      if (2 * over <= -knee) gr = 0;
      else if (knee > 0 && 2 * std::fabs(over) < knee) gr = slope * (over + knee / 2) * (over + knee / 2) / (2 * knee);
      else gr = slope * over;
      compEnv_ = gr < compEnv_ ? compAtt_ * compEnv_ + (1 - compAtt_) * gr : compRel_ * compEnv_ + (1 - compRel_) * gr;
      const float g = std::pow(10.0f, (compEnv_ + makeup) / 20.0f);
      L *= g; R *= g;
    }

    if (p.crossfeed.on) {
      xfLP_[0].z += xfLP_[0].a * (R - xfLP_[0].z);
      xfLP_[1].z += xfLP_[1].a * (L - xfLP_[1].z);
      const float cl = tick(xfDelay_[0], xfLP_[0].z), cr = tick(xfDelay_[1], xfLP_[1].z);
      L = (L + xfGain_ * cl) * xfNorm_;
      R = (R + xfGain_ * cr) * xfNorm_;
    }

    if (p.spatial.on) {
      spLP_[0].z += spLP_[0].a * (R - spLP_[0].z);
      spLP_[1].z += spLP_[1].a * (L - spLP_[1].z);
      const float cl = tick(spDelay_[0], spLP_[0].z), cr = tick(spDelay_[1], spLP_[1].z);
      L = (L + spGain_ * cl) * spNorm_;
      R = (R + spGain_ * cr) * spNorm_;
    }

    if (p.width.on) {
      if (p.width.swap) std::swap(L, R);
      const float m = (L + R) * 0.5f, side = (L - R) * 0.5f * width_;
      L = (m + side) * balL_;
      R = (m - side) * balR_;
    }

    if (p.reverb.on) {
      const float in = tick(pre_, (L + R) * 0.015f);
      float out[2] = {0, 0};
      for (int ch = 0; ch < 2; ch++) {
        for (auto& c : comb_[ch]) {
          const float y = c.line.buf[c.line.pos];
          c.store = y * c.damp2 + c.store * c.damp1;
          if (std::fabs(c.store) < 1e-25f) c.store = 0;
          c.line.buf[c.line.pos] = in + c.store * c.feedback;
          if (++c.line.pos >= c.line.len) c.line.pos = 0;
          out[ch] += y;
        }
        for (auto& a : ap_[ch]) {
          const float b = a.buf[a.pos];
          a.buf[a.pos] = out[ch] + b * 0.5f;
          if (++a.pos >= a.len) a.pos = 0;
          out[ch] = b - out[ch];
        }
      }
      L = L * dry_ + out[0] * wet1_ + out[1] * wet2_;
      R = R * dry_ + out[1] * wet1_ + out[0] * wet2_;
    }

    L *= outGain_; R *= outGain_;

    if (p.limiter.on) {
      const float peak = std::max(std::fabs(L), std::fabs(R));
      const float target = peak > ceiling_ ? ceiling_ / peak : 1.0f;
      limGain_ = target < limGain_ ? target : target + (limGain_ - target) * limRel_;
      L = std::clamp(L * limGain_, -ceiling_, ceiling_);
      R = std::clamp(R * limGain_, -ceiling_, ceiling_);
    }

    s[2 * i] = sanitize(L);
    s[2 * i + 1] = sanitize(R);
  }
}
}
