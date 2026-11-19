/*
 * test_fx_workers_races.c — the effects workers under real concurrency
 * (#1515, part 1).
 *
 * One thread stands in for the device callback and runs 10,000 periods of
 * le_engine_process with two effects workers, four monitored inputs and a
 * chain on each, so every period is a round the workers share. The control
 * thread meanwhile posts what a player does to those chains, OPS of them
 * each period: parameter edits, stomps, retypes, a chain switched off and
 * on, a monitor muted and unmuted, Cut all sound; and it polls the snapshot
 * and the workers' telemetry the way the UI and a bench do.
 *
 * What it proves, under ThreadSanitizer (the native-tests-tsan job runs it
 * through NATIVE_TESTS_ONLY=races): no data race between a worker running a
 * monitor chain and the callback's command drain that edits it, between a
 * round's jobs and the callback's mix of their output, or between either and
 * the control thread. The retypes include the octaver family, whose
 * buffers the control thread prepares into the live chain state while a
 * slot still runs another kind (#1522), and the whole run repeats at
 * 44.1 kHz, where a running octaver reads its resampler table every sample.
 * And, in the plain suite, that every period finishes, the workers really
 * shared the rounds, and the engine accepts every mute and every Cut.
 *
 * The two threads pace each other (#1629). Unpaced, the control thread filled
 * the command ring whenever the scheduler took the audio thread off its core
 * for a few milliseconds (the longest periods of a loaded run took hundreds of
 * milliseconds of wall time and under 2 ms of CPU): the mutes have nothing else
 * holding them back, and a full ring refuses them, as it should. Now the
 * control thread runs batch w (OPS ops) only once the callback has finished
 * period w - 1, and the callback runs period p only once the control thread has
 * finished batch p - LAG - 1. Between two drains the ring therefore holds at
 * most the batches LAG + 2 periods can post, each op at most two commands:
 * (LAG + 2) * OPS * 2 = 64 of its 255 slots, so a refused mute or Cut is the
 * engine's fault. Both counters are relaxed, so the pacing adds no
 * happens-before edge for ThreadSanitizer to hide a race behind; the
 * interleaving inside a period is still the scheduler's. The op sequence and
 * its count are fixed by the seed, and so are the mutes and Cuts it makes.
 */
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "engine_fx.h" /* le_fx_defaults */
#include "segno_engine_api.h"

#define PERIOD 64
#define PERIODS 10000
#define INPUTS 4
/* The control thread's ops a period, and how many periods the callback may
 * run ahead of its batches. */
#define OPS 8
#define LAG 2

static atomic_long g_blocks;  /* periods the callback has finished */
static atomic_long g_batches; /* batches the control thread has finished */
static int g_failures;

#define CHECK(cond)                                        \
  do {                                                     \
    if (!(cond)) {                                         \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__);   \
      ++g_failures;                                        \
    }                                                      \
  } while (0)

static uint32_t g_seed = 0x1515u;
static uint32_t next_rand(void) {
  g_seed = g_seed * 1664525u + 1013904223u;
  return g_seed >> 8;
}

static void* audio_thread(void* arg) {
  le_engine* e = (le_engine*)arg;
  static float in[PERIOD * INPUTS];
  static float out[PERIOD * 2];
  uint32_t n = 1u;
  for (long p = 0; p < PERIODS; ++p) {
    while (atomic_load_explicit(&g_batches, memory_order_relaxed) < p - LAG) {
      sched_yield();
    }
    for (int i = 0; i < PERIOD * INPUTS; ++i) {
      n = n * 1103515245u + 12345u;
      in[i] = (float)((n >> 9) & 0xFFFF) / 65536.0f - 0.5f;
    }
    le_engine_process(e, out, in, PERIOD);
    atomic_fetch_add_explicit(&g_blocks, 1, memory_order_relaxed);
  }
  return NULL;
}

/* Monitor [c]'s chain: four kinds, including ones on the hop and synced ones,
 * each with its own identity so an edit that keeps an entry keeps its state. */
static void base_recipe(le_fx_recipe* r, int c) {
  static const int32_t kinds[INPUTS][4] = {
      {LE_FX_DELAY, LE_FX_CHORUS, LE_FX_PUMPER, LE_FX_EQ},
      {LE_FX_OCTAVER, LE_FX_REVERB, LE_FX_COMPRESSOR, LE_FX_TREMOLO},
      {LE_FX_MODE_DELAY, LE_FX_WAH, LE_FX_SLICER, LE_FX_DRIVE},
      {LE_FX_OVERDRIVE, LE_FX_ECHO, LE_FX_MOD, LE_FX_FILTER}};
  memset(r, 0, sizeof(*r));
  r->enabled = 1;
  r->count = 4;
  for (int s = 0; s < 4; ++s) {
    r->type[s] = kinds[c][s];
    r->slot_enabled[s] = 1;
    r->level[s] = 1.0f;
    le_fx_defaults(kinds[c][s], r->params[s]);
    r->instance[s] = (uint64_t)(10 * (c + 1) + s);
  }
}

/* One run at [sr]. */
static void run_at(int sr) {
  printf("test_fx_workers_races at %d Hz\n", sr);
  g_seed = 0x1515u; /* the same seed at every rate */
  atomic_store(&g_blocks, 0);
  atomic_store(&g_batches, 0);
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, sr, INPUTS, 2, sr) == LE_OK);
  CHECK(le_engine_set_fx_workers(e, 2, NULL) == LE_OK);
  le_fx_recipe r[INPUTS];
  uint32_t rev = 1;
  for (int c = 0; c < INPUTS; ++c) {
    CHECK(le_engine_set_monitor_input(e, c, 1) == LE_OK);
    CHECK(le_engine_set_monitor_input_output(e, c, 0x3u) == LE_OK);
    base_recipe(&r[c], c);
    CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, c, 0, ++rev,
                                  &r[c]) == LE_OK);
  }
  pthread_t audio;
  CHECK(pthread_create(&audio, NULL, audio_thread, e) == 0);

  /* The octaver family among them: preparing one on a slot that never held
   * one writes its buffer pointers into the live chain state, which a reset
   * of the slot as its present kind must leave alone (#1522). */
  static const int32_t retypes[] = {
      LE_FX_DRIVE,   LE_FX_DELAY,   LE_FX_CHORUS,       LE_FX_TREMOLO,
      LE_FX_PUMPER,  LE_FX_REVERB,  LE_FX_OCTAVER,      LE_FX_WHAMMY,
      LE_FX_DUAL_OCTAVER, LE_FX_SMART_TUNE};
  const int retype_count = (int)(sizeof(retypes) / sizeof(retypes[0]));
  int posted = 0, in_flight = 0, polls = 0, mutes = 0, cuts = 0;
  int refused_mutes = 0, refused_cuts = 0;
  long last_cut = -50;
  uint64_t next_instance = 1000;
  le_snapshot snap;
  le_fx_workers_telemetry tm;
  for (long w = 0; w < PERIODS; ++w) {
    /* Batch w once the callback has finished period w - 1 (see the top). */
    while (atomic_load_explicit(&g_blocks, memory_order_relaxed) < w) {
      sched_yield();
    }
    for (int op = 0; op < OPS; ++op) {
      const int c = (int)(next_rand() % INPUTS);
      const int s = (int)(next_rand() % 4);
      switch (next_rand() % 7) {
        case 0: /* a parameter edit */
          r[c].params[s][0] = (float)(next_rand() % 1000) / 1000.0f;
          break;
        case 1: /* a stomp */
          r[c].slot_enabled[s] = !r[c].slot_enabled[s];
          break;
        case 2: { /* a retype: a new entry, so its state resets */
          const int32_t k = retypes[next_rand() % (uint32_t)retype_count];
          r[c].type[s] = k;
          le_fx_defaults(k, r[c].params[s]);
          r[c].instance[s] = ++next_instance;
          break;
        }
        case 3: /* the chain off or on */
          r[c].enabled = !r[c].enabled;
          break;
        case 4: /* the monitor muted or unmuted: a round with fewer jobs */
          if (le_engine_set_monitor_input_mute(
                  e, c, (int32_t)(next_rand() & 1u)) == LE_OK) {
            ++mutes;
          } else {
            ++refused_mutes;
          }
          break;
        case 5: /* Cut all sound: every chain's tails, as their kinds stand */
          /* At most one every 50 batches: a Cut clears every ring at once,
           * and a stream of them would stall the callback. */
          if (w - last_cut < 50) continue;
          if (le_engine_cut_sound(e) == LE_OK) {
            ++cuts;
            last_cut = w;
          } else {
            ++refused_cuts;
          }
          break;
        default: /* the UI's poll and a bench's read */
          le_engine_get_snapshot(e, &snap);
          le_engine_get_fx_workers_telemetry(e, &tm);
          ++polls;
          continue;
      }
      /* The ring has room, so a refusal is the chain's last edit still in
       * flight. */
      if (le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, c, 0, ++rev,
                                  &r[c]) == LE_OK) {
        ++posted;
      } else {
        ++in_flight;
      }
    }
    atomic_store_explicit(&g_batches, w + 1, memory_order_relaxed);
  }
  CHECK(pthread_join(audio, NULL) == 0);
  le_engine_get_fx_workers_telemetry(e, &tm);
  printf("  %ld periods, %d edits posted, %d in flight, %d mutes, %d cuts, "
         "%d mutes and %d cuts refused, %d polls, %llu rounds, "
         "%llu jobs on the callback, %llu and %llu on the workers\n",
         (long)atomic_load(&g_blocks), posted, in_flight, mutes, cuts,
         refused_mutes, refused_cuts, polls,
         (unsigned long long)tm.rounds, (unsigned long long)tm.callback_jobs,
         (unsigned long long)tm.worker[0].jobs,
         (unsigned long long)tm.worker[1].jobs);
  CHECK(atomic_load(&g_blocks) == PERIODS);
  CHECK(tm.running == 2);
  /* The ring never fills (see the top), so the engine takes every one. */
  CHECK(refused_mutes == 0);
  CHECK(refused_cuts == 0);
  /* The seed fixes these two; the floors guard a change to the op mix. */
  CHECK(mutes >= 10);
  CHECK(cuts >= 10);
  /* The interleaving is the scheduler's; these only prove the race was
   * exercised, with margins no machine should miss. */
  CHECK(posted >= 100);
  CHECK(tm.rounds >= 1000);
  le_engine_destroy(e);
}

int main(void) {
  run_at(48000);
  run_at(44100);
  if (g_failures) {
    printf("%d CHECK(S) FAILED\n", g_failures);
    return 1;
  }
  printf("ALL PASSED\n");
  return 0;
}
