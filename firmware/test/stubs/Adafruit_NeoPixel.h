#ifndef SEGNO_TEST_ADAFRUIT_NEOPIXEL_H
#define SEGNO_TEST_ADAFRUIT_NEOPIXEL_H

// Deterministic Arduino I/O for compiling the actual console sketch on the
// host. Pin levels, time, UART I/O and pixel buffers are simulated; input
// classification and the wire codec remain the production implementation.
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <cassert>
#include <vector>

#define HIGH 1
#define LOW 0
#define INPUT 0
#define OUTPUT 1
#define INPUT_PULLUP 2
#define INPUT_PULLDOWN 3
#define LED_BUILTIN 25
#define CHANGE 0
#define NEO_GRB 0x52
#define NEO_KHZ800 0

namespace fake_arduino {
inline unsigned long now = 0;
inline int analog[32] = {};
inline int digital[32] = {};
inline std::vector<std::vector<uint8_t>> sent;
inline std::deque<uint8_t> received;
}

inline unsigned long millis() { return fake_arduino::now; }
inline int digitalRead(int pin) { return fake_arduino::digital[pin]; }
inline int analogRead(int pin) { return fake_arduino::analog[pin]; }
inline void digitalWrite(int pin, int value) { fake_arduino::digital[pin] = value; }
inline void pinMode(int pin, int mode) {
  if (mode == INPUT_PULLUP) fake_arduino::digital[pin] = HIGH;
  if (mode == INPUT_PULLDOWN) fake_arduino::digital[pin] = LOW;
}
inline void analogReadResolution(int) {}
inline void noInterrupts() {}
inline void interrupts() {}
inline int digitalPinToInterrupt(int pin) { return pin; }
inline void attachInterrupt(int, void (*)(), int) {}
inline void delay(int duration) { fake_arduino::now += duration; }

struct FakeSerial {
  void setTX(int) {}
  void setRX(int) {}
  void begin(unsigned long) {}
  int available() { return (int)fake_arduino::received.size(); }
  int read() {
    if (fake_arduino::received.empty()) return -1;
    const uint8_t byte = fake_arduino::received.front();
    fake_arduino::received.pop_front();
    return byte;
  }
  size_t write(const uint8_t *bytes, size_t length) {
    fake_arduino::sent.emplace_back(bytes, bytes + length);
    return length;
  }
};
inline FakeSerial Serial1;

class Adafruit_NeoPixel {
 public:
  Adafruit_NeoPixel(int count, int pin, int type)
      : pin(pin), type(type), pixels(count), shown(count) {}
  void begin() {}
  void setBrightness(int value) { brightness = value; }
  void show() {
    shown = pixels;
    // Production uses a fixed brightness set before rendering. Model its
    // transmitted channel scale while retaining logical colors for reads.
    if (brightness != 255) for (auto &pixel : shown) {
      const uint16_t scale = brightness + 1;
      pixel = Color(((pixel >> 16) & 255) * scale >> 8,
                    ((pixel >> 8) & 255) * scale >> 8,
                    (pixel & 255) * scale >> 8);
    }
    ++showCount;
  }
  void clear() { for (auto &pixel : pixels) pixel = 0; }
  void setPixelColor(int index, uint32_t color) {
    assert(index >= 0 && (size_t)index < pixels.size());
    pixels[index] = color;
  }
  uint32_t getPixelColor(int index) const {
    assert(index >= 0 && (size_t)index < pixels.size());
    return pixels[index];
  }
  int pin;
  int type;
  std::vector<uint32_t> pixels;
  std::vector<uint32_t> shown;
  unsigned showCount = 0;
  int brightness = 255;
  static uint32_t Color(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)r << 16 | (uint32_t)g << 8 | b;
  }
  // A nonlinear fake makes an accidental extra gamma pass observable. Tests
  // assert rendered behavior, not the device library's exact lookup table.
  static uint8_t gamma8(uint8_t x) { return (uint8_t)((x * (uint16_t)x + 127) / 255); }
  static uint32_t gamma32(uint32_t color) {
    return (uint32_t)gamma8((uint8_t)(color >> 24)) << 24 |
        Color(gamma8((uint8_t)(color >> 16)), gamma8((uint8_t)(color >> 8)),
              gamma8((uint8_t)color));
  }
};

#endif
