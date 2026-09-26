#ifndef SEGNO_TEST_ADAFRUIT_NEOPIXEL_H
#define SEGNO_TEST_ADAFRUIT_NEOPIXEL_H

// Deterministic Arduino I/O for compiling the actual console sketch on the
// host. Only pin levels, time and outgoing UART bytes are simulated; input
// classification and the wire codec remain the production implementation.
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <vector>

#define HIGH 1
#define LOW 0
#define INPUT 0
#define OUTPUT 1
#define INPUT_PULLUP 2
#define INPUT_PULLDOWN 3
#define LED_BUILTIN 25
#define CHANGE 0
#define NEO_GRB 0
#define NEO_KHZ800 0

static const uint8_t D0 = 26, D1 = 27, D2 = 28, D3 = 5, D9 = 4, D10 = 3;
struct FakeRp2040 { uint32_t hwrand32() { return 0x1234; } };
inline FakeRp2040 rp2040;

namespace fake_arduino {
inline unsigned long now = 0;
inline int analog[32] = {};
inline int digital[32] = {};
inline std::vector<std::vector<uint8_t>> sent;
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
  std::deque<uint8_t> received;
  void setTX(int) {}
  void setRX(int) {}
  void begin(unsigned long) {}
  int available() { return received.size(); }
  int read() {
    if (received.empty()) return -1;
    const uint8_t value = received.front(); received.pop_front(); return value;
  }
  size_t write(const uint8_t *bytes, size_t length) {
    fake_arduino::sent.emplace_back(bytes, bytes + length);
    return length;
  }
};
inline FakeSerial Serial1;

namespace fake_neopixels {
inline std::map<int, std::vector<uint32_t>> values;
}

class Adafruit_NeoPixel {
 public:
  Adafruit_NeoPixel(int count, int pin, int) : pin_(pin) {
    fake_neopixels::values[pin].resize(count);
  }
  void begin() {}
  void setBrightness(int) {}
  void show() {}
  void clear() { for (auto &color : fake_neopixels::values[pin_]) color = 0; }
  void setPixelColor(int pixel, uint32_t color) {
    fake_neopixels::values[pin_].at(pixel) = color;
  }
  static uint32_t Color(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)r << 16 | (uint32_t)g << 8 | b;
  }
  static uint32_t gamma32(uint32_t color) { return color; }
  static uint8_t gamma8(uint8_t x) { return x; }
 private:
  int pin_;
};

#endif
