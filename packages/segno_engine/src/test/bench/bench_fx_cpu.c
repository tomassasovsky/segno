/*
 * bench_fx_cpu.c — what built-in effects cost the audio callback (#915).
 *
 * NOT part of the test gate. Build and run it with ./bench_fx_cpu.sh.
 *
 * WHY: a phase-vocoder octaver runs four length-1024 FFTs per channel once
 * every LE_PV_HOP (256) samples. At 96 kHz / 64 frames that is one callback in
 * four, so its cost is a TAIL, not a mean, and what matters is whether several
 * instances land their frames in the same callback. Before #915 every instance
 * reset its hop counter to 0, so a chain publish (which resets every slot it
 * carries) put all of a chain's octavers on one sample index; two stereo
 * octavers then missed the 667 us deadline on every heavy block on the console.
 *
 * Every scenario runs on a playing 8-track rig (bench_common.h) and publishes
 * its effects through le_engine_set_fx_recipe, the path the app uses, so the
 * resets happen exactly as they do live:
 *
 *   chain N   N octavers in one monitor chain, one publish.
 *   lanes N   one octaver on lane 0 of N tracks, N publishes in one block.
 *   late N    the same N octavers added one at a time, three callbacks apart
 *             (#941: an instance added later keeps its own quarter).
 *
 * With --kind eq the same scenarios run an EQ (#887 part 4) with every band
 * engaged, and `late` becomes `moving`: the chain's gains change every
 * callback, so every EQ recomputes its coefficients on each update. The
 * dynamics kinds (#887 part 5) run the same way with --kind comp, transient
 * or hpgate, the modulation kinds (part 6) with doubler, chorus or wah, and
 * the drives and lo-fi kinds (part 7) with overdrive, distortion, vinyl,
 * degrade or lpf, and the spring (part 8), each set so its whole kernel
 * works; `moving` changes a setting that
 * glides (the threshold, the attack amount, the high-pass corner, the
 * doubler's mix, the chorus's rate, the wah's pedal, the drives' tone, the
 * vinyl's frequency, the degrade's hold, the low-pass cutoff, the spring's
 * time).
 *
 * Reported per scenario: p50 / p99 / p99.9 / max per callback, the callbacks
 * over the period's deadline, and the mean cost of the blocks starting in
 * each quarter of the octaver's hop, which is where the FFT work lands.
 *
 *   ./bench_fx_cpu.sh                      # 96 kHz / 64 frames, unpaced
 *   ./bench_fx_cpu.sh --paced              # paced to the period, like a device
 *   ./bench_fx_cpu.sh --smoke              # short runs (CI)
 *   ./bench_fx_cpu.sh --kind eq            # the EQ instead of the octaver
 *   ./bench_fx_cpu.sh --racks              # each rack as built today on one
 *                                          # input, against its budget
 *   ./bench_fx_cpu.sh --table              # each kind's admission charge
 *   ./bench_fx_cpu.sh --kind comp          # or transient, hpgate, doubler,
 *                                          # chorus, wah, overdrive,
 *                                          # distortion, vinyl, degrade,
 *                                          # lpf, spring
 *   bench_fx_cpu --paced --cpu 3           # on the console, off the audio core
 *
 * On the console, run it pinned away from the app's audio core; the timed
 * loops raise themselves to SCHED_FIFO BENCH_RT_PRIO (below the app's 80).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
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
#include "engine_fx.h" /* LE_PV_HOP */
#include "bench_common.h"

/* The octaver's hop in quarters: each block is counted in the quarter its
 * first sample falls in, so the column shows where the FFT work lands at any
 * period. */
#define HOP LE_PV_HOP
#define PHASES 4 /* quarters of the hop */

static int g_paced;
/* --kind: the effect every scenario runs (LE_FX_OCTAVER by default). */
static int32_t g_kind = LE_FX_OCTAVER;

/* An octaver recipe entry: one octave up, tone open, full wet, phase vocoder.
 * Full wet keeps the wet path (the FFTs) the whole output. */
static int g_psola; /* --kind psola: the octaver in PSOLA mode */
/* --kind lpflfo, and the Rhythmic rack: the LPF swept by its LFO, which
 * redesigns the ladder at every sample */
static int g_lpf_lfo;

static void octaver_entry(le_fx_recipe* r, int s) {
  r->type[s] = LE_FX_OCTAVER;
  r->slot_enabled[s] = 1;
  r->params[s][0] = 0.75f;
  r->params[s][1] = 1.0f;
  r->params[s][2] = 1.0f;
  r->params[s][3] = g_psola ? 1.0f : 0.0f;
  r->level[s] = 1.0f;
}

/* An EQ recipe entry with every band engaged: both cuts and every bell away
 * from 0 dB (the layout with cuts). */
static void eq_entry(le_fx_recipe* r, int s) {
  r->type[s] = LE_FX_EQ;
  r->slot_enabled[s] = 1;
  le_fx_defaults(LE_FX_EQ, r->params[s]);
  r->params[s][0] = 0.3f;  /* low cut ~120 Hz */
  r->params[s][1] = 0.6f;  /* +3.6 dB */
  r->params[s][4] = 0.4f;  /* -3.6 dB */
  r->params[s][7] = 0.65f; /* +5.4 dB */
  r->params[s][10] = 0.45f;
  r->params[s][13] = 0.8f; /* high cut ~7.2 kHz */
  r->params[s][14] = 0.5f; /* bells and cuts */
  r->level[s] = 1.0f;
}

/* A dynamics entry set so its whole kernel runs: the compressor 30 dB
 * under the bench source's level with make-up, the transient shaper off
 * neutral on both controls, the high-pass at 31 Hz under a -60 dB gate. */
static void dynamics_entry(le_fx_recipe* r, int s, int32_t kind) {
  r->type[s] = kind;
  r->slot_enabled[s] = 1;
  le_fx_defaults(kind, r->params[s]);
  if (kind == LE_FX_COMPRESSOR) {
    r->params[s][0] = 0.5f;
    r->params[s][4] = 0.3f;
  } else if (kind == LE_FX_TRANSIENT) {
    r->params[s][0] = 0.9f;
    r->params[s][2] = 0.3f;
  } else if (kind == LE_FX_HP_GATE) {
    r->params[s][0] = 0.5f;
    r->params[s][1] = 0.5f;
  } else if (kind == LE_FX_DEGRADE) {
    r->params[s][0] = 0.4f; /* holding at 3.2 kHz */
  } else if (kind == LE_FX_LPF) {
    r->params[s][0] = 0.6f; /* 1.2 kHz */
    if (g_lpf_lfo) {
      r->params[s][2] = 0.8f; /* swept by its LFO */
      r->params[s][3] = 0.8f; /* at 1/8 */
    }
  } else if (kind == LE_FX_DUAL_OCTAVER) {
    r->params[s][3] = 0.6f; /* both voices: Bass Octave Layer's Octave 2 */
  } else if (kind == LE_FX_MODE_DELAY) {
    r->params[s][0] = 9.0f / 19.0f; /* 1/4 */
    r->params[s][3] = 7.0f / 11.0f; /* RES LO L/R: both taps voiced */
  } else if (kind == LE_FX_SLICER) {
    r->params[s][0] = 15.0f / 19.0f; /* AB<<: replays and reversals */
    r->params[s][1] = 1.0f / 8.0f;   /* 1/4T: reads far back in the ring */
  } else if (kind == LE_FX_WHAMMY) {
    r->params[s][0] = 0.5f; /* half the pedal */
    r->params[s][1] = 1.0f; /* up */
  } /* the doubler, chorus, wah, drives, delay and reverb run at their
     * defaults */
  r->level[s] = 1.0f;
}

static void kind_entry(le_fx_recipe* r, int s, int32_t kind) {
  if (kind == LE_FX_OCTAVER) {
    octaver_entry(r, s);
  } else if (kind == LE_FX_EQ) {
    eq_entry(r, s);
  } else {
    dynamics_entry(r, s, kind);
  }
}

static void fx_entry(le_fx_recipe* r, int s) { kind_entry(r, s, g_kind); }

/* --racks: each Looper X rack's chain, in its chain order
 * (docs/plan/2026-10-20-looperx-derived-tables.md, "Chain order"), on one
 * monitored input, against the per-rack worst-block increment the racks plan
 * budgets (#1372: 60 us for Drum, Dub, Lo-Fi and Rhythmic, 200 us for Ed's,
 * Guitar, Studio and Vocal, 300 us for the Vocal Tuner). Each slot runs the
 * kind it has or will have:
 *  - the Dual Octaver (one voice, #1464 adds the second) for Ed's Octaver,
 *    the octaver for the Pitch Shift (#1441), and the chorus and tremolo for
 *    the Mod module, which is not built yet (a projection of its cost);
 *  - the Mode delay for the racks' Delay and Dub Delay, and the engine's
 *    reverb for their Reverb;
 *  - every EQ with every band engaged and every compressor working (the
 *    kinds' heaviest settings, an upper bound for each rack's variant).
 * Left out, not built yet: Amp+Cab, the Mod module's phaser and flanger,
 * Smart Tune and Harmonizer.
 * Each list ends at the first LE_FX_NONE. */
typedef struct {
  const char* name;
  double budget_us;
  int32_t kinds[10];
} rack_spec;

static const rack_spec k_racks[] = {
    {"drum", 60.0,
     {LE_FX_TRANSIENT, LE_FX_MODE_DELAY, LE_FX_REVERB, LE_FX_EQ, LE_FX_COMPRESSOR}},
    {"dub", 60.0,
     {LE_FX_DOUBLER, LE_FX_MODE_DELAY, LE_FX_DUB_VERB, LE_FX_AMB_VERB,
      LE_FX_COMPRESSOR, LE_FX_EQ}},
    {"lofi", 60.0,
     {LE_FX_LPF, LE_FX_VINYL, LE_FX_DEGRADE, LE_FX_DISTORTION, LE_FX_EQ,
      LE_FX_MODE_DELAY}},
    {"rhythmic", 60.0,
     {LE_FX_LPF, LE_FX_SLICER, LE_FX_PUMPER, LE_FX_EQ, LE_FX_MODE_DELAY,
      LE_FX_REVERB}},
    {"eds", 200.0,
     {LE_FX_DUAL_OCTAVER, LE_FX_WAH, LE_FX_COMPRESSOR, LE_FX_OVERDRIVE,
      LE_FX_CHORUS, LE_FX_REVERB, LE_FX_MODE_DELAY, LE_FX_EQ}},
    {"guitar", 200.0,
     {LE_FX_WHAMMY, LE_FX_OVERDRIVE, LE_FX_WAH, LE_FX_CHORUS, LE_FX_SPRING,
      LE_FX_MODE_DELAY}},
    {"studio", 200.0,
     {LE_FX_OCTAVER, LE_FX_DISTORTION, LE_FX_DOUBLER, LE_FX_CHORUS,
      LE_FX_TREMOLO, LE_FX_MODE_DELAY, LE_FX_REVERB, LE_FX_COMPRESSOR, LE_FX_EQ}},
    {"vocal", 200.0,
     {LE_FX_HP_GATE, LE_FX_OCTAVER, LE_FX_DOUBLER, LE_FX_MODE_DELAY, LE_FX_REVERB,
      LE_FX_COMPRESSOR, LE_FX_EQ}},
    {"vtuner", 300.0,
     {LE_FX_HP_GATE, LE_FX_DOUBLER, LE_FX_MODE_DELAY, LE_FX_REVERB,
      LE_FX_COMPRESSOR, LE_FX_EQ}},
};

/* The number of kinds in [rack]'s list. */
static int rack_len(const rack_spec* rack) {
  int n = 0;
  while (n < 10 && rack->kinds[n] != LE_FX_NONE) ++n;
  return n;
}

/* Whether [rack] holds a kind on the hop (the octaver, the Whammy), whose
 * work the hop quarters show. */
static int rack_has_octaver(const rack_spec* rack) {
  for (int i = 0; i < rack_len(rack); ++i) {
    if (le_fx_type_hops(rack->kinds[i])) return 1;
  }
  return 0;
}
static int g_racks;

/* `moving` (every kind but the octaver): one gliding setting of each entry
 * in the monitor chain alternates every callback, so each entry is always
 * smoothing: the EQ's low-mid gain, the compressor's threshold, the
 * transient shaper's attack, the high-pass corner. */
static int32_t moving_param(void) {
  if (g_kind == LE_FX_EQ) return 4;
  /* The drives' tone: the setting whose move redesigns a filter. */
  if (g_kind == LE_FX_OVERDRIVE || g_kind == LE_FX_DISTORTION ||
      g_kind == LE_FX_VINYL) {
    return 1; /* the drives' tone, the vinyl's frequency */
  }
  return 0;
}
static int g_moving;
static int g_moving_n;

/* Times `blocks` callbacks after `warm` discarded ones. */
static stats time_blocks(rig* r, int blocks, int warm, double phase_mean[PHASES]) {
  double* us = (double*)malloc(sizeof(double) * (size_t)blocks);
  stats none;
  memset(&none, 0, sizeof(none));
  if (us == NULL) {
    fprintf(stderr, "out of memory for %d timings\n", blocks);
    for (int p = 0; p < PHASES; ++p) phase_mean[p] = 0.0;
    return none;
  }
  double phase_sum[PHASES] = {0};
  int phase_n[PHASES] = {0};
  const double step = g_budget_us; /* one period, in us */
  rt_enter();
  /* The engine frame of the first block, so each block is counted in the
   * quarter of the engine clock it starts at, which is what the octaver's
   * heavy ticks follow (#941), whatever ran before the timed loop. */
  const uint64_t frame0 =
      atomic_load_explicit(&r->e->a_frames, memory_order_relaxed);
  double next = now_us();
  int kept = 0;
  for (int b = 0; b < blocks + warm; ++b) {
    if (g_paced) {
      next += step;
      sleep_until_us(next);
    }
    if (g_moving) {
      for (int s = 0; s < g_moving_n; ++s) {
        le_engine_set_monitor_input_fx_param(r->e, 0, s, moving_param(),
                                             (b & 1) ? 0.2f : 0.8f);
      }
    }
    const double t0 = now_us();
    le_engine_process(r->e, r->out, r->in, (uint32_t)r->period);
    const double dt = now_us() - t0;
    if (b >= warm) {
      us[kept++] = dt;
      const int q = (int)((frame0 + (uint64_t)b * (uint64_t)r->period) %
                          (uint64_t)HOP) /
                    (HOP / PHASES);
      phase_sum[q] += dt;
      phase_n[q]++;
    }
  }
  rt_leave();
  for (int p = 0; p < PHASES; ++p) {
    phase_mean[p] = phase_n[p] ? phase_sum[p] / phase_n[p] : 0.0;
  }
  stats s = stats_of(us, (size_t)kept);
  free(us);
  return s;
}

static const char* kind_name(void) {
  if (g_kind == LE_FX_OCTAVER && g_psola) return "psola";
  if (g_kind == LE_FX_LPF && g_lpf_lfo) return "lpflfo";
  switch (g_kind) {
    case LE_FX_EQ: return "eq";
    case LE_FX_COMPRESSOR: return "comp";
    case LE_FX_TRANSIENT: return "transient";
    case LE_FX_HP_GATE: return "hpgate";
    case LE_FX_DOUBLER: return "doubler";
    case LE_FX_CHORUS: return "chorus";
    case LE_FX_WAH: return "wah";
    case LE_FX_OVERDRIVE: return "overdrive";
    case LE_FX_DISTORTION: return "distortion";
    case LE_FX_VINYL: return "vinyl";
    case LE_FX_DEGRADE: return "degrade";
    case LE_FX_LPF: return "lpf";
    case LE_FX_SPRING: return "spring";
    case LE_FX_DRIVE: return "drive";
    case LE_FX_FILTER: return "filter";
    case LE_FX_DELAY: return "delay";
    case LE_FX_TREMOLO: return "tremolo";
    case LE_FX_ECHO: return "echo";
    case LE_FX_REVERB: return "reverb";
    case LE_FX_DUB_VERB: return "dubverb";
    case LE_FX_AMB_VERB: return "ambverb";
    case LE_FX_WHAMMY: return "whammy";
    case LE_FX_PUMPER: return "pumper";
    case LE_FX_SLICER: return "slicer";
    case LE_FX_MODE_DELAY: return "modedelay";
    case LE_FX_DUAL_OCTAVER: return "dualoct";
    default: return "octaver";
  }
}

static void report(const char* label, stats s, const double ph[PHASES]) {
  printf("| %-18s | %8.1f | %8.1f | %8.1f | %8.1f | %5zu | %7.1f %7.1f %7.1f %7.1f |\n",
         label, s.p50, s.p99, s.p999, s.max, s.over, ph[0], ph[1], ph[2],
         ph[3]);
  fflush(stdout);
}

/* A playing rig with monitor input 0 routed to both outputs and the source's
 * first period at its input. Returns 0 when the engine refused it. */
static int monitor_rig(rig* r, const bench_opts* o, float* src, int32_t frames) {
  if (!rig_create_io(r, o, 1, src, frames, 2)) return 0;
  if (le_engine_set_monitor_input(r->e, 0, 1) != LE_OK ||
      le_engine_set_monitor_input_output(r->e, 0, 0x3) != LE_OK) {
    rig_destroy(r);
    return 0;
  }
  for (int32_t f = 0; f < o->period; ++f) {
    r->in[2 * f] = src[f];
    r->in[2 * f + 1] = src[f];
  }
  return 1;
}

/* The monitor rig running [rack]'s chain (none for a NULL rack), timed.
 * Returns 0 when the engine refused the setup. */
static int time_rack(const bench_opts* o, float* src, int32_t frames,
                     const rack_spec* rack, int blocks, int warm, stats* out,
                     double ph[PHASES]) {
  rig r;
  if (!monitor_rig(&r, o, src, frames)) return 0;
  if (rack != NULL) {
    le_fx_recipe rec;
    memset(&rec, 0, sizeof(rec));
    rec.enabled = 1;
    rec.count = rack_len(rack);
    for (int s = 0; s < rec.count; ++s) kind_entry(&rec, s, rack->kinds[s]);
    if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_MONITOR, 0, 0, 1, &rec) !=
        LE_OK) {
      rig_destroy(&r);
      return 0;
    }
  }
  *out = time_blocks(&r, blocks, warm, ph);
  rig_destroy(&r);
  return 1;
}

/* --racks: each rack timed right after a rig without effects, its increment
 * taken against that run, so drift between runs stays out of it. The budget
 * is a worst-block increment; the verdict reads the p99.9 increment, the
 * worst block but for a 0.1 % tail, so a single interrupt in either run does
 * not decide it (the max increment is printed beside it). A verdict is given
 * only where the budgets apply: the console's core (a Cortex-A76, part
 * 0xd0b), paced, with the timed loops under SCHED_FIFO. Any other run prints
 * the numbers without one. A rack the engine refuses gets a row saying so. */
static int run_racks(const bench_opts* o, float* src, int32_t frames,
                     int blocks, int warm) {
  printf("bench_fx_cpu: racks, %s, %d Hz, %d-frame periods (deadline %.1f "
         "us), %d timed blocks%s\n",
         g_cpu_name, o->rate, o->period, g_budget_us, blocks,
         g_paced ? ", paced" : "");
  printf("| rack     |  p50 us |  p99 us |  max us | late | +p99.9 us | +max "
         "us | budget us | within | phase 0..3 mean us               |\n");
  printf("|----------|---------|---------|---------|------|-----------|-------"
         "--|-----------|--------|-----------------------------------|\n");
  int judged = 0;
  for (size_t k = 0; k < sizeof(k_racks) / sizeof(k_racks[0]); ++k) {
    const rack_spec* rack = &k_racks[k];
    stats base;
    stats st;
    double ph[PHASES];
    /* The Rhythmic Rack's LPF runs its LFO; the Lo-Fi Rack's has none. */
    g_lpf_lfo = !strcmp(rack->name, "rhythmic");
    const int timed =
        time_rack(o, src, frames, NULL, blocks, warm, &base, ph) &&
        time_rack(o, src, frames, rack, blocks, warm, &st, ph);
    g_lpf_lfo = 0;
    if (!timed) {
      printf("| %-8s | refused by the engine |\n", rack->name);
      fflush(stdout);
      continue;
    }
    judged = g_cpu_part == 0xd0b && g_paced &&
             strstr(g_timed_sched, "SCHED_FIFO") != NULL &&
             strstr(g_timed_sched, "refused") == NULL;
    const double d999 = st.p999 - base.p999;
    char phases[40] = "-";
    if (rack_has_octaver(rack)) {
      snprintf(phases, sizeof(phases), "%7.1f %7.1f %7.1f %7.1f", ph[0], ph[1],
               ph[2], ph[3]);
    }
    printf("| %-8s | %7.1f | %7.1f | %7.1f | %4zu | %9.1f | %7.1f | %9.0f | "
           "%-6s | %-33s |\n",
           rack->name, st.p50, st.p99, st.max, st.over, d999,
           st.max - base.max, rack->budget_us,
           !judged ? "-" : d999 <= rack->budget_us ? "yes" : "NO", phases);
    fflush(stdout);
  }
  printf("timed loops ran at: %s%s\n", g_timed_sched,
         judged ? "" : " (no verdict: not paced on the console under "
                       "SCHED_FIFO)");
  return 0;
}

/* --table: what admission control charges each kind (#887 part 9): one
 * instance's share of the worst block, in ns per frame, on the monitor rig.
 * Eight instances in one chain show the steady share, an eighth of their
 * p99 increment over the rig alone. A kind on the hop clock (the phase
 * vocoder, PSOLA) can land a whole frame in one block, so it is charged the
 * larger of that and one instance's own p99 increment (p99 rather than the
 * racks' p99.9: a share of eight is steadier there). Prints a row per kind,
 * then the charges for kFxKindCostNs and kFxHopCostUs (looper_repository).
 * Run it paced on the console; elsewhere the numbers are only a proxy. */
typedef struct {
  const char* name;
  int32_t type;
  int variant; /* 1: PSOLA for the octaver, the LFO for the LPF */
} table_kind;

static const table_kind k_table[] = {
    {"drive", LE_FX_DRIVE, 0},          {"filter", LE_FX_FILTER, 0},
    {"delay", LE_FX_DELAY, 0},          {"tremolo", LE_FX_TREMOLO, 0},
    {"octaver", LE_FX_OCTAVER, 0},      {"psola", LE_FX_OCTAVER, 1},
    {"echo", LE_FX_ECHO, 0},            {"reverb", LE_FX_REVERB, 0},
    {"eq", LE_FX_EQ, 0},                {"comp", LE_FX_COMPRESSOR, 0},
    {"transient", LE_FX_TRANSIENT, 0},  {"hpgate", LE_FX_HP_GATE, 0},
    {"doubler", LE_FX_DOUBLER, 0},      {"chorus", LE_FX_CHORUS, 0},
    {"wah", LE_FX_WAH, 0},              {"overdrive", LE_FX_OVERDRIVE, 0},
    {"distortion", LE_FX_DISTORTION, 0}, {"vinyl", LE_FX_VINYL, 0},
    {"degrade", LE_FX_DEGRADE, 0},      {"lpf", LE_FX_LPF, 0},
    {"lpflfo", LE_FX_LPF, 1},
    {"spring", LE_FX_SPRING, 0},        {"dubverb", LE_FX_DUB_VERB, 0},
    {"ambverb", LE_FX_AMB_VERB, 0},     {"whammy", LE_FX_WHAMMY, 0},
    {"pumper", LE_FX_PUMPER, 0},        {"slicer", LE_FX_SLICER, 0},
    {"modedelay", LE_FX_MODE_DELAY, 0}, {"dualoct", LE_FX_DUAL_OCTAVER, 0},
};

/* The monitor rig with [n] instances of [kind] in one chain, timed. */
static int time_kinds(const bench_opts* o, float* src, int32_t frames,
                      const table_kind* kind, int n, int blocks, int warm,
                      stats* out) {
  rig r;
  if (!monitor_rig(&r, o, src, frames)) return 0;
  if (n > 0) {
    le_fx_recipe rec;
    memset(&rec, 0, sizeof(rec));
    rec.enabled = 1;
    rec.count = n;
    g_psola = kind->type == LE_FX_OCTAVER && kind->variant;
    g_lpf_lfo = kind->type == LE_FX_LPF && kind->variant;
    for (int s = 0; s < n; ++s) kind_entry(&rec, s, kind->type);
    g_psola = 0;
    g_lpf_lfo = 0;
    if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_MONITOR, 0, 0, 1, &rec) !=
        LE_OK) {
      rig_destroy(&r);
      return 0;
    }
  }
  double ph[PHASES];
  *out = time_blocks(&r, blocks, warm, ph);
  rig_destroy(&r);
  return 1;
}

static int run_table(const bench_opts* o, float* src, int32_t frames,
                     int blocks, int warm) {
  printf("bench_fx_cpu: cost table, %s, %d Hz, %d-frame periods, %d timed "
         "blocks%s\n",
         g_cpu_name, o->rate, o->period, blocks, g_paced ? ", paced" : "");
  printf("| kind       | base p99 us | 1 x +us | 8 x +us | charge ns/frame |\n");
  printf("|------------|-------------|---------|---------|-----------------|\n");
  double ns[sizeof(k_table) / sizeof(k_table[0])];
  stats base;
  if (!time_kinds(o, src, frames, &k_table[0], 0, blocks, warm, &base)) {
    fprintf(stderr, "the rig alone refused\n");
    return 1;
  }
  for (size_t k = 0; k < sizeof(k_table) / sizeof(k_table[0]); ++k) {
    const table_kind* kind = &k_table[k];
    stats one, eight;
    if (!time_kinds(o, src, frames, kind, 1, blocks, warm, &one) ||
        !time_kinds(o, src, frames, kind, 8, blocks, warm, &eight)) {
      fprintf(stderr, "%s refused\n", kind->name);
      return 1;
    }
    const double d1 = one.p99 - base.p99;
    const double d8 = (eight.p99 - base.p99) / 8.0;
    const int hops = le_fx_type_hops(kind->type);
    const double us = hops && d1 > d8 ? d1 : d8;
    ns[k] = us > 0.0 ? 1000.0 * us / (double)o->period : 0.0;
    printf("| %-10s | %11.1f | %7.1f | %7.1f | %15.0f |%s\n", kind->name,
           base.p99, d1, 8.0 * d8, ns[k],
           ns[k] <= 0.0 ? " lost in the noise: rerun" : "");
    fflush(stdout);
  }
  /* kFxKindCostNs takes these per frame; the octaver and PSOLA go to
   * kFxHopCostUs and kFxPsolaCostUs per block (1 x +us). */
  printf("charges, ns per frame:");
  for (size_t k = 0; k < sizeof(k_table) / sizeof(k_table[0]); ++k) {
    printf(" %s=%.0f", k_table[k].name, ns[k]);
  }
  printf("\ntimed loops ran at: %s\n", g_timed_sched);
  return 0;
}

int main(int argc, char** argv) {
  bench_opts o;
  int table = 0;
  memset(&o, 0, sizeof(o));
  o.rate = 96000;
  o.period = 64;
  o.loop_seconds = 2.0;
  int blocks = 12000;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--smoke")) {
      o.smoke = 1;
      blocks = 400;
    } else if (!strcmp(argv[i], "--paced")) {
      g_paced = 1;
    } else if (!strcmp(argv[i], "--racks")) {
      g_racks = 1;
    } else if (!strcmp(argv[i], "--table")) {
      table = 1;
    } else if (!strcmp(argv[i], "--kind") && i + 1 < argc) {
      const char* kind = argv[++i];
      if (!strcmp(kind, "octaver")) {
        g_kind = LE_FX_OCTAVER;
      } else if (!strcmp(kind, "eq")) {
        g_kind = LE_FX_EQ;
      } else if (!strcmp(kind, "comp")) {
        g_kind = LE_FX_COMPRESSOR;
      } else if (!strcmp(kind, "transient")) {
        g_kind = LE_FX_TRANSIENT;
      } else if (!strcmp(kind, "hpgate")) {
        g_kind = LE_FX_HP_GATE;
      } else if (!strcmp(kind, "doubler")) {
        g_kind = LE_FX_DOUBLER;
      } else if (!strcmp(kind, "chorus")) {
        g_kind = LE_FX_CHORUS;
      } else if (!strcmp(kind, "wah")) {
        g_kind = LE_FX_WAH;
      } else if (!strcmp(kind, "overdrive")) {
        g_kind = LE_FX_OVERDRIVE;
      } else if (!strcmp(kind, "distortion")) {
        g_kind = LE_FX_DISTORTION;
      } else if (!strcmp(kind, "vinyl")) {
        g_kind = LE_FX_VINYL;
      } else if (!strcmp(kind, "degrade")) {
        g_kind = LE_FX_DEGRADE;
      } else if (!strcmp(kind, "lpf")) {
        g_kind = LE_FX_LPF;
      } else if (!strcmp(kind, "lpflfo")) {
        g_kind = LE_FX_LPF;
        g_lpf_lfo = 1;
      } else if (!strcmp(kind, "spring")) {
        g_kind = LE_FX_SPRING;
      } else if (!strcmp(kind, "psola")) {
        g_kind = LE_FX_OCTAVER;
        g_psola = 1;
      } else if (!strcmp(kind, "drive")) {
        g_kind = LE_FX_DRIVE;
      } else if (!strcmp(kind, "filter")) {
        g_kind = LE_FX_FILTER;
      } else if (!strcmp(kind, "delay")) {
        g_kind = LE_FX_DELAY;
      } else if (!strcmp(kind, "tremolo")) {
        g_kind = LE_FX_TREMOLO;
      } else if (!strcmp(kind, "echo")) {
        g_kind = LE_FX_ECHO;
      } else if (!strcmp(kind, "reverb")) {
        g_kind = LE_FX_REVERB;
      } else if (!strcmp(kind, "dubverb")) {
        g_kind = LE_FX_DUB_VERB;
      } else if (!strcmp(kind, "ambverb")) {
        g_kind = LE_FX_AMB_VERB;
      } else if (!strcmp(kind, "whammy")) {
        g_kind = LE_FX_WHAMMY;
      } else if (!strcmp(kind, "pumper")) {
        g_kind = LE_FX_PUMPER;
      } else if (!strcmp(kind, "dualoct")) {
        g_kind = LE_FX_DUAL_OCTAVER;
      } else if (!strcmp(kind, "modedelay")) {
        g_kind = LE_FX_MODE_DELAY;
      } else if (!strcmp(kind, "slicer")) {
        g_kind = LE_FX_SLICER;
      } else {
        fprintf(stderr,
                "unknown --kind %s (octaver, psola, eq, comp, transient, "
                "hpgate, doubler, chorus, wah, overdrive, distortion, vinyl, "
                "degrade, lpf, lpflfo, spring, drive, filter, delay, tremolo, echo, "
                "reverb, dubverb, ambverb, whammy, pumper, slicer, "
                "modedelay, dualoct)\n",
                kind);
        return 2;
      }
    } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
      o.rate = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--period") && i + 1 < argc) {
      o.period = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) {
      blocks = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--cpu") && i + 1 < argc) {
      /* Pin to one core, so on the console the bench stays off the app's
       * audio core. Linux only. */
      const int cpu = atoi(argv[++i]);
#if defined(__linux__)
      cpu_set_t set;
      CPU_ZERO(&set);
      CPU_SET(cpu, &set);
      if (sched_setaffinity(0, sizeof(set), &set) != 0) perror("sched_setaffinity");
#else
      (void)cpu;
#endif
    } else {
      fprintf(stderr,
              "usage: %s [--smoke] [--paced] [--racks] [--rate HZ] "
              "[--period FRAMES] "
              "[--blocks N] [--cpu N] "
              "[--kind octaver|psola|eq|comp|transient|hpgate|doubler|chorus|"
              "wah|overdrive|distortion|vinyl|degrade|lpf|lpflfo|spring|drive|filter|"
              "delay|tremolo|echo|reverb|dubverb|ambverb|whammy|"
              "pumper|slicer|modedelay|dualoct] [--table]\n",
              argv[0]);
      return 2;
    }
  }
  if (blocks < 100) blocks = 100;
  g_budget_us = 1e6 * (double)o.period / (double)o.rate;
  detect_cpu();
  const int32_t frames = (int32_t)(o.loop_seconds * o.rate);
  float* src = make_source(frames, o.rate);
  if (src == NULL) return 1;

  const int warm = 600;
  if (g_racks || table) {
    const int rc = table ? run_table(&o, src, frames, blocks, warm)
                         : run_racks(&o, src, frames, blocks, warm);
    free(src);
    return rc;
  }
  const int counts[] = {0, 1, 2, 4, 8};
  printf("bench_fx_cpu: %s, %s, %d Hz, %d-frame periods (deadline %.1f us), "
         "%d timed blocks%s\n",
         kind_name(), g_cpu_name, o.rate, o.period, g_budget_us,
         blocks, g_paced ? ", paced" : "");
  printf("| scenario           |  p50 us |  p99 us | p99.9 us |  max us | late "
         "| phase 0..3 mean us               |\n");
  printf("|--------------------|---------|---------|----------|---------|------"
         "|-----------------------------------|\n");
  for (int mode = 0; mode < 3; ++mode) {
    for (size_t k = 0; k < sizeof(counts) / sizeof(counts[0]); ++k) {
      const int n = counts[k];
      if (mode > 0 && n == 0) continue;
      rig r;
      if (!monitor_rig(&r, &o, src, frames)) {
        fprintf(stderr, "rig or monitor input 0 refused\n");
        return 1;
      }
      if (n > 0) {
        le_fx_recipe rec;
        memset(&rec, 0, sizeof(rec));
        rec.enabled = 1;
        if (mode == 0 || (g_kind != LE_FX_OCTAVER && mode == 2)) {
          rec.count = n;
          for (int s = 0; s < n; ++s) fx_entry(&rec, s);
          if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_MONITOR, 0, 0, 1, &rec) !=
              LE_OK) {
            fprintf(stderr, "monitor recipe refused\n");
            return 1;
          }
        } else {
          rec.count = 1;
          fx_entry(&rec, 0);
          for (int t = 0; t < n; ++t) {
            if (le_engine_set_fx_recipe(r.e, LE_FX_OWNER_LANE, t, 0, 1, &rec) !=
                LE_OK) {
              fprintf(stderr, "lane recipe refused\n");
              return 1;
            }
            if (mode == 2) {
              for (int b = 0; b < 3; ++b) {
                le_engine_process(r.e, r.out, r.in, (uint32_t)r.period);
              }
            }
          }
        }
      }
      double ph[PHASES];
      g_moving = g_kind != LE_FX_OCTAVER && mode == 2;
      g_moving_n = n;
      const stats s = time_blocks(&r, blocks, warm, ph);
      g_moving = 0;
      char label[32];
      static const char* const names[] = {"chain", "lanes", "late"};
      static const char* const kind_names[] = {"chain", "lanes", "moving"};
      if (g_kind == LE_FX_OCTAVER) {
        snprintf(label, sizeof(label), "%s %d", names[mode], n);
      } else {
        snprintf(label, sizeof(label), "%s %s %d", kind_name(),
                 kind_names[mode], n);
      }
      report(label, s, ph);
      rig_destroy(&r);
    }
  }
  printf("timed loops ran at: %s\n", g_timed_sched);
  free(src);
  return 0;
}
