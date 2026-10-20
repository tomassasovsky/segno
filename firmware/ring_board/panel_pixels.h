#pragma once
#include <NeoPixelBus.h>

// PIO + DMA leaves UART and encoder interrupts running during a push.
// NeoPixel::show() masks them for the whole strip, longer than a PIO RX FIFO
// holds at 115200 baud.
class PanelPixels {
 public:
  PanelPixels(uint16_t count, uint8_t pin) : pixels_(count, pin) {}
  void begin() { pixels_.Begin(); }
  void setPixelColor(uint16_t index, uint32_t color) {
    pixels_.SetPixelColor(index, RgbColor((uint8_t)(color >> 16), (uint8_t)(color >> 8), (uint8_t)color));
  }
  void clear() { pixels_.ClearTo(RgbColor(0)); }
  uint32_t getPixelColor(uint16_t index) const {
    const RgbColor c = pixels_.GetPixelColor(index);
    return (uint32_t)c.R << 16 | (uint32_t)c.G << 8 | c.B;
  }
  void show() { pixels_.Dirty(); pixels_.Show(); }
 private:
  NeoPixelBus<NeoGrbFeature, Rp2040x4Pio1Ws2812xMethod> pixels_;
};
