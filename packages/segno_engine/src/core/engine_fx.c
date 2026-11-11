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
/* #1718: this unit's chain driver goes to the hot section (engine_hot.h). */
#define LE_AUDIO_TU 1

#include <float.h> /* FLT_MAX */
#if defined(__aarch64__)
#include <arm_neon.h> /* vsqrtq_f32 */
#endif
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "engine_fx_simd.h" /* le_f4, le_u4 (#1755) */
#include "engine_hot.h"      /* LE_AUDIO_HOT_AT (#1718) */
#include "engine_internal.h" /* le_psola_detect_band prototype (below) */
#include "fft.h" /* le_rfft_plan, le_rfft_fwd / le_rfft_inv, le_hann_init */
#include "rt_alloc.h" /* le_rt_alloc_prefaulted / le_rt_free: the audio thread writes these */
#include "../host/plugin_slot.h" /* le_plugin_slot_process (LE_FX_PLUGIN row) */

/* #1718: LE_AUDIO_TU came before every include, so the pins took. */
#if defined(__ELF__) && (defined(__GNUC__) || defined(__clang__)) && \
    !defined(LE_AUDIO_HOT_PINNED)
#error "define LE_AUDIO_TU before the first include (engine_hot.h)"
#endif

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
/* A heap-state kind whose block is at least this large (the doubler's and
 * the chorus's delay lines, the spring's ring) is spaced the same way: the
 * reset clears its block on the audio thread, about 1.6 us per 16 KB on the
 * console, so a stomp engaging several must not clear them in one
 * callback. */
#define LE_FX_SPACED_CLEAR_BYTES 4096

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

/* ---- Tables made once per sample rate ----
 *
 * The pitch kinds' resamplers and the Amp+Cab's cabinets are worked out for
 * a rate the first time a slot is prepared at it (a control thread, under
 * the set's lock) and kept for the life of the process. The slots fill in
 * order and are never freed or replaced, so any thread, the audio thread
 * included, finds a table without a lock. */
#define LE_RATE_TABLES 16

typedef struct le_rate_tables {
  void* _Atomic tab[LE_RATE_TABLES];
  int32_t sr[LE_RATE_TABLES]; /* slot i's rate, set before tab[i] is */
  pthread_mutex_t mu;
} le_rate_tables;

/* [set]'s table for [sr], or NULL when none was made. Any thread. */
static const void* le_rate_tables_find(le_rate_tables* set, int32_t sr) {
  for (int i = 0; i < LE_RATE_TABLES; ++i) {
    const void* t = atomic_load_explicit(&set->tab[i], memory_order_acquire);
    if (t == NULL) return NULL; /* the slots past it are empty too */
    if (set->sr[i] == sr) return t;
  }
  return NULL;
}

/* [set]'s table for [sr], made by [make] the first time (a control thread;
 * [make] runs under the set's lock). NULL when it cannot be made, or when
 * every slot holds another rate's. */
static const void* le_rate_tables_get(le_rate_tables* set, int32_t sr,
                                      void* (*make)(int32_t sr)) {
  const void* found = le_rate_tables_find(set, sr);
  if (found != NULL) return found;
  pthread_mutex_lock(&set->mu);
  int slot = 0; /* the first empty slot, unless one holds [sr] by now */
  for (; slot < LE_RATE_TABLES; ++slot) {
    void* t = atomic_load_explicit(&set->tab[slot], memory_order_relaxed);
    if (t == NULL) break;
    if (set->sr[slot] == sr) {
      found = t;
      break;
    }
  }
  if (found == NULL && slot < LE_RATE_TABLES) {
    void* made = make(sr);
    if (made != NULL) {
      set->sr[slot] = sr;
      atomic_store_explicit(&set->tab[slot], made, memory_order_release);
      found = made;
    }
  }
  pthread_mutex_unlock(&set->mu);
  return found;
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

/* At 96 kHz the EQ's bands and the other kinds' filter sections (#1547)
 * run their 48 kHz designs on every other sample, each of the two
 * interleaved phases with its own state: that is H48(z^2), which below
 * 24 kHz is exactly the 48 kHz response, including its compression toward
 * 24 kHz. Above 24 kHz it mirrors what is below: it passes what a signal
 * holds there at the gain the 48 kHz design has at the mirror image, so a
 * curve's output first passes a half-band (le_hb). Only linear sections run
 * this way: a nonlinear kernel would run as two unrelated ones (the LPF and
 * the Degrade run at 48 kHz instead). The phases count the engine's frames,
 * so a section's state never swaps phase; a new rate clears them.
 * LE_RS_PH is the most phases a section runs. */
#define LE_RS_PH 2
static inline int le_rs_phases(int sr) { return sr == 96000 ? 2 : 1; }
/* The rate a section is designed at: 48 kHz at 96 kHz, else the rate. */
static inline int le_rs_design_rate(int sr) { return sr == 96000 ? 48000 : sr; }

/* I0, the modified Bessel function of the first kind, for the Kaiser
 * window: the power series, to float precision. */
static double le_bessel_i0(double x) {
  double sum = 1.0, term = 1.0;
  for (int k = 1; k < 64 && term > 1e-12 * sum; ++k) {
    const double h = x / (2.0 * k);
    term *= h * h;
    sum += term;
  }
  return sum;
}

/* A recirculating delay of [d] samples where its 48 kHz length is no whole
 * number of samples at the rate (#1547): [n] whole samples, and the
 * coefficient [a] of a first-order all-pass (a + z^-1) / (1 + a z^-1) that
 * adds the rest, 0.5 to 1.5 samples at low frequencies (le_frac_tick). A
 * delay under 1.5 samples runs 1.5. */
static void le_frac_split(double d, uint32_t* n, float* a) {
  double whole = floor(d - 0.5);
  if (whole < 1.0) whole = 1.0;
  double rest = d - whole;
  if (rest < 0.5) rest = 0.5;
  *n = (uint32_t)whole;
  *a = (float)((1.0 - rest) / (1.0 + rest));
}

/* [x] through le_frac_split's all-pass [a], its last input and output in
 * [z]. */
static inline float le_frac_tick(float a, float z[2], float x) {
  const float y = a * (x - z[1]) + z[0];
  z[0] = x;
  z[1] = y;
  return y;
}

/* le_frac_tick on four lines: their all-pass coefficients [a], last inputs
 * [x1] and last outputs [y1]. */
static inline le_f4 le_frac_tick4(const float* a, float* x1, float* y1,
                                  le_f4 x) {
  const le_f4 y = le_f4_load(a) * (x - le_f4_load(y1)) + le_f4_load(x1);
  le_f4_store(x1, x);
  le_f4_store(y1, y);
  return y;
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
static void fx_filter(le_fx_state* fx, int slot, int sr, float* l, float* r,
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
  /* Both channels on the one design: the low-pass output of each. */
  le_svf_tick(*l, a1, a2, a3, &fx->svf_ic1[slot][0], &fx->svf_ic2[slot][0],
              &v1, &v2);
  *l = v2;
  le_svf_tick(*r, a1, a2, a3, &fx->svf_ic1[slot][1], &fx->svf_ic2[slot][1],
              &v1, &v2);
  *r = v2;
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

/* Linearly interpolated read from a ring of [cap] samples, [d] samples behind
 * the head [head] (the index of the most recently written sample). [d] may be
 * fractional and is assumed in [0, cap). */
/* Where a ring of [cap] is read [d] samples behind [head]: the two samples
 * between which, and the fraction. */
typedef struct le_frac_at {
  int i0, i1;
  float frac;
} le_frac_at;

static le_frac_at le_frac_where(int cap, int head, float d) {
  float rp = (float)head - d;
  while (rp < 0.0f) rp += (float)cap;
  while (rp >= (float)cap) rp -= (float)cap;
  le_frac_at w;
  w.i0 = (int)rp;
  w.frac = rp - (float)w.i0;
  w.i1 = w.i0 + 1;
  if (w.i1 >= cap) w.i1 = 0;
  return w;
}

static float fx_read_frac(const float* buf, int cap, int head, float d) {
  const le_frac_at w = le_frac_where(cap, head, d);
  return buf[w.i0] + w.frac * (buf[w.i1] - buf[w.i0]);
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
_Static_assert(LE_OCT_REACH >= LE_PSOLA_LAG + LE_PSOLA_RAW + LE_PSOLA_AHOP,
               "the ring guard covers PSOLA's refinement window, copied up "
               "to a hop after it ended");
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

/* ---- LFOs on the engine clock (#1620) ----
 *
 * A time-based modulator takes its phase from the engine frame it is
 * processing (le_fx_now), not from its own reset: frac(rate * frame / sr).
 * So two instances of the same settings agree whenever they process the same
 * frame, whenever each was reset, which is what lets a print (rendered from a
 * fresh chain at the clock it stands in for) agree with the live chain it
 * swaps in over, and what makes an offline render reproduce what was heard.
 *
 * A rate move would make a pure clock phase jump (rate times a frame count
 * in the millions), so the move keeps the phase continuous through an offset
 * and the offset then slides back to 0 at LE_LFO_RELOCK_CPS cycles a second,
 * or half the LFO's rate when that is less (the LFO runs that much fast or
 * slow for at most 2 s, 10 s at the slowest tremolo). While it slides the
 * slot is relocking (le_fx_lfo_relocking) and the wet cache counts the live
 * chain's run from when it is back on the clock. A slot's lfo[slot][0] is the
 * offset in cycles and lfo_rate[slot] the rate it was set for (0: none yet,
 * a fresh slot, which starts on the clock); lfo_frame[slot] is the last frame
 * (to catch the 32-bit clock wrapping) or, for a state nobody clocks, its
 * own count. */
#define LE_LFO_RELOCK_CPS 0.25

/* The tremolo's rate at settings [p], Hz. */
static double le_tremolo_rate(const float* p) {
  return 0.1 + (double)p[0] * 11.9;
}

/* The echo's wow rate, Hz: fixed. */
#define LE_ECHO_WOW_HZ 0.7

/* The most a clock LFO may miss a whole number of cycles in a lap and still
 * print (le_fx_entry_lfo_drifts): its print loops one lap, so at each loop
 * top the LFO steps back by the miss. The tremolo's gain moves pi x depth
 * per cycle at most, so 3e-5 cycles is under 1e-4 of gain; the echo's wow
 * moves its read by 2 pi x 4 ms a cycle, so 5e-7 cycles keeps the read
 * within 8e-4 frames, under 1e-4 on a full-scale 1 kHz tone. */
#define LE_TREMOLO_LAP_TOL 3e-5
#define LE_ECHO_LAP_TOL 5e-7

/* frac(x), in [0, 1). */
static inline double le_frac(double x) { return x - floor(x); }

/* Slot [slot]'s LFO phase, in cycles, at [rate] Hz on the frame [fx] is
 * processing: the clock phase plus the slot's relock offset, which this
 * advances (once per frame: call it once per slot per sample). */
static double le_clock_lfo(le_fx_state* fx, int slot, double rate, int sr) {
  const double hz = (double)(sr > 0 ? sr : 48000);
  const int clocked = fx->clock_src != NULL || fx->clocked;
  const uint32_t now = clocked ? le_fx_now(fx) : fx->lfo_frame[slot]++;
  const double t = (double)now / hz;
  float* offset = &fx->lfo[slot][0];
  double* set = &fx->lfo_rate[slot];
  if (*set != rate) {
    if (*set > 0.0) {
      /* Continuous through the move: the old phase, from the new rate. */
      const double was = le_frac(*set * t + (double)*offset);
      double o = was - le_frac(rate * t);
      o -= floor(o + 0.5); /* the shorter way round, in [-0.5, 0.5) */
      *offset = (float)o;
    }
    *set = rate;
  } else if (clocked && now < fx->lfo_frame[slot] &&
             fx->lfo_frame[slot] - now > 0x80000000u) {
    /* The 32-bit clock wrapped (a day at 48 kHz): the clock phase jumps by
     * frac(rate * 2^32 / sr), so carry the old phase across and relock. */
    double o = (double)*offset + le_frac(rate * 4294967296.0 / hz);
    o -= floor(o + 0.5);
    *offset = (float)o;
  }
  if (clocked) fx->lfo_frame[slot] = now;
  if (*offset != 0.0f) {
    /* Never faster than half the LFO itself, so a slow one slows down
     * rather than running backwards while it relocks. */
    const double cps =
        rate * 0.5 < LE_LFO_RELOCK_CPS ? rate * 0.5 : LE_LFO_RELOCK_CPS;
    const float step = (float)(cps / hz);
    *offset = fabsf(*offset) <= step ? 0.0f
              : *offset > 0.0f       ? *offset - step
                                     : *offset + step;
  }
  return le_frac(rate * t + (double)*offset);
}

int le_fx_type_clock_lfo(int32_t type) {
  return type == LE_FX_TREMOLO || type == LE_FX_ECHO;
}

int le_fx_lfo_relocking(const le_fx_state* fx, int slot, int32_t type) {
  return slot >= 0 && slot < LE_FX_MAX && le_fx_type_clock_lfo(type) &&
         fx->lfo[slot][0] != 0.0f;
}

int le_fx_entry_lfo_drifts(int32_t type, const float* p, int32_t len, int sr) {
  double rate = 0.0;
  if (type == LE_FX_TREMOLO && p[1] > 0.0f) rate = le_tremolo_rate(p);
  if (type == LE_FX_ECHO && p[2] > 0.0f) rate = LE_ECHO_WOW_HZ;
  if (rate <= 0.0 || len <= 0) return 0;
  const double cycles = rate * (double)len / (double)(sr > 0 ? sr : 48000);
  /* The miss each lap is the step at each loop top: held to LE_LFO_LAP_STEP
   * of output, through each kind's sensitivity to its phase. */
  const double tol = type == LE_FX_TREMOLO ? LE_TREMOLO_LAP_TOL
                                           : LE_ECHO_LAP_TOL;
  return fabs(cycles - floor(cycles + 0.5)) > tol;
}

/* Tremolo: sine LFO amplitude modulation, on the engine clock. p0 = rate
 * (0.1..12 Hz), p1 = depth. */
/* The tremolo's gain at LFO phase [ph] (cycles), both channels'. */
static float fx_tremolo_gain(double ph, const float* p) {
  const float depth = p[1];
  const float lfo = 0.5f * (1.0f + sinf(2.0f * LE_PI * (float)ph)); /* 0..1 */
  return 1.0f - depth * (1.0f - lfo);
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
  /* Resampled, the kernel keeps to its own ticks (fx_octaver_run). */
  const uint32_t clock = fx->oct_rs[slot] ? fx->oct_tick[slot] : le_fx_now(fx);
  const uint32_t to_go = (0u - (clock + phase)) & (uint32_t)(LE_PV_HOP - 1);
  return (int)to_go + 1;
}

/* The second voice's regions in the octaver scratch (LE_PV_SCRATCH, after
 * the frame arrays listed at le_pv_stage_analyse): its synthesis spectrum,
 * and its running phases, which persist from frame to frame (#1464). */
#define LE_PV_S_RE2(o) ((o)->scratch + LE_PV_N + 5 * LE_PV_BINS)
#define LE_PV_S_IM2(o) ((o)->scratch + LE_PV_N + 6 * LE_PV_BINS)
#define LE_PV_S_PHASE2(o) ((o)->scratch + LE_PV_N + 7 * LE_PV_BINS)

static void le_pv_reset_runtime(le_fx_state* fx, int slot, int chan,
                                int ticks);
static void le_low_reset_runtime(le_oct_low* L);

/* Puts channel [chan] of octaver slot [slot] on [mode] with its runtime
 * reset, keeping its hop schedule: the new mode's heavy tick lands where the
 * old mode's next one would have. Re-seeding from the phase instead would
 * anchor it to this instant and move it off the instance's quarter. */
static void le_oct_switch_mode(le_fx_state* fx, int slot, int chan, int mode) {
  le_octaver_state* o = &fx->oct[slot][chan];
  const int ticks = le_oct_ticks_to_work(o);
  o->cur_mode = mode;
  le_pv_reset_runtime(fx, slot, chan, ticks);
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
  if (low != NULL) le_low_reset_runtime(low);
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

/* The most the held formants may lift a region (+18 dB). The envelope's
 * ratio between where a region lands and where it came from grows without
 * bound where the source is all but silent (an octave down from the empty
 * top of the band), and lifted the window's leakage there to the level of
 * the signal: a voice that the slightest change in the input moved
 * (#1547). */
#define LE_PV_FORMANT_MAX 8.0f

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
 * keeps the shipped octaver's behaviour). [by_owner]: the low band takes
 * its share of each bin by the partial that owns it (the first voice), not
 * of each region's bins wherever they land (the second; see below). */
static void le_pv_shift_into(le_octaver_state* o, float ratio, float* sum_phase,
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
            le_wrap_pi(peak_phase + (in_phase[k] - in_phase[peak]));
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

static void le_pv_stage_shift(le_octaver_state* o) {
  le_pv_shift_into(o, o->frame_ratio, o->sum_phase, LE_PV_S_RE(o),
                   LE_PV_S_IM(o), 0, 1);
}

/* The second voice's shift (#1464): the same analysis at its own ratio,
 * into its own spectrum and phases. */
static void le_pv_stage_shift2(le_octaver_state* o) {
  le_pv_shift_into(o, o->frame_ratio2, LE_PV_S_PHASE2(o), LE_PV_S_RE2(o),
                   LE_PV_S_IM2(o), o->frame_ratio2 < 1.0f, 0);
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
                        float level1, float level2, float low_w,
                        float low_g, float low_kc) {
  if (o->out == NULL || o->scratch == NULL) return 0.0f;
  switch (o->hop_count) {
    case 0:
      le_pv_stage_analyse(o, fifo, head, cap);
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
static void le_psola_pass_apply(le_octaver_state* o, float period,
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
static void le_psola_pass_begin(le_octaver_state* o, const float* fifo,
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
  if (!le_yin_begin(&ps->yin, win, LE_PSOLA_DWIN, LE_OCT_RATE / d, LE_PSOLA_MIN_HZ,
                    LE_PSOLA_MAX_HZ, LE_PS_DP(o), LE_PSOLA_DWIN / 2 + 1)) {
    le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  ps->phase = 1;
}

/* Hands the finished coarse pass to the refinement, freezing the kernel-rate
 * window it walks, or applies the coarse period as it is when refining would
 * not change what plays: a period too long for two of it to fit the
 * kernel-rate window, or a frame under the voicing gate (fx_octaver's dry
 * fallback takes it whatever its period). */
static void le_psola_coarse_done(le_octaver_state* o, const float* fifo,
                                 int cap) {
  le_psola_pass* ps = le_ps(o);
  float period = 0.0f;
  le_yin_finish(&ps->yin, &period, &ps->conf);
  if (period <= 0.0f) {
    le_psola_pass_apply(o, 0.0f, 0.0f);
    return;
  }
  ps->coarse = period * (float)LE_PSOLA_DECIM;
  if (ps->conf < 0.3f ||
      !le_refine_begin(&ps->ref, ps->coarse, LE_PSOLA_DECIM, LE_PSOLA_RAW)) {
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

/* One tick of detection: starts a pass on each hop, adds the tick's work to
 * the credit and, while it is positive, spends it on lags (a lag is never
 * split, so the last one may overshoot into a debt), carrying from the coarse
 * pass into the refinement, and applies the result once the refinement is
 * in. [hop] is set on the tick a PSOLA hop begins. */
static void le_psola_pass_tick(le_octaver_state* o, const float* fifo, int end,
                               int cap, int hop) {
  le_psola_pass* ps = le_ps(o);
  if (hop) le_psola_pass_begin(o, fifo, end, cap);
  const int32_t work = LE_PSOLA_WORK_PER_TICK;
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
  le_psola_pass_tick(o, fifo, head - lag, cap, hop);

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
  int didx = head - le_octaver_latency(o) + 1;
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
 * Per channel: le_low_write low-passes every input sample into the band's
 * ring and its decimated detection ring, le_low_follow tracks its pitch
 * and weight, le_low_play plays the two down voices from the ring.
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
static void le_low_reset_runtime(le_oct_low* L) {
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
static void le_low_forget(le_oct_low* L) {
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

/* le_low_reset_runtime and le_low_forget, and the crossover and both rings
 * cleared. */
static void le_low_clear(le_oct_low* L) {
  le_low_forget(L);
  memset(L->ring, 0, sizeof(L->ring));
  L->head = 0;
  le_low_reset_runtime(L);
}

/* Sets up a zeroed band (control thread, before the slot is published):
 * the crossover's coefficients (the bilinear 2nd-order Butterworth) and the
 * centre (each section delays low frequencies by sqrt(2) / (2 K)
 * samples). */
static void le_low_init(le_oct_low* L) {
  const double k = le_prewarp(LE_OCT_LOW_HZ, LE_OCT_RATE);
  const double r2 = 1.4142135623730951;
  const double n = 1.0 / (1.0 + r2 * k + k * k);
  L->lp[0] = (float)(k * k * n);
  L->lp[1] = 2.0f * L->lp[0];
  L->lp[2] = L->lp[0];
  L->lp[3] = (float)(2.0 * (k * k - 1.0) * n);
  L->lp[4] = (float)((1.0 - r2 * k + k * k) * n);
  L->centre = (float)((double)LE_PV_LATENCY - r2 / k);
  L->work = 0;
  le_low_clear(L);
}

/* Writes input sample [x] through the crossover into the ring, and the
 * decimator, and follows the input's and the band's power. */
static void le_low_write(le_oct_low* L, float x) {
  L->e_in += (x * x - L->e_in) * LE_OCT_LOW_EK;
  const float y = le_biquad_tick(L->lp, L->z[1],
                                 le_biquad_tick(L->lp, L->z[0], x));
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
static float le_low_read(const le_oct_low* L, float d) {
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
static void le_low_apply(le_oct_low* L, float period, float conf) {
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
 * as PSOLA's sliced pass does (le_psola_pass_tick). A band holding under a
 * twentieth of the input's power carries no note of its own (a tone above
 * the crossover leaks into it): no pitch, and no pass. */
static void le_low_detect(le_oct_low* L, int analysis) {
  if (analysis) {
    if (L->e_low < 0.05f * L->e_in) {
      L->busy = 0;
      le_low_apply(L, 0.0f, 0.0f);
      return;
    }
    int32_t k = L->dhead; /* the oldest decimated sample */
    for (int i = 0; i < LE_OCT_LOW_DWIN; ++i) {
      L->win[i] = L->dring[k];
      if (++k == LE_OCT_LOW_DWIN) k = 0;
    }
    L->busy = le_yin_begin(&L->yin, L->win, LE_OCT_LOW_DWIN,
                           LE_OCT_RATE / LE_OCT_LOW_DECIM,
                           LE_OCT_LOW_MIN_HZ, LE_OCT_LOW_MAX_HZ, L->dp,
                           LE_OCT_LOW_DWIN / 2 + 1);
    if (L->busy) {
      /* The pass's lags spread over the ticks until the next one starts,
       * with a quarter to spare. */
      L->work = (5 * L->yin.maxlag * L->yin.integ) / (4 * LE_PV_HOP) + 1;
    } else {
      le_low_apply(L, 0.0f, 0.0f); /* silence */
    }
  }
  if (!L->busy) return;
  L->credit += L->work;
  if (L->credit > L->work) L->credit = L->work; /* no banking while idle */
  while (L->credit > 0 && L->busy) {
    const int32_t was = L->yin.tau;
    const int done = le_yin_step(&L->yin, L->credit);
    L->credit -= (L->yin.tau - was) * L->yin.integ;
    if (done) {
      float period = 0.0f;
      float conf = 0.0f;
      le_yin_finish(&L->yin, &period, &conf);
      L->busy = 0;
      /* A dip still falling at the longest lag is a note below the floor
       * (a 55 Hz sine reads as 60 Hz there), and one at the shortest a note
       * above the range read as a multiple of its period: no pitch. */
      if (period >= (float)(L->yin.maxlag - 1) ||
          period <= (float)(L->yin.minlag + 1)) {
        conf = 0.0f;
      }
      le_low_apply(L, period * (float)LE_OCT_LOW_DECIM, conf);
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
static float le_low_voice(le_oct_low* L, le_oct_low_voice* v, float ratio,
                          float per) {
  float y = le_low_read(L, v->d);
  const float step = 1.0f - ratio;
  if (v->fade > 0) {
    const float t = (float)v->fade / (float)v->fade_len; /* 1 down to 0 */
    const float w = t * t * (3.0f - 2.0f * t);
    y += w * (le_low_read(L, v->d_old) - y);
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
 * partial (le_pv_shift_into: of the bins it owns in the first voice, of its
 * region in the second), so a note near the crossover is not split between
 * two voices whose phases differ. A note above the crossover is left to the
 * vocoder, the band fading out by 1.15 fc. The voices come in over a
 * smoothstep from LE_OCT_LOW_MIN_HZ, where the Looper X's start
 * (engine_fx.h): their level only, as the Looper X plays no other voice
 * there, so the vocoder still hands the note over. */
static void le_low_follow(le_oct_low* L, int analysis) {
  le_low_detect(L, analysis);
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
static float le_low_play(le_oct_low* L, int ticks, float level1,
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
  if (L->level1 > 1e-4f) y += L->level1 * le_low_voice(L, &L->v[0], 0.5f, per);
  if (L->level2 > 1e-4f) y += L->level2 * le_low_voice(L, &L->v[1], 0.25f, per);
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
 * (fx_octaver_run), which is the time base of its smoothing, its dip and its
 * detection; [cap] is only its ring's length. */
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
      /* The band heard nothing while the slot was not ticked either. */
      le_oct_low* low = atomic_load_explicit(&o->low, memory_order_acquire);
      if (low != NULL) le_low_forget(low);
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
        const int ticks = le_oct_ticks_to_work(o);
        o->cur_mode = requested;
        le_oct_set_ticks_to_work(o, ticks);
      } else {
        le_oct_switch_mode(fx, slot, chan, requested);
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
      le_oct_switch_mode(fx, slot, chan, requested);
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
  if (low != NULL) le_low_write(low, x);
  float wet;
  if (o->cur_mode == 0) {
    float band = 0.0f;
    float low_w = 0.0f;
    float low_g = 1.0f;
    float low_kc = 1.0f;
    if (low != NULL) {
      le_low_follow(low, o->hop_count == 0);
      if (!up) { /* each voice at its Vol, untrimmed (le_doct_settings) */
        band = le_low_play(low, o->hop_count, p[8], p[7]);
        low_w = low->gate;
        low_g = low->boost;
        low_kc = LE_OCT_LOW_KC;
      }
    }
    wet = le_pv_tick(o, buf, head, cap, ratio, p[4] >= 0.5f, ratio * ratio,
                     1.0f - p[5], level2, low_w, low_g, low_kc) +
          band;
  } else {
    wet = le_psola_tick(o, buf, head, cap, ratio);
  }

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

/* The delay rings [type] runs on (defined with the vtable). */
static int le_fx_ring_count(int32_t type);

/* Whether delay[slot][c] is one this thread may read for a slot running a
 * kind with [rings] rings: one of the kind's, or one the slot's earlier
 * kinds left (ring_known). */
static int le_fx_ring_readable(const le_fx_state* fx, int slot, int c,
                               int rings) {
  return c < rings || ((fx->ring_known[slot] >> c) & 1u) != 0;
}

/* Stores slot [slot]'s drain flag [v]. le_engine_get_snapshot reads the
 * flag on the control thread (#1733), so it is stored whole with a relaxed
 * builtin store: on every target that is the plain store it replaces. */
#define LE_FX_DRAIN_STORE(fx, slot, v) \
  __atomic_store_n(&(fx)->enable_drain[(slot)], (v), __ATOMIC_RELAXED)

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay read head, one-pole memory, the octaver phase-vocoder runtime
 * when [type] is of its family, a heap-state kind's block) so a freshly
 * engaged effect starts clean — no filter blow-up from stale
 * integrators, no delay-read of old content. Does NOT free or allocate the delay
 * ring or octaver buffers; the control thread owns their lifetime. Shared by
 * le_lane_reset, le_monitor_input_reset, and the SET_*_FX ring handlers (which
 * reset one slot when its type changes), removing what was a copy-pasted clear.
 *
 * RT note: this runs on the AUDIO THREAD (the SET_*_FX ring handlers). For an
 * allocated octaver slot it memsets the phase-vocoder accumulator and phase
 * buffers (~9 KB/channel; the frame scratch is not cleared, see
 * le_octaver_state::analysed). That is bounded and fires only on a discrete type-change
 * event (never per sample). */
/* The Mode delay's line (defined with its kernel). */
static void le_mdly_reset(struct le_fx_line* line);
static void le_mdly_clear(struct le_fx_line* line);
static int32_t le_mdly_frames(const struct le_fx_line* line);
/* The Amp+Cab's instance (defined with its kernel). */
static void le_amp_reset(struct le_fx_amp* a);

void le_fx_entry_reset(le_fx_state* fx, int slot, int32_t type) {
  /* The octaver family's runtime lives in its heap buffers, which the
   * control thread may be preparing for a coming retype of this slot while
   * the slot runs another kind (prepare_recipe writes them into the live
   * state). Only a slot that runs one of those kinds has them published to
   * this thread, so only such a slot touches them (#1522). Any other slot's
   * octaver runtime is unread until a type of the family lands here, and
   * that landing resets it. */
  const int hops = le_fx_type_hops(type);
  /* The kind's rings were published with it: from here on they are known
   * to this thread whatever runs on the slot. */
  const int rings = le_fx_ring_count(type);
  for (int c = 0; c < rings; ++c) {
    if (fx->delay[slot][c] != NULL) fx->ring_known[slot] |= (uint8_t)(1u << c);
  }
  struct le_fx_line* line =
      atomic_load_explicit(&fx->line[slot], memory_order_acquire);
  if (line != NULL) le_mdly_reset(line);
  struct le_fx_amp* amp =
      atomic_load_explicit(&fx->amp[slot], memory_order_acquire);
  if (amp != NULL) le_amp_reset(amp);
  fx->lfo_frame[slot] = 0;
  fx->lfo_rate[slot] = 0.0;
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
    o->cur_mode = 0;  /* phase vocoder, until the settings say otherwise */
    o->fresh = LE_PV_LATENCY;
    o->xfade = 1.0f;  /* steady (no gain dip) */
    if (!hops) continue;
    le_pv_reset_runtime(fx, slot, chan, le_oct_seeded_ticks(fx, slot));
    /* A retyped slot's band starts with nothing heard: it heard nothing
     * while the slot ran as another kind. */
    le_oct_low* low = atomic_load_explicit(&o->low, memory_order_acquire);
    if (low != NULL) le_low_forget(low);
  }
  fx->oct_run[slot] = 0; /* the resamplers start again (fx_octaver_run) */
  memset(&fx->slice[slot], 0, sizeof(fx->slice[slot]));
  /* A heap-state kind starts clean too: its block is cleared and settled
   * the next time the slot runs (fx_kind_state). */
  le_fx_kinds* kinds = atomic_load_explicit(&fx->kinds, memory_order_acquire);
  if (kinds != NULL) kinds->slot[slot].cur = NULL;
  /* A retyped slot has no tail to drain: a stale budget would let the next
   * re-enable edge skip its clean reset and read the old type's ring. */
  LE_FX_DRAIN_STORE(fx, slot, 0);
  fx->enable_quiet[slot] = 0;
}

/* Seeds slot [slot]'s octaver runtime settled at [params] (engine_fx.h). */
void le_fx_octaver_seed_settled(le_fx_state* fx, int slot,
                                const float* params) {
  if (fx == NULL || params == NULL || slot < 0 || slot >= LE_FX_MAX) return;
  /* The mode needs no seeding: a slot just reset takes its settings' mode
   * within a latency of its reset (fx_octaver, #1482). */
  for (int chan = 0; chan < 2; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    o->sm_shift = params[0];
    o->sm_tone = params[1];
    o->sm_mix = params[2];
    o->sm_level = 1.0f - params[5];
    o->xfade = 1.0f; /* steady: no gain dip on the first sample */
  }
}

/* Zeroes slot [slot]'s delay rings ([cap] floats each) when allocated: the
 * audio-thread half of "start clean" that le_fx_entry_reset leaves out.
 * Shared by the settled-bypass re-enable edge and Cut all sound; one ring is
 * cap floats, so callers decide the spacing. Of the rings, only those [type]
 * runs on or an earlier kind left (ring_known): the control thread may be
 * allocating another for a coming retype while the slot runs [type]
 * (#1522). */
void le_fx_entry_clear_rings(le_fx_state* fx, int slot, int cap,
                             int32_t type) {
  /* The Mode delay's line reads nothing older than its clear: no zeroing
   * of its seconds of ring on the audio thread. */
  struct le_fx_line* line =
      atomic_load_explicit(&fx->line[slot], memory_order_acquire);
  if (line != NULL) le_mdly_clear(line);
  const int rings = le_fx_ring_count(type);
  for (int chan = 0; chan < 2; ++chan) {
    if (le_fx_ring_readable(fx, slot, chan, rings) &&
        fx->delay[slot][chan] != NULL) {
      memset(fx->delay[slot][chan], 0, (size_t)cap * sizeof(float));
    }
    /* The Dual Octaver's low band reads its own ring (#1467). */
    le_oct_low* low =
        atomic_load_explicit(&fx->oct[slot][chan].low, memory_order_acquire);
    if (low != NULL) le_low_clear(low);
  }
}

/* Seeds chain slot [slot]'s enable-crossfade runtime SETTLED at enabled, so a
 * freshly created (zeroed) le_fx_state does not read as a mid-ramp bypass and
 * fade in on first use. Every standalone le_fx_state owner calls this after
 * creating/zeroing its state: le_lane_reset / le_monitor_input_reset, the
 * offline renders (through le_fx_enable_seed_at), and the test harnesses.
 * Deliberately NOT part of le_fx_entry_reset, which touches only the DRAIN
 * half of the runtime (a retyped slot has no tail to drain) and leaves an
 * in-flight enable ramp alone. */
void le_fx_enable_seed_settled(le_fx_state* fx, int slot) {
  fx->enable_mix[slot] = 1.0f;
  fx->enable_target[slot] = 1;
  fx->enable_warmup[slot] = 0;
  LE_FX_DRAIN_STORE(fx, slot, 0);
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
LE_AUDIO_HOT_AT(12) int le_fx_enable_settled_bypassed(const le_fx_state* fx, int slot) {
  return fx->enable_mix[slot] == 0.0f && fx->enable_target[slot] == 0 &&
         fx->enable_warmup[slot] == 0 && fx->enable_drain[slot] == 0 &&
         fx->enable_quiet[slot] == 0;
}

void le_fx_enable_force_bypass(le_fx_state* fx, int slot) {
  fx->enable_mix[slot] = 0.0f;
  fx->enable_target[slot] = 0;
  fx->enable_warmup[slot] = 0;
  LE_FX_DRAIN_STORE(fx, slot, 0); /* a slot nobody processes cannot drain */
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
    le_rt_free(o->rs_in);
    o->rs_in = NULL;
    le_rt_free(o->rs_out);
    o->rs_out = NULL;
    fx->oct_tab[slot] = NULL;
    le_rt_free(atomic_load_explicit(&o->low, memory_order_relaxed));
    atomic_store_explicit(&o->low, NULL, memory_order_relaxed);
  }
}

void le_fx_free_delay(le_fx_state* fx, int slot) {
  le_rt_free(fx->delay[slot][0]);
  fx->delay[slot][0] = NULL;
  le_rt_free(fx->delay[slot][1]);
  fx->delay[slot][1] = NULL;
  fx->ring_known[slot] = 0;
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
  fx_filter(fx, slot, sr, l, r, p);
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
  const double ph = le_clock_lfo(fx, slot, le_tremolo_rate(p), sr);
  const float g = fx_tremolo_gain(ph, p);
  *l *= g;
  *r *= g;
}
/* ---- The pitch kinds at rates other than 48 kHz (#1547) ----
 *
 * The octaver's kernel counts in samples: its 1024-point frame, its hop,
 * PSOLA's grains and its pitch detection's windows. At another rate the
 * same counts are other times and other frequencies (a bin is 93.75 Hz at
 * 96 kHz, 46.9 at 48: the down voices on bass, #1467). So the kernel runs
 * at LE_OCT_RATE at every rate, as the Looper X runs its own engine at
 * 48 kHz behind its converter: the input is resampled to 48 kHz, the
 * kernel ticks there, and its output is resampled back. Each resampler is
 * a Kaiser-windowed sinc, linear phase, read at its fractional position
 * from a table of LE_OCT_RS_PHASES phases (linear between two): flat to
 * 0.43 of the lower rate and 72 dB down from half of it. The effect's
 * latency is then a whole number of frames at the rate (le_oct_rs_latency_of):
 * the kernel's 1216 frames at 48 kHz, 25.3 ms, and both filters' delays.
 * A kernel tick is placed by the engine clock (by the slot's own frame
 * count for a state nobody clocks), so a render reproduces the live
 * chain's ticks. */
#define LE_OCT_RS_PHASES 256
#define LE_OCT_RS_BETA 6.98 /* 72 dB */

typedef struct le_oct_rs {
  int32_t sr;
  int32_t win, wout;  /* taps a side: into the kernel (rate sr), out (48 kHz) */
  int32_t d48;        /* kernel ticks the input reaches the kernel late */
  int32_t latency;    /* the effect's, frames at sr */
  float* gin;         /* (LE_OCT_RS_PHASES + 1) x 2 win weights */
  float* gout;        /* (LE_OCT_RS_PHASES + 1) x 2 wout */
} le_oct_rs;

static le_rate_tables le_oct_rs_tabs = {.mu = PTHREAD_MUTEX_INITIALIZER};

/* A filter's half-width, in samples of its input at [rate_in], for the
 * pass and stop edges of the lower of [sr] and 48 kHz. */
static int le_oct_rs_width(int sr, double rate_in) {
  const double lower = sr < LE_OCT_RATE ? (double)sr : (double)LE_OCT_RATE;
  const double dw = 2.0 * 3.14159265358979323846 * (0.5 - 0.43) * lower / rate_in;
  const int n = (int)ceil((72.0 - 8.0) / (2.285 * dw)) + 1;
  return (n + 1) / 2;
}

/* The ticks the input reaches the kernel late: enough that the way in's
 * last tap at [sr], [win] a side, is a frame already heard. A whole number
 * of ticks, so the kernel hears the input's own 48 kHz samples (its hop
 * and frames are not time-invariant: a fraction of a tick moves them). */
static int le_oct_rs_d48(int sr, int win) {
  return (int)ceil((double)(win + 1) * LE_OCT_RATE / sr);
}

/* The effect's latency at [sr], frames: the [d48] ticks in, the kernel's
 * LE_PV_LATENCY, and the way out's [wout] taps at 48 kHz, so its last tap
 * is a tick already made. */
static int le_oct_rs_latency_of(int sr, int d48, int wout) {
  return (int)ceil((double)(d48 + LE_PV_LATENCY + wout + 2) * sr / LE_OCT_RATE);
}

/* One filter's table: weights for each of the phases (and one past), for
 * an input at [rate_in], cut midway between the pass and stop edges. Each
 * phase sums to 1, so a tone passes at unity whatever the fraction. */
static float* le_oct_rs_design(int sr, double rate_in, int w) {
  float* g = (float*)calloc((size_t)(LE_OCT_RS_PHASES + 1) * 2 * w, sizeof(float));
  if (g == NULL) return NULL;
  const double lower = sr < LE_OCT_RATE ? (double)sr : (double)LE_OCT_RATE;
  /* the cutoff, as a share of rate_in's Nyquist */
  const double fc = (0.5 + 0.43) * lower / rate_in;
  const double i0b = le_bessel_i0(LE_OCT_RS_BETA);
  for (int p = 0; p <= LE_OCT_RS_PHASES; ++p) {
    float* row = g + (size_t)p * 2 * w;
    double sum = 0.0;
    for (int j = 0; j < 2 * w; ++j) {
      /* tap j reads the sample w - 1 - j before the position's whole part */
      const double t = (double)p / LE_OCT_RS_PHASES + (double)(w - 1 - j);
      const double u = t / (double)w;
      double h = 0.0;
      if (fabs(u) < 1.0) {
        const double a = 3.14159265358979323846 * fc * t;
        const double sinc = a == 0.0 ? 1.0 : sin(a) / a;
        h = fc * sinc * le_bessel_i0(LE_OCT_RS_BETA * sqrt(1.0 - u * u)) / i0b;
      }
      row[j] = (float)h;
      sum += h;
    }
    for (int j = 0; j < 2 * w; ++j) row[j] = (float)(row[j] / sum);
  }
  return g;
}

/* The resamplers' tables for [sr] (le_rate_tables_get), or NULL when they
 * cannot be made: the filters would outgrow the rings. */
static void* le_oct_rs_make(int32_t sr) {
  le_oct_rs* t = (le_oct_rs*)calloc(1, sizeof(*t));
  if (t == NULL) return NULL;
  t->sr = sr;
  t->win = le_oct_rs_width(sr, (double)sr);
  t->wout = le_oct_rs_width(sr, (double)LE_OCT_RATE);
  t->d48 = le_oct_rs_d48(sr, t->win);
  t->latency = le_oct_rs_latency_of(sr, t->d48, t->wout);
  t->gin = le_oct_rs_design(sr, (double)sr, t->win);
  t->gout = le_oct_rs_design(sr, (double)LE_OCT_RATE, t->wout);
  /* What each ring must still hold: the input back to the oldest tap a
   * tick reads (a frame's ticks span up to sr / 48 kHz frames), the
   * output back to the oldest tap the frame reads. */
  if (t->gin == NULL || t->gout == NULL ||
      2 * t->win + 4 + sr / LE_OCT_RATE > LE_OCT_RS_RING ||
      2 * t->wout + 10 + LE_OCT_RATE / sr > LE_OCT_RS_RING) {
    free(t->gin);
    free(t->gout);
    free(t);
    return NULL;
  }
  return t;
}

/* The tables for [sr], made the first time (control thread); NULL when
 * they cannot be. */
static const le_oct_rs* le_oct_rs_get(int sr) {
  return (const le_oct_rs*)le_rate_tables_get(&le_oct_rs_tabs, sr,
                                              le_oct_rs_make);
}

/* The two channels' rings [a] and [b] (LE_OCT_RS_RING samples, indexed by
 * absolute frame) read at position [num] / [den] through the table [g] of
 * [w] taps a side, into [ya] and [yb]. The position is exact, so frames a
 * whole number of hops apart at the kernel's rate read with the same
 * weights. */
static void le_oct_rs_read(const float* a, const float* b, int64_t num,
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

static inline float fx_sanitize(float x);

/* A kind's settings for each kernel tick (Smart Tune's correction moves
 * with what the kernel detects); NULL for settings fixed for the frame. */
typedef void (*le_oct_tick_fn)(le_fx_state* fx, int slot, const float* p,
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
static void fx_octaver_run(le_fx_state* fx, int slot, int sr, int cap,
                           float* l, float* r, float* q, const float* p,
                           le_oct_tick_fn tick) {
  if (sr == LE_OCT_RATE || sr <= 0) {
    fx->oct_rs[slot] = 0;
    if (tick != NULL) tick(fx, slot, p, q);
    *l = fx_octaver(fx, slot, 0, cap, *l, q);
    *r = fx_octaver(fx, slot, 1, cap, *r, q);
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
  const uint32_t c = clocked ? le_fx_now(fx)
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
  o[0].rs_in[c & (LE_OCT_RS_RING - 1)] = fx_sanitize(*l);
  o[1].rs_in[c & (LE_OCT_RS_RING - 1)] = fx_sanitize(*r);
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
      const int ticks = le_oct_seeded_ticks(fx, slot);
      for (int ch = 0; ch < 2; ++ch) {
        le_pv_reset_runtime(fx, slot, ch, ticks);
        le_oct_low* low = atomic_load_explicit(&o[ch].low, memory_order_acquire);
        if (low != NULL) le_low_forget(low);
      }
    }
    if (tick != NULL) tick(fx, slot, p, q);
    float in_l;
    float in_r;
    le_oct_rs_read(o[0].rs_in, o[1].rs_in, heard * sr, LE_OCT_RATE, t->gin,
                   t->win, &in_l, &in_r);
    *out_l = fx_octaver(fx, slot, 0, cap, in_l, q);
    *out_r = fx_octaver(fx, slot, 1, cap, in_r, q);
  }
  /* The output [latency] frames behind: what the kernel made LE_PV_LATENCY
   * ticks after it heard the input of then. */
  const int64_t v = ((int64_t)c - t->latency) * LE_OCT_RATE +
                    (int64_t)(t->d48 + LE_PV_LATENCY) * sr;
  le_oct_rs_read(o[0].rs_out, o[1].rs_out, v, sr, t->gout, t->wout, l, r);
}

static void fx_octaver_process(le_fx_state* fx, int slot, int sr, int cap,
                               float* l, float* r, const float* p) {
  float q[9] = {p[0], p[1], p[2], p[3], p[4], 0.0f, 0.0f, 0.0f, 0.0f};
  fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
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
         type == LE_FX_DUAL_OCTAVER || type == LE_FX_SMART_TUNE;
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
static void le_st_settings(float* out) {
  out[0] = 0.5f;
  out[1] = 1.0f;
  out[2] = 1.0f;
  out[3] = 1.0f;
  out[4] = 0.0f;
}

void le_fx_octaver_settings(int32_t type, const float* params, float* out) {
  for (int k = 0; k < LE_FX_PARAMS; ++k) out[k] = params[k];
  out[5] = 0.0f; /* the wet voice's cut: none */
  out[6] = 0.0f; /* the plain octaver: a linear mix, a gliding shift */
  out[7] = 0.0f; /* no second voice */
  out[8] = 0.0f; /* no low band */
  if (type == LE_FX_DUAL_OCTAVER) {
    le_doct_settings(params, out);
    return;
  }
  if (type == LE_FX_SMART_TUNE) {
    le_st_settings(out);
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
  /* The nine settings the octaver's kernel reads (le_fx_octaver_settings). */
  float q[9] = {le_whammy_shift(p), 1.0f, 1.0f, 0.0f, 1.0f,
                0.0f, 0.0f, 0.0f, 0.0f};
  fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
}

static void fx_dual_octaver_process(le_fx_state* fx, int slot, int sr,
                                    int cap, float* l, float* r,
                                    const float* p) {
  float q[9];
  le_doct_settings(p, q);
  fx_octaver_run(fx, slot, sr, cap, l, r, q, p, NULL);
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

/* The duck's shape (#891 s17rhy, a steady 1 kHz tone at Bar, 1/2, 1/4, 1/8
 * and 1/16, Depth 50, 70, 85 and 100 %: the same at every rate and depth to
 * 0.001). It falls from the beat to full depth over the first 0.022 of the
 * period, straight in dB at full depth: (1 - 100^(-phase / 0.022)) / 0.99,
 * held at 1 (11 ms at 1/4 and 120 BPM, 44 ms at a bar); then it recovers as
 * LE_PUMP_SHAPE, every 1/40 of the period from the beat, to 0 by about
 * three quarters. */
#define LE_PUMP_ATTACK 0.022
static const float LE_PUMP_SHAPE[32] = {
    1.0f,    0.9998f, 0.9969f, 0.9934f, 0.9890f, 0.9835f, 0.9769f, 0.9688f,
    0.9590f, 0.9472f, 0.9331f, 0.9165f, 0.8968f, 0.8739f, 0.8473f, 0.8167f,
    0.7819f, 0.7425f, 0.6985f, 0.6497f, 0.5963f, 0.5385f, 0.4769f, 0.4121f,
    0.3450f, 0.2772f, 0.2103f, 0.1464f, 0.0890f, 0.0403f, 0.0074f, 0.0f};

/* The duck's steepest, at full depth at the attack's start: ln(100) /
 * 0.022 a period. The duck moves no faster than 1.5 times that, so the
 * shape itself plays as measured, while a gain step, a click (#813), where
 * an anchor moves the phase (a loop top that is not a whole number of
 * periods) glides as fast as the attack falls; and never faster than
 * across LE_PUMP_MIN_GLIDE_S, which only the fastest rates reach. */
#define LE_PUMP_MAX_SLOPE (1.5 * 4.605170186 / LE_PUMP_ATTACK)
#define LE_PUMP_MIN_GLIDE_S 0.00025

static float le_pump_shape(double phase) {
  const double x = phase * 40.0;
  if (!(x < 31.0)) return 0.0f;
  const int i = x > 0.0 ? (int)x : 0;
  const float f = (float)(x - (double)i);
  const float rec =
      LE_PUMP_SHAPE[i] + (LE_PUMP_SHAPE[i + 1] - LE_PUMP_SHAPE[i]) * f;
  if (phase >= LE_PUMP_ATTACK) return rec;
  /* 100^(-phase / attack) */
  const float att = (float)(
      (1.0 - exp(-phase * (4.605170185988091 / LE_PUMP_ATTACK))) / 0.99);
  return (att < 1.0f ? att : 1.0f) * rec;
}

/* The depth at full duck (#891 s17rhy): a = 0.99 d (2 - d), dips of 6.1,
 * 11.8, 20.1, 29.8 and 40.0 dB at 30, 50, 70, 85 and 100 %, each within
 * 0.15 dB of the captures (6.20, 11.89, 20.09, 29.93 and 40.09). */
static float le_pump_depth(float d) {
  if (!(d > 0.0f)) return 0.0f;
  if (d >= 1.0f) d = 1.0f;
  return 0.99f * d * (2.0f - d);
}


/* The measured shape at the frame [fx] is processing, for the rate
 * setting [rate_setting]; [frames], if not NULL, is set to the period in
 * frames (0 with no usable tempo). */
static float le_pump_shape_now(const le_fx_state* fx, int sr,
                               float rate_setting, double* frames) {
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
  if (frames != NULL) *frames = qpf > 0.0f ? period / (double)qpf : 0.0;
  return le_pump_shape(into / period);
}

void le_fx_pumper_seed_settled(le_fx_state* fx, int slot, const float* params,
                               int sr) {
  if (fx == NULL || params == NULL || slot < 0 || slot >= LE_FX_MAX) return;
  fx->lfo[slot][0] = le_pump_depth(params[1]);
  fx->lfo[slot][1] = fx->lfo[slot][0];
  fx->fx_lp[slot][0] = params[1];
  fx->fx_lp[slot][1] =
      fx->lfo[slot][0] *
      le_pump_shape_now(fx, sr > 0 ? sr : 48000, params[0], NULL);
}

static void fx_pumper_process(le_fx_state* fx, int slot, int sr, int cap,
                              float* l, float* r, const float* p) {
  (void)cap;
  const int32_t rate = sr > 0 ? sr : 48000;
  double period;
  const float e = le_pump_shape_now(fx, rate, p[0], &period);
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
  /* The duck itself (fx_lp[slot][1], 0 after a reset), held to
   * LE_PUMP_MAX_SLOPE. */
  float* duck = &fx->fx_lp[slot][1];
  const float d = *a * e - *duck;
  const double floor_f = 1.0 / (LE_PUMP_MIN_GLIDE_S * (double)rate);
  const float most = (float)(period > 0.0
                                 ? fmin(LE_PUMP_MAX_SLOPE / period, floor_f)
                                 : floor_f);
  *duck += d > most ? most : d < -most ? -most : d;
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
 * that half step three times); _ rests for a step, or half a step in a
 * pattern with lower-case letters (s6v: AB__dd and AA__dd; the capture
 * reads 48 to 54 dB down; this one is silent). From one slice to the next
 * the output crossfades, straight, over the 4 ms from the boundary: the
 * slice before plays on past its end as it fades out, and the new one fades
 * in (#1447, s4/21-23 against the Pumper's beat in the same session). <
 * plays the step before backwards (the factory "Reverse" preset is <<<<).
 * The list stops at <<<<: the Looper X's three Fd patterns after it are not
 * modelled (no capture, no factory preset), so they are not offered.
 *
 * Each slice fixes where it reads when it starts (a distance back, or the
 * point it mirrors about), so a tempo change under a slice does not move
 * it. A new pattern or step waits for the slice playing to end. A slice
 * cut short (a beat that jumps) crossfades to the next the same way. The
 * source is the slot's delay ring: a slice whose source is not all within
 * it is silent. With the 1 s ring the quarter-step factory presets (a
 * one-step replay) hold above 60 BPM, and Reverse (two 1/16 steps back) a
 * little above 30 BPM. */

/* The patterns, in the choice's order (the Looper X's SlicerPattern table,
 * read from its binary, up to <<<<; docs/plan/2026-10-20-looperx-derived-
 * tables.md). */
#define LE_SLICE_PATTERN_N 17
static const char* const LE_SLICE_PATTERNS[LE_SLICE_PATTERN_N] = {
    "AABB", "ABCC",   "AACD",   "ABC_",   "A_C_", "A_CC", "A___C___",
    "ABcccc", "AAccdd", "AB__dd", "AA__dd", "ABC<", "AB_<", "AA_<",
    "A_B_C<", "AB<<", "<<<<"};

/* The pattern position a stored choice value names. */
static int le_slice_index(float v) {
  const int i = (int)(v * (float)(LE_SLICE_PATTERN_N - 1) + 0.5f);
  return i < 0 ? 0 : i >= LE_SLICE_PATTERN_N ? LE_SLICE_PATTERN_N - 1 : i;
}

/* Each step position's length in quarter notes: 1/4, 1/4T, 1/8, 1/8T,
 * 1/16, 1/16T, 1/32, 1/32T, 1/64. */
static const double LE_SLICE_STEP[9] = {1.0,       2.0 / 3.0, 0.5,
                                        1.0 / 3.0, 0.25,      1.0 / 6.0,
                                        0.125,     1.0 / 12.0, 0.0625};

/* The crossfade from one slice to the next (#891: about 4 ms). */
#define LE_SLICE_FADE_S 0.004

/* A token's length in half steps: a capital letter or < is a step, a
 * lower-case letter half a step, and _ a step, or half a step in a pattern
 * that holds a lower-case letter (#891 s6v: AB__dd and AA__dd rest one
 * step between B and d, as A_C_ rests a step after each letter). */
static int le_slice_half_rest(const char* pat) {
  for (const char* d = pat; *d; ++d) {
    if (*d >= 'a' && *d <= 'z') return 1;
  }
  return 0;
}

static inline int le_slice_len(int half_rest, char c) {
  if (c >= 'a' && c <= 'z') return 1;
  return c == '_' && half_rest ? 1 : 2;
}

static int le_slice_cycle(const char* pat) {
  const int hr = le_slice_half_rest(pat);
  int n = 0;
  for (const char* c = pat; *c; ++c) n += le_slice_len(hr, *c);
  return n;
}

/* The token pattern [pat] plays [half] half steps into its cycle: its
 * index, its start, its length and where its letter first sounds (the
 * last three in half steps). */
static char le_slice_token(const char* pat, double half, int* index,
                           int* start, int* len, int* first) {
  const int hr = le_slice_half_rest(pat);
  int at = 0;
  for (const char* c = pat; *c; ++c) {
    const int n = le_slice_len(hr, *c);
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
        f += le_slice_len(hr, *d);
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

/* Ends slot [st]'s slice (the ring's newest frame at [pos] of [cap]): it
 * carries on as a voice fading out over [fade] frames from full, or at its
 * own crossfade's rate if that is faster (a slice shorter than 8 ms), so
 * the two fading voices free up in time; a reversed slice fades out by the
 * end of the source it latched, never turning round. It takes whichever of
 * the two fading voices is free or quieter (a third voice, quieter than
 * both, is dropped: with the gains summing to at most 1, it is at most a
 * third). */
static void le_slice_cut(le_fx_slice_state* st, double fade, int pos,
                         int cap) {
  if (st->cur.mode != LE_SLICE_SILENT && st->cur.gain > 0.0f) {
    const int k = st->out[0].gain <= st->out[1].gain ? 0 : 1;
    if (st->cur.gain > st->out[k].gain) {
      float step = fmaxf(st->cur.step, (float)(1.0 / fade));
      if (st->cur.mode == LE_SLICE_MIRROR) {
        int n = pos - st->cur.arg;
        if (n < 0) n += cap;
        const int left = st->cur.len - n;
        step = left > 0 ? fmaxf(step, st->cur.gain / (float)left)
                        : st->cur.gain;
      }
      st->out[k] = st->cur;
      st->out[k].step = step;
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

/* Where the beat falls in [st]'s pattern and step: the slice's token, its
 * id (0 is none; its cycle, token and settings), how far into it, its
 * length and fade, and for a letter how far back it reads (in frames at
 * [qpf] quarters a frame). */
typedef struct le_slice_pos {
  char tok;
  double id, into_f, len_f, fade_f, back_f;
} le_slice_pos;

static void le_slice_at(const le_fx_slice_state* st, double beat, float qpf,
                        int rate, le_slice_pos* sp) {
  const char* pat = LE_SLICE_PATTERNS[st->patt];
  const double half_q = LE_SLICE_STEP[st->step] * 0.5;
  const double cycle_q = (double)le_slice_cycle(pat) * half_q;
  const double cycles = floor(beat / cycle_q);
  const double pos_q = beat - cycles * cycle_q;
  int index, start, len, first;
  sp->tok = le_slice_token(pat, pos_q / half_q, &index, &start, &len, &first);
  const double fpq = 1.0 / (double)qpf; /* frames a quarter */
  sp->into_f = (pos_q - (double)start * half_q) * fpq;
  sp->len_f = (double)len * half_q * fpq;
  sp->fade_f = fmin(LE_SLICE_FADE_S * (double)rate, 0.5 * sp->len_f);
  sp->back_f = (double)(start - first) * half_q * fpq;
  sp->id = 1.0 +
           ((cycles * 32.0 + (double)index) * 20.0 + (double)st->patt) * 9.0 +
           (double)st->step;
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
  int si = (int)(p[1] * 8.0f + 0.5f);
  si = si < 0 ? 0 : si > 8 ? 8 : si;
  float qpf;
  int32_t num, den;
  const double beat = le_fx_beat_now(fx, rate, &qpf, &num, &den);
  /* No usable tempo: the input passes, crossfaded to over the 4 ms. */
  const int passes = !(qpf > 0.0f) || !isfinite(beat);
  if (passes) {
    le_slice_cut(st, fade4, pos, cap);
  } else if (beat < st->last_beat) {
    le_slice_cut(st, fade4, pos, cap); /* the beat went back: a new slice */
  }
  st->last_beat = passes ? 0.0 : beat;
  if (fresh) st->pass = passes ? 1.0f : 0.0f;

  if (!passes) {
    le_slice_pos sp;
    le_slice_at(st, beat, qpf, rate, &sp);
    /* A new pattern or step waits for the slice playing to end (or a
     * rest): a setting change never cuts a slice. */
    const int np = le_slice_index(p[0]);
    if ((sp.id != st->id || st->cur.gain <= 0.0f) &&
        (np != st->patt || si != st->step)) {
      st->patt = np;
      st->step = si;
      le_slice_at(st, beat, qpf, rate, &sp);
    }
    if (sp.id != st->id) {
      le_fx_slice_voice v = {LE_SLICE_SILENT, 0, 0, 0.0f, 0.0f};
      if (sp.tok == '<') {
        /* The step before, backwards: at n frames into the slice, 2n
         * back, so the slice needs twice its length of ring, and its fade
         * past the end as much as the ring has left. */
        if (2.0 * sp.len_f < (double)(cap - 1)) {
          const double run = fmin(sp.len_f + sp.fade_f, 0.5 * (cap - 2));
          const long n0 = lround(sp.into_f);
          long e = (long)pos - n0;
          while (e < 0) e += cap;
          v.mode = LE_SLICE_MIRROR;
          v.arg = (int32_t)e;
          v.len = (int32_t)ceil(run);
        }
      } else if (sp.tok != '_') {
        const double back = sp.back_f;
        if (back >= 0.0 && back < (double)cap - 0.5) {
          v.mode = LE_SLICE_BACK;
          v.arg = (int32_t)(back + 0.5);
        }
      }
      if (st->cur.mode == LE_SLICE_BACK && v.mode == LE_SLICE_BACK &&
          st->cur.arg == v.arg && st->cur.gain > 0.0f) {
        /* The same audio from the same point (a live slice into a live
         * one): it plays on. */
        v.gain = st->cur.gain;
      } else if (st->cur.gain > 0.0f) {
        /* The slice before plays on past its end, fading out, while this
         * one fades in from nothing (#891 s4/21-23: a linear crossfade of
         * about 4 ms from the boundary). */
        le_slice_cut(st, sp.fade_f, pos, cap);
      }
      v.step = (float)(1.0 / sp.fade_f); /* its crossfade's rate */
      st->cur = v;
      st->id = sp.id;
    }
    if (st->cur.mode != LE_SLICE_SILENT) {
      /* A slice fades in over its 4 ms (half the slice, if shorter), no
       * faster than the voices before it fade out, so they never sum above
       * the input. A reversed slice also fades out to end where its
       * latched source does, should the tempo drop under it; once that has
       * run out it stays silent. */
      float want = 1.0f;
      int src_out = 0;
      if (st->cur.mode == LE_SLICE_MIRROR) {
        int n = pos - st->cur.arg;
        if (n < 0) n += cap;
        const double left = (double)(st->cur.len - n);
        want = left >= sp.fade_f ? 1.0f
               : left > 0.0     ? (float)(left / sp.fade_f)
                                : 0.0f;
        src_out = left <= 0.0;
      }
      const float d = (float)(1.0 / sp.fade_f);
      const float g = fminf(fminf(fmaxf(want, st->cur.gain - d),
                                  st->cur.gain + d),
                            1.0f - le_slice_fading(st, 1));
      st->cur.gain = g > 0.0f ? g : 0.0f;
      if (src_out && st->cur.gain <= 0.0f) st->cur.mode = LE_SLICE_SILENT;
    } else {
      st->cur.gain = 0.0f;
    }
  }

  float wet[2] = {0.0f, 0.0f};
  if (st->cur.mode != LE_SLICE_SILENT && !passes) {
    wet[0] = st->cur.gain * le_slice_read(ring[0], cap, pos, &st->cur);
    wet[1] = st->cur.gain * le_slice_read(ring[1], cap, pos, &st->cur);
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
  /* Mix (#891 s17rhy, noise at 25, 50, 75, 90 and 100 %): the slices at
   * m (2 - m) and the dry at 1 - m^2, each within 0.015 of the captures
   * (0.75 and 0.75 at 50 %). */
  const float m = st->mix;
  const float dry = 1.0f - m * m;
  const float wg = m * (2.0f - m);
  float o[2] = {in[0] * dry + wet[0] * wg, in[1] * dry + wet[1] * wg};
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
 *   GRV the right at 251/300 of the time (0.881) and the left on time at
 *   0.753 + 0.129 Feedback, each carrying 0.143 of the other side's
 *   (s17grv: the early tap 15060 frames of 18000 at 1/8D, 20080 of 24000
 *   at 1/4, 10040 at 1/8; RES HI GRV within 0.1 dB at Feedback 0, 29 and
 *   50 %). The timings were measured on DIGI and RES HI, and are the same
 *   on both; the DAMPED and RESO LO ones, composed from them, match their
 *   own captures (s6v 9-16) within 0.3 dB through the fourth repeat.
 * Two limits, fit to DIGI passes (s6v 17-18, with s4/4): the echo
 * saturates from 0.55 toward 0.60 (at Feedback 0 % a 0 dBFS tone's echo
 * comes back 3.1 dB down on the capture and 2.95 dB here, a -3 dBFS one
 * 0.2 dB and 0.7 dB down), and what feeds back from 0.20 toward 0.40,
 * which holds DIGI at 100 % Feedback to the Looper X's level under a sweep
 * (within 0.4 dB a second over 9 s, but for the second the sweep ends in).
 * Its loop alone loses nothing per repeat; above the knee the limit
 * always gives back less than it takes, so a hot loop decays toward the
 * knee, and past the 9 s the capture covers that is unmeasured. The
 * echo's limit sits after the voicing and before the L/R and GRV side
 * gains (s7dly: RESO LO's echo saturates from -6 dBFS in, 3 dB earlier
 * than DIGI's, and DIGI L/R's left echo, at 0.219, saturates at 0 dBFS as
 * if at full level; the kernel within 0.5 dB on every ladder step). A
 * 5 Hz DC blocker sits in the loop. Its tempo is the live song's, which a print would not keep,
 * so a lane holding one is never printed. */

static const double LE_MDLY_QUARTERS[20] = {
    0.125, 1.0 / 6.0, 0.1875, 0.25, 1.0 / 3.0, 0.375, 0.5, 2.0 / 3.0, 0.75, 1.0,
    4.0 / 3.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0, 8.0};
#define LE_MDLY_XFADE_S 0.020 /* a new time crossfades over 20 ms */
#define LE_MDLY_GLIDE_S 0.010 /* feedback and mix glide over 10 ms */
#define LE_MDLY_HP_HZ 32.1
#define LE_MDLY_OUT_LP_HZ 10917.0
#define LE_MDLY_LOOP_LP_HZ 14832.0
#define LE_MDLY_DAMP_HZ 13203.0
#define LE_MDLY_GRV (251.0 / 300.0) /* GRV's early tap (s17grv) */
#define LE_MDLY_DC_HZ 5.0  /* the loop's DC blocker */
#define LE_MDLY_ECHO_KNEE 0.55f /* the voiced echo's limit: knee, ceiling */
#define LE_MDLY_ECHO_CEIL 0.60f
#define LE_MDLY_FB_KNEE 0.20f /* what feeds back: knee, ceiling */
#define LE_MDLY_FB_CEIL 0.40f
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

/* A one-pole high-pass, bilinear: y = b0 (x - x1) - a1 y1. */
typedef struct le_mdly_pole {
  float b0, a1, x1, y1;
} le_mdly_pole;

static void le_mdly_pole_set(le_mdly_pole* f, double hz, int sr, int high) {
  const double k = le_prewarp(hz, sr);
  f->b0 = (float)(high ? 1.0 / (1.0 + k) : k / (1.0 + k));
  f->a1 = (float)((k - 1.0) / (k + 1.0));
}

static inline float le_mdly_pole_hp(le_mdly_pole* f, float x) {
  const float y = f->b0 * (x - f->x1) - f->a1 * f->y1;
  f->x1 = x;
  f->y1 = y;
  return y;
}

/* [x] past [knee] bends toward [ceil] (tanh), the sign kept. */
static inline float le_mdly_limit(float x, float knee, float ceil) {
  const float ab = fabsf(x);
  if (ab <= knee) return x;
  return copysignf(knee + (ceil - knee) * tanhf((ab - knee) / (ceil - knee)),
                   x);
}

/* A biquad, transposed direct form II. */
typedef struct le_mdly_bq {
  float b0, b1, b2, a1, a2, z1[LE_RS_PH], z2[LE_RS_PH]; /* per phase (le_rs_phases) */
} le_mdly_bq;

static inline float le_mdly_bq_run(le_mdly_bq* f, float x, int ph) {
  const float y = f->b0 * x + f->z1[ph];
  f->z1[ph] = f->b1 * x - f->a1 * y + f->z2[ph];
  f->z2[ph] = f->b2 * x - f->a2 * y;
  return y;
}

/* The voicing [v] as a biquad at [sr]: an RBJ peak, a one-pole low-pass, or
 * the identity. */
static void le_mdly_bq_rbj(le_mdly_bq* f, int kind, double hz, double q,
                           double db, int sr);
static void le_mdly_voice_set(le_mdly_bq* f, int v, int sr) {
  if (LE_MDLY_VOICE[v].peak_db != 0.0) {
    le_mdly_bq_rbj(f, 0, LE_MDLY_VOICE[v].peak_hz, LE_MDLY_VOICE[v].peak_q,
                   LE_MDLY_VOICE[v].peak_db, sr);
  } else if (LE_MDLY_VOICE[v].damp_hz > 0.0) {
    le_mdly_bq_rbj(f, 3, LE_MDLY_VOICE[v].damp_hz, 0.707, 0.0, sr);
  } else {
    le_mdly_bq_rbj(f, 5, 0.0, 1.0, 0.0, sr);
  }
}

/* A section at [rate] into [f]: an RBJ peak of [db] at [hz], Q [q] (kind
 * 0); a low-pass (1) or high-pass (2) at [hz], Q [q]; a bilinear one-pole
 * low-pass (3) or high-pass (4) at [hz]; or the identity (5), each with its
 * 48 kHz response (le_rate_design). The state is kept. */
static void le_rate_design(int kind, double hz, double db, double q, int sr,
                           double c[5]);
/* le_rate_design's kinds past le_eq_design's: the bilinear one-poles, as
 * biquads. */
enum { LE_RS_LP1 = LE_EQ_HIGHCUT + 1, LE_RS_HP1 };
static void le_mdly_bq_rbj(le_mdly_bq* f, int kind, double hz, double q,
                           double db, int sr) {
  static const int as_rate[5] = {LE_EQ_LOMID, LE_EQ_HIGHCUT, LE_EQ_LOWCUT,
                                 LE_RS_LP1, LE_RS_HP1};
  double c[5] = {1.0, 0.0, 0.0, 0.0, 0.0};
  if (kind >= 0 && kind < 5) le_rate_design(as_rate[kind], hz, db, q, sr, c);
  f->b0 = (float)c[0]; f->b1 = (float)c[1]; f->b2 = (float)c[2];
  f->a1 = (float)c[3]; f->a2 = (float)c[4];
}

/* The Drum Rack's delay (#891 s6rev 22-27, #1473): a one-pole low-pass at
 * 3.3 kHz and a bell of +2.25 dB, Q 1, at Del Freq on every echo and again
 * in the loop, which loses 1.83 dB more; the echoes alone also pass a
 * one-pole high-pass at 19 Hz, at 0.964. Fit within 0.6 dB rms, 40 Hz to
 * 12 kHz, at Freq 0, 25, 50, 75 and 100 %; the bell's centre runs
 * 98 Hz to 10.6 kHz there, within 6 % of the control's 100 Hz to 10 kHz,
 * which the kernel uses. */
#define LE_MDLY_DRUM_LP_HZ 3307.0
#define LE_MDLY_DRUM_BELL_DB 2.25
#define LE_MDLY_DRUM_BELL_Q 1.0
#define LE_MDLY_DRUM_HP_HZ 19.4
#define LE_MDLY_DRUM_LEVEL 0.964f
#define LE_MDLY_DRUM_LOOP_DB (-1.83)

/* The Dub Rack's delay (#891 s6rev 28-37, #1473): a low-pass that Damp
 * sets (a table: its corner and Q at 0, 35 and 100 %) and a peak of
 * 11.0 dB x Reso^2.72 at Res-Freq (6.0 dB at the default 80 %), Q
 * 0.69 + 0.05 Reso, on every echo and
 * again in the loop, which loses 4.45 dB more; the echoes alone also pass
 * a 14 Hz high-pass (Q 0.2). Fit within 0.6 dB rms (0.9 at Damp 100 %),
 * 40 Hz to 12 kHz. L/R Ratio puts the right echo at 1 - Ratio / 2 of the
 * time, each side with 0.143 of the other's, at side gains measured at
 * Ratio 0, 50 and 100 % (Feedback 50 % only: the Mode delay's L/R left
 * gain moves with Feedback, the Dub's was not captured at others).
 *
 * The damping table is fitted at 48 kHz, and its default's corner sits at
 * the 0.45-of-the-rate clamp: the section is mostly the bilinear warp. At
 * other rates le_rate_design gives it that 48 kHz response, as it does
 * every section here. */
#define LE_MDLY_DUB_PEAK_DB 11.02
#define LE_MDLY_DUB_PEAK_POW 2.72 /* 6.0 dB at Reso 80 %, 11.0 at 100 % */
#define LE_MDLY_DUB_PEAK_Q0 0.69
#define LE_MDLY_DUB_PEAK_Q1 0.05
#define LE_MDLY_DUB_HP_HZ 14.06
#define LE_MDLY_DUB_HP_Q 0.20
#define LE_MDLY_DUB_LOOP_DB (-4.45)
#define LE_MDLY_DUB_CROSS 0.143f
static const double LE_MDLY_DUB_DAMP[3][3] = {
    {0.0, 11866.0, 1.015}, {0.35, 21600.0, 0.141}, {1.0, 10788.0, 0.100}};
static const float LE_MDLY_DUB_SIDES[3][3] = {
    {0.0f, 0.751f, 0.750f}, {0.5f, 0.659f, 0.754f}, {1.0f, 0.533f, 0.852f}};

/* The Drum's or Dub's voicing [v] (4, 5) at the settings [s] (freq, damp,
 * ratio, reso, res-freq) into [line] at [sr]; [fresh] also sets the
 * sections no setting moves. */
static void le_mdly_own_voice_set(struct le_fx_line* line, int v,
                                  const float* s, int sr, int fresh);
static float le_fx_smooth_k(int sr);
static inline void le_fx_step_toward(float* cur, float tgt, float k);

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
  le_mdly_bq voice2[2]; /* the Drum's and Dub's second section (else 1) */
  le_mdly_bq out_hp[2]; /* the Drum's and Dub's high-pass, echoes only */
  float out_g;          /* the Drum's level on its echoes (else 1) */
  float cur[5];   /* freq, damp, ratio, reso, res-freq: gliding, set for */
  float k;        /* le_fx_smooth_k at [sr] */
  int32_t tick;   /* frames to the next glide step */
  int32_t ramp;   /* frames of the voicing's coefficient ramp left */
  float ramp_d[4][5]; /* per frame: voice[0], voice[1], voice2[0], voice2[1] */
  le_mdly_bq ramp_to[4]; /* where it lands */
  int32_t etap, etap_old; /* the early tap, frames, and the one fading out */
  le_mdly_pole hp[2], dc;
  le_mdly_bq lp_out[2], lp_loop; /* one-poles, as biquads (le_rate_design) */
  int32_t timing; /* the last frame's: plain, L/R or GRV */
  int32_t ph, nph; /* the sections' phase this frame (le_rs_phases) */
  float loop_g;
  /* What the rate and the tempo give, kept until they change: the glide's
   * step, the crossfade's frames, and the time in frames for note value
   * want_div at want_qpf quarters a frame (0: none yet). */
  float glide;
  int32_t xf_n;
  float want_qpf;
  int32_t want_div, want_frames;
  float ring[];
} le_fx_line;

/* Resets [line]'s runtime, keeping its ring (fill 0: nothing is read) and
 * its length, which is never rewritten. */
static void le_mdly_reset(le_fx_line* line) {
  memset(&line->pos, 0, offsetof(le_fx_line, ring) - offsetof(le_fx_line, pos));
  line->mode = -1;
}

static float le_mdly_clamp01(float v) {
  return v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v;
}

/* Section [f]'s coefficients onto [to], whose state stays its own. */
static void le_mdly_bq_copy(le_mdly_bq* to, const le_mdly_bq* f) {
  to->b0 = f->b0;
  to->b1 = f->b1;
  to->b2 = f->b2;
  to->a1 = f->a1;
  to->a2 = f->a2;
}

/* Both sides run the same sections: each is designed once, on the left,
 * and copied to the right. */
static void le_mdly_own_voice_set(le_fx_line* line, int v, const float* s,
                                  int sr, int fresh) {
  if (v == 4) { /* Drum */
    const double hz = 100.0 * pow(100.0, (double)le_mdly_clamp01(s[0]));
    if (fresh) {
      le_mdly_bq_rbj(&line->voice[0], 3, LE_MDLY_DRUM_LP_HZ, 0.707, 0.0, sr);
      le_mdly_bq_rbj(&line->out_hp[0], 4, LE_MDLY_DRUM_HP_HZ, 0.707, 0.0, sr);
      le_mdly_bq_copy(&line->voice[1], &line->voice[0]);
      le_mdly_bq_copy(&line->out_hp[1], &line->out_hp[0]);
    }
    le_mdly_bq_rbj(&line->voice2[0], 0, hz, LE_MDLY_DRUM_BELL_Q,
                   LE_MDLY_DRUM_BELL_DB, sr);
    le_mdly_bq_copy(&line->voice2[1], &line->voice2[0]);
    line->out_g = LE_MDLY_DRUM_LEVEL;
    line->loop_g = (float)pow(10.0, LE_MDLY_DRUM_LOOP_DB / 20.0);
    return;
  }
  /* Dub: the damping table, its corner and Q between points in octaves. */
  const double d = (double)le_mdly_clamp01(s[1]);
  const int i = d <= LE_MDLY_DUB_DAMP[1][0] ? 0 : 1;
  const double t = (d - LE_MDLY_DUB_DAMP[i][0]) /
                   (LE_MDLY_DUB_DAMP[i + 1][0] - LE_MDLY_DUB_DAMP[i][0]);
  const double lp_hz = LE_MDLY_DUB_DAMP[i][1] *
                       pow(LE_MDLY_DUB_DAMP[i + 1][1] / LE_MDLY_DUB_DAMP[i][1], t);
  const double lp_q = LE_MDLY_DUB_DAMP[i][2] *
                      pow(LE_MDLY_DUB_DAMP[i + 1][2] / LE_MDLY_DUB_DAMP[i][2], t);
  const double reso = (double)le_mdly_clamp01(s[3]);
  const double rf = 100.0 * pow(100.0, (double)le_mdly_clamp01(s[4]));
  le_mdly_bq_rbj(&line->voice[0], 1, lp_hz, lp_q, 0.0, sr);
  le_mdly_bq_rbj(&line->voice2[0], 0, rf,
                 LE_MDLY_DUB_PEAK_Q0 + LE_MDLY_DUB_PEAK_Q1 * reso,
                 LE_MDLY_DUB_PEAK_DB * pow(reso, LE_MDLY_DUB_PEAK_POW), sr);
  le_mdly_bq_copy(&line->voice[1], &line->voice[0]);
  le_mdly_bq_copy(&line->voice2[1], &line->voice2[0]);
  if (fresh) {
    le_mdly_bq_rbj(&line->out_hp[0], 2, LE_MDLY_DUB_HP_HZ, LE_MDLY_DUB_HP_Q,
                   0.0, sr);
    le_mdly_bq_copy(&line->out_hp[1], &line->out_hp[0]);
  }
  line->out_g = 1.0f;
  line->loop_g = (float)pow(10.0, LE_MDLY_DUB_LOOP_DB / 20.0);
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
  int mode = (int)(p[3] * 13.0f + 0.5f);
  mode = mode < 0 ? 0 : mode > 13 ? 13 : mode;
  /* DIGI, DAMPED, RESO LO, RESO HI, then the Drum's and the Dub's own */
  const int voice = mode < 12 ? mode / 3 : mode - 8;
  /* plain, L/R, GRV, or the Dub's L/R Ratio */
  const int timing = mode < 12 ? mode % 3 : mode == 13 ? 3 : 0;
  const int own = voice >= 4;
  /* The Drum's and Dub's settings glide (LE_FX_SMOOTH_S), their filters
   * redesigned every LE_FX_UPDATE_FRAMES frames while they move; a new
   * voicing or rate lands on them at once. */
  const int fresh = line->sr != rate || line->mode != voice;
  int moved = 0;
  if (own && !fresh && --line->tick <= 0) {
    line->tick = LE_FX_UPDATE_FRAMES;
    for (int k = 0; k < 5; ++k) {
      const float to = le_mdly_clamp01(p[4 + k]);
      if (line->cur[k] != to) {
        le_fx_step_toward(&line->cur[k], to, line->k);
        moved = 1;
      }
    }
  }
  if (fresh || moved) {
    if (fresh) line->ramp = 0; /* a new voicing or rate lands at once */
    if (line->sr != rate) {
      line->k = le_fx_smooth_k(rate);
      line->nph = le_rs_phases(rate);
      line->ph = 0;
      le_mdly_bq* sec[9] = {&line->voice[0],  &line->voice[1],  &line->voice2[0],
                            &line->voice2[1], &line->out_hp[0], &line->out_hp[1],
                            &line->lp_out[0], &line->lp_out[1], &line->lp_loop};
      for (int i = 0; i < 9; ++i) {
        memset(sec[i]->z1, 0, sizeof(sec[i]->z1));
        memset(sec[i]->z2, 0, sizeof(sec[i]->z2));
      }
      line->glide = (float)(1.0 / (LE_MDLY_GLIDE_S * (double)rate));
      line->xf_n = (int32_t)(LE_MDLY_XFADE_S * (double)rate);
      le_mdly_bq_rbj(&line->lp_loop, 3, LE_MDLY_LOOP_LP_HZ, 0.707, 0.0, rate);
      le_mdly_pole_set(&line->dc, LE_MDLY_DC_HZ, rate, 1);
      for (int c = 0; c < 2; ++c) {
        le_mdly_pole_set(&line->hp[c], LE_MDLY_HP_HZ, rate, 1);
        le_mdly_bq_rbj(&line->lp_out[c], 3, LE_MDLY_OUT_LP_HZ, 0.707, 0.0, rate);
      }
    }
    if (own) {
      le_mdly_bq* swept[4] = {&line->voice[0], &line->voice[1],
                              &line->voice2[0], &line->voice2[1]};
      le_mdly_bq was[4];
      for (int j = 0; j < 4; ++j) was[j] = *swept[j];
      if (fresh) {
        for (int k = 0; k < 5; ++k) line->cur[k] = le_mdly_clamp01(p[4 + k]);
        line->tick = LE_FX_UPDATE_FRAMES;
      }
      le_mdly_own_voice_set(line, voice, line->cur, rate, fresh);
      /* A glide step ramps the coefficients there over the frames to the
       * next one, so the filters never jump. */
      if (!fresh) {
        line->ramp = LE_FX_UPDATE_FRAMES;
        const float per = 1.0f / (float)LE_FX_UPDATE_FRAMES;
        for (int j = 0; j < 4; ++j) {
          const le_mdly_bq* to = swept[j];
          le_mdly_bq* f = &was[j];
          line->ramp_d[j][0] = (to->b0 - f->b0) * per;
          line->ramp_d[j][1] = (to->b1 - f->b1) * per;
          line->ramp_d[j][2] = (to->b2 - f->b2) * per;
          line->ramp_d[j][3] = (to->a1 - f->a1) * per;
          line->ramp_d[j][4] = (to->a2 - f->a2) * per;
          line->ramp_to[j] = *to;
          *swept[j] = *f;
        }
      }
    } else {
      for (int c = 0; c < 2; ++c) {
        le_mdly_voice_set(&line->voice[c], voice, rate);
        le_mdly_bq_rbj(&line->voice2[c], 5, 0.0, 1.0, 0.0, rate);
        le_mdly_bq_rbj(&line->out_hp[c], 5, 0.0, 1.0, 0.0, rate);
      }
      line->out_g = 1.0f;
      line->loop_g = (float)pow(10.0, LE_MDLY_VOICE[voice].loop_db / 20.0);
    }
    line->sr = rate;
    line->mode = voice;
  }
  if (line->ramp > 0) {
    le_mdly_bq* swept[4] = {&line->voice[0], &line->voice[1],
                            &line->voice2[0], &line->voice2[1]};
    for (int j = 0; j < 4; ++j) {
      swept[j]->b0 += line->ramp_d[j][0];
      swept[j]->b1 += line->ramp_d[j][1];
      swept[j]->b2 += line->ramp_d[j][2];
      swept[j]->a1 += line->ramp_d[j][3];
      swept[j]->a2 += line->ramp_d[j][4];
      if (line->ramp == 1) { /* land on the design itself */
        swept[j]->b0 = line->ramp_to[j].b0;
        swept[j]->b1 = line->ramp_to[j].b1;
        swept[j]->b2 = line->ramp_to[j].b2;
        swept[j]->a1 = line->ramp_to[j].a1;
        swept[j]->a2 = line->ramp_to[j].a2;
      }
    }
    --line->ramp;
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
    if (qpf != line->want_qpf || div != line->want_div) {
      const double frames = LE_MDLY_QUARTERS[div] / (double)qpf;
      const double most = (double)(line->cap - 2);
      line->want_frames =
          (int32_t)(frames < 1.0 ? 1.0 : frames > most ? most : frames + 0.5);
      line->want_qpf = qpf;
      line->want_div = div;
    }
    want = line->want_frames;
  }
  if (!line->primed) {
    line->primed = 1;
    line->fb = fb_to;
    line->mix = mix_to;
    line->tap = want > 0 ? want : 1;
  }
  /* The early tap: L/R half the time, GRV 251/300 of it, the Dub's
   * 1 - Ratio / 2. */
  const double early = timing == 1   ? 0.5
                       : timing == 2 ? LE_MDLY_GRV
                                     : 1.0 - 0.5 * (double)le_mdly_clamp01(p[6]);
  const int32_t want_e = (int32_t)(want * early + 0.5);
  /* It starts clean, at its place, when it comes into use. */
  if (timing != 0 && line->timing == 0) {
    memset(line->voice[1].z1, 0, sizeof(line->voice[1].z1));
    memset(line->voice[1].z2, 0, sizeof(line->voice[1].z2));
    memset(line->voice2[1].z1, 0, sizeof(line->voice2[1].z1));
    memset(line->voice2[1].z2, 0, sizeof(line->voice2[1].z2));
    line->etap = line->etap_old = (int32_t)(line->tap * early + 0.5);
  }
  line->timing = timing;
  const float glide = line->glide;
  line->fb += (fb_to - line->fb) * glide;
  line->mix += (mix_to - line->mix) * glide;
  const int32_t xf_n = line->xf_n;
  if (line->xf == 0 &&
      (want != line->tap || (timing != 0 && want_e != line->etap))) {
    line->tap_old = line->tap;
    line->tap = want;
    line->etap_old = line->etap;
    line->etap = want_e;
    line->xf = xf_n;
  }

  /* The taps, on time and early, crossfading from the old times to the
   * new (a new Time, or a new Ratio). */
  const float t_new = line->xf > 0 ? 1.0f - (float)line->xf / (float)xf_n : 1.0f;
  const int ph = line->ph;
  if (++line->ph >= line->nph) line->ph = 0;
  float tp = le_mdly_read(line, line->tap);
  float te = 0.0f;
  if (timing != 0) te = le_mdly_read(line, line->etap);
  if (line->xf > 0) {
    tp = t_new * tp + (1.0f - t_new) * le_mdly_read(line, line->tap_old);
    if (timing != 0) {
      te = t_new * te + (1.0f - t_new) * le_mdly_read(line, line->etap_old);
    }
    --line->xf;
  }
  const float vp = le_mdly_limit(
      le_mdly_bq_run(&line->voice2[0], le_mdly_bq_run(&line->voice[0], tp, ph), ph),
      LE_MDLY_ECHO_KNEE, LE_MDLY_ECHO_CEIL);
  const float ve =
      timing != 0
          ? le_mdly_limit(le_mdly_bq_run(&line->voice2[1],
                                         le_mdly_bq_run(&line->voice[1], te, ph),
                                         ph),
                          LE_MDLY_ECHO_KNEE, LE_MDLY_ECHO_CEIL)
          : 0.0f;

  /* The loop: the on-time echo, voiced and limited, fed back at Feedback
   * through a DC blocker far under the band (5 Hz: 0.04 dB at 50 Hz), and
   * limited again; the input goes in as it is. */
  const float back = le_mdly_limit(
      line->fb * line->loop_g *
          le_mdly_bq_run(&line->lp_loop, le_mdly_pole_hp(&line->dc, vp), ph),
      LE_MDLY_FB_KNEE, LE_MDLY_FB_CEIL);
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
  } else if (timing == 2) { /* GRV: each side carries 0.143 of the other */
    wl = (0.753f + 0.129f * fb) * (vp + 0.143f * ve);
    wr = 0.881f * (ve + 0.143f * vp);
  } else { /* the Dub's L/R Ratio, its side gains gliding */
    const float ra = line->cur[2];
    const int i = ra <= 0.5f ? 0 : 1;
    const float t = (ra - LE_MDLY_DUB_SIDES[i][0]) * 2.0f;
    const float gl = LE_MDLY_DUB_SIDES[i][1] +
                     t * (LE_MDLY_DUB_SIDES[i + 1][1] - LE_MDLY_DUB_SIDES[i][1]);
    const float gr = LE_MDLY_DUB_SIDES[i][2] +
                     t * (LE_MDLY_DUB_SIDES[i + 1][2] - LE_MDLY_DUB_SIDES[i][2]);
    wl = gl * (vp + LE_MDLY_DUB_CROSS * ve);
    wr = gr * (ve + LE_MDLY_DUB_CROSS * vp);
  }
  if (own) {
    wl = line->out_g * le_mdly_bq_run(&line->out_hp[0], wl, ph);
    wr = line->out_g * le_mdly_bq_run(&line->out_hp[1], wr, ph);
  }
  wl = le_mdly_bq_run(&line->lp_out[0], le_mdly_pole_hp(&line->hp[0], wl), ph);
  wr = le_mdly_bq_run(&line->lp_out[1], le_mdly_pole_hp(&line->hp[1], wr), ph);
  const float m = line->mix;
  const float wet = m <= 0.5f ? 4.0f * m * m : 1.0f;
  const float dry = m <= 0.5f ? 1.0f : 1.0f - (2.0f * m - 1.0f) * (2.0f * m - 1.0f);
  *l = *l * dry + wl * wet;
  *r = *r * dry + wr * wet;
}

/* Octaver's added latency, adapted to the vtable's (fx, slot) signature. */
static int fx_octaver_latency_vt(const le_fx_state* fx, int slot,
                                 int32_t type, int sr) {
  (void)type;
  if (sr == LE_OCT_RATE || sr <= 0) return LE_PV_LATENCY;
  /* Away from 48 kHz, the resampled kernel's (fx_octaver_run); none for a
   * slot not prepared at this rate, which passes its input. */
  const le_oct_rs* t = fx != NULL ? fx->oct_tab[slot] : NULL;
  return t != NULL && t->sr == sr ? t->latency : 0;
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
  float** owned[14]; /* addresses of the pointers we null on rollback */
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
  /* At another rate, the resamplers to and from the kernel's (#1547). */
  const le_oct_rs* tab = cap != LE_OCT_RATE ? le_oct_rs_get(cap) : NULL;
  if (cap != LE_OCT_RATE && tab == NULL) goto oom;
  for (int chan = 0; chan < 2 && cap != LE_OCT_RATE; ++chan) {
    le_octaver_state* o = &fx->oct[slot][chan];
    if (o->rs_in == NULL) {
      o->rs_in = (float*)le_rt_alloc_prefaulted(LE_OCT_RS_RING * sizeof(float));
      if (o->rs_in == NULL) goto oom;
      owned[n++] = &o->rs_in;
    }
    if (o->rs_out == NULL) {
      o->rs_out = (float*)le_rt_alloc_prefaulted(LE_OCT_RS_RING * sizeof(float));
      if (o->rs_out == NULL) goto oom;
      owned[n++] = &o->rs_out;
    }
  }
  /* Written only when it changes: a slot already running a kind of the
   * family reads it every sample (fx_octaver_run), and a recipe prepares
   * every slot it names again, a kept octaver too (#1522). */
  if (fx->oct_tab[slot] != tab) fx->oct_tab[slot] = tab;
  return LE_OK;
oom:
  for (int i = n - 1; i >= 0; --i) {
    le_rt_free(*owned[i]);
    *owned[i] = NULL;
  }
  return LE_ERR_INVALID;
}

size_t le_fx_octaver_bytes(int sr) {
  size_t floats = (size_t)LE_PV_OUT + 2u * LE_PV_BINS + LE_PV_SCRATCH_ALLOC;
  if (sr != LE_OCT_RATE) floats += 2u * LE_OCT_RS_RING;
  return 2u * floats * sizeof(float);
}

size_t le_fx_low_band_bytes(void) { return 2u * sizeof(le_oct_low); }

/* DUAL OCTAVER: the octaver's buffers, and its low band's (#1467) per
 * channel, at LE_OCT_RATE (the kernel's rate at every engine rate). */
static int32_t fx_dual_octaver_prepare(le_fx_state* fx, int slot, int cap) {
  le_oct_low* made[2] = {NULL, NULL};
  for (int chan = 0; chan < 2; ++chan) {
    if (atomic_load_explicit(&fx->oct[slot][chan].low, memory_order_relaxed) !=
        NULL) {
      continue;
    }
    made[chan] = (le_oct_low*)le_rt_alloc_prefaulted(sizeof(le_oct_low));
    if (made[chan] == NULL) goto oom;
    /* All but the ring, which le_low_init clears. */
    memset(made[chan], 0, offsetof(le_oct_low, ring));
    le_low_init(made[chan]);
  }
  if (fx_octaver_prepare(fx, slot, cap) != LE_OK) goto oom;
  for (int chan = 0; chan < 2; ++chan) {
    if (made[chan] != NULL) {
      atomic_store_explicit(&fx->oct[slot][chan].low, made[chan],
                            memory_order_release);
    }
  }
  return LE_OK;
oom:
  le_rt_free(made[0]);
  le_rt_free(made[1]);
  return LE_ERR_INVALID;
}

/* ---- per-type parameter descriptors (le_fx_param_info) ----
 *
 * One row per parameter, in parameter order. Each states what the kernel above
 * does with the normalized setting: the mapping, the unit it reads in, and the
 * setting a freshly engaged effect starts at (le_fx_defaults reads `def` from
 * here, so the defaults have one home). test_fx_param_descriptors_match_kernels
 * measures the kernels against these rows. */

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
 * (linear, #1731 s19oct: -6.02 dB at 50 %), the mix, and Octave 2's level
 * (linear, s6v: -6.2 dB at 50 %). */
static const le_fx_param_desc LE_FX_DUAL_OCTAVER_PARAMS[] = {
    {"oct_high_mode", LE_FX_UNIT_CHOICE, 2, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
    {"octave_1_vol", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     1.0f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f, 0},
    {"octave_2_vol", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
};
/* The Vocal Tuner's Smart Tune (#1480): the speed 1 to 1000 ms (6, 32, 179
 * and 994 on the Looper X's screen at 25, 50, 75 and 100 %), the scale root
 * C to B, the scale type in LE_ST_SCALES's order, and the reference 420 to
 * 460 Hz (459.9 at 99.6 %). */
static const le_fx_param_desc LE_FX_SMART_TUNE_PARAMS[] = {
    {"speed", LE_FX_UNIT_MS, 0, 1.0f, 1000.0f, LE_FX_CURVE_EXPONENTIAL, 0.5f,
     0},
    {"scale_root", LE_FX_UNIT_CHOICE, 12, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
    {"scale_type", LE_FX_UNIT_CHOICE, 14, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
    {"reference", LE_FX_UNIT_HZ, 0, 420.0f, 460.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
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
    {"slicer_pattern", LE_FX_UNIT_CHOICE, LE_SLICE_PATTERN_N, 0.0f, 1.0f,
     LE_FX_CURVE_LINEAR, 0.0f, 0},
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
    /* DIGI, DIGI L/R, DIGI GRV, DAMPED, DAMPED L/R, DAMPED GRV, RESO LO,
     * RES LO L/R, RES LO GRV, RESO HI, RES HI L/R, RES HI GRV (the seven
     * racks' twelve), then the Drum Rack's and the Dub Rack's own delays */
    {"delay_mode", LE_FX_UNIT_CHOICE, 14, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
    /* the Drum Rack's Del Freq: its bell's centre */
    {"delay_freq", LE_FX_UNIT_HZ, 0, 100.0f, 10000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.25f, 0},
    /* the Dub Rack's Del Damp, Del L/R Ratio, Del Reso and Del Res-Freq */
    {"damp", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.35f, 0},
    {"lr_ratio", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
    {"reso", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.8f, 0},
    {"res_freq", LE_FX_UNIT_HZ, 0, 100.0f, 10000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.35f, 0},
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
#define LE_FX_DYN_SETTLE 8   /* the block was just cleared: land at once */

/* Returns 0 when nothing changed and nothing moves; otherwise LE_FX_DYN_RUN
 * with the other bits saying what changed, and the rate and settings
 * recorded. fx_kind_state runs it on the block's head before every update,
 * so a kind's update is handed the head and these bits. */
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
         (new_rate || new_params || settle ? LE_FX_DYN_CHANGED : 0) |
         (settle ? LE_FX_DYN_SETTLE : 0);
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
#define LE_EQ_CUT_Q 0.70710678118654752

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
  /* Transposed direct form II, per phase: its two memories, each the left
   * and right channel's side by side (one vector, le_d2). */
  le_d2 z[LE_RS_PH][2];
} le_eq_band;

typedef struct le_fx_eq {
  /* Smoothed targets per band: log2 Hz, ln Q, and for a shelf or peak its
   * dB, for a cut its amount (1 on, 0 off), which it glides in and out by
   * so switching one never steps. */
  float hz[LE_EQ_BANDS];
  float db[LE_EQ_BANDS];
  float lnq[LE_EQ_BANDS];
  uint32_t active; /* bands that are not the identity */
  float tgt_hz[LE_EQ_BANDS];
  float tgt_db[LE_EQ_BANDS];
  float tgt_lnq[LE_EQ_BANDS];
  le_eq_band band[LE_EQ_BANDS];
  /* Whether the outer bands are shelves (the Drum layout), as designed and
   * as the settings ask. They change shape only at 0 dB (fx_eq_update). */
  int32_t shelves;
  int32_t tgt_shelves;
  int32_t ph, nph; /* the phase this frame runs, of le_rs_phases */
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
void le_eq_design(int kind, double hz, double db, double q, int sr,
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
 * lookup, no fitting. 48 kHz needs none; 96 kHz runs the 48 kHz design
 * itself on alternate samples (le_eq_band, #1547), which is exact; other
 * rates run the plain design. */
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
  if (shape == LE_EQR_NONE) return NULL;
  if (sr == 44100) return t44[shape];
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
static void le_rate_apply(const le_eq_rate_table* t, double hz, double db,
                          double q, double c[5]) {
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

static void le_eq_rate_correct(int shape, double hz, double db, double q,
                               int sr, double c[5]) {
  le_rate_apply(le_eq_rate_table_for(shape, sr), hz, db, q, c);
}

/* ---- The other kinds' filters at rates other than 48 kHz (#1547) ----
 *
 * The kinds are fitted to the Looper X at 48 kHz too, and their filters
 * are the same bilinear designs as the EQ's bands: at 96 kHz they run
 * brighter near the top of the band than at 48 kHz, at 44.1 kHz darker
 * (the effects matrix's response check). le_rate_design gives a kind's
 * section at the running rate corrected to its 48 kHz response, as the
 * EQ's bands are: the bells and high shelves through the EQ's own tables
 * (an RBJ peak is a bell at a wider Q), the cuts at any Q and the
 * one-poles through tool/rate_fit.py's (engine_fx_rate.inc). The low
 * shelves need none (their corners sit low). That is at 44.1 kHz; 96 kHz
 * runs the 48 kHz designs on alternate samples (le_rs_phases), which is
 * exact, where a corrected biquad comes only within a dB or two of a
 * one-pole's 48 kHz response. At 48 kHz, and at other rates, it is the
 * plain design. */
#include "engine_fx_rate.inc"


static const le_eq_rate_table* le_rf_table(int kind, int sr) {
  if (sr == 44100) {
    switch (kind) {
      case LE_EQ_LOWCUT: return &LE_RF_HPQ_44100;
      case LE_EQ_HIGHCUT: return &LE_RF_LPQ_44100;
      case LE_RS_LP1: return &LE_RF_LP1_44100;
      case LE_RS_HP1: return &LE_RF_HP1_44100;
      default: return NULL;
    }
  }
  return NULL;
}

/* Whether [v] lies on an axis of [n] points from [v0] in steps of [dv] (a
 * one-point axis takes anything). */
static int le_rate_on_axis(double v, double v0, double dv, int32_t n) {
  if (n < 2) return 1;
  const double tol = 1e-6 * fabs(dv);
  return v >= v0 - tol && v <= v0 + (double)(n - 1) * dv + tol;
}

/* le_rate_apply where table [t] covers the settings; elsewhere [c] stays
 * the plain design, rather than taking the correction fitted for the
 * grid's edge (a +23 dB bell corrected as an 18 dB one). */
static void le_rate_apply_on_grid(const le_eq_rate_table* t, double hz,
                                  double db, double q, double c[5]) {
  if (t == NULL || !le_rate_on_axis(log(hz), t->f0, t->df, t->nf) ||
      !le_rate_on_axis(log(q), t->q0, t->dq, t->nq) ||
      !le_rate_on_axis(db, t->g0, t->dg, t->ng)) {
    return;
  }
  le_rate_apply(t, hz, db, q, c);
}

/* [kind]'s section (an LE_EQ_* design, or LE_RS_LP1 / LE_RS_HP1 at [hz])
 * at [sr], with the response it has at 48 kHz: at 96 kHz the 48 kHz
 * design, which the kind runs on alternate samples (le_rs_phases). */
static void le_rate_design(int kind, double hz, double db, double q, int sr,
                           double c[5]) {
  sr = le_rs_design_rate(sr);
  if (kind == LE_RS_LP1 || kind == LE_RS_HP1) {
    const double k = le_prewarp(hz, sr);
    const double b0 = kind == LE_RS_HP1 ? 1.0 / (1.0 + k) : k / (1.0 + k);
    c[0] = b0;
    c[1] = kind == LE_RS_HP1 ? -b0 : b0;
    c[2] = 0.0;
    c[3] = (k - 1.0) / (k + 1.0);
    c[4] = 0.0;
    le_rate_apply_on_grid(le_rf_table(kind, sr), hz, 0.0, LE_EQ_CUT_Q, c);
    return;
  }
  const le_eq_rate_table* bells = le_eq_rate_table_for(LE_EQR_BELL, sr);
  if (bells != NULL && (kind == LE_EQ_LOMID || kind == LE_EQ_HIMID)) {
    /* The RBJ peak at 48 kHz is the bell at Q q 10^(|db| / 40) /
     * cos(w0 / 2) there (le_eq_bell): that bell, corrected. */
    const double qb = q * pow(10.0, fabs(db) / 40.0) /
                      cos(3.14159265358979323846 * (hz < 23520.0 ? hz : 23520.0) /
                          48000.0);
    if (le_rate_on_axis(log(hz), bells->f0, bells->df, bells->nf) &&
        le_rate_on_axis(log(qb), bells->q0, bells->dq, bells->nq) &&
        le_rate_on_axis(db, bells->g0, bells->dg, bells->ng)) {
      le_eq_bell(hz, db, qb, sr, c);
      le_rate_apply(bells, hz, db, qb, c);
      return;
    }
  }
  le_eq_design(kind, hz, db, q, sr, c);
  if (kind == LE_EQ_HIGH) {
    le_rate_apply_on_grid(le_eq_rate_table_for(LE_EQR_HS, sr), hz, db, q, c);
  } else {
    le_rate_apply_on_grid(le_rf_table(kind, sr), hz, db, q, c);
  }
}

/* Exposed for the native tests: [kind]'s section as le_rate_design gives
 * it, and the ladder's correction. */
void le_rate_design_for_test(int kind, double hz, double db, double q, int sr,
                             double c[5]);
void le_ladder_correction_for_test(double hz, double k, int sr, double c[5]);

/* The LPF kind's ladder (fx_lpf_*) at [sr], corner [hz] and feedback [k]:
 * the correction biquad that runs after it, so the two have the ladder's
 * 48 kHz response; the identity at 48 kHz, and at 96 kHz, where the ladder
 * runs at 48 kHz (le_lpf_halved).
 * An oscillating ladder takes the correction of the edge, k = 3.99. */
static void le_ladder_correction(double hz, double k, int sr, double c[5]) {
  c[0] = 1.0;
  c[1] = c[2] = c[3] = c[4] = 0.0;
  const le_eq_rate_table* t = sr == 44100 ? &LE_RF_LADDER_44100 : NULL;
  le_rate_apply(t, hz, 0.0, k < 3.99 ? (k > 0.2 ? k : 0.2) : 3.99, c);
}

void le_rate_design_for_test(int kind, double hz, double db, double q, int sr,
                             double c[5]) {
  le_rate_design(kind, hz, db, q, sr, c);
}

void le_ladder_correction_for_test(double hz, double k, int sr, double c[5]) {
  le_ladder_correction(hz, k, sr, c);
}

/* The EQ kind's design of band [b] (LE_EQB_*): the cuts, the outer bands as
 * shelves or bells, and the mid bells, each corrected to its 48 kHz
 * response at the running rate where a table has it. */
static void le_eq_band_design(int b, int shelves, double hz, double db,
                              double q, int sr, double c[5]) {
  sr = le_rs_design_rate(sr); /* 96 kHz runs the 48 kHz design (le_eq_band) */
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

static void fx_eq_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                         int f) {
  le_fx_eq* q = (le_fx_eq*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int new_rate = (f & LE_FX_DYN_NEW_RATE) != 0; /* every design moves */
  if (new_rate) {
    q->nph = le_rs_phases(sr);
    q->ph = 0;
    for (int b = 0; b < LE_EQ_BANDS; ++b) memset(q->band[b].z, 0, sizeof(q->band[b].z));
  }
  /* The targets change only with the settings; a glide reuses them. */
  if (f & LE_FX_DYN_CHANGED) {
    le_eq_targets(p, q->tgt_hz, q->tgt_db, q->tgt_lnq, &q->tgt_shelves);
  }
  const float k = settle ? 1.0f : h->k;
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
  h->moving = moving;
}

static void fx_eq_kprocess(void* ks, float* l, float* r) {
  le_fx_eq* q = (le_fx_eq*)ks;
  /* A non-finite sample would latch into the band memory for good. Both
   * channels run as one vector, each lane as on its own. */
  le_d2 x = {isfinite(*l) ? *l : 0.0, isfinite(*r) ? *r : 0.0};
  const int ph = q->ph;
  for (int b = 0; b < LE_EQ_BANDS; ++b) {
    if (!(q->active & (1u << b))) continue;
    le_eq_band* f = &q->band[b];
    le_d2* z = f->z[ph];
    const le_d2 in = x;
    const le_d2 y = le_d2_set1(f->b0) * in + z[0];
    le_d2 ay1 = le_d2_set1(f->a1) * y;
    le_d2 ay2 = le_d2_set1(f->a2) * y;
    LE_ROUNDED(ay1);
    LE_ROUNDED(ay2);
    z[0] = le_d2_set1(f->b1) * in - ay1 + z[1];
    z[1] = le_d2_set1(f->b2) * in - ay2;
    x = f->mix >= 1.0f ? y : in + le_d2_set1(f->mix) * (y - in);
  }
  if (++q->ph >= q->nph) q->ph = 0;
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
/* The release and detector rows are segno's (#1644). Each starts at the
 * Looper X's measured gate (a 3.2 ms close, keyed on each sample's peak), so
 * a rack that sets only the first two rows, or leaves the rest at 0, plays
 * as the Looper X's. */
static const le_fx_param_desc LE_FX_HP_GATE_PARAMS[] = {
    {"highpass", LE_FX_UNIT_HZ, 0, 0.5f, 500.0f, LE_FX_CURVE_EXPONENTIAL, 0.0f,
     LE_FX_PARAM_OFF_AT_MIN},
    {"gate_threshold", LE_FX_UNIT_DB, 0, -120.0f, 0.0f, LE_FX_CURVE_LINEAR, 0.0f,
     0},
    {"gate_release", LE_FX_UNIT_MS, 0, 3.2f, 2000.0f, LE_FX_CURVE_EXPONENTIAL,
     0.0f, 0},
    {"gate_detector", LE_FX_UNIT_MS, 0, 0.5f, 100.0f, LE_FX_CURVE_EXPONENTIAL,
     0.0f, LE_FX_PARAM_OFF_AT_MIN},
};

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

static void fx_comp_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                           int f) {
  le_fx_comp* c = (le_fx_comp*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
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
  const float k = settle ? 1.0f : h->k;
  int moving = le_fx_glide_step(&c->thr, (float)le_fx_desc_value(&d[0], p[0]), k);
  moving |= le_fx_glide_step(
      &c->slope, (float)(1.0 - 1.0 / le_fx_desc_value(&d[1], p[1])), k);
  moving |= le_fx_glide_step(&c->mk, (float)le_fx_desc_value(&d[4], p[4]), k);
  h->moving = moving;
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
 * 1.6 dB within each cycle at 40 Hz, 0.9 dB at 80 Hz and 0.5 dB at 160 Hz
 * (the captures held only a 1 kHz tone). Gains in the
 * linear domain saturate, as the Looper X's do: at 100 % an onset rises by
 * at most 1 + LE_TR_ATK_K (+15.2 dB) whatever its size, and after a 30 dB
 * drop the sustain lift peaks near +19 dB about 290 ms in (measured:
 * +18.3 dB at 286 ms). LE_TR_FLOOR keeps a decay into silence from reading
 * as an endless drop. Against the 16 measured passes the crest gains match
 * to 0.4 dB RMS or better on the onsets and under 1 dB on the decays.
 *
 * The peak envelope ripples once a cycle, and on samples alone (#1547)
 * both the height of each rise and the gain's step at it depend on where
 * the samples fall on the cycle: a pattern that beats with the rate,
 * which is aliasing (-47 dB on a 1319 Hz note at 48 kHz). So the level
 * feeding the envelope is the true peak between samples, the vertex of
 * the parabola through the three around a strict local maximum, held to
 * a sine's (le_tr_true_peak), and the gain is smoothed over LE_TR_GAIN_S,
 * too short to move a measured crest gain.
 * Folds then stay under -69 dB at every factory setting up to E6, at 44.1,
 * 48 and 96 kHz. */
#define LE_TR_PEAK_REL_S 0.090
#define LE_TR_ATK_MIN_S 0.00312 /* the attack follower at 0 % length */
#define LE_TR_ATK_SPAN 7.12     /* ... and this many times that at 100 % */
#define LE_TR_ATK_K 4.72f
#define LE_TR_SUS_RISE_S 0.095
#define LE_TR_SUS_FALL_S 0.080
#define LE_TR_SUS_LIFT_S 0.038
#define LE_TR_SUS_K 13.4f
#define LE_TR_FLOOR 1e-5f
#define LE_TR_GAIN_S 0.0001 /* the gain's smoothing */
/* The most the true peak may read above its sample: a sine's, up to
 * 2.1 kHz at 48 kHz. A sharp click's parabola would read up to 12.5 %
 * high, which is no sine's peak. */
#define LE_TR_PEAK_LIFT 0.01f

typedef struct le_fx_transient {
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
  float gain_c;   /* the gain's smoothing coefficient */
  float dg;       /* the smoothed gain less 1 (0 when zeroed: unity) */
  float a1;       /* the last two levels, for the true peak */
  float a2;
} le_fx_transient;

static void fx_transient_update(void* ks, le_fx_dyn_head* h, const float* p,
                                int sr, int f) {
  le_fx_transient* t = (le_fx_transient*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int changed = (f & LE_FX_DYN_CHANGED) != 0;
  if (changed) {
    const float len = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
    t->rise = le_one_pole(LE_TR_ATK_MIN_S * pow(LE_TR_ATK_SPAN, len), sr);
  }
  if (f & LE_FX_DYN_NEW_RATE) {
    t->peak_rel = le_one_pole(LE_TR_PEAK_REL_S, sr);
    t->sus_rise = le_one_pole(LE_TR_SUS_RISE_S, sr);
    t->sus_fall = le_one_pole(LE_TR_SUS_FALL_S, sr);
    t->lift = le_one_pole(LE_TR_SUS_LIFT_S, sr);
    t->gain_c = le_one_pole(LE_TR_GAIN_S, sr);
  }
  const float k = settle ? 1.0f : h->k;
  const float a = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float s = p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2];
  int moving = le_fx_glide_step(&t->atk, 2.0f * a - 1.0f, k);
  moving |= le_fx_glide_step(&t->sus, 2.0f * s - 1.0f, k);
  h->moving = moving;
}

/* The level's peak between the samples, read on the sample after a strict
 * local maximum [a1] (between [a2] before it and [a0] after): the vertex of
 * the parabola through the three, at most LE_TR_PEAK_LIFT above [a1].
 * Anything else, a flat top or a step included, is its own sample [a0]. */
static inline float le_tr_true_peak(float a2, float a1, float a0) {
  if (!(a1 > a0 && a1 > a2)) return a0;
  const float d0 = a1 - a0; /* both > 0 */
  const float d2 = a1 - a2;
  const float sum = d0 + d2;
  /* (d2 - d0)^2 / (8 (d0 + d2)), in terms that cannot overflow */
  const float q = sum < INFINITY ? (d2 - d0) / sum : 0.0f;
  const float v = fminf(a1 + 0.125f * (d2 - d0) * q, a1 * (1.0f + LE_TR_PEAK_LIFT));
  return v > a0 ? v : a0;
}

static void fx_transient_kprocess(void* ks, float* l, float* r) {
  le_fx_transient* t = (le_fx_transient*)ks;
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  const float atk = le_fx_glide_next(&t->atk);
  const float sus = le_fx_glide_next(&t->sus);
  const float level = fmaxf(fabsf(x0), fabsf(x1));
  const float x = le_tr_true_peak(t->a2, t->a1, level);
  t->a2 = t->a1;
  t->a1 = level;
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
    t->dg = 0.0f;
    *l = x0;
    *r = x1;
    return; /* neutral: the identity */
  }
  const float ra = (pk - t->riser) / (pk + LE_TR_FLOOR);
  const float ga = 1.0f + fabsf(atk) * LE_TR_ATK_K * ra;
  const float gs = 1.0f + fabsf(sus) * t->sus_gain;
  const float g = (atk >= 0.0f ? ga : 1.0f / ga) * (sus >= 0.0f ? gs : 1.0f / gs);
  const float dg = g - 1.0f;
  t->dg = dg + t->gain_c * (t->dg - dg);
  const float gain = 1.0f + t->dg;
  *l = x0 * gain;
  *r = x1 * gain;
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
 * gain; the close is the Looper X's 2.7 dB/ms fall (a 3.2 ms time constant),
 * or the release row's.
 *
 * With the detector row on (#1644), the gate closes on the level averaged
 * over that time constant (the louder channel's mean square), so a steady
 * floor reads as its RMS rather than its highest peaks and a fading note
 * closes it as it reaches the floor. It opens on that average reaching the
 * threshold, or on a single peak LE_GATE_PEAK_DB over it, which no noise
 * floor that closes it reaches (white noise's peaks stand about 13 dB over
 * its RMS within a hold) and the first crest of a note does: the attack is
 * not lost while the average catches up. Such a gate starts shut. */
#define LE_HPG_DAMP 1.5f /* 1 / Q */
#define LE_GATE_HYST_DB 6.0
#define LE_GATE_HOLD_S 0.250
#define LE_GATE_OPEN_S 0.00005
#define LE_GATE_PEAK_DB 10.0 /* the detector on: a peak opens this far over */

typedef struct le_fx_hp_gate {
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
  int32_t rms;  /* close on the mean square (the detector row on) */
  float env_c;  /* its smoothing coefficient */
  float env;    /* the mean square now */
  float peak_at; /* the detector on: the peak that opens at once */
  float rel_p, det_p; /* the release and detector rows the coefficients are for */
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

static void fx_hp_gate_update(void* ks, le_fx_dyn_head* h, const float* p,
                              int sr, int f) {
  le_fx_hp_gate* q = (le_fx_hp_gate*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int new_rate = (f & LE_FX_DYN_NEW_RATE) != 0;
  const le_fx_param_desc* d = LE_FX_HP_GATE_PARAMS;
  if (new_rate) {
    q->open_c = le_one_pole(LE_GATE_OPEN_S, sr);
    q->hold_n = (int32_t)(LE_GATE_HOLD_S * (double)(sr > 0 ? sr : 48000));
  }
  if (new_rate || settle || p[2] != q->rel_p) {
    q->rel_p = p[2];
    q->close_c = le_one_pole(le_fx_desc_value(&d[2], p[2]) * 1e-3, sr);
  }
  if (new_rate || settle || p[3] != q->det_p) {
    q->det_p = p[3];
    q->rms = p[3] > 0.0f;
    if (q->rms) q->env_c = le_one_pole(le_fx_desc_value(&d[3], p[3]) * 1e-3, sr);
    q->env = 0.0f;
  }
  if (f & LE_FX_DYN_CHANGED) {
    q->tgt_lhz = (float)log2(le_fx_desc_value(&d[0], p[0]));
    q->tgt_wet = p[0] > 0.0f ? 1.0f : 0.0f;
    const double thr = le_fx_desc_value(&d[1], p[1]);
    q->open_at = le_gain_of_db((float)thr);
    q->close_at = le_gain_of_db((float)(thr - LE_GATE_HYST_DB));
    q->peak_at = le_gain_of_db((float)(thr + LE_GATE_PEAK_DB));
    if (q->rms) { /* compared as mean squares */
      q->open_at *= q->open_at;
      q->close_at *= q->close_at;
    }
  }
  /* The corner glides in octaves; the filter is redesigned while it moves
   * (a state-variable filter takes a coefficient change without a click). */
  if (settle) {
    /* A fresh peak gate starts open, so it never cuts into the first sound
     * it is handed; with nothing to hold it open it closes after the hold.
     * One that opens on a peak or the average starts shut: it opens on the
     * first crest anyway, and starting open would let the floor through
     * for the hold and the release. */
    q->open = !q->rms;
    q->gain = q->open ? 1.0f : 0.0f;
    q->hold = q->open ? q->hold_n : 0;
  }
  if (q->lhz != q->tgt_lhz || new_rate) {
    le_fx_step_toward(&q->lhz, q->tgt_lhz, settle ? 1.0f : h->k);
    le_hpg_design(q, sr);
  }
  le_fx_step_toward(&q->wet, q->tgt_wet, settle ? 1.0f : h->k);
  if (q->wet == 0.0f) { /* off: the filter starts clean when it comes back */
    q->lp[0] = q->lp[1] = 0.0f;
    q->bp[0] = q->bp[1] = 0.0f;
  }
  h->moving = q->lhz != q->tgt_lhz || q->wet != q->tgt_wet;
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
  float x = fmaxf(fabsf(y[0]), fabsf(y[1]));
  const int crest = q->rms && x >= q->peak_at;
  if (q->rms) {
    q->env = x * x + q->env_c * (q->env - x * x);
    x = q->env;
  }
  /* Open at the threshold; the hold restarts whenever the level is back
   * within the hysteresis, so the gate closes only once it has stayed under
   * close_at for the whole hold. */
  if (crest || x >= q->open_at) {
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
    {"rate", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.45f, 0},
    {"depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.21f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
};
/* The Mod's controls, each measured at 0, 25, 50, 75 and 100 % (#1470).
 * Its modes: CHORUS, PHASER, FLANGER (the Guitar Rack's) and Tremolo (the
 * Studio Rack's). */
static const le_fx_param_desc LE_FX_MOD_PARAMS[] = {
    {"rate", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"depth", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"mod_mode", LE_FX_UNIT_CHOICE, 4, 0.0f, 1.0f, LE_FX_CURVE_LINEAR, 0.0f, 0},
};
static const le_fx_param_desc LE_FX_WAH_PARAMS[] = {
    {"pedal", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.619f,
     0},
};

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

/* le_ring_read on the frames of one phase of [nph] (le_rs_phases): [delay]
 * frames back, read between the frames nph apart, as the 48 kHz kernel
 * reads its own at 96 kHz. At least nph back, so it reads only what
 * earlier frames wrote. */
static inline float le_ring_read_ph(const float* ring, uint32_t mask,
                                    uint32_t w, float delay, int nph) {
  if (nph <= 1) return le_ring_read(ring, mask, w, delay);
  float d = delay / (float)nph;
  if (d < 1.0f) d = 1.0f;
  const float whole = floorf(d);
  const float fr = d - whole;
  const uint32_t near = (w - (uint32_t)nph * (uint32_t)whole) & mask;
  const float a = ring[near];
  const float b = ring[(near - (uint32_t)nph) & mask];
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
/* The clock LFO phase the chain handed the kind this sample (lfo_hz). */
static float le_fx_kind_lfo(const void* ks);

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
 *   which a slot allocates the first time it holds a doubler and the audio
 *   thread clears when a slot turns into one.
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

static void fx_doubler_update(void* ks, le_fx_dyn_head* h, const float* p,
                              int sr, int f) {
  le_fx_doubler* d = (le_fx_doubler*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
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
  h->moving = 0;
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
 * the Guitar Rack's chorus (#891: s3/4 and s3/5 on plucks and chords, and
 * s6trem and s6mod with each control at 0, 25, 50, 75 and 100 %,
 * docs/plan/2026-10-25-looperx-mod-measured.md):
 * - the voice's delay is a triangle from LE_CHO_BASE_MS (1.767 ms measured
 *   at 0 % depth, held to whole samples at the common rates) up, its swing
 *   LE_CHO_SPAN_MS times the square of Depth (2.45 ms at 50 %, 9.7 ms at
 *   100 %, and the s3 capture's 0.141 ms at 12 %);
 * - the rate is a line, 0.40 Hz at 0 % to 3.20 Hz at 100 %;
 * - the voice is low-passed by two 2nd-order sections at 6.7 kHz, Q 0.65,
 *   fitted to s3 (-2.0, -11.2 and -23 dB at 4, 8 and 12 kHz; these give
 *   -1.9, -11.2 and -23.1 at 96 kHz). s6 read -1.8, -10.5 and -21 dB
 *   through the rig's 48 kHz resampling, which this does not follow above
 *   8 kHz;
 * - the dry gain is 1 - 0.29 mix and the voice's 0.83 mix (1.0 and 0,
 *   0.855 and 0.43, 0.71 and 0.82 at 0, 50 and 100 %).
 * Ed's Rack's Chorus is taken to be the same module (#891), and the Mod
 * kind's chorus mode is this voice. Both channels share the LFO. */
#define LE_CHO_RING 4096u /* holds the 11.5 ms of 100 % at 192 kHz */
#define LE_CHO_BASE_MS (85.0 / 48.0) /* 1.771 ms: whole samples at 48, 96 and 192 kHz */
#define LE_CHO_SPAN_MS 9.78
#define LE_CHO_RATE_MIN_HZ 0.4005
#define LE_CHO_RATE_SPAN_HZ 2.799
#define LE_CHO_LP_HZ 6700.0
#define LE_CHO_LP_Q 0.65
#define LE_CHO_DRY_DROP 0.29f
#define LE_CHO_VOICE 0.83f

/* The voice's low-pass at [rate]: RBJ, the design le_eq_design uses for a
 * cut, a0-normalized b0 b1 b2 a1 a2. */
static void le_cho_lowpass(float* lp, double rate) {
  const double w0 = 2.0 * 3.14159265358979323846 *
                    (LE_CHO_LP_HZ < 0.45 * rate ? LE_CHO_LP_HZ : 0.45 * rate) /
                    rate;
  const double cw = cos(w0);
  const double alpha = sin(w0) / (2.0 * LE_CHO_LP_Q);
  const double a0 = 1.0 + alpha;
  lp[0] = (float)((1.0 - cw) / 2.0 / a0);
  lp[1] = (float)((1.0 - cw) / a0);
  lp[2] = lp[0];
  lp[3] = (float)(-2.0 * cw / a0);
  lp[4] = (float)((1.0 - alpha) / a0);
}

typedef struct le_fx_chorus {
  le_fx_glide rate;  /* LFO rate, Hz */
  le_fx_glide swing; /* the delay's swing above the base, samples */
  le_fx_glide dry;
  le_fx_glide wet;
  float base; /* the shortest delay, samples */
  float max_swing; /* what the ring holds past the base */
  float inv_sr;
  double ph;
  float lp[5];       /* the voice low-pass */
  float z[2][2][2];  /* [section][channel][state] */
  uint32_t w;
  float ring[2][LE_CHO_RING];
} le_fx_chorus;

static void fx_chorus_update(void* ks, le_fx_dyn_head* h, const float* p,
                             int sr, int f) {
  le_fx_chorus* c = (le_fx_chorus*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const double rate = (double)(sr > 0 ? sr : 48000);
  if (f & LE_FX_DYN_NEW_RATE) {
    c->base = (float)(LE_CHO_BASE_MS * 1e-3 * rate);
    c->max_swing = (float)(LE_CHO_RING - 2u) - c->base;
    c->inv_sr = (float)(1.0 / rate);
    le_cho_lowpass(c->lp, rate);
  }
  const float k = settle ? 1.0f : h->k;
  const float v[3] = {
      p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0],
      p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1],
      p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2],
  };
  int moving = le_fx_glide_step(
      &c->rate, (float)(LE_CHO_RATE_MIN_HZ + LE_CHO_RATE_SPAN_HZ * v[0]), k);
  float swing = (float)(LE_CHO_SPAN_MS * 1e-3 * rate) * v[1] * v[1];
  if (swing > c->max_swing) swing = c->max_swing;
  moving |= le_fx_glide_step(&c->swing, swing, k);
  moving |= le_fx_glide_step(&c->dry, 1.0f - LE_CHO_DRY_DROP * v[2], k);
  moving |= le_fx_glide_step(&c->wet, LE_CHO_VOICE * v[2], k);
  h->moving = moving;
}

static void fx_chorus_kprocess(void* ks, float* l, float* r) {
  le_fx_chorus* c = (le_fx_chorus*)ks;
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  const double inc = (double)le_fx_glide_next(&c->rate) * (double)c->inv_sr;
  const float swing = le_fx_glide_next(&c->swing);
  const float dry = le_fx_glide_next(&c->dry);
  const float wet = le_fx_glide_next(&c->wet);
  c->ph = le_lfo_step(c->ph, inc);
  const float delay = c->base + swing * 0.5f * (1.0f + le_tri((float)c->ph));
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

/* ---- Modulation (LE_FX_MOD, #887 part 13) ----
 *
 * The Looper X's Mod pedal: the Guitar Rack's CHORUS, PHASER and FLANGER
 * and the Studio Rack's Chorus and Tremolo, one mode at a time. Measured on
 * the #891 rig (s6trem and s6mod, docs/plan/2026-10-25-looperx-mod-measured.md)
 * with each control at 0, 25, 50, 75 and 100 % (and the flanger's depth at
 * 10 and 90 %). Both sides run the same LFO, as the Looper X does (its
 * outputs are identical for a mono input).
 *
 * - CHORUS: the chorus kind's voice (fx_chorus_*, the same measurements).
 *   The Studio Rack's chorus is this one at Mix 50 %.
 * - PHASER: four first-order allpass stages whose corners sit LE_PHA_SPREAD
 *   apart around 654 Hz, mixed with the dry signal (Mix is a measured
 *   table). The LFO, 0.1 x 100^Rate Hz, moves the corners by up to
 *   5.87 x Depth octaves along a sine raised to LE_PHA_SHAPE, which tracks
 *   the swept notches within 0.02 octave. The Looper X's wet signal is
 *   up to 1.2 dB louder between the notches than an allpass; that is not
 *   modelled.
 * - FLANGER: one voice on a triangle delay, its shortest and longest a
 *   measured table against Depth, its rate 0.0166 x 604^Rate Hz; dry
 *   1 - Mix, the voice 0.88 Mix. Each repeat feeds back through a
 *   first-order high-pass and low-pass, so the repeats lose their bass and
 *   treble while the first one keeps its full range.
 * - Tremolo: a square LFO, 0.255 x 51^Rate Hz, on for LE_TRM_DUTY of each
 *   cycle, through a gain that rises with a 13 ms and falls with a 30.5 ms
 *   time constant. Depth sets the gain of the off part (a measured table).
 *   Mix does nothing in this mode.
 *
 * A mode change crossfades over LE_MOD_FADE frames, with both modes
 * running for that time. */
enum { LE_MOD_CHORUS, LE_MOD_PHASER, LE_MOD_FLANGER, LE_MOD_TREMOLO,
       LE_MOD_MODES };
#define LE_MOD_RING LE_CHO_RING
#define LE_FLA_RING 2048u /* the flanger's 6.84 ms at 192 kHz */
_Static_assert(LE_FLA_RING - 2u >= 1313u,
               "the flanger's ring holds 6.836 ms at 192 kHz");
_Static_assert(LE_CHO_RING - 2u >= 2218u,
               "the chorus's ring holds 1.771 + 9.78 ms at 192 kHz");
#define LE_MOD_FADE 1024
#define LE_PHA_SPREAD 1.4263
#define LE_PHA_SHAPE 0.87
#define LE_PHA_CORNER_HZ 654.0
#define LE_PHA_OCTAVES 5.87 /* the sweep at Depth 100 %, octaves */
#define LE_PHA_MEAN 0.467 /* fitted: where on the shaped sine the corner sits */
#define LE_PHA_COEF_FRAMES 16 /* the phaser's corners are recomputed this often */
#define LE_FLA_FB 1.03f
#define LE_FLA_HP_HZ 1560.0
#define LE_FLA_LP_HZ 6150.0
#define LE_FLA_VOICE 0.88f
#define LE_TRM_DUTY 0.58
#define LE_TRM_ATTACK_S 0.013
#define LE_TRM_RELEASE_S 0.0305

/* A first-order allpass (bilinear): its coefficient for corner [hz] at
 * [rate] (the corner held under 0.45 of the rate), and one tick,
 * y = a u + z, z = u - a y. */
static float le_ap1_coef(double hz, double rate) {
  if (hz > 0.45 * rate) hz = 0.45 * rate;
  const double t = tan(3.14159265358979323846 * hz / rate);
  return (float)((t - 1.0) / (t + 1.0));
}

static inline float le_ap1_tick(float a, float* z, float u) {
  const float y = a * u + *z;
  *z = fx_sanitize(u - a * y);
  return y;
}

/* A point of a measured setting table: the setting and up to two values. */
typedef struct le_mod_point {
  float at, a, b;
} le_mod_point;

/* Linear interpolation of a table at setting [v] (0..1). */
static void le_mod_table(const le_mod_point* t, int n, float v, float* a,
                         float* b) {
  int i = 0;
  while (i < n - 2 && v > t[i + 1].at) ++i;
  float f = (v - t[i].at) / (t[i + 1].at - t[i].at);
  f = f < 0.0f ? 0.0f : f > 1.0f ? 1.0f : f;
  *a = t[i].a + f * (t[i + 1].a - t[i].a);
  if (b != NULL) *b = t[i].b + f * (t[i + 1].b - t[i].b);
}

/* The phaser's dry and wet gains against Mix. */
static const le_mod_point LE_PHA_MIX[] = {{0.0f, 1.0f, 0.0f},
                                          {0.25f, 0.963f, 0.470f},
                                          {0.5f, 0.789f, 0.798f},
                                          {0.75f, 0.481f, 0.993f},
                                          {1.0f, 0.043f, 1.048f}};
/* The flanger's shortest and longest delay, ms, against Depth. */
static const le_mod_point LE_FLA_DEPTH[] = {
    {0.0f, 0.805f, 0.805f}, {0.1f, 0.662f, 2.062f}, {0.25f, 0.494f, 3.515f},
    {0.5f, 0.279f, 5.361f}, {0.75f, 0.151f, 6.467f}, {0.9f, 0.116f, 6.775f},
    {1.0f, 0.109f, 6.836f}};
/* The tremolo's gain in its off part against Depth. */
static const le_mod_point LE_TRM_DEPTH[] = {{0.0f, 1.0f, 0},
                                            {0.25f, 0.880f, 0},
                                            {0.5f, 0.564f, 0},
                                            {0.75f, 0.194f, 0},
                                            {1.0f, 0.0f, 0}};
#define LE_MOD_POINTS(t) ((int)(sizeof(t) / sizeof(t[0])))

/* The LFO rate, Hz, mode [m] runs at Rate [v]. */
static double le_mod_rate_hz(int m, double v) {
  switch (m) {
    case LE_MOD_PHASER: return 0.1 * pow(100.0, v);
    case LE_MOD_FLANGER: return 0.01657 * pow(604.0, v);
    case LE_MOD_TREMOLO: return 0.2551 * pow(50.97, v);
    default: return LE_CHO_RATE_MIN_HZ + LE_CHO_RATE_SPAN_HZ * v;
  }
}

static int le_mod_mode(float v) {
  const int m = (int)lrintf((v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v) *
                            (float)(LE_MOD_MODES - 1));
  return m;
}

/* One mode's settings, glided; the mode fading out keeps its own. */
typedef struct le_mod_voice {
  le_fx_glide inc;  /* LFO phase step a sample */
  le_fx_glide dry;
  le_fx_glide wet;
  le_fx_glide a;    /* chorus: swing; phaser: octaves; flanger: shortest;
                     * tremolo: the off gain */
  le_fx_glide b;    /* flanger: longest */
  double ph;
} le_mod_voice;

typedef struct le_fx_mod {
  int32_t mode;
  int32_t from; /* the mode fading out, or -1 */
  int32_t fade; /* frames of the crossfade left */
  float rate;   /* the sample rate */
  float base;   /* the chorus's shortest delay, samples */
  float max_delay;
  le_mod_voice v[LE_MOD_MODES];
  float cho_lp[5];
  float cho_z[2][2][2];
  /* phaser: the stage coefficients now and their per-sample steps */
  float pha_a[4], pha_da[4];
  float pha_z[2][4];
  double pha_spread[4]; /* each stage's corner over the sweep's, set once */
  int32_t pha_left; /* samples until the next corner */
  /* flanger: the repeats' high-pass and low-pass, bilinear one-poles run
   * as biquads (le_rate_design) */
  float fla_hp[5], fla_lp[5];
  float fla_hz[2][LE_RS_PH][2], fla_lz[2][LE_RS_PH][2];
  int32_t ph, nph; /* their phase this frame (le_rs_phases) */
  /* tremolo */
  float trm_g;
  float trm_ka, trm_kr;
  uint32_t w;
  float ring[2][LE_MOD_RING]; /* the chorus's input */
  float fring[2][LE_FLA_RING]; /* the flanger's input and repeats */
} le_fx_mod;

/* The targets mode [m] glides to at settings [p] (each 0..1). */
static int le_mod_targets(le_fx_mod* q, int m, const float* p, float k) {
  le_mod_voice* o = &q->v[m];
  const float rate = p[0], depth = p[1], mix = p[2];
  int moving = le_fx_glide_step(
      &o->inc, (float)(le_mod_rate_hz(m, rate) / (double)q->rate), k);
  float dry = 1.0f, wet = 0.0f, a = 0.0f, b = 0.0f;
  switch (m) {
    case LE_MOD_CHORUS:
      dry = 1.0f - LE_CHO_DRY_DROP * mix;
      wet = LE_CHO_VOICE * mix;
      a = (float)(LE_CHO_SPAN_MS * 1e-3 * q->rate) * depth * depth;
      if (a > q->max_delay - q->base) a = q->max_delay - q->base;
      break;
    case LE_MOD_PHASER:
      le_mod_table(LE_PHA_MIX, LE_MOD_POINTS(LE_PHA_MIX), mix, &dry, &wet);
      a = (float)LE_PHA_OCTAVES * depth;
      break;
    case LE_MOD_FLANGER:
      dry = 1.0f - mix;
      wet = LE_FLA_VOICE * mix;
      le_mod_table(LE_FLA_DEPTH, LE_MOD_POINTS(LE_FLA_DEPTH), depth, &a, &b);
      a *= q->rate * 1e-3f;
      b *= q->rate * 1e-3f;
      if (a < 1.0f) a = 1.0f; /* the voice reads only past samples */
      if (b > (float)(LE_FLA_RING - 2u)) b = (float)(LE_FLA_RING - 2u);
      break;
    default: /* LE_MOD_TREMOLO */
      le_mod_table(LE_TRM_DEPTH, LE_MOD_POINTS(LE_TRM_DEPTH), depth, &a, NULL);
      break;
  }
  moving |= le_fx_glide_step(&o->dry, dry, k);
  moving |= le_fx_glide_step(&o->wet, wet, k);
  moving |= le_fx_glide_step(&o->a, a, k);
  moving |= le_fx_glide_step(&o->b, b, k);
  return moving;
}

/* The phaser's four corners at LFO phase [ph] with a sweep of [span]
 * octaves. */
static void le_mod_phaser_corners(const le_fx_mod* q, double ph, float span,
                                  float* a) {
  const double u = 0.5 * (1.0 + sin(2.0 * 3.14159265358979323846 * ph));
  const double oct = (double)span * (pow(u, LE_PHA_SHAPE) - LE_PHA_MEAN);
  const double c = LE_PHA_CORNER_HZ * exp2(oct);
  for (int s = 0; s < 4; ++s) a[s] = le_ap1_coef(c * q->pha_spread[s], q->rate);
}

/* The phaser's corners land where its settings are now, with no ramp: a
 * fresh block, or the mode a change fades in. */
static void le_mod_phaser_land(le_fx_mod* q) {
  const le_mod_voice* o = &q->v[LE_MOD_PHASER];
  le_mod_phaser_corners(q, o->ph, o->a.v, q->pha_a);
  for (int s = 0; s < 4; ++s) q->pha_da[s] = 0.0f;
  q->pha_left = 0;
}

static void fx_mod_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                          int f) {
  le_fx_mod* q = (le_fx_mod*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  if (f & LE_FX_DYN_NEW_RATE) {
    const double rate = (double)(sr > 0 ? sr : 48000);
    q->rate = (float)rate;
    q->base = (float)(LE_CHO_BASE_MS * 1e-3 * rate);
    q->max_delay = (float)(LE_MOD_RING - 2u);
    le_cho_lowpass(q->cho_lp, rate);
    q->nph = le_rs_phases(rate);
    q->ph = 0;
    memset(q->fla_hz, 0, sizeof(q->fla_hz));
    memset(q->fla_lz, 0, sizeof(q->fla_lz));
    double c[5];
    le_rate_design(LE_RS_HP1, LE_FLA_HP_HZ, 0.0, 0.0, rate, c);
    for (int i = 0; i < 5; ++i) q->fla_hp[i] = (float)c[i];
    le_rate_design(LE_RS_LP1, LE_FLA_LP_HZ, 0.0, 0.0, rate, c);
    for (int i = 0; i < 5; ++i) q->fla_lp[i] = (float)c[i];
    q->trm_ka = (float)(1.0 - exp(-1.0 / (LE_TRM_ATTACK_S * rate)));
    q->trm_kr = (float)(1.0 - exp(-1.0 / (LE_TRM_RELEASE_S * rate)));
    for (int s = 0; s < 4; ++s) {
      q->pha_spread[s] = pow(LE_PHA_SPREAD, (double)s - 1.5);
    }
  }
  const float v[3] = {
      p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0],
      p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1],
      p[2] < 0.0f ? 0.0f : p[2] > 1.0f ? 1.0f : p[2],
  };
  const int m = le_mod_mode(p[3]);
  if (settle) {
    q->mode = m;
    q->from = -1;
    q->fade = 0;
    q->trm_g = 1.0f;
  } else if (m != q->mode && q->fade == 0) {
    /* A change picked during a fade waits for it (h.moving keeps the
     * update running until then). */
    q->from = q->mode;
    q->mode = m;
    q->fade = LE_MOD_FADE;
    le_mod_targets(q, m, v, 1.0f); /* the incoming mode starts set */
    if (m == LE_MOD_PHASER) le_mod_phaser_land(q);
    if (m == LE_MOD_TREMOLO) q->trm_g = 1.0f;
  }
  const float k = settle ? 1.0f : h->k;
  int moving = le_mod_targets(q, q->mode, v, k);
  if (settle) le_mod_phaser_land(q);
  h->moving = moving || q->fade > 0 || m != q->mode;
}

/* The chorus mode on one sample of both sides. */
static void le_mod_chorus(le_fx_mod* q, const float* x, float* y) {
  le_mod_voice* o = &q->v[LE_MOD_CHORUS];
  const double inc = (double)le_fx_glide_next(&o->inc);
  const float swing = le_fx_glide_next(&o->a);
  const float dry = le_fx_glide_next(&o->dry);
  const float wet = le_fx_glide_next(&o->wet);
  le_fx_glide_next(&o->b);
  o->ph = le_lfo_step(o->ph, inc);
  const float delay = q->base + swing * 0.5f * (1.0f + le_tri((float)o->ph));
  for (int ch = 0; ch < 2; ++ch) {
    float v = le_ring_read(q->ring[ch], LE_MOD_RING - 1u, q->w, delay);
    for (int s = 0; s < 2; ++s) v = le_biquad_tick(q->cho_lp, q->cho_z[s][ch], v);
    y[ch] = dry * x[ch] + wet * v;
  }
}

static void le_mod_phaser(le_fx_mod* q, const float* x, float* y) {
  le_mod_voice* o = &q->v[LE_MOD_PHASER];
  const double inc = (double)le_fx_glide_next(&o->inc);
  const float span = le_fx_glide_next(&o->a);
  const float dry = le_fx_glide_next(&o->dry);
  const float wet = le_fx_glide_next(&o->wet);
  le_fx_glide_next(&o->b);
  o->ph = le_lfo_step(o->ph, inc);
  if (q->pha_left <= 0) {
    /* Where the corners land LE_PHA_COEF_FRAMES samples on; the samples
     * between step there in a line. */
    float to[4];
    le_mod_phaser_corners(q, o->ph + inc * (double)LE_PHA_COEF_FRAMES, span,
                          to);
    for (int s = 0; s < 4; ++s) {
      q->pha_da[s] = (to[s] - q->pha_a[s]) * (1.0f / (float)LE_PHA_COEF_FRAMES);
    }
    q->pha_left = LE_PHA_COEF_FRAMES;
  }
  q->pha_left--;
  for (int s = 0; s < 4; ++s) q->pha_a[s] += q->pha_da[s];
  for (int ch = 0; ch < 2; ++ch) {
    float u = x[ch];
    for (int s = 0; s < 4; ++s) u = le_ap1_tick(q->pha_a[s], &q->pha_z[ch][s], u);
    y[ch] = dry * x[ch] + wet * u;
  }
}

static void le_mod_flanger(le_fx_mod* q, const float* x, float* y) {
  le_mod_voice* o = &q->v[LE_MOD_FLANGER];
  const double inc = (double)le_fx_glide_next(&o->inc);
  const float lo = le_fx_glide_next(&o->a);
  const float hi = le_fx_glide_next(&o->b);
  const float dry = le_fx_glide_next(&o->dry);
  const float wet = le_fx_glide_next(&o->wet);
  o->ph = le_lfo_step(o->ph, inc);
  const float delay = lo + (hi - lo) * 0.5f * (1.0f + le_tri((float)o->ph));
  const uint32_t at = q->w & (LE_FLA_RING - 1u);
  for (int ch = 0; ch < 2; ++ch) {
    /* The delay is at least a sample (le_mod_targets), so this reads only
     * what earlier samples wrote. */
    const float v =
        le_ring_read_ph(q->fring[ch], LE_FLA_RING - 1u, q->w, delay, q->nph);
    /* The repeat: high-passed, then low-passed. */
    const float hp = le_biquad_tick(q->fla_hp, q->fla_hz[ch][q->ph], v);
    const float lp = le_biquad_tick(q->fla_lp, q->fla_lz[ch][q->ph], hp);
    q->fring[ch][at] = x[ch] + LE_FLA_FB * lp;
    y[ch] = dry * x[ch] + wet * v;
  }
}

static void le_mod_tremolo(le_fx_mod* q, const float* x, float* y) {
  le_mod_voice* o = &q->v[LE_MOD_TREMOLO];
  const double inc = (double)le_fx_glide_next(&o->inc);
  const float off = le_fx_glide_next(&o->a);
  le_fx_glide_next(&o->b);
  le_fx_glide_next(&o->dry);
  le_fx_glide_next(&o->wet);
  o->ph = le_lfo_step(o->ph, inc);
  const float tgt = o->ph < LE_TRM_DUTY ? 1.0f : off;
  q->trm_g += (tgt > q->trm_g ? q->trm_ka : q->trm_kr) * (tgt - q->trm_g);
  y[0] = q->trm_g * x[0];
  y[1] = q->trm_g * x[1];
}

static void le_mod_run(le_fx_mod* q, int m, const float* x, float* y) {
  switch (m) {
    case LE_MOD_PHASER: le_mod_phaser(q, x, y); return;
    case LE_MOD_FLANGER: le_mod_flanger(q, x, y); return;
    case LE_MOD_TREMOLO: le_mod_tremolo(q, x, y); return;
    default: le_mod_chorus(q, x, y); return;
  }
}

static void fx_mod_kprocess(void* ks, float* l, float* r) {
  le_fx_mod* q = (le_fx_mod*)ks;
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  const uint32_t at = q->w & (LE_MOD_RING - 1u);
  q->ring[0][at] = x[0];
  q->ring[1][at] = x[1];
  float y[2];
  le_mod_run(q, q->mode, x, y);
  if (q->fade > 0) {
    float z[2];
    le_mod_run(q, q->from, x, z);
    const float g = (float)q->fade * (1.0f / (float)LE_MOD_FADE);
    y[0] += g * (z[0] - y[0]);
    y[1] += g * (z[1] - y[1]);
    if (--q->fade == 0) q->from = -1;
  }
  if (q->mode != LE_MOD_FLANGER && q->from != LE_MOD_FLANGER) {
    /* Kept current, so the flanger never starts on old audio. */
    const uint32_t fat = q->w & (LE_FLA_RING - 1u);
    q->fring[0][fat] = x[0];
    q->fring[1][fat] = x[1];
  }
  q->w++;
  if (++q->ph >= q->nph) q->ph = 0;
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

static void fx_wah_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                          int f) {
  le_fx_wah* q = (le_fx_wah*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  if (f & LE_FX_DYN_CHANGED) {
    q->tgt = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  }
  if (q->pos != q->tgt || (f & LE_FX_DYN_NEW_RATE) || settle) {
    le_fx_step_toward(&q->pos, q->tgt, settle ? 1.0f : h->k);
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
  h->moving = q->pos != q->tgt;
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

/* ---- Oversampling the waveshapers (#1547) ----
 *
 * A waveshaper's harmonics above the rate's Nyquist fold back under it as
 * inharmonic tones (#1540). The Overdrive, Distortion, Vinyl and Amp+Cab
 * run their curves at a multiple of the rate: each 2x stage is a polyphase
 * IIR half-band, up before the curve and down after it, cascaded for 4x
 * and 8x. The linear filters around a curve stay at the rate.
 *
 * The half-band is Laurent de Soras's (HIIR): two paths of first-order
 * allpass sections in z^2, H(z) = (A0(z^2) + z^-1 A1(z^2)) / 2, its
 * coefficients from his elliptic design (PolyphaseIir2Designer). Each
 * stage is designed when the rate is set: flat to LE_OS_PASS_HZ (or 0.42
 * of a lower rate), at least LE_OS_ATT_DB down from the image of that
 * edge, with as few coefficients as that takes (6 for the first stage at
 * 44.1 and 48 kHz, 3 or 4 after it). It is minimum phase: the whole path
 * runs about 4 frames late at 48 kHz, where a linear-phase FIR of the same
 * stopband ran 33. Its delay grows toward the top of the band: the 8x path
 * at 44.1 kHz holds 1 kHz 4.5 frames, 10 kHz 5.3 and 15 kHz 7.2 (at
 * 96 kHz, 3.5 to 3.8). The kind reports the low-frequency figure as its
 * latency (le_os_latency).
 *
 * State per channel and stage: each section's last input and output, for
 * the way up and the way down. Nothing is allocated: the arrays are sized
 * for LE_OS_MAX_STAGES stages of LE_OS_MAX_COEFS sections, inside the
 * kind's block. */
#define LE_OS_MAX_STAGES 3 /* up to 8x */
#define LE_OS_MAX_COEFS 8
#define LE_OS_PASS_HZ 20000.0
#define LE_OS_ATT_DB 70.0

typedef struct le_os_path {
  float x[LE_OS_MAX_COEFS], y[LE_OS_MAX_COEFS]; /* per section */
} le_os_path;

typedef struct le_os {
  int32_t sr;     /* the rate the design is for; 0: none yet */
  int32_t stages; /* log2 of the factor */
  int32_t n[LE_OS_MAX_STAGES];                /* coefficients a stage */
  float c[LE_OS_MAX_STAGES][LE_OS_MAX_COEFS]; /* even: A0, odd: A1 */
  le_os_path up[2][LE_OS_MAX_STAGES], down[2][LE_OS_MAX_STAGES];
} le_os;

/* The pass edge at [sr]: LE_OS_PASS_HZ, or 0.42 of a rate too low for it. */
static double le_os_pass_hz(int sr) {
  const double rate = (double)(sr > 0 ? sr : 48000);
  return LE_OS_PASS_HZ > 0.42 * rate ? 0.42 * rate : LE_OS_PASS_HZ;
}

/* Stage [s]'s coefficients at [sr], into [c]; returns how many. De Soras's
 * design: the transition band, as a share of the upper rate, from the pass
 * edge to its image; the elliptic order that holds LE_OS_ATT_DB over it;
 * each coefficient from the elliptic functions' series (summed until their
 * terms are below what a float carries). */
static int le_os_coefs(int sr, int s, float* c) {
  const double pi = 3.14159265358979323846;
  const double rate = (double)(sr > 0 ? sr : 48000);
  const double tbw = 0.25 - le_os_pass_hz(sr) / (2.0 * rate * (double)(1 << s));
  double k = tan((1.0 - 2.0 * tbw) * pi / 4.0);
  k *= k;
  const double kr = pow(1.0 - k * k, 0.25);
  const double e = 0.5 * (1.0 - kr) / (1.0 + kr);
  const double e4 = e * e * e * e;
  const double q = e * (1.0 + e4 * (2.0 + e4 * (15.0 + 150.0 * e4)));
  const double att = pow(10.0, -LE_OS_ATT_DB / 10.0);
  const double a = att / (1.0 - att);
  int order = (int)ceil(log(a * a / 16.0) / log(q));
  if ((order & 1) == 0) ++order;
  if (order < 3) order = 3;
  /* A band too narrow for LE_OS_MAX_COEFS sections is designed at the
   * largest order they hold (less attenuation, but a true half-band), never
   * cut short. */
  if (order > 2 * LE_OS_MAX_COEFS + 1) order = 2 * LE_OS_MAX_COEFS + 1;
  const int n = (order - 1) / 2;
  for (int i = 0; i < n; ++i) {
    const double m = (double)(i + 1);
    double num = 0.0, den = 0.0;
    for (int j = 0; j < 40; ++j) {
      const double t = pow(q, (double)(j * (j + 1))) *
                       sin((2.0 * j + 1.0) * m * pi / order);
      num += (j & 1) ? -t : t;
      if (fabs(t) < 1e-30) break;
    }
    for (int j = 1; j < 40; ++j) {
      const double t = pow(q, (double)(j * j)) * cos(2.0 * j * m * pi / order);
      den += (j & 1) ? -t : t;
      if (fabs(t) < 1e-30) break;
    }
    const double ww = num * pow(q, 0.25) / (den + 0.5);
    const double w2 = ww * ww;
    const double x = sqrt((1.0 - w2 * k) * (1.0 - w2 / k)) / (1.0 + w2);
    c[i] = (float)((1.0 - x) / (1.0 + x));
  }
  return n;
}

/* Designs [o] for 2^[stages] times [sr] and clears its state. Audio thread
 * (a kind's update, on a new rate): a few hundred operations, once. */
static void le_os_design(le_os* o, int sr, int stages) {
  memset(o, 0, sizeof(*o));
  o->sr = sr;
  o->stages = stages;
  for (int s = 0; s < stages; ++s) o->n[s] = le_os_coefs(sr, s, o->c[s]);
}

/* Empties [o]'s state, keeping its design. */
static void le_os_clear(le_os* o) {
  memset(o->up, 0, sizeof(o->up));
  memset(o->down, 0, sizeof(o->down));
}

/* The frames the up and down pair delays a signal at low frequencies,
 * rounded: each stage's half-band delays by the mean of its two paths
 * (a section (c + z^-2) / (1 + c z^-2) by 2 (1 - c) / (1 + c) samples of
 * the upper rate at DC, the odd path one more), once up and once down. */
static int le_os_latency_of(int sr, int stages) {
  double d = 0.0;
  for (int s = 0; s < stages; ++s) {
    float c[LE_OS_MAX_COEFS];
    const int n = le_os_coefs(sr, s, c);
    double t[2] = {0.0, 1.0};
    for (int i = 0; i < n; ++i) t[i & 1] += 2.0 * (1.0 - c[i]) / (1.0 + c[i]);
    /* Up and down, in samples of the upper rate, over 2^(s + 1). */
    d += (t[0] + t[1]) / (double)(1 << s) / 2.0;
  }
  return (int)(d + 0.5);
}

/* le_os_latency_of, kept per rate once worked out: every enabled
 * waveshaper asks on each snapshot, and the audio thread on an enable edge,
 * and the design behind it is a few hundred transcendental operations. Any
 * thread: two that work out the same entry store the same value. */
static const int le_os_rates[6] = {44100, 48000, 88200, 96000, 176400, 192000};
static _Atomic int le_os_lat_memo[6][LE_OS_MAX_STAGES + 1]; /* frames + 1 */

static int le_os_latency(int sr, int stages) {
  if (stages <= 0) return 0;
  for (int i = 0; i < 6; ++i) {
    if (le_os_rates[i] != sr) continue;
    _Atomic int* m = &le_os_lat_memo[i][stages];
    const int got = atomic_load_explicit(m, memory_order_relaxed);
    if (got > 0) return got - 1;
    const int lat = le_os_latency_of(sr, stages);
    atomic_store_explicit(m, lat + 1, memory_order_relaxed);
    return lat;
  }
  return le_os_latency_of(sr, stages);
}

/* [x] through path [p]'s sections (every other coefficient of [c], from
 * [first]), each y = c (x - y') + x' in the path's own rate. */
static inline float le_os_path_run(const float* c, int n, int first,
                                   le_os_path* p, float x) {
  for (int i = first; i < n; i += 2) {
    const float y = c[i] * (x - p->y[i]) + p->x[i];
    p->x[i] = x;
    p->y[i] = y;
    x = y;
  }
  return x;
}

/* [x] on channel [ch] up to 2^stages samples, in time order, into [out]:
 * each stage's even output is A0's, its odd one A1's. */
static inline int le_os_up(le_os* o, int ch, float x, float* out) {
  out[0] = x;
  int n = 1;
  for (int s = 0; s < o->stages; ++s) {
    float tmp[1 << LE_OS_MAX_STAGES];
    le_os_path* p = &o->up[ch][s];
    for (int i = 0; i < n; ++i) {
      tmp[2 * i] = le_os_path_run(o->c[s], o->n[s], 0, p, out[i]);
      tmp[2 * i + 1] = le_os_path_run(o->c[s], o->n[s], 1, p, out[i]);
    }
    n *= 2;
    for (int i = 0; i < n; ++i) out[i] = tmp[i];
  }
  return n;
}

/* The 2^stages samples in [in] (time order) on channel [ch] back down to
 * one: each pair's newer sample through A0, its older through A1, halved.
 * [in] is used as scratch. */
static inline float le_os_down(le_os* o, int ch, float* in) {
  int n = 1 << o->stages;
  /* The paths are recursive: a sample that is not finite would stay in
   * them, so it goes in as 0. */
  for (int i = 0; i < n; ++i) in[i] = fx_sanitize(in[i]);
  for (int s = o->stages - 1; s >= 0; --s) {
    n /= 2;
    le_os_path* p = &o->down[ch][s];
    for (int i = 0; i < n; ++i) {
      const float a0 = le_os_path_run(o->c[s], o->n[s], 0, p, in[2 * i + 1]);
      const float a1 = le_os_path_run(o->c[s], o->n[s], 1, p, in[2 * i]);
      in[i] = 0.5f * (a0 + a1);
    }
  }
  return in[0];
}

/* At 96 kHz a 48 kHz design run on alternate samples (le_rs_phases) passes
 * what lies above 24 kHz at its mirror image's gain: a low-pass passes
 * 40 kHz as it passes 8. A curve's harmonics reach there, so the waveshapers
 * with such sections after the curve first pass its output through the
 * oversampler's half-band at the full rate (le_os_coefs over 48 kHz: flat
 * to 20 kHz), H(z) = (A0(z^2) + z^-1 A1(z^2)) / 2. Each path runs on the
 * frame's phase's own states; A1's output is used a frame later. Nothing
 * at other rates (n 0). */
typedef struct le_hb {
  float c[LE_OS_MAX_COEFS];
  int32_t n;
  le_os_path p[2][LE_RS_PH]; /* per channel and phase */
  float a1[2];               /* A1's last output, per channel */
} le_hb;

static void le_hb_design(le_hb* h, int sr) {
  memset(h, 0, sizeof(*h));
  if (le_rs_phases(sr) > 1) h->n = le_os_coefs(le_rs_design_rate(sr), 0, h->c);
}

static inline float le_hb_tick(le_hb* h, int ch, int ph, float x) {
  if (h->n == 0) return x;
  le_os_path* p = &h->p[ch][ph];
  const float y = 0.5f * (le_os_path_run(h->c, h->n, 0, p, x) + h->a1[ch]);
  h->a1[ch] = le_os_path_run(h->c, h->n, 1, p, x);
  return y;
}

/* The frames le_hb delays a signal at low frequencies at [sr]: one way of
 * the oversampler's first stage over 48 kHz, which le_os_latency counts in
 * 48 kHz frames up and down, the same figure. */
static int le_hb_latency(int sr) {
  return le_rs_phases(sr) > 1 ? le_os_latency(le_rs_design_rate(sr), 1) : 0;
}

/* ---- The oversampler in lanes (#1755) ----
 *
 * le_os_path_run runs a path's sections one after another, and le_os_up and
 * le_os_down run a channel's two paths one after the other: every section
 * waits for the one before it, and the CPU spends most of the oversampler's
 * time waiting. The Overdrive and the Distortion run their half-bands in
 * lanes instead. One four-float vector holds the left channel's A0 and A1
 * and the right channel's (lanes 0 to 3), so a section is one vector
 * multiply-add for all four. Each lane does what
 * le_os_path_run does, in the same order and with the same expression (so a
 * compiler fuses the same multiply-adds), and the output is bit-identical
 * to the scalar paths'. When a stage's count is odd, A0 has one section
 * more than A1: on that section A1's lanes keep their input
 * (le_lanes.keep). The Amp+Cab is mono: its two paths are one chain of
 * dependent sections however they are laid out, so it keeps le_os. GCC and
 * clang vector extensions: SSE on x86, NEON on the console. */
typedef float le_f4 __attribute__((vector_size(16)));
typedef int32_t le_i4 __attribute__((vector_size(16)));
#define LE_LANES_MAX ((LE_OS_MAX_COEFS + 1) / 2)

/* Lane by lane, [m]'s lanes from [a], the rest from [b]. */
static inline le_f4 le_f4_sel(le_i4 m, le_f4 a, le_f4 b) {
  return (le_f4)((m & (le_i4)a) | (~m & (le_i4)b));
}

/* One half-band in lanes: section j of A0 and of A1, for both channels. */
typedef struct le_lanes {
  le_f4 c[LE_LANES_MAX];
  le_i4 keep;   /* the lanes that run the last section when [odd] */
  int32_t full; /* the sections both paths run */
  int32_t odd;  /* A0 runs one more */
} le_lanes;

/* Each section's last input and output, per lane. */
typedef struct le_lanes_state {
  le_f4 x[LE_LANES_MAX], y[LE_LANES_MAX];
} le_lanes_state;

/* [d] for the [n] coefficients in [c] (le_os_coefs: even A0, odd A1). */
static void le_lanes_design(le_lanes* d, const float* c, int n) {
  memset(d, 0, sizeof(*d));
  d->full = n / 2;
  d->odd = n & 1;
  for (int j = 0; j < (n + 1) / 2; ++j) {
    const float a0 = c[2 * j];
    const float a1 = 2 * j + 1 < n ? c[2 * j + 1] : 0.0f;
    d->c[j] = (le_f4){a0, a1, a0, a1};
  }
  d->keep = (le_i4){-1, 0, -1, 0};
}

/* The [m] samples in [v] through every lane's path, in place: each section
 * y = c (x - y') + x', as le_os_path_run. The states stay in registers over
 * the [m] samples; [full] and [odd] are constants where le_lanes_block
 * calls it, so the sections unroll. */
static inline void le_lanes_run(const le_lanes* d, le_lanes_state* st,
                                le_f4* v, int m, const int full,
                                const int odd) {
  le_f4 x[LE_LANES_MAX], y[LE_LANES_MAX];
  for (int j = 0; j < full + odd; ++j) {
    x[j] = st->x[j];
    y[j] = st->y[j];
  }
  for (int i = 0; i < m; ++i) {
    le_f4 in = v[i];
    for (int j = 0; j < full; ++j) {
      const le_f4 out = d->c[j] * (in - y[j]) + x[j];
      x[j] = in;
      y[j] = out;
      in = out;
    }
    if (odd) {
      const le_f4 out = d->c[full] * (in - y[full]) + x[full];
      x[full] = in;
      y[full] = out;
      in = le_f4_sel(d->keep, out, in);
    }
    v[i] = in;
  }
  for (int j = 0; j < full + odd; ++j) {
    st->x[j] = x[j];
    st->y[j] = y[j];
  }
}

static inline void le_lanes_block(const le_lanes* d, le_lanes_state* st,
                                  le_f4* v, int m) {
  switch (d->full * 2 + d->odd) {
    case 3: le_lanes_run(d, st, v, m, 1, 1); break;
    case 4: le_lanes_run(d, st, v, m, 2, 0); break;
    case 5: le_lanes_run(d, st, v, m, 2, 1); break;
    case 6: le_lanes_run(d, st, v, m, 3, 0); break;
    case 7: le_lanes_run(d, st, v, m, 3, 1); break;
    case 8: le_lanes_run(d, st, v, m, 4, 0); break;
    default: le_lanes_run(d, st, v, m, d->full, d->odd); break;
  }
}

/* le_os for a pair of channels in lanes: the same design and stages. */
typedef struct le_os4 {
  int32_t stages; /* log2 of the factor */
  le_lanes d[LE_OS_MAX_STAGES];
  le_lanes_state up[LE_OS_MAX_STAGES], down[LE_OS_MAX_STAGES];
} le_os4;

/* As le_os_design: designs [o] for 2^[stages] times [sr], state cleared. */
static void le_os4_design(le_os4* o, int sr, int stages) {
  memset(o, 0, sizeof(*o));
  o->stages = stages;
  for (int s = 0; s < stages; ++s) {
    float c[LE_OS_MAX_COEFS];
    le_lanes_design(&o->d[s], c, le_os_coefs(sr, s, c));
  }
}

/* Each lane as fx_sanitize: 0 for what is not finite or within 1e-30 of
 * 0, the rest as it is. */
static inline le_f4 le_f4_sanitize(le_f4 x) {
  const le_f4 a = (le_f4)((le_i4)x & 0x7fffffff);
  return (le_f4)((le_i4)x & ((a >= 1e-30f) & (a <= FLT_MAX)));
}

/* The oversampled pair is kept as vectors of two samples a channel:
 * p[i] = {L(2i), L(2i + 1), R(2i), R(2i + 1)}, i up to 2^stages / 2, which is
 * what an up stage's sections give for one input and what a down stage's
 * take for one output (a shuffle apart), so no sample goes through memory
 * between stages. */

/* As le_os_up for both channels: [l] and [r] up 2^stages times, into [p]
 * as pairs. Returns how many pairs: with no stages, one, {l, 0, r, 0}. */
static inline int le_os4_up(le_os4* o, float l, float r, le_f4* p) {
  if (o->stages == 0) {
    p[0] = (le_f4){l, 0.0f, r, 0.0f};
    return 1;
  }
  p[0] = (le_f4){l, l, r, r};
  int m = 1; /* the stage's inputs a channel */
  for (int s = 0;; ++s) {
    le_lanes_block(&o->d[s], &o->up[s], p, m);
    if (s + 1 == o->stages) return m;
    m *= 2;
    /* sample 2i is each channel's even output, 2i + 1 its odd one */
    for (int i = m / 2 - 1; i >= 0; --i) {
      const le_f4 even = __builtin_shufflevector(p[i], p[i], 0, 0, 2, 2);
      const le_f4 odd = __builtin_shufflevector(p[i], p[i], 1, 1, 3, 3);
      p[2 * i] = even;
      p[2 * i + 1] = odd;
    }
  }
}

/* As le_os_down for both channels: the pairs in [p] (as le_os4_up gave
 * them; used as scratch) down to one sample each, into [l] and [r]. Each
 * pair goes in newer sample first (A0 takes it), and comes out as
 * 0.5 (A0 + A1) per channel. */
static inline void le_os4_down(le_os4* o, le_f4* p, float* l, float* r) {
  int m = o->stages > 0 ? 1 << (o->stages - 1) : 1; /* pairs into the stage */
  /* The paths are recursive: a sample that is not finite would stay in
   * them, so it goes in as 0 (with no stages, as le_os_down does too). */
  for (int i = 0; i < m; ++i) p[i] = le_f4_sanitize(p[i]);
  if (o->stages == 0) {
    *l = p[0][0];
    *r = p[0][2];
    return;
  }
  for (int s = o->stages - 1;; --s) {
    for (int i = 0; i < m; ++i) {
      p[i] = __builtin_shufflevector(p[i], p[i], 1, 0, 3, 2);
    }
    le_lanes_block(&o->d[s], &o->down[s], p, m);
    for (int i = 0; i < m; ++i) {
      p[i] = 0.5f * (p[i] + __builtin_shufflevector(p[i], p[i], 1, 0, 3, 2));
    }
    if (s == 0) {
      *l = p[0][0];
      *r = p[0][2];
      return;
    }
    m /= 2;
    for (int i = 0; i < m; ++i) {
      p[i] = __builtin_shufflevector(p[2 * i], p[2 * i + 1], 0, 4, 2, 6);
    }
  }
}

/* le_hb for a pair of channels in lanes. */
typedef struct le_hb4 {
  le_lanes d;
  int32_t n;                 /* 0: nothing to do at this rate */
  le_lanes_state p[LE_RS_PH]; /* per phase */
  float a1[2];               /* A1's last output, per channel */
} le_hb4;

static void le_hb4_design(le_hb4* h, int sr) {
  memset(h, 0, sizeof(*h));
  if (le_rs_phases(sr) > 1) {
    float c[LE_OS_MAX_COEFS];
    h->n = le_os_coefs(le_rs_design_rate(sr), 0, c);
    le_lanes_design(&h->d, c, h->n);
  }
}

/* Each lane's square root, correctly rounded as sqrtf is. */
static inline le_f4 le_f4_sqrt(le_f4 x) {
#if defined(__aarch64__)
  return (le_f4)vsqrtq_f32((float32x4_t)x);
#elif defined(__SSE__)
  return (le_f4)_mm_sqrt_ps((__m128)x);
#else
  return (le_f4){sqrtf(x[0]), sqrtf(x[1]), sqrtf(x[2]), sqrtf(x[3])};
#endif
}

/* tanhf on four lanes (#1755), for the Overdrive's curve: the console's own
 * tanhf, glibc 2.41's correctly rounded one (CORE-MATH's tanhf, revision
 * b1ecd83, by Alexei Sibidanov, MIT licence: a rational approximation in
 * double, evaluated as it is), two lanes of double at a time. Being
 * correctly rounded, it gives the one right float for every input, so it
 * is bit-identical to the console's tanhf: checked over every finite float
 * on the console, with denormals flushed as the engine runs (#1755). Only
 * the special cases differ in form: glibc's shortcuts below 2^-12 give what
 * the rational does, and from 9.0109... (0x41102cb3), where tanh rounds to
 * 1, this returns +-1 as glibc does, and a NaN as a NaN. Its error is
 * below half an ulp everywhere, where platforms' own tanhf (macOS, glibc
 * before 2.41) are up to 0.8 and 2.2 ulps off. */
typedef double le_d2 __attribute__((vector_size(16)));
typedef float le_f2 __attribute__((vector_size(8)));

static inline le_d2 le_tanh_rational(le_d2 z) {
  const le_d2 z2 = z * z, z4 = z2 * z2, z8 = z4 * z4;
  le_d2 n0 = 0x1p+0 + z2 * 0x1.30877b8b72d33p-3;
  const le_d2 n2 = 0x1.694aa09ae9e5ep-8 + z2 * 0x1.4101377abb729p-14;
  le_d2 n4 = 0x1.e0392b1db0018p-22 + z2 * 0x1.2533756e546f7p-30;
  const le_d2 n6 = 0x1.d62e5abe6ae8ap-41 + z2 * 0x1.b06be534182dep-54;
  n0 += z4 * n2;
  n4 += z4 * n6;
  n0 += z8 * n4;
  le_d2 d0 = 0x1p+0 + z2 * 0x1.ed99131b0ebeap-2;
  const le_d2 d2 = 0x1.0d27ed6c95a69p-5 + z2 * 0x1.7cbdaca0e9fccp-11;
  le_d2 d4 = 0x1.b4e60b892578ep-18 + z2 * 0x1.a6f707c5c71abp-26;
  const le_d2 d6 = 0x1.35a8b6e2cd94cp-35 + z2 * 0x1.ca8230677aa01p-47;
  d0 += z4 * d2;
  d4 += z4 * d6;
  d0 += z8 * d4;
  return z * n0 / d0;
}

static inline le_f4 le_tanh4(le_f4 x) {
  typedef uint32_t le_u4 __attribute__((vector_size(16)));
  const le_u4 ux = (le_u4)x;
  /* past 0x41102cb3 and not NaN (x != x), which goes through as tanhf's */
  const le_i4 one = (le_i4)((ux << 1) > (0x41102cb3u << 1)) & (x == x);
  const le_d2 lo = __builtin_convertvector(__builtin_shufflevector(x, x, 0, 1), le_d2);
  const le_d2 hi = __builtin_convertvector(__builtin_shufflevector(x, x, 2, 3), le_d2);
  const le_f4 t = __builtin_shufflevector(
      __builtin_convertvector(le_tanh_rational(lo), le_f2),
      __builtin_convertvector(le_tanh_rational(hi), le_f2), 0, 1, 2, 3);
  const le_f4 sign_one = (le_f4)((ux & 0x80000000u) | 0x3f800000u);
  /* The engine runs with denormals flushed (le_flush_denormals), where the
   * console's tanhf returns +0 for a subnormal x (it reads as 0) and a zero
   * of x's sign at +-2^-126 (x - x^2 is under the smallest normal before
   * rounding, and flushes). */
  const le_u4 ax = ux & 0x7fffffffu;
  const le_i4 sub = (le_i4)(ax - 1u < 0x007fffffu);
  const le_i4 edge = (le_i4)(ax == 0x00800000u);
  const le_f4 r = le_f4_sel(one, sign_one, t);
  return le_f4_sel(sub | edge, (le_f4)(ux & 0x80000000u & (le_u4)edge), r);
}

/* As le_hb_tick on both channels, in place. */
static inline void le_hb4_tick(le_hb4* h, int ph, float* l, float* r) {
  if (h->n == 0) return;
  le_f4 y = {*l, *l, *r, *r};
  le_lanes_block(&h->d, &h->p[ph], &y, 1);
  *l = 0.5f * (y[0] + h->a1[0]);
  *r = 0.5f * (y[2] + h->a1[1]);
  h->a1[0] = y[1];
  h->a1[1] = y[3];
}

/* The oversampling stages a waveshaper of [type] runs at [sr]: the
 * smallest factor at which every factory setting keeps its aliasing at
 * least 61 dB under its output, a dB inside the effects matrix's 60
 * (#1547: -12 dBFS sines at E4, E5 and E6), so platform rounding cannot
 * push it past the limit. The worst setting's aliasing at 1x, 2x, 4x and 8x, at
 * 44.1 / 48 / 96 kHz:
 *
 *   Overdrive   -34.9 -42.3 -50.3 -62.3 / -35.7 -43.0 -51.4 -64.8 /
 *               -42.9 -51.3 -64.7 -88.4
 *   Amp+Cab     -24.9 -40.4 -58.5 -76.5 / -26.8 -41.9 -59.9 -78.6 /
 *               -42.4 -60.2 -72.5
 *   Vinyl       -44.5 -58.2 -70.4 / -45.9 -59.8 -72.0 / -59.9 -72.4
 *   Distortion  -53.8 -77.2 / -55.7 -80.5 / -80.3
 *
 * The Overdrive's clipped part (G / c up to 1090 times the input into a
 * tanh) is close to a square wave, so each doubling lowers its aliasing by
 * only 8 dB. The table predates the clipped part's small-signal refit
 * (#1663), which raised that gain up to 1.6 times at high drive: its worst
 * setting now reads -59.9 dB at 8x and 44.1 kHz (listed as a known failure
 * in the effects matrix; 16x cleared it in a trial, at twice the kind's
 * cost there), -62.7 dB at 8x and 48 kHz, and -62.7 dB at 4x and 96 kHz.
 * Likewise the Amp+Cab's row predates its Drive-by-Modern table (#1664),
 * which drives its clipper up to 9.4 dB harder: its worst setting now reads
 * -63.6, -63.7 and -63.8 dB at 44.1, 48 and 96 kHz.
 * First-order antiderivative anti-aliasing on that tanh (its antiderivative
 * log cosh) reaches -69 dB at 2x and 44.1 kHz, but its exp and log1p in
 * double on every sample cost more than 8x plain: about 280 against 233 ns
 * a frame at 48 kHz on an M4 Pro. The curves stay where they are:
 * oversampling only takes away what folded back. A rate past 96 kHz runs
 * the 96 kHz factor. */
static int le_os_stages(int32_t type, int sr) {
  const int low = sr < 88200; /* 44.1 and 48 kHz */
  switch (type) {
    case LE_FX_OVERDRIVE:
    case LE_FX_AMP_CAB:
      return low ? 3 : 2; /* 8x, 4x */
    case LE_FX_VINYL:
      return low ? 2 : 1; /* 4x, 2x */
    case LE_FX_DISTORTION:
      return low ? 1 : 0; /* 2x, 1x */
    default:
      return 0;
  }
}

static int le_cab_pre(int sr);

/* The latency of a kind that oversamples, for the effect table: the
 * oversampler's; at 96 kHz the half-band its curve's output passes on the
 * way to the 48 kHz sections (le_hb; the Vinyl has none, the Amp+Cab two,
 * one after each curve); and the frames
 * the Amp+Cab's resampled cabinet starts late (le_cab_pre). */
static int fx_os_latency_vt(const le_fx_state* fx, int slot, int32_t type,
                            int sr) {
  (void)fx;
  (void)slot;
  int lat = le_os_latency(sr, le_os_stages(type, sr));
  if (type != LE_FX_VINYL) lat += le_hb_latency(sr);
  if (type == LE_FX_AMP_CAB) lat += le_hb_latency(sr); /* its first curve's */
  if (type == LE_FX_AMP_CAB) lat += le_cab_pre(sr);
  return lat;
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
 * - the polarity is the input's: the onset of a +0.5 impulse comes out
 *   positive, 2 samples late as the dry path is, then rings to its largest
 *   swing, negative, 23 to 30 samples later, which Phase 0 read as an
 *   inverted output; below the knee the pedal's phase sits 180 degrees from
 *   an inverted one's (#1743, sessions s20pol and s19lofi).
 * The model, u = K x + LP(c tanh(G x_d / c)), then (tanh(a (u + b)) -
 * tanh(a b)) / a, then the tone filter, matches the fundamental within
 * 0.9 dB and the third harmonic within 3 dB at every level and drive
 * (scratch fit, not committed).
 *
 * Small signal (#1663, session s18idle: white noise at -90 dBFS, 1 kHz
 * from -70 to -40 dBFS, Drive 0, 11.3, 50.3, 90 and 100 % at Tone 50.2 %,
 * Tone 0, 25.4, 75 and 100 % at Drive 50.3 %): below the clipped part's
 * knee the Looper X's pedal is a band-pass, rising 6 dB an octave to a peak
 * near 800 Hz (+12.5 dB at Drive 0, +30.7 dB at 100 %), so it lifts 50 Hz hum
 * 15 to 19 dB less than a flat gain would. The clipped part's input x_d is
 * the input through a 434 Hz high-pass, and its output passes a low-pass
 * whose corner falls as the drive rises, fg = 176.6 kHz / G, a fixed
 * gain-bandwidth (a Tube Screamer's feedback network does both: a capacitor
 * in series with its gain leg, one across its diodes); both run at the
 * curve's rate. The low-pass sits after the curve because the captures
 * put it there: before it, noise at -55 dBFS came out 2 to 3 dB louder than
 * the Looper X's at Drive 90 % and up; after it, within 1.1 dB. G, the
 * clipped part's small-signal gain, is e^(1.542 + 1.357 v + 0.792 v^2),
 * 4.7 at Drive 0 and 40.1 at 100 %. The clean part stays flat. With the
 * existing curve and filters, this fits the twelve captured settings'
 * responses from 30 Hz to 16 kHz within 1.1 dB rms (worst: 3.7 dB at
 * 16 kHz, 1.8 dB at 31 Hz), the 1 kHz ladders within 1.7 dB and the
 * Phase 0 levels within 0.9 dB.
 *
 * The tone filter is post-curve (a tone setting moves the 1 kHz ladder by
 * the same dB at every level): the 1.63 kHz corner the 50 % fit has, then
 * a high shelf at 1419 Hz (q 0.463) and a bell at 1271 Hz (Q 0.274) whose
 * gains were fitted at Tone 0, 25, 75 and 100 % (within 0.8 dB of the
 * captured change from 50 %, 40 Hz to 16 kHz) and are flat at 50 %, which
 * leaves the Phase 0 fit as it was. Between those the gains interpolate
 * linearly, as the Amp+Cab's settings do.
 *
 * The level is a gain after all of it, 0 to +12 dB, 0 dB by default (the
 * OvDrive's).
 * The Lo-Fi Rack's Distort is this pedal at +4.08 dB, a gain of 1.6
 * (#1737, session s19lofi: at Drive 0, 53.5 and 100 % and Tone 0, 50 and
 * 100 % it is the Guitar Rack's OvDrive times 1.600 to a residual of -73
 * dB, -149 dB at Drive 0). */
static const le_fx_param_desc LE_FX_OVERDRIVE_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.09f,
     0},
    {"tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f,
     0},
    /* 0 dB at setting 0, so a setting nobody wrote leaves the pedal as fit */
    {"level", LE_FX_UNIT_DB, 0, 0.0f, 12.0f, LE_FX_CURVE_LINEAR, 0.0f, 0},
};
#define LE_OD_K 0.5166f      /* the clean part */
#define LE_OD_C 0.0367f      /* the clipped part's ceiling */
#define LE_OD_A 2.8826f      /* the second stage */
#define LE_OD_B 0.0772f      /* ... and its asymmetry */
#define LE_OD_OFF 0.21893453f /* tanh(LE_OD_A LE_OD_B): its rest point */
#define LE_OD_P 0.9752f      /* output, with the tone filter at 1 kHz */
#define LE_OD_LNG0 1.5423    /* ln G = LNG0 + LNG1 v + LNG2 v^2 */
#define LE_OD_LNG1 1.3574
#define LE_OD_LNG2 0.7915
#define LE_OD_DHP_HZ 434.24  /* the clipped part's high-pass */
#define LE_OD_GBW_HZ 176638.0 /* its low-pass: fg = GBW / G */
#define LE_OD_HP_HZ 17.32
#define LE_OD_PEAK_HZ 682.2
#define LE_OD_PEAK_DB 1.552
#define LE_OD_PEAK_Q 0.566
#define LE_OD_TONE_HZ 1630.2 /* the tone corner */
#define LE_OD_LP2_HZ 11110.0
#define LE_OD_TONE_1K 0.98544 /* |tone filter| at 1 kHz, 50 %: the fit's unit */
#define LE_OD_SH_HZ 1418.7    /* the tone's shelf */
#define LE_OD_SH_Q 0.4626
#define LE_OD_BL_HZ 1271.1    /* the tone's bell */
#define LE_OD_BL_Q 0.2742
#define LE_OD_TONE_PTS 5      /* Tone 0, 25, 50, 75 and 100 % */
static const float LE_OD_SH_DB[LE_OD_TONE_PTS] = {-1.535f, 0.481f, 0.0f, 1.555f,
                                                  13.70f};
static const float LE_OD_BL_DB[LE_OD_TONE_PTS] = {-4.647f, -2.324f, 0.0f,
                                                  1.489f, -0.19f};

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
  le_fx_glide g;    /* the clipped part's gain over its ceiling, G / c */
  le_fx_glide level; /* the gain after the tone filter */
  float g_tgt;      /* where g is headed */
  float dlp_g;      /* the glide point dlp_g1 was designed for, -1 for none */
  float tone;       /* the tone setting now, 0..1 */
  float tone_tgt;
  float level_tgt;  /* where level is headed, a gain */
  float hp_g1;
  float dhp_g1, dlp_g1; /* the clipped part's input high-pass and output
                         * low-pass, one-poles at the curve's rate */
  float s_dhp[2], s_dlp[2];
  float pk[5];      /* the 680 Hz rise, RBJ, a0-normalized */
  float tone_lp[5], sh[5], bl[5]; /* the tone: its corner, shelf and bell */
  float lp2[5];     /* the 11 kHz pole */
  float s_hp[2];
  float z_pk[2][LE_RS_PH][2], z_tone[2][LE_RS_PH][2], z_sh[2][LE_RS_PH][2];
  float z_bl[2][LE_RS_PH][2], z_lp2[2][LE_RS_PH][2];
  int32_t ph, nph; /* the sections' phase this frame (le_rs_phases) */
  le_os4 os; /* the curve's oversampling, both channels in lanes */
  le_hb4 hb; /* at 96 kHz, the curve's output under 24 kHz */
} le_fx_overdrive;

/* The tone's shelf or bell gain at setting [t], dB: [tab] read at Tone 0,
 * 25, 50, 75 and 100 %, linear between. */
static float le_od_tone_db(const float* tab, float t) {
  const float x = (t < 0.0f ? 0.0f : t > 1.0f ? 1.0f : t) *
                  (float)(LE_OD_TONE_PTS - 1);
  int i = (int)x;
  if (i > LE_OD_TONE_PTS - 2) i = LE_OD_TONE_PTS - 2;
  const float w = x - (float)i;
  return tab[i] + w * (tab[i + 1] - tab[i]);
}

static void le_od_coefs(float* dst, int kind, double hz, double db, double q,
                        int sr) {
  double c[5];
  le_rate_design(kind, hz, db, q, sr, c);
  for (int i = 0; i < 5; ++i) dst[i] = (float)c[i];
}

static void fx_overdrive_update(void* ks, le_fx_dyn_head* h, const float* p,
                                int sr, int f) {
  le_fx_overdrive* o = (le_fx_overdrive*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    le_os4_design(&o->os, sr, le_os_stages(LE_FX_OVERDRIVE, sr));
    le_hb4_design(&o->hb, sr);
    o->nph = le_rs_phases(sr);
    memset(o->s_dhp, 0, sizeof(o->s_dhp));
    memset(o->s_dlp, 0, sizeof(o->s_dlp));
    memset(o->z_pk, 0, sizeof(o->z_pk));
    memset(o->z_tone, 0, sizeof(o->z_tone));
    memset(o->z_sh, 0, sizeof(o->z_sh));
    memset(o->z_bl, 0, sizeof(o->z_bl));
    memset(o->z_lp2, 0, sizeof(o->z_lp2));
    o->ph = 0;
    o->dlp_g = -1.0f; /* none designed at this rate yet */
    o->hp_g1 = le_onepole_g1(LE_OD_HP_HZ, sr);
    o->dhp_g1 = le_onepole_g1(LE_OD_DHP_HZ, rate << o->os.stages);
    le_od_coefs(o->lp2, LE_RS_LP1, LE_OD_LP2_HZ, 0.0, 0.0, rate);
    le_od_coefs(o->pk, LE_EQ_LOMID, LE_OD_PEAK_HZ, LE_OD_PEAK_DB, LE_OD_PEAK_Q,
                rate);
    le_od_coefs(o->tone_lp, LE_RS_LP1, LE_OD_TONE_HZ, 0.0, 0.0, rate);
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    o->tone_tgt = t;
    o->g_tgt = (float)(exp(LE_OD_LNG0 + d * (LE_OD_LNG1 + d * LE_OD_LNG2)) /
                       LE_OD_C);
    /* 0 dB is a gain of exactly 1, so the default leaves the output as it
     * was. */
    o->level_tgt = le_gain_of_db(
        (float)le_fx_desc_value(&LE_FX_OVERDRIVE_PARAMS[2], p[2]));
  }
  const float k = settle ? 1.0f : h->k;
  int moving = le_fx_glide_step(&o->g, o->g_tgt, k);
  moving |= le_fx_glide_step(&o->level, o->level_tgt, k);
  if (o->dlp_g != o->g.g) {
    /* the low-pass follows the gain the glide is headed for this step */
    o->dlp_g = o->g.g;
    const double gain = (double)o->g.g * LE_OD_C;
    o->dlp_g1 = le_onepole_g1(LE_OD_GBW_HZ / gain, rate << o->os.stages);
  }
  if (o->tone != o->tone_tgt || (f & LE_FX_DYN_NEW_RATE)) {
    le_fx_step_toward(&o->tone, o->tone_tgt, k);
    le_od_coefs(o->sh, LE_EQ_HIGH, LE_OD_SH_HZ,
                le_od_tone_db(LE_OD_SH_DB, o->tone), LE_OD_SH_Q, rate);
    le_od_coefs(o->bl, LE_EQ_LOMID, LE_OD_BL_HZ,
                le_od_tone_db(LE_OD_BL_DB, o->tone), LE_OD_BL_Q, rate);
  }
  moving |= o->tone != o->tone_tgt;
  h->moving = moving;
}

/* The kernel takes both channels together (#1755): the oversampler in lanes
 * (le_os4), then the curve a step at a time across all sixteen samples (8x,
 * two channels): the high-passes, every first tanh, the low-passes, every
 * second tanh. The one-poles stay in time order per channel, and the tanhs
 * run four at a time (le_tanh4, the console's tanhf exactly). Per sample
 * the arithmetic is what it was, so on the console the output is
 * bit-identical. */
static void fx_overdrive_kprocess(void* ks, float* l, float* r) {
  le_fx_overdrive* o = (le_fx_overdrive*)ks;
  const float g = le_fx_glide_next(&o->g);
  const float level = le_fx_glide_next(&o->level);
  le_f4 p[1 << (LE_OS_MAX_STAGES - 1)];
  le_f4 t[1 << (LE_OS_MAX_STAGES - 1)];
  const int m = le_os4_up(&o->os, fx_sanitize(*l), fx_sanitize(*r), p);
  /* The clipped part: the 434 Hz high-pass before the curve, the drive's
   * low-pass after it, at the curve's rate. Lane 2 ch + k of pair i is
   * channel ch's sample 2 i + k. */
  for (int i = 0; i < m; ++i) {
    for (int k = 0; k < 2; ++k) {
      for (int ch = 0; ch < 2; ++ch) {
        const float x = p[i][2 * ch + k];
        t[i][2 * ch + k] =
            g * (x - le_onepole_lp(&o->s_dhp[ch], o->dhp_g1, x));
      }
    }
  }
  for (int i = 0; i < m; ++i) t[i] = le_tanh4(t[i]);
  for (int i = 0; i < m; ++i) {
    for (int k = 0; k < 2; ++k) {
      for (int ch = 0; ch < 2; ++ch) {
        const float u = LE_OD_K * p[i][2 * ch + k] +
                        le_onepole_lp(&o->s_dlp[ch], o->dlp_g1,
                                      LE_OD_C * t[i][2 * ch + k]);
        t[i][2 * ch + k] = LE_OD_A * (u + LE_OD_B);
      }
    }
  }
  for (int i = 0; i < m; ++i) {
    p[i] = (le_tanh4(t[i]) - LE_OD_OFF) * (1.0f / LE_OD_A);
  }
  float io[2];
  le_os4_down(&o->os, p, &io[0], &io[1]);
  le_hb4_tick(&o->hb, o->ph, &io[0], &io[1]);
  for (int ch = 0; ch < 2; ++ch) {
    float v = io[ch];
    /* The tone filter: the 17 Hz high-pass, the 680 Hz rise, the tone
     * corner, shelf and bell, and the 11 kHz pole. */
    v = v - le_onepole_lp(&o->s_hp[ch], o->hp_g1, v);
    v = le_biquad_tick(o->pk, o->z_pk[ch][o->ph], v);
    v = le_biquad_tick(o->tone_lp, o->z_tone[ch][o->ph], v);
    v = le_biquad_tick(o->sh, o->z_sh[ch][o->ph], v);
    v = le_biquad_tick(o->bl, o->z_bl[ch][o->ph], v);
    v = le_biquad_tick(o->lp2, o->z_lp2[ch][o->ph], v);
    io[ch] = ((LE_OD_P / (float)LE_OD_TONE_1K) * v) * level;
  }
  if (++o->ph >= o->nph) o->ph = 0;
  *l = io[0];
  *r = io[1];
}

/* ---- Amp+Cab (LE_FX_AMP_CAB, #887 part 12) ----
 *
 * The Looper X's Amp pedal (Ed's and Guitar racks; the Studio Rack's Dist on
 * the D.I., #1743), fit to the #891 rig
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
 * corners in octaves), the plainest reading of five points. Drive and
 * Modern do not act apart: the level into the clipper also reads a
 * Drive-by-Modern table (LE_AMP_DM_DB, s18amp, #1664). */

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
  int32_t parts;
  int32_t pre; /* le_cab_pre at the bank's rate: the D.I. waits as long */
  float head[LE_CAB_ROWS][LE_CAB_B]; /* last tap first (le_cab_head) */
  float re[LE_CAB_ROWS][LE_CAB_MAX_PARTS][LE_CAB_NB];
  float im[LE_CAB_ROWS][LE_CAB_MAX_PARTS][LE_CAB_NB];
} le_cab_bank;

static le_rate_tables le_cab_banks = {.mu = PTHREAD_MUTEX_INITIALIZER};
static le_rfft_plan le_cab_fft; /* built under le_cab_banks' lock */

/* The bank for [sr], or NULL when none was built. Any thread. */
static const le_cab_bank* le_cab_bank_find(int32_t sr) {
  return (const le_cab_bank*)le_rate_tables_find(&le_cab_banks, sr);
}

#define LE_CAB_SINC_HW 32    /* resampling kernel half-width, 48 kHz taps */
#define LE_CAB_SINC_HZ 21000.0 /* its cutoff, under 44.1 kHz's Nyquist */
#define LE_CAB_SINC_BETA 8.0  /* its Kaiser window */

/* The samples a resampled cabinet starts late at [sr] (le_cab_bank_make):
 * about 0.09 ms, none at 48 and 96 kHz. */
static int le_cab_pre(int sr) {
  return sr == 48000 || sr == 96000 ? 0 : (int)(4.0 * sr / 48000.0 + 0.5);
}

/* Builds the bank for [sr] (le_rate_tables_get). At 48 kHz each row is the
 * captured response itself. At 96 kHz the 48 kHz response runs on every
 * other sample (taps at the even positions, le_rs_phases), which is that
 * response exactly below 24 kHz. Other rates resample the 48 kHz response
 * with a Kaiser-windowed sinc cut at 21 kHz, scaled by 48000 / sr so the
 * cabinet's gain does not change with the rate. The kernel rings before the
 * response's sharp onset, so the resampled response starts le_cab_pre
 * samples late, keeping that ringing rather than dropping it, which left the
 * deep 10-16 kHz region up to 2 dB off at 44.1 kHz (#1547); the Amp+Cab
 * reports them as latency. Past 96 kHz the
 * response is cut at LE_CAB_MAX_PARTS partitions, with a fade over its last
 * quarter. */
static void* le_cab_bank_make(int32_t sr) {
  const int n48 = LE_CAB_TAPS48;
  const int max_taps = LE_CAB_B * (LE_CAB_MAX_PARTS + 1);
  const double r = 48000.0 / (double)sr; /* 48 kHz taps per output sample */
  const int pre = le_cab_pre(sr);
  int m = sr == 48000   ? n48
          : sr == 96000 ? 2 * n48
                        : pre + (int)ceil((n48 + LE_CAB_SINC_HW) / r);
  const int cut = m > max_taps; /* past 96 kHz the tail is cut */
  if (cut) m = max_taps;
  le_cab_bank* b = (le_cab_bank*)calloc(1, sizeof(*b));
  /* every row's response at the rate, row after row */
  float* h = (float*)malloc(sizeof(float) * (size_t)m * LE_CAB_ROWS);
  if (b == NULL || h == NULL || !le_rfft_plan_init(&le_cab_fft, 2 * LE_CAB_B)) {
    free(b);
    free(h);
    return NULL;
  }
  b->pre = pre;
  b->parts = (m - LE_CAB_B + LE_CAB_B - 1) / LE_CAB_B;
  if (b->parts > LE_CAB_MAX_PARTS) b->parts = LE_CAB_MAX_PARTS;
  if (sr == 48000) {
    for (int row = 0; row < LE_CAB_ROWS; ++row) {
      memcpy(h + (size_t)row * m, LE_CAB_IR48[row], sizeof(float) * (size_t)n48);
    }
  } else if (sr == 96000) {
    for (int row = 0; row < LE_CAB_ROWS; ++row) {
      float* hr = h + (size_t)row * m;
      for (int t = 0; t < n48; ++t) {
        hr[2 * t] = LE_CAB_IR48[row][t];
        hr[2 * t + 1] = 0.0f;
      }
    }
  } else {
    /* Each output tap's kernel weights, worked out once for every row. */
    const double fc = 2.0 * LE_CAB_SINC_HZ / 48000.0; /* of the 48 kHz rate */
    const double i0b = le_bessel_i0(LE_CAB_SINC_BETA);
    double kw[2 * LE_CAB_SINC_HW + 1];
    for (int t = 0; t < m; ++t) {
      const double x = (double)(t - pre) * r; /* in 48 kHz taps */
      int n0 = (int)ceil(x - LE_CAB_SINC_HW);
      int n1 = (int)floor(x + LE_CAB_SINC_HW);
      if (n0 < 0) n0 = 0;
      if (n1 > n48 - 1) n1 = n48 - 1;
      for (int n = n0; n <= n1; ++n) {
        const double d = x - (double)n, u = d / LE_CAB_SINC_HW;
        const double a = 3.14159265358979323846 * fc * d;
        const double sinc = a == 0.0 ? 1.0 : sin(a) / a;
        const double w = le_bessel_i0(LE_CAB_SINC_BETA * sqrt(1.0 - u * u));
        kw[n - n0] = fc * sinc * w / i0b * r;
      }
      for (int row = 0; row < LE_CAB_ROWS; ++row) {
        const float* h48 = LE_CAB_IR48[row];
        double acc = 0.0;
        for (int n = n0; n <= n1; ++n) acc += (double)h48[n] * kw[n - n0];
        h[(size_t)row * m + t] = (float)acc;
      }
    }
  }
  float frame[2 * LE_CAB_B];
  for (int row = 0; row < LE_CAB_ROWS; ++row) {
    float* hr = h + (size_t)row * m;
    if (cut) {
      const int q = m / 4;
      for (int t = m - q; t < m; ++t) {
        const double c = cos(1.5707963267948966 * (double)(t - (m - q)) / q);
        hr[t] *= (float)(c * c);
      }
    }
    for (int t = 0; t < LE_CAB_B; ++t) {
      b->head[row][LE_CAB_B - 1 - t] = t < m ? hr[t] : 0.0f;
    }
    for (int p = 0; p < b->parts; ++p) {
      for (int t = 0; t < 2 * LE_CAB_B; ++t) {
        const int k = LE_CAB_B + p * LE_CAB_B + t;
        frame[t] = t < LE_CAB_B && k < m ? hr[k] : 0.0f;
      }
      le_rfft_fwd(&le_cab_fft, frame, b->re[row][p], b->im[row][p]);
    }
  }
  free(h);
  return b;
}

/* The bank for [sr], built the first time (control thread). */
static const le_cab_bank* le_cab_bank_get(int32_t sr) {
  if (sr <= 0) sr = 48000;
  return (const le_cab_bank*)le_rate_tables_get(&le_cab_banks, sr,
                                                le_cab_bank_make);
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
/* Drive and Modern together (#1664, session s18amp: white noise at
 * -90 dBFS, D.I., tone at 50 %): the level into the clipper the two tables
 * above miss, dB, on a Drive (rows) by Modern (columns) grid at 0, 25, 50,
 * 75 and 100 %, bilinear between. On the Looper X, the gain Modern adds
 * grows with the drive: from 25 to 75 % it moves the small-signal gain by
 * 6.6 dB at Drive 0, 14 dB at 75 % and 23 dB at 100 %, where the tables
 * gave 4 to 6 dB. Each entry is the capture's gain minus the tables', 200 Hz
 * to 2 kHz; the rest of the response already matched within 1 dB. */
static const float LE_AMP_DM_DB[LE_AMP_PTS][LE_AMP_PTS] = {
    {-0.23f, -0.25f, -0.34f, -0.39f, -0.36f},
    {0.58f, 0.15f, -0.32f, -1.01f, -1.62f},
    {1.04f, 0.40f, -0.55f, -1.92f, -2.18f},
    {0.37f, -0.50f, -1.12f, 6.74f, 8.99f},
    {-8.16f, -9.02f, -0.36f, 7.35f, 9.43f}};
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

/* [d] and [m] (0..1) on a five-by-five table, bilinearly: each row read
 * at [m], then that column at [d]. */
static float le_amp_lerp2(const float tab[LE_AMP_PTS][LE_AMP_PTS], float d,
                          float m) {
  float col[LE_AMP_PTS];
  for (int i = 0; i < LE_AMP_PTS; ++i) col[i] = le_amp_lerp(tab[i], m);
  return le_amp_lerp(col, d);
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

/* le_amp_knee on four lanes: square roots and division are correctly
 * rounded, in lanes as alone, so each lane is bit-identical to it. */
static inline le_f4 le_amp_knee4(le_f4 z) {
  const le_f4 a = z * z;
  return z / le_f4_sqrt(le_f4_sqrt(1.0f + a * a));
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
  /* the sections' state per phase (le_rs_phases); the one-pole couplings
   * run at the rate */
  float z_pre[3][LE_RS_PH][2], z_dc[2], z_m[3][LE_RS_PH][2], z_dhs[LE_RS_PH][2],
      z_post_hp[2], z_tone[2][LE_RS_PH][2], z_lp[2][LE_RS_PH][2];
  int32_t ph, nph;
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
  le_os os; /* the clipper's oversampling (mono: channel 0) */
  le_hb hbq; /* at 96 kHz, the first curve's output under 24 kHz */
  le_hb hb;  /* and the clipper's */
} le_fx_amp;

static void le_amp_design(int kind, double hz, double db, double q, int sr,
                          float c[5]) {
  double d[5];
  le_rate_design(kind, hz, db, q, sr, d);
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
  le_os_clear(&a->os);
  memset(a->hbq.p, 0, sizeof(a->hbq.p));
  memset(a->hbq.a1, 0, sizeof(a->hbq.a1));
  memset(a->hb.p, 0, sizeof(a->hb.p));
  memset(a->hb.a1, 0, sizeof(a->hb.a1));
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
    le_os_design(&a->os, sr, le_os_stages(LE_FX_AMP_CAB, sr));
    le_hb_design(&a->hb, sr);
    le_hb_design(&a->hbq, sr);
    a->nph = le_rs_phases(sr);
    memset(a->z_pre, 0, sizeof(a->z_pre));
    memset(a->z_m, 0, sizeof(a->z_m));
    memset(a->z_dhs, 0, sizeof(a->z_dhs));
    memset(a->z_tone, 0, sizeof(a->z_tone));
    memset(a->z_lp, 0, sizeof(a->z_lp));
    a->ph = 0;
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
                        le_amp_lerp(LE_AMP_MPRE_DB, modern) +
                            le_amp_lerp2(LE_AMP_DM_DB, drive, modern),
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

/* A cabinet's first LE_CAB_B taps on the last LE_CAB_B inputs: [h] is the
 * bank's row, last tap first, so it runs forward over the history from
 * hx[-(B - 1)] to hx[0]. Sixteen products at a time in four sums (#1755),
 * where one sum in time order kept each multiply-add waiting on the last;
 * the order of the additions changes only their rounding, at most a few
 * ulps of the output. */
static inline float le_cab_head(const float* h, const float* hx) {
  const float* x = hx - (LE_CAB_B - 1);
  le_f4 s[4] = {{0}};
  for (int t = 0; t < LE_CAB_B; t += 16) {
    for (int k = 0; k < 4; ++k) {
      le_f4 hv, xv;
      memcpy(&hv, h + t + 4 * k, sizeof(hv));
      memcpy(&xv, x + t + 4 * k, sizeof(xv));
      s[k] += hv * xv;
    }
  }
  const le_f4 v = (s[0] + s[1]) + (s[2] + s[3]);
  return (v[0] + v[1]) + (v[2] + v[3]);
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
    /* The D.I. waits the frames a resampled cabinet starts late, so every
     * cabinet has the latency the table reports (none at 48 and 96 kHz). */
    yn = hx[-bk->pre];
  } else {
    yn = le_cab_head(bk->head[rn], hx) + a->tail[0][a->j];
  }
  const int fading = a->xf > 0;
  if (fading) {
    if (ro < 0) {
      yo = hx[-bk->pre];
    } else {
      yo = le_cab_head(bk->head[ro], hx) + a->tail[1][a->j];
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
  const int ph = a->ph;
  if (++a->ph >= a->nph) a->ph = 0;
  float u = le_biquad_tick(a->pre_hp, a->z_pre[0][ph], x);
  u = le_biquad_tick(a->pre_pk1, a->z_pre[1][ph], u);
  u = le_biquad_tick(a->pre_pk2, a->z_pre[2][ph], u);
  u *= a->ga_lin;
  float v = le_hb_tick(&a->hbq, 0, ph, u + a->kq * u * u);
  v = le_amp_hp1_tick(a->dc_b0, a->dc_a1, a->z_dc, v);
  v = le_biquad_tick(a->m_ls, a->z_m[0][ph], v);
  v = le_biquad_tick(a->m_pk, a->z_m[1][ph], v);
  v = le_biquad_tick(a->m_hs, a->z_m[2][ph], v);
  v = le_biquad_tick(a->d_hs, a->z_dhs[ph], v);
  /* The clipper, four samples at a time (#1755), the rest one by one. */
  float os[1 << LE_OS_MAX_STAGES];
  const int n = le_os_up(&a->os, 0, v * a->mpre_lin * a->gb_lin, os);
  int i = 0;
  for (; i + 4 <= n; i += 4) {
    le_f4 w;
    memcpy(&w, &os[i], sizeof(w));
    const le_f4 c = le_f4_sel(
        w >= 0.0f,
        (le_f4){LE_AMP_CLIP_POS, LE_AMP_CLIP_POS, LE_AMP_CLIP_POS, LE_AMP_CLIP_POS},
        (le_f4){LE_AMP_CLIP_NEG, LE_AMP_CLIP_NEG, LE_AMP_CLIP_NEG, LE_AMP_CLIP_NEG});
    w = c * le_amp_knee4(w / c);
    memcpy(&os[i], &w, sizeof(w));
  }
  for (; i < n; ++i) {
    const float w = os[i];
    os[i] = w >= 0.0f ? LE_AMP_CLIP_POS * le_amp_knee(w / LE_AMP_CLIP_POS)
                      : LE_AMP_CLIP_NEG * le_amp_knee(w / LE_AMP_CLIP_NEG);
  }
  float y = le_hb_tick(&a->hb, 0, ph, le_os_down(&a->os, 0, os));
  y = le_amp_hp1_tick(a->post_hp_b0, a->post_hp_a1, a->z_post_hp, y);
  y = le_biquad_tick(a->t_bass, a->z_tone[0][ph], y);
  y = le_biquad_tick(a->t_treb, a->z_tone[1][ph], y);
  y = le_biquad_tick(a->lp1, a->z_lp[0][ph], y);
  y = le_biquad_tick(a->lp2, a->z_lp[1][ph], y);
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
 * No factory rack builds this since #1737 (the Lo-Fi Distort is the
 * Overdrive) and #1743 (the Studio Dist is the Amp+Cab on its D.I.
 * cabinet); chains saved with it keep it, as it was.
 *
 * Fit as the Looper X's amp simulator at its other controls' defaults:
 * Bass, Treble and Modern 50 % and the 4x12" cabinet. Fit to the Phase 0
 * captures (#891):
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
 *   within 0.8 dB rms from 45 Hz to 18 kHz. That fit held at 96 kHz; at
 *   48 kHz, where the Looper X runs, the same sections fell 2.4 dB under
 *   the capture at 7.5 kHz and 6 dB at 11.4 kHz. They are
 *   refitted at 48 kHz to the 96 kHz fit's response, within 0.07 dB from
 *   45 Hz to 18 kHz (#1547), and the other rates follow 48 kHz.
 * Against the Studio Rack's Dist (#1731, session s19std) this drive law's
 * 1 kHz small-signal gain is within 3.1 dB at every setting, though the
 * Dist's voicing is flatter, which is why the Studio Rack now builds the
 * Amp+Cab (#1743). The tone is a 2 kHz high shelf of
 * LE_DIST_TONE_DB x (2 tone - 1) dB. */
static const le_fx_param_desc LE_FX_DISTORTION_PARAMS[] = {
    {"drive", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.2f, 0},
    {"tone", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
};
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
    {LE_EQ_LOWCUT, 51.74, 0.0, 1.9454},   {LE_EQ_HIGHCUT, 19519.1, 0.0, 1.6499},
    {LE_EQ_HIGHCUT, 2546.2, 0.0, 0.4000}, {LE_EQ_LOMID, 313.62, 9.114, 0.2394},
    {LE_EQ_LOMID, 835.00, -3.591, 3.7963}, {LE_EQ_LOMID, 1112.85, 1.243, 7.1632},
    {LE_EQ_LOMID, 720.77, -1.541, 5.3833}, {LE_EQ_LOMID, 2709.65, 10.279, 0.7815},
    {LE_EQ_LOMID, 6416.11, 22.886, 1.0974},
};

typedef struct le_fx_distortion {
  le_fx_glide g;     /* the gain into the curve */
  le_fx_glide level; /* the output level, over the cabinet's 1 kHz gain */
  float norm;        /* 1 / |cabinet at 1 kHz| */
  float tone_db;     /* the shelf now, gliding to tone_tgt */
  float tone_tgt;
  int32_t shelf_on;
  float cab[LE_DIST_SECTIONS][5];
  float shelf[5];
  float z[LE_DIST_SECTIONS + 1][2][LE_RS_PH][2]; /* [section][channel][phase][state] */
  int32_t ph, nph; /* the sections' phase this frame (le_rs_phases) */
  le_os4 os; /* the curve's oversampling, both channels in lanes */
  le_hb4 hb; /* at 96 kHz, the curve's output under 24 kHz */
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

static void fx_distortion_update(void* ks, le_fx_dyn_head* h, const float* p,
                                 int sr, int f) {
  le_fx_distortion* q = (le_fx_distortion*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    le_os4_design(&q->os, sr, le_os_stages(LE_FX_DISTORTION, sr));
    le_hb4_design(&q->hb, sr);
    q->nph = le_rs_phases(sr);
    memset(q->z, 0, sizeof(q->z));
    q->ph = 0;
    double mag = 1.0;
    /* The sections are designed at le_rs_design_rate. */
    const double w1k =
        2.0 * 3.14159265358979323846 * 1000.0 / le_rs_design_rate(rate);
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      double c[5];
      le_rate_design(LE_DIST_CAB[s].kind, LE_DIST_CAB[s].hz, LE_DIST_CAB[s].db,
                   LE_DIST_CAB[s].q, rate, c);
      for (int i = 0; i < 5; ++i) q->cab[s][i] = (float)c[i];
      mag *= le_biquad_mag(c, w1k);
    }
    q->norm = (float)(1.0 / mag);
  }
  const float d = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  const float t = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  const float k = settle ? 1.0f : h->k;
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
      le_rate_design(LE_EQ_HIGH, LE_DIST_TONE_HZ, q->tone_db, 0.70710678, rate,
                     c);
      for (int i = 0; i < 5; ++i) q->shelf[i] = (float)c[i];
    }
  }
  moving |= q->tone_db != q->tone_tgt;
  h->moving = moving;
}

/* powf on four lanes (#1755), for the Distortion's curve: glibc 2.41's powf
 * as the console's glibc builds it for aarch64 (sysdeps/ieee754/flt-32/
 * e_powf.c, Szabolcs Nagy's algorithm from Arm's optimized-routines,
 * LGPL-2.1-or-later; TOINT_INTRINSICS, so POWF_SCALE 32 and round), its
 * tables and its arithmetic in the same order, two lanes of double at a
 * time. Checked against the console's powf over every positive float for
 * the curve's two exponents, with denormals flushed as the engine runs:
 * bit-identical. A lane whose x is not a positive normal float, or whose
 * y log2 x is past +-126 (where glibc turns to its overflow and underflow
 * cases), takes powf itself; x = 0 gives 0, as powf does for y > 0. */
static const double LE_POWF_INVC[16] = {
    0x1.661ec79f8f3bep+0, 0x1.571ed4aaf883dp+0, 0x1.49539f0f010bp+0,
    0x1.3c995b0b80385p+0, 0x1.30d190c8864a5p+0, 0x1.25e227b0b8eap+0,
    0x1.1bb4a4a1a343fp+0, 0x1.12358f08ae5bap+0, 0x1.0953f419900a7p+0,
    0x1p+0,               0x1.e608cfd9a47acp-1, 0x1.ca4b31f026aap-1,
    0x1.b2036576afce6p-1, 0x1.9c2d163a1aa2dp-1, 0x1.886e6037841edp-1,
    0x1.767dcf5534862p-1};
static const double LE_POWF_LOGC[16] = { /* times POWF_SCALE */
    -0x1.efec65b963019p-2 * 32, -0x1.b0b6832d4fca4p-2 * 32,
    -0x1.7418b0a1fb77bp-2 * 32, -0x1.39de91a6dcf7bp-2 * 32,
    -0x1.01d9bf3f2b631p-2 * 32, -0x1.97c1d1b3b7afp-3 * 32,
    -0x1.2f9e393af3c9fp-3 * 32, -0x1.960cbbf788d5cp-4 * 32,
    -0x1.a6f9db6475fcep-5 * 32, 0x0p+0 * 32,
    0x1.338ca9f24f53dp-4 * 32,  0x1.476a9543891bap-3 * 32,
    0x1.e840b4ac4e4d2p-3 * 32,  0x1.40645f0c6651cp-2 * 32,
    0x1.88e9c2c1b9ff8p-2 * 32,  0x1.ce0a44eb17bccp-2 * 32};
static const double LE_POWF_A[5] = {
    0x1.27616c9496e0bp-2 * 32, -0x1.71969a075c67ap-2 * 32,
    0x1.ec70a6ca7baddp-2 * 32, -0x1.7154748bef6c8p-1 * 32,
    0x1.71547652ab82bp0 * 32};
/* 2^(i/32) as tab[i] + (i << 47), glibc's __exp2f_data.tab */
static const uint64_t LE_EXP2F_TAB[32] = {
    0x3ff0000000000000, 0x3fefd9b0d3158574, 0x3fefb5586cf9890f,
    0x3fef9301d0125b51, 0x3fef72b83c7d517b, 0x3fef54873168b9aa,
    0x3fef387a6e756238, 0x3fef1e9df51fdee1, 0x3fef06fe0a31b715,
    0x3feef1a7373aa9cb, 0x3feedea64c123422, 0x3feece086061892d,
    0x3feebfdad5362a27, 0x3feeb42b569d4f82, 0x3feeab07dd485429,
    0x3feea47eb03a5585, 0x3feea09e667f3bcd, 0x3fee9f75e8ec5f74,
    0x3feea11473eb0187, 0x3feea589994cce13, 0x3feeace5422aa0db,
    0x3feeb737b0cdc5e5, 0x3feec49182a3f090, 0x3feed503b23e255d,
    0x3feee89f995ad3ad, 0x3feeff76f2fb5e47, 0x3fef199bdd85529c,
    0x3fef3720dcef9069, 0x3fef5818dcfba487, 0x3fef7c97337b9b5f,
    0x3fefa4afa2a490da, 0x3fefd0765b6e4540};
static const double LE_EXP2F_C[3] = { /* glibc's poly_scaled */
    0x1.c6af84b912394p-5 / 32 / 32 / 32, 0x1.ebfce50fac4f3p-3 / 32 / 32,
    0x1.62e42ff0c52d6p-1 / 32};

/* glibc's log2_inline and exp2_inline on two lanes of positive normal
 * [ix]: x^y as a double; [far] gets the lanes where y log2 x is past
 * +-126. */
static inline le_d2 le_powf_d2(const uint32_t* ix, double y, int* far) {
  le_d2 invc, y0, z;
  for (int k = 0; k < 2; ++k) {
    const uint32_t tmp = ix[k] - 0x3f330000u;
    const int i = (int)((tmp >> (23 - 4)) % 16);
    const uint32_t top = tmp & 0xff800000u;
    const uint32_t iz = ix[k] - top;
    float zf;
    memcpy(&zf, &iz, sizeof(zf));
    invc[k] = LE_POWF_INVC[i];
    y0[k] = LE_POWF_LOGC[i] + (double)((int32_t)top >> (23 - 5));
    z[k] = (double)zf;
  }
  const le_d2 r = z * invc - 1;
  const le_d2 r2 = r * r;
  le_d2 v = LE_POWF_A[0] * r + LE_POWF_A[1];
  const le_d2 p = LE_POWF_A[2] * r + LE_POWF_A[3];
  const le_d2 r4 = r2 * r2;
  le_d2 q = LE_POWF_A[4] * r + y0;
  q = p * r2 + q;
  v = v * r4 + q;
  const le_d2 ylogx = y * v;
  le_d2 kd, s;
  for (int k = 0; k < 2; ++k) {
    const double e = ylogx[k];
    uint64_t u;
    memcpy(&u, &e, sizeof(u));
    far[k] = (u >> 47 & 0xffff) >= (0x40af800000000000ull >> 47); /* 126 x 32 */
    kd[k] = __builtin_round(e);
    const uint64_t ki = (uint64_t)(int64_t)kd[k];
    const uint64_t t = LE_EXP2F_TAB[ki % 32] + (ki << (52 - 5));
    double sk;
    memcpy(&sk, &t, sizeof(sk));
    s[k] = sk;
  }
  const le_d2 rr = ylogx - kd;
  const le_d2 c = LE_EXP2F_C[0] * rr + LE_EXP2F_C[1];
  const le_d2 rr2 = rr * rr;
  le_d2 e = LE_EXP2F_C[2] * rr + 1;
  e = c * rr2 + e;
  return e * s;
}

static inline le_f4 le_powf4(le_f4 x, float y) {
  uint32_t ix[4];
  memcpy(ix, &x, sizeof(ix));
  int special[4]; /* the lanes powf takes */
  uint32_t jx[4];
  for (int k = 0; k < 4; ++k) {
    special[k] = ix[k] - 0x00800000u >= 0x7f800000u - 0x00800000u;
    jx[k] = special[k] ? 0x3f800000u : ix[k];
  }
  int far[4];
  const le_d2 lo = le_powf_d2(jx, (double)y, far);
  const le_d2 hi = le_powf_d2(jx + 2, (double)y, far + 2);
  le_f4 out = __builtin_shufflevector(__builtin_convertvector(lo, le_f2),
                                      __builtin_convertvector(hi, le_f2), 0, 1,
                                      2, 3);
  for (int k = 0; k < 4; ++k) {
    if (ix[k] == 0) {
      out[k] = 0.0f;
    } else if (special[k] || far[k]) {
      out[k] = powf(x[k], y);
    }
  }
  return out;
}

/* The curve on four lanes of [x], at gain [g]: lane by lane the arithmetic
 * of the scalar curve it replaced (#1755), with the console's powf
 * (le_powf4), so bit-identical there. */
static inline le_f4 le_dist_curve4(le_f4 x, float g) {
  const le_f4 u = g * x;
  const le_f4 au = LE_DIST_ALPHA * u;
  const le_f4 w = u + LE_DIST_ALPHA * u * u / (1.0f + au * au);
  const le_f4 c = le_f4_sel(w > 0.0f,
                            (le_f4){LE_DIST_UP, LE_DIST_UP, LE_DIST_UP, LE_DIST_UP},
                            (le_f4){LE_DIST_DOWN, LE_DIST_DOWN, LE_DIST_DOWN,
                                    LE_DIST_DOWN});
  const le_f4 a = (le_f4)((le_i4)(w / c) & 0x7fffffff);
  const le_f4 d =
      le_powf4(1.0f + le_powf4(a, LE_DIST_KNEE), 1.0f / LE_DIST_KNEE);
  return w / d;
}

/* Both channels together (#1755): the oversampler in lanes (le_os4) and
 * the curve four samples at a time. */
static void fx_distortion_kprocess(void* ks, float* l, float* r) {
  le_fx_distortion* q = (le_fx_distortion*)ks;
  const float g = le_fx_glide_next(&q->g);
  const float level = le_fx_glide_next(&q->level);
  float io[2];
  le_f4 p[1 << (LE_OS_MAX_STAGES - 1)];
  const int m = le_os4_up(&q->os, fx_sanitize(*l), fx_sanitize(*r), p);
  for (int i = 0; i < m; ++i) p[i] = le_dist_curve4(p[i], g);
  le_os4_down(&q->os, p, &io[0], &io[1]);
  le_hb4_tick(&q->hb, q->ph, &io[0], &io[1]);
  for (int ch = 0; ch < 2; ++ch) {
    float v = io[ch];
    for (int s = 0; s < LE_DIST_SECTIONS; ++s) {
      v = le_biquad_tick(q->cab[s], q->z[s][ch][q->ph], v);
    }
    /* The tone shelf, skipped while flat (the Studio Rack's, and the
     * default); its memory clears so it starts clean when it comes back. */
    if (q->shelf_on) {
      v = le_biquad_tick(q->shelf, q->z[LE_DIST_SECTIONS][ch][q->ph], v);
    }
    io[ch] = level * v;
  }
  if (++q->ph >= q->nph) q->ph = 0;
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
 *   the high-pass's 1.035 at 1 kHz taken out). The Looper X's output
 *   carries the rectifier's DC (here up to -11 dBFS at Drive 100 %); a
 *   LE_VIN_DC_HZ high-pass after the copy takes it out of what plays
 *   (#1547, the owner's call, a departure from the capture), so bypassing
 *   the vinyl never steps by it. The limiter below still reads the copy
 *   with its DC, so its gain, and every level the capture fitted, stay
 *   as they were;
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
#define LE_VIN_DRY 0.5f
#define LE_VIN_RECT 3.75f   /* the rectifier at 100 % drive, x drive^2 */
#define LE_VIN_SQUARE 4.3f  /* the square law, x the rectifier */
#define LE_VIN_SPLIT_Q 1.1
#define LE_VIN_DC_HZ 5.0 /* the DC blocker, as the amp's coupling */
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
  le_os os; /* the copy's oversampling: its high-pass runs inside it */
  le_os os_dry; /* the dry share's way down, in step with the copy's */
  float dc_b0, dc_a1; /* the DC blocker after the copy */
  float z_dc[2][2];
} le_fx_vinyl;

static void fx_vinyl_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                            int f) {
  le_fx_vinyl* v = (le_fx_vinyl*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  const float k = settle ? 1.0f : h->k;
  if (settle) {
    const uint32_t seed = le_fx_kind_seed(ks);
    v->rng[0] = seed | 1u;
    v->rng[1] = (seed * 2654435761u) | 1u;
    v->rng_shared = (seed * 40503u + 0x9E3779B9u) | 1u;
    v->lim = 1.0f;
  }
  if (f & LE_FX_DYN_NEW_RATE) {
    le_os_design(&v->os, rate, le_os_stages(LE_FX_VINYL, rate));
    v->os_dry = v->os; /* the same filters, its own (cleared) state */
    memset(v->z_hp, 0, sizeof(v->z_hp));
    le_amp_hp1(LE_VIN_DC_HZ, rate, &v->dc_b0, &v->dc_a1);
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
    le_eq_design(LE_EQ_LOWCUT, exp2((double)v->hz_l2), 0.0, LE_VIN_SPLIT_Q,
                 rate << v->os.stages, c);
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
  h->moving = moving;
}

static void fx_vinyl_kprocess(void* ks, float* l, float* r) {
  le_fx_vinyl* v = (le_fx_vinyl*)ks;
  const float c = le_fx_glide_next(&v->gain);
  const float n = le_fx_glide_next(&v->noise);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  float det[2]; /* what the limiter reads: the output with the copy's DC */
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
    /* The dry share goes up and down too, on its own way down, so it stays
     * in step with the copy while only the copy is DC-blocked. */
    float os[1 << LE_OS_MAX_STAGES], dry[1 << LE_OS_MAX_STAGES];
    const int m = le_os_up(&v->os, ch, io[ch], os);
    for (int i = 0; i < m; ++i) {
      const float x = os[i];
      const float hcopy = le_biquad_tick(v->hp, v->z_hp[ch], x);
      dry[i] = LE_VIN_DRY * x;
      os[i] = c * (fabsf(hcopy) + LE_VIN_SQUARE * hcopy * hcopy);
    }
    const float copy = le_os_down(&v->os, ch, os);
    const float through = le_os_down(&v->os_dry, ch, dry);
    /* The limiter reads the copy with its DC, as fitted; what it scales is
     * the copy without it. */
    float d = through + copy;
    float y = through + le_amp_hp1_tick(v->dc_b0, v->dc_a1, v->z_dc[ch], copy);
    if (n > 0.0f) {
      float bed = n * (shared + LE_VIN_OWN * v->hiss * le_noise(&v->rng[ch]));
      if (!v->tone_open) bed = le_biquad_tick(v->tone, v->z_tone[ch], bed);
      y += bed;
      d += bed;
    }
    io[ch] = y;
    det[ch] = d;
  }
  /* The limiter: the peak follows the louder side at once and falls back
   * through its release; the gain drops to the ceiling at once and rises
   * through its own. */
  const float a0 = fabsf(det[0]);
  const float a1 = fabsf(det[1]);
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
 * - the mix crossfades dry to held (0 % bit-exact dry at 44.1 and 48 kHz).
 * At 96 kHz all of it runs at 48 kHz between two half-bands
 * (le_deg_halved), 27 frames (0.28 ms) late, so it holds and images as at
 * 48 kHz.
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
#define LE_DEG_RATIO 0.194  /* the corner over the hold, at 0 % */
#define LE_DEG_RATIO_MID 0.89 /* at 50 % */
#define LE_DEG_Q1 0.91
#define LE_DEG_Q2 1.83

#define LE_DEG_FIR_M 22     /* the way down's half-length and delay (even) */
#define LE_DEG_FIR_BETA 5.65 /* its Kaiser window */
#define LE_DEG_HIST 64       /* its history, a power of two past 2 M + 1 */

typedef struct le_fx_degrade {
  le_fx_glide step; /* the hold's phase step per sample (1: every sample) */
  le_fx_glide mix;
  float lp_l2, lp_tgt; /* the low-pass corner, log2 Hz */
  double ph;
  float held[2];
  le_fx_glide amount; /* 1 filtering, 0 off (filter at 100 %) */
  float c1[5], c2[5];
  float z1[2][2], z2[2][2];
  /* At 96 kHz the kernel runs at 48 kHz (le_deg_halved): each pair of
   * frames goes down through a linear-phase half-band (le_deg_down), and
   * its one output back up through the oversampler's (le_os, one stage
   * over 48 kHz), played over the next pair. */
  int32_t halved, odd;
  float fir[LE_DEG_FIR_M / 2]; /* the half-band's odd taps, h[1], h[3], ... */
  float hist[2][LE_DEG_HIST];
  int32_t hpos;
  /* The glides' values (step, mix, amount) for the kernel's last
   * LE_DEG_FIR_M / 2 frames: they reach it as late as the input does. */
  float ctl[LE_DEG_FIR_M / 2][3];
  int32_t cpos;
  le_os os;
  float out2[2][2];
} le_fx_degrade;

/* Whether the Degrade runs its kernel at half the rate [sr]: at 96 kHz,
 * where per-phase holds (le_rs_phases) mixed the two phases' images
 * differently from 48 kHz's one hold (1.5 dB at 16 kHz, #1547). */
static int le_deg_halved(int sr) { return sr == 96000; }

/* The frames the Degrade delays everything at [sr]: at 96 kHz the way down
 * (LE_DEG_FIR_M), the oversampler's way up (half its le_os_latency, at
 * 48 kHz) and the pair it waits for. */
static int le_deg_latency(int sr) {
  return le_deg_halved(sr) ? LE_DEG_FIR_M + le_os_latency(sr / 2, 1) + 2 : 0;
}

/* The way down's taps into [q]: a Kaiser-windowed half-band, flat to
 * 20 kHz and 58 dB down from 28 kHz at 96 kHz. Linear phase, and its delay
 * a whole number of 48 kHz samples, so what the hold samples are the
 * input's own 48 kHz samples, as at 48 kHz: a minimum-phase way down
 * shifted them, and with them the hold's images (1.2 dB at 50 Hz). */
static void le_deg_down_design(le_fx_degrade* q) {
  const double i0b = le_bessel_i0(LE_DEG_FIR_BETA);
  double sum = 0.0;
  for (int i = 0; i < LE_DEG_FIR_M / 2; ++i) {
    const int k = 2 * i + 1;
    const double u = (double)k / (LE_DEG_FIR_M + 1);
    const double w = le_bessel_i0(LE_DEG_FIR_BETA * sqrt(1.0 - u * u)) / i0b;
    const double h = ((i & 1) ? -1.0 : 1.0) / (3.14159265358979323846 * k) * w;
    q->fir[i] = (float)h;
    sum += 2.0 * h;
  }
  /* The odd taps carry half the DC gain, the centre (1/2) the other. */
  for (int i = 0; i < LE_DEG_FIR_M / 2; ++i) q->fir[i] *= (float)(0.5 / sum);
}

/* Channel [ch]'s way down, its newest frame just written: the 48 kHz
 * sample LE_DEG_FIR_M frames back. */
static float le_deg_down(const le_fx_degrade* q, int ch) {
  const float* x = q->hist[ch];
  const int mask = LE_DEG_HIST - 1;
  const int c = q->hpos - LE_DEG_FIR_M;
  float y = 0.5f * x[c & mask];
  for (int i = 0; i < LE_DEG_FIR_M / 2; ++i) {
    const int k = 2 * i + 1;
    y += q->fir[i] * (x[(c - k) & mask] + x[(c + k) & mask]);
  }
  return y;
}

static int fx_degrade_latency_vt(const le_fx_state* fx, int slot, int32_t type,
                                 int sr) {
  (void)fx;
  (void)slot;
  (void)type;
  return le_deg_latency(sr);
}

static void fx_degrade_update(void* ks, le_fx_dyn_head* h, const float* p,
                              int sr, int f) {
  le_fx_degrade* q = (le_fx_degrade*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int sr_in = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    q->halved = le_deg_halved(sr_in);
    q->odd = 0;
    if (q->halved) {
      le_os_design(&q->os, sr_in / 2, 1);
      le_deg_down_design(q);
    }
    memset(q->hist, 0, sizeof(q->hist));
    q->hpos = 0;
    memset(q->ctl, 0, sizeof(q->ctl));
    q->cpos = 0;
    memset(q->out2, 0, sizeof(q->out2));
  }
  /* The rate the kernel runs at: a hold at or above it holds every
   * sample. */
  const int rate = q->halved ? sr_in / 2 : sr_in;
  const float k = settle ? 1.0f : h->k;
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
    le_rate_design(LE_EQ_HIGHCUT, exp2((double)q->lp_l2), 0.0, LE_DEG_Q1, rate, c);
    for (int i = 0; i < 5; ++i) q->c1[i] = (float)c[i];
    le_rate_design(LE_EQ_HIGHCUT, exp2((double)q->lp_l2), 0.0, LE_DEG_Q2, rate, c);
    for (int i = 0; i < 5; ++i) q->c2[i] = (float)c[i];
  }
  moving |= q->lp_l2 != q->lp_tgt;
  h->moving = moving;
}

/* One frame of the kernel at its rate: [x] in, [y] out. The glides have
 * already moved for it. */
static void le_deg_tick(le_fx_degrade* q, float step, float m, float amount,
                        const float* x, float* y) {
  q->ph += (double)step;
  const int take = q->ph >= 1.0;
  if (take) q->ph -= 1.0;
  for (int ch = 0; ch < 2; ++ch) {
    if (take) q->held[ch] = x[ch];
    float wet = q->held[ch];
    if (amount <= 0.0f) {
      /* No filter: its memory cleared so it starts clean when it comes
       * back. */
      q->z1[ch][0] = q->z1[ch][1] = q->z2[ch][0] = q->z2[ch][1] = 0.0f;
    } else {
      const float lp =
          le_biquad_tick(q->c2, q->z2[ch], le_biquad_tick(q->c1, q->z1[ch], wet));
      wet = amount >= 1.0f ? lp : wet + amount * (lp - wet);
    }
    y[ch] = x[ch] + m * (wet - x[ch]);
  }
}

static void fx_degrade_kprocess(void* ks, float* l, float* r) {
  le_fx_degrade* q = (le_fx_degrade*)ks;
  const float step = le_fx_glide_next(&q->step);
  const float m = le_fx_glide_next(&q->mix);
  const float amount = le_fx_glide_next(&q->amount);
  const float x[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  if (!q->halved) {
    float y[2];
    le_deg_tick(q, step, m, amount, x, y);
    *l = y[0];
    *r = y[1];
    return;
  }
  /* Halved: the pair's first frame waits; on its second the kernel runs
   * once, and its output comes back up for the next pair. The input reaches
   * the kernel LE_DEG_FIR_M / 2 of its frames late, and so do the glides,
   * so it runs exactly as at 48 kHz, that much later: the hold takes the
   * same samples (its images depend on where they fall). */
  const int i = q->odd;
  q->hpos = (q->hpos + 1) & (LE_DEG_HIST - 1);
  q->hist[0][q->hpos] = x[0];
  q->hist[1][q->hpos] = x[1];
  *l = q->out2[0][i];
  *r = q->out2[1][i];
  q->odd = !i;
  if (i == 0) return;
  float xd[2], yd[2];
  for (int ch = 0; ch < 2; ++ch) xd[ch] = le_deg_down(q, ch);
  float* c = q->ctl[q->cpos];
  const float was[3] = {c[0], c[1], c[2]};
  c[0] = step;
  c[1] = m;
  c[2] = amount;
  q->cpos = q->cpos + 1 < LE_DEG_FIR_M / 2 ? q->cpos + 1 : 0;
  le_deg_tick(q, was[0], was[1], was[2], xd, yd);
  for (int ch = 0; ch < 2; ++ch) le_os_up(&q->os, ch, yd[ch], q->out2[ch]);
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
  float cor[5];      /* after the ladder: its 48 kHz response (le_rate_design) */
  float cor_inc[5];  /* its step a frame toward the update's, while g_n runs */
  float z_cor[2][2];
  int32_t cor_on;    /* whether the rate has a correction (44.1 kHz) */
  /* At 96 kHz the kernel runs at 48 kHz (le_lpf_halved): each pair of
   * frames goes down through the oversampler's half-band, and its one
   * output back up, played over the next pair. A nonlinear ladder cannot
   * run as two interleaved 48 kHz ones (le_rs_phases): oscillating, each
   * would settle at its own phase. */
  int32_t halved, odd;
  le_os os;
  float in2[2][2], out2[2][2];
} le_fx_lpf;

/* Whether the LPF runs its kernel at half the rate [sr]: at 96 kHz. */
static int le_lpf_halved(int sr) { return sr == 96000; }

/* The frames the LPF delays everything at [sr]: at 96 kHz the half-band's
 * way down and up (le_os_latency, at 48 kHz) and the pair it waits for. */
static int le_lpf_latency(int sr) {
  return le_lpf_halved(sr) ? 2 * le_os_latency(sr / 2, 1) + 2 : 0;
}

static int fx_lpf_latency_vt(const le_fx_state* fx, int slot, int32_t type,
                             int sr) {
  (void)fx;
  (void)slot;
  (void)type;
  return le_lpf_latency(sr);
}

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

static void fx_lpf_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                          int f) {
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
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const float k = settle ? 1.0f : h->k;
  if (settle) q->s[0][0] = q->s[1][0] = LE_LPF_SEED;
  if (f & LE_FX_DYN_CHANGED) {
    const double v = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : p[1];
    const double ratio = LE_LPF_FC_LO + (LE_LPF_FC_HI - LE_LPF_FC_LO) * v;
    q->tgt = (float)log2(ratio * le_fx_desc_value(&LE_FX_LPF_PARAMS[0], p[0]));
    q->ktgt = (float)(LE_LPF_K0 + LE_LPF_K1 * pow(v, LE_LPF_K_POW));
  }
  /* The rate the kernel runs at. */
  const int kr = le_lpf_halved(sr) ? sr / 2 : sr;
  /* Kernel frames to the next update. */
  const int ticks = le_lpf_halved(sr) ? LE_FX_UPDATE_FRAMES / 2 : LE_FX_UPDATE_FRAMES;
  if (f & LE_FX_DYN_NEW_RATE) {
    q->halved = le_lpf_halved(sr);
    q->odd = 0;
    if (q->halved) le_os_design(&q->os, kr, 1);
    memset(q->in2, 0, sizeof(q->in2));
    memset(q->out2, 0, sizeof(q->out2));
    memset(q->s, 0, sizeof(q->s));
    q->s[0][0] = q->s[1][0] = LE_LPF_SEED;
    q->sh[0] = q->sh[1] = 0.0f;
    memset(q->z_cor, 0, sizeof(q->z_cor));
    q->cor_on = sr == 44100;
    const double gh = le_prewarp(LE_LPF_HP_HZ, kr);
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
    const double hz = exp2((double)(q->l2 + q->lfo));
    const double g = le_prewarp(hz, kr);
    const double G = g / (1.0 + g);
    double c[5];
    le_ladder_correction(hz, (double)q->k, sr, c);
    if (settle || (f & LE_FX_DYN_NEW_RATE)) {
      le_lpf_coefs(q, G);
      q->g_inc = 0.0f;
      q->g_n = 0;
    } else {
      /* The samples up to the next update ramp G onto it, and the
       * correction with it. */
      q->g_inc = (float)((G - (double)q->g) / (double)ticks);
      q->g_n = ticks;
      if (q->g + q->g_inc == q->g) { /* closer than a step can show */
        le_lpf_coefs(q, G);
        q->g_inc = 0.0f;
        q->g_n = 0;
      }
    }
    for (int i = 0; i < 5; ++i) {
      q->cor_inc[i] =
          q->g_n > 0 ? (float)((c[i] - (double)q->cor[i]) / q->g_n) : 0.0f;
      if (q->g_n == 0) q->cor[i] = (float)c[i];
    }
  }
  const int moving = le_fx_glide_step(&q->amount, p[0] >= 1.0f ? 0.0f : 1.0f, k);
  h->moving = moving || q->l2 != q->tgt || q->k != q->ktgt || sweeping ||
                q->lfo != 0.0f || q->g_n > 0;
}

static void fx_lpf_beat(void* ks, double beat) {
  ((le_fx_lpf*)ks)->beat = beat;
}

/* One frame of the kernel at its rate, [io] in and out. */
static void le_lpf_tick(le_fx_lpf* q, float amount, float* io) {
  if (amount <= 0.0f) {
    /* Off: the identity, with the filter's memory cleared (but for the
     * seed) so it starts clean when it comes back, and any ramp of G
     * landed so the updates go idle. */
    if (q->g_n > 0) {
      le_lpf_coefs(q, (double)(q->g + q->g_inc * (float)q->g_n));
      for (int i = 0; i < 5; ++i) q->cor[i] += q->cor_inc[i] * (float)q->g_n;
      q->g_inc = 0.0f;
      q->g_n = 0;
    }
    memset(q->s, 0, sizeof(q->s));
    memset(q->z_cor, 0, sizeof(q->z_cor));
    q->s[0][0] = q->s[1][0] = LE_LPF_SEED;
    q->sh[0] = q->sh[1] = 0.0f;
    return;
  }
  if (q->g_n > 0) {
    le_lpf_coefs(q, (double)(q->g + q->g_inc));
    for (int i = 0; i < 5; ++i) q->cor[i] += q->cor_inc[i];
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
    if (q->cor_on) u = le_biquad_tick(q->cor, q->z_cor[ch], u);
    io[ch] = amount >= 1.0f ? u : io[ch] + amount * (u - io[ch]);
  }
}

static void fx_lpf_kprocess(void* ks, float* l, float* r) {
  le_fx_lpf* q = (le_fx_lpf*)ks;
  const float amount = le_fx_glide_next(&q->amount);
  float io[2] = {fx_sanitize(*l), fx_sanitize(*r)};
  if (!q->halved) {
    le_lpf_tick(q, amount, io);
    *l = io[0];
    *r = io[1];
    return;
  }
  /* Halved: the pair's first frame waits; on its second the kernel runs
   * once, and its output comes back up for the next pair. */
  const int i = q->odd;
  q->in2[0][i] = io[0];
  q->in2[1][i] = io[1];
  *l = q->out2[0][i];
  *r = q->out2[1][i];
  q->odd = !i;
  if (i == 0) return;
  float x[2];
  for (int ch = 0; ch < 2; ++ch) x[ch] = le_os_down(&q->os, ch, q->in2[ch]);
  le_lpf_tick(q, amount, x);
  for (int ch = 0; ch < 2; ++ch) le_os_up(&q->os, ch, x[ch], q->out2[ch]);
}

/* ---- Spring (LE_FX_SPRING, #887 part 8) ----
 *
 * Fit to the captures of the Guitar Rack's Spring at Mix 28.9 % (#891: s3/6
 * and s3/7 at Time 2 and 8 s, and s16spring at every whole second from 1 to
 * 10 s, the steps the Looper X's Time takes; #1547):
 * - the tank is one recirculating spring: its echo returns every 38.0 ms
 *   (the envelope's autocorrelation peak in both), dispersed on each trip by
 *   a chain of twelve first-order all-passes;
 * - Time is a whole number of seconds, rounded, as the device steps it (bar
 *   0.90, 7.94 s by the taper, plays 8 s);
 * - the decay: each trip loses LE_SPR_TIME's loss at the Time, 0.45 dB more
 *   above 1.2 kHz and its low gain less below 400 Hz (first-order shelves
 *   in the loop). Read on the impulse responses in windows a trip long, from
 *   0.3 to 1.0 s, broadband and in four bands from 200 Hz to 4 kHz, it is
 *   within 2 % of the captures broadband at every Time and within 10 % in
 *   each band (the 1-2 kHz band the furthest, 9 % short at 10 s). 20 ms
 *   windows alternate between the echoes and the near-silence between them:
 *   they read the earlier tank at 8 s as 5.89 s, 43 % over its 4.12;
 * - the wet sound is band-limited, 200 Hz to a steep edge near 4 kHz
 *   (-46 dB at 4.7 kHz, -96 dB at 7.2 kHz): nine sections fitted to the
 *   impulse response's spectrum within 1.7 dB rms from 100 Hz to 7.3 kHz;
 * - the mix law is the chorus's (dry 1 - 0.29 mix; the capture's dry gain
 *   was 0.9165 at 28.9 %), and the wet level is LE_SPR_TIME's at the Time,
 *   times the mix: fitted so the wet energy over the impulse response's
 *   first second, against the dry, is the capture's at every whole second
 *   (-18.1 dB at 1 s to -17.1 dB at 10 s, the rise all from the longer
 *   tail; #1576).
 * A known difference: successive echoes repeat more closely (envelope
 * autocorrelation 0.87 at 38 ms against the capture's 0.4). Both channels
 * take the tank's mono output (the capture's correlated at 0.996). */
static const le_fx_param_desc LE_FX_SPRING_PARAMS[] = {
    {"time", LE_FX_UNIT_SECONDS, 0, 1.0f, 10.0f, LE_FX_CURVE_EXPONENTIAL,
     0.30103f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
};
#define LE_SPR_RING 4096u /* holds the 38 ms trip up to 107 kHz */
#define LE_SPR_TRIP_S 0.038
#define LE_SPR_STAGES 12
#define LE_SPR_DISPERSION_HZ 1500.0
#define LE_SPR_LOSS_HZ 1200.0
#define LE_SPR_LOSS_SHELF 0.949511f /* -0.45 dB per trip above it */
#define LE_SPR_LOW_HZ 400.0
#define LE_SPR_DRY_DROP 0.29f
#define LE_SPR_SECTIONS 9

/* At each whole second of Time from 1 to 10 s: the dB a trip loses, the dB
 * it keeps more below LE_SPR_LOW_HZ, and the wet gain at 100 % mix. */
static const struct {
  double loss_db, low_db, wet;
} LE_SPR_TIME[10] = {
    {1.5925, 0.0000, 0.3496}, {1.0904, 0.0000, 0.3075},
    {0.8372, 0.0000, 0.2819}, {0.6768, 0.0231, 0.2637},
    {0.5571, 0.0330, 0.2491}, {0.4629, 0.0409, 0.2371},
    {0.3854, 0.0470, 0.2271}, {0.3199, 0.0522, 0.2184},
    {0.2631, 0.0563, 0.2097}, {0.2129, 0.0595, 0.2026},
};

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
  le_fx_glide gain; /* the loop's gain per trip */
  le_fx_glide low;  /* its gain below LE_SPR_LOW_HZ, over it */
  le_fx_glide dry;
  le_fx_glide wet;
  float gain_tgt;   /* the targets, recomputed when the settings change */
  float low_tgt;
  float wet_tgt;
  double trip_scale; /* the trip held, over the 38 ms one (1 below 107 kHz) */
  float ap;         /* the all-passes' coefficient */
  float loss_g1;
  float low_g1;
  uint32_t trip;    /* the delay line's samples */
  float shape[LE_SPR_SECTIONS][5];
  /* the filters' states per phase: at 96 kHz the tank is the 48 kHz one on
   * alternate samples (le_rs_phases), its trip twice the 48 kHz one's */
  float z[LE_SPR_SECTIONS][LE_RS_PH][2];
  float ap_z[LE_RS_PH][LE_SPR_STAGES];
  float loss_s[LE_RS_PH];
  float low_s[LE_RS_PH];
  int32_t ph, nph;
  /* At rates other than 48 and 96 kHz, the trip's fraction of a sample: a
   * first-order all-pass delaying low frequencies by it (frac_on). */
  float frac_ap, frac_z[2];
  int32_t frac_on;
  le_hb hb; /* at 96 kHz, the input under 24 kHz (le_hb) */
  uint32_t w;
  float ring[LE_SPR_RING];
} le_fx_spring;

static void fx_spring_update(void* ks, le_fx_dyn_head* h, const float* p,
                             int sr, int f) {
  le_fx_spring* q = (le_fx_spring*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    /* A rate change makes the ring's samples another rate's: start clean
     * (a fresh block is already clear). */
    if (!settle) {
      memset(q->ring, 0, sizeof(q->ring));
      memset(q->z, 0, sizeof(q->z));
      memset(q->ap_z, 0, sizeof(q->ap_z));
      memset(q->loss_s, 0, sizeof(q->loss_s));
      memset(q->low_s, 0, sizeof(q->low_s));
      memset(q->frac_z, 0, sizeof(q->frac_z));
    }
    le_hb_design(&q->hb, rate);
    q->nph = le_rs_phases(rate);
    q->ph = 0;
    const int drate = le_rs_design_rate(rate);
    for (int s = 0; s < LE_SPR_SECTIONS; ++s) {
      double c[5];
      le_rate_design(LE_SPR_SHAPE[s].kind, LE_SPR_SHAPE[s].hz, LE_SPR_SHAPE[s].db,
                     LE_SPR_SHAPE[s].q, rate, c);
      for (int i = 0; i < 5; ++i) q->shape[s][i] = (float)c[i];
    }
    const double t = le_prewarp(LE_SPR_DISPERSION_HZ, drate);
    const double a = (1.0 - t) / (1.0 + t);
    q->ap = (float)a;
    q->loss_g1 = le_onepole_g1(LE_SPR_LOSS_HZ, drate);
    q->low_g1 = le_onepole_g1(LE_SPR_LOW_HZ, drate);
    /* The loop's delay at low frequencies is the 48 kHz tank's: its whole
     * trip (38 ms less the all-passes' delay, rounded) and its all-passes.
     * At 96 kHz the trip is twice that, so each phase runs the 48 kHz tank;
     * at other rates the delay is no whole number of samples, so a 13th
     * first-order all-pass takes the fraction (0.5 to 1.5 samples), where a
     * rounded trip drifted the echoes against 48 kHz's by a millisecond
     * over three seconds (#1547). */
    const double t48 = le_prewarp(LE_SPR_DISPERSION_HZ, 48000);
    const double a48 = (1.0 - t48) / (1.0 + t48);
    const double ap48 = LE_SPR_STAGES * (1.0 - a48) / (1.0 + a48);
    const double trip48 = floor(LE_SPR_TRIP_S * 48000.0 - ap48 + 0.5);
    const double loop_s = (trip48 + ap48) / 48000.0;
    double want;
    q->frac_on = drate != 48000;
    if (q->frac_on) {
      uint32_t n;
      le_frac_split(loop_s * rate - LE_SPR_STAGES * (1.0 - a) / (1.0 + a), &n,
                    &q->frac_ap);
      want = (double)n;
    } else {
      want = q->nph * trip48;
    }
    double trip = want;
    /* Past 107 kHz the trip outgrows the ring: hold it there and scale the
     * loss per trip, so the decay stays right though the echo shortens. */
    if (trip > (double)(LE_SPR_RING - 1u)) trip = (double)(LE_SPR_RING - 1u);
    if (trip < 1.0) trip = 1.0;
    q->trip = (uint32_t)trip;
    q->trip_scale = want > 1.0 ? (double)q->trip / want : 1.0;
  }
  const float m = p[1] < 0.0f ? 0.0f : p[1] > 1.0f ? 1.0f : p[1];
  if (f & LE_FX_DYN_CHANGED) {
    /* Time in whole seconds, as the Looper X steps it (a NaN reads as 1 s). */
    const double t = le_fx_desc_value(&LE_FX_SPRING_PARAMS[0], p[0]);
    const int i = !(t >= 1.5) ? 0 : !(t < 9.5) ? 9 : (int)(t + 0.5) - 1;
    q->gain_tgt =
        (float)pow(10.0, -LE_SPR_TIME[i].loss_db * q->trip_scale / 20.0);
    q->low_tgt = (float)pow(10.0, LE_SPR_TIME[i].low_db * q->trip_scale / 20.0);
    q->wet_tgt = (float)LE_SPR_TIME[i].wet;
  }
  const float k = settle ? 1.0f : h->k;
  int moving = le_fx_glide_step(&q->gain, q->gain_tgt, k);
  moving |= le_fx_glide_step(&q->low, q->low_tgt, k);
  moving |= le_fx_glide_step(&q->dry, 1.0f - LE_SPR_DRY_DROP * m, k);
  moving |= le_fx_glide_step(&q->wet, q->wet_tgt * m, k);
  h->moving = moving;
}

static void fx_spring_kprocess(void* ks, float* l, float* r) {
  le_fx_spring* q = (le_fx_spring*)ks;
  const float g = le_fx_glide_next(&q->gain);
  const float lowk = le_fx_glide_next(&q->low);
  const float dry = le_fx_glide_next(&q->dry);
  const float wet = le_fx_glide_next(&q->wet);
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  const int ph = q->ph;
  if (++q->ph >= q->nph) q->ph = 0;
  float s = le_hb_tick(&q->hb, 0, ph, 0.5f * (x0 + x1));
  for (int i = 0; i < LE_SPR_SECTIONS; ++i) {
    s = le_biquad_tick(q->shape[i], q->z[i][ph], s);
  }
  const uint32_t at = q->w & (LE_SPR_RING - 1u);
  /* The delayed trip: written trip samples ago. */
  float u = s + g * q->ring[(q->w - q->trip) & (LE_SPR_RING - 1u)];
  float* apz = q->ap_z[ph];
  for (int i = 0; i < LE_SPR_STAGES; ++i) {
    const float y = q->ap * u + apz[i];
    apz[i] = u - q->ap * y;
    u = y;
  }
  if (q->frac_on) u = le_frac_tick(q->frac_ap, q->frac_z, u);
  if (lowk != 1.0f) u += (lowk - 1.0f) * le_onepole_lp(&q->low_s[ph], q->low_g1, u);
  u += (LE_SPR_LOSS_SHELF - 1.0f) *
       (u - le_onepole_lp(&q->loss_s[ph], q->loss_g1, u));
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
/* le_vb_network runs the lines as two groups of four, one a ring. */
_Static_assert(LE_VB_LINES == 8, "the network's lines are two vectors of four");
#define LE_VB_APS 6 /* the most diffusers a side runs (the Dub reverbs run 2) */
#define LE_VB_TN 10
#define LE_VB_WN 7

typedef struct {
  double pd_ms[2];
  int aps; /* diffusers a side runs (0: 2) */
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
  double lg[LE_VB_TN];  /* a room's late gain at tv (0: none, 1 throughout) */
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

typedef struct le_fx_verb {
  le_fx_glide dry;
  le_fx_glide wet;
  const le_verb_def* def;
  uint32_t need[2]; /* the samples each ring must hold */
  uint32_t hist_n;
  uint32_t pd[2];
  uint32_t tap[2];
  int aps;
  uint32_t ap_n[2][LE_VB_APS];
  uint32_t ap_off[2][LE_VB_APS];
  uint32_t line_n[LE_VB_LINES];
  uint32_t line_off[LE_VB_LINES]; /* lines 0-3 in ring 0, 4-7 in ring 1 */
  uint32_t hist_w;
  uint32_t ap_w[2][LE_VB_APS];
  uint32_t line_w[LE_VB_LINES];
  /* Whether each structure has wrapped since the block was cleared: before
   * that, a read returns silence, not what the ring held. A line's flag is
   * all ones once it has (a lane mask); lines_full once every line has. */
  uint8_t hist_full;
  uint8_t ap_full[2][LE_VB_APS];
  uint32_t line_full[LE_VB_LINES];
  uint32_t lines_full;
  float dec;        /* Dec, gliding toward the setting */
  float dec_design; /* the Dec the lines were last designed for (-1: none) */
  /* Per rate: the line shelves' prewarped corners (lo, hi) and the anchors'
   * cos and sin (125 Hz, 1 kHz, 8 kHz), so a redesign calls no trig. */
  double warp[2];
  double anchor[3][2];
  /* The lines' gains and first-order shelves (b0, b1, a1), each
   * coefficient of the eight lines together, so four lines run as one
   * vector (engine_fx_simd.h). */
  float gm[LE_VB_LINES];
  float lo[3][LE_VB_LINES];
  float hi[3][LE_VB_LINES];
  /* The filters' states per phase: at 96 kHz the network is the 48 kHz one
   * on alternate samples (le_rs_phases), every length twice its 48 kHz
   * one. */
  float lo_z[LE_RS_PH][2][LE_VB_LINES]; /* x1, y1 */
  float hi_z[LE_RS_PH][2][LE_VB_LINES];
  /* The def's injection signs times its late gain, and its output signs. */
  float cin_g[LE_VB_LINES];
  float cl[LE_VB_LINES];
  float cr[LE_VB_LINES];
  float shelf[3];
  float shelf_z[2][LE_RS_PH][2];
  float peak[5];
  float peak_z[2][LE_RS_PH][2];
  float tail_z[LE_RS_PH];
  float tail_p; /* the def's tail pole at the rate (its 48 kHz time) */
  int32_t ph, nph;
  /* At rates other than 48 and 96 kHz a line's 48 kHz length is no whole
   * number of samples: each runs short and a first-order all-pass delays
   * it by the rest (frac_on; le_vb_geometry). line_d is each line's
   * delay. */
  int32_t frac_on;
  float frac_a[LE_VB_LINES];
  float frac_z[2][LE_VB_LINES]; /* x1, y1 */
  float ap_fa[2][LE_VB_APS]; /* the diffusers' likewise */
  float ap_fz[2][LE_VB_APS][2];
  double line_d[LE_VB_LINES];
  le_hb hb; /* at 96 kHz, the input under 24 kHz (le_hb) */
  float late_k;  /* the late network's output gain (1 but for the rooms) */
  float ap_g;    /* the diffusers' gain and the early part's (the def's, */
  float early_g; /* or a room's at its Density) */
  uint32_t reach;    /* the history a room's early taps read, at least */
  /* A redesign while Dec (or Length) glides ramps the lines' gains and
   * shelves to it over the LE_FX_UPDATE_FRAMES frames after, so the
   * recirculating signal never steps. */
  int32_t line_ramp;
  float gm_to[LE_VB_LINES], gm_d[LE_VB_LINES];
  float lo_to[3][LE_VB_LINES], lo_d[3][LE_VB_LINES];
  float hi_to[3][LE_VB_LINES], hi_d[3][LE_VB_LINES];
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

/* A table [y] at the def's tv points, read at [v] log-linearly between
 * them and held past the ends. */
static double le_vb_t_at(const le_verb_def* d, const double* y, double v) {
  if (v <= d->tv[0]) return y[0];
  for (int i = 1; i < d->tn; ++i) {
    if (v <= d->tv[i]) {
      const double f = (v - d->tv[i - 1]) / (d->tv[i] - d->tv[i - 1]);
      return y[i - 1] * pow(y[i] / y[i - 1], f);
    }
  }
  return y[d->tn - 1];
}

/* le_vb_shelf for four lines at once, their gains [k]: each line's b0 and
 * b1 into [b0], [b1]. Its a1 is le_vb_shelf's, the same for every line. */
static void le_vb_shelf4(double t, le_d4 k, int high, le_f4* b0, le_f4* b1) {
  const le_d4 tt = le_d4_set1(t);
  const le_d4 one = le_d4_set1(1.0);
  const le_d4 den = one + tt;
  if (high) {
    *b0 = le_f4_of((k + tt) / den);
    *b1 = le_f4_of((tt - k) / den);
  } else {
    *b0 = le_f4_of((one + k * tt) / den);
    *b1 = le_f4_of((k * tt - one) / den);
  }
}

/* le_vb_mag for four first-order sections (b0, b1 and the shared a1) at the
 * frequency whose cos and sin are [cs]. */
static le_d4 le_vb_mag4(le_f4 b0, le_f4 b1, float a1, const double cs[2]) {
  const le_d4 nr = le_d4_of(b0) + le_d4_of(b1) * le_d4_set1(cs[0]);
  const le_d4 ni = le_d4_of(-b1) * le_d4_set1(cs[1]);
  const double dr = 1.0 + a1 * cs[0], di = -a1 * cs[1];
  const le_d4 r = (nr * nr + ni * ni) / le_d4_set1(dr * dr + di * di);
  return (le_d4){sqrt(r[0]), sqrt(r[1]), sqrt(r[2]), sqrt(r[3])};
}

/* Every line's shelves and gain for the decay times [t] (s), four lines at
 * a time, each as on its own. The shelves' gains are corrected four times
 * for their leakage at the other anchors. */
static void le_vb_design_lines(le_fx_verb* q, const double t[3], int sr) {
  const double(*a)[2] = q->anchor; /* 125 Hz, 1 kHz, 8 kHz */
  float c[3];
  le_vb_shelf(q->warp[0], 1.0, 0, c);
  const float alo = c[2];
  le_vb_shelf(q->warp[1], 1.0, 1, c);
  const float ahi = c[2];
  for (int b = 0; b < LE_VB_LINES; b += 4) {
    le_d4 glo, gmid, ghi;
    for (int j = 0; j < 4; ++j) {
      const double len = q->line_d[b + j];
      glo[j] = pow(10.0, -3.0 * len / (t[0] * sr));
      gmid[j] = pow(10.0, -3.0 * len / (t[1] * sr));
      ghi[j] = pow(10.0, -3.0 * len / (t[2] * sr));
    }
    le_d4 klo = glo / gmid;
    le_d4 khi = ghi / gmid;
    le_f4 l0, l1, h0, h1;
    for (int it = 0; it < 4; ++it) {
      le_vb_shelf4(q->warp[0], klo, 0, &l0, &l1);
      le_vb_shelf4(q->warp[1], khi, 1, &h0, &h1);
      const le_d4 gm =
          gmid / (le_vb_mag4(l0, l1, alo, a[1]) * le_vb_mag4(h0, h1, ahi, a[1]));
      klo *= glo / (gm * le_vb_mag4(l0, l1, alo, a[0]) *
                    le_vb_mag4(h0, h1, ahi, a[0]));
      khi *= ghi / (gm * le_vb_mag4(l0, l1, alo, a[2]) *
                    le_vb_mag4(h0, h1, ahi, a[2]));
    }
    le_vb_shelf4(q->warp[0], klo, 0, &l0, &l1);
    le_vb_shelf4(q->warp[1], khi, 1, &h0, &h1);
    le_f4_store(q->gm + b, le_f4_of(gmid / (le_vb_mag4(l0, l1, alo, a[1]) *
                                             le_vb_mag4(h0, h1, ahi, a[1]))));
    le_f4_store(q->lo[0] + b, l0);
    le_f4_store(q->lo[1] + b, l1);
    le_f4_store(q->lo[2] + b, le_f4_set1(alo));
    le_f4_store(q->hi[0] + b, h0);
    le_f4_store(q->hi[1] + b, h1);
    le_f4_store(q->hi[2] + b, le_f4_set1(ahi));
  }
}

/* [ms] in samples at [sr]: at 96 kHz twice its 48 kHz samples, so each
 * phase runs the 48 kHz network. */
static uint32_t le_vb_at(double ms, int sr) {
  return (uint32_t)(ms * (double)le_rs_design_rate(sr) / 1000.0 + 0.5) *
         (uint32_t)le_rs_phases(sr);
}

/* le_vb_at, at least 1. */
static uint32_t le_vb_len(double ms, int sr) {
  const uint32_t n = le_vb_at(ms, sr);
  return n < 1u ? 1u : n;
}

/* The geometry at [sr]: every length, and where each stage sits in its
 * ring. */
static void le_vb_geometry(le_fx_verb* q, int sr) {
  const le_verb_def* d = q->def;
  q->aps = d->aps > 0 && d->aps <= LE_VB_APS ? d->aps : 2;
  q->pd[0] = le_vb_len(d->pd_ms[0], sr);
  q->pd[1] = le_vb_len(d->pd_ms[1], sr);
  q->tap[0] = d->tap_ms[0] > 0.0 ? le_vb_len(d->tap_ms[0], sr) : 0u;
  q->tap[1] = d->tap_ms[1] > 0.0 ? le_vb_len(d->tap_ms[1], sr) : 0u;
  uint32_t reach = q->pd[0] > q->pd[1] ? q->pd[0] : q->pd[1];
  if (q->reach > reach) reach = q->reach;
  if (q->tap[0] > reach) reach = q->tap[0];
  if (q->tap[1] > reach) reach = q->tap[1];
  q->hist_n = reach + 2u;
  /* The history is written twice, hist_n apart, so a tap reads it without
   * wrapping (le_rv_taps). */
  uint32_t at[2] = {2u * q->hist_n, 0u};
  for (int c = 0; c < 2; ++c) {
    for (int k = 0; k < q->aps; ++k) {
      if (q->frac_on) {
        le_frac_split((double)le_vb_len(d->ap_ms[c][k], 48000) * sr / 48000.0,
                      &q->ap_n[c][k], &q->ap_fa[c][k]);
      } else {
        q->ap_n[c][k] = le_vb_len(d->ap_ms[c][k], sr);
      }
      q->ap_off[c][k] = at[c];
      at[c] += q->ap_n[c][k];
    }
  }
  for (int i = 0; i < LE_VB_LINES; ++i) {
    const int c = i < LE_VB_LINES / 2 ? 0 : 1;
    if (q->frac_on) {
      /* The 48 kHz line's delay at this rate: a whole part that leaves 0.5
       * to 1.5 samples to the all-pass, whose coefficient gives it. */
      const double dl = (double)le_vb_len(d->line_ms[i], 48000) * sr / 48000.0;
      le_frac_split(dl, &q->line_n[i], &q->frac_a[i]);
      q->line_d[i] = dl;
    } else {
      q->line_n[i] = le_vb_len(d->line_ms[i], sr);
      q->line_d[i] = (double)q->line_n[i];
    }
    q->line_off[i] = at[c];
    at[c] += q->line_n[i];
  }
  q->need[0] = at[0];
  q->need[1] = at[1];
}

/* Lays [q]'s network out for [def] at [rate]: the positions start over and
 * each structure reads silence until it wraps (le_fx_verb), as after a new
 * rate, whose rings hold another rate's audio. */
static void le_vb_lay(le_fx_verb* q, const le_verb_def* def, int rate) {
  q->def = def;
  memset(q->lo_z, 0, sizeof(q->lo_z));
  memset(q->hi_z, 0, sizeof(q->hi_z));
  memset(q->shelf_z, 0, sizeof(q->shelf_z));
  memset(q->peak_z, 0, sizeof(q->peak_z));
  memset(q->tail_z, 0, sizeof(q->tail_z));
  memset(q->frac_z, 0, sizeof(q->frac_z));
  memset(q->ap_fz, 0, sizeof(q->ap_fz));
  q->nph = le_rs_phases(rate);
  q->ph = 0;
  q->frac_on = le_rs_design_rate(rate) != 48000;
  le_hb_design(&q->hb, rate);
  /* The tail's pole per sample at 48 kHz; on each phase at 96, and keeping
   * its time constant elsewhere. */
  q->tail_p = (float)pow((double)def->tail_p,
                         48000.0 / (double)le_rs_design_rate(rate));
  memset(q->ap_w, 0, sizeof(q->ap_w));
  memset(q->line_w, 0, sizeof(q->line_w));
  memset(q->ap_full, 0, sizeof(q->ap_full));
  memset(q->line_full, 0, sizeof(q->line_full));
  q->lines_full = 0;
  q->hist_full = 0;
  for (int i = 0; i < LE_VB_LINES; ++i) {
    q->cin_g[i] = (float)def->cin[i] * def->late_g;
    q->cl[i] = (float)def->cl[i];
    q->cr[i] = (float)def->cr[i];
  }
  q->hist_w = 0;
  q->dec_design = -1.0f;
  le_vb_geometry(q, rate);
  /* The filters at the rate they run at: 48 kHz at 96 (each phase). */
  const int drate = le_rs_design_rate(rate);
  q->warp[0] = le_vb_warp(def->lo_hz, drate);
  q->warp[1] = le_vb_warp(def->hi_hz, drate);
  static const double anchor_hz[3] = {125.0, 1000.0, 8000.0};
  for (int a = 0; a < 3; ++a) {
    const double w = 2.0 * LE_PI * anchor_hz[a] / (double)drate;
    q->anchor[a][0] = cos(w);
    q->anchor[a][1] = sin(w);
  }
  le_vb_shelf(le_vb_warp(def->shelf_hz, drate), def->shelf_k, 1, q->shelf);
  if (def->peak_db != 0.0) {
    double c[5];
    le_eq_design(LE_EQ_LOMID, def->peak_hz, def->peak_db, def->peak_q, drate,
                 c);
    for (int i = 0; i < 5; ++i) q->peak[i] = (float)c[i];
  }
  q->late_k = 1.0f;
  q->ap_g = def->ap_g;
  q->early_g = def->early_g;
  q->line_ramp = 0;
}

/* Dec (or Length) one smoothing step [k] toward [dec_tgt] (0..1); the
 * lines are redesigned (eight shelf pairs) only while it moves. A def with
 * a late gain table sets the late network's gain with it. */
static void le_vb_glide_dec(le_fx_verb* q, float dec_tgt, float k, int rate) {
  const le_verb_def* def = q->def;
  const int first = q->dec_design < 0.0f;
  le_fx_step_toward(&q->dec, dec_tgt, k);
  if (q->dec == q->dec_design) return;
  double t[3];
  le_vb_t(def, (double)q->dec, t);
  float gm[LE_VB_LINES], lo[3][LE_VB_LINES], hi[3][LE_VB_LINES];
  if (!first) {
    memcpy(gm, q->gm, sizeof gm);
    memcpy(lo, q->lo, sizeof lo);
    memcpy(hi, q->hi, sizeof hi);
  }
  le_vb_design_lines(q, t, rate);
  q->dec_design = q->dec;
  q->line_ramp = 0;
  if (!first) {
    /* Back to where they stood, ramping to the new design. */
    const float per = 1.0f / (float)LE_FX_UPDATE_FRAMES;
    for (int i = 0; i < LE_VB_LINES; ++i) {
      q->gm_to[i] = q->gm[i];
      q->gm_d[i] = (q->gm[i] - gm[i]) * per;
      q->gm[i] = gm[i];
      for (int j = 0; j < 3; ++j) {
        q->lo_to[j][i] = q->lo[j][i];
        q->lo_d[j][i] = (q->lo[j][i] - lo[j][i]) * per;
        q->lo[j][i] = lo[j][i];
        q->hi_to[j][i] = q->hi[j][i];
        q->hi_d[j][i] = (q->hi[j][i] - hi[j][i]) * per;
        q->hi[j][i] = hi[j][i];
      }
    }
    q->line_ramp = LE_FX_UPDATE_FRAMES;
  }
  if (def->lg[0] > 0.0) q->late_k = (float)le_vb_t_at(def, def->lg, q->dec);
}

static void fx_verb_update(void* ks, le_fx_dyn_head* h, const float* p, int sr,
                           int f, const le_verb_def* def) {
  le_fx_verb* q = (le_fx_verb*)ks;
  q->def = def;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) le_vb_lay(q, def, rate);
  const float k = settle ? 1.0f : h->k;
  /* Dec glides with the other settings' smoothing, not when Vol does. */
  const float dec_tgt = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  le_vb_glide_dec(q, dec_tgt, k, rate);
  const double vol = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : (double)p[1];
  int moving = le_fx_glide_step(&q->dry, (float)le_vb_interp(def->dry, vol), k);
  moving |= le_fx_glide_step(&q->wet, (float)le_vb_interp(LE_VB_WET, vol), k);
  moving |= q->dec != dec_tgt;
  h->moving = moving;
}

static void fx_dub_verb_update(void* ks, le_fx_dyn_head* h, const float* p,
                               int sr, int f) {
  fx_verb_update(ks, h, p, sr, f, &LE_DUB_VERB_DEF);
}
static void fx_amb_verb_update(void* ks, le_fx_dyn_head* h, const float* p,
                               int sr, int f) {
  fx_verb_update(ks, h, p, sr, f, &LE_AMB_VERB_DEF);
}

/* One sample of [q]'s network: the mono input [m] into its history, and
 * the wet left and right into [w], before any dry. The two sides'
 * diffusers run in step, and the lines four at a time (lines 0-3 share
 * ring 0, 4-7 ring 1), each exactly as on its own: the sides and the lines
 * are independent until the sums that mix them, which run in line order. */
static inline void le_vb_network(le_fx_verb* q, float* r0, float* r1, float m,
                                 float w[2]) {
  const le_verb_def* d = q->def;
  const int ph = q->ph;
  q->ph = ph + 1 < q->nph ? ph + 1 : 0;
  m = le_hb_tick(&q->hb, 0, ph, m);
  float* ring[2] = {r0, r1};
  /* The input history: the pre-delays and the strong taps read it. */
  float* hist = r0;
  hist[q->hist_w] = m;
  hist[q->hist_w + q->hist_n] = m;
  float e[2];
  float tap[2] = {0.0f, 0.0f};
  for (int c = 0; c < 2; ++c) {
    /* Before the history wraps, only the indices up to its write position
     * hold this block's input. */
    uint32_t at = q->hist_w + q->hist_n - q->pd[c];
    if (at >= q->hist_n) at -= q->hist_n;
    e[c] = q->hist_full || at <= q->hist_w ? hist[at] : 0.0f;
    if (q->tap[c] != 0u) {
      uint32_t ta = q->hist_w + q->hist_n - q->tap[c];
      if (ta >= q->hist_n) ta -= q->hist_n;
      tap[c] = q->hist_full || ta <= q->hist_w ? d->tap_g[c] * hist[ta] : 0.0f;
    }
  }
  const float apg = q->ap_g;
  for (int k = 0; k < q->aps; ++k) {
    for (int c = 0; c < 2; ++c) {
      float* b = ring[c] + q->ap_off[c][k];
      const uint32_t aw = q->ap_w[c][k];
      float dl = q->ap_full[c][k] ? b[aw] : 0.0f;
      if (q->frac_on) dl = le_frac_tick(q->ap_fa[c][k], q->ap_fz[c][k], dl);
      const float v = e[c] + apg * dl;
      e[c] = dl - apg * v;
      b[aw] = fx_sanitize(v);
      if (aw + 1u >= q->ap_n[c][k]) {
        q->ap_w[c][k] = 0u;
        q->ap_full[c][k] = 1u;
      } else {
        q->ap_w[c][k] = aw + 1u;
      }
    }
  }
  if (++q->hist_w >= q->hist_n) {
    q->hist_w = 0;
    q->hist_full = 1u;
  }
  /* The network: each line's output was written line_n samples ago, at the
   * position its input goes to now. */
  float o[LE_VB_LINES];
  le_u4 pos[2];
  for (int g = 0; g < 2; ++g) {
    const int b = 4 * g;
    const float* rg = ring[g];
    const le_u4 at = le_u4_load(q->line_off + b) + le_u4_load(q->line_w + b);
    pos[g] = at;
    le_f4 x = {rg[at[0]], rg[at[1]], rg[at[2]], rg[at[3]]};
    if (!q->lines_full) x = le_f4_keep(x, le_u4_load(q->line_full + b));
    if (q->frac_on) {
      x = le_frac_tick4(q->frac_a + b, q->frac_z[0] + b, q->frac_z[1] + b, x);
    }
    le_f4_store(o + b, x);
  }
  float sum = 0.0f;
  float ol = 0.0f;
  float orr = 0.0f;
  for (int i = 0; i < LE_VB_LINES; ++i) {
    sum += o[i];
    ol += q->cl[i] * o[i];
    orr += q->cr[i] * o[i];
  }
  const float house = 2.0f / (float)LE_VB_LINES * sum;
  if (q->line_ramp > 0) {
    if (--q->line_ramp == 0) {
      memcpy(q->gm, q->gm_to, sizeof(q->gm));
      memcpy(q->lo, q->lo_to, sizeof(q->lo));
      memcpy(q->hi, q->hi_to, sizeof(q->hi));
    } else {
      for (int b = 0; b < LE_VB_LINES; b += 4) {
        le_f4_store(q->gm + b, le_f4_load(q->gm + b) + le_f4_load(q->gm_d + b));
        for (int j = 0; j < 3; ++j) {
          le_f4_store(q->lo[j] + b,
                      le_f4_load(q->lo[j] + b) + le_f4_load(q->lo_d[j] + b));
          le_f4_store(q->hi[j] + b,
                      le_f4_load(q->hi[j] + b) + le_f4_load(q->hi_d[j] + b));
        }
      }
    }
  }
  const le_f4 hv = le_f4_set1(house);
  const le_f4 inj = {e[0], e[1], e[0], e[1]}; /* even lines take left */
  uint32_t all = ~0u;
  for (int g = 0; g < 2; ++g) {
    const int b = 4 * g;
    float* rg = ring[g];
    /* le_vb_tick through the low shelf, then the high, four lines */
    float* lx = q->lo_z[ph][0] + b;
    float* ly = q->lo_z[ph][1] + b;
    float* hx = q->hi_z[ph][0] + b;
    float* hy = q->hi_z[ph][1] + b;
    /* The products the scalar code rounds on their own (le_vb_tick's b1 x1,
     * the injection) are spelled out (LE_ROUNDED); the others fuse. */
    const le_f4 x = le_f4_load(o + b) - hv;
    le_f4 lb = le_f4_load(q->lo[1] + b) * le_f4_load(lx);
    LE_ROUNDED(lb);
    const le_f4 y = le_f4_load(q->lo[0] + b) * x + lb -
                    le_f4_load(q->lo[2] + b) * le_f4_load(ly);
    le_f4_store(lx, x);
    le_f4_store(ly, y);
    le_f4 hb = le_f4_load(q->hi[1] + b) * le_f4_load(hx);
    LE_ROUNDED(hb);
    const le_f4 y2 = le_f4_load(q->hi[0] + b) * y + hb -
                     le_f4_load(q->hi[2] + b) * le_f4_load(hy);
    le_f4_store(hx, y);
    le_f4_store(hy, y2);
    le_f4 in_v = le_f4_load(q->cin_g + b) * inj;
    LE_ROUNDED(in_v);
    const le_f4 v = le_f4_sanitize(le_f4_load(q->gm + b) * y2 + in_v);
    const le_u4 at = pos[g];
    rg[at[0]] = v[0];
    rg[at[1]] = v[1];
    rg[at[2]] = v[2];
    rg[at[3]] = v[3];
    const le_u4 next = le_u4_load(q->line_w + b) + le_u4_set1(1u);
    const le_u4 wrap = (le_u4)(next >= le_u4_load(q->line_n + b));
    le_u4_store(q->line_w + b, next & ~wrap);
    if (!q->lines_full) {
      const le_u4 full = le_u4_load(q->line_full + b) | wrap;
      le_u4_store(q->line_full + b, full);
      all &= full[0] & full[1] & full[2] & full[3];
    }
  }
  if (!q->lines_full) q->lines_full = all != 0u;
  const float inv = 0.35355339f * q->late_k; /* 1 / sqrt(8) */
  w[0] = inv * ol + q->early_g * e[0] + tap[0];
  w[1] = inv * orr + q->early_g * e[1] + tap[1];
  for (int c = 0; c < 2; ++c) {
    if (d->peak_db != 0.0) {
      w[c] = le_biquad_tick(q->peak, q->peak_z[c][ph], w[c]);
    }
    w[c] = le_vb_tick(q->shelf, q->shelf_z[c][ph], w[c]);
  }
  if (d->tail_g != 0.0f) {
    q->tail_z[ph] = fx_sanitize(q->tail_p * q->tail_z[ph] + m);
    const float t = d->tail_g * (q->tail_z[ph] - m);
    w[0] += t;
    w[1] += t;
  }
}

static void fx_verb_rkprocess(void* ks, float* r0, float* r1, int cap, float* l,
                              float* r) {
  le_fx_verb* q = (le_fx_verb*)ks;
  /* Rings too short for the geometry, or one missing: the input passes
   * untouched, as it does when the slot has no rings (fx_run). */
  if (q->def == NULL || r1 == NULL || (uint32_t)cap < q->need[0] ||
      (uint32_t)cap < q->need[1])
    return;
  const float dry = le_fx_glide_next(&q->dry);
  const float wet = le_fx_glide_next(&q->wet);
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  float w[2];
  le_vb_network(q, r0, r1, 0.5f * (x0 + x1), w);
  *l = dry * x0 + wet * w[0];
  *r = dry * x1 + wet * w[1];
}

/* ---- Reverb (LE_FX_ROOM_VERB, #1476) ----
 *
 * The Looper X's Reverb module, fit to its #891 captures (s6rev, s8, s14;
 * docs/plan/2026-10-25-looperx-reverb-measured.md). Its racks show it two
 * ways: the Drum Rack's, with ER rooms, Lo/Hi, Tail/ER and Density (twelve
 * of its fifteen rooms: the last three are off the Looper X's screen and
 * unmeasured); and the others', with four modes (HALL, STADIUM, ROOM, BOX)
 * and Bright. The captures put one network behind every room, the
 * Dub-Verb's (its arrivals match to the sample): HALL's delays are 0.841
 * of the Drum's, STADIUM's the same behind 72 ms, ROOM's 0.43. Each room:
 * - its first 40 to 50 ms are the capture's own taps (up to LE_RV_FIR a
 *   side, read off the input history; the Drum tail's at five Density
 *   points), which do not move with Length on any capture;
 * - behind them a le_verb_def network at the room's size: three diffusers
 *   at the network's own delays, heard as they ring and feeding eight
 *   lines with the room's decay table against Length and a late gain
 *   table, fit to the captures' envelopes at every captured Length;
 * - the Drum's rooms add their ER taps (16 a side, from the ER-only
 *   captures);
 * - a first-order low-pass on the whole wet at 1010 x 20.5^Bright Hz
 *   (bilinear, the same corner at every rate; within 0.2 kHz of the seven
 *   captured Bright settings); Lo/Hi sets it from its own five captured
 *   corners, and moves a low cut that is always in on those rooms;
 * - the Drum's Tail/ER and Mix are equal-power over a quarter turn (at
 *   Mix 100 % the dry is still 0.707); the modes' Mix over a half turn.
 * What a setting moves ramps per frame; a room change fades the old room
 * out, lays the network out again (its geometry is the room's) and fades
 * the new room's input in. The lines live in the slot's two one-second
 * rings. */
#define LE_RV_ROOMS 16
#define LE_RV_ER 16
#define LE_RV_FIR 64 /* the most taps a network's early part runs a side */
_Static_assert(LE_RV_FIR % 4 == 0, "the taps' gains ramp four at a time");

/* A network's early part, read off the captures as taps (delay, and gain
 * at each Density point 0, 25, 50, 75 and 100 %; a mode's at one), the
 * same at every Length: the captures' first tens of milliseconds do not
 * move with it. */
typedef struct le_rv_fir {
  int n[2];
  int nd; /* Density points held: 1, or 5 evenly from 0 to 100 % */
  double ms[2][LE_RV_FIR];
  const float (*g)[2][LE_RV_FIR]; /* [nd] */
} le_rv_fir;

typedef struct le_rv_room {
  const le_verb_def* tail;
  const le_rv_fir* fir;
  int drum; /* a Drum Rack ER room: Lo/Hi, Tail/ER, Density, its Mix law */
  int er_n[2];
  double er_ms[2][LE_RV_ER]; /* the ER taps: delay (ms) and gain */
  float er_g[2][LE_RV_ER];
} le_rv_room;

static const le_fx_param_desc LE_FX_ROOM_VERB_PARAMS[] = {
    {"length", LE_FX_UNIT_SECONDS, 0, 0.45f, 144.0f, LE_FX_CURVE_REVERB_TIME,
     0.4f, 0},
    {"mix", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.15f, 0},
    /* HALL, STADIUM, ROOM, BOX, then the Drum Rack's ER rooms: BOOTH, CLUB,
     * ROOM, SMALL CHAMBER, Med CHAMBER, LARGE CHAMBER, SMALL STUDIO,
     * LARGE STUDIO, SCORING STAGE, PHILHARMONIC, CONCERT HALL, CHURCH */
    {"room", LE_FX_UNIT_CHOICE, LE_RV_ROOMS, 0.0f, 1.0f, LE_FX_CURVE_LINEAR,
     0.0f, 0},
    {"bright", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.8f, 0},
    {"lo_hi", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.5f, 0},
    {"tail_er", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 0.3f,
     0},
    {"density", LE_FX_UNIT_PERCENT, 0, 0.0f, 100.0f, LE_FX_CURVE_LINEAR, 1.0f,
     0},
};

/* LE_RV_ROOM_TABLE: the rooms, filled from the captures below. */
#include "engine_fx_rooms.inc"

typedef struct le_fx_rverb {
  le_fx_verb v; /* the room's network */
  int room;    /* the room laid out, -1 for none */
  int rate;    /* the rate it is laid out at */
  uint32_t er_n[2];
  uint32_t er_at[2][LE_RV_ER];
  float er_g[2][LE_RV_ER];
  uint32_t fir_n[2];
  uint32_t fir_at[2][LE_RV_FIR];
  float fir_g[2][LE_RV_FIR]; /* at the Density they were set for */
  float fir_d;               /* that Density (-1: none) */
  float dens;                /* Density, gliding */
  le_fx_glide in_g;          /* the input's fade-in after a room change */
  /* What each update moves (the early taps' gains, the low-pass, the
   * diffusers' gain, the late network's output gain) ramps to its new value
   * over the LE_FX_UPDATE_FRAMES frames after it, so nothing steps. */
  int32_t ramp;
  float fir_d_g[2][LE_RV_FIR];
  float fir_to[2][LE_RV_FIR];
  float tone_d[3], tone_to[3];
  float apg_d, apg_to;
  float latek_d, latek_to;
  le_fx_glide er_k;  /* the early taps' weight (Tail/ER) */
  le_fx_glide tail_k; /* the network's weight (Tail/ER) */
  le_fx_glide dip;   /* the wet's dip across a room change */
  float tone_v;      /* the tone setting the filter is designed for */
  float tone_tgt;
  float tone[3];     /* first-order low-pass: b0, b1, a1 */
  float tone_z[2][LE_RS_PH][2]; /* per phase, as the network's (le_fx_verb) */
  int cut;          /* Lo/Hi's low cut runs (a Drum room) */
  double cut_hz;    /* the corner it is designed for (0: not yet) */
  float lc[5];
  float lc_to[5], lc_d[5];
  float lc_z[2][LE_RS_PH][2];
} le_fx_rverb;

/* Lo/Hi's low-pass corner (Hz) at 0, 25, 50, 75 and 100 %, read off the
 * Drum captures' first tap; log-linear between. */
static const double LE_RV_LOHI_HZ[5] = {1348.0, 2481.0, 4492.0, 9432.0,
                                        20700.0};

/* The low-pass's corner (Hz) at tone setting [v]: Bright's law (within
 * 0.2 kHz of its seven captured settings), or Lo/Hi's table on a Drum
 * room. */
static double le_rv_tone_hz(double v, int drum) {
  if (!drum) return 1010.0 * pow(20.5, v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v);
  const double x = (v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v) * 4.0;
  const int i = x >= 4.0 ? 3 : (int)x;
  return LE_RV_LOHI_HZ[i] * pow(LE_RV_LOHI_HZ[i + 1] / LE_RV_LOHI_HZ[i],
                                x - (double)i);
}

/* The room's network and taps laid out at [rate]. */
static void le_rv_lay(le_fx_rverb* q, int room, int rate) {
  const le_rv_room* rm = &LE_RV_ROOM_TABLE[room];
  uint32_t reach = 0;
  for (int c = 0; c < 2; ++c) {
    q->er_n[c] = (uint32_t)rm->er_n[c];
    for (int i = 0; i < rm->er_n[c]; ++i) {
      q->er_at[c][i] = le_vb_len(rm->er_ms[c][i], rate);
      q->er_g[c][i] = rm->er_g[c][i];
      if (q->er_at[c][i] > reach) reach = q->er_at[c][i];
    }
  }
  const le_rv_fir* fir = rm->fir;
  for (int c = 0; c < 2; ++c) {
    q->fir_n[c] = (uint32_t)fir->n[c];
    for (uint32_t i = 0; i < q->fir_n[c]; ++i) {
      q->fir_at[c][i] = le_vb_at(fir->ms[c][i], rate);
      if (q->fir_at[c][i] > reach) reach = q->fir_at[c][i];
    }
  }
  q->fir_d = -1.0f;
  q->v.reach = reach + 1u;
  le_vb_lay(&q->v, rm->tail, rate);
  memset(q->tone_z, 0, sizeof(q->tone_z));
  memset(q->lc_z, 0, sizeof(q->lc_z));
  q->tone_v = -1.0f;
  q->cut = 0;
  q->cut_hz = 0.0;
  q->room = room;
  q->rate = rate;
}

/* The tone filter at setting [v] (the Drum's Lo/Hi or the modes' Bright),
 * and for a Drum room Lo/Hi's low cut: a 12 dB/octave high-pass at
 * LE_RV_CUT_HZ at 100 %, LE_RV_CUT_STEP times lower each quarter below
 * (the captures put it at 65 Hz at 100 % and under 8 Hz at 75 %). */
static void le_rv_tone(le_fx_rverb* q, float v, int drum, int sr) {
  const int rate = le_rs_design_rate(sr); /* 48 kHz at 96, on each phase */
  double hz = le_rv_tone_hz((double)v, drum);
  if (hz > 0.45 * (double)rate) hz = 0.45 * (double)rate;
  const double t = le_vb_warp(hz, rate);
  q->tone_to[0] = (float)(t / (1.0 + t));
  q->tone_to[1] = q->tone_to[0];
  q->tone_to[2] = (float)((t - 1.0) / (1.0 + t));
  q->tone_v = v;
  q->cut = drum;
  if (!drum) return;
  /* Always in on a Drum room, so it never switches: below 8 Hz (Lo/Hi
   * under about 78 %) it holds there, which reads as the 75 % capture's
   * -0.9 dB at 12 Hz. The captures read Lo/Hi against 50 %, so a corner
   * held at every lower setting does not show in them. */
  double cut = LE_RV_CUT_HZ * pow(LE_RV_CUT_STEP, 4.0 * ((double)v - 1.0));
  if (cut < 8.0) cut = 8.0;
  if (cut == q->cut_hz) return;
  double c[5];
  le_eq_design(LE_EQ_LOWCUT, cut, 0.0, LE_EQ_CUT_Q, rate, c);
  for (int i = 0; i < 5; ++i) q->lc_to[i] = (float)c[i];
  q->cut_hz = cut;
}

static void fx_room_verb_update(void* ks, le_fx_dyn_head* h, const float* p,
                                int sr, int f) {
  le_fx_rverb* q = (le_fx_rverb*)ks;
  const int settle = (f & LE_FX_DYN_SETTLE) != 0;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  int room = (int)(p[2] * (float)(LE_RV_ROOMS - 1) + 0.5f);
  room = room < 0 ? 0 : room >= LE_RV_ROOMS ? LE_RV_ROOMS - 1 : room;
  const float k = settle ? 1.0f : h->k;
  int moving = 0;
  /* A new rate, a first update or a settle lays the room out at once; a
   * room change dips the wet first. */
  const int fresh = (f & LE_FX_DYN_NEW_RATE) || q->v.def == NULL || settle;
  int laid = 0;
  if (fresh) {
    if (q->v.def == NULL || q->room != room || q->rate != rate) {
      le_rv_lay(q, room, rate);
      laid = 1;
    }
    le_fx_glide_step(&q->dip, 1.0f, 1.0f);
    le_fx_glide_step(&q->in_g, 1.0f, 1.0f);
  } else if (room != q->room) {
    /* The old room fades out, the new one is laid out empty, and its input
     * fades in: neither the old tail nor the new taps step. */
    moving |= le_fx_glide_step(&q->dip, 0.0f, k);
    if (q->dip.v == 0.0f && q->dip.g == 0.0f) {
      le_rv_lay(q, room, rate);
      laid = 1;
      le_fx_glide_step(&q->dip, 1.0f, 1.0f);
      le_fx_glide_step(&q->in_g, 0.0f, 1.0f);
      moving = 1;
    }
  } else {
    moving |= le_fx_glide_step(&q->dip, 1.0f, k);
    moving |= le_fx_glide_step(&q->in_g, 1.0f, k);
  }
  const int instant = fresh || laid || q->tone_v < 0.0f;
  const float latek_was = q->v.late_k;
  const le_rv_room* rm = &LE_RV_ROOM_TABLE[q->room];
  const float len = p[0] < 0.0f ? 0.0f : p[0] > 1.0f ? 1.0f : p[0];
  le_vb_glide_dec(&q->v, len, q->v.dec_design < 0.0f ? 1.0f : k, rate);
  moving |= q->v.dec != len;
  q->latek_to = q->v.late_k;
  q->v.late_k = instant ? q->latek_to : latek_was;
  /* The tone: the Drum's Lo/Hi or the modes' Bright, gliding. */
  const float tv = rm->drum ? p[4] : p[3];
  q->tone_tgt = tv < 0.0f ? 0.0f : tv > 1.0f ? 1.0f : tv;
  const int design = q->tone_v < 0.0f;
  if (design) q->tone_v = q->tone_tgt;
  float tone = q->tone_v;
  le_fx_step_toward(&tone, q->tone_tgt, k);
  if (tone != q->tone_v || design) le_rv_tone(q, tone, rm->drum, rate);
  moving |= q->tone_v != q->tone_tgt;
  /* Mix: equal-power, over a quarter turn on the Drum, a half on the
   * modes; Tail/ER equal-power over a quarter turn (the Drum's alone). */
  const double m = p[1] < 0.0f ? 0.0 : p[1] > 1.0f ? 1.0 : (double)p[1];
  const double turn = rm->drum ? 0.25 * LE_PI : 0.5 * LE_PI;
  moving |= le_fx_glide_step(&q->v.dry, (float)cos(m * turn), k);
  moving |= le_fx_glide_step(&q->v.wet, (float)(sin(m * turn) / sin(turn)), k);
  double er = 1.0, tail = 1.0;
  if (rm->drum) {
    const double te = p[5] < 0.0f ? 0.0 : p[5] > 1.0f ? 1.0 : (double)p[5];
    er = cos((1.0 - te) * 0.25 * LE_PI);
    tail = sin((1.0 - te) * 0.25 * LE_PI) / sin(0.25 * LE_PI);
  }
  moving |= le_fx_glide_step(&q->er_k, (float)er, k);
  moving |= le_fx_glide_step(&q->tail_k, (float)tail, k);
  /* Density (the Drum's): the early part's taps between the captured
   * points, and the diffusers' gain with it. */
  const float dt = !rm->drum ? 1.0f : p[6] < 0.0f ? 0.0f : p[6] > 1.0f ? 1.0f : p[6];
  le_fx_step_toward(&q->dens, dt, q->fir_d < 0.0f ? 1.0f : k);
  moving |= q->dens != dt;
  const float d = q->dens;
  if (d != q->fir_d) {
    const le_rv_fir* fir = rm->fir;
    int i0 = 0;
    float t = 0.0f;
    if (fir->nd > 1) {
      const float x = d * (float)(fir->nd - 1);
      i0 = (int)x < fir->nd - 1 ? (int)x : fir->nd - 2;
      t = x - (float)i0;
    }
    for (int c = 0; c < 2; ++c) {
      for (uint32_t i = 0; i < q->fir_n[c]; ++i) {
        const float a = fir->g[i0][c][i];
        q->fir_to[c][i] = fir->nd > 1 ? a + t * (fir->g[i0 + 1][c][i] - a) : a;
      }
    }
    q->fir_d = d;
    q->apg_to = rm->tail->ap_g * d;
  }
  /* Ramp from where each stands to its new value over the next update. */
  const float per = 1.0f / (float)LE_FX_UPDATE_FRAMES;
  for (int c = 0; c < 2; ++c) {
    for (uint32_t i = 0; i < q->fir_n[c]; ++i) {
      if (instant) q->fir_g[c][i] = q->fir_to[c][i];
      q->fir_d_g[c][i] = (q->fir_to[c][i] - q->fir_g[c][i]) * per;
    }
  }
  for (int i = 0; i < 3; ++i) {
    if (instant) q->tone[i] = q->tone_to[i];
    q->tone_d[i] = (q->tone_to[i] - q->tone[i]) * per;
  }
  for (int i = 0; q->cut && i < 5; ++i) {
    if (instant) q->lc[i] = q->lc_to[i];
    q->lc_d[i] = (q->lc_to[i] - q->lc[i]) * per;
  }
  if (instant) q->v.ap_g = q->apg_to;
  q->apg_d = (q->apg_to - q->v.ap_g) * per;
  q->latek_d = (q->latek_to - q->v.late_k) * per;
  q->ramp = instant ? 0 : LE_FX_UPDATE_FRAMES;
  h->moving = moving;
}

/* [n] taps (delays [at], gains [g]) off the history [hist], whose newest
 * sample is at [now]: once it has wrapped, straight reads of its second
 * copy; before, only what it holds since it was cleared. */
static inline float le_rv_taps(const float* hist, uint32_t now,
                               const le_fx_verb* v, const uint32_t* at,
                               const float* g, uint32_t n) {
  float acc = 0.0f;
  if (v->hist_full) {
    const float* h = hist + now + v->hist_n;
    for (uint32_t i = 0; i < n; ++i) acc += g[i] * h[-(int32_t)at[i]];
  } else {
    for (uint32_t i = 0; i < n; ++i) {
      if (at[i] <= now) acc += g[i] * hist[now - at[i]];
    }
  }
  return acc;
}

static void fx_room_verb_rkprocess(void* ks, float* r0, float* r1, int cap,
                                   float* l, float* r) {
  le_fx_rverb* q = (le_fx_rverb*)ks;
  le_fx_verb* v = &q->v;
  if (v->def == NULL || r1 == NULL || (uint32_t)cap < v->need[0] ||
      (uint32_t)cap < v->need[1])
    return;
  const float dry = le_fx_glide_next(&v->dry);
  const float wet = le_fx_glide_next(&v->wet) * le_fx_glide_next(&q->dip);
  const float erk = le_fx_glide_next(&q->er_k);
  const float tk = le_fx_glide_next(&q->tail_k);
  const float in_g = le_fx_glide_next(&q->in_g);
  if (q->ramp > 0) {
    if (--q->ramp == 0) {
      memcpy(q->fir_g, q->fir_to, sizeof(q->fir_g));
      memcpy(q->tone, q->tone_to, sizeof(q->tone));
      if (q->cut) memcpy(q->lc, q->lc_to, sizeof(q->lc));
      v->ap_g = q->apg_to;
      v->late_k = q->latek_to;
    } else {
      for (int c = 0; c < 2; ++c) { /* to the next whole four taps */
        float* g = q->fir_g[c];
        const float* dg = q->fir_d_g[c];
        const size_t n = q->fir_n[c];
        for (size_t i = 0; i < n; i += 4) {
          le_f4_store(g + i, le_f4_load(g + i) + le_f4_load(dg + i));
        }
      }
      for (int i = 0; i < 3; ++i) q->tone[i] += q->tone_d[i];
      for (int i = 0; q->cut && i < 5; ++i) q->lc[i] += q->lc_d[i];
      v->ap_g += q->apg_d;
      v->late_k += q->latek_d;
    }
  }
  const float x0 = fx_sanitize(*l);
  const float x1 = fx_sanitize(*r);
  float w[2];
  const int ph = v->ph; /* the phase le_vb_network runs */
  le_vb_network(v, r0, r1, 0.5f * (x0 + x1) * in_g, w);
  /* The early taps read the history the network just wrote: the newest
   * sample sits one behind its write position. le_rv_taps is the reference
   * engine's, character for character: the compilers decide per loop shape
   * whether to fuse each tap's multiply-add, and a Drum room's low cut
   * carries a changed rounding to about -62 dBFS (#1755, #1761). */
  const float* hist = r0;
  const uint32_t now = v->hist_w == 0u ? v->hist_n - 1u : v->hist_w - 1u;
  for (int c = 0; c < 2; ++c) {
    const float e = le_rv_taps(hist, now, v, q->er_at[c], q->er_g[c], q->er_n[c]);
    const float f =
        le_rv_taps(hist, now, v, q->fir_at[c], q->fir_g[c], q->fir_n[c]);
    float y = erk * e + tk * (w[c] + f);
    y = le_vb_tick(q->tone, q->tone_z[c][ph], y);
    if (q->cut) y = le_biquad_tick(q->lc, q->lc_z[c][ph], y);
    w[c] = y;
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
LE_FX_ROWS_FIT(LE_FX_ROOM_VERB_PARAMS);
LE_FX_ROWS_FIT(LE_FX_WHAMMY_PARAMS);
LE_FX_ROWS_FIT(LE_FX_PUMPER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_SLICER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_MODE_DELAY_PARAMS);
LE_FX_ROWS_FIT(LE_FX_DUAL_OCTAVER_PARAMS);
LE_FX_ROWS_FIT(LE_FX_AMP_CAB_PARAMS);
LE_FX_ROWS_FIT(LE_FX_MOD_PARAMS);
LE_FX_ROWS_FIT(LE_FX_SMART_TUNE_PARAMS);

/* ---- Smart Tune (LE_FX_SMART_TUNE, #1480) ----
 *
 * The Vocal Tuner's Smart Tune, against the #891 captures (s6pitch 0-22, a
 * 50-cent staircase from 440 to 880 Hz, and s5/8-11, 1 kHz bursts): the
 * output goes to the nearest note of the scale (Scale Root and Scale Type;
 * a pitch exactly between two goes up), and glides there in cents with a
 * time constant of half the Speed (17 ms at 32 ms, 78 at 179, about 500 at
 * 1000). A note after silence starts from the input's pitch. The octaver's
 * PSOLA does the shifting, fully wet: its detection gives the period, and
 * its grains are laid at the period the target asks for, so the output
 * lands on the note. */

/* Each scale type's notes, bit d for d semitones above the root, in the
 * Looper X's order. Locrian is Phrygian's notes, as the device plays it
 * (s6pitch 8 against 5: G, not Gb); Penta is the minor pentatonic
 * (s6pitch 10). Min Triad and Root are off the device's screen, so their
 * notes come from their names. */
static const uint16_t LE_ST_SCALES[14] = {
    0xAB5, /* Major */
    0x5AD, /* Minor */
    0x9AD, /* Harm Min */
    0xAAD, /* Melo Min */
    0x6AD, /* Dorian */
    0x5AB, /* Phrygian */
    0xAD5, /* Lydian */
    0x6B5, /* Mixo */
    0x5AB, /* Locrian */
    0xFFF, /* Chromatic */
    0x4A9, /* Penta */
    0x091, /* Maj Triad */
    0x089, /* Min Triad */
    0x001, /* Root */
};

/* How much nearer, in semitones, another note of the scale must be before
 * the held one gives way to it: a voice that sits between two notes stays
 * on one, as the captures' steps exactly between two do. The captured
 * glide (s6pitch 15, 220 to 440 Hz in 3 s) leaves a whole tone 0 to 3
 * cents past the midpoint and a semitone 10 to 12 past it. */
#define LE_ST_HOLD 0.1

/* Whether note [k] (semitones above the root) is in [mask]. */
static int le_st_in(unsigned mask, int k) {
  return ((mask >> (((k % 12) + 12) % 12)) & 1u) != 0u;
}

/* The correction, in cents, that takes channel [o]'s pitch of period [pf]
 * (kernel samples, at LE_OCT_RATE) to the nearest note of [p]'s scale, or
 * to the note it holds while that is within LE_ST_HOLD of as near. */
static float le_st_want(le_octaver_state* o, float pf, const float* p) {
  const le_fx_param_desc* d = LE_FX_SMART_TUNE_PARAMS;
  const double ref = le_fx_desc_value(&d[3], p[3]);
  const int root = (int)(le_mdly_clamp01(p[1]) * 11.0f + 0.5f);
  const int type = (int)(le_mdly_clamp01(p[2]) * 13.0f + 0.5f);
  const unsigned mask = LE_ST_SCALES[type];
  /* Semitones above the root (A is 9 above C). */
  const double x =
      12.0 * log2((double)LE_OCT_RATE / (double)pf / ref) + 9.0 - root;
  const int b = (int)floor(x);
  int best = b;
  double gap = 1e9;
  for (int k = b - 12; k <= b + 12; ++k) {
    if (!le_st_in(mask, k)) continue;
    const double dist = fabs(x - (double)k);
    if (dist <= gap) { /* ascending, so a tie keeps the higher note */
      gap = dist;
      best = k;
    }
  }
  if (o->tune_held && le_st_in(mask, o->tune_note) &&
      fabs(x - (double)o->tune_note) <= gap + LE_ST_HOLD) {
    best = o->tune_note;
  }
  o->tune_note = best;
  o->tune_held = 1;
  return (float)(100.0 * ((double)best - x));
}

/* The correction this sample, in cents, in [o]'s glide: one step toward the
 * one the pitch channel [in] detects asks for, or none while that input is
 * unvoiced (PSOLA plays the dry then), so a new note starts from its own
 * pitch. A note starts correcting once PSOLA's voicing reaches 0.6, its
 * third detection, when the period it smooths has left the last note's. */
static float le_st_correct(le_octaver_state* o, const le_octaver_state* in,
                           const float* p) {
  const float pf = in->period;
  const float gate = o->tune_held ? 0.3f : 0.6f;
  if (in->cur_mode != 1 || pf <= 0.0f || in->voiced < gate) {
    o->tune_c = 0.0f;
    o->tune_held = 0;
    o->tune_at[0] = -1.0f; /* the next note works its target out afresh */
    return 0.0f;
  }
  if (p[0] != o->tune_at[1]) {
    o->tune_at[1] = p[0];
    const double tau =
        0.5e-3 * le_fx_desc_value(&LE_FX_SMART_TUNE_PARAMS[0], p[0]);
    o->tune_a = (float)(1.0 - exp(-1.0 / (tau * (double)LE_OCT_RATE)));
  }
  if (pf != o->tune_at[0] || p[1] != o->tune_at[2] || p[2] != o->tune_at[3] ||
      p[3] != o->tune_at[4]) {
    /* A new root or scale makes the held note another pitch: hold none. */
    if (p[1] != o->tune_at[2] || p[2] != o->tune_at[3]) o->tune_held = 0;
    o->tune_at[0] = pf;
    for (int k = 2; k < 5; ++k) o->tune_at[k] = p[k - 1];
    o->tune_want = le_st_want(o, pf, p);
  }
  o->tune_c += o->tune_a * (o->tune_want - o->tune_c);
  return o->tune_c;
}

/* One correction drives both channels, so a stereo input never splits
 * across two notes. It follows the channel more clearly voiced (the left
 * unless the right is so by 0.1), so a voice on either side is tuned. */
static void le_st_tick(le_fx_state* fx, int slot, const float* p, float* q) {
  le_octaver_state* o = fx->oct[slot];
  /* Its tone, mix and level are the kind's own, fixed: set there after a
   * reset, not ramped from its dry, dark state. And it always runs PSOLA: a
   * slot found off it (a state prepared without a reset) takes it at once,
   * as a reset slot does, not through the mode-switch dip. */
  for (int chan = 0; chan < 2; ++chan) {
    if (o[chan].cur_mode != 1 && o[chan].fresh == 0) o[chan].fresh = 1;
    if (o[chan].fresh > 0) {
      o[chan].sm_tone = q[1];
      o[chan].sm_mix = q[2];
      o[chan].sm_level = 1.0f;
    }
  }
  const int in = o[1].voiced > o[0].voiced + 0.1f ? 1 : 0;
  q[0] = 0.5f + le_st_correct(&o[0], &o[in], p) / 4800.0f;
  /* The shift is set, not smoothed: the glide is the correction's own. */
  o[0].sm_shift = q[0];
  o[1].sm_shift = q[0];
}

static void fx_smart_tune_process(le_fx_state* fx, int slot, int sr, int cap,
                                  float* l, float* r, const float* p) {
  float q[9] = {0.0f};
  le_st_settings(q);
  /* The correction is worked out each kernel tick, at the kernel's rate. */
  fx_octaver_run(fx, slot, sr, cap, l, r, q, p, le_st_tick);
}

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


/* ---- Echo (LE_FX_ECHO) ----
 *
 * Tape-style echo. Three things set it apart from the clean digital delay: a
 * slow wow LFO wobbles the read time (tape pitch flutter, read fractionally), a
 * heavy one-pole low-pass darkens the loop so each repeat loses highs, and the
 * fed-back signal is softly saturated (tape compression, which also self-limits
 * the feedback). The wet tap is that processed signal, so even the first repeat
 * is coloured rather than a clean copy. p0 = time (0..1 s), p1 = feedback,
 * p2 = wet mix. Its lines are the slot's two rings; its block knows how much
 * of them it has written, so the rings are never cleared for it. The wow LFO
 * runs on the engine clock (le_clock_lfo, through the vtable's lfo_hz). */

typedef struct le_fx_echo {
  /* The settings: the time's share of the ring, the loop's feedback and
   * the wet mix. */
  float time;
  float fb;
  float mix;
  /* Per-rate: the loop low-pass's step (0.18 at 48 kHz; elsewhere the same
   * time constant, 1 - 0.82^(48000 / sr), so the repeats darken alike,
   * #1547) and the wow's depth (4 ms). */
  float step;
  float wob;
  float lp[2];   /* the loop low-pass, per channel */
  int32_t pos;   /* the rings' write head */
  int32_t full;  /* the rings have wrapped: every sample is written */
} le_fx_echo;

static void fx_echo_update(void* ks, le_fx_dyn_head* h, const float* p,
                           int sr, int f) {
  (void)h;
  le_fx_echo* q = (le_fx_echo*)ks;
  if (!f) return;
  if (f & LE_FX_DYN_NEW_RATE) {
    const int rate = sr > 0 ? sr : 48000;
    q->step = (float)(1.0 - pow(0.82, 48000.0 / rate));
    q->wob = 0.004f * (float)rate;
  }
  q->time = p[0];
  q->fb = p[1] * 0.97f;
  q->mix = p[2];
}

/* The ring [buf] at [w]; a sample not yet written since the block was
 * cleared reads as silence. */
static float le_echo_read(const le_fx_echo* q, const float* buf,
                          le_frac_at w) {
  const float a = q->full || w.i0 < q->pos ? buf[w.i0] : 0.0f;
  const float b = q->full || w.i1 < q->pos ? buf[w.i1] : 0.0f;
  return a + w.frac * (b - a);
}

static void fx_echo_rkprocess(void* ks, float* r0, float* r1, int cap, float* l,
                              float* r) {
  le_fx_echo* q = (le_fx_echo*)ks;
  if (cap <= 1 || r1 == NULL) return;
  if (q->pos >= cap) { /* the rings were remade shorter: start them again */
    q->pos = 0;
    q->full = 0;
  }
  /* Wow/flutter: a slow LFO on the engine clock wobbles the read time a few
   * ms for tape wobble. */
  const float wow = sinf(2.0f * LE_PI * le_fx_kind_lfo(ks));
  float d = q->time * (float)(cap - 1) + wow * q->wob;
  if (d < 1.0f) d = 1.0f;
  if (d > (float)(cap - 1)) d = (float)(cap - 1);
  float* ring[2] = {r0, r1};
  float* io[2] = {l, r};
  const le_frac_at w = le_frac_where(cap, q->pos, d);
  for (int c = 0; c < 2; ++c) {
    const float x = *io[c];
    const float delayed = le_echo_read(q, ring[c], w);
    /* Darken the loop (~1.4 kHz one-pole) then soft-saturate the repeats. */
    q->lp[c] += q->step * (delayed - q->lp[c]);
    const float wet = tanhf(q->lp[c]);
    ring[c][q->pos] = x + wet * q->fb;
    *io[c] = x * (1.0f - q->mix) + wet * q->mix;
  }
  if (++q->pos >= cap) {
    q->pos = 0;
    q->full = 1;
  }
}

/* ---- Reverb (LE_FX_REVERB) ----
 *
 * Schroeder/Freeverb reverb: LE_REV_COMBS parallel damped comb filters are
 * summed and run through LE_REV_APS series allpass diffusers, producing a dense
 * decaying tail rather than the discrete repeats of DELAY/ECHO. Two such banks
 * run in parallel — a left and a right whose lines are offset by LE_REV_SPREAD —
 * each fed by its own input (the left bank by the left, the right bank by the
 * right). A mono input feeds both banks identically, so it still yields a
 * decorrelated stereo tail from the spread alone; an already-stereo input
 * reverberates each side on its own bank. p0 = size (tail length, via comb
 * feedback), p1 = damping (treble absorbed each pass), p2 = wet mix. The wet
 * path carries only the reverberated signal, so the dry is heard through
 * (1 - mix). Both banks are packed into the slot's first ring (its `prepare`
 * makes only that one); both banks total well under 1 s even at 192 kHz. Its
 * block knows which lines it has filled, so the ring is never cleared for
 * it. */
#define LE_REV_COMBS 8
#define LE_REV_APS 4
#define LE_REV_BANKS 2
#define LE_REV_LINES ((LE_REV_COMBS + LE_REV_APS) * LE_REV_BANKS)
_Static_assert(LE_REV_COMBS % 4 == 0, "a bank's combs run four at a time");
_Static_assert(LE_RS_PH == 2, "the Freeverb's damping keeps two phases");

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

typedef struct le_fx_rev {
  float room; /* the comb feedback, 0.70..0.98 */
  float damp; /* the comb feedback low-pass's pole, at the rate */
  float mix;
  /* Per-rate: the phases the 48 kHz network runs on (le_rs_phases), and
   * whether its lines take a fraction of a sample (le_rev_geometry). */
  int32_t nph;
  int32_t frac;
  int32_t ph; /* the phase this sample runs */
  /* Each line's samples, its all-pass for the rest of its 48 kHz length,
   * its write head and whether it has wrapped: the left bank's combs, then
   * its allpasses, then the right bank's. */
  uint32_t len[LE_REV_LINES];
  uint32_t off[LE_REV_LINES]; /* where each line starts in the ring */
  uint32_t need;              /* the ring's samples the lines take */
  float fa[LE_REV_LINES];
  uint32_t pos[LE_REV_LINES];
  uint32_t full[LE_REV_LINES]; /* all ones once the line has wrapped */
  /* Each line's fraction: its all-pass's last input, then its output. */
  float frac_z[2][LE_REV_LINES];
  /* Each comb's damping memory, one per phase: at 96 kHz the network is the
   * 48 kHz one on alternate samples. */
  float comb_lp[LE_RS_PH][LE_REV_COMBS * LE_REV_BANKS];
} le_fx_rev;

/* [q]'s lines at [sr]: each one's samples and, where frac applies, its
 * all-pass for the rest of its 48 kHz length (le_frac_split). The line
 * lengths are Freeverb's 44.1 kHz ones scaled to 48 kHz, and at 96 kHz
 * exactly twice those: with the damping on each phase's own memory, every
 * phase then runs the 48 kHz network (#1547). At other rates a line's
 * 48 kHz length is no whole number of samples: the line runs a sample or so
 * short and a first-order all-pass delays it by the rest, where rounding
 * moved the tail's echoes and with them its envelope by 3 dB at 44.1 kHz. */
static void le_rev_geometry(le_fx_rev* q, int sr) {
  const float scale = 48000.0f / 44100.0f;
  q->nph = le_rs_phases(sr);
  q->frac = le_rs_design_rate(sr) != 48000;
  for (int bank = 0; bank < LE_REV_BANKS; ++bank) {
    const int spread = bank == 0 ? 0 : (int)((float)LE_REV_SPREAD * scale);
    for (int k = 0; k < LE_REV_COMBS + LE_REV_APS; ++k) {
      const int base = k < LE_REV_COMBS ? LE_REV_COMB_LEN[k]
                                        : LE_REV_AP_LEN[k - LE_REV_COMBS];
      const int len48 = (int)((float)base * scale) + spread;
      const int i = bank * (LE_REV_COMBS + LE_REV_APS) + k;
      uint32_t n = (uint32_t)(len48 * q->nph);
      float a = 0.0f;
      if (q->frac) le_frac_split((double)len48 * (double)sr / 48000.0, &n, &a);
      q->len[i] = n > 1u ? n : 1u;
      q->fa[i] = a;
    }
  }
  uint32_t at = 0;
  for (int i = 0; i < LE_REV_LINES; ++i) {
    q->off[i] = at;
    at += q->len[i];
  }
  q->need = at;
}

static void fx_reverb_update(void* ks, le_fx_dyn_head* h, const float* p,
                             int sr, int f) {
  (void)h;
  le_fx_rev* q = (le_fx_rev*)ks;
  if (!f) return;
  const int rate = sr > 0 ? sr : 48000;
  if (f & LE_FX_DYN_NEW_RATE) {
    /* A new layout: every line starts again empty, so none reads what the
     * old one wrote there. */
    le_rev_geometry(q, rate);
    memset(q->pos, 0, sizeof(q->pos));
    memset(q->full, 0, sizeof(q->full));
    memset(q->frac_z, 0, sizeof(q->frac_z));
  }
  q->room = 0.70f + p[0] * 0.28f;
  /* 0..0.4 feedback low-pass, its pole at 48 kHz; at other rates but 96
   * the pole keeps its time constant, so the tail darkens alike. */
  q->damp = p[1] * 0.4f;
  if (q->frac && q->damp > 0.0f) {
    q->damp = powf(q->damp, 48000.0f / (float)rate);
  }
  q->mix = p[2];
}

/* Line [i]'s oldest sample, silence until it has wrapped, through its
 * fraction's all-pass where [q] runs one; then its write head moves on. */
static inline float le_rev_take(le_fx_rev* q, const float* buf, int i,
                                uint32_t* at) {
  const uint32_t pos = q->pos[i];
  float y = q->full[i] ? buf[q->off[i] + pos] : 0.0f;
  if (q->frac) {
    float z[2] = {q->frac_z[0][i], q->frac_z[1][i]};
    y = le_frac_tick(q->fa[i], z, y);
    q->frac_z[0][i] = z[0];
    q->frac_z[1][i] = z[1];
  }
  *at = q->off[i] + pos;
  if (pos + 1u >= q->len[i]) {
    q->pos[i] = 0u;
    q->full[i] = ~0u;
  } else {
    q->pos[i] = pos + 1u;
  }
  return y;
}

/* Rings too short for the lines: the input passes untouched, as it does
 * when the slot has no rings (fx_run). A bank's eight combs run four at a
 * time and the two banks' all-passes in step, each line exactly as on its
 * own; a bank's combs are summed in their order. */
static void fx_reverb_rkprocess(void* ks, float* r0, float* r1, int cap,
                                float* l, float* r) {
  (void)r1;
  le_fx_rev* q = (le_fx_rev*)ks;
  if (q->need == 0u || (uint32_t)cap < q->need) return;
  float* buf = r0;
  const int ph = q->ph < q->nph ? q->ph : 0;
  q->ph = ph + 1 < q->nph ? ph + 1 : 0;
  float* comb_lp = q->comb_lp[ph];
  const float room = q->room;
  const float damp = q->damp;
  const float mix = q->mix;
  const float x[LE_REV_BANKS] = {*l, *r};
  float wet[LE_REV_BANKS];
  for (int bank = 0; bank < LE_REV_BANKS; ++bank) {
    const int lbase = bank * (LE_REV_COMBS + LE_REV_APS); /* its lines */
    const int cbase = bank * LE_REV_COMBS; /* its combs' damping */
    const le_f4 in = le_f4_set1(x[bank] * 0.015f); /* Freeverb input gain */
    float y8[LE_REV_COMBS];
    for (int g = 0; g < LE_REV_COMBS; g += 4) {
      const int i = lbase + g;
      const le_u4 pos = le_u4_load(q->pos + i);
      const le_u4 at = le_u4_load(q->off + i) + pos;
      le_f4 y = {buf[at[0]], buf[at[1]], buf[at[2]], buf[at[3]]};
      y = le_f4_keep(y, le_u4_load(q->full + i));
      if (q->frac) {
        y = le_frac_tick4(q->fa + i, q->frac_z[0] + i, q->frac_z[1] + i, y);
      }
      le_f4_store(y8 + g, y);
      /* damp the signal fed back (lp d rounded on its own, as in the
       * scalar code: LE_ROUNDED) */
      le_f4 kept = le_f4_load(comb_lp + cbase + g) * le_f4_set1(damp);
      LE_ROUNDED(kept);
      const le_f4 lp = y * le_f4_set1(1.0f - damp) + kept;
      le_f4_store(comb_lp + cbase + g, lp);
      const le_f4 v = in + lp * le_f4_set1(room);
      buf[at[0]] = v[0];
      buf[at[1]] = v[1];
      buf[at[2]] = v[2];
      buf[at[3]] = v[3];
      const le_u4 next = pos + le_u4_set1(1u);
      const le_u4 wrap = (le_u4)(next >= le_u4_load(q->len + i));
      le_u4_store(q->pos + i, next & ~wrap);
      le_u4_store(q->full + i, le_u4_load(q->full + i) | wrap);
    }
    float acc = 0.0f;
    for (int c = 0; c < LE_REV_COMBS; ++c) acc += y8[c];
    wet[bank] = acc;
  }
  for (int a = 0; a < LE_REV_APS; ++a) {
    for (int bank = 0; bank < LE_REV_BANKS; ++bank) {
      const int i = bank * (LE_REV_COMBS + LE_REV_APS) + LE_REV_COMBS + a;
      uint32_t at;
      const float bufout = le_rev_take(q, buf, i, &at);
      buf[at] = wet[bank] + bufout * 0.5f; /* allpass feedback coefficient */
      wet[bank] = bufout - wet[bank];
    }
  }
  *l = x[0] * (1.0f - mix) + wet[0] * mix;
  *r = x[1] * (1.0f - mix) + wet[1] * mix;
}

typedef struct le_fx_vtable {
  /* Processes one stereo sample through chain slot [slot] in place, advancing
   * that slot's per-channel DSP state. NULL == a no-op slot (LE_FX_NONE). */
  void (*process)(le_fx_state* fx, int slot, int sr, int cap, float* l, float* r,
                  const float* p);
  /* Added latency in frames for slot [slot] of [type] at [sr], or NULL when
   * the effect adds none. */
  int (*latency)(const le_fx_state* fx, int slot, int32_t type, int sr);
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
   * `update` on its block at the update cadence (and with LE_FX_DYN_SETTLE
   * set right after the block is cleared, so smoothing lands at once), then
   * `kprocess`. The block's head [h] holds the settings the kind last saw
   * and its smoothing step; [f] is le_fx_dyn_begin's verdict on them, 0 when
   * nothing changed and nothing moves. */
  size_t state_size;
  void (*update)(void* ks, le_fx_dyn_head* h, const float* p, int sr, int f);
  void (*kprocess)(void* ks, float* l, float* r);
  /* A heap-state kind whose long lines live in the slot's rings, which its
   * `prepare` allocates (the echo and the reverbs): run instead of
   * `kprocess`, with the rings and their length (the sample rate). The
   * second ring is NULL for a kind whose `prepare` makes only the first
   * (the Freeverb); a slot without the first passes the input untouched,
   * and so does a kind that needs both and lacks the second. Its block
   * tracks which parts of the rings it has written, so the rings are never
   * cleared for it. */
  void (*rkprocess)(void* ks, float* r0, float* r1, int cap, float* l,
                    float* r);
  /* A heap-state kind locked to the beat (the Rhythmic LPF's LFO): given,
   * just before each `update`, the beat in quarter notes of the last frame
   * that update covers (where a setting it ramps toward lands). NULL for
   * the rest. */
  void (*beat)(void* ks, double beat);
  /* A heap-state kind with an LFO on the engine clock (the echo's wow): its
   * rate, Hz, whose phase the chain works out each sample through the
   * slot's clock LFO (le_clock_lfo) and hands the kernel in its block
   * (le_fx_kind_lfo). 0 for the rest. */
  double lfo_hz;
} le_fx_vtable;

/* Bypass drains the tail instead of crossfading out: a linear kind that
 * holds a tail in rings and reports no latency (delay, echo, reverb, whose
 * rings `prepare` allocates; the spring, whose ring is in its kind block). */
#define LE_FX_F_DRAINS 1u
/* A free-running modulator (an LFO that runs on whatever the loop does), or
 * a kind on the octaver's kernel, whose phase vocoder carries running
 * synthesis phases a loop advances by a fraction of a cycle each lap
 * (#1624): the kind sounds different each lap, so a chain holding it is
 * never printed (le_fx_type_free_running). */
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
                       fx_octaver_prepare, LE_FX_OCTAVER_PARAMS,
                       LE_FX_F_FREE_RUNNING},
    /* The echo and the Freeverb keep their state in the block and their
     * lines in the slot's rings, and drain their tails on bypass. */
    [LE_FX_ECHO] = {NULL, NULL, fx_stereo_ring_prepare, LE_FX_ECHO_PARAMS,
                    LE_FX_F_DRAINS, sizeof(le_fx_echo), fx_echo_update, NULL,
                    fx_echo_rkprocess, NULL, LE_ECHO_WOW_HZ},
    [LE_FX_REVERB] = {NULL, NULL, fx_reverb_prepare, LE_FX_REVERB_PARAMS,
                      LE_FX_F_DRAINS, sizeof(le_fx_rev), fx_reverb_update, NULL,
                      fx_reverb_rkprocess},
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
    /* The waveshapers run oversampled, a fixed number of frames late. */
    [LE_FX_OVERDRIVE] = {NULL, fx_os_latency_vt, NULL, LE_FX_OVERDRIVE_PARAMS, 0,
                         sizeof(le_fx_overdrive), fx_overdrive_update,
                         fx_overdrive_kprocess},
    [LE_FX_DISTORTION] = {NULL, fx_os_latency_vt, NULL, LE_FX_DISTORTION_PARAMS, 0,
                          sizeof(le_fx_distortion), fx_distortion_update,
                          fx_distortion_kprocess},
    [LE_FX_VINYL] = {NULL, fx_os_latency_vt, NULL, LE_FX_VINYL_PARAMS,
                     LE_FX_F_FREE_RUNNING,
                     sizeof(le_fx_vinyl), fx_vinyl_update, fx_vinyl_kprocess},
    [LE_FX_DEGRADE] = {NULL, fx_degrade_latency_vt, NULL, LE_FX_DEGRADE_PARAMS,
                       LE_FX_F_FREE_RUNNING, sizeof(le_fx_degrade),
                       fx_degrade_update, fx_degrade_kprocess},
    [LE_FX_LPF] = {NULL, fx_lpf_latency_vt, NULL, LE_FX_LPF_PARAMS,
                   LE_FX_F_FREE_RUNNING,
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
                      fx_octaver_prepare, LE_FX_WHAMMY_PARAMS,
                      LE_FX_F_FREE_RUNNING},
    /* The octaver's kernel and state, its settings mapped (le_doct_settings). */
    [LE_FX_DUAL_OCTAVER] = {fx_dual_octaver_process, fx_octaver_latency_vt,
                            fx_dual_octaver_prepare, LE_FX_DUAL_OCTAVER_PARAMS,
                            LE_FX_F_FREE_RUNNING},
    /* The amp and its cabinet, in its own per-slot instance (fx->amp). */
    [LE_FX_AMP_CAB] = {fx_amp_cab_process, fx_os_latency_vt, fx_amp_cab_prepare,
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
    [LE_FX_MOD] = {NULL, NULL, NULL, LE_FX_MOD_PARAMS, LE_FX_F_FREE_RUNNING,
                   sizeof(le_fx_mod), fx_mod_update, fx_mod_kprocess},
    [LE_FX_ROOM_VERB] = {NULL, NULL, fx_stereo_ring_prepare,
                         LE_FX_ROOM_VERB_PARAMS, LE_FX_F_DRAINS,
                         sizeof(le_fx_rverb), fx_room_verb_update, NULL,
                         fx_room_verb_rkprocess},
    /* The octaver's kernel and state, its shift following the detected
     * pitch (fx_smart_tune_process). */
    [LE_FX_SMART_TUNE] = {fx_smart_tune_process, fx_octaver_latency_vt,
                          fx_octaver_prepare, LE_FX_SMART_TUNE_PARAMS,
                          LE_FX_F_FREE_RUNNING},
};
#define LE_FX_TYPE_COUNT ((int32_t)(sizeof(LE_FX) / sizeof(LE_FX[0])))

/* Each type's descriptor count: the only copy, read by le_fx_param_width,
 * le_fx_param_count and le_fx_defaults. A type with descriptor rows and no
 * entry here would read nothing; test_fx_params_past_count_are_inert checks
 * every built-in has one. */
#define LE_FX_ROW_COUNT(t) (uint8_t)(sizeof(t) / sizeof(t[0]))
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
    [LE_FX_MOD] = LE_FX_ROW_COUNT(LE_FX_MOD_PARAMS),
    [LE_FX_ROOM_VERB] = LE_FX_ROW_COUNT(LE_FX_ROOM_VERB_PARAMS),
    [LE_FX_SMART_TUNE] = LE_FX_ROW_COUNT(LE_FX_SMART_TUNE_PARAMS),
};

/* ---- per-kind state (le_fx_kinds, engine_private.h) ---- */

/* A block's header; the kind's state follows at LE_FX_KIND_HEAD. The
 * header holds the change detection every kind shares (le_fx_dyn_begin):
 * the settings the kind last saw, as many as its type reads. */
#define LE_FX_KIND_ALIGN 64
typedef struct le_fx_kind_block {
  struct le_fx_kind_block* next; /* set before the block is published */
  int32_t type;
  int32_t settle; /* audio thread: the next update lands at once */
  uint32_t seed;  /* audio thread: set with each clear (le_fx_kind_seed) */
  le_fx_dyn_head h;           /* audio thread */
  float last[LE_FX_PARAMS];   /* audio thread: the settings h saw */
  float lfo;      /* audio thread: the clock LFO's phase this sample, cycles */
} le_fx_kind_block;
#define LE_FX_KIND_HEAD                                       \
  ((sizeof(le_fx_kind_block) + LE_FX_KIND_ALIGN - 1) &        \
   ~(size_t)(LE_FX_KIND_ALIGN - 1))

static inline void* le_fx_kind_payload(le_fx_kind_block* b) {
  return (unsigned char*)b + LE_FX_KIND_HEAD;
}

static float le_fx_kind_lfo(const void* ks) {
  return ((const le_fx_kind_block*)((const unsigned char*)ks -
                                    LE_FX_KIND_HEAD))->lfo;
}

static uint32_t le_fx_kind_seed(const void* ks) {
  return ((const le_fx_kind_block*)((const unsigned char*)ks -
                                    LE_FX_KIND_HEAD))->seed;
}

static size_t le_fx_kind_block_bytes(int32_t type) {
  const size_t n = LE_FX[type].state_size;
  return LE_FX_KIND_HEAD +
         ((n + LE_FX_KIND_ALIGN - 1) & ~(size_t)(LE_FX_KIND_ALIGN - 1));
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
  /* Sized for this kind only, so a slot pays for the kinds it has held. */
  le_fx_kind_block* b =
      (le_fx_kind_block*)le_rt_alloc_prefaulted(le_fx_kind_block_bytes(type));
  if (b == NULL) return LE_ERR_INVALID;
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
  le_fx_kind_block* b = atomic_load_explicit(&ks->head, memory_order_relaxed);
  atomic_store_explicit(&ks->head, NULL, memory_order_relaxed);
  ks->cur = NULL;
  while (b != NULL) {
    le_fx_kind_block* next = b->next;
    le_rt_free(b);
    b = next;
  }
}

void le_fx_free_kind_table(le_fx_state* fx) {
  le_fx_kinds* k = atomic_load_explicit(&fx->kinds, memory_order_relaxed);
  if (k == NULL) return;
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_free_kinds(fx, s);
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
    memset(&b->h, 0, sizeof(b->h)); /* sees no settings yet */
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
    const int f = le_fx_dyn_begin(&b->h, b->last, p,
                                   (size_t)le_fx_param_width(ty), sr, b->settle);
    LE_FX[ty].update(st, &b->h, p, sr, f);
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
    if (LE_FX[ty].lfo_hz > 0.0) {
      ((le_fx_kind_block*)((unsigned char*)st - LE_FX_KIND_HEAD))->lfo =
          (float)le_clock_lfo(fx, s, LE_FX[ty].lfo_hz, sr);
    }
    if (LE_FX[ty].rkprocess != NULL) {
      /* Only the rings this kind runs on, or ones an earlier kind left: the
       * control thread may be making the other for a coming retype
       * (#1522). */
      const int rings = le_fx_ring_count(ty);
      float* r0 = le_fx_ring_readable(fx, s, 0, rings) ? fx->delay[s][0] : NULL;
      float* r1 = le_fx_ring_readable(fx, s, 1, rings) ? fx->delay[s][1] : NULL;
      if (r0 != NULL) LE_FX[ty].rkprocess(st, r0, r1, cap, l, r);
      return;
    }
    LE_FX[ty].kprocess(st, l, r);
    return;
  }
  LE_FX[ty].process(fx, s, sr, cap, l, r, p);
}

/* Whether slot [s] as [type] holds state that re-enabling must clear, spaced
 * (enable_clear_cooldown): the rings `prepare` allocated (the delay, the
 * octaver), a draining heap-state kind's block (the spring's ring; the
 * echo's and the reverbs' record of what their rings hold), or a block of
 * LE_FX_SPACED_CLEAR_BYTES or more (the doubler's, the chorus's and the
 * mod's lines). A renewed entry enters through the enable edge for the same
 * reason (le_fx_entry_renew). */
static int le_fx_holds_tail(const le_fx_state* fx, int s, int32_t type) {
  if (type <= LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return 0;
  /* A heap-state kind: a draining one's block holds its tail, and a large
   * block costs enough to clear that its reset is spaced like a ring's
   * (LE_FX_SPACED_CLEAR_BYTES). */
  if (LE_FX[type].state_size != 0) {
    return (LE_FX[type].flags & LE_FX_F_DRAINS) != 0 ||
           LE_FX[type].state_size >= LE_FX_SPACED_CLEAR_BYTES;
  }
  if (type == LE_FX_MODE_DELAY) {
    return atomic_load_explicit(&fx->line[s], memory_order_acquire) != NULL;
  }
  if (LE_FX[type].prepare == NULL) return 0;
  const int rings = le_fx_ring_count(type);
  for (int c = 0; c < 2; ++c) {
    if (le_fx_ring_readable(fx, s, c, rings) && fx->delay[s][c] != NULL) {
      return 1;
    }
  }
  return 0;
}

/* Both rings for the ring kinds and the octaver family, the first alone for
 * the Reverb, none for any other kind. Only these are published to the thread
 * running a slot as [type]; the others may be in the making on the control
 * thread for a coming retype (#1522). */
static int le_fx_ring_count(int32_t type) {
  if (type <= LE_FX_NONE || type >= LE_FX_TYPE_COUNT) return 0;
  int32_t (*const prepare)(le_fx_state*, int, int) = LE_FX[type].prepare;
  if (prepare == fx_reverb_prepare) return 1;
  return prepare == fx_stereo_ring_prepare || prepare == fx_octaver_prepare ||
                 prepare == fx_dual_octaver_prepare
             ? 2
             : 0;
}

void le_fx_entry_renew(le_fx_state* fx, int slot, int32_t type, int sounding) {
  le_fx_entry_reset(fx, slot, type);
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
    case LE_FX_DEGRADE: /* holding (below its kernel's rate), and heard */
      return le_fx_desc_value(&LE_FX_DEGRADE_PARAMS[0], p[0]) <
                 (double)(le_deg_halved(sr) ? sr / 2 : sr > 0 ? sr : 48000) &&
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
    case LE_FX_MOD: /* the tremolo dipping, or the others swept and heard */
      return le_mod_mode(p[3]) == LE_MOD_TREMOLO ? p[1] > 0.0f
                                                  : p[1] > 0.0f && p[2] > 0.0f;
    case LE_FX_SLICER: /* heard */
      return p[2] > 0.0f;
    /* The octaver's kernel (#1624), heard and shifting: */
    case LE_FX_OCTAVER: /* its voice in the mix */
      return p[2] > 0.0f;
    case LE_FX_DUAL_OCTAVER: /* in the mix, an octave up */
      return p[2] > 0.0f && (p[1] > 0.0f || p[3] > 0.0f);
    case LE_FX_WHAMMY: /* off unison (the pedal at 0 shifts nothing) */
      return p[0] > 0.0f;
    case LE_FX_SMART_TUNE: /* always correcting */
      return 1;
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

LE_AUDIO_HOT_AT(4) void fx_apply_chain_with_gain(le_fx_state* fx, int sr, int cap, float* l, float* r,
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
        LE_FX_DRAIN_STORE(fx, s, 0);
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
           * heap-state kind, or one with a large block
           * (LE_FX_SPACED_CLEAR_BYTES), is spaced the same way: the reset
           * clears its block (the spring's ring, the doubler's and the
           * chorus's delay lines live there). A ring kernel
           * (`rkprocess`: the echo and the reverbs) skips the ring clear:
           * its cleared block marks every structure unwrapped, so it reads
           * silence until it has written there again. */
          /* The Mode delay reads only its own line, which the reset
           * empties at once: no ring to clear, no spacing to wait on, and
           * any 1 s rings an earlier kind left stay as they are, unread. */
          const int needs_clear =
              ty != LE_FX_MODE_DELAY && le_fx_holds_tail(fx, s, ty);
          if (needs_clear && fx->enable_clear_cooldown > 0) goto slot_done;
          le_fx_entry_reset(fx, s, ty);
          if (needs_clear) {
            if (LE_FX[ty].prepare != NULL && LE_FX[ty].rkprocess == NULL)
              le_fx_entry_clear_rings(fx, s, cap, ty);
            fx->enable_clear_cooldown = LE_FX_ENABLE_CLEAR_SPACING;
          }
          fx->enable_warmup[s] = le_fx_added_latency(fx, s, ty, sr);
        } else if (!want) {
          fx->enable_warmup[s] = 0; /* an aborted warmup never resumes */
          /* Bypass edge: mark the tail draining once the feed has
           * ramped to silence; none for a latency-bearing slot, which
           * crossfades out instead (see above). */
          LE_FX_DRAIN_STORE(fx, s, le_fx_type_drains(ty) ? 1 : 0);
          fx->enable_quiet[s] = 0;
        }
        if (want) LE_FX_DRAIN_STORE(fx, s, 0); /* fed again: nothing to drain */
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
            LE_FX_DRAIN_STORE(fx, s, 0);
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

LE_AUDIO_HOT_AT(8) void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS],
                    const int32_t* enabled) {
  fx_apply_chain_with_gain(fx, sr, cap, l, r, count, types, params, enabled, 0, 1);
}

void fx_apply_chain_from(le_fx_state* fx, int sr, int cap, float* l,
                         float* r, int from, int count, const int32_t* types,
                         const float params[LE_FX_MAX][LE_FX_PARAMS],
                         const int32_t* enabled, int counted) {
  const int32_t cooldown = fx->enable_clear_cooldown;
  if (from <= 0) {
    fx_apply_chain(fx, sr, cap, l, r, count, types, params, enabled);
    if (counted && fx->enable_clear_cooldown == (cooldown > 0 ? cooldown - 1 : 0)) {
      fx->enable_clear_cooldown = cooldown;
    }
    return;
  }
  if (from >= count) return;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  /* The entries before [from] pass the signal on as an empty slot does,
   * their racks' edges out of the walk. The ring-clear cooldown counts a
   * frame once: when a walk over [0, from) already counted this one
   * ([counted]), this walk's count is taken back, unless a clear in it set
   * the spacing anew. The shared walk stays the one the mixer runs. */
  int32_t ty[LE_FX_MAX];
  int32_t racks[LE_FX_MAX];
  for (int s = 0; s < count; ++s) ty[s] = s < from ? LE_FX_NONE : types[s];
  for (int s = 0; s < from; ++s) {
    racks[s] = fx->chan[s].rack;
    fx->chan[s].rack = 0;
  }
  fx_apply_chain_with_gain(fx, sr, cap, l, r, count, ty, params, enabled, 0, 1);
  if (counted && fx->enable_clear_cooldown == (cooldown > 0 ? cooldown - 1 : 0)) {
    fx->enable_clear_cooldown = cooldown;
  }
  for (int s = 0; s < from; ++s) fx->chan[s].rack = racks[s];
}

int le_fx_added_latency(const le_fx_state* fx, int slot, int32_t type, int sr) {
  if (type > LE_FX_NONE && type < LE_FX_TYPE_COUNT && LE_FX[type].latency) {
    return LE_FX[type].latency(fx, slot, type, sr);
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
