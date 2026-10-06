/*
 * engine_backing.c — the backing player's buffers and control-thread API
 * (#1200). The contract is in segno_engine_api.h; the voice itself (the
 * command handlers and the per-frame read) is in engine_process.c, the
 * audio-thread translation unit.
 *
 * Ownership. A buffer is the caller's until le_engine_backing_load or
 * le_engine_backing_stage_next accepts it. From then on it is listed in
 * engine->backing_owned until the control thread frees it, which happens in
 * exactly two ways:
 *   - the callback stores it in an a_backing_dead slot once it will never
 *     read it again, and le_backing_collect frees it;
 *   - le_backing_release frees it with the callback stopped (configure,
 *     reopen, destroy): a buffer still queued in the command ring (which
 *     configure and reopen re-initialise) is freed here too.
 * The audio thread never allocates or frees.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"
#include "engine_private.h"

int32_t le_backing_buffer_from_pcm(const float* interleaved, int32_t frames,
                                   int32_t channels, int32_t sample_rate,
                                   le_backing_buffer** out) {
  if (out != NULL) *out = NULL;
  if (interleaved == NULL || out == NULL || frames <= 0 || channels < 1 ||
      channels > 2 || sample_rate <= 0) {
    return LE_ERR_INVALID;
  }
  le_backing_buffer* b = (le_backing_buffer*)calloc(1, sizeof(*b));
  if (b == NULL) return LE_ERR_CAPACITY;
  b->pcm = (float*)malloc((size_t)frames * 2u * sizeof(float));
  if (b->pcm == NULL) {
    free(b);
    return LE_ERR_CAPACITY;
  }
  if (channels == 2) {
    memcpy(b->pcm, interleaved, (size_t)frames * 2u * sizeof(float));
  } else {
    for (int32_t f = 0; f < frames; ++f) {
      b->pcm[2 * f] = interleaved[f];
      b->pcm[2 * f + 1] = interleaved[f];
    }
  }
  b->frames = frames;
  b->sample_rate = sample_rate;
  *out = b;
  return LE_OK;
}

int32_t le_backing_buffer_frames(const le_backing_buffer* buffer) {
  return buffer == NULL ? 0 : buffer->frames;
}

int32_t le_backing_buffer_rate(const le_backing_buffer* buffer) {
  return buffer == NULL ? 0 : buffer->sample_rate;
}

int32_t le_backing_buffer_peaks(const le_backing_buffer* buffer, float* out,
                                int32_t buckets) {
  if (buffer == NULL || out == NULL || buckets <= 0) return LE_ERR_INVALID;
  for (int32_t k = 0; k < buckets; ++k) {
    const int64_t a = (int64_t)buffer->frames * k / buckets;
    const int64_t z = (int64_t)buffer->frames * (k + 1) / buckets;
    float peak = 0.0f;
    for (int64_t f = a; f < z; ++f) {
      const float l = fabsf(buffer->pcm[2 * f]);
      const float r = fabsf(buffer->pcm[2 * f + 1]);
      if (l > peak) peak = l;
      if (r > peak) peak = r;
    }
    out[k] = peak;
  }
  return buckets;
}

void le_backing_buffer_free(le_backing_buffer* buffer) {
  if (buffer == NULL) return;
  free(buffer->pcm);
  free(buffer);
}

/* ---- the control-thread registry ---- */

static int le_backing_owned_index(const le_engine* e,
                                  const le_backing_buffer* b) {
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    if (e->backing_owned[i] == b) return i;
  }
  return -1;
}

static int le_backing_owned_count(const le_engine* e) {
  int n = 0;
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    if (e->backing_owned[i] != NULL) ++n;
  }
  return n;
}

/* Frees every buffer the callback has returned. Control thread. */
static void le_backing_collect(le_engine* e) {
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    le_backing_buffer* b = atomic_exchange_explicit(
        &e->a_backing_dead[i], (le_backing_buffer*)NULL, memory_order_acquire);
    if (b == NULL) continue;
    const int k = le_backing_owned_index(e, b);
    if (k >= 0) e->backing_owned[k] = NULL;
    le_backing_buffer_free(b);
  }
}

void le_backing_release(le_engine* e, int keep_loaded) {
  le_backing_collect(e);
  le_backing_buffer* keep_cur = keep_loaded ? e->backing_cur.buf : NULL;
  le_backing_buffer* keep_next = keep_loaded ? e->backing_next : NULL;
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    le_backing_buffer* b = e->backing_owned[i];
    if (b == NULL || b == keep_cur || b == keep_next) continue;
    le_backing_buffer_free(b);
    e->backing_owned[i] = NULL;
  }
  e->backing_fade = (le_backing_voice){0};
  e->backing_cur = (le_backing_voice){.buf = keep_cur};
  e->backing_next = keep_next;
  if (keep_cur == NULL) e->backing_item = -1;
  if (keep_next == NULL) e->backing_next_item = -1;
  e->backing_state = LE_BACKING_STOPPED;
  store_i32(&e->a_backing_item, e->backing_item);
  store_i32(&e->a_backing_next_item, e->backing_next_item);
  store_i32(&e->a_backing_transport, LE_BACKING_STOPPED);
  store_i32(&e->a_backing_position, 0);
  store_i32(&e->a_backing_frames, keep_cur != NULL ? keep_cur->frames : 0);
}

/* ---- the API ---- */

/* Registers [buffer] and posts it with [code]. */
static int32_t le_backing_post_buffer(le_engine* e, int32_t code,
                                      le_backing_buffer* buffer, int32_t item,
                                      int32_t play) {
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (buffer != NULL && (buffer->sample_rate != e->sample_rate ||
                         le_backing_owned_index(e, buffer) >= 0)) {
    return LE_ERR_INVALID;
  }
  le_backing_collect(e);
  int slot = -1;
  if (buffer != NULL) {
    slot = le_backing_owned_index(e, NULL);
    if (slot < 0) return LE_ERR_NOT_READY;
    e->backing_owned[slot] = buffer;
  }
  const int32_t rc = le_push_cmd(
      e, (le_command){.code = code, .backing = {buffer, item, play ? 1 : 0}});
  if (rc != LE_OK && slot >= 0) e->backing_owned[slot] = NULL;
  return rc;
}

int32_t le_engine_backing_load(le_engine* engine, le_backing_buffer* buffer,
                               int32_t item, int32_t play) {
  if (engine == NULL || buffer == NULL) return LE_ERR_INVALID;
  return le_backing_post_buffer(engine, LE_CMD_BACKING_LOAD, buffer, item,
                                play);
}

int32_t le_engine_backing_stage_next(le_engine* engine,
                                     le_backing_buffer* buffer, int32_t item) {
  if (engine == NULL) return LE_ERR_INVALID;
  return le_backing_post_buffer(engine, LE_CMD_BACKING_STAGE_NEXT, buffer,
                                buffer != NULL ? item : -1, 0);
}

int32_t le_engine_backing_clear(le_engine* engine) {
  return le_push(engine, LE_CMD_BACKING_CLEAR, 0, 0.0f);
}

int32_t le_engine_backing_transport(le_engine* engine, int32_t op) {
  if (op < LE_BACKING_OP_PLAY || op > LE_BACKING_OP_STOP) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_BACKING_TRANSPORT, op, 0.0f);
}

int32_t le_engine_backing_seek(le_engine* engine, int32_t frame) {
  return le_push(engine, LE_CMD_BACKING_SEEK, frame < 0 ? 0 : frame, 0.0f);
}

int32_t le_engine_backing_set_end(le_engine* engine, int32_t mode) {
  if (engine == NULL || mode < LE_BACKING_END_STOP ||
      mode > LE_BACKING_END_NEXT) {
    return LE_ERR_INVALID;
  }
  store_i32(&engine->a_backing_end_mode, mode);
  return LE_OK;
}

int32_t le_engine_backing_set_output(le_engine* engine, int32_t mask) {
  if (engine == NULL) return LE_ERR_INVALID;
  atomic_store_explicit(&engine->a_backing_mask, (uint32_t)mask,
                        memory_order_relaxed);
  return LE_OK;
}

int32_t le_engine_backing_set_level(le_engine* engine, float gain) {
  if (engine == NULL || isnan(gain)) return LE_ERR_INVALID;
  if (gain < 0.0f) gain = 0.0f;
  if (gain > LE_MAX_GAIN) gain = LE_MAX_GAIN;
  store_f32(&engine->a_backing_level_bits, gain);
  return LE_OK;
}

static int32_t le_store_pan(le_engine* engine, _Atomic uint32_t* slot,
                            float pan) {
  if (engine == NULL || isnan(pan)) return LE_ERR_INVALID;
  if (pan < -1.0f) pan = -1.0f;
  if (pan > 1.0f) pan = 1.0f;
  store_f32(slot, pan);
  return LE_OK;
}

int32_t le_engine_backing_set_pan(le_engine* engine, float pan) {
  return le_store_pan(engine, engine ? &engine->a_backing_pan_bits : NULL, pan);
}

int32_t le_engine_set_click_pan(le_engine* engine, float pan) {
  return le_store_pan(engine, engine ? &engine->a_click_pan_bits : NULL, pan);
}

int32_t le_engine_backing_state(le_engine* engine, le_backing_state* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  le_backing_collect(engine);
  out->epoch = atomic_load_explicit(&engine->a_backing_epoch,
                                    memory_order_acquire);
  out->item = load_i32(&engine->a_backing_item);
  out->next_item = load_i32(&engine->a_backing_next_item);
  out->transport = load_i32(&engine->a_backing_transport);
  out->position = load_i32(&engine->a_backing_position);
  out->frames = load_i32(&engine->a_backing_frames);
  out->end_count = atomic_load_explicit(&engine->a_backing_end_count,
                                        memory_order_relaxed);
  out->last_end = load_i32(&engine->a_backing_last_end);
  out->end_mode = load_i32(&engine->a_backing_end_mode);
  out->mask = atomic_load_explicit(&engine->a_backing_mask,
                                   memory_order_relaxed);
  out->level = load_f32(&engine->a_backing_level_bits);
  out->pan = load_f32(&engine->a_backing_pan_bits);
  out->click_pan = load_f32(&engine->a_click_pan_bits);
  out->owned = le_backing_owned_count(engine);
  return LE_OK;
}
