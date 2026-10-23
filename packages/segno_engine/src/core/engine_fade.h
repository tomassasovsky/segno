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

/* One frame of an audibility fade (#1400): [g] moves [step] toward [target]
 * (0 or 1) and lands on it exactly. The callback steps a lane's mute, a
 * track's solo and a track's play gain with it, and the performance replay
 * steps the same gates with it, so an export fades where the performer heard
 * a fade. */
static inline float le_gate_step(float g, float target, float step) {
  if (g < target) {
    g += step;
    return g > target ? target : g;
  }
  if (g > target) {
    g -= step;
    return g < target ? target : g;
  }
  return g;
}

/* The step le_gate_step takes at [sample_rate]: one fade over sr / 100
 * frames (~10 ms), the overdub punch's od_step and the loop seam's length. */
static inline float le_gate_step_size(int sample_rate) {
  int32_t frames = (sample_rate > 0 ? sample_rate : 48000) / 100;
  if (frames < 1) frames = 1;
  return 1.0f / (float)frames;
}
#endif
