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

/* One tick of a TPT state-variable filter (Cytomic/Zavalishin form) with
 * coefficients a1 = 1 / (1 + g (g + k)), a2 = g a1, a3 = g a2: advances the
 * state (ic1, ic2) and gives the band-pass v1 and the low-pass v2 (the
 * high-pass is x - k v1 - v2). */
static inline void le_svf_tick(float x, float a1, float a2, float a3,
                               float* ic1, float* ic2, float* v1, float* v2) {
  const float v3 = x - *ic2;
  *v1 = a1 * (*ic1) + a2 * v3;
  *v2 = *ic2 + a2 * (*ic1) + a3 * v3;
  *ic1 = 2.0f * (*v1) - *ic1;
  *ic2 = 2.0f * (*v2) - *ic2;
}

/* The bilinear prewarp of a corner [hz] at [sr]: tan(pi hz / sr), the
 * corner held under 0.45 of the rate. The Looper X kinds' TPT filters
 * design from it (the built-in resonant filter keeps its own float form). */
static double le_prewarp(double hz, int sr) {
  const double rate = (double)(sr > 0 ? sr : 48000);
  if (hz > 0.45 * rate) hz = 0.45 * rate;
  return tan(3.14159265358979323846 * hz / rate);
}

/* A state-variable filter's coefficients for prewarped corner [g] and
 * damping [k] (1 / Q), in le_svf_tick's order. */
static void le_svf_coefs(double g, double k, float* a1, float* a2, float* a3) {
  const double c = 1.0 / (1.0 + g * (g + k));
  *a1 = (float)c;
  *a2 = (float)(g * c);
  *a3 = (float)(g * g * c);
}

/* One tick of an a0-normalized biquad (b0 b1 b2 a1 a2) in transposed direct
 * form II, state [z]. */
static inline float le_biquad_tick(const float* b, float* z, float x) {
  const float y = b[0] * x + z[0];
  z[0] = b[1] * x - b[3] * y + z[1];
  z[1] = b[2] * x - b[4] * y;
  return y;
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
  float v1;
  float v2;
  le_svf_tick(x, a1, a2, a3, &fx->svf_ic1[slot][chan], &fx->svf_ic2[slot][chan],
              &v1, &v2);
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
_Static_assert(LE_OCT_REACH > LE_PV_LATENCY && LE_OCT_REACH > LE_PV_N,
               "the octaver's ring guard covers the dry tap and the PV window");

/* The analysis-hop PHASE of the octaver in chain slot [slot] of [fx]: the
 * owner's quarter plus the slot, mod 4, on the quarter lattice (engine_fx.h).
 * Its analysis ticks fall on the engine frames c with (c + phase) mod
 * LE_PV_HOP equal to 0 (le_oct_seeded_ticks), and the PV frame's later
 * stages a quarter apart after them. Spreading the phase does not reduce the
 * work; it stops it arriving in one callback.
 *
 * WHY IT COSTS NO LATENCY: a PV frame is analysed at hop_count == 0 and its
 * synthesis is emitted a fixed number of ticks later, so the emitted sample
 * always corresponds to input index (head - LE_PV_LATENCY + 1), whatever the
 * phase. So le_octaver_latency stays a flat LE_PV_LATENCY, fx_octaver's dry
 * tap stays matched, and fx_apply_chain's warmup stays sufficient (le_pv_tick
 * has the warmup argument).
 *
 * PER SLOT, NOT PER CHANNEL: mono coherence (test_octaver_mono_coherent)
 * needs identical left and right in to give identical out, so both channels
 * of one instance share a phase.
 *
 * MASKED, not %-ed: hop_count indexes o->out[] in le_pv_tick, so the phase
 * must be in [0, LE_PV_HOP) for any seed a caller stores. */
/* The engine frame the chain is processing (le_fx_state::clock): the one
 * clock the octaver's hop and a heap-state kind's update cadence follow. */
static inline uint32_t le_fx_now(const le_fx_state* fx) {
  return fx->clock_src != NULL
             ? atomic_load_explicit(fx->clock_src, memory_order_relaxed)
             : fx->clock;
}

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
  const uint32_t clock = le_fx_now(fx);
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
  /* PSOLA's analysis marks start at its nominal source distance (dn in
   * le_psola_tick), so the first deposit has nothing to snap. */
  o->in_epoch = LE_PV_N - LE_PV_N / 2 + LE_PSOLA_LAG;
  o->out_epoch = 0;
  o->period = 0.0f;
  o->voiced = 0.0f;
  if (o->out != NULL) memset(o->out, 0, sizeof(float) * LE_PV_OUT);
  o->analysed = 0;
  o->frame_ratio = 1.0f;
  o->frame_formants_move = 0;
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

/* One STFT analysis/synthesis frame, in four stages (the hop split, #887
 * part 9): le_pv_tick runs stage k on the tick a quarter-hop k into the hop,
 * so a frame's work spreads over the callbacks of its hop. The stages pass
 * their results through o->scratch:
 *
 *   win  [LE_PV_N]    the windowed input, then the inverse transform
 *   re   [LE_PV_BINS] the spectrum, then the synthesis spectrum
 *   im   [LE_PV_BINS]
 *   mag  [LE_PV_BINS] magnitude
 *   freq [LE_PV_BINS] true frequency, in bins
 *   env  [LE_PV_BINS] the formant envelope
 *
 * The frame shifts the harmonic structure by `ratio`, holding the cepstral
 * formant envelope fixed in frequency or, with p4 (formants) moved, letting
 * it go with the pitch, and overlap-adds the result into o->out from the
 * element its synthesis tick emits (LE_PV_SYNTH_TICK, so the octaver's
 * latency is LE_PV_LATENCY).
 *
 * Cost per hop per channel: four length-N real FFTs, one per stage but the
 * shift (analysis, the two cepstrum transforms, synthesis; two with the
 * formants moved, which skips the envelope stage), on the shared plan
 * le_pv_fft (fft.h). On the console a stereo frame cost ~170 us in one
 * callback (#1410). The stages are not equal: measured on the dev machine
 * the analysis, envelope, shift and synthesis take about 29, 34, 22 and 15 %
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
static void le_pv_stage_analyse(le_octaver_state* o, const float* fifo,
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
    win[i] = fifo[idx] * le_hann[i];
    if (++idx == cap) idx = 0;
  }
  le_rfft_fwd(&le_pv_fft, win, re, im);
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
}

/* Stage 1: the formant envelope (le_octaver_envelope); skipped for a frame
 * whose formants move with the pitch, which needs none. */
static void le_pv_stage_envelope(le_octaver_state* o) {
  le_octaver_envelope(LE_PV_S_MAG(o), LE_PV_S_ENV(o));
}

/* Stage 2: shift bins by the ratio read at analysis, advance the synthesis
 * phase (2*pi*freq*HOP/N a hop) and rebuild the half spectrum. Holding the
 * formants, each bin is whitened (mag/env) and the envelope re-applied at the
 * DESTINATION bin, so the formants stay fixed in frequency; moving them, the
 * magnitude goes over as it is, envelope and all. */
static void le_pv_stage_shift(le_octaver_state* o) {
  const float ratio = o->frame_ratio;
  float* re = LE_PV_S_RE(o);
  float* im = LE_PV_S_IM(o);
  const float* mag = LE_PV_S_MAG(o);
  const float* freq = LE_PV_S_FREQ(o);
  const float* env = LE_PV_S_ENV(o);
  float syn_mag[LE_PV_BINS];
  float syn_freq[LE_PV_BINS];
  for (int k = 0; k < LE_PV_BINS; ++k) {
    syn_mag[k] = 0.0f;
    syn_freq[k] = 0.0f;
  }
  for (int k = 0; k < LE_PV_BINS; ++k) {
    const int j = (int)((float)k * ratio + 0.5f);
    if (j >= 0 && j < LE_PV_BINS) {
      if (o->frame_formants_move) {
        syn_mag[j] += mag[k];
      } else {
        syn_mag[j] += mag[k] / (env[k] + 1e-9f) * env[j];
      }
      syn_freq[j] = freq[k] * ratio;
    }
  }
  for (int k = 0; k < LE_PV_BINS; ++k) {
    o->sum_phase[k] +=
        2.0f * LE_PI * syn_freq[k] * (float)LE_PV_HOP / (float)LE_PV_N;
    re[k] = syn_mag[k] * cosf(o->sum_phase[k]);
    im[k] = syn_mag[k] * sinf(o->sum_phase[k]);
  }
}

/* Stage 3: inverse transform, synthesis-window, and overlap-add from the
 * accumulator element this tick emits (the Hann x Hann windows at 4x overlap
 * sum to 1.5: divide for unity). */
static void le_pv_stage_synth(le_octaver_state* o) {
  float* win = LE_PV_S_WIN(o);
  le_rfft_inv(&le_pv_fft, LE_PV_S_RE(o), LE_PV_S_IM(o), win);
  const float norm = 1.0f / 1.5f;
  float* out = o->out + LE_PV_SYNTH_TICK;
  for (int i = 0; i < LE_PV_N; ++i) {
    out[i] += win[i] * le_hann[i] * norm;
  }
}

/* Emits one phase-vocoder output sample (latency LE_PV_LATENCY), running a
 * frame's stage at each quarter of the hop and streaming the synthesis
 * accumulator out by one sample per call, shifting it down by a hop once a
 * hop is fully emitted.
 *
 * HOP PHASE AND THE THREE THINGS IT MUST NOT MOVE. hop_count starts at any
 * value p in [0, LE_PV_HOP) (le_oct_seeded_ticks: whatever puts the
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
 *  2. The dry-delay match (fx_octaver's tap at head - latency + 1) is the same
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
static float le_pv_tick(le_octaver_state* o, const float* fifo, int head, int cap,
                        float ratio, int formants_move) {
  if (o->out == NULL || o->scratch == NULL) return 0.0f;
  switch (o->hop_count) {
    case 0:
      le_pv_stage_analyse(o, fifo, head, cap);
      o->frame_ratio = ratio;
      o->frame_formants_move = formants_move;
      o->analysed = 1;
      break;
    case LE_PV_HOP / 4:
      if (o->analysed && !o->frame_formants_move) le_pv_stage_envelope(o);
      break;
    case LE_PV_HOP / 2:
      if (o->analysed) le_pv_stage_shift(o);
      break;
    case LE_PV_SYNTH_TICK:
      if (o->analysed) le_pv_stage_synth(o);
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
 * warn about monitoring lag. PSOLA reuses the PV's OLA accumulator (the no-
 * extra-allocation budget part 3 fixed); its grain centers sit LE_PV_N behind the
 * input it reads, and it reads LE_PSOLA_LAG further back than the head, so its
 * latency equals the phase vocoder's. Both modes therefore report LE_PV_LATENCY
 * and the dry tap does not jump on a switch. The argument is the per-mode seam a
 * future dedicated PSOLA buffer (lower latency) would use. */
static int le_octaver_latency(const le_octaver_state* o) {
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
static float le_psola_tick(le_octaver_state* o, const float* fifo, int head,
                           int cap, float ratio) {
  if (o->out == NULL) return 0.0f;
  const int N = LE_PV_N;
  /* PSOLA works on the input LE_PSOLA_LAG ticks back (its pitch window, its
   * grain sources and its dry fallback), so its latency matches the split
   * phase vocoder's. */
  const int lag = LE_PSOLA_LAG;
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
      int idx = head - lag - (LE_PSOLA_WIN - 1) + i;
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
    const int dn = N - c + lag; /* nominal source distance behind the head */
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
 * then mixes a delay-matched dry tap (LE_PV_LATENCY back) with a wet voice from the
 * phase vocoder (mode p3 < 0.5) or PSOLA (part 4, currently silent). p0 = shift
 * (0 = -2 oct, 0.5 = unison, 1 = +2 oct), p1 = tone (one-pole darkening of the
 * wet voice), p2 = dry/wet mix, p3 = mode, p4 = formants (held or moved with
 * the pitch, the phase vocoder only). Params are one-pole smoothed
 * (zipper-free) and a mode switch runs an equal-power gain dip while the DSP
 * runtime resets. The ring length `cap` equals the sample rate (1 s), used here
 * as the time base for the smoothing / dip constants. */
static float fx_octaver(le_fx_state* fx, int slot, int chan, int cap, float x,
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
  const float wet = o->cur_mode == 0
                        ? le_pv_tick(o, buf, head, cap, ratio, p[4] >= 0.5f)
                        : le_psola_tick(o, buf, head, cap, ratio);

  /* Tone: a one-pole low-pass on the wet voice that opens up as p1 rises. */
  const float a = 0.05f + 0.9f * o->sm_tone;
  float lp = fx->fx_lp[slot][chan];
  lp += a * (wet - lp);
  fx->fx_lp[slot][chan] = lp;

  /* Delay-matched dry (D2): read the dry tap behind the newest by the active
   * mode's added latency (le_octaver_latency) so the mix stays comb-free. Both
   * modes report LE_PV_LATENCY, so the dry tap does not jump on a mode switch. */
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
 * allocated octaver slot it memsets the phase-vocoder accumulator and phase
 * buffers (~9 KB/channel; the frame scratch is not cleared, see
 * le_octaver_state::analysed). That is bounded and fires only on a discrete type-change
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
  /* A heap-state kind starts clean too: its block is cleared and settled
   * the next time the slot runs (fx_kind_state). */
  le_fx_kinds* kinds = atomic_load_explicit(&fx->kinds, memory_order_acquire);
  if (kinds != NULL) kinds->slot[slot].cur = NULL;
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
    le_rt_free(o->scratch);
    o->scratch = NULL;
  }
}

void le_fx_free_delay(le_fx_state* fx, int slot) {
  le_rt_free(fx->delay[slot][0]);
  fx->delay[slot][0] = NULL;
  le_rt_free(fx->delay[slot][1]);
  fx->delay[slot][1] = NULL;
}

void le_fx_free_slot(le_fx_state* fx, int slot) {
  le_fx_free_delay(fx, slot);
  le_fx_free_octaver(fx, slot);
  le_fx_free_kinds(fx, slot);
}

void le_fx_state_free_buffers(le_fx_state* fx) {
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_free_slot(fx, s);
  le_fx_free_kind_table(fx);
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
 * sum_phase / scratch per channel) and the shared Hann window — up to 10
 * allocations. Tracks
 * each it newly makes and frees exactly those, in reverse, on any failure. */
static int32_t fx_octaver_prepare(le_fx_state* fx, int slot, int cap) {
  float** owned[10]; /* addresses of the pointers we null on rollback */
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
      o->out = (float*)le_rt_alloc_prefaulted((size_t)LE_PV_OUT * sizeof(float));
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
    if (o->scratch == NULL) {
      o->scratch =
          (float*)le_rt_alloc_prefaulted((size_t)LE_PV_SCRATCH * sizeof(float));
      if (o->scratch == NULL) goto oom;
      owned[n++] = &o->scratch;
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
    /* position 0 = held where they are (the cepstral envelope stays fixed in
     * frequency), 1 = moved with the pitch; the phase vocoder only */
    {"formants", LE_FX_UNIT_CHOICE, 2, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
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

/* The EQ's parameters (the generic module's whole set), in the values the
 * Looper X applies, as measured in #891
 * (docs/plan/2026-10-23-looperx-eq-measured.md). The defaults are Ed's 4-band
 * EQ's. Where a rack's control shows a range other than the one it applies
 * (Ed's Lo Mid, Hi Mid and High frequencies and its Low and High Q), or uses
 * its own scale (the mid frequencies, 40..8000 Hz in Ed's and the Drum Rack
 * and 120..16000 Hz in the others), the rack variant converts the setting, so
 * every row shows the value the kernel applies. The cuts never switch off:
 * at the ends of their ranges they are a 20 Hz high-pass and a 20 kHz
 * low-pass. The layout sets the outer bands' shape and whether the cuts run
 * (le_eq_targets). */
static const le_fx_param_desc LE_FX_EQ_PARAMS[] = {
    {"low_cut", LE_FX_UNIT_HZ, 0, 20.0f, 8000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.21f, 0},
    {"low_gain", LE_FX_UNIT_DB, 0, -18.0f, 18.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"low_freq", LE_FX_UNIT_HZ, 0, 20.0f, 1000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.384476f, 0},
    {"low_q", LE_FX_UNIT_Q, 0, 0.4f, 10.0f, LE_FX_CURVE_EXPONENTIAL, 0.0f, 0},
    {"lo_mid_gain", LE_FX_UNIT_DB, 0, -18.0f, 18.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    /* Ed's default, 101.5 Hz */
    {"lo_mid_freq", LE_FX_UNIT_HZ, 0, 20.0f, 20000.0f,
     LE_FX_CURVE_EXPONENTIAL, 0.235138f, 0},
    {"lo_mid_q", LE_FX_UNIT_Q, 0, 0.4f, 10.0f, LE_FX_CURVE_EXPONENTIAL, 0.174f,
     0},
    {"hi_mid_gain", LE_FX_UNIT_DB, 0, -18.0f, 18.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    /* Ed's default, 3040 Hz */
    {"hi_mid_freq", LE_FX_UNIT_HZ, 0, 20.0f, 20000.0f,
     LE_FX_CURVE_EXPONENTIAL, 0.727302f, 0},
    {"hi_mid_q", LE_FX_UNIT_Q, 0, 0.4f, 10.0f, LE_FX_CURVE_EXPONENTIAL,
     0.15557f, 0},
    {"high_gain", LE_FX_UNIT_DB, 0, -18.0f, 18.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"high_freq", LE_FX_UNIT_HZ, 0, 1200.0f, 20000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.5278f, 0},
    {"high_q", LE_FX_UNIT_Q, 0, 0.4f, 10.0f, LE_FX_CURVE_EXPONENTIAL, 0.0f, 0},
    {"high_cut", LE_FX_UNIT_HZ, 0, 120.0f, 20000.0f, LE_FX_CURVE_EXPONENTIAL,
     1.0f, 0},
    /* position 0 = low and high shelves and no cuts (Drum), 1 = four bells
     * and both cuts (Ed's and the Para EQ), 2 = four bells and no cuts
     * (Vocal, Studio and Vocal Tuner) */
    {"layout", LE_FX_UNIT_CHOICE, 3, 0.0f, 2.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
};

/* The per-update smoothing factor of a setting that glides over
 * LE_FX_SMOOTH_S at [sr]: the share of the remaining distance one update
 * (LE_FX_UPDATE_FRAMES frames) covers. */
#define LE_FX_SMOOTH_S 0.010
static float le_fx_smooth_k(int sr) {
  return (float)(1.0 - exp(-(double)LE_FX_UPDATE_FRAMES /
                           (LE_FX_SMOOTH_S * (double)(sr > 0 ? sr : 48000))));
}

/* One smoothing step of a setting the update cadence moves: [*cur] covers a
 * share [k] of the way to [tgt], landing on it once within 1e-4 (or at once
 * for k >= 1). The one rule every Looper X kind glides by. */
static inline void le_fx_step_toward(float* cur, float tgt, float k) {
  const float d = tgt - *cur;
  *cur = k >= 1.0f || fabsf(d) < 1e-4f ? tgt : *cur + k * d;
}

/* What every Looper X kind's update starts with: whether it has anything to
 * do, given the settings it last saw ([last], [n] of them), the rate its
 * smoothing factor was computed at and whether something still moves. */
typedef struct le_fx_dyn_head {
  int32_t primed; /* [last] holds settings */
  int32_t k_sr;   /* the rate [k] is for */
  int32_t moving; /* a glide is under way */
  float k;        /* le_fx_smooth_k(k_sr) */
} le_fx_dyn_head;

#define LE_FX_DYN_RUN 1      /* the update has work */
#define LE_FX_DYN_NEW_RATE 2 /* the sample rate changed */
#define LE_FX_DYN_CHANGED 4  /* the settings or the rate changed, or settle */

/* Returns 0 when nothing changed and nothing moves; otherwise LE_FX_DYN_RUN
 * with the other bits saying what changed, and the rate and settings
 * recorded. */
static int le_fx_dyn_begin(le_fx_dyn_head* h, float* last, const float* p,
                           size_t n, int sr, int settle) {
  const int new_rate = !h->primed || h->k_sr != sr;
  const int new_params =
      !h->primed || memcmp(last, p, n * sizeof(float)) != 0;
  if (!settle && !new_rate && !new_params && !h->moving) return 0;
  if (new_rate) {
    h->k_sr = sr;
    h->k = le_fx_smooth_k(sr);
  }
  if (new_params || settle) {
    memcpy(last, p, n * sizeof(float));
    h->primed = 1;
  }
  return LE_FX_DYN_RUN | (new_rate ? LE_FX_DYN_NEW_RATE : 0) |
         (new_rate || new_params || settle ? LE_FX_DYN_CHANGED : 0);
}

/* A setting a kernel reads every sample. Each update moves its glide point
 * one smoothing step toward the target, and the samples after it ramp from
 * wherever the value is onto that point over LE_FX_UPDATE_FRAMES samples,
 * stopping there. A change never steps, and frames the kernel did not run
 * (a slot skipped for a while) only slow the ramp down. */
typedef struct le_fx_glide {
  float v;   /* the value now */
  float inc; /* per-sample step toward g */
  float g;   /* the glide point */
} le_fx_glide;

/* Update: one glide step toward [tgt] (k >= 1 lands at once). Returns
 * whether the value is still moving. */
static int le_fx_glide_step(le_fx_glide* s, float tgt, float k) {
  le_fx_step_toward(&s->g, tgt, k);
  if (k >= 1.0f) s->v = s->g;
  s->inc = (s->g - s->v) * (1.0f / (float)LE_FX_UPDATE_FRAMES);
  if (s->v + s->inc == s->v) { /* closer than a step can show: land */
    s->v = s->g;
    s->inc = 0.0f;
  }
  return s->v != s->g || s->g != tgt;
}

static inline float le_fx_glide_next(le_fx_glide* s) {
  if (s->inc != 0.0f) {
    s->v += s->inc;
    if (s->inc > 0.0f ? s->v >= s->g : s->v <= s->g) {
      s->v = s->g;
      s->inc = 0.0f;
    }
  }
  return s->v;
}

/* ---- EQ (LE_FX_EQ, #887 part 4) ----
 *
 * The Looper X's generic EQ module, of which each rack exposes a subset (the
 * rack variants live in kFxModuleVariants on the Dart side). Six biquads in
 * series, designed in double, as measured in #891
 * (docs/plan/2026-10-23-looperx-eq-measured.md): a 12 dB/octave RBJ high-pass
 * (low cut), the low band, two bells, the high band and a 12 dB/octave RBJ
 * low-pass (high cut). The outer bands are bells, or RBJ shelves in the Drum
 * Rack's layout. Every bell is the fixed-pole one (le_eq_bell), which widens
 * as its gain rises; segno's earlier RBJ constant-Q peak did not. The cuts
 * always run in the layout that has them; a shelf or bell at 0 dB is
 * skipped.
 *
 * Settings are smoothed per update (LE_FX_UPDATE_FRAMES frames) over about
 * 10 ms, in octaves, decibels and log Q, and coefficients are recomputed only
 * while something moves. */
#define LE_EQ_PARAMS_N 15 /* LE_FX_EQ_PARAMS rows */
#define LE_EQ_CUT_Q 0.70710678118654752

/* le_eq_design's kinds, which the other kinds' voicings use too. */
enum { LE_EQ_LOWCUT, LE_EQ_LOW, LE_EQ_LOMID, LE_EQ_HIMID, LE_EQ_HIGH,
       LE_EQ_HIGHCUT };

/* The EQ kind's bands, in processing order. */
enum { LE_EQB_LOWCUT, LE_EQB_LOW, LE_EQB_LOMID, LE_EQB_HIMID, LE_EQB_HIGH,
       LE_EQB_HIGHCUT, LE_EQ_BANDS };

/* The layout positions (the "layout" row). */
enum { LE_EQ_LAYOUT_SHELVES, LE_EQ_LAYOUT_CUTS, LE_EQ_LAYOUT_BELLS };

/* In double: in float, the rounding of a 20 Hz cut's coefficients alone
 * moves its response by 0.1 dB, and the cuts always run. */
typedef struct le_eq_band {
  double b0, b1, b2, a1, a2; /* a0-normalized */
  float mix;                 /* a cut's amount (1 for a shelf or bell) */
  double z[2][2];            /* transposed direct form II, per channel */
} le_eq_band;

typedef struct le_fx_eq {
  /* Smoothed targets per band: log2 Hz, ln Q, and for a shelf or peak its
   * dB, for a cut its amount (1 on, 0 off), which it glides in and out by
   * so switching one never steps. */
  float hz[LE_EQ_BANDS];
  float db[LE_EQ_BANDS];
  float lnq[LE_EQ_BANDS];
  uint32_t active; /* bands that are not the identity */
  /* The settings the targets were last taken from, and the smoothing step
   * for the rate it was computed at: a settled EQ whose settings did not
   * change costs one compare per update. */
  le_fx_dyn_head h;
  float last[LE_EQ_PARAMS_N];
  float tgt_hz[LE_EQ_BANDS];
  float tgt_db[LE_EQ_BANDS];
  float tgt_lnq[LE_EQ_BANDS];
  le_eq_band band[LE_EQ_BANDS];
  /* Whether the outer bands are shelves (the Drum layout), as designed and
   * as the settings ask. They change shape only at 0 dB (fx_eq_update). */
  int32_t shelves;
  int32_t tgt_shelves;
} le_fx_eq;

/* The value of descriptor row [d] at setting v, in its own unit. */
static double le_fx_desc_value(const le_fx_param_desc* d, float v) {
  if (v < 0.0f) v = 0.0f;
  if (v > 1.0f) v = 1.0f;
  if (d->curve == LE_FX_CURVE_EXPONENTIAL) {
    return (double)d->at_min * pow((double)d->at_max / (double)d->at_min, v);
  }
  if (d->curve == LE_FX_CURVE_RECIPROCAL) {
    const double lo = 1.0 / (double)d->at_min;
    return 1.0 / (lo + (1.0 / (double)d->at_max - lo) * v);
  }
  return (double)d->at_min + ((double)d->at_max - (double)d->at_min) * v;
}


/* RBJ cookbook coefficients, in double. kind is an LE_EQ_* design (the
 * peaking ones are RBJ's constant-Q peak, which the other kinds' voicings
 * were fitted with; the EQ kind's bells are le_eq_bell); hz the corner or
 * centre, db the gain, q the Q. */
static void le_eq_design(int kind, double hz, double db, double q, int sr,
                         double c[5]) {
  const double nyq = 0.49 * (double)sr;
  if (hz > nyq) hz = nyq;
  const double w0 = 2.0 * 3.14159265358979323846 * hz / (double)sr;
  const double cw = cos(w0);
  const double sw = sin(w0);
  const double alpha = sw / (2.0 * q);
  const double A = pow(10.0, db / 40.0);
  const double sa = 2.0 * sqrt(A) * alpha;
  double b0, b1, b2, a0, a1, a2;
  switch (kind) {
    case LE_EQ_LOWCUT:
      b0 = (1.0 + cw) / 2.0; b1 = -(1.0 + cw); b2 = b0;
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      break;
    case LE_EQ_HIGHCUT:
      b0 = (1.0 - cw) / 2.0; b1 = 1.0 - cw; b2 = b0;
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      break;
    case LE_EQ_LOW:
      b0 = A * ((A + 1.0) - (A - 1.0) * cw + sa);
      b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
      b2 = A * ((A + 1.0) - (A - 1.0) * cw - sa);
      a0 = (A + 1.0) + (A - 1.0) * cw + sa;
      a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
      a2 = (A + 1.0) + (A - 1.0) * cw - sa;
      break;
    case LE_EQ_HIGH:
      b0 = A * ((A + 1.0) + (A - 1.0) * cw + sa);
      b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
      b2 = A * ((A + 1.0) + (A - 1.0) * cw - sa);
      a0 = (A + 1.0) - (A - 1.0) * cw + sa;
      a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
      a2 = (A + 1.0) - (A - 1.0) * cw - sa;
      break;
    default: /* peaking */
      b0 = 1.0 + alpha * A; b1 = -2.0 * cw; b2 = 1.0 - alpha * A;
      a0 = 1.0 + alpha / A; a1 = -2.0 * cw; a2 = 1.0 - alpha / A;
      break;
  }
  c[0] = b0 / a0; c[1] = b1 / a0; c[2] = b2 / a0; c[3] = a1 / a0;
  c[4] = a2 / a0;
}

/* Exposed for the native tests: band [kind]'s design at these values. */
void le_eq_design_for_test(int kind, double hz, double db, double q, int sr,
                           double c[5]) {
  le_eq_design(kind, hz, db, q, sr, c);
}

/* The Looper X's bell, in double (#891): a fixed-pole peaking filter
 * (Regalia-Mitra), with k = sin(w0 / 2) / q. A boost scales the numerator's
 * k by V = 10^(|db| / 20); a cut is the boost's exact inverse. It equals the
 * RBJ peak at Q q * cos(w0 / 2) / 10^(|db| / 40), so it widens as the gain
 * rises: at +18 dB its skirts are up to 6.7 dB above the RBJ peak's. */
static void le_eq_bell(double hz, double db, double q, int sr, double c[5]) {
  const double nyq = 0.49 * (double)sr;
  if (hz > nyq) hz = nyq;
  const double w0 = 2.0 * 3.14159265358979323846 * hz / (double)sr;
  const double k = sin(0.5 * w0) / q;
  const double cw = cos(w0);
  const double v = pow(10.0, fabs(db) / 20.0);
  double num[3] = {1.0 + v * k, -2.0 * cw, 1.0 - v * k};
  double den[3] = {1.0 + k, -2.0 * cw, 1.0 - k};
  if (db < 0.0) {
    for (int i = 0; i < 3; ++i) {
      const double t = num[i];
      num[i] = den[i];
      den[i] = t;
    }
  }
  c[0] = num[0] / den[0]; c[1] = num[1] / den[0]; c[2] = num[2] / den[0];
  c[3] = den[1] / den[0]; c[4] = den[2] / den[0];
}

/* Exposed for the native tests: the bell at these values. */
void le_eq_bell_for_test(double hz, double db, double q, int sr, double c[5]) {
  le_eq_bell(hz, db, q, sr, c);
}

/* The EQ kind's design of band [b] (LE_EQB_*): the cuts, the outer bands as
 * shelves or bells, and the mid bells. */
static void le_eq_band_design(int b, int shelves, double hz, double db,
                              double q, int sr, double c[5]) {
  switch (b) {
    case LE_EQB_LOWCUT:
      le_eq_design(LE_EQ_LOWCUT, hz, 0.0, q, sr, c);
      return;
    case LE_EQB_HIGHCUT:
      le_eq_design(LE_EQ_HIGHCUT, hz, 0.0, q, sr, c);
      return;
    case LE_EQB_LOW:
      if (shelves) {
        le_eq_design(LE_EQ_LOW, hz, db, q, sr, c);
        return;
      }
      break;
    case LE_EQB_HIGH:
      if (shelves) {
        le_eq_design(LE_EQ_HIGH, hz, db, q, sr, c);
        return;
      }
      break;
    default:
      break;
  }
  le_eq_bell(hz, db, q, sr, c);
}

/* The targets [p] sets, per band: Hz (log2), ln Q, and dB (a shelf or bell)
 * or amount (a cut: 1 where the layout runs the cuts, else 0); and whether
 * the outer bands are shelves. */
static void le_eq_targets(const float* p, float hz[LE_EQ_BANDS],
                          float db[LE_EQ_BANDS], float lnq[LE_EQ_BANDS],
                          int32_t* shelves);

static void fx_eq_update(void* ks, const float* p, int sr, int settle) {
  le_fx_eq* q = (le_fx_eq*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_EQ_PARAMS_N, sr, settle);
  if (!f) return;
  const int new_rate = (f & LE_FX_DYN_NEW_RATE) != 0; /* every design moves */
  /* The targets change only with the settings; a glide reuses them. */
  if (f & LE_FX_DYN_CHANGED) {
    le_eq_targets(p, q->tgt_hz, q->tgt_db, q->tgt_lnq, &q->tgt_shelves);
  }
  const float k = settle ? 1.0f : q->h.k;
  /* The outer bands change shape (bell or shelf) only at 0 dB, where both
   * are the identity: a layout change first glides them to 0 dB, switches
   * the shape there and glides them back, so it never steps. A settle
   * switches at once. */
  if (settle) q->shelves = q->tgt_shelves;
  const int reshaping = q->shelves != q->tgt_shelves;
  int moving = reshaping;
  for (int b = 0; b < LE_EQ_BANDS; ++b) {
    const int outer = b == LE_EQB_LOW || b == LE_EQB_HIGH;
    float* cur[3] = {&q->hz[b], &q->db[b], &q->lnq[b]};
    const float tgt[3] = {q->tgt_hz[b],
                          reshaping && outer ? 0.0f : q->tgt_db[b],
                          q->tgt_lnq[b]};
    int dirty = settle || new_rate;
    for (int i = 0; i < 3; ++i) {
      if (tgt[i] == *cur[i]) continue;
      dirty = 1;
      le_fx_step_toward(cur[i], tgt[i], k);
      if (*cur[i] != tgt[i]) moving = 1;
    }
    if (!dirty) continue; /* only a band that moved is redesigned */
    const int cut = b == LE_EQB_LOWCUT || b == LE_EQB_HIGHCUT;
    /* A cut whose amount has glided to 0, or a shelf or bell that has
     * settled at 0 dB, is the identity: the band is skipped and its memory
     * cleared, so it starts clean when it comes back. A gain that only
     * passes through 0 dB on its way somewhere is never exactly 0, so the
     * band keeps running and its state stays continuous. */
    le_eq_band* band = &q->band[b];
    band->mix = cut ? q->db[b] : 1.0f;
    if (q->db[b] == 0.0f) {
      if (q->active & (1u << b)) memset(band->z, 0, sizeof(band->z));
      q->active &= ~(1u << b);
      continue;
    }
    double c[5];
    le_eq_band_design(b, q->shelves, exp2((double)q->hz[b]),
                      cut ? 0.0 : (double)q->db[b], exp((double)q->lnq[b]),
                      sr, c);
    band->b0 = c[0]; band->b1 = c[1]; band->b2 = c[2];
    band->a1 = c[3]; band->a2 = c[4];
    q->active |= 1u << b;
  }
  if (reshaping && q->db[LE_EQB_LOW] == 0.0f && q->db[LE_EQB_HIGH] == 0.0f) {
    q->shelves = q->tgt_shelves; /* both outer bands are the identity now */
  }
  q->h.moving = moving;
}

static void fx_eq_kprocess(void* ks, float* l, float* r) {
  le_fx_eq* q = (le_fx_eq*)ks;
  /* A non-finite sample would latch into the band memory for good (the
   * conditioning stage's biquads guard the same way). */
  double x[2] = {isfinite(*l) ? *l : 0.0, isfinite(*r) ? *r : 0.0};
  for (int b = 0; b < LE_EQ_BANDS; ++b) {
    if (!(q->active & (1u << b))) continue;
    le_eq_band* f = &q->band[b];
    for (int c = 0; c < 2; ++c) {
      const double in = x[c];
      const double y = f->b0 * in + f->z[c][0];
      f->z[c][0] = f->b1 * in - f->a1 * y + f->z[c][1];
      f->z[c][1] = f->b2 * in - f->a2 * y;
      x[c] = f->mix >= 1.0f ? y : in + f->mix * (y - in);
    }
  }
  *l = (float)x[0];
  *r = (float)x[1];
}

static void le_eq_targets(const float* p, float hz[LE_EQ_BANDS],
                          float db[LE_EQ_BANDS], float lnq[LE_EQ_BANDS],
                          int32_t* shelves) {
  const le_fx_param_desc* d = LE_FX_EQ_PARAMS;
#define LE_EQ_V(i) le_fx_desc_value(&d[i], p[i])
  const double ln_cut_q = log(LE_EQ_CUT_Q);
  const float lv = p[14] < 0.0f ? 0.0f : p[14] > 1.0f ? 1.0f : p[14];
  const int layout = (int)(lv * 2.0f + 0.5f);
  const float cuts = layout == LE_EQ_LAYOUT_CUTS ? 1.0f : 0.0f;
  *shelves = layout == LE_EQ_LAYOUT_SHELVES;
  hz[LE_EQB_LOWCUT] = (float)log2(LE_EQ_V(0));
  db[LE_EQB_LOWCUT] = cuts;
  lnq[LE_EQB_LOWCUT] = (float)ln_cut_q;
  hz[LE_EQB_LOW] = (float)log2(LE_EQ_V(2));
  db[LE_EQB_LOW] = (float)LE_EQ_V(1);
  lnq[LE_EQB_LOW] = (float)log(LE_EQ_V(3));
  hz[LE_EQB_LOMID] = (float)log2(LE_EQ_V(5));
  db[LE_EQB_LOMID] = (float)LE_EQ_V(4);
  lnq[LE_EQB_LOMID] = (float)log(LE_EQ_V(6));
  hz[LE_EQB_HIMID] = (float)log2(LE_EQ_V(8));
  db[LE_EQB_HIMID] = (float)LE_EQ_V(7);
  lnq[LE_EQB_HIMID] = (float)log(LE_EQ_V(9));
  hz[LE_EQB_HIGH] = (float)log2(LE_EQ_V(11));
  db[LE_EQB_HIGH] = (float)LE_EQ_V(10);
  lnq[LE_EQB_HIGH] = (float)log(LE_EQ_V(12));
  hz[LE_EQB_HIGHCUT] = (float)log2(LE_EQ_V(13));
  db[LE_EQB_HIGHCUT] = cuts;
  lnq[LE_EQB_HIGHCUT] = (float)ln_cut_q;
#undef LE_EQ_V
}

/* ---- Dynamics: Compressor, Transient, HP/Gate (#887 part 5) ----
 *
 * The ranges and tapers are the Looper X's own
 * (docs/plan/2026-10-20-looperx-derived-tables.md), and what happens inside
 * each module was measured in #891
 * (docs/plan/2026-10-23-looperx-dynamics-measured.md). Each constant below
 * says what it was fitted to. */

/* The make-up row is the gain the compressor applies, which is not the
 * Looper X's display: its 0..30 dB control applies 0..21.07 dB along a
 * measured curve, which the rack variants convert. The default is Ed's,
 * 3.25 dB (shown there as 1.8 dB). */
static const le_fx_param_desc LE_FX_COMPRESSOR_PARAMS[] = {
    {"threshold", LE_FX_UNIT_DB, 0, 0.0f, -60.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
    {"ratio", LE_FX_UNIT_RATIO, 0, 1.0f, 100.0f, LE_FX_CURVE_RECIPROCAL, 0.76f,
     0},
    {"attack", LE_FX_UNIT_MS, 0, 0.01f, 300.0f, LE_FX_CURVE_EXPONENTIAL, 0.5f,
     0},
    {"release", LE_FX_UNIT_MS, 0, 5.0f, 4000.0f, LE_FX_CURVE_EXPONENTIAL, 0.5f,
     0},
    {"makeup", LE_FX_UNIT_DB, 0, 0.0f, 30.0f, LE_FX_CURVE_LINEAR, 0.10833334f,
     0},
};
/* Shown as the Looper X shows them, 0 to 100 %. */
static const le_fx_param_desc LE_FX_TRANSIENT_PARAMS[] = {
    {"attack", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"attack_length", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.5f, 0},
    {"sustain", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
};
/* The high-pass row is the corner the filter applies: the Looper X's
 * 1..1000 Hz control puts it at half the value it shows, and at its lowest
 * (shown as 1 Hz) runs no high-pass at all: a 60 dB drop there leaves no
 * low-frequency tail, which any filter at 0.5 Hz would. */
static const le_fx_param_desc LE_FX_HP_GATE_PARAMS[] = {
    {"highpass", LE_FX_UNIT_HZ, 0, 0.5f, 500.0f, LE_FX_CURVE_EXPONENTIAL, 0.0f,
     LE_FX_PARAM_OFF_AT_MIN},
    {"gate_threshold", LE_FX_UNIT_DB, 0, -120.0f, 0.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
};
#define LE_COMP_PARAMS_N 5
#define LE_TR_PARAMS_N 3
#define LE_HPG_PARAMS_N 2

/* 20 log10 |x| and back, through log2 and exp2. */
#define LE_DB_PER_OCTAVE 6.0205999132796239f /* 20 log10 2 */
static inline float le_db_of(float x) { return LE_DB_PER_OCTAVE * log2f(x); }
static inline float le_gain_of_db(float db) {
  return exp2f(db * (1.0f / LE_DB_PER_OCTAVE));
}

/* The coefficient of a one-pole smoother with time constant [tau_s] at
 * [sr]: each sample keeps this share of the distance to the target, so the
 * smoother covers 1 - 1/e of a step in tau_s. */
static float le_one_pole(double tau_s, int sr) {
  const double n = tau_s * (double)(sr > 0 ? sr : 48000);
  return n <= 0.0 ? 0.0f : (float)exp(-1.0 / n);
}

/* D-RT: bound a sample so it cannot poison a kernel's state, downstream
 * lanes or the master sum (a hosted plugin's output, a dynamics kind's
 * input): NaN and Inf map to 0, and denormals flush to 0. */
static inline float fx_sanitize(float x) {
  if (!isfinite(x)) return 0.0f;
  if (x < 1e-30f && x > -1e-30f) return 0.0f;
  return x;
}

/* ---- Compressor (LE_FX_COMPRESSOR) ----
 *
 * Feed-forward, after Giannoulis, Massberg and Reiss ("Digital dynamic range
 * compressor design", JAES 2012), as the Looper X measured: a peak envelope
 * of the louder channel, a branching one-pole on |x| in the linear domain
 * (attack while |x| is above it, release while below), whose level in dB
 * feeds a quadratic soft knee LE_COMP_KNEE_DB wide; then the make-up. Both
 * channels take the same gain. Fitted to Ed's Rack's ladders and bursts, the
 * envelope's attack time constant is the attack setting and its release
 * time constant LE_COMP_REL_SHARE of the release setting. The whole passes
 * match to 0.25 dB RMS: every ladder step within 0.4 dB (a steady sine reads
 * about 0.3 dB higher on this envelope than on the Looper X's), the times to
 * half of each step change within about half, slower on long attacks and
 * faster on the shortest release. */
#define LE_COMP_KNEE_DB 15.0f
#define LE_COMP_REL_SHARE 0.47

typedef struct le_fx_comp {
  le_fx_dyn_head h;
  float last[LE_COMP_PARAMS_N];
  le_fx_glide thr;   /* threshold, dB */
  le_fx_glide slope; /* 1 - 1 / ratio */
  le_fx_glide mk;    /* make-up, dB */
  float att;         /* envelope coefficients */
  float rel;
  float att_p;       /* the settings they were computed from */
  float rel_p;
  float env; /* the peak envelope, linear */
} le_fx_comp;

/* The quadratic soft knee: the gain reduction in dB at [over] dB above the
 * threshold, for slope 1 - 1 / ratio. */
static inline float le_comp_knee(float over, float slope) {
  const float w = LE_COMP_KNEE_DB;
  if (2.0f * over <= -w) return 0.0f;
  if (2.0f * over >= w) return slope * over;
  const float t = over + 0.5f * w;
  return slope * t * t * (0.5f / w);
}

static void fx_comp_update(void* ks, const float* p, int sr, int settle) {
  le_fx_comp* c = (le_fx_comp*)ks;
  const int f = le_fx_dyn_begin(&c->h, c->last, p, LE_COMP_PARAMS_N, sr, settle);
  if (!f) return;
  const le_fx_param_desc* d = LE_FX_COMPRESSOR_PARAMS;
  if ((f & LE_FX_DYN_NEW_RATE) || settle || p[2] != c->att_p ||
      p[3] != c->rel_p) {
    c->att_p = p[2];
    c->rel_p = p[3];
    c->att = le_one_pole(le_fx_desc_value(&d[2], p[2]) * 1e-3, sr);
    c->rel = le_one_pole(
        le_fx_desc_value(&d[3], p[3]) * 1e-3 * LE_COMP_REL_SHARE, sr);
  }
  const float k = settle ? 1.0f : c->h.k;
  int moving = le_fx_glide_step(&c->thr, (float)le_fx_desc_value(&d[0], p[0]), k);
  moving |= le_fx_glide_step(
      &c->slope, (float)(1.0 - 1.0 / le_fx_desc_value(&d[1], p[1])), k);
  moving |= le_fx_glide_step(&c->mk, (float)le_fx_desc_value(&d[4], p[4]), k);
  c->h.moving = moving;
}

static void fx_comp_kprocess(void* ks, float* l, float* r) {
  le_fx_comp* c = (le_fx_comp*)ks;
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  const float thr = le_fx_glide_next(&c->thr);
  const float slope = le_fx_glide_next(&c->slope);
  const float mk = le_fx_glide_next(&c->mk);
  const float peak = fmaxf(fabsf(x0), fabsf(x1));
  float env = peak + (peak > c->env ? c->att : c->rel) * (c->env - peak);
  if (env < 1e-9f) env = 0.0f; /* settled: no denormal tail */
  c->env = env;
  const float gr =
      env > 0.0f ? le_comp_knee(le_db_of(env) - thr, slope) : 0.0f;
  const float g = le_gain_of_db(mk - gr);
  *l = x0 * g;
  *r = x1 * g;
}

/* Exposed for the native tests: the compressor's static curve, the gain
 * reduction in dB an envelope level [in_db] gives at settings [p]. */
float le_comp_static_gr_for_test(const float* p, float in_db) {
  const le_fx_param_desc* d = LE_FX_COMPRESSOR_PARAMS;
  return le_comp_knee(in_db - (float)le_fx_desc_value(&d[0], p[0]),
                      (float)(1.0 - 1.0 / le_fx_desc_value(&d[1], p[1])));
}

/* ---- Transient (LE_FX_TRANSIENT) ----
 *
 * A differential-envelope shaper, fitted to the Drum Rack's (#891): the
 * louder channel's peak envelope (instant rise, a LE_TR_PEAK_REL_S fall) and
 * two followers of it.
 * - The attack follower climbs to the peak envelope over
 *   LE_TR_ATK_MIN_S * LE_TR_ATK_SPAN^length and falls with it at once. While
 *   a sound starts, the peak envelope leads it by the share
 *   ra = (env - follower) / env, and the attack gain is 1 + a * LE_TR_ATK_K
 *   * ra, its reciprocal for a cut (a from -1 at 0 % to +1 at 100 %).
 * - The sustain follower climbs over LE_TR_SUS_RISE_S and falls over
 *   LE_TR_SUS_FALL_S, so after a sound starts to decay it sits above the
 *   peak envelope by the share rs = 1 - env / follower. The sustain gain
 *   rises toward LE_TR_SUS_K * rs over LE_TR_SUS_LIFT_S and drops back at
 *   once, and is applied as 1 + s * gain, or its reciprocal for a cut.
 * A held tone leads neither follower and keeps its level, up to the peak
 * envelope's ripple on a low note: at 100 % the attack gain moves by up to
 * 1.7 dB within each cycle at 40 Hz, 0.9 dB at 80 Hz and 0.5 dB at 160 Hz
 * (the captures held only a 1 kHz tone). Gains in the
 * linear domain saturate, as the Looper X's do: at 100 % an onset rises by
 * at most 1 + LE_TR_ATK_K (+15.2 dB) whatever its size, and after a 30 dB
 * drop the sustain lift peaks near +19 dB about 290 ms in (measured:
 * +18.3 dB at 286 ms). LE_TR_FLOOR keeps a decay into silence from reading
 * as an endless drop. Against the 16 measured passes the crest gains match
 * to 0.4 dB RMS or better on the onsets and under 1 dB on the decays. */
#define LE_TR_PEAK_REL_S 0.090
#define LE_TR_ATK_MIN_S 0.00312 /* the attack follower at 0 % length */
#define LE_TR_ATK_SPAN 7.12     /* ... and this many times that at 100 % */
#define LE_TR_ATK_K 4.72f
#define LE_TR_SUS_RISE_S 0.095
#define LE_TR_SUS_FALL_S 0.080
#define LE_TR_SUS_LIFT_S 0.038
#define LE_TR_SUS_K 13.4f
#define LE_TR_FLOOR 1e-5f

typedef struct le_fx_transient {
  le_fx_dyn_head h;
  float last[LE_TR_PARAMS_N];
  le_fx_glide atk; /* attack amount, -1..1 */
  le_fx_glide sus; /* sustain amount, -1..1 */
  float peak_rel;  /* coefficients */
  float rise;
  float sus_rise;
  float sus_fall;
  float lift;
  float peak; /* the peak envelope */
  float riser; /* the attack follower */
  float faller; /* the sustain follower */
  float sus_gain; /* the sustain lift before its amount, linear */
} le_fx_transient;

static void fx_transient_update(void* ks, const float* p, int sr, int settle) {
  le_fx_transient* t = (le_fx_transient*)ks;
  const int f = le_fx_dyn_begin(&t->h, t->last, p, LE_TR_PARAMS_N, sr, settle);
  if (!f) return;
  const int changed = (f & LE_FX_DYN_CHANGED) != 0;
  if (changed) {
    const float len = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
    t->peak_rel = le_one_pole(LE_TR_PEAK_REL_S, sr);
    t->rise = le_one_pole(LE_TR_ATK_MIN_S * pow(LE_TR_ATK_SPAN, len), sr);
    t->sus_rise = le_one_pole(LE_TR_SUS_RISE_S, sr);
    t->sus_fall = le_one_pole(LE_TR_SUS_FALL_S, sr);
    t->lift = le_one_pole(LE_TR_SUS_LIFT_S, sr);
  }
  const float k = settle ? 1.0f : t->h.k;
  const float a = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float s = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  int moving = le_fx_glide_step(&t->atk, 2.0f * a - 1.0f, k);
  moving |= le_fx_glide_step(&t->sus, 2.0f * s - 1.0f, k);
  t->h.moving = moving;
}

static void fx_transient_kprocess(void* ks, float* l, float* r) {
  le_fx_transient* t = (le_fx_transient*)ks;
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  const float atk = le_fx_glide_next(&t->atk);
  const float sus = le_fx_glide_next(&t->sus);
  const float x = fmaxf(fabsf(x0), fabsf(x1));
  const float pk = x > t->peak ? x : x + t->peak_rel * (t->peak - x);
  t->peak = pk;
  t->riser = pk < t->riser ? pk : pk + t->rise * (t->riser - pk);
  t->faller = pk + (pk > t->faller ? t->sus_rise : t->sus_fall) *
                       (t->faller - pk);
  float rs = 1.0f - (pk + LE_TR_FLOOR) / (t->faller + LE_TR_FLOOR);
  if (rs < 0.0f) rs = 0.0f;
  const float want = LE_TR_SUS_K * rs;
  t->sus_gain = want < t->sus_gain ? want
                                   : want + t->lift * (t->sus_gain - want);
  if (t->sus_gain < 1e-9f) t->sus_gain = 0.0f; /* no denormal tail */
  if (atk == 0.0f && sus == 0.0f) {
    *l = x0;
    *r = x1;
    return; /* neutral: the identity */
  }
  const float ra = (pk - t->riser) / (pk + LE_TR_FLOOR);
  const float ga = 1.0f + fabsf(atk) * LE_TR_ATK_K * ra;
  const float gs = 1.0f + fabsf(sus) * t->sus_gain;
  const float g = (atk >= 0.0f ? ga : 1.0f / ga) * (sus >= 0.0f ? gs : 1.0f / gs);
  *l = x0 * g;
  *r = x1 * g;
}

/* ---- HP/Gate (LE_FX_HP_GATE) ----
 *
 * As the Vocal and Vocal Tuner racks' measured (#891). A 12 dB/octave
 * high-pass: the high-pass output of a Chamberlin state-variable filter at
 * Q 2/3 (F = 2 sin(pi fc / fs)), which matches the captures to 0.02 dB RMS,
 * their slight lift above the corner included. It is off at the bottom of
 * its range, and fades in and out over the smoothing time. Then a gate keyed on the
 * filtered signal: it opens on the first sample whose level (the louder
 * channel's |x|) reaches the threshold, and closes LE_GATE_HOLD_S after the
 * level last reached LE_GATE_HYST_DB under it. Opening and closing ramp the
 * gain; the close is the Looper X's 2.7 dB/ms fall. */
#define LE_HPG_DAMP 1.5f /* 1 / Q */
#define LE_GATE_HYST_DB 6.0
#define LE_GATE_HOLD_S 0.250
#define LE_GATE_OPEN_S 0.00005
#define LE_GATE_CLOSE_S 0.0032

typedef struct le_fx_hp_gate {
  le_fx_dyn_head h;
  float last[LE_HPG_PARAMS_N];
  float lhz; /* the corner now, log2 Hz */
  float tgt_lhz;
  float f;      /* the filter's frequency coefficient */
  float lp[2];  /* its low-pass and band-pass states, per channel */
  float bp[2];
  float open_at;     /* gate thresholds, linear */
  float close_at;
  float open_c;      /* gate coefficients */
  float close_c;
  int32_t hold_n;
  float gain; /* gate gain now */
  int32_t hold;
  int32_t open;
  float wet;     /* the high-pass's share of the output: 1 on, 0 off */
  float tgt_wet;
} le_fx_hp_gate;

static void le_hpg_design(le_fx_hp_gate* q, int sr) {
  q->f = (float)(2.0 * sin(3.14159265358979323846 * exp2((double)q->lhz) /
                           (double)(sr > 0 ? sr : 48000)));
}

static void fx_hp_gate_update(void* ks, const float* p, int sr, int settle) {
  le_fx_hp_gate* q = (le_fx_hp_gate*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_HPG_PARAMS_N, sr, settle);
  if (!f) return;
  const int new_rate = (f & LE_FX_DYN_NEW_RATE) != 0;
  const le_fx_param_desc* d = LE_FX_HP_GATE_PARAMS;
  if (new_rate) {
    q->open_c = le_one_pole(LE_GATE_OPEN_S, sr);
    q->close_c = le_one_pole(LE_GATE_CLOSE_S, sr);
    q->hold_n = (int32_t)(LE_GATE_HOLD_S * (double)(sr > 0 ? sr : 48000));
  }
  if (f & LE_FX_DYN_CHANGED) {
    q->tgt_lhz = (float)log2(le_fx_desc_value(&d[0], p[0]));
    q->tgt_wet = p[0] > 0.0f ? 1.0f : 0.0f;
    const double thr = le_fx_desc_value(&d[1], p[1]);
    q->open_at = le_gain_of_db((float)thr);
    q->close_at = le_gain_of_db((float)(thr - LE_GATE_HYST_DB));
  }
  /* The corner glides in octaves; the filter is redesigned while it moves
   * (a state-variable filter takes a coefficient change without a click). */
  if (settle) {
    /* A fresh gate starts open, so it never cuts into the first sound it
     * is handed; with nothing to hold it open it closes after the hold. */
    q->open = 1;
    q->gain = 1.0f;
    q->hold = q->hold_n;
  }
  if (q->lhz != q->tgt_lhz || new_rate) {
    le_fx_step_toward(&q->lhz, q->tgt_lhz, settle ? 1.0f : q->h.k);
    le_hpg_design(q, sr);
  }
  le_fx_step_toward(&q->wet, q->tgt_wet, settle ? 1.0f : q->h.k);
  if (q->wet == 0.0f) { /* off: the filter starts clean when it comes back */
    q->lp[0] = q->lp[1] = 0.0f;
    q->bp[0] = q->bp[1] = 0.0f;
  }
  q->h.moving = q->lhz != q->tgt_lhz || q->wet != q->tgt_wet;
}

static void fx_hp_gate_kprocess(void* ks, float* l, float* r) {
  le_fx_hp_gate* q = (le_fx_hp_gate*)ks;
  float y[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  if (q->wet > 0.0f) {
    for (int c = 0; c < 2; ++c) {
      const float hp = y[c] - q->lp[c] - LE_HPG_DAMP * q->bp[c];
      q->bp[c] += q->f * hp;
      q->lp[c] += q->f * q->bp[c];
      y[c] = q->wet >= 1.0f ? hp : y[c] + q->wet * (hp - y[c]);
    }
  }
  const float x = fmaxf(fabsf(y[0]), fabsf(y[1]));
  /* Open at the threshold; the hold restarts whenever the level is back
   * within the hysteresis, so the gate closes only once it has stayed under
   * close_at for the whole hold. */
  if (x >= q->open_at) {
    q->open = 1;
    q->hold = q->hold_n;
  } else if (x >= q->close_at) {
    q->hold = q->hold_n;
  } else if (q->hold > 0) {
    q->hold--;
  } else {
    q->open = 0;
  }
  const float tgt = q->open ? 1.0f : 0.0f;
  float g = tgt + (q->open ? q->open_c : q->close_c) * (q->gain - tgt);
  if (g < 1e-6f) g = 0.0f;
  if (g > 1.0f - 1e-7f) g = 1.0f;
  q->gain = g;
  *l = y[0] * g;
  *r = y[1] * g;
}

/* ---- Modulation and filter: Doubler, Chorus, Wah (#887 part 6) ----
 *
 * The Looper X shows every control of these three as 0 to 100 %. What the
 * percentages do is the choice here, except where the Phase 0 captures of
 * the Guitar Rack's chorus (#891, sessions s3/4 and s3/5) measured it; each
 * constant says which. */

static const le_fx_param_desc LE_FX_DOUBLER_PARAMS[] = {
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"separation", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, LE_FX_PARAM_TAPER_UNVERIFIED},
};
static const le_fx_param_desc LE_FX_CHORUS_PARAMS[] = {
    {"rate", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.45f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.21f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
};
static const le_fx_param_desc LE_FX_WAH_PARAMS[] = {
    {"pedal", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.619f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_DBL_PARAMS_N 2
#define LE_CHO_PARAMS_N 3
#define LE_WAH_PARAMS_N 1

/* A delay line inside a kind's block: [LE_*_RING] floats, a power of two,
 * written at [w] every sample and read back [delay] samples earlier by
 * linear interpolation. The whole samples are counted in integers, so the
 * read stays exact however long the counter has run. */
static inline float le_ring_read(const float* ring, uint32_t mask, uint32_t w,
                                 float delay) {
  const float whole = floorf(delay);
  const float fr = delay - whole;
  const uint32_t near = (w - (uint32_t)whole) & mask;
  const float a = ring[near];
  const float b = ring[(near - 1u) & mask];
  return a + fr * (b - a);
}

/* A triangle wave of phase [ph] in 0..1, from -1 through +1 and back. */
static inline float le_tri(float ph) {
  return ph < 0.5f ? 4.0f * ph - 1.0f : 3.0f - 4.0f * ph;
}

/* Advances an LFO phase in 0..1 by [inc]. The phase is kept in double: a
 * slow LFO's step at a high rate (1.5e-6 a sample) is too fine for a float
 * near 1. */
static inline double le_lfo_step(double ph, double inc) {
  ph += inc;
  return ph >= 1.0 ? ph - 1.0 : ph;
}

/* ---- Doubler (LE_FX_DOUBLER) ----
 *
 * Automatic double tracking: two delayed copies of the input (its mono sum),
 * each drifting slowly in time so its pitch wanders by a few cents, panned
 * apart by the separation and added to the dry signal at the mix. At 0 %
 * separation both copies sit in the centre; at 100 % one is hard left and
 * the other hard right (equal-power pan). The dry signal passes untouched.
 * The voice times and drifts are chosen (#891). */
#define LE_DBL_RING 4096u /* holds 21 ms at 192 kHz */
#define LE_DBL_A_MS 11.0
#define LE_DBL_B_MS 17.0
#define LE_DBL_DRIFT_MS 0.6 /* each voice drifts +-0.6 ms ... */
#define LE_DBL_A_HZ 0.29    /* ... at these rates (+-1.2 and +-1.5 cents) */
#define LE_DBL_B_HZ 0.37
#define LE_DBL_VOICE 0.7071f /* each copy at -3 dB of the dry signal */

typedef struct le_fx_doubler {
  le_fx_dyn_head h;
  float last[LE_DBL_PARAMS_N];
  le_fx_glide mix;
  le_fx_glide sep_a[2]; /* voice A's left and right gains */
  le_fx_glide sep_b[2];
  float base_a, base_b, drift; /* in samples */
  double inc_a, inc_b;         /* LFO phase per sample */
  double ph_a, ph_b;
  uint32_t w;
  float ring[LE_DBL_RING];
} le_fx_doubler;

static void fx_doubler_update(void* ks, const float* p, int sr, int settle) {
  le_fx_doubler* d = (le_fx_doubler*)ks;
  const int f = le_fx_dyn_begin(&d->h, d->last, p, LE_DBL_PARAMS_N, sr, settle);
  if (!f) return;
  if (f & LE_FX_DYN_NEW_RATE) {
    const double rate = (double)(sr > 0 ? sr : 48000);
    d->base_a = (float)(LE_DBL_A_MS * 1e-3 * rate);
    d->base_b = (float)(LE_DBL_B_MS * 1e-3 * rate);
    d->drift = (float)(LE_DBL_DRIFT_MS * 1e-3 * rate);
    /* Past 192 kHz the voices would outgrow the ring: hold them inside. */
    const float room = (float)(LE_DBL_RING - 2u) - d->drift;
    if (d->base_a > room) d->base_a = room;
    if (d->base_b > room) d->base_b = room;
    d->inc_a = LE_DBL_A_HZ / rate;
    d->inc_b = LE_DBL_B_HZ / rate;
  }
  if (settle) d->ph_b = 0.5; /* a fresh pair starts half a cycle apart */
  const float k = settle ? 1.0f : d->h.k;
  const float m = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float s = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  /* Equal-power pan: voice A at -s, voice B at +s. */
  const float th = 0.78539816f * s; /* 0 centre .. pi/4 hard */
  const float c0 = 0.78539816f;
  int moving = le_fx_glide_step(&d->mix, m * LE_DBL_VOICE, k);
  moving |= le_fx_glide_step(&d->sep_a[0], cosf(c0 - th), k);
  moving |= le_fx_glide_step(&d->sep_a[1], sinf(c0 - th), k);
  moving |= le_fx_glide_step(&d->sep_b[0], cosf(c0 + th), k);
  moving |= le_fx_glide_step(&d->sep_b[1], sinf(c0 + th), k);
  d->h.moving = moving;
}

static void fx_doubler_kprocess(void* ks, float* l, float* r) {
  le_fx_doubler* d = (le_fx_doubler*)ks;
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  const float mix = le_fx_glide_next(&d->mix);
  const float al = le_fx_glide_next(&d->sep_a[0]);
  const float ar = le_fx_glide_next(&d->sep_a[1]);
  const float bl = le_fx_glide_next(&d->sep_b[0]);
  const float br = le_fx_glide_next(&d->sep_b[1]);
  d->ring[d->w & (LE_DBL_RING - 1u)] = 0.5f * (x0 + x1);
  d->ph_a = le_lfo_step(d->ph_a, d->inc_a);
  d->ph_b = le_lfo_step(d->ph_b, d->inc_b);
  const float va = le_ring_read(d->ring, LE_DBL_RING - 1u, d->w,
                                d->base_a + d->drift * le_tri((float)d->ph_a));
  const float vb = le_ring_read(d->ring, LE_DBL_RING - 1u, d->w,
                                d->base_b + d->drift * le_tri((float)d->ph_b));
  d->w++;
  *l = x0 + mix * (al * va + bl * vb);
  *r = x1 + mix * (ar * va + br * vb);
}

/* ---- Chorus (LE_FX_CHORUS) ----
 *
 * One modulated voice per channel, mixed with the dry signal. Measured on
 * the Guitar Rack's chorus, the Phase 0 captures (#891, s3/4 and s3/5):
 * - the voice's delay is a triangle about 1.875 ms, swinging +-0.0704 ms at
 *   12 % depth, taken here as proportional, 0.587 ms at 100 %;
 * - the rate was 1.313 Hz at 32.6 % and 2.638 Hz at 79.7 %, taken here as
 *   the line through them, 0.396 Hz at 0 % to 3.209 Hz at 100 %;
 * - the voice is low-passed by about two 2nd-order sections at 6.7 kHz,
 *   Q 0.65 (fitted within 0.1 dB to 16 kHz);
 * - at 33.2 % mix the dry gain was 0.904 and the voice's 0.276: dry
 *   1 - 0.29 mix, voice 0.83 mix.
 * With these, a model of this kernel fitted only for the LFO's phase nulls
 * both captures to -40 dB over 7 s of plucks and chords. Ed's Rack's Chorus
 * is taken to be the same module (#891). Both channels share the LFO. */
#define LE_CHO_RING 1024u /* holds 5.3 ms at 192 kHz */
#define LE_CHO_CENTRE_MS 1.875
#define LE_CHO_DEPTH_MS 0.587
#define LE_CHO_RATE_MIN_HZ 0.3959
#define LE_CHO_RATE_SPAN_HZ 2.8132
#define LE_CHO_LP_HZ 6700.0
#define LE_CHO_LP_Q 0.65
#define LE_CHO_DRY_DROP 0.29f
#define LE_CHO_VOICE 0.83f

typedef struct le_fx_chorus {
  le_fx_dyn_head h;
  float last[LE_CHO_PARAMS_N];
  le_fx_glide rate;  /* LFO rate, Hz */
  le_fx_glide swing; /* the delay's swing, samples */
  le_fx_glide dry;
  le_fx_glide wet;
  float centre; /* samples */
  float max_swing; /* what the ring holds past the centre */
  float inv_sr;
  double ph;
  float lp[5];       /* the voice low-pass, a0-normalized b0 b1 b2 a1 a2 */
  float z[2][2][2];  /* [section][channel][state] */
  uint32_t w;
  float ring[2][LE_CHO_RING];
} le_fx_chorus;

static void fx_chorus_update(void* ks, const float* p, int sr, int settle) {
  le_fx_chorus* c = (le_fx_chorus*)ks;
  const int f = le_fx_dyn_begin(&c->h, c->last, p, LE_CHO_PARAMS_N, sr, settle);
  if (!f) return;
  const double rate = (double)(sr > 0 ? sr : 48000);
  if (f & LE_FX_DYN_NEW_RATE) {
    c->centre = (float)(LE_CHO_CENTRE_MS * 1e-3 * rate);
    c->max_swing = (float)(LE_CHO_RING - 2u) - c->centre;
    c->inv_sr = (float)(1.0 / rate);
    /* RBJ low-pass, the same design le_eq_design uses for a cut. */
    const double w0 = 2.0 * 3.14159265358979323846 *
                      (LE_CHO_LP_HZ < 0.45 * rate ? LE_CHO_LP_HZ : 0.45 * rate) /
                      rate;
    const double cw = cos(w0);
    const double alpha = sin(w0) / (2.0 * LE_CHO_LP_Q);
    const double a0 = 1.0 + alpha;
    c->lp[0] = (float)((1.0 - cw) / 2.0 / a0);
    c->lp[1] = (float)((1.0 - cw) / a0);
    c->lp[2] = c->lp[0];
    c->lp[3] = (float)(-2.0 * cw / a0);
    c->lp[4] = (float)((1.0 - alpha) / a0);
  }
  const float k = settle ? 1.0f : c->h.k;
  const float v[3] = {
      p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0],
      p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1],
      p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2],
  };
  int moving = le_fx_glide_step(
      &c->rate, (float)(LE_CHO_RATE_MIN_HZ + LE_CHO_RATE_SPAN_HZ * v[0]), k);
  float swing = (float)(LE_CHO_DEPTH_MS * 1e-3 * rate * v[1]);
  if (swing > c->max_swing) swing = c->max_swing;
  moving |= le_fx_glide_step(&c->swing, swing, k);
  moving |= le_fx_glide_step(&c->dry, 1.0f - LE_CHO_DRY_DROP * v[2], k);
  moving |= le_fx_glide_step(&c->wet, LE_CHO_VOICE * v[2], k);
  c->h.moving = moving;
}

static void fx_chorus_kprocess(void* ks, float* l, float* r) {
  le_fx_chorus* c = (le_fx_chorus*)ks;
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  const double inc = (double)le_fx_glide_next(&c->rate) * (double)c->inv_sr;
  const float swing = le_fx_glide_next(&c->swing);
  const float dry = le_fx_glide_next(&c->dry);
  const float wet = le_fx_glide_next(&c->wet);
  c->ph = le_lfo_step(c->ph, inc);
  const float delay = c->centre + swing * le_tri((float)c->ph);
  const uint32_t at = c->w & (LE_CHO_RING - 1u);
  float y[2];
  for (int ch = 0; ch < 2; ++ch) {
    c->ring[ch][at] = x[ch];
    float v = le_ring_read(c->ring[ch], LE_CHO_RING - 1u, c->w, delay);
    for (int s = 0; s < 2; ++s) v = le_biquad_tick(c->lp, c->z[s][ch], v);
    y[ch] = dry * x[ch] + wet * v;
  }
  c->w++;
  *l = y[0];
  *r = y[1];
}

/* ---- Wah (LE_FX_WAH) ----
 *
 * A resonant band-pass swept by the pedal, as a state-variable filter: from
 * LE_WAH_LO_HZ heel down to LE_WAH_HI_HZ toe up (log), Q LE_WAH_Q, its peak
 * LE_WAH_PEAK (+6 dB) over the input. The pedal glides in octaves (a pedal moved
 * by an expression input never zips). The sweep, Q and level are chosen
 * (#891). */
#define LE_WAH_LO_HZ 350.0
#define LE_WAH_HI_HZ 2500.0
#define LE_WAH_Q 4.0
#define LE_WAH_PEAK 1.9952623149688795 /* +6 dB */

typedef struct le_fx_wah {
  le_fx_dyn_head h;
  float last[LE_WAH_PARAMS_N];
  float lhz; /* the centre now, log2 Hz */
  float tgt_lhz;
  float a1, a2, a3; /* SVF coefficients */
  float gain;       /* band output to peak level */
  float ic1[2];
  float ic2[2];
} le_fx_wah;

static void fx_wah_update(void* ks, const float* p, int sr, int settle) {
  le_fx_wah* q = (le_fx_wah*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_WAH_PARAMS_N, sr, settle);
  if (!f) return;
  if (f & LE_FX_DYN_CHANGED) {
    const float v = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
    q->tgt_lhz = (float)log2(LE_WAH_LO_HZ * pow(LE_WAH_HI_HZ / LE_WAH_LO_HZ, v));
  }
  if (q->lhz != q->tgt_lhz || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&q->lhz, q->tgt_lhz, settle ? 1.0f : q->h.k);
    const double kq = 1.0 / LE_WAH_Q;
    le_svf_coefs(le_prewarp(exp2((double)q->lhz), sr), kq, &q->a1, &q->a2,
                 &q->a3);
    /* The band output peaks at 1 / k; scale it to the chosen peak. */
    q->gain = (float)(kq * LE_WAH_PEAK);
  }
  q->h.moving = q->lhz != q->tgt_lhz;
}

static void fx_wah_kprocess(void* ks, float* l, float* r) {
  le_fx_wah* q = (le_fx_wah*)ks;
  float y[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float v1;
    float v2;
    le_svf_tick(y[ch], q->a1, q->a2, q->a3, &q->ic1[ch], &q->ic2[ch], &v1, &v2);
    y[ch] = q->gain * v1;
  }
  *l = y[0];
  *r = y[1];
}

/* ---- Overdrive (LE_FX_OVERDRIVE, #887 part 7) ----
 *
 * Fit to the Phase 0 captures of the Guitar Rack's OvDrive (#891, session
 * fxlive: Drive 10.7, 50 and 90 % at Tone 50 %, 1 kHz ladders from -48 to
 * 0 dBFS and a -12 dBFS sweep). What the captures show:
 * - the output is a clean part plus a clipped part, as in a diode-feedback
 *   overdrive: above -24 dBFS in the three drives give the same output
 *   (the clipped part has saturated and only the clean part still grows),
 *   while below it the drive sets the gain (+13.5, +17.6 and +20.2 dB at
 *   -48 dBFS); the third, fifth and seventh harmonics of the clipped part
 *   stay at the same level from -24 to -12 dBFS;
 * - a second, softer stage compresses the top, slightly asymmetrically
 *   (the second harmonic reaches -20 dBc at 0 dBFS);
 * - a tone filter after both: a +1.5 dB rise about 680 Hz and a roll-off
 *   from 1.6 kHz (fitted within 0.24 dB rms from 30 Hz to 18 kHz);
 * - the polarity is inverted.
 * The model, u = K x + c tanh(G x / c), then (tanh(a (u + b)) -
 * tanh(a b)) / a, then the tone filter, matches the fundamental within
 * 0.9 dB and the third harmonic within 3 dB at every level and drive
 * (scratch fit, not committed). The drive's clipped-part gain follows
 * G = 3.98 e^(1.812 v), within 2 % of the three fitted gains. Only Tone
 * 50 % was captured: the tone setting moves the 1.6 kHz corner two octaves
 * either way, a choice (#891). */
static const le_fx_param_desc LE_FX_OVERDRIVE_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.09f,
     0},
    {"tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_OD_PARAMS_N 2
#define LE_OD_K 0.5166f      /* the clean part */
#define LE_OD_C 0.0367f      /* the clipped part's ceiling */
#define LE_OD_A 2.8826f      /* the second stage */
#define LE_OD_B 0.0772f      /* ... and its asymmetry */
#define LE_OD_OFF 0.21893453f /* tanh(LE_OD_A LE_OD_B): its rest point */
#define LE_OD_P 0.9752f      /* output, with the tone filter at 1 kHz */
#define LE_OD_G0 3.9823      /* G at 0 % drive */
#define LE_OD_GK 1.8122      /* ln G per unit of drive */
#define LE_OD_HP_HZ 17.32
#define LE_OD_PEAK_HZ 682.2
#define LE_OD_PEAK_DB 1.552
#define LE_OD_PEAK_Q 0.566
#define LE_OD_TONE_HZ 1630.2 /* the tone corner at 50 % */
#define LE_OD_LP2_HZ 11110.0
#define LE_OD_TONE_1K 0.98544 /* |tone filter| at 1 kHz, 50 %: the fit's unit */

/* A one-pole filter in trapezoidal form: g = tan(pi fc / sr). */
static inline float le_onepole_lp(float* s, float g1, float x) {
  const float v = (x - *s) * g1; /* g1 = g / (1 + g) */
  const float y = v + *s;
  *s = y + v;
  return y;
}

static float le_onepole_g1(double hz, int sr) {
  const double g = le_prewarp(hz, sr);
  return (float)(g / (1.0 + g));
}

typedef struct le_fx_overdrive {
  le_fx_dyn_head h;
  float last[LE_OD_PARAMS_N];
  le_fx_glide g;    /* the clipped part's gain over its ceiling, G / c */
  float tone_lhz;   /* the tone corner now, log2 Hz */
  float tone_tgt;
  float hp_g1, tone_g1, lp2_g1;
  float pk[5];      /* the 680 Hz rise, RBJ, a0-normalized */
  float s_hp[2], s_tone[2], s_lp2[2];
  float z_pk[2][2];
} le_fx_overdrive;

static void fx_overdrive_update(void* ks, const float* p, int sr, int settle) {
  le_fx_overdrive* o = (le_fx_overdrive*)ks;
  const int f = le_fx_dyn_begin(&o->h, o->last, p, LE_OD_PARAMS_N, sr, settle);
  if (!f) return;
  const double rate = (double)(sr > 0 ? sr : 48000);
  if (f & LE_FX_DYN_NEW_RATE) {
    o->hp_g1 = le_onepole_g1(LE_OD_HP_HZ, sr);
    o->lp2_g1 = le_onepole_g1(LE_OD_LP2_HZ, sr);
    double c[5];
    le_eq_design(LE_EQ_LOMID, LE_OD_PEAK_HZ, LE_OD_PEAK_DB, LE_OD_PEAK_Q,
                 (int)rate, c);
    for (int i = 0; i < 5; ++i) o->pk[i] = (float)c[i];
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    o->tone_tgt = (float)(log2(LE_OD_TONE_HZ) + 2.0 * (2.0 * t - 1.0));
  }
  const float k = settle ? 1.0f : o->h.k;
  int moving = le_fx_glide_step(
      &o->g, (float)(LE_OD_G0 * exp(LE_OD_GK * d) / LE_OD_C), k);
  if (o->tone_lhz != o->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&o->tone_lhz, o->tone_tgt, k);
    o->tone_g1 = le_onepole_g1(exp2((double)o->tone_lhz), sr);
  }
  moving |= o->tone_lhz != o->tone_tgt;
  o->h.moving = moving;
}

static void fx_overdrive_kprocess(void* ks, float* l, float* r) {
  le_fx_overdrive* o = (le_fx_overdrive*)ks;
  const float g = le_fx_glide_next(&o->g);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    const float x = io[ch];
    const float u = LE_OD_K * x + LE_OD_C * tanhf(g * x);
    float v = (tanhf(LE_OD_A * (u + LE_OD_B)) - LE_OD_OFF) * (1.0f / LE_OD_A);
    /* The tone filter: the 17 Hz high-pass, the 680 Hz rise, the tone
     * corner and the 11 kHz pole. */
    v = v - le_onepole_lp(&o->s_hp[ch], o->hp_g1, v);
    v = le_biquad_tick(o->pk, o->z_pk[ch], v);
    v = le_onepole_lp(&o->s_tone[ch], o->tone_g1, v);
    v = le_onepole_lp(&o->s_lp2[ch], o->lp2_g1, v);
    io[ch] = -(LE_OD_P / (float)LE_OD_TONE_1K) * v; /* inverted, as captured */
  }
  *l = io[0];
  *r = io[1];
}

/* ---- Distortion (LE_FX_DISTORTION, #887 part 7) ----
 *
 * The Looper X's amp simulator, which the Studio Rack labels Dist (the
 * chain scan, #891), at its other controls' defaults: Bass, Treble and
 * Modern 50 % and the 4x12" cabinet. Fit to the Phase 0 captures (#891):
 * the amp at Drive 50 % with the D.I. cabinet (s4/17) for the curve, with
 * the 4x12" (s4/16) for the cabinet, and at Drive 10, 22.7 and 80 % with
 * the 4x12" (s3/3, s3/1, s3/2) for the drive's law.
 * - The curve: an early asymmetry (the second harmonic is -18 dBc at
 *   -24 dBFS while the third is -38), then a knee into asymmetric ceilings.
 *   Fitted, it gives the fundamental within 2 dB at every level and drive
 *   (a closer fit needs the multi-stage amp the Amp+Cab part will build).
 * - The drive: the gain into the curve follows ln G = -1.089 + 2.314 v -
 *   3.344 v^2 + 6.512 v^3, through the four fitted gains (rising
 *   throughout); the output level falls with drive, 1.451 - 0.482 v.
 * - The cabinet and the amp's voicing after the curve: nine sections fitted
 *   within 0.8 dB rms from 45 Hz to 18 kHz.
 * The Lo-Fi Rack's Dist Tone has no capture: it tilts a 2 kHz shelf
 * +-6 dB, flat at 50 % (#891). */
/* The drive's law is the Studio Rack's Dist's; the Lo-Fi Rack's Dist is
 * taken to be the same module, so the drive carries the flag too. */
static const le_fx_param_desc LE_FX_DISTORTION_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.2f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_DIST_PARAMS_N 2
#define LE_DIST_ALPHA 3.4467f /* the early asymmetry */
#define LE_DIST_UP 0.20428f   /* the positive ceiling */
#define LE_DIST_DOWN 0.045506f
#define LE_DIST_KNEE 3.5319f
#define LE_DIST_SECTIONS 9
#define LE_DIST_TONE_HZ 2000.0
#define LE_DIST_TONE_DB 6.0

/* The cabinet and voicing: band kind (le_eq_design's), Hz, dB, Q. */
static const struct {
  int kind;
  double hz, db, q;
} LE_DIST_CAB[LE_DIST_SECTIONS] = {
    {LE_EQ_LOWCUT, 51.72, 0.0, 1.9413},  {LE_EQ_HIGHCUT, 5935.5, 0.0, 0.5584},
    {LE_EQ_HIGHCUT, 6353.9, 0.0, 0.8313}, {LE_EQ_LOMID, 314.57, 9.102, 0.2376},
    {LE_EQ_LOMID, 835.28, -3.605, 3.7532}, {LE_EQ_LOMID, 1113.0, 1.233, 7.0801},
    {LE_EQ_LOMID, 720.80, -1.553, 5.1893}, {LE_EQ_LOMID, 2660.4, 7.255, 0.9623},
    {LE_EQ_LOMID, 6429.4, 12.876, 2.2105},
};

typedef struct le_fx_distortion {
  le_fx_dyn_head h;
  float last[LE_DIST_PARAMS_N];
  le_fx_glide g;     /* the gain into the curve */
  le_fx_glide level; /* the output level, over the cabinet's 1 kHz gain */
  float norm;        /* 1 / |cabinet at 1 kHz| */
  float tone_db;     /* the shelf now, gliding to tone_tgt */
  float tone_tgt;
  int32_t shelf_on;
  float cab[LE_DIST_SECTIONS][5];
  float shelf[5];
  float z[LE_DIST_SECTIONS + 1][2][2]; /* [section][channel][state] */
} le_fx_distortion;

/* |H(e^jw)| of one a0-normalized biquad. */
static double le_biquad_mag(const double c[5], double w) {
  const double cr = cos(w), ci = -sin(w), c2r = cos(2.0 * w), c2i = -sin(2.0 * w);
  const double nr = c[0] + c[1] * cr + c[2] * c2r;
  const double ni = c[1] * ci + c[2] * c2i;
  const double dr = 1.0 + c[3] * cr + c[4] * c2r;
  const double di = c[3] * ci + c[4] * c2i;
  return sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

static void fx_distortion_update(void* ks, const float* p, int sr, int settle) {
  le_fx_distortion* q = (le_fx_distortion*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_DIST_PARAMS_N, sr, settle);
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    double mag = 1.0;
    const double w1k = 2.0 * 3.14159265358979323846 * 1000.0 / rate;
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      double c[5];
      le_eq_design(LE_DIST_CAB[s].kind, LE_DIST_CAB[s].hz, LE_DIST_CAB[s].db,
                   LE_DIST_CAB[s].q, rate, c);
      for (int i = 0; i < 5; ++i) q->cab[s][i] = (float)c[i];
      mag *= le_biquad_mag(c, w1k);
    }
    q->norm = (float)(1.0 / mag);
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  const float k = settle ? 1.0f : q->h.k;
  int moving = le_fx_glide_step(
      &q->g,
      (float)exp(-1.0887 + d * (2.3136 + d * (-3.3444 + d * 6.5117))), k);
  moving |= le_fx_glide_step(&q->level, (1.4512f - 0.4823f * d) * q->norm, k);
  if (f & LE_FX_DYN_CHANGED) {
    q->tone_tgt = (float)(LE_DIST_TONE_DB * (2.0 * t - 1.0));
  }
  if (q->tone_db != q->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    /* The shelf glides in dB, redesigned while it moves. */
    le_fx_step_toward(&q->tone_db, q->tone_tgt, k);
    const int on = q->tone_db != 0.0f;
    if (!on && q->shelf_on) {
      memset(q->z[LE_DIST_SECTIONS], 0, sizeof(q->z[LE_DIST_SECTIONS]));
    }
    q->shelf_on = on;
    if (on) {
      double c[5];
      le_eq_design(LE_EQ_HIGH, LE_DIST_TONE_HZ, q->tone_db, 0.70710678, rate, c);
      for (int i = 0; i < 5; ++i) q->shelf[i] = (float)c[i];
    }
  }
  moving |= q->tone_db != q->tone_tgt;
  q->h.moving = moving;
}

static void fx_distortion_kprocess(void* ks, float* l, float* r) {
  le_fx_distortion* q = (le_fx_distortion*)ks;
  const float g = le_fx_glide_next(&q->g);
  const float level = le_fx_glide_next(&q->level);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    const float u = g * io[ch];
    const float au = LE_DIST_ALPHA * u;
    const float w = u + LE_DIST_ALPHA * u * u / (1.0f + au * au);
    const float c = w > 0.0f ? LE_DIST_UP : LE_DIST_DOWN;
    float v = w / powf(1.0f + powf(fabsf(w / c), LE_DIST_KNEE),
                       1.0f / LE_DIST_KNEE);
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      v = le_biquad_tick(q->cab[s], q->z[s][ch], v);
    }
    /* The tone shelf, skipped while flat (the Studio Rack's, and the
     * default); its memory clears so it starts clean when it comes back. */
    if (q->shelf_on) v = le_biquad_tick(q->shelf, q->z[LE_DIST_SECTIONS][ch], v);
    io[ch] = level * v;
  }
  *l = io[0];
  *r = io[1];
}

/* ---- Lo-fi: Vinyl, Degrade, LPF (#887 part 7) ----
 *
 * No Phase 0 capture covers these. The ranges and tapers are the Looper
 * X's (the derived tables); what each control does inside is chosen (#891),
 * so every control carries the flag but the LPF's cutoff, whose range and
 * taper are all it is. */

/* The seed a kind's fresh block was given (fx_kind_state): the owner's
 * hop-stagger seed and the slot, so two owners' noise differs and an
 * owner's is the same from every fresh block (the plan's per-owner
 * seeding, as the hop phase is). */
static uint32_t le_fx_kind_seed(const void* ks);

/* xorshift32: the next state, never 0 from a nonzero one. */
static inline uint32_t le_xorshift(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

/* A uniform sample in [-1, 1). */
static inline float le_noise(uint32_t* s) {
  return (float)(int32_t)le_xorshift(s) * (1.0f / 2147483648.0f);
}

/* ---- Vinyl (LE_FX_VINYL) ----
 *
 * A worn record: a 12 dB/octave high-pass at Freq (the Looper X's 50 to
 * 5000 Hz, thinning the low end), a fixed 7 kHz roll-off, a soft saturation
 * the drive pushes (gain 1 to 10), then surface noise mixed in: hiss and
 * crackle (clicks at up to 8 a second), both through a low-pass the noise
 * tone sets (500 Hz to 12 kHz). Each channel has its own noise. The noise
 * runs on whatever the loop does, so a vinyl with noise up never prints. */
static const le_fx_param_desc LE_FX_VINYL_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.4f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"frequency", LE_FX_UNIT_HZ, 0, 50.0f, 5000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.35f, LE_FX_PARAM_TAPER_UNVERIFIED},
    {"noise", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.3f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"noise_tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.9f, LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_VIN_PARAMS_N 4
#define LE_VIN_LP_HZ 7000.0
#define LE_VIN_HISS 0.02f        /* -34 dBFS of hiss at 100 % noise */
#define LE_VIN_CRACKLE 0.3f      /* a click's peak at 100 % */
#define LE_VIN_CRACKLE_HZ 8.0    /* clicks a second at 100 % */
#define LE_VIN_CRACKLE_S 0.0002  /* a click's decay */
#define LE_VIN_TONE_LO_HZ 500.0
#define LE_VIN_TONE_HI_HZ 12000.0

typedef struct le_fx_vinyl {
  le_fx_dyn_head h;
  float last[LE_VIN_PARAMS_N];
  le_fx_glide gain;  /* the saturation's gain */
  le_fx_glide noise; /* the noise level, 0..1 */
  float hz_l2, hz_tgt; /* the high-pass corner, log2 Hz */
  float tone_l2, tone_tgt;
  float hp[5], lp[5];
  float tone_a1, tone_a2, tone_a3; /* the noise's low-pass, SVF */
  float click_odds;                /* a click per sample, at 100 % noise */
  float click_decay;
  float z_hp[2][2], z_lp[2][2];
  float n_ic1[2], n_ic2[2];
  float click[2];
  uint32_t rng[2];
} le_fx_vinyl;

static void fx_vinyl_update(void* ks, const float* p, int sr, int settle) {
  le_fx_vinyl* v = (le_fx_vinyl*)ks;
  const int f = le_fx_dyn_begin(&v->h, v->last, p, LE_VIN_PARAMS_N, sr, settle);
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  const float k = settle ? 1.0f : v->h.k;
  if (settle) {
    const uint32_t seed = le_fx_kind_seed(ks);
    v->rng[0] = seed | 1u;
    v->rng[1] = (seed * 2654435761u) | 1u;
  }
  if (f & LE_FX_DYN_NEW_RATE) {
    double c[5];
    le_eq_design(LE_EQ_HIGHCUT, LE_VIN_LP_HZ, 0.0, 0.70710678, rate, c);
    for (int i = 0; i < 5; ++i) v->lp[i] = (float)c[i];
    v->click_decay = le_one_pole(LE_VIN_CRACKLE_S, rate);
  }
  const le_fx_param_desc* d = LE_FX_VINYL_PARAMS;
  const float drive = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float noise = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  if (f & LE_FX_DYN_CHANGED) {
    v->hz_tgt = (float)log2(le_fx_desc_value(&d[1], p[1]));
    const float t = p[3] < 0.0f ? 0.0f : p[3] > 1.0f ? 1.0f : p[3];
    v->tone_tgt = (float)log2(LE_VIN_TONE_LO_HZ *
                              pow(LE_VIN_TONE_HI_HZ / LE_VIN_TONE_LO_HZ, t));
    v->click_odds = (float)(4294967295.0 * LE_VIN_CRACKLE_HZ / (double)rate);
  }
  int moving = le_fx_glide_step(&v->gain, 1.0f + 9.0f * drive, k);
  moving |= le_fx_glide_step(&v->noise, noise, k);
  if (v->hz_l2 != v->hz_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&v->hz_l2, v->hz_tgt, k);
    double c[5];
    le_eq_design(LE_EQ_LOWCUT, exp2((double)v->hz_l2), 0.0, 0.70710678, rate, c);
    for (int i = 0; i < 5; ++i) v->hp[i] = (float)c[i];
  }
  if (v->tone_l2 != v->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&v->tone_l2, v->tone_tgt, k);
    le_svf_coefs(le_prewarp(exp2((double)v->tone_l2), rate), 1.41421356,
                 &v->tone_a1, &v->tone_a2, &v->tone_a3);
  }
  moving |= v->hz_l2 != v->hz_tgt || v->tone_l2 != v->tone_tgt;
  v->h.moving = moving;
}

static void fx_vinyl_kprocess(void* ks, float* l, float* r) {
  le_fx_vinyl* v = (le_fx_vinyl*)ks;
  const float g = le_fx_glide_next(&v->gain);
  const float noise = le_fx_glide_next(&v->noise);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float x = le_biquad_tick(v->hp, v->z_hp[ch], io[ch]);
    x = le_biquad_tick(v->lp, v->z_lp[ch], x);
    x = tanhf(g * x) / g;
    if (noise <= 0.0f) {
      /* Silent: nothing left to come back when the noise is raised. */
      v->click[ch] = 0.0f;
      v->n_ic1[ch] = 0.0f;
      v->n_ic2[ch] = 0.0f;
    } else {
      /* A click starts when the draw falls under the odds (they follow the
       * gliding noise level), at a random size and sign, then decays. */
      if (le_xorshift(&v->rng[ch]) < (uint32_t)(v->click_odds * noise)) {
        v->click[ch] = LE_VIN_CRACKLE * le_noise(&v->rng[ch]);
      }
      const float n = LE_VIN_HISS * le_noise(&v->rng[ch]) + v->click[ch];
      v->click[ch] *= v->click_decay;
      float b1;
      float lp;
      le_svf_tick(n, v->tone_a1, v->tone_a2, v->tone_a3, &v->n_ic1[ch],
                  &v->n_ic2[ch], &b1, &lp);
      x += noise * lp;
    }
    io[ch] = x;
  }
  *l = io[0];
  *r = io[1];
}

/* ---- Degrade (LE_FX_DEGRADE) ----
 *
 * Sample-rate reduction: the input held at the Looper X's 500 Hz to 50 kHz
 * (at or above the engine's rate it holds every sample, so only the filter
 * and the mix act), then a 12 dB/octave low-pass the filter control moves
 * from 20 kHz (0 %) down to half the held rate (100 %), mixed with the dry
 * signal. The hold runs on whatever the loop does, so a degrade that holds
 * never prints. */
static const le_fx_param_desc LE_FX_DEGRADE_PARAMS[] = {
    {"frequency", LE_FX_UNIT_HZ, 0, 500.0f, 50000.0f, LE_FX_CURVE_EXPONENTIAL,
     1.0f, LE_FX_PARAM_TAPER_UNVERIFIED},
    {"filter", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f,
     LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_DEG_PARAMS_N 3
#define LE_DEG_OPEN_HZ 20000.0

typedef struct le_fx_degrade {
  le_fx_dyn_head h;
  float last[LE_DEG_PARAMS_N];
  le_fx_glide step; /* the hold's phase step per sample (1: every sample) */
  le_fx_glide mix;
  float lp_l2, lp_tgt; /* the low-pass corner, log2 Hz */
  float a1, a2, a3;
  double ph;
  float held[2];
  float ic1[2], ic2[2];
} le_fx_degrade;

static void fx_degrade_update(void* ks, const float* p, int sr, int settle) {
  le_fx_degrade* q = (le_fx_degrade*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_DEG_PARAMS_N, sr, settle);
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  const float k = settle ? 1.0f : q->h.k;
  const le_fx_param_desc* d = LE_FX_DEGRADE_PARAMS;
  const double hz = le_fx_desc_value(&d[0], p[0]);
  const float step = (float)(hz >= rate ? 1.0 : hz / rate);
  if (f & LE_FX_DYN_CHANGED) {
    const double v = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : p[1];
    const double down = 0.5 * (hz < rate ? hz : rate);
    q->lp_tgt = (float)((1.0 - v) * log2(LE_DEG_OPEN_HZ) + v * log2(down));
  }
  const float m = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  int moving = le_fx_glide_step(&q->step, step, k);
  moving |= le_fx_glide_step(&q->mix, m, k);
  if (q->lp_l2 != q->lp_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&q->lp_l2, q->lp_tgt, k);
    le_svf_coefs(le_prewarp(exp2((double)q->lp_l2), rate), 1.41421356, &q->a1,
                 &q->a2, &q->a3);
  }
  moving |= q->lp_l2 != q->lp_tgt;
  q->h.moving = moving;
}

static void fx_degrade_kprocess(void* ks, float* l, float* r) {
  le_fx_degrade* q = (le_fx_degrade*)ks;
  const float step = le_fx_glide_next(&q->step);
  const float m = le_fx_glide_next(&q->mix);
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  q->ph += (double)step;
  const int take = q->ph >= 1.0;
  if (take) q->ph -= 1.0;
  float y[2];
  for (int ch = 0; ch < 2; ++ch) {
    if (take) q->held[ch] = x[ch];
    float b1;
    float lp;
    le_svf_tick(q->held[ch], q->a1, q->a2, q->a3, &q->ic1[ch], &q->ic2[ch], &b1,
                &lp);
    y[ch] = x[ch] + m * (lp - x[ch]);
  }
  *l = y[0];
  *r = y[1];
}

/* ---- LPF (LE_FX_LPF) ----
 *
 * A resonant 12 dB/octave low-pass (state-variable): the Looper X's cutoff,
 * 20 Hz to 20 kHz, and its resonance from Q 0.71 (0 %) to Q 3 (100 %,
 * +9.5 dB at the corner). The cutoff glides in octaves. At the top of its
 * range the filter is off (the Looper X's default, with resonance at
 * 100 %: a fresh filter is transparent), gliding in and out as the EQ's
 * cuts do. The Rhythmic
 * Rack's LFO over the cutoff comes with the tempo context (#887 part 10). */
static const le_fx_param_desc LE_FX_LPF_PARAMS[] = {
    {"cutoff", LE_FX_UNIT_HZ, 0, 20.0f, 20000.0f, LE_FX_CURVE_EXPONENTIAL,
     1.0f, LE_FX_PARAM_OFF_AT_MAX},
    {"resonance", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, LE_FX_PARAM_TAPER_UNVERIFIED},
};
#define LE_LPF_PARAMS_N 2
#define LE_LPF_Q_LO 0.70710678
#define LE_LPF_Q_HI 3.0

typedef struct le_fx_lpf {
  le_fx_dyn_head h;
  float last[LE_LPF_PARAMS_N];
  float l2, tgt;   /* the cutoff, log2 Hz */
  float lnq, qtgt; /* the resonance, ln Q */
  le_fx_glide amount; /* 1 filtering, 0 off (cutoff at the top) */
  float a1, a2, a3;
  float ic1[2], ic2[2];
} le_fx_lpf;

static void fx_lpf_update(void* ks, const float* p, int sr, int settle) {
  le_fx_lpf* q = (le_fx_lpf*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_LPF_PARAMS_N, sr, settle);
  if (!f) return;
  const float k = settle ? 1.0f : q->h.k;
  if (f & LE_FX_DYN_CHANGED) {
    q->tgt = (float)log2(le_fx_desc_value(&LE_FX_LPF_PARAMS[0], p[0]));
    const double v = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : p[1];
    q->qtgt = (float)(log(LE_LPF_Q_LO) + v * log(LE_LPF_Q_HI / LE_LPF_Q_LO));
  }
  if (q->l2 != q->tgt || q->lnq != q->qtgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&q->l2, q->tgt, k);
    le_fx_step_toward(&q->lnq, q->qtgt, k);
    le_svf_coefs(le_prewarp(exp2((double)q->l2), sr), exp(-(double)q->lnq),
                 &q->a1, &q->a2, &q->a3);
  }
  const int moving = le_fx_glide_step(&q->amount, p[0] >= 1.0f ? 0.0f : 1.0f, k);
  q->h.moving = moving || q->l2 != q->tgt || q->lnq != q->qtgt;
}

static void fx_lpf_kprocess(void* ks, float* l, float* r) {
  le_fx_lpf* q = (le_fx_lpf*)ks;
  const float amount = le_fx_glide_next(&q->amount);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  if (amount <= 0.0f) {
    /* Off: the identity, with the filter's memory cleared so it starts
     * clean when it comes back. */
    q->ic1[0] = q->ic1[1] = q->ic2[0] = q->ic2[1] = 0.0f;
    *l = io[0];
    *r = io[1];
    return;
  }
  for (int ch = 0; ch < 2; ++ch) {
    float b1;
    float lp;
    le_svf_tick(io[ch], q->a1, q->a2, q->a3, &q->ic1[ch], &q->ic2[ch], &b1, &lp);
    io[ch] = amount >= 1.0f ? lp : io[ch] + amount * (lp - io[ch]);
  }
  *l = io[0];
  *r = io[1];
}

/* ---- Spring (LE_FX_SPRING, #887 part 8) ----
 *
 * Fit to the Phase 0 captures of the Guitar Rack's Spring (#891, s3/6 at
 * Time 2.00 s and s3/7 at Time 7.9 s, both at Mix 28.9 %):
 * - the tank is one recirculating spring: its echo returns every 38.0 ms
 *   (the envelope's autocorrelation peak in both), dispersed on each trip by
 *   a chain of twelve first-order all-passes;
 * - the decay: each trip loses 2.14 / Time + 0.17 dB, and above 1.2 kHz
 *   another 0.32 dB (a first-order shelf in the loop). Measured on the
 *   impulse responses in four bands from 200 Hz to 4 kHz, that decays in
 *   1.95, 1.85, 1.74, 1.63 s against the capture's 1.96, 1.86, 1.76, 1.54
 *   at Time 2.00 s, and 6.2, 5.3, 4.4, 3.8 s against 6.5, 5.3, 4.5, 3.4 at
 *   7.9 s (so Time is the decay at the bottom of the band at short settings
 *   and longer than it at long ones);
 * - the wet sound is band-limited, 200 Hz to a steep edge near 4 kHz
 *   (-46 dB at 4.7 kHz, -96 dB at 7.2 kHz): nine sections fitted to the
 *   impulse response's spectrum within 1.7 dB rms from 100 Hz to 7.3 kHz;
 * - the mix law is the chorus's (dry 1 - 0.29 mix; the capture's dry gain
 *   was 0.9165 at 28.9 %), and the wet level follows
 *   0.85 mix (Time / 2)^0.45, fitted to the wet energy against the dry at
 *   both Times.
 * A known difference: successive echoes repeat more closely (envelope
 * autocorrelation 0.87 at 38 ms against the capture's 0.4). Both channels
 * take the tank's mono output (the capture's correlated at 0.996). */
static const le_fx_param_desc LE_FX_SPRING_PARAMS[] = {
    {"time", LE_FX_UNIT_SECONDS, 0, 1.0f, 10.0f, LE_FX_CURVE_EXPONENTIAL,
     0.30103f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
};
#define LE_SPR_PARAMS_N 2
#define LE_SPR_RING 4096u /* holds the 38 ms trip up to 107 kHz */
#define LE_SPR_TRIP_S 0.038
#define LE_SPR_STAGES 12
#define LE_SPR_DISPERSION_HZ 1500.0
#define LE_SPR_LOSS_HZ 1200.0
#define LE_SPR_LOSS_SHELF 0.963829f /* -0.32 dB per trip above it */
#define LE_SPR_DRY_DROP 0.29f
#define LE_SPR_WET 0.85
#define LE_SPR_WET_EXP 0.45
#define LE_SPR_LOSS_TIME_DB 2.14 /* dB a trip, over Time */
#define LE_SPR_LOSS_DB 0.17
#define LE_SPR_SECTIONS 9

static const struct {
  int kind;
  double hz, db, q;
} LE_SPR_SHAPE[LE_SPR_SECTIONS] = {
    {LE_EQ_LOWCUT, 103.20, 0.0, 0.1057},  {LE_EQ_LOWCUT, 130.52, 0.0, 0.1164},
    {LE_EQ_HIGHCUT, 1154.0, 0.0, 1.1618}, {LE_EQ_HIGHCUT, 4120.4, 0.0, 7.0998},
    {LE_EQ_HIGHCUT, 3248.9, 0.0, 4.3359}, {LE_EQ_HIGHCUT, 882.81, 0.0, 1.2811},
    {LE_EQ_LOMID, 405.11, 18.600, 0.1000}, {LE_EQ_LOMID, 2014.2, 4.521, 3.8881},
    {LE_EQ_LOMID, 948.47, -6.570, 2.5891},
};

typedef struct le_fx_spring {
  le_fx_dyn_head h;
  float last[LE_SPR_PARAMS_N];
  le_fx_glide gain; /* the loop's gain per trip */
  le_fx_glide dry;
  le_fx_glide wet;
  float gain_tgt;   /* the targets, recomputed when the settings change */
  float wet_tgt;
  double trip_scale; /* the trip held, over the 38 ms one (1 below 107 kHz) */
  float ap;         /* the all-passes' coefficient */
  float loss_g1;
  uint32_t trip;    /* the delay line's samples */
  float shape[LE_SPR_SECTIONS][5];
  float z[LE_SPR_SECTIONS][2];
  float ap_z[LE_SPR_STAGES];
  float loss_s;
  uint32_t w;
  float ring[LE_SPR_RING];
} le_fx_spring;

static void fx_spring_update(void* ks, const float* p, int sr, int settle) {
  le_fx_spring* q = (le_fx_spring*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_SPR_PARAMS_N, sr, settle);
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    /* A rate change makes the ring's samples another rate's: start clean
     * (a fresh block is already clear). */
    if (!settle) {
      memset(q->ring, 0, sizeof(q->ring));
      memset(q->z, 0, sizeof(q->z));
      memset(q->ap_z, 0, sizeof(q->ap_z));
      q->loss_s = 0.0f;
    }
    for (int s = 0; s < LE_SPR_SECTIONS; ++s) {
      double c[5];
      le_eq_design(LE_SPR_SHAPE[s].kind, LE_SPR_SHAPE[s].hz, LE_SPR_SHAPE[s].db,
                   LE_SPR_SHAPE[s].q, rate, c);
      for (int i = 0; i < 5; ++i) q->shape[s][i] = (float)c[i];
    }
    const double t = le_prewarp(LE_SPR_DISPERSION_HZ, rate);
    const double a = (1.0 - t) / (1.0 + t);
    q->ap = (float)a;
    q->loss_g1 = le_onepole_g1(LE_SPR_LOSS_HZ, rate);
    /* The trip less the all-passes' delay at low frequencies. */
    const double want = LE_SPR_TRIP_S * rate - LE_SPR_STAGES * (1.0 - a) / (1.0 + a);
    double trip = want;
    /* Past 107 kHz the trip outgrows the ring (a larger one would sit in
     * every slot's arena): hold it there and scale the loss per trip, so the
     * decay stays right though the echo shortens. */
    if (trip > (double)(LE_SPR_RING - 1u)) trip = (double)(LE_SPR_RING - 1u);
    if (trip < 1.0) trip = 1.0;
    q->trip = (uint32_t)(trip + 0.5);
    q->trip_scale = want > 1.0 ? (double)q->trip / want : 1.0;
  }
  const float m = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    const double time = le_fx_desc_value(&LE_FX_SPRING_PARAMS[0], p[0]);
    q->gain_tgt = (float)pow(10.0, -(LE_SPR_LOSS_TIME_DB / time + LE_SPR_LOSS_DB) *
                                       q->trip_scale / 20.0);
    q->wet_tgt = (float)(LE_SPR_WET * pow(time / 2.0, LE_SPR_WET_EXP));
  }
  const float k = settle ? 1.0f : q->h.k;
  int moving = le_fx_glide_step(&q->gain, q->gain_tgt, k);
  moving |= le_fx_glide_step(&q->dry, 1.0f - LE_SPR_DRY_DROP * m, k);
  moving |= le_fx_glide_step(&q->wet, q->wet_tgt * m, k);
  q->h.moving = moving;
}

static void fx_spring_kprocess(void* ks, float* l, float* r) {
  le_fx_spring* q = (le_fx_spring*)ks;
  const float g = le_fx_glide_next(&q->gain);
  const float dry = le_fx_glide_next(&q->dry);
  const float wet = le_fx_glide_next(&q->wet);
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  float s = 0.5f * (x0 + x1);
  for (int i = 0; i < LE_SPR_SECTIONS; ++i) {
    s = le_biquad_tick(q->shape[i], q->z[i], s);
  }
  const uint32_t at = q->w & (LE_SPR_RING - 1u);
  /* The delayed trip: written trip samples ago. */
  float u = s + g * q->ring[(q->w - q->trip) & (LE_SPR_RING - 1u)];
  for (int i = 0; i < LE_SPR_STAGES; ++i) {
    const float y = q->ap * u + q->ap_z[i];
    q->ap_z[i] = u - q->ap * y;
    u = y;
  }
  u += (LE_SPR_LOSS_SHELF - 1.0f) * (u - le_onepole_lp(&q->loss_s, q->loss_g1, u));
  u = fx_sanitize(u); /* a decayed tail flushes to 0 */
  q->ring[at] = u;
  q->w++;
  *l = dry * x0 + wet * u;
  *r = dry * x1 + wet * u;
}

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
LE_FX_ROWS_FIT(LE_FX_EQ_PARAMS);
LE_FX_ROWS_FIT(LE_FX_COMPRESSOR_PARAMS);
LE_FX_ROWS_FIT(LE_FX_TRANSIENT_PARAMS);
LE_FX_ROWS_FIT(LE_FX_HP_GATE_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DOUBLER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_CHORUS_PARAMS);
LE_FX_ROWS_FIT(LE_FX_WAH_PARAMS);
LE_FX_ROWS_FIT(LE_FX_OVERDRIVE_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DISTORTION_PARAMS);
LE_FX_ROWS_FIT(LE_FX_VINYL_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DEGRADE_PARAMS);
LE_FX_ROWS_FIT(LE_FX_LPF_PARAMS);
LE_FX_ROWS_FIT(LE_FX_SPRING_PARAMS);

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
  /* The type's parameter descriptors (le_fx_param_info), NULL for a type
   * without fixed params; their count is le_fx_widths[type], the one table
   * le_fx_param_width reads. Defaults come from here. */
  const le_fx_param_desc* params;
  /* LE_FX_F_* behaviour bits. */
  uint32_t flags;
  /* A kind that keeps its state on the heap (le_fx_kinds): the bytes of its
   * block, 0 for the rest. Such a kind has no `process`; the chain runs
   * `update` on its block at the update cadence (and with settle set right
   * after the block is cleared, so smoothing lands at once), then
   * `kprocess`. */
  size_t state_size;
  void (*update)(void* ks, const float* p, int sr, int settle);
  void (*kprocess)(void* ks, float* l, float* r);
} le_fx_vtable;

/* Bypass drains the tail instead of crossfading out: a linear kind that
 * holds a tail in rings and reports no latency (delay, echo, reverb, whose
 * rings `prepare` allocates; the spring, whose ring is in its kind block). */
#define LE_FX_F_DRAINS 1u
/* A free-running modulator (an LFO that runs on whatever the loop does): the
 * kind sounds different each lap, so a chain holding it is never printed
 * (le_fx_type_free_running). */
#define LE_FX_F_FREE_RUNNING 2u

/* Indexed by le_fx_type — one row per effect. Adding an effect is adding its
 * kernels above + one row here. LE_FX_NONE is the all-NULL no-op (the empty-chain
 * regression guard). */
static const le_fx_vtable LE_FX[] = {
    [LE_FX_NONE] = {NULL, NULL, NULL, NULL},
    [LE_FX_DRIVE] = {fx_drive_process, NULL, NULL, LE_FX_DRIVE_PARAMS},
    [LE_FX_FILTER] = {fx_filter_process, NULL, NULL, LE_FX_FILTER_PARAMS},
    [LE_FX_DELAY] =
        {fx_delay_process, NULL, fx_stereo_ring_prepare, LE_FX_DELAY_PARAMS, LE_FX_F_DRAINS},
    [LE_FX_TREMOLO] = {fx_tremolo_process, NULL, NULL, LE_FX_TREMOLO_PARAMS},
    [LE_FX_OCTAVER] = {fx_octaver_process, fx_octaver_latency_vt,
                       fx_octaver_prepare, LE_FX_OCTAVER_PARAMS},
    [LE_FX_ECHO] =
        {fx_echo_process, NULL, fx_stereo_ring_prepare, LE_FX_ECHO_PARAMS, LE_FX_F_DRAINS},
    [LE_FX_REVERB] =
        {fx_reverb_process, NULL, fx_reverb_prepare, LE_FX_REVERB_PARAMS, LE_FX_F_DRAINS},
    /* A hosted plugin: process forwards to its slot; no params, no prepare, no
     * defaults (the host owns all state). Output is sanitized at the chain
     * boundary in fx_apply_chain. */
    [LE_FX_PLUGIN] = {fx_plugin_process, NULL, NULL, NULL},
    /* The EQ: linear but with no tail worth draining, so it crossfades. */
    [LE_FX_EQ] = {NULL, NULL, NULL, LE_FX_EQ_PARAMS, 0, sizeof(le_fx_eq),
                  fx_eq_update, fx_eq_kprocess},
    /* The dynamics kinds hold no tail worth draining: they crossfade. */
    [LE_FX_COMPRESSOR] = {NULL, NULL, NULL, LE_FX_COMPRESSOR_PARAMS, 0,
                          sizeof(le_fx_comp), fx_comp_update, fx_comp_kprocess},
    [LE_FX_TRANSIENT] = {NULL, NULL, NULL, LE_FX_TRANSIENT_PARAMS, 0,
                         sizeof(le_fx_transient), fx_transient_update,
                         fx_transient_kprocess},
    [LE_FX_HP_GATE] = {NULL, NULL, NULL, LE_FX_HP_GATE_PARAMS, 0,
                       sizeof(le_fx_hp_gate), fx_hp_gate_update,
                       fx_hp_gate_kprocess},
    [LE_FX_DOUBLER] = {NULL, NULL, NULL, LE_FX_DOUBLER_PARAMS,
                       LE_FX_F_FREE_RUNNING, sizeof(le_fx_doubler),
                       fx_doubler_update, fx_doubler_kprocess},
    [LE_FX_CHORUS] = {NULL, NULL, NULL, LE_FX_CHORUS_PARAMS,
                      LE_FX_F_FREE_RUNNING, sizeof(le_fx_chorus),
                      fx_chorus_update, fx_chorus_kprocess},
    [LE_FX_WAH] = {NULL, NULL, NULL, LE_FX_WAH_PARAMS, 0, sizeof(le_fx_wah),
                   fx_wah_update, fx_wah_kprocess},
    [LE_FX_OVERDRIVE] = {NULL, NULL, NULL, LE_FX_OVERDRIVE_PARAMS, 0,
                         sizeof(le_fx_overdrive), fx_overdrive_update,
                         fx_overdrive_kprocess},
    [LE_FX_DISTORTION] = {NULL, NULL, NULL, LE_FX_DISTORTION_PARAMS, 0,
                          sizeof(le_fx_distortion), fx_distortion_update,
                          fx_distortion_kprocess},
    [LE_FX_VINYL] = {NULL, NULL, NULL, LE_FX_VINYL_PARAMS, LE_FX_F_FREE_RUNNING,
                     sizeof(le_fx_vinyl), fx_vinyl_update, fx_vinyl_kprocess},
    [LE_FX_DEGRADE] = {NULL, NULL, NULL, LE_FX_DEGRADE_PARAMS,
                       LE_FX_F_FREE_RUNNING, sizeof(le_fx_degrade),
                       fx_degrade_update, fx_degrade_kprocess},
    [LE_FX_LPF] = {NULL, NULL, NULL, LE_FX_LPF_PARAMS, 0, sizeof(le_fx_lpf),
                   fx_lpf_update, fx_lpf_kprocess},
    /* The spring drains its tail on bypass, as the delay and reverb do. */
    [LE_FX_SPRING] = {NULL, NULL, NULL, LE_FX_SPRING_PARAMS, LE_FX_F_DRAINS,
                      sizeof(le_fx_spring), fx_spring_update,
                      fx_spring_kprocess},
};
#define LE_FX_TYPE_COUNT ((int32_t)(sizeof(LE_FX) / sizeof(LE_FX[0])))

/* Each type's descriptor count: the only copy, read by le_fx_param_width,
 * le_fx_param_count and le_fx_defaults. A type with descriptor rows and no
 * entry here would read nothing; test_fx_params_past_count_are_inert checks
 * every built-in has one. */
#define LE_FX_ROW_COUNT(t) (uint8_t)(sizeof(t) / sizeof(t[0]))
_Static_assert(LE_EQ_PARAMS_N ==
                   sizeof(LE_FX_EQ_PARAMS) / sizeof(LE_FX_EQ_PARAMS[0]),
               "le_fx_eq.last holds every EQ setting");
_Static_assert(LE_COMP_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_COMPRESSOR_PARAMS) &&
                   LE_TR_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_TRANSIENT_PARAMS) &&
                   LE_HPG_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_HP_GATE_PARAMS) &&
                   LE_DBL_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_DOUBLER_PARAMS) &&
                   LE_CHO_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_CHORUS_PARAMS) &&
                   LE_WAH_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_WAH_PARAMS) &&
                   LE_OD_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_OVERDRIVE_PARAMS) &&
                   LE_DIST_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_DISTORTION_PARAMS) &&
                   LE_VIN_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_VINYL_PARAMS) &&
                   LE_DEG_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_DEGRADE_PARAMS) &&
                   LE_LPF_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_LPF_PARAMS) &&
                   LE_SPR_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_SPRING_PARAMS),
               "each Looper X kind's `last` holds every setting");
_Static_assert(LE_FX_WIDTHS == sizeof(LE_FX) / sizeof(LE_FX[0]),
               "LE_FX_WIDTHS must be one past the last le_fx_type code");
const uint8_t le_fx_widths[LE_FX_WIDTHS] = {
    [LE_FX_DRIVE] = LE_FX_ROW_COUNT(LE_FX_DRIVE_PARAMS),
    [LE_FX_FILTER] = LE_FX_ROW_COUNT(LE_FX_FILTER_PARAMS),
    [LE_FX_DELAY] = LE_FX_ROW_COUNT(LE_FX_DELAY_PARAMS),
    [LE_FX_TREMOLO] = LE_FX_ROW_COUNT(LE_FX_TREMOLO_PARAMS),
    [LE_FX_OCTAVER] = LE_FX_ROW_COUNT(LE_FX_OCTAVER_PARAMS),
    [LE_FX_ECHO] = LE_FX_ROW_COUNT(LE_FX_ECHO_PARAMS),
    [LE_FX_REVERB] = LE_FX_ROW_COUNT(LE_FX_REVERB_PARAMS),
    [LE_FX_EQ] = LE_FX_ROW_COUNT(LE_FX_EQ_PARAMS),
    [LE_FX_COMPRESSOR] = LE_FX_ROW_COUNT(LE_FX_COMPRESSOR_PARAMS),
    [LE_FX_TRANSIENT] = LE_FX_ROW_COUNT(LE_FX_TRANSIENT_PARAMS),
    [LE_FX_HP_GATE] = LE_FX_ROW_COUNT(LE_FX_HP_GATE_PARAMS),
    [LE_FX_DOUBLER] = LE_FX_ROW_COUNT(LE_FX_DOUBLER_PARAMS),
    [LE_FX_CHORUS] = LE_FX_ROW_COUNT(LE_FX_CHORUS_PARAMS),
    [LE_FX_WAH] = LE_FX_ROW_COUNT(LE_FX_WAH_PARAMS),
    [LE_FX_OVERDRIVE] = LE_FX_ROW_COUNT(LE_FX_OVERDRIVE_PARAMS),
    [LE_FX_DISTORTION] = LE_FX_ROW_COUNT(LE_FX_DISTORTION_PARAMS),
    [LE_FX_VINYL] = LE_FX_ROW_COUNT(LE_FX_VINYL_PARAMS),
    [LE_FX_DEGRADE] = LE_FX_ROW_COUNT(LE_FX_DEGRADE_PARAMS),
    [LE_FX_LPF] = LE_FX_ROW_COUNT(LE_FX_LPF_PARAMS),
    [LE_FX_SPRING] = LE_FX_ROW_COUNT(LE_FX_SPRING_PARAMS),
};

/* ---- per-kind state (le_fx_kinds, engine_private.h) ---- */

/* A block's header; the kind's state follows at LE_FX_KIND_ALIGN. */
#define LE_FX_KIND_ALIGN 64
typedef struct le_fx_kind_block {
  struct le_fx_kind_block* next; /* set before the block is published */
  int32_t type;
  int32_t settle; /* audio thread: the next update lands at once */
  uint32_t seed;  /* audio thread: set with each clear (le_fx_kind_seed) */
} le_fx_kind_block;

static inline void* le_fx_kind_payload(le_fx_kind_block* b) {
  return (unsigned char*)b + LE_FX_KIND_ALIGN;
}

static uint32_t le_fx_kind_seed(const void* ks) {
  return ((const le_fx_kind_block*)((const unsigned char*)ks -
                                    LE_FX_KIND_ALIGN))->seed;
}

static size_t le_fx_kind_block_bytes(int32_t type) {
  const size_t n = LE_FX[type].state_size;
  return LE_FX_KIND_ALIGN + ((n + LE_FX_KIND_ALIGN - 1) & ~(size_t)(LE_FX_KIND_ALIGN - 1));
}

/* One slot's arena: room for one block of every heap-state kind, so a slot
 * that holds each kind in turn never runs out. */
static size_t le_fx_kind_arena_bytes(void) {
  size_t bytes = 0;
  for (int32_t t = LE_FX_NONE + 1; t < LE_FX_TYPE_COUNT; ++t) {
    if (LE_FX[t].state_size) bytes += le_fx_kind_block_bytes(t);
  }
  return bytes;
}

/* Control thread: makes sure slot [slot] has a block for [type]. */
static int32_t le_fx_kind_prepare(le_fx_state* fx, int slot, int32_t type) {
  le_fx_kinds* k = atomic_load_explicit(&fx->kinds, memory_order_relaxed);
  if (k == NULL) {
    k = (le_fx_kinds*)le_rt_alloc_prefaulted(sizeof(*k));
    if (k == NULL) return LE_ERR_INVALID;
    atomic_store_explicit(&fx->kinds, k, memory_order_release);
  }
  le_fx_kind_slot* ks = &k->slot[slot];
  le_fx_kind_block* head = atomic_load_explicit(&ks->head, memory_order_relaxed);
  for (le_fx_kind_block* b = head; b != NULL; b = b->next) {
    if (b->type == type) return LE_OK;
  }
  if (ks->arena.base == NULL &&
      !le_rt_arena_init(&ks->arena, le_fx_kind_arena_bytes())) {
    return LE_ERR_INVALID;
  }
  le_fx_kind_block* b = (le_fx_kind_block*)le_rt_arena_alloc(
      &ks->arena, le_fx_kind_block_bytes(type));
  if (b == NULL) return LE_ERR_INVALID; /* sized for every kind: unreachable */
  b->type = type;
  b->settle = 1;
  b->next = head;
  atomic_store_explicit(&ks->head, b, memory_order_release);
  return LE_OK;
}

void le_fx_free_kinds(le_fx_state* fx, int slot) {
  le_fx_kinds* k = atomic_load_explicit(&fx->kinds, memory_order_relaxed);
  if (k == NULL) return;
  le_fx_kind_slot* ks = &k->slot[slot];
  atomic_store_explicit(&ks->head, NULL, memory_order_relaxed);
  ks->cur = NULL;
  le_rt_arena_release(&ks->arena);
}

void le_fx_free_kind_table(le_fx_state* fx) {
  le_fx_kinds* k = atomic_load_explicit(&fx->kinds, memory_order_relaxed);
  if (k == NULL) return;
  for (int s = 0; s < LE_FX_MAX; ++s) le_rt_arena_release(&k->slot[s].arena);
  atomic_store_explicit(&fx->kinds, NULL, memory_order_relaxed);
  le_rt_free(k);
}

/* Where in the update cadence slot [s] of this owner runs: one of four
 * quarters, from the owner's hop-stagger quarter plus the slot, as the
 * octaver staggers its hop (le_pv_hop_phase). Several gliding instances then
 * redesign on different frames instead of all on the same one. The offline
 * renders copy the owner's seed, so they keep the live phase. */
static inline uint32_t le_fx_update_phase(const le_fx_state* fx, int s) {
  const uint32_t quarter =
      (uint32_t)fx->hop_seed / (uint32_t)LE_PV_STAGGER_QUARTER + (uint32_t)s;
  return (quarter & 3u) * (uint32_t)(LE_FX_UPDATE_FRAMES / 4);
}

/* Audio thread: slot [s]'s state for [ty], updated at the cadence, or NULL
 * when the control thread prepared none (the slot then passes through). A
 * block it switches to (a retype, or le_fx_entry_reset) starts cleared and
 * settles on its first update. */
static void* fx_kind_state(le_fx_state* fx, int s, int32_t ty, int sr,
                           const float* p) {
  le_fx_kinds* k = atomic_load_explicit(&fx->kinds, memory_order_acquire);
  if (k == NULL) return NULL;
  le_fx_kind_slot* ks = &k->slot[s];
  le_fx_kind_block* b = ks->cur;
  if (b == NULL || b->type != ty) {
    b = atomic_load_explicit(&ks->head, memory_order_acquire);
    while (b != NULL && b->type != ty) b = b->next;
    ks->cur = b;
    if (b == NULL) return NULL;
    memset(le_fx_kind_payload(b), 0, LE_FX[ty].state_size);
    b->settle = 1;
    b->seed = ((uint32_t)fx->hop_seed + 1u) * 2654435761u +
              (uint32_t)s * 0x9E3779B9u;
  }
  void* st = le_fx_kind_payload(b);
  if (b->settle ||
      ((le_fx_now(fx) + le_fx_update_phase(fx, s)) &
       (uint32_t)(LE_FX_UPDATE_FRAMES - 1)) == 0) {
    LE_FX[ty].update(st, p, sr, b->settle);
    b->settle = 0;
  }
  return st;
}

/* One entry's effect on a pair: the kernel, or a heap-state kind's update
 * and kernel. */
static inline void fx_run(le_fx_state* fx, int s, int32_t ty, int sr, int cap,
                          float* l, float* r, const float* p) {
  if (LE_FX[ty].state_size) {
    void* st = fx_kind_state(fx, s, ty, sr, p);
    if (st != NULL) LE_FX[ty].kprocess(st, l, r);
    return;
  }
  LE_FX[ty].process(fx, s, sr, cap, l, r, p);
}

/* Whether slot [s] as [type] holds a tail that re-enabling must clear: the
 * rings `prepare` allocated (delay, echo, reverb, the octaver), or a
 * draining kind's block (the spring's ring). */
static int le_fx_holds_tail(const le_fx_state* fx, int s, int32_t type) {
  if (type <= LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return 0;
  if (LE_FX[type].state_size != 0) return (LE_FX[type].flags & LE_FX_F_DRAINS) != 0;
  return LE_FX[type].prepare != NULL &&
         (fx->delay[s][0] != NULL || fx->delay[s][1] != NULL);
}

void le_fx_entry_renew(le_fx_state* fx, int slot, int32_t type) {
  le_fx_entry_reset(fx, slot);
  if (le_fx_holds_tail(fx, slot, type)) le_fx_enable_force_bypass(fx, slot);
}

int le_fx_type_free_running(int32_t type) {
  return type > LE_FX_NONE && type < LE_FX_TYPE_COUNT &&
         (LE_FX[type].flags & LE_FX_F_FREE_RUNNING) != 0;
}

int le_fx_entry_free_running(int32_t type, const float* p, int sr) {
  if (!le_fx_type_free_running(type)) return 0;
  switch (type) {
    case LE_FX_VINYL:
      return p[2] > 0.0f; /* the noise */
    case LE_FX_DEGRADE: /* holding (below the rate), and heard */
      return le_fx_desc_value(&LE_FX_DEGRADE_PARAMS[0], p[0]) <
                 (double)(sr > 0 ? sr : 48000) &&
             p[2] > 0.0f;
    case LE_FX_DOUBLER:
      return p[0] > 0.0f; /* at 0 % mix the voices add nothing */
    default:
      return p[2] > 0.0f; /* the chorus's mix */
  }
}

/* Whether a bypassed slot of [type] drains its tail rather than crossfading
 * out: a ring-owning type with no reported latency (delay, echo, reverb, the
 * spring).
 * Everything else — memoryless kernels, the latency-bearing octaver, hosted
 * plugins — crossfades (see fx_apply_chain's doc). */
int le_fx_type_drains(int32_t type) {
  return type > LE_FX_NONE && type < LE_FX_TYPE_COUNT &&
         (LE_FX[type].flags & LE_FX_F_DRAINS) != 0;
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
    if (ty > LE_FX_NONE && ty < LE_FX_TYPE_COUNT &&
        (LE_FX[ty].process || LE_FX[ty].kprocess)) {
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
          /* A draining kind keeps its ring in its block, which the reset
           * below clears: it is spaced the same way. */
          const int needs_clear = le_fx_holds_tail(fx, s, ty);
          if (needs_clear && fx->enable_clear_cooldown > 0) goto slot_done;
          le_fx_entry_reset(fx, s);
          if (needs_clear) {
            if (LE_FX[ty].state_size == 0) le_fx_entry_clear_rings(fx, s, cap);
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
        fx_run(fx, s, ty, sr, cap, &wl, &wr, params[s]);
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
      fx_run(fx, s, ty, sr, cap, &wl, &wr, params[s]);
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
  if (type <= LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return LE_OK;
  if (LE_FX[type].state_size) return le_fx_kind_prepare(fx, slot, type);
  if (LE_FX[type].prepare == NULL) return LE_OK; /* needs no heap */
  return LE_FX[type].prepare(fx, slot, cap);
}

void le_fx_defaults(int32_t type, float out[LE_FX_PARAMS]) {
  const int known = type > LE_FX_NONE && type < LE_FX_TYPE_COUNT;
  const int32_t n = known ? le_fx_widths[type] : 0;
  for (int p = 0; p < LE_FX_PARAMS; ++p) {
    out[p] = p < n ? LE_FX[type].params[p].def : 0.0f; /* NONE / unknown: 0 */
  }
}

int32_t le_fx_param_count(int32_t type) {
  if (type < LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return LE_ERR_INVALID;
  return le_fx_widths[type];
}

int32_t le_fx_param_info(int32_t type, int32_t param, le_fx_param_desc* out) {
  if (out == NULL || type < LE_FX_NONE || type >= LE_FX_TYPE_COUNT ||
      param < 0 || param >= le_fx_widths[type]) {
    return LE_ERR_INVALID;
  }
  *out = LE_FX[type].params[param];
  return LE_OK;
}
