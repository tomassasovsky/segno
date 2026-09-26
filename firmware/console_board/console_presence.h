#ifndef SEGNO_CONSOLE_PRESENCE_H
#define SEGNO_CONSOLE_PRESENCE_H

#include <stdint.h>
#include <hardware/gpio.h>
#include <hardware/sync.h>
#include <pico/time.h>

// RP2350-E9: the A2 pad input buffer can supply enough leakage to defeat
// an internal pull-down after the jack's normal contact opens. Raspberry Pi
// specifies keeping IE off between software samples (RP2350 datasheet E9).
// This is safe on later silicon too. Do not replace it with an output-low
// pulse: the empty jack is connected to the analogue tip through R21/R22.
static inline void console_presence_begin(uint8_t pin) {
  const uint32_t saved = save_and_disable_interrupts();
  gpio_init(pin);
  gpio_set_dir(pin, GPIO_IN);
  gpio_set_input_enabled(pin, false);
  gpio_pull_down(pin);
  restore_interrupts(saved);
  // Clear a latch left by a warm restart before the very first sample. The
  // normal 10 ms CTRL sample interval then provides the off time each read.
  busy_wait_us_32(1000);
}

// True means HIGH (empty); the sketch retains its 50 ms presence debounce.
static inline bool console_presence_read(uint8_t pin) {
  const uint32_t saved = save_and_disable_interrupts();
  gpio_set_input_enabled(pin, true);
  const bool high = gpio_get(pin);
  gpio_set_input_enabled(pin, false);
  restore_interrupts(saved);
  return high;
}

#endif
