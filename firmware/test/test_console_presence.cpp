#include <cstdio>
#include <cstdlib>
#include "../console_board/console_presence.h"

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
    std::exit(1); \
  } \
} while (0)

int main() {
  // Demonstrate the regression on the model before exercising production.
  gpio_init(19);
  gpio_pull_down(19);
  fake_arduino::digital[19] = 1;
  CHECK(gpio_get(19), "an empty jack drives high");
  fake_arduino::digital[19] = 0;
  CHECK(gpio_get(19), "continuous IE reproduces the A2 held-high fault");

  console_presence_begin(19);
  CHECK(!fake_gpio::enabled[19], "startup must leave IE disabled");
  CHECK(fake_gpio::pulldown[19], "startup must leave the pull-down enabled");
  CHECK(fake_pico_time::waited_us >= 1000, "startup must allow discharge");
  CHECK(!console_presence_read(19), "warm restart must clear the old latch");

  fake_arduino::digital[19] = 1;
  CHECK(console_presence_read(19), "empty jack must read high");
  CHECK(!fake_gpio::enabled[19], "IE must be disabled immediately after high");
  fake_arduino::digital[19] = 0;
  CHECK(!console_presence_read(19), "plugging in must read low after a high");
  CHECK(!fake_gpio::enabled[19], "IE must be disabled immediately after low");
  CHECK(fake_sync::interrupts_enabled, "a normal call must restore interrupts");

  fake_sync::interrupts_enabled = false;
  console_presence_begin(22);
  fake_arduino::digital[22] = 1;
  CHECK(console_presence_read(22), "second jack must sample independently");
  CHECK(!console_presence_read(19), "reading jack two must not alter jack one");
  CHECK(!fake_sync::interrupts_enabled, "a masked caller must stay masked");
  CHECK(fake_gpio::writes == 0, "presence must never be configured as output");
  CHECK(!fake_gpio::enabled[22], "second jack must also leave IE disabled");
  std::puts("Console presence E9 sequence: ALL PASSED");
}
