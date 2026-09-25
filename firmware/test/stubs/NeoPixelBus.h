#ifndef SEGNO_TEST_NEOPIXELBUS_H
#define SEGNO_TEST_NEOPIXELBUS_H

#include <cstdint>
#include <vector>

struct RgbColor {
  RgbColor() {}
  RgbColor(uint8_t r, uint8_t g, uint8_t b) : R(r), G(g), B(b) {}
  RgbColor(uint8_t brightness) : R(brightness), G(brightness), B(brightness) {}
  bool operator==(const RgbColor& other) const {
    return R == other.R && G == other.G && B == other.B;
  }
  bool operator!=(const RgbColor& other) const { return !(*this == other); }
  uint8_t R, G, B;
};

struct NeoGrbFeature {};
struct Rp2040x4Pio1Ws2812xMethod {};

// Model the library's editing buffer, dirty flag and submitted frame. The
// hardware build separately verifies the real PIO/DMA implementation.
template <class Feature, class Method>
class NeoPixelBus {
 public:
  NeoPixelBus(uint16_t count, uint8_t pin)
      : pin(pin), pixels(count), shown(count) {}
  void Begin() { ClearTo(RgbColor(0)); }
  void ClearTo(RgbColor color) {
    for (auto& pixel : pixels) pixel = pack(color);
    Dirty();
  }
  void SetPixelColor(uint16_t index, RgbColor color) {
    if (index < pixels.size()) {
      pixels[index] = pack(color);
      Dirty();
    }
  }
  RgbColor GetPixelColor(uint16_t index) const {
    const uint32_t color = index < pixels.size() ? pixels[index] : 0;
    return RgbColor((uint8_t)(color >> 16), (uint8_t)(color >> 8),
                    (uint8_t)color);
  }
  void Dirty() { dirty_ = true; }
  bool IsDirty() const { return dirty_; }
  void Show() {
    if (!dirty_) return;
    shown = pixels;
    ++showCount;
    dirty_ = false;
  }
  uint16_t PixelCount() const { return (uint16_t)pixels.size(); }

  uint8_t pin;
  std::vector<uint32_t> pixels;
  std::vector<uint32_t> shown;
  unsigned showCount = 0;

 private:
  static uint32_t pack(RgbColor color) {
    return (uint32_t)color.R << 16 | (uint32_t)color.G << 8 | color.B;
  }
  bool dirty_ = false;
};

#endif
