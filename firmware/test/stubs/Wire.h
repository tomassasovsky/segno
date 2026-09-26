#ifndef SEGNO_TEST_WIRE_H
#define SEGNO_TEST_WIRE_H

#include <Adafruit_NeoPixel.h>
#include <array>
#include <functional>

namespace fake_wire {
inline std::array<uint8_t, 256> registers{};
inline unsigned transfers = 0;
inline unsigned requests = 0;
inline unsigned fail_transfer = 0;
inline unsigned short_request = 0;
inline unsigned negative_request = 0;
inline uint8_t address = 0;
inline uint8_t sda = 255, scl = 255;
inline uint32_t clock = 0, timeout = 0;
inline unsigned register_writes = 0;
inline std::function<void(unsigned)> before_request;
inline void reset() {
  registers.fill(0);
  transfers = requests = fail_transfer = short_request = negative_request = 0;
  register_writes = 0;
  before_request = {};
}
}

class TwoWire {
 public:
  bool setSDA(uint8_t pin) { fake_wire::sda = pin; return true; }
  bool setSCL(uint8_t pin) { fake_wire::scl = pin; return true; }
  void begin() { tx.clear(); rx.clear(); }
  void end() { tx.clear(); rx.clear(); }
  void setClock(uint32_t value) { fake_wire::clock = value; }
  void setTimeout(uint32_t value, bool) { fake_wire::timeout = value; }
  void beginTransmission(uint8_t address) { fake_wire::address = address; tx.clear(); }
  size_t write(uint8_t value) { tx.push_back(value); return 1; }
  uint8_t endTransmission(bool) {
    ++fake_wire::transfers;
    if (tx.size() > 1) ++fake_wire::register_writes;
    if (!tx.empty()) reg = tx[0];
    return fake_wire::fail_transfer == fake_wire::transfers ? 2 : 0;
  }
  size_t requestFrom(uint8_t address, size_t count, bool) {
    fake_wire::address = address;
    ++fake_wire::requests;
    if (fake_wire::before_request) fake_wire::before_request(fake_wire::requests);
    rx.clear();
    position = 0;
    if (fake_wire::short_request == fake_wire::requests && count) --count;
    for (size_t i = 0; i < count; ++i) rx.push_back(fake_wire::registers[reg + i]);
    return count;
  }
  int read() {
    if (fake_wire::negative_request == fake_wire::requests || position == rx.size()) return -1;
    return rx[position++];
  }
 private:
  uint8_t reg = 0;
  size_t position = 0;
  std::vector<uint8_t> tx, rx;
};
inline TwoWire Wire;

#endif
