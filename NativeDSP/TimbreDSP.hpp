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
}
