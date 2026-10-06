/*
 * engine_read_head.h — the per-track read coordinate (Reverse #1162, Speed
 * #1179).
 *
 * One pure header shared by the audio callback (mix_tracks_frame), the offline
 * performance renderer (perf_render.c) and the bench, so they can never
 * disagree about which sample a track reads. Positional initializers only, no
 * _Atomic, no allocation and no libm: it reaches every VST3 C++ translation
 * unit through engine_private.h (docs/PROGRESS.md, the C++ blast radius) and
 * runs on the audio thread.
 *
 * A track reads its source through a head {reversed, origin, rate}. For the
 * UNBOUNDED song position `pos` (a count of song frames since the track's
 * start, never the wrapped per-frame position) the source index is
 *
 *   forward:  (origin + rate * pos) mod len
 *   reversed: (origin - 1 - rate * pos) mod len
 *
 * derived from the clock on every frame rather than integrated, so nothing
 * drifts. The reversed form keeps Reverse's convention: with origin 0 a
 * reversed lap starts at len - 1 exactly where a forward lap starts at 0, so
 * a reversed Sync division still meets the primary's loop top. At rate 1 with
 * an integral origin every index is integral and le_head_sample returns
 * buf[i] itself, so the mixer's integer path stays bit-identical. A change of
 * rate or direction re-origins (le_head_origin) so the index is continuous.
 */
#ifndef LE_ENGINE_READ_HEAD_H
#define LE_ENGINE_READ_HEAD_H
#include <stdint.h>

typedef struct le_read_head {
  int32_t reversed; /* 0 forward, 1 reversed */
  double origin;    /* source-frame origin, re-set so the index stays continuous */
  double rate;      /* source frames per song frame = speed * (len_src / play_len) */
} le_read_head;

/* The Speed factor as one published word (#1179): numer << 8 | denom, both
 * 1..8, so the pair is stored and loaded in one access and never torn. */
static inline int32_t le_speed_pack(int32_t numer, int32_t denom) {
  return (numer << 8) | denom;
}
static inline int32_t le_speed_numer_of(int32_t packed) {
  return packed >> 8;
}
static inline int32_t le_speed_denom_of(int32_t packed) {
  return packed & 0xff;
}

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
  return le_head_wrap(
      h->reversed ? h->origin - 1.0 - travel : h->origin + travel, len);
}

/* The origin that makes le_head_index == `index` at `pos` (continuity at a
 * rate step, a direction turn, a relaunch or any clock discontinuity). */
static inline double le_head_origin(const le_read_head* h, double index,
                                    int64_t pos, int32_t len) {
  if (len <= 0) return 0.0;
  const double travel = h->rate * (double)pos;
  return le_head_wrap(h->reversed ? index + 1.0 + travel : index - travel, len);
}

/* The rate of a take of `len` source frames that spans `play_len` song frames
 * at Speed numer/denom (#1179 Part 4a): speed * len / play_len, one integer
 * quotient so the callback and the offline renderer compute the same double.
 * A take at its own span (or a missing span) reads at the Speed alone. */
static inline double le_head_rate(int32_t numer, int32_t denom, int32_t len,
                                  int32_t play_len) {
  if (len <= 0 || play_len <= 0 || len == play_len) {
    return (double)numer / (double)denom;
  }
  return (double)((int64_t)numer * len) / (double)((int64_t)denom * play_len);
}

/* The default head: forward, parked, rate 1 (the mixer's integer path). */
static inline int le_head_is_identity(const le_read_head* h) {
  return h->reversed == 0 && h->origin == 0.0 && h->rate == 1.0;
}

/* Whether every index the head reads is a whole sample: rate 1 from an
 * integral origin (the integer read path and an engaged print apply). */
static inline int le_head_is_integral(const le_read_head* h) {
  return h->rate == 1.0 && h->origin == (double)(int64_t)h->origin;
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

/* Mean of the n source samples a head passes over from index i in its
 * direction: i .. i+n-1 forward, i-n+1 .. i reversed, wrapped. */
static inline float le_head_box(const float* buf, int32_t len, int64_t i,
                                int32_t n, int32_t reversed) {
  int64_t j = reversed ? i - n + 1 : i;
  while (j < 0) j += len;
  float sum = 0.0f;
  for (int32_t k = 0; k < n; ++k) {
    sum += buf[j];
    if (++j >= len) j = 0;
  }
  return sum / (float)n;
}

/* The first-order anti-alias for rate >= 2: a box of floor(rate) samples in
 * the head's direction (first sidelobe -13 dB), interpolated between the
 * boxes at floor(index) and the next index so a non-integer position is not
 * quantised to whole samples. Below 2 it is the plain sample. */
static inline float le_head_sample_decimated(const float* buf, int32_t len,
                                             double index, double rate,
                                             int32_t reversed) {
  int32_t n = (int32_t)rate;
  if (n < 2 || len <= 0) return le_head_sample(buf, len, index);
  if (n > len) n = len;
  int64_t i = (int64_t)index;
  const float frac = (float)(index - (double)i);
  if (i >= len) i -= len;
  if (i < 0) i = 0;
  const float b0 = le_head_box(buf, len, i, n, reversed);
  if (frac == 0.0f) return b0;
  const float b1 = le_head_box(buf, len, i + 1 >= len ? 0 : i + 1, n, reversed);
  return b0 + frac * (b1 - b0);
}

/* The sample a head reads at `index`: decimated at rate >= 2, interpolated
 * below. One definition for the callback and the renderer. */
static inline float le_head_read(const float* buf, int32_t len,
                                 const le_read_head* h, double index) {
  return h->rate >= 2.0
             ? le_head_sample_decimated(buf, len, index, h->rate, h->reversed)
             : le_head_sample(buf, len, index);
}

/* Weight of the NEW head `i` frames into a window of `F` frames. The old
 * head's weight is le_head_turn_mix(F - i, F, equal_power). Equal-gain (i/F)
 * for a rate or direction turn: both heads read the same material and are
 * continuous at the turn (the law le_seam_fold uses for the loop seam).
 * Equal-power (sin(i/F * pi/2), an odd polynomial so no libm, error < 2e-4)
 * for a swap between source kinds, whose signals are uncorrelated and would
 * dip 6 dB at mid-fade under equal gain. */
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
 * a forward head wraps when the index falls, a reversed one when it rises.
 * At rate 1 this is "the index reached the lap start" (0 forward, len - 1
 * reversed), the edge Once stops at. */
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
