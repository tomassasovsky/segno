#pragma once
#include <Adafruit_NeoPixel.h>
#include "pedal_link.h"
struct Rgb { uint8_t r, g, b; };
inline uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return Adafruit_NeoPixel::gamma32(Adafruit_NeoPixel::Color(r, g, b));
}
// `level` dims a colour. Gamma goes on the colour and on the level separately,
// and the two multiply, rounded: scaling before gamma, or truncating, drops a
// mixed colour's weaker channel to 0 first, so a fading yellow went red at the
// dim end. For pure red, green and blue the result is the same as before.
inline uint32_t scaled(uint8_t r, uint8_t g, uint8_t b, uint8_t level) {
  const uint16_t k = Adafruit_NeoPixel::gamma8(level);
  const uint32_t c = rgb(r, g, b);
  return Adafruit_NeoPixel::Color((uint8_t)((((c >> 16) & 0xFF) * k + 127) / 255),
                                  (uint8_t)((((c >> 8) & 0xFF) * k + 127) / 255),
                                  (uint8_t)(((c & 0xFF) * k + 127) / 255));
}

inline Rgb ledColor(uint8_t led) {
  switch (led) {
    case PEDAL_LED_GREEN: return {0, 255, 0};
    case PEDAL_LED_RED: return {255, 0, 0};
    case PEDAL_LED_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}
// The mode pill's colour: rec red, play green, FX blue. Solid, always — this
// pill means the interaction mode and nothing else.
inline Rgb modeColor(uint8_t mode) {
  switch (mode) {
    case PEDAL_MODE_PLAY: return {0, 255, 0};
    case PEDAL_MODE_FX: return {0, 0, 255};
    default: return {255, 0, 0};  // PEDAL_MODE_REC
  }
}
inline Rgb globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN: return {0, 255, 0};
    case PEDAL_GLOBAL_RED: return {255, 0, 0};
    // Yellow, on the owner's call. Equal red and green read lime on these LEDs;
    // green at 235 was matched by eye on the unit (#1064).
    case PEDAL_GLOBAL_AMBER: return {255, 235, 0};
    case PEDAL_GLOBAL_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}
