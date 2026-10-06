/*
 * engine_read_head.h — the per-track fractional read coordinate (#1179).
 *
 * One pure header shared by the audio callback, the offline performance
 * renderer and the bench harness, in the role engine_fade.h plays for the Fade
 * envelope: positional initializers only, no _Atomic, no allocation and no
 * libm, so it is C++17-clean (the VST3 host TUs reach every core header) and
 * safe on the audio thread.
 *
 * A track reads its source through a head {reversed, origin, rate}. For the
 * UNBOUNDED song position `pos` (a count of song frames since the track's
 * start, never the wrapped per-frame position) the source index is
 *
 *   forward:  (origin + rate * pos) mod len
 *   reversed: (origin - rate * pos) mod len
 *
 * derived from the clock on every frame rather than integrated, so nothing
 * drifts. `rate == 1`, `origin` integral and `reversed == 0` is the identity
 * head: le_head_sample returns buf[i] exactly, so the mixer's integer read path
 * stays bit-identical. `rate == 1`, `reversed == 1` is the Foot Reverse
 * coordinate; Speed and tempo follow are rates other than 1.
 */
#ifndef LE_ENGINE_READ_HEAD_H
#define LE_ENGINE_READ_HEAD_H
#include <stdint.h>

typedef struct le_read_head {
  int32_t reversed; /* 0 forward, 1 reversed */
  double origin;    /* source-frame origin, re-set so the index stays continuous */
  double rate;      /* source frames per song frame = speed * (len_src / play_len) */
} le_read_head;

/* x reduced into [0, len) without fmod: an int64 quotient and one correction. */
static inline double le_head_wrap(double x, int32_t len) {
  const double l = (double)len;
  const int64_t q = (int64_t)(x / l); /* truncates toward zero */
  double r = x - (double)q * l;
  if (r < 0.0) r += l;
  if (r >= l) r -= l;
  return r;
}

/* Source index for song position `pos` on a source of `len` frames. */
static inline double le_head_index(const le_read_head* h, int64_t pos,
                                   int32_t len) {
  if (len <= 0) return 0.0;
  const double travel = h->rate * (double)pos;
  return le_head_wrap(h->reversed ? h->origin - travel : h->origin + travel,
                      len);
}

/* The origin that makes le_head_index == `index` at `pos` (continuity at a
 * rate step, a direction turn, a relaunch or any clock discontinuity). */
static inline double le_head_origin(const le_read_head* h, double index,
                                    int64_t pos, int32_t len) {
  if (len <= 0) return 0.0;
  const double travel = h->rate * (double)pos;
  return le_head_wrap(h->reversed ? index + travel : index - travel, len);
}

static inline int le_head_is_identity(const le_read_head* h) {
  return h->reversed == 0 && h->origin == 0.0 && h->rate == 1.0;
}

/* Linear interpolation between the two source samples around `index`, with
 * wrap. A zero fraction returns buf[i] itself (the identity path). */
static inline float le_head_sample(const float* buf, int32_t len,
                                   double index) {
  int64_t i = (int64_t)index;
  const float frac = (float)(index - (double)i);
  if (i >= len) i -= len;
  if (i < 0) i = 0;
  if (frac == 0.0f) return buf[i];
  int64_t j = i + 1;
  if (j >= len) j = 0;
  return buf[i] + frac * (buf[j] - buf[i]);
}

/* Box average of the floor(rate) source samples a head stepping `rate` per
 * frame passes over, from floor(index), wrapped: the first-order anti-alias
 * for rate >= 2 (first sidelobe -13 dB). Below 2 it is the plain sample. */
static inline float le_head_sample_decimated(const float* buf, int32_t len,
                                             double index, double rate) {
  int32_t n = (int32_t)rate;
  if (n < 2 || len <= 0) return le_head_sample(buf, len, index);
  if (n > len) n = len;
  int64_t i = (int64_t)index;
  if (i >= len) i -= len;
  if (i < 0) i = 0;
  float sum = 0.0f;
  for (int32_t k = 0; k < n; ++k) {
    sum += buf[i];
    if (++i >= len) i = 0;
  }
  return sum / (float)n;
}

/* Weight of the NEW head `i` frames into a window of `F` frames. The old
 * head's weight is le_head_turn_mix(F - i, F, equal_power). Equal-gain (i/F)
 * for a rate or direction turn: both heads read the same material and are
 * continuous at the turn. Equal-power (sin(i/F * pi/2), an odd polynomial so
 * no libm, error < 2e-4) for a swap between source kinds, whose signals are
 * uncorrelated and would dip 6 dB at mid-fade under equal gain. */
static inline float le_head_turn_mix(int32_t i, int32_t F,
                                     int32_t equal_power) {
  if (F <= 0 || i >= F) return 1.0f;
  if (i <= 0) return 0.0f;
  const float x = (float)i / (float)F;
  if (!equal_power) return x;
  const float t = x * 1.5707963f;
  const float t2 = t * t;
  const float s =
      t * (1.0f - t2 * (0.16666667f - t2 * (0.0083333f - t2 * 0.00019841f)));
  return s > 1.0f ? 1.0f : s;
}

/* Whether the head wrapped between two consecutive indices, in its direction:
 * a forward head wraps when the index falls, a reversed one when it rises. */
static inline int le_head_wrapped(double prev, double next, int32_t reversed) {
  return reversed ? (next > prev) : (next < prev);
}

/* Q32.32 fixed point of an index, the form the performance log carries so the
 * offline renderer anchors from the exact value the callback used. */
static inline uint64_t le_head_index_q32(double index) {
  return (uint64_t)(index * 4294967296.0);
}
static inline double le_head_index_from_q32(uint64_t q) {
  return (double)q / 4294967296.0;
}

#endif /* LE_ENGINE_READ_HEAD_H */
