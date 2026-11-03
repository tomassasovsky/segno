/* The light sensor's probe and smoothing (ambient_light.c, #1564), run on the
 * host as the board runs them. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "ambient_light.h"
#include "pedal_link.h"

#define AMBIENT_ADC_MAX 4095u

#define CHECK(condition, message)                                       \
  do {                                                                  \
    if (!(condition)) {                                                 \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
      exit(1);                                                          \
    }                                                                   \
  } while (0)

/* The tests speak in ADC counts: the board knows nothing of lux. */
static uint16_t counts_at(float counts) {
  return counts > (float)AMBIENT_ADC_MAX ? (uint16_t)AMBIENT_ADC_MAX : (uint16_t)(counts + 0.5f);
}

/* One second of steady readings. */
static void second(ambient_light *a, uint16_t counts) {
  for (unsigned i = 0; i < AMBIENT_WINDOW; ++i) ambient_light_sample(a, counts);
}

static ambient_light fitted_at(float counts) {
  ambient_light a;
  ambient_light_init(&a);
  ambient_light_probe(&a, (uint16_t)(counts_at(counts) + 172), counts_at(counts));
  second(&a, counts_at(counts));
  return a;
}

static float counts_of(uint8_t level) {
  return powf(2.0f, (float)level / (float)PEDAL_AMBIENT_STEPS_PER_DOUBLING);
}

static void test_scale(void) {
  /* 16 steps per doubling of the reading; one count or less is 0; the top
   * of the range is 3500 counts. */
  CHECK(fabsf(ambient_light_level_of(1024.0f) - 160.0f) < 0.01f, "1024 counts is not level 160");
  CHECK(ambient_light_level_of(1.0f) == 0.0f, "one count is not level 0");
  const uint8_t top = ambient_light_top_level();
  CHECK(top == 188, "the top of the range moved");
  CHECK(fabsf(counts_of(top) - 3500.0f) < 100.0f, "the top is not about 3500 counts");
  CHECK(ambient_light_level_of(4095.0f) == ambient_light_level_of(AMBIENT_TOP_COUNTS),
        "a saturated reading is not capped at the top");
}

static void test_probe(void) {
  /* Nothing on J22: the pin follows both pulls. */
  CHECK(!ambient_light_probe_fitted(4095, 0), "an open pin reads as fitted");
  CHECK(!ambient_light_probe_fitted(3950, 150), "an open pin near the rails reads as fitted");
  /* Weak pad pulls against the ADC's sampling load fall well short of the
   * rails and still read as open. */
  CHECK(!ambient_light_probe_fitted(3100, 900), "an open pin on weak pulls reads as fitted");
  /* The largest load the docs allow, 22 k, in a bright room: the pulls move
   * it about 1 V apart, and it is still a sensor. */
  CHECK(ambient_light_probe_fitted(3250, 1950), "a 22 k load reads as missing");
  /* A pin shorted to ground stays there with the pull-up on. */
  CHECK(!ambient_light_probe_fitted(10, 0), "a grounded pin reads as fitted");
  /* Fitted, in the dark: the 2.2 k holds a 50 k pull-up to ~0.14 V, and a
   * 1 k swapped in holds an 80 k one to ~0.04 V. */
  CHECK(ambient_light_probe_fitted(172, 0), "a dark sensor reads as missing");
  CHECK(ambient_light_probe_fitted(50, 0), "a dark sensor on 1 k reads as missing");
  /* Fitted, in a room, and at the top of the range: both pulls barely move it. */
  CHECK(ambient_light_probe_fitted(counts_at(300) + 300, counts_at(300) - 20),
        "a lit sensor reads as missing");
  CHECK(ambient_light_probe_fitted(3990, 3900), "a saturated sensor reads as missing");
}

static void test_no_sensor(void) {
  ambient_light a;
  ambient_light_init(&a);
  CHECK(!ambient_light_ready(&a), "ready before any probe");
  second(&a, 2048);
  CHECK(!ambient_light_ready(&a), "a reading before the probe counted");
  ambient_light_probe(&a, 4095, 0);
  CHECK(ambient_light_ready(&a), "an empty J22 is not reported at once");
  second(&a, 2048);
  CHECK(ambient_light_sensor(&a) == PEDAL_AMBIENT_NONE && ambient_light_level(&a) == 0,
        "an open pin's readings reached the level");
  uint8_t frame[PEDAL_LINK_MAX_FRAME];
  CHECK(pedal_link_encode_ambient(ambient_light_sensor(&a), ambient_light_level(&a), frame) == 6,
        "the no-sensor report does not encode");
}

static void test_first_second_and_top(void) {
  ambient_light a;
  ambient_light_init(&a);
  ambient_light_probe(&a, 400, 50);
  CHECK(!ambient_light_ready(&a), "a fitted sensor reported before its first second");
  second(&a, counts_at(200.0f));
  CHECK(ambient_light_ready(&a) && ambient_light_sensor(&a) == PEDAL_AMBIENT_READING,
        "the first second is not reported");
  CHECK(fabsf(counts_of(ambient_light_level(&a)) - 200.0f) < 10.0f, "the first second is not 200 counts");

  ambient_light bright = fitted_at(5000.0f);
  CHECK(ambient_light_sensor(&bright) == PEDAL_AMBIENT_ABOVE &&
            ambient_light_level(&bright) == ambient_light_top_level(),
        "daylight is not reported as the top of the range");
  /* Leaving the top follows the median, as reaching it does: two seconds
   * back in range change nothing, the third does. */
  for (int i = 0; i < 4; ++i) second(&bright, counts_at(5000.0f));
  for (int i = 0; i < 2; ++i) second(&bright, counts_at(2000.0f));
  CHECK(ambient_light_sensor(&bright) == PEDAL_AMBIENT_ABOVE, "two seconds left the top");
  second(&bright, counts_at(2000.0f));
  CHECK(ambient_light_sensor(&bright) == PEDAL_AMBIENT_READING, "the median back in range is still the top");
  ambient_light dark = fitted_at(0.0f);
  CHECK(ambient_light_sensor(&dark) == PEDAL_AMBIENT_READING && ambient_light_level(&dark) == 0,
        "darkness is not level 0");
}

/* A shadow or a strobe hit shorter than half the median window never moves
 * the level. */
static void test_short_events_are_ignored(void) {
  ambient_light a = fitted_at(150.0f);
  const uint8_t before = ambient_light_level(&a);
  for (int i = 0; i < 6; ++i) second(&a, counts_at(150.0f));
  CHECK(ambient_light_level(&a) == before, "steady light moved the level");
  for (int event = 0; event < 2; ++event) {
    second(&a, counts_at(event ? 4000.0f : 2.0f));  /* one second: a hand, a strobe */
    second(&a, counts_at(event ? 4000.0f : 2.0f));  /* two */
    for (int i = 0; i < 8; ++i) {
      second(&a, counts_at(150.0f));
      CHECK(ambient_light_level(&a) == before, "a two-second event moved the level");
    }
  }
}

/* Light that hovers around a level does not toggle it. */
static void test_hysteresis(void) {
  ambient_light a = fitted_at(100.0f);
  const uint8_t before = ambient_light_level(&a);
  for (int i = 0; i < 60; ++i) second(&a, counts_at(i % 2 ? 112.0f : 90.0f));
  CHECK(ambient_light_level(&a) == before, "light within the hysteresis moved the level");
}

/* A real change lands within seconds, and in one step per change. */
static void test_a_real_change_follows(void) {
  ambient_light a = fitted_at(300.0f);
  int changes = 0, seconds_to_settle = -1;
  uint8_t last = ambient_light_level(&a);
  for (int i = 0; i < 30; ++i) {
    second(&a, counts_at(5.0f));  /* the house lights go down */
    if (ambient_light_level(&a) != last) {
      ++changes;
      last = ambient_light_level(&a);
    }
    if (seconds_to_settle < 0 && fabsf(counts_of(last) - 5.0f) < 1.5f) seconds_to_settle = i + 1;
  }
  CHECK(seconds_to_settle >= 3 && seconds_to_settle <= 15, "a dark stage takes too long or too short");
  CHECK(changes <= 10, "the level steps too often on the way down");
}

/* A lead plugged in or pulled needs two probes to change the verdict, and a
 * changed verdict starts the smoothing over. */
static void test_verdict_needs_two_probes(void) {
  ambient_light a = fitted_at(100.0f);
  ambient_light_probe(&a, 4095, 0);
  CHECK(ambient_light_sensor(&a) != PEDAL_AMBIENT_NONE, "one open probe dropped the sensor");
  ambient_light_probe(&a, 400, 300);
  ambient_light_probe(&a, 4095, 0);
  CHECK(ambient_light_sensor(&a) != PEDAL_AMBIENT_NONE, "two non-consecutive probes dropped it");
  ambient_light_probe(&a, 4095, 0);
  CHECK(ambient_light_sensor(&a) == PEDAL_AMBIENT_NONE && ambient_light_ready(&a),
        "two open probes did not drop the sensor");
  ambient_light_probe(&a, 400, 300);
  ambient_light_probe(&a, 400, 300);
  CHECK(!ambient_light_ready(&a), "a sensor plugged back in reported before a fresh second");
  second(&a, counts_at(20.0f));
  CHECK(fabsf(counts_of(ambient_light_level(&a)) - 20.0f) < 2.0f,
        "the old reading leaked into a fresh start");
}

/* The reading interval is random, 7..13 ms, so a flicker locked to the
 * 10 ms mean (100 Hz, lamps on 50 Hz mains) is seen at every phase and
 * averages out instead of reading one point of its cycle. */
static void test_flicker_averages_out(void) {
  uint32_t seed = 0x5E6A0C17u;
  unsigned seen[AMBIENT_SAMPLE_MIN_MS + AMBIENT_SAMPLE_JITTER_MS] = {0};
  for (int i = 0; i < 1000; ++i) {
    const uint32_t interval = ambient_light_next_interval(&seed);
    CHECK(interval >= AMBIENT_SAMPLE_MIN_MS &&
              interval < AMBIENT_SAMPLE_MIN_MS + AMBIENT_SAMPLE_JITTER_MS,
          "an interval out of range");
    seen[interval]++;
  }
  for (unsigned i = AMBIENT_SAMPLE_MIN_MS; i < AMBIENT_SAMPLE_MIN_MS + AMBIENT_SAMPLE_JITTER_MS; ++i)
    CHECK(seen[i] > 50, "an interval never drawn");
  /* A lamp at 1000 counts with 100 % flicker at 100 Hz, its peak at t = 0:
   * a fixed 10 ms reads 2000 every time. The random intervals read the mean:
   * each second within 35 % (one second's spread is about 10 %), and the
   * level the board reports, after its median and average, within its
   * hysteresis of the mean's. */
  const double pi = 3.14159265358979;
  for (int phase = 0; phase < 4; ++phase) {
    ambient_light a;
    ambient_light_init(&a);
    ambient_light_probe(&a, 1200, 900);
    double t = phase * 2.5;
    for (int second_n = 0; second_n < 20; ++second_n) {
      double sum = 0;
      for (unsigned i = 0; i < AMBIENT_WINDOW; ++i) {
        const double counts = 1000.0 * (1.0 + cos(2.0 * pi * 100.0 * t / 1000.0));
        sum += counts;
        ambient_light_sample(&a, (uint16_t)(counts + 0.5));
        t += ambient_light_next_interval(&seed);
      }
      const double mean = sum / AMBIENT_WINDOW;
      CHECK(mean > 650.0 && mean < 1350.0, "100 Hz flicker did not average out");
    }
    const int want = (int)(16.0 * log2(1000.0) + 0.5);
    CHECK(abs((int)ambient_light_level(&a) - want) < AMBIENT_HYSTERESIS,
          "the level under flicker is not the mean's");
  }
}

int main(void) {
  test_scale();
  test_probe();
  test_no_sensor();
  test_first_second_and_top();
  test_short_events_are_ignored();
  test_hysteresis();
  test_a_real_change_follows();
  test_verdict_needs_two_probes();
  test_flicker_averages_out();
  printf("ambient light: ALL PASSED\n");
  return 0;
}
