#ifndef SEGNO_TEST_PICO_TIME_H
#define SEGNO_TEST_PICO_TIME_H

#include <Adafruit_NeoPixel.h>
namespace fake_pico_time {
inline uint32_t waited_us = 0;
}
inline void busy_wait_us_32(uint32_t duration) {
  fake_pico_time::waited_us += duration;
  fake_arduino::now += duration / 1000;
}

#endif
