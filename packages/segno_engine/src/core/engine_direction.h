/* Per-track read direction (Reverse, #1162): the pure index arithmetic shared
 * by the audio callback (mix_tracks_frame) and the offline renderer
 * (perf_render.c), so the two can never disagree about which sample a
 * reversed track reads. C and C++17 clean on purpose: this header reaches
 * every VST3 C++ translation unit through engine_private.h, so it uses no
 * _Atomic, no designated initializers and nothing but <stdint.h>.
 *
 * Model: a track has a clock position `pos` (the shared clock plus its segment,
 * a Sync division's fold, or its private Free/Song clock) and a read origin
 * `origin` (le_track.playback_offset). Forward reads (pos + origin) mod len.
 * Reversed reads (origin - pos - 1) mod len, so with origin 0 a lap starts at
 * len - 1 exactly where a forward lap starts at 0: the reversed lap of a Sync
 * division still coincides with the primary's loop top. A toggle re-origins so
 * the index is continuous at the turn (le_direction_origin). */
#ifndef LE_ENGINE_DIRECTION_H
#define LE_ENGINE_DIRECTION_H
#include <stdint.h>

/* Read index for clock position `pos` on a track of `len` frames (len > 0). */
static inline int32_t le_direction_index(int reversed, int32_t origin,
                                         int64_t pos, int32_t len) {
  int64_t i = reversed ? (int64_t)origin - pos - 1 : pos + (int64_t)origin;
  i %= len;
  if (i < 0) i += len;
  return (int32_t)i;
}

/* The origin that makes le_direction_index read `index` at `pos`. */
static inline int32_t le_direction_origin(int reversed, int32_t index,
                                          int64_t pos, int32_t len) {
  int64_t o = reversed ? (int64_t)index + pos + 1 : (int64_t)index - pos;
  o %= len;
  if (o < 0) o += len;
  return (int32_t)o;
}

/* First index of a lap: 0 forward, len - 1 reversed. */
static inline int32_t le_direction_lap_start(int reversed, int32_t len) {
  return reversed ? len - 1 : 0;
}

/* Equal-gain weight of the NEW head `i` frames into a turn of `frames`
 * frames: the two heads read the same material and are equal at i == 0, so a
 * linear law is the one le_seam_fold already uses for the loop seam. */
static inline float le_direction_turn_mix(int32_t i, int32_t frames) {
  return (float)i / (float)frames;
}

#endif /* LE_ENGINE_DIRECTION_H */
