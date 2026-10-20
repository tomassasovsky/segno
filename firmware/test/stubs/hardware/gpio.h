#ifndef SEGNO_TEST_HARDWARE_GPIO_H
#define SEGNO_TEST_HARDWARE_GPIO_H

#include <Adafruit_NeoPixel.h>

#define GPIO_IN false

namespace fake_gpio {
inline bool enabled[32] = {};
inline bool latched[32] = {};
inline bool pulldown[32] = {};
inline bool output[32] = {};
inline unsigned reads = 0;
inline unsigned writes = 0;
}

inline void gpio_init(unsigned pin) {
  fake_gpio::enabled[pin] = true;
  fake_gpio::output[pin] = false;
}
inline void gpio_set_dir(unsigned pin, bool output) {
  fake_gpio::output[pin] = output;
  if (output) ++fake_gpio::writes;
}
inline void gpio_set_input_enabled(unsigned pin, bool enabled) {
  fake_gpio::enabled[pin] = enabled;
  // Model the E9 hold state only. This proves the sequence, not analogue
  // settling time, which remains a test of the assembled jack and cable.
  if (!enabled) fake_gpio::latched[pin] = false;
}
inline void gpio_pull_down(unsigned pin) { fake_gpio::pulldown[pin] = true; }
inline void gpio_disable_pulls(unsigned pin) { fake_gpio::pulldown[pin] = false; }
inline bool gpio_get(unsigned pin) {
  ++fake_gpio::reads;
  if (!fake_gpio::enabled[pin]) return false;
  if (fake_arduino::digital[pin]) fake_gpio::latched[pin] = true;
  return fake_arduino::digital[pin] || fake_gpio::latched[pin];
}

#endif
