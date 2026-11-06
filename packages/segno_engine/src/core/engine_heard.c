/*
 * engine_heard.c — the heard image (#1713): see le_heard in engine_private.h
 * for the model and engine_heard.h for the contract.
 *
 * Control thread: the planes follow the clean slot's allocation discipline
 * (rt_alloc mappings, the retire queue, the prefaulter, the standbys and
 * zero spares of #900 and #906), so the callback never faults on one and
 * never reads one being freed.
 *
 * Audio thread: the first frame loop logs where it wrote the clean take and
 * which content operations it made; after the block's monitor jobs the
 * post-pass writes each lane's input chain output at the same places and
 * replays the operations, so the image follows the clean take write for
 * write. Nothing here allocates, locks or blocks.
 */
#include "engine_heard.h"

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#include "engine_core.h"
#include "engine_fx.h" /* le_fx_enable_force_bypass, le_fx_rack_reset */
#include "engine_instruments.h"
#include "engine_prefault.h"
#include "rt_alloc.h"

/* ---- either thread ---- */

int le_heard_track_has(const le_engine* e, int32_t ch, int32_t slot) {
  const int32_t n = le_lanes_active(&e->tracks[ch]);
  for (int32_t l = 0; l < n; ++l) {
    if (le_heard_has(e, ch, l, slot)) return 1;
  }
  return 0;
}

int le_heard_lane_plays(const le_engine* e, int32_t ch, int32_t l) {
  const le_heard* h = &e->heard[ch][l];
  if (atomic_load_explicit(&h->a_source, memory_order_relaxed) !=
      LE_HEARD_SOURCE_HEARD) {
    return 0;
  }
  const int32_t live = load_i32(&((le_engine*)e)->tracks[ch].lanes[l].a_live);
  return le_heard_has(e, ch, l, live);
}

/* Counts [d] (+1 or -1) slots of [h] holding an image, and the lanes
 * holding one in the engine (a_heard_lanes) as [h] gains its first or loses
 * its last. Either thread (the callback installs an attach). */
static void le_heard_slots_add(le_engine* e, le_heard* h, int32_t d) {
  const int32_t was =
      atomic_fetch_add_explicit(&h->a_slots, d, memory_order_relaxed);
  if (was == 0 && d > 0) {
    atomic_fetch_add_explicit(&e->a_heard_lanes, 1, memory_order_relaxed);
  } else if (was > 0 && was + d == 0) {
    atomic_fetch_sub_explicit(&e->a_heard_lanes, 1, memory_order_relaxed);
  }
}

/* ---- control thread ---- */

static void le_heard_set(le_engine* e, int32_t ch, int32_t l, int32_t slot,
                         float* pl, float* pr, int32_t cap) {
  le_heard* h = &e->heard[ch][l];
  const int had = le_heard_plane(h, 0, slot) != NULL;
  le_heard_plane_set(h, 0, slot, pl);
  le_heard_plane_set(h, 1, slot, pr);
  h->cap[slot] = pl != NULL ? cap : 0;
  const int has = pl != NULL;
  if (has != had) le_heard_slots_add(e, h, has ? 1 : -1);
}

static void le_heard_drop(le_engine* e, int32_t ch, int32_t l, int32_t slot,
                          int how) {
  le_heard* h = &e->heard[ch][l];
  float* pl = le_heard_plane(h, 0, slot);
  float* pr = le_heard_plane(h, 1, slot);
  if (pl == NULL && pr == NULL) return;
  le_heard_set(e, ch, l, slot, NULL, NULL, 0);
  if (how == LE_HEARD_RETIRE) {
    le_retire_buffer(e, pl);
    le_retire_buffer(e, pr);
  } else {
    le_free_audio_buffer(e, pl);
    le_free_audio_buffer(e, pr);
  }
}

/* Two fresh untouched mappings of [frames] frames, or neither. */
static int le_heard_alloc(int32_t frames, float** pl, float** pr) {
  *pl = (float*)le_rt_alloc((size_t)frames * sizeof(float));
  *pr = *pl != NULL ? (float*)le_rt_alloc((size_t)frames * sizeof(float))
                    : NULL;
  if (*pr == NULL) {
    le_rt_free(*pl);
    *pl = NULL;
    return 0;
  }
  return 1;
}

int le_heard_match(le_engine* e, int32_t ch, int32_t l, int32_t slot, int want,
                   int how) {
  if (slot < 0 || slot >= LE_POOL_SLOTS) return !want;
  const le_lane* ln = &e->tracks[ch].lanes[l];
  const int32_t cap = ln->pool_cap[slot];
  if (!want || ln->pool[slot] == NULL || cap <= 0) {
    le_heard_drop(e, ch, l, slot, how);
    return !want;
  }
  le_heard* h = &e->heard[ch][l];
  if (le_heard_plane(h, 0, slot) != NULL && h->cap[slot] == cap) return 1;
  float* pl;
  float* pr;
  if (!le_heard_alloc(cap, &pl, &pr)) {
    le_heard_drop(e, ch, l, slot, how);
    return 0;
  }
  le_heard_drop(e, ch, l, slot, how);
  le_heard_set(e, ch, l, slot, pl, pr, cap);
  return 1;
}

#ifdef LE_NATIVE_TESTS
int le_test_heard_force = 0;
void (*le_test_heard_check)(le_engine*) = NULL;
#endif

int le_heard_prepare_capture(le_engine* e, int32_t ch, uint32_t mask,
                             int zero) {
  le_track* t = &e->tracks[ch];
#ifdef LE_NATIVE_TESTS
  if (le_test_heard_force) {
    mask = 0xffu;
    for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
      atomic_store_explicit(&e->heard[ch][l].a_source, LE_HEARD_SOURCE_CLEAN,
                            memory_order_relaxed);
      e->heard[ch][l].mix = 0.0f;
    }
  }
#endif
  const int32_t lanes = le_lanes_active(t);
  int ok = 1;
  for (int32_t l = 0; l < lanes; ++l) {
    const int32_t live = load_i32(&t->lanes[l].a_live);
    const le_lane* ln = &t->lanes[l];
    le_heard* h = &e->heard[ch][l];
    const int want = (mask & (1u << l)) != 0 && ln->pool[live] != NULL;
    if (!want) {
      le_heard_drop(e, ch, l, live, LE_HEARD_RETIRE);
      continue;
    }
    const int32_t cap = ln->pool_cap[live];
    if (!zero && le_heard_has(e, ch, l, live) && h->cap[live] == cap) {
      continue; /* a defining capture keeps its planes, as its clean slot */
    }
    le_heard_drop(e, ch, l, live, LE_HEARD_RETIRE);
    if (cap == e->max_loop_frames && h->zero_spare[0] != NULL &&
        h->zero_spare_cap == cap) {
      /* Zeroed by an untouched mapping, as the clean live slot is
       * (le_prepare_new_capture): the planes cost nothing until written. */
      le_heard_set(e, ch, l, live, h->zero_spare[0], h->zero_spare[1], cap);
      h->zero_spare[0] = NULL;
      h->zero_spare[1] = NULL;
      h->zero_spare_cap = 0;
      continue;
    }
    if (!le_heard_match(e, ch, l, live, 1, LE_HEARD_RETIRE)) ok = 0;
  }
  return ok;
}

int le_heard_capture_replaces(le_engine* e, int32_t ch, uint32_t mask,
                              int zero) {
#ifdef LE_NATIVE_TESTS
  if (le_test_heard_force) mask = 0xffu;
#endif
  le_track* t = &e->tracks[ch];
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    const int32_t live = load_i32(&t->lanes[l].a_live);
    if (!le_heard_has(e, ch, l, live) || !(mask & (1u << l))) continue;
    if (zero || e->heard[ch][l].cap[live] != t->lanes[l].pool_cap[live]) {
      return 1;
    }
  }
  return 0;
}

uint32_t le_heard_match_shadow(le_engine* e, int32_t ch, int32_t slot,
                               uint32_t standby_mask) {
  le_track* t = &e->tracks[ch];
  const int32_t lanes = le_lanes_active(t);
  uint32_t from_standby = 0u;
  for (int32_t l = 0; l < lanes; ++l) {
    const int32_t live = load_i32(&t->lanes[l].a_live);
    const le_heard* h = &e->heard[ch][l];
    const int attaching =
        h->attach[0] != NULL && h->attach_slot == live &&
        h->attach_posted !=
            atomic_load_explicit(&((le_heard*)h)->a_attach_done,
                                 memory_order_acquire);
    const int want = le_heard_has(e, ch, l, live) || attaching;
    if (want && (standby_mask & (1u << l)) &&
        le_heard_take_standby(e, ch, l, slot)) {
      from_standby |= 1u << l;
      continue;
    }
    /* A shadow slot is not live and not armed until it is posted, so the
     * callback cannot name it: free at once. */
    (void)le_heard_match(e, ch, l, slot, want, LE_HEARD_FREE);
  }
  return from_standby;
}

void le_heard_shrink(le_engine* e, int32_t ch, int32_t l, int32_t slot,
                     int32_t frames) {
  le_heard* h = &e->heard[ch][l];
  if (frames <= 0 || le_heard_plane(h, 0, slot) == NULL || h->cap[slot] <= frames) {
    return;
  }
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    le_prefault_forget(e, le_heard_plane(h, p, slot));
  }
  h->cap[slot] = frames;
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    le_rt_shrink(le_heard_plane(h, p, slot), (size_t)frames * sizeof(float));
  }
}

static void le_heard_release_standby(le_engine* e, le_heard* h) {
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    le_free_audio_buffer(e, h->standby[p]);
    h->standby[p] = NULL;
    store_i32(&h->a_standby_ready[p], 0);
  }
  h->standby_cap = 0;
}

static void le_heard_release_zero_spare(le_engine* e, le_heard* h) {
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    le_free_audio_buffer(e, h->zero_spare[p]);
    h->zero_spare[p] = NULL;
  }
  h->zero_spare_cap = 0;
}

void le_heard_free_lane(le_engine* e, int32_t ch, int32_t l) {
  le_heard* h = &e->heard[ch][l];
  /* An attach the callback installed but control has not settled yet is in
   * the table now, and freed there: forget the second reference first. */
  if (h->attach[0] != NULL && h->attach_slot >= 0 &&
      le_heard_plane(h, 0, h->attach_slot) == h->attach[0]) {
    h->attach[0] = NULL;
    h->attach[1] = NULL;
  }
  for (int32_t s = 0; s < LE_POOL_SLOTS; ++s) {
    le_heard_drop(e, ch, l, s, LE_HEARD_FREE);
  }
  le_heard_release_standby(e, h);
  le_heard_release_zero_spare(e, h);
  /* An attach not installed cannot be any more: every caller runs with no
   * callback and its command gone (configure re-initialises the ring), or
   * on a lane le_release_removed_lanes leaves alone while one is posted.
   * Its planes are freed here and the counters start over. */
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    le_free_audio_buffer(e, h->attach[p]);
    h->attach[p] = NULL;
  }
  h->attach_slot = -1;
  h->attach_posted = 0;
  atomic_store_explicit(&h->a_attach_done, 0, memory_order_relaxed);
  if (atomic_exchange_explicit(&h->a_slots, 0, memory_order_relaxed) > 0) {
    atomic_fetch_sub_explicit(&e->a_heard_lanes, 1, memory_order_relaxed);
  }
  h->mix = 0.0f; /* no callback runs */
}

int le_heard_take_standby(le_engine* e, int32_t ch, int32_t l, int32_t slot) {
  le_heard* h = &e->heard[ch][l];
  const int32_t cap = e->tracks[ch].lanes[l].pool_cap[slot];
  if (h->standby[0] == NULL || h->standby_cap != cap ||
      !atomic_load_explicit(&h->a_standby_ready[0], memory_order_acquire) ||
      !atomic_load_explicit(&h->a_standby_ready[1], memory_order_acquire)) {
    return 0;
  }
  le_heard_drop(e, ch, l, slot, LE_HEARD_FREE);
  le_heard_set(e, ch, l, slot, h->standby[0], h->standby[1], cap);
  h->standby[0] = NULL;
  h->standby[1] = NULL;
  h->standby_cap = 0;
  store_i32(&h->a_standby_ready[0], 0);
  store_i32(&h->a_standby_ready[1], 0);
  return 1;
}

void le_heard_keep_standby(le_engine* e, int32_t ch, int32_t l, int keep,
                           int32_t want) {
  le_heard* h = &e->heard[ch][l];
  const int32_t live = load_i32(&((le_engine*)e)->tracks[ch].lanes[l].a_live);
  const int need = keep && want > 0 && le_heard_has(e, ch, l, live);
  if (h->standby[0] != NULL && (!need || h->standby_cap != want)) {
    le_heard_release_standby(e, h);
  }
  if (!need) return;
  if (h->standby[0] == NULL) {
    if (!le_heard_alloc(want, &h->standby[0], &h->standby[1])) return;
    h->standby_cap = want;
    store_i32(&h->a_standby_ready[0], 0);
    store_i32(&h->a_standby_ready[1], 0);
  }
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    if (!atomic_load_explicit(&h->a_standby_ready[p], memory_order_acquire)) {
      le_prefault_buffer(e, h->standby[p], h->standby_cap,
                         &h->a_standby_ready[p]);
    }
  }
}

void le_heard_keep_zero_spare(le_engine* e, int32_t ch, int32_t l, int want) {
  le_heard* h = &e->heard[ch][l];
  if (want) {
    /* Only where a take is likely to want an image: the lane's input runs
     * a chain. A spare costs address space, not memory, but two per lane on
     * every empty track is more of it than a dry rig needs. */
    const int32_t input = load_i32(&e->tracks[ch].lanes[l].a_input_channel);
    want = input >= 0 && input < LE_MAX_MONITORED_INPUTS &&
           load_i32(&e->monitors[input].a_fx_count) > 0;
  }
  if (h->zero_spare[0] != NULL &&
      (!want || h->zero_spare_cap != e->max_loop_frames)) {
    le_heard_release_zero_spare(e, h);
  }
  if (want && h->zero_spare[0] == NULL &&
      le_heard_alloc(e->max_loop_frames, &h->zero_spare[0],
                     &h->zero_spare[1])) {
    h->zero_spare_cap = e->max_loop_frames;
  }
}

size_t le_heard_standby_bytes(const le_engine* e, int32_t ch, int32_t l,
                              int32_t frames) {
  const int32_t live = load_i32(&((le_engine*)e)->tracks[ch].lanes[l].a_live);
  const size_t planes =
      1u + (le_heard_has(e, ch, l, live) ? (size_t)LE_HEARD_PLANES : 0u);
  return (size_t)frames * sizeof(float) * planes;
}

void le_heard_settle_attaches(le_engine* e) {
  for (int32_t ch = 0; ch < e->track_count; ++ch) {
    for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
      le_heard* h = &e->heard[ch][l];
      if (h->attach[0] == NULL) continue;
      if (h->attach_posted !=
          atomic_load_explicit(&h->a_attach_done, memory_order_acquire)) {
        continue;
      }
      if (!atomic_load_explicit(&h->a_attach_ok, memory_order_relaxed)) {
        /* Refused: the slot was no longer live, or already held an image.
         * The callback never saw these planes in the table. */
        for (int p = 0; p < LE_HEARD_PLANES; ++p) {
          le_free_audio_buffer(e, h->attach[p]);
        }
        h->cap[h->attach_slot] = le_heard_plane(h, 0, h->attach_slot) != NULL
                                     ? e->tracks[ch].lanes[l]
                                           .pool_cap[h->attach_slot]
                                     : 0;
      }
      h->attach[0] = NULL;
      h->attach[1] = NULL;
      h->attach_slot = -1;
    }
  }
}

int le_heard_attach_pending(const le_engine* e, int32_t ch) {
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    const le_heard* h = &e->heard[ch][l];
    if (h->attach[0] != NULL &&
        h->attach_posted !=
            atomic_load_explicit(&h->a_attach_done, memory_order_acquire)) {
      return 1;
    }
  }
  return 0;
}

int le_lane_slot_buffers(const le_engine* e, int32_t ch, int32_t l,
                         int32_t slot, float* out[1 + LE_HEARD_PLANES]) {
  const le_lane* ln = &e->tracks[ch].lanes[l];
  if (slot < 0 || slot >= LE_POOL_SLOTS || ln->pool[slot] == NULL) return 0;
  int n = 0;
  out[n++] = ln->pool[slot];
  const le_heard* h = &e->heard[ch][l];
  if (le_heard_plane(h, 0, slot) != NULL) {
    for (int p = 0; p < LE_HEARD_PLANES; ++p) out[n++] = le_heard_plane(h, p, slot);
  }
  return n;
}

int32_t le_engine_heard_attach(le_engine* engine, int32_t channel,
                               int32_t lane) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count ||
      lane < 0 || lane >= LE_MAX_LANES) {
    return LE_ERR_INVALID;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  if (lane >= le_lanes_active(t)) return LE_ERR_INVALID;
  le_lane* ln = &t->lanes[lane];
  le_heard* h = &engine->heard[channel][lane];
  const int32_t live = load_i32(&ln->a_live);
  if (le_heard_has(engine, channel, lane, live)) return LE_OK;
  if (h->attach[0] != NULL) return LE_ERR_NOT_READY; /* one in flight */
  /* The copy reads the clean take, so nothing may be writing it: a take
   * with content, not capturing, its last overdub pass retired (the drain
   * and a punch-out's fade both write the live slot under that flag). */
  const int32_t st = le_effective_state(t);
  if ((st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) ||
      load_i32(&t->a_state) != st ||
      atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire) ||
      t->length_pending || t->bounce_inflight != NULL) {
    return LE_ERR_NOT_READY;
  }
  const int32_t len = load_i32(&ln->a_len);
  const int32_t cap = ln->pool_cap[live];
  if (ln->pool[live] == NULL || len <= 0 || cap < len) return LE_ERR_INVALID;
  /* Only a take that sounds as its clean signal was heard as it: one with
   * a chain of its own sounds through that chain. */
  for (int32_t s = 0; s < load_i32(&ln->a_fx_count) && s < LE_FX_MAX; ++s) {
    if (load_i32(&ln->a_fx_type[s]) != LE_FX_NONE) return LE_ERR_INVALID;
  }
  float* pl;
  float* pr;
  if (!le_heard_alloc(cap, &pl, &pr)) return LE_ERR_INVALID;
  /* A dry take sounded as its clean signal, so that is what it was heard
   * as, in both planes. Copying it faults the planes in. */
  memcpy(pl, ln->pool[live], (size_t)len * sizeof(float));
  memcpy(pr, ln->pool[live], (size_t)len * sizeof(float));
  h->attach[0] = pl;
  h->attach[1] = pr;
  h->attach_slot = live;
  h->cap[live] = cap; /* the planes' size, should the callback install them */
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_HEARD_ATTACH,
                           .lanei = {channel, lane, live}});
  if (rc != LE_OK) {
    le_rt_free(pl);
    le_rt_free(pr);
    h->attach[0] = NULL;
    h->attach[1] = NULL;
    h->attach_slot = -1;
    h->cap[live] = 0;
    return rc;
  }
  h->attach_posted++;
  return LE_OK;
}

int32_t le_engine_set_lane_source(le_engine* engine, int32_t channel,
                                  int32_t lane, int32_t source) {
  if (engine == NULL || channel < 0 || channel >= LE_MAX_TRACKS || lane < 0 ||
      lane >= LE_MAX_LANES ||
      (source != LE_LANE_SOURCE_HEARD && source != LE_LANE_SOURCE_CLEAN)) {
    return LE_ERR_INVALID;
  }
  atomic_store_explicit(&engine->heard[channel][lane].a_source,
                        source == LE_LANE_SOURCE_CLEAN ? LE_HEARD_SOURCE_CLEAN
                                                       : LE_HEARD_SOURCE_HEARD,
                        memory_order_relaxed);
  return LE_OK;
}

/* ---- audio thread ---- */

/* Whether track [t] may write its clean take in the coming block, as far as
 * the block's start can tell: capturing, finishing a punch-out's fade or a
 * seam overlap, or armed to start. */
static int le_heard_may_write(le_track* t) {
  const int32_t st = load_i32(&t->a_state);
  return st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
         t->od_gain > 0.0f || t->seam_capture > 0 || t->xfade_capture > 0 ||
         t->pending_record || t->pending_image.revision != 0 ||
         load_i32(&t->a_pending) || load_i32(&t->a_pending_launch);
}

/* The monitor chains a heard block runs beside the monitored ones (#1713):
 * every input a capturing heard lane records, monitored or not, since the
 * take records the chain's output. Notes in heard_jobs every chain that runs
 * this block, for the post-pass (le_heard_input) and the next block. A chain
 * that starts running only because a take records it held whatever it last
 * ran on: it comes in through its re-enable ramp, as a chain switched back on
 * does. */
static void le_heard_add_jobs(
    le_engine* e, le_fx_par* par, const float* in, int ch_in,
    uint32_t excluded, const int* mon_has_fx, const int32_t* mon_fx_count) {
  uint64_t ran = 0u;
  for (int k = 0; k < par->jobs; ++k) ran |= UINT64_C(1) << par->job_mon[k];
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    const uint64_t bit = UINT64_C(1) << c;
    if (!(e->heard_inputs & bit) || (ran & bit) || !mon_has_fx[c]) continue;
    const int instrument = c >= LE_INSTRUMENT_SOURCE_BASE;
    if (!instrument && (in == NULL || c >= ch_in)) continue;
    if (c < LE_MAX_CHANNELS && (excluded & (1u << c))) continue;
    par->job_mon[par->jobs++] = c;
    ran |= bit;
    if (!(e->heard_jobs_prev & bit)) {
      for (int32_t s = 0; s < mon_fx_count[c]; ++s) {
        le_fx_enable_force_bypass(&e->monitors[c].fx, s);
        le_fx_rack_reset(&e->monitors[c].fx, s);
      }
    }
  }
  e->heard_jobs = ran;
}

int le_heard_block_begin(le_engine* e, int tc, const int32_t* lane_n,
                         le_fx_par* par, const float* in, int ch_in,
                         uint32_t excluded, const int* mon_has_fx,
                         const int32_t* mon_fx_count) {
  /* The chains the last block ran, if it was a heard block (le_heard_add_jobs
   * notes them); after a plain one, none counts as running. */
  e->heard_jobs_prev = e->heard_trk != 0u ? e->heard_jobs : 0u;
  e->heard_jobs = 0u;
  e->heard_inputs = 0u;
  /* No lane anywhere holds an image, and none did last block: nothing to
   * enter, leave or log. */
  if (e->heard_trk == 0u &&
      atomic_load_explicit(&e->a_heard_lanes, memory_order_relaxed) == 0) {
    return 0;
  }
  e->heard_trk = 0u;
  for (int t = 0; t < tc; ++t) {
    e->heard_log[t].n = 0;
    le_track* tr = &e->tracks[t];
    uint32_t lanes = 0u;
    for (int l = 0; l < lane_n[t]; ++l) {
      if (le_heard_any(e, t, l)) lanes |= 1u << l;
    }
    /* A lane whose last image went (a fresh clean take, a reset) leaves the
     * heard path while it may still be playing it: its chain comes back
     * through its re-enable ramp, as on a source switch. A lane that gets
     * its first one starts on its clean take and fades to the image (a take
     * that records one has done so by the time it plays). */
    const uint32_t left = e->heard_lanes[t] & ~lanes;
    for (int l = 0; l < LE_MAX_LANES && left != 0u; ++l) {
      if (!(left & (1u << l))) continue;
      le_heard* h = &e->heard[t][l];
      if (h->mix > 0.0f) {
        le_lane* ln = &tr->lanes[l];
        int32_t n = load_i32(&ln->a_fx_count);
        if (n > LE_FX_MAX) n = LE_FX_MAX;
        for (int32_t s = 0; s < n; ++s) {
          le_fx_enable_force_bypass(&ln->fx, s);
          le_fx_rack_reset(&ln->fx, s);
        }
      }
      h->mix = 0.0f;
    }
    const uint32_t entered = lanes & ~e->heard_lanes[t];
    for (int l = 0; l < LE_MAX_LANES && entered != 0u; ++l) {
      if (entered & (1u << l)) e->heard[t][l].mix = 0.0f;
    }
    e->heard_lanes[t] = lanes;
    if (lanes == 0u) continue;
    e->heard_trk |= 1u << t;
    /* The inputs as the block starts: the post-pass reads the same. */
    for (int l = 0; l < lane_n[t]; ++l) {
      e->heard_input[t][l] = load_i32(&tr->lanes[l].a_input_channel);
    }
    if (!le_heard_may_write(tr)) continue;
    for (int l = 0; l < lane_n[t]; ++l) {
      if (!(lanes & (1u << l))) continue;
      const int32_t live = load_i32(&tr->lanes[l].a_live);
      if (!le_heard_has(e, t, l, live)) continue;
      const int32_t c = e->heard_input[t][l];
      if (c >= 0 && c < LE_MAX_MONITORED_INPUTS) {
        e->heard_inputs |= UINT64_C(1) << c;
      }
    }
  }
  if (e->heard_trk == 0u) return 0;
  le_heard_add_jobs(e, par, in, ch_in, excluded, mon_has_fx, mon_fx_count);
  return 1;
}

/* One plane's share of each logged content operation: the clean helpers'
 * arithmetic exactly (engine_core.h), against the clean slot's capacity. */
static void le_heard_apply_lane(le_engine* e, int32_t ch, int32_t l,
                                const le_heard_rec* r) {
  const le_lane* ln = &e->tracks[ch].lanes[l];
  const le_heard* h = &e->heard[ch][l];
  const int32_t s = r->slot;
  if (s < 0 || s >= LE_POOL_SLOTS || le_heard_plane(h, 0, s) == NULL) return;
  const int32_t cap = ln->pool_cap[s];
  for (int p = 0; p < LE_HEARD_PLANES; ++p) {
    float* b = le_heard_plane(h, p, s);
    switch (r->kind) {
      case LE_HEARD_REC_SEAM_FOLD:
        if (cap >= r->a + r->b) le_seam_fold_head(b, b + r->a, r->b);
        break;
      case LE_HEARD_REC_SHADOW_FOLD: {
        const int32_t d = r->slot2;
        if (d < 0 || d >= LE_POOL_SLOTS || d == s) break;
        float* sb = le_heard_plane(h, p, d);
        if (sb != NULL && cap >= r->a + r->b && ln->pool_cap[d] >= r->b) {
          le_seam_fold_head(sb, b + r->a, r->b);
        }
        break;
      }
      case LE_HEARD_REC_FADE_OUT:
        if (cap >= r->b) le_plane_fade_out_to(b, r->a, r->b, r->c);
        break;
      case LE_HEARD_REC_FADE_IN:
        if (cap >= r->b) le_plane_fade_in_at(b, r->a, r->b, r->c);
        break;
      case LE_HEARD_REC_COPY: {
        const int32_t d = r->slot2;
        if (d < 0 || d >= LE_POOL_SLOTS) break;
        float* sb = le_heard_plane(h, p, d);
        if (sb != NULL && cap >= r->c && ln->pool_cap[d] >= r->c) {
          le_plane_copy_wrapped(sb, b, r->a, r->b, r->c);
        }
        break;
      }
      default:
        break;
    }
  }
}

static void le_heard_apply(le_engine* e, int32_t ch, const le_heard_rec* r) {
  const int32_t n = le_lanes_active(&e->tracks[ch]);
  for (int32_t l = 0; l < n; ++l) {
    if (le_heard_any(e, ch, l)) le_heard_apply_lane(e, ch, l, r);
  }
}

void le_heard_op(le_engine* e, le_track* t, le_heard_rec op) {
  const int32_t ch = (int32_t)(t - e->tracks);
  /* In the frame loop only a track of the block's heard set logs: the
   * post-pass replays no other. */
  if (e->heard_i >= 0 && !(e->heard_trk & (1u << ch))) return;
  const int32_t n = le_lanes_active(t);
  int any = 0;
  for (int32_t l = 0; l < n && !any; ++l) any = le_heard_any(e, ch, l);
  if (!any) return;
  if (e->heard_i < 0) {
    le_heard_apply(e, ch, &op);
    return;
  }
  le_heard_log* lg = &e->heard_log[ch];
  if (lg->n >= LE_HEARD_LOG_CAP) {
    lg->dropped++;
    return;
  }
  op.i = (uint16_t)e->heard_i;
  lg->rec[lg->n++] = op;
}

void le_heard_seam_fold(le_engine* e, le_track* t, int32_t len, int32_t F,
                        int shadow) {
  const int16_t live = (int16_t)load_i32(&t->lanes[0].a_live);
  if (shadow && t->dub_slot >= 0 && load_i32(&t->a_layer_in_flight)) {
    le_heard_op(e, t, (le_heard_rec){.kind = LE_HEARD_REC_SHADOW_FOLD,
                                     .slot = live,
                                     .slot2 = (int16_t)t->dub_slot,
                                     .a = len, .b = F});
  }
  le_heard_op(e, t, (le_heard_rec){.kind = LE_HEARD_REC_SEAM_FOLD,
                                   .slot = live, .slot2 = -1, .a = len,
                                   .b = F});
}

/* Lane l's input chain output at block frame [i], times its capture trim. */
static void le_heard_input(const le_engine* e, const le_fx_par* par,
                           uint32_t b0, uint32_t i, const float* in, int ch_in,
                           const float* in_trim, uint32_t excluded,
                           const int* mon_has_fx, int32_t c, float* wl,
                           float* wr) {
  *wl = 0.0f;
  *wr = 0.0f;
  if (c < 0 || c >= LE_MAX_MONITORED_INPUTS) return;
  const int instrument = le_source_is_instrument(c);
  if (!instrument) {
    if (in == NULL || c >= ch_in || (excluded & (1u << c))) return;
  }
  /* The capture trim scales what records (slice 3): the clean take, and so
   * its image. An instrument has none. */
  const float trim = instrument ? 1.0f : in_trim[c];
  /* The chain's output where it ran as a job this block; its input where
   * it has no chain. */
  (void)mon_has_fx;
  if ((e->heard_jobs >> c) & 1u) {
    *wl = par->mon_l[c][i] * trim;
    *wr = par->mon_r[c][i] * trim;
    return;
  }
  const uint32_t f = b0 + i;
  const float x = instrument ? le_instrument_source_sample(e, c, f)
                             : in[f * (uint32_t)ch_in + (uint32_t)c];
  *wl = x * trim;
  *wr = *wl;
}

void le_heard_post(le_engine* e, const le_fx_par* par, uint32_t b0,
                   const float* in, int ch_in, const float* in_trim,
                   uint32_t excluded, const int* mon_has_fx) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    if (!(e->heard_trk & (1u << t))) continue;
    le_heard_log* lg = &e->heard_log[t];
    if (lg->n == 0 && lg->dropped == 0) continue;
    le_track* tr = &e->tracks[t];
    const int32_t lanes = le_lanes_active(tr);
    const int32_t* input = e->heard_input[t];
    for (int32_t k = 0; k < lg->n; ++k) {
      const le_heard_rec* r = &lg->rec[k];
      if (r->kind != LE_HEARD_REC_WRITE) {
        le_heard_apply(e, t, r);
        continue;
      }
      const int32_t s = r->slot;
      if (s < 0 || s >= LE_POOL_SLOTS) continue;
      for (int32_t l = 0; l < lanes; ++l) {
        le_heard* h = &e->heard[t][l];
        float* hl = le_heard_plane(h, 0, s);
        if (hl == NULL) continue;
        float* hr = le_heard_plane(h, 1, s);
        const int32_t cap = tr->lanes[l].pool_cap[s];
        float wl;
        float wr;
        le_heard_input(e, par, b0, (uint32_t)r->i - b0, in, ch_in, in_trim,
                       excluded, mon_has_fx, input[l], &wl, &wr);
        if (r->a >= 0 && r->a < cap) {
          hl[r->a] = wl;
          hr[r->a] = wr;
        }
        if (r->b >= 0 && r->b < cap) {
          /* Backup-on-write first, as the clean take's: the shadow keeps the
           * pre-pass image. */
          const int32_t d = r->slot2;
          if (d >= 0 && d < LE_POOL_SLOTS && le_heard_plane(h, 0, d) != NULL &&
              r->b < tr->lanes[l].pool_cap[d]) {
            le_heard_plane(h, 0, d)[r->b] = hl[r->b];
            le_heard_plane(h, 1, d)[r->b] = hr[r->b];
          }
          hl[r->b] = hl[r->b] * r->fb + wl * r->g;
          hr[r->b] = hr[r->b] * r->fb + wr * r->g;
        }
        if (r->c >= 0 && r->c < cap) {
          hl[r->c] = wl;
          hr[r->c] = wr;
        }
      }
    }
    if (lg->dropped) {
      atomic_fetch_add_explicit(&e->a_heard_dropped, lg->dropped,
                                memory_order_relaxed);
      lg->dropped = 0;
    }
    lg->n = 0;
  }
}

void le_heard_run_copy(le_engine* e, le_track* t, int32_t live, int32_t shadow,
                       int32_t w0, int32_t run, int shadow_to_live) {
  const int32_t ch = (int32_t)(t - e->tracks);
  if (live < 0 || live >= LE_POOL_SLOTS || shadow < 0 ||
      shadow >= LE_POOL_SLOTS) {
    return;
  }
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    if (!le_heard_any(e, ch, l)) continue;
    le_heard* h = &e->heard[ch][l];
    for (int p = 0; p < LE_HEARD_PLANES; ++p) {
      float* lb = le_heard_plane(h, p, live);
      float* sb = le_heard_plane(h, p, shadow);
      if (lb == NULL || sb == NULL) continue;
      if (shadow_to_live) {
        memcpy(lb + w0, sb + w0, (size_t)run * sizeof(float));
      } else {
        memcpy(sb + w0, lb + w0, (size_t)run * sizeof(float));
      }
    }
  }
}

void le_heard_truncate(le_engine* e, le_track* t, int64_t from, int64_t to,
                       int32_t offset, int32_t known_len) {
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    if (!le_heard_any(e, ch, l)) continue;
    const int32_t live = load_i32(&t->lanes[l].a_live);
    float* pl;
    float* pr;
    if (!le_heard_planes(e, ch, l, live, &pl, &pr)) continue;
    for (int64_t p = from; p < to; ++p) {
      int64_t w = p - offset; /* the write head's mapping, as for the take */
      if (w < 0) continue;
      if (known_len > 0 && w >= known_len) w %= known_len;
      if (w >= e->max_loop_frames) continue;
      pl[(int32_t)w] = 0.0f;
      pr[(int32_t)w] = 0.0f;
    }
  }
}

void le_heard_attach_apply(le_engine* e, int32_t ch, int32_t l) {
  if (ch < 0 || ch >= LE_MAX_TRACKS || l < 0 || l >= LE_MAX_LANES) return;
  le_heard* h = &e->heard[ch][l];
  const int32_t slot = h->attach_slot;
  int ok = 0;
  if (slot >= 0 && slot < LE_POOL_SLOTS && h->attach[0] != NULL &&
      load_i32(&e->tracks[ch].lanes[l].a_live) == slot &&
      le_heard_plane(h, 0, slot) == NULL) {
    le_heard_plane_set(h, 0, slot, h->attach[0]);
    le_heard_plane_set(h, 1, slot, h->attach[1]);
    le_heard_slots_add(e, h, 1);
    ok = 1;
  }
  atomic_store_explicit(&h->a_attach_ok, ok, memory_order_relaxed);
  /* The only writer: one report per handled command (control posts the
   * next only after reading this one). */
  atomic_store_explicit(
      &h->a_attach_done,
      atomic_load_explicit(&h->a_attach_done, memory_order_relaxed) + 1u,
      memory_order_release);
}
