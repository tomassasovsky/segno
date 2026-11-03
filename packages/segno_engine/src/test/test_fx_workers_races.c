/*
 * test_fx_workers_races.c — the effects workers under real concurrency
 * (#1515, part 1).
 *
 * One thread stands in for the device callback and runs 10,000 periods of
 * le_engine_process with two effects workers, four monitored inputs and a
 * chain on each, so every period is a round the workers share. The control
 * thread meanwhile posts what a player does to those chains as fast as it
 * can: parameter edits, stomps, retypes, a chain switched off and on, a
 * monitor muted and unmuted; and it polls the snapshot and the workers'
 * telemetry the way the UI and a bench do.
 *
 * What it proves, under ThreadSanitizer (the native-tests-tsan job runs it
 * through NATIVE_TESTS_ONLY=races): no data race between a worker running a
 * monitor chain and the callback's command drain that edits it, between a
 * round's jobs and the callback's mix of their output, or between either and
 * the control thread. The retypes include the octaver family, whose
 * buffers the control thread prepares into the live chain state while a
 * slot still runs another kind (#1522), and the whole run repeats at
 * 44.1 kHz, where a running octaver reads its resampler table every sample.
 * And, in the plain suite, that every period finishes and the workers really
 * shared the rounds.
 *
 * Deterministic op sequence (fixed seed); the interleaving is not.
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

static atomic_int g_done;
static atomic_long g_blocks;
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
    for (int i = 0; i < PERIOD * INPUTS; ++i) {
      n = n * 1103515245u + 12345u;
      in[i] = (float)((n >> 9) & 0xFFFF) / 65536.0f - 0.5f;
    }
    le_engine_process(e, out, in, PERIOD);
    atomic_fetch_add_explicit(&g_blocks, 1, memory_order_relaxed);
  }
  atomic_store_explicit(&g_done, 1, memory_order_release);
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
  atomic_store(&g_done, 0);
  atomic_store(&g_blocks, 0);
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
  int posted = 0, refused = 0, polls = 0;
  uint64_t next_instance = 1000;
  le_snapshot snap;
  le_fx_workers_telemetry tm;
  while (!atomic_load_explicit(&g_done, memory_order_acquire)) {
    const int c = (int)(next_rand() % INPUTS);
    const int s = (int)(next_rand() % 4);
    switch (next_rand() % 6) {
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
        /* The edits fill the command ring faster than a slow callback (the
         * resampled pitch kinds under a sanitizer) drains it, and a full
         * ring refuses the mute as it refuses an edit. */
        if (le_engine_set_monitor_input_mute(e, c,
                                             (int32_t)(next_rand() & 1u)) !=
            LE_OK) {
          ++refused;
        }
        break;
      default: /* the UI's poll and a bench's read */
        le_engine_get_snapshot(e, &snap);
        le_engine_get_fx_workers_telemetry(e, &tm);
        ++polls;
        continue;
    }
    if (le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, c, 0, ++rev, &r[c]) ==
        LE_OK) {
      ++posted;
    } else {
      ++refused; /* a full ring or a structural edit still in flight */
    }
    sched_yield();
  }
  CHECK(pthread_join(audio, NULL) == 0);
  le_engine_get_fx_workers_telemetry(e, &tm);
  printf("  %ld periods, %d edits posted, %d refused, %d polls, %llu rounds, "
         "%llu jobs on the callback, %llu and %llu on the workers\n",
         (long)atomic_load(&g_blocks), posted, refused, polls,
         (unsigned long long)tm.rounds, (unsigned long long)tm.callback_jobs,
         (unsigned long long)tm.worker[0].jobs,
         (unsigned long long)tm.worker[1].jobs);
  CHECK(atomic_load(&g_blocks) == PERIODS);
  CHECK(tm.running == 2);
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
