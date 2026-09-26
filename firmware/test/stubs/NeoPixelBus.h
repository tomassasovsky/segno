#pragma once
#include <Adafruit_NeoPixel.h>
struct RgbColor {
  uint8_t R, G, B;
  RgbColor(uint8_t value) : R(value), G(value), B(value) {}
  RgbColor(uint8_t r, uint8_t g, uint8_t b) : R(r), G(g), B(b) {}
};
struct NeoGrbFeature {};
struct Rp2040x4Pio1Ws2812xMethod {};
namespace fake_pixels {
inline std::vector<uint32_t> values[32];
inline unsigned shows[32] = {};
}
template<class Feature, class Method> class NeoPixelBus {
 public:
  NeoPixelBus(uint16_t count, uint8_t pin) : pin_(pin) { fake_pixels::values[pin].resize(count); }
  void Begin() {}
  void SetPixelColor(uint16_t index, RgbColor value) {
    fake_pixels::values[pin_].at(index) = (uint32_t)value.R << 16 | (uint32_t)value.G << 8 | value.B;
  }
  void ClearTo(RgbColor value) {
    for (size_t i = 0; i < fake_pixels::values[pin_].size(); ++i) SetPixelColor(i, value);
  }
  void Dirty() {}
  void Show() { ++fake_pixels::shows[pin_]; }
 private:
  uint8_t pin_;
};
