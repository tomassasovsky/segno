/*
 * engine_fx.c — per-lane / per-monitor effects DSP (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: audio thread. Every kernel here runs inside the device
 * callback via fx_apply_chain; all are branch-light and allocation-free (delay
 * rings and octaver buffers are pre-allocated by the control thread in
 * le_fx_prepare_entry). The only control-thread entry points are le_fx_entry_reset
 * (also called on the audio thread), le_fx_free_octaver, le_octaver_latency, and
 * le_fx_ensure_pv_tables. Parameters arrive normalized (0..1) and are mapped to
 * musical ranges here.
 *
 * Behaviour is identical to the pre-split engine.c; the chain is non-destructive
 * (recordings stay dry) and stageless (every active entry colours in order). The
 * cross-TU surface and the PV/PSOLA tuning constants live in engine_fx.h.
 */
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_internal.h" /* le_psola_detect prototype (defined below) */
#include "fft.h" /* le_rfft_plan, le_rfft_fwd / le_rfft_inv, le_hann_init */
#include "rt_alloc.h" /* le_rt_alloc_prefaulted / le_rt_free: the audio thread writes these */
#include "../host/plugin_slot.h" /* le_plugin_slot_process (LE_FX_PLUGIN row) */

#ifndef LE_PI
#define LE_PI 3.14159265358979323846f
#endif

/* Read-only Hann window shared by every octaver instance (analysis + synthesis
 * window). Built once under a guarded init; never per-instance state. */
/* Minimum samples between two ring-clearing re-enable edges on one chain
 * (fx_apply_chain's enable_clear_cooldown): bounds the per-callback clear
 * work to roughly one slot's rings while keeping the stagger inaudible
 * (~2.7 ms at 48 kHz between engages on a whole-chain stomp). The octaver's
 * hop is anchored to the engine clock (#941), so the instant a slot resets at
 * does not move its schedule and the spacing is free of the hop. */
#define LE_FX_ENABLE_CLEAR_SPACING 128

static float le_hann[LE_PV_N];
/* The length-LE_PV_N real-FFT tables, shared the same way (fft.h). */
static le_rfft_plan le_pv_fft;
static pthread_once_t le_pv_tables_once = PTHREAD_ONCE_INIT;

static void le_pv_tables_build(void) {
  int ready = 0;
  le_hann_init(le_hann, LE_PV_N, &ready);
  (void)le_rfft_plan_init(&le_pv_fft, LE_PV_N);
}

/* Builds the shared octaver Hann window and FFT tables, exactly once in the
 * process. More than one thread prepares octavers (the control thread, the
 * wet-cache worker through le_fx_prepare), and a plain ready flag would let
 * one see the flag before the table stores (#1410). pthread_once orders the
 * build before every caller's return, and the audio thread reads the tables
 * only through a slot a preparing thread published to it afterwards, so the
 * audio path takes no lock. Reached only through fx_octaver_prepare. */
static void le_fx_ensure_pv_tables(void) {
  (void)pthread_once(&le_pv_tables_once, le_pv_tables_build);
}

/* Soft-clipping overdrive: tanh saturation with a pre-gain, then output trim. */
static float fx_drive(float x, const float* p) {
  const float drive = 1.0f + p[0] * 29.0f; /* 1x .. 30x pre-gain */
  const float level = p[1];                /* 0..1 output trim */
  return tanhf(x * drive) * level;
}

/* Resonant low-pass: a TPT state-variable filter (Cytomic/Zavalishin form).
 * p0 = cutoff (20 Hz .. ~18 kHz, log), p1 = resonance. */
static float fx_filter(le_fx_state* fx, int slot, int chan, int sr, float x,
                       const float* p) {
  float fc = 20.0f * powf(900.0f, p[0]); /* 20 * 900 = 18 kHz at p0 = 1 */
  const float nyq = 0.45f * (float)sr;
  if (fc > nyq) fc = nyq;
  const float g = tanf(LE_PI * fc / (float)sr);
  const float k = 2.0f - 1.8f * p[1]; /* damping: 2 (none) .. 0.2 (resonant) */
  const float a1 = 1.0f / (1.0f + g * (g + k));
  const float a2 = g * a1;
  const float a3 = g * a2;
  float* ic1 = &fx->svf_ic1[slot][chan];
  float* ic2 = &fx->svf_ic2[slot][chan];
  const float v3 = x - *ic2;
  const float v1 = a1 * (*ic1) + a2 * v3;
  const float v2 = *ic2 + a2 * (*ic1) + a3 * v3;
  *ic1 = 2.0f * v1 - *ic1;
  *ic2 = 2.0f * v2 - *ic2;
  return v2; /* low-pass output */
}

/* Feedback delay: p0 = time (0..1 s), p1 = feedback, p2 = wet mix. The ring is
 * the control-thread-allocated fx_delay line of e->fx_delay_frames samples. */
static float fx_delay(le_fx_state* fx, int slot, int chan, int cap, float x,
                      const float* p) {
  float* buf = fx->delay[slot][chan];
  if (buf == NULL || cap <= 1) return x;
  int d = (int)(p[0] * (float)(cap - 1));
  if (d < 1) d = 1;
  int pos = fx->delay_pos[slot][chan];
  int rp = pos - d;
  if (rp < 0) rp += cap;
  const float delayed = buf[rp];
  const float fb = p[1] * 0.95f; /* keep the feedback loop stable (< 1) */
  buf[pos] = x + delayed * fb;
  pos += 1;
  if (pos >= cap) pos = 0;
  fx->delay_pos[slot][chan] = pos;
  const float mix = p[2];
  return x * (1.0f - mix) + delayed * mix;
}

/* Tremolo: sine LFO amplitude modulation. p0 = rate (0.1..12 Hz), p1 = depth. */
static float fx_tremolo(le_fx_state* fx, int slot, int chan, int sr, float x,
                        const float* p) {
  const float rate = 0.1f + p[0] * 11.9f;
  const float depth = p[1];
  float ph = fx->lfo[slot][chan];
  const float lfo = 0.5f * (1.0f + sinf(2.0f * LE_PI * ph)); /* 0..1 */
  ph += rate / (float)sr;
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot][chan] = ph;
  return x * (1.0f - depth * (1.0f - lfo));
}

/* Linearly interpolated read from a ring of [cap] samples, [d] samples behind
 * the head [head] (the index of the most recently written sample). [d] may be
 * fractional and is assumed in [0, cap). */
static float fx_read_frac(const float* buf, int cap, int head, float d) {
  float rp = (float)head - d;
  while (rp < 0.0f) rp += (float)cap;
  while (rp >= (float)cap) rp -= (float)cap;
  const int i0 = (int)rp;
  const float frac = rp - (float)i0;
  int i1 = i0 + 1;
  if (i1 >= cap) i1 = 0;
  return buf[i0] + frac * (buf[i1] - buf[i0]);
}

/* --- Phase-vocoder octaver (LE_FX_OCTAVER) ------------------------------------
 *
 * A streaming STFT phase vocoder that shifts pitch while holding the formant
 * (spectral) envelope fixed, so a shifted voice neither combs (granular overlap)
 * nor chipmunks (resampled formants). The chain still calls the effect one sample
 * at a time; internally it buffers input in the slot's delay ring, runs one FFT
 * frame every LE_PV_HOP samples, and emits a latency-delayed sample. All heavy
 * buffers are control-thread allocated; the audio thread never allocates. */

/* Wraps a phase value into [-pi, pi] in O(1) — the raw per-hop phase deviation
 * (phase - k*expct) can be hundreds of radians for high bins, so a subtract loop
 * would spin many times per bin per hop. */
static float le_wrap_pi(float x) {
  const float two_pi = 2.0f * LE_PI;
  return x - two_pi * roundf(x / two_pi);
}

/* The invariants the stagger arithmetic rests on (engine_fx.h): the masks
 * need LE_PV_HOP to be a power of two, the quarters need it to divide by 4,
 * and the two modes share one schedule only because PSOLA re-analyses once
 * per phase-vocoder hop. */
_Static_assert((LE_PV_HOP & (LE_PV_HOP - 1)) == 0,
               "LE_PV_HOP must be a power of two (hop-phase masks)");
_Static_assert(LE_PV_HOP % 4 == 0, "the stagger lattice is four quarters");
_Static_assert(LE_PSOLA_AHOP == LE_PV_HOP,
               "PSOLA's YIN cadence must equal the PV hop to share its schedule");

/* The analysis-hop PHASE of the octaver in chain slot [slot] of [fx]: the
 * owner's quarter plus the slot, mod 4, on the quarter lattice (engine_fx.h).
 * Its heavy ticks fall on the engine frames c with (c + phase) mod LE_PV_HOP
 * equal to 0 (le_oct_seeded_ticks). Spreading the phase does not reduce the
 * work; it stops it arriving in one callback.
 *
 * WHY IT COSTS NO LATENCY: a PV frame runs at hop_count == 0 and writes the
 * OLA accumulator so that out[j] is emitted j samples later; the emitted
 * sample always corresponds to input index (head - LE_PV_N + 1), whatever the
 * phase. So le_octaver_latency stays a flat LE_PV_N, fx_octaver's dry tap
 * stays matched, and fx_apply_chain's warmup stays sufficient (le_pv_tick has
 * the warmup argument).
 *
 * PER SLOT, NOT PER CHANNEL: mono coherence (test_octaver_mono_coherent)
 * needs identical left and right in to give identical out, so both channels
 * of one instance share a phase.
 *
 * MASKED, not %-ed: hop_count indexes o->out[] in le_pv_tick, so the phase
 * must be in [0, LE_PV_HOP) for any seed a caller stores. */
static int le_pv_hop_phase(const le_fx_state* fx, int slot) {
  return le_fx_hop_mask((uint32_t)fx->hop_seed +
                        (uint32_t)slot * (uint32_t)LE_PV_STAGGER_QUARTER);
}

/* The two modes run one counter in opposite directions: PV counts up and runs
 * its frame on the tick where hop_count is 0, PSOLA counts down and runs YIN on
 * the tick that takes it to 0 or below. These two convert between the counter
 * and "ticks until the next heavy tick" (1 = the coming tick), so a phase
 * means the same schedule in both modes and a mode switch keeps the schedule
 * it had instead of restarting it. */
static int le_oct_ticks_to_work(const le_octaver_state* o) {
  if (o->cur_mode == 0) {
    return o->hop_count == 0 ? 1 : LE_PV_HOP - o->hop_count + 1;
  }
  return o->hop_count < 1 ? 1 : o->hop_count;
}

static void le_oct_set_ticks_to_work(le_octaver_state* o, int ticks) {
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
static int le_oct_seeded_ticks(const le_fx_state* fx, int slot) {
  const uint32_t phase = (uint32_t)le_pv_hop_phase(fx, slot);
  const uint32_t clock =
      fx->clock_src != NULL
          ? atomic_load_explicit(fx->clock_src, memory_order_relaxed)
          : fx->clock;
  const uint32_t to_go = (0u - (clock + phase)) & (uint32_t)(LE_PV_HOP - 1);
  return (int)to_go + 1;
}

/* Zeros the octaver's per-mode DSP runtime (phase history, synthesis
 * accumulator, hop counter) without touching the heap-buffer allocation or the
 * smoothed params / current mode. Used on a mode switch and on entry reset; safe
 * with NULL buffers (a slot that is not an octaver). The hop counter is set, in
 * the current mode's terms, to run its first heavy tick [ticks] ticks from now:
 * a reset passes le_oct_seeded_ticks (the instance's staggered phase), a mode
 * switch the old mode's remaining ticks. */
static void le_pv_reset_runtime(le_fx_state* fx, int slot, int chan,
                                int ticks) {
  le_octaver_state* o = &fx->oct[slot][chan];
  le_oct_set_ticks_to_work(o, ticks);
  o->out_pos = 0;
  o->in_epoch = 0;
  o->out_epoch = 0;
  o->period = 0.0f;
  o->voiced = 0.0f;
  if (o->out != NULL) memset(o->out, 0, sizeof(float) * LE_PV_N);
  if (o->last_phase != NULL) memset(o->last_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->sum_phase != NULL) memset(o->sum_phase, 0, sizeof(float) * LE_PV_BINS);
}

/* The formant envelope (engine_fx.h). */
void le_octaver_envelope(const float* mag, float* env) {
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
  le_rfft_fwd(&le_pv_fft, cl, cr, ci); /* -> cepstrum, quefrency 0 .. N/2 */
  for (int q = 0; q < LE_PV_LIFTER; ++q) cl[q] = cr[q];
  for (int q = LE_PV_LIFTER; q <= LE_PV_N - LE_PV_LIFTER; ++q) cl[q] = 0.0f;
  for (int q = 1; q < LE_PV_LIFTER; ++q) cl[LE_PV_N - q] = cr[q];
  le_rfft_fwd(&le_pv_fft, cl, cr, ci); /* -> N * smoothed log-magnitude */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    env[k] = expf(cr[k] / (float)LE_PV_N);
  }
}

/* Runs one STFT analysis/synthesis frame: windows the newest LE_PV_N FIFO
 * samples, shifts the harmonic structure by `ratio` while holding the cepstral
 * formant envelope fixed in frequency, and overlap-adds the result into o->out.
 * Called once per LE_PV_HOP samples from le_pv_tick. All scratch is stack-local
 * (bounded; no allocation). `head` indexes the newest FIFO sample.
 *
 * Cost per hop per channel: four length-N real FFTs — analysis, the two cepstrum
 * transforms, and synthesis — all on the shared plan le_pv_fft (fft.h). On the
 * console a stereo frame costs ~170 us, down from ~290 us with full-length
 * complex transforms (bench_fx_cpu, gcc -O2; #1410).
 * Stack peak ~34 KB at N = 1024 (the locals below ~18 KB, plus either
 * le_octaver_envelope's ~8 KB or le_rfft_inv's ~16 KB scratch, which run one
 * after the other). This scales with N, so a future bump to N = 2048 must
 * re-check constrained (e.g. plugin-host) audio-thread stack budgets. */
static void le_octaver_frame(le_octaver_state* o, const float* fifo, int head,
                             int cap, float ratio) {
  float win[LE_PV_N];
  float re[LE_PV_BINS];
  float im[LE_PV_BINS];
  float mag[LE_PV_BINS];
  float freq[LE_PV_BINS];
  float env[LE_PV_BINS];
  float syn_mag[LE_PV_BINS];
  float syn_freq[LE_PV_BINS];

  const float expct = 2.0f * LE_PI * (float)LE_PV_HOP / (float)LE_PV_N;
  const float osamp = (float)LE_PV_N / (float)LE_PV_HOP;

  /* 1. Hann-window the newest N samples (win[N-1] is the freshest). */
  int idx = (head - LE_PV_N + 1) % cap;
  if (idx < 0) idx += cap;
  for (int i = 0; i < LE_PV_N; ++i) {
    win[i] = fifo[idx] * le_hann[i];
    if (++idx == cap) idx = 0;
  }
  le_rfft_fwd(&le_pv_fft, win, re, im);

  /* 2. Per-bin magnitude + true frequency (in bins) from the phase advance. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const float r = re[k];
    const float im_k = im[k];
    mag[k] = sqrtf(r * r + im_k * im_k);
    const float phase = atan2f(im_k, r);
    float d = phase - o->last_phase[k];
    o->last_phase[k] = phase;
    d -= (float)k * expct;
    d = le_wrap_pi(d);
    freq[k] = (float)k + osamp * d / (2.0f * LE_PI);
  }

  /* 3. Formant envelope (le_octaver_envelope). */
  le_octaver_envelope(mag, env);

  /* 4. Whiten (mag/env), shift bins by `ratio`, then re-apply the envelope at
   *    the DESTINATION bin so the formants stay fixed in frequency. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    syn_mag[k] = 0.0f;
    syn_freq[k] = 0.0f;
  }
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const int j = (int)((float)k * ratio + 0.5f);
    if (j >= 0 && j < LE_PV_BINS) {
      const float res = mag[k] / (env[k] + 1e-9f);
      syn_mag[j] += res * env[j];
      syn_freq[j] = freq[k] * ratio;
    }
  }

  /* 5. Accumulate synthesis phase (advance per hop = 2*pi*freq*HOP/N) and
   *    rebuild the half spectrum. */
  for (int k = 0; k < LE_PV_BINS; ++k) {
    o->sum_phase[k] +=
        2.0f * LE_PI * syn_freq[k] * (float)LE_PV_HOP / (float)LE_PV_N;
    re[k] = syn_mag[k] * cosf(o->sum_phase[k]);
    im[k] = syn_mag[k] * sinf(o->sum_phase[k]);
  }

  /* 6. Inverse transform, synthesis-window, overlap-add. The Hann analysis x
   *    Hann synthesis window at 4x overlap sums to 1.5 — divide for unity. */
  le_rfft_inv(&le_pv_fft, re, im, win);
  const float norm = 1.0f / 1.5f;
  for (int i = 0; i < LE_PV_N; ++i) {
    o->out[i] += win[i] * le_hann[i] * norm;
  }
}

/* Emits one phase-vocoder output sample (latency LE_PV_N), running a fresh frame
 * at each hop boundary and streaming the synthesis accumulator out by one sample
 * per call, shifting it down by a hop once a block is fully emitted.
 *
 * HOP PHASE AND THE THREE THINGS IT MUST NOT MOVE. hop_count starts at any
 * value p in [0, LE_PV_HOP) (le_oct_seeded_ticks: whatever puts the heavy
 * ticks on the instance's frames of the engine clock), so the first frame
 * runs at tick (LE_PV_HOP - p) % LE_PV_HOP + 1 instead of tick 1:
 *
 *  1. Reported latency. A frame analysed with the FIFO head at H covers input
 *     [H - N + 1, H] and lands at out[0 .. N-1]; out[j] is emitted j ticks
 *     later, when the head is H + j. The emitted sample therefore corresponds
 *     to input (head - N + 1) for every p: latency stays LE_PV_N.
 *  2. The dry-delay match (fx_octaver's tap at head - latency + 1) is the same
 *     index, so wet and dry stay aligned at every phase.
 *  3. fx_apply_chain's warmup (LE_PV_N ticks, output discarded). Frames run at
 *     ticks t1, t1 + HOP, t1 + 2 HOP, t1 + 3 HOP, and out[0] has all four
 *     contributions at the fourth. The worst phase is p = 1 (t1 = LE_PV_HOP),
 *     whose fourth frame lands on tick LE_PV_N exactly, so the first ramped
 *     sample (tick LE_PV_N + 1) is complete at every phase, with no margin.
 *     test_octaver_hop_stagger_alignment sweeps all LE_PV_HOP phases and
 *     fails with a warmup one sample shorter. */
static float le_pv_tick(le_octaver_state* o, const float* fifo, int head, int cap,
                        float ratio) {
  if (o->out == NULL) return 0.0f;
  if (o->hop_count == 0) {
    le_octaver_frame(o, fifo, head, cap, ratio);
  }
  const float y = o->out[o->hop_count];
  if (++o->hop_count >= LE_PV_HOP) {
    memmove(o->out, o->out + LE_PV_HOP, sizeof(float) * (LE_PV_N - LE_PV_HOP));
    memset(o->out + (LE_PV_N - LE_PV_HOP), 0, sizeof(float) * LE_PV_HOP);
    o->hop_count = 0;
  }
  return y;
}

/* YIN pitch detector (see engine_internal.h). Plain autocorrelation peak-picking
 * is prone to octave errors — a sub/multiple of the true period correlates nearly
 * as well — and a mis-spaced grain wrecks both pitch and formants, so the modest
 * extra cost of YIN's cumulative-mean normalization is worth it here. */
int le_psola_detect(const float* x, int n, int sr, float* out_period,
                    float* out_voiced) {
  /* The octaver's band, unchanged. Integer division on the same operands as
   * before the band became a parameter, so the lags are bit-identical. */
  return le_psola_detect_band(x, n, sr, 60, 1000, out_period, out_voiced);
}

/* ---- Resumable YIN pass (see le_yin_pass in engine_private.h) --------------
 *
 * The three steps below ARE le_psola_detect_band, split at the two points a
 * caller can pause at: before the difference function and after it. The
 * octaver runs all three back to back (it needs the answer inside the same
 * grain); the tuner runs le_yin_step a slice at a time across callbacks. The
 * arithmetic is byte-identical either way, which is the whole point of the
 * split — there is no second copy of the detector to keep in step. */

int le_yin_begin(le_yin_pass* p, const float* x, int n, int sr, int min_hz,
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

int le_yin_step(le_yin_pass* p, long budget) {
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

int le_yin_finish(const le_yin_pass* p, float* out_period, float* out_voiced) {
  const float* dp = p->dp;
  const int minlag = p->minlag;
  const int maxlag = p->maxlag;

  /* A rejected le_yin_begin leaves minlag == maxlag == 0 and never writes
   * dp[0], but le_yin_step still reports "done" (tau 1 > maxlag 0). A caller
   * that ignores le_yin_begin's return would land here and read dp[0]
   * uninitialised, yielding a garbage period at conf = 1 - garbage. The
   * symmetric misuse -- finishing before le_yin_step has reported done --
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

int le_psola_detect_band(const float* x, int n, int sr, int min_hz, int max_hz,
                         float* out_period, float* out_voiced) {
  *out_period = 0.0f;
  *out_voiced = 0.0f;
  float dp[LE_PSOLA_MAXLAG + 1];
  const int dp_cap = (int)(sizeof(dp) / sizeof(dp[0]));
  le_yin_pass p;
  if (!le_yin_begin(&p, x, n, sr, min_hz, max_hz, dp, dp_cap)) return 0;
  /* Unbounded: the octaver needs the answer now. A negative budget always
   * completes, so the check can only ever pass -- it is here so the one-shot
   * path states the precondition le_yin_finish relies on rather than assuming
   * it. */
  if (!le_yin_step(&p, -1)) return 0;
  return le_yin_finish(&p, out_period, out_voiced);
}

/* Added latency (frames) of the active octaver. Single source of truth, read in
 * two places: the dry-delay match in fx_octaver (D2), and — per the part-5 plan —
 * the control thread, which folds it into the published snapshot so the UI can
 * warn about monitoring lag. PSOLA reuses the LE_PV_N OLA accumulator (the no-
 * extra-allocation budget part 3 fixed), and by construction its grain centers sit
 * LE_PV_N behind the head, so its latency equals the phase vocoder's; both modes
 * therefore report LE_PV_N and the dry tap does not jump on a switch. The argument
 * is the per-mode seam a future dedicated PSOLA buffer (lower latency) would use. */
static int le_octaver_latency(const le_octaver_state* o) {
  (void)o;
  return LE_PV_N;
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
static float le_psola_tick(le_octaver_state* o, const float* fifo, int head,
                           int cap, float ratio) {
  if (o->out == NULL) return 0.0f;
  const int N = LE_PV_N;
  const int sr = cap; /* the fx ring is 1 s long, so cap == sample rate */

  /* 1. Emit one sample from the circular OLA accumulator, clearing it behind. */
  const int rp = o->out_pos;
  const float y = o->out[rp];
  o->out[rp] = 0.0f;
  o->out_pos = (rp + 1 >= N) ? 0 : rp + 1;

  /* 2. Periodic pitch analysis: YIN over a contiguous copy of the FIFO tail. */
  if (--o->hop_count <= 0) {
    o->hop_count = LE_PSOLA_AHOP;
    float win[LE_PSOLA_WIN];
    for (int i = 0; i < LE_PSOLA_WIN; ++i) {
      int idx = head - (LE_PSOLA_WIN - 1) + i;
      idx %= cap;
      if (idx < 0) idx += cap;
      win[i] = fifo[idx];
    }
    float p = 0.0f;
    float vc = 0.0f;
    le_psola_detect(win, LE_PSOLA_WIN, sr, &p, &vc);
    o->voiced += 0.35f * (vc - o->voiced); /* smooth -> chatter-free soft gate */
    if (p > 0.0f) {                        /* hold last period through gaps */
      o->period = o->period <= 0.0f ? p : o->period + 0.5f * (p - o->period);
    }
  }

  /* 3. Synthesis: marks recede from the head one sample per tick; at each
   *    synthesis mark deposit a Hann grain whose source snaps to the nearest
   *    analysis mark, so the grain spacing (pitch) changes by `ratio` while the
   *    grain shape (formant envelope) does not. */
  o->in_epoch += 1;
  if (--o->out_epoch <= 0) {
    float pf = o->period; /* sub-sample period: sets the grain spacing (pitch) */
    if (pf < 2.0f) pf = 2.0f;
    if (pf > (float)LE_PSOLA_MAXLAG) pf = (float)LE_PSOLA_MAXLAG;
    float ps = pf / ratio; /* synthesis spacing -> output pitch = ratio * f0 */
    if (ps < 1.0f) ps = 1.0f;
    /* Integer countdown to the next deposit; sub-sample spacing is fine to round
     * here — the pitch error is < 1 sample over a period and is inaudible. */
    o->out_epoch += (int)(ps + 0.5f);

    const int pi = (int)(pf + 0.5f); /* integer period: the analysis-mark grid step */
    int th = pi;
    if (th > LE_PSOLA_THMAX) th = LE_PSOLA_THMAX;
    const int c = N / 2;  /* grain center offset ahead of the read pointer */
    const int dn = N - c; /* nominal source distance behind the head */
    /* Snap the analysis mark to the nearest of the period-spaced grid near dn. */
    while (o->in_epoch - dn > pi / 2) o->in_epoch -= pi;
    while (dn - o->in_epoch > pi / 2) o->in_epoch += pi;
    if (o->in_epoch < th) o->in_epoch = th; /* keep the grain read causal */
    if (o->in_epoch > cap - 1 - th) o->in_epoch = cap - 1 - th;

    /* COLA gain: Hann area (= th) over the hop (= ps) keeps the overlap-add near
     * unity across the shift; clamp so a clamped grain cannot blow up. */
    float gain = ps / (float)th;
    if (gain > 2.0f) gain = 2.0f;
    for (int j = -th; j <= th; ++j) {
      const float wf =
          0.5f - 0.5f * cosf(LE_PI * (float)(j + th) / (float)th); /* Hann */
      int src = head - o->in_epoch + j;
      src %= cap;
      if (src < 0) src += cap;
      int dst = rp + c + j;
      dst %= N;
      if (dst < 0) dst += N;
      o->out[dst] += gain * wf * fifo[src];
    }
  }

  /* 4. Soft voiced/unvoiced gate (D4): crossfade the grain voice against the
   *    delay-matched dry by the smoothed confidence. Silence -> voiced ~0 and the
   *    dry tap is ~0, so the output collapses to silence (no grain buzz). */
  int didx = head - le_octaver_latency(o) + 1;
  didx %= cap;
  if (didx < 0) didx += cap;
  const float dry = fifo[didx];
  float wv = (o->voiced - 0.3f) / 0.3f; /* soft gate around conf ~0.3..0.6 */
  if (wv < 0.0f) wv = 0.0f;
  if (wv > 1.0f) wv = 1.0f;
  return wv * y + (1.0f - wv) * dry;
}

/* Formant-preserving octaver. Writes the newest sample to the slot's FIFO ring,
 * then mixes a delay-matched dry tap (head - LE_PV_N) with a wet voice from the
 * phase vocoder (mode p3 < 0.5) or PSOLA (part 4, currently silent). p0 = shift
 * (0 = -2 oct, 0.5 = unison, 1 = +2 oct), p1 = tone (one-pole darkening of the
 * wet voice), p2 = dry/wet mix, p3 = mode. Params are one-pole smoothed
 * (zipper-free) and a mode switch runs an equal-power gain dip while the DSP
 * runtime resets. The ring length `cap` equals the sample rate (1 s), used here
 * as the time base for the smoothing / dip constants. */
static float fx_octaver(le_fx_state* fx, int slot, int chan, int cap, float x,
                        const float* p) {
  float* buf = fx->delay[slot][chan];
  le_octaver_state* o = &fx->oct[slot][chan];
  if (buf == NULL || o->out == NULL || cap < LE_PV_N + 1) return x;

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
    const int ticks = le_oct_seeded_ticks(fx, slot);
    if (le_oct_ticks_to_work(o) != ticks) {
      le_pv_reset_runtime(fx, slot, chan, ticks);
    }
  }

  /* Write the newest sample at the head, then advance. */
  const int head = fx->delay_pos[slot][chan];
  buf[head] = x;
  int npos = head + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot][chan] = npos;

  /* Zipper-free param smoothing (~5 ms one-pole; cap == sample rate). */
  const float sc = 1.0f / (0.005f * (float)cap);
  o->sm_shift += sc * (p[0] - o->sm_shift);
  o->sm_tone += sc * (p[1] - o->sm_tone);
  o->sm_mix += sc * (p[2] - o->sm_mix);

  /* Mode switch (D1): equal-power gain dip, ~15 ms per leg — fade the wet out,
   * reset the DSP runtime at the bottom, then fade back in on the new mode. */
  const int requested = p[3] >= 0.5f ? 1 : 0;
  const float xstep = 1.0f / (0.015f * (float)cap);
  if (requested != o->cur_mode) {
    o->xfade -= xstep;
    if (o->xfade <= 0.0f) {
      o->xfade = 0.0f;
      /* Keep the hop schedule across the switch: the new mode's heavy tick
       * lands where the old mode's next one would have. Re-seeding from the
       * phase here would anchor it to this instant, ~15 ms after the reset,
       * and move it off the instance's quarter. */
      const int ticks = le_oct_ticks_to_work(o);
      o->cur_mode = requested;
      le_pv_reset_runtime(fx, slot, chan, ticks);
    }
  } else if (o->xfade < 1.0f) {
    o->xfade += xstep;
    if (o->xfade > 1.0f) o->xfade = 1.0f;
  }

  const float ratio = powf(2.0f, (o->sm_shift - 0.5f) * 48.0f / 12.0f);
  const float wet = o->cur_mode == 0 ? le_pv_tick(o, buf, head, cap, ratio)
                                     : le_psola_tick(o, buf, head, cap, ratio);

  /* Tone: a one-pole low-pass on the wet voice that opens up as p1 rises. */
  const float a = 0.05f + 0.9f * o->sm_tone;
  float lp = fx->fx_lp[slot][chan];
  lp += a * (wet - lp);
  fx->fx_lp[slot][chan] = lp;

  /* Delay-matched dry (D2): read the dry tap behind the newest by the active
   * mode's added latency (le_octaver_latency) so the mix stays comb-free. Both
   * modes report LE_PV_N today, so the dry tap does not jump on a mode switch. */
  int dry_idx = head - le_octaver_latency(o) + 1;
  dry_idx %= cap;
  if (dry_idx < 0) dry_idx += cap;
  const float dry = buf[dry_idx];

  /* Equal-power gain-dip envelope on the wet leg (g == 1 when steady). */
  const float g = sinf(o->xfade * 0.5f * LE_PI);
  const float mix = o->sm_mix;
  return dry * (1.0f - mix) + g * lp * mix;
}

/* Tape-style echo. Three things set it apart from the clean digital delay: a
 * slow wow LFO wobbles the read time (tape pitch flutter, read fractionally), a
 * heavy one-pole low-pass darkens the loop so each repeat loses highs, and the
 * fed-back signal is softly saturated (tape compression, which also self-limits
 * the feedback). The wet tap is that processed signal, so even the first repeat
 * is coloured rather than a clean copy. p0 = time (0..1 s), p1 = feedback,
 * p2 = wet mix. Shares the fx_delay ring; lfo is the wow phase, fx_lp the loop
 * low-pass. */
static float fx_echo(le_fx_state* fx, int slot, int chan, int sr, int cap,
                     float x, const float* p) {
  float* buf = fx->delay[slot][chan];
  if (buf == NULL || cap <= 1) return x;

  /* Wow/flutter: a slow LFO wobbles the read time a few ms for tape wobble. */
  float ph = fx->lfo[slot][chan];
  const float wow = sinf(2.0f * LE_PI * ph);
  ph += 0.7f / (float)sr; /* ~0.7 Hz wow */
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot][chan] = ph;
  const float wob = 0.004f * (float)sr; /* ~4 ms wobble depth */
  float d = p[0] * (float)(cap - 1) + wow * wob;
  if (d < 1.0f) d = 1.0f;
  if (d > (float)(cap - 1)) d = (float)(cap - 1);

  const int pos = fx->delay_pos[slot][chan];
  const float delayed = fx_read_frac(buf, cap, pos, d);

  /* Darken the loop (~1.4 kHz one-pole) then soft-saturate the repeats. */
  float lp = fx->fx_lp[slot][chan];
  lp += 0.18f * (delayed - lp);
  fx->fx_lp[slot][chan] = lp;
  const float wet = tanhf(lp);
  const float fb = p[1] * 0.97f;

  buf[pos] = x + wet * fb;
  int npos = pos + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot][chan] = npos;

  const float mix = p[2];
  return x * (1.0f - mix) + wet * mix;
}

/* Comb and allpass line lengths (samples at 44.1 kHz; scaled to the running
 * rate). The classic Freeverb tunings: mutually prime lengths so the comb
 * resonances and allpass diffusion never line up into a periodic ring. */
static const int LE_REV_COMB_LEN[LE_REV_COMBS] = {1116, 1188, 1277, 1356,
                                                  1422, 1491, 1557, 1617};
static const int LE_REV_AP_LEN[LE_REV_APS] = {556, 441, 341, 225};

/* Freeverb stereo spread: the right bank's lines are this many samples longer
 * (at 44.1 kHz, scaled to the running rate) so its tail decorrelates from the
 * left's, giving a mono input a wide stereo decay. */
#define LE_REV_SPREAD 23

/* Clears the reverb comb/allpass write heads and per-comb damping memory for
 * chain slot [s] across both stereo banks (the reverb's share of the per-slot
 * DSP state). */
static void le_fx_clear_reverb(le_fx_state* fx, int s) {
  for (int i = 0; i < LE_REV_COMBS * LE_REV_BANKS; ++i) {
    fx->rev_comb_pos[s][i] = 0;
    fx->rev_comb_lp[s][i] = 0.0f;
  }
  for (int i = 0; i < LE_REV_APS * LE_REV_BANKS; ++i) fx->rev_ap_pos[s][i] = 0;
}

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay read head, one-pole memory, octaver phase-vocoder runtime, reverb
 * lines) so a freshly engaged effect starts clean — no filter blow-up from stale
 * integrators, no delay-read of old content. Does NOT free or allocate the delay
 * ring or octaver buffers; the control thread owns their lifetime. Shared by
 * le_lane_reset, le_monitor_input_reset, and the SET_*_FX ring handlers (which
 * reset one slot when its type changes), removing what was a copy-pasted clear.
 *
 * RT note: this runs on the AUDIO THREAD (the SET_*_FX ring handlers). For an
 * allocated octaver slot it now memsets the three phase-vocoder buffers
 * (~16 KB/channel). That is bounded and fires only on a discrete type-change
 * event (never per sample), consistent with the existing reverb-line clears. */
void le_fx_entry_reset(le_fx_state* fx, int slot) {
  for (int chan = 0; chan < 2; ++chan) {
    fx->svf_ic1[slot][chan] = 0.0f;
    fx->svf_ic2[slot][chan] = 0.0f;
    fx->lfo[slot][chan] = 0.0f;
    fx->delay_pos[slot][chan] = 0;
    fx->fx_lp[slot][chan] = 0.0f;
    le_octaver_state* o = &fx->oct[slot][chan];
    o->sm_shift = 0.5f; /* unison: the smoother ramps up from no shift, not -2 oct */
    o->sm_tone = 0.0f;
    o->sm_mix = 0.0f; /* starts dry, so the param ramp-in is inaudible */
    o->cur_mode = 0;  /* phase vocoder */
    o->xfade = 1.0f;  /* steady (no gain dip) */
    le_pv_reset_runtime(fx, slot, chan, le_oct_seeded_ticks(fx, slot));
  }
  le_fx_clear_reverb(fx, slot);
  /* A retyped slot has no tail to drain: a stale budget would let the next
   * re-enable edge skip its clean reset and read the old type's ring. */
  fx->enable_drain[slot] = 0;
  fx->enable_quiet[slot] = 0;
}

/* Seeds slot [slot]'s octaver runtime settled at [params] (engine_fx.h). */
void le_fx_octaver_seed_settled(le_fx_state* fx, int slot,
                                const float* params) {
  if (fx == NULL || params == NULL || slot < 0 || slot >= LE_FX_MAX) return;
  const int mode = params[3] >= 0.5f ? 1 : 0;
  for (int chan = 0; chan < 2; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    o->sm_shift = params[0];
    o->sm_tone = params[1];
    o->sm_mix = params[2];
    o->xfade = 1.0f; /* steady: no gain dip on the first sample */
    if (mode != o->cur_mode) {
      /* Land on the requested mode without fx_octaver's ~15 ms dip, and
       * re-seed the runtime as that switch would, hop phase included. */
      o->cur_mode = mode;
      le_pv_reset_runtime(fx, slot, chan, le_oct_seeded_ticks(fx, slot));
    }
  }
}

/* Zeroes chain slot [slot]'s delay rings (both channels, [cap] floats each)
 * when allocated: the audio-thread half of "start clean" that
 * le_fx_entry_reset leaves out. Shared by the settled-bypass re-enable edge
 * and Cut all sound; one ring is cap floats, so callers decide the spacing. */
void le_fx_entry_clear_rings(le_fx_state* fx, int slot, int cap) {
  for (int chan = 0; chan < 2; ++chan) {
    if (fx->delay[slot][chan] != NULL) {
      memset(fx->delay[slot][chan], 0, (size_t)cap * sizeof(float));
    }
  }
}

/* Seeds chain slot [slot]'s enable-crossfade runtime SETTLED at enabled, so a
 * freshly created (zeroed) le_fx_state does not read as a mid-ramp bypass and
 * fade in on first use. Every standalone le_fx_state owner calls this after
 * creating/zeroing its state: le_lane_reset / le_monitor_input_reset, the
 * offline renders (through le_fx_enable_seed_at), the VST3 plugin
 * processors, and the test harnesses. Deliberately NOT part of le_fx_entry_reset, which touches only
 * the DRAIN half of the runtime (a retyped slot has no tail to drain) and
 * leaves an in-flight enable ramp alone. */
void le_fx_enable_seed_settled(le_fx_state* fx, int slot) {
  fx->enable_mix[slot] = 1.0f;
  fx->enable_target[slot] = 1;
  fx->enable_warmup[slot] = 0;
  fx->enable_drain[slot] = 0;
  fx->enable_quiet[slot] = 0;
  le_fx_rack_reset(fx, slot);
}

void le_fx_rack_reset(le_fx_state* fx, int slot) {
  fx->rack_primed[slot] = 0;
}

void le_fx_enable_seed_at(le_fx_state* fx, int slot, int effective) {
  if (effective) {
    le_fx_enable_seed_settled(fx, slot);
  } else {
    le_fx_enable_force_bypass(fx, slot);
    /* A seed is a fresh start for the rack side too. force_bypass alone
     * leaves it, because the live settle sweep calls it every buffer. */
    le_fx_rack_reset(fx, slot);
  }
}

/* Settles chain slot [slot]'s enable-crossfade runtime at fully BYPASSED.
 * Called by the per-buffer snapshot (and le_engine_stop) for a slot the chain
 * will NOT process while its effective enabled bit is 0: an unprocessed slot
 * cannot advance its ramp, so without this a disable followed by a processing
 * gap (monitor muted/off, fx count shrunk, chain emptied, device stopped)
 * would strand enable_mix mid-fade and a later re-enable would skip the
 * settled-edge reset — resuming an arbitrarily stale tail. Forcing settled
 * bypass is inaudible (the slot is not sounding) and guarantees resumption
 * re-enters through the clean re-enable path. Enabled slots are deliberately
 * left alone: their state persisting across a gap is the pre-existing
 * behavior for engaged effects. */
int le_fx_enable_settled_bypassed(const le_fx_state* fx, int slot) {
  return fx->enable_mix[slot] == 0.0f && fx->enable_target[slot] == 0 &&
         fx->enable_warmup[slot] == 0 && fx->enable_drain[slot] == 0 &&
         fx->enable_quiet[slot] == 0;
}

void le_fx_enable_force_bypass(le_fx_state* fx, int slot) {
  fx->enable_mix[slot] = 0.0f;
  fx->enable_target[slot] = 0;
  fx->enable_warmup[slot] = 0;
  fx->enable_drain[slot] = 0; /* a slot nobody processes cannot drain */
  fx->enable_quiet[slot] = 0;
}

/* Frees a chain slot's octaver phase-vocoder heap buffers (both channels) and
 * nulls them. Control-thread only (lane/monitor reset and engine destroy), where
 * the audio thread is no longer reading the slot — mirroring how the delay rings
 * are freed. Like the rings, the buffers are KEPT (not freed) across an in-place
 * retype so a retype-back reuses them; freeing on retype would race the audio
 * thread still processing the slot before the type-change command is observed. */
void le_fx_free_octaver(le_fx_state* fx, int slot) {
  for (int chan = 0; chan < 2; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    le_rt_free(o->out);
    o->out = NULL;
    le_rt_free(o->last_phase);
    o->last_phase = NULL;
    le_rt_free(o->sum_phase);
    o->sum_phase = NULL;
  }
}

void le_fx_free_delay(le_fx_state* fx, int slot) {
  le_rt_free(fx->delay[slot][0]);
  fx->delay[slot][0] = NULL;
  le_rt_free(fx->delay[slot][1]);
  fx->delay[slot][1] = NULL;
}

void le_fx_state_free_buffers(le_fx_state* fx) {
  for (int s = 0; s < LE_FX_MAX; ++s) {
    le_fx_free_delay(fx, s);
    le_fx_free_octaver(fx, s);
  }
}

/* Schroeder/Freeverb reverb: LE_REV_COMBS parallel damped comb filters are
 * summed and run through LE_REV_APS series allpass diffusers, producing a dense
 * decaying tail rather than the discrete repeats of DELAY/ECHO. Two such banks
 * run in parallel — a left and a right whose lines are offset by LE_REV_SPREAD —
 * each fed by its own input (the left bank by xl, the right by xr) and returned
 * through *out_l / *out_r. A mono input (xl == xr) feeds both banks identically,
 * so it still yields a decorrelated stereo tail from the spread alone, exactly as
 * before; an already-stereo input reverberates each side on its own bank. p0 =
 * size (tail length, via comb feedback), p1 = damping (treble absorbed each
 * pass), p2 = wet mix. The wet path carries only the reverberated signal, so the
 * dry is heard through (1 - mix). Both banks are packed into the slot's single
 * 1 s ring delay[slot][0] (delay[slot][1] is unused by reverb); both banks total
 * well under 1 s even at 192 kHz.
 *
 * The call site passes &xl / &xr as the out-params while xl / xr are also the
 * inputs, so both wet[] values are computed before either out-param is written —
 * xl / xr are never read after the first store. */
static void fx_reverb(le_fx_state* fx, int slot, int sr, int cap, float xl,
                      float xr, const float* p, float* out_l, float* out_r) {
  float* buf = fx->delay[slot][0];
  if (buf == NULL || cap <= 1) {
    *out_l = xl;
    *out_r = xr;
    return;
  }
  const float scale = (float)sr / 44100.0f;
  const float room = 0.70f + p[0] * 0.28f; /* 0.70..0.98 comb feedback */
  const float damp = p[1] * 0.4f;          /* 0..0.4 feedback low-pass */
  const float mix = p[2];

  int off = 0;
  float wet[LE_REV_BANKS] = {0.0f, 0.0f};
  for (int bank = 0; bank < LE_REV_BANKS; ++bank) {
    const int spread = bank == 0 ? 0 : (int)((float)LE_REV_SPREAD * scale);
    const int cbase = bank * LE_REV_COMBS; /* this bank's state slice */
    const int abase = bank * LE_REV_APS;
    const float in = (bank == 0 ? xl : xr) * 0.015f; /* Freeverb input gain */
    float acc = 0.0f;
    for (int c = 0; c < LE_REV_COMBS; ++c) {
      int len = (int)((float)LE_REV_COMB_LEN[c] * scale) + spread;
      if (len < 1) len = 1;
      if (off + len > cap) break; /* safety: never index past the ring */
      int pos = fx->rev_comb_pos[slot][cbase + c];
      if (pos >= len) pos = 0;
      const float y = buf[off + pos];
      acc += y;
      float lp = fx->rev_comb_lp[slot][cbase + c];
      lp = y * (1.0f - damp) + lp * damp; /* damp the signal fed back */
      fx->rev_comb_lp[slot][cbase + c] = lp;
      buf[off + pos] = in + lp * room;
      pos += 1;
      if (pos >= len) pos = 0;
      fx->rev_comb_pos[slot][cbase + c] = pos;
      off += len;
    }
    float s = acc;
    for (int a = 0; a < LE_REV_APS; ++a) {
      int len = (int)((float)LE_REV_AP_LEN[a] * scale) + spread;
      if (len < 1) len = 1;
      if (off + len > cap) break;
      int pos = fx->rev_ap_pos[slot][abase + a];
      if (pos >= len) pos = 0;
      const float bufout = buf[off + pos];
      buf[off + pos] = s + bufout * 0.5f; /* allpass feedback coefficient */
      s = bufout - s;
      pos += 1;
      if (pos >= len) pos = 0;
      fx->rev_ap_pos[slot][abase + a] = pos;
      off += len;
    }
    wet[bank] = s;
  }
  /* Write both out-params last: they may alias the xl / xr inputs. */
  *out_l = xl * (1.0f - mix) + wet[0] * mix;
  *out_r = xr * (1.0f - mix) + wet[1] * mix;
}

/* ---- the effect vtable ----
 *
 * Each built-in effect exposes a uniform stereo `process(fx, slot, sr, cap, l, r,
 * params)` kernel and (if it adds any) a `latency`. A `static const` table indexed
 * by le_fx_type dispatches the chain, so adding an effect is adding its kernel(s)
 * plus one table row — and a hosted VST3/CLAP plugin can later slot in as just
 * another row whose `process` calls the plugin host. The per-channel kernels
 * above already carry each slot's L/R DSP state; the wrappers below adapt their
 * varied signatures (mono-per-channel vs the stereo reverb) to the uniform one,
 * preserving the exact left-then-right call order. Effects that ignore sr or cap
 * cast them to void to keep the signature uniform. */

static void fx_drive_process(le_fx_state* fx, int slot, int sr, int cap,
                             float* l, float* r, const float* p) {
  (void)fx;
  (void)slot;
  (void)sr;
  (void)cap;
  *l = fx_drive(*l, p);
  *r = fx_drive(*r, p);
}
static void fx_filter_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  (void)cap;
  *l = fx_filter(fx, slot, 0, sr, *l, p);
  *r = fx_filter(fx, slot, 1, sr, *r, p);
}
static void fx_delay_process(le_fx_state* fx, int slot, int sr, int cap,
                             float* l, float* r, const float* p) {
  (void)sr;
  *l = fx_delay(fx, slot, 0, cap, *l, p);
  *r = fx_delay(fx, slot, 1, cap, *r, p);
}
static void fx_tremolo_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  (void)cap;
  *l = fx_tremolo(fx, slot, 0, sr, *l, p);
  *r = fx_tremolo(fx, slot, 1, sr, *r, p);
}
static void fx_octaver_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  (void)sr;
  *l = fx_octaver(fx, slot, 0, cap, *l, p);
  *r = fx_octaver(fx, slot, 1, cap, *r, p);
}
static void fx_echo_process(le_fx_state* fx, int slot, int sr, int cap, float* l,
                            float* r, const float* p) {
  *l = fx_echo(fx, slot, 0, sr, cap, *l, p);
  *r = fx_echo(fx, slot, 1, sr, cap, *r, p);
}
/* Reverb is natively stereo (it cross-feeds its two banks), so its wrapper makes
 * the one stereo call. fx_reverb computes both wet values before writing either
 * out-param, so passing l / r as both inputs and outputs is safe. */
static void fx_reverb_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  fx_reverb(fx, slot, sr, cap, *l, *r, p, l, r);
}

/* Octaver's added latency, adapted to the vtable's (fx, slot) signature. */
static int fx_octaver_latency_vt(const le_fx_state* fx, int slot) {
  return le_octaver_latency(&fx->oct[slot][0]);
}

/* ---- per-type lazy allocation (control thread) ----
 *
 * Each ringed/buffered effect lazily allocates its heap state on first use and
 * keeps it for reuse (a reorder back to the type reuses it). All-or-nothing: on
 * OOM each helper frees only what THIS call allocated and leaves any pre-existing
 * buffer the slot already owned.
 *
 * Every buffer here is written by the audio thread from the first frame the
 * slot processes (and cleared whole on a re-enable), so it comes from
 * le_rt_alloc_prefaulted: fork-shielded, and every page faulted in now, on
 * this thread (rt_alloc.h). The offline renderers (wet cache, performance
 * render) reach this too; they write the rings at once, so the prefault costs
 * them nothing extra. Released through le_fx_free_delay / le_fx_free_octaver,
 * never free(). */

/* Allocates delay ring [slot][chan] if absent. 1 = newly allocated, 0 = already
 * present, -1 = OOM. */
static int fx_alloc_ring(le_fx_state* fx, int slot, int chan, int cap) {
  if (fx->delay[slot][chan] != NULL) return 0;
  fx->delay[slot][chan] =
      (float*)le_rt_alloc_prefaulted((size_t)cap * sizeof(float));
  return fx->delay[slot][chan] != NULL ? 1 : -1;
}

/* DELAY / ECHO: a stereo pair of delay rings (one per channel). */
static int32_t fx_stereo_ring_prepare(le_fx_state* fx, int slot, int cap) {
  const int a0 = fx_alloc_ring(fx, slot, 0, cap);
  if (a0 < 0) return LE_ERR_INVALID;
  if (fx_alloc_ring(fx, slot, 1, cap) < 0) {
    if (a0 == 1) { /* free only the ring this call allocated */
      le_rt_free(fx->delay[slot][0]);
      fx->delay[slot][0] = NULL;
    }
    return LE_ERR_INVALID;
  }
  return LE_OK;
}

/* REVERB: one ring (both stereo banks pack into delay[slot][0]; [1] is unused,
 * and a [1] retained from a prior delay-type is left for reuse). */
static int32_t fx_reverb_prepare(le_fx_state* fx, int slot, int cap) {
  return fx_alloc_ring(fx, slot, 0, cap) < 0 ? LE_ERR_INVALID : LE_OK;
}

/* OCTAVER: the stereo ring plus the phase-vocoder buffers (out / last_phase /
 * sum_phase per channel) and the shared Hann window — up to 8 allocations. Tracks
 * each it newly makes and frees exactly those, in reverse, on any failure. */
static int32_t fx_octaver_prepare(le_fx_state* fx, int slot, int cap) {
  float** owned[8]; /* addresses of the pointers we null on rollback */
  int n = 0;
  for (int chan = 0; chan < 2; ++chan) {
    if (fx->delay[slot][chan] == NULL) {
      fx->delay[slot][chan] =
          (float*)le_rt_alloc_prefaulted((size_t)cap * sizeof(float));
      if (fx->delay[slot][chan] == NULL) goto oom;
      owned[n++] = &fx->delay[slot][chan];
    }
  }
  le_fx_ensure_pv_tables(); /* before the slot can be processed */
  for (int chan = 0; chan < 2; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    if (o->out == NULL) {
      o->out = (float*)le_rt_alloc_prefaulted((size_t)LE_PV_N * sizeof(float));
      if (o->out == NULL) goto oom;
      owned[n++] = &o->out;
    }
    if (o->last_phase == NULL) {
      o->last_phase =
          (float*)le_rt_alloc_prefaulted((size_t)LE_PV_BINS * sizeof(float));
      if (o->last_phase == NULL) goto oom;
      owned[n++] = &o->last_phase;
    }
    if (o->sum_phase == NULL) {
      o->sum_phase =
          (float*)le_rt_alloc_prefaulted((size_t)LE_PV_BINS * sizeof(float));
      if (o->sum_phase == NULL) goto oom;
      owned[n++] = &o->sum_phase;
    }
  }
  return LE_OK;
oom:
  for (int i = n - 1; i >= 0; --i) {
    le_rt_free(*owned[i]);
    *owned[i] = NULL;
  }
  return LE_ERR_INVALID;
}

/* ---- per-type parameter descriptors (le_fx_param_info) ----
 *
 * One row per parameter, in parameter order. Each states what the kernel above
 * does with the normalized setting: the mapping, the unit it reads in, and the
 * setting a freshly engaged effect starts at (le_fx_defaults reads `def` from
 * here, so the defaults have one home). test_fx_param_descriptors_match_kernels
 * measures the kernels against these rows. The seven built-ins are segno's own
 * effects, so none carries LE_FX_PARAM_TAPER_UNVERIFIED. */
#define LE_FX_ROWS(t) t, (int32_t)(sizeof(t) / sizeof(t[0]))

static const le_fx_param_desc LE_FX_DRIVE_PARAMS[] = {
    /* tanh pre-gain 1 + 29 v */
    {"drive", LE_FX_UNIT_TIMES, 0, 1.0f, 30.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"level", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.8f, 0},
};
static const le_fx_param_desc LE_FX_FILTER_PARAMS[] = {
    /* 20 * 900^v Hz, clamped to 0.45 x the sample rate */
    {"cutoff", LE_FX_UNIT_HZ, 0, 20.0f, 18000.0f, LE_FX_CURVE_EXPONENTIAL, 0.5f,
     0},
    {"resonance", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.2f,
     0},
};
static const le_fx_param_desc LE_FX_DELAY_PARAMS[] = {
    /* v x the one-second ring, at least one sample */
    {"time", LE_FX_UNIT_MS, 0, 0.0f, 1000.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
    {"feedback", LE_FX_UNIT_PERCENT, 0, 0.0f, 95.0f, LE_FX_CURVE_LINEAR, 0.35f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
};
static const le_fx_param_desc LE_FX_TREMOLO_PARAMS[] = {
    {"rate", LE_FX_UNIT_HZ, 0, 0.1f, 12.0f, LE_FX_CURVE_LINEAR, 0.3f, 0},
    {"depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.7f, 0},
};
static const le_fx_param_desc LE_FX_OCTAVER_PARAMS[] = {
    /* ratio 2^((v - 0.5) * 48 / 12); whole semitones across +-2 octaves */
    {"shift", LE_FX_UNIT_SEMITONES, 49, -24.0f, 24.0f, LE_FX_CURVE_LINEAR,
     0.25f, 0},
    {"tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    /* position 0 = phase vocoder, 1 = PSOLA (fx_octaver: v >= 0.5) */
    {"mode", LE_FX_UNIT_CHOICE, 2, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f, 0},
};
static const le_fx_param_desc LE_FX_ECHO_PARAMS[] = {
    {"time", LE_FX_UNIT_MS, 0, 0.0f, 1000.0f, LE_FX_CURVE_LINEAR, 0.45f, 0},
    {"feedback", LE_FX_UNIT_PERCENT, 0, 0.0f, 97.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
};
static const le_fx_param_desc LE_FX_REVERB_PARAMS[] = {
    /* comb feedback 0.70 + 0.28 v; feedback low-pass 0.4 v */
    {"size", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"damping", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
};

/* A type's rows are the parameters an entry holds, so none may outgrow it. */
#define LE_FX_ROWS_FIT(t)                                  \
  _Static_assert(sizeof(t) / sizeof(t[0]) <= LE_FX_PARAMS, \
                 #t " has more rows than LE_FX_PARAMS")
LE_FX_ROWS_FIT(LE_FX_DRIVE_PARAMS);
LE_FX_ROWS_FIT(LE_FX_FILTER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DELAY_PARAMS);
LE_FX_ROWS_FIT(LE_FX_TREMOLO_PARAMS);
LE_FX_ROWS_FIT(LE_FX_OCTAVER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_ECHO_PARAMS);
LE_FX_ROWS_FIT(LE_FX_REVERB_PARAMS);

/* LE_FX_PLUGIN process: forward one stereo sample to the hosted plugin slot
 * published for this chain entry (NULL / not-ready => dry passthrough; the slot
 * adapter handles the per-sample/block bridging). No DSP state lives in
 * le_fx_state for a plugin — the host owns it. */
static void fx_plugin_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  (void)sr;
  (void)cap;
  (void)p;
  le_plugin_slot* s =
      atomic_load_explicit(&fx->plugin[slot], memory_order_acquire);
  le_plugin_slot_process(s, l, r);
}

/* D-RT: bound a misbehaving plugin's output so it cannot poison downstream
 * lanes or the master sum — NaN/Inf map to 0 and denormals flush to 0. */
static inline float fx_sanitize(float x) {
  if (!isfinite(x)) return 0.0f;
  if (x < 1e-30f && x > -1e-30f) return 0.0f;
  return x;
}

typedef struct le_fx_vtable {
  /* Processes one stereo sample through chain slot [slot] in place, advancing
   * that slot's per-channel DSP state. NULL == a no-op slot (LE_FX_NONE). */
  void (*process)(le_fx_state* fx, int slot, int sr, int cap, float* l, float* r,
                  const float* p);
  /* Added latency in frames for slot [slot], or NULL when the effect adds none. */
  int (*latency)(const le_fx_state* fx, int slot);
  /* Lazily allocates slot [slot]'s heap buffers (control thread). LE_OK, or
   * LE_ERR_INVALID on OOM (after freeing whatever it allocated this call). NULL =
   * the type needs no allocation. */
  int32_t (*prepare)(le_fx_state* fx, int slot, int cap);
  /* The type's parameter descriptors (le_fx_param_info) and their count; NULL
   * and 0 for a type without fixed params. Defaults come from here. */
  const le_fx_param_desc* params;
  int32_t param_count;
} le_fx_vtable;

/* Indexed by le_fx_type — one row per effect. Adding an effect is adding its
 * kernels above + one row here. LE_FX_NONE is the all-NULL no-op (the empty-chain
 * regression guard). */
static const le_fx_vtable LE_FX[] = {
    [LE_FX_NONE] = {NULL, NULL, NULL, NULL, 0},
    [LE_FX_DRIVE] = {fx_drive_process, NULL, NULL, LE_FX_ROWS(LE_FX_DRIVE_PARAMS)},
    [LE_FX_FILTER] = {fx_filter_process, NULL, NULL, LE_FX_ROWS(LE_FX_FILTER_PARAMS)},
    [LE_FX_DELAY] =
        {fx_delay_process, NULL, fx_stereo_ring_prepare, LE_FX_ROWS(LE_FX_DELAY_PARAMS)},
    [LE_FX_TREMOLO] = {fx_tremolo_process, NULL, NULL, LE_FX_ROWS(LE_FX_TREMOLO_PARAMS)},
    [LE_FX_OCTAVER] = {fx_octaver_process, fx_octaver_latency_vt,
                       fx_octaver_prepare, LE_FX_ROWS(LE_FX_OCTAVER_PARAMS)},
    [LE_FX_ECHO] =
        {fx_echo_process, NULL, fx_stereo_ring_prepare, LE_FX_ROWS(LE_FX_ECHO_PARAMS)},
    [LE_FX_REVERB] =
        {fx_reverb_process, NULL, fx_reverb_prepare, LE_FX_ROWS(LE_FX_REVERB_PARAMS)},
    /* A hosted plugin: process forwards to its slot; no params, no prepare, no
     * defaults (the host owns all state). Output is sanitized at the chain
     * boundary in fx_apply_chain. */
    [LE_FX_PLUGIN] = {fx_plugin_process, NULL, NULL, NULL, 0},
};
#define LE_FX_TYPE_COUNT ((int32_t)(sizeof(LE_FX) / sizeof(LE_FX[0])))

/* Whether a bypassed slot of [type] drains its tail rather than crossfading
 * out: a ring-owning type with no reported latency (delay, echo, reverb).
 * Everything else — memoryless kernels, the latency-bearing octaver, hosted
 * plugins — crossfades (see fx_apply_chain's doc). */
int le_fx_type_drains(int32_t type) {
  return type > LE_FX_NONE && type < LE_FX_TYPE_COUNT &&
         LE_FX[type].prepare != NULL && LE_FX[type].latency == NULL;
}

/* Applies a chain to one stereo sample, in chain order, carrying the (l, r) pair
 * in place. The chain is stageless: every active entry processes both channels.
 * [count] is the active chain length; [types]/[params]/[enabled] are the
 * per-buffer snapshot ([enabled] is per-slot EFFECTIVE bits — chain && slot —
 * or NULL for all-enabled).
 *
 * Every effect runs in full stereo — each colours l and r through its own
 * per-channel DSP state, so there is no mono/stereo distinction and no ordering
 * constraint: a reverb (or any decorrelating effect) may sit anywhere in the
 * chain and every later effect still processes both channels. A mono source
 * seeds l == r, so a symmetric chain leaves l == r and is audibly unchanged.
 * Dispatch is table-driven (LE_FX); an out-of-range or no-op (LE_FX_NONE) slot is
 * skipped.
 *
 * Enable crossfade: each slot tracks its effective bit in enable_target and
 * ramps enable_mix linearly over ~LE_FX_ENABLE_RAMP_MS on a transition.
 * enable_mix scales the slot's FEED: the output is dry * (1 - mix) plus the
 * effect run on dry * mix, so a settled enabled slot is the effect verbatim
 * and a ramp hands the new audio from the effect to the dry path. Bypass
 * (slice 3b; accepted: "bypass sends new audio dry and drains old wet
 * tails"): once the feed has ramped to silence the slot keeps running on
 * that silence and its tail — whatever the effect still holds — sums onto
 * the dry signal until it has stayed under LE_FX_DRAIN_FLOOR for
 * a whole delay-ring horizon (at least LE_FX_DRAIN_QUIET_MS); then the slot is
 * skipped entirely, the same shape as the LE_FX_NONE skip, so a settled
 * bypassed slot is bit-exact passthrough by construction (D-BITEXACT). Only
 * a ring-owning type with no reported latency drains (le_fx_type_drains:
 * delay, echo, reverb — linear, so the feed ramp is the output ramp, and the
 * tail is what the rings hold). Everything else crossfades out over the
 * ramp on the full feed (dry * (1 - mix) + wet * mix) and settles with no
 * drain: a memoryless drive has no tail and its small-signal gain would
 * make a scaled feed overshoot both endpoints; a latency-bearing slot (the
 * octaver) holds a delayed copy of the dry signal, which summed onto the
 * direct path would double the audio for the latency window; a hosted
 * plugin owns its tail and has no reset seam.
 * On the re-enable edge from a settled bypass, a BUILT-IN slot starts
 * clean: le_fx_entry_reset, plus — for a ring-owning type only — its
 * delay-ring content zeroed, so stale integrators or ring content never
 * sound. A latency-bearing slot (the octaver) is then WARMED for its
 * reported latency: the kernel is fed input while the output stays bit-exact
 * dry, so its delay-matched dry tap holds real signal before the ramp-in —
 * no silence hole. An LE_FX_PLUGIN slot has no reset seam — the host owns
 * its internal state (D-LIFE), so a bypassed plugin's frozen tail resumes
 * and fades back in on re-enable; a flush seam is future work.
 *
 * RT note: a ring clear is [cap] floats per allocated channel (cap ==
 * sample_rate, ~190 KB/channel at 48 kHz, ~750 KB/channel at 192 kHz), so
 * ring-clearing re-enables are SPACED by enable_clear_cooldown: at most one
 * per LE_FX_ENABLE_CLEAR_SPACING samples per chain — a whole-chain stomp
 * engages its ring slots staggered a few ms apart instead of memsetting
 * every ring inside one callback. Ring-less types engage immediately. A
 * fully settled ENABLED slot takes the wet result verbatim (no crossfade
 * arithmetic), keeping default-enabled output bit-identical to the
 * pre-enable-flag engine.
 *
 * A slot the chain does NOT process cannot advance this state machine; the
 * per-buffer snapshots settle such slots to bypass while their effective bit
 * is 0 (le_fx_enable_force_bypass), so gaps never strand a ramp. */
/* An entry's input choice applied to a pair: what the entry's effects are
 * handed (per entry), or what a rack's pedals are handed (at its head). */
static inline void fx_chan_input(int32_t mode, float* l, float* r) {
  switch (mode) {
    case LE_FX_CHAN_IN_LEFT:
      *r = *l;
      break;
    case LE_FX_CHAN_IN_RIGHT:
      *l = *r;
      break;
    case LE_FX_CHAN_IN_MONO: {
      const float mid = 0.5f * (*l + *r);
      *l = mid;
      *r = mid;
      break;
    }
    default:
      break;
  }
}

/* An entry's output side applied to a pair: its output choice, then its
 * gains and level. Linear, which the rack tail relies on. */
static inline void fx_chan_output(const le_fx_chan* c, float* l, float* r) {
  if (c->out_mode == LE_FX_CHAN_OUT_MONO) {
    const float mid = 0.5f * (*l + *r);
    *l = mid;
    *r = mid;
  }
  *l *= c->gl * c->level;
  *r *= c->gr * c->level;
}

/* A rack's head, reached at its FIRST entry [s] (fx_apply_chain).
 *
 * Finds the rack's LAST entry (where the rack's crossfade lives) and whether
 * any of its pedals wants to run, advances the crossfade toward that, and
 * applies the RACK's input choice (the first entry's) to the pair the rack
 * is handed, faded the same way: while any pedal is on the pedals get the
 * chosen pair, whatever the first pedal is; with every pedal off the pair
 * passes untouched. Returns the last entry's index, or -1 for a run with no
 * last entry (not a rack, nothing applied). */
static inline int fx_rack_head(le_fx_state* fx, int s, int count,
                               const int32_t* enabled, int sr, float* xl,
                               float* xr) {
  int on = 0;
  int tail = -1;
  for (int t = s; t < count; ++t) {
    if (enabled == NULL || enabled[t] != 0) on = 1;
    if (fx->chan[t].rack & LE_FX_RACK_LAST) {
      tail = t;
      break;
    }
  }
  if (tail < 0) return -1;
  const float target = on ? 1.0f : 0.0f;
  float m = fx->rack_mix[tail];
  if (!fx->rack_primed[tail]) {
    m = target;
    fx->rack_primed[tail] = 1;
  } else if (m != target) {
    const float step =
        sr > 0 ? 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * (float)sr) : 1.0f;
    m = on ? m + step : m - step;
    if (m > 1.0f) m = 1.0f;
    if (m < 0.0f) m = 0.0f;
  }
  fx->rack_mix[tail] = m;
  const int32_t mode = fx->chan[s].in_mode;
  if (m > 0.0f && mode != LE_FX_CHAN_IN_STEREO) {
    float il = *xl;
    float ir = *xr;
    fx_chan_input(mode, &il, &ir);
    if (m >= 1.0f) {
      *xl = il;
      *xr = ir;
    } else {
      *xl += (il - *xl) * m;
      *xr += (ir - *xr) * m;
    }
  }
  return tail;
}

/* A rack's output side, applied after its LAST entry [s] to whatever the
 * rack handed on. [dl, dr] is the pair the rack was handed at its head.
 *
 * On (rack_mix 1) the side applies to the whole result: T(x). Off (0) the
 * pair the rack was handed passes untouched and only what the rack ADDED to
 * it — a tail still draining out of a bypassed pedal — goes through the
 * side, at the level it was heard at: d + T(x) - T(d), which the side's
 * linearity makes d + T(x - d). In between the two blend, so a stomp never
 * steps. Settled off with nothing draining the result is d exactly, so a
 * rack with every pedal off is bit-exact passthrough; settled on it is the
 * arithmetic the per-entry path uses, so a rack whose last entry is an
 * engaged effect sounds exactly as it did when that entry carried it. */
static inline void fx_rack_output(const le_fx_state* fx, int s, float dl,
                                  float dr, float* xl, float* xr) {
  const float m = fx->rack_mix[s];
  const le_fx_chan* c = &fx->chan[s];
  if (m <= 0.0f && *xl == dl && *xr == dr) return; /* nothing added: dry */
  float tl = *xl;
  float tr = *xr;
  fx_chan_output(c, &tl, &tr);
  if (m >= 1.0f) {
    *xl = tl;
    *xr = tr;
    return;
  }
  float ul = dl;
  float ur = dr;
  fx_chan_output(c, &ul, &ur);
  if (m <= 0.0f) {
    *xl = dl + (tl - ul);
    *xr = dr + (tr - ur);
  } else {
    *xl = tl + (1.0f - m) * (dl - ul);
    *xr = tr + (1.0f - m) * (dr - ur);
  }
}

void fx_apply_chain_with_gain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled, int gain_at, float gain) {
  float xl = *l;
  float xr = *r;
  /* The rack being walked: its last entry (-1 outside a rack) and the pair
   * its head was handed (fx_rack_head / fx_rack_output). */
  int rack_tail = -1;
  float rack_dl = 0.0f;
  float rack_dr = 0.0f;
  if (fx->enable_clear_cooldown > 0) fx->enable_clear_cooldown--;
  for (int s = 0; s < count; ++s) {
    if (s == gain_at) { xl *= gain; xr *= gain; }
    if (fx->chan_any && (fx->chan[s].rack & LE_FX_RACK_FIRST)) {
      rack_dl = xl;
      rack_dr = xr;
      rack_tail = fx_rack_head(fx, s, count, enabled, sr, &xl, &xr);
    }
    const int32_t ty = types[s];
    if (ty > LE_FX_NONE && ty < LE_FX_TYPE_COUNT && LE_FX[ty].process) {
      /* Plugin installation can replace a draining built-in without a ring
       * command. Its obsolete tail state belongs to this callback, never
       * to the concurrent installer. Plugins use crossfade, not drain. */
      if (ty == LE_FX_PLUGIN) {
        fx->enable_drain[s] = 0;
        fx->enable_quiet[s] = 0;
      }
      const int32_t want = enabled == NULL || enabled[s] != 0;
      if (want != fx->enable_target[s]) {
        if (want && fx->enable_mix[s] <= 0.0f && fx->enable_drain[s] == 0) {
          /* Re-enable edge from a SETTLED bypass: start clean so nothing
           * stale ever sounds. A re-enable that lands mid-fade-out or
           * mid-drain keeps the state instead — the slot never stopped
           * processing, so nothing is stale, and resetting would
           * discontinue a still-audible tail.
           * Only ring-OWNING types (vtable `prepare` non-NULL) pay the ring
           * clear, and those are spaced by the cooldown: a deferred slot
           * simply stays bypassed and retries next sample. */
          const int needs_clear =
              LE_FX[ty].prepare != NULL &&
              (fx->delay[s][0] != NULL || fx->delay[s][1] != NULL);
          if (needs_clear && fx->enable_clear_cooldown > 0) goto slot_done;
          le_fx_entry_reset(fx, s);
          if (needs_clear) {
            le_fx_entry_clear_rings(fx, s, cap);
            fx->enable_clear_cooldown = LE_FX_ENABLE_CLEAR_SPACING;
          }
          fx->enable_warmup[s] = le_fx_added_latency(fx, s, ty);
        } else if (!want) {
          fx->enable_warmup[s] = 0; /* an aborted warmup never resumes */
          /* Bypass edge: mark the tail draining once the feed has
           * ramped to silence; none for a latency-bearing slot, which
           * crossfades out instead (see above). */
          fx->enable_drain[s] = le_fx_type_drains(ty) ? 1 : 0;
          fx->enable_quiet[s] = 0;
        }
        if (want) fx->enable_drain[s] = 0; /* fed again: nothing to drain */
        fx->enable_target[s] = want;
      }
      if (want && fx->enable_warmup[s] > 0) {
        /* Warm a latency-bearing slot: feed the kernel, discard its output,
         * pass the dry signal through bit-exact until the delay-matched tap
         * holds real input, THEN ramp in. */
        float wl = xl;
        float wr = xr;
        LE_FX[ty].process(fx, s, sr, cap, &wl, &wr, params[s]);
        fx->enable_warmup[s]--;
        goto slot_done;
      }
      float mix = fx->enable_mix[s];
      if (want) {
        if (mix < 1.0f) {
          /* Per-sample linear ramp step: full swing in the ramp window.
           * Computed only while a ramp is actually in flight — the settled
           * paths never pay the divide. */
          const float step =
              sr > 0 ? 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * (float)sr)
                     : 1.0f;
          mix += step;
          if (mix > 1.0f) mix = 1.0f;
          fx->enable_mix[s] = mix;
        }
      } else if (mix > 0.0f) {
        const float step =
            sr > 0 ? 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * (float)sr)
                   : 1.0f;
        mix -= step;
        if (mix < 0.0f) mix = 0.0f;
        fx->enable_mix[s] = mix;
      } else if (fx->enable_drain[s] <= 0) {
        goto slot_done; /* settled bypassed, tail drained: skip (D-BITEXACT) */
      }
      /* The feed: the whole dry signal while settled enabled (and always for
       * a crossfading type), a scaled copy while a draining type ramps,
       * exact silence while it drains.
       *
       * Channel handling (slice 3e) rides the FEED, not the dry: the entry's
       * input choice decides what its effects are handed, and the untouched
       * (xl, xr) stays the dry side of the crossfade — so a bypassed entry
       * passes the signal through exactly as it arrived, choice and all. */
      const int fades = mix < 1.0f && !le_fx_type_drains(ty);
      float il = xl;
      float ir = xr;
      /* A rack's first entry carries the RACK's input choice, applied at the
       * head instead (fx_rack_head). */
      if (fx->chan_any && !(fx->chan[s].rack & LE_FX_RACK_FIRST)) {
        fx_chan_input(fx->chan[s].in_mode, &il, &ir);
      }
      float wl = mix >= 1.0f || fades ? il : il * mix;
      float wr = mix >= 1.0f || fades ? ir : ir * mix;
      LE_FX[ty].process(fx, s, sr, cap, &wl, &wr, params[s]);
      /* Sanitize a plugin slot's output before it re-enters the chain (D-RT).
       * Built-ins are already bounded, so only the plugin row pays this. */
      if (ty == LE_FX_PLUGIN) {
        wl = fx_sanitize(wl);
        wr = fx_sanitize(wr);
      }
      /* The entry's output choice and then its level, both AFTER its effects
       * (the accepted design's order). Stereo keeps what the effects made and
       * the gains are a balance; Mono averages them and the gains place the
       * result. Applied to the wet only, so the crossfade below still blends
       * against the untouched dry — and a tail draining out of a bypassed
       * entry keeps the level it was heard at. A rack's last entry carries
       * the RACK's output side instead, applied after the entry below. */
      if (fx->chan_any && !(fx->chan[s].rack & LE_FX_RACK_LAST)) {
        fx_chan_output(&fx->chan[s], &wl, &wr);
      }
      if (mix >= 1.0f) {
        /* Settled wet: verbatim, not via the crossfade arithmetic. */
        xl = wl;
        xr = wr;
      } else if (fades) {
        xl = xl * (1.0f - mix) + wl * mix;
        xr = xr * (1.0f - mix) + wr * mix;
      } else {
        xl = xl * (1.0f - mix) + wl;
        xr = xr * (1.0f - mix) + wr;
        if (mix <= 0.0f) {
          /* Draining: (wl, wr) is the tail alone. A full memory horizon
           * below the floor settles the slot. */
          const float al = fabsf(wl);
          const float ar = fabsf(wr);
          const float mag = al > ar ? al : ar;
          if (mag < LE_FX_DRAIN_FLOOR) {
            fx->enable_quiet[s]++;
          } else {
            fx->enable_quiet[s] = 0;
          }
          /* A quiet gap shorter than the whole delay memory says nothing
           * about a pending sparse echo. Observe a complete ring horizon,
           * with no arbitrary lifetime cutoff for audible feedback tails. */
          const int32_t minimum = sr > 0 ? (sr * LE_FX_DRAIN_QUIET_MS) / 1000 : 1;
          const int32_t quiet_n = cap > minimum ? cap : minimum;
          if (fx->enable_quiet[s] >= quiet_n) {
            fx->enable_drain[s] = 0;
          }
        }
      }
    }
  slot_done:
    /* Whatever the entry did — processed, passed through as LE_FX_NONE,
     * skipped as a settled bypass — a rack's last entry hands on through the
     * rack's output side. */
    if (s == rack_tail) {
      fx_rack_output(fx, s, rack_dl, rack_dr, &xl, &xr);
      rack_tail = -1;
    }
  }
  if (gain_at == count) { xl *= gain; xr *= gain; }
  *l = xl;
  *r = xr;
}

void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled) {
  fx_apply_chain_with_gain(fx, sr, cap, l, r, count, types, params, enabled, 0, 1);
}

int le_fx_added_latency(const le_fx_state* fx, int slot, int32_t type) {
  if (type > LE_FX_NONE && type < LE_FX_TYPE_COUNT && LE_FX[type].latency) {
    return LE_FX[type].latency(fx, slot);
  }
  return 0;
}

int32_t le_fx_prepare(le_fx_state* fx, int slot, int32_t type, int cap) {
  if (type <= LE_FX_NONE || type >= LE_FX_TYPE_COUNT ||
      LE_FX[type].prepare == NULL) {
    return LE_OK; /* type needs no heap allocation */
  }
  return LE_FX[type].prepare(fx, slot, cap);
}

void le_fx_defaults(int32_t type, float out[LE_FX_PARAMS]) {
  const int known = type > LE_FX_NONE && type < LE_FX_TYPE_COUNT;
  const int32_t n = known ? LE_FX[type].param_count : 0;
  for (int p = 0; p < LE_FX_PARAMS; ++p) {
    out[p] = p < n ? LE_FX[type].params[p].def : 0.0f; /* NONE / unknown: 0 */
  }
}

int32_t le_fx_param_count(int32_t type) {
  if (type < LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return LE_ERR_INVALID;
  return LE_FX[type].param_count;
}

int32_t le_fx_param_info(int32_t type, int32_t param, le_fx_param_desc* out) {
  if (out == NULL || type < LE_FX_NONE || type >= LE_FX_TYPE_COUNT ||
      param < 0 || param >= LE_FX[type].param_count) {
    return LE_ERR_INVALID;
  }
  *out = LE_FX[type].params[param];
  return LE_OK;
}
