/*
 * test_backing_races.c — the backing player's buffer handoff under real
 * concurrency (#1200, plan review H1). One thread runs le_engine_process in
 * small blocks with End = Next and short buffers, so automatic advances land
 * inside blocks all the time; the control thread meanwhile loads, stages,
 * clears, seeks, toggles transport and collects, as fast as it can.
 *
 * What it proves, under ThreadSanitizer (the native-tests-tsan job runs it
 * through NATIVE_TESTS_ONLY=races) and AddressSanitizer (the ASan job runs
 * the whole script):
 *   - no data race between a load, stage or clear and an advance, a fade or
 *     a return (TSAN);
 *   - no buffer is read after it is freed, freed twice, or leaked (ASan:
 *     every buffer the test hands over is either refused back to it and
 *     freed here, or freed by the engine before destroy returns);
 *   - the registry bounds always hold: at most LE_BACKING_MAX_BUFFERS
 *     buffers and LE_BACKING_BUDGET_BYTES owned, observed after every collect.
 * The Library's audition voice (#1178) shares the buffer type and the
 * hand-back pattern, so the same loop also starts, stops and collects
 * previews, cuts the sound, and arms and disarms a performance capture
 * (which ends a preview and refuses new ones) against the running callback:
 * at most LE_AUDITION_MAX_BUFFERS previews owned after every collect.
 * Deterministic op sequence (fixed seed); the interleaving is not.
 */
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "segno_engine_api.h"

#define SR 48000
#define OPS 20000

static atomic_int g_stop;
/* The control thread parks the pump around a capture arm or disarm: on a
 * device-free engine (a_running 0) le_perf_disarm consumes the queued
 * commands by running a block itself, which must not overlap the pump's. */
static atomic_int g_pause;
static atomic_int g_paused;
static atomic_long g_blocks;
static int g_failures;

#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__);               \
      ++g_failures;                                                    \
    }                                                                  \
  } while (0)

static uint32_t g_seed = 0x1200u;
static uint32_t next_rand(void) {
  g_seed = g_seed * 1664525u + 1013904223u;
  return g_seed >> 8;
}

static void* audio_thread(void* arg) {
  le_engine* e = (le_engine*)arg;
  float in[64] = {0};
  float out[64 * 2];
  uint32_t n = 1;
  while (!atomic_load_explicit(&g_stop, memory_order_acquire)) {
    if (atomic_load_explicit(&g_pause, memory_order_acquire)) {
      atomic_store_explicit(&g_paused, 1, memory_order_release);
      while (atomic_load_explicit(&g_pause, memory_order_acquire) &&
             !atomic_load_explicit(&g_stop, memory_order_acquire)) {
        sched_yield();
      }
      atomic_store_explicit(&g_paused, 0, memory_order_release);
      continue;
    }
    le_engine_process(e, out, in, n);
    atomic_fetch_add_explicit(&g_blocks, 1, memory_order_relaxed);
    n = n % 61 + 1; /* every block length 1..61, so ends land anywhere */
  }
  return NULL;
}

static void pause_pump(void) {
  atomic_store_explicit(&g_pause, 1, memory_order_release);
  while (!atomic_load_explicit(&g_paused, memory_order_acquire)) sched_yield();
}

static void resume_pump(void) {
  atomic_store_explicit(&g_pause, 0, memory_order_release);
  while (atomic_load_explicit(&g_paused, memory_order_acquire)) sched_yield();
}

static le_backing_buffer* make_buffer(void) {
  const int frames = 1 + (int)(next_rand() % 200);
  float pcm[200];
  for (int i = 0; i < frames; ++i) pcm[i] = (float)i / 256.0f;
  le_backing_buffer* b = NULL;
  CHECK(le_backing_buffer_from_pcm(pcm, frames, 1, SR, &b) == LE_OK);
  return b;
}

int main(void) {
  printf("test_backing_handoff_races\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, SR, 1, 2, SR * 4) == LE_OK);
  CHECK(le_engine_backing_set_output(e, 0x3) == LE_OK);
  CHECK(le_engine_backing_set_end(e, LE_BACKING_END_NEXT) == LE_OK);
  pthread_t audio;
  CHECK(pthread_create(&audio, NULL, audio_thread, e) == 0);

  int accepted = 0, refused = 0, max_owned = 0, handoffs = 0, advances = 0;
  int previews = 0, arms = 0;
  int armed = 0;
  char capture_dir[512];
  {
    const char* tmp = getenv("TMPDIR");
    snprintf(capture_dir, sizeof capture_dir, "%s/segno_races_XXXXXX",
             tmp != NULL && tmp[0] != '\0' ? tmp : "/tmp");
  }
  CHECK(mkdtemp(capture_dir) != NULL);
  uint32_t last_end_count = 0;
  for (int op = 0; op < OPS; ++op) {
    int32_t rc = LE_OK;
    switch (next_rand() % 13) {
      case 0:
      case 1: {
        le_backing_buffer* b = make_buffer();
        rc = le_engine_backing_load(e, b, op, next_rand() % 4 != 0);
        if (rc != LE_OK) le_backing_buffer_free(b);
        else ++handoffs;
        break;
      }
      case 2:
      case 3: {
        le_backing_buffer* b = make_buffer();
        rc = le_engine_backing_stage_next(e, b, op);
        if (rc != LE_OK) le_backing_buffer_free(b);
        else ++handoffs;
        break;
      }
      case 4:
        rc = le_engine_backing_clear(e);
        break;
      case 5:
        rc = le_engine_backing_transport(e, (int32_t)(next_rand() % 3));
        break;
      case 6:
        rc = le_engine_backing_seek(e, (int32_t)(next_rand() % 250));
        break;
      case 7:
        /* Mostly Next, so advances keep landing inside blocks. */
        rc = le_engine_backing_set_end(
            e, next_rand() % 4 == 0 ? (int32_t)(next_rand() % 2)
                                    : LE_BACKING_END_NEXT);
        break;
      case 8:
      case 9: {
        le_backing_buffer* b = make_buffer();
        rc = le_engine_audition_start(e, b, 0);
        if (rc != LE_OK) le_backing_buffer_free(b);
        else ++previews;
        break;
      }
      case 10:
        rc = le_engine_audition_stop(e);
        break;
      case 11:
        rc = le_engine_cut_sound(e);
        break;
      case 12:
        /* Rarely: a capture arm ends a preview and refuses new ones, so a
         * start racing it must be handed back by the callback. */
        if (next_rand() % 16 == 0) {
          /* The arm is posted with the pump parked only as long as the
           * device-free disarm needs; starts then race its apply. */
          pause_pump();
          rc = armed ? le_perf_disarm(e) : le_perf_arm(e, capture_dir);
          resume_pump();
          if (rc == LE_OK) {
            if (!armed) ++arms;
            armed = !armed;
          }
        }
        break;
      default:
        break;
    }
    /* Keep the two threads interleaved: every fourth op waits for the audio
     * thread to finish a block, so the control side cannot run the whole
     * sequence against a starved callback. */
    if (op % 4 == 3) {
      const long seen = atomic_load_explicit(&g_blocks, memory_order_relaxed);
      while (atomic_load_explicit(&g_blocks, memory_order_relaxed) == seen) {
        sched_yield();
      }
    }
    if (rc == LE_OK) ++accepted;
    else ++refused;
    CHECK(rc == LE_OK || rc == LE_ERR_NOT_READY || rc == LE_ERR_INVALID ||
          rc == LE_ERR_ALREADY_RUNNING);
    le_audition_state as;
    CHECK(le_engine_audition_state(e, &as) == LE_OK);
    CHECK(as.owned >= 0 && as.owned <= LE_AUDITION_MAX_BUFFERS);
    le_backing_state s;
    CHECK(le_engine_backing_state(e, &s) == LE_OK);
    CHECK(s.owned >= 0 && s.owned <= LE_BACKING_MAX_BUFFERS);
    CHECK(s.owned_bytes <= LE_BACKING_BUDGET_BYTES);
    if (s.owned > max_owned) max_owned = s.owned;
    if (s.end_count != last_end_count && s.last_end == LE_BACKING_EV_ADVANCED)
      ++advances;
    last_end_count = s.end_count;
  }
  if (armed) {
    pause_pump();
    CHECK(le_perf_disarm(e) == LE_OK);
    resume_pump();
  }
  atomic_store_explicit(&g_stop, 1, memory_order_release);
  CHECK(pthread_join(audio, NULL) == 0);
  printf("  %d accepted, %d refused (ring full or in transit), %d buffer "
         "handoffs, %d advances seen, %ld blocks, max owned %d, %d previews, "
         "%d arms\n",
         accepted, refused, handoffs, advances,
         (long)atomic_load(&g_blocks), max_owned, previews, arms);
  /* The interleaving is the scheduler's; these only prove the race was
   * exercised at all, with margins no machine should miss. */
  CHECK(handoffs >= 100);
  CHECK(previews >= 50);
  CHECK(arms >= 1);
  CHECK(advances >= 1);
  CHECK(atomic_load(&g_blocks) >= 100);
  le_engine_destroy(e); /* frees whatever is loaded, staged or in flight */
  {
    char cmd[600];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", capture_dir);
    CHECK(system(cmd) == 0);
  }
  if (g_failures) {
    printf("%d CHECK(S) FAILED\n", g_failures);
    return 1;
  }
  printf("ALL PASSED\n");
  return 0;
}
