/* The octaver's shared tables built by two threads at once (#1410).
 *
 * The Hann window and the FFT plan are process-wide and built the first time
 * any thread prepares an octaver: the control thread and the wet-cache worker
 * both can. Two threads here prepare their own octaver at the same instant and
 * run it straight away, so whichever loses the race reads tables the other is
 * building. ThreadSanitizer (native-tests-tsan) reports that read if the build
 * is not ordered before it; without TSan, both outputs must still match a
 * third run made after the tables are certainly complete.
 *
 * Its own binary on purpose: the tables are built once per process, so the
 * race only exists for the first octaver a process prepares. */
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"
#include "../host/plugin_slot.h"

/* engine_fx.c's LE_FX_PLUGIN row; no plugin runs here. */
void le_plugin_slot_process(le_plugin_slot* slot, float* l, float* r) {
  (void)slot; (void)l; (void)r;
}

static int failures;
#define CHECK(c)                                                       \
  do {                                                                 \
    if (!(c)) {                                                        \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);     \
      ++failures;                                                      \
    }                                                                  \
  } while (0)

enum { SR = 48000, FRAMES = SR / 2 };

/* Both racers spin here until both have arrived (macOS has no
 * pthread_barrier). */
static atomic_int g_arrived;

typedef struct {
  float out[FRAMES];
  int ok;
} runner;

/* Prepares an octaver an octave down, fully wet, and runs a 220 Hz sine
 * through it. */
static void run_octaver(runner* r) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(*fx));
  if (fx == NULL) return;
  int32_t types[LE_FX_MAX] = {LE_FX_OCTAVER};
  int32_t enabled[LE_FX_MAX] = {1};
  float params[LE_FX_MAX][LE_FX_PARAMS] = {{0.25f, 0.5f, 1.0f, 0.0f}};
  le_fx_entry_reset(fx, 0);
  r->ok = le_fx_prepare(fx, 0, LE_FX_OCTAVER, SR) == LE_OK;
  for (int i = 0; i < FRAMES && r->ok; ++i) {
    float l = 0.5f * sinf(2.0f * 3.14159265f * 220.0f * (float)i / SR);
    float rr = l;
    fx_apply_chain(fx, SR, SR, &l, &rr, 1, types, params, enabled);
    r->out[i] = l;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
}

static void* racer(void* opaque) {
  runner* r = (runner*)opaque;
  atomic_fetch_add(&g_arrived, 1);
  while (atomic_load(&g_arrived) < 2) {
  }
  run_octaver(r);
  return NULL;
}

int main(void) {
  static runner a, b, ref;
  pthread_t ta, tb;
  CHECK(pthread_create(&ta, NULL, racer, &a) == 0);
  CHECK(pthread_create(&tb, NULL, racer, &b) == 0);
  CHECK(pthread_join(ta, NULL) == 0);
  CHECK(pthread_join(tb, NULL) == 0);

  run_octaver(&ref); /* the tables are complete by now */
  CHECK(a.ok && b.ok && ref.ok);
  CHECK(memcmp(a.out, ref.out, sizeof(ref.out)) == 0);
  CHECK(memcmp(b.out, ref.out, sizeof(ref.out)) == 0);
  /* And the octaver did sound: the wet tail is not silence. */
  float peak = 0.0f;
  for (int i = FRAMES / 2; i < FRAMES; ++i) peak = fmaxf(peak, fabsf(ref.out[i]));
  CHECK(peak > 0.05f);

  printf("FX table build race failures: %d\n", failures);
  return failures != 0;
}
