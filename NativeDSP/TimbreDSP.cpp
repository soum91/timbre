#include "TimbreDSP.hpp"
#include "TimbreHRTF.h"
#include "TimbreHRTFSphere.h"
#include <cstring>
#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace timbre {
Coeffs coefficients(const Band& b, double fs) {
  if (!(fs>100) || !std::isfinite(fs)) throw std::invalid_argument("sample rate");
  if (!std::isfinite(b.frequency)||!std::isfinite(b.q)||!std::isfinite(b.gainDB)) throw std::invalid_argument("band");
  const double f=std::clamp(b.frequency,2.0,fs*0.49), q=std::clamp(b.q,0.05,40.0);
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
double curvePeakDB(const Band* bands, size_t count, double fs) {
  if (!(fs > 100) || !bands) return 0;
  Coeffs k[64];
  size_t n = 0;
  for (size_t i = 0; i < count && n < 64; i++) {
    if (!bands[i].enabled) continue;
    try { k[n++] = coefficients(bands[i], fs); } catch (...) {}
  }
  double peak = 0;
  for (int i = 0; i < 400; i++) {
    const double f = 5.0 * std::pow(4000.0, i / 399.0);
    if (f >= fs * 0.49) break;
    const double w = 2 * std::acos(-1.0) * f / fs, c1 = std::cos(w), s1 = std::sin(w), c2 = std::cos(2 * w), s2 = std::sin(2 * w);
    double db = 0;
    for (size_t j = 0; j < n; j++) {
      const double nr = k[j].b0 + k[j].b1 * c1 + k[j].b2 * c2, ni = -(k[j].b1 * s1 + k[j].b2 * s2);
      const double dr = 1 + k[j].a1 * c1 + k[j].a2 * c2, di = -(k[j].a1 * s1 + k[j].a2 * s2);
      db += 10 * std::log10(std::max((nr * nr + ni * ni) / std::max(dr * dr + di * di, 1e-30), 1e-18));
    }
    peak = std::max(peak, db);
  }
  return peak;
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
// Transparent below 90% of the ceiling, then bends smoothly into it.
inline float softClip(float x, float c) {
  const float a = std::fabs(x), knee = 0.9f * c;
  if (a <= knee) return x;
  const float y = knee + (c - knee) * std::tanh((a - knee) / (c - knee));
  return x < 0 ? -y : y;
}
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
  const size_t upCap = static_cast<size_t>(0.03 * fs) + 2, histCap = hrtf::kMaxTaps - 1 + kBlock;
  const size_t limCap = static_cast<size_t>(0.002 * fs) + 2;
  total += preCap + 4 * shortCap + 10 * upCap + kSources * histCap + 4 * kBlock + 3 * limCap;
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
  for (auto& l : upDelay_) take(l, upCap);
  for (auto& src : src_) { src.hist = at; at += histCap; }
  accL_ = at; at += kBlock; accR_ = at; at += kBlock; tmp_ = at; at += kBlock; tmp2_ = at; at += kBlock;
  take(limDelay_[0], limCap); take(limDelay_[1], limCap);
  limWindow_ = at; at += limCap;
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
  for (auto& l : upDelay_) clear(l);
  for (auto& o : upLP_) o.z = 0;
  for (auto& o : topLP_) o.z = 0;
  for (auto& src : src_) std::fill(src.hist, src.hist + hrtf::kMaxTaps - 1 + kBlock, 0.0f);
  clear(limDelay_[0]); clear(limDelay_[1]);
  std::fill(limWindow_, limWindow_ + limDelay_[0].cap, 0.0f);
  limPos_ = 0;
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

  // Immersive
  imAmount_ = static_cast<float>(std::clamp(p.spatial.amount, 0.0, 1.0));
  imSurround_ = static_cast<float>(std::clamp(p.spatial.surround, 0.0, 1.0));
  imHeight_ = static_cast<float>(std::clamp(p.spatial.height, 0.0, 1.0));
  imRoom_ = static_cast<float>(std::clamp(p.spatial.room, 0.0, 1.0));
  {
    // 0-3: decorrelated side/rear ambience, 4-5: height, 6-9: early reflections of the front pair
    const double delaysMs[10] = {11, 13, 19, 23, 5, 6, 7, 9, 15, 18};
    const double cutoffs[10] = {7000, 7000, 4500, 4500, 0, 0, 6000, 6000, 3500, 3500};
    for (int i = 0; i < 10; i++) {
      upDelay_[i].len = std::clamp<size_t>(static_cast<size_t>(std::lround(delaysMs[i] * 0.001 * fs)), 1, upDelay_[i].cap);
      if (cutoffs[i] > 0) upLP_[i].a = onePoleCoeff(cutoffs[i], fs);
    }
    for (auto& o : topLP_) o.a = onePoleCoeff(1500.0, fs);
  }
  loadHRTF();
  const bool immersiveNow = p.spatial.on && p.spatial.mode == 1, immersiveBefore = old.spatial.on && old.spatial.mode == 1;
  if (immersiveNow && (!immersiveBefore || old.spatial.angle != p.spatial.angle || old.spatial.hrtf != p.spatial.hrtf)) {
    for (auto& src : src_) std::fill(src.hist, src.hist + hrtf::kMaxTaps - 1 + kBlock, 0.0f);
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
  limRel_ = static_cast<float>(std::exp(-1.0 / (0.12 * fs)));
  // 1.5 ms lookahead: the gain starts falling before a peak reaches the output.
  limLen_ = std::clamp<size_t>(static_cast<size_t>(0.0015 * fs), 1, limDelay_[0].cap);
  limDelay_[0].len = limDelay_[1].len = limLen_;
  limAtt_ = static_cast<float>(1.0 - std::exp(-1.0 / std::max(1.0, limLen_ / 3.0)));
  if (limPos_ >= limLen_) limPos_ = 0;
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

    if (p.spatial.on && p.spatial.mode != 1) {
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

    s[2 * i] = L;
    s[2 * i + 1] = R;
  }

  if (p.spatial.on && p.spatial.mode == 1) immersive(s, frames);

  for (size_t i = 0; i < frames; i++) {
    float L = s[2 * i] * outGain_, R = s[2 * i + 1] * outGain_;

    if (p.limiter.on) {
      // Lookahead peak limiter: window max over the delay, smooth gain, then a soft knee instead of a hard clip.
      limWindow_[limPos_] = std::max(std::fabs(L), std::fabs(R));
      if (++limPos_ >= limLen_) limPos_ = 0;
      float peak = 0;
      for (size_t k = 0; k < limLen_; k++) peak = std::max(peak, limWindow_[k]);
      const float target = peak > ceiling_ ? ceiling_ / peak : 1.0f;
      limGain_ = target < limGain_ ? limGain_ + (target - limGain_) * limAtt_ : target + (limGain_ - target) * limRel_;
      L = softClip(tick(limDelay_[0], L) * limGain_, ceiling_);
      R = softClip(tick(limDelay_[1], R) * limGain_, ceiling_);
    }

    s[2 * i] = sanitize(L);
    s[2 * i + 1] = sanitize(R);
  }
}

void Effects::loadHRTF() noexcept {
  if (!(fs_ > 0)) return;
  // Nearest measured rate; KEMAR tables exist for 44.1, 48, 88.2 and 96 kHz.
  int r = 0;
  for (int i = 1; i < 4; i++) if (std::fabs(hrtf::kRates[i] - fs_) < std::fabs(hrtf::kRates[r] - fs_)) r = i;
  taps_ = hrtf::kTaps[r];
  sphereRate_ = -1;
  for (int i = 0; i < 2; i++) if (std::fabs(hrtf_sphere::kRates[i] - fs_) < 1000) sphereRate_ = i;
  const int front = std::clamp(static_cast<int>(std::lround((std::clamp(p_.spatial.angle, 10.0, 60.0) - hrtf::kFrontMin) / hrtf::kFrontStep)), 0, hrtf::kFrontCount - 1);
  // Sources: centre, front L/R, side L/R, rear L/R, top-front L/R. Odd indices are on the left.
  const int pos[kSources] = {hrtf::kCentre, front, front, hrtf::kSide, hrtf::kSide, hrtf::kRear, hrtf::kRear, hrtf::kTop, hrtf::kTop};
  const int set = p_.spatial.hrtf == 0 ? 0 : 1;
  for (int k = 0; k < kSources; k++) {
    const float* nearEar = hrtf::kData[set][r][pos[k]][0];
    const float* farEar = hrtf::kData[set][r][pos[k]][1];
    const bool left = k > 0 && (k % 2 == 1);
    src_[k].hR = left ? farEar : nearEar;
    src_[k].hL = left ? nearEar : farEar;
    src_[k].key = -1;
  }
  double e = 0;
  for (size_t i = 0; i < taps_; i++) e += double(src_[2].hR[i]) * src_[2].hR[i] + double(src_[2].hL[i]) * src_[2].hL[i];
  imNorm_ = e > 1e-9 ? static_cast<float>(1.0 / std::sqrt(e)) : 1.0f;
}

// Direction of virtual speaker k relative to the listener's head, mapped to the full-circle table.
bool Effects::sphereFilters(int k, double headYaw, const float** hR, const float** hL, int* key) const noexcept {
  if (sphereRate_ < 0) return false;
  const double angle = std::clamp(p_.spatial.angle, 10.0, 60.0);
  const double azimuth[kSources] = {0, -angle, angle, -90, 90, -135, 135, -45, 45};
  const bool high = k >= 7;
  double rel = azimuth[k] - headYaw;
  rel = std::fmod(rel + 540.0, 360.0) - 180.0;  // wrap to [-180, 180)
  const double mag = std::fabs(rel);
  const int idx = high ? hrtf_sphere::kLevelCount + std::clamp(static_cast<int>(std::lround(mag / hrtf_sphere::kHighStep)), 0, hrtf_sphere::kHighCount - 1)
                       : std::clamp(static_cast<int>(std::lround(mag / hrtf_sphere::kLevelStep)), 0, hrtf_sphere::kLevelCount - 1);
  const bool left = rel < 0 && idx != 0 && idx != hrtf_sphere::kLevelCount;
  const int set = p_.spatial.hrtf == 0 ? 0 : 1;
  const float* right = hrtf_sphere::kData[set][sphereRate_][idx][0];
  const float* leftEar = hrtf_sphere::kData[set][sphereRate_][idx][1];
  *hR = left ? leftEar : right;
  *hL = left ? right : leftEar;
  *key = idx * 2 + (left ? 1 : 0);
  return true;
}

namespace {
// y[i] = sum_k h[k] * x[i - k], where x points at the first new sample and has taps-1 samples of history before it.
inline void convolve(const float* x, const float* h, size_t taps, float* y, size_t n) {
#if defined(__APPLE__)
  vDSP_conv(x - (taps - 1), 1, h + taps - 1, -1, y, 1, n, taps);
#else
  for (size_t i = 0; i < n; i++) {
    float acc = 0;
    for (size_t k = 0; k < taps; k++) acc += h[k] * x[static_cast<std::ptrdiff_t>(i) - static_cast<std::ptrdiff_t>(k)];
    y[i] = acc;
  }
#endif
}
}

void Effects::immersive(float* s, size_t frames) noexcept {
  if (!taps_) return;
  const size_t hist = taps_ - 1;
  const float dry = 1.0f - imAmount_, wet = imAmount_ * imNorm_;
  for (size_t off = 0; off < frames; off += kBlock) {
    const size_t n = std::min(kBlock, frames - off);
    // Upmix stereo to nine speaker feeds.
    for (size_t i = 0; i < n; i++) {
      const float L = s[2 * (off + i)], R = s[2 * (off + i) + 1];
      const float M = 0.5f * (L + R), S = 0.5f * (L - R), C = 0.5f * M;
      float sides[4];
      for (int d = 0; d < 4; d++) {
        upLP_[d].z += upLP_[d].a * (S - upLP_[d].z);
        sides[d] = tick(upDelay_[d], upLP_[d].z);
      }
      topLP_[0].z += topLP_[0].a * (L - topLP_[0].z);
      topLP_[1].z += topLP_[1].a * (R - topLP_[1].z);
      const float tl = tick(upDelay_[4], L - topLP_[0].z), tr = tick(upDelay_[5], R - topLP_[1].z);
      // Early reflections: the front pair bouncing off side walls and the back wall. These are what make
      // headphone sound feel like it is in a room instead of inside your head.
      float refl[4];
      const float srcs[4] = {L, R, L, R};
      for (int d = 0; d < 4; d++) {
        upLP_[6 + d].z += upLP_[6 + d].a * (srcs[d] - upLP_[6 + d].z);
        refl[d] = tick(upDelay_[6 + d], upLP_[6 + d].z);
      }
      const float feeds[kSources] = {
        C, L - 0.5f * C, R - 0.5f * C,
        0.6f * imSurround_ * sides[0] + 0.38f * imRoom_ * refl[0], -0.6f * imSurround_ * sides[1] + 0.38f * imRoom_ * refl[1],
        0.45f * imSurround_ * sides[2] + 0.26f * imRoom_ * refl[2], -0.45f * imSurround_ * sides[3] + 0.26f * imRoom_ * refl[3],
        0.5f * imHeight_ * tl, 0.5f * imHeight_ * tr,
      };
      for (int k = 0; k < kSources; k++) src_[k].hist[hist + i] = feeds[k];
    }
    // Head tracking: follow the head, drift the reference slowly back to it (about 8 s) so the stage
    // re-centres when you turn your whole body, like Apple's head-tracked mode.
    const bool tracking = p_.spatial.headTracking && sphereRate_ >= 0;
    double rel = 0;
    if (!tracking || !headValid_) headSnapped_ = false;
    if (tracking) {
      const double yaw = headValid_ ? (p_.spatial.headInvert ? -headYaw_ : headYaw_) : headRef_;
      if (headValid_ && !headSnapped_) { headRef_ = yaw; headSnapped_ = true; }  // first reading = straight ahead
      double d = std::fmod(yaw - headRef_ + 540.0, 360.0) - 180.0;
      headRef_ += d * std::min(1.0, static_cast<double>(n) / (8.0 * fs_));
      headRef_ = std::fmod(headRef_ + 360.0, 360.0);
      rel = std::fmod(yaw - headRef_ + 540.0, 360.0) - 180.0;
    }
    // Binaural render, crossfading a speaker over one block whenever its filter changes.
    std::fill(accL_, accL_ + n, 0.0f);
    std::fill(accR_, accR_ + n, 0.0f);
    for (int k = 0; k < kSources; k++) {
      Source& src = src_[k];
      const float* x = src.hist + hist;
      const float *newR = src.hR, *newL = src.hL;
      int newKey = src.key;
      if (tracking) sphereFilters(k, rel, &newR, &newL, &newKey);
      const bool fade = newKey != src.key;
      for (int ear = 0; ear < 2; ear++) {
        float* acc = ear == 0 ? accR_ : accL_;
        const float* oldH = ear == 0 ? src.hR : src.hL;
        const float* newH = ear == 0 ? newR : newL;
        convolve(x, oldH, taps_, tmp_, n);
        if (fade && newH != oldH) {
          convolve(x, newH, taps_, tmp2_, n);
          for (size_t i = 0; i < n; i++) {
            const float t = static_cast<float>(i + 1) / static_cast<float>(n);
            acc[i] += tmp_[i] + (tmp2_[i] - tmp_[i]) * t;
          }
        } else {
          for (size_t i = 0; i < n; i++) acc[i] += tmp_[i];
        }
      }
      src.hR = newR; src.hL = newL; src.key = newKey;
      std::memmove(src.hist, src.hist + n, hist * sizeof(float));
    }
    for (size_t i = 0; i < n; i++) {
      float& L = s[2 * (off + i)];
      float& R = s[2 * (off + i) + 1];
      L = L * dry + accL_[i] * wet;
      R = R * dry + accR_[i] * wet;
    }
  }
}
}
