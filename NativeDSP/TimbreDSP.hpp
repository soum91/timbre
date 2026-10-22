#pragma once
#include <array>
#include <cstddef>
#include <vector>
namespace timbre {
enum class FilterType { Peaking, LowShelf, HighShelf, LowPass, HighPass, BandPass, Notch, AllPass };
struct Band { bool enabled=true; FilterType type=FilterType::Peaking; double frequency=1000, gainDB=0, q=1; };
struct Coeffs { double b0,b1,b2,a1,a2; };
Coeffs coefficients(const Band& band, double sampleRate);
// Highest boost (dB) of the combined response of the enabled bands, sampled 5 Hz..20 kHz.
double curvePeakDB(const Band* bands, size_t count, double sampleRate);
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
// mode 0: classic interaural delay/head shadow; mode 1: Immersive (stereo upmix to 9 virtual speakers rendered with KEMAR HRTFs).
// hrtf 0: KEMAR diffused (flatter, "Natural"); 1: KEMAR normal (stronger localisation, "Precise"). room adds early reflections.
// headTracking rotates the virtual speakers against the listener's head yaw (see Effects::setHeadYaw).
struct SpatialParams { bool on=false; double angle=30, amount=0.8, distance=1; int mode=0; double surround=0.5, height=0.3; int hrtf=1; double room=0.4; bool headTracking=false, headInvert=false; };
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
  // Head yaw in degrees, positive = turned right. Call before process(); invalid data holds the stage still.
  void setHeadYaw(double degrees, bool valid) noexcept { headYaw_ = degrees; headValid_ = valid; }
private:
  struct Line { float* buf=nullptr; size_t cap=0, len=1, pos=0; };
  struct Comb { Line line; float store=0, feedback=0, damp1=0, damp2=1; };
  struct OnePole { float a=1, z=0; };
  static constexpr int kSources = 9;
  static constexpr size_t kBlock = 256;
  // hR/hL: impulse responses into the right and left ear for this virtual speaker's current direction.
  struct Source { float* hist=nullptr; const float* hR=nullptr; const float* hL=nullptr; int key=-1; };
  bool sphereFilters(int k, double headYaw, const float** hR, const float** hL, int* key) const noexcept;
  void loadHRTF() noexcept;
  void immersive(float* interleaved, size_t frames) noexcept;
  Source src_[kSources];
  size_t taps_=0;
  float* accL_=nullptr; float* accR_=nullptr; float* tmp_=nullptr; float* tmp2_=nullptr;
  int sphereRate_=-1;          // index into the head-tracking table for this sample rate, or -1
  double headYaw_=0, headRef_=0; bool headValid_=false, headSnapped_=false;
  Line upDelay_[10]; OnePole upLP_[10]; OnePole topLP_[2];
  Line limDelay_[2]; float* limWindow_=nullptr; size_t limLen_=1, limPos_=0; float limAtt_=0;
  float imAmount_=0, imSurround_=0, imHeight_=0, imRoom_=0, imNorm_=1;
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
