/*
 * engine_bridge.h — the pitch bridge (#1675): a real-time time stretch that
 * keeps a track's pitch from the first frame of a tempo change until its
 * stretch render lands.
 *
 * Under Follow tempo with Pitch Unchanged a track off its span wants a
 * stretch render from the cache worker (#1179 Part 4a-ii). Until that render
 * lands the track used to read its take through the varispeed head, so its
 * pitch moved by the tempo ratio (-316 cents from 120 to 100 BPM) for the
 * settle, the copy and the render: seconds on the Pi. The bridge plays the
 * same take at its own pitch instead, by WSOLA: grains of 2 x hop frames read
 * the source at the grain rate (the Speed alone, so Speed keeps its coupled
 * pitch), each starting where the varispeed head is when it starts, and are
 * overlap-added with a Hann window (sin^2 and its complement, summing to 1).
 * A new grain continues the one before it while that stays within a few
 * tens of milliseconds of the head, and is otherwise moved, within the same
 * tolerance, to where its waveform best continues it (a decimated,
 * normalized cross-correlation search), which is what keeps tones and bass
 * from beating. Timing stays the head's: every grain starts within the
 * tolerance of the varispeed index, so the bridge never drifts from the
 * clock.
 *
 * One pure header for the audio callback (mix_tracks_frame) and the offline
 * renderer (perf_render.c), which run the same arithmetic on the same frames,
 * so a stem reproduces what the performer heard. No allocation and no libm.
 * The state per lane is the two grains' start indices, the rate and
 * direction each reads at, and the engine frame of the last frame stepped:
 * a step that does not follow the last one (the first frame of a bridge, a
 * track that stopped and plays again) lays both grains on the head again. A
 * Speed step or a Reverse toggle reaches the next grain, so no grain jumps
 * mid-read and the change crossfades over one grain. Grain edges sit on
 * the engine clock (the frame the effect chains count, perf_arm_fx_clock + f
 * in the renderer) offset per lane, so at most one lane's search lands in
 * any period.
 *
 * Plain C, C++17-clean (no _Atomic, positional initializers): core headers
 * reach the VST3 C++ TUs.
 */
#ifndef LE_ENGINE_BRIDGE_H
#define LE_ENGINE_BRIDGE_H
#include <stdint.h>

#include "engine_read_head.h"

/* Which sides of a track's read go through the bridge this frame. */
#define LE_BRIDGE_NEW 1 /* the new head */
#define LE_BRIDGE_OLD 2 /* a turn window's old head */

typedef struct le_bridge {
  double cur;          /* source index the current grain started at */
  double prev;         /* and the grain before it, one hop earlier */
  double cur_g;        /* the grain rate each reads at: the Speed in force */
  double prev_g;       /* when it started */
  uint32_t last_clock; /* engine frame of the last frame stepped */
  int32_t cur_rev;     /* the direction each reads in */
  int32_t prev_rev;
  int32_t live;        /* 0: the next step lays both grains on the head */
  int32_t tonal;       /* the last search found a continuation (le_bridge_align) */
} le_bridge;

/* The grain hop: the power of two nearest 40 ms (4096 frames at 96 kHz, 2048
 * at 44.1 and 48 kHz), so a grain edge is a mask of the engine clock and
 * survives its 32-bit wrap. Grains are two hops long. */
static inline int32_t le_bridge_hop(int32_t sample_rate) {
  const int32_t want = sample_rate > 0 ? sample_rate / 25 : 1920;
  int32_t hop = 64;
  while (hop < want && hop < (1 << 20)) hop <<= 1;
  /* nearest: step back when the power below is closer */
  if (hop > 64 && want - hop / 2 < hop - want) hop >>= 1;
  return hop;
}

/* Lane l of track t starts its grains this many frames into the hop, so the
 * 64 lanes' searches spread over the hop (one every hop / 64 frames, one
 * period at 96 kHz / 64 and 48 kHz / 32). */
static inline uint32_t le_bridge_offset(int32_t track, int32_t lane,
                                        int32_t hop) {
  return (uint32_t)((track * 8 + lane) & 63) * (uint32_t)(hop / 64);
}

/* Index x reduced into [0, len) for a whole-sample read (the search taps). */
static inline int64_t le_bridge_whole(double x, int32_t len) {
  int64_t i = (int64_t)le_head_wrap(x, len);
  if (i >= len) i = len - 1;
  return i;
}

/* Normalized correlation of the `n` target taps with taps of `sub` from
 * index `k0`, every `kb` entries: c * |c| / energy, so the comparison needs
 * no square root. Four partial sums, in a fixed order on both sides. */
static inline double le_bridge_score(const float* sub, const float* target,
                                     int32_t n, int32_t k0, int32_t kb) {
  float c0 = 0.0f, c1 = 0.0f, c2 = 0.0f, c3 = 0.0f;
  float e0 = 0.0f, e1 = 0.0f, e2 = 0.0f, e3 = 0.0f;
  int32_t j = 0;
  const float* x = sub + k0;
  for (; j + 4 <= n; j += 4) {
    const float a = x[(j + 0) * kb], b = x[(j + 1) * kb];
    const float c = x[(j + 2) * kb], d = x[(j + 3) * kb];
    c0 += a * target[j + 0];
    c1 += b * target[j + 1];
    c2 += c * target[j + 2];
    c3 += d * target[j + 3];
    e0 += a * a;
    e1 += b * b;
    e2 += c * c;
    e3 += d * d;
  }
  for (; j < n; ++j) {
    const float a = x[j * kb];
    c0 += a * target[j];
    e0 += a * a;
  }
  const double cc = (double)((c0 + c1) + (c2 + c3));
  const double en = (double)((e0 + e1) + (e2 + e3)) + 1e-12;
  return cc * (cc < 0.0 ? -cc : cc) / en;
}

/* The search. A splice joins two reads of the take that are not
 * continuous, over one hop's crossfade; how it sounds depends on how well
 * the new grain continues the old one, and how often it happens. So
 * (#1675, after the owner heard the first version as grainy on held notes):
 *
 * - a grain whose continuation is still within the tolerance of the head
 *   continues, with no splice and no search: WSOLA's best match is the
 *   continuation itself, which no other lag can outscore;
 * - once the continuation has drifted out, the search covers +-25 ms of
 *   the head, wide enough for a whole period of a five-string bass's low
 *   B (32 ms) and to find one lag that continues every note of a chord, and
 *   compares 20 ms of waveform, more than a period of a guitar's low E;
 * - among good matches it leans to the side away from the drift, so the
 *   next splice is as far off as it can be;
 * - material that repeats nowhere within the search, away from the
 *   continuation itself (noise, cymbals: normalized correlation under 0.5),
 *   keeps to +-10 ms, for the search and for how far a grain may continue
 *   (`tonal`), so its hits stay on time.
 *
 * Grains start on whole samples, so at a whole Speed they read the take's
 * samples rather than interpolations that would dull the top end by a
 * different amount in every grain.
 *
 * The first version searched +-10 ms over 10 ms of waveform on every hop.
 * Offline at 48 kHz from 120 to 100 BPM, on a held chord, a bass note, drums
 * and the owner's guitar takes, this splices 4 to 6 times a second instead
 * of 14 to 22, the chord's partials dip about a third as much (0.7 dB RMS
 * below their running level against 2.1; the Signalsmith render measures
 * 0.9), and a bass note no longer beats. A drum loop's hits land about
 * 15 ms from their place on average against 10 (a kick's ringing body
 * repeats, so it counts as tonal). One search
 * costs about 40 % more (9.3 against 6.6 us on an M4) and runs a quarter to
 * a third as often. */
#define LE_BRIDGE_REACH_MS 25
#define LE_BRIDGE_INNER_MS 10
#define LE_BRIDGE_WINDOW_MS 20
#define LE_BRIDGE_MAX_TAPS 160
#define LE_BRIDGE_MAX_SUB 2560

/* x rounded to a whole index in [0, len). */
static inline int64_t le_bridge_round(double x, int32_t len) {
  return le_bridge_whole(x + 0.5, len);
}

/* d reduced to the signed distance nearest zero on a loop of len frames. */
static inline int64_t le_bridge_near(int64_t d, int32_t len) {
  d %= len;
  if (d > len / 2) d -= len;
  if (d < -(int64_t)(len / 2)) d += len;
  return d;
}

/* The start index for a new grain, whole: the continuation of the grain
 * before it (`cont`) while that is within LE_BRIDGE_REACH_MS of the head's
 * index (`ideal`), else the head's index moved by the lag whose waveform
 * best continues it. The taps (20 ms of them, every sample_rate / 6000
 * frames at the grain rate) and the candidate region are gathered once into
 * flat arrays at their common spacing, so each lag is a strided dot product.
 * The lags run on the tap spacing, then every lag around the best one. */
static inline double le_bridge_align(const float* buf, int32_t len,
                                     double ideal, double cont, double g,
                                     int32_t reversed, int32_t sample_rate,
                                     int32_t* tonal) {
  const int64_t base = le_bridge_round(ideal, len);
  const int64_t from = le_bridge_round(cont, len);
  const int32_t reach = sample_rate * LE_BRIDGE_REACH_MS / 1000;
  const int32_t inner = sample_rate * LE_BRIDGE_INNER_MS / 1000;
  const int32_t keep = *tonal ? reach : inner;
  const int64_t drift = le_bridge_near(from - base, len);
  if (drift >= -keep && drift <= keep) return (double)from;
  int32_t step = sample_rate / 6000;
  if (step < 1) step = 1;
  int32_t n = sample_rate * LE_BRIDGE_WINDOW_MS / 1000 / step;
  if (n > LE_BRIDGE_MAX_TAPS) n = LE_BRIDGE_MAX_TAPS;
  int32_t stride = (int32_t)(g * (double)step + 0.5);
  if (stride < 1) stride = 1;
  if (n < 4 || (int64_t)len <= 2 * (int64_t)reach + (int64_t)n * stride) {
    return (double)base;
  }
  /* u: the spacing both the lags (step) and the taps (stride) sit on */
  int32_t u = step, v = stride;
  while (v != 0) {
    const int32_t r = u % v;
    u = v;
    v = r;
  }
  const int32_t a = step / u, b = stride / u;
  const int32_t span = (2 * reach + n * stride) / u + 2;
  if (span > LE_BRIDGE_MAX_SUB) return (double)base;
  float target[LE_BRIDGE_MAX_TAPS];
  float sub[LE_BRIDGE_MAX_SUB];
  const int64_t sgn = reversed ? -1 : 1;
  int64_t i = from;
  float et = 0.0f;
  for (int32_t j = 0; j < n; ++j) {
    target[j] = buf[i];
    et += target[j] * target[j];
    i += sgn * stride;
    if (i >= len) i -= len;
    if (i < 0) i += len;
  }
  /* sub[k] = buf[origin + u * k]: forward taps walk up from base - reach,
   * reversed ones down from base + reach, so the region starts below both. */
  const int64_t tail = reversed ? (int64_t)n * stride : 0;
  i = base - reach - tail;
  while (i < 0) i += len;
  i %= len;
  for (int32_t k = 0; k < span; ++k) {
    sub[k] = buf[i];
    i += u;
    if (i >= len) i -= len;
  }
  /* lag L = -reach + li * step reads its first tap at k0 = (tail + li * step)
   * / u and steps sgn * b. A score leans by up to 15 % toward the side away
   * from the drift (`away` * L > 0); `best` is over every lag, `near` over
   * those within LE_BRIDGE_INNER_MS. */
  const double away = drift > 0 ? -0.15 / (double)reach : 0.15 / (double)reach;
  const int32_t first = (int32_t)(tail / u);
  const int32_t kb = reversed ? -b : b;
  const int32_t lags = 2 * reach / step;
  int32_t best = 0, near = lags / 2;
  double best_score = -1e300, near_score = -1e300, other = 0.0;
  for (int32_t li = 0; li <= lags; ++li) {
    const int32_t l = -reach + li * step;
    const double raw = le_bridge_score(sub, target, n, first + li * a, kb);
    /* the best match at least LE_BRIDGE_INNER_MS from the continuation,
     * which matches itself whatever the material */
    const int64_t off = (int64_t)l - drift;
    if ((off < -inner || off > inner) && raw > other) other = raw;
    const double s = raw > 0.0 ? raw * (1.0 + away * (double)l) : raw;
    if (s > best_score) {
      best_score = s;
      best = li;
    }
    if (l >= -inner && l <= inner && s > near_score) {
      near_score = s;
      near = li;
    }
  }
  /* raw = c|c| / e_c, so c^2 / (e_c e_t) is raw / e_t: under 0.25
   * (normalized correlation 0.5) away from the continuation, the waveform
   * repeats nowhere and the lag that keeps time wins. */
  int32_t limit = reach;
  *tonal = other >= 0.25 * ((double)et + 1e-12);
  if (!*tonal) {
    best = near;
    best_score = near_score;
    limit = inner;
  }
  int32_t lag = -reach + best * step;
  const int32_t fine_span = 2 * step + n * stride;
  if (step > 1 && fine_span <= LE_BRIDGE_MAX_SUB) {
    /* every lag around the coarse one, from a region gathered at unit
     * spacing: lag coarse + d reads its first tap at
     * k0 = ftail + d + step - 1 */
    const int32_t coarse = lag;
    const int32_t ftail = reversed ? n * stride : 0;
    i = base + coarse - (step - 1) - ftail;
    while (i < 0) i += len;
    i %= len;
    for (int32_t k = 0; k < fine_span; ++k) {
      sub[k] = buf[i];
      if (++i >= len) i = 0;
    }
    const int32_t fkb = reversed ? -stride : stride;
    for (int32_t d = -step + 1; d < step; ++d) {
      const int32_t l = coarse + d;
      if (d == 0 || l < -limit || l > limit) continue;
      double s = le_bridge_score(sub, target, n, ftail + d + step - 1, fkb);
      if (s > 0.0) s *= 1.0 + away * (double)l;
      if (s > best_score) {
        best_score = s;
        lag = l;
      }
    }
  }
  int64_t at = base + lag;
  if (at < 0) at += len;
  if (at >= len) at -= len;
  return (double)at;
}

/* Whether a step at engine frame `clock` follows the lane's last one, so the
 * grains go on rather than being laid on the head again. */
static inline int le_bridge_continues(const le_bridge* b, uint32_t clock) {
  return b->live && clock == b->last_clock + 1u;
}

/* Advances a lane's grains to song position `pos`, whose head index is
 * `index` (le_head_index(h, pos, len)), at engine frame `clock`, and returns
 * the frame's phase in the hop. `buf` holds `len` frames at the take's own
 * timing (the dry take or a plain Transpose render) and is what a new grain
 * is aligned on; `g` is the grain rate a new grain reads at, source frames
 * per song frame (the Speed), in the head's direction. Call once per frame
 * the lane sounds through the bridge, then read with le_bridge_read. */
static inline int32_t le_bridge_step(le_bridge* b, const float* buf,
                                     int32_t len, const le_read_head* h,
                                     double g, double index, int64_t pos,
                                     uint32_t clock, uint32_t offset,
                                     int32_t hop, int32_t sample_rate) {
  if (len <= 0 || hop <= 0) return 0;
  const int32_t phase = (int32_t)((clock + offset) & (uint32_t)(hop - 1));
  if (!le_bridge_continues(b, clock)) {
    /* whole indices, so a grain at a whole rate reads samples, not
     * interpolations whose smoothing would change from grain to grain */
    b->cur = (double)le_bridge_round(le_head_index(h, pos - phase, len), len);
    b->prev =
        (double)le_bridge_round(le_head_index(h, pos - phase - hop, len), len);
    b->cur_g = b->prev_g = g;
    b->cur_rev = b->prev_rev = h->reversed;
    b->live = 1;
    b->tonal = 0;
  } else if (phase == 0) {
    const double dir = b->cur_rev ? -1.0 : 1.0;
    const double cont =
        le_head_wrap(b->cur + dir * b->cur_g * (double)hop, len);
    b->prev = b->cur;
    b->prev_g = b->cur_g;
    b->prev_rev = b->cur_rev;
    b->cur = le_bridge_align(buf, len, index, cont, g, h->reversed,
                             sample_rate, &b->tonal);
    b->cur_g = g;
    b->cur_rev = h->reversed;
  }
  b->last_clock = clock;
  return phase;
}

/* x, within a few laps of [0, len), reduced into it by whole laps: no
 * division on the per-frame path (a grain reads at most 2 x hop x 8 frames
 * from where it started). */
static inline double le_bridge_wrap_near(double x, int32_t len) {
  const double l = (double)len;
  while (x >= l) x -= l;
  while (x < 0.0) x += l;
  return x;
}

/* The sample one grain reads from `buf` `into` frames after it started. */
static inline float le_bridge_grain(const float* buf, int32_t len,
                                    double start, double g, int32_t reversed,
                                    int32_t into) {
  const le_read_head gh = {reversed, 0.0, g};
  const double x = le_bridge_wrap_near(
      start + (reversed ? -g : g) * (double)into, len);
  return le_head_read(buf, len, &gh, x);
}

/* The sample the lane's two grains read from `buf` (`len` frames, the take's
 * timing) at `phase`: the current grain fading in over the hop as the one
 * before it fades out, sin^2 and its complement. */
static inline float le_bridge_read(const le_bridge* b, const float* buf,
                                   int32_t len, int32_t phase, int32_t hop) {
  if (len <= 0 || hop <= 0) return 0.0f;
  const float m = le_head_turn_mix(phase, hop, 1);
  const float w = m * m;
  return w * le_bridge_grain(buf, len, b->cur, b->cur_g, b->cur_rev, phase) +
         (1.0f - w) * le_bridge_grain(buf, len, b->prev, b->prev_g,
                                      b->prev_rev, phase + hop);
}

/* One lane's frame through the bridge, the one sequence the callback and the
 * renderer both run: the grains step over the bridged side's source (`fresh`
 * when the new head is bridged, else `old`, a turn window's old source),
 * then each bridged side reads them, *x from `fresh` when `on`, *y from
 * `old` when `old_on`. Sides that are not bridged are left alone. */
static inline void le_bridge_frame(le_bridge* b, int on, int old_on,
                                   const float* fresh, const float* old,
                                   int32_t len, const le_read_head* h,
                                   double g, double index, int64_t pos,
                                   uint32_t clock, uint32_t offset,
                                   int32_t hop, int32_t sample_rate, float* x,
                                   float* y) {
  if (!on && !old_on) return;
  const int32_t phase = le_bridge_step(b, on ? fresh : old, len, h, g, index,
                                       pos, clock, offset, hop, sample_rate);
  if (on) *x = le_bridge_read(b, fresh, len, phase, hop);
  if (old_on) *y = le_bridge_read(b, old, len, phase, hop);
}

#endif /* LE_ENGINE_BRIDGE_H */
