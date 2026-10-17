// Host stand-in for arduino-pico's TwoWire: an I2C bus with nothing on it
// unless a test attaches a device. Register writes and reads reach the
// device's callbacks; with none attached every address NACKs.
#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

struct FakeI2cDevice {
  int (*write)(uint8_t reg, const uint8_t *data, uint8_t len) = nullptr;
  int (*read)(uint8_t reg, uint8_t *data, uint8_t len) = nullptr;
};

class TwoWire {
 public:
  FakeI2cDevice device;

  void setSDA(int) {}
  void setSCL(int) {}
  void setClock(uint32_t) {}
  void setTimeout(uint32_t = 25, bool = false) {}
  void begin() {}
  void beginTransmission(uint8_t) { out_.clear(); }
  size_t write(uint8_t byte) {
    out_.push_back(byte);
    return 1;
  }
  size_t write(const uint8_t *bytes, size_t length) {
    out_.insert(out_.end(), bytes, bytes + length);
    return length;
  }
  uint8_t endTransmission(bool = true) {
    if (!device.write || out_.empty()) return 2;  // address NACK
    reg_ = out_[0];
    if (out_.size() > 1 && device.write(reg_, out_.data() + 1, (uint8_t)(out_.size() - 1)))
      return 3;
    return 0;
  }
  size_t requestFrom(uint8_t, size_t quantity, bool = true) {
    in_.assign(quantity, 0);
    in_pos_ = 0;
    if (!device.read || device.read(reg_, in_.data(), (uint8_t)quantity)) {
      in_.clear();
      return 0;
    }
    return quantity;
  }
  int read() { return in_pos_ < in_.size() ? in_[in_pos_++] : -1; }

 private:
  std::vector<uint8_t> out_, in_;
  size_t in_pos_ = 0;
  uint8_t reg_ = 0;
};

inline TwoWire Wire;
