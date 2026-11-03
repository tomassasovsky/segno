#include "ambient_light.h"

#include <math.h>
#include <string.h>

#include "pedal_link.h"

void ambient_light_init(ambient_light *a) { memset(a, 0, sizeof(*a)); }

float ambient_light_level_of(float counts) {
  if (counts > (float)AMBIENT_TOP_COUNTS) counts = (float)AMBIENT_TOP_COUNTS;
  if (counts <= 1.0f) return 0.0f;
  return (float)PEDAL_AMBIENT_STEPS_PER_DOUBLING * log2f(counts);
}

static uint8_t round_level(float level) {
  if (level <= 0.0f) return 0;
  if (level >= 255.0f) return 255;
  return (uint8_t)(level + 0.5f);
}

uint8_t ambient_light_top_level(void) {
  return round_level(ambient_light_level_of((float)AMBIENT_TOP_COUNTS));
}

int ambient_light_probe_fitted(uint16_t with_pull_up, uint16_t with_pull_down) {
  if (with_pull_up <= AMBIENT_PROBE_GROUNDED) return 0;
  if (with_pull_up >= AMBIENT_PROBE_RAIL && with_pull_down <= AMBIENT_PROBE_FLOOR) return 0;
  return 1;
}

uint32_t ambient_light_next_interval(uint32_t *seed) {
  uint32_t x = *seed ? *seed : 0x9E3779B9u;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *seed = x;
  return AMBIENT_SAMPLE_MIN_MS + x % AMBIENT_SAMPLE_JITTER_MS;
}

static void restart(ambient_light *a) {
  a->sum = 0;
  a->samples = 0;
  a->history_len = 0;
  a->history_pos = 0;
  a->have_level = 0;
  a->level = 0;
  a->above = 0;
}

void ambient_light_probe(ambient_light *a, uint16_t with_pull_up, uint16_t with_pull_down) {
  const uint8_t fitted = (uint8_t)ambient_light_probe_fitted(with_pull_up, with_pull_down);
  if (!a->probed) {
    a->probed = 1;
    a->fitted = fitted;
    a->disagreed = 0;
    restart(a);
    return;
  }
  if (fitted == a->fitted) {
    a->disagreed = 0;
    return;
  }
  if (++a->disagreed < 2) return;
  a->fitted = fitted;
  a->disagreed = 0;
  restart(a);
}

static float median(const float *values, uint8_t n) {
  float sorted[AMBIENT_MEDIAN];
  memcpy(sorted, values, n * sizeof(float));
  for (uint8_t i = 1; i < n; ++i) {
    const float v = sorted[i];
    uint8_t j = i;
    while (j > 0 && sorted[j - 1] > v) {
      sorted[j] = sorted[j - 1];
      --j;
    }
    sorted[j] = v;
  }
  return n % 2 ? sorted[n / 2] : 0.5f * (sorted[n / 2 - 1] + sorted[n / 2]);
}

/* One second is in: fold its mean into the level. */
static void close_second(ambient_light *a) {
  const float second = ambient_light_level_of((float)a->sum / (float)a->samples);
  a->sum = 0;
  a->samples = 0;
  a->history[a->history_pos] = second;
  a->history_pos = (uint8_t)((a->history_pos + 1) % AMBIENT_MEDIAN);
  if (a->history_len < AMBIENT_MEDIAN) ++a->history_len;
  const float middle = median(a->history, a->history_len);
  if (!a->have_level) {
    a->smoothed = middle;
  } else {
    a->smoothed += AMBIENT_SMOOTHING * (middle - a->smoothed);
  }
  a->above = middle >= ambient_light_level_of((float)AMBIENT_TOP_COUNTS);
  const uint8_t target = round_level(a->smoothed);
  const int moved = (int)target - (int)a->level;
  if (a->above) {
    a->level = ambient_light_top_level();  /* the top of the range, exactly */
  } else if (!a->have_level || target == 0 || moved >= AMBIENT_HYSTERESIS ||
             moved <= -AMBIENT_HYSTERESIS) {
    a->level = target;  /* darkness, 0, exactly */
  }
  a->have_level = 1;
}

void ambient_light_sample(ambient_light *a, uint16_t counts) {
  if (!a->probed || !a->fitted) return;
  a->sum += counts;
  if (++a->samples >= AMBIENT_WINDOW) close_second(a);
}

int ambient_light_ready(const ambient_light *a) {
  return a->probed && (!a->fitted || a->have_level);
}

uint8_t ambient_light_sensor(const ambient_light *a) {
  if (!a->fitted) return PEDAL_AMBIENT_NONE;
  return a->above ? PEDAL_AMBIENT_ABOVE : PEDAL_AMBIENT_READING;
}

uint8_t ambient_light_level(const ambient_light *a) { return a->fitted ? a->level : 0; }
