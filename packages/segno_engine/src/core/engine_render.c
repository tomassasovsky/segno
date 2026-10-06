/*
 * engine_render.c — the shared render recipe for Bounce and Save selected
 * audio (#1202; plan docs/plan/2026-10-06-feat-render-recipe-bounce-plan.md).
 *
 * WHAT IS RENDERED (plan 4.2-4.6). The selected recorded tracks, regardless
 * of transport, Mute and Solo, as the live mixer would play them with no
 * gates: per lane the take's material (its Pre print, made by the wet cache's
 * own print function, or dry x level), the lane's Post entries, the lane pan;
 * per track its gain x the frozen Fade amount and its track chain (or the
 * whole-track print where the live rig prints one); optionally the All tracks
 * chain (Mix FX). Never live inputs, monitors, click, output buses, output FX
 * or the master. Hosted plugins render dry and are reported in the plan.
 *
 * LIFECYCLE. One job per engine.
 *  - begin (control): measure, freeze the chains and levels, reserve the
 *    job's bytes against the wet cache's cap, post LE_CMD_RENDER_FREEZE.
 *  - freeze (audio thread, engine_process.c): records each source's read law
 *    (clock position at the top of the current iteration, direction, origin,
 *    live slot, length, state, Fade amount, audio revision) into the
 *    engine-owned record, at the next drain — no wait for a loop top.
 *  - staging (control, the cache tick): copies each source lane's frozen slot
 *    in bounded chunks under the cache's copy-at-enqueue gate; a revision
 *    that moves fails the job with LE_ERR_TRACKS_CHANGED.
 *  - rendering (the cache worker): one unit per call — a lane print, a track
 *    print, the state setup, or one slice of the window — interleaved with
 *    the cache's own prints by the worker's priority rule.
 *  - collection (control): DONE / FAILED reach poll; the job lives until
 *    cancel (or the next begin after a terminal state).
 *
 * OWNERSHIP. The job is control-allocated. The worker reaches it only through
 * a_render_runnable while a_render_worker_busy is set (both seq_cst), so a
 * job retired from the control side is freed only once the worker is
 * provably out of it. No audio-thread allocation; the callback only writes
 * the engine-owned freeze record.
 */
#include "engine_render.h"

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_cache.h"    /* le_fx_frozen_*, le_fx_print, reserve/release */
#include "engine_core.h"     /* le_lanes_active, le_effective_state, le_push_cmd */
#include "engine_direction.h" /* le_direction_index, the live read law */
#include "engine_fx.h"       /* fx_apply_chain(_with_gain), state teardown */
#include "engine_wav.h"      /* the one native WAV writer */
#include "segno_engine_api.h"

/* Worker-side progress, published to control. */
enum {
  LE_RW_WAITING = 0,  /* not yet staged */
  LE_RW_RUNNABLE = 1, /* staged; the worker renders it */
  LE_RW_DONE = 2,
  LE_RW_FAILED = 3,
};

typedef struct le_render_lane {
  float* dry;  /* staged frames [0, len) */
  float* pre;  /* the Pre print (2 x len), or NULL */
  float vol, gl, gr;
  le_fx_frozen_chain chain;
  le_fx_state* fx; /* the Post stage, NULL without Post entries */
  int32_t post_bits[LE_FX_MAX];
  int has_pre, has_post;
} le_render_lane;

typedef struct le_render_src {
  int32_t channel, lanes, len, once;
  float gain, fade;
  le_fx_frozen_chain track;
  le_fx_state* tfx;
  int32_t track_bits[LE_FX_MAX];
  int track_has;     /* a real entry on the track chain */
  int track_printed; /* the live rig plays the whole-track print */
  float* tpre;       /* that print (2 x len) */
  int64_t base0;
  int32_t reversed, offset, slot;
  int64_t once_start;
  uint32_t audio_rev;
  int plugin;
  le_render_lane lane[LE_MAX_LANES];
} le_render_src;

struct le_render_job {
  uint32_t id;
  le_render_request req;
  char* path;
  char* part_path;
  le_render_plan plan;
  int32_t frames, sample_rate, cap, passes;
  uint64_t i_ref; /* the iteration the freeze landed in */
  int32_t nsrc;
  le_render_src src[LE_MAX_TRACKS];
  le_fx_frozen_chain mix;
  le_fx_state* mixfx;
  int32_t mix_bits[LE_FX_MAX];
  int mix_on;
  int64_t charged;
  /* control */
  int32_t state; /* le_render_state */
  int32_t result;
  int32_t stage_src, stage_lane, stage_pos;
  /* worker */
  _Atomic int32_t a_work;
  _Atomic int32_t a_result;
  _Atomic int32_t a_permille;
  _Atomic int32_t a_cancel;
  int32_t unit;   /* setup units done */
  int32_t units;  /* setup units in all */
  int32_t pass;
  int32_t pos;
  float* out;     /* memory: 2 x frames; file: 2 x slice */
  le_wav_writer wav;
  int wav_open;
};

/* ---- small helpers ---- */

static uint64_t le_render_gcd(uint64_t a, uint64_t b) {
  while (b != 0) {
    const uint64_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

static int64_t le_render_mod(int64_t v, int64_t m) {
  v %= m;
  return v < 0 ? v + m : v;
}

static float le_render_tempo(le_engine* e) {
  return bits_to_f32(
      atomic_load_explicit(&e->a_tempo_bpm_bits, memory_order_acquire));
}

static int le_render_engine_ok(le_engine* e) {
  return e != NULL &&
         atomic_load_explicit(&e->a_configured, memory_order_acquire);
}

/* ---- measure ---- */

/* The verdict and plan. *lens receives each selected source's length. */
static int32_t le_render_measure_impl(le_engine* e, const le_render_request* q,
                                      le_render_plan* plan,
                                      int32_t lens[LE_MAX_TRACKS]) {
  memset(plan, 0, sizeof(*plan));
  if (q == NULL) return LE_ERR_INVALID;
  const uint32_t all =
      e->track_count >= 32 ? 0xffffffffu : ((1u << e->track_count) - 1u);
  if (q->source_mask == 0 || (q->source_mask & ~all)) return LE_ERR_INVALID;
  if (q->tails != LE_RENDER_WRAP && q->tails != LE_RENDER_CUT) {
    return LE_ERR_INVALID;
  }
  if (q->target != LE_RENDER_TARGET_MEMORY &&
      q->target != LE_RENDER_TARGET_FILE) {
    return LE_ERR_INVALID;
  }
  if (q->target == LE_RENDER_TARGET_FILE &&
      (q->path == NULL || q->path[0] == '\0')) {
    return LE_ERR_INVALID;
  }
  if (q->length_bars < 0 || q->max_frames < 0) return LE_ERR_INVALID;
  const int32_t sr = e->sample_rate;
  const float bpm = le_render_tempo(e);
  const int tempo_set = bpm > 0.0f;
  plan->tempo_set = tempo_set;
  /* The cap: 1024 beats at the tempo, or 512 seconds without one. */
  const uint64_t cap = tempo_set
      ? (uint64_t)floor(1024.0 * 60.0 * (double)sr / (double)bpm)
      : (uint64_t)512 * (uint64_t)sr;
  uint64_t cycle = 1;
  int lcm_ok = 1;
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (!(q->source_mask & (1u << t))) continue;
    le_track* tr = &e->tracks[t];
    const int32_t st = le_effective_state(tr);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
        atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire)) {
      return LE_ERR_NOT_READY;
    }
    const int32_t len = load_i32(&tr->lanes[0].a_len);
    if (st == LE_TRACK_EMPTY || len <= 0) return LE_ERR_INVALID;
    lens[t] = len;
    if (lcm_ok) {
      cycle = cycle / le_render_gcd(cycle, (uint64_t)len) * (uint64_t)len;
      if (cycle > cap) lcm_ok = 0; /* also guards the next multiply */
    }
    /* Plugins render dry; name the tracks that hold one. */
    le_fx_frozen_chain chain;
    int plugin = 0;
    for (int32_t l = 0; l < le_lanes_active(tr) && !plugin; ++l) {
      LE_FX_FROZEN_CAPTURE(&chain, &tr->lanes[l]);
      plugin = le_fx_frozen_has(&chain, 0, chain.count, LE_FX_PLUGIN);
    }
    if (!plugin) {
      LE_FX_FROZEN_CAPTURE(&chain, &tr->bus);
      plugin = le_fx_frozen_has(&chain, 0, chain.count, LE_FX_PLUGIN);
    }
    if (plugin) plan->plugin_mask |= 1u << t;
    if (bits_to_f32(atomic_load_explicit(&tr->a_fade_amount,
                                         memory_order_seq_cst)) < 1.0f) {
      plan->faded_mask |= 1u << t;
    }
  }
  int64_t frames;
  if (q->length_bars > 0) {
    if (!tempo_set) return LE_ERR_INVALID; /* no bars without a tempo */
    int32_t num = load_i32(&e->a_ts_num);
    if (num < 1) num = 4;
    int32_t bars = q->length_bars;
    if (bars > 1024 / num) bars = 1024 / num; /* the policy's clamp */
    if (bars < 1) bars = 1;
    frames = (int64_t)llround((double)bars * num * 60.0 * sr / bpm);
    plan->method = LE_RENDER_CHOSEN_LENGTH;
  } else {
    if (!lcm_ok) return LE_ERR_NO_COMMON_CYCLE;
    frames = (int64_t)cycle;
    plan->method = LE_RENDER_COMMON_CYCLE;
  }
  if (frames <= 0 || frames > INT32_MAX / 2) return LE_ERR_CAPACITY;
  plan->frames = (int32_t)frames;
  if (tempo_set) {
    plan->beats_milli =
        (int32_t)llround((double)frames * bpm * 1000.0 / (60.0 * sr));
  }
  if (q->max_frames > 0 && frames > q->max_frames) return LE_ERR_CAPACITY;
  return LE_OK;
}

int32_t le_engine_render_measure(le_engine* engine,
                                 const le_render_request* request,
                                 le_render_plan* plan) {
  if (engine == NULL || plan == NULL) return LE_ERR_INVALID;
  if (!le_render_engine_ok(engine)) return LE_ERR_NOT_RUNNING;
  int32_t lens[LE_MAX_TRACKS];
  return le_render_measure_impl(engine, request, plan, lens);
}

/* ---- job lifetime ---- */

static void le_render_free_buffers(le_render_job* j) {
  for (int32_t i = 0; i < j->nsrc; ++i) {
    le_render_src* s = &j->src[i];
    for (int32_t l = 0; l < s->lanes; ++l) {
      le_render_lane* ln = &s->lane[l];
      free(ln->dry);
      free(ln->pre);
      ln->dry = ln->pre = NULL;
      if (ln->fx != NULL) {
        le_fx_state_free_buffers(ln->fx);
        free(ln->fx);
        ln->fx = NULL;
      }
    }
    free(s->tpre);
    s->tpre = NULL;
    if (s->tfx != NULL) {
      le_fx_state_free_buffers(s->tfx);
      free(s->tfx);
      s->tfx = NULL;
    }
  }
  if (j->mixfx != NULL) {
    le_fx_state_free_buffers(j->mixfx);
    free(j->mixfx);
    j->mixfx = NULL;
  }
  free(j->out);
  j->out = NULL;
  if (j->wav_open) {
    le_wav_abandon(&j->wav);
    j->wav_open = 0;
    if (j->part_path != NULL) remove(j->part_path);
  }
}

static void le_render_free_job(le_engine* e, le_render_job* j) {
  if (j == NULL) return;
  le_render_free_buffers(j);
  if (j->charged > 0) le_cache_release(e, j->charged);
  free(j->path);
  free(j->part_path);
  free(j);
}

/* Frees a retired job once the worker is provably out of it. */
static void le_render_sweep_retired(le_engine* e) {
  if (e->render_retired == NULL) return;
  if (atomic_load_explicit(&e->a_render_worker_busy, memory_order_seq_cst)) {
    return;
  }
  le_render_free_job(e, e->render_retired);
  e->render_retired = NULL;
}

/* Detaches the current job from the worker and retires it. */
static void le_render_retire(le_engine* e) {
  le_render_job* j = e->render_job;
  if (j == NULL) return;
  atomic_store_explicit(&j->a_cancel, 1, memory_order_seq_cst);
  atomic_store_explicit(&e->a_render_runnable, NULL, memory_order_seq_cst);
  e->render_job = NULL;
  if (e->render_retired != NULL) {
    /* At most one retired job at a time: the previous one waits for the
     * worker exactly like this one. */
    while (atomic_load_explicit(&e->a_render_worker_busy,
                                memory_order_seq_cst)) {
    }
    le_render_free_job(e, e->render_retired);
  }
  e->render_retired = j;
  le_render_sweep_retired(e);
}

static void le_render_fail(le_render_job* j, int32_t result) {
  j->state = LE_RENDER_FAILED;
  j->result = result;
}

/* ---- begin ---- */

static int64_t le_render_job_bytes(const le_render_job* j) {
  int64_t bytes = 0;
  for (int32_t i = 0; i < j->nsrc; ++i) {
    const le_render_src* s = &j->src[i];
    const int64_t len = s->len;
    for (int32_t l = 0; l < s->lanes; ++l) {
      bytes += len * 4;                               /* staged dry */
      if (s->lane[l].has_pre) bytes += 2 * len * 4;   /* Pre print */
    }
    if (s->track_printed) bytes += 4 * len * 4; /* assembly + track print */
  }
  bytes += j->req.target == LE_RENDER_TARGET_MEMORY
               ? 2ll * j->frames * 4
               : 2ll * LE_RENDER_SLICE_FRAMES * 4;
  return bytes;
}

int32_t le_engine_render_begin(le_engine* engine,
                               const le_render_request* request,
                               uint32_t* job) {
  if (engine == NULL || request == NULL || job == NULL) return LE_ERR_INVALID;
  if (!le_render_engine_ok(engine)) return LE_ERR_NOT_RUNNING;
  le_render_sweep_retired(engine);
  if (engine->render_job != NULL) {
    if (engine->render_job->state != LE_RENDER_DONE &&
        engine->render_job->state != LE_RENDER_FAILED) {
      return LE_ERR_ALREADY_RUNNING;
    }
    le_render_retire(engine); /* a finished job gives way to a new one */
  }
  if (engine->cache == NULL) return LE_ERR_UNSUPPORTED;
  le_engine_drain_events(engine);
  int32_t lens[LE_MAX_TRACKS];
  le_render_plan plan;
  const int32_t verdict = le_render_measure_impl(engine, request, &plan, lens);
  if (verdict != LE_OK) return verdict;

  le_render_job* j = (le_render_job*)calloc(1, sizeof(le_render_job));
  if (j == NULL) return LE_ERR_CAPACITY;
  j->req = *request;
  j->plan = plan;
  j->frames = plan.frames;
  j->sample_rate = engine->sample_rate;
  j->cap = engine->fx_delay_frames;
  j->passes = request->tails == LE_RENDER_WRAP ? 2 : 1;
  if (request->target == LE_RENDER_TARGET_FILE) {
    const size_t n = strlen(request->path);
    j->path = (char*)malloc(n + 1);
    j->part_path = (char*)malloc(n + 6);
    if (j->path == NULL || j->part_path == NULL) {
      le_render_free_job(engine, j);
      return LE_ERR_CAPACITY;
    }
    memcpy(j->path, request->path, n + 1);
    snprintf(j->part_path, n + 6, "%s.part", request->path);
    j->req.path = j->path;
  }
  /* Freeze what the control thread owns: chains, levels, pans, gains. The
   * callback freezes the read law; staging freezes the PCM. */
  for (int32_t t = 0; t < engine->track_count; ++t) {
    if (!(request->source_mask & (1u << t))) continue;
    le_track* tr = &engine->tracks[t];
    le_render_src* s = &j->src[j->nsrc++];
    s->channel = t;
    s->len = lens[t];
    s->lanes = le_lanes_active(tr);
    s->once = load_i32(&tr->a_one_shot) != 0;
    s->gain = load_f32(&tr->a_gain_bits);
    int lanes_post = 0;
    for (int32_t l = 0; l < s->lanes; ++l) {
      le_lane* src = &tr->lanes[l];
      le_render_lane* ln = &s->lane[l];
      LE_FX_FROZEN_CAPTURE(&ln->chain, src);
      ln->vol = load_f32(&src->a_vol_bits);
      ln->gl = load_f32(&src->a_pan_gl_bits);
      ln->gr = load_f32(&src->a_pan_gr_bits);
      ln->has_pre = le_fx_frozen_has(&ln->chain, 0, ln->chain.pre, LE_FX_NONE);
      ln->has_post = le_fx_frozen_has(&ln->chain, ln->chain.pre,
                                      ln->chain.count, LE_FX_NONE);
      le_fx_frozen_bits(&ln->chain, ln->chain.pre, ln->chain.count,
                        ln->post_bits);
      lanes_post |= ln->has_post;
      if (le_fx_frozen_has(&ln->chain, 0, ln->chain.count, LE_FX_PLUGIN)) {
        s->plugin = 1;
      }
    }
    LE_FX_FROZEN_CAPTURE(&s->track, &tr->bus);
    s->track_has = le_fx_frozen_has(&s->track, 0, s->track.count, LE_FX_NONE);
    /* The live rig plays the whole-track print only while every part is
     * wholly Pre (slice 3e); otherwise the track chain runs live. */
    s->track_printed =
        !lanes_post &&
        le_fx_frozen_has(&s->track, 0, s->track.pre, LE_FX_NONE);
    le_fx_frozen_bits(&s->track, s->track_printed ? s->track.pre : 0,
                      s->track.count, s->track_bits);
  }
  if (request->mix_fx) {
    LE_FX_FROZEN_CAPTURE(&j->mix, &engine->all_tracks);
    j->mix.pre = 0;
    j->mix_on = le_fx_frozen_has(&j->mix, 0, j->mix.count, LE_FX_NONE);
    le_fx_frozen_bits(&j->mix, 0, j->mix.count, j->mix_bits);
  }
  /* Setup units: one per lane print, one per track print, one for the states. */
  for (int32_t i = 0; i < j->nsrc; ++i) {
    for (int32_t l = 0; l < j->src[i].lanes; ++l) {
      j->units += j->src[i].lane[l].has_pre;
    }
    j->units += j->src[i].track_printed;
  }
  j->units += 1;

  const int64_t bytes = le_render_job_bytes(j);
  if (!le_cache_reserve(engine, bytes)) {
    le_render_free_job(engine, j);
    return LE_ERR_CAPACITY;
  }
  j->charged = bytes;

  uint32_t id = ++engine->render_next_id;
  if (id == 0) id = ++engine->render_next_id;
  j->id = id;
  atomic_store_explicit(&engine->render_freeze.a_id, id, memory_order_release);
  const int32_t rc = le_push_cmd(
      engine, (le_command){.code = LE_CMD_RENDER_FREEZE,
                           .render_freeze = {&engine->render_freeze, id,
                                             request->source_mask}});
  if (rc != LE_OK) {
    atomic_store_explicit(&engine->render_freeze.a_id, 0, memory_order_release);
    le_render_free_job(engine, j);
    return rc;
  }
  j->state = LE_RENDER_FREEZING;
  engine->render_job = j;
  *job = id;
  return LE_OK;
}

/* ---- control heartbeat: freeze, staging, collection ---- */

static void le_render_after_freeze(le_engine* e, le_render_job* j) {
  const le_render_freeze* fz = &e->render_freeze;
  j->i_ref = fz->i_ref;
  for (int32_t i = 0; i < j->nsrc; ++i) {
    le_render_src* s = &j->src[i];
    const le_render_freeze_src* f = &fz->src[s->channel];
    if (f->state == LE_TRACK_RECORDING || f->state == LE_TRACK_OVERDUBBING ||
        f->state == LE_TRACK_EMPTY || f->len != s->len) {
      le_render_fail(j, LE_ERR_TRACKS_CHANGED);
      return;
    }
    s->base0 = f->base0;
    s->reversed = f->reversed;
    s->offset = f->offset;
    s->slot = f->slot;
    s->fade = f->fade;
    s->audio_rev = f->audio_rev;
    /* A Once source's single pass starts at the first window frame its law
     * reads the lap start; the pass wraps around the window end. */
    s->once_start =
        s->reversed ? le_render_mod((int64_t)s->offset - s->base0, s->len)
                    : le_render_mod(-(s->base0 + s->offset), s->len);
    for (int32_t l = 0; l < s->lanes; ++l) {
      s->lane[l].dry = (float*)calloc((size_t)s->len, sizeof(float));
      if (s->lane[l].dry == NULL) {
        le_render_fail(j, LE_ERR_CAPACITY);
        return;
      }
    }
  }
  j->state = LE_RENDER_STAGING;
}

static void le_render_stage(le_engine* e, le_render_job* j) {
  while (j->stage_src < j->nsrc) {
    le_render_src* s = &j->src[j->stage_src];
    le_track* tr = &e->tracks[s->channel];
    /* A moved revision fails at once; it must not wait on a readable gate
     * that a cleared or recording track never opens again. */
    if (atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) !=
            s->audio_rev ||
        load_i32(&tr->lanes[0].a_live) != s->slot) {
      le_render_fail(j, LE_ERR_TRACKS_CHANGED);
      return;
    }
    const int32_t st = le_effective_state(tr);
    if (st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) {
      le_render_fail(j, LE_ERR_TRACKS_CHANGED);
      return;
    }
    if (!le_cache_source_ready(e, s->channel)) return; /* next tick */
    if (j->stage_lane >= s->lanes) {
      j->stage_src++;
      j->stage_lane = 0;
      j->stage_pos = 0;
      continue;
    }
    le_lane* ln = &tr->lanes[j->stage_lane];
    const float* pcm = ln->pool[s->slot];
    int32_t n = s->len - j->stage_pos;
    if (n > LE_RENDER_COPY_CHUNK_FRAMES) n = LE_RENDER_COPY_CHUNK_FRAMES;
    if (pcm != NULL) {
      if (ln->pool_cap[s->slot] < s->len) {
        le_render_fail(j, LE_ERR_TRACKS_CHANGED);
        return;
      }
      memcpy(s->lane[j->stage_lane].dry + j->stage_pos, pcm + j->stage_pos,
             (size_t)n * sizeof(float));
    } /* a lane with no buffer plays silence: the calloc'd zeros */
    j->stage_pos += n;
    if (j->stage_pos >= s->len) {
      j->stage_lane++;
      j->stage_pos = 0;
    }
    return; /* one bounded chunk per heartbeat */
  }
  /* Completion: the content key must still be what was frozen. */
  atomic_thread_fence(memory_order_acquire);
  for (int32_t i = 0; i < j->nsrc; ++i) {
    if (atomic_load_explicit(&e->tracks[j->src[i].channel].a_audio_rev,
                             memory_order_acquire) != j->src[i].audio_rev) {
      le_render_fail(j, LE_ERR_TRACKS_CHANGED);
      return;
    }
  }
  j->state = LE_RENDER_RENDERING;
  atomic_store_explicit(&j->a_work, LE_RW_RUNNABLE, memory_order_release);
  atomic_store_explicit(&e->a_render_runnable, j, memory_order_seq_cst);
}

void le_render_tick(le_engine* engine) {
  if (engine == NULL) return;
  le_render_sweep_retired(engine);
  le_render_job* j = engine->render_job;
  if (j == NULL) return;
  if (j->state == LE_RENDER_FREEZING &&
      atomic_load_explicit(&engine->render_freeze.a_done,
                           memory_order_acquire) == j->id) {
    le_render_after_freeze(engine, j);
  }
  if (j->state == LE_RENDER_STAGING) le_render_stage(engine, j);
  if (j->state == LE_RENDER_RENDERING) {
    const int32_t w = atomic_load_explicit(&j->a_work, memory_order_acquire);
    if (w == LE_RW_DONE || w == LE_RW_FAILED) {
      atomic_store_explicit(&engine->a_render_runnable, NULL,
                            memory_order_seq_cst);
      if (w == LE_RW_DONE) {
        j->state = LE_RENDER_DONE;
      } else {
        le_render_fail(j, atomic_load_explicit(&j->a_result,
                                               memory_order_acquire));
      }
    }
  }
  if (j->state == LE_RENDER_FAILED && j->charged > 0) {
    /* A failed job keeps only its verdict; wait for the worker before the
     * buffers go. */
    if (!atomic_load_explicit(&engine->a_render_worker_busy,
                              memory_order_seq_cst) &&
        atomic_load_explicit(&engine->a_render_runnable,
                             memory_order_seq_cst) == NULL) {
      le_render_free_buffers(j);
      le_cache_release(engine, j->charged);
      j->charged = 0;
    }
  }
}

int32_t le_engine_render_poll(le_engine* engine, uint32_t job, int32_t* state,
                              int32_t* permille, int32_t* result) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (le_render_engine_ok(engine)) le_engine_drain_events(engine);
  le_render_job* j = engine->render_job;
  if (j == NULL || j->id != job) return LE_ERR_INVALID;
  if (engine->cache == NULL) le_render_tick(engine); /* no worker heartbeat */
  if (state != NULL) *state = j->state;
  if (permille != NULL) {
    *permille = j->state == LE_RENDER_DONE
                    ? 1000
                    : atomic_load_explicit(&j->a_permille,
                                           memory_order_relaxed);
  }
  if (result != NULL) *result = j->state == LE_RENDER_FAILED ? j->result : LE_OK;
  return LE_OK;
}

int32_t le_engine_render_copy(le_engine* engine, uint32_t job, float* out,
                              int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames < 0) return LE_ERR_INVALID;
  le_render_job* j = engine->render_job;
  if (j == NULL || j->id != job ||
      j->req.target != LE_RENDER_TARGET_MEMORY) {
    return LE_ERR_INVALID;
  }
  if (j->state != LE_RENDER_DONE || j->out == NULL) return LE_ERR_NOT_READY;
  const int32_t n = max_frames < j->frames ? max_frames : j->frames;
  memcpy(out, j->out, (size_t)n * 2 * sizeof(float));
  return n;
}

int32_t le_engine_render_cancel(le_engine* engine, uint32_t job) {
  if (engine == NULL) return LE_ERR_INVALID;
  le_render_job* j = engine->render_job;
  if (j == NULL || j->id != job) return LE_ERR_INVALID;
  le_render_retire(engine);
  return LE_OK;
}

void le_render_on_cache_shutdown(le_engine* engine) {
  le_render_job* j = engine->render_job;
  /* The worker is joined: nothing holds a job. */
  atomic_store_explicit(&engine->a_render_runnable, NULL, memory_order_seq_cst);
  le_render_free_job(engine, engine->render_retired);
  engine->render_retired = NULL;
  if (j == NULL) return;
  if (j->state != LE_RENDER_DONE && j->state != LE_RENDER_FAILED) {
    le_render_fail(j, LE_ERR_DEVICE);
  }
  if (j->state == LE_RENDER_FAILED) le_render_free_buffers(j);
  /* The books this job was charged to are being freed with the cache. */
  if (j->charged > 0) le_cache_release(engine, j->charged);
  j->charged = 0;
}

int32_t le_render_take(le_engine* engine, uint32_t job, const float** stereo,
                       int32_t* frames, uint64_t* i_ref) {
  le_render_job* j = engine->render_job;
  if (j == NULL || j->id != job || j->req.target != LE_RENDER_TARGET_MEMORY ||
      j->state != LE_RENDER_DONE || j->out == NULL) {
    return LE_ERR_NOT_READY;
  }
  for (int32_t i = 0; i < j->nsrc; ++i) {
    if (atomic_load_explicit(&engine->tracks[j->src[i].channel].a_audio_rev,
                             memory_order_acquire) != j->src[i].audio_rev) {
      return LE_ERR_TRACKS_CHANGED;
    }
  }
  *stereo = j->out;
  *frames = j->frames;
  *i_ref = j->i_ref;
  return LE_OK;
}

void le_render_destroy(le_engine* engine) {
  if (engine == NULL) return;
  le_render_free_job(engine, engine->render_job);
  le_render_free_job(engine, engine->render_retired);
  engine->render_job = NULL;
  engine->render_retired = NULL;
}

/* ---- the worker ---- */

static int le_render_cancelled(void* arg) {
  const le_render_job* j = (const le_render_job*)arg;
  return atomic_load_explicit(&j->a_cancel, memory_order_acquire);
}

static void le_render_worker_fail(le_render_job* j, int32_t result) {
  atomic_store_explicit(&j->a_result, result, memory_order_relaxed);
  atomic_store_explicit(&j->a_work, LE_RW_FAILED, memory_order_release);
}

/* One setup unit: the next lane print, the next track print, or the states. */
static void le_render_setup_unit(le_render_job* j) {
  int32_t k = 0;
  for (int32_t i = 0; i < j->nsrc; ++i) {
    le_render_src* s = &j->src[i];
    for (int32_t l = 0; l < s->lanes; ++l) {
      le_render_lane* ln = &s->lane[l];
      if (!ln->has_pre) continue;
      if (k++ != j->unit) continue;
      /* The lane's take: the cache's own print of its Pre entries over
       * dry x level, wrapped at the lane's length (plan 4.3). */
      ln->pre = (float*)malloc((size_t)s->len * 2 * sizeof(float));
      const int32_t rc =
          ln->pre == NULL
              ? LE_ERR_INVALID
              : le_fx_print(&ln->chain, ln->chain.pre, ln->dry, 0, ln->vol,
                            s->len, j->sample_rate, j->cap, ln->pre,
                            le_render_cancelled, j);
      if (rc != LE_OK) le_render_worker_fail(j, rc);
      return;
    }
    if (!s->track_printed) continue;
    if (k++ != j->unit) continue;
    /* The whole-track print over the parts' printed material at their
     * levels and pans (the cache's track job, without the live gates). */
    float* src = (float*)calloc((size_t)s->len * 2, sizeof(float));
    s->tpre = (float*)malloc((size_t)s->len * 2 * sizeof(float));
    int32_t rc = LE_ERR_INVALID;
    if (src != NULL && s->tpre != NULL) {
      for (int32_t l = 0; l < s->lanes; ++l) {
        const le_render_lane* ln = &s->lane[l];
        for (int32_t f = 0; f < s->len; ++f) {
          const float a = ln->pre ? ln->pre[2 * f] : ln->dry[f] * ln->vol;
          const float b = ln->pre ? ln->pre[2 * f + 1] : ln->dry[f] * ln->vol;
          src[2 * f] += a * ln->gl;
          src[2 * f + 1] += b * ln->gr;
        }
      }
      rc = le_fx_print(&s->track, s->track.pre, src, 1, 1.0f, s->len,
                       j->sample_rate, j->cap, s->tpre, le_render_cancelled,
                       j);
    }
    free(src);
    if (rc != LE_OK) le_render_worker_fail(j, rc);
    return;
  }
  /* The last unit: the window stages' states and the output. */
  for (int32_t i = 0; i < j->nsrc; ++i) {
    le_render_src* s = &j->src[i];
    for (int32_t l = 0; l < s->lanes && !s->track_printed; ++l) {
      le_render_lane* ln = &s->lane[l];
      if (!ln->has_post) continue;
      ln->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
      if (ln->fx == NULL ||
          le_fx_frozen_state_init(ln->fx, &ln->chain, ln->chain.pre,
                                  ln->chain.count, j->cap) != LE_OK) {
        le_render_worker_fail(j, LE_ERR_INVALID);
        return;
      }
    }
    if (s->track_has) {
      s->tfx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
      if (s->tfx == NULL ||
          le_fx_frozen_state_init(s->tfx, &s->track,
                                  s->track_printed ? s->track.pre : 0,
                                  s->track.count, j->cap) != LE_OK) {
        le_render_worker_fail(j, LE_ERR_INVALID);
        return;
      }
    }
  }
  if (j->mix_on) {
    j->mixfx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
    if (j->mixfx == NULL ||
        le_fx_frozen_state_init(j->mixfx, &j->mix, 0, j->mix.count, j->cap) !=
            LE_OK) {
      le_render_worker_fail(j, LE_ERR_INVALID);
      return;
    }
  }
  const size_t out_frames = j->req.target == LE_RENDER_TARGET_MEMORY
                                ? (size_t)j->frames
                                : (size_t)LE_RENDER_SLICE_FRAMES;
  j->out = (float*)calloc(out_frames * 2, sizeof(float));
  if (j->out == NULL) {
    le_render_worker_fail(j, LE_ERR_CAPACITY);
    return;
  }
  if (j->req.target == LE_RENDER_TARGET_FILE) {
    j->wav_open = 1;
    if (!le_wav_open(&j->wav, j->part_path, j->sample_rate, 2, NULL, NULL, 0)) {
      le_render_worker_fail(j, LE_ERR_DEVICE);
    }
  }
}

/* Renders window frames [from, from + n) into out (interleaved stereo). */
static void le_render_window(le_render_job* j, int32_t from, int32_t n,
                             float* out) {
  const int32_t sr = j->sample_rate;
  const int32_t cap = j->cap;
  for (int32_t k = 0; k < n; ++k) {
    const int64_t f = (int64_t)from + k;
    float ml = 0.0f;
    float mr = 0.0f;
    for (int32_t i = 0; i < j->nsrc; ++i) {
      le_render_src* s = &j->src[i];
      const int32_t idx =
          le_direction_index(s->reversed, s->offset, s->base0 + f, s->len);
      const int sounding =
          !s->once || le_render_mod(f - s->once_start, j->frames) < s->len;
      const float g = s->gain * s->fade;
      float tl = 0.0f;
      float tr = 0.0f;
      if (s->track_printed) {
        if (sounding) {
          tl = s->tpre[2 * idx];
          tr = s->tpre[2 * idx + 1];
        }
      } else {
        for (int32_t l = 0; l < s->lanes; ++l) {
          le_render_lane* ln = &s->lane[l];
          float a = 0.0f;
          float b = 0.0f;
          if (sounding) {
            if (ln->pre != NULL) {
              a = ln->pre[2 * idx];
              b = ln->pre[2 * idx + 1];
            } else {
              a = ln->dry[idx] * ln->vol;
              b = a;
            }
          }
          if (ln->fx != NULL) {
            fx_apply_chain(ln->fx, sr, cap, &a, &b, ln->chain.count,
                           ln->chain.type, ln->chain.params, ln->post_bits);
          }
          a *= ln->gl;
          b *= ln->gr;
          if (!s->track_has) {
            /* The live order: lane pan, then gain x Fade, per lane. */
            a *= g;
            b *= g;
          }
          tl += a;
          tr += b;
        }
      }
      if (s->track_has) {
        fx_apply_chain_with_gain(s->tfx, sr, cap, &tl, &tr, s->track.count,
                                 s->track.type, s->track.params, s->track_bits,
                                 s->track.pre, g);
      } else if (s->track_printed) {
        tl *= g;
        tr *= g;
      }
      ml += tl;
      mr += tr;
    }
    if (j->mixfx != NULL) {
      fx_apply_chain(j->mixfx, sr, cap, &ml, &mr, j->mix.count, j->mix.type,
                     j->mix.params, j->mix_bits);
    }
    out[2 * k] = ml;
    out[2 * k + 1] = mr;
  }
}

static void le_render_progress(le_render_job* j) {
  const double total =
      (double)j->units + (double)j->passes * (double)j->frames / LE_RENDER_SLICE_FRAMES;
  const double done = (double)j->unit + ((double)j->pass * j->frames + j->pos) /
                                            LE_RENDER_SLICE_FRAMES;
  int32_t pm = total > 0 ? (int32_t)(done * 1000.0 / total) : 0;
  if (pm > 999) pm = 999;
  atomic_store_explicit(&j->a_permille, pm, memory_order_relaxed);
}

static void le_render_unit(le_render_job* j) {
  if (atomic_load_explicit(&j->a_cancel, memory_order_acquire)) {
    le_render_worker_fail(j, LE_ERR_INVALID);
    return;
  }
  if (j->unit < j->units) {
    le_render_setup_unit(j);
    if (atomic_load_explicit(&j->a_work, memory_order_relaxed) ==
        LE_RW_RUNNABLE) {
      j->unit++;
      le_render_progress(j);
    }
    return;
  }
  int32_t n = j->frames - j->pos;
  if (n > LE_RENDER_SLICE_FRAMES) n = LE_RENDER_SLICE_FRAMES;
  const int last = j->pass == j->passes - 1;
  float* dst = j->req.target == LE_RENDER_TARGET_MEMORY
                   ? j->out + 2 * (size_t)j->pos
                   : j->out;
  le_render_window(j, j->pos, n, dst);
  if (last && j->req.target == LE_RENDER_TARGET_FILE &&
      !le_wav_append(&j->wav, j->out, (uint64_t)n)) {
    le_render_worker_fail(j, LE_ERR_DEVICE);
    return;
  }
  j->pos += n;
  if (j->pos >= j->frames) {
    j->pos = 0;
    j->pass++;
  }
  le_render_progress(j);
  if (j->pass < j->passes) return;
  if (j->req.target == LE_RENDER_TARGET_FILE) {
    j->wav_open = 0;
    if (!le_wav_seal(&j->wav, 1) || !le_wav_publish(j->part_path, j->path)) {
      remove(j->part_path);
      le_render_worker_fail(j, LE_ERR_DEVICE);
      return;
    }
  }
  atomic_store_explicit(&j->a_work, LE_RW_DONE, memory_order_release);
}

int le_render_worker_choice(int audible_print, int recipe, int* yields) {
  if (!recipe) return 0;
  if (!audible_print || *yields >= LE_RENDER_MAX_YIELDS) {
    *yields = 0;
    return 1;
  }
  ++*yields;
  return 0;
}

int le_render_worker_ready(le_engine* engine) {
  atomic_store_explicit(&engine->a_render_worker_busy, 1, memory_order_seq_cst);
  le_render_job* j =
      atomic_load_explicit(&engine->a_render_runnable, memory_order_seq_cst);
  const int ready =
      j != NULL &&
      atomic_load_explicit(&j->a_work, memory_order_acquire) == LE_RW_RUNNABLE;
  atomic_store_explicit(&engine->a_render_worker_busy, 0, memory_order_seq_cst);
  return ready;
}

void le_render_worker_step(le_engine* engine) {
  atomic_store_explicit(&engine->a_render_worker_busy, 1, memory_order_seq_cst);
  le_render_job* j =
      atomic_load_explicit(&engine->a_render_runnable, memory_order_seq_cst);
  if (j != NULL &&
      atomic_load_explicit(&j->a_work, memory_order_acquire) == LE_RW_RUNNABLE) {
    le_render_unit(j);
  }
  atomic_store_explicit(&engine->a_render_worker_busy, 0, memory_order_seq_cst);
}
