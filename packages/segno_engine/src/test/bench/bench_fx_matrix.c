/*
 * bench_fx_matrix.c — every effect kind at every sample rate and buffer size
 * the app offers (#1547).
 *
 * The full run is a bench: ./bench_fx_matrix.sh. The native tests run a CI
 * subset of it (--ci, run_native_tests.sh).
 *
 * WHY: an effect should sound the same at 44.1, 48 and 96 kHz and at any
 * block from 32 to 512 frames. A coefficient designed in samples, a time
 * constant counted in blocks, or a waveshaper whose harmonics fold back at
 * the lower rates all break that, and nothing else in the suite runs a kind
 * at more than one rate and block.
 *
 * Each setting runs through the real engine (le_engine_process), one kind in
 * a monitored input's chain, so whatever the engine does per block is in the
 * measurement. The settings are every distinct entry the factory racks build
 * (fx_factory_settings.inc, generated from the catalogue by
 * packages/looper_repository/tool/generate_fx_factory_settings.dart), plus
 * each kind at its defaults, which covers the kinds no rack uses.
 *
 * The checks, each per kind and rate:
 *
 *   block     The plucked phrase (below) at blocks of 32, 64, 128, 256 and
 *             512 frames must be bit-identical to the 32-frame render. Every
 *             kind runs per sample, and the hop kinds (the octaver family)
 *             and the update hooks keep their schedules on the engine's
 *             frame clock rather than on the block, so there is no reason
 *             for any output to differ: bit exactness is the tolerance, for
 *             every kind, the hop kinds included.
 *   response  At 44.1 and 96 kHz against 48 kHz: the output's level in each
 *             third of an octave from 40 Hz to 16 kHz, on a steady pink
 *             multitone, within MX_RESPONSE_DB. This is the frequency
 *             response, the pitch (a shifted voice moves its energy to other
 *             bands) and the level. A kind that rings (le_fx_type_drains:
 *             the delays and reverbs) is read in octaves: its response is a
 *             comb of modes that land a little differently at each rate
 *             however its times are set, and a third of an octave at the
 *             bottom holds only a few of them.
 *   envelope  At 44.1 and 96 kHz against 48 kHz: the plucked phrase's level
 *             every 5 ms, within MX_ENVELOPE_DB on all but MX_ENVELOPE_SHARE
 *             of the frames that matter. This is the attack, release and
 *             decay times, the delay times and the LFO rates, all in
 *             milliseconds. Each render is first moved back by the latency
 *             the engine reports for it: what is compared is the sound, and
 *             the latency is reported and compensated elsewhere.
 *   alias     At each rate, a -12 dBFS sine at E4, E5 and E6 (330, 659 and
 *             1319 Hz, the top of a guitar): the energy its harmonics fold
 *             onto below 20 kHz at least MX_ALIAS_DB below the output, read
 *             by bench_alias's measurement (alias_spectrum.h, #1540). Only
 *             for the kinds whose output on a sine is meant to be its
 *             harmonics (mx_kind::harmonic), and not at a setting whose
 *             free-running modulator is heard (le_fx_entry_free_running).
 *   blowup    At each rate, every render: no NaN or infinity, and a peak
 *             below MX_PEAK_LIMIT.
 *   dc        At each rate: no DC beyond MX_DC_LIMIT, read as the
 *             Hann-weighted mean of the alias sines' windows (whole cycles, so a curve that is
 *             not lopsided leaves zero) and of the phrase's last half
 *             second, which is silence.
 *   stall     The silent tail of the plucked phrase may cost at most
 *             MX_STALL_RATIO times what the notes cost a frame (medians of
 *             the 512-frame blocks): a kind whose work grows once the input
 *             stops. The engine flushes denormals each callback (FTZ, and
 *             DAZ on x86), as it does on the console, so this reads the tail
 *             as shipped; a kernel that went denormal on a platform without
 *             the flush would show here. Timing, so it is reported and never
 *             fails a run.
 *
 * The input signals are functions of time, the same at every rate, and
 * band-limited to 18 kHz so the 44.1 kHz render loses nothing:
 *
 *   - the plucked phrase: E2, A2, D3, G3, B3, E4, E5 and E6, 400 ms apart,
 *     each with harmonics to 12 kHz, a 2 ms attack and a 250 ms decay,
 *     after 100 ms of silence and before 1.1 s of it (4.6 s);
 *   - the multitone: every even hertz from 36 Hz to 18 kHz, pink, at
 *     -20 dBFS RMS, faded in over 50 ms and read over its second second;
 *   - the alias sines: faded in over 10 ms, one second to settle, then a
 *     65536-frame window (131072 at 96 kHz), as bench_alias.
 *
 * 48 kHz is the reference for response and envelope because the kinds are
 * fitted to the Looper X's captures, which run at 48 kHz.
 *
 * KNOWN FAILURES: what fails today is listed in k_known, by kind, check and
 * rate, with the worst figure it may reach. A failure on the list within
 * that ceiling does not fail the run; one past it does, as does one that
 * is not on the list, and so, in the full run, does an entry on the list
 * that now passes or is no longer read (its fix forgot to take it off).
 * The CI subset runs one setting a kind, so an entry it does not reproduce
 * is only reported there.
 *
 *   ./bench_fx_matrix.sh                    # every setting
 *   ./bench_fx_matrix.sh --kind overdrive   # one kind
 *   ./bench_fx_matrix.sh --detail           # every setting's figures
 *   ./bench_fx_matrix.sh --jobs 4           # worker threads (default: cores)
 *   ./bench_fx_matrix.sh --ci               # the native tests' subset
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif

#include "segno_engine_api.h"
#include "engine_fx.h" /* le_fx_defaults, le_fx_type_hops, ... */
#include "bench_common.h"
#include "alias_spectrum.h"

/* ---------------- tolerances ---------------- */

/* response: 1 dB, about the smallest change in a band's level that a
 * listener picks out on music, and what the EQ's per-rate fit (#1436)
 * holds its bells to. */
#define MX_RESPONSE_DB 1.0
/* Bands more than this far below the loudest are not judged: they are a
 * filter's stopband or a notch, which is not the sound, and their level
 * rests on rounding. The Dual Octaver's top bands, 40 to 50 dB down, read
 * 12 dB apart on macOS and 22 dB on Linux from the same code. */
#define MX_RESPONSE_FLOOR_DB 40.0
/* envelope: 1.5 dB on all but 2 % of the frames that matter. The kinds that
 * keep their times in milliseconds stay within 0.8 dB on every frame; the
 * 2 % lets through what is random by design, the vinyl's clicks and the
 * doubler's wander, which land on other frames at each rate. A time
 * constant, a delay time or an LFO rate that is off moves many more frames
 * than that, by several dB. */
#define MX_ENVELOPE_DB 1.5
#define MX_ENVELOPE_SHARE 0.02
/* Frames more than this far below the loudest are not judged. */
#define MX_ENVELOPE_FLOOR_DB 40.0
/* alias: #1547's bar, on guitar notes up to E6. */
#define MX_ALIAS_DB (-60.0)
/* blowup: +12 dBFS is 22 dB over the phrase's -10 dBFS peak, past any
 * kind's own gain (a rack's level is applied after the kind, and the
 * matrix runs the kind alone), and -60 dBFS of DC steps by that much when
 * the effect is bypassed. */
#define MX_PEAK_LIMIT 4.0
#define MX_DC_LIMIT 1e-3
/* stall: a denormal costs tens to hundreds of times a normal operation;
 * three times is past what preemption leaves in a median. */
#define MX_STALL_RATIO 3.0

/* ---------------- the matrix ---------------- */

#define MX_NRATES 3
static const int k_rates[MX_NRATES] = {44100, 48000, 96000};
#define MX_REF 1 /* 48 kHz, k_rates' index */
#define MX_NBLOCKS 5
static const int k_blocks[MX_NBLOCKS] = {32, 64, 128, 256, 512};

typedef struct {
  const char* name;
  int32_t type;
  float p[LE_FX_PARAMS];
} mx_setting;

static const mx_setting k_factory[] = {
#include "fx_factory_settings.inc"
};
#define MX_NFACTORY (int)(sizeof(k_factory) / sizeof(k_factory[0]))

/* [harmonic]: on a steady sine the kind's output is meant to hold that
 * sine's harmonics and nothing else (a waveshaper, a filter, a level
 * follower), so whatever lands on the bins its harmonics fold to is
 * aliasing, and the alias check reads it. The rest move the pitch (the hop
 * kinds), modulate it (sidebands are their sound) or ring at their own
 * modes, and are not read for it. */
typedef struct {
  int32_t type;
  const char* name;
  int harmonic;
} mx_kind;

static const mx_kind k_kinds[] = {
    {LE_FX_DRIVE, "drive", 1},         {LE_FX_FILTER, "filter", 1},
    {LE_FX_DELAY, "delay", 0},         {LE_FX_TREMOLO, "tremolo", 0},
    {LE_FX_OCTAVER, "octaver", 0},     {LE_FX_ECHO, "echo", 0},
    {LE_FX_REVERB, "reverb", 0},       {LE_FX_EQ, "eq", 1},
    {LE_FX_COMPRESSOR, "comp", 1},     {LE_FX_TRANSIENT, "transient", 1},
    {LE_FX_HP_GATE, "hpgate", 1},      {LE_FX_DOUBLER, "doubler", 0},
    {LE_FX_CHORUS, "chorus", 0},       {LE_FX_WAH, "wah", 1},
    {LE_FX_OVERDRIVE, "overdrive", 1}, {LE_FX_DISTORTION, "distortion", 1},
    {LE_FX_VINYL, "vinyl", 1},         {LE_FX_DEGRADE, "degrade", 1},
    {LE_FX_LPF, "lpf", 1},             {LE_FX_SPRING, "spring", 0},
    {LE_FX_DUB_VERB, "dubverb", 0},    {LE_FX_AMB_VERB, "ambverb", 0},
    {LE_FX_WHAMMY, "whammy", 0},       {LE_FX_PUMPER, "pumper", 0},
    {LE_FX_SLICER, "slicer", 0},       {LE_FX_MODE_DELAY, "modedelay", 0},
    {LE_FX_DUAL_OCTAVER, "dualoct", 0}, {LE_FX_AMP_CAB, "ampcab", 1},
    {LE_FX_MOD, "mod", 0},             {LE_FX_ROOM_VERB, "roomverb", 0},
    {LE_FX_SMART_TUNE, "smarttune", 0},
};
#define MX_NKINDS (int)(sizeof(k_kinds) / sizeof(k_kinds[0]))

static int kind_index(int32_t type) {
  for (int k = 0; k < MX_NKINDS; ++k) {
    if (k_kinds[k].type == type) return k;
  }
  return -1;
}

enum {
  MX_BLOCK,
  MX_RESPONSE,
  MX_ENVELOPE,
  MX_ALIAS,
  MX_BLOWUP,
  MX_DC,
  MX_STALL,
  MX_NCHECKS
};
static const char* const k_check_names[MX_NCHECKS] = {
    "block", "response", "envelope", "alias", "blowup", "dc", "stall"};

/* ---------------- known failures ---------------- */

/* [ceiling]: the worst figure the entry allows, in the check's unit (dB
 * for response, envelope and alias, dBFS for dc): the worst today on
 * macOS (arm64, clang) and Linux (gcc) plus at least 1 dB. The hop kinds'
 * figures differ by up to 0.3 dB between the two, through their libm. A listed kind that gets worse than that fails as new,
 * so the list does not hide a regression of a kind already on it. */
typedef struct {
  const char* kind;
  int check;
  int rate;
  double ceiling;
} mx_known;

/* What fails today, emptied by the parts of #1547 that fix it. The full
 * run's table names the worst setting of each. */
static const mx_known k_known[] = {
    /* The transient shaper's peak envelope, which rises at once to the
     * largest sample of each cycle, ripples off the harmonics: the
     * envelope, not a curve, so oversampling is not its fix (part 3). */
    {"transient", MX_ALIAS, 44100, -46.5},
    {"transient", MX_ALIAS, 48000, -46.0},
    {"transient", MX_ALIAS, 96000, -57.0},
    /* The Dual Octaver is sensitive to tiny input changes: adding -120 dB
     * of noise at 48 kHz moves its envelope as far as running at 44.1 or
     * 96 kHz does, most likely through the low band's pitch detection. Its
     * kernel runs at 48 kHz at every rate (part 3c), so the residue is
     * that sensitivity, not a rate dependence. */
    {"dualoct", MX_ENVELOPE, 44100, 5.0},
    {"dualoct", MX_ENVELOPE, 96000, 5.0},
    {NULL, 0, 0, 0.0},
};

static const mx_known* known_entry(int kind, int check, int rate) {
  for (const mx_known* k = k_known; k->kind != NULL; ++k) {
    if (k->check == check && k->rate == rate &&
        !strcmp(k->kind, k_kinds[kind].name)) {
      return k;
    }
  }
  return NULL;
}

/* ---------------- the input signals ---------------- */

#define MX_PLUCK_MS 4600
#define MX_PLUCK_S (MX_PLUCK_MS / 1000.0)
#define MX_PLUCK_LEAD_S 0.1
#define MX_PLUCK_STEP_S 0.4
#define MX_PLUCK_RING_S 0.6   /* each note's length, its release included */
#define MX_PLUCK_TAIL_S 3.6   /* where the tail the stall check reads starts */
#define MX_TONES_S 2.0
#define MX_ALIAS_SETTLE_S 1.0

static const double k_notes[8] = {82.41, 110.0, 146.83, 196.0,
                                  246.94, 329.63, 659.26, 1318.51};

/* A raised-cosine ramp from 0 at [t] = 0 to 1 at [t] = [len]. */
static double ramp(double t, double len) {
  if (t <= 0.0) return 0.0;
  if (t >= len) return 1.0;
  return 0.5 - 0.5 * cos(M_PI * t / len);
}

static float* make_pluck(int sr, int64_t* n_out) {
  const int64_t n = (int64_t)(MX_PLUCK_S * sr);
  float* x = (float*)calloc((size_t)n, sizeof(float));
  if (x == NULL) exit(1);
  for (int k = 0; k < 8; ++k) {
    const double t0 = MX_PLUCK_LEAD_S + k * MX_PLUCK_STEP_S;
    const double f = k_notes[k];
    int harm = (int)(12000.0 / f);
    if (harm > 24) harm = 24;
    const int64_t a = (int64_t)ceil(t0 * sr);
    const int64_t b = (int64_t)ceil((t0 + MX_PLUCK_RING_S) * sr);
    for (int64_t i = a; i < b && i < n; ++i) {
      const double t = (double)i / sr - t0;
      const double env = ramp(t, 0.002) * exp(-t / 0.25) *
                         ramp(MX_PLUCK_RING_S - t, 0.02);
      double v = 0.0;
      for (int h = 1; h <= harm; ++h) {
        v += sin(2.0 * M_PI * f * h * t) / pow(h, 1.2);
      }
      x[i] += (float)(0.2 * env * v);
    }
  }
  *n_out = n;
  return x;
}

/* The steady tones: every even hertz from MX_TONE_LO to MX_TONE_HI, pink
 * (equal energy in every band) at -20 dBFS RMS in all, with phases from a
 * fixed sequence so they sum to something noise-like rather than to one
 * peak. Whole hertz, so the input repeats every second exactly, at every
 * rate. */
#define MX_TONE_LO 36
#define MX_TONE_HI 18000

static float* make_tones(int sr, int64_t* n_out) {
  const int64_t n = (int64_t)(MX_TONES_S * sr);
  double* period = (double*)calloc((size_t)sr, sizeof(double));
  float* x = (float*)calloc((size_t)n, sizeof(float));
  if (period == NULL || x == NULL) exit(1);
  uint32_t rng = 1547u;
  double power = 0.0;
  for (int f = MX_TONE_LO; f <= MX_TONE_HI; f += 2) {
    rng = rng * 1664525u + 1013904223u;
    const double ph = 2.0 * M_PI * (double)(rng >> 8) / 16777216.0;
    const double a = 1.0 / sqrt((double)f);
    power += 0.5 * a * a;
    /* One second of the tone by a rotating phasor, renormalised now and
     * then so it stays on the unit circle. */
    double c = cos(ph), si = sin(ph);
    const double cw = cos(2.0 * M_PI * f / sr), sw = sin(2.0 * M_PI * f / sr);
    for (int i = 0; i < sr; ++i) {
      period[i] += a * si;
      const double c2 = c * cw - si * sw;
      si = si * cw + c * sw;
      c = c2;
      if ((i & 1023) == 1023) {
        const double m = 1.0 / sqrt(c * c + si * si);
        c *= m;
        si *= m;
      }
    }
  }
  const double g = 0.1 / sqrt(power); /* -20 dBFS RMS */
  for (int64_t i = 0; i < n; ++i) {
    const double t = (double)i / sr;
    x[i] = (float)(g * ramp(t, 0.05) * period[i % sr]);
  }
  free(period);
  *n_out = n;
  return x;
}

/* The alias sines' window and bin at [sr]: whole cycles of the window, on an
 * odd bin, as near [hz] as that allows. */
static const double k_alias_hz[3] = {329.63, 659.26, 1318.51};

static int alias_win(int sr) { return sr > 48000 ? 131072 : 65536; }

static int alias_bin(int sr, double hz) {
  const int win = alias_win(sr);
  int b = (int)lround(hz * win / sr);
  if ((b & 1) == 0) b += 1;
  return b;
}

/* ---------------- rendering ---------------- */

typedef struct {
  float* l;
  float* r;
  int64_t n;
  int32_t latency; /* frames the engine reports for the chain */
  double ns_active, ns_tail; /* per frame, notes and silent tail */
} mx_out;

static void out_free(mx_out* o) {
  free(o->l);
  free(o->r);
  memset(o, 0, sizeof(*o));
}

/* [in] (mono, [n] frames) through [s] in input 0's monitor chain at [sr],
 * [block] frames a callback, into [o] (both output channels). [tail_from]
 * splits the timing: the frames before it are "active". */
static int render(const mx_setting* s, int sr, int block, const float* in,
                  int64_t n, int64_t tail_from, mx_out* o) {
  memset(o, 0, sizeof(*o));
  le_engine* e = le_engine_create();
  if (e == NULL) return 0;
  int ok = le_engine_configure(e, sr, 1, 2, sr) == LE_OK &&
           le_engine_set_monitor_input(e, 0, 1) == LE_OK &&
           le_engine_set_monitor_input_output(e, 0, 3) == LE_OK &&
           le_engine_set_monitor_input_fx(e, 0, 0, s->type) == LE_OK;
  for (int p = 0; ok && p < le_fx_param_width(s->type); ++p) {
    ok = le_engine_set_monitor_input_fx_param(e, 0, 0, p, s->p[p]) == LE_OK;
  }
  ok = ok && le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK;
  float* buf = (float*)malloc(sizeof(float) * 2 * (size_t)block);
  o->l = (float*)malloc(sizeof(float) * (size_t)n);
  o->r = (float*)malloc(sizeof(float) * (size_t)n);
  if (!ok || buf == NULL || o->l == NULL || o->r == NULL) {
    free(buf);
    out_free(o);
    le_engine_destroy(e);
    return 0;
  }
  o->n = n;
  /* Each block's cost a frame, notes and tail apart: their medians, so a
   * worker preempted for a block does not read as a stall. */
  const size_t nb = (size_t)((n + block - 1) / block);
  double* t_active = (double*)malloc(sizeof(double) * nb);
  double* t_tail = (double*)malloc(sizeof(double) * nb);
  size_t n_active = 0, n_tail = 0;
  le_snapshot* snap = (le_snapshot*)calloc(1, sizeof(le_snapshot));
  for (int64_t at = 0; at < n; at += block) {
    const int64_t len = n - at < block ? n - at : block;
    const double t0 = now_us();
    le_engine_process(e, buf, in + at, (uint32_t)len);
    const double ns = 1e3 * (now_us() - t0) / (double)len;
    if (t_active != NULL && t_tail != NULL) {
      if (at >= tail_from) {
        t_tail[n_tail++] = ns;
      } else {
        t_active[n_active++] = ns;
      }
    }
    for (int64_t f = 0; f < len; ++f) {
      o->l[at + f] = buf[2 * f];
      o->r[at + f] = buf[2 * f + 1];
    }
  }
  /* The latency the chain reports once it has run the whole input. */
  if (snap != NULL) {
    le_engine_get_snapshot(e, snap);
    o->latency = snap->fx_added_latency_frames;
  }
  o->ns_active = n_active ? stats_of(t_active, n_active).p50 : 0.0;
  o->ns_tail = n_tail ? stats_of(t_tail, n_tail).p50 : 0.0;
  free(t_active);
  free(t_tail);
  free(snap);
  free(buf);
  le_engine_destroy(e);
  return 1;
}

/* ---------------- measurements ---------------- */

/* ---- An exact one-second spectrum ----
 * One second of output is sr frames, and every tone of the input is a whole
 * number of hertz, so a DFT of exactly sr points puts each on its own bin at
 * every rate, with no window and no leakage. sr is not a power of two
 * (44100 = 2^2 3^2 5^2 7^2, 48000 = 2^7 3 5^3, 96000 = 2^8 3 5^3), so this
 * is a plain mixed-radix Cooley-Tukey, its twiddles read from one table of
 * the sr-th roots of unity per rate. */

typedef struct {
  int n;
  int factors[32];
  int nf;
  double* wr; /* cos(2 pi j / n) */
  double* wi; /* -sin(2 pi j / n) */
} mx_plan;

static mx_plan g_plan[MX_NRATES];

static void plan_init(mx_plan* p, int n) {
  p->n = n;
  p->nf = 0;
  for (int m = n, d = 2; m > 1;) {
    if (m % d == 0) {
      p->factors[p->nf++] = d;
      m /= d;
    } else {
      d++;
    }
  }
  p->wr = (double*)malloc(sizeof(double) * (size_t)n);
  p->wi = (double*)malloc(sizeof(double) * (size_t)n);
  if (p->wr == NULL || p->wi == NULL) exit(1);
  for (int j = 0; j < n; ++j) {
    p->wr[j] = cos(2.0 * M_PI * j / n);
    p->wi[j] = -sin(2.0 * M_PI * j / n);
  }
}

static void plan_free(mx_plan* p) {
  free(p->wr);
  free(p->wi);
}

/* [n] outputs of the DFT of in[0], in[stride], ... into (or, oi), on
 * factors [f..]. */
static void dft_rec(const mx_plan* p, const float* in, int stride, int n,
                    int f, double* or_, double* oi) {
  if (n == 1) {
    or_[0] = in[0];
    oi[0] = 0.0;
    return;
  }
  const int r = p->factors[f];
  const int m = n / r;
  for (int q = 0; q < r; ++q) {
    dft_rec(p, in + q * stride, stride * r, m, f + 1, or_ + q * m, oi + q * m);
  }
  const int step = p->n / n; /* w_n^j is the table's entry j * step */
  double tr[16], ti[16];
  for (int k = 0; k < m; ++k) {
    for (int q = 0; q < r; ++q) {
      const int j = (int)(((int64_t)q * k * step) % p->n);
      const double xr = or_[q * m + k], xi = oi[q * m + k];
      tr[q] = xr * p->wr[j] - xi * p->wi[j];
      ti[q] = xr * p->wi[j] + xi * p->wr[j];
    }
    for (int s2 = 0; s2 < r; ++s2) {
      double ar = 0.0, ai = 0.0;
      for (int q = 0; q < r; ++q) {
        const int j = (int)(((int64_t)((q * s2) % r) * (p->n / r)) % p->n);
        ar += tr[q] * p->wr[j] - ti[q] * p->wi[j];
        ai += tr[q] * p->wi[j] + ti[q] * p->wr[j];
      }
      or_[s2 * m + k] = ar;
      oi[s2 * m + k] = ai;
    }
  }
}

/* The DFT reads a unit sine at 1 kHz as n / 2 on bin 1000 and nothing on
 * its neighbours, at [ri]'s rate, or the run stops. */
static void plan_check(int ri) {
  const mx_plan* p = &g_plan[ri];
  const int n = p->n;
  float* x = (float*)malloc(sizeof(float) * (size_t)n);
  double* re = (double*)malloc(sizeof(double) * (size_t)n);
  double* im = (double*)malloc(sizeof(double) * (size_t)n);
  if (x == NULL || re == NULL || im == NULL) exit(1);
  for (int i = 0; i < n; ++i) x[i] = (float)sin(2.0 * M_PI * 1000.0 * i / n);
  dft_rec(p, x, 1, n, 0, re, im);
  const double on = sqrt(re[1000] * re[1000] + im[1000] * im[1000]) / (0.5 * n);
  const double off = sqrt(re[999] * re[999] + im[999] * im[999]) / (0.5 * n);
  if (fabs(on - 1.0) > 1e-5 || off > 1e-5) {
    fprintf(stderr, "the %d-point DFT reads 1 kHz as %g and 999 Hz as %g\n", n,
            on, off);
    exit(2);
  }
  free(x);
  free(re);
  free(im);
}

/* The bands the response is read in: thirds of an octave from 40 Hz
 * (MX_BAND_K0) to 16 kHz, nine whole octaves of three. */
#define MX_BAND_K0 (-1)
#define MX_NBANDS 27

static double band_centre(int b) { return 50.0 * pow(2.0, (b + MX_BAND_K0) / 3.0); }

/* [x]'s level in dB in each band, over its second second (the input's
 * second period). */
static void band_levels(const float* x, int ri, double* db) {
  const mx_plan* p = &g_plan[ri];
  const int n = p->n;
  double* re = (double*)malloc(sizeof(double) * (size_t)n);
  double* im = (double*)malloc(sizeof(double) * (size_t)n);
  if (re == NULL || im == NULL) exit(1);
  dft_rec(p, x + n, 1, n, 0, re, im);
  for (int b = 0; b < MX_NBANDS; ++b) {
    const double c = band_centre(b);
    const int lo = (int)ceil(c * pow(2.0, -1.0 / 6.0));
    const int hi = (int)ceil(c * pow(2.0, 1.0 / 6.0));
    double e = 0.0;
    for (int f = lo; f < hi && f < n / 2; ++f) e += re[f] * re[f] + im[f] * im[f];
    /* A sine of amplitude A reads A n / 2 on its bin: per n, the levels
     * of every rate are on one scale. */
    db[b] = 10.0 * log10(e / ((double)n * n) + 1e-30);
  }
  free(re);
  free(im);
}

/* The largest |difference| in dB between [a] and [ref] over the bands the
 * reference holds within MX_RESPONSE_FLOOR_DB of its loudest, in thirds of
 * an octave, or in octaves for a kind that rings ([octaves]). */
static double response_diff(const double* a, const double* ref, int octaves,
                            int* at) {
  double ga[MX_NBANDS], gr[MX_NBANDS];
  int ng = 0;
  const int w = octaves ? 3 : 1;
  for (int b = 0; b + w <= MX_NBANDS; b += w) {
    double ea = 0.0, er = 0.0;
    for (int k = b; k < b + w; ++k) {
      ea += pow(10.0, a[k] / 10.0);
      er += pow(10.0, ref[k] / 10.0);
    }
    ga[ng] = 10.0 * log10(ea);
    gr[ng] = 10.0 * log10(er);
    ng++;
  }
  double top = -400.0;
  for (int g = 0; g < ng; ++g) {
    if (gr[g] > top) top = gr[g];
  }
  double worst = 0.0;
  *at = 0;
  for (int g = 0; g < ng; ++g) {
    if (gr[g] < top - MX_RESPONSE_FLOOR_DB && ga[g] < top - MX_RESPONSE_FLOOR_DB) {
      continue;
    }
    const double d = fabs(ga[g] - gr[g]);
    if (d > worst) {
      worst = d;
      *at = (int)lround(band_centre(g * w + w / 2));
    }
  }
  return worst;
}

#define MX_FRAME_S (MX_FRAME_MS / 1000.0)
#define MX_FRAME_MS 5
#define MX_NFRAMES (MX_PLUCK_MS / MX_FRAME_MS)

/* [x]'s level in dB every 5 ms, read [lat] frames later: its energy under
 * a 20 ms Hann window centred there. 20 ms is about a period of the
 * phrase's lowest note, so the level is the note's and not where in its
 * waveform a short frame happened to fall (which an effect that moves the
 * phase of the harmonics, as a pitch shifter does, would change). */
#define MX_FRAME_WIN_S 0.02

static void frame_levels(const float* x, int64_t n, int sr, int lat, double* db) {
  for (int j = 0; j < MX_NFRAMES; ++j) {
    const double centre = (j + 0.5) * MX_FRAME_S;
    const int64_t a = (int64_t)ceil((centre - 0.5 * MX_FRAME_WIN_S) * sr);
    const int64_t b = (int64_t)ceil((centre + 0.5 * MX_FRAME_WIN_S) * sr);
    double e = 0.0, wsum = 0.0;
    for (int64_t i = a; i < b; ++i) {
      const double t = (double)i / sr - (centre - 0.5 * MX_FRAME_WIN_S);
      const double w = 0.5 - 0.5 * cos(2.0 * M_PI * t / MX_FRAME_WIN_S);
      const int64_t k = i + lat;
      if (k >= 0 && k < n) e += w * (double)x[k] * x[k];
      wsum += w;
    }
    db[j] = 10.0 * log10(e / (wsum > 0 ? wsum : 1) + 1e-20);
  }
}

/* The |difference| in dB that all but MX_ENVELOPE_SHARE of the frames that
 * matter stay within, and the largest. */
static double envelope_diff(const double* a, const double* ref, double* max_out,
                            int* at_ms) {
  double top = -400.0;
  for (int j = 0; j < MX_NFRAMES; ++j) {
    if (ref[j] > top) top = ref[j];
    if (a[j] > top) top = a[j];
  }
  double d[MX_NFRAMES];
  int m = 0;
  double worst = 0.0;
  *at_ms = 0;
  for (int j = 0; j < MX_NFRAMES; ++j) {
    if (ref[j] < top - MX_ENVELOPE_FLOOR_DB && a[j] < top - MX_ENVELOPE_FLOOR_DB) {
      continue;
    }
    d[m] = fabs(a[j] - ref[j]);
    if (d[m] > worst) {
      worst = d[m];
      *at_ms = (int)lround(j * MX_FRAME_S * 1000.0);
    }
    m++;
  }
  *max_out = worst;
  if (m == 0) return 0.0;
  qsort(d, (size_t)m, sizeof(double), cmp_double);
  int idx = (int)ceil((1.0 - MX_ENVELOPE_SHARE) * m) - 1;
  if (idx < 0) idx = 0;
  return d[idx];
}

typedef struct {
  int nonfinite;
  double peak;
  double dc; /* the largest |mean| over a window of whole cycles */
} mx_health;

/* Folds [o]'s non-finite samples and peak into [h], and, when [len] > 0,
 * the DC of its [len] frames from [from]: their mean under a Hann window,
 * which takes a tone of a few cycles in the window down by far more than a
 * plain mean does (its sidelobes fall as the cube of the frequency), so a
 * tail still ringing there does not read as DC. */
static void health_of(const mx_out* o, int64_t from, int64_t len, mx_health* h) {
  const float* ch[2] = {o->l, o->r};
  for (int c = 0; c < 2; ++c) {
    double sum = 0.0, wsum = 0.0;
    for (int64_t i = 0; i < o->n; ++i) {
      const float v = ch[c][i];
      if (!isfinite(v)) {
        h->nonfinite++;
        continue;
      }
      if (fabsf(v) > h->peak) h->peak = fabsf(v);
      if (i >= from && i < from + len) {
        const double w = 0.5 - 0.5 * cos(2.0 * M_PI * (double)(i - from) / len);
        sum += w * v;
        wsum += w;
      }
    }
    if (wsum > 0.0 && fabs(sum / wsum) > h->dc) h->dc = fabs(sum / wsum);
  }
}

/* ---------------- one setting ---------------- */

typedef struct {
  /* per rate */
  int block_exact[MX_NRATES];   /* every block bit-identical */
  int block_worst[MX_NRATES];   /* the block that differs the most */
  double block_diff_db[MX_NRATES]; /* its largest difference, dB re peak */
  double response_db[MX_NRATES];
  int response_hz[MX_NRATES];
  double envelope_db[MX_NRATES];
  double envelope_max_db[MX_NRATES];
  int envelope_ms[MX_NRATES];
  int alias_judged[MX_NRATES];
  double alias_db[MX_NRATES]; /* the worst of the three sines */
  int alias_hz[MX_NRATES];
  mx_health health[MX_NRATES];
  double stall[MX_NRATES]; /* tail ns over active ns, a frame */
  int32_t latency[MX_NRATES];
  int failed_render;
  int fail[MX_NCHECKS][MX_NRATES];
} mx_result;

static float* g_pluck[MX_NRATES];
static int64_t g_pluck_n[MX_NRATES];
static float* g_tones[MX_NRATES];
static int64_t g_tones_n[MX_NRATES];
static float* g_alias_in[MX_NRATES][3];
static int64_t g_alias_n[MX_NRATES];
static int g_ci;

static void run_setting(const mx_setting* s, mx_result* r) {
  memset(r, 0, sizeof(*r));
  double tl[MX_NRATES][2][MX_NBANDS];
  double fl[MX_NRATES][2][MX_NFRAMES];
  /* The alias sines run the vinyl with its noise off, as bench_alias does:
   * the bed is added after the curve, so it is not the curve's aliasing,
   * and it would bury the folds. */
  mx_setting as = *s;
  if (as.type == LE_FX_VINYL) as.p[2] = 0.0f;
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    r->alias_judged[ri] = k_kinds[kind_index(s->type)].harmonic &&
                          !le_fx_entry_free_running(as.type, as.p, k_rates[ri]);
  }
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    const int sr = k_rates[ri];
    mx_health* h = &r->health[ri];
    /* block */
    mx_out ref;
    const int64_t tail = (int64_t)(MX_PLUCK_TAIL_S * sr);
    if (!render(s, sr, k_blocks[0], g_pluck[ri], g_pluck_n[ri], tail, &ref)) {
      r->failed_render = 1;
      return;
    }
    const int64_t rest = sr / 2; /* the phrase's last half second: silence */
    health_of(&ref, ref.n - rest, rest, h);
    r->latency[ri] = ref.latency;
    r->block_exact[ri] = 1;
    double peak = 1e-9;
    for (int64_t i = 0; i < ref.n; ++i) {
      if (fabsf(ref.l[i]) > peak) peak = fabsf(ref.l[i]);
      if (fabsf(ref.r[i]) > peak) peak = fabsf(ref.r[i]);
    }
    for (int bi = 1; bi < MX_NBLOCKS; ++bi) {
      mx_out o;
      if (!render(s, sr, k_blocks[bi], g_pluck[ri], g_pluck_n[ri], tail, &o)) {
        r->failed_render = 1;
        out_free(&ref);
        return;
      }
      health_of(&o, o.n - rest, rest, h);
      if (bi == MX_NBLOCKS - 1) { /* the longest block times steadiest */
        r->stall[ri] = o.ns_active > 0 ? o.ns_tail / o.ns_active : 0.0;
      }
      if (memcmp(o.l, ref.l, sizeof(float) * (size_t)o.n) != 0 ||
          memcmp(o.r, ref.r, sizeof(float) * (size_t)o.n) != 0) {
        double d = 0.0;
        for (int64_t i = 0; i < o.n; ++i) {
          const double dl = fabs((double)o.l[i] - ref.l[i]);
          const double dr = fabs((double)o.r[i] - ref.r[i]);
          if (dl > d) d = dl;
          if (dr > d) d = dr;
        }
        const double db = 20.0 * log10(d / peak + 1e-30);
        if (r->block_exact[ri] || db > r->block_diff_db[ri]) {
          r->block_diff_db[ri] = db;
          r->block_worst[ri] = k_blocks[bi];
        }
        r->block_exact[ri] = 0;
      }
      out_free(&o);
    }
    frame_levels(ref.l, ref.n, sr, ref.latency, fl[ri][0]);
    frame_levels(ref.r, ref.n, sr, ref.latency, fl[ri][1]);
    out_free(&ref);
    /* response */
    mx_out t;
    if (!render(s, sr, 512, g_tones[ri], g_tones_n[ri], g_tones_n[ri], &t)) {
      r->failed_render = 1;
      return;
    }
    /* Not read for DC: the tones' intermodulation lands on 0 Hz through
     * any curve, a symmetric one too (f1 + f2 - f3 = 0). */
    health_of(&t, 0, 0, h);
    band_levels(t.l, ri, tl[ri][0]);
    band_levels(t.r, ri, tl[ri][1]);
    out_free(&t);
    /* alias */
    r->alias_db[ri] = -400.0;
    if (r->alias_judged[ri]) {
      const int win = alias_win(sr);
      const int64_t settle = (int64_t)(MX_ALIAS_SETTLE_S * sr);
      for (int k = 0; k < 3; ++k) {
        mx_out a;
        if (!render(&as, sr, 512, g_alias_in[ri][k], g_alias_n[ri], g_alias_n[ri],
                    &a)) {
          r->failed_render = 1;
          return;
        }
        health_of(&a, settle, win, h);
        for (int c = 0; c < 2; ++c) {
          const alias_spectrum sp = alias_analyze(
              (c ? a.r : a.l) + settle, win, sr, alias_bin(sr, k_alias_hz[k]), NULL);
          if (sp.alias_db > r->alias_db[ri]) {
            r->alias_db[ri] = sp.alias_db;
            r->alias_hz[ri] = (int)lround(k_alias_hz[k]);
          }
        }
        out_free(&a);
      }
    }
  }
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    if (ri == MX_REF) continue;
    for (int c = 0; c < 2; ++c) {
      int hz = 0, ms = 0;
      const double rd = response_diff(tl[ri][c], tl[MX_REF][c],
                                        le_fx_type_drains(s->type), &hz);
      if (rd >= r->response_db[ri]) {
        r->response_db[ri] = rd;
        r->response_hz[ri] = hz;
      }
      double mx = 0.0;
      const double ed = envelope_diff(fl[ri][c], fl[MX_REF][c], &mx, &ms);
      if (ed >= r->envelope_db[ri]) {
        r->envelope_db[ri] = ed;
        r->envelope_max_db[ri] = mx;
        r->envelope_ms[ri] = ms;
      }
    }
  }
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    const mx_health* h = &r->health[ri];
    r->fail[MX_BLOCK][ri] = !r->block_exact[ri];
    if (ri != MX_REF) {
      r->fail[MX_RESPONSE][ri] = r->response_db[ri] > MX_RESPONSE_DB;
      r->fail[MX_ENVELOPE][ri] = r->envelope_db[ri] > MX_ENVELOPE_DB;
    }
    r->fail[MX_ALIAS][ri] = r->alias_judged[ri] && r->alias_db[ri] > MX_ALIAS_DB;
    r->fail[MX_BLOWUP][ri] = h->nonfinite > 0 || h->peak > MX_PEAK_LIMIT;
    r->fail[MX_DC][ri] = h->dc > MX_DC_LIMIT;
    r->fail[MX_STALL][ri] = r->stall[ri] > MX_STALL_RATIO;
  }
}

/* ---------------- the work list ---------------- */

typedef struct {
  mx_setting s;
  char name[160];
  mx_result r;
} mx_item;

static mx_item* g_items;
static int g_nitems;
static atomic_int g_next;

static void* worker(void* arg) {
  (void)arg;
  for (;;) {
    const int i = atomic_fetch_add(&g_next, 1);
    if (i >= g_nitems) break;
    run_setting(&g_items[i].s, &g_items[i].r);
  }
  return NULL;
}

static void add_item(const mx_setting* s, const char* name) {
  mx_item* it = &g_items[g_nitems++];
  it->s = *s;
  snprintf(it->name, sizeof(it->name), "%s", name);
  it->s.name = it->name;
}

/* The settings to run: each kind at its defaults, then the factory
 * settings. [ci]: one setting a kind, its first factory setting, or its
 * defaults when no rack uses it. [only] keeps one kind. */
static void build_items(int ci, int32_t only) {
  g_items = (mx_item*)calloc((size_t)(MX_NKINDS + MX_NFACTORY), sizeof(mx_item));
  if (g_items == NULL) exit(1);
  int in_racks[MX_NKINDS];
  memset(in_racks, 0, sizeof(in_racks));
  for (int i = 0; i < MX_NFACTORY; ++i) {
    const int k = kind_index(k_factory[i].type);
    if (k < 0) {
      fprintf(stderr, "%s: type %d is not in the matrix's kinds\n",
              k_factory[i].name, k_factory[i].type);
      exit(2);
    }
    in_racks[k] = 1;
  }
  for (int k = 0; k < MX_NKINDS; ++k) {
    if (only >= 0 && k_kinds[k].type != only) continue;
    if (ci && in_racks[k]) continue;
    mx_setting s;
    memset(&s, 0, sizeof(s));
    s.type = k_kinds[k].type;
    le_fx_defaults(s.type, s.p);
    char name[160];
    snprintf(name, sizeof(name), "%s defaults", k_kinds[k].name);
    add_item(&s, name);
  }
  int taken[MX_NKINDS];
  memset(taken, 0, sizeof(taken));
  for (int i = 0; i < MX_NFACTORY; ++i) {
    const int k = kind_index(k_factory[i].type);
    if (only >= 0 && k_factory[i].type != only) continue;
    if (ci && taken[k]) continue;
    taken[k] = 1;
    add_item(&k_factory[i], k_factory[i].name);
  }
}

/* Every built-in kind the engine has is in k_kinds, so a new one cannot
 * be left out of the matrix, and every known failure names a kind, a check
 * and a rate the matrix has, so a typo cannot hide one. */
static void check_kinds(void) {
  for (const mx_known* k = k_known; k->kind != NULL; ++k) {
    int kind = -1, rate = 0;
    for (int i = 0; i < MX_NKINDS; ++i) {
      if (!strcmp(k_kinds[i].name, k->kind)) kind = i;
    }
    for (int ri = 0; ri < MX_NRATES; ++ri) {
      if (k_rates[ri] == k->rate) rate = 1;
    }
    if (kind < 0 || !rate || k->check < 0 || k->check >= MX_STALL ||
        ((k->check == MX_RESPONSE || k->check == MX_ENVELOPE) &&
         k->rate == k_rates[MX_REF])) {
      fprintf(stderr, "known failure %s/%d/%d is not in the matrix\n", k->kind,
              k->check, k->rate);
      exit(2);
    }
  }
  for (int32_t t = LE_FX_NONE + 1; t < LE_FX_WIDTHS; ++t) {
    if (t == LE_FX_PLUGIN) continue;
    if (kind_index(t) < 0) {
      fprintf(stderr, "effect type %d is missing from the matrix's kinds\n", t);
      exit(2);
    }
  }
}

/* ---------------- the report ---------------- */

static int g_detail;

static void print_item(const mx_item* it) {
  const mx_result* r = &it->r;
  printf("%-10s %s\n", k_kinds[kind_index(it->s.type)].name, it->name);
  if (r->failed_render) {
    printf("    the engine refused it\n");
    return;
  }
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    printf("    %5.1f kHz: block %s", k_rates[ri] / 1000.0,
           r->block_exact[ri] ? "exact" : "DIFFERS");
    if (!r->block_exact[ri]) {
      printf(" (%d frames, %.1f dB)", r->block_worst[ri], r->block_diff_db[ri]);
    }
    if (ri != MX_REF) {
      printf(", response %.2f dB at %d Hz, envelope %.2f dB (max %.1f at %d ms)",
             r->response_db[ri], r->response_hz[ri], r->envelope_db[ri],
             r->envelope_max_db[ri], r->envelope_ms[ri]);
    }
    if (r->alias_judged[ri]) {
      printf(", alias %.1f dB at %d Hz", r->alias_db[ri], r->alias_hz[ri]);
    }
    printf(", peak %.2f, dc %.1e, stall x%.1f, latency %d", r->health[ri].peak,
           r->health[ri].dc, r->stall[ri], r->latency[ri]);
    if (r->health[ri].nonfinite) printf(", %d NON-FINITE", r->health[ri].nonfinite);
    printf("\n");
  }
}

/* How far [r] is from passing [check] at rate [ri], larger worse, and the
 * figure that says so, into [buf]. */
static double severity(const mx_result* r, int check, int ri, char* buf, size_t n) {
  const mx_health* h = &r->health[ri];
  switch (check) {
    case MX_BLOCK:
      if (r->block_exact[ri]) {
        snprintf(buf, n, "exact");
        return -400.0;
      }
      snprintf(buf, n, "%.1f dB at %d", r->block_diff_db[ri], r->block_worst[ri]);
      return r->block_diff_db[ri];
    case MX_RESPONSE:
      snprintf(buf, n, "%.2f dB at %d Hz", r->response_db[ri], r->response_hz[ri]);
      return r->response_db[ri];
    case MX_ENVELOPE:
      snprintf(buf, n, "%.2f dB", r->envelope_db[ri]);
      return r->envelope_db[ri];
    case MX_ALIAS:
      snprintf(buf, n, "%.1f dB at %d Hz", r->alias_db[ri], r->alias_hz[ri]);
      return r->alias_db[ri];
    case MX_BLOWUP:
      if (h->nonfinite) {
        snprintf(buf, n, "%d non-finite", h->nonfinite);
        return 1e9;
      }
      snprintf(buf, n, "peak %+.1f dBFS", 20.0 * log10(h->peak + 1e-30));
      return 20.0 * log10(h->peak + 1e-30);
    case MX_DC:
      snprintf(buf, n, "%.1f dBFS", 20.0 * log10(h->dc + 1e-30));
      return 20.0 * log10(h->dc + 1e-30);
    default:
      snprintf(buf, n, "x%.1f", r->stall[ri]);
      return r->stall[ri];
  }
}

/* The worst of [check] over [kind]'s settings at rate [ri], into [buf], and
 * the setting it came from; [fails] gets how many settings fail it,
 * [judged] how many it was read on. */
static double worst_of(int kind, int check, int ri, char* buf, size_t n,
                       const char** name, int* fails, int* judged) {
  double worst = -1e30;
  *name = "";
  buf[0] = 0;
  *fails = 0;
  *judged = 0;
  for (int i = 0; i < g_nitems; ++i) {
    const mx_item* it = &g_items[i];
    if (kind_index(it->s.type) != kind || it->r.failed_render) continue;
    const mx_result* r = &it->r;
    if (check == MX_ALIAS && !r->alias_judged[ri]) continue;
    if ((check == MX_RESPONSE || check == MX_ENVELOPE) && ri == MX_REF) continue;
    char fig[64];
    const double v = severity(r, check, ri, fig, sizeof(fig));
    (*judged)++;
    const int failed = r->fail[check][ri];
    if (failed) (*fails)++;
    /* The worst failing setting, or the worst of all when none fails. */
    if (failed ? (*fails == 1 || v > worst) : (*fails == 0 && v > worst)) {
      worst = v;
      *name = it->name;
      snprintf(buf, n, "%s", fig);
    }
  }
  return worst;
}

static int report(void) {
  int new_fail = 0, stale = 0, refused = 0;
  for (int i = 0; i < g_nitems; ++i) {
    if (g_items[i].r.failed_render) {
      printf("REFUSED: %s (type %d)\n", g_items[i].name, g_items[i].s.type);
      refused++;
    }
  }
  int ran[MX_NKINDS];
  memset(ran, 0, sizeof(ran));
  for (int i = 0; i < g_nitems; ++i) ran[kind_index(g_items[i].s.type)] = 1;
  printf("\n## Failures\n\n");
  printf("| kind       | check    | rate   | failing    | list   | worst                  | worst setting |\n");
  printf("|------------|----------|--------|------------|--------|------------------------|---------------|\n");
  for (int k = 0; k < MX_NKINDS; ++k) {
    for (int c = 0; c < MX_NCHECKS; ++c) {
      for (int ri = 0; ri < MX_NRATES; ++ri) {
        if ((c == MX_RESPONSE || c == MX_ENVELOPE) && ri == MX_REF) continue;
        const char* name = "";
        int fails = 0, judged = 0;
        char fig[64];
        const double v =
            worst_of(k, c, ri, fig, sizeof(fig), &name, &fails, &judged);
        const mx_known* known = known_entry(k, c, k_rates[ri]);
        if (judged == 0) {
          /* A listed entry no setting of a kind that ran is read on. */
          if (known != NULL && ran[k] && !g_ci) {
            printf("| %-10s | %-8s | %5.1fk | not read   | known  | "
                   "TAKE IT OFF THE LIST | |\n",
                   k_kinds[k].name, k_check_names[c], k_rates[ri] / 1000.0);
            stale++;
          }
          continue;
        }
        if (fails > 0) {
          const int over = known != NULL && v > known->ceiling;
          const char* list = c == MX_STALL ? "timing"
                             : over        ? "WORSE"
                             : known       ? "known"
                                           : "NEW";
          printf("| %-10s | %-8s | %5.1fk | %3d of %3d | %-6s | %-22s | %s |\n",
                 k_kinds[k].name, k_check_names[c], k_rates[ri] / 1000.0, fails,
                 judged, list, fig, name);
          /* Timing is reported and never fails a run. */
          if ((known == NULL || over) && c != MX_STALL) new_fail++;
        } else if (known != NULL) {
          printf("| %-10s | %-8s | %5.1fk | passes     | known  | %s | |\n",
                 k_kinds[k].name, k_check_names[c], k_rates[ri] / 1000.0,
                 g_ci ? "not every setting ran" : "TAKE IT OFF THE LIST");
          if (!g_ci) stale++;
        }
      }
    }
  }
  printf("\n%d settings, %d new or worse failures, %d known entries now "
         "passing, %d refused\n",
         g_nitems, new_fail, stale, refused);
  return new_fail || stale || refused ? 1 : 0;
}

/* ---------------- main ---------------- */

static int cpu_count(void) {
  const long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int)n : 1;
}

int main(int argc, char** argv) {
  int jobs = 0;
  int32_t only = -1;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--ci")) {
      g_ci = 1;
    } else if (!strcmp(argv[i], "--detail")) {
      g_detail = 1;
    } else if (!strcmp(argv[i], "--jobs") && i + 1 < argc) {
      jobs = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--kind") && i + 1 < argc) {
      const char* want = argv[++i];
      for (int k = 0; k < MX_NKINDS; ++k) {
        if (!strcmp(k_kinds[k].name, want)) only = k_kinds[k].type;
      }
      if (only < 0) {
        fprintf(stderr, "unknown kind %s\n", want);
        return 2;
      }
    } else {
      fprintf(stderr,
              "usage: %s [--ci] [--detail] [--jobs N] [--kind NAME]\n", argv[0]);
      return 2;
    }
  }
  if (jobs <= 0) jobs = cpu_count();
  check_kinds();
  detect_cpu();
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    const int sr = k_rates[ri];
    g_pluck[ri] = make_pluck(sr, &g_pluck_n[ri]);
    g_tones[ri] = make_tones(sr, &g_tones_n[ri]);
    plan_init(&g_plan[ri], sr);
    plan_check(ri);
    g_alias_n[ri] = (int64_t)(MX_ALIAS_SETTLE_S * sr) + alias_win(sr);
    for (int k = 0; k < 3; ++k) {
      const double hz = (double)alias_bin(sr, k_alias_hz[k]) * sr / alias_win(sr);
      float* x = (float*)malloc(sizeof(float) * (size_t)g_alias_n[ri]);
      if (x == NULL) exit(1);
      for (int64_t i = 0; i < g_alias_n[ri]; ++i) {
        x[i] = (float)(0.25 * ramp((double)i / sr, 0.01) *
                       sin(2.0 * M_PI * hz * (double)i / sr));
      }
      g_alias_in[ri][k] = x;
    }
  }
  build_items(g_ci, only);
  printf("bench_fx_matrix%s: %d settings, %d kinds, at 44.1, 48 and 96 kHz, "
         "blocks 32 to 512; %s, %d jobs\n",
         g_ci ? " (CI subset)" : "", g_nitems, MX_NKINDS, g_cpu_name, jobs);
  const double t0 = now_us();
  pthread_t* th = (pthread_t*)calloc((size_t)jobs, sizeof(pthread_t));
  int started = 0;
  for (int j = 0; j < jobs; ++j) {
    if (pthread_create(&th[started], NULL, worker, NULL) == 0) started++;
  }
  if (started == 0) worker(NULL); /* no thread: run them here */
  for (int j = 0; j < started; ++j) pthread_join(th[j], NULL);
  free(th);
  printf("ran in %.1f s\n", (now_us() - t0) / 1e6);
  if (g_detail) {
    printf("\n## Every setting\n\n");
    for (int i = 0; i < g_nitems; ++i) print_item(&g_items[i]);
  }
  const int rc = report();
  for (int ri = 0; ri < MX_NRATES; ++ri) {
    free(g_pluck[ri]);
    free(g_tones[ri]);
    plan_free(&g_plan[ri]);
    for (int k = 0; k < 3; ++k) free(g_alias_in[ri][k]);
  }
  free(g_items);
  printf("%s\n", rc ? "FAILED" : "PASSED");
  return rc;
}
