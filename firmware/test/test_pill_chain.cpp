#include <cstdio>
#include <cstdlib>
#include "../pill_chain_test/pill_chain_test.ino"
#define CHECK(x, msg) do { if (!(x)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); std::exit(1); } } while (0)

static void send(const char* text) {
  for (const char* p = text; *p; ++p) Serial1.received.push_back(*p);
  loop();
}
static bool dark(int pin) {
  for (uint32_t color : fake_neopixels::values[pin]) if (color) return false;
  return true;
}
int main() {
  setup();
  CHECK(fake_neopixels::values[18].size() == 80 && dark(18) && dark(12), "all pixels boot dark");
  send("chain full\n"); CHECK(dark(18), "unknown high-load command cannot light LEDs");
  fake_arduino::now = 100;
  send("chain run\n");
  // Sample the entire real renderer at every transition, including both passes.
  for (uint32_t ms = 0; ms < 100000; ms += 100) {
    fake_arduino::now = 100 + ms;
    loop();
    const auto& pixels = fake_neopixels::values[18];
    const unsigned group = (ms / 5000) % 10, phase = ms % 5000;
    unsigned lit = 0;
    for (unsigned i = 0; i < 80; ++i) if (pixels[i]) {
      ++lit;
      CHECK(i / 8 == group, "only intended pill lights");
      CHECK(pixels[i] == 0x200000 || pixels[i] == 0x002000 || pixels[i] == 0x000020,
            "single color channel capped at32");
    }
    CHECK(lit == (phase < 3000 ? 8U : phase < 4600 ? 1U : 0U), "bounded load at every transition");
    CHECK(dark(12), "ring remains dark");
    if (phase < 3000)
      CHECK(pixels[group * 8] == (phase < 1000 ? 0x200000U : phase < 2000 ? 0x002000U : 0x000020U),
            "red green blue sequence");
    else if (phase < 4600) {
      const unsigned physical = (phase - 3000) / 200;
      CHECK(pixels[group * 8 + (group < 8 ? 7 - physical : physical)] == 0x002000,
            "left-to-right chase accounts for each row's input end");
    }
    if (ms == 99000) send("chain run\n");
  }
  fake_arduino::now = 100100; loop();
  CHECK(!running && dark(18), "host-independent100second shutoff; repeated run cannot extend it");
  send("chain run\n"); CHECK(!dark(18), "new run can start after timeout");
  send("chain off\n"); CHECK(dark(18), "UART off blanks immediately");
  send("chain run\n"); fake_arduino::digital[3] = LOW; loop();
  CHECK(!running && dark(18), "physical STOP blanks immediately");
  fake_arduino::digital[3] = HIGH;
  fake_arduino::now = 0xffffff00UL;
  send("chain run\n"); fake_arduino::now = 0x000185a0UL; loop();
  CHECK(!running && dark(18), "shutoff also survives timer wrap");
  std::puts("Pill chain diagnostic: ALL PASSED");
}
