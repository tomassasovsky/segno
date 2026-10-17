#pragma once
#include <Adafruit_NeoPixel.h>
#include <deque>
struct SerialPIO {
  SerialPIO(int txPin, int rxPin, size_t) : tx(txPin), rx(rxPin) {}
  void begin(unsigned long) {}
  int available() const { return received.size(); }
  int read() { if (received.empty()) return -1; const uint8_t byte = received.front(); received.pop_front(); return byte; }
  size_t write(const uint8_t *data, size_t size) { sent.emplace_back(data, data + size); return size; }
  int tx, rx;
  std::deque<uint8_t> received;
  std::vector<std::vector<uint8_t>> sent;
};
