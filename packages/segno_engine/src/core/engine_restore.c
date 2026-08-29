/*
 * engine_restore.c — the offline loop-close restoration worker (#697 S9).
 *
 * A second background worker, mirroring engine_cache.c's [R2] thread-ownership
 * contract, that repairs a track's captured lanes after a loop closes and
 * publishes the result as one lockstep undo layer — so the raw take stays one
 * le_engine_undo away and the RT audio thread is untouched by construction.
 *
 * THREAD OWNERSHIP — the [R2] contract, adapted to a single job engine-wide:
 *  (a) Lane PCM handoff is COPY-AT-ENQUEUE: le_engine_restore_track allocates a
 *      per-opted-lane copy buffer and le_restore_tick (CONTROL thread) copies
 *      pool[a_live] into it, CHUNKED across ticks so the UI-poll drain path
 *      never stalls behind one giant memcpy, tagged with the a_audio_rev it
 *      copied under and re-checked at copy completion (seqlock shape). Only the
 *      control thread swaps a_live / reallocs pool slots, so a control-side
 *      copy can never race a pool free; the gate (enqueue-time PLAYING/STOPPED,
 *      no layer in flight) plus the rev re-check discard a copy the moment a
 *      capture starts (OVERDUBBING entry bumps a_audio_rev BEFORE its first
 *      write — the same guarantee the wet cache leans on).
 *  (b) The restored audio is published CONTROL-THREAD-ONLY via
 *      le_restore_commit_layer (engine_commands.c): it re-checks the rev [B5],
 *      acquires a fresh pool slot, fills it (restored PCM for opted lanes, a
 *      plain copy of the live buffer for the rest), pushes the pre-restoration
 *      live slot as ONE lockstep undo layer, and swaps a_live via
 *      le_track_publish_live (which bumps a_audio_rev and re-renders the wet
 *      cache). The audio thread only ever loads a_live once per buffer, so the
 *      atomic swap is the entire handoff — no buffer the audio thread can hold
 *      is ever freed (the old live slot lives on as the undo layer), so unlike
 *      the wet cache this worker needs no graveyard / quiescent window.
 *  (c) Rev-bump abort [B5]: the worker checks a_audio_rev (and shutdown /
 *      cancel) once per lane and aborts on any bump; the commit re-checks it a
 *      final time, so a take that moved mid-restore is discarded, never
 *      published.
 *  (d) Join-before-free: le_restore_shutdown joins the worker and is called
 *      from le_engine_stop, the top of le_engine_configure, and
 *      le_engine_destroy BEFORE any pool free.
 *
 * The single job is an SPSC state machine (control: EMPTY -> COPYING -> QUEUED
 * and *->EMPTY; worker: QUEUED -> RUNNING -> DONE/ABORTED), so no mutex exists
 * and the audio thread is untouched. One job in flight engine-wide: a second
 * request while busy is refused (LE_ERR_INVALID), matching the plan.
 *
 * Pipeline per opted lane: de-clip (restore_declip.c, full rate) THEN optional
 * RNNoise denoise — clipping is broadband garbage that pollutes RNNoise's
 * spectral features, so the waveform is repaired first. RNNoise is fixed
 * 48 kHz / 480-sample frames: at 48 k it is passthrough, at 96 k the pair
 * decimate 2:1 -> denoise -> interpolate 2:1 (restore_halfband.c), and any
 * other rate skips denoise (de-clip still runs).
 */
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"    /* le_effective_state, le_lanes_active */
#include "engine_private.h" /* le_engine, load/store helpers */
#include "engine_restore.h"
#include "restore_declip.h"  /* le_declip_process + scratch */
#include "restore_halfband.h" /* 2:1 decimate / interpolate (96 k denoise leg) */
#include "rnnoise.h"          /* vendored denoiser */
#include "segno_engine_api.h"

/* ---- portable thread shim (duplicated per TU, matching engine_cache.c) ---- */
#if defined(_WIN32)
#include <windows.h>
typedef HANDLE le_rs_thread_t;
static void le_rs_worker_main(void* arg);
static DWORD WINAPI le_rs_win_trampoline(LPVOID arg) {
  le_rs_worker_main(arg);
  return 0;
}
static int le_rs_thread_start(le_rs_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_rs_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}
static void le_rs_thread_join(le_rs_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}
static void le_rs_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <pthread.h>
#include <time.h>
typedef pthread_t le_rs_thread_t;
static void le_rs_worker_main(void* arg);
static void* le_rs_posix_trampoline(void* arg) {
  le_rs_worker_main(arg);
  return NULL;
}
static int le_rs_thread_start(le_rs_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_rs_posix_trampoline, arg) == 0;
}
static void le_rs_thread_join(le_rs_thread_t th) { pthread_join(th, NULL); }
static void le_rs_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* Copy-at-enqueue chunk size, in frames per tick (~192 KB): bounds the
 * UI-poll drain path's per-call memcpy cost, like the wet cache's own chunk. */
#define LE_RESTORE_COPY_CHUNK_FRAMES 48000

/* RNNoise's fixed frame contract (asserted in the S7 smoke test). */
#define LE_RNNOISE_FRAME 480
/* RNNoise expects 16-bit-scaled floats, not +/-1.0 (see its vendor smoke
 * test): scale in, unscale out. */
#define LE_RNNOISE_SCALE 32768.0f

/* SPSC job lifecycle. Control writes EMPTY->COPYING->QUEUED and *->EMPTY; the
 * worker writes QUEUED->RUNNING->DONE/ABORTED. All transitions release; all
 * cross-thread reads acquire. */
enum {
  LE_RS_EMPTY = 0,
  LE_RS_COPYING = 1,
  LE_RS_QUEUED = 2,
  LE_RS_RUNNING = 3,
  LE_RS_DONE = 4,
  LE_RS_ABORTED = 5,
};

/* The single restoration job. buf[l] is control-allocated at enqueue, filled
 * by the chunked copy, restored IN PLACE by the worker, read by the control
 * commit, and control-freed at collection. Only opted lanes (lane_mask bit set)
 * have a buffer; the rest are NULL and the commit copies their live audio. */
typedef struct le_restore_job {
  _Atomic int32_t a_state;
  _Atomic int32_t a_cancel;
  int32_t channel;
  uint32_t lane_mask;
  uint32_t flags;
  uint32_t audio_rev;
  int32_t len;
  int32_t sample_rate;
  int32_t active_lanes;
  int32_t copy_lane; /* chunked-copy cursor: next lane */
  int32_t copy_pos;  /* chunked-copy cursor: frame within the lane */
  float* buf[LE_MAX_LANES];
} le_restore_job;

struct le_restore {
  le_engine* engine;
  le_restore_job job;
  _Atomic int32_t a_shutdown;
  int worker_started;
  le_rs_thread_t worker;
};

/* ---- DSP pipeline (worker thread) ---- */

/* Denoises `n` 48 kHz samples in place, in 480-sample frames with a zero-padded
 * remainder. `st` is reset (rnnoise_init) by the caller per lane so no history
 * bleeds across lanes. */
static void le_rs_denoise_48k(float* buf, int32_t n, DenoiseState* st) {
  float in[LE_RNNOISE_FRAME];
  float out[LE_RNNOISE_FRAME];
  int32_t i = 0;
  while (i < n) {
    int32_t m = n - i;
    if (m > LE_RNNOISE_FRAME) m = LE_RNNOISE_FRAME;
    for (int32_t k = 0; k < LE_RNNOISE_FRAME; ++k) {
      in[k] = (k < m) ? buf[i + k] * LE_RNNOISE_SCALE : 0.0f;
    }
    rnnoise_process_frame(st, out, in);
    for (int32_t k = 0; k < m; ++k) buf[i + k] = out[k] / LE_RNNOISE_SCALE;
    i += m;
  }
}

/* Denoises `n` 96 kHz samples in place via the exact 2:1 half-band pair:
 * decimate -> 48 k denoise -> interpolate. Allocates two transient buffers;
 * on OOM it leaves the (already de-clipped) signal untouched. */
static void le_rs_denoise_96k(float* buf, int32_t n, DenoiseState* st) {
  const int32_t n48 = (n + 1) / 2;
  float* down = (float*)malloc((size_t)n48 * sizeof(float));
  float* up = (float*)malloc(2u * (size_t)n48 * sizeof(float));
  if (down == NULL || up == NULL) {
    free(down);
    free(up);
    return;
  }
  le_halfband_decimate(buf, (uint32_t)n, down);
  le_rs_denoise_48k(down, n48, st);
  le_halfband_interpolate(down, (uint32_t)n48, up);
  /* 2 * n48 >= n; keep the first n samples (interpolation is group-delay
   * compensated inside the call, so the copy is time-aligned). */
  memcpy(buf, up, (size_t)n * sizeof(float));
  free(down);
  free(up);
}

/* Restores one lane's buffer in place: de-clip (full rate) then optional
 * denoise. `scr` NULL disables de-clip (worker OOM); `st` NULL or an
 * unsupported rate disables denoise. */
static void le_rs_restore_lane(float* buf, int32_t n, int32_t sr, uint32_t flags,
                               le_declip_scratch* scr, DenoiseState* st) {
  if ((flags & LE_RESTORE_DECLIP) && scr != NULL) {
    le_declip_process(buf, (uint32_t)n, 0.999f, scr);
  }
  if ((flags & LE_RESTORE_DENOISE) && st != NULL) {
    rnnoise_init(st, NULL); /* fresh history per lane */
    if (sr == 48000) {
      le_rs_denoise_48k(buf, n, st);
    } else if (sr == 96000) {
      le_rs_denoise_96k(buf, n, st);
    }
    /* other rates: denoise skipped, de-clip already ran (plan §3). */
  }
}

/* ---- worker ---- */

static void le_rs_render(le_engine* e, struct le_restore* r,
                         le_declip_scratch* scr, DenoiseState* st) {
  le_restore_job* j = &r->job;
  atomic_store_explicit(&j->a_state, LE_RS_RUNNING, memory_order_release);
  le_track* tr = &e->tracks[j->channel];
  int aborted = 0;
  for (int32_t l = 0; l < j->active_lanes && !aborted; ++l) {
    if (!(j->lane_mask & (1u << l)) || j->buf[l] == NULL) continue;
    if (atomic_load_explicit(&r->a_shutdown, memory_order_acquire) ||
        atomic_load_explicit(&j->a_cancel, memory_order_acquire) ||
        atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) !=
            j->audio_rev) {
      aborted = 1;
      break;
    }
    le_rs_restore_lane(j->buf[l], j->len, j->sample_rate, j->flags, scr, st);
  }
  atomic_store_explicit(&j->a_state, aborted ? LE_RS_ABORTED : LE_RS_DONE,
                        memory_order_release);
}

static void le_rs_worker_main(void* arg) {
  le_engine* e = (le_engine*)arg;
  struct le_restore* r = e->restore; /* stable: shutdown joins before free */
  /* One scratch + denoise state for the worker's life (the declip scratch is
   * ~33 KB; a per-job alloc would churn). NULL is tolerated downstream. */
  le_declip_scratch* scr = (le_declip_scratch*)malloc(sizeof(le_declip_scratch));
  DenoiseState* st = rnnoise_create(NULL);
  int idle_ms = 1;
  while (!atomic_load_explicit(&r->a_shutdown, memory_order_acquire)) {
    if (atomic_load_explicit(&r->job.a_state, memory_order_acquire) ==
        LE_RS_QUEUED) {
      idle_ms = 1;
      le_rs_render(e, r, scr, st);
      continue;
    }
    le_rs_sleep_ms(idle_ms);
    if (idle_ms < 32) idle_ms *= 2;
  }
  free(scr);
  if (st != NULL) rnnoise_destroy(st);
}

/* ---- control-thread tick ---- */

/* Frees the job's copy buffers and returns the slot to EMPTY (clearing the
 * track's restore telemetry). Shared by the discard, cancel, and collect
 * paths. */
static void le_rs_release_job(le_engine* e, le_restore_job* j) {
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    free(j->buf[l]);
    j->buf[l] = NULL;
  }
  if (j->channel >= 0 && j->channel < e->track_count) {
    store_i32(&e->tracks[j->channel].a_restore_state, 0);
  }
  atomic_store_explicit(&j->a_state, LE_RS_EMPTY, memory_order_release);
}

/* Advances the chunked enqueue copy [R2](a). Re-resolves pool[a_live] on this
 * control thread (the only swapper) per chunk; a rev bump seen at any chunk or
 * at completion discards the job outright. */
static void le_rs_copy_step(le_engine* e, struct le_restore* r) {
  le_restore_job* j = &r->job;
  if (atomic_load_explicit(&j->a_state, memory_order_relaxed) != LE_RS_COPYING) {
    return;
  }
  le_track* tr = &e->tracks[j->channel];
  if (atomic_load_explicit(&j->a_cancel, memory_order_acquire) ||
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) !=
          j->audio_rev) {
    le_rs_release_job(e, j);
    return;
  }
  int32_t budget = LE_RESTORE_COPY_CHUNK_FRAMES;
  while (budget > 0 && j->copy_lane < j->active_lanes) {
    const int32_t l = j->copy_lane;
    if (!(j->lane_mask & (1u << l)) || j->buf[l] == NULL) {
      j->copy_lane++;
      j->copy_pos = 0;
      continue;
    }
    le_lane* ln = &tr->lanes[l];
    const float* src = ln->pool[load_i32(&ln->a_live)];
    if (src == NULL) {
      le_rs_release_job(e, j);
      return;
    }
    int32_t n = j->len - j->copy_pos;
    if (n > budget) n = budget;
    memcpy(j->buf[l] + j->copy_pos, src + j->copy_pos, (size_t)n * sizeof(float));
    j->copy_pos += n;
    budget -= n;
    if (j->copy_pos >= j->len) {
      j->copy_lane++;
      j->copy_pos = 0;
    }
  }
  if (j->copy_lane >= j->active_lanes) {
    /* Completion re-check (the fence orders the copied reads before the
     * revision load — seqlock shape). */
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire) !=
        j->audio_rev) {
      le_rs_release_job(e, j);
      return;
    }
    atomic_store_explicit(&j->a_state, LE_RS_QUEUED, memory_order_release);
  }
}

/* Collects a finished job: publishes a DONE result whose rev still matches
 * [B5] (unless cancelled), then frees the copies and returns the slot to
 * EMPTY. */
static void le_rs_collect(le_engine* e, struct le_restore* r) {
  le_restore_job* j = &r->job;
  const int32_t st = atomic_load_explicit(&j->a_state, memory_order_acquire);
  if (st != LE_RS_DONE && st != LE_RS_ABORTED) return;
  if (st == LE_RS_DONE &&
      !atomic_load_explicit(&j->a_cancel, memory_order_acquire)) {
    float* restored[LE_MAX_LANES] = {0};
    for (int32_t l = 0; l < j->active_lanes; ++l) {
      if (j->lane_mask & (1u << l)) restored[l] = j->buf[l];
    }
    /* Return ignored: the commit re-checks the rev/len itself and declines a
     * moved take — the raw copy is discarded below either way. */
    (void)le_restore_commit_layer(e, j->channel, j->lane_mask, j->audio_rev,
                                  j->len, restored);
  }
  le_rs_release_job(e, j);
}

void le_restore_tick(le_engine* engine) {
  struct le_restore* r = engine->restore;
  if (r == NULL) return;
  le_rs_copy_step(engine, r);
  le_rs_collect(engine, r);
  /* Mirror the live job state into the track's telemetry (0 idle / 1 queued /
   * 2 running); the collect above already cleared a finished job to 0. */
  le_restore_job* j = &r->job;
  const int32_t s = atomic_load_explicit(&j->a_state, memory_order_acquire);
  if (j->channel >= 0 && j->channel < engine->track_count) {
    if (s == LE_RS_RUNNING) {
      store_i32(&engine->tracks[j->channel].a_restore_state, 2);
    } else if (s == LE_RS_COPYING || s == LE_RS_QUEUED) {
      store_i32(&engine->tracks[j->channel].a_restore_state, 1);
    }
  }
}

/* ---- lifecycle ---- */

void le_restore_init(le_engine* engine) {
  if (engine == NULL || engine->restore != NULL) return;
  struct le_restore* r = (struct le_restore*)calloc(1, sizeof(struct le_restore));
  if (r == NULL) return; /* restoration disabled; audio unaffected */
  r->engine = engine;
  r->job.channel = -1;
  engine->restore = r;
  if (!le_rs_thread_start(&r->worker, engine)) {
    engine->restore = NULL;
    free(r);
    return;
  }
  r->worker_started = 1;
}

void le_restore_shutdown(le_engine* engine) {
  if (engine == NULL || engine->restore == NULL) return;
  struct le_restore* r = engine->restore;
  atomic_store_explicit(&r->a_shutdown, 1, memory_order_release);
  if (r->worker_started) le_rs_thread_join(r->worker);
  /* The worker is gone; free any copies the job still owns (a mid-flight
   * shutdown). No published buffer is ever freed here — the old live slot
   * lives on in the lane pool as an undo layer. */
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) free(r->job.buf[l]);
  /* Clear a mid-flight job's telemetry so a later snapshot never reports a
   * restoration still running after this teardown. */
  if (r->job.channel >= 0 && r->job.channel < engine->track_count) {
    store_i32(&engine->tracks[r->job.channel].a_restore_state, 0);
  }
  engine->restore = NULL;
  free(r);
}

/* ---- trigger API (control thread) ---- */

int32_t le_engine_restore_track(le_engine* engine, int32_t channel,
                                uint32_t lane_mask, uint32_t flags) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return LE_ERR_INVALID;
  }
  flags &= (uint32_t)(LE_RESTORE_DECLIP | LE_RESTORE_DENOISE);
  if (flags == 0) return LE_ERR_INVALID; /* no-op when disabled */
  struct le_restore* r = engine->restore;
  if (r == NULL) return LE_ERR_INVALID;

  le_track* tr = &engine->tracks[channel];
  /* Same gate the wet cache's enqueue uses: never while capturing, never with
   * a layer in flight (the punch tail / drain still write the live buffers). */
  const int32_t est = le_effective_state(tr);
  if (est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) return LE_ERR_INVALID;
  if (atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  const int32_t len = load_i32(&tr->lanes[0].a_len);
  if (len <= 0) return LE_ERR_INVALID;

  const int32_t lanes = le_lanes_active(tr);
  const uint32_t active_bits =
      (lanes >= 32) ? 0xffffffffu : ((1u << lanes) - 1u);
  const uint32_t mask = lane_mask & active_bits;
  if (mask == 0) return LE_ERR_INVALID;

  le_restore_job* j = &r->job;
  if (atomic_load_explicit(&j->a_state, memory_order_acquire) != LE_RS_EMPTY) {
    return LE_ERR_INVALID; /* one job in flight engine-wide */
  }

  for (int32_t l = 0; l < LE_MAX_LANES; ++l) j->buf[l] = NULL;
  int ok = 1;
  for (int32_t l = 0; l < lanes; ++l) {
    if (!(mask & (1u << l))) continue;
    j->buf[l] = (float*)malloc((size_t)len * sizeof(float));
    if (j->buf[l] == NULL) ok = 0;
  }
  if (!ok) {
    for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
      free(j->buf[l]);
      j->buf[l] = NULL;
    }
    return LE_ERR_INVALID;
  }

  j->channel = channel;
  j->lane_mask = mask;
  j->flags = flags;
  j->audio_rev =
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  j->len = len;
  j->sample_rate = engine->sample_rate > 0 ? engine->sample_rate : 48000;
  j->active_lanes = lanes;
  j->copy_lane = 0;
  j->copy_pos = 0;
  atomic_store_explicit(&j->a_cancel, 0, memory_order_relaxed);
  store_i32(&tr->a_restore_state, 1);
  atomic_store_explicit(&j->a_state, LE_RS_COPYING, memory_order_release);
  return LE_OK;
}

int32_t le_engine_cancel_restore(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return LE_ERR_INVALID;
  }
  struct le_restore* r = engine->restore;
  if (r == NULL) return LE_ERR_INVALID;
  le_restore_job* j = &r->job;
  const int32_t st = atomic_load_explicit(&j->a_state, memory_order_acquire);
  if (st == LE_RS_EMPTY || j->channel != channel) return LE_ERR_INVALID;
  if (st == LE_RS_COPYING) {
    /* Still control-side: free immediately, nothing else observes it. */
    le_rs_release_job(engine, j);
    return LE_OK;
  }
  /* Worker-side (QUEUED/RUNNING) or already DONE: signal cancel. The worker
   * aborts at its next lane boundary; a DONE job's collect skips the publish
   * when the cancel flag is set. The tick reclaims either way. */
  atomic_store_explicit(&j->a_cancel, 1, memory_order_release);
  return LE_OK;
}
