/*
 * engine_audition.c — the Library audition voice's control-thread API
 * (#1178). The contract is in segno_engine_api.h; the voice itself (the
 * command handlers and the per-frame mix) is in engine_process.c.
 *
 * Ownership is the backing player's (engine_backing.c), on a registry of its
 * own so a preview never takes a backing slot: a buffer is the caller's until
 * le_engine_audition_start accepts it, then it is listed in
 * engine->audition_owned until the control thread frees it, either after the
 * callback hands it back through an a_audition_dead slot (le_audition_collect)
 * or with the callback stopped (le_audition_release: configure, reopen,
 * destroy, which also frees a buffer still queued in the command ring). The
 * audio thread never allocates or frees.
 */
#include "engine_core.h"
#include "engine_private.h"

static int le_audition_owned_index(const le_engine* e,
                                   const le_backing_buffer* b) {
  for (int i = 0; i < LE_AUDITION_MAX_BUFFERS; ++i) {
    if (e->audition_owned[i] == b) return i;
  }
  return -1;
}

/* Frees every buffer the callback has handed back. Control thread. */
static void le_audition_collect(le_engine* e) {
  for (int i = 0; i < LE_AUDITION_MAX_BUFFERS; ++i) {
    le_backing_buffer* b = atomic_exchange_explicit(
        &e->a_audition_dead[i], (le_backing_buffer*)NULL,
        memory_order_acquire);
    if (b == NULL) continue;
    const int k = le_audition_owned_index(e, b);
    if (k >= 0) e->audition_owned[k] = NULL;
    le_backing_buffer_free(b);
  }
}

void le_audition_release(le_engine* e) {
  le_audition_collect(e);
  for (int i = 0; i < LE_AUDITION_MAX_BUFFERS; ++i) {
    le_backing_buffer_free(e->audition_owned[i]);
    e->audition_owned[i] = NULL;
  }
  e->audition_buf = NULL;
  e->audition_pos = 0;
  e->audition_bus = -1;
  store_i32(&e->a_audition_frames, 0);
  store_i32(&e->a_audition_position, 0);
  store_i32(&e->a_audition_bus, -1);
}

int32_t le_engine_audition_start(le_engine* engine, le_backing_buffer* buffer,
                                 int32_t bus) {
  if (engine == NULL || buffer == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (buffer->sample_rate != engine->sample_rate || buffer->frames <= 0 ||
      (int64_t)buffer->frames >
          (int64_t)LE_AUDITION_MAX_SECONDS * engine->sample_rate ||
      bus < 0 || bus >= LE_MAX_OUTPUT_BUSES ||
      le_audition_owned_index(engine, buffer) >= 0) {
    return LE_ERR_INVALID;
  }
  if (atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  le_audition_collect(engine);
  const int slot = le_audition_owned_index(engine, NULL);
  if (slot < 0) return LE_ERR_NOT_READY;
  engine->audition_owned[slot] = buffer;
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_AUDITION_START,
                           .backing = {buffer, bus, 0}});
  if (rc != LE_OK) engine->audition_owned[slot] = NULL;
  return rc;
}

int32_t le_engine_audition_stop(le_engine* engine) {
  return le_push(engine, LE_CMD_AUDITION_STOP, 0, 0.0f);
}

int32_t le_engine_audition_state(le_engine* engine, le_audition_state* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  le_audition_collect(engine);
  out->epoch = atomic_load_explicit(&engine->a_audition_epoch,
                                    memory_order_acquire);
  out->frames = load_i32(&engine->a_audition_frames);
  out->position = load_i32(&engine->a_audition_position);
  out->bus = load_i32(&engine->a_audition_bus);
  int owned = 0;
  for (int i = 0; i < LE_AUDITION_MAX_BUFFERS; ++i) {
    if (engine->audition_owned[i] != NULL) ++owned;
  }
  out->owned = owned;
  return LE_OK;
}
