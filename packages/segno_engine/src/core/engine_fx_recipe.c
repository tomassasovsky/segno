#include "../host/plugin_slot.h"
#include "engine_private.h"
#include "engine_fx.h"
/* Atomic structural recipes. The control owner retains each immutable bundle
 * through the callback's final buffer access. A deferred arm retains it until
 * its image publishes or the callback reports that the arm was cancelled. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "engine_core.h"
#include "engine_internal.h"

typedef struct le_recipe_target {
  le_fx_state* fx;
  _Atomic int32_t *count, *pre, *enabled, *type, *slot_enabled, *in, *out;
  _Atomic uint32_t (*param)[LE_FX_PARAMS];
  _Atomic uint32_t *pan, *gl, *gr, *level;
  int32_t *pushed_count, *pushed_type;
  _Atomic uint32_t* revision;
} le_recipe_target;

struct le_prepared_fx {
  struct le_prepared_fx* next;
  uint64_t ticket;
  uint32_t image_revision, revision;
  int owner, channel, lane, count;
  uint32_t lane_mask;
  le_fx_recipe recipes[LE_MAX_LANES];
  le_plugin_slot* removed[LE_MAX_LANES * LE_FX_MAX];
  le_plugin_slot* added[LE_MAX_LANES * LE_FX_MAX];
  int removed_count, added_count;
  _Atomic int applied;
};

#define LE_RECIPE_TARGET(v) (le_recipe_target){ &(v)->fx, &(v)->a_fx_count, \
  NULL, &(v)->a_fx_chain_enabled, (v)->a_fx_type, (v)->a_fx_enabled, \
  (v)->a_fx_chan_in, (v)->a_fx_chan_out, (v)->a_fx_param, \
  (v)->a_fx_chan_pan_bits, (v)->a_fx_chan_gl_bits, (v)->a_fx_chan_gr_bits, \
  (v)->a_fx_chan_level_bits, &(v)->fx_count_pushed, (v)->fx_type_pushed, &(v)->a_fx_recipe_revision }

static int recipe_target(le_engine* e, int owner, int ch, int lane,
                          le_recipe_target* target) {
  if (!e) return 0;
  if (owner == LE_FX_OWNER_LANE) {
    if (ch < 0 || ch >= e->track_count || lane < 0 || lane >= LE_MAX_LANES) return 0;
    le_lane* v = &e->tracks[ch].lanes[lane];
    *target = LE_RECIPE_TARGET(v); target->pre = &v->a_fx_pre_count;
  } else if (owner == LE_FX_OWNER_MONITOR) {
    if (ch < 0 || ch >= LE_MAX_MONITORED_INPUTS) return 0;
    *target = LE_RECIPE_TARGET(&e->monitors[ch]);
  } else {
    if (owner != LE_FX_OWNER_TRACK && owner != LE_FX_OWNER_ALL_TRACKS && owner != LE_FX_OWNER_OUTPUT) return 0;
    if (owner == LE_FX_OWNER_OUTPUT && (ch < 0 || ch >= LE_MAX_OUTPUT_BUSES)) return 0;
    if (owner == LE_FX_OWNER_TRACK && (ch < 0 || ch >= e->track_count)) return 0;
    le_fx_bus* v = owner == LE_FX_OWNER_TRACK ? &e->tracks[ch].bus :
        owner == LE_FX_OWNER_OUTPUT ? &e->outputs[ch].fx : &e->all_tracks;
    *target = LE_RECIPE_TARGET(v); target->pre = &v->a_fx_pre_count;
  }
  return 1;
}
#undef LE_RECIPE_TARGET

static int prepared_index(le_engine* e, le_plugin_slot* slot) {
  if (!slot) return -1;
  for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES * LE_FX_MAX; ++i)
    if (e->prepared_plugins[i] == slot) return i;
  return -1;
}

int32_t le_engine_prepare_plugin(le_engine* e, const char* id,
                                  le_plugin_slot** out) {
  if (!e || !id || !out || !load_i32(&e->a_configured)) return LE_ERR_INVALID;
  *out = NULL;
  int free_index = -1;
  for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES * LE_FX_MAX; ++i)
    if (!e->prepared_plugins[i]) { free_index = i; break; }
  if (free_index < 0) return LE_ERR_INVALID;
  int32_t reason = LE_ERR_DEVICE;
  le_plugin_slot* slot = le_plugin_slot_create(id, e->sample_rate, &reason);
  if (!slot) return reason;
  e->prepared_plugins[free_index] = slot;
  *out = slot;
  return LE_OK;
}

int32_t le_engine_discard_prepared_plugin(le_engine* e, le_plugin_slot* slot) {
  if (!e) return LE_ERR_INVALID;
  const int i = prepared_index(e, slot);
  if (i < 0) return LE_ERR_INVALID;
  e->prepared_plugins[i] = NULL;
  le_plugin_slot_destroy(slot);
  return LE_OK;
}

int32_t le_engine_prepare_plugin_param(le_engine* e, le_plugin_slot* slot,
                                        uint32_t id, double value) {
  if (!e || prepared_index(e, slot) < 0 || !isfinite(value)) return LE_ERR_INVALID;
  return le_plugin_slot_prepare_param(slot, id, value);
}

int le_fx_edit_pending(le_engine* e, int owner, int ch, int lane) {
  if (!e || lane < 0 || lane >= LE_MAX_LANES) return 0;
  le_fx_recipe_collect(e, 0);
  for (struct le_prepared_fx* p = e->pending_fx_edits; p; p = p->next) {
    if (p->owner != owner || p->channel != ch) continue;
    if (owner != LE_FX_OWNER_LANE || (p->lane_mask & (1u << lane))) return 1;
  }
  return 0;
}

static int pointer_in_recipe(const le_fx_recipe* recipe, le_plugin_slot* p) {
  for (int s = 0; s < recipe->count; ++s) if (recipe->plugin[s] == p) return 1;
  return 0;
}

static int prepare_recipe(le_engine* e, struct le_prepared_fx* edit,
                            int lane, const le_fx_recipe* r) {
  le_recipe_target t;
  if (!recipe_target(e, edit->owner, edit->channel, lane, &t) || !r ||
      r->count < 0 || r->count > LE_FX_MAX || r->pre_count < 0 ||
      r->pre_count > r->count || (r->enabled != 0 && r->enabled != 1) ||
      ((edit->owner == LE_FX_OWNER_MONITOR || edit->owner == LE_FX_OWNER_ALL_TRACKS || edit->owner == LE_FX_OWNER_OUTPUT)
       && r->pre_count)) return 0;
  if (le_fx_edit_pending(e, edit->owner, edit->channel, lane)) return 0;
  for (int s = 0; s < r->count; ++s) {
    if (r->type[s] < LE_FX_NONE || r->type[s] > LE_FX_PLUGIN ||
        (r->slot_enabled[s] != 0 && r->slot_enabled[s] != 1) ||
        r->input_mode[s] < 0 || r->input_mode[s] > 3 ||
        r->output_mode[s] < 0 || r->output_mode[s] > 1 ||
        !isfinite(r->placement[s]) || r->placement[s] < -1 || r->placement[s] > 1 ||
        !isfinite(r->level[s]) || r->level[s] < 0 || r->level[s] > LE_MAX_GAIN) return 0;
    for (int k = 0; k < LE_FX_PARAMS; ++k)
      if (!isfinite(r->params[s][k]) || r->params[s][k] < 0 || r->params[s][k] > 1) return 0;
    le_plugin_slot* slot = r->plugin[s];
    if ((r->type[s] == LE_FX_PLUGIN) != (slot != NULL)) return 0;
    if (slot) {
      if (edit->owner != LE_FX_OWNER_LANE && edit->owner != LE_FX_OWNER_MONITOR) return 0;
      for (int prev = 0; prev < s; ++prev) if (r->plugin[prev] == slot) return 0;
      int retained = 0;
      for (int k = 0; k < LE_FX_MAX; ++k)
        if (atomic_load_explicit(&t.fx->plugin[k], memory_order_acquire) == slot) retained = 1;
      if (!retained) {
        if (prepared_index(e, slot) < 0) return 0;
        for (int k = 0; k < edit->added_count; ++k) if (edit->added[k] == slot) return 0;
        edit->added[edit->added_count++] = slot;
      }
    }
  }
  /* Allocation only fills absent buffers for types not yet dispatched. It
   * never resets, reallocates or frees a buffer the old chain can read. */
  const int instances = edit->owner == LE_FX_OWNER_ALL_TRACKS
      ? (e->out_channels + 1) / 2 : 1;
  for (int bus = 0; bus < instances; ++bus) {
    le_fx_state* fx = edit->owner == LE_FX_OWNER_ALL_TRACKS ? &e->all_tracks_fx[bus] : t.fx;
    for (int s = 0; s < r->count; ++s)
      if (le_fx_prepare(fx, s, r->type[s], e->fx_delay_frames) != LE_OK) return 0;
  }
  for (int s = 0; s < LE_FX_MAX; ++s) {
    le_plugin_slot* old = atomic_load_explicit(&t.fx->plugin[s], memory_order_acquire);
    if (old && !pointer_in_recipe(r, old)) edit->removed[edit->removed_count++] = old;
  }
  edit->recipes[lane] = *r;
  return 1;
}

struct le_prepared_fx* le_fx_prepare_capture(le_engine* e, int ch,
                                            const le_record_image* image) {
  if (!image->fx_lane_mask) return NULL;
  if (!image->lane_fx || (image->fx_lane_mask >> LE_MAX_LANES)) return NULL;
  struct le_prepared_fx* p = calloc(1, sizeof(*p));
  if (!p) return NULL;
  p->owner = LE_FX_OWNER_LANE; p->channel = ch; p->lane_mask = image->fx_lane_mask;
  for (int lane = 0; lane < LE_MAX_LANES; ++lane)
    if ((p->lane_mask & (1u << lane)) && !prepare_recipe(e, p, lane, &image->lane_fx[lane])) {
      free(p); return NULL;
    }
  for (int i = 0; i < p->added_count; ++i) le_plugin_slot_set_ready(p->added[i], 1);
  return p;
}

struct le_prepared_fx* le_fx_prepare_chains(le_engine* e, int owner,
                                            int channel, int count,
                                            const le_fx_recipe* recipes,
                                            int recipe_count) {
  if (owner != LE_FX_OWNER_LANE && owner != LE_FX_OWNER_TRACK) return NULL;
  if (owner == LE_FX_OWNER_TRACK) count = 1;
  if (count < 1 || count > LE_MAX_LANES) return NULL;
  struct le_prepared_fx* p = calloc(1, sizeof(*p));
  if (!p) return NULL;
  p->owner = owner; p->channel = channel;
  le_fx_recipe empty;
  memset(&empty, 0, sizeof(empty));
  empty.enabled = 1;
  for (int lane = 0; lane < count; ++lane) {
    const le_fx_recipe* r =
        recipes != NULL && lane < recipe_count ? &recipes[lane] : &empty;
    p->lane_mask |= 1u << lane;
    if (!prepare_recipe(e, p, lane, r)) {
      free(p);
      return NULL;
    }
  }
  for (int i = 0; i < p->added_count; ++i) le_plugin_slot_set_ready(p->added[i], 1);
  return p;
}

void le_fx_recipe_abandon(struct le_prepared_fx* p) {
  if (!p) return;
  for (int i = 0; i < p->added_count; ++i) le_plugin_slot_set_ready(p->added[i], 0);
  free(p);
}

void le_fx_recipe_admitted(le_engine* e, struct le_prepared_fx* p, uint32_t image) {
  if (!p) return;
  p->ticket = e->commands_posted; p->image_revision = image;
  for (int i = 0; i < p->added_count; ++i) {
    const int index = prepared_index(e, p->added[i]);
    if (index >= 0) e->prepared_plugins[index] = NULL;
    le_plugin_slot_set_ready(p->added[i], 1);
  }
  p->next = e->pending_fx_edits; e->pending_fx_edits = p;
}

int32_t le_engine_set_fx_recipe(le_engine* e, int owner, int ch, int lane,
                                 uint32_t revision, const le_fx_recipe* r) {
  if (!e || !load_i32(&e->a_configured)) return LE_ERR_NOT_RUNNING;
  if (!revision || lane < 0 || lane >= LE_MAX_LANES ||
      (owner != LE_FX_OWNER_LANE && lane != 0) ||
      (owner == LE_FX_OWNER_ALL_TRACKS && ch != 0)) return LE_ERR_INVALID;
  struct le_prepared_fx* p = calloc(1, sizeof(*p));
  if (!p) return LE_ERR_INVALID;
  p->owner = owner; p->channel = ch; p->lane = lane; p->lane_mask = 1u << lane;
  p->revision = revision;
  if (!prepare_recipe(e, p, lane, r)) { free(p); return LE_ERR_INVALID; }
  /* Ready is atomic; no callback can see a detached pointer before the ring
   * release. Ownership transfers only if that release succeeds. */
  for (int i = 0; i < p->added_count; ++i) le_plugin_slot_set_ready(p->added[i], 1);
  const int rc = le_push_cmd(e, (le_command){.code = LE_CMD_SET_FX_RECIPE, .recipe = p});
  if (rc != LE_OK) {
    for (int i = 0; i < p->added_count; ++i) le_plugin_slot_set_ready(p->added[i], 0);
    free(p); return rc;
  }
  le_fx_recipe_admitted(e, p, 0);
  return LE_OK;
}

void le_fx_recipe_apply(le_engine* e, struct le_prepared_fx* p, uint64_t frame) {
  if (!p) return;
  for (int lane = 0; lane < LE_MAX_LANES; ++lane) {
    if (!(p->lane_mask & (1u << lane))) continue;
    le_recipe_target t;
    if (!recipe_target(e, p->owner, p->channel, lane, &t)) return;
    const le_fx_recipe* r = &p->recipes[lane];
    for (int s = 0; s < LE_FX_MAX; ++s) {
      const int active = s < r->count;
      const int ty = active ? r->type[s] : LE_FX_NONE;
      atomic_store_explicit(&t.fx->plugin[s], active ? r->plugin[s] : NULL, memory_order_release);
      store_i32(&t.type[s], ty);
      if (!active) continue;
      for (int k = 0; k < LE_FX_PARAMS; ++k) store_f32(&t.param[s][k], r->params[s][k]);
      store_i32(&t.slot_enabled[s], r->slot_enabled[s]);
      store_i32(&t.in[s], r->input_mode[s]); store_i32(&t.out[s], r->output_mode[s]);
      store_f32(&t.pan[s], r->placement[s]); store_f32(&t.level[s], r->level[s]);
      float gl, gr; le_pan_gains(r->placement[s], &gl, &gr);
      store_f32(&t.gl[s], gl); store_f32(&t.gr[s], gr);
      const int instances = p->owner == LE_FX_OWNER_ALL_TRACKS ? (e->out_channels + 1) / 2 : 1;
      for (int bus = 0; bus < instances; ++bus)
        le_fx_entry_reset(p->owner == LE_FX_OWNER_ALL_TRACKS ? &e->all_tracks_fx[bus] : t.fx, s);
    }
    if (p->owner == LE_FX_OWNER_OUTPUT) {
      for (int s = 0; s < r->count; ++s) {
        le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_OUTPUT_FX,
            .fx = {p->channel, 0, s, r->type[s]}});
        for (int k = 0; k < LE_FX_PARAMS; ++k)
          le_plog_push(e, frame, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_PARAM,
              .fx = {p->channel, 0, LE_PLOG_FX_PARAM_PACK(s, k), (int32_t)f32_to_bits(r->params[s][k])}});
      }
      le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_OUTPUT_FX_COUNT,
          .fxcount = {p->channel, 0, r->count, 0}});
      for (int s = 0; s < r->count; ++s)
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_ENABLED,
            .fx = {p->channel, 0, s, r->slot_enabled[s]}});
      le_plog_push(e, frame, (le_command){.code = LE_PLOG_SET_OUTPUT_FX_CHAIN_ENABLED,
          .arg_i = p->channel, .arg_f = (float)r->enabled});
    }
    store_i32(t.count, r->count); if (t.pre) store_i32(t.pre, r->pre_count);
    store_i32(t.enabled, r->enabled);
    atomic_store_explicit(t.revision, p->revision, memory_order_release);
    if (p->owner == LE_FX_OWNER_LANE) le_lane_fx_gen_bump(&e->tracks[p->channel].lanes[lane]);
  }
  atomic_store_explicit(&p->applied, 1, memory_order_release);
}

void le_fx_recipe_collect(le_engine* e, int quiescent) {
  if (!e) return;
  const uint64_t published = atomic_load_explicit(&e->a_commands_published, memory_order_acquire);
  struct le_prepared_fx** link = &e->pending_fx_edits;
  while (*link) {
    struct le_prepared_fx* p = *link;
    if (!quiescent && p->ticket > published) { link = &p->next; continue; }
    if (!quiescent && p->image_revision && atomic_load_explicit(
          &e->tracks[p->channel].a_pending_image_revision, memory_order_acquire) == p->image_revision) {
      link = &p->next; continue;
    }
    const int applied = atomic_load_explicit(&p->applied, memory_order_acquire);
    le_plugin_slot** garbage = applied ? p->removed : p->added;
    const int n = applied ? p->removed_count : p->added_count;
    for (int i = 0; i < n; ++i) le_plugin_slot_destroy(garbage[i]);
    if (applied) for (int lane = 0; lane < LE_MAX_LANES; ++lane) {
      if (!(p->lane_mask & (1u << lane))) continue;
      le_recipe_target t;
      if (recipe_target(e, p->owner, p->channel, lane, &t)) {
        *t.pushed_count = p->recipes[lane].count;
        memcpy(t.pushed_type, p->recipes[lane].type, sizeof(p->recipes[lane].type));
      }
    }
    *link = p->next; free(p);
  }
  if (quiescent) for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES * LE_FX_MAX; ++i) {
    le_plugin_slot_destroy(e->prepared_plugins[i]); e->prepared_plugins[i] = NULL;
  }
}

uint32_t le_engine_fx_recipe_revision(le_engine* e, int owner, int ch, int lane) {
  le_recipe_target t;
  if (!recipe_target(e, owner, ch, lane, &t)) return 0;
  return atomic_load_explicit(t.revision, memory_order_acquire);
}
