/*
 * pitch_ref.c — the pitch kernels as they were before #1755, frozen as the
 * oracle the optimised ones are held to (test_pitch_oracle.c).
 *
 * GENERATED, NOT EDITED: a verbatim copy of the pitch family's kernels from
 * engine_fx.c and fft.h at 65f85a3b4 (the phase vocoder and its stages, YIN and
 * the refinement, PSOLA, the Dual Octaver's low band, fx_octaver, the
 * resamplers' read and fx_octaver_run, and the Octaver, Whammy, Dual
 * Octaver and Smart Tune process functions), with every function and table
 * renamed ref_*. It runs on the live le_fx_state, prepared and reset by the
 * live engine; Smart Tune's per-tick settings (le_st_tick) are the live
 * ones, since #1755 does not touch them. A change that is meant to change
 * the sound of a pitch kind changes this file with it, in the same PR, and
 * says so.
 */
#ifdef LE_NATIVE_TESTS

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_internal.h"
#include "pitch_ref.h"

#ifndef LE_PI
#define LE_PI 3.14159265358979323846f
#endif
#define LE_FFT_MAX_N 4096

static inline float ref_le_biquad_tick(const float* b, float* z, float x) {
  const float y = b[0] * x + z[0];
  z[0] = b[1] * x - b[3] * y + z[1];
  z[1] = b[2] * x - b[4] * y;
  return y;
}

static inline float ref_fx_sanitize(float x) {
  if (!isfinite(x)) return 0.0f;
  if (x < 1e-30f && x > -1e-30f) return 0.0f;
  return x;
}

#define LE_FFT_PI 3.14159265358979323846f

/* Upper bound on the real transform length a plan can hold. The phase vocoder
 * uses n = 1024. The inverse's stack scratch is LE_FFT_MAX_N floats. A TU that
 * needs longer transforms off the audio thread (the pitch bench's analysis)
 * defines a larger bound before including this header; the plan type is
 * private to each TU, so the bounds never have to agree. */
#ifndef LE_FFT_MAX_N
#define LE_FFT_MAX_N 4096
#endif

/* The tables for one real transform length. Filled by ref_le_rfft_plan_init on a
 * non-real-time thread and read-only afterwards, so one plan serves any number
 * of instances and threads. */
typedef struct ref_le_rfft_plan {
  int n; /* real length; 0 = not built */
  /* Twiddles of the length-n/2 complex FFT, stage by stage: the stage whose
   * butterflies span 2h points reads exp(-2 pi i k / 2h), k < h, from offset
   * h - 1. n/2 - 1 entries in all. */
  float st_re[LE_FFT_MAX_N / 2];
  float st_im[LE_FFT_MAX_N / 2];
  /* The split twiddles W^k = exp(-2 pi i k / n), k = 0 .. n/2. */
  float sp_re[LE_FFT_MAX_N / 2 + 1];
  float sp_im[LE_FFT_MAX_N / 2 + 1];
} ref_le_rfft_plan;

/* Builds [p] for real length [n] (a power of two, 4 .. LE_FFT_MAX_N). A no-op
 * when [p] already holds n. Returns 1 when [p] holds a plan for n, 0 for a bad
 * n. Not real-time safe (double-precision trig), and not synchronised: a plan
 * shared between threads must be built once before any of them reads it
 * (engine_fx.c builds its plan under pthread_once). */
static int ref_le_rfft_plan_init(ref_le_rfft_plan* p, int n) {
  if (n < 4 || n > LE_FFT_MAX_N || (n & (n - 1)) != 0) return 0;
  if (p->n == n) return 1;
  const double pi = 3.14159265358979323846;
  const int m = n / 2;
  for (int h = 1; h < m; h <<= 1) {
    for (int k = 0; k < h; ++k) {
      const double a = -pi * (double)k / (double)h;
      p->st_re[h - 1 + k] = (float)cos(a);
      p->st_im[h - 1 + k] = (float)sin(a);
    }
  }
  for (int k = 0; k <= m; ++k) {
    const double a = -2.0 * pi * (double)k / (double)n;
    p->sp_re[k] = (float)cos(a);
    p->sp_im[k] = (float)sin(a);
  }
  p->n = n;
  return 1;
}

/* In-place iterative radix-2 complex FFT of length m = p->n / 2.
 * inverse == 0: forward; inverse != 0: inverse WITHOUT 1/m scaling. */
static void ref_le_fft_half(const ref_le_rfft_plan* p, float* re, float* im,
                        int inverse) {
  const int m = p->n / 2;
  /* Bit-reversal permutation: reorder samples into butterfly order in place. */
  for (int i = 1, j = 0; i < m; ++i) {
    int bit = m >> 1;
    for (; j & bit; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      float tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      float ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  /* Danielson–Lanczos butterflies, doubling the sub-transform length each
   * pass; the inverse conjugates the twiddles. */
  const float sgn = inverse ? -1.0f : 1.0f;
  for (int h = 1; h < m; h <<= 1) {
    const float* wr = p->st_re + (h - 1);
    const float* wi = p->st_im + (h - 1);
    for (int i = 0; i < m; i += 2 * h) {
      float* ar = re + i;
      float* ai = im + i;
      float* br = ar + h;
      float* bi = ai + h;
      for (int k = 0; k < h; ++k) {
        const float c = wr[k];
        const float s = sgn * wi[k];
        const float vr = br[k] * c - bi[k] * s;
        const float vi = br[k] * s + bi[k] * c;
        br[k] = ar[k] - vr;
        bi[k] = ai[k] - vi;
        ar[k] += vr;
        ai[k] += vi;
      }
    }
  }
}

/* Real input x[n] -> half spectrum re/im[0..n/2] (n/2+1 bins), n = p->n.
 * re/im sized >= n/2+1; they double as the transform's scratch. */
static void ref_le_rfft_fwd(const ref_le_rfft_plan* p, const float* x, float* re,
                        float* im) {
  const int m = p->n / 2;
  for (int j = 0; j < m; ++j) {
    re[j] = x[2 * j];
    im[j] = x[2 * j + 1];
  }
  ref_le_fft_half(p, re, im, 0);

  /* Split Z = FFT(even + i odd) into X[k] = E[k] + W^k O[k], where
   * E[k] = (Z[k] + conj Z[m-k]) / 2 and O[k] = (Z[k] - conj Z[m-k]) / 2i.
   * Bins k and m - k read each other, so each pair is done together; bin
   * m - k has E and O conjugated. */
  const float z0r = re[0];
  const float z0i = im[0];
  re[0] = z0r + z0i;
  im[0] = 0.0f;
  re[m] = z0r - z0i;
  im[m] = 0.0f;
  for (int k = 1; k <= m / 2; ++k) {
    const int q = m - k;
    const float ar = re[k], ai = im[k];
    const float br = re[q], bi = im[q];
    const float er = 0.5f * (ar + br), ei = 0.5f * (ai - bi);
    const float or_ = 0.5f * (ai + bi), oi = -0.5f * (ar - br);
    const float wr = p->sp_re[k], wi = p->sp_im[k];
    re[k] = er + (wr * or_ - wi * oi);
    im[k] = ei + (wr * oi + wi * or_);
    const float vr = p->sp_re[q], vi = p->sp_im[q];
    re[q] = er + (vr * or_ + vi * oi);
    im[q] = -ei + (vi * or_ - vr * oi);
  }
}

/* Half spectrum re/im[0..n/2] -> real output y[n], normalized by 1/n, n = p->n.
 * The spectrum is read as Hermitian: the imaginary parts of the DC and Nyquist
 * bins are ignored, as a real signal has none. */
static void ref_le_rfft_inv(const ref_le_rfft_plan* p, const float* re,
                        const float* im, float* y) {
  float zr[LE_FFT_MAX_N / 2];
  float zi[LE_FFT_MAX_N / 2];
  const int m = p->n / 2;

  /* Rebuild Z[k] = E[k] + i O[k] from E[k] = (X[k] + conj X[m-k]) / 2 and
   * O[k] = (X[k] - conj X[m-k]) / 2 * conj(W^k), a pair of bins at a time. */
  zr[0] = 0.5f * (re[0] + re[m]);
  zi[0] = 0.5f * (re[0] - re[m]);
  for (int k = 1; k <= m / 2; ++k) {
    const int q = m - k;
    const float ar = re[k], ai = im[k];
    const float br = re[q], bi = im[q];
    const float er = 0.5f * (ar + br), ei = 0.5f * (ai - bi);
    const float dr = 0.5f * (ar - br), di = 0.5f * (ai + bi);
    const float wr = p->sp_re[k], wi = p->sp_im[k];
    const float or_ = dr * wr + di * wi, oi = di * wr - dr * wi;
    zr[k] = er - oi;
    zi[k] = ei + or_;
    if (q != k) {
      /* Bin m - k: E conjugated, D negated and conjugated. */
      const float vr = p->sp_re[q], vi = p->sp_im[q];
      const float qr = -dr * vr + di * vi, qi = di * vr + dr * vi;
      zr[q] = er - qi;
      zi[q] = -ei + qr;
    }
  }
  ref_le_fft_half(p, zr, zi, 1);
  const float scale = 1.0f / (float)m;
  for (int j = 0; j < m; ++j) {
    y[2 * j] = zr[j] * scale;
    y[2 * j + 1] = zi[j] * scale;
  }
}

/* Fills table[0..n-1] with a periodic Hann window once, then short-circuits on
 * later calls via *ready. The table is read-only shared state owned by the
 * caller, sized to its own n, so fft.h stays free of engine constants. The
 * flag is not synchronised: a table shared between threads must be built once
 * before any of them reads it (engine_fx.c builds its own under pthread_once).
 * Periodic form (divide by n, not n-1) gives correct constant-overlap-add for
 * the STFT. */
static void ref_le_hann_init(float* table, int n, int* ready) {
  if (*ready) {
    return;
  }
  for (int i = 0; i < n; ++i) {
    table[i] = 0.5f - 0.5f * cosf(2.0f * LE_FFT_PI * (float)i / (float)n);
  }
  *ready = 1;
}


static float ref_le_hann[LE_PV_N];
static ref_le_rfft_plan ref_le_pv_fft;
static pthread_once_t ref_tables_once = PTHREAD_ONCE_INIT;

static void ref_tables_build(void) {
  int ready = 0;
  ref_le_hann_init(ref_le_hann, LE_PV_N, &ready);
  (void)ref_le_rfft_plan_init(&ref_le_pv_fft, LE_PV_N);
}

/* Wraps a phase value into [-pi, pi] in O(1) — the raw per-hop phase deviation
 * (phase - k*expct) can be hundreds of radians for high bins, so a subtract loop
 * would spin many times per bin per hop. */
static float ref_le_wrap_pi(float x) {
  const float two_pi = 2.0f * LE_PI;
  return x - two_pi * roundf(x / two_pi);
}

static inline uint32_t ref_le_fx_now(const le_fx_state* fx) {
  return fx->clock_src != NULL
             ? atomic_load_explicit(fx->clock_src, memory_order_relaxed)
             : fx->clock;
}

static int ref_le_pv_hop_phase(const le_fx_state* fx, int slot) {
  return le_fx_hop_mask((uint32_t)fx->hop_seed +
                        (uint32_t)slot * (uint32_t)LE_PV_STAGGER_QUARTER);
}

/* The two modes run one counter in opposite directions: PV counts up and runs
 * its frame on the tick where hop_count is 0, PSOLA counts down and runs YIN on
 * the tick that takes it to 0 or below. These two convert between the counter
 * and "ticks until the next heavy tick" (1 = the coming tick), so a phase
 * means the same schedule in both modes and a mode switch keeps the schedule
 * it had instead of restarting it. */
static int ref_le_oct_ticks_to_work(const le_octaver_state* o) {
  if (o->cur_mode == 0) {
    return o->hop_count == 0 ? 1 : LE_PV_HOP - o->hop_count + 1;
  }
  return o->hop_count < 1 ? 1 : o->hop_count;
}

static void ref_le_oct_set_ticks_to_work(le_octaver_state* o, int ticks) {
  if (ticks < 1) ticks = 1;
  if (ticks > LE_PV_HOP) ticks = LE_PV_HOP;
  o->hop_count = o->cur_mode == 0 ? (ticks == 1 ? 0 : LE_PV_HOP - ticks + 1)
                                  : ticks;
}

/* The ticks until the first heavy tick of an instance reset now, at the
 * chain's clock (le_fx_state::clock, the frame of the sample it processes
 * next): heavy ticks fall on the frames c where (c + phase) mod LE_PV_HOP is
 * 0, so instances keep their quarters apart whenever each was reset (#941).
 * At clock 0 (a state nobody clocks) this is the phase counted from the
 * reset. */
static int ref_le_oct_seeded_ticks(const le_fx_state* fx, int slot) {
  const uint32_t phase = (uint32_t)ref_le_pv_hop_phase(fx, slot);
  /* Resampled, the kernel keeps to its own ticks (ref_fx_octaver_run). */
  const uint32_t clock = fx->oct_rs[slot] ? fx->oct_tick[slot] : ref_le_fx_now(fx);
  const uint32_t to_go = (0u - (clock + phase)) & (uint32_t)(LE_PV_HOP - 1);
  return (int)to_go + 1;
}

/* The second voice's regions in the octaver scratch (LE_PV_SCRATCH, after
 * the frame arrays listed at ref_le_pv_stage_analyse): its synthesis spectrum,
 * and its running phases, which persist from frame to frame (#1464). */
#define LE_PV_S_RE2(o) ((o)->scratch + LE_PV_N + 5 * LE_PV_BINS)
#define LE_PV_S_IM2(o) ((o)->scratch + LE_PV_N + 6 * LE_PV_BINS)
#define LE_PV_S_PHASE2(o) ((o)->scratch + LE_PV_N + 7 * LE_PV_BINS)

static void ref_le_pv_reset_runtime(le_fx_state* fx, int slot, int chan,
                                int ticks);
static void ref_le_low_reset_runtime(le_oct_low* L);

/* Puts channel [chan] of octaver slot [slot] on [mode] with its runtime
 * reset, keeping its hop schedule: the new mode's heavy tick lands where the
 * old mode's next one would have. Re-seeding from the phase instead would
 * anchor it to this instant and move it off the instance's quarter. */
static void ref_le_oct_switch_mode(le_fx_state* fx, int slot, int chan, int mode) {
  le_octaver_state* o = &fx->oct[slot][chan];
  const int ticks = ref_le_oct_ticks_to_work(o);
  o->cur_mode = mode;
  ref_le_pv_reset_runtime(fx, slot, chan, ticks);
}

/* Zeros the octaver's per-mode DSP runtime (phase history, synthesis
 * accumulator, hop counter) without touching the heap-buffer allocation or the
 * smoothed params / current mode. Used on a mode switch and on entry reset; safe
 * with NULL buffers (a slot that is not an octaver). The hop counter is set, in
 * the current mode's terms, to run its first heavy tick [ticks] ticks from now:
 * a reset passes ref_le_oct_seeded_ticks (the instance's staggered phase), a mode
 * switch the old mode's remaining ticks. */
static void ref_le_pv_reset_runtime(le_fx_state* fx, int slot, int chan,
                                int ticks) {
  le_octaver_state* o = &fx->oct[slot][chan];
  ref_le_oct_set_ticks_to_work(o, ticks);
  o->out_pos = 0;
  /* PSOLA's analysis marks start at its nominal source distance (dn in
   * ref_le_psola_tick), so the first deposit has nothing to snap. */
  o->in_epoch = (float)(LE_PV_N - LE_PV_N / 2 + LE_PSOLA_LAG);
  o->out_epoch = 0.0f;
  o->period = 0.0f;
  o->voiced = 0.0f;
  if (o->out != NULL) memset(o->out, 0, sizeof(float) * LE_PV_OUT);
  o->analysed = 0;
  if (o->scratch != NULL) {
    le_psola_pass* ps = le_ps(o);
    ps->phase = 0;
    ps->credit = 0;
  }
  o->frame_ratio = 1.0f;
  o->frame_formants_move = 0;
  o->frame_ratio2 = 1.0f;
  o->frame_level1 = 1.0f;
  o->frame_level2 = 0.0f;
  o->frame_low_w = 0.0f;
  o->frame_low_g = 1.0f;
  o->frame_low_kc = 1.0f;
  le_oct_low* low = atomic_load_explicit(&o->low, memory_order_acquire);
  if (low != NULL) ref_le_low_reset_runtime(low);
  o->tune_c = 0.0f;
  o->tune_at[0] = -1.0f;
  o->tune_at[1] = -1.0f;
  o->tune_held = 0;
  if (o->last_phase != NULL) memset(o->last_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->sum_phase != NULL) memset(o->sum_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->scratch != NULL) {
    memset(LE_PV_S_PHASE2(o), 0, sizeof(float) * LE_PV_BINS);
  }
}

/* The formant envelope (engine_fx.h). */
static void ref_le_octaver_envelope(const float* mag, float* env) {
  float cl[LE_PV_N];    /* the full log-magnitude, then the liftered cepstrum */
  float cr[LE_PV_BINS]; /* their transforms (real; ci is the zero imaginary) */
  float ci[LE_PV_BINS];
  /* The full symmetric log-magnitude is real and even, so its transform is
   * real and even too, and the same in either direction: two real FFTs give
   * N * the smoothed log-magnitude, and the 1/N is divided back out. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    cl[k] = logf(mag[k] + 1e-9f);
  }
  for (int k = 1; k < LE_PV_N / 2; ++k) {
    cl[LE_PV_N - k] = cl[k];
  }
  ref_le_rfft_fwd(&ref_le_pv_fft, cl, cr, ci); /* -> cepstrum, quefrency 0 .. N/2 */
  for (int q = 0; q < LE_PV_LIFTER; ++q) cl[q] = cr[q];
  for (int q = LE_PV_LIFTER; q <= LE_PV_N - LE_PV_LIFTER; ++q) cl[q] = 0.0f;
  for (int q = 1; q < LE_PV_LIFTER; ++q) cl[LE_PV_N - q] = cr[q];
  ref_le_rfft_fwd(&ref_le_pv_fft, cl, cr, ci); /* -> N * smoothed log-magnitude */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    env[k] = expf(cr[k] / (float)LE_PV_N);
  }
}

/* One STFT analysis/synthesis frame, in four stages (the hop split, #887
 * part 9): ref_le_pv_tick runs stage k on the tick a quarter-hop k into the hop,
 * so a frame's work spreads over the callbacks of its hop. The stages pass
 * their results through o->scratch:
 *
 *   win  [LE_PV_N]    the windowed input, then the inverse transform
 *   re   [LE_PV_BINS] the spectrum, then the synthesis spectrum
 *   im   [LE_PV_BINS]
 *   mag  [LE_PV_BINS] magnitude
 *   freq [LE_PV_BINS] true frequency, in bins
 *   env  [LE_PV_BINS] the formant envelope
 *   re2, im2, phase2   a second voice's (LE_PV_S_RE2 ...)
 *
 * The frame shifts the harmonic structure by `ratio`, holding the cepstral
 * formant envelope fixed in frequency or, with p4 (formants) moved, letting
 * it go with the pitch, and overlap-adds the result into o->out from the
 * element its synthesis tick emits (LE_PV_SYNTH_TICK, so the octaver's
 * latency is LE_PV_LATENCY).
 *
 * Cost per hop per channel: four length-N real FFTs, one per stage but the
 * shift (analysis, the two cepstrum transforms, synthesis; two with the
 * formants moved, which skips the envelope stage). A second voice (the Dual
 * Octaver's Octave 2) adds a second shift in the envelope's quarter and
 * sums into the one synthesis transform. All on the shared plan
 * ref_le_pv_fft (fft.h). On the console a stereo frame cost ~170 us in one
 * callback (#1410). The stages are not equal: measured on the dev machine
 * the analysis, envelope, shift and synthesis take about 30, 31, 26 and 13 %
 * of a frame, so the heaviest callback carries about a third of it. The
 * frame's arrays live in the heap scratch, so the stack holds only each
 * stage's own temporaries. */
#define LE_PV_S_WIN(o) ((o)->scratch)
#define LE_PV_S_RE(o) ((o)->scratch + LE_PV_N)
#define LE_PV_S_IM(o) ((o)->scratch + LE_PV_N + LE_PV_BINS)
#define LE_PV_S_MAG(o) ((o)->scratch + LE_PV_N + 2 * LE_PV_BINS)
#define LE_PV_S_FREQ(o) ((o)->scratch + LE_PV_N + 3 * LE_PV_BINS)
#define LE_PV_S_ENV(o) ((o)->scratch + LE_PV_N + 4 * LE_PV_BINS)

/* Stage 0: Hann-window the newest N samples (win[N-1] is the freshest),
 * transform, and read each bin's magnitude and true frequency from its phase
 * advance. */
static void ref_le_pv_stage_analyse(le_octaver_state* o, const float* fifo,
                                int head, int cap) {
  float* win = LE_PV_S_WIN(o);
  float* re = LE_PV_S_RE(o);
  float* im = LE_PV_S_IM(o);
  float* mag = LE_PV_S_MAG(o);
  float* freq = LE_PV_S_FREQ(o);
  const float expct = 2.0f * LE_PI * (float)LE_PV_HOP / (float)LE_PV_N;
  const float osamp = (float)LE_PV_N / (float)LE_PV_HOP;
  int idx = (head - LE_PV_N + 1) % cap;
  if (idx < 0) idx += cap;
  for (int i = 0; i < LE_PV_N; ++i) {
    win[i] = fifo[idx] * ref_le_hann[i];
    if (++idx == cap) idx = 0;
  }
  ref_le_rfft_fwd(&ref_le_pv_fft, win, re, im);
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const float r = re[k];
    const float im_k = im[k];
    mag[k] = sqrtf(r * r + im_k * im_k);
    const float phase = atan2f(im_k, r);
    float d = phase - o->last_phase[k];
    o->last_phase[k] = phase;
    d -= (float)k * expct;
    d = ref_le_wrap_pi(d);
    freq[k] = (float)k + osamp * d / (2.0f * LE_PI);
  }
}

/* The most the held formants may lift a region (+18 dB). The envelope's
 * ratio between where a region lands and where it came from grows without
 * bound where the source is all but silent (an octave down from the empty
 * top of the band), and lifted the window's leakage there to the level of
 * the signal: a voice that the slightest change in the input moved
 * (#1547). */
#define LE_PV_FORMANT_MAX 8.0f

/* Stage 1: the formant envelope (ref_le_octaver_envelope); skipped for a frame
 * whose formants move with the pitch, which needs none. */
static void ref_le_pv_stage_envelope(le_octaver_state* o) {
  ref_le_octaver_envelope(LE_PV_S_MAG(o), LE_PV_S_ENV(o));
}

/* Stage 2: move each peak region by the ratio read at analysis, advance each
 * moved peak's synthesis phase (2*pi*freq*HOP/N a hop), lock the bins around
 * it to it, and rebuild the half spectrum. Holding the formants, each bin is
 * whitened (mag/env) and the envelope re-applied at the DESTINATION bin, so
 * the formants stay fixed in frequency; moving them, the magnitude goes over
 * as it is, envelope and all. [drop_dc] also drops a region whose peak
 * lands below bin 1 (the second voice's, two octaves down; the first voice
 * keeps the shipped octaver's behaviour). [by_owner]: the low band takes
 * its share of each bin by the partial that owns it (the first voice), not
 * of each region's bins wherever they land (the second; see below). */
static void ref_le_pv_shift_into(le_octaver_state* o, float ratio, float* sum_phase,
                             float* re, float* im, int drop_dc, int by_owner) {
  /* The Dual Octaver's low band (#1467) plays this share of each partial
   * below the crossover: the band's weight times what it passes at the
   * partial's peak, its boost over the crossover's low-pass there
   * (1 / (1 + (f / fc)^4), the Linkwitz-Riley pair), at most all of it.
   * The vocoder gives it up from the region's bins (the second voice) or
   * from the bins the partial owns (the first, [by_owner]; see below), so
   * the two bands sum to the whole voice on a lone partial. Where two
   * partials share bins, giving up by owner drops the other's part of a
   * bin the handed-over partial owns, and keeps the handed-over partial's
   * part of a bin the other owns: on a held 147 Hz bass the down voice's
   * second harmonic reads -8.7 dB against its fundamental (-5.4 dB by
   * region; a waveform at half speed has -6.0). None from 5 fc up (under
   * -45 dB) or with no band, which leaves the vocoder as it was. */
  const float low_w = o->frame_low_w;
  const float low_g = o->frame_low_g;
  const float kc = o->frame_low_kc;
  const float* mag = LE_PV_S_MAG(o);
  const float* freq = LE_PV_S_FREQ(o);
  const float* env = LE_PV_S_ENV(o);
  const float* in_phase = o->last_phase; /* this frame's, from the analysis */
  const float advance = 2.0f * LE_PI * (float)LE_PV_HOP / (float)LE_PV_N;
  float syn_mag[LE_PV_BINS];
  float syn_phase[LE_PV_BINS];
  float syn_best[LE_PV_BINS];
  float syn_keep[LE_PV_BINS]; /* by_owner: the share the bin's owner keeps */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    syn_mag[k] = 0.0f;
    syn_phase[k] = sum_phase[k];
    syn_best[k] = -1.0f;
    syn_keep[k] = 1.0f;
  }
  /* Peak-region shifting with identity phase locking (Laroche and Dolson,
   * 1999): each spectral peak moves to its shifted frequency carrying the
   * bins around it, and those bins keep their phases relative to the peak.
   * A partial keeps its main lobe's shape, and with it its level, at any
   * ratio; scaling each bin's index instead spread an up-shifted lobe over
   * every other bin and lost up to 13 dB at a fifth. A region runs from
   * halfway after the previous peak to halfway before the next; where two
   * regions land on one bin, the louder source sets its phase.
   *
   * With [by_owner], the first voice is shifted whole, as the plain
   * octaver's is, and the low band then takes its share of each bin in the
   * proportion it takes of the partial that set the bin's phase, its owner
   * (#1580). Taking the share of each region before the contest left a
   * handed-over partial's remainder close in level to a neighbour's lobe,
   * so the slightest change in the input decided which set the bin's
   * phase; the bin then summed with the band's voice at a phase that moved
   * with it, and the Dual Octaver's level at 44.1 and 96 kHz strayed up to
   * 3.9 dB from 48 kHz's. Judging the contest on the whole partials but
   * still taking the share region by region was steady, but left a
   * neighbour's lobe turning at the handed-over partial's phase: 1.3 dB
   * too much down voice on a 110 Hz bass. The second voice keeps the share
   * by region: whether by owner suits it too is #1616's to measure (its
   * residue at 96 kHz is its own: it strays further with the band off). */
  int peaks[LE_PV_BINS];
  int np = 0;
  for (int q = 0; q < LE_PV_BINS; ++q) {
    const float m = mag[q];
    if ((q < 1 || m > mag[q - 1]) && (q < 2 || m > mag[q - 2]) &&
        (q + 1 >= LE_PV_BINS || m >= mag[q + 1]) &&
        (q + 2 >= LE_PV_BINS || m >= mag[q + 2])) {
      peaks[np++] = q;
    }
  }
  if (np == 0) peaks[np++] = 0; /* NaN magnitudes only: one region */
  int start = 0;
  for (int r = 0; r < np; ++r) {
    const int peak = peaks[r];
    const int end = r + 1 < np ? (peak + peaks[r + 1] + 1) / 2 : LE_PV_BINS;
    const int to = (int)((float)peak * ratio + 0.5f);
    if (to >= LE_PV_BINS || (drop_dc && to < 1)) {
      /* the peak leaves the band (above it, or down onto DC): drop its
       * region */
      start = end;
      continue;
    }
    const int shift = to - peak;
    float keep = 1.0f;
    if (low_w > 0.0f) {
      const float f = freq[peak] / kc;
      if (f < 5.0f) {
        float pass = low_g / (1.0f + f * f * f * f);
        if (pass > 1.0f) pass = 1.0f;
        keep = 1.0f - low_w * pass;
      }
    }
    /* The peak's phase at its new bin: last frame's there, advanced by the
     * shifted frequency. */
    const float peak_phase = sum_phase[to] + advance * freq[peak] * ratio;
    for (int k = start; k < end; ++k) {
      const int j = k + shift;
      if (j < 0 || j >= LE_PV_BINS) continue;
      /* The source bin as it is (by_owner: the share comes off below), or
       * its region's share already off. */
      const float m = by_owner ? mag[k] : keep * mag[k];
      float fg = 1.0f;
      if (!o->frame_formants_move) {
        fg = env[j] / (env[k] + 1e-9f);
        if (fg > LE_PV_FORMANT_MAX) fg = LE_PV_FORMANT_MAX;
      }
      syn_mag[j] += m * fg;
      if (m > syn_best[j]) {
        syn_best[j] = m;
        syn_keep[j] = keep;
        syn_phase[j] =
            ref_le_wrap_pi(peak_phase + (in_phase[k] - in_phase[peak]));
      }
    }
    start = end;
  }
  for (int b = 0; b < LE_PV_BINS; ++b) {
    if (by_owner) syn_mag[b] *= syn_keep[b];
    sum_phase[b] = syn_phase[b];
    re[b] = syn_mag[b] * cosf(syn_phase[b]);
    im[b] = syn_mag[b] * sinf(syn_phase[b]);
  }
}

static void ref_le_pv_stage_shift(le_octaver_state* o) {
  ref_le_pv_shift_into(o, o->frame_ratio, o->sum_phase, LE_PV_S_RE(o),
                   LE_PV_S_IM(o), 0, 1);
}

/* The second voice's shift (#1464): the same analysis at its own ratio,
 * into its own spectrum and phases. */
static void ref_le_pv_stage_shift2(le_octaver_state* o) {
  ref_le_pv_shift_into(o, o->frame_ratio2, LE_PV_S_PHASE2(o), LE_PV_S_RE2(o),
                   LE_PV_S_IM2(o), o->frame_ratio2 < 1.0f, 0);
}

/* Stage 3: inverse transform, synthesis-window, and overlap-add from the
 * accumulator element this tick emits (the Hann x Hann windows at 4x overlap
 * sum to 1.5: divide for unity). */
static void ref_le_pv_stage_synth(le_octaver_state* o) {
  float* re = LE_PV_S_RE(o);
  float* im = LE_PV_S_IM(o);
  float level = o->frame_level1;
  if (o->frame_level2 > 0.0f) {
    /* The second voice's spectrum summed in at its level relative to the
     * first's: one inverse transform for both (it is linear). */
    const float l1 = o->frame_level1;
    const float l2 = o->frame_level2;
    const float* re2 = LE_PV_S_RE2(o);
    const float* im2 = LE_PV_S_IM2(o);
    for (int k = 0; k < LE_PV_BINS; ++k) {
      re[k] = l1 * re[k] + l2 * re2[k];
      im[k] = l1 * im[k] + l2 * im2[k];
    }
    level = 1.0f;
  }
  float* win = LE_PV_S_WIN(o);
  ref_le_rfft_inv(&ref_le_pv_fft, re, im, win);
  const float norm = level / 1.5f;
  float* out = o->out + LE_PV_SYNTH_TICK;
  for (int i = 0; i < LE_PV_N; ++i) {
    out[i] += win[i] * ref_le_hann[i] * norm;
  }
}

/* Emits one phase-vocoder output sample (latency LE_PV_LATENCY), running a
 * frame's stage at each quarter of the hop and streaming the synthesis
 * accumulator out by one sample per call, shifting it down by a hop once a
 * hop is fully emitted.
 *
 * HOP PHASE AND THE THREE THINGS IT MUST NOT MOVE. hop_count starts at any
 * value p in [0, LE_PV_HOP) (ref_le_oct_seeded_ticks: whatever puts the
 * analysis ticks on the instance's frames of the engine clock), so the first
 * analysis runs at tick (LE_PV_HOP - p) % LE_PV_HOP + 1 instead of tick 1:
 *
 *  1. Reported latency. A frame analysed with the FIFO head at H covers input
 *     [H - N + 1, H]. Its synthesis runs LE_PV_SYNTH_TICK (S) ticks later,
 *     with the head at H + S, and overlap-adds at out[S ..]: frame sample s
 *     sits at out[S + s] in that hop's frame of reference, and is emitted
 *     when the head is H + S + s (the shift at each hop's end moves it and
 *     the read position together). The emitted sample therefore corresponds
 *     to input (head - N - S + 1) for every p: latency stays LE_PV_LATENCY.
 *  2. The dry-delay match (ref_fx_octaver's tap at head - latency + 1) is the same
 *     index, so wet and dry stay aligned at every phase.
 *  3. fx_apply_chain's warmup (LE_PV_LATENCY ticks, output discarded). The
 *     argument is the unsplit one moved S ticks later: the worst phase's
 *     fourth frame lands on tick LE_PV_LATENCY exactly, so the first ramped
 *     sample is complete at every phase, with no margin.
 *     test_octaver_hop_stagger_alignment sweeps all LE_PV_HOP phases and
 *     fails with a warmup one sample shorter.
 *
 * A stage whose tick comes before the first analysis after a reset is
 * skipped (o->analysed), so a reset never synthesises a stale frame. */
static float ref_le_pv_tick(le_octaver_state* o, const float* fifo, int head, int cap,
                        float ratio, int formants_move, float ratio2,
                        float level1, float level2, float low_w,
                        float low_g, float low_kc) {
  if (o->out == NULL || o->scratch == NULL) return 0.0f;
  switch (o->hop_count) {
    case 0:
      ref_le_pv_stage_analyse(o, fifo, head, cap);
      o->frame_ratio = ratio;
      o->frame_formants_move = formants_move;
      o->frame_ratio2 = ratio2;
      o->frame_level1 = level1;
      o->frame_low_w = low_w;
      o->frame_low_g = low_g;
      o->frame_low_kc = low_kc;
      {
        /* A second voice (the Dual Octaver's Octave 2, #1464) takes the
         * envelope's quarter, so only with the formants moving; coming
         * back from silence it starts its phases afresh. */
        const float l2 = formants_move ? level2 : 0.0f;
        if (l2 > 0.0f && o->frame_level2 <= 0.0f) {
          memset(LE_PV_S_PHASE2(o), 0, sizeof(float) * LE_PV_BINS);
        }
        o->frame_level2 = l2;
      }
      o->analysed = 1;
      break;
    case LE_PV_HOP / 4:
      if (o->analysed && !o->frame_formants_move) ref_le_pv_stage_envelope(o);
      if (o->analysed && o->frame_level2 > 0.0f) ref_le_pv_stage_shift2(o);
      break;
    case LE_PV_HOP / 2:
      if (o->analysed) ref_le_pv_stage_shift(o);
      break;
    case LE_PV_SYNTH_TICK:
      if (o->analysed) ref_le_pv_stage_synth(o);
      break;
    default:
      break;
  }
  const float y = o->out[o->hop_count];
  if (++o->hop_count >= LE_PV_HOP) {
    memmove(o->out, o->out + LE_PV_HOP, sizeof(float) * (LE_PV_OUT - LE_PV_HOP));
    memset(o->out + (LE_PV_OUT - LE_PV_HOP), 0, sizeof(float) * LE_PV_HOP);
    o->hop_count = 0;
  }
  return y;
}

/* YIN pitch detection (see engine_internal.h). Plain autocorrelation
 * peak-picking is prone to octave errors — a sub/multiple of the true period
 * correlates nearly as well — and a mis-spaced grain wrecks both pitch and
 * formants, so the modest extra cost of YIN's cumulative-mean normalization
 * is worth it for the PSOLA octaver. */

/* ---- Resumable YIN pass (see le_yin_pass in engine_private.h) --------------
 *
 * The three steps below ARE le_psola_detect_band, split at the two points a
 * caller can pause at: before the difference function and after it. The
 * tuner and the PSOLA octaver run ref_le_yin_step a slice at a time across
 * callbacks. The
 * arithmetic is byte-identical either way, which is the whole point of the
 * split — there is no second copy of the detector to keep in step. */

static int ref_le_yin_begin(le_yin_pass* p, const float* x, int n, int sr, int min_hz,
                 int max_hz, float* dp, int dp_cap) {
  p->x = x;
  p->dp = dp;
  p->tau = 1;
  p->cum = 0.0;
  p->minlag = 0;
  p->maxlag = 0;
  p->integ = 0;
  if (min_hz <= 0 || max_hz <= min_hz) return 0;
  int minlag = sr / max_hz;
  if (minlag < 2) minlag = 2;
  int maxlag = sr / min_hz;
  if (maxlag > LE_PSOLA_MAXLAG) maxlag = LE_PSOLA_MAXLAG;
  if (maxlag > n / 2) maxlag = n / 2;
  if (maxlag <= minlag) return 0;
  if (dp_cap < maxlag + 1) return 0;
  const int integ = n - maxlag; /* difference-function integration length */

  /* Silence floor: never run the detector on the noise floor (avoids reporting a
   * spurious "pitch" for hiss); a quiet frame reads as unvoiced. */
  double energy = 0.0;
  for (int i = 0; i < integ; ++i) energy += (double)x[i] * (double)x[i];
  if (energy < (double)integ * 1e-7) return 0;

  p->minlag = minlag;
  p->maxlag = maxlag;
  p->integ = integ;
  dp[0] = 1.0f;
  return 1;
}

static int ref_le_yin_step(le_yin_pass* p, long budget) {
  /* Difference function d(tau), then its cumulative-mean normalization d'(tau).
   * One whole lag always runs, however small the budget: a caller whose budget
   * is under one integration length must still make progress, or the pass
   * stalls forever. One lag is bounded by n/2 inner iterations. */
  while (p->tau <= p->maxlag) {
    double sum = 0.0;
    const int tau = p->tau;
    for (int i = 0; i < p->integ; ++i) {
      const float diff = p->x[i] - p->x[i + tau];
      sum += (double)diff * (double)diff;
    }
    p->cum += sum;
    p->dp[tau] = p->cum > 0.0 ? (float)(sum * (double)tau / p->cum) : 1.0f;
    ++p->tau;
    if (budget >= 0) {
      budget -= p->integ;
      if (budget <= 0) break;
    }
  }
  return p->tau > p->maxlag;
}

static int ref_le_yin_finish(const le_yin_pass* p, float* out_period, float* out_voiced) {
  const float* dp = p->dp;
  const int minlag = p->minlag;
  const int maxlag = p->maxlag;

  /* A rejected ref_le_yin_begin leaves minlag == maxlag == 0 and never writes
   * dp[0], but ref_le_yin_step still reports "done" (tau 1 > maxlag 0). A caller
   * that ignores ref_le_yin_begin's return would land here and read dp[0]
   * uninitialised, yielding a garbage period at conf = 1 - garbage. The
   * symmetric misuse -- finishing before ref_le_yin_step has reported done --
   * reads dp[tau..maxlag] uninitialised for the same result, so tau is
   * checked here too. Both callers are correct today; le_yin_* is published in
   * engine_fx.h now, so the failed states answer "no pitch" themselves rather
   * than depending on every future caller. */
  if (minlag < 2 || maxlag <= minlag || p->tau <= maxlag) {
    *out_period = 0.0f;
    *out_voiced = 0.0f;
    return 0;
  }

  /* First dip below the absolute threshold, walked down to its local minimum;
   * fall back to the global minimum (low confidence) when nothing crosses. */
  int tau = -1;
  for (int t = minlag; t <= maxlag; ++t) {
    if (dp[t] < LE_PSOLA_THRESH) {
      while (t + 1 <= maxlag && dp[t + 1] < dp[t]) ++t;
      tau = t;
      break;
    }
  }
  if (tau < 0) {
    float best = dp[minlag];
    tau = minlag;
    for (int t = minlag + 1; t <= maxlag; ++t) {
      if (dp[t] < best) {
        best = dp[t];
        tau = t;
      }
    }
  }

  /* Parabolic interpolation around the chosen lag for a sub-sample period. */
  float period = (float)tau;
  if (tau > minlag && tau < maxlag) {
    const float s0 = dp[tau - 1];
    const float s1 = dp[tau];
    const float s2 = dp[tau + 1];
    const float denom = s0 + s2 - 2.0f * s1;
    if (fabsf(denom) > 1e-9f) period = (float)tau + 0.5f * (s0 - s2) / denom;
  }

  float conf = 1.0f - dp[tau];
  if (conf < 0.0f) conf = 0.0f;
  if (conf > 1.0f) conf = 1.0f;
  *out_period = period;
  *out_voiced = conf;
  return conf > 0.5f ? 1 : 0;
}

static int ref_le_refine_begin(le_lag_refine* r, float coarse, int span, int n) {
  if (span < 1 || span > LE_REFINE_SPAN_MAX) return 0;
  const int lo = (int)coarse - span;
  const int hi = (int)coarse + span + 1;
  if (lo < 2 || hi >= n / 2) return 0;
  r->lo = lo;
  r->hi = hi;
  r->integ = n - hi;
  r->tau = lo;
  r->best = 0;
  return 1;
}

static int ref_le_refine_step(le_lag_refine* r, const float* x, long budget) {
  while (r->tau <= r->hi) {
    const int tau = r->tau;
    double sum = 0.0;
    for (int i = 0; i < r->integ; ++i) {
      const float df = x[i] - x[i + tau];
      sum += (double)df * (double)df;
    }
    const int k = tau - r->lo;
    r->d[k] = (float)sum;
    if (tau == r->lo || r->d[k] < r->d[r->best]) r->best = k;
    ++r->tau;
    budget -= r->integ;
    if (budget <= 0) break;
  }
  return r->tau > r->hi;
}

static float ref_le_refine_finish(const le_lag_refine* r, float coarse) {
  if (r->best == 0 || r->best == r->hi - r->lo) return coarse;
  const float s0 = r->d[r->best - 1];
  const float s1 = r->d[r->best];
  const float s2 = r->d[r->best + 1];
  const float denom = s0 + s2 - 2.0f * s1;
  float refined = (float)(r->lo + r->best);
  if (fabsf(denom) > 1e-9f) refined += 0.5f * (s0 - s2) / denom;
  return refined;
}


/* ---- PSOLA's sliced pitch detection (#913) ---------------------------------
 *
 * A whole YIN pass over the old 1600-sample window was ~640k iterations in one
 * callback every hop: about 1.1 ms on the console, over the 667 us deadline
 * of a 64-frame period at 96 kHz. The pass now runs on a window decimated
 * by LE_PSOLA_DECIM (a boxcar is the decimator and its own anti-alias
 * filter, as the tuner's), so it searches down to 60 Hz for a fraction of
 * the work, then refines at the kernel's rate around the coarse lag
 * (le_refine_*),
 * and both are spread over the hop: each tick adds LE_PSOLA_WORK_PER_TICK to
 * a credit the pass spends, and a lag that overshoots it leaves a debt the
 * next ticks pay, so the pass averages exactly that much a tick. The
 * decimated window is frozen into the scratch when the pass starts, and the
 * kernel-rate one when the refinement starts, up to a hop later (the ring
 * still holds it: LE_OCT_REACH), so the moving ring cannot change either
 * under the pass. The result lands
 * within the hop it was started in, a hop at most after the one-shot pass's
 * would have: the period and the voicing it feeds are smoothed over several
 * hops anyway. */
#define LE_PS_WIN(o) ((o)->scratch)
#define LE_PS_DP(o) ((o)->scratch + LE_PSOLA_DWIN)
#define LE_PS_RAW(o) ((o)->scratch + LE_PSOLA_DWIN + LE_PSOLA_DWIN / 2 + 1)
_Static_assert(LE_PSOLA_DECIM <= LE_REFINE_SPAN_MAX,
               "PSOLA's refinement span fits le_lag_refine");
_Static_assert(LE_PSOLA_DECIM * LE_PSOLA_DWIN <= LE_PSOLA_RAW,
               "PSOLA's decimated window lies inside its refinement window");

/* Feeds a finished detection into the smoothed voicing and period, as the
 * one-shot pass did: the voicing follows every result, the period only a
 * pitched one (it holds through gaps). */
static void ref_le_psola_pass_apply(le_octaver_state* o, float period,
                                float voiced) {
  le_ps(o)->phase = 0;
  o->voiced += 0.35f * (voiced - o->voiced); /* chatter-free soft gate */
  if (period > 0.0f) {
    o->period =
        o->period <= 0.0f ? period : o->period + 0.5f * (period - o->period);
  }
}

/* Starts a detection over the input ending at FIFO index [end]: freezes the
 * decimated window into the scratch and opens the coarse pass, charging the
 * decimation to the pass's credit. Any pass still in flight is dropped. A
 * silent window settles at once as unvoiced. */
static void ref_le_psola_pass_begin(le_octaver_state* o, const float* fifo,
                                int end, int cap) {
  le_psola_pass* ps = le_ps(o);
  const int d = LE_PSOLA_DECIM;
  float* win = LE_PS_WIN(o);
  end %= cap;
  if (end < 0) end += cap;
  int idx = (end - LE_PSOLA_DWIN * d + 1) % cap;
  if (idx < 0) idx += cap;
  const float inv = 1.0f / (float)d;
  for (int i = 0; i < LE_PSOLA_DWIN; ++i) {
    float acc = 0.0f;
    for (int k = 0; k < d; ++k) {
      acc += fifo[idx];
      if (++idx == cap) idx = 0;
    }
    win[i] = acc * inv;
  }
  ps->end = end;
  ps->credit -= LE_PSOLA_DWIN * d;
  if (!ref_le_yin_begin(&ps->yin, win, LE_PSOLA_DWIN, LE_OCT_RATE / d, LE_PSOLA_MIN_HZ,
                    LE_PSOLA_MAX_HZ, LE_PS_DP(o), LE_PSOLA_DWIN / 2 + 1)) {
    ref_le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  ps->phase = 1;
}

/* Hands the finished coarse pass to the refinement, freezing the kernel-rate
 * window it walks, or applies the coarse period as it is when refining would
 * not change what plays: a period too long for two of it to fit the
 * kernel-rate window, or a frame under the voicing gate (ref_fx_octaver's dry
 * fallback takes it whatever its period). */
static void ref_le_psola_coarse_done(le_octaver_state* o, const float* fifo,
                                 int cap) {
  le_psola_pass* ps = le_ps(o);
  float period = 0.0f;
  ref_le_yin_finish(&ps->yin, &period, &ps->conf);
  if (period <= 0.0f) {
    ref_le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  ps->coarse = period * (float)LE_PSOLA_DECIM;
  if (ps->conf < 0.3f ||
      !ref_le_refine_begin(&ps->ref, ps->coarse, LE_PSOLA_DECIM, LE_PSOLA_RAW)) {
    ref_le_psola_pass_apply(o, ps->coarse, ps->conf);
    return;
  }
  float* raw = LE_PS_RAW(o);
  int idx = (ps->end - LE_PSOLA_RAW + 1) % cap;
  if (idx < 0) idx += cap;
  for (int i = 0; i < LE_PSOLA_RAW; ++i) {
    raw[i] = fifo[idx];
    if (++idx == cap) idx = 0;
  }
  ps->credit -= LE_PSOLA_RAW;
  ps->phase = 2;
}

/* One tick of detection: starts a pass on each hop, adds the tick's work to
 * the credit and, while it is positive, spends it on lags (a lag is never
 * split, so the last one may overshoot into a debt), carrying from the coarse
 * pass into the refinement, and applies the result once the refinement is
 * in. [hop] is set on the tick a PSOLA hop begins. */
static void ref_le_psola_pass_tick(le_octaver_state* o, const float* fifo, int end,
                               int cap, int hop) {
  le_psola_pass* ps = le_ps(o);
  if (hop) ref_le_psola_pass_begin(o, fifo, end, cap);
  const int32_t work = LE_PSOLA_WORK_PER_TICK;
  ps->credit += work;
  if (ps->credit > work) ps->credit = work; /* no banking while idle */
  while (ps->credit > 0 && ps->phase != 0) {
    if (ps->phase == 1) {
      const int32_t was = ps->yin.tau;
      const int done = ref_le_yin_step(&ps->yin, ps->credit);
      ps->credit -= (ps->yin.tau - was) * ps->yin.integ;
      if (done) ref_le_psola_coarse_done(o, fifo, cap);
      continue;
    }
    const int32_t was = ps->ref.tau;
    const int done = ref_le_refine_step(&ps->ref, LE_PS_RAW(o), ps->credit);
    ps->credit -= (ps->ref.tau - was) * ps->ref.integ;
    if (done) {
      ref_le_psola_pass_apply(o, ref_le_refine_finish(&ps->ref, ps->coarse), ps->conf);
    }
  }
}

/* Added latency (frames) of the active octaver. Single source of truth, read in
 * two places: the dry-delay match in ref_fx_octaver (D2), and — per the part-5 plan —
 * the control thread, which folds it into the published snapshot so the UI can
 * warn about monitoring lag. PSOLA reuses the PV's OLA accumulator (the no-
 * extra-allocation budget part 3 fixed); its grain centers sit LE_PV_N behind the
 * input it reads, and it reads LE_PSOLA_LAG further back than the head, so its
 * latency equals the phase vocoder's. Both modes therefore report LE_PV_LATENCY
 * and the dry tap does not jump on a switch. The argument is the per-mode seam a
 * future dedicated PSOLA buffer (lower latency) would use. */
static int ref_le_octaver_latency(const le_octaver_state* o) {
  (void)o;
  return LE_PV_LATENCY;
}

/* TD-PSOLA pitch shift (mode >= 0.5). Grains are repositioned but never resampled,
 * so the grain's spectral shape — the formants — stays fixed while the epoch
 * repetition rate changes the pitch. Lowest-latency, most natural on solo voice;
 * polyphonic/transient input reads as unvoiced (low YIN confidence) and falls back
 * to the delay-matched dry, and silence collapses to dry (~0). A one-pole-smoothed
 * confidence drives a soft voiced<->unvoiced crossfade (no dry<->wet chatter). The
 * synthesis OLA reuses o->out as a circular accumulator (PSOLA's circular access
 * and the phase vocoder's linear+memmove access never coexist — the mode switch
 * resets the shared buffer at the gain-dip bottom; no new allocation either way).
 *
 * Analysis marks are uniform (period-spaced), not true glottal-closure instants —
 * the plan's deliberate "it's an effect, not speech-synthesis" choice. The cost is
 * that a pulse-less, near-pure tone (e.g. a flute/whistle/sine) can self-cancel on
 * a large up-shift, where same-period grains land antiphase; harmonic-rich voice
 * (the documented sweet spot) has localized epochs and reinforces. */
static float ref_le_psola_tick(le_octaver_state* o, const float* fifo, int head,
                           int cap, float ratio) {
  if (o->out == NULL) return 0.0f;
  const int N = LE_PV_N;
  /* PSOLA works on the input LE_PSOLA_LAG ticks back (its pitch window, its
   * grain sources and its dry fallback), so its latency matches the split
   * phase vocoder's. */
  const int lag = LE_PSOLA_LAG;
  const int sr = LE_OCT_RATE; /* the kernel's rate; cap is the ring's length */

  /* 1. Emit one sample from the circular OLA accumulator, clearing it behind. */
  const int rp = o->out_pos;
  const float y = o->out[rp];
  o->out[rp] = 0.0f;
  o->out_pos = (rp + 1 >= N) ? 0 : rp + 1;

  /* 2. Periodic pitch analysis: a detection starts every hop over the input
   *    ending `lag` back, and runs a slice every tick (le_psola_pass_*). */
  const int hop = --o->hop_count <= 0;
  if (hop) o->hop_count = LE_PSOLA_AHOP;
  ref_le_psola_pass_tick(o, fifo, head - lag, cap, hop);

  /* 3. Synthesis: marks recede from the head one sample per tick; at each
   *    synthesis mark deposit a Hann grain whose source snaps to the nearest
   *    analysis mark, so the grain spacing (pitch) changes by `ratio` while the
   *    grain shape (formant envelope) does not. */
  o->in_epoch += 1.0f;
  o->out_epoch -= 1.0f;
  if (o->out_epoch <= 0.0f) {
    float pf = o->period; /* sub-sample period: sets the grain spacing (pitch) */
    if (pf < 2.0f) pf = 2.0f;
    if (pf > (float)(sr / LE_PSOLA_MIN_HZ)) pf = (float)(sr / LE_PSOLA_MIN_HZ);
    float ps = pf / ratio; /* synthesis spacing -> output pitch = ratio * f0 */
    if (ps < 1.0f) ps = 1.0f;
    /* Both marks keep their fractions (#1480): the synthesis mark fell
     * [late] samples before this tick, so the grain is laid that much
     * earlier, and the analysis marks step by the period itself, so each
     * grain's source lies whole periods after the last one's. The grains
     * then repeat the input's own waveform at the new spacing, and the
     * output is the input times the ratio. Rounded to whole samples, either
     * put a 880 Hz voice at 48 kHz up to 16 cents off the ratio. */
    float late = -o->out_epoch;
    if (late > 1.0f) late = 1.0f;
    o->out_epoch += ps;

    int th = (int)(pf + 0.5f);
    if (th > LE_PSOLA_THMAX) th = LE_PSOLA_THMAX;
    const int c = N / 2;  /* grain center offset ahead of the read pointer */
    const float dn = (float)(N - c + lag); /* nominal source distance behind the head */
    /* Snap the analysis mark to the nearest of the period-spaced grid near dn. */
    while (o->in_epoch - dn > 0.5f * pf) o->in_epoch -= pf;
    while (dn - o->in_epoch > 0.5f * pf) o->in_epoch += pf;
    /* Keep the grain read causal: a mark too near the head moves on by whole
     * periods, so it stays on the period grid (a long period at a high rate
     * can snap it under th). */
    while (o->in_epoch < (float)(th + 1)) o->in_epoch += pf;
    if (o->in_epoch > (float)(cap - 1 - th)) o->in_epoch = (float)(cap - 1 - th);
    /* The grain's source centre, a whole sample and the fraction past it. */
    const float at = late - o->in_epoch;
    const int base = (int)floorf(at);
    const float fr = at - (float)base;

    /* COLA gain: Hann area (= th) over the hop (= ps) keeps the overlap-add near
     * unity across the shift; clamp so a clamped grain cannot blow up. */
    float gain = ps / (float)th;
    if (gain > 2.0f) gain = 2.0f;
    for (int j = -th; j <= th; ++j) {
      const float wf =
          0.5f - 0.5f * cosf(LE_PI * (float)(j + th) / (float)th); /* Hann */
      int src = head + base + j;
      src %= cap;
      if (src < 0) src += cap;
      const int next = src + 1 >= cap ? 0 : src + 1;
      int dst = rp + c + j;
      dst %= N;
      if (dst < 0) dst += N;
      o->out[dst] += gain * wf * (fifo[src] + fr * (fifo[next] - fifo[src]));
    }
  }

  /* 4. Soft voiced/unvoiced gate (D4): crossfade the grain voice against the
   *    delay-matched dry by the smoothed confidence. Silence -> voiced ~0 and the
   *    dry tap is ~0, so the output collapses to silence (no grain buzz). */
  int didx = head - ref_le_octaver_latency(o) + 1;
  didx %= cap;
  if (didx < 0) didx += cap;
  const float dry = fifo[didx];
  float wv = (o->voiced - 0.3f) / 0.3f; /* soft gate around conf ~0.3..0.6 */
  if (wv < 0.0f) wv = 0.0f;
  if (wv > 1.0f) wv = 1.0f;
  return wv * y + (1.0f - wv) * dry;
}

/* ---- The Dual Octaver's low band (#1467; engine_fx.h) ----------------------
 *
 * Per channel: ref_le_low_write low-passes every input sample into the band's
 * ring and its decimated detection ring, ref_le_low_follow tracks its pitch
 * and weight, ref_le_low_play plays the two down voices from the ring.
 *
 * Why resampled taps and not the octaver's PSOLA grains: below the
 * crossover a note is nearly one sinusoid, and a grain laid without
 * resampling keeps its waveform's frequency, so the octaver's PSOLA drops a
 * 110 Hz sine an octave as 110 Hz at 0 dB and 55 Hz at -6 dB. A tap read
 * at half speed plays 55 Hz alone, as the Looper X does (55 Hz at 0.0 dB,
 * 110 Hz at -72 dB in the s7oct capture). */

/* The band's per-sample constants at the kernel's rate: the 50, 10 and
 * 5 ms one-poles' steps, the shortest and longest periods searched (kernel
 * samples), and the crossover in phase-vocoder bins, where the vocoder
 * hands over. */
#define LE_OCT_LOW_EK (20.0f / (float)LE_OCT_RATE)
#define LE_OCT_LOW_K10 (100.0f / (float)LE_OCT_RATE)
#define LE_OCT_LOW_K5 (200.0f / (float)LE_OCT_RATE)
#define LE_OCT_LOW_PER_MIN ((float)LE_OCT_RATE / (float)LE_OCT_LOW_MAX_HZ)
#define LE_OCT_LOW_PER_MAX ((float)LE_OCT_RATE / (float)LE_OCT_LOW_MIN_HZ)
#define LE_OCT_LOW_KC \
  ((float)(LE_OCT_LOW_HZ * (double)LE_PV_N / (double)LE_OCT_RATE))
#define LE_OCT_LOW_MASK (LE_OCT_LOW_RING - 1)
_Static_assert((LE_OCT_LOW_RING & LE_OCT_LOW_MASK) == 0,
               "the low band's ring is a power of two");
_Static_assert(LE_OCT_LOW_RING >=
                   LE_PV_LATENCY + 2 * (LE_OCT_RATE / LE_OCT_LOW_MIN_HZ) + 8,
               "the low band's ring holds the deepest tap");

/* The voices' runtime back to a reset's, as the vocoder's is on a reset or
 * a High Mode switch: silent for the frames the vocoder has not analysed
 * yet, each tap centred. The detection keeps what it heard (it runs in
 * either mode), so a note held across the switch is handed over at once. */
static void ref_le_low_reset_runtime(le_oct_low* L) {
  L->level1 = 0.0f;
  L->level2 = 0.0f;
  for (int k = 0; k < 4; ++k) L->hold[k] = 0.0f;
  L->hold_at = 0;
  for (int k = 0; k < 2; ++k) {
    L->v[k].d = L->centre;
    L->v[k].d_old = L->centre;
    L->v[k].fade = 0;
    L->v[k].fade_len = 1;
  }
}

/* The detection back to a reset's: no pitch heard, the band silent (the
 * vocoder plays all of it), and nothing in its crossover, window or power
 * followers, so it hears only what comes in from now. The ring keeps its
 * audio: a new note takes a detection window and the hand-over's delay to
 * reach the voices, by which time the taps read only new input. */
static void ref_le_low_forget(le_oct_low* L) {
  memset(L->z, 0, sizeof(L->z));
  memset(L->dring, 0, sizeof(L->dring));
  L->dn = 0;
  L->dacc = 0.0f;
  L->dhead = 0;
  L->e_in = 0.0f;
  L->e_low = 0.0f;
  L->busy = 0;
  L->credit = 0;
  L->period = 0.0f;
  L->f0 = 0.0f;
  L->voiced = 0.0f;
  L->gate = 0.0f;
  L->boost = 1.0f;
  L->ramp = 0.0f;
}



/* Writes input sample [x] through the crossover into the ring, and the
 * decimator, and follows the input's and the band's power. */
static void ref_le_low_write(le_oct_low* L, float x) {
  L->e_in += (x * x - L->e_in) * LE_OCT_LOW_EK;
  const float y = ref_le_biquad_tick(L->lp, L->z[1],
                                 ref_le_biquad_tick(L->lp, L->z[0], x));
  L->e_low += (y * y - L->e_low) * LE_OCT_LOW_EK;
  L->head = (L->head + 1) & LE_OCT_LOW_MASK;
  L->ring[L->head] = y;
  L->dacc += y;
  if (++L->dn >= LE_OCT_LOW_DECIM) {
    L->dring[L->dhead] = L->dacc / (float)LE_OCT_LOW_DECIM;
    if (++L->dhead >= LE_OCT_LOW_DWIN) L->dhead = 0;
    L->dacc = 0.0f;
    L->dn = 0;
  }
}

/* The band [d] samples behind its head, linearly interpolated (d >= 1). */
static float ref_le_low_read(const le_oct_low* L, float d) {
  const float rp = (float)L->head - d;
  const float fl = floorf(rp);
  const int32_t i = (int32_t)fl;
  const float a = L->ring[i & LE_OCT_LOW_MASK];
  return a + (rp - fl) * (L->ring[(i + 1) & LE_OCT_LOW_MASK] - a);
}

/* A finished detection. Only a confident one counts as voiced, and it
 * sets the period, so the band never plays at a weight whose pitch it has
 * not got. The period steps to a new note rather than gliding there (a tap
 * jumping by a period between two notes' would not land on a repeat of the
 * waveform). */
static void ref_le_low_apply(le_oct_low* L, float period, float conf) {
  const int sure = period > 0.0f && conf >= 0.5f;
  L->voiced += 0.35f * ((sure ? conf : 0.0f) - L->voiced);
  if (!sure) return;
  if (L->period <= 0.0f || fabsf(period - L->period) > 0.03f * L->period) {
    L->period = period;
  } else {
    L->period += 0.5f * (period - L->period);
  }
  if (L->period < LE_OCT_LOW_PER_MIN) L->period = LE_OCT_LOW_PER_MIN;
  if (L->period > LE_OCT_LOW_PER_MAX) L->period = LE_OCT_LOW_PER_MAX;
  L->f0 = (float)LE_OCT_RATE / L->period;
}

/* One tick of detection: on each analysis tick of the vocoder (the hop's,
 * so the pass runs on the instance's own schedule) freeze the
 * decimated window and start a YIN pass, then spend the tick's credit on it,
 * as PSOLA's sliced pass does (ref_le_psola_pass_tick). A band holding under a
 * twentieth of the input's power carries no note of its own (a tone above
 * the crossover leaks into it): no pitch, and no pass. */
static void ref_le_low_detect(le_oct_low* L, int analysis) {
  if (analysis) {
    if (L->e_low < 0.05f * L->e_in) {
      L->busy = 0;
      ref_le_low_apply(L, 0.0f, 0.0f);
      return;
    }
    int32_t k = L->dhead; /* the oldest decimated sample */
    for (int i = 0; i < LE_OCT_LOW_DWIN; ++i) {
      L->win[i] = L->dring[k];
      if (++k == LE_OCT_LOW_DWIN) k = 0;
    }
    L->busy = ref_le_yin_begin(&L->yin, L->win, LE_OCT_LOW_DWIN,
                           LE_OCT_RATE / LE_OCT_LOW_DECIM,
                           LE_OCT_LOW_MIN_HZ, LE_OCT_LOW_MAX_HZ, L->dp,
                           LE_OCT_LOW_DWIN / 2 + 1);
    if (L->busy) {
      /* The pass's lags spread over the ticks until the next one starts,
       * with a quarter to spare. */
      L->work = (5 * L->yin.maxlag * L->yin.integ) / (4 * LE_PV_HOP) + 1;
    } else {
      ref_le_low_apply(L, 0.0f, 0.0f); /* silence */
    }
  }
  if (!L->busy) return;
  L->credit += L->work;
  if (L->credit > L->work) L->credit = L->work; /* no banking while idle */
  while (L->credit > 0 && L->busy) {
    const int32_t was = L->yin.tau;
    const int done = ref_le_yin_step(&L->yin, L->credit);
    L->credit -= (L->yin.tau - was) * L->yin.integ;
    if (done) {
      float period = 0.0f;
      float conf = 0.0f;
      ref_le_yin_finish(&L->yin, &period, &conf);
      L->busy = 0;
      /* A dip still falling at the longest lag is a note below the floor
       * (a 55 Hz sine reads as 60 Hz there), and one at the shortest a note
       * above the range read as a multiple of its period: no pitch. */
      if (period >= (float)(L->yin.maxlag - 1) ||
          period <= (float)(L->yin.minlag + 1)) {
        conf = 0.0f;
      }
      ref_le_low_apply(L, period * (float)LE_OCT_LOW_DECIM, conf);
    }
  }
}

/* One sample of a voice at [ratio] (1/2 for Octave 1, 1/4 for Octave 2):
 * the band read through a tap whose delay grows by 1 - ratio a sample (the
 * tap moves at the ratio, so the band plays that much lower). Once the
 * delay reaches the top of its range the tap jumps one input period
 * [per] nearer the head, where the waveform repeats, and fades from the
 * old tap over a quarter of the time to the next jump. A tap running from
 * lo to lo + per with that fade spends its time at lo + 0.625 per on
 * average, so lo centres it on L->centre (about 1130 samples), which
 * leaves room for the band's longest period (800 samples, its 60 Hz
 * floor). */
static float ref_le_low_voice(le_oct_low* L, le_oct_low_voice* v, float ratio,
                          float per) {
  float y = ref_le_low_read(L, v->d);
  const float step = 1.0f - ratio;
  if (v->fade > 0) {
    const float t = (float)v->fade / (float)v->fade_len; /* 1 down to 0 */
    const float w = t * t * (3.0f - 2.0f * t);
    y += w * (ref_le_low_read(L, v->d_old) - y);
    v->d_old += step;
    --v->fade;
  }
  v->d += step;
  float lo = L->centre - 0.625f * per;
  if (lo < 2.0f) lo = 2.0f;
  if (v->fade == 0 && v->d >= lo + per) {
    v->d_old = v->d;
    v->d -= per;
    int32_t len = (int32_t)(0.25f * per / step);
    if (len < 1) len = 1;
    v->fade_len = len;
    v->fade = len;
  }
  if (v->d > (float)(LE_OCT_LOW_MASK - 2) ||
      v->d_old > (float)(LE_OCT_LOW_MASK - 2)) {
    v->d = lo; /* a period change left the tap past the ring: restart */
    v->d_old = lo;
    v->fade = 0;
  }
  return y;
}

/* The band's detection and weight for one sample, in either High Mode:
 * the detection's tick ([analysis]: the vocoder's analysis tick), then the
 * band's weight (the voicing), its boost and its floor's ramp, each
 * following in 10 ms (one-pole). On the analysis tick it keeps the product
 * for the voices, which play it once the frame analysed now is heard.
 *
 * The note's fundamental is handed over whole: the band is boosted by the
 * crossover's loss at the detected pitch (1 + (f0 / fc)^4, up to 2 at the
 * crossover), and the vocoder gives up the same share of the note's
 * partial (ref_le_pv_shift_into: of the bins it owns in the first voice, of its
 * region in the second), so a note near the crossover is not split between
 * two voices whose phases differ. A note above the crossover is left to the
 * vocoder, the band fading out by 1.15 fc. The voices come in over a
 * smoothstep from LE_OCT_LOW_MIN_HZ, where the Looper X's start
 * (engine_fx.h): their level only, as the Looper X plays no other voice
 * there, so the vocoder still hands the note over. */
static void ref_le_low_follow(le_oct_low* L, int analysis) {
  ref_le_low_detect(L, analysis);
  const float f0 = L->f0;
  float want = (L->voiced - 0.3f) / 0.3f; /* PSOLA's soft gate */
  if (want < 0.0f || f0 <= 0.0f) want = 0.0f;
  if (want > 1.0f) want = 1.0f;
  float in = (f0 - (float)LE_OCT_LOW_MIN_HZ) /
             (LE_OCT_LOW_FULL_HZ - (float)LE_OCT_LOW_MIN_HZ);
  if (in < 0.0f) in = 0.0f;
  if (in > 1.0f) in = 1.0f;
  in *= in * (3.0f - 2.0f * in);
  const float x = f0 / (float)LE_OCT_LOW_HZ;
  float boost = 2.0f;
  if (x <= 1.0f) {
    boost = 1.0f + x * x * x * x;
  } else {
    want *= x >= 1.15f ? 0.0f : (1.15f - x) / 0.15f;
  }
  const float k = LE_OCT_LOW_K10;
  L->gate += (want - L->gate) * k;
  if (want == 0.0f && L->gate < 1e-4f) L->gate = 0.0f;
  L->boost += (boost - L->boost) * k;
  L->ramp += (in - L->ramp) * k;
  if (analysis) {
    L->hold_at = (L->hold_at + 1) & 3;
    L->hold[L->hold_at] = L->gate * L->boost * L->ramp;
  }
}

/* How many samples after its analysis tick the vocoder's frame is heard:
 * its middle (LE_PV_N / 2 before the tick) leaves the octaver
 * LE_PV_LATENCY after it went in. */
#define LE_OCT_LOW_HOLD (LE_PV_LATENCY - LE_PV_N / 2)

/* The low band's two down voices for one sample, at [level1] (Octave 1)
 * and [level2] (Octave 2), [ticks] after the vocoder's last analysis tick.
 * They play the band's weight from LE_OCT_LOW_HOLD samples ago (between the
 * two analysis ticks around then): the share the vocoder's frame playing
 * now gave up, so the two sum to one voice while the weight moves too. A
 * band with no weight plays nothing, and stops reading. */
static float ref_le_low_play(le_oct_low* L, int ticks, float level1,
                         float level2) {
  const float k = LE_OCT_LOW_K5;
  L->level1 += (level1 - L->level1) * k;
  L->level2 += (level2 - L->level2) * k;
  const float back = (float)(LE_OCT_LOW_HOLD - ticks) / (float)LE_PV_HOP;
  const int j = (int)back; /* whole analysis ticks back: 1 or 2 */
  const float frac = back - (float)j;
  const float a = L->hold[(L->hold_at - j) & 3];
  const float w = a + frac * (L->hold[(L->hold_at - j - 1) & 3] - a);
  if (w <= 0.0f) return 0.0f;
  /* Before any pitch is heard (the weight is then 0 anyway), a 100 Hz
   * period keeps the taps moving. */
  const float per = L->period > 0.0f ? L->period : 0.01f * (float)LE_OCT_RATE;
  float y = 0.0f;
  if (L->level1 > 1e-4f) y += L->level1 * ref_le_low_voice(L, &L->v[0], 0.5f, per);
  if (L->level2 > 1e-4f) y += L->level2 * ref_le_low_voice(L, &L->v[1], 0.25f, per);
  return w * y;
}

/* Octave 2's trims, where the capture's voice sits against the dry, each
 * read at its own frequency (#891): up, -0.2 dB (s5/6; the vocoder alone
 * gives -3.6 at +24); down, -0.2 dB (s6v 26; the vocoder alone gives 0.0
 * at -24). */
#define LE_DOCT_UP2_LEVEL 1.485f   /* +3.4 dB */
#define LE_DOCT_DOWN2_LEVEL 0.982f /* -0.2 dB */

/* Formant-preserving octaver. Writes the newest sample to the slot's FIFO ring,
 * then mixes a delay-matched dry tap (LE_PV_LATENCY back) with a wet voice from the
 * phase vocoder (mode p3 < 0.5) or PSOLA (part 4, currently silent). p0 = shift
 * (0 = -2 oct, 0.5 = unison, 1 = +2 oct), p1 = tone (one-pole darkening of the
 * wet voice), p2 = dry/wet mix, p3 = mode, p4 = formants (held or moved with
 * the pitch, the phase vocoder only). Params are one-pole smoothed
 * (zipper-free) and a mode switch runs an equal-power gain dip while the DSP
 * runtime resets. It runs at LE_OCT_RATE whatever the engine's rate
 * (ref_fx_octaver_run), which is the time base of its smoothing, its dip and its
 * detection; [cap] is only its ring's length. */
static float ref_fx_octaver(le_fx_state* fx, int slot, int chan, int cap, float x,
                        const float* p) {
  float* buf = fx->delay[slot][chan];
  le_octaver_state* o = &fx->oct[slot][chan];
  if (buf == NULL || o->out == NULL || o->scratch == NULL ||
      cap < LE_OCT_REACH) {
    return x;
  }

  /* Keep the hop on the engine clock (#941). The counter advances one per
   * tick, so it stays in step for as long as the slot is ticked every frame;
   * a slot the engine did not tick for a while (a monitor whose input was
   * muted, a slot beyond a chain count that later grew back) finds its
   * counter off the clock here and restarts its runtime on its own schedule.
   * The overlap-add starts empty, so the wet voice builds back over one
   * window, as it does after any reset; the input ring is not cleared, as it
   * is not on the trunk either. An offline render runs the same check, so it
   * restarts on the same frame. */
  if (fx->clock_src != NULL || fx->clocked) {
    const int ticks = ref_le_oct_seeded_ticks(fx, slot);
    if (ref_le_oct_ticks_to_work(o) != ticks) {
      ref_le_pv_reset_runtime(fx, slot, chan, ticks);
      /* The band heard nothing while the slot was not ticked either. */
      le_oct_low* low = atomic_load_explicit(&o->low, memory_order_acquire);
      if (low != NULL) ref_le_low_forget(low);
    }
  }

  /* Write the newest sample at the head, then advance. */
  const int head = fx->delay_pos[slot][chan];
  buf[head] = x;
  int npos = head + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot][chan] = npos;

  /* Zipper-free param smoothing (~5 ms one-pole at the kernel's rate). */
  const float sc = 1.0f / (0.005f * (float)LE_OCT_RATE);
  /* The Dual Octaver's shift is a switch (p6): it changes in the gain dip
   * below, never through a glide (which would sweep two octaves). */
  const int dual = p[6] >= 0.5f;
  if (!dual) o->sm_shift += sc * (p[0] - o->sm_shift);
  o->sm_tone += sc * (p[1] - o->sm_tone);
  o->sm_mix += sc * (p[2] - o->sm_mix);
  o->sm_level += sc * ((1.0f - p[5]) - o->sm_level);

  /* For a latency after a reset, a phase vocoder has played nothing yet:
   * the mode, and the Dual Octaver's shift, follow the settings at once,
   * where the dip below dropped a PSOLA-mode octaver's wet voice for 30 ms on
   * every engage (#1482). A window, not just the first sample, so a setting
   * that lands up to a latency (1216 frames) after the type still takes
   * it. PSOLA plays its dry fallback from its first tick, so leaving it takes
   * the dip as before. On the window's first tick the runtime is the reset's
   * own, so only the counter changes modes; later a switch clears the frames
   * analysed at the old settings. */
  const int requested = p[3] >= 0.5f ? 1 : 0;
  if (o->fresh > 0) {
    const int first = o->fresh == LE_PV_LATENCY;
    --o->fresh;
    const int jump = dual && o->sm_shift != p[0];
    if (o->cur_mode == 0 && (requested == 1 || jump)) {
      if (first) {
        const int ticks = ref_le_oct_ticks_to_work(o);
        o->cur_mode = requested;
        ref_le_oct_set_ticks_to_work(o, ticks);
      } else {
        ref_le_oct_switch_mode(fx, slot, chan, requested);
      }
      if (dual) o->sm_shift = p[0];
    }
  }

  /* Mode switch (D1): equal-power gain dip, ~15 ms per leg — fade the wet out,
   * reset the DSP runtime at the bottom, then fade back in on the new mode. */
  const float xstep = 1.0f / (0.015f * (float)LE_OCT_RATE);
  const int shift_jump = dual && o->sm_shift != p[0];
  if (requested != o->cur_mode || shift_jump) {
    o->xfade -= xstep;
    if (o->xfade <= 0.0f) {
      o->xfade = 0.0f;
      ref_le_oct_switch_mode(fx, slot, chan, requested);
      o->sm_shift = dual ? p[0] : o->sm_shift;
    }
  } else if (o->xfade < 1.0f) {
    o->xfade += xstep;
    if (o->xfade > 1.0f) o->xfade = 1.0f;
  }

  const float ratio = powf(2.0f, (o->sm_shift - 0.5f) * 48.0f / 12.0f);
  /* The Dual Octaver's Octave 2 (p7, its level; #1464) is Octave 1 squared,
   * two octaves where Octave 1 is one, so it switches with Octave 1's
   * latched shift in the dip, its trim with it. */
  const int up = o->sm_shift > 0.5f;
  const float level2 =
      dual ? p[7] * (up ? LE_DOCT_UP2_LEVEL : LE_DOCT_DOWN2_LEVEL) : 0.0f;
  /* The Dual Octaver's low band (#1467) takes its down voices below the
   * crossover from the vocoder; it hears every sample, so it has the input
   * the moment high mode goes off. */
  le_oct_low* low =
      dual ? atomic_load_explicit(&o->low, memory_order_acquire) : NULL;
  if (low != NULL) ref_le_low_write(low, x);
  float wet;
  if (o->cur_mode == 0) {
    float band = 0.0f;
    float low_w = 0.0f;
    float low_g = 1.0f;
    float low_kc = 1.0f;
    if (low != NULL) {
      ref_le_low_follow(low, o->hop_count == 0);
      if (!up) { /* each voice at its Vol, untrimmed (ref_le_doct_settings) */
        band = ref_le_low_play(low, o->hop_count, p[8], p[7]);
        low_w = low->gate;
        low_g = low->boost;
        low_kc = LE_OCT_LOW_KC;
      }
    }
    wet = ref_le_pv_tick(o, buf, head, cap, ratio, p[4] >= 0.5f, ratio * ratio,
                     1.0f - p[5], level2, low_w, low_g, low_kc) +
          band;
  } else {
    wet = ref_le_psola_tick(o, buf, head, cap, ratio);
  }

  /* Tone: a one-pole low-pass on the wet voice that opens up as p1 rises. */
  const float a = 0.05f + 0.9f * o->sm_tone;
  float lp = fx->fx_lp[slot][chan];
  lp += a * (wet - lp);
  fx->fx_lp[slot][chan] = lp;

  /* Delay-matched dry (D2): read the dry tap behind the newest by the active
   * mode's added latency (ref_le_octaver_latency) so the mix stays comb-free. Both
   * modes report LE_PV_LATENCY, so the dry tap does not jump on a mode switch. */
  int dry_idx = head - ref_le_octaver_latency(o) + 1;
  dry_idx %= cap;
  if (dry_idx < 0) dry_idx += cap;
  const float dry = buf[dry_idx];

  /* Equal-power gain-dip envelope on the wet leg (g == 1 when steady). */
  const float g = sinf(o->xfade * 0.5f * LE_PI);
  const float mix = o->sm_mix;
  /* The phase vocoder applies the voices' levels in its synthesis (two
   * voices share one accumulator); PSOLA's one voice takes it here. */
  const float wet_out = g * lp * (o->cur_mode == 0 ? 1.0f : o->sm_level);
  if (dual) { /* an equal-power mix, its gains kept until the mix moves */
    if (mix != o->ep_mix) {
      o->ep_mix = mix;
      o->ep_dry = cosf(mix * 0.5f * LE_PI);
      o->ep_wet = sinf(mix * 0.5f * LE_PI);
    }
    return dry * o->ep_dry + wet_out * o->ep_wet;
  }
  return dry * (1.0f - mix) + wet_out * mix;
}


#define LE_OCT_RS_PHASES 256

typedef struct le_oct_rs {
  int32_t sr;
  int32_t win, wout;  /* taps a side: into the kernel (rate sr), out (48 kHz) */
  int32_t d48;        /* kernel ticks the input reaches the kernel late */
  int32_t latency;    /* the effect's, frames at sr */
  float* gin;         /* (LE_OCT_RS_PHASES + 1) x 2 win weights */
  float* gout;        /* (LE_OCT_RS_PHASES + 1) x 2 wout */
} le_oct_rs;

static void ref_le_oct_rs_read(const float* a, const float* b, int64_t num,
                           int64_t den, const float* g, int w, float* ya,
                           float* yb) {
  int64_t whole = num / den;
  if (whole * den > num) --whole; /* floor, for a position before 0 */
  const int64_t ph = (num - whole * den) * LE_OCT_RS_PHASES;
  const int pi = (int)(ph / den);
  const float fr = (float)((double)(ph % den) / (double)den);
  const float* g0 = g + (size_t)pi * 2 * w;
  const float* g1 = g0 + 2 * w;
  const int64_t first = whole - (w - 1);
  float acc_a = 0.0f;
  float acc_b = 0.0f;
  for (int j = 0; j < 2 * w; ++j) {
    const int64_t i = (first + j) & (LE_OCT_RS_RING - 1);
    const float gj = g0[j] + fr * (g1[j] - g0[j]);
    acc_a += a[i] * gj;
    acc_b += b[i] * gj;
  }
  *ya = acc_a;
  *yb = acc_b;
}


/* A kind's settings for each kernel tick (Smart Tune's correction moves
 * with what the kernel detects); NULL for settings fixed for the frame. */
typedef void (*ref_le_oct_tick_fn)(le_fx_state* fx, int slot, const float* p,
                               float* q);

/* The octaver's kernel on its nine settings (le_fx_octaver_settings):
 * shift, tone, mix, mode, formants, the wet voice's cut (0: none), 1 for
 * the Dual Octaver (an equal-power mix, a switched shift, and a second
 * voice two octaves out) or 0, that second voice's level (0: none), and
 * the first voice's level before its trim (the Dual Octaver's low band,
 * #1467) — so a zeroed tail is the plain octaver. At rates other than
 * LE_OCT_RATE the kernel runs at it, between two resamplers (above);
 * [tick], when set, works the settings out for each kernel tick from the
 * kind's own [p]. */
static void ref_fx_octaver_run(le_fx_state* fx, int slot, int sr, int cap,
                           float* l, float* r, float* q, const float* p,
                           ref_le_oct_tick_fn tick) {
  if (sr == LE_OCT_RATE || sr <= 0) {
    fx->oct_rs[slot] = 0;
    if (tick != NULL) tick(fx, slot, p, q);
    *l = ref_fx_octaver(fx, slot, 0, cap, *l, q);
    *r = ref_fx_octaver(fx, slot, 1, cap, *r, q);
    return;
  }
  const le_oct_rs* t = fx->oct_tab[slot];
  le_octaver_state* o = fx->oct[slot];
  if (t == NULL || t->sr != sr || o[0].rs_in == NULL || o[1].rs_in == NULL ||
      o[0].rs_out == NULL || o[1].rs_out == NULL) {
    return; /* not prepared for this rate: the input passes, unlate */
  }
  fx->oct_rs[slot] = 1;
  /* The frame this is: the engine's clock, or the slot's own count. One
   * that does not follow the last (a slot not ticked for a while, or the
   * clock wrapping) starts the resamplers again, as a reset does: the
   * frame-to-tick placement holds only along an unbroken run. */
  const int clocked = fx->clock_src != NULL || fx->clocked;
  const int running = fx->oct_run[slot] != 0;
  const uint32_t c = clocked ? ref_le_fx_now(fx)
                             : (running ? fx->oct_frame[slot] + 1u : 0u);
  if (running && (c != fx->oct_frame[slot] + 1u || c == 0u)) {
    fx->oct_run[slot] = 0;
  }
  fx->oct_frame[slot] = c;
  /* The kernel ticks k whose time k sr / 48 kHz falls in this frame. */
  const uint64_t k0 = ((uint64_t)c * LE_OCT_RATE + (uint64_t)sr - 1) / (uint64_t)sr;
  const uint64_t k1 =
      (((uint64_t)c + 1) * LE_OCT_RATE + (uint64_t)sr - 1) / (uint64_t)sr;
  if (fx->oct_run[slot] == 0) {
    /* From silence: the kernel starts on this frame's first 48 kHz sample,
     * as it starts on the reset's own frame at 48 kHz, not on the silence
     * the resampler holds before it. */
    for (int ch = 0; ch < 2; ++ch) {
      memset(o[ch].rs_in, 0, LE_OCT_RS_RING * sizeof(float));
      memset(o[ch].rs_out, 0, LE_OCT_RS_RING * sizeof(float));
    }
    fx->oct_n0[slot] = (uint32_t)k0;
    fx->oct_run[slot] = 1;
  }
  o[0].rs_in[c & (LE_OCT_RS_RING - 1)] = ref_fx_sanitize(*l);
  o[1].rs_in[c & (LE_OCT_RS_RING - 1)] = ref_fx_sanitize(*r);
  for (uint64_t k = k0; k < k1; ++k) {
    /* Tick k hears the input's 48 kHz sample k - d48, and keeps to that
     * sample's index as the 48 kHz kernel keeps to its clock. */
    const int64_t heard = (int64_t)k - t->d48;
    const uint32_t tk = (uint32_t)heard;
    fx->oct_tick[slot] = tk;
    float* out_l = &o[0].rs_out[k & (LE_OCT_RS_RING - 1)];
    float* out_r = &o[1].rs_out[k & (LE_OCT_RS_RING - 1)];
    if (fx->oct_run[slot] == 1) {
      /* still the silence from before the start: the kernel waits */
      if ((int32_t)(tk - fx->oct_n0[slot]) < 0) {
        *out_l = 0.0f;
        *out_r = 0.0f;
        continue;
      }
      /* Its first tick: the runtime starts on the slot's hop phase at this
       * tick, as a reset at 48 kHz starts it at the clock's frame. */
      fx->oct_run[slot] = 2;
      const int ticks = ref_le_oct_seeded_ticks(fx, slot);
      for (int ch = 0; ch < 2; ++ch) {
        ref_le_pv_reset_runtime(fx, slot, ch, ticks);
        le_oct_low* low = atomic_load_explicit(&o[ch].low, memory_order_acquire);
        if (low != NULL) ref_le_low_forget(low);
      }
    }
    if (tick != NULL) tick(fx, slot, p, q);
    float in_l;
    float in_r;
    ref_le_oct_rs_read(o[0].rs_in, o[1].rs_in, heard * sr, LE_OCT_RATE, t->gin,
                   t->win, &in_l, &in_r);
    *out_l = ref_fx_octaver(fx, slot, 0, cap, in_l, q);
    *out_r = ref_fx_octaver(fx, slot, 1, cap, in_r, q);
  }
  /* The output [latency] frames behind: what the kernel made LE_PV_LATENCY
   * ticks after it heard the input of then. */
  const int64_t v = ((int64_t)c - t->latency) * LE_OCT_RATE +
                    (int64_t)(t->d48 + LE_PV_LATENCY) * sr;
  ref_le_oct_rs_read(o[0].rs_out, o[1].rs_out, v, sr, t->gout, t->wout, l, r);
}

static void ref_fx_octaver_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  float q[9] = {p[0], p[1], p[2], p[3], p[4], 0.0f, 0.0f, 0.0f, 0.0f};
  ref_fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
}

/* The Whammy's taper: the pedal's share of the range, pedal^1.39. The
 * captures put 50 % at 4.57 of the 12 semitones (-4.57 / -4.52 down, +4.61 /
 * +4.57 up), and 0 and 100 % at the ends (#891). The earlier 1 kHz pass read
 * 99.8 % as -11.8 semitones, where the taper gives -11.97; one point, read
 * off a single tone, so the fit keeps the three-point sweep. */
#define LE_WHAMMY_TAPER 1.39f

/* The Whammy's shift as the octaver's shift setting: -24 + 48 v semitones
 * for range x pedal^taper. */
static float ref_le_whammy_shift(const float* p) {
  const float pedal = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float range = p[1] >= 0.5f ? 12.0f : -12.0f;
  return 0.5f + range * powf(pedal, LE_WHAMMY_TAPER) / 48.0f;
}

/* The Dual Octaver's first voice (#891, s5/4-7 and s6v 25-28): one octave
 * down with high mode off (1 kHz to 505 Hz) and up with it on (2 kHz), at
 * Octave 1 Vol times a trim that puts the phase vocoder's voice where the
 * capture's sits against the dry (-0.3 dB down, 0.0 dB up, each read at
 * its own frequency; the vocoder alone gives -1.5 and -0.4 on a 1 kHz
 * tone); Octave Mix an equal-power crossfade (the capture's 50 % puts dry
 * and wet each 3 dB down). */
#define LE_DOCT_DOWN_LEVEL 1.159f /* +1.3 dB */
#define LE_DOCT_UP_LEVEL 1.042f   /* +0.4 dB */

static void ref_le_doct_settings(const float* p, float* out) {
  const int high = p[0] >= 0.5f;
  const float vol = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  out[0] = high ? 0.75f : 0.25f; /* +12 or -12 of the octaver's +-24 */
  out[1] = 1.0f;                 /* the tone open */
  out[2] = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  out[3] = 0.0f; /* the phase vocoder */
  out[4] = 1.0f; /* the formants move with the pitch */
  out[5] = 1.0f - vol * (high ? LE_DOCT_UP_LEVEL : LE_DOCT_DOWN_LEVEL);
  out[6] = 1.0f; /* the Dual Octaver: equal power, a switched shift */
  /* Octave 2's level (#1464), linear (s6v: -6.2 dB at 50 %): its voice,
   * two octaves up in high mode (s5/6) or down without it (s6v 26-27), and
   * its trim follow Octave 1's shift in the kernel. */
  out[7] = p[3] < 0.0f ? 0.0f : p[3] > 1.0f ? 1.0f : p[3];
  /* Octave 1 Vol untrimmed, for the low band (#1467), which needs no trim:
   * a tap passes a tone at 0 dB, where the capture's down voices sit from
   * 110 Hz up (s15bass, s7oct). */
  out[8] = vol;
}

/* The octaver settings Smart Tune runs (LE_FX_SMART_TUNE, its kernel with
 * the parameter tables below): PSOLA, fully wet with the tone open, at
 * unison until it hears a pitch. */
static void ref_le_st_settings(float* out) {
  out[0] = 0.5f;
  out[1] = 1.0f;
  out[2] = 1.0f;
  out[3] = 1.0f;
  out[4] = 0.0f;
}

static void ref_fx_whammy_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  /* The nine settings the octaver's kernel reads (le_fx_octaver_settings). */
  float q[9] = {ref_le_whammy_shift(p), 1.0f, 1.0f, 0.0f, 1.0f,
                0.0f, 0.0f, 0.0f, 0.0f};
  ref_fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
}

static void ref_fx_dual_octaver_process(le_fx_state* fx, int slot, int sr,
                                    int cap, float* l, float* r,
                                    const float* p) {
  float q[9];
  ref_le_doct_settings(p, q);
  ref_fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
}

static void ref_fx_smart_tune_process(le_fx_state* fx, int slot, int sr, int cap,
                                  float* l, float* r, const float* p) {
  float q[9] = {0.0f};
  ref_le_st_settings(q);
  /* The correction is worked out each kernel tick, at the kernel's rate. */
  ref_fx_octaver_run(fx, slot, sr, cap, l, r, q, p, le_fx_test_st_tick);
}

int le_pitch_ref_process(le_fx_state* fx, int slot, int32_t type, int sr,
                         int cap, float* l, float* r, const float* p) {
  (void)pthread_once(&ref_tables_once, ref_tables_build);
  switch (type) {
    case LE_FX_OCTAVER:
      ref_fx_octaver_process(fx, slot, sr, cap, l, r, p);
      return 1;
    case LE_FX_WHAMMY:
      ref_fx_whammy_process(fx, slot, sr, cap, l, r, p);
      return 1;
    case LE_FX_DUAL_OCTAVER:
      ref_fx_dual_octaver_process(fx, slot, sr, cap, l, r, p);
      return 1;
    case LE_FX_SMART_TUNE:
      ref_fx_smart_tune_process(fx, slot, sr, cap, l, r, p);
      return 1;
    default:
      return 0;
  }
}

/* The transforms as they were, for the FFT's own comparison. */
static ref_le_rfft_plan ref_plans[13];

static const ref_le_rfft_plan* ref_plan(int n) {
  int b = 0;
  while ((1 << b) < n) ++b;
  if (b >= 13 || !ref_le_rfft_plan_init(&ref_plans[b], n)) return NULL;
  return &ref_plans[b];
}

int le_pitch_ref_rfft_fwd(int n, const float* x, float* re, float* im) {
  const ref_le_rfft_plan* p = ref_plan(n);
  if (p == NULL) return 0;
  ref_le_rfft_fwd(p, x, re, im);
  return 1;
}

int le_pitch_ref_rfft_inv(int n, const float* re, const float* im, float* y) {
  const ref_le_rfft_plan* p = ref_plan(n);
  if (p == NULL) return 0;
  ref_le_rfft_inv(p, re, im, y);
  return 1;
}

#endif /* LE_NATIVE_TESTS */
