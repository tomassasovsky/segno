/* One sample-clock envelope, shared by the callback and performance replay. */
#ifndef LE_ENGINE_FADE_H
#define LE_ENGINE_FADE_H
#include <math.h>
#include <stdint.h>
typedef struct le_fade {
  double amount;
  float target;
  float seconds;
  double origin;
  uint64_t frames;
} le_fade;
static inline float le_fade_tick(le_fade* fade, int sample_rate) {
  const float sample = (float)fade->amount;
  if (fade->amount != fade->target && fade->seconds > 0) {
    if (fade->frames == 0) fade->origin = fade->amount;
    const double distance = (double)++fade->frames / ((double)sample_rate * fade->seconds);
    if (fade->origin < fade->target)
      fade->amount = fmin(fade->target, fade->origin + distance);
    else
      fade->amount = fmax(fade->target, fade->origin - distance);
  }
  return sample;
}
#endif
