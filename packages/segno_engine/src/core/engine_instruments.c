/*
 * engine_instruments.c — instrument slots, buses and note rings, and the
 * synth inside the audio callback (#1197 Part 2a).
 *
 * Threads: the le_engine_* calls below run on the control thread (the single
 * producer of every command and of both note rings); le_instruments_block,
 * le_instruments_apply_command and le_instruments_cut run on the audio
 * thread; create, reset and destroy run with no callback (create/destroy, or
 * configure/reopen with the device closed).
 *
 * Ordering: the control thread stamps every event with one posting sequence
 * across the note-on ring and the release ring and publishes the highest
 * sequence after each push. The callback reads that high-water mark first
 * and merges the two rings by sequence up to it: every event at or below it
 * is visible in both rings, so the merge sees a consistent cut and a note-on
 * and its note-off are applied in posting order whenever they land. Patch changes ride the note-on ring too,
 * so a note posted after its instrument was set can never meet the previous
 * patch (the command ring is drained separately and gives no such order).
 * The release ring is a reserved lane: a full note-on ring refuses note-ons
 * (counted) but never a release. The note-on ring itself keeps room for one
 * patch change per slot: note-ons are refused while fewer than
 * LE_MAX_INSTRUMENTS slots would stay free, so an Apply or Cancel always
 * fits.
 *
 * Parameters are continuous controls: three float bits per slot stamped with
 * the patch they belong to and a revision. The callback applies a changed
 * revision once per block, only to the patch it was stamped for, and a patch
 * change applies the current stamped values at once. A read that overlaps
 * two publishes may mix them for one block; the next revision settles it
 * (eventually consistent, as every continuous control).
 */
#include "engine_instruments.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"
#include "segno_engine_api.h"
#include "synth_voice.h"

enum {
  LE_INST_NOTE_ON = 1,
  LE_INST_NOTE_OFF = 2,
  LE_INST_SET_PATCH = 3, /* note = patch index, or LE_INST_NO_PATCH */
  LE_INST_SUSTAIN_ON = 4,
  LE_INST_SUSTAIN_OFF = 5, /* release lane */
  LE_INST_CHORD_NOTE_ON = 6, /* a chord's later note: no repeated strike */
};

/* The public pool bound is the synth's. */
_Static_assert(LE_INST_MAX_VOICES == LE_SYNTH_MAX_VOICES,
               "LE_INST_MAX_VOICES is the synth pool");

/* MIDI origins: tag bit clear, port (3 bits), channel (4), kind (1: note 0,
 * controller 1), number (7). Control origins set the tag bit. */
#define LE_INST_PORT_MASK (LE_INST_CONTROL_ORIGIN | (7u << 24))

static uint32_t midi_origin(int32_t port, int32_t ch, int32_t kind,
                            int32_t number) {
  return ((uint32_t)port << 24) | ((uint32_t)ch << 16) |
         ((uint32_t)kind << 8) | (uint32_t)number;
}

#define LE_INST_NO_PATCH 0xffu

/* The callback applies at most this many note events per block; the rest
 * wait one block, in order. */
#define LE_INST_EVENTS_PER_BLOCK 512
#define LE_INST_DEFAULT_VOICE_LIMIT 32

/* ---- the event rings ---- */

static void ring_init(le_inst_ring* r, le_inst_event* storage, uint32_t cap) {
  atomic_store_explicit(&r->head, 0u, memory_order_relaxed);
  atomic_store_explicit(&r->tail, 0u, memory_order_relaxed);
  r->mask = cap - 1u;
  r->slots = storage;
}

/* Free slots (producer side; one slot is always kept empty). */
static uint32_t ring_free(le_inst_ring* r) {
  const uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
  const uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
  return r->mask - (tail - head);
}

static int ring_push(le_inst_ring* r, const le_inst_event* ev) {
  const uint32_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
  const uint32_t head = atomic_load_explicit(&r->head, memory_order_acquire);
  if (tail - head >= r->mask) return 0; /* full (one slot kept empty) */
  r->slots[tail & r->mask] = *ev;
  atomic_store_explicit(&r->tail, tail + 1u, memory_order_release);
  return 1;
}

/* The oldest event, or NULL when empty (consumer side). */
static const le_inst_event* ring_peek(le_inst_ring* r) {
  const uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
  const uint32_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
  if (head == tail) return NULL;
  return &r->slots[head & r->mask];
}

static void ring_pop(le_inst_ring* r) {
  const uint32_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
  atomic_store_explicit(&r->head, head + 1u, memory_order_release);
}

/* ---- lifecycle (no callback running) ---- */

int le_instruments_create(le_engine* e) {
  e->synth = (struct le_synth*)calloc(1, sizeof(le_synth));
  e->inst_bus = (float*)calloc(
      (size_t)LE_MAX_INSTRUMENTS * (size_t)LE_COND_SCRATCH_FRAMES, sizeof(float));
  if (e->synth == NULL || e->inst_bus == NULL) {
    le_instruments_destroy(e);
    return 0;
  }
  ring_init(&e->inst_ring, e->inst_ring_storage, LE_INST_EVENT_CAPACITY);
  ring_init(&e->inst_release_ring, e->inst_release_storage,
            LE_INST_RELEASE_CAPACITY);
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    e->inst_patch_requested[k] = -1;
    store_i32(&e->a_inst_patch[k], -1);
    store_i32(&e->a_inst_param_patch[k], -1);
  }
  store_i32(&e->a_voice_limit, LE_INST_DEFAULT_VOICE_LIMIT);
  return 1;
}

void le_instruments_destroy(le_engine* e) {
  free(e->synth);
  free(e->inst_bus);
  e->synth = NULL;
  e->inst_bus = NULL;
}

void le_instruments_reset(le_engine* e, int32_t sample_rate) {
  if (e->synth == NULL) return;
  le_synth* s = (le_synth*)e->synth;
  le_synth_init(s, sample_rate, LE_SYNTH_MAX_VOICES, LE_INST_SYNTH_SEED);
  le_synth_set_voice_limit(s, LE_INST_DEFAULT_VOICE_LIMIT);
  ring_init(&e->inst_ring, e->inst_ring_storage, LE_INST_EVENT_CAPACITY);
  ring_init(&e->inst_release_ring, e->inst_release_storage,
            LE_INST_RELEASE_CAPACITY);
  e->inst_seq = 0;
  atomic_store_explicit(&e->a_inst_seq_pub, 0u, memory_order_relaxed);
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    e->inst_patch_requested[k] = -1;
    e->inst_param_seen[k] = 0;
    atomic_store_explicit(&e->a_inst_param_rev[k], 0u, memory_order_relaxed);
    for (int p = 0; p < 3; ++p) store_f32(&e->a_inst_param_bits[k][p], 0.0f);
    store_i32(&e->a_inst_param_patch[k], -1);
    store_i32(&e->a_inst_patch[k], -1);
    store_i32(&e->a_inst_voices[k], 0);
    store_f32(&e->a_inst_peak_bits[k], 0.0f);
  }
  store_i32(&e->a_voice_limit, LE_INST_DEFAULT_VOICE_LIMIT);
  atomic_store_explicit(&e->a_voices_stolen, 0u, memory_order_relaxed);
  atomic_store_explicit(&e->a_voices_stolen_hard, 0u, memory_order_relaxed);
  atomic_store_explicit(&e->a_inst_events_refused, 0u, memory_order_relaxed);
  atomic_store_explicit(&e->a_inst_fallback_blocks, 0u, memory_order_relaxed);
  atomic_store_explicit(&e->a_inst_sustain_refused, 0u, memory_order_relaxed);
  memset(e->inst_routes, 0, sizeof(e->inst_routes));
  memset(e->inst_remap_index, 0, sizeof(e->inst_remap_index));
  memset(e->inst_remap_insts, 0, sizeof(e->inst_remap_insts));
  memset(e->inst_remap_first, 0, sizeof(e->inst_remap_first));
  store_i32(&e->a_inst_routes_live, 0);
  store_i32(&e->a_inst_routes_seen, 0);
  e->inst_routes_active = &e->inst_routes[0];
  e->inst_remap_active = e->inst_remap_index[0];
  e->inst_remap_insts_active = e->inst_remap_insts[0];
  e->inst_remap_first_active = e->inst_remap_first[0];
  memset(e->inst_expr_port, -1, sizeof(e->inst_expr_port));
  atomic_fetch_add_explicit(&e->a_synth_epoch, 1u, memory_order_release);
}

/* ---- control thread ---- */

static int configured(le_engine* e) {
  return atomic_load_explicit(&e->a_configured, memory_order_acquire) != 0;
}

/* Stores a slot's three parameters stamped with `patch`, then bumps its
 * revision (release); see the header comment for the consistency it gives. */
static void publish_params(le_engine* e, int32_t slot, int32_t patch,
                           const float* v) {
  for (int p = 0; p < 3; ++p) store_f32(&e->a_inst_param_bits[slot][p], v[p]);
  store_i32(&e->a_inst_param_patch[slot], patch);
  atomic_fetch_add_explicit(&e->a_inst_param_rev[slot], 1u, memory_order_release);
}

static float clamp100(float v) { return v < 0.0f ? 0.0f : v > 100.0f ? 100.0f : v; }

static int push_event(le_engine* e, le_inst_ring* r, uint32_t origin,
                      uint8_t kind, uint8_t slot, uint8_t note,
                      uint8_t velocity) {
  const le_inst_event ev = {e->inst_seq + 1u, origin, kind, slot, note, velocity};
  if (!ring_push(r, &ev)) return 0;
  e->inst_seq++;
  atomic_store_explicit(&e->a_inst_seq_pub, e->inst_seq, memory_order_release);
  return 1;
}

LE_EXPORT int32_t le_engine_set_instrument(le_engine* engine, int32_t slot,
                                           int32_t patch, const float* params) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS || patch < -1) {
    return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  float v[3] = {0.0f, 0.0f, 0.0f};
  if (patch >= 0) {
    const le_synth_patch* p = le_synth_patch_at(patch);
    if (p == NULL) return LE_ERR_UNKNOWN_PATCH;
    for (int i = 0; i < 3; ++i) {
      if (params != NULL && params[i] != params[i]) return LE_ERR_INVALID;
      v[i] = params != NULL ? clamp100(params[i]) : p->defaults[i];
    }
  }
  /* The values first, stamped for the new patch (the callback ignores them
   * until it plays that patch), then the ordered patch event. */
  float old[3];
  for (int i = 0; i < 3; ++i) old[i] = load_f32(&engine->a_inst_param_bits[slot][i]);
  const int32_t old_patch = load_i32(&engine->a_inst_param_patch[slot]);
  publish_params(engine, slot, patch, v);
  if (!push_event(engine, &engine->inst_ring, 0u, LE_INST_SET_PATCH,
                  (uint8_t)slot,
                  patch < 0 ? (uint8_t)LE_INST_NO_PATCH : (uint8_t)patch, 0)) {
    publish_params(engine, slot, old_patch, old);
    return LE_ERR_CAPACITY;
  }
  engine->inst_patch_requested[slot] = patch;
  return LE_OK;
}

LE_EXPORT int32_t le_engine_set_instrument_param(le_engine* engine, int32_t slot,
                                                 int32_t param, float value) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS || param < 0 ||
      param > 2 || value != value) {
    return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  const int32_t patch = engine->inst_patch_requested[slot];
  if (patch < 0) return LE_ERR_NO_INSTRUMENT;
  float v[3];
  for (int p = 0; p < 3; ++p) v[p] = load_f32(&engine->a_inst_param_bits[slot][p]);
  v[param] = clamp100(value);
  publish_params(engine, slot, patch, v);
  return LE_OK;
}

LE_EXPORT int32_t le_engine_set_voice_limit(le_engine* engine, int32_t limit) {
  if (engine == NULL || limit < 1 || limit > LE_SYNTH_MAX_VOICES) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_SET_VOICE_LIMIT, limit, 0.0f);
}

LE_EXPORT int32_t le_engine_reset_instrument(le_engine* engine, int32_t slot) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_INSTRUMENT_RESET, slot, 0.0f);
}

LE_EXPORT int32_t le_engine_instrument_note_on(le_engine* engine, int32_t slot,
                                               uint32_t origin, int32_t note,
                                               int32_t velocity) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS || note < 0 ||
      note > 127 || velocity < 1 || velocity > 127) {
    return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  if (engine->inst_patch_requested[slot] < 0) return LE_ERR_NO_INSTRUMENT;
  /* keep room for one patch change per slot */
  if (ring_free(&engine->inst_ring) <= LE_MAX_INSTRUMENTS ||
      !push_event(engine, &engine->inst_ring, origin | LE_INST_CONTROL_ORIGIN,
                  LE_INST_NOTE_ON, (uint8_t)slot, (uint8_t)note,
                  (uint8_t)velocity)) {
    atomic_fetch_add_explicit(&engine->a_inst_events_refused, 1u,
                              memory_order_relaxed);
    return LE_ERR_CAPACITY;
  }
  return LE_OK;
}

LE_EXPORT int32_t le_engine_instrument_chord_on(le_engine* engine,
                                                int32_t slot, uint32_t origin,
                                                const int32_t* notes,
                                                int32_t count,
                                                int32_t velocity) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS ||
      notes == NULL || count < 1 || count > LE_INST_CHORD_NOTES ||
      velocity < 1 || velocity > 127) {
    return LE_ERR_INVALID;
  }
  for (int32_t n = 0; n < count; ++n) {
    if (notes[n] < 0 || notes[n] > 127) return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  if (engine->inst_patch_requested[slot] < 0) return LE_ERR_NO_INSTRUMENT;
  /* all or nothing, keeping room for one patch change per slot */
  if (ring_free(&engine->inst_ring) <= (uint32_t)(LE_MAX_INSTRUMENTS + count - 1)) {
    atomic_fetch_add_explicit(&engine->a_inst_events_refused, 1u,
                              memory_order_relaxed);
    return LE_ERR_CAPACITY;
  }
  for (int32_t n = 0; n < count; ++n) {
    /* the first note is an ordinary strike (it replaces the origin's held
     * voice), the others join it */
    push_event(engine, &engine->inst_ring, origin | LE_INST_CONTROL_ORIGIN,
               n == 0 ? LE_INST_NOTE_ON : LE_INST_CHORD_NOTE_ON, (uint8_t)slot,
               (uint8_t)notes[n], (uint8_t)velocity);
  }
  return LE_OK;
}

LE_EXPORT int32_t le_engine_instrument_note_off(le_engine* engine,
                                                uint32_t origin) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  if (!push_event(engine, &engine->inst_release_ring,
                  origin | LE_INST_CONTROL_ORIGIN, LE_INST_NOTE_OFF, 0, 0, 0)) {
    return LE_ERR_CAPACITY;
  }
  return LE_OK;
}

LE_EXPORT int32_t le_engine_instrument_sustain(le_engine* engine, int32_t slot,
                                               uint32_t origin, int32_t on) {
  if (engine == NULL || slot < 0 || slot >= LE_MAX_INSTRUMENTS) {
    return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  const uint32_t o = origin | LE_INST_CONTROL_ORIGIN;
  if (!on) {
    return push_event(engine, &engine->inst_release_ring, o,
                      LE_INST_SUSTAIN_OFF, (uint8_t)slot, 0, 0)
               ? LE_OK
               : LE_ERR_CAPACITY;
  }
  if (engine->inst_patch_requested[slot] < 0) return LE_ERR_NO_INSTRUMENT;
  if (ring_free(&engine->inst_ring) <= LE_MAX_INSTRUMENTS ||
      !push_event(engine, &engine->inst_ring, o, LE_INST_SUSTAIN_ON,
                  (uint8_t)slot, 0, 0)) {
    return LE_ERR_CAPACITY;
  }
  return LE_OK;
}

static int routes_valid(const le_inst_routes* r) {
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    const le_inst_route* q = &r->inst[k];
    if ((q->midi_enabled != 0 && q->midi_enabled != 1) || q->port < 0 ||
        q->port >= LE_MAX_MIDI_PORTS || q->channel < 0 || q->channel > 16 ||
        q->low < 0 || q->high > 127 || q->low > q->high ||
        q->remap_count < 0 || q->remap_count > LE_INST_MAX_REMAPS) {
      return 0;
    }
    for (int m = 0; m < q->remap_count; ++m) {
      const le_inst_remap* x = &q->remaps[m];
      if (x->port < 0 || x->port >= LE_MAX_MIDI_PORTS || x->channel < 0 ||
          x->channel > 16 ||
          (x->kind != LE_INST_REMAP_NOTE && x->kind != LE_INST_REMAP_CC) ||
          x->number < 0 || x->number > 127 || x->count < 1 ||
          x->count > LE_INST_REMAP_NOTES) {
        return 0;
      }
      for (int n = 0; n < x->count; ++n) {
        if (x->notes[n] < 0 || x->notes[n] > 127) return 0;
      }
    }
  }
  return 1;
}

LE_EXPORT int32_t le_engine_set_instrument_routes(le_engine* engine,
                                                  const le_inst_routes* routes) {
  if (engine == NULL || routes == NULL || !routes_valid(routes)) {
    return LE_ERR_INVALID;
  }
  if (!configured(engine)) return LE_ERR_NOT_RUNNING;
  const int running = load_i32(&engine->a_running) != 0;
  const int32_t live = load_i32(&engine->a_inst_routes_live);
  /* The callback may still read the other table until it has acknowledged
   * the current one. The acquire pairs with the callback's release of the
   * acknowledgement, so its last reads of the other table happen before the
   * copy below overwrites it. */
  if (running && atomic_load_explicit(&engine->a_inst_routes_seen,
                                      memory_order_acquire) != live) {
    return LE_ERR_NOT_READY;
  }
  const int32_t next = 1 - live;
  engine->inst_routes[next] = *routes;
  uint16_t(*index)[2][128] = engine->inst_remap_index[next];
  uint8_t(*insts)[2][128] = engine->inst_remap_insts[next];
  uint8_t(*first)[LE_MAX_MIDI_PORTS][2][128] = engine->inst_remap_first[next];
  memset(index, 0, sizeof(engine->inst_remap_index[next]));
  memset(insts, 0, sizeof(engine->inst_remap_insts[next]));
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    for (int m = routes->inst[k].remap_count - 1; m >= 0; --m) {
      const le_inst_remap* x = &routes->inst[k].remaps[m];
      index[x->port][x->kind][x->number] |=
          x->channel == 0 ? 0xFFFFu : (uint16_t)(1u << (x->channel - 1));
      insts[x->port][x->kind][x->number] |= (uint8_t)(1u << k);
      first[k][x->port][x->kind][x->number] = (uint8_t)m; /* lowest wins */
    }
  }
  /* Release: the callback that loads `next` sees the whole table. */
  atomic_store_explicit(&engine->a_inst_routes_live, next,
                        memory_order_release);
  /* Stopped: no callback reads either table, so the switch is immediate. */
  if (!running) store_i32(&engine->a_inst_routes_seen, next);
  return LE_OK;
}

/* ---- audio thread ---- */

void le_instruments_apply_command(le_engine* e, const le_command* cmd) {
  le_synth* s = (le_synth*)e->synth;
  if (s == NULL) return;
  switch (cmd->code) {
    case LE_CMD_SET_VOICE_LIMIT:
      if (le_synth_set_voice_limit(s, cmd->arg_i) == 0) {
        store_i32(&e->a_voice_limit, cmd->arg_i);
      }
      break;
    case LE_CMD_INSTRUMENT_RESET:
      if (cmd->arg_i >= 0 && cmd->arg_i < LE_MAX_INSTRUMENTS) {
        le_synth_cut(s, cmd->arg_i);
      }
      break;
    default:
      break;
  }
}

/* ---- MIDI routing (audio thread, from le_midi_ports_drain) ---- */

/* An instrument whose MIDI `next` turns off or moves to another port or
 * channel: the old port's notes and sustain on it end as at a Note Off, and
 * the expression MIDI set on it returns to neutral, as the reference's
 * silenceController does. Range and remap edits leave held notes to their
 * own release. `prev` is intact here: the control thread cannot overwrite
 * it before this block acknowledges `next`. */
static void retire_moved_routes(le_engine* e, const le_inst_routes* prev,
                                const le_inst_routes* next) {
  le_synth* s = (le_synth*)e->synth;
  if (s == NULL) return;
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    const le_inst_route* was = &prev->inst[k];
    const le_inst_route* now = &next->inst[k];
    if (!was->midi_enabled ||
        (now->midi_enabled && now->port == was->port &&
         now->channel == was->channel)) {
      continue;
    }
    le_synth_release_matching(s, k, LE_INST_PORT_MASK, (uint32_t)was->port << 24);
    for (int x = 0; x < 3; ++x) {
      if (e->inst_expr_port[k][x] >= 0) {
        le_synth_expression(s, k, x, 0.0f);
        e->inst_expr_port[k][x] = -1;
      }
    }
  }
}

void le_instruments_midi_begin(le_engine* e) {
  const int32_t live =
      atomic_load_explicit(&e->a_inst_routes_live, memory_order_acquire);
  const le_inst_routes* prev = e->inst_routes_active;
  if (prev != NULL && prev != &e->inst_routes[live]) {
    retire_moved_routes(e, prev, &e->inst_routes[live]);
  }
  e->inst_routes_active = &e->inst_routes[live];
  e->inst_remap_active = e->inst_remap_index[live];
  e->inst_remap_insts_active = e->inst_remap_insts[live];
  e->inst_remap_first_active = e->inst_remap_first[live];
  /* Release: every read of the previous table (earlier blocks) happens
   * before the control thread may overwrite it. */
  atomic_store_explicit(&e->a_inst_routes_seen, live, memory_order_release);
}

void le_instruments_midi_gone(le_engine* e, int32_t port) {
  le_synth* s = (le_synth*)e->synth;
  if (s == NULL) return;
  le_synth_release_matching(s, -1, LE_INST_PORT_MASK, (uint32_t)port << 24);
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    for (int x = 0; x < 3; ++x) {
      if (e->inst_expr_port[k][x] == port) {
        le_synth_expression(s, k, x, 0.0f);
        e->inst_expr_port[k][x] = -1;
      }
    }
  }
}

static int channel_matches(int32_t want, int32_t ch) {
  return want == 0 || want == ch + 1;
}

static const le_inst_remap* find_remap(const le_inst_route* q, int first,
                                       int32_t port, int32_t ch, int32_t kind,
                                       int32_t number) {
  for (int m = first; m < q->remap_count; ++m) {
    const le_inst_remap* x = &q->remaps[m];
    if (x->port == port && channel_matches(x->channel, ch) && x->kind == kind &&
        x->number == number) {
      return x;
    }
  }
  return NULL;
}

static void play_remap(le_synth* s, int32_t inst, const le_inst_remap* x,
                       uint32_t origin, int32_t velocity) {
  for (int n = 0; n < x->count; ++n) {
    if (n == 0) {
      le_synth_note_on(s, inst, origin, x->notes[n], velocity);
    } else {
      le_synth_note_on_chord(s, inst, origin, x->notes[n], velocity);
    }
  }
}

static void set_expression(le_engine* e, le_synth* s, int32_t inst,
                           int32_t port, int32_t kind, float value) {
  le_synth_expression(s, inst, kind, value);
  e->inst_expr_port[inst][kind] = (int8_t)port;
}

void le_instruments_midi_event(le_engine* e, int32_t port,
                               const le_midi_port_event* ev) {
  le_synth* s = (le_synth*)e->synth;
  if (s == NULL || e->inst_routes_active == NULL) return;
  const int32_t type = ev->status & 0xF0;
  const int32_t ch = ev->status & 0x0F;
  const int32_t d1 = ev->data1 & 0x7F, d2 = ev->data2 & 0x7F;
  const int note_on = type == 0x90 && d2 > 0;
  const int note_off = type == 0x80 || (type == 0x90 && d2 == 0);
  const int cc = type == 0xB0;
  const int32_t kind = cc ? LE_INST_REMAP_CC : LE_INST_REMAP_NOTE;
  const uint32_t origin = midi_origin(port, ch, kind, d1);
  /* Releases first, by origin, on every instrument, whatever the routes say
   * now: a route edit can never strand a held note (review M1). */
  if (note_off) {
    le_synth_note_off(s, origin);
    return;
  }
  if (cc && d2 < 64) {
    le_synth_note_off(s, origin);    /* a remapped switch let go */
    le_synth_sustain_off(s, origin); /* a CC64 let go */
  }
  if (!note_on && !cc && type != 0xE0 && type != 0xD0) return;
  /* which instruments' remaps can match this message (none: no scan) */
  const uint32_t remapped =
      (note_on || cc) && (e->inst_remap_active[port][kind][d1] >> ch) & 1u
          ? e->inst_remap_insts_active[port][kind][d1]
          : 0u;
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    const le_inst_route* q = &e->inst_routes_active->inst[k];
    if (!q->midi_enabled || s->inst[k].patch < 0) continue;
    if ((remapped >> k) & 1u) {
      const le_inst_remap* x = find_remap(
          q, e->inst_remap_first_active[k][port][kind][d1], port, ch, kind, d1);
      if (x != NULL) {
        /* a switch-like controller already held on this instrument does not
         * strike again (review L1: only here, never for the others) */
        const int repeat = cc && le_synth_held(s, k, origin);
        if ((note_on || d2 >= 64) && !repeat) {
          play_remap(s, k, x, origin, note_on ? d2 : 100);
        }
        continue; /* a remap replaces the ordinary handling (no CC64 sustain) */
      }
    }
    if (q->port != port || !channel_matches(q->channel, ch)) continue;
    if (note_on) {
      if (d1 >= q->low && d1 <= q->high) le_synth_note_on(s, k, origin, d1, d2);
    } else if (cc) {
      if (d1 == 64 && d2 >= 64) {
        if (le_synth_sustain(s, k, origin, 1) != 0) {
          atomic_store_explicit(&e->a_inst_sustain_refused, s->sustain_refused,
                                memory_order_relaxed);
        }
      } else if (d1 == 1) {
        set_expression(e, s, k, port, LE_SYNTH_MOD, (float)d2 / 127.0f);
      }
    } else if (type == 0xE0) {
      const int32_t v = d1 | (d2 << 7);
      set_expression(e, s, k, port, LE_SYNTH_BEND, (float)(v - 8192) / 8192.0f);
    } else {
      set_expression(e, s, k, port, LE_SYNTH_PRESSURE, (float)d1 / 127.0f);
    }
  }
}

void le_instruments_cut(le_engine* e) {
  if (e->synth != NULL) le_synth_cut((le_synth*)e->synth, -1);
}

/* Applies slot k's stamped values when they belong to the patch it plays. */
static void apply_slot_params(le_engine* e, le_synth* s, int k) {
  e->inst_param_seen[k] =
      atomic_load_explicit(&e->a_inst_param_rev[k], memory_order_acquire);
  if (s->inst[k].patch < 0 || load_i32(&e->a_inst_param_patch[k]) != s->inst[k].patch) {
    return;
  }
  for (int p = 0; p < 3; ++p) {
    le_synth_set_param(s, k, p, load_f32(&e->a_inst_param_bits[k][p]));
  }
}

static void apply_params(le_engine* e, le_synth* s) {
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    if (atomic_load_explicit(&e->a_inst_param_rev[k], memory_order_acquire) !=
        e->inst_param_seen[k]) {
      apply_slot_params(e, s, k);
    }
  }
}

static void apply_event(le_engine* e, le_synth* s, const le_inst_event* ev) {
  switch (ev->kind) {
    case LE_INST_NOTE_ON:
      le_synth_note_on(s, ev->slot, ev->origin, ev->note, ev->velocity);
      break;
    case LE_INST_CHORD_NOTE_ON:
      le_synth_note_on_chord(s, ev->slot, ev->origin, ev->note, ev->velocity);
      break;
    case LE_INST_NOTE_OFF:
      le_synth_note_off(s, ev->origin);
      break;
    case LE_INST_SUSTAIN_ON:
      if (le_synth_sustain(s, ev->slot, ev->origin, 1) != 0) {
        atomic_store_explicit(&e->a_inst_sustain_refused, s->sustain_refused,
                              memory_order_relaxed);
      }
      break;
    case LE_INST_SUSTAIN_OFF:
      le_synth_sustain(s, ev->slot, ev->origin, 0);
      break;
    case LE_INST_SET_PATCH: {
      if (ev->slot >= LE_MAX_INSTRUMENTS) break;
      const int32_t patch = ev->note == LE_INST_NO_PATCH ? -1 : (int32_t)ev->note;
      if (le_synth_set_instrument(s, ev->slot, patch) != 0) break;
      store_i32(&e->a_inst_patch[ev->slot], patch);
      apply_slot_params(e, s, ev->slot);
      break;
    }
    default:
      break;
  }
}

/* Both rings in posting order up to the published high-water mark, at most
 * LE_INST_EVENTS_PER_BLOCK events. An event above the mark (pushed after
 * the mark was read) waits for the next block, so the other ring's earlier
 * events can never be overtaken by it. */
static void drain_events(le_engine* e, le_synth* s) {
  const uint32_t mark =
      atomic_load_explicit(&e->a_inst_seq_pub, memory_order_acquire);
  for (int n = 0; n < LE_INST_EVENTS_PER_BLOCK; ++n) {
    const le_inst_event* on = ring_peek(&e->inst_ring);
    const le_inst_event* off = ring_peek(&e->inst_release_ring);
    if (on != NULL && (int32_t)(on->seq - mark) > 0) on = NULL;
    if (off != NULL && (int32_t)(off->seq - mark) > 0) off = NULL;
    if (on == NULL && off == NULL) return;
    if (off == NULL || (on != NULL && (int32_t)(on->seq - off->seq) < 0)) {
      apply_event(e, s, on);
      ring_pop(&e->inst_ring);
    } else {
      apply_event(e, s, off);
      ring_pop(&e->inst_release_ring);
    }
  }
}

void le_instruments_block(le_engine* e, uint32_t frames) {
  le_instruments_apply(e);
  le_instruments_render(e, frames);
}

void le_instruments_apply(le_engine* e) {
  le_synth* s = (le_synth*)e->synth;
  if (s == NULL) return;
  apply_params(e, s);
  drain_events(e, s);
}

void le_instruments_render(le_engine* e, uint32_t frames) {
  le_synth* s = (le_synth*)e->synth;
  /* The buses hold this block's audio (silence included) unless the block
   * is larger than the scratch; instrument sources read silence then. */
  e->inst_bus_live = s != NULL && frames <= LE_COND_SCRATCH_FRAMES;
  if (s == NULL) return;
  if (frames == 0) return;
  int any = le_synth_fading(s) > 0;
  for (int k = 0; k < LE_MAX_INSTRUMENTS && !any; ++k) {
    any = s->inst[k].patch >= 0 && le_synth_active(s, k) > 0;
  }
  if (!any) {
    /* Nothing sounds: no render and no cost; a bus that last carried audio
     * is cleared once. */
    for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
      store_i32(&e->a_inst_voices[k], 0);
      if (load_f32(&e->a_inst_peak_bits[k]) != 0.0f) {
        memset(e->inst_bus + (int64_t)k * LE_COND_SCRATCH_FRAMES, 0,
               sizeof(float) * (size_t)LE_COND_SCRATCH_FRAMES);
        store_f32(&e->a_inst_peak_bits[k], 0.0f);
      }
    }
    return;
  }
  if (frames > LE_COND_SCRATCH_FRAMES) {
    /* Larger than the bus scratch (only synthetic test blocks): counted, no
     * instrument audio and silent buses, never an allocation on this
     * thread. */
    atomic_fetch_add_explicit(&e->a_inst_fallback_blocks, 1u,
                              memory_order_relaxed);
    memset(e->inst_bus, 0,
           sizeof(float) * (size_t)LE_MAX_INSTRUMENTS * LE_COND_SCRATCH_FRAMES);
    for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
      store_f32(&e->a_inst_peak_bits[k], 0.0f);
    }
    return;
  }
  float* bus[LE_MAX_INSTRUMENTS];
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    bus[k] = e->inst_bus + (int64_t)k * LE_COND_SCRATCH_FRAMES;
  }
  le_synth_render(s, bus, LE_MAX_INSTRUMENTS, (int32_t)frames);
  for (int k = 0; k < LE_MAX_INSTRUMENTS; ++k) {
    float peak = 0.0f;
    for (uint32_t f = 0; f < frames; ++f) {
      const float a = fabsf(bus[k][f]);
      if (a > peak) peak = a;
    }
    store_f32(&e->a_inst_peak_bits[k], peak);
    store_i32(&e->a_inst_voices[k], le_synth_active(s, k));
  }
  atomic_store_explicit(&e->a_voices_stolen, s->stolen, memory_order_relaxed);
  atomic_store_explicit(&e->a_voices_stolen_hard, s->stolen_hard,
                        memory_order_relaxed);
}
