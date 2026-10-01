/* Real recipe/command/callback lifecycle with a deterministic hosted effect.
 * Only the host is fake; allocation, admission, publication and retirement use
 * the production engine. Run under ASan/TSan as well as the portable gate. */
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "engine_internal.h"
#include "engine_private.h"
#include "engine_core.h"
#include "tempo_grid.h"
#include "../host/plugin_slot.h"

#define le_plugin_slot_create unused_slot_create
#define le_plugin_slot_destroy unused_slot_destroy
#define le_plugin_slot_set_ready unused_slot_set_ready
#define le_plugin_slot_process unused_slot_process
#define le_plugin_slot_prepare_param unused_slot_prepare_param
#include "../core/plugin_disabled.c"
#undef le_plugin_slot_create
#undef le_plugin_slot_destroy
#undef le_plugin_slot_set_ready
#undef le_plugin_slot_process
#undef le_plugin_slot_prepare_param

struct le_plugin_slot { _Atomic int ready; float gain; int id; };
void le_test_after_clear_posted(le_engine* e) { (void)e; }
void le_test_record_image_staged(le_engine* e) { (void)e; }
static int created, destroyed, failures;
static _Atomic int park, entered, resume_callback;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)
le_plugin_slot* le_plugin_slot_create(const char* id, double sr, int32_t* reason) {
  (void)sr;
  if (!strcmp(id, "fail")) { *reason = LE_ERR_DEVICE; return NULL; }
  le_plugin_slot* p = calloc(1, sizeof(*p));
  if (!p) { *reason = LE_ERR_DEVICE; return NULL; }
  p->gain = .5f; p->id = ++created; *reason = LE_OK; return p;
}
void le_plugin_slot_destroy(le_plugin_slot* p) { if (p) { ++destroyed; free(p); } }
void le_plugin_slot_set_ready(le_plugin_slot* p, int ready) {
  atomic_store_explicit(&p->ready, ready, memory_order_release);
}
int32_t le_plugin_slot_prepare_param(le_plugin_slot* p, uint32_t id, double value) {
  if (atomic_load(&p->ready) || id != 0) return LE_ERR_INVALID;
  p->gain = (float)value; return LE_OK;
}
void le_plugin_slot_process(le_plugin_slot* p, float* l, float* r) {
  if (!atomic_load_explicit(&p->ready, memory_order_acquire)) return;
  if (atomic_exchange(&park, 0)) {
    atomic_store(&entered, 1);
    while (!atomic_load(&resume_callback)) {}
  }
  *l *= p->gain; *r *= p->gain;
}
static le_fx_recipe recipe(le_plugin_slot* p) {
  le_fx_recipe r = {.count = 1, .enabled = 1};
  r.type[0] = LE_FX_PLUGIN; r.plugin[0] = p;
  r.slot_enabled[0] = 1; r.level[0] = 1; return r;
}
static void pump(le_engine* e, float input, float* out) {
  float in[64]; for (int i = 0; i < 64; ++i) in[i] = input;
  le_engine_process(e, out, in, 64);
}
static void* parked_process(void* engine) {
  float out[128]; pump(engine, .4f, out); return NULL;
}
/* The final slot participates in the complete recipe, and a refused 65-slot
 * edit leaves the prior recipe sounding and acknowledged. This exercises the
 * production callback, not just the published arrays. */
static void test_full_recipe_boundary(void) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 2, 1000) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 3) == LE_OK);
  le_fx_recipe r = {.count = LE_FX_MAX, .enabled = 1};
  for (int s = 0; s < LE_FX_MAX; ++s) {
    r.type[s] = LE_FX_DRIVE;
    r.slot_enabled[s] = 1;
    r.level[s] = 1;
    r.params[s][1] = 1.0f; /* unity output gain */
  }
  const int last = LE_FX_MAX - 1;
  r.params[last][3] = .375f;
  r.output_mode[last] = 1;
  r.placement[last] = 1;
  r.level[last] = .5f;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 100, &r) == LE_OK);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 0);
  float out[128];
  for (int n = 0; n < 12; ++n) pump(e, .4f, out);
  le_engine_drain_events(e);
  float expected = .4f;
  for (int s = 0; s < LE_FX_MAX; ++s) expected = tanhf(expected);
  CHECK(fabsf(out[126]) < 1e-6f);
  CHECK(fabsf(out[127] - expected * .5f) < 1e-5f);
  CHECK(load_f32(&e->monitors[0].a_fx_param[last][3]) == .375f);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 100);
  r.count = LE_FX_MAX + 1;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 101, &r) == LE_ERR_INVALID);
  pump(e, .4f, out);
  CHECK(fabsf(out[127] - expected * .5f) < 1e-5f);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 100);
  r.count = LE_FX_MAX;
  r.slot_enabled[last] = 0;
  r.output_mode[last] = 0; r.placement[last] = 0; r.level[last] = 1;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 102, &r) == LE_OK);
  for (int n = 0; n < 12; ++n) pump(e, .4f, out);
  expected = .4f;
  for (int s = 0; s < last; ++s) expected = tanhf(expected);
  CHECK(fabsf(out[126] - expected) < 1e-5f);
  CHECK(fabsf(out[127] - expected) < 1e-5f);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 102);
  le_engine_destroy(e);
}

int main(void) {
  test_full_recipe_boundary();
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 2, 1000) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 3) == LE_OK);
  float out[128]; pump(e, 0, out);
  le_plugin_slot *old = NULL, *next = NULL;
  CHECK(le_engine_prepare_plugin(e, "gain", &old) == LE_OK);
  le_fx_recipe r = recipe(old);
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 1, &r) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 0, .7f) == LE_ERR_INVALID);
  pump(e, .4f, out); le_engine_drain_events(e);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 1);
  CHECK(out[126] > .199f && out[126] < .201f);
  CHECK(le_engine_prepare_plugin(e, "fail", &next) == LE_ERR_DEVICE);
  CHECK(destroyed == 0);
  CHECK(le_engine_prepare_plugin(e, "gain", &next) == LE_OK);
  CHECK(le_engine_prepare_plugin_param(e, next, 0, .25) == LE_OK);
  r = recipe(next);
  while (le_engine_set_quantize_div(e, LE_GRID_DIV_OFF) == LE_OK) {}
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 2, &r) == LE_ERR_INVALID);
  CHECK(le_engine_discard_prepared_plugin(e, next) == LE_OK);
  CHECK(destroyed == 1);
  pump(e, .4f, out); CHECK(out[126] > .199f && out[126] < .201f);

  CHECK(le_engine_prepare_plugin(e, "gain", &next) == LE_OK);
  CHECK(le_engine_prepare_plugin_param(e, next, 0, .25) == LE_OK);
  r = recipe(next);
  /* Existing command settlement is 64-bit. Cross the 32-bit boundary while
   * an old callback holds the host; truncating the ticket frees the queued
   * replacement before the callback can acquire it. */
  e->commands_posted = UINT32_MAX;
  e->commands_applied = UINT32_MAX;
  atomic_store(&e->a_commands_published, UINT32_MAX);
  atomic_store(&park, 1);
  pthread_t thread; CHECK(pthread_create(&thread, NULL, parked_process, e) == 0);
  while (!atomic_load(&entered)) {}
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 3, &r) == LE_OK);
  le_engine_drain_events(e); CHECK(destroyed == 1);
  atomic_store(&resume_callback, 1);
  CHECK(pthread_join(thread, NULL) == 0);
  le_engine_drain_events(e); CHECK(destroyed == 1);
  pump(e, .4f, out); le_engine_drain_events(e);
  CHECK(destroyed == 2);
  CHECK(out[126] > .099f && out[126] < .101f);
  CHECK(le_engine_fx_recipe_revision(e, LE_FX_OWNER_MONITOR, 0, 0) == 3);

  /* An arm owns its frozen host until capture or cancellation, even though
   * the admission command has long since been consumed. */
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK); pump(e, 0, out);
  le_plugin_slot* take = NULL;
  CHECK(le_engine_prepare_plugin(e, "gain", &take) == LE_OK);
  le_fx_recipe lanes[LE_MAX_LANES] = {0}; lanes[0] = recipe(take);
  le_record_image image = {.revision = 17, .lane_mask = 1, .gain = {1},
      .fx_lane_mask = 1, .lane_fx = lanes};
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  pump(e, 0, out); le_engine_drain_events(e); CHECK(destroyed == 2);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, .2f) == LE_ERR_INVALID);
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump(e, 0, out); le_engine_drain_events(e); CHECK(destroyed == 3);
  CHECK(atomic_load(&e->tracks[0].lanes[0].fx.plugin[0]) == NULL);

  /* Placement/reorder retains the same live instance rather than cloning or
   * destroying its host. Per-entry power follows that instance. */
  le_plugin_slot* companion = NULL;
  CHECK(le_engine_prepare_plugin(e, "gain", &companion) == LE_OK);
  le_fx_recipe pair = recipe(next); pair.count = 2;
  pair.type[1] = LE_FX_PLUGIN; pair.plugin[1] = companion;
  pair.slot_enabled[0] = 0; pair.slot_enabled[1] = 1; pair.level[1] = 1;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 4, &pair) == LE_OK);
  for (int i = 0; i < 8; ++i) pump(e, .4f, out);
  le_engine_drain_events(e); CHECK(destroyed == 3);
  pair.plugin[0] = companion; pair.plugin[1] = next;
  pair.slot_enabled[0] = 1; pair.slot_enabled[1] = 0;
  CHECK(le_engine_set_fx_recipe(e, LE_FX_OWNER_MONITOR, 0, 0, 5, &pair) == LE_OK);
  for (int i = 0; i < 8; ++i) pump(e, .4f, out);
  le_engine_drain_events(e); CHECK(destroyed == 3);
  CHECK(atomic_load(&e->monitors[0].fx.plugin[0]) == companion);
  CHECK(atomic_load(&e->monitors[0].fx.plugin[1]) == next);
  CHECK(out[126] > .199f && out[126] < .201f);

  /* Prepared handles from another engine are refused without dereferencing. */
  le_engine* other = le_engine_create();
  CHECK(le_engine_configure(other, 48000, 1, 2, 1000) == LE_OK);
  r = recipe(next);
  CHECK(le_engine_set_fx_recipe(other, LE_FX_OWNER_MONITOR, 0, 0, 1, &r) == LE_ERR_INVALID);
  le_engine_destroy(other);
  le_engine_destroy(e);
  CHECK(created == destroyed);
  printf("fx recipe plugin lifecycle: %d failures (%d hosts reclaimed)\n", failures, destroyed);
  return failures ? 1 : 0;
}
