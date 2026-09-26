#pragma once
#include <NeoPixelBus.h>

// PIO + DMA leaves UART and encoder interrupts running for all 80 pixels.
// NeoPixel::show() would mask them for 2.4 ms, longer than a PIO RX FIFO.
class PanelPixels {
 public:
  PanelPixels(uint16_t count, uint8_t pin) : pixels_(count, pin) {}
  void begin() { pixels_.Begin(); }
  void setBrightness(uint8_t value) { brightness_ = (uint16_t)value + 1; }
  void setPixelColor(uint16_t index, uint32_t color) {
    pixels_.SetPixelColor(index, RgbColor(scale(color >> 16), scale(color >> 8), scale(color)));
  }
  void clear() { pixels_.ClearTo(RgbColor(0)); }
  void show() { pixels_.Dirty(); pixels_.Show(); }
 private:
  uint8_t scale(uint8_t value) const { return (uint16_t)value * brightness_ >> 8; }
  NeoPixelBus<NeoGrbFeature, Rp2040x4Pio1Ws2812xMethod> pixels_;
  uint16_t brightness_ = 256;
};
