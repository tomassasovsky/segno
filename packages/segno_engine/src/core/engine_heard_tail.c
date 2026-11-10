/*
 * engine_heard_tail.c — the heard image's rendered tails (#1713 part 3).
 *
 * See le_heard_ring in engine_private.h for the model. The threads:
 *
 * - The callback records each input a capturing heard lane records into
 *   that input's ring (le_heard_tail_post), follows each track's pass, and
 *   at a pass's end leaves what the render needs in le_engine.heard_end and
 *   posts LE_EVT_HEARD_TAIL (le_heard_tail_block). It then adds a published
 *   tail into the image, a frame of tail per frame of time since the end,
 *   and lets go of it.
 * - Control (le_engine_drain_events) maps the rings, copies the end's input
 *   window and freezes the input chain into a tail (le_heard_tail_event),
 *   publishes it once rendered and frees it once the callback is done
 *   (le_heard_tail_poll).
 * - The cache worker renders it, a lane per step (le_heard_tail_worker_step).
 *
 * A tail's state says who holds it: the worker from taking it off
 * engine->heard_tail_queue[t] until it stores RENDERED or FAILED (between
 * lanes it puts it back on the queue), then control, then the callback while
 * it is published (engine->heard_tail[t] non-NULL), and control again once
 * the callback clears that pointer and marks it DONE. The worker reads no
 * other pointer to it, so control frees a tail only in a state the worker
 * and the callback are done with.
 */
#include "engine_heard.h"

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_cache.h" /* le_fx_frozen_chain, le_fx_frozen_state_init */
#include "engine_core.h"
#include "engine_fx.h"
#include "engine_instruments.h" /* le_source_is_instrument */
#include "engine_internal.h"
#include "rt_alloc.h"

enum {
  LE_HEARD_TAIL_QUEUED = 1,
  LE_HEARD_TAIL_RENDERING = 2,
  LE_HEARD_TAIL_RENDERED = 3,
  LE_HEARD_TAIL_DONE = 4,
  LE_HEARD_TAIL_FAILED = 5,
  LE_HEARD_TAIL_PUBLISHED = 6,
};

/* Frames the callback adds per track per block, so a tail published late
 * catches up over a few blocks rather than in one. */
#define LE_HEARD_TAIL_ADD_BUDGET 4096

/* The level a tail is cut at once every frame of a 100 ms window is below
 * it: -80 dBFS. */
#define LE_HEARD_TAIL_FLOOR 1e-4f

typedef struct le_heard_tail {
  _Atomic int32_t a_state;
  /* Control: a newer pass end overtook it; the worker stops rendering it. */
  _Atomic int32_t a_stale;
  int32_t channel;
  uint32_t gen;
  /* Where it goes: the live slot at the end, the loop length, the position
   * after the last write and the clock of the first tail frame. */
  int32_t slot;
  int32_t len;
  int32_t q0;
  uint32_t start_clock;
  /* Per lane: the input window (raw, [window] frames ending at the last
   * write), the frozen chain, its tempo and the capture trim; the rendered
   * tail as (L, R) pairs, [frames] of them (0: nothing to add). */
  uint32_t lanes;
  int32_t window;
  int32_t sample_rate;
  int32_t fx_cap;
  float* in[LE_MAX_LANES];
  le_fx_frozen_chain chain[LE_MAX_LANES];
  le_fx_tempo tempo[LE_MAX_LANES];
  float trim[LE_MAX_LANES];
  float* out[LE_MAX_LANES];
  int32_t frames[LE_MAX_LANES];
  int32_t most; /* the longest of frames[] */
  /* Worker: the next lane to render. */
  int32_t next_lane;
  /* Callback: frames added so far, the position the next one goes to, and
   * whether any sample went into an image. */
  int32_t done;
  int32_t q;
  int32_t added;
} le_heard_tail;

static void le_heard_tail_free(le_heard_tail* j) {
  if (j == NULL) return;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    free(j->in[l]);
    free(j->out[l]);
  }
  free(j);
}

/* ---- audio thread ---- */

void le_heard_tail_note_write(le_engine* e, int t, uint32_t clock,
                              int32_t pos) {
  le_heard_pass* p = &e->heard_pass[t];
  p->capturing = 1;
  p->last_clock = clock;
  p->last_pos = pos;
}

void le_heard_tail_post(le_engine* e, const le_fx_par* par, const float* in,
                        int ch_in, uint32_t excluded) {
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!((e->heard_inputs >> c) & 1u)) continue;
    le_heard_ring* r = &e->heard_ring[c];
    float* buf = atomic_load_explicit(&r->buf, memory_order_acquire);
    if (buf == NULL || r->cap <= 0) continue;
    const uint32_t mask = (uint32_t)r->cap - 1u;
    const int instrument = le_source_is_instrument(c);
    /* An excluded input records silence (le_heard_input), so it leaves no
     * tail either. */
    const int silent =
        !instrument && (in == NULL || c >= ch_in ||
                        (c < LE_MAX_CHANNELS && (excluded & (1u << c))));
    /* A gap since the last frame written (the input recorded by no heard
     * lane meanwhile) leaves older frames in the ring: its history starts
     * over here, so a window reaching back past the gap reads silence, not
     * an earlier lap of the ring. */
    if (!atomic_load_explicit(&r->a_started, memory_order_relaxed)) {
      atomic_store_explicit(&r->a_prev_begin, par->clock, memory_order_relaxed);
      atomic_store_explicit(&r->a_prev_end, par->clock, memory_order_relaxed);
      atomic_store_explicit(&r->a_begin, par->clock, memory_order_relaxed);
      atomic_store_explicit(&r->a_started, 1, memory_order_relaxed);
    } else if (atomic_load_explicit(&r->a_end, memory_order_relaxed) !=
               par->clock) {
      /* The run that ended stays readable as the previous one. */
      atomic_store_explicit(
          &r->a_prev_begin,
          atomic_load_explicit(&r->a_begin, memory_order_relaxed),
          memory_order_relaxed);
      atomic_store_explicit(
          &r->a_prev_end,
          atomic_load_explicit(&r->a_end, memory_order_relaxed),
          memory_order_relaxed);
      atomic_store_explicit(&r->a_begin, par->clock, memory_order_release);
    }
    for (uint32_t i = 0; i < par->n; ++i) {
      const uint32_t f = par->f0 + i;
      float x = 0.0f;
      if (!par->owned[i] && !silent) {
        x = instrument ? le_instrument_source_sample(e, c, f)
                       : in[f * (uint32_t)ch_in + (uint32_t)c];
      }
      buf[(par->clock + i) & mask] = x;
    }
    atomic_store_explicit(&r->a_end, par->clock + par->n,
                          memory_order_release);
  }
}

/* The end of track [t]'s pass: what control needs, then the event. */
static void le_heard_tail_end(le_engine* e, int t) {
  le_heard_pass* p = &e->heard_pass[t];
  le_track* tr = &e->tracks[t];
  p->capturing = 0;
  ++p->gen;
  if (p->gen == 0u) p->gen = 1u; /* 0 is the sequence lock's "writing" */
  le_heard_end* d = &e->heard_end[t];
  atomic_store_explicit(&d->a_gen, 0u, memory_order_relaxed);
  atomic_thread_fence(memory_order_release);
  d->slot = load_i32(&tr->lanes[0].a_live);
  d->last_clock = p->last_clock;
  d->last_pos = p->last_pos;
  d->len = load_i32(&tr->lanes[0].a_len);
  d->lanes = e->heard_lanes[t];
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    d->input[l] = -1;
    if (!((d->lanes >> l) & 1u)) continue;
    const int32_t c = e->heard_input[t][l];
    d->input[l] = c;
    if (c < 0 || c >= LE_MAX_MONITORED_INPUTS) continue;
    d->trim[l] = le_source_is_instrument(c) || c >= LE_MAX_CHANNELS
                     ? 1.0f
                     : load_f32(&e->a_in_trim_bits[c]);
    d->tempo[l] = e->monitors[c].fx_time.tempo;
  }
  atomic_store_explicit(&d->a_gen, p->gen, memory_order_release);
  const le_command evt = {.code = LE_EVT_HEARD_TAIL,
                          .evt = {t, d->slot, p->gen}};
  (void)le_ring_push(&e->evt_ring, evt); /* a full ring: no tail */
}

/* Adds what is due of track [t]'s published tail, or lets go of it. */
static void le_heard_tail_add(le_engine* e, int t, le_heard_tail* j) {
  le_track* tr = &e->tracks[t];
  const int32_t live = load_i32(&tr->lanes[0].a_live);
  /* Still the last pass's tail, on the take it ended (no capture since, or
   * starting in this block), playing at its own timing. */
  const int keep = j->gen == e->heard_pass[t].gen &&
                   !e->heard_pass[t].capturing &&
                   !le_heard_track_may_write(e, t) &&
                   load_i32(&tr->a_state) == LE_TRACK_PLAYING &&
                   live == j->slot && load_i32(&tr->lanes[0].a_len) == j->len &&
                   le_head_is_identity(&tr->head);
  int32_t upto = (int32_t)(e->fx_clock_base - j->start_clock);
  if (upto < 0 || upto > j->most) upto = j->most;
  if (keep && upto > j->done) {
    int32_t n = upto - j->done;
    if (n > LE_HEARD_TAIL_ADD_BUDGET) n = LE_HEARD_TAIL_ADD_BUDGET;
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      if (!((j->lanes >> l) & 1u) || j->out[l] == NULL) continue;
      float* pl;
      float* pr;
      if (!le_heard_planes(e, t, l, j->slot, &pl, &pr)) continue;
      const int32_t cap = tr->lanes[l].pool_cap[j->slot];
      const int32_t stop = j->done + n < j->frames[l] ? j->done + n
                                                      : j->frames[l];
      int32_t q = j->q;
      for (int32_t k = j->done; k < stop; ++k) {
        if (q < cap) {
          pl[q] += j->out[l][2 * k];
          pr[q] += j->out[l][2 * k + 1];
        }
        if (++q == j->len) q = 0;
      }
      if (stop > j->done) j->added = 1;
    }
    j->done += n;
    j->q = (int32_t)(((int64_t)j->q + n) % j->len);
    if (j->done < j->most) return;
  } else if (keep) {
    return; /* nothing due yet */
  }
  /* Done, or dropped: what was added is content (the wet cache and the
   * Transpose renders re-key); control frees the tail. */
  if (j->added) le_audio_rev_bump(tr);
  atomic_store_explicit(&e->heard_tail[t], NULL, memory_order_relaxed);
  atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_DONE, memory_order_release);
}

void le_heard_tail_block(le_engine* e, int tc) {
  for (int t = 0; t < tc; ++t) {
    if (e->heard_pass[t].capturing && !le_heard_track_may_write(e, t)) {
      le_heard_tail_end(e, t);
    }
    le_heard_tail* j =
        atomic_load_explicit(&e->heard_tail[t], memory_order_acquire);
    if (j != NULL) le_heard_tail_add(e, t, j);
  }
}

/* ---- control thread ---- */

/* The ring's size for [sr]: the smallest power of two holding
 * LE_HEARD_TAIL_RING_S seconds. */
static int32_t le_heard_ring_cap(int32_t sr) {
  const int64_t want = (int64_t)sr * LE_HEARD_TAIL_RING_S;
  int64_t cap = 1;
  while (cap < want) cap <<= 1;
  return cap > INT32_MAX / 2 ? 0 : (int32_t)cap;
}

/* Maps a ring for every input a lane holding an image records, so its next
 * capture's end finds the input's history. */
static void le_heard_tail_rings(le_engine* e) {
  const int32_t sr = e->sample_rate;
  if (sr <= 0) return;
  for (int t = 0; t < e->track_count; ++t) {
    for (int l = 0; l < le_lanes_active(&e->tracks[t]); ++l) {
      if (!le_heard_any(e, t, l)) continue;
      const int32_t c = load_i32(&e->tracks[t].lanes[l].a_input_channel);
      if (c < 0 || c >= LE_MAX_MONITORED_INPUTS) continue;
      le_heard_ring* r = &e->heard_ring[c];
      if (atomic_load_explicit(&r->buf, memory_order_relaxed) != NULL) {
        continue;
      }
      const int32_t cap = le_heard_ring_cap(sr);
      float* buf = cap > 0 ? (float*)le_rt_alloc_prefaulted(
                                 (size_t)cap * sizeof(float))
                           : NULL;
      if (buf == NULL) continue; /* no tail for this input */
      r->cap = cap;
      atomic_store_explicit(&r->a_started, 0, memory_order_relaxed);
      atomic_store_explicit(&r->buf, buf, memory_order_release);
    }
  }
}

/* Copies [n] frames of ring [r] ending at clock [last] (inclusive) into
 * [out]; frames outside the ring's current and previous runs read 0.
 * Returns 0 when the ring has not reached [last], or the callback overwrote
 * part of the window (or may be writing it, a block ahead of what it
 * published) while it was read. */
static int le_heard_tail_copy(le_heard_ring* r, uint32_t last, int32_t n,
                              float* out) {
  const float* buf = atomic_load_explicit(&r->buf, memory_order_acquire);
  if (buf == NULL || !atomic_load_explicit(&r->a_started,
                                           memory_order_relaxed)) {
    return 0;
  }
  const uint32_t mask = (uint32_t)r->cap - 1u;
  const uint32_t end0 = atomic_load_explicit(&r->a_end, memory_order_acquire);
  if ((int32_t)(end0 - (last + 1u)) < 0) return 0; /* not written yet */
  const uint32_t begin =
      atomic_load_explicit(&r->a_begin, memory_order_acquire);
  const uint32_t pbegin =
      atomic_load_explicit(&r->a_prev_begin, memory_order_relaxed);
  const uint32_t pend =
      atomic_load_explicit(&r->a_prev_end, memory_order_relaxed);
  const uint32_t first = last - (uint32_t)(n - 1);
  for (int32_t i = 0; i < n; ++i) {
    const uint32_t clk = first + (uint32_t)i;
    const int in_run = (int32_t)(clk - begin) >= 0;
    const int in_prev = (int32_t)(clk - pbegin) >= 0 && (int32_t)(pend - clk) > 0;
    out[i] = in_run || in_prev ? buf[clk & mask] : 0.0f;
  }
  /* The oldest frame read must still be in the ring now, with a block's
   * margin for the write the callback has not published yet, and the runs
   * must be the ones it read. */
  const uint32_t end = atomic_load_explicit(&r->a_end, memory_order_acquire);
  return (int64_t)(uint32_t)(end - first) <=
             (int64_t)r->cap - LE_FX_BLOCK &&
         atomic_load_explicit(&r->a_begin, memory_order_acquire) == begin;
}

static _Atomic int32_t le_heard_tail_no_pre; /* monitors have no Pre split */

/* Builds track [t]'s tail for its pass end of generation [gen], if the
 * callback's record of that end is still that one and a cache worker runs
 * to render it. NULL when there is nothing to render. */
static le_heard_tail* le_heard_tail_build(le_engine* e, int32_t t,
                                          uint32_t gen) {
  if (e->cache == NULL) return NULL; /* caching off: no worker */
  le_heard_end* d = &e->heard_end[t];
  if (atomic_load_explicit(&d->a_gen, memory_order_acquire) != gen) {
    return NULL;
  }
  le_heard_end end = *d; /* the sequence lock's copy */
  atomic_thread_fence(memory_order_acquire);
  if (atomic_load_explicit(&d->a_gen, memory_order_relaxed) != gen ||
      end.len <= 0) {
    return NULL; /* a later end overwrote it while it was read */
  }
  le_heard_tail* j = (le_heard_tail*)calloc(1, sizeof(le_heard_tail));
  if (j == NULL) return NULL;
  j->channel = t;
  j->gen = gen;
  j->slot = end.slot;
  j->len = end.len;
  j->q0 = (int32_t)(((int64_t)end.last_pos + 1) % end.len);
  if (j->q0 < 0) j->q0 += end.len;
  j->q = j->q0;
  j->start_clock = end.last_clock + 1u;
  j->sample_rate = e->sample_rate;
  j->fx_cap = e->fx_delay_frames;
  j->window = e->sample_rate * LE_HEARD_TAIL_WINDOW_S;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    if (!((end.lanes >> l) & 1u)) continue;
    const int32_t c = end.input[l];
    if (c < 0 || c >= LE_MAX_MONITORED_INPUTS) continue;
    le_monitor_input* m = &e->monitors[c];
    le_fx_frozen_capture(&j->chain[l], &m->a_fx_count, &le_heard_tail_no_pre,
                         &m->a_fx_chain_enabled, m->a_fx_type, m->a_fx_enabled,
                         m->a_fx_param, m->a_fx_chan_in, m->a_fx_chan_out,
                         m->a_fx_chan_gl_bits, m->a_fx_chan_gr_bits,
                         m->a_fx_chan_level_bits, m->a_fx_chan_rack,
                         m->fx.hop_seed);
    if (!le_fx_frozen_has(&j->chain[l], 0, j->chain[l].count, LE_FX_NONE)) {
      continue; /* no chain: the input itself, which leaves no tail */
    }
    j->in[l] = (float*)malloc((size_t)j->window * sizeof(float));
    if (j->in[l] == NULL ||
        !le_heard_tail_copy(&e->heard_ring[c], end.last_clock, j->window,
                            j->in[l])) {
      free(j->in[l]);
      j->in[l] = NULL;
      continue;
    }
    j->chain[l].clock0 = j->start_clock - (uint32_t)j->window;
    j->tempo[l] = end.tempo[l];
    j->trim[l] = end.trim[l];
    j->lanes |= 1u << l;
  }
  if (j->lanes == 0u) {
    le_heard_tail_free(j);
    return NULL;
  }
  return j;
}

/* Makes [j] track [t]'s tail in flight and hands it to the worker. */
static void le_heard_tail_queue(le_engine* e, int32_t t, le_heard_tail* j) {
  e->heard_tail_ctl[t] = j;
  atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_QUEUED,
                        memory_order_relaxed);
  atomic_store_explicit(&e->heard_tail_queue[t], j, memory_order_release);
}

void le_heard_tail_event(le_engine* e, const le_command* evt) {
  const int32_t t = evt->evt.channel;
  if (t < 0 || t >= LE_MAX_TRACKS || e->sample_rate <= 0) return;
  le_heard_tail* j = le_heard_tail_build(e, t, evt->evt.generation);
  if (e->heard_tail_ctl[t] != NULL) {
    /* The last tail is still in flight: a capture has since overtaken it,
     * so it is not added (the worker stops rendering it), and this end's,
     * built now while its input is in the ring, goes next. */
    atomic_store_explicit(&e->heard_tail_ctl[t]->a_stale, 1,
                          memory_order_relaxed);
    le_heard_tail_free(e->heard_tail_next[t]);
    e->heard_tail_next[t] = j;
    return;
  }
  if (j != NULL) le_heard_tail_queue(e, t, j);
}

void le_heard_tail_poll(le_engine* e) {
  le_heard_tail_rings(e);
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_heard_tail* j = e->heard_tail_ctl[t];
    if (j == NULL) continue;
    const int32_t st = atomic_load_explicit(&j->a_state, memory_order_acquire);
    if (st == LE_HEARD_TAIL_RENDERED) {
      if (j->most <= 0 ||
          atomic_load_explicit(&j->a_stale, memory_order_relaxed)) {
        e->heard_tail_ctl[t] = NULL;
        le_heard_tail_free(j);
        continue;
      }
      /* The callback lets go of a tail before it takes the next. */
      if (atomic_load_explicit(&e->heard_tail[t], memory_order_relaxed) ==
          NULL) {
        atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_PUBLISHED,
                              memory_order_relaxed);
        atomic_store_explicit(&e->heard_tail[t], j, memory_order_release);
      }
    } else if (st == LE_HEARD_TAIL_DONE || st == LE_HEARD_TAIL_FAILED) {
      e->heard_tail_ctl[t] = NULL;
      le_heard_tail_free(j);
    }
  }
  /* A pass end's tail that waited for its track's last one. */
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    if (e->heard_tail_ctl[t] != NULL || e->heard_tail_next[t] == NULL) {
      continue;
    }
    le_heard_tail* j = e->heard_tail_next[t];
    e->heard_tail_next[t] = NULL;
    le_heard_tail_queue(e, t, j);
  }
}

/* The tail of one lane: the window through a fresh copy of the chain, then
 * silence, kept from the window's end until it falls under the floor for a
 * 100 ms run or LE_HEARD_TAIL_MAX_S passes. */
static int le_heard_tail_render_lane(le_engine* e, le_heard_tail* j, int l) {
  const int32_t sr = j->sample_rate;
  const int32_t most = sr * LE_HEARD_TAIL_MAX_S;
  const int32_t quiet_run = sr / 10 > 0 ? sr / 10 : 1;
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) return 0;
  const le_fx_frozen_chain* c = &j->chain[l];
  int ok = le_fx_frozen_state_init(fx, c, 0, c->count, j->fx_cap) == LE_OK;
  fx->tempo = &j->tempo[l];
  int32_t bits[LE_FX_MAX];
  le_fx_frozen_bits(c, 0, c->count, bits);
  float* out = ok ? (float*)malloc(2 * (size_t)most * sizeof(float)) : NULL;
  ok = out != NULL;
  int32_t kept = 0;
  int32_t quiet = 0;
  const float trim = j->trim[l];
  for (int32_t f = 0; ok && f < j->window + most; ++f) {
    if ((f & 4095) == 0 && le_cache_shutting_down(e)) {
      ok = 0;
      break;
    }
    float a = f < j->window ? j->in[l][f] : 0.0f;
    float b = a;
    fx->clock = c->clock0 + (uint32_t)f;
    fx_apply_chain(fx, sr, j->fx_cap, &a, &b, c->count, c->type, c->params,
                   bits);
    if (f < j->window) continue;
    out[2 * kept] = a * trim;
    out[2 * kept + 1] = b * trim;
    ++kept;
    quiet = fabsf(a * trim) < LE_HEARD_TAIL_FLOOR &&
                    fabsf(b * trim) < LE_HEARD_TAIL_FLOOR
                ? quiet + 1
                : 0;
    if (quiet >= quiet_run) break;
  }
  le_fx_state_free_buffers(fx);
  free(fx);
  if (!ok) {
    free(out);
    return 0;
  }
  j->frames[l] = kept - quiet; /* the quiet run adds nothing */
  /* Only what is kept stays allocated (the worst case is 20 s). */
  float* fit = (float*)realloc(out, 2 * (size_t)(j->frames[l] > 0 ? j->frames[l]
                                                                  : 1) *
                                        sizeof(float));
  j->out[l] = fit != NULL ? fit : out;
  if (j->frames[l] > j->most) j->most = j->frames[l];
  return 1;
}

int le_heard_tail_worker_ready(le_engine* e) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    if (atomic_load_explicit(&e->heard_tail_queue[t], memory_order_relaxed) !=
        NULL) {
      return 1;
    }
  }
  return 0;
}

void le_heard_tail_worker_step(le_engine* e) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_heard_tail* j = atomic_exchange_explicit(&e->heard_tail_queue[t], NULL,
                                                memory_order_acq_rel);
    if (j == NULL) continue;
    atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_RENDERING,
                          memory_order_relaxed);
    /* One lane per step, so the cache's own jobs get the worker between
     * lanes. */
    while (j->next_lane < LE_MAX_LANES && !((j->lanes >> j->next_lane) & 1u)) {
      ++j->next_lane;
    }
    if (atomic_load_explicit(&j->a_stale, memory_order_relaxed)) {
      j->next_lane = LE_MAX_LANES; /* overtaken: control frees it */
    }
    if (j->next_lane < LE_MAX_LANES) {
      if (!le_heard_tail_render_lane(e, j, j->next_lane)) {
        atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_FAILED,
                              memory_order_release);
        return;
      }
      ++j->next_lane;
    }
    while (j->next_lane < LE_MAX_LANES && !((j->lanes >> j->next_lane) & 1u)) {
      ++j->next_lane;
    }
    if (j->next_lane < LE_MAX_LANES) {
      atomic_store_explicit(&e->heard_tail_queue[t], j, memory_order_release);
    } else {
      atomic_store_explicit(&j->a_state, LE_HEARD_TAIL_RENDERED,
                            memory_order_release);
    }
    return;
  }
}

void le_heard_tail_free_all(le_engine* e) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_heard_tail* pub =
        atomic_load_explicit(&e->heard_tail[t], memory_order_relaxed);
    if (pub != NULL && pub != e->heard_tail_ctl[t]) le_heard_tail_free(pub);
    le_heard_tail_free(e->heard_tail_ctl[t]);
    e->heard_tail_ctl[t] = NULL;
    atomic_store_explicit(&e->heard_tail[t], NULL, memory_order_relaxed);
    atomic_store_explicit(&e->heard_tail_queue[t], NULL, memory_order_relaxed);
    le_heard_tail_free(e->heard_tail_next[t]);
    e->heard_tail_next[t] = NULL;
    memset(&e->heard_pass[t], 0, sizeof(e->heard_pass[t]));
    atomic_store_explicit(&e->heard_end[t].a_gen, 0u, memory_order_relaxed);
  }
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_heard_ring* r = &e->heard_ring[c];
    le_rt_free(atomic_load_explicit(&r->buf, memory_order_relaxed));
    atomic_store_explicit(&r->buf, NULL, memory_order_relaxed);
    r->cap = 0;
    atomic_store_explicit(&r->a_started, 0, memory_order_relaxed);
  }
}
