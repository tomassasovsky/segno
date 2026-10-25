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
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_internal.h" /* le_psola_detect_band prototype (below) */
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
_Static_assert(LE_OCT_REACH >= LE_PSOLA_LAG + LE_PSOLA_RAW,
               "the ring guard covers PSOLA's refinement window");
_Static_assert(LE_PSOLA_DWIN + LE_PSOLA_DWIN / 2 + 1 + LE_PSOLA_RAW <=
                   LE_PV_SCRATCH,
               "PSOLA's detection windows fit the octaver scratch");

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

/* The second voice's regions in the octaver scratch (LE_PV_SCRATCH, after
 * the frame arrays listed at le_pv_stage_analyse): its synthesis spectrum,
 * and its running phases, which persist from frame to frame (#1464). */
#define LE_PV_S_RE2(o) ((o)->scratch + LE_PV_N + 5 * LE_PV_BINS)
#define LE_PV_S_IM2(o) ((o)->scratch + LE_PV_N + 6 * LE_PV_BINS)
#define LE_PV_S_PHASE2(o) ((o)->scratch + LE_PV_N + 7 * LE_PV_BINS)

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
  if (o->scratch != NULL) {
    le_psola_pass* ps = le_ps(o);
    ps->phase = 0;
    ps->credit = 0;
    ps->hops = 0;
  }
  o->frame_ratio = 1.0f;
  o->frame_formants_move = 0;
  o->frame_ratio2 = 1.0f;
  o->frame_level1 = 1.0f;
  o->frame_level2 = 0.0f;
  if (o->last_phase != NULL) memset(o->last_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->sum_phase != NULL) memset(o->sum_phase, 0, sizeof(float) * LE_PV_BINS);
  if (o->scratch != NULL) {
    memset(LE_PV_S_PHASE2(o), 0, sizeof(float) * LE_PV_BINS);
  }
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
 * le_pv_fft (fft.h). On the console a stereo frame cost ~170 us in one
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

/* Stage 2: move each peak region by the ratio read at analysis, advance each
 * moved peak's synthesis phase (2*pi*freq*HOP/N a hop), lock the bins around
 * it to it, and rebuild the half spectrum. Holding the formants, each bin is
 * whitened (mag/env) and the envelope re-applied at the DESTINATION bin, so
 * the formants stay fixed in frequency; moving them, the magnitude goes over
 * as it is, envelope and all. [drop_dc] also drops a region whose peak
 * lands below bin 1 (the second voice's, two octaves down; the first voice
 * keeps the shipped octaver's behaviour). */
static void le_pv_shift_into(le_octaver_state* o, float ratio, float* sum_phase,
                             float* re, float* im, int drop_dc) {
  const float* mag = LE_PV_S_MAG(o);
  const float* freq = LE_PV_S_FREQ(o);
  const float* env = LE_PV_S_ENV(o);
  const float* in_phase = o->last_phase; /* this frame's, from the analysis */
  const float advance = 2.0f * LE_PI * (float)LE_PV_HOP / (float)LE_PV_N;
  float syn_mag[LE_PV_BINS];
  float syn_phase[LE_PV_BINS];
  float syn_best[LE_PV_BINS];
  for (int k = 0; k < LE_PV_BINS; ++k) {
    syn_mag[k] = 0.0f;
    syn_phase[k] = sum_phase[k];
    syn_best[k] = -1.0f;
  }
  /* Peak-region shifting with identity phase locking (Laroche and Dolson,
   * 1999): each spectral peak moves to its shifted frequency carrying the
   * bins around it, and those bins keep their phases relative to the peak.
   * A partial keeps its main lobe's shape, and with it its level, at any
   * ratio; scaling each bin's index instead spread an up-shifted lobe over
   * every other bin and lost up to 13 dB at a fifth. A region runs from
   * halfway after the previous peak to halfway before the next; where two
   * regions land on one bin, the louder source sets its phase. */
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
    /* The peak's phase at its new bin: last frame's there, advanced by the
     * shifted frequency. */
    const float peak_phase = sum_phase[to] + advance * freq[peak] * ratio;
    for (int k = start; k < end; ++k) {
      const int j = k + shift;
      if (j < 0 || j >= LE_PV_BINS) continue;
      syn_mag[j] += o->frame_formants_move
                        ? mag[k]
                        : mag[k] / (env[k] + 1e-9f) * env[j];
      if (mag[k] > syn_best[j]) {
        syn_best[j] = mag[k];
        syn_phase[j] =
            le_wrap_pi(peak_phase + (in_phase[k] - in_phase[peak]));
      }
    }
    start = end;
  }
  for (int b = 0; b < LE_PV_BINS; ++b) {
    sum_phase[b] = syn_phase[b];
    re[b] = syn_mag[b] * cosf(syn_phase[b]);
    im[b] = syn_mag[b] * sinf(syn_phase[b]);
  }
}

static void le_pv_stage_shift(le_octaver_state* o) {
  le_pv_shift_into(o, o->frame_ratio, o->sum_phase, LE_PV_S_RE(o),
                   LE_PV_S_IM(o), 0);
}

/* The second voice's shift (#1464): the same analysis at its own ratio,
 * into its own spectrum and phases. */
static void le_pv_stage_shift2(le_octaver_state* o) {
  le_pv_shift_into(o, o->frame_ratio2, LE_PV_S_PHASE2(o), LE_PV_S_RE2(o),
                   LE_PV_S_IM2(o), o->frame_ratio2 < 1.0f);
}

/* Stage 3: inverse transform, synthesis-window, and overlap-add from the
 * accumulator element this tick emits (the Hann x Hann windows at 4x overlap
 * sum to 1.5: divide for unity). */
static void le_pv_stage_synth(le_octaver_state* o) {
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
  le_rfft_inv(&le_pv_fft, re, im, win);
  const float norm = level / 1.5f;
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
                        float ratio, int formants_move, float ratio2,
                        float level1, float level2) {
  if (o->out == NULL || o->scratch == NULL) return 0.0f;
  switch (o->hop_count) {
    case 0:
      le_pv_stage_analyse(o, fifo, head, cap);
      o->frame_ratio = ratio;
      o->frame_formants_move = formants_move;
      o->frame_ratio2 = ratio2;
      o->frame_level1 = level1;
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
      if (o->analysed && !o->frame_formants_move) le_pv_stage_envelope(o);
      if (o->analysed && o->frame_level2 > 0.0f) le_pv_stage_shift2(o);
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

/* YIN pitch detection (see engine_internal.h). Plain autocorrelation
 * peak-picking is prone to octave errors — a sub/multiple of the true period
 * correlates nearly as well — and a mis-spaced grain wrecks both pitch and
 * formants, so the modest extra cost of YIN's cumulative-mean normalization
 * is worth it for the PSOLA octaver. */

/* ---- Resumable YIN pass (see le_yin_pass in engine_private.h) --------------
 *
 * The three steps below ARE le_psola_detect_band, split at the two points a
 * caller can pause at: before the difference function and after it. The
 * tuner and the PSOLA octaver run le_yin_step a slice at a time across
 * callbacks. The
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

int le_refine_begin(le_lag_refine* r, float coarse, int span, int n) {
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

int le_refine_step(le_lag_refine* r, const float* x, long budget) {
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

float le_refine_finish(const le_lag_refine* r, float coarse) {
  if (r->best == 0 || r->best == r->hi - r->lo) return coarse;
  const float s0 = r->d[r->best - 1];
  const float s1 = r->d[r->best];
  const float s2 = r->d[r->best + 1];
  const float denom = s0 + s2 - 2.0f * s1;
  float refined = (float)(r->lo + r->best);
  if (fabsf(denom) > 1e-9f) refined += 0.5f * (s0 - s2) / denom;
  return refined;
}

int le_psola_detect_band(const float* x, int n, int sr, int min_hz, int max_hz,
                         float* out_period, float* out_voiced) {
  *out_period = 0.0f;
  *out_voiced = 0.0f;
  float dp[LE_PSOLA_MAXLAG + 1];
  const int dp_cap = (int)(sizeof(dp) / sizeof(dp[0]));
  le_yin_pass p;
  if (!le_yin_begin(&p, x, n, sr, min_hz, max_hz, dp, dp_cap)) return 0;
  /* Unbounded: a one-shot caller (the detector's tests, its oracle) wants
   * the answer now. A negative budget always completes, so the check can only
   * ever pass -- it is here so the one-shot path states the precondition
   * le_yin_finish relies on rather than assuming it. */
  if (!le_yin_step(&p, -1)) return 0;
  return le_yin_finish(&p, out_period, out_voiced);
}

/* ---- PSOLA's sliced pitch detection (#913) ---------------------------------
 *
 * A whole YIN pass over the old 1600-sample window was ~640k iterations in one
 * callback every hop: about 1.1 ms on the console, over the 667 us deadline
 * of a 64-frame period at 96 kHz. The pass now runs on a decimated window
 * (a boxcar of D samples is the decimator and its own anti-alias filter, as
 * the tuner's), so it searches 60 Hz at every rate for about a quarter of the
 * work, then refines at the device rate around the coarse lag (le_refine_*),
 * and both are spread over the hop: each tick adds LE_PSOLA_WORK_PER_TICK to
 * a credit the pass spends, and a lag that overshoots it leaves a debt the
 * next ticks pay, so the pass averages exactly that much a tick. The
 * decimated window is frozen into the scratch when the pass starts, and the
 * device-rate one when the refinement starts (the 1 s ring still holds it),
 * so the moving ring cannot change either under the pass. The result lands
 * within the hop it was started in, a hop at most after the one-shot pass's
 * would have: the period and the voicing it feeds are smoothed over several
 * hops anyway. */
#define LE_PS_WIN(o) ((o)->scratch)
#define LE_PS_DP(o) ((o)->scratch + LE_PSOLA_DWIN)
#define LE_PS_RAW(o) ((o)->scratch + LE_PSOLA_DWIN + LE_PSOLA_DWIN / 2 + 1)
_Static_assert(LE_PSOLA_DMAX <= LE_REFINE_SPAN_MAX,
               "PSOLA's refinement span fits le_lag_refine");

/* The decimation for a [sr] Hz input: ceil(sr / LE_PSOLA_RATE), 1 to
 * LE_PSOLA_DMAX, so the analysis rate is at most LE_PSOLA_RATE and its
 * window holds two periods of LE_PSOLA_MIN_HZ (up to 192 kHz). */
static int le_psola_decim(int sr) {
  int d = (sr + LE_PSOLA_RATE - 1) / LE_PSOLA_RATE;
  if (d < 1) d = 1;
  if (d > LE_PSOLA_DMAX) d = LE_PSOLA_DMAX;
  return d;
}

/* Feeds a finished detection into the smoothed voicing and period, as the
 * one-shot pass did: the voicing follows every result, the period only a
 * pitched one (it holds through gaps). */
static void le_psola_pass_apply(le_octaver_state* o, float period,
                                float voiced) {
  le_ps(o)->phase = 0;
  o->voiced += 0.35f * (voiced - o->voiced); /* chatter-free soft gate */
  if (period > 0.0f) {
    o->period =
        o->period <= 0.0f ? period : o->period + 0.5f * (period - o->period);
  }
}

/* Hops between pass starts at [sr] Hz: max(1, D / 2), so a pass starts about
 * every 5 ms at every rate. */
static int le_psola_every(int sr) {
  const int every = le_psola_decim(sr) / 2;
  return every < 1 ? 1 : every;
}

/* Starts a detection over the input ending at FIFO index [end]: freezes the
 * decimated window into the scratch and opens the coarse pass, charging the
 * decimation to the pass's credit. Any pass still in flight is dropped. A
 * silent window settles at once as unvoiced. */
static void le_psola_pass_begin(le_octaver_state* o, const float* fifo,
                                int end, int cap) {
  le_psola_pass* ps = le_ps(o);
  const int sr = cap; /* the fx ring is 1 s long, so cap == sample rate */
  const int d = le_psola_decim(sr);
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
  ps->decim = d;
  ps->end = end;
  ps->credit -= LE_PSOLA_DWIN * d;
  if (!le_yin_begin(&ps->yin, win, LE_PSOLA_DWIN, sr / d, LE_PSOLA_MIN_HZ,
                    LE_PSOLA_MAX_HZ, LE_PS_DP(o), LE_PSOLA_DWIN / 2 + 1)) {
    le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  ps->phase = 1;
}

/* Hands the finished coarse pass to the refinement, freezing the device-rate
 * window it walks, or applies the coarse period as it is when refining would
 * not change what plays: no decimation, a period too long for two of it to
 * fit the device-rate window, or a frame under the voicing gate (fx_octaver's
 * dry fallback takes it whatever its period). */
static void le_psola_coarse_done(le_octaver_state* o, const float* fifo,
                                 int cap) {
  le_psola_pass* ps = le_ps(o);
  float period = 0.0f;
  le_yin_finish(&ps->yin, &period, &ps->conf);
  if (period <= 0.0f) {
    le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  const int d = ps->decim;
  ps->coarse = period * (float)d;
  if (d == 1 || ps->conf < 0.3f ||
      !le_refine_begin(&ps->ref, ps->coarse, d, LE_PSOLA_RAW)) {
    le_psola_pass_apply(o, ps->coarse, ps->conf);
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

/* One tick of detection: starts a pass on its hop, adds the tick's work to
 * the credit and, while it is positive, spends it on lags (a lag is never
 * split, so the last one may overshoot into a debt), carrying from the coarse
 * pass into the refinement, and applies the result once the refinement is
 * in. [hop] is set on the tick a PSOLA hop begins. */
static void le_psola_pass_tick(le_octaver_state* o, const float* fifo, int end,
                               int cap, int hop) {
  le_psola_pass* ps = le_ps(o);
  const int every = le_psola_every(cap);
  if (hop && ++ps->hops >= every) {
    ps->hops = 0;
    le_psola_pass_begin(o, fifo, end, cap);
  }
  const int32_t work = LE_PSOLA_WORK_PER_TICK / every;
  ps->credit += work;
  if (ps->credit > work) ps->credit = work; /* no banking while idle */
  while (ps->credit > 0 && ps->phase != 0) {
    if (ps->phase == 1) {
      const int32_t was = ps->yin.tau;
      const int done = le_yin_step(&ps->yin, ps->credit);
      ps->credit -= (ps->yin.tau - was) * ps->yin.integ;
      if (done) le_psola_coarse_done(o, fifo, cap);
      continue;
    }
    const int32_t was = ps->ref.tau;
    const int done = le_refine_step(&ps->ref, LE_PS_RAW(o), ps->credit);
    ps->credit -= (ps->ref.tau - was) * ps->ref.integ;
    if (done) {
      le_psola_pass_apply(o, le_refine_finish(&ps->ref, ps->coarse), ps->conf);
    }
  }
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

  /* 2. Periodic pitch analysis: a detection starts every hop over the input
   *    ending `lag` back, and runs a slice every tick (le_psola_pass_*). */
  const int hop = --o->hop_count <= 0;
  if (hop) o->hop_count = LE_PSOLA_AHOP;
  le_psola_pass_tick(o, fifo, head - lag, cap, hop);

  /* 3. Synthesis: marks recede from the head one sample per tick; at each
   *    synthesis mark deposit a Hann grain whose source snaps to the nearest
   *    analysis mark, so the grain spacing (pitch) changes by `ratio` while the
   *    grain shape (formant envelope) does not. */
  o->in_epoch += 1;
  if (--o->out_epoch <= 0) {
    float pf = o->period; /* sub-sample period: sets the grain spacing (pitch) */
    if (pf < 2.0f) pf = 2.0f;
    if (pf > (float)(sr / LE_PSOLA_MIN_HZ)) pf = (float)(sr / LE_PSOLA_MIN_HZ);
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
    /* Keep the grain read causal: a mark too near the head moves on by whole
     * periods, so it stays on the period grid (a long period at a high rate
     * can snap it under th). */
    while (o->in_epoch < th) o->in_epoch += pi;
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

/* Octave 2's trims: up, where the capture's sits (-0.7 dB against the dry,
 * level with Octave 1; the vocoder alone gives -3.6 at +24); down, level
 * with Octave 1 down (no capture; the vocoder alone gives 0.0 at -24). */
#define LE_DOCT_UP2_LEVEL 1.396f   /* +2.9 dB */
#define LE_DOCT_DOWN2_LEVEL 0.841f /* -1.5 dB */

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
  /* The Dual Octaver's shift is a switch (p6): it changes in the gain dip
   * below, never through a glide (which would sweep two octaves). */
  const int dual = p[6] >= 0.5f;
  if (!dual) o->sm_shift += sc * (p[0] - o->sm_shift);
  o->sm_tone += sc * (p[1] - o->sm_tone);
  o->sm_mix += sc * (p[2] - o->sm_mix);
  o->sm_level += sc * ((1.0f - p[5]) - o->sm_level);

  /* Mode switch (D1): equal-power gain dip, ~15 ms per leg — fade the wet out,
   * reset the DSP runtime at the bottom, then fade back in on the new mode. */
  const int requested = p[3] >= 0.5f ? 1 : 0;
  const float xstep = 1.0f / (0.015f * (float)cap);
  const int shift_jump = dual && o->sm_shift != p[0];
  if (requested != o->cur_mode || shift_jump) {
    o->xfade -= xstep;
    if (o->xfade <= 0.0f) {
      o->xfade = 0.0f;
      /* Keep the hop schedule across the switch: the new mode's heavy tick
       * lands where the old mode's next one would have. Re-seeding from the
       * phase here would anchor it to this instant, ~15 ms after the reset,
       * and move it off the instance's quarter. */
      const int ticks = le_oct_ticks_to_work(o);
      o->cur_mode = requested;
      o->sm_shift = dual ? p[0] : o->sm_shift;
      le_pv_reset_runtime(fx, slot, chan, ticks);
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
  const float wet = o->cur_mode == 0
                        ? le_pv_tick(o, buf, head, cap, ratio, p[4] >= 0.5f,
                                     ratio * ratio, 1.0f - p[5], level2)
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
/* The Mode delay's line (defined with its kernel). */
static void le_mdly_reset(struct le_fx_line* line);
static void le_mdly_clear(struct le_fx_line* line);
static int32_t le_mdly_frames(const struct le_fx_line* line);
/* The Amp+Cab's instance (defined with its kernel). */
static void le_amp_reset(struct le_fx_amp* a);

void le_fx_entry_reset(le_fx_state* fx, int slot) {
  struct le_fx_line* line =
      atomic_load_explicit(&fx->line[slot], memory_order_acquire);
  if (line != NULL) le_mdly_reset(line);
  struct le_fx_amp* amp =
      atomic_load_explicit(&fx->amp[slot], memory_order_acquire);
  if (amp != NULL) le_amp_reset(amp);
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
    o->sm_level = 1.0f;
    o->ep_mix = -1.0f; /* the equal-power gains are computed at first use */
    o->cur_mode = 0;  /* phase vocoder */
    o->xfade = 1.0f;  /* steady (no gain dip) */
    le_pv_reset_runtime(fx, slot, chan, le_oct_seeded_ticks(fx, slot));
  }
  le_fx_clear_reverb(fx, slot);
  memset(&fx->slice[slot], 0, sizeof(fx->slice[slot]));
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
    o->sm_level = 1.0f - params[5];
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
  /* The Mode delay's line reads nothing older than its clear: no zeroing
   * of its seconds of ring on the audio thread. */
  struct le_fx_line* line =
      atomic_load_explicit(&fx->line[slot], memory_order_acquire);
  if (line != NULL) le_mdly_clear(line);
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
  fx->path_primed[slot] = 0;
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
    o->analysed = 0; /* no frame outlives the scratch it is in */
  }
}

void le_fx_free_delay(le_fx_state* fx, int slot) {
  le_rt_free(fx->delay[slot][0]);
  fx->delay[slot][0] = NULL;
  le_rt_free(fx->delay[slot][1]);
  fx->delay[slot][1] = NULL;
  le_rt_free(atomic_load_explicit(&fx->line[slot], memory_order_relaxed));
  atomic_store_explicit(&fx->line[slot], NULL, memory_order_relaxed);
  le_rt_free(atomic_load_explicit(&fx->amp[slot], memory_order_relaxed));
  atomic_store_explicit(&fx->amp[slot], NULL, memory_order_relaxed);
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
/* The octaver's kernel on its eight settings (le_fx_octaver_settings):
 * shift, tone, mix, mode, formants, the wet voice's cut (0: none), 1 for
 * the Dual Octaver (an equal-power mix, a switched shift, and a second
 * voice two octaves out) or 0, and that second voice's level (0: none) —
 * so a zeroed tail is the plain octaver. */
static void fx_octaver_run(le_fx_state* fx, int slot, int cap, float* l,
                           float* r, const float* q) {
  *l = fx_octaver(fx, slot, 0, cap, *l, q);
  *r = fx_octaver(fx, slot, 1, cap, *r, q);
}

static void fx_octaver_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  (void)sr;
  const float q[8] = {p[0], p[1], p[2], p[3], p[4], 0.0f, 0.0f, 0.0f};
  fx_octaver_run(fx, slot, cap, l, r, q);
}

/* The Whammy's taper: the pedal's share of the range, pedal^1.39. The
 * captures put 50 % at 4.57 of the 12 semitones (-4.57 / -4.52 down, +4.61 /
 * +4.57 up), and 0 and 100 % at the ends (#891). The earlier 1 kHz pass read
 * 99.8 % as -11.8 semitones, where the taper gives -11.97; one point, read
 * off a single tone, so the fit keeps the three-point sweep. */
#define LE_WHAMMY_TAPER 1.39f

/* The Whammy's shift as the octaver's shift setting: -24 + 48 v semitones
 * for range x pedal^taper. */
static float le_whammy_shift(const float* p) {
  const float pedal = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float range = p[1] >= 0.5f ? 12.0f : -12.0f;
  return 0.5f + range * powf(pedal, LE_WHAMMY_TAPER) / 48.0f;
}

int le_fx_type_hops(int32_t type) {
  return type == LE_FX_OCTAVER || type == LE_FX_WHAMMY ||
         type == LE_FX_DUAL_OCTAVER;
}

/* The Dual Octaver's first voice (#891, s5/4-7): one octave down with high
 * mode off (1 kHz to 510 Hz) and up with it on (2 kHz), at Octave 1 Vol
 * times a trim that puts the phase vocoder's voice where the capture's
 * sits against the dry (-1.5 dB down, -0.6 dB up; the vocoder alone gives
 * -1.5 and -0.4 on a 1 kHz tone); Octave Mix an equal-power crossfade (the
 * capture's 50 % puts dry and wet each 3 dB down). */
#define LE_DOCT_DOWN_LEVEL 1.0f
#define LE_DOCT_UP_LEVEL 0.977f /* -0.2 dB */

static void le_doct_settings(const float* p, float* out) {
  const int high = p[0] >= 0.5f;
  const float vol = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  out[0] = high ? 0.75f : 0.25f; /* +12 or -12 of the octaver's +-24 */
  out[1] = 1.0f;                 /* the tone open */
  out[2] = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  out[3] = 0.0f; /* the phase vocoder */
  out[4] = 1.0f; /* the formants move with the pitch */
  out[5] = 1.0f - vol * (high ? LE_DOCT_UP_LEVEL : LE_DOCT_DOWN_LEVEL);
  out[6] = 1.0f; /* the Dual Octaver: equal power, a switched shift */
  /* Octave 2's level (#1464): its voice, two octaves up in high mode
   * (measured, s5/6) or down without it (inferred: no capture), and its
   * trim follow Octave 1's shift in the kernel. */
  out[7] = p[3] < 0.0f ? 0.0f : p[3] > 1.0f ? 1.0f : p[3];
}

void le_fx_octaver_settings(int32_t type, const float* params, float* out) {
  for (int k = 0; k < LE_FX_PARAMS; ++k) out[k] = params[k];
  out[5] = 0.0f; /* the wet voice's cut: none */
  out[6] = 0.0f; /* the plain octaver: a linear mix, a gliding shift */
  out[7] = 0.0f; /* no second voice */
  if (type == LE_FX_DUAL_OCTAVER) {
    le_doct_settings(params, out);
    return;
  }
  if (type != LE_FX_WHAMMY) return;
  out[0] = le_whammy_shift(params);
  out[1] = 1.0f;              /* the tone open */
  out[2] = 1.0f;              /* fully wet */
  out[3] = 0.0f;              /* the phase vocoder */
  out[4] = 1.0f;              /* the formants move with the pitch */
}

static void fx_whammy_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  (void)sr;
  /* The eight settings the octaver's kernel reads (le_fx_octaver_settings). */
  const float q[8] = {le_whammy_shift(p), 1.0f, 1.0f, 0.0f, 1.0f,
                      0.0f, 0.0f, 0.0f};
  fx_octaver_run(fx, slot, cap, l, r, q);
}

static void fx_dual_octaver_process(le_fx_state* fx, int slot, int sr,
                                    int cap, float* l, float* r,
                                    const float* p) {
  (void)sr;
  float q[8];
  le_doct_settings(p, q);
  fx_octaver_run(fx, slot, cap, l, r, q);
}
/* The beat (quarter notes) of the frame [fx] is processing, the quarter
 * notes a frame advances and the time signature (le_fx_tempo, #887 part
 * 10). A state with no tempo runs at 120 BPM in 4/4 from its clock 0. */
static inline double le_fx_beat_now(const le_fx_state* fx, int sr, float* qpf,
                                    int32_t* num, int32_t* den) {
  const uint32_t now = le_fx_now(fx);
  const le_fx_tempo* t = fx->tempo;
  if (t == NULL) {
    *qpf = (float)(2.0 / (double)(sr > 0 ? sr : 48000));
    *num = 4;
    *den = 4;
    return (double)now * (double)*qpf;
  }
  *qpf = t->qpf;
  *num = t->num > 0 ? t->num : 4;
  *den = t->den > 0 ? t->den : 4;
  return t->anchor_beat + (double)(uint32_t)(now - t->anchor_clock) *
                              (double)t->qpf;
}

/* ---- Pumper (LE_FX_PUMPER, #887 part 10) ----
 *
 * gain = 1 - a(depth) e(phase), phase 0 on the beat of the note value
 * (#891, docs/plan/2026-10-23-looperx-gaps-measured.md). */

/* Each rate position's period in quarter notes; Bar is the bar's (-1). The
 * order is the binary's 11-entry note-value table (Bar, 1/2, 1/2T, ...,
 * 1/32T), which the presets' 11-step grid matches; the capture confirmed
 * Bar, 1/2, 1/4, 1/8 and 1/16 (#891). */
static const double LE_PUMP_PERIOD[11] = {
    -1.0, 2.0, 4.0 / 3.0, 1.0, 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.25, 1.0 / 6.0,
    0.125, 1.0 / 12.0};

/* e(phase) every 1/20 of the period from the beat, as measured; 0 from three
 * quarters on. */
static const float LE_PUMP_SHAPE[16] = {
    1.000f, 0.994f, 0.984f, 0.970f, 0.948f, 0.918f, 0.876f, 0.820f,
    0.746f, 0.654f, 0.544f, 0.418f, 0.284f, 0.153f, 0.045f, 0.0f};

/* The dip in dB against depth, as measured at 30, 70 and 100 % (a = 0.50,
 * 0.901, 0.990), linear between. */
static const float LE_PUMP_DIP_AT[4] = {0.0f, 0.3f, 0.7f, 1.0f};
static const float LE_PUMP_DIP_DB[4] = {0.0f, 6.0206f, 20.0877f, 40.0f};

/* The duck is smoothed with this time constant: the measured shape is at
 * full depth on the beat, and a gain step is a click (#813), whether at the
 * beat or where an anchor moves the phase (a loop top that is not a whole
 * number of periods). */
#define LE_PUMP_SMOOTH_S 0.00025

static float le_pump_shape(double phase) {
  const double x = phase * 20.0;
  if (x >= 15.0) return 0.0f;
  const int i = (int)x;
  const float f = (float)(x - (double)i);
  return LE_PUMP_SHAPE[i] + (LE_PUMP_SHAPE[i + 1] - LE_PUMP_SHAPE[i]) * f;
}

static float le_pump_depth(float d) {
  if (!(d > 0.0f)) return 0.0f;
  if (d >= 1.0f) d = 1.0f;
  int i = 1;
  while (i < 3 && d > LE_PUMP_DIP_AT[i]) ++i;
  const float f = (d - LE_PUMP_DIP_AT[i - 1]) /
                  (LE_PUMP_DIP_AT[i] - LE_PUMP_DIP_AT[i - 1]);
  const float db =
      LE_PUMP_DIP_DB[i - 1] + (LE_PUMP_DIP_DB[i] - LE_PUMP_DIP_DB[i - 1]) * f;
  return 1.0f - powf(10.0f, -db / 20.0f);
}


/* The measured shape at the frame [fx] is processing, for the rate
 * setting [rate_setting]. */
static float le_pump_shape_now(const le_fx_state* fx, int sr,
                               float rate_setting) {
  float qpf;
  int32_t num, den;
  const double beat = le_fx_beat_now(fx, sr, &qpf, &num, &den);
  int pos = (int)(rate_setting * 10.0f + 0.5f);
  if (pos < 0) pos = 0;
  if (pos > 10) pos = 10;
  const double period = pos == 0 ? (double)num * 4.0 / (double)den
                                 : LE_PUMP_PERIOD[pos];
  double into = fmod(beat, period); /* quarter notes since the beat */
  if (into < 0.0) into += period;
  return le_pump_shape(into / period);
}

void le_fx_pumper_seed_settled(le_fx_state* fx, int slot, const float* params,
                               int sr) {
  if (fx == NULL || params == NULL || slot < 0 || slot >= LE_FX_MAX) return;
  fx->lfo[slot][0] = le_pump_depth(params[1]);
  fx->lfo[slot][1] = fx->lfo[slot][0];
  fx->fx_lp[slot][0] = params[1];
  fx->fx_lp[slot][1] =
      fx->lfo[slot][0] * le_pump_shape_now(fx, sr > 0 ? sr : 48000, params[0]);
}

static void fx_pumper_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  (void)cap;
  const int32_t rate = sr > 0 ? sr : 48000;
  const float e = le_pump_shape_now(fx, rate, p[0]);
  /* The depth glides (about 10 ms), so a moving control never steps. Its
   * target is worked out only when the setting moves: lfo[slot][1] holds
   * it for the setting in fx_lp[slot][0] (both 0 after a reset, which is
   * a(0)). */
  if (p[1] != fx->fx_lp[slot][0]) {
    fx->fx_lp[slot][0] = p[1];
    fx->lfo[slot][1] = le_pump_depth(p[1]);
  }
  float* a = &fx->lfo[slot][0];
  *a += (fx->lfo[slot][1] - *a) * (100.0f / (float)rate);
  /* The duck itself, smoothed (fx_lp[slot][1], 0 after a reset). */
  float* duck = &fx->fx_lp[slot][1];
  *duck += (*a * e - *duck) /
           (1.0f + (float)(LE_PUMP_SMOOTH_S * (double)rate));
  const float g = 1.0f - *duck;
  *l *= g;
  *r *= g;
}

/* ---- Slicer (LE_FX_SLICER, #887 part 10) ----
 *
 * Measured (#891, the s4 captures at 1/16 and 120 BPM): a capital letter is
 * one step and a lower-case one half a step; a letter's first slice plays
 * the live input and each later one replays it from its start (AABB
 * replays A at a 125 ms delay; ABcccc plays A, B, then c live and replays
 * that half step three times); _ rests for a step (the capture reads 48 to
 * 54 dB down; this one is silent); a slice ends with a 4 ms fade and starts
 * without one. < plays the step before backwards (the factory "Reverse"
 * preset is <<<<). The Fd patterns are not modelled.
 *
 * Each slice fixes where it reads when it starts (a distance back, or the
 * point it mirrors about), so a tempo change under a slice does not move
 * it. A new pattern or step waits for the slice playing to end. A slice
 * cut short (a beat that jumps) fades out over the 4 ms while the next one
 * fades in. The source is the slot's
 * delay ring: a slice whose source is not all within it is silent. With
 * the 1 s ring the quarter-step factory presets (a one-step replay) hold
 * above 60 BPM, and Reverse (two 1/16 steps back) above 30 BPM. */

/* The patterns, in the choice's order (the Looper X's SlicerPattern table,
 * read from its binary; docs/plan/2026-10-20-looperx-derived-tables.md);
 * NULL for one not modelled. */
static const char* const LE_SLICE_PATTERNS[20] = {
    "AABB", "ABCC",   "AACD",   "ABC_",   "A_C_", "A_CC", "A___C___",
    "ABcccc", "AAccdd", "AB__dd", "AA__dd", "ABC<", "AB_<", "AA_<",
    "A_B_C<", "AB<<", "<<<<",  NULL,     NULL,   NULL};

/* The pattern position a stored choice value names, 0..19. */
static int le_slice_index(float v) {
  const int i = (int)(v * 19.0f + 0.5f);
  return i < 0 ? 0 : i > 19 ? 19 : i;
}

/* The pattern a stored choice value names; NULL when not modelled. */
static const char* le_slice_pattern(float v) {
  return LE_SLICE_PATTERNS[le_slice_index(v)];
}

/* Each step position's length in quarter notes: 1/4, 1/4T, 1/8, 1/8T,
 * 1/16, 1/16T, 1/32, 1/32T, 1/64. */
static const double LE_SLICE_STEP[9] = {1.0,       2.0 / 3.0, 0.5,
                                        1.0 / 3.0, 0.25,      1.0 / 6.0,
                                        0.125,     1.0 / 12.0, 0.0625};

/* The slice end's fade (#891: about 4 ms). */
#define LE_SLICE_FADE_S 0.004

/* A token's length in half steps: lower case is half a step. */
static int le_slice_len(char c) { return c >= 'a' && c <= 'z' ? 1 : 2; }

static int le_slice_cycle(const char* pat) {
  int n = 0;
  for (const char* c = pat; *c; ++c) n += le_slice_len(*c);
  return n;
}

/* The token pattern [pat] plays [half] half steps into its cycle: its
 * index, its start, its length and where its letter first sounds (the
 * last three in half steps). */
static char le_slice_token(const char* pat, double half, int* index,
                           int* start, int* len, int* first) {
  int at = 0;
  for (const char* c = pat; *c; ++c) {
    const int n = le_slice_len(*c);
    if (half < (double)(at + n) || c[1] == '\0') {
      *index = (int)(c - pat);
      *start = at;
      *len = n;
      *first = at;
      int f = 0;
      for (const char* d = pat; d < c; ++d) {
        if ((*d | 0x20) == (*c | 0x20) && *c != '_' && *c != '<') {
          *first = f;
          break;
        }
        f += le_slice_len(*d);
      }
      return *c;
    }
    at += n;
  }
  *index = *start = *len = *first = 0;
  return '_';
}

/* What voice [v] reads from [ring] with the newest frame at [pos]. */
static float le_slice_read(const float* ring, int cap, int pos,
                           const le_fx_slice_voice* v) {
  int back;
  if (v->mode == LE_SLICE_BACK) {
    back = v->arg;
  } else if (v->mode == LE_SLICE_MIRROR) {
    int n = pos - v->arg;
    if (n < 0) n += cap;
    if (n > v->len) n = v->len; /* never past the length it was latched for */
    back = 2 * n;
  } else {
    return 0.0f;
  }
  if (back < 0 || back >= cap) return 0.0f;
  int at = pos - back;
  if (at < 0) at += cap;
  return ring[at];
}

/* Ends slot [st]'s slice early: it carries on as a voice fading out at
 * the 4 ms rate ([fade] frames from full), in whichever of the two fading
 * voices is free or quieter (a third voice, quieter than both, is
 * dropped: with the gains summing to at most 1, it is at most a third). */
static void le_slice_cut(le_fx_slice_state* st, double fade) {
  if (st->cur.mode != LE_SLICE_SILENT && st->cur.gain > 0.0f) {
    const int k = st->out[0].gain <= st->out[1].gain ? 0 : 1;
    if (st->cur.gain > st->out[k].gain) {
      st->out[k] = st->cur;
      st->out[k].step = (float)(1.0 / fade);
    }
  }
  st->cur.mode = LE_SLICE_SILENT;
  st->cur.gain = 0.0f;
  st->id = 0.0;
}

/* The fading voices' gains together, now or ([next]) after this frame's
 * step. */
static float le_slice_fading(const le_fx_slice_state* st, int next) {
  float sum = 0.0f;
  for (int k = 0; k < 2; ++k) {
    const float g = st->out[k].gain - (next ? st->out[k].step : 0.0f);
    if (g > 0.0f) sum += g;
  }
  return sum;
}

static void fx_slicer_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  float* ring[2] = {fx->delay[slot][0], fx->delay[slot][1]};
  if (ring[0] == NULL || ring[1] == NULL || cap <= 1) return;
  const int32_t rate = sr > 0 ? sr : 48000;
  const float in[2] = {*l, *r};
  const int pos = fx->delay_pos[slot][0];
  ring[0][pos] = in[0];
  ring[1][pos] = in[1];
  fx->delay_pos[slot][0] = pos + 1 >= cap ? 0 : pos + 1;

  le_fx_slice_state* st = &fx->slice[slot];
  const double fade4 = LE_SLICE_FADE_S * (double)rate;
  const float mix_to = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  const int fresh = !st->primed;
  if (fresh) {
    st->primed = 1;
    st->mix = mix_to;
  }
  /* Mix glides over about 10 ms, so a moving control never steps. */
  const float mix_next =
      st->mix + (mix_to - st->mix) * (float)(1.0 / (0.010 * (double)rate));
  /* Landing once a step no longer moves it. */
  st->mix = mix_next == st->mix ? mix_to : mix_next;
  /* A new pattern or step waits for the slice playing to end: a setting
   * change never cuts a slice. */
  int si = (int)(p[1] * 8.0f + 0.5f);
  si = si < 0 ? 0 : si > 8 ? 8 : si;
  if (st->cur.gain <= 0.0f) {
    st->patt = le_slice_index(p[0]);
    st->step = si;
  }
  const char* pat = LE_SLICE_PATTERNS[st->patt];
  float qpf;
  int32_t num, den;
  const double beat = le_fx_beat_now(fx, rate, &qpf, &num, &den);
  /* Not modelled (the Fd patterns) or no usable tempo: the input passes,
   * crossfaded to over the 4 ms. */
  const int passes = pat == NULL || !(qpf > 0.0f) || !isfinite(beat);
  if (passes) {
    le_slice_cut(st, fade4);
  } else if (beat < st->last_beat) {
    le_slice_cut(st, fade4); /* the beat went back: a new slice */
  }
  st->last_beat = passes ? 0.0 : beat;
  if (fresh) st->pass = passes ? 1.0f : 0.0f;

  if (!passes) {
    const double half_q = LE_SLICE_STEP[st->step] * 0.5;
    const double cycle_q = (double)le_slice_cycle(pat) * half_q;
    const double cycles = floor(beat / cycle_q);
    const double pos_q = beat - cycles * cycle_q;
    int index, start, len, first;
    const char tok =
        le_slice_token(pat, pos_q / half_q, &index, &start, &len, &first);
    const double into = pos_q - (double)start * half_q; /* quarter notes */
    const double fpq = 1.0 / (double)qpf;              /* frames a quarter */
    const double len_f = (double)len * half_q * fpq;    /* the slice */
    const double fade_f = fmin(fade4, 0.5 * len_f);
    /* Which slice this is (0 is none): its cycle, token and settings. */
    const double id =
        1.0 + ((cycles * 32.0 + (double)index) * 20.0 + (double)st->patt) *
                  9.0 +
        (double)st->step;
    if (id != st->id) {
      le_fx_slice_voice v = {LE_SLICE_SILENT, 0, 0, 1.0f, 0.0f};
      if (tok == '<') {
        /* The step before, backwards: at n frames into the slice, 2n
         * back, so the whole slice needs twice its length of ring. */
        if (2.0 * len_f < (double)(cap - 1)) {
          const long n0 = lround(into * fpq);
          long e = (long)pos - n0;
          while (e < 0) e += cap;
          v.mode = LE_SLICE_MIRROR;
          v.arg = (int32_t)e;
          v.len = (int32_t)ceil(len_f);
        }
      } else if (tok != '_') {
        const double back = (double)(start - first) * half_q * fpq;
        if (back >= 0.0 && back < (double)cap - 0.5) {
          v.mode = LE_SLICE_BACK;
          v.arg = (int32_t)(back + 0.5);
        }
      }
      if (st->cur.mode == LE_SLICE_BACK && v.mode == LE_SLICE_BACK &&
          st->cur.arg == v.arg && st->cur.gain > 0.0f) {
        /* The same audio from the same point (a live slice into a live
         * one across a jump): it plays on. */
        v.gain = st->cur.gain;
      } else {
        if (st->cur.gain > 0.0f) le_slice_cut(st, fade4);
        /* Under slices fading out, the new one fades in as they fade: on
         * time, nothing fades and the new slice starts at once. */
        v.gain = 1.0f - le_slice_fading(st, 0);
      }
      st->cur = v;
      st->id = id;
    }
    if (st->cur.mode != LE_SLICE_SILENT) {
      /* The slice's end fades out over 4 ms (half the slice, if shorter);
       * the gain moves no faster than that either way, so a beat that
       * jumps or a tempo that changes near the end still fades. */
      double left = len_f - into * fpq;
      int src_out = 0;
      if (st->cur.mode == LE_SLICE_MIRROR) {
        /* A reversed slice ends where its latched source does, should the
         * tempo drop under it; once that has run out it stays silent. */
        int n = pos - st->cur.arg;
        if (n < 0) n += cap;
        left = fmin(left, (double)(st->cur.len - n));
        src_out = st->cur.len - n <= 0;
      }
      const float want = left >= fade_f ? 1.0f
                         : left > 0.0   ? (float)(left / fade_f)
                                        : 0.0f;
      const float d = (float)(1.0 / fade_f);
      /* With the fading voices, never more than the input. */
      const float g = fminf(fminf(fmaxf(want, st->cur.gain - d),
                                  st->cur.gain + d),
                            1.0f - le_slice_fading(st, 1));
      /* A slice that reached its end on time has nothing left to fade
       * out after its last frame. */
      st->cur.gain = left > 1.5 || g > want + 1e-3f ? g : 0.0f;
      st->wet_g = g;
      if (src_out && st->cur.gain <= 0.0f) st->cur.mode = LE_SLICE_SILENT;
    } else {
      st->cur.gain = 0.0f;
      st->wet_g = 0.0f;
    }
  }

  float wet[2] = {0.0f, 0.0f};
  if (st->cur.mode != LE_SLICE_SILENT && !passes) {
    wet[0] = st->wet_g * le_slice_read(ring[0], cap, pos, &st->cur);
    wet[1] = st->wet_g * le_slice_read(ring[1], cap, pos, &st->cur);
  }
  for (int k = 0; k < 2; ++k) {
    le_fx_slice_voice* v = &st->out[k];
    if (v->gain <= 0.0f) continue;
    v->gain -= v->step;
    if (v->gain <= 0.0f) {
      v->gain = 0.0f;
      v->mode = LE_SLICE_SILENT;
      continue;
    }
    wet[0] += v->gain * le_slice_read(ring[0], cap, pos, v);
    wet[1] += v->gain * le_slice_read(ring[1], cap, pos, v);
  }
  /* Mix (#891): 100 % is the slices alone; 50 % keeps the dry whole and
   * adds the slices at half. */
  const float m = st->mix;
  const float dry = m > 0.5f ? 2.0f * (1.0f - m) : 1.0f;
  float o[2] = {in[0] * dry + wet[0] * m, in[1] * dry + wet[1] * m};
  /* Toward the input when it passes, over the 4 ms. */
  const float fd_step = (float)(1.0 / fade4);
  st->pass = passes ? fminf(1.0f, st->pass + fd_step)
                    : fmaxf(0.0f, st->pass - fd_step);
  *l = o[0] + st->pass * (in[0] - o[0]);
  *r = o[1] + st->pass * (in[1] - o[1]);
}

/* ---- Mode delay (LE_FX_MODE_DELAY, #887 part 10) ----
 *
 * The Looper X's delay, fit to the #891 captures (s4/4, 10-15 at 1/8D,
 * Feedback 50 %, Mix 30 %; gC passes at Feedback 0 %; s3/8 at 2/4, 29 %,
 * 9 %), measured on the deconvolved sweep:
 * - the time is the note value at the song tempo (1/8D at 120 BPM is
 *   375 ms); the line holds 4 s, so a longer time holds at 4 s (#1372
 *   Architecture 7), and a new time crossfades from the old over 20 ms;
 * - the dry stays whole and the wet is (2 Mix)^2 (0.36 at 30 %, 0.0324 at
 *   9 %: both within 0.2 dB); above 50 % the wet holds at 1 and the dry
 *   falls as 1 - (2 Mix - 1)^2, the Dub Rack's measured law (assumed here:
 *   no capture above 30 %);
 * - each repeat is Feedback of the one before (-6.0 dB at 50 %);
 * - the input is summed to mono (the captures fed both sides alike);
 * - the voicings, on every echo and again in the loop (rms fit error
 *   0.02-0.27 dB to 8 kHz): DIGI flat; DAMPED a one-pole at 13.2 kHz;
 *   RESO LO a +6.1 dB peak at 981 Hz (Q 0.80) and RESO HI +6.1 dB at
 *   2425 Hz (Q 0.85), whose loops also lose 4.9 and 4.8 dB; every echo
 *   passes a 32 Hz high-pass and a 10.9 kHz one-pole, the loop a 14.8 kHz
 *   one-pole;
 * - the timings: the plain modes put the echo on both sides; L/R the right
 *   one half the time early (0.881) with the left on time at
 *   0.219 + 0.666 Feedback, each with 0.126 / 0.143 of the other side's;
 *   GRV the right at 0.837 of the time (0.871) and the left on time at
 *   0.750 + 0.116 Feedback, with 0.126 / 0.113 of the other. The timings
 *   were measured on DIGI and RES HI, and are the same on both; the DAMPED
 *   and RESO LO ones are composed from them.
 * What feeds back is kept under full scale with a soft knee, and a 5 Hz
 * DC blocker sits in the loop: a resonant voicing (or DIGI at DC) at 100 %
 * Feedback would otherwise grow. Its tempo is the live song's, which a
 * print would not keep, so a lane holding one is never printed. */

static const double LE_MDLY_QUARTERS[20] = {
    0.125, 1.0 / 6.0, 0.1875, 0.25, 1.0 / 3.0, 0.375, 0.5, 2.0 / 3.0, 0.75, 1.0,
    4.0 / 3.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0, 8.0};
#define LE_MDLY_XFADE_S 0.020 /* a new time crossfades over 20 ms */
#define LE_MDLY_GLIDE_S 0.010 /* feedback and mix glide over 10 ms */
#define LE_MDLY_HP_HZ 32.1
#define LE_MDLY_OUT_LP_HZ 10917.0
#define LE_MDLY_LOOP_LP_HZ 14832.0
#define LE_MDLY_DAMP_HZ 13203.0
#define LE_MDLY_GRV 0.8368
#define LE_MDLY_DC_HZ 5.0  /* the loop's DC blocker */
#define LE_MDLY_KNEE 0.8f  /* the line's soft knee, ceiling 1 */
#define LE_MDLY_LINE_S 4 /* the line holds 4 s (#1372 Architecture 7) */

/* A voicing: a peak (gain dB 0 for none) or a damping one-pole, and the
 * loop's own loss. */
static const struct {
  double peak_hz, peak_db, peak_q, damp_hz, loop_db;
} LE_MDLY_VOICE[4] = {
    {0.0, 0.0, 1.0, 0.0, 0.0},             /* DIGI */
    {0.0, 0.0, 1.0, LE_MDLY_DAMP_HZ, 0.0}, /* DAMPED */
    {981.0, 6.12, 0.801, 0.0, -4.92},      /* RESO LO */
    {2425.0, 6.08, 0.853, 0.0, -4.81},     /* RESO HI */
};

/* A one-pole low- or high-pass, bilinear: y = b0 (x + x1) - a1 y1 (low) or
 * b0 (x - x1) - a1 y1 (high). */
typedef struct le_mdly_pole {
  float b0, a1, x1, y1;
} le_mdly_pole;

static void le_mdly_pole_set(le_mdly_pole* f, double hz, int sr, int high) {
  const double k = le_prewarp(hz, sr);
  f->b0 = (float)(high ? 1.0 / (1.0 + k) : k / (1.0 + k));
  f->a1 = (float)((k - 1.0) / (k + 1.0));
}

static inline float le_mdly_pole_lp(le_mdly_pole* f, float x) {
  const float y = f->b0 * (x + f->x1) - f->a1 * f->y1;
  f->x1 = x;
  f->y1 = y;
  return y;
}

static inline float le_mdly_pole_hp(le_mdly_pole* f, float x) {
  const float y = f->b0 * (x - f->x1) - f->a1 * f->y1;
  f->x1 = x;
  f->y1 = y;
  return y;
}

/* A biquad, transposed direct form II. */
typedef struct le_mdly_bq {
  float b0, b1, b2, a1, a2, z1, z2;
} le_mdly_bq;

static inline float le_mdly_bq_run(le_mdly_bq* f, float x) {
  const float y = f->b0 * x + f->z1;
  f->z1 = f->b1 * x - f->a1 * y + f->z2;
  f->z2 = f->b2 * x - f->a2 * y;
  return y;
}

/* The voicing [v] as a biquad at [sr]: an RBJ peak, a one-pole low-pass, or
 * the identity. */
static void le_mdly_voice_set(le_mdly_bq* f, int v, int sr) {
  const double rate = (double)(sr > 0 ? sr : 48000);
  f->b0 = 1.0f;
  f->b1 = f->b2 = f->a1 = f->a2 = 0.0f;
  if (LE_MDLY_VOICE[v].peak_db != 0.0) {
    const double A = pow(10.0, LE_MDLY_VOICE[v].peak_db / 40.0);
    const double w0 = 2.0 * 3.14159265358979323846 *
                      LE_MDLY_VOICE[v].peak_hz / rate;
    const double al = sin(w0) / (2.0 * LE_MDLY_VOICE[v].peak_q);
    const double a0 = 1.0 + al / A;
    f->b0 = (float)((1.0 + al * A) / a0);
    f->b1 = (float)(-2.0 * cos(w0) / a0);
    f->b2 = (float)((1.0 - al * A) / a0);
    f->a1 = (float)(-2.0 * cos(w0) / a0);
    f->a2 = (float)((1.0 - al / A) / a0);
  } else if (LE_MDLY_VOICE[v].damp_hz > 0.0) {
    const double k = le_prewarp(LE_MDLY_VOICE[v].damp_hz, sr);
    f->b0 = f->b1 = (float)(k / (1.0 + k));
    f->a1 = (float)((k - 1.0) / (k + 1.0));
  }
}

/* A slot's Mode delay: its runtime, then its mono line. */
typedef struct le_fx_line {
  int32_t cap;  /* the line's frames */
  int32_t pos;  /* where the next frame is written */
  int32_t fill; /* frames written since it was cleared (nothing older is read) */
  int32_t primed;
  int32_t sr, mode;     /* what the filters are set for */
  int32_t tap, tap_old; /* the time, frames, and the one fading out */
  int32_t xf;           /* frames of that crossfade left */
  float fb, mix;        /* gliding */
  le_mdly_bq voice[2];  /* on the on-time tap and the early one */
  le_mdly_pole hp[2], lp_out[2], lp_loop, dc;
  int32_t timing; /* the last frame's: plain, L/R or GRV */
  float loop_g;
  float ring[];
} le_fx_line;

/* Resets [line]'s runtime, keeping its ring (fill 0: nothing is read) and
 * its length, which is never rewritten. */
static void le_mdly_reset(le_fx_line* line) {
  memset(&line->pos, 0, offsetof(le_fx_line, ring) - offsetof(le_fx_line, pos));
  line->mode = -1;
}

static int32_t fx_mode_delay_prepare(le_fx_state* fx, int slot, int cap) {
  if (atomic_load_explicit(&fx->line[slot], memory_order_relaxed) != NULL) {
    return LE_OK;
  }
  /* LE_MDLY_LINE_S seconds ([cap] is the chain's one-second ring), and a
   * little. */
  const int32_t frames = LE_MDLY_LINE_S * (cap > 0 ? cap : 48000) + 4;
  le_fx_line* line = (le_fx_line*)le_rt_alloc_prefaulted(
      sizeof(le_fx_line) + (size_t)frames * sizeof(float));
  if (line == NULL) return LE_ERR_INVALID;
  line->cap = frames;
  le_mdly_reset(line);
  /* Published whole: an audio-thread reset of the slot may see it. */
  atomic_store_explicit(&fx->line[slot], line, memory_order_release);
  return LE_OK;
}

/* A clear is a reset of the line: the ring's old frames are never read
 * again, and nothing the filters hold feeds back into it. */
static void le_mdly_clear(le_fx_line* line) { le_mdly_reset(line); }

static int32_t le_mdly_frames(const le_fx_line* line) { return line->cap; }

/* The line [back] frames behind the next write, or silence past what it
 * has been written since it was cleared. */
static inline float le_mdly_read(const le_fx_line* line, int back) {
  if (back < 1 || back > line->fill) return 0.0f;
  int at = line->pos - back;
  if (at < 0) at += line->cap;
  return line->ring[at];
}

static void fx_mode_delay_process(le_fx_state* fx, int slot, int sr, int cap,
                                  float* l, float* r, const float* p) {
  (void)cap;
  le_fx_line* line =
      atomic_load_explicit(&fx->line[slot], memory_order_acquire);
  if (line == NULL) return;
  const int32_t rate = sr > 0 ? sr : 48000;
  int mode = (int)(p[3] * 11.0f + 0.5f);
  mode = mode < 0 ? 0 : mode > 11 ? 11 : mode;
  const int voice = mode / 3;  /* DIGI, DAMPED, RESO LO, RESO HI */
  const int timing = mode % 3; /* plain, L/R, GRV */
  if (line->sr != rate || line->mode != voice) {
    if (line->sr != rate) {
      le_mdly_pole_set(&line->lp_loop, LE_MDLY_LOOP_LP_HZ, rate, 0);
      le_mdly_pole_set(&line->dc, LE_MDLY_DC_HZ, rate, 1);
      for (int c = 0; c < 2; ++c) {
        le_mdly_pole_set(&line->hp[c], LE_MDLY_HP_HZ, rate, 1);
        le_mdly_pole_set(&line->lp_out[c], LE_MDLY_OUT_LP_HZ, rate, 0);
      }
    }
    for (int c = 0; c < 2; ++c) le_mdly_voice_set(&line->voice[c], voice, rate);
    line->loop_g = (float)pow(10.0, LE_MDLY_VOICE[voice].loop_db / 20.0);
    line->sr = rate;
    line->mode = voice;
  }
  const float fb_to = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  const float mix_to = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  int div = (int)(p[0] * 19.0f + 0.5f);
  div = div < 0 ? 0 : div > 19 ? 19 : div;
  float qpf;
  int32_t num, den;
  (void)le_fx_beat_now(fx, rate, &qpf, &num, &den);
  int32_t want = line->tap;
  if (qpf > 0.0f && isfinite(qpf)) {
    const double frames = LE_MDLY_QUARTERS[div] / (double)qpf;
    const double most = (double)(line->cap - 2);
    want = (int32_t)(frames < 1.0 ? 1.0 : frames > most ? most : frames + 0.5);
  }
  if (!line->primed) {
    line->primed = 1;
    line->fb = fb_to;
    line->mix = mix_to;
    line->tap = want > 0 ? want : 1;
  }
  /* The early tap's voicing starts clean when it comes into use. */
  if (timing != 0 && line->timing == 0) {
    line->voice[1].z1 = line->voice[1].z2 = 0.0f;
  }
  line->timing = timing;
  const float glide = (float)(1.0 / (LE_MDLY_GLIDE_S * (double)rate));
  line->fb += (fb_to - line->fb) * glide;
  line->mix += (mix_to - line->mix) * glide;
  const int32_t xf_n = (int32_t)(LE_MDLY_XFADE_S * (double)rate);
  if (want != line->tap && line->xf == 0) {
    line->tap_old = line->tap;
    line->tap = want;
    line->xf = xf_n;
  }

  /* The taps: on time, and early (L/R half the time, GRV 0.837 of it),
   * crossfading from the old time to the new. */
  const float t_new = line->xf > 0 ? 1.0f - (float)line->xf / (float)xf_n : 1.0f;
  float tp = le_mdly_read(line, line->tap);
  float te = 0.0f;
  const double early = timing == 1 ? 0.5 : LE_MDLY_GRV;
  if (timing != 0) te = le_mdly_read(line, (int)(line->tap * early + 0.5));
  if (line->xf > 0) {
    tp = t_new * tp + (1.0f - t_new) * le_mdly_read(line, line->tap_old);
    if (timing != 0) {
      te = t_new * te + (1.0f - t_new) *
                            le_mdly_read(line, (int)(line->tap_old * early + 0.5));
    }
    --line->xf;
  }
  const float vp = le_mdly_bq_run(&line->voice[0], tp);
  const float ve = timing != 0 ? le_mdly_bq_run(&line->voice[1], te) : 0.0f;

  /* The loop: the on-time echo, voiced, fed back at Feedback, a DC
   * blocker far under the band (5 Hz: 0.04 dB at 50 Hz), and the fed-back
   * part kept under full scale with a soft knee from 0.8; the input goes
   * in as it is. */
  float back = line->fb * line->loop_g *
               le_mdly_pole_lp(&line->lp_loop, le_mdly_pole_hp(&line->dc, vp));
  const float ab = fabsf(back);
  if (ab > LE_MDLY_KNEE) {
    const float over = (ab - LE_MDLY_KNEE) / (1.0f - LE_MDLY_KNEE);
    back = copysignf(LE_MDLY_KNEE + (1.0f - LE_MDLY_KNEE) * tanhf(over), back);
  }
  line->ring[line->pos] = 0.5f * (*l + *r) + back;
  line->pos = line->pos + 1 >= line->cap ? 0 : line->pos + 1;
  if (line->fill < line->cap) ++line->fill;

  float wl, wr;
  const float fb = line->fb;
  if (timing == 0) {
    wl = wr = vp;
  } else if (timing == 1) { /* L/R */
    const float gl = 0.219f + 0.666f * fb;
    wl = gl * (vp + 0.143f * ve);
    wr = 0.881f * ve + 0.126f * vp;
  } else { /* GRV */
    wl = (0.750f + 0.116f * fb) * vp + 0.1135f * ve;
    wr = 0.871f * ve + 0.126f * vp;
  }
  wl = le_mdly_pole_lp(&line->lp_out[0], le_mdly_pole_hp(&line->hp[0], wl));
  wr = le_mdly_pole_lp(&line->lp_out[1], le_mdly_pole_hp(&line->hp[1], wr));
  const float m = line->mix;
  const float wet = m <= 0.5f ? 4.0f * m * m : 1.0f;
  const float dry = m <= 0.5f ? 1.0f : 1.0f - (2.0f * m - 1.0f) * (2.0f * m - 1.0f);
  *l = *l * dry + wl * wet;
  *r = *r * dry + wr * wet;
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
          (float*)le_rt_alloc_prefaulted((size_t)LE_PV_SCRATCH_ALLOC *
                                         sizeof(float));
      if (o->scratch == NULL) goto oom;
      owned[n++] = &o->scratch;
      o->analysed = 0; /* a fresh (zeroed) scratch holds no frame or pass */
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
/* Ed's Rack's Dual Octaver (#891): high mode off or on, Octave 1's level
 * (its taper unmeasured: every factory preset sits at 100 %), the mix, and
 * Octave 2's level (its taper unmeasured, and two octaves down inferred,
 * #1464). */
static const le_fx_param_desc LE_FX_DUAL_OCTAVER_PARAMS[] = {
    {"oct_high_mode", LE_FX_UNIT_CHOICE, 2, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
    {"octave_1_vol", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, LE_FX_PARAM_TAPER_UNVERIFIED},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f, 0},
    {"octave_2_vol", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.0f, LE_FX_PARAM_TAPER_UNVERIFIED},
};
/* The Guitar Rack's Whammy (#891): position 0 of the range is -12, 1 is
 * +12 semitones, the Looper X's two. */
static const le_fx_param_desc LE_FX_WHAMMY_PARAMS[] = {
    {"pedal", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.0f, 0},
    {"whammy_range", LE_FX_UNIT_CHOICE, 2, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
};
/* The Rhythmic Rack's Pumper (#891): the rate a note value (positions in
 * LE_PUMP_PERIOD's order), the depth the dip. */
static const le_fx_param_desc LE_FX_PUMPER_PARAMS[] = {
    {"pumper_rate", LE_FX_UNIT_CHOICE, 11, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     0.3f, 0},
    {"depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.7f, 0},
};
/* The Rhythmic Rack's Slicer (#891): the pattern and the step in the
 * orders of LE_SLICE_PATTERNS and LE_SLICE_STEP; the mix. */
static const le_fx_param_desc LE_FX_SLICER_PARAMS[] = {
    {"slicer_pattern", LE_FX_UNIT_CHOICE, 20, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
    {"slicer_step", LE_FX_UNIT_CHOICE, 9, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f, 0},
};
/* The Looper X's delay (#891): the time a note value (in
 * LE_MDLY_QUARTERS's order), feedback, mix and mode (LE_MDLY_VOICE's
 * voicings, each plain, L/R and GRV). */
static const le_fx_param_desc LE_FX_MODE_DELAY_PARAMS[] = {
    {"delay_time", LE_FX_UNIT_CHOICE, 20, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     8.0f / 19.0f, 0},
    {"feedback", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.2f, 0},
    {"delay_mode", LE_FX_UNIT_CHOICE, 12, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
};
/* The Amp+Cab's controls. Drive, Bass, Treble and Modern were captured at
 * 0, 25, 50, 75 and 100 % and interpolate between (#1468). */
static const le_fx_param_desc LE_FX_AMP_CAB_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"bass", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"treble", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    {"modern", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    /* D.I., BRIT, 1x8", 1x12", 2x10", 2x12", 4x10", 4x12", 1x15", BASS,
     * 4x10", RADIO; 4x12" by default */
    {"cabinet", LE_FX_UNIT_CHOICE, 12, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     7.0f / 11.0f, 0},
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
  if (d->curve == LE_FX_CURVE_REVERB_TIME) {
    const double t =
        v >= 1.0f ? (double)d->at_max : ((double)v + d->at_min) / (1.0 - v);
    return t < (double)d->at_max ? t : (double)d->at_max;
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

/* ---- The EQ at rates other than 48 kHz (#1436) ----
 *
 * The bands are the Looper X's, measured at 48 kHz. At another rate the same
 * design runs high near the top of the audio band, where the 48 kHz response
 * is compressed toward its 24 kHz Nyquist frequency: at 96 kHz the 20 kHz
 * high cut lost 1.2 dB at 16 kHz instead of 0.2 dB, and a bell near 20 kHz
 * was off by up to 7 dB. tool/eq_rate_fit.py fits, for each band shape at
 * each point of a grid over its settings, a biquad at the running rate to
 * the 48 kHz magnitude response over 20 Hz to 20 kHz, and stores how its
 * coefficients differ from the plain design below. A band adds the
 * difference, interpolated over the grid, to its plain design: a table
 * lookup, no fitting. 48 kHz needs none, and other rates run the plain
 * design. */
typedef struct le_eq_rate_table {
  int32_t nf, nq, ng;     /* grid points per axis */
  double f0, df;          /* ln f0 at the first point, and the step */
  double q0, dq;          /* ln Q likewise */
  double g0, dg;          /* gain in dB likewise */
  const float* d;         /* [nf][nq][ng][5]: b0 b1 b2 a1 a2 */
} le_eq_rate_table;

#include "engine_fx_eq_rate.inc"

enum { LE_EQR_BELL, LE_EQR_HS, LE_EQR_LP, LE_EQR_HP, LE_EQR_NONE };

static const le_eq_rate_table* le_eq_rate_table_for(int shape, int sr) {
  static const le_eq_rate_table* const t44[4] = {
      &LE_EQR_BELL_44100, &LE_EQR_HS_44100, &LE_EQR_LP_44100, &LE_EQR_HP_44100};
  static const le_eq_rate_table* const t96[4] = {
      &LE_EQR_BELL_96000, &LE_EQR_HS_96000, &LE_EQR_LP_96000, &LE_EQR_HP_96000};
  if (shape == LE_EQR_NONE) return NULL;
  if (sr == 44100) return t44[shape];
  if (sr == 96000) return t96[shape];
  return NULL;
}

/* The grid position of [v] on an axis of [n] points from [v0] in steps of
 * [dv]: the lower point and the share toward the next, clamped to the grid. */
static void le_eq_rate_axis(double v, double v0, double dv, int32_t n,
                            int32_t* i, double* t) {
  if (n < 2) {
    *i = 0;
    *t = 0.0;
    return;
  }
  double u = (v - v0) / dv;
  if (u < 0.0) u = 0.0;
  if (u > (double)(n - 1)) u = (double)(n - 1);
  int32_t k = (int32_t)u;
  if (k > n - 2) k = n - 2;
  *i = k;
  *t = u - (double)k;
}

/* How close to the stability edge a correction may move a pole. */
#define LE_EQR_MARGIN 0.9999

/* Adds [shape]'s correction at these settings to the plain design [c], when
 * the rate has one. The grid's own designs are all stable, but the plain
 * design between grid points plus the interpolated correction could land
 * close to or past the edge, so the correction is scaled by the largest
 * s <= 1 that keeps |a2| <= LE_EQR_MARGIN and |a1| <= LE_EQR_MARGIN (1 + a2),
 * or no further out than the plain design where that already is. Each bound
 * is linear in s, so s moves continuously with the settings and a glide
 * never steps (tool/eq_rate_fit.py guarded() is the same). */
static void le_eq_rate_correct(int shape, double hz, double db, double q,
                               int sr, double c[5]) {
  const le_eq_rate_table* t = le_eq_rate_table_for(shape, sr);
  if (t == NULL) return;
  int32_t i[3];
  double w[3];
  le_eq_rate_axis(log(hz), t->f0, t->df, t->nf, &i[0], &w[0]);
  le_eq_rate_axis(log(q), t->q0, t->dq, t->nq, &i[1], &w[1]);
  le_eq_rate_axis(db, t->g0, t->dg, t->ng, &i[2], &w[2]);
  double d[5] = {0.0, 0.0, 0.0, 0.0, 0.0};
  for (int corner = 0; corner < 8; ++corner) {
    const int32_t fi = i[0] + ((corner & 1) && t->nf > 1);
    const int32_t qi = i[1] + ((corner & 2) && t->nq > 1);
    const int32_t gi = i[2] + ((corner & 4) && t->ng > 1);
    const double wt = ((corner & 1) ? w[0] : 1.0 - w[0]) *
                      ((corner & 2) ? w[1] : 1.0 - w[1]) *
                      ((corner & 4) ? w[2] : 1.0 - w[2]);
    if (wt == 0.0) continue;
    const float* e = t->d + 5 * ((fi * t->nq + qi) * t->ng + gi);
    for (int k = 0; k < 5; ++k) d[k] += wt * (double)e[k];
  }
  const double m = LE_EQR_MARGIN;
  const double a1 = c[3];
  const double a2 = c[4];
  const double g0[4] = {a2 - m, -a2 - m, a1 - m * (1.0 + a2),
                        -a1 - m * (1.0 + a2)};
  const double dg[4] = {d[4], -d[4], d[3] - m * d[4], -d[3] - m * d[4]};
  double s = 1.0;
  for (int k = 0; k < 4; ++k) {
    const double bound = g0[k] > 0.0 ? g0[k] : 0.0;
    if (dg[k] > 0.0 && (bound - g0[k]) / dg[k] < s) s = (bound - g0[k]) / dg[k];
  }
  if (s < 0.0) s = 0.0;
  for (int k = 0; k < 5; ++k) c[k] += s * d[k];
}

/* The EQ kind's design of band [b] (LE_EQB_*): the cuts, the outer bands as
 * shelves or bells, and the mid bells, each corrected to its 48 kHz
 * response at the running rate where a table has it. */
static void le_eq_band_design(int b, int shelves, double hz, double db,
                              double q, int sr, double c[5]) {
  int shape = LE_EQR_BELL;
  switch (b) {
    case LE_EQB_LOWCUT:
      le_eq_design(LE_EQ_LOWCUT, hz, 0.0, q, sr, c);
      shape = LE_EQR_HP;
      break;
    case LE_EQB_HIGHCUT:
      le_eq_design(LE_EQ_HIGHCUT, hz, 0.0, q, sr, c);
      shape = LE_EQR_LP;
      break;
    case LE_EQB_LOW:
      if (shelves) {
        /* at most 1 kHz: its plain design is within 0.12 dB at any rate */
        le_eq_design(LE_EQ_LOW, hz, db, q, sr, c);
        shape = LE_EQR_NONE;
      } else {
        le_eq_bell(hz, db, q, sr, c);
      }
      break;
    case LE_EQB_HIGH:
      if (shelves) {
        le_eq_design(LE_EQ_HIGH, hz, db, q, sr, c);
        shape = LE_EQR_HS;
      } else {
        le_eq_bell(hz, db, q, sr, c);
      }
      break;
    default:
      le_eq_bell(hz, db, q, sr, c);
      break;
  }
  le_eq_rate_correct(shape, hz, db, q, sr, c);
}

/* Exposed for the native tests: band [b]'s design, as the kernel runs it. */
void le_eq_band_design_for_test(int b, int shelves, double hz, double db,
                                double q, int sr, double c[5]) {
  le_eq_band_design(b, shelves, hz, db, q, sr, c);
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
 * percentages do is measured: the chorus on the Guitar Rack's (#891,
 * sessions s3/4 and s3/5), the doubler and the wah in the Phase 0 gap
 * captures (#1445, docs/plan/2026-10-23-looperx-gaps-measured.md); the
 * chorus's constants say where its fit stops. */

static const le_fx_param_desc LE_FX_DOUBLER_PARAMS[] = {
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f, 0},
    {"separation", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, 0},
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
     0},
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

/* A uniform sample in [0, 1). */
static inline float le_unit(uint32_t* s) {
  return (float)(le_xorshift(s) >> 8) * (1.0f / 16777216.0f);
}

/* ---- Doubler (LE_FX_DOUBLER) ----
 *
 * Fit to the Dub, Studio and Vocal racks' doublers (#1445, the Phase 0 gap
 * captures): each side is one copy of its own input at a random delay. It
 * holds that delay for 125 to 175 ms, crossfades over 25 ms to a new random
 * delay and holds again; left and right draw independently. The dry signal
 * is cut to 0.31 and the copy sits at 0.95 (measured 0.9 to 1.0).
 * - The separation sets the longest delay a side draws: 1 ms at 0 %,
 *   50.5 ms at 50 % and 100 ms at 100 % (measured 1.0, 51.2 and 100.8 ms),
 *   the shortest 0.2 ms. The ring holds 100 ms up to 162 kHz, so the
 *   appliance's 96 kHz gets the whole range; that makes the block 128 KB,
 *   which every slot's arena holds once and the audio thread clears when a
 *   slot turns into a doubler.
 * - The mix does not fade the copy: from 50 % up it changes nothing
 *   (Studio, Vocal and Dub alike), and towards 0 % it shrinks the delays
 *   until, at 0 %, the copy sits within 1 ms of the dry signal (the range
 *   of 0 % separation) and sums with it (the Looper X's +2 to +4.4 dB
 *   flutter on a steady tone). Between 0 and 50 % the longest delay moves
 *   linearly (chosen; only 0, 50 and 100 % were captured).
 * A new mix or separation applies from the next delay a side draws. */
#define LE_DBL_RING 16384u /* holds the longest delay up to 162 kHz */
#define LE_DBL_DRY 0.31f
#define LE_DBL_VOICE 0.95f
#define LE_DBL_SHORT_MS 0.2
#define LE_DBL_LONG_MIN_MS 1.0   /* the longest delay at 0 % separation */
#define LE_DBL_LONG_MAX_MS 100.0 /* at 100 % */
#define LE_DBL_HOLD_MIN_S 0.125
#define LE_DBL_HOLD_MAX_S 0.175
#define LE_DBL_FADE_S 0.025

typedef struct le_fx_doubler {
  le_fx_dyn_head h;
  float last[LE_DBL_PARAMS_N];
  uint32_t w;
  float short_n; /* the shortest delay, in samples */
  float long_n;  /* the longest the settings allow, in samples */
  float hold_n;  /* the shortest hold, in samples */
  float spread_n; /* the hold's random extra, in samples */
  int32_t fade_n;
  uint32_t rng[2];
  uint32_t cur[2];  /* each side's delay, in samples */
  uint32_t next[2]; /* the delay it fades to */
  int32_t left[2];  /* samples until the next fade starts */
  int32_t fade[2];  /* samples into the fade, or -1 */
  float ring[2][LE_DBL_RING];
} le_fx_doubler;

static uint32_t le_dbl_draw_delay(le_fx_doubler* d, int ch) {
  const float span = d->long_n > d->short_n ? d->long_n - d->short_n : 0.0f;
  return (uint32_t)(d->short_n + span * le_unit(&d->rng[ch]) + 0.5f);
}

static int32_t le_dbl_draw_hold(le_fx_doubler* d, int ch) {
  return (int32_t)(d->hold_n + d->spread_n * le_unit(&d->rng[ch]));
}

static void fx_doubler_update(void* ks, const float* p, int sr, int settle) {
  le_fx_doubler* d = (le_fx_doubler*)ks;
  const int f = le_fx_dyn_begin(&d->h, d->last, p, LE_DBL_PARAMS_N, sr, settle);
  if (!f) return;
  const double rate = (double)(sr > 0 ? sr : 48000);
  const float m = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float s = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  const float reach = m >= 0.5f ? 1.0f : 2.0f * m;
  const double long_ms =
      LE_DBL_LONG_MIN_MS + (LE_DBL_LONG_MAX_MS - LE_DBL_LONG_MIN_MS) * s;
  d->short_n = (float)(LE_DBL_SHORT_MS * 1e-3 * rate);
  d->long_n = (float)((LE_DBL_LONG_MIN_MS +
                       (long_ms - LE_DBL_LONG_MIN_MS) * reach) *
                      1e-3 * rate);
  if (d->long_n > (float)(LE_DBL_RING - 1u)) d->long_n = (float)(LE_DBL_RING - 1u);
  if (d->short_n > d->long_n) d->short_n = d->long_n;
  if (f & LE_FX_DYN_NEW_RATE) {
    d->hold_n = (float)(LE_DBL_HOLD_MIN_S * rate);
    d->spread_n = (float)((LE_DBL_HOLD_MAX_S - LE_DBL_HOLD_MIN_S) * rate);
    d->fade_n = (int32_t)(LE_DBL_FADE_S * rate);
    if (d->fade_n < 1) d->fade_n = 1;
  }
  if (settle) {
    const uint32_t seed = le_fx_kind_seed(ks);
    d->rng[0] = seed | 1u;
    d->rng[1] = (seed * 2654435761u) | 1u;
    for (int ch = 0; ch < 2; ++ch) {
      d->cur[ch] = le_dbl_draw_delay(d, ch);
      d->left[ch] = le_dbl_draw_hold(d, ch);
      d->fade[ch] = -1;
    }
  }
  /* A rate change can leave a drawn delay past the ring, or a fade past its
   * new length: hold both inside. */
  for (int ch = 0; ch < 2; ++ch) {
    if (d->fade[ch] >= d->fade_n) d->fade[ch] = d->fade_n - 1;
    if (d->cur[ch] > LE_DBL_RING - 1u) d->cur[ch] = LE_DBL_RING - 1u;
    if (d->next[ch] > LE_DBL_RING - 1u) d->next[ch] = LE_DBL_RING - 1u;
  }
  d->h.moving = 0;
}

static void fx_doubler_kprocess(void* ks, float* l, float* r) {
  le_fx_doubler* d = (le_fx_doubler*)ks;
  const uint32_t mask = LE_DBL_RING - 1u;
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float* ring = d->ring[ch];
    ring[d->w & mask] = io[ch];
    float v = ring[(d->w - d->cur[ch]) & mask];
    if (d->fade[ch] >= 0) {
      const float t = (float)d->fade[ch] / (float)d->fade_n;
      v += t * (ring[(d->w - d->next[ch]) & mask] - v);
      if (++d->fade[ch] >= d->fade_n) {
        d->cur[ch] = d->next[ch];
        d->fade[ch] = -1;
        d->left[ch] = le_dbl_draw_hold(d, ch);
      }
    } else if (--d->left[ch] <= 0) {
      d->next[ch] = le_dbl_draw_delay(d, ch);
      d->fade[ch] = 0;
    }
    io[ch] = LE_DBL_DRY * io[ch] + LE_DBL_VOICE * v;
  }
  d->w++;
  *l = io[0];
  *r = io[1];
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
 * Fit to the Guitar and Ed's racks' wahs (#1445, the Phase 0 gap captures;
 * the two are the same filter to 0.5 dB and 1 %): one state-variable
 * filter whose band-pass, low-pass and high-pass outputs are mixed,
 * H(s) = (hp s^2 + bp s / Q + lp) / (s^2 + s / Q + 1). A pure band-pass
 * misses the Looper X's floor (about -17 dB below 100 Hz) by up to 10 dB;
 * this form fits each captured pedal position's noise response within
 * 0.06 dB rms (1.2 dB at worst), 30 Hz to 15 kHz. Between the captured
 * positions the corner, Q and gains are interpolated, in log for all but
 * the low-pass's. The pedal glides (an expression input never zips). */
typedef struct le_wah_point {
  float pedal;
  float hz, q, bp, lp, hp;
} le_wah_point;

static const le_wah_point LE_WAH_TABLE[] = {
    {0.0f, 438.6f, 11.43f, 4.325f, 0.130f, 0.0153f},
    {0.25f, 459.0f, 11.23f, 4.703f, 0.140f, 0.0184f},
    {0.5f, 536.1f, 7.49f, 3.551f, 0.127f, 0.0267f},
    {0.619f, 748.8f, 5.74f, 4.177f, 0.161f, 0.0546f}, /* Ed's default */
    {0.75f, 1208.5f, 3.75f, 3.514f, 0.159f, 0.1023f},
    {1.0f, 2311.5f, 2.10f, 4.517f, 0.140f, 0.3717f},
};
#define LE_WAH_POINTS ((int)(sizeof(LE_WAH_TABLE) / sizeof(LE_WAH_TABLE[0])))

typedef struct le_fx_wah {
  le_fx_dyn_head h;
  float last[LE_WAH_PARAMS_N];
  float pos; /* the pedal now */
  float tgt;
  float a1, a2, a3; /* SVF coefficients */
  float cb, cl, cx; /* y = cb v1 + cl v2 + cx x */
  float ic1[2];
  float ic2[2];
} le_fx_wah;

/* The filter at pedal [v] (0..1): corner, Q and the three output gains. */
static void le_wah_at(float v, double* hz, double* q, double* bp, double* lp,
                      double* hp) {
  int i = 0;
  while (i < LE_WAH_POINTS - 2 && v > LE_WAH_TABLE[i + 1].pedal) ++i;
  const le_wah_point* a = &LE_WAH_TABLE[i];
  const le_wah_point* b = &LE_WAH_TABLE[i + 1];
  double t = (v - a->pedal) / (b->pedal - a->pedal);
  t = t < 0.0 ? 0.0 : t > 1.0 ? 1.0 : t;
  *hz = a->hz * pow(b->hz / a->hz, t);
  *q = a->q * pow(b->q / a->q, t);
  *bp = a->bp * pow(b->bp / a->bp, t);
  *lp = a->lp + (b->lp - a->lp) * t;
  *hp = a->hp * pow(b->hp / a->hp, t);
}

static void fx_wah_update(void* ks, const float* p, int sr, int settle) {
  le_fx_wah* q = (le_fx_wah*)ks;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_WAH_PARAMS_N, sr, settle);
  if (!f) return;
  if (f & LE_FX_DYN_CHANGED) {
    q->tgt = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  }
  if (q->pos != q->tgt || (f & LE_FX_DYN_NEW_RATE) || settle) {
    le_fx_step_toward(&q->pos, q->tgt, settle ? 1.0f : q->h.k);
    double hz, qq, bp, lp, hp;
    le_wah_at(q->pos, &hz, &qq, &bp, &lp, &hp);
    const double k = 1.0 / qq;
    le_svf_coefs(le_prewarp(hz, sr), k, &q->a1, &q->a2, &q->a3);
    /* v1 is the band output (peak Q), v2 the low-pass; the high-pass is
     * x - k v1 - v2. */
    q->cb = (float)((bp - hp) * k);
    q->cl = (float)(lp - hp);
    q->cx = (float)hp;
  }
  q->h.moving = q->pos != q->tgt;
}

static void fx_wah_kprocess(void* ks, float* l, float* r) {
  le_fx_wah* q = (le_fx_wah*)ks;
  float y[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  for (int ch = 0; ch < 2; ++ch) {
    float v1;
    float v2;
    le_svf_tick(y[ch], q->a1, q->a2, q->a3, &q->ic1[ch], &q->ic2[ch], &v1, &v2);
    y[ch] = q->cb * v1 + q->cl * v2 + q->cx * y[ch];
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

/* ---- Amp+Cab (LE_FX_AMP_CAB, #887 part 12) ----
 *
 * The Looper X's Amp pedal (Ed's and Guitar racks), fit to the #891 rig
 * captures (s3/1-3, s4/16-20, and s6: drive, tone and every cabinet). Mono:
 * the Looper X's amp is (its outputs are identical), so the pair's average
 * goes in and the result goes to both sides.
 *
 *   input voicing  an 81 Hz high-pass, +6.4 dB at 4.5 kHz and +1 dB at
 *                  415 Hz (the small-signal response at drive 0)
 *   drive, first   a gain, then a square-law term: the even harmonic every
 *                  pass shows below clipping, sized by Modern
 *   Modern         a low shelf, a broad rise near 5 kHz, a high shelf and a
 *                  level before the clipper (Modern mostly moves how hard it
 *                  is driven), and a smaller level after it (0 to -3 dB)
 *   drive, second  a gain with the drive's own treble loss (a 9 kHz shelf,
 *                  0 to -13 dB from 0 to 100 %), into a clipper whose two
 *                  sides limit at different levels
 *   tone           Bass and Treble shelves after the clipper (a saturated
 *                  sweep shows them in full)
 *   output         a 10.1 kHz low-pass, a gentle one at 22 kHz, and the
 *                  output level
 *   cabinet        one of eleven measured responses, or none (D.I.), as
 *                  zero-latency partitioned convolution
 *
 * Drive, Bass, Treble and Modern were captured at 0, 25, 50, 75 and 100 %
 * (s6); between those the settings interpolate linearly (gains in dB,
 * corners in octaves), the plainest reading of five points. */

#include "engine_fx_cabs.inc"

#define LE_AMP_PARAMS_N 5
#define LE_CAB_B 64               /* partition length, frames */
#define LE_CAB_NB (LE_CAB_B + 1)  /* half-spectrum bins of a 2B transform */
#define LE_CAB_MAX_PARTS 64       /* 4160 taps: the 4096 a cabinet needs at 96 kHz */
#define LE_CAB_XF_FRAMES 1024     /* a cabinet change crossfades this long */

/* The cabinets at one sample rate, built off the audio thread and read-only
 * after: each row's first B taps (run directly) and the spectra of the
 * partitions after them. */
typedef struct le_cab_bank {
  int32_t sr, parts;
  float head[LE_CAB_ROWS][LE_CAB_B];
  float re[LE_CAB_ROWS][LE_CAB_MAX_PARTS][LE_CAB_NB];
  float im[LE_CAB_ROWS][LE_CAB_MAX_PARTS][LE_CAB_NB];
} le_cab_bank;

#define LE_CAB_BANKS 6 /* 44.1, 48, 88.2, 96, 176.4 and 192 kHz */
static le_cab_bank* _Atomic le_cab_banks[LE_CAB_BANKS];
static pthread_mutex_t le_cab_banks_mu = PTHREAD_MUTEX_INITIALIZER;
static le_rfft_plan le_cab_fft;

/* The bank for [sr], or NULL when none was built. Any thread. */
static const le_cab_bank* le_cab_bank_find(int32_t sr) {
  for (int i = 0; i < LE_CAB_BANKS; ++i) {
    const le_cab_bank* b =
        atomic_load_explicit(&le_cab_banks[i], memory_order_acquire);
    if (b != NULL && b->sr == sr) return b;
  }
  return NULL;
}

/* Builds the bank for [sr] once (control thread). Each 48 kHz response is
 * resampled through its spectrum: the rate's impulse response is the
 * inverse transform of the 48 kHz bins (everything below 24 kHz, on their
 * own spacing) at the rate's sample times, scaled by 48000 / sr so the
 * cabinet's gain does not change with the rate. Nothing is added above
 * 24 kHz, where every cabinet is already 40 dB or more down. At 48 kHz that
 * is the response itself, and at 96 kHz one zero-padded inverse FFT (about
 * a millisecond); other rates sum the bins directly (tens of ms, once).
 * Past 96 kHz the response is cut at LE_CAB_MAX_PARTS partitions, with a
 * fade over its last quarter. */
static le_rfft_plan le_cab_fft48;
static le_rfft_plan le_cab_fft96;
static const le_cab_bank* le_cab_bank_get(int32_t sr) {
  if (sr <= 0) sr = 48000;
  const le_cab_bank* found = le_cab_bank_find(sr);
  if (found != NULL) return found;
  pthread_mutex_lock(&le_cab_banks_mu);
  found = le_cab_bank_find(sr);
  int slot = -1;
  for (int i = 0; found == NULL && i < LE_CAB_BANKS; ++i) {
    if (atomic_load_explicit(&le_cab_banks[i], memory_order_relaxed) == NULL) {
      slot = i;
      break;
    }
  }
  if (found != NULL || slot < 0) {
    pthread_mutex_unlock(&le_cab_banks_mu);
    return found;
  }
  const int n48 = LE_CAB_TAPS48;
  const int half = n48 / 2;
  const int max_taps = LE_CAB_B * (LE_CAB_MAX_PARTS + 1);
  int m = (int)((double)n48 * (double)sr / 48000.0 + 0.5);
  const int cut = m > max_taps; /* past 96 kHz the tail is cut */
  if (cut) m = max_taps;
  le_cab_bank* b = (le_cab_bank*)calloc(1, sizeof(*b));
  float* h = (float*)malloc(sizeof(float) * (size_t)m);
  double* acc = (double*)malloc(sizeof(double) * (size_t)m);
  float xr[LE_CAB_TAPS48 / 2 + 1], xi[LE_CAB_TAPS48 / 2 + 1];
  if (b == NULL || h == NULL || acc == NULL ||
      !le_rfft_plan_init(&le_cab_fft, 2 * LE_CAB_B) ||
      !le_rfft_plan_init(&le_cab_fft48, n48)) {
    free(b);
    free(h);
    free(acc);
    pthread_mutex_unlock(&le_cab_banks_mu);
    return NULL;
  }
  b->sr = sr;
  b->parts = (m - LE_CAB_B + LE_CAB_B - 1) / LE_CAB_B;
  if (b->parts > LE_CAB_MAX_PARTS) b->parts = LE_CAB_MAX_PARTS;
  const double step = 2.0 * 3.14159265358979323846 * 48000.0 /
                      ((double)n48 * (double)sr); /* one bin, one sample */
  float frame[2 * LE_CAB_B];
  const int fft96 = !cut && m == 2 * n48 && 2 * n48 <= LE_FFT_MAX_N &&
                    le_rfft_plan_init(&le_cab_fft96, 2 * n48);
  for (int row = 0; row < LE_CAB_ROWS; ++row) {
    if (m == n48) {
      memcpy(h, LE_CAB_IR48[row], sizeof(float) * (size_t)n48);
    } else if (fft96) {
      /* The 48 kHz bins, zero-padded to twice the length: 24 kHz becomes an
       * inner bin, so it carries half its weight; le_rfft_inv's 1 / 2n48
       * is the 48000 / sr scale. */
      static float zr[LE_FFT_MAX_N / 2 + 1], zi[LE_FFT_MAX_N / 2 + 1];
      le_rfft_fwd(&le_cab_fft48, LE_CAB_IR48[row], xr, xi);
      memset(zr, 0, sizeof(zr));
      memset(zi, 0, sizeof(zi));
      for (int k = 0; k <= half; ++k) {
        const float w = k == half ? 0.5f : 1.0f;
        zr[k] = w * xr[k];
        zi[k] = w * xi[k];
      }
      le_rfft_inv(&le_cab_fft96, zr, zi, h);
    } else {
    le_rfft_fwd(&le_cab_fft48, LE_CAB_IR48[row], xr, xi);
    for (int t = 0; t < m; ++t) acc[t] = 0.0;
    for (int k = 0; k <= half; ++k) {
      /* bin k at the rate's sample times, by a rotating phasor */
      const double w = (k == 0 || k == half) ? 1.0 : 2.0;
      const double cr = cos(step * (double)k), ci = sin(step * (double)k);
      double zr = 1.0, zi = 0.0;
      const double ar = w * (double)xr[k], ai = w * (double)xi[k];
      for (int t = 0; t < m; ++t) {
        acc[t] += ar * zr - ai * zi;
        const double nr = zr * cr - zi * ci;
        zi = zr * ci + zi * cr;
        zr = nr;
      }
    }
    /* le_rfft_fwd is unscaled: 1 / n48, and 48000 / sr for the rate */
    const double scale = 48000.0 / ((double)n48 * (double)sr);
    for (int t = 0; t < m; ++t) h[t] = (float)(acc[t] * scale);
    }
    if (cut) {
      const int r = m / 4;
      for (int t = m - r; t < m; ++t) {
        const double c = cos(1.5707963267948966 * (double)(t - (m - r)) / r);
        h[t] *= (float)(c * c);
      }
    }
    for (int t = 0; t < LE_CAB_B; ++t) b->head[row][t] = t < m ? h[t] : 0.0f;
    for (int p = 0; p < b->parts; ++p) {
      for (int t = 0; t < 2 * LE_CAB_B; ++t) {
        const int k = LE_CAB_B + p * LE_CAB_B + t;
        frame[t] = t < LE_CAB_B && k < m ? h[k] : 0.0f;
      }
      le_rfft_fwd(&le_cab_fft, frame, b->re[row][p], b->im[row][p]);
    }
  }
  free(h);
  free(acc);
  atomic_store_explicit(&le_cab_banks[slot], b, memory_order_release);
  pthread_mutex_unlock(&le_cab_banks_mu);
  return b;
}

/* ---- the amp's voicing, fit to the s6 captures (scratch analysis) ---- */
/* The input voicing: a high-pass and two rises. */
#define LE_AMP_HP_HZ 81.2
#define LE_AMP_HP_Q 0.655
#define LE_AMP_PK1_HZ 4542.0
#define LE_AMP_PK1_DB 6.44
#define LE_AMP_PK1_Q 0.80
#define LE_AMP_PK2_HZ 415.0
#define LE_AMP_PK2_DB 1.06
#define LE_AMP_PK2_Q 0.64
#define LE_AMP_DC_HZ 5.0        /* the coupling after the square-law stage */
#define LE_AMP_POST_HP_HZ 1 /* the coupling after the clipper */
#define LE_AMP_LP1_HZ 10099.0
#define LE_AMP_LP1_Q 0.945
#define LE_AMP_LP2_HZ 22083.0
#define LE_AMP_LP2_Q 0.30
#define LE_AMP_CLIP_POS 1.2071f  /* the clipper's two limits */
#define LE_AMP_CLIP_NEG 0.52724f
/* Interpolation points: settings 0, 25, 50, 75 and 100 %. */
#define LE_AMP_PTS 5
/* Drive: the gain into the square-law stage, the one into the clipper and
 * the output level, dB. */
static const float LE_AMP_GA_DB[LE_AMP_PTS] = {3.119f, 12.62f, 9.896f, 11.61f, 21.15f};
static const float LE_AMP_GB_DB[LE_AMP_PTS] = {-9.026f, -0.7326f, 9.114f, 14.53f, 17.76f};
static const float LE_AMP_OUT_DB[LE_AMP_PTS] = {-2.482f, -17.02f, -18.34f, -19.3f, -18.89f};
/* The drive's treble loss before the clipper (the quiet sweeps): a high
 * shelf per drive point, none at 0 %. */
static const float LE_AMP_DRIVE_HS[LE_AMP_PTS][3] = {
    {0.0f, 0.0f, 0.0f}, {9332.0f, -2.76f, 0.51f}, {9004.0f, -4.35f, 0.51f},
    {8378.0f, -7.44f, 0.50f}, {9506.0f, -13.12f, 0.33f}};
/* Modern: the square-law coefficient; the low shelf (34 Hz, Q 0.54), the
 * 5.3 kHz rise (Q 0.22) and the high shelf (2.55 kHz, Q 1.3), dB; its level
 * into the clipper and after it, dB. */
#define LE_AMP_MLS_HZ 34.0
#define LE_AMP_MLS_Q 0.54
#define LE_AMP_MPK_HZ 5281.0
#define LE_AMP_MPK_Q 0.22
#define LE_AMP_MHS_HZ 2553.0
#define LE_AMP_MHS_Q 1.30
static const float LE_AMP_K[LE_AMP_PTS] = {0.3399f, 0.3853f, 0.1617f, 0.2122f, 0.1038f};
static const float LE_AMP_MLS_DB[LE_AMP_PTS] = {-0.78f, 0.60f, 0.0f, 5.20f, 7.99f};
static const float LE_AMP_MPK_DB[LE_AMP_PTS] = {-3.55f, -2.69f, 0.0f, 4.00f, 8.34f};
static const float LE_AMP_MHS_DB[LE_AMP_PTS] = {-2.09f, -1.21f, 0.0f, 0.44f, 0.07f};
static const float LE_AMP_MPRE_DB[LE_AMP_PTS] = {-1.763f, -0.4865f, 0.0f, 3.377f, 6.943f};
static const float LE_AMP_MPOST_DB[LE_AMP_PTS] = {-3.187f, -1.593f, 0.0f, -1.137f, -2.273f};
/* Bass and Treble: each setting's shelf (corner Hz, gain dB, Q). 50 % is
 * flat: between 25 and 75 % the gain goes to 0 dB on its neighbour's corner
 * and Q. */
static const float LE_AMP_BASS[LE_AMP_PTS][3] = {
    {74.0f, -22.60f, 0.410f}, {40.0f, -12.04f, 0.471f}, {0.0f, 0.0f, 0.0f},
    {179.0f, 8.31f, 0.436f}, {263.0f, 12.88f, 0.441f}};
static const float LE_AMP_TREBLE[LE_AMP_PTS][3] = {
    {2608.0f, -8.90f, 0.869f}, {2809.0f, -6.28f, 0.846f}, {0.0f, 0.0f, 0.0f},
    {4229.0f, 6.65f, 0.920f}, {5179.0f, 13.41f, 0.864f}};

/* [t] (0..1) on a five-point table, linearly between the points. */
static float le_amp_lerp(const float* tab, float t) {
  const float x = (t < 0.0f ? 0.0f : t > 1.0f ? 1.0f : t) * (float)(LE_AMP_PTS - 1);
  int i = (int)x;
  if (i > LE_AMP_PTS - 2) i = LE_AMP_PTS - 2;
  const float f = x - (float)i;
  return tab[i] + f * (tab[i + 1] - tab[i]);
}

/* A shelf setting on a five-point table: log2 corner, gain, Q. The row
 * [flat] is no shelf: next to it the gain fades to 0 dB on the neighbouring
 * row's corner and Q. */
static void le_amp_shelf(const float tab[LE_AMP_PTS][3], int flat, float t,
                         float out[3]) {
  const float x = (t < 0.0f ? 0.0f : t > 1.0f ? 1.0f : t) * (float)(LE_AMP_PTS - 1);
  int i = (int)x;
  if (i > LE_AMP_PTS - 2) i = LE_AMP_PTS - 2;
  const float f = x - (float)i;
  const float* r0 = tab[i == flat ? i + 1 : i];
  const float* r1 = tab[i + 1 == flat ? i : i + 1];
  const float g0 = i == flat ? 0.0f : r0[1];
  const float g1 = i + 1 == flat ? 0.0f : r1[1];
  out[0] = log2f(r0[0]) + f * (log2f(r1[0]) - log2f(r0[0]));
  out[1] = g0 + f * (g1 - g0);
  out[2] = r0[2] + f * (r1[2] - r0[2]);
}

/* The clipper's knee: z / (1 + z^4)^(1/4), limiting at +-1 (two square
 * roots, no powf). */
static inline float le_amp_knee(float z) {
  const float a = z * z;
  return z / sqrtf(sqrtf(1.0f + a * a));
}

/* One instance (mono). */
typedef struct le_fx_amp {
  int32_t sr;                 /* what the filters and the bank are for; 0: unset */
  int32_t settle;             /* the next update lands every glide at once */
  int32_t tick;               /* frames to the next update */
  int32_t cab, cab_from;      /* the cabinet index heard, the one fading out */
  int32_t xf;                 /* crossfade frames left */
  int32_t moving;             /* a glide has not landed */
  float last[LE_AMP_PARAMS_N];
  float k;                    /* glide factor per update */
  /* glides, in their own units (dB, octaves, a coefficient) */
  float ga, gb, kq, mpre, mpost, mls, mpk, mhs;
  float bass[3], treble[3], dhs[3]; /* log2 Hz, dB, Q */
  float ga_lin, gb_lin, out_lin, mpre_lin;
  /* filters, a0-normalized biquads and their states */
  float pre_hp[5], pre_pk1[5], pre_pk2[5], dc_b0, dc_a1;
  float m_ls[5], m_pk[5], m_hs[5], d_hs[5];
  float post_hp_b0, post_hp_a1, t_bass[5], t_treb[5], lp1[5], lp2[5];
  float z_pre[3][2], z_dc[2], z_m[3][2], z_dhs[2], z_post_hp[2], z_tone[2][2], z_lp[2][2];
  /* the cabinet: head history (doubled), the block being filled, the
   * frequency-domain delay line, and the tail each running cabinet adds to
   * the next block */
  const le_cab_bank* bank;
  int32_t hp, j, fpos;
  float hist[2 * LE_CAB_B];
  float frame[2 * LE_CAB_B];
  float tail[2][LE_CAB_B];
  float fre[LE_CAB_MAX_PARTS][LE_CAB_NB], fim[LE_CAB_MAX_PARTS][LE_CAB_NB];
  float wr[LE_CAB_NB], wi[LE_CAB_NB], tmp[2 * LE_CAB_B];
} le_fx_amp;

static void le_amp_design(int kind, double hz, double db, double q, int sr,
                          float c[5]) {
  double d[5];
  le_eq_design(kind, hz, db, q, sr, d);
  for (int i = 0; i < 5; ++i) c[i] = (float)d[i];
}

/* A one-pole high-pass's coefficients (bilinear, prewarped). */
static void le_amp_hp1(double hz, int sr, float* b0, float* a1) {
  const double k = le_prewarp(hz, sr);
  *b0 = (float)(1.0 / (1.0 + k));
  *a1 = (float)((k - 1.0) / (k + 1.0));
}

static inline float le_amp_hp1_tick(float b0, float a1, float* z, float x) {
  /* y[n] = b0 (x[n] - x[n-1]) - a1 y[n-1]; z = {x[n-1], y[n-1]} */
  const float y = b0 * (x - z[0]) - a1 * z[1];
  z[0] = x;
  z[1] = y;
  return y;
}

/* Clears what the instance plays from (filters, the cabinet's history),
 * keeping its rate and coefficients; the next update settles. */
static void le_amp_reset(le_fx_amp* a) {
  memset(a->z_pre, 0, sizeof(a->z_pre));
  memset(a->z_dc, 0, sizeof(a->z_dc));
  memset(a->z_m, 0, sizeof(a->z_m));
  memset(a->z_dhs, 0, sizeof(a->z_dhs));
  memset(a->z_post_hp, 0, sizeof(a->z_post_hp));
  memset(a->z_tone, 0, sizeof(a->z_tone));
  memset(a->z_lp, 0, sizeof(a->z_lp));
  memset(a->hist, 0, sizeof(a->hist));
  memset(a->frame, 0, sizeof(a->frame));
  memset(a->tail, 0, sizeof(a->tail));
  memset(a->fre, 0, sizeof(a->fre));
  memset(a->fim, 0, sizeof(a->fim));
  a->hp = a->j = a->fpos = 0;
  a->xf = 0;
  a->cab_from = a->cab;
  a->tick = 0;
  a->settle = 1;
}

/* The settings' targets, glided at the update cadence; filters redesigned
 * when a setting they read moved. */
static void le_amp_update(le_fx_amp* a, const float* p, int sr) {
  const int new_rate = a->sr != sr;
  /* Settled and unchanged: nothing to do. */
  if (!new_rate && !a->settle && !a->moving &&
      memcmp(a->last, p, sizeof(a->last)) == 0) {
    return;
  }
  memcpy(a->last, p, sizeof(a->last));
  if (new_rate) {
    a->sr = sr;
    a->k = le_fx_smooth_k(sr);
    le_amp_design(LE_EQ_LOWCUT, LE_AMP_HP_HZ, 0.0, LE_AMP_HP_Q, sr, a->pre_hp);
    le_amp_design(LE_EQ_LOMID, LE_AMP_PK1_HZ, LE_AMP_PK1_DB, LE_AMP_PK1_Q, sr,
                  a->pre_pk1);
    le_amp_design(LE_EQ_LOMID, LE_AMP_PK2_HZ, LE_AMP_PK2_DB, LE_AMP_PK2_Q, sr,
                  a->pre_pk2);
    le_amp_hp1(LE_AMP_DC_HZ, sr, &a->dc_b0, &a->dc_a1);
    le_amp_hp1(LE_AMP_POST_HP_HZ, sr, &a->post_hp_b0, &a->post_hp_a1);
    le_amp_design(LE_EQ_HIGHCUT, LE_AMP_LP1_HZ, 0.0, LE_AMP_LP1_Q, sr, a->lp1);
    le_amp_design(LE_EQ_HIGHCUT, LE_AMP_LP2_HZ, 0.0, LE_AMP_LP2_Q, sr, a->lp2);
    a->bank = le_cab_bank_find(sr);
  }
  const float k = a->settle ? 1.0f : a->k;
  const float drive = p[0], bass = p[1], treble = p[2], modern = p[3];
  int cab = (int)(p[4] * 11.0f + 0.5f);
  cab = cab < 0 ? 0 : cab > 11 ? 11 : cab;
  if (a->settle) {
    a->cab = a->cab_from = cab;
    a->xf = 0;
  } else if (cab != a->cab && a->xf == 0) {
    /* Fade the old one out over the next frames: it keeps its tail, and
     * the new one's builds from the next block. */
    memcpy(a->tail[1], a->tail[0], sizeof(a->tail[0]));
    a->cab_from = a->cab;
    a->cab = cab;
    a->xf = LE_CAB_XF_FRAMES;
  }
  float tb[3], tt[3];
  le_amp_shelf(LE_AMP_BASS, 2, bass, tb);
  le_amp_shelf(LE_AMP_TREBLE, 2, treble, tt);
  float td[3];
  le_amp_shelf(LE_AMP_DRIVE_HS, 0, drive, td);
  const float tgt[8] = {le_amp_lerp(LE_AMP_GA_DB, drive),
                        le_amp_lerp(LE_AMP_GB_DB, drive),
                        le_amp_lerp(LE_AMP_K, modern),
                        le_amp_lerp(LE_AMP_MPRE_DB, modern),
                        le_amp_lerp(LE_AMP_MPOST_DB, modern) +
                            le_amp_lerp(LE_AMP_OUT_DB, drive),
                        le_amp_lerp(LE_AMP_MLS_DB, modern),
                        le_amp_lerp(LE_AMP_MPK_DB, modern),
                        le_amp_lerp(LE_AMP_MHS_DB, modern)};
  float* cur[8] = {&a->ga, &a->gb, &a->kq, &a->mpre, &a->mpost,
                   &a->mls, &a->mpk, &a->mhs};
  int moved_m = new_rate, moved_t = new_rate;
  for (int i = 0; i < 8; ++i) {
    const float before = *cur[i];
    le_fx_step_toward(cur[i], tgt[i], k);
    if (i >= 5 && *cur[i] != before) moved_m = 1;
  }
  int moved_d = new_rate;
  for (int i = 0; i < 3; ++i) {
    const float b0 = a->bass[i], t0 = a->treble[i], d0 = a->dhs[i];
    le_fx_step_toward(&a->bass[i], tb[i], k);
    le_fx_step_toward(&a->treble[i], tt[i], k);
    le_fx_step_toward(&a->dhs[i], td[i], k);
    if (a->bass[i] != b0 || a->treble[i] != t0) moved_t = 1;
    if (a->dhs[i] != d0) moved_d = 1;
  }
  int moving = cab != a->cab; /* a change waiting for a fade to end */
  for (int i = 0; i < 8; ++i) moving |= *cur[i] != tgt[i];
  for (int i = 0; i < 3; ++i) {
    moving |= a->bass[i] != tb[i] || a->treble[i] != tt[i] || a->dhs[i] != td[i];
  }
  a->moving = moving;
  if (a->settle) moved_m = moved_t = moved_d = 1;
  if (moved_d) {
    le_amp_design(LE_EQ_HIGH, exp2((double)a->dhs[0]), a->dhs[1], a->dhs[2], sr,
                  a->d_hs);
  }
  a->ga_lin = powf(10.0f, a->ga / 20.0f);
  a->gb_lin = powf(10.0f, a->gb / 20.0f);
  a->mpre_lin = powf(10.0f, a->mpre / 20.0f);
  a->out_lin = powf(10.0f, a->mpost / 20.0f);
  if (moved_m) {
    le_amp_design(LE_EQ_LOW, LE_AMP_MLS_HZ, a->mls, LE_AMP_MLS_Q, sr, a->m_ls);
    le_amp_design(LE_EQ_LOMID, LE_AMP_MPK_HZ, a->mpk, LE_AMP_MPK_Q, sr, a->m_pk);
    le_amp_design(LE_EQ_HIGH, LE_AMP_MHS_HZ, a->mhs, LE_AMP_MHS_Q, sr, a->m_hs);
  }
  if (moved_t) {
    le_amp_design(LE_EQ_LOW, exp2((double)a->bass[0]), a->bass[1], a->bass[2],
                  sr, a->t_bass);
    le_amp_design(LE_EQ_HIGH, exp2((double)a->treble[0]), a->treble[1],
                  a->treble[2], sr, a->t_treb);
  }
  a->settle = 0;
}

/* One sample through the cabinet, both cabinets while one fades into the
 * other; at a block's end the partitions' spectra make the next block's
 * tails. */
static float le_amp_cab(le_fx_amp* a, float x) {
  const le_cab_bank* bk = a->bank;
  const int rn = LE_CAB_ROW[a->cab];
  const int ro = LE_CAB_ROW[a->cab_from];
  if (bk == NULL) return x;
  a->hist[a->hp] = x;
  a->hist[a->hp + LE_CAB_B] = x;
  const float* hx = a->hist + a->hp + LE_CAB_B; /* hx[-t]: t frames ago */
  float yn = 0.0f, yo = 0.0f;
  if (rn < 0) {
    yn = x;
  } else {
    const float* h = bk->head[rn];
    for (int t = 0; t < LE_CAB_B; ++t) yn += h[t] * hx[-t];
    yn += a->tail[0][a->j];
  }
  const int fading = a->xf > 0;
  if (fading) {
    if (ro < 0) {
      yo = x;
    } else {
      const float* h = bk->head[ro];
      for (int t = 0; t < LE_CAB_B; ++t) yo += h[t] * hx[-t];
      yo += a->tail[1][a->j];
    }
  }
  a->hp = (a->hp + 1) & (LE_CAB_B - 1);
  a->frame[LE_CAB_B + a->j] = x;
  if (++a->j == LE_CAB_B) {
    a->j = 0;
    const int parts = bk->parts;
    a->fpos = a->fpos + 1 >= parts ? 0 : a->fpos + 1;
    le_rfft_fwd(&le_cab_fft, a->frame, a->fre[a->fpos], a->fim[a->fpos]);
    memmove(a->frame, a->frame + LE_CAB_B, sizeof(float) * LE_CAB_B);
    for (int which = 0; which < 2; ++which) {
      const int row = which == 0 ? rn : ro;
      if (which == 1 && a->xf <= 1) break; /* the fade ends on this frame */
      if (row < 0) {
        memset(a->tail[which], 0, sizeof(a->tail[which]));
        continue;
      }
      memset(a->wr, 0, sizeof(a->wr));
      memset(a->wi, 0, sizeof(a->wi));
      for (int pp = 0; pp < parts; ++pp) {
        int s = a->fpos - pp;
        if (s < 0) s += parts;
        const float* xr = a->fre[s];
        const float* xi = a->fim[s];
        const float* hr = bk->re[row][pp];
        const float* hi = bk->im[row][pp];
        for (int q = 0; q < LE_CAB_NB; ++q) {
          a->wr[q] += xr[q] * hr[q] - xi[q] * hi[q];
          a->wi[q] += xr[q] * hi[q] + xi[q] * hr[q];
        }
      }
      le_rfft_inv(&le_cab_fft, a->wr, a->wi, a->tmp);
      memcpy(a->tail[which], a->tmp + LE_CAB_B, sizeof(float) * LE_CAB_B);
    }
  }
  if (!fading) return yn;
  const float w = (float)a->xf / (float)LE_CAB_XF_FRAMES; /* the old one's share */
  if (--a->xf == 0) a->cab_from = a->cab;
  return yn + w * (yo - yn);
}

static void fx_amp_cab_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  (void)cap;
  le_fx_amp* a = atomic_load_explicit(&fx->amp[slot], memory_order_acquire);
  if (a == NULL) return;
  const int rate = sr > 0 ? sr : 48000;
  if (a->tick <= 0 || a->sr != rate) {
    le_amp_update(a, p, rate);
    a->tick = LE_FX_UPDATE_FRAMES;
  }
  --a->tick;
  const float x = 0.5f * (fx_sanitize(*l) + fx_sanitize(*r));
  float u = le_biquad_tick(a->pre_hp, a->z_pre[0], x);
  u = le_biquad_tick(a->pre_pk1, a->z_pre[1], u);
  u = le_biquad_tick(a->pre_pk2, a->z_pre[2], u);
  u *= a->ga_lin;
  float v = u + a->kq * u * u;
  v = le_amp_hp1_tick(a->dc_b0, a->dc_a1, a->z_dc, v);
  v = le_biquad_tick(a->m_ls, a->z_m[0], v);
  v = le_biquad_tick(a->m_pk, a->z_m[1], v);
  v = le_biquad_tick(a->m_hs, a->z_m[2], v);
  v = le_biquad_tick(a->d_hs, a->z_dhs, v);
  const float w = v * a->mpre_lin * a->gb_lin;
  float y = w >= 0.0f ? LE_AMP_CLIP_POS * le_amp_knee(w / LE_AMP_CLIP_POS)
                      : LE_AMP_CLIP_NEG * le_amp_knee(w / LE_AMP_CLIP_NEG);
  y = le_amp_hp1_tick(a->post_hp_b0, a->post_hp_a1, a->z_post_hp, y);
  y = le_biquad_tick(a->t_bass, a->z_tone[0], y);
  y = le_biquad_tick(a->t_treb, a->z_tone[1], y);
  y = le_biquad_tick(a->lp1, a->z_lp[0], y);
  y = le_biquad_tick(a->lp2, a->z_lp[1], y);
  y = le_amp_cab(a, y * a->out_lin);
  *l = y;
  *r = y;
}

/* Control thread: the slot's instance, and the cabinets at this rate. */
static int32_t fx_amp_cab_prepare(le_fx_state* fx, int slot, int cap) {
  if (le_cab_bank_get(cap > 0 ? cap : 48000) == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&fx->amp[slot], memory_order_relaxed) != NULL) {
    return LE_OK;
  }
  le_fx_amp* a = (le_fx_amp*)le_rt_alloc_prefaulted(sizeof(le_fx_amp));
  if (a == NULL) return LE_ERR_INVALID;
  memset(a, 0, sizeof(*a));
  le_amp_reset(a);
  atomic_store_explicit(&fx->amp[slot], a, memory_order_release);
  return LE_OK;
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
 * Fit to the Lo-Fi and Rhythmic racks' captures in the Phase 0 gap session
 * (#1445, docs/plan/2026-10-23-looperx-gaps-measured.md). The ranges and
 * tapers are the Looper X's; each kind says what its fit covers. */

/* ---- Vinyl (LE_FX_VINYL) ----
 *
 * Fit to the Lo-Fi Rack's vinyl (1 kHz ladders from -48 to 0 dBFS at four
 * drives and four frequencies, and the noise bed in silence at five noise
 * settings):
 * - the whole input passes at 0.5 (-6.0 dB at every setting);
 * - the drive adds an even-harmonic copy above Freq: h, the input through
 *   a 12 dB/octave high-pass at Freq (Q 1.1), gives c (|h| + 4.3 h^2), a
 *   full-wave rectifier and a square law, with c = 3.75 drive^2 (0.60 at
 *   the default 40 %). The rectifier's share at 1 kHz was 0.621, 0.600,
 *   0.471 and 0.024 at Freq 251, 50, 1256 and 5000 Hz (the high-pass gives
 *   0.621, 0.601, 0.469 and 0.025), 3.88 at Drive 100 %; the square law's
 *   was 4.4 and 4.5 times the rectifier's at 40 and 100 % (4.3 times with
 *   the high-pass's 1.035 at 1 kHz taken out). The copy carries the
 *   rectifier's DC, as the Looper X's output does;
 * - a stereo-linked limiter holds the output's peaks to 0.5: at once on the
 *   way down, back up through a 57 ms release on its peak and 145 ms on its
 *   gain (fit to the recovery after a loud tone within 0.055 of gain);
 * - the noise bed, at Noise 100 %: white hiss at -65.7 dBFS, a rumble that
 *   is the same white noise through a 12 dB/octave low-pass at 80 Hz,
 *   33 dB up (the Looper X's loudest band is 63 Hz), and clicks 1/48000 s
 *   long at 10 a second whose sizes fall off as a power law from 0.04
 *   (3 a second over 0.1, up to 0.5). The tone is a 12 dB/octave low-pass
 *   from 5 kHz (0 %) to 21.6 kHz (100 %) over all three. The whole bed
 *   scales as noise^3 (the captured bands fell 20 dB at 50 % and 33 dB at
 *   30 %). Between the clicks, the octave bands from 63 Hz to 16 kHz fall
 *   within 3.7 dB of the capture's at all five settings; the clicks over
 *   0.1 come at the capture's rate (1.5 a second against 1.1 to 1.6). The
 *   Looper X's crackle also has a low thump in it that these clicks lack.
 *   The hiss is 90 % shared between the sides, the rumble and the clicks
 *   fully: the sides correlate at 0.99 (the Looper X's 0.89 to 0.99).
 * The noise runs on whatever the loop does, so a vinyl with noise up never
 * prints. */
static const le_fx_param_desc LE_FX_VINYL_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.4f,
     0},
    {"frequency", LE_FX_UNIT_HZ, 0, 50.0f, 5000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.35f, 0},
    {"noise", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.3f,
     0},
    {"noise_tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.9f, 0},
};
#define LE_VIN_PARAMS_N 4
#define LE_VIN_DRY 0.5f
#define LE_VIN_RECT 3.75f   /* the rectifier at 100 % drive, x drive^2 */
#define LE_VIN_SQUARE 4.3f  /* the square law, x the rectifier */
#define LE_VIN_SPLIT_Q 1.1
#define LE_VIN_CEIL 0.5f
#define LE_VIN_PEAK_S 0.057
#define LE_VIN_GAIN_S 0.145
#define LE_VIN_HISS 9.0e-4f   /* the hiss's peak at 48 kHz: -65.7 dBFS rms */
#define LE_VIN_OWN 0.33f      /* each side's own share of the hiss */
#define LE_VIN_RUMBLE_HZ 80.0
#define LE_VIN_RUMBLE 45.0f   /* the rumble over the hiss it filters */
#define LE_VIN_CLICK_MIN 0.04f /* clicks are this size or more ... */
#define LE_VIN_CLICK_MAX 0.5f
#define LE_VIN_CLICK_POW (-0.8f) /* ... size = min u^this, u in (0, 1] */
#define LE_VIN_CLICK_HZ 10.0
#define LE_VIN_NOISE_POW 3.0
#define LE_VIN_TONE_LO_HZ 5000.0
#define LE_VIN_TONE_HI_HZ 21600.0

typedef struct le_fx_vinyl {
  le_fx_dyn_head h;
  float last[LE_VIN_PARAMS_N];
  le_fx_glide gain;  /* the copy's gain c */
  le_fx_glide noise; /* the bed's level, noise^3 */
  float hz_l2, hz_tgt; /* the high-pass corner, log2 Hz */
  float tone_l2, tone_tgt;
  float hp[5];
  float click_odds; /* a click per sample */
  float z_hp[2][2];
  uint32_t rng[2];
  float tone[5]; /* the tone's low-pass */
  float rumble[5];
  float hiss; /* the hiss's peak at this rate */
  float peak_rel, gain_rel; /* the limiter's release coefficients */
  float peak, lim;
  int32_t tone_open; /* the tone at or past 0.45 of the rate: no filter */
  float z_tone[2][2];
  float z_rumble[2];
  uint32_t rng_shared;
  float click;       /* the click under way */
  int32_t click_left; /* its samples still to come */
  int32_t click_len;  /* a click's samples: 1/48000 s at this rate */
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
    v->rng_shared = (seed * 40503u + 0x9E3779B9u) | 1u;
    v->lim = 1.0f;
  }
  if (f & LE_FX_DYN_NEW_RATE) {
    double c[5];
    le_eq_design(LE_EQ_HIGHCUT, LE_VIN_RUMBLE_HZ, 0.0, 0.70710678, rate, c);
    for (int i = 0; i < 5; ++i) v->rumble[i] = (float)c[i];
    v->peak_rel = le_one_pole(LE_VIN_PEAK_S, rate);
    v->gain_rel = le_one_pole(LE_VIN_GAIN_S, rate);
    /* The hiss keeps its density per Hz at any rate. */
    v->hiss = (float)(LE_VIN_HISS * sqrt((double)rate / 48000.0));
    v->click_odds = (float)(4294967295.0 * LE_VIN_CLICK_HZ / (double)rate);
    v->click_len = (int32_t)((double)rate / 48000.0 + 0.5);
    if (v->click_len < 1) v->click_len = 1;
  }
  const le_fx_param_desc* d = LE_FX_VINYL_PARAMS;
  const float drive = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float noise = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  if (f & LE_FX_DYN_CHANGED) {
    v->hz_tgt = (float)log2(le_fx_desc_value(&d[1], p[1]));
    const float t = p[3] < 0.0f ? 0.0f : p[3] > 1.0f ? 1.0f : p[3];
    v->tone_tgt = (float)log2(LE_VIN_TONE_LO_HZ *
                              pow(LE_VIN_TONE_HI_HZ / LE_VIN_TONE_LO_HZ, t));
  }
  int moving = le_fx_glide_step(&v->gain, LE_VIN_RECT * drive * drive, k);
  moving |= le_fx_glide_step(&v->noise,
                             (float)pow((double)noise, LE_VIN_NOISE_POW), k);
  if (v->hz_l2 != v->hz_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&v->hz_l2, v->hz_tgt, k);
    double c[5];
    le_eq_design(LE_EQ_LOWCUT, exp2((double)v->hz_l2), 0.0, LE_VIN_SPLIT_Q, rate,
                 c);
    for (int i = 0; i < 5; ++i) v->hp[i] = (float)c[i];
  }
  if (v->tone_l2 != v->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&v->tone_l2, v->tone_tgt, k);
    const double hz = exp2((double)v->tone_l2);
    const int32_t open = hz >= 0.45 * (double)rate;
    /* Back from open, the filter starts clean rather than from old state. */
    if (open != v->tone_open) memset(v->z_tone, 0, sizeof(v->z_tone));
    v->tone_open = open;
    double c[5];
    le_eq_design(LE_EQ_HIGHCUT, hz, 0.0, 0.70710678, rate, c);
    for (int i = 0; i < 5; ++i) v->tone[i] = (float)c[i];
  }
  moving |= v->hz_l2 != v->hz_tgt || v->tone_l2 != v->tone_tgt;
  v->h.moving = moving;
}

static void fx_vinyl_kprocess(void* ks, float* l, float* r) {
  le_fx_vinyl* v = (le_fx_vinyl*)ks;
  const float c = le_fx_glide_next(&v->gain);
  const float n = le_fx_glide_next(&v->noise);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  float shared = 0.0f;
  if (n <= 0.0f) {
    /* Silent: nothing left to come back when the noise is raised. */
    v->z_rumble[0] = v->z_rumble[1] = 0.0f;
    v->z_tone[0][0] = v->z_tone[0][1] = v->z_tone[1][0] = v->z_tone[1][1] = 0.0f;
  } else {
    const float w = v->hiss * le_noise(&v->rng_shared);
    shared = w + LE_VIN_RUMBLE * le_biquad_tick(v->rumble, v->z_rumble, w);
    /* A click when the draw falls under the odds, at a random sign and a
     * size from the power law. It lasts 1/48000 s at any rate (the
     * captured clicks were single samples at 48 kHz), so its level under
     * the tone does not fall as the rate rises. */
    if (le_xorshift(&v->rng_shared) < (uint32_t)v->click_odds) {
      const uint32_t draw = le_xorshift(&v->rng_shared);
      const float u = (float)((draw >> 8) + 1u) * (1.0f / 16777216.0f);
      float size = LE_VIN_CLICK_MIN * powf(u, LE_VIN_CLICK_POW);
      if (size > LE_VIN_CLICK_MAX) size = LE_VIN_CLICK_MAX;
      v->click = (draw & 1u) ? size : -size;
      v->click_left = v->click_len;
    }
    if (v->click_left > 0) {
      shared += v->click;
      --v->click_left;
    }
  }
  for (int ch = 0; ch < 2; ++ch) {
    const float x = io[ch];
    const float hcopy = le_biquad_tick(v->hp, v->z_hp[ch], x);
    float y = LE_VIN_DRY * x + c * (fabsf(hcopy) + LE_VIN_SQUARE * hcopy * hcopy);
    if (n > 0.0f) {
      float bed = n * (shared + LE_VIN_OWN * v->hiss * le_noise(&v->rng[ch]));
      if (!v->tone_open) bed = le_biquad_tick(v->tone, v->z_tone[ch], bed);
      y += bed;
    }
    io[ch] = y;
  }
  /* The limiter: the peak follows the louder side at once and falls back
   * through its release; the gain drops to the ceiling at once and rises
   * through its own. */
  const float a0 = fabsf(io[0]);
  const float a1 = fabsf(io[1]);
  const float a = a0 > a1 ? a0 : a1;
  v->peak = a > v->peak ? a : a + v->peak_rel * (v->peak - a);
  const float want = v->peak > LE_VIN_CEIL ? LE_VIN_CEIL / v->peak : 1.0f;
  v->lim = want < v->lim ? want : want + v->gain_rel * (v->lim - want);
  *l = v->lim * io[0];
  *r = v->lim * io[1];
}

/* ---- Degrade (LE_FX_DEGRADE) ----
 *
 * Fit to the Lo-Fi Rack's degrade (noise responses and 1 kHz images at
 * holds of 1581, 5000 and 15 811 Hz):
 * - a sample-and-hold at the display's rate (the images put the Looper X's
 *   hold 0.5 to 2.5 % above it); at or above the engine's rate it holds
 *   every sample;
 * - the filter control runs the other way to its name: 100 % (the default)
 *   is no filter, 0 % the strongest, a steep low-pass of two 2nd-order
 *   sections (Q 0.91 and 1.83) at 0.194 of the hold rate (fit within
 *   2.4 dB rms below 0.8 of the hold, with the +3 dB rise just under the
 *   corner); at 50 % the corner fits at 0.89 of the hold (3.0 dB rms), and
 *   in between it moves in log, 0.194 x 4.59^(2 filter), off at 100 %;
 * - the mix crossfades dry to held (0 % bit-exact dry).
 * Two differences stay: the Looper X's hold droops less than a
 * sample-and-hold does (1 kHz on a 1581 Hz hold: -3.1 dB, here -6.8), and
 * its held path runs about 10 samples late, which combs a 50 % mix (-4.2 dB
 * at 1 kHz; here the held path is not delayed, -0.7 dB).
 * The hold runs on whatever the loop does, so a degrade that holds never
 * prints. */
static const le_fx_param_desc LE_FX_DEGRADE_PARAMS[] = {
    {"frequency", LE_FX_UNIT_HZ, 0, 500.0f, 50000.0f, LE_FX_CURVE_EXPONENTIAL,
     1.0f, 0},
    {"filter", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f,
     0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f, 0},
};
#define LE_DEG_PARAMS_N 3
#define LE_DEG_RATIO 0.194  /* the corner over the hold, at 0 % */
#define LE_DEG_RATIO_MID 0.89 /* at 50 % */
#define LE_DEG_Q1 0.91
#define LE_DEG_Q2 1.83

typedef struct le_fx_degrade {
  le_fx_dyn_head h;
  float last[LE_DEG_PARAMS_N];
  le_fx_glide step; /* the hold's phase step per sample (1: every sample) */
  le_fx_glide mix;
  float lp_l2, lp_tgt; /* the low-pass corner, log2 Hz */
  double ph;
  float held[2];
  le_fx_glide amount; /* 1 filtering, 0 off (filter at 100 %) */
  float c1[5], c2[5];
  float z1[2][2], z2[2][2];
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
  const float v = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    double corner = hz * LE_DEG_RATIO *
                    pow(LE_DEG_RATIO_MID / LE_DEG_RATIO, 2.0 * (double)v);
    if (corner > 0.45 * rate) corner = 0.45 * rate;
    q->lp_tgt = (float)log2(corner);
  }
  const float m = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  int moving = le_fx_glide_step(&q->step, step, k);
  moving |= le_fx_glide_step(&q->mix, m, k);
  moving |= le_fx_glide_step(&q->amount, v >= 1.0f ? 0.0f : 1.0f, k);
  if (q->lp_l2 != q->lp_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&q->lp_l2, q->lp_tgt, k);
    double c[5];
    le_eq_design(LE_EQ_HIGHCUT, exp2((double)q->lp_l2), 0.0, LE_DEG_Q1, rate, c);
    for (int i = 0; i < 5; ++i) q->c1[i] = (float)c[i];
    le_eq_design(LE_EQ_HIGHCUT, exp2((double)q->lp_l2), 0.0, LE_DEG_Q2, rate, c);
    for (int i = 0; i < 5; ++i) q->c2[i] = (float)c[i];
  }
  moving |= q->lp_l2 != q->lp_tgt;
  q->h.moving = moving;
}

static void fx_degrade_kprocess(void* ks, float* l, float* r) {
  le_fx_degrade* q = (le_fx_degrade*)ks;
  const float step = le_fx_glide_next(&q->step);
  const float m = le_fx_glide_next(&q->mix);
  const float amount = le_fx_glide_next(&q->amount);
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  q->ph += (double)step;
  const int take = q->ph >= 1.0;
  if (take) q->ph -= 1.0;
  float y[2];
  for (int ch = 0; ch < 2; ++ch) {
    if (take) q->held[ch] = x[ch];
    float wet = q->held[ch];
    if (amount <= 0.0f) {
      /* No filter: its memory cleared so it starts clean when it comes
       * back. */
      q->z1[ch][0] = q->z1[ch][1] = q->z2[ch][0] = q->z2[ch][1] = 0.0f;
    } else {
      const float lp = le_biquad_tick(
          q->c2, q->z2[ch], le_biquad_tick(q->c1, q->z1[ch], wet));
      wet = amount >= 1.0f ? lp : wet + amount * (lp - wet);
    }
    y[ch] = x[ch] + m * (wet - x[ch]);
  }
  *l = y[0];
  *r = y[1];
}

/* ---- LPF (LE_FX_LPF) ----
 *
 * Fit to the Lo-Fi and Rhythmic racks' LPF (the same filter with the LFO at
 * 0; noise responses at three cutoffs and three resonances, 1 kHz ladders,
 * and the self-oscillation in silence):
 * - a 4-pole (24 dB/octave) zero-delay-feedback ladder, four TPT one-poles
 *   with feedback k around them and the passband held at unity, small-signal
 *   H = (1 + k) P^4 / (1 + k P^4): the feedback takes the output minus the
 *   input, u = x - k f(y - x), so the passband stays at unity at any level;
 * - k = 0.2 + 4.2 reso^1.15 (fits 0.20 at 0 % and 2.06 at 50 %), past 4 at
 *   92 % and up, where the filter oscillates;
 * - f(v) = tanh(2.4 v) / 2.4 bounds the feedback: the oscillation settles
 *   at about 0.27 peak (the Looper X's 0.25 and 0.28), and a loud tone
 *   above the corner loses some resonance (1 kHz at a 632 Hz corner,
 *   50 %: -10.3 dB at -48 dBFS to -15.0 dB at 0 dBFS, the Looper X's -9.7
 *   to -17.1);
 * - the corner is 1.04 x the cutoff at 0 % resonance, 1.015 x at 100 %, so
 *   the oscillation lands within 1 % of where the Looper X's does (644.5 Hz
 *   for 632 Hz shown, 3575.5 for 3557); the responses fit within 0.4 dB at
 *   632 Hz (0 and 50 %) and 0.7 dB at 112 Hz, down to -50 dB; at 3557 Hz
 *   the ladder at the
 *   engine's rate falls faster than the Looper X's above 8 kHz (-31 dB
 *   against -27 at 8 kHz, -48 against -40 at 12 kHz);
 * - a one-pole high-pass at 25.3 Hz in front (-4.2 dB at 20 Hz and -1.0 dB
 *   at 50 Hz; the Looper X's -3.9 and -1.1).
 * An oscillating filter starts on its own: its first stage starts from a
 * 1e-9 offset rather than 0, and gets it again whenever the stages have
 * died away in silence, so it rises out of digital silence in about 0.2 s
 * (632 Hz), as the Looper X's sounds in silence.
 * The Looper X's filter also adds a second harmonic (-23 dBc for a
 * -12 dBFS tone above the corner); this one adds none. At the top of the
 * cutoff's range the filter is off (the Looper X's default; its filter
 * there is within 0.3 dB to 12 kHz), gliding in and out as the EQ's cuts
 * do. An oscillating filter sounds on its own, so it never prints. The
 * Rhythmic Rack's LFO over the cutoff runs on the beat (#887 part 10; see
 * fx_lpf_update). */
static const le_fx_param_desc LE_FX_LPF_PARAMS[] = {
    {"cutoff", LE_FX_UNIT_HZ, 0, 20.0f, 20000.0f, LE_FX_CURVE_EXPONENTIAL,
     1.0f, LE_FX_PARAM_OFF_AT_MAX},
    {"resonance", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, 0},
    /* The Rhythmic Rack's LFO over the cutoff: its depth (0 leaves the
     * cutoff still, as the Lo-Fi Rack's has it) and its rate, a note value
     * in LE_LPF_LFO_QUARTERS's order. */
    {"lfo_depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
    {"lfo_rate", LE_FX_UNIT_CHOICE, 16, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.4f,
     0},
};
#define LE_LPF_PARAMS_N 4
#define LE_LPF_K0 0.2
#define LE_LPF_K1 4.2
#define LE_LPF_K_POW 1.15
#define LE_LPF_FC_LO 1.04  /* the corner over the cutoff at 0 % */
#define LE_LPF_FC_HI 1.015 /* at 100 % */
#define LE_LPF_SAT 2.4f
#define LE_LPF_HP_HZ 25.3
#define LE_LPF_SEED 1e-9f /* the first stage's start, so it can oscillate */
#define LE_LPF_DEAD 1e-30f /* under this the stages have died away */

/* The resonance from which the ladder oscillates (k > 4). */
static double le_lpf_osc_reso(void) {
  return pow((4.0 - LE_LPF_K0) / LE_LPF_K1, 1.0 / LE_LPF_K_POW);
}

/* The LFO's period at each rate position, in quarter notes: 8/4, 6/4, 5/4,
 * 4/4, 3/4, 1T, 2, 4D, 2T, 4, 8D, 4T, 8, 16D, 8T, 16, the order of the
 * Looper X binary's 16-entry note-value table for the LFO (NoteDiv16,
 * longest first); the capture confirmed position 6 (2, 1 s at 120 BPM). */
static const double LE_LPF_LFO_QUARTERS[16] = {
    8.0, 6.0, 5.0,       4.0,  3.0,       8.0 / 3.0, 2.0,   1.5,
    4.0 / 3.0, 1.0, 0.75, 2.0 / 3.0, 0.5, 0.375,     1.0 / 3.0, 0.25};
/* The octaves the cutoff's whole range spans (20 Hz to 20 kHz). */
#define LE_LPF_RANGE_OCT 9.965784284662087
/* The LFO's swing in the stored cutoff: LE_LPF_LFO_SWING Depth^LE_LPF_LFO_EXP
 * either side, fit to the capture's whole cycle at Depth 50 and 100 % (#891,
 * gD passes 3 and 4): +-1.56 and +-7.2 octaves. */
#define LE_LPF_LFO_SWING 0.72
#define LE_LPF_LFO_EXP 2.2

typedef struct le_fx_lpf {
  le_fx_dyn_head h;
  float last[LE_LPF_PARAMS_N];
  double beat;      /* the beat the coming update lands on (fx_lpf_beat) */
  float l2, tgt;    /* the corner, log2 Hz, without the LFO */
  float lfo;        /* the LFO's offset to the corner now, octaves */
  float lfo_max;    /* the most the offset moves in an update, octaves */
  float k, ktgt;    /* the feedback */
  le_fx_glide amount; /* 1 filtering, 0 off (cutoff at the top) */
  float g;     /* the one-pole's G = g / (1 + g), now */
  float g_inc; /* its step a frame toward the update's G */
  int32_t g_n; /* the frames that step still runs */
  float sb[4]; /* each stage state's share of the output */
  float g4;    /* G^4 */
  float inv;   /* 1 / (1 + k G^4) */
  float gh;    /* the high-pass one-pole's G */
  float s[2][4];
  float sh[2];
} le_fx_lpf;

/* The fastest the LFO's offset moves, octaves a second: above the fastest
 * sweep (1/16 at 300 BPM, Depth 100 %: about 900), so a sweep runs as
 * computed, while a beat that jumps (a loop top that is not a whole number
 * of periods, a new rate or depth) moves the corner over a millisecond or
 * so rather than at once. */
#define LE_LPF_LFO_MAX_OCT_S 1500.0

/* [q]'s ladder coefficients for the one-pole G [G]. */
static void le_lpf_coefs(le_fx_lpf* q, double G) {
  /* The output from the stages' states: y = G^4 u + sum sb[i] s[i]. */
  q->g = (float)G;
  q->sb[0] = (float)(G * G * G * (1.0 - G));
  q->sb[1] = (float)(G * G * (1.0 - G));
  q->sb[2] = (float)(G * (1.0 - G));
  q->sb[3] = (float)(1.0 - G);
  const double g4 = G * G * G * G;
  q->g4 = (float)g4;
  q->inv = (float)(1.0 / (1.0 + (double)q->k * g4));
}

static void fx_lpf_update(void* ks, const float* p, int sr, int settle) {
  le_fx_lpf* q = (le_fx_lpf*)ks;
  /* Oscillating, a side whose stages have all died away in silence (to 0,
   * or to the denormal crumbs where growth no longer works) gets the seed
   * again, so it starts on its own. */
  if (q->k > 4.0f) {
    for (int ch = 0; ch < 2; ++ch) {
      const float* st = q->s[ch];
      if (fabsf(st[0]) < LE_LPF_DEAD && fabsf(st[1]) < LE_LPF_DEAD &&
          fabsf(st[2]) < LE_LPF_DEAD && fabsf(st[3]) < LE_LPF_DEAD) {
        q->s[ch][0] = LE_LPF_SEED;
      }
    }
  }
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_LPF_PARAMS_N, sr, settle);
  if (!f) return;
  const float k = settle ? 1.0f : q->h.k;
  if (settle) q->s[0][0] = q->s[1][0] = LE_LPF_SEED;
  if (f & LE_FX_DYN_CHANGED) {
    const double v = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : p[1];
    const double ratio = LE_LPF_FC_LO + (LE_LPF_FC_HI - LE_LPF_FC_LO) * v;
    q->tgt = (float)log2(ratio * le_fx_desc_value(&LE_FX_LPF_PARAMS[0], p[0]));
    q->ktgt = (float)(LE_LPF_K0 + LE_LPF_K1 * pow(v, LE_LPF_K_POW));
  }
  if (f & LE_FX_DYN_NEW_RATE) {
    const double gh = le_prewarp(LE_LPF_HP_HZ, sr);
    q->gh = (float)(gh / (1.0 + gh));
    q->lfo_max = (float)(LE_LPF_LFO_MAX_OCT_S * (double)LE_FX_UPDATE_FRAMES /
                         (double)sr);
  }
  const int sweeping = p[2] > 0.0f && p[0] < 1.0f;
  const float l2_was = q->l2;
  const float k_was = q->k;
  le_fx_step_toward(&q->l2, q->tgt, k);
  le_fx_step_toward(&q->k, q->ktgt, k);
  /* The LFO (#891, gD): a sine in log frequency, rising from the start of
   * each period of the beat, that swings the stored cutoff by
   * LE_LPF_LFO_SWING Depth^LE_LPF_LFO_EXP, held to the cutoff's range
   * around the corner as it glides. */
  float lfo = 0.0f;
  if (sweeping) {
    const double d = p[2] > 1.0f ? 1.0 : p[2];
    int ri = (int)(p[3] * 15.0f + 0.5f);
    ri = ri < 0 ? 0 : ri > 15 ? 15 : ri;
    double ph = fmod(q->beat / LE_LPF_LFO_QUARTERS[ri], 1.0);
    if (ph < 0.0) ph += 1.0;
    const double swing = LE_LPF_LFO_SWING * pow(d, LE_LPF_LFO_EXP) *
                         LE_LPF_RANGE_OCT *
                         sin(2.0 * 3.14159265358979323846 * ph);
    /* The range's ends, log2 Hz, at the corner's ratio to the cutoff. */
    const double ratio_l2 =
        (double)q->tgt - log2(le_fx_desc_value(&LE_FX_LPF_PARAMS[0], p[0]));
    const double lo = log2(20.0) + ratio_l2;
    const double hi = log2(20000.0) + ratio_l2;
    double corner = (double)q->l2 + swing;
    corner = corner < lo ? lo : corner > hi ? hi : corner;
    lfo = (float)(corner - (double)q->l2);
  }
  const float lfo_was = q->lfo;
  if (settle) {
    q->lfo = lfo;
  } else {
    const float d = lfo - q->lfo;
    q->lfo += d > q->lfo_max ? q->lfo_max : d < -q->lfo_max ? -q->lfo_max : d;
  }
  if (q->l2 != l2_was || q->k != k_was || q->lfo != lfo_was || settle ||
      (f & LE_FX_DYN_CHANGED) || q->g_n > 0) {
    const double g = le_prewarp(exp2((double)(q->l2 + q->lfo)), sr);
    const double G = g / (1.0 + g);
    if (settle || (f & LE_FX_DYN_NEW_RATE)) {
      le_lpf_coefs(q, G);
      q->g_inc = 0.0f;
      q->g_n = 0;
    } else {
      /* The samples up to the next update ramp G onto it. */
      q->g_inc = (float)((G - (double)q->g) / (double)LE_FX_UPDATE_FRAMES);
      q->g_n = LE_FX_UPDATE_FRAMES;
      if (q->g + q->g_inc == q->g) { /* closer than a step can show */
        le_lpf_coefs(q, G);
        q->g_inc = 0.0f;
        q->g_n = 0;
      }
    }
  }
  const int moving = le_fx_glide_step(&q->amount, p[0] >= 1.0f ? 0.0f : 1.0f, k);
  q->h.moving = moving || q->l2 != q->tgt || q->k != q->ktgt || sweeping ||
                q->lfo != 0.0f || q->g_n > 0;
}

static void fx_lpf_beat(void* ks, double beat) {
  ((le_fx_lpf*)ks)->beat = beat;
}

static void fx_lpf_kprocess(void* ks, float* l, float* r) {
  le_fx_lpf* q = (le_fx_lpf*)ks;
  const float amount = le_fx_glide_next(&q->amount);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  if (amount <= 0.0f) {
    /* Off: the identity, with the filter's memory cleared (but for the
     * seed) so it starts clean when it comes back, and any ramp of G
     * landed so the updates go idle. */
    if (q->g_n > 0) {
      le_lpf_coefs(q, (double)(q->g + q->g_inc * (float)q->g_n));
      q->g_inc = 0.0f;
      q->g_n = 0;
    }
    memset(q->s, 0, sizeof(q->s));
    q->s[0][0] = q->s[1][0] = LE_LPF_SEED;
    q->sh[0] = q->sh[1] = 0.0f;
    *l = io[0];
    *r = io[1];
    return;
  }
  if (q->g_n > 0) {
    le_lpf_coefs(q, (double)(q->g + q->g_inc));
    --q->g_n;
  }
  const float G = q->g;
  const float fb = q->k;
  for (int ch = 0; ch < 2; ++ch) {
    float* s = q->s[ch];
    /* The high-pass: the input less a one-pole low-pass of it. */
    const float vh = (io[ch] - q->sh[ch]) * q->gh;
    const float low = vh + q->sh[ch];
    q->sh[ch] = low + vh;
    const float x = io[ch] - low;
    /* The ladder: solve the loop as if f were linear, then bound the
     * feedback with f at that estimate. */
    const float st = q->sb[0] * s[0] + q->sb[1] * s[1] + q->sb[2] * s[2] +
                     q->sb[3] * s[3];
    const float u_lin = (x * (1.0f + fb) - fb * st) * q->inv;
    const float e = q->g4 * u_lin + st - x;
    float u = x - fb * tanhf(LE_LPF_SAT * e) * (1.0f / LE_LPF_SAT);
    for (int i = 0; i < 4; ++i) {
      const float vv = (u - s[i]) * G;
      const float o = vv + s[i];
      s[i] = o + vv;
      u = o;
    }
    io[ch] = amount >= 1.0f ? u : io[ch] + amount * (u - io[ch]);
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

/* ---- Dub-Verb and Amb-Verb (LE_FX_DUB_VERB, LE_FX_AMB_VERB, #1430) ----
 *
 * Fit to the Phase 0 captures of the Dub Rack's two reverbs (#891,
 * docs/plan/2026-10-23-looperx-dub-reverbs-measured.md): impulse responses
 * at every Dec from 0 to 0.9 and Vol from 0 to 1. One structure serves both,
 * from a definition per kind (le_verb_def):
 * - the mono input, a pre-delay per side and a two-stage all-pass diffuser
 *   per side, heard directly (the early part, the same at every Dec, as
 *   measured) and fed into
 * - an eight-line feedback delay network (Householder mixing), each line
 *   with a first-order low shelf, a first-order high shelf and a gain
 *   designed so it decays at the measured T30 at 125 Hz, mid (500 Hz - 1 kHz)
 *   and 8 kHz for the Dec setting (le_verb_t, the capture's table, extended
 *   above Dec 0.9 by the doc's power law);
 * - an output equalizer for the wet spectrum, and the Amb-Verb's two strong
 *   early taps (32.79 ms left, 40.48 ms right) and the Dub-Verb's small
 *   negative tail right after the dry;
 * - the Vol law: a dry gain that falls (to 0.66, 0.71) and a wet gain, both
 *   interpolated from the captures.
 * Measured against the captures at Dec 0.1, 0.5 and 0.8 (Dub) and 0.2, 0.5
 * and 0.8 (Amb): wet energy within 0.4 dB, the first 90 ms within 0.2 dB,
 * the octave-band T30 from 125 Hz to 8 kHz within 14 % (most within 6 %),
 * the octave-band spectrum within 1 dB, the first arrivals to a sample,
 * left and right uncorrelated (test_dub_verbs_match_the_captures).
 * A known difference: the echo density builds faster than the Dub-Verb's
 * (0.6 against 0.4 at 100 ms) and slower than the Amb-Verb's (0.4 against
 * 0.9 at 200 ms). The long lines live in the slot's two
 * one-second rings (fx_stereo_ring_prepare); the block holds the filters and
 * write positions. A ring can hold another type's audio, or this one's at
 * another rate (a retype or a rate change keeps the rings): every structure
 * reads silence until its write position has wrapped once since the block
 * was cleared, so nothing it did not write ever sounds. Dec glides, and the
 * lines are redesigned only while it moves. */
#define LE_VB_LINES 8
#define LE_VB_APS 2
#define LE_VB_TN 10
#define LE_VB_WN 7

typedef struct {
  double pd_ms[2];
  double ap_ms[2][LE_VB_APS];
  float ap_g;
  float early_g;
  float late_g;
  double tap_ms[2]; /* the Amb-Verb's strong early taps; 0 for none */
  float tap_g[2];
  double line_ms[LE_VB_LINES];
  signed char cin[LE_VB_LINES]; /* injection signs (even lines take left) */
  signed char cl[LE_VB_LINES];  /* output signs, over sqrt(8) */
  signed char cr[LE_VB_LINES];
  double lo_hz; /* the lines' shelf corners */
  double hi_hz;
  double shelf_hz; /* the output's first-order high shelf */
  double shelf_k;
  double peak_hz; /* the output's peaking cut; 0 dB for none */
  double peak_db;
  double peak_q;
  float tail_g; /* the immediate tail, tail_g * tail_p^k at lag k >= 1 */
  float tail_p;
  int tn; /* the decay table: T30 (s) at 125 Hz, mid and 8 kHz against Dec */
  double tv[LE_VB_TN];
  double tlo[LE_VB_TN];
  double tmid[LE_VB_TN];
  double thi[LE_VB_TN];
  double law_exp;  /* mid above the table: (display ratio)^law_exp */
  int hi_by_rate;  /* above the table, 8 kHz keeps its excess decay rate */
  double dry[LE_VB_WN]; /* the dry gain at LE_VB_WV */
} le_verb_def;

/* The Vol points the dry and wet laws are tabulated at, and the wet law
 * (the same for both reverbs, measured to 0.01). */
static const double LE_VB_WV[LE_VB_WN] = {0.0, 0.1, 0.3, 0.5, 0.7, 0.85, 1.0};
static const double LE_VB_WET[LE_VB_WN] = {0.0,   0.124, 0.346, 0.552,
                                            0.753, 0.895, 1.0};

static const le_verb_def LE_DUB_VERB_DEF = {
    .pd_ms = {10.19, 10.65},
    .ap_ms = {{7.13, 11.31}, {6.71, 12.07}},
    .ap_g = 0.5f,
    .early_g = 0.40f,
    .late_g = 0.18f,
    .line_ms = {31.3, 33.9, 36.7, 38.9, 41.3, 44.6, 47.3, 51.1},
    .cin = {-1, -1, -1, -1, 1, -1, -1, -1},
    .cl = {1, -1, -1, -1, -1, 1, 1, 1},
    .cr = {1, 1, -1, 1, 1, 1, -1, 1},
    .lo_hz = 200.0,
    .hi_hz = 4000.0,
    .shelf_hz = 5000.0,
    .shelf_k = 0.35,
    .tail_g = -0.162f,
    .tail_p = 0.415f,
    .tn = 10,
    .tv = {0.0, 0.02, 0.05, 0.1, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9},
    .tlo = {0.413, 0.533, 0.711, 0.834, 1.555, 2.653, 3.403, 4.772, 7.534,
            14.361},
    .tmid = {0.356, 0.491, 0.679, 0.832, 1.556, 2.635, 3.370, 4.745, 7.408,
             14.132},
    .thi = {0.386, 0.451, 0.638, 0.786, 1.318, 2.036, 2.526, 3.114, 3.967,
            5.564},
    .law_exp = 0.845,
    .hi_by_rate = 1,
    .dry = {1.0, 1.0, 0.9742, 0.8959, 0.8324, 0.7588, 0.6616},
};

static const le_verb_def LE_AMB_VERB_DEF = {
    .pd_ms = {24.58, 24.58},
    .ap_ms = {{1.73, 3.11}, {2.41, 4.07}},
    .ap_g = 0.5f,
    .early_g = 0.35f,
    .late_g = 0.20f,
    .tap_ms = {32.79, 40.48},
    .tap_g = {0.30f, 0.33f},
    .line_ms = {52.1, 59.7, 63.4, 68.5, 71.0, 76.1, 78.5, 94.1},
    .cin = {1, -1, -1, -1, 1, -1, -1, -1},
    .cl = {1, 1, -1, 1, -1, 1, 1, -1},
    .cr = {1, -1, -1, -1, 1, 1, -1, -1},
    .lo_hz = 150.0,
    .hi_hz = 6000.0,
    .shelf_hz = 8000.0,
    .shelf_k = 0.85,
    .peak_hz = 320.0,
    .peak_db = -2.5,
    .peak_q = 0.9,
    .tn = 8,
    .tv = {0.0, 0.1, 0.2, 0.3, 0.5, 0.6, 0.8, 0.9},
    .tlo = {0.351, 0.386, 0.445, 0.533, 0.747, 0.830, 1.166, 1.379},
    .tmid = {0.429, 0.509, 0.613, 0.769, 1.206, 1.586, 3.232, 5.834},
    .thi = {0.440, 0.529, 0.641, 0.818, 1.304, 1.744, 3.805, 7.603},
    .law_exp = 0.811,
    .hi_by_rate = 0,
    .dry = {1.0, 0.9962, 0.9702, 0.9204, 0.8492, 0.7777, 0.7062},
};

static const le_fx_param_desc LE_FX_DUB_VERB_PARAMS[] = {
    {"decay", LE_FX_UNIT_SECONDS, 0, 0.45f, 144.0f, LE_FX_CURVE_REVERB_TIME,
     0.7f, 0},
    {"volume", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.2f,
     0},
};
static const le_fx_param_desc LE_FX_AMB_VERB_PARAMS[] = {
    {"decay", LE_FX_UNIT_SECONDS, 0, 0.45f, 144.0f, LE_FX_CURVE_REVERB_TIME,
     0.2f, 0},
    {"volume", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.4f,
     0},
    /* The Dub Rack's Amb-Dub Mix: read by the chain's parallel paths, not
     * by this kernel. */
    {"amb_dub_mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.4f, 0},
};
#define LE_VB_PARAMS_N 3

typedef struct le_fx_verb {
  le_fx_dyn_head h;
  float last[LE_VB_PARAMS_N];
  le_fx_glide dry;
  le_fx_glide wet;
  const le_verb_def* def;
  uint32_t need[2]; /* the samples each ring must hold */
  uint32_t hist_n;
  uint32_t pd[2];
  uint32_t tap[2];
  uint32_t ap_n[2][LE_VB_APS];
  uint32_t ap_off[2][LE_VB_APS];
  uint32_t line_n[LE_VB_LINES];
  uint32_t line_off[LE_VB_LINES]; /* lines 0-3 in ring 0, 4-7 in ring 1 */
  uint32_t hist_w;
  uint32_t ap_w[2][LE_VB_APS];
  uint32_t line_w[LE_VB_LINES];
  /* Whether each structure has wrapped since the block was cleared: before
   * that, a read returns silence, not what the ring held. */
  uint8_t hist_full;
  uint8_t ap_full[2][LE_VB_APS];
  uint8_t line_full[LE_VB_LINES];
  float dec;        /* Dec, gliding toward the setting */
  float dec_design; /* the Dec the lines were last designed for (-1: none) */
  /* Per rate: the line shelves' prewarped corners (lo, hi) and the anchors'
   * cos and sin (125 Hz, 1 kHz, 8 kHz), so a redesign calls no trig. */
  double warp[2];
  double anchor[3][2];
  float gm[LE_VB_LINES];
  float lo[LE_VB_LINES][3]; /* first-order: b0, b1, a1 */
  float hi[LE_VB_LINES][3];
  float lo_z[LE_VB_LINES][2]; /* x1, y1 */
  float hi_z[LE_VB_LINES][2];
  float shelf[3];
  float shelf_z[2][2];
  float peak[5];
  float peak_z[2][2];
  float tail_z;
} le_fx_verb;

/* A corner [hz] prewarped for the bilinear transform at [sr]. */
static double le_vb_warp(double hz, int sr) {
  return tan(LE_PI * hz / (double)sr);
}

/* A first-order shelf (bilinear): gain [k] at DC (low) or Nyquist (high),
 * unity at the other end, at the prewarped corner [t]. */
static void le_vb_shelf(double t, double k, int high, float c[3]) {
  if (high) {
    c[0] = (float)((k + t) / (1.0 + t));
    c[1] = (float)((t - k) / (1.0 + t));
  } else {
    c[0] = (float)((1.0 + k * t) / (1.0 + t));
    c[1] = (float)((k * t - 1.0) / (1.0 + t));
  }
  c[2] = (float)((t - 1.0) / (1.0 + t));
}

/* A first-order section's gain at the frequency whose cos and sin are
 * [cs]. */
static double le_vb_mag(const float c[3], const double cs[2]) {
  const double nr = c[0] + c[1] * cs[0], ni = -c[1] * cs[1];
  const double dr = 1.0 + c[2] * cs[0], di = -c[2] * cs[1];
  return sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

/* One sample through a first-order section [c] (b0, b1, a1) with state [z]
 * (x1, y1). */
static inline float le_vb_tick(const float c[3], float z[2], float x) {
  const float y = c[0] * x + c[1] * z[0] - c[2] * z[1];
  z[0] = x;
  z[1] = y;
  return y;
}

/* The table's value at Vol [v] (linear between the points). */
static double le_vb_interp(const double* y, double v) {
  if (v <= 0.0) return y[0];
  for (int i = 1; i < LE_VB_WN; ++i) {
    if (v <= LE_VB_WV[i]) {
      const double t = (v - LE_VB_WV[i - 1]) / (LE_VB_WV[i] - LE_VB_WV[i - 1]);
      return y[i - 1] + (y[i] - y[i - 1]) * t;
    }
  }
  return y[LE_VB_WN - 1];
}

/* The reverb time display at Dec [v] (s), as the descriptor shows it. */
static double le_vb_display(double v) {
  return le_fx_desc_value(&LE_FX_DUB_VERB_PARAMS[0], (float)v);
}

/* T30 at 125 Hz, mid and 8 kHz for Dec [v]: the table, log-linear between
 * its points, and above its last point the doc's power law on the display
 * for mid, the low band at its last ratio, and 8 kHz at its last excess
 * decay rate (Dub) or ratio (Amb). */
static void le_vb_t(const le_verb_def* d, double v, double t[3]) {
  const int n = d->tn;
  if (v <= d->tv[0]) {
    t[0] = d->tlo[0];
    t[1] = d->tmid[0];
    t[2] = d->thi[0];
    return;
  }
  for (int i = 1; i < n; ++i) {
    if (v <= d->tv[i]) {
      const double f = (v - d->tv[i - 1]) / (d->tv[i] - d->tv[i - 1]);
      t[0] = d->tlo[i - 1] * pow(d->tlo[i] / d->tlo[i - 1], f);
      t[1] = d->tmid[i - 1] * pow(d->tmid[i] / d->tmid[i - 1], f);
      t[2] = d->thi[i - 1] * pow(d->thi[i] / d->thi[i - 1], f);
      return;
    }
  }
  const double vl = d->tv[n - 1];
  const double mid =
      d->tmid[n - 1] * pow(le_vb_display(v) / le_vb_display(vl), d->law_exp);
  t[1] = mid;
  t[0] = mid * d->tlo[n - 1] / d->tmid[n - 1];
  t[2] = d->hi_by_rate
             ? 1.0 / (1.0 / mid + 1.0 / d->thi[n - 1] - 1.0 / d->tmid[n - 1])
             : mid * d->thi[n - 1] / d->tmid[n - 1];
}

/* Line [i]'s shelves and gain for the decay times [t] (s). The shelves'
 * gains are corrected four times for their leakage at the other anchors. */
static void le_vb_design_line(le_fx_verb* q, int i, const double t[3],
                              int sr) {
  const double len = (double)q->line_n[i];
  const double(*a)[2] = q->anchor; /* 125 Hz, 1 kHz, 8 kHz */
  const double glo = pow(10.0, -3.0 * len / (t[0] * sr));
  const double gmid = pow(10.0, -3.0 * len / (t[1] * sr));
  const double ghi = pow(10.0, -3.0 * len / (t[2] * sr));
  double klo = glo / gmid;
  double khi = ghi / gmid;
  for (int it = 0; it < 4; ++it) {
    le_vb_shelf(q->warp[0], klo, 0, q->lo[i]);
    le_vb_shelf(q->warp[1], khi, 1, q->hi[i]);
    const double gm =
        gmid / (le_vb_mag(q->lo[i], a[1]) * le_vb_mag(q->hi[i], a[1]));
    klo *= glo / (gm * le_vb_mag(q->lo[i], a[0]) * le_vb_mag(q->hi[i], a[0]));
    khi *= ghi / (gm * le_vb_mag(q->lo[i], a[2]) * le_vb_mag(q->hi[i], a[2]));
  }
  le_vb_shelf(q->warp[0], klo, 0, q->lo[i]);
  le_vb_shelf(q->warp[1], khi, 1, q->hi[i]);
  q->gm[i] = (float)(gmid / (le_vb_mag(q->lo[i], a[1]) *
                             le_vb_mag(q->hi[i], a[1])));
}

static uint32_t le_vb_len(double ms, int sr) {
  const double n = ms * (double)sr / 1000.0 + 0.5;
  return n < 1.0 ? 1u : (uint32_t)n;
}

/* The geometry at [sr]: every length, and where each stage sits in its
 * ring. */
static void le_vb_geometry(le_fx_verb* q, int sr) {
  const le_verb_def* d = q->def;
  q->pd[0] = le_vb_len(d->pd_ms[0], sr);
  q->pd[1] = le_vb_len(d->pd_ms[1], sr);
  q->tap[0] = d->tap_ms[0] > 0.0 ? le_vb_len(d->tap_ms[0], sr) : 0u;
  q->tap[1] = d->tap_ms[1] > 0.0 ? le_vb_len(d->tap_ms[1], sr) : 0u;
  uint32_t reach = q->pd[0] > q->pd[1] ? q->pd[0] : q->pd[1];
  if (q->tap[0] > reach) reach = q->tap[0];
  if (q->tap[1] > reach) reach = q->tap[1];
  q->hist_n = reach + 2u;
  uint32_t at[2] = {q->hist_n, 0u};
  for (int c = 0; c < 2; ++c) {
    for (int k = 0; k < LE_VB_APS; ++k) {
      q->ap_n[c][k] = le_vb_len(d->ap_ms[c][k], sr);
      q->ap_off[c][k] = at[c];
      at[c] += q->ap_n[c][k];
    }
  }
  for (int i = 0; i < LE_VB_LINES; ++i) {
    const int c = i < LE_VB_LINES / 2 ? 0 : 1;
    q->line_n[i] = le_vb_len(d->line_ms[i], sr);
    q->line_off[i] = at[c];
    at[c] += q->line_n[i];
  }
  q->need[0] = at[0];
  q->need[1] = at[1];
}

static void fx_verb_update(void* ks, const float* p, int sr, int settle,
                           const le_verb_def* def) {
  le_fx_verb* q = (le_fx_verb*)ks;
  q->def = def;
  const int f = le_fx_dyn_begin(&q->h, q->last, p, LE_VB_PARAMS_N, sr, settle);
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    /* A new rate makes the rings another rate's: the positions start over,
     * and each structure reads silence until it wraps (le_fx_verb). */
    memset(q->lo_z, 0, sizeof(q->lo_z));
    memset(q->hi_z, 0, sizeof(q->hi_z));
    memset(q->shelf_z, 0, sizeof(q->shelf_z));
    memset(q->peak_z, 0, sizeof(q->peak_z));
    memset(q->ap_w, 0, sizeof(q->ap_w));
    memset(q->line_w, 0, sizeof(q->line_w));
    memset(q->ap_full, 0, sizeof(q->ap_full));
    memset(q->line_full, 0, sizeof(q->line_full));
    q->hist_full = 0;
    q->hist_w = 0;
    q->tail_z = 0.0f;
    q->dec_design = -1.0f;
    le_vb_geometry(q, rate);
    q->warp[0] = le_vb_warp(def->lo_hz, rate);
    q->warp[1] = le_vb_warp(def->hi_hz, rate);
    static const double anchor_hz[3] = {125.0, 1000.0, 8000.0};
    for (int a = 0; a < 3; ++a) {
      const double w = 2.0 * LE_PI * anchor_hz[a] / (double)rate;
      q->anchor[a][0] = cos(w);
      q->anchor[a][1] = sin(w);
    }
    le_vb_shelf(le_vb_warp(def->shelf_hz, rate), def->shelf_k, 1, q->shelf);
    if (def->peak_db != 0.0) {
      double c[5];
      le_eq_design(LE_EQ_LOMID, def->peak_hz, def->peak_db, def->peak_q, rate,
                   c);
      for (int i = 0; i < 5; ++i) q->peak[i] = (float)c[i];
    }
  }
  const float k = settle ? 1.0f : q->h.k;
  /* Dec glides with the other settings' smoothing; the lines are redesigned
   * (eight shelf pairs) only while it moves, not when Vol does. */
  const float dec_tgt = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  le_fx_step_toward(&q->dec, dec_tgt, k);
  if (q->dec != q->dec_design) {
    double t[3];
    le_vb_t(def, (double)q->dec, t);
    for (int i = 0; i < LE_VB_LINES; ++i) le_vb_design_line(q, i, t, rate);
    q->dec_design = q->dec;
  }
  const double vol = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : (double)p[1];
  int moving = le_fx_glide_step(&q->dry, (float)le_vb_interp(def->dry, vol), k);
  moving |= le_fx_glide_step(&q->wet, (float)le_vb_interp(LE_VB_WET, vol), k);
  moving |= q->dec != dec_tgt;
  q->h.moving = moving;
}

static void fx_dub_verb_update(void* ks, const float* p, int sr, int settle) {
  fx_verb_update(ks, p, sr, settle, &LE_DUB_VERB_DEF);
}
static void fx_amb_verb_update(void* ks, const float* p, int sr, int settle) {
  fx_verb_update(ks, p, sr, settle, &LE_AMB_VERB_DEF);
}

static void fx_verb_rkprocess(void* ks, float* r0, float* r1, int cap, float* l,
                              float* r) {
  le_fx_verb* q = (le_fx_verb*)ks;
  const le_verb_def* d = q->def;
  /* Rings too short for the geometry: the input passes untouched, as it
   * does when the slot has no rings (fx_run). */
  if (d == NULL || (uint32_t)cap < q->need[0] || (uint32_t)cap < q->need[1])
    return;
  const float dry = le_fx_glide_next(&q->dry);
  const float wet = le_fx_glide_next(&q->wet);
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  float* ring[2] = {r0, r1};
  const float m = 0.5f * (x0 + x1);
  /* The input history: the pre-delays and the strong taps read it. */
  float* hist = r0;
  hist[q->hist_w] = m;
  float e[2];
  float tap[2] = {0.0f, 0.0f};
  for (int c = 0; c < 2; ++c) {
    /* Before the history wraps, only the indices up to its write position
     * hold this block's input. */
    uint32_t at = q->hist_w + q->hist_n - q->pd[c];
    if (at >= q->hist_n) at -= q->hist_n;
    float u = q->hist_full || at <= q->hist_w ? hist[at] : 0.0f;
    if (q->tap[c] != 0u) {
      uint32_t ta = q->hist_w + q->hist_n - q->tap[c];
      if (ta >= q->hist_n) ta -= q->hist_n;
      tap[c] = q->hist_full || ta <= q->hist_w ? d->tap_g[c] * hist[ta] : 0.0f;
    }
    for (int k = 0; k < LE_VB_APS; ++k) {
      float* b = ring[c] + q->ap_off[c][k];
      const uint32_t w = q->ap_w[c][k];
      const float dl = q->ap_full[c][k] ? b[w] : 0.0f;
      const float v = u + d->ap_g * dl;
      u = dl - d->ap_g * v;
      b[w] = fx_sanitize(v);
      if (w + 1u >= q->ap_n[c][k]) {
        q->ap_w[c][k] = 0u;
        q->ap_full[c][k] = 1u;
      } else {
        q->ap_w[c][k] = w + 1u;
      }
    }
    e[c] = u;
  }
  if (++q->hist_w >= q->hist_n) {
    q->hist_w = 0;
    q->hist_full = 1u;
  }
  /* The network: each line's output was written line_n samples ago. */
  float o[LE_VB_LINES];
  float sum = 0.0f;
  float ol = 0.0f;
  float orr = 0.0f;
  for (int i = 0; i < LE_VB_LINES; ++i) {
    const int c = i < LE_VB_LINES / 2 ? 0 : 1;
    o[i] = q->line_full[i] ? ring[c][q->line_off[i] + q->line_w[i]] : 0.0f;
    sum += o[i];
    ol += (float)d->cl[i] * o[i];
    orr += (float)d->cr[i] * o[i];
  }
  const float house = 2.0f / (float)LE_VB_LINES * sum;
  for (int i = 0; i < LE_VB_LINES; ++i) {
    const int c = i < LE_VB_LINES / 2 ? 0 : 1;
    const float y = le_vb_tick(q->lo[i], q->lo_z[i], o[i] - house);
    const float y2 = le_vb_tick(q->hi[i], q->hi_z[i], y);
    const float inj = (i & 1) == 0 ? e[0] : e[1];
    ring[c][q->line_off[i] + q->line_w[i]] =
        fx_sanitize(q->gm[i] * y2 + (float)d->cin[i] * d->late_g * inj);
    if (q->line_w[i] + 1u >= q->line_n[i]) {
      q->line_w[i] = 0u;
      q->line_full[i] = 1u;
    } else {
      q->line_w[i] += 1u;
    }
  }
  const float inv = 0.35355339f; /* 1 / sqrt(8) */
  float w[2] = {inv * ol + d->early_g * e[0] + tap[0],
                inv * orr + d->early_g * e[1] + tap[1]};
  for (int c = 0; c < 2; ++c) {
    if (d->peak_db != 0.0) w[c] = le_biquad_tick(q->peak, q->peak_z[c], w[c]);
    w[c] = le_vb_tick(q->shelf, q->shelf_z[c], w[c]);
  }
  if (d->tail_g != 0.0f) {
    q->tail_z = fx_sanitize(d->tail_p * q->tail_z + m);
    const float t = d->tail_g * (q->tail_z - m);
    w[0] += t;
    w[1] += t;
  }
  *l = dry * x0 + wet * w[0];
  *r = dry * x1 + wet * w[1];
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
LE_FX_ROWS_FIT(LE_FX_DUB_VERB_PARAMS);
LE_FX_ROWS_FIT(LE_FX_AMB_VERB_PARAMS);
LE_FX_ROWS_FIT(LE_FX_WHAMMY_PARAMS);
LE_FX_ROWS_FIT(LE_FX_PUMPER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_SLICER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_MODE_DELAY_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DUAL_OCTAVER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_AMP_CAB_PARAMS);

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
  /* A heap-state kind whose long lines live in the slot's two rings, which
   * its `prepare` allocates (the reverbs): run instead of `kprocess`, with
   * both rings and their length (the sample rate). A slot without both
   * rings passes the input untouched. Its block tracks which parts of the
   * rings it has written, so the rings are never cleared for it. */
  void (*rkprocess)(void* ks, float* r0, float* r1, int cap, float* l,
                    float* r);
  /* A heap-state kind locked to the beat (the Rhythmic LPF's LFO): given,
   * just before each `update`, the beat in quarter notes of the last frame
   * that update covers (where a setting it ramps toward lands). NULL for
   * the rest. */
  void (*beat)(void* ks, double beat);
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
    [LE_FX_LPF] = {NULL, NULL, NULL, LE_FX_LPF_PARAMS, LE_FX_F_FREE_RUNNING,
                   sizeof(le_fx_lpf), fx_lpf_update, fx_lpf_kprocess, NULL,
                   fx_lpf_beat},
    /* The spring drains its tail on bypass, as the delay and reverb do. */
    [LE_FX_SPRING] = {NULL, NULL, NULL, LE_FX_SPRING_PARAMS, LE_FX_F_DRAINS,
                      sizeof(le_fx_spring), fx_spring_update,
                      fx_spring_kprocess},
    /* The reverbs keep their filters in the block and their lines in the
     * slot's rings, and drain their tails on bypass. */
    [LE_FX_DUB_VERB] = {NULL, NULL, fx_stereo_ring_prepare,
                        LE_FX_DUB_VERB_PARAMS, LE_FX_F_DRAINS,
                        sizeof(le_fx_verb), fx_dub_verb_update, NULL,
                        fx_verb_rkprocess},
    [LE_FX_AMB_VERB] = {NULL, NULL, fx_stereo_ring_prepare,
                        LE_FX_AMB_VERB_PARAMS, LE_FX_F_DRAINS,
                        sizeof(le_fx_verb), fx_amb_verb_update, NULL,
                        fx_verb_rkprocess},
    /* The octaver's kernel and state, its settings mapped (fx_whammy_process). */
    [LE_FX_WHAMMY] = {fx_whammy_process, fx_octaver_latency_vt,
                      fx_octaver_prepare, LE_FX_WHAMMY_PARAMS},
    /* The octaver's kernel and state, its settings mapped (le_doct_settings). */
    [LE_FX_DUAL_OCTAVER] = {fx_dual_octaver_process, fx_octaver_latency_vt,
                            fx_octaver_prepare, LE_FX_DUAL_OCTAVER_PARAMS},
    /* The amp and its cabinet, in its own per-slot instance (fx->amp). */
    [LE_FX_AMP_CAB] = {fx_amp_cab_process, NULL, fx_amp_cab_prepare,
                       LE_FX_AMP_CAB_PARAMS},
    /* Locked to the beat: a print could not stand for it lap after lap. */
    [LE_FX_PUMPER] = {fx_pumper_process, NULL, NULL, LE_FX_PUMPER_PARAMS,
                      LE_FX_F_FREE_RUNNING},
    /* Its input history in the slot's rings; locked to the beat. */
    [LE_FX_SLICER] = {fx_slicer_process, NULL, fx_stereo_ring_prepare,
                      LE_FX_SLICER_PARAMS, LE_FX_F_FREE_RUNNING},
    /* Its own seconds-long line (fx->line), drained on bypass. */
    [LE_FX_MODE_DELAY] = {fx_mode_delay_process, NULL, fx_mode_delay_prepare,
                          LE_FX_MODE_DELAY_PARAMS,
                          LE_FX_F_DRAINS | LE_FX_F_FREE_RUNNING},
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
                   LE_SPR_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_SPRING_PARAMS) &&
                   LE_VB_PARAMS_N >= LE_FX_ROW_COUNT(LE_FX_DUB_VERB_PARAMS) &&
                   LE_VB_PARAMS_N == LE_FX_ROW_COUNT(LE_FX_AMB_VERB_PARAMS),
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
    [LE_FX_DUB_VERB] = LE_FX_ROW_COUNT(LE_FX_DUB_VERB_PARAMS),
    [LE_FX_AMB_VERB] = LE_FX_ROW_COUNT(LE_FX_AMB_VERB_PARAMS),
    [LE_FX_WHAMMY] = LE_FX_ROW_COUNT(LE_FX_WHAMMY_PARAMS),
    [LE_FX_PUMPER] = LE_FX_ROW_COUNT(LE_FX_PUMPER_PARAMS),
    [LE_FX_SLICER] = LE_FX_ROW_COUNT(LE_FX_SLICER_PARAMS),
    [LE_FX_MODE_DELAY] = LE_FX_ROW_COUNT(LE_FX_MODE_DELAY_PARAMS),
    [LE_FX_DUAL_OCTAVER] = LE_FX_ROW_COUNT(LE_FX_DUAL_OCTAVER_PARAMS),
    [LE_FX_AMP_CAB] = LE_FX_ROW_COUNT(LE_FX_AMP_CAB_PARAMS),
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
    if (LE_FX[ty].beat != NULL) {
      float qpf;
      int32_t num, den;
      const double now = le_fx_beat_now(fx, sr, &qpf, &num, &den);
      LE_FX[ty].beat(st,
                     now + (double)(LE_FX_UPDATE_FRAMES - 1) * (double)qpf);
    }
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
    if (st == NULL) return;
    if (LE_FX[ty].rkprocess != NULL) {
      float* r0 = fx->delay[s][0];
      float* r1 = fx->delay[s][1];
      if (r0 != NULL && r1 != NULL) LE_FX[ty].rkprocess(st, r0, r1, cap, l, r);
      return;
    }
    LE_FX[ty].kprocess(st, l, r);
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
  if (type == LE_FX_MODE_DELAY) {
    return atomic_load_explicit(&fx->line[s], memory_order_acquire) != NULL;
  }
  return LE_FX[type].prepare != NULL &&
         (fx->delay[s][0] != NULL || fx->delay[s][1] != NULL);
}

void le_fx_entry_renew(le_fx_state* fx, int slot, int32_t type, int sounding) {
  le_fx_entry_reset(fx, slot);
  /* An entry replacing one the chain was running enters through the enable
   * edge: handed the old entry's settled ramp, it would switch in at full in
   * one sample (#1452). */
  if (sounding || le_fx_holds_tail(fx, slot, type)) {
    le_fx_enable_force_bypass(fx, slot);
  }
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
      return 1; /* even at 0 % mix its copy wanders within 1 ms */
    case LE_FX_LPF: /* on, and oscillating or swept by the beat */
      return p[0] < 1.0f &&
             ((double)p[1] > le_lpf_osc_reso() || p[2] > 0.0f);
    case LE_FX_PUMPER: /* ducking at all */
      return p[1] > 0.0f;
    case LE_FX_MODE_DELAY: /* heard (its time is the live tempo's) */
      return p[2] > 0.0f;
    case LE_FX_SLICER: /* slicing, and heard */
      return p[2] > 0.0f && le_slice_pattern(p[0]) != NULL;
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

#define LE_FX_RACK_PATHS (LE_FX_RACK_DUB_PATH | LE_FX_RACK_AMB_PATH)

/* A parallel section being walked (LE_FX_RACK_DUB_PATH and
 * LE_FX_RACK_AMB_PATH): its first entry
 * (-1 outside one), the pair it was handed, each path's running pair ([0]
 * Amb, [1] Dub) and its Amb-Dub Mix. */
typedef struct fx_section {
  int at;
  int has_mix;
  float mix;
  float x[2];
  float p[2][2];
} fx_section;

/* The Amb-Dub Mix law at [m]: the Amb path's gain [0], the Dub path's [1]. */
static inline void fx_path_targets(float m, float g[2]) {
  const float d = 2.0f * (m < 0.0f ? 0.0f : m > 1.0f ? 1.0f : m);
  g[1] = d < 1.0f ? d * d : 1.0f;
  g[0] = d > 1.0f ? 1.0f - (d - 1.0f) * (d - 1.0f) : 1.0f;
}

/* Entry [s] of a section ([sec]) takes its path's running pair, opening
 * the section at its first entry. Returns the path (0 Amb, 1 Dub). */
static inline int fx_section_enter(fx_section* sec, int s, int32_t bits,
                                   int32_t ty, const float* p, float* xl,
                                   float* xr) {
  if (sec->at < 0) {
    sec->at = s;
    sec->has_mix = 0;
    sec->mix = LE_FX_AMB_VERB_PARAMS[2].def;
    sec->x[0] = sec->p[0][0] = sec->p[1][0] = *xl;
    sec->x[1] = sec->p[0][1] = sec->p[1][1] = *xr;
  }
  /* Read here, ahead of anything that skips the entry: a bypassed
   * Amb-Verb's Amb-Dub Mix still sets the mix. */
  if (ty == LE_FX_AMB_VERB && !sec->has_mix) {
    sec->mix = p[2];
    sec->has_mix = 1;
  }
  const int path = (bits & LE_FX_RACK_AMB_PATH) ? 0 : 1;
  *xl = sec->p[path][0];
  *xr = sec->p[path][1];
  return path;
}

/* Whether the section ends after entry [s]: the chain, the rack or the run
 * of path entries ends there. */
static inline int fx_section_ends(const le_fx_state* fx, int s, int count) {
  return s + 1 >= count || (fx->chan[s].rack & LE_FX_RACK_LAST) ||
         (fx->chan[s + 1].rack & LE_FX_RACK_FIRST) ||
         !(fx->chan[s + 1].rack & LE_FX_RACK_PATHS);
}

/* A section's output: x + A (amb - x) + D (dub - x) + rm (A + D - 1) x,
 * which is A amb + D dub with the rack on (rack crossfade [rm] 1) and, with
 * it off, the input plus whatever each path added (a draining tail) at its
 * path's gain. So a section whose entries are all settled off, in a rack
 * that is off, hands on its input exactly. */
static inline void fx_section_merge(le_fx_state* fx, const fx_section* sec,
                                    int sr, float rm, float* xl, float* xr) {
  float tgt[2];
  fx_path_targets(sec->mix, tgt);
  float* g = fx->path_gain[sec->at];
  if (!fx->path_primed[sec->at]) {
    g[0] = tgt[0];
    g[1] = tgt[1];
    fx->path_primed[sec->at] = 1;
  } else if (g[0] != tgt[0] || g[1] != tgt[1]) {
    const float step =
        sr > 0 ? 1000.0f / ((float)LE_FX_ENABLE_RAMP_MS * (float)sr) : 1.0f;
    for (int i = 0; i < 2; ++i) {
      const float d = tgt[i] - g[i];
      g[i] = d > step ? g[i] + step : d < -step ? g[i] - step : tgt[i];
    }
  }
  const float boost = rm * (g[0] + g[1] - 1.0f);
  float out[2];
  for (int c = 0; c < 2; ++c) {
    const float x = sec->x[c];
    out[c] = x + g[0] * (sec->p[0][c] - x) + g[1] * (sec->p[1][c] - x);
    if (boost != 0.0f) out[c] += boost * x;
  }
  *xl = out[0];
  *xr = out[1];
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
  fx_section sec;
  sec.at = -1;
  if (fx->enable_clear_cooldown > 0) fx->enable_clear_cooldown--;
  for (int s = 0; s < count; ++s) {
    if (s == gain_at) {
      xl *= gain;
      xr *= gain;
      if (sec.at >= 0) { /* the merge is linear: scale what it will sum */
        for (int c = 0; c < 2; ++c) {
          sec.x[c] *= gain;
          sec.p[0][c] *= gain;
          sec.p[1][c] *= gain;
        }
      }
    }
    if (fx->chan_any && (fx->chan[s].rack & LE_FX_RACK_FIRST)) {
      rack_dl = xl;
      rack_dr = xr;
      rack_tail = fx_rack_head(fx, s, count, enabled, sr, &xl, &xr);
    }
    const int32_t ty = types[s];
    const int32_t path_bits =
        fx->chan_any ? fx->chan[s].rack & LE_FX_RACK_PATHS : 0;
    const int path = path_bits ? fx_section_enter(&sec, s, path_bits, ty,
                                                  params[s], &xl, &xr)
                               : -1;
    if (ty > LE_FX_NONE && ty < LE_FX_TYPE_COUNT &&
        (LE_FX[ty].process || LE_FX[ty].kprocess || LE_FX[ty].rkprocess)) {
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
           * simply stays bypassed and retries next sample. A draining
           * heap-state kind is spaced the same way: the reset clears its
           * block (the spring's ring lives there). A ring kernel
           * (`rkprocess`, the reverbs) skips the ring clear: its cleared
           * block marks every structure unwrapped, so it reads silence
           * until it has written there again. */
          /* The Mode delay reads only its own line, which the reset
           * empties at once: no ring to clear, no spacing to wait on, and
           * any 1 s rings an earlier kind left stay as they are, unread. */
          const int needs_clear =
              ty != LE_FX_MODE_DELAY && le_fx_holds_tail(fx, s, ty);
          if (needs_clear && fx->enable_clear_cooldown > 0) goto slot_done;
          le_fx_entry_reset(fx, s);
          if (needs_clear) {
            if (LE_FX[ty].prepare != NULL && LE_FX[ty].rkprocess == NULL)
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
          int32_t quiet_n = cap > minimum ? cap : minimum;
          /* The Mode delay remembers its own line's length. */
          const struct le_fx_line* line =
              ty == LE_FX_MODE_DELAY
                  ? atomic_load_explicit(&fx->line[s], memory_order_acquire)
                  : NULL;
          if (line != NULL && le_mdly_frames(line) > quiet_n) {
            quiet_n = le_mdly_frames(line);
          }
          if (fx->enable_quiet[s] >= quiet_n) {
            fx->enable_drain[s] = 0;
          }
        }
      }
    }
  slot_done:
    /* Whatever the entry did, a path entry hands its result back to its
     * path, and the section's last one merges the paths. */
    if (path >= 0) {
      sec.p[path][0] = xl;
      sec.p[path][1] = xr;
      if (fx_section_ends(fx, s, count)) {
        fx_section_merge(fx, &sec, sr,
                         rack_tail >= 0 ? fx->rack_mix[rack_tail] : 1.0f, &xl,
                         &xr);
        sec.at = -1;
      }
    }
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
  if (LE_FX[type].state_size) {
    const int32_t rc = le_fx_kind_prepare(fx, slot, type);
    /* A kind with rings too (the reverbs) allocates them as the delay does. */
    if (rc != LE_OK || LE_FX[type].prepare == NULL) return rc;
    return LE_FX[type].prepare(fx, slot, cap);
  }
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
