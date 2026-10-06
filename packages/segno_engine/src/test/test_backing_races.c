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
 * Deterministic op sequence (fixed seed); the interleaving is not.
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "segno_engine_api.h"

#define SR 48000
#define OPS 20000

static atomic_int g_stop;
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
    le_engine_process(e, out, in, n);
    n = n % 61 + 1; /* every block length 1..61, so ends land anywhere */
  }
  return NULL;
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

  int accepted = 0, refused = 0, max_owned = 0;
  for (int op = 0; op < OPS; ++op) {
    int32_t rc = LE_OK;
    switch (next_rand() % 9) {
      case 0:
      case 1: {
        le_backing_buffer* b = make_buffer();
        rc = le_engine_backing_load(e, b, op, (int32_t)(next_rand() % 2));
        if (rc != LE_OK) le_backing_buffer_free(b);
        break;
      }
      case 2:
      case 3: {
        le_backing_buffer* b = make_buffer();
        rc = le_engine_backing_stage_next(e, b, op);
        if (rc != LE_OK) le_backing_buffer_free(b);
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
        rc = le_engine_backing_set_end(e, (int32_t)(next_rand() % 3));
        break;
      default:
        break;
    }
    if (rc == LE_OK) ++accepted;
    else ++refused;
    CHECK(rc == LE_OK || rc == LE_ERR_NOT_READY || rc == LE_ERR_INVALID);
    le_backing_state s;
    CHECK(le_engine_backing_state(e, &s) == LE_OK);
    CHECK(s.owned >= 0 && s.owned <= LE_BACKING_MAX_BUFFERS);
    CHECK(s.owned_bytes <= LE_BACKING_BUDGET_BYTES);
    if (s.owned > max_owned) max_owned = s.owned;
  }
  atomic_store_explicit(&g_stop, 1, memory_order_release);
  CHECK(pthread_join(audio, NULL) == 0);
  printf("  %d accepted, %d refused (ring full or in transit), max owned %d\n",
         accepted, refused, max_owned);
  CHECK(accepted > OPS / 2);
  le_engine_destroy(e); /* frees whatever is loaded, staged or in flight */
  if (g_failures) {
    printf("%d CHECK(S) FAILED\n", g_failures);
    return 1;
  }
  printf("ALL PASSED\n");
  return 0;
}
