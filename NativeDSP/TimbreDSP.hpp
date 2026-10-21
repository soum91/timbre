#pragma once
#include <array>
#include <cstddef>
#include <vector>
namespace timbre {
enum class FilterType { Peaking, LowShelf, HighShelf, LowPass, HighPass, BandPass, Notch, AllPass };
struct Band { bool enabled=true; FilterType type=FilterType::Peaking; double frequency=1000, gainDB=0, q=1; };
struct Coeffs { double b0,b1,b2,a1,a2; };
Coeffs coefficients(const Band& band, double sampleRate);
class StereoEQ {
public:
  explicit StereoEQ(double sampleRate);
  void configure(const std::vector<Band>& bands, double preampDB);
  void process(float* interleavedStereo, size_t frames) noexcept;
  void reset() noexcept;
private:
  struct State { double z1=0,z2=0; };
  struct Stage { Coeffs coeff; std::array<State,2> state; };
  double sampleRate_, gain_=1;
  std::vector<Stage> stages_;
};

// Post-EQ effects chain: compressor -> crossfeed -> spatial -> stereo -> reverb -> output -> limiter.
// All memory is allocated in the constructor. prepare/configure/process never allocate.
struct CompressorParams { bool on=false; double threshold=-24, knee=6, ratio=3, attack=10, release=150, makeup=0; };
struct CrossfeedParams { bool on=false; double level=-6, cutoff=700, delay=0.3; };
struct WidthParams { bool on=false; double width=1, balance=0; bool mono=false, swap=false; };
struct SpatialParams { bool on=false; double angle=30, amount=0.8, distance=1; };
struct ReverbParams { bool on=false; double decay=1.8, predelay=20, damping=6000, width=1, mix=0.25; };
struct LimiterParams { bool on=true; double ceiling=-1; };
struct EffectsParams {
  double outputDB=0;
  CompressorParams comp; CrossfeedParams crossfeed; WidthParams width;
  SpatialParams spatial; ReverbParams reverb; LimiterParams limiter;
};
bool effectsActive(const EffectsParams& p) noexcept;

class Effects {
public:
  static constexpr double kMaxSampleRate = 96000;
  Effects();
  Effects(const Effects&) = delete;
  Effects& operator=(const Effects&) = delete;
  bool prepare(double sampleRate) noexcept;   // false when the rate is unsupported
  void configure(const EffectsParams& p) noexcept;
  void reset() noexcept;
  void process(float* interleavedStereo, size_t frames) noexcept;
  bool ready() const noexcept { return ready_; }
private:
  struct Line { float* buf=nullptr; size_t cap=0, len=1, pos=0; };
  struct Comb { Line line; float store=0, feedback=0, damp1=0, damp2=1; };
  struct OnePole { float a=1, z=0; };
  static float tick(Line& l, float x) noexcept;
  static void clear(Line& l) noexcept;
  void clearReverb() noexcept;
  std::vector<float> memory_;
  double fs_=0; bool ready_=false;
  EffectsParams p_{};
  Comb comb_[2][8]; Line ap_[2][4]; Line pre_;
  Line xfDelay_[2]; OnePole xfLP_[2]; float xfGain_=0, xfNorm_=1;
  Line spDelay_[2]; OnePole spLP_[2]; float spGain_=0, spNorm_=1;
  float wet1_=0, wet2_=0, dry_=1;
  float compAtt_=0, compRel_=0, compEnv_=0;
  float width_=1, balL_=1, balR_=1;
  float outGain_=1, ceiling_=1, limGain_=1, limRel_=0;
};
}
