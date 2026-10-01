/* Portable plugin publication regression. The fake host owns no DSP; the
 * production installer and callback DSP share their real runtime state. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include "engine_fx.h"
#include "../host/plugin_slot.h"

struct le_plugin_slot { _Atomic int ready; };
le_plugin_slot* le_plugin_slot_create(const char* id, double sr, int32_t* reason) {
  (void)id; (void)sr;
  le_plugin_slot* slot = calloc(1, sizeof(*slot));
  if (reason) *reason = slot ? LE_OK : LE_ERR_DEVICE;
  return slot;
}
void le_plugin_slot_destroy(le_plugin_slot* slot) { free(slot); }
void le_plugin_slot_set_ready(le_plugin_slot* slot, int ready) {
  atomic_store_explicit(&slot->ready, ready, memory_order_release);
}
void le_plugin_slot_process(le_plugin_slot* slot, float* l, float* r) {
  if (atomic_load_explicit(&slot->ready, memory_order_acquire)) { *l *= .5f; *r *= .5f; }
}
static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)
typedef struct {
  le_engine* e;
  _Atomic int primed, resume, done;
  int parked;
} fixture;
static void* callback(void* opaque) {
  fixture* f = opaque;
  le_monitor_input* m = &f->e->monitors[0];
  le_fx_state* fx = &m->fx;
  int32_t types[LE_FX_MAX] = {LE_FX_DELAY};
  int32_t enabled[LE_FX_MAX] = {0};
  float params[LE_FX_MAX][LE_FX_PARAMS] = {{.2f, .5f, 1, 0}};
  /* This callback owns the exact fields install formerly changed. */
  fx->enable_drain[0] = 1;
  fx->enable_quiet[0] = 17;
  atomic_store_explicit(&f->primed, 1, memory_order_release);
  if (f->parked) while (!atomic_load_explicit(&f->resume, memory_order_acquire)) {}
  for (int n = 0; n < 100000; ++n) {
    types[0] = atomic_load_explicit(&m->a_fx_type[0], memory_order_acquire);
    enabled[0] = atomic_load_explicit(&m->a_fx_enabled[0], memory_order_relaxed);
    float l = .1f, r = .1f;
    fx_apply_chain(fx, 1000, 1000, &l, &r, 1, types, params, enabled);
  }
  atomic_store_explicit(&f->done, 1, memory_order_release);
  return NULL;
}
int main(void) {
  for (int parked = 0; parked < 2; ++parked) {
    le_engine* e = calloc(1, sizeof(*e));
    fixture f = {.e = e, .parked = parked};
    e->sample_rate = 1000;
    le_monitor_input* m = &e->monitors[0];
    atomic_store(&m->a_fx_type[0], LE_FX_DELAY);
    atomic_store(&m->a_fx_enabled[0], 0);
    CHECK(le_fx_prepare(&m->fx, 0, LE_FX_DELAY, 1000) == LE_OK);
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, callback, &f) == 0);
    while (!atomic_load_explicit(&f.primed, memory_order_acquire)) {}
    le_plugin_slot* slot = NULL;
    CHECK(le_engine_set_monitor_plugin(e, 0, 0, "test", &slot) == LE_OK);
    if (parked) {
      CHECK(m->fx.enable_drain[0] == 1);
      CHECK(m->fx.enable_quiet[0] == 17);
    }
    atomic_store_explicit(&f.resume, 1, memory_order_release);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(m->fx.enable_drain[0] == 0);
    CHECK(m->fx.enable_quiet[0] == 0);
    CHECK(le_engine_clear_monitor_plugin(e, 0, 0) == LE_OK);
    le_fx_state_free_buffers(&m->fx);
    free(e);
  }
  printf("Plugin runtime race failures: %d\n", failures);
  return failures != 0;
}
