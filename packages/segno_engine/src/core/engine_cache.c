/*
 * engine_cache.c — the Loop-stage wet cache (FX v3 part 2).
 *
 * When a lane's record-route chain is STABLE, a single background worker [B6]
 * renders the lane's whole loop offline — dry PCM x pre-chain volume through
 * the engine's own fx_apply_chain, verbatim on a heap le_fx_state (the
 * perf_render pattern; no forked DSP) — and the audio thread plays the cached
 * stereo result at zero FX CPU. Any edit falls back to live processing within
 * one buffer. Design rule: when in doubt, play live. The cache is invisible,
 * never destructive, and never allowed to play stale audio.
 *
 * THREAD OWNERSHIP — the [R2] contract, clause by clause:
 *  (a) Dry-PCM handoff is COPY-AT-ENQUEUE: the CONTROL thread (le_cache_tick)
 *      copies pool[a_live] into a worker-owned buffer, only while the track is
 *      not RECORDING/OVERDUBBING and no overdub layer is in flight (the fade
 *      tail and drain both hold a_layer_in_flight), tagged with the
 *      a_audio_rev it copied under. Every chunk requires settled commands and
 *      the callback's end-of-block readable fact (no armed/seam/fade writer).
 *      Revision/key checks reject stale work; they do not synchronize PCM.
 *      The copy is CHUNKED across ticks (le_cache_copy_step, bounded
 *      per call) so the UI-poll drain path never stalls behind one giant
 *      memcpy. A finished render whose revision moved is discarded. In-flight
 *      copies count against the memory cap. The control thread owns all pool
 *      management (alloc/shrink/a_live swaps), so a control-side copy can
 *      never race a pool free.
 *  (b) Wet-buffer publication mirrors the fx->plugin[] discipline
 *      (engine_plugin.c): entries are control-allocated, fully written, then
 *      published as ONE atomic pointer (le_lane.a_wet, release) whose key the
 *      audio thread re-derives and checks once per buffer. Publication and
 *      retraction are CONTROL-THREAD-ONLY (single writer); the worker never
 *      touches a_wet — it only fills its job slot, which the next tick
 *      collects, validates ([B5]: key must still match), and publishes.
 *  (c) Reclamation uses the engine_plugin.c clear-slot pattern's SAFETY RULE
 *      — retract the pointer, then observe two processed-buffer boundaries
 *      via a_frames before freeing — but observes them PASSIVELY: a retracted
 *      entry moves to a graveyard list and the tick frees it once a_frames
 *      has been seen to change twice since retraction (or immediately with no
 *      audio thread). No control-thread sleep, ever — the UI's snapshot poll
 *      must never stall on cache housekeeping. A stalled device callback just
 *      parks the graveyard (bounded); never a use-after-free.
 *  (d) Join-before-free: le_cache_shutdown joins the worker and is called
 *      from le_engine_stop, the top of le_engine_configure, and
 *      le_engine_destroy BEFORE any pool or wet-buffer free.
 *
 * The job queue is a fixed slot array with SPSC state machines (control:
 * EMPTY -> QUEUED and DONE/ABORTED/FAILED -> EMPTY; worker: QUEUED -> RUNNING
 * -> DONE/ABORTED/FAILED), so no mutex exists anywhere in the engine and the
 * audio thread is untouched. The worker polls (bounded 1 ms sleeps), renders
 * the loop TWICE back-to-back and keeps the second pass, so delay/reverb
 * tails that wrap the loop boundary are baked in; it aborts early when it
 * observes an a_audio_rev bump for its lane [B5] or shutdown.
 */
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_cache.h"
#include "engine_render.h" /* the recipe job on this worker */
#include "engine_core.h"    /* le_lanes_active, le_engine_drain_events */
#include "engine_fx.h"      /* fx_apply_chain, le_fx_prepare, seed/bypass */
#include "engine_private.h" /* le_engine, le_wet_entry, load/store helpers */
#include "segno_engine_api.h"
#include "../stretch/le_stretch.h" /* Transpose's source renders (#1179) */
#if defined(__linux__)
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

/* ---- portable thread shim (mirrors perf_render.c's own; duplicated per
 * translation unit rather than shared, matching this codebase's existing
 * one-file-branch-by-platform convention for background threads). ---- */
#if defined(_WIN32)
#include <windows.h>
typedef HANDLE le_ca_thread_t;
static void le_ca_worker_main(void* arg);
static DWORD WINAPI le_ca_win_trampoline(LPVOID arg) {
  le_ca_worker_main(arg);
  return 0;
}
static int le_ca_thread_start(le_ca_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_ca_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}
static void le_ca_thread_join(le_ca_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}
static void le_ca_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <pthread.h>
#include <time.h>
typedef pthread_t le_ca_thread_t;
static void le_ca_worker_main(void* arg);
static void* le_ca_posix_trampoline(void* arg) {
  le_ca_worker_main(arg);
  return NULL;
}
static int le_ca_thread_start(le_ca_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_ca_posix_trampoline, arg) == 0;
}
static void le_ca_thread_join(le_ca_thread_t th) { pthread_join(th, NULL); }
static void le_ca_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* ---- tuning ---- */
/* (LE_CACHE_SETTLE_MS — the settle debounce window — lives in engine_cache.h
 * so the native tests derive their pump counts from the one definition.) */

/* Job queue slots. Bounded small: one job per lane at most (job_pending), a
 * single worker consumes them, and a full queue just retries next tick —
 * deliberately below LE_MAX_TRACKS so the overflow path is reachable (and
 * tested) instead of dead code. */
#define LE_CACHE_JOB_SLOTS 4

/* Retained entries per lane: the toggled-pair retention [B2] — the current
 * key's entry plus its most recent sibling (e.g. an enabled-bit toggle's
 * other half), so an off/on stomp is cache-hot in both directions. The pair
 * counts twice against the cap. */
#define LE_CACHE_ENTRIES_PER_LANE 2
_Static_assert(LE_CACHE_ENTRIES_PER_LANE == LE_SRC_CANDIDATES,
               "every retained source render is published to the callback");

/* Worker abort-check cadence [B5]: revision/shutdown checked once per this
 * many rendered frames — cheap per block, never per sample. */
#define LE_CACHE_ABORT_CHECK_FRAMES 4096

/* Quiescent reclaim [R2](c): two processed-buffer boundaries (a_frames seen
 * to change twice) prove the audio thread no longer holds a retracted entry
 * pointer — the engine_plugin.c clear-slot number, observed passively here.
 * The graveyard is sized so it can hold EVERY possible entry at once — the
 * retained pairs of every lane (prints and source renders) AND of every
 * track's whole-track print, plus install-replacement churn — so pushing can
 * never overflow by construction. The track term is what a second entry
 * class costs here; leaving it out would turn an overflow into a permanent
 * leak. The last term is Transpose's pins (#1179): a retracted source
 * render a lane still selects (a_src_pin) or a turn window still reads
 * (a_turn_src) waits here until the callback lets go, which with the device
 * stopped is the next callback, while its book slot is already refilled. */
#define LE_CACHE_QUIESCE_BOUNDARIES 2
#define LE_CACHE_GRAVEYARD                                             \
  (2 * LE_MAX_TRACKS * LE_MAX_LANES * LE_CACHE_ENTRIES_PER_LANE +       \
   LE_MAX_TRACKS * LE_CACHE_ENTRIES_PER_LANE + LE_CACHE_JOB_SLOTS +     \
   2 * LE_MAX_TRACKS * LE_MAX_LANES)


/* Consecutive render failures (allocation, prepare OOM) before a lane stops
 * retrying and reports gave-up; any key change re-arms it. */
#define LE_CACHE_FAIL_GIVE_UP 3

/* ---- state ---- */

/* SPSC job lifecycle. Control writes EMPTY->COPYING->QUEUED and *->EMPTY;
 * the worker writes QUEUED->RUNNING->DONE/ABORTED/FAILED. All transitions
 * release; all cross-thread reads acquire. COPYING is control-private: the
 * enqueue dry copy advances one bounded chunk per tick (le_cache_copy_step)
 * so a long loop can never stall the control thread behind one giant memcpy;
 * the worker and the collector both ignore the state. */
enum {
  LE_CACHE_JOB_EMPTY = 0,
  LE_CACHE_JOB_QUEUED = 1,
  LE_CACHE_JOB_RUNNING = 2,
  LE_CACHE_JOB_DONE = 3,
  LE_CACHE_JOB_ABORTED = 4,
  LE_CACHE_JOB_FAILED = 5,
  LE_CACHE_JOB_COPYING = 6,
};

/* Copy-at-enqueue chunk size, in frames (~192 KB, ~1 s of audio): the most
 * dry PCM one tick will copy per job, bounding the UI-poll drain path's
 * per-call cost. A typical loop stages in one or two ticks; a maximal 8-min
 * loop takes ~50 ticks — irrelevant next to the 250 ms settle debounce. */
#define LE_CACHE_COPY_CHUNK_FRAMES 48000

/* One render job. `dry` is control-allocated at enqueue and control-freed at
 * collection (the worker only reads it); `wet` is worker-allocated and either
 * handed over on DONE (control takes ownership) or worker-freed on
 * ABORTED/FAILED. The chain snapshot is frozen at enqueue — the fingerprint
 * IS that snapshot's identity, so a chain that moved by publish time simply
 * fails the [B5] key check and the result is discarded. */
typedef struct le_cache_job {
  _Atomic int32_t a_state;
  /* LE_CACHE_KIND_LANE: `lane` names the part, `dry` is its mono recording
   * and `vol` the level baked in front of the chain (D-VOL).
   * LE_CACHE_KIND_TRACK (slice 3e): `lane` is -1, `dry` is the ASSEMBLED
   * stereo combination of the track's parts — each part's own printed
   * material at its level and mute, placed by its pan — and `vol` is unity.
   * Everything downstream is identical: the same chain snapshot, the same
   * two-pass render, the same key check at publish. */
  int32_t kind;
  int32_t channel;
  int32_t lane;
  uint32_t audio_rev; /* LE_CACHE_KIND_SOURCE: the content key (a_src_key) */
  uint32_t copy_rev;  /* LE_CACHE_KIND_SOURCE: a_audio_rev under the copy */
  uint64_t chain_fp;
  uint32_t vol_bits;
  float vol;
  int32_t len;
  int32_t sample_rate;
  int32_t fx_cap;
  /* The chain, frozen at enqueue — entries, effective bits (D-EFFBITS) and
   * the entries' channel handling and level (slice 3e): a printed Pre entry
   * that lost its input choice or its level would not be what the player
   * heard live. */
  le_fx_frozen_chain chain;
  int32_t copy_pos; /* frames of dry staged so far (COPYING state only) */
  /* LE_CACHE_KIND_SOURCE (#1179): `lanes` mono takes staged back to back in
   * `dry`, shifted by `semitones` into one buffer per lane in `src`. */
  int32_t lanes;
  int32_t semitones;
  int32_t out_len; /* LE_CACHE_KIND_SOURCE: the render's length (#1179) */
  float* src[LE_MAX_LANES];
  float* dry;
  float* wet;
} le_cache_job;

/* What a job renders. */
enum {
  LE_CACHE_KIND_LANE = 0,
  LE_CACHE_KIND_TRACK = 1,
  LE_CACHE_KIND_SOURCE = 2, /* a track's Transpose renders, one per lane */
};

/* Frames of dry a job stages per frame of output: one for a part's mono
 * recording, two for an assembled stereo combination. The accounting below
 * derives every reservation from this rather than assuming mono, so a track
 * job cannot under-reserve. */
static int32_t le_ca_src_channels(int32_t kind) {
  return kind == LE_CACHE_KIND_TRACK ? 2 : 1;
}

/* Bytes a job in flight holds: its staged source plus the stereo wet it will
 * produce. Charged up front at enqueue, released at collection. */
static int64_t le_ca_job_bytes(int32_t kind, int32_t len, int32_t lanes,
                               int32_t out_len) {
  if (kind == LE_CACHE_KIND_SOURCE) { /* mono in, mono out, every lane */
    return (int64_t)lanes * ((int64_t)len + (int64_t)out_len) *
           (int64_t)sizeof(float);
  }
  return (int64_t)(le_ca_src_channels(kind) + 2) * (int64_t)len *
         (int64_t)sizeof(float);
}

/* Per-lane control-side bookkeeping (telemetry + debounce + retained pair). */
typedef struct le_lane_cache {
  le_wet_entry* entries[LE_CACHE_ENTRIES_PER_LANE];
  uint64_t last_key_hash;
  uint64_t key_stable_frames; /* a_frames when the key last changed */
  int has_key;
  int job_pending;
  int32_t state;  /* le_cache_state */
  int32_t reason; /* le_cache_reason */
  int32_t renders;
  int32_t fail_count;
} le_lane_cache;

/* One retracted entry awaiting its passive quiescent window [R2](c): freed
 * once a_frames has been observed to change LE_CACHE_QUIESCE_BOUNDARIES times
 * since retraction (each tick samples once), or immediately when no audio
 * thread runs. Its bytes left the cap accounting at retraction, so the real
 * allocation transiently exceeds `used_bytes` by the graveyard's total for a
 * couple of ticks — bounded and deliberate: the alternative is sleeping on
 * the UI-poll drain path. */
typedef struct le_cache_grave {
  le_wet_entry* ent; /* NULL = free slot */
  uint64_t stamp;    /* last sampled a_frames */
  int boundaries;    /* distinct changes observed since retraction */
} le_cache_grave;

struct le_fx_cache {
  le_engine* engine;
  le_lane_cache lanes[LE_MAX_TRACKS][LE_MAX_LANES];
  /* The same bookkeeping for each track's whole-track Pre print (slice 3e):
   * one entry class more, sharing the worker, the budget and the graveyard.
   * A track's print is rendered over its parts' PRINTED material, so this
   * table is scheduled after the lane table each tick. */
  le_lane_cache tracks[LE_MAX_TRACKS];
  /* Transpose's source renders (#1179): entries per lane, scheduling (one
   * job per track, so its lanes publish together) per track. */
  le_lane_cache src_lanes[LE_MAX_TRACKS][LE_MAX_LANES];
  le_lane_cache src_tracks[LE_MAX_TRACKS];
  le_cache_job jobs[LE_CACHE_JOB_SLOTS];
  le_cache_grave graveyard[LE_CACHE_GRAVEYARD];
  int64_t used_bytes;
  uint64_t lru_clock;
  _Atomic int32_t a_shutdown;
  int worker_started;
  le_ca_thread_t worker;
};

/* ---- key / fingerprint helpers (control thread) ---- */

/* le_fx_chain_fingerprint's fold, over an already-snapshotted chain instead of
 * the live atomics (D-FPEMPTY order preserved: chain bit only when non-empty,
 * then per entry type + enabled bit + built-in params), built on the ONE
 * shared byte fold (le_fx_fp_u32, engine_core.h). Folding the SNAPSHOT makes
 * the job's fingerprint the identity of exactly what will render; the
 * scheduler cross-checks it against the canonical atomic read and skips the
 * tick on any mismatch (a concurrent audio-thread type/count publish), so the
 * two folds can never silently disagree about a scheduled render. */
static uint64_t le_ca_snapshot_fp(int32_t count, int32_t chain_on,
                                  const int32_t* types, const int32_t* enabled,
                                  const float params[LE_FX_MAX][LE_FX_PARAMS],
                                  const le_fx_chan* chan) {
  uint64_t h = 0xcbf29ce484222325ULL;
  if (count > 0) h = le_fx_fp_u32(h, chain_on ? 1u : 0u);
  for (int32_t i = 0; i < count; ++i) {
    h = le_fx_fp_u32(h, (uint32_t)types[i]);
    h = le_fx_fp_u32(h, enabled[i] ? 1u : 0u);
    if (types[i] == LE_FX_PLUGIN) continue;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      h = le_fx_fp_u32(h, f32_to_bits(params[i][p]));
    }
  }
  /* The channel handling, after the entries — the order
   * le_lane_pre_fx_fingerprint folds it in (slice 3e). */
  for (int32_t i = 0; i < count; ++i) h = le_fx_chan_fold(h, &chan[i]);
  return h;
}

/* Composite change-detection hash over the whole cache key (rev, fp, volume,
 * length). Only drives the settle debounce — entry MATCHING always compares
 * the full tuple, never this hash. */
static uint64_t le_ca_key_hash(uint32_t rev, uint64_t fp, uint32_t vol_bits,
                               int32_t len) {
  uint64_t h = fp;
  h = le_fx_fp_u32(h, rev);
  h = le_fx_fp_u32(h, vol_bits);
  h = le_fx_fp_u32(h, (uint32_t)len);
  return h;
}

/* ---- quiescent reclaim [R2](c) — passive, never sleeps ---- */

static int64_t le_ca_entry_bytes(const le_wet_entry* ent) {
  if (ent->kind == 1) return (int64_t)ent->out_len * (int64_t)sizeof(float);
  return 2ll * (int64_t)ent->len * (int64_t)sizeof(float); /* stereo [R5] */
}

/* Whether a turn window still reads this render (E4): the audio thread
 * publishes the source its old head reads in a_turn_src before the buffer
 * that reads it ends, so a sweep that has seen the quiescent boundaries also
 * sees the pin, and defers the free until the window lets go. */
static int le_ca_pinned(le_engine* e, const le_wet_entry* ent) {
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      /* the render a lane still selects (until its next verdict lets go)
       * and the one a turn window's old head reads */
      if (atomic_load_explicit(&e->tracks[t].a_turn_src[l],
                               memory_order_acquire) == ent ||
          atomic_load_explicit(&e->tracks[t].a_src_pin[l],
                               memory_order_acquire) == ent) return 1;
    }
  }
  return 0;
}

/* Frees every graveyard entry whose passive quiescent window has closed: with
 * no audio thread everything is immediately reclaimable; otherwise an entry
 * frees once a_frames has been observed to change twice since retraction (one
 * sample per tick — the engine_plugin.c two-boundary rule without the sleep).
 * `force` (shutdown, where the callers guarantee the audio thread is gone)
 * frees unconditionally. */
static void le_cache_sweep_graveyard(le_engine* e, struct le_fx_cache* c,
                                     int force) {
  const int running = load_i32(&e->a_running);
  const uint64_t now =
      atomic_load_explicit(&e->a_frames, memory_order_acquire);
  for (int g = 0; g < LE_CACHE_GRAVEYARD; ++g) {
    le_cache_grave* gr = &c->graveyard[g];
    if (gr->ent == NULL) continue;
    if (!force && running) {
      if (now != gr->stamp) {
        gr->boundaries++;
        gr->stamp = now;
      }
      if (gr->boundaries < LE_CACHE_QUIESCE_BOUNDARIES) continue;
    }
    /* a turn window still reading it (E4), with or without a device: a
     * device-free host drives the same callback */
    if (!force && le_ca_pinned(e, gr->ent)) continue;
    free(gr->ent->pcm);
    free(gr->ent);
    gr->ent = NULL;
  }
}

/* ---- the two entry classes, addressed the same way ----
 *
 * A part's print and a track's whole-track print differ only in what they are
 * rendered from; every lifetime rule below — publication, retraction, the
 * budget, the graveyard, shutdown — is identical, so each site takes a `kind`
 * and resolves the three things that differ through these three accessors. A
 * track's slot uses lane index 0 and ignores it. */

/* How many lane slots a kind spans, for the iteration spaces below. */
static int le_ca_lane_span(int32_t kind) {
  return kind == LE_CACHE_KIND_TRACK ? 1 : LE_MAX_LANES;
}

static le_lane_cache* le_ca_book(struct le_fx_cache* c, int32_t kind, int t,
                                 int l) {
  if (kind == LE_CACHE_KIND_SOURCE) {
    return l < 0 ? &c->src_tracks[t] : &c->src_lanes[t][l];
  }
  return kind == LE_CACHE_KIND_TRACK ? &c->tracks[t] : &c->lanes[t][l];
}

static le_wet_entry* _Atomic* le_ca_published(le_engine* e, int32_t kind, int t,
                                              int l, int i) {
  if (kind == LE_CACHE_KIND_SOURCE) return &e->tracks[t].lanes[l].a_src[i];
  return kind == LE_CACHE_KIND_TRACK ? &e->tracks[t].a_track_wet
                                     : &e->tracks[t].lanes[l].a_wet;
}

static _Atomic int32_t* le_ca_active(le_engine* e, int32_t kind, int t, int l) {
  return kind == LE_CACHE_KIND_TRACK ? &e->tracks[t].a_track_cache_active
                                     : &e->tracks[t].lanes[l].a_cache_active;
}

/* Retracts entry [i] of the (kind, t, l) slot: un-publishes it from the audio
 * thread, removes its bytes from the cap accounting, and parks it in the
 * graveyard for the passive quiescent free above. Non-blocking by design
 * [R2](c) — this runs on the UI-poll drain path. The graveyard is sized to
 * hold every possible entry of every class plus the pinned stragglers
 * (LE_CACHE_GRAVEYARD), so the push cannot fail. */
static void le_cache_drop_entry(le_engine* e, struct le_fx_cache* c,
                                int32_t kind, int t, int l, int i) {
  le_lane_cache* book = le_ca_book(c, kind, t, l);
  le_wet_entry* ent = book->entries[i];
  if (ent == NULL) return;
  le_wet_entry* _Atomic* pub = le_ca_published(e, kind, t, l, i);
  if (atomic_load_explicit(pub, memory_order_relaxed) == ent) {
    atomic_store_explicit(pub, NULL, memory_order_release);
  }
  c->used_bytes -= le_ca_entry_bytes(ent);
  book->entries[i] = NULL;
  for (int attempt = 0; attempt < 2; ++attempt) {
    for (int g = 0; g < LE_CACHE_GRAVEYARD; ++g) {
      if (c->graveyard[g].ent == NULL) {
        c->graveyard[g].ent = ent;
        c->graveyard[g].stamp =
            atomic_load_explicit(&e->a_frames, memory_order_acquire);
        c->graveyard[g].boundaries = 0;
        return;
      }
    }
    /* Unreachable by sizing (see LE_CACHE_GRAVEYARD). If the sizing
     * invariant ever breaks, sweep and retry once — and if the graveyard is
     * somehow STILL full, deliberately LEAK the entry rather than free it:
     * a raw free here would skip the quiescent window [R2](c) while the
     * audio thread may still hold the pointer for the current buffer. A
     * bounded leak beats a use-after-free. */
    le_cache_sweep_graveyard(e, c, 0);
  }
}

/* Retracts every entry of both classes (the cap-disabled path and shutdown's
 * prelude). */
static void le_cache_free_all_entries(le_engine* e, struct le_fx_cache* c) {
  for (int32_t kind = LE_CACHE_KIND_LANE; kind <= LE_CACHE_KIND_SOURCE; ++kind) {
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      for (int l = 0; l < le_ca_lane_span(kind); ++l) {
        for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
          le_cache_drop_entry(e, c, kind, t, l, i);
        }
      }
    }
  }
}

/* Whether an entry may be evicted (E7): a source render that is the one a
 * transposed track with material names for its current content never is —
 * evicting it would drop the track to its dry take, a silent pitch change,
 * now (PLAYING) or at its next Play (STOPPED, review L2). A job that needs
 * its room is refused instead. */
static int le_ca_evictable(le_engine* e, int32_t kind, int t,
                           const le_wet_entry* ent) {
  if (kind != LE_CACHE_KIND_SOURCE) return 1;
  le_track* tr = &e->tracks[t];
  const int32_t st = load_i32(&e->a_transpose_bypass)
                         ? 0
                         : load_i32(&tr->a_transpose_st);
  const int32_t len = load_i32(&tr->lanes[0].a_len);
  const int32_t want_out = le_track_want_out(e, tr);
  return load_i32(&tr->a_state) == LE_TRACK_EMPTY ||
         (st == 0 && want_out == len) ||
         !le_src_entry_fits(
             ent, atomic_load_explicit(&tr->a_src_key, memory_order_acquire),
             len, st, want_out);
}

/* LRU eviction until [needed] more bytes fit under [cap]: Pre prints first
 * (the live chain computes the same function), then source renders no
 * track is playing (E7). An evicted lane simply plays live and may re-render
 * later; eviction may take the print the audio thread is currently playing
 * (via the retract + quiesce dance — the audible result is the ordinary
 * same-buffer live fallback). Returns 1 when the budget fits. */
static int le_cache_ensure_budget(le_engine* e, struct le_fx_cache* c,
                                  int64_t cap, int64_t needed) {
  /* The overwhelmingly common case — already under budget — pays one
   * comparison, not the 128-slot scans below (this runs on every tick). */
  if (c->used_bytes + needed <= cap) return 1;
  /* Feasibility first: only entries are evictable (in-flight job bytes are
   * not), so if evicting EVERYTHING still would not fit, fail without
   * destroying entries that could keep serving — an infeasible render must
   * not thrash the survivors away. */
  int64_t evictable = 0;
  for (int32_t kind = LE_CACHE_KIND_LANE; kind <= LE_CACHE_KIND_SOURCE; ++kind) {
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      for (int l = 0; l < le_ca_lane_span(kind); ++l) {
        const le_lane_cache* book = le_ca_book(c, kind, t, l);
        for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
          if (book->entries[i] != NULL &&
              le_ca_evictable(e, kind, t, book->entries[i])) {
            evictable += le_ca_entry_bytes(book->entries[i]);
          }
        }
      }
    }
  }
  /* A cap that shrank below what is protected (needed == 0) still sheds
   * everything evictable; a job that cannot fit sheds nothing. */
  if (needed > 0 && c->used_bytes - evictable + needed > cap) return 0;
  while (c->used_bytes + needed > cap) {
    int32_t bk = -1;
    int bt = -1, bl = -1, bi = -1;
    uint64_t best = 0;
    for (int32_t kind = LE_CACHE_KIND_LANE; kind <= LE_CACHE_KIND_SOURCE;
         ++kind) {
      /* a print anywhere goes before any source render */
      if (kind == LE_CACHE_KIND_SOURCE && bk >= 0) break;
      for (int t = 0; t < LE_MAX_TRACKS; ++t) {
        for (int l = 0; l < le_ca_lane_span(kind); ++l) {
          const le_lane_cache* book = le_ca_book(c, kind, t, l);
          for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
            le_wet_entry* ent = book->entries[i];
            if (ent == NULL || !le_ca_evictable(e, kind, t, ent)) continue;
            if (bk < 0 || ent->last_used < best) {
              best = ent->last_used;
              bk = kind;
              bt = t;
              bl = l;
              bi = i;
            }
          }
        }
      }
    }
    if (bk < 0) return 0; /* nothing left to evict; budget cannot fit */
    le_cache_drop_entry(e, c, bk, bt, bl, bi);
  }
  return 1;
}

/* ---- publication (control thread, [B5] + [B2]) ---- */

/* Wraps a DONE job's wet buffer in a le_wet_entry and installs it in the
 * slot's retained pair: reuse a same-key slot, else a free slot, else replace
 * the pair's LRU member. The entry is fully written BEFORE the release
 * publish, so the audio thread can never see a partial entry [R2](b). */
static void le_cache_install_entry(le_engine* e, struct le_fx_cache* c,
                                   int32_t kind, int t, int l,
                                   const le_wet_entry* key, float** pcm) {
  le_lane_cache* lc = le_ca_book(c, kind, t, l);

  int slot = -1;
  for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
    le_wet_entry* ent = lc->entries[i];
    if (ent != NULL &&
        le_wet_entry_key_matches_kind(ent, key->audio_rev, key->chain_fp,
                                      key->vol_bits, key->len, key->kind,
                                      key->semitones, key->out_len)) {
      slot = i; /* same key rendered twice (races resolve here): replace */
      break;
    }
  }
  if (slot < 0) {
    for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
      if (lc->entries[i] == NULL) {
        slot = i;
        break;
      }
    }
  }
  if (slot < 0) {
    slot = 0; /* replace the pair's LRU member [B2] */
    for (int i = 1; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
      if (lc->entries[i]->last_used < lc->entries[slot]->last_used) slot = i;
    }
  }
  le_cache_drop_entry(e, c, kind, t, l, slot);

  le_wet_entry* ent = (le_wet_entry*)calloc(1, sizeof(le_wet_entry));
  if (ent == NULL) {
    free(*pcm);
    *pcm = NULL;
    return;
  }
  *ent = *key;
  ent->pcm = *pcm;
  ent->last_used = c->lru_clock;
  *pcm = NULL; /* ownership moved */
  lc->entries[slot] = ent;
  c->used_bytes += le_ca_entry_bytes(ent);
  atomic_store_explicit(le_ca_published(e, kind, t, l, slot), ent,
                        memory_order_release);
}

static void le_cache_install(le_engine* e, struct le_fx_cache* c,
                             le_cache_job* job) {
  const le_wet_entry key = {.audio_rev = job->audio_rev,
                            .chain_fp = job->chain_fp,
                            .vol_bits = job->vol_bits,
                            .len = job->len,
                            .out_len = job->len};
  le_cache_install_entry(e, c, job->kind, job->channel, job->lane, &key,
                         &job->wet);
}

/* A track's source key as it stands (Transpose, #1179): its content, its
 * stored pitch, and whether it is bypassed. */
static int le_ca_source_current(le_engine* e, const le_cache_job* job) {
  le_track* tr = &e->tracks[job->channel];
  const int32_t st = load_i32(&e->a_transpose_bypass)
                         ? 0
                         : load_i32(&tr->a_transpose_st);
  const le_wet_entry made = {.audio_rev = job->audio_rev,
                             .len = job->len,
                             .kind = 1,
                             .semitones = job->semitones,
                             .out_len = job->out_len};
  return le_lanes_active(tr) == job->lanes &&
         le_src_entry_fits(
             &made, atomic_load_explicit(&tr->a_src_key, memory_order_acquire),
             load_i32(&tr->lanes[0].a_len), st, le_track_want_out(e, tr));
}

/* Collects finished jobs: frees the enqueue copy, publishes a DONE render iff
 * its key STILL matches the lane's current key [B5], and returns the slot to
 * EMPTY. Failure/abort bookkeeping feeds the telemetry states. */
static void le_cache_collect(le_engine* e, struct le_fx_cache* c,
                             int64_t cap) {
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    le_cache_job* job = &c->jobs[j];
    const int32_t st =
        atomic_load_explicit(&job->a_state, memory_order_acquire);
    if (st != LE_CACHE_JOB_DONE && st != LE_CACHE_JOB_ABORTED &&
        st != LE_CACHE_JOB_FAILED) {
      continue;
    }
    le_lane_cache* lc = le_ca_book(c, job->kind, job->channel, job->lane);
    lc->job_pending = 0;
    /* The enqueue copy and the pre-accounted wet leave the books here; a
     * published wet re-enters as entry bytes in le_cache_install. */
    c->used_bytes -=
        le_ca_job_bytes(job->kind, job->len, job->lanes, job->out_len);
    free(job->dry);
    job->dry = NULL;
    if (job->kind == LE_CACHE_KIND_SOURCE) {
      /* Every lane at once, or none: a track never plays two pitches. */
      const int publish = st == LE_CACHE_JOB_DONE && cap > 0 &&
                          le_ca_source_current(e, job);
      if (st == LE_CACHE_JOB_DONE) lc->renders++;
      if (st == LE_CACHE_JOB_FAILED) {
        lc->state = LE_CACHE_GAVE_UP;
        lc->reason = LE_CACHE_REASON_RENDER_FAILED;
      }
      for (int l = 0; l < job->lanes; ++l) {
        const le_wet_entry key = {.audio_rev = job->audio_rev,
                                  .len = job->len,
                                  .kind = 1,
                                  .semitones = job->semitones,
                                  .out_len = job->out_len};
        if (publish && job->src[l] != NULL) {
          le_cache_install_entry(e, c, LE_CACHE_KIND_SOURCE, job->channel, l,
                                 &key, &job->src[l]);
        }
        free(job->src[l]);
        job->src[l] = NULL;
      }
      atomic_store_explicit(&job->a_state, LE_CACHE_JOB_EMPTY,
                            memory_order_release);
      continue;
    }
    if (st == LE_CACHE_JOB_DONE) {
      lc->renders++;
      lc->fail_count = 0;
      le_track* tr = &e->tracks[job->channel];
      le_lane* ln = &tr->lanes[job->lane < 0 ? 0 : job->lane];
      const uint32_t rev =
          atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
      /* [B5] again at publish, against the SAME key the slot's scheduler
       * derives — a track's key is the whole combination, a lane's its own
       * Pre prefix. A track job's vol term is unity: every part's level is
       * already inside the assembled source. */
      const uint64_t fp = job->kind == LE_CACHE_KIND_TRACK
                              ? le_track_pre_fingerprint(e, job->channel)
                              : le_lane_pre_fx_fingerprint(e, job->channel,
                                                           job->lane);
      const uint32_t vol =
          job->kind == LE_CACHE_KIND_TRACK
              ? job->vol_bits
              : atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
      const int32_t len = load_i32(&ln->a_len);
      const le_wet_entry probe = {.audio_rev = job->audio_rev,
                                  .chain_fp = job->chain_fp,
                                  .vol_bits = job->vol_bits,
                                  .len = job->len,
                                  .out_len = job->len};
      if (cap > 0 && le_wet_entry_key_matches(&probe, rev, fp, vol, len)) {
        le_cache_install(e, c, job);
      } else {
        free(job->wet); /* the key moved mid-render: discard, never publish */
        job->wet = NULL;
      }
    } else if (st == LE_CACHE_JOB_FAILED) {
      lc->fail_count++;
      if (lc->fail_count >= LE_CACHE_FAIL_GIVE_UP) {
        lc->state = LE_CACHE_GAVE_UP;
        lc->reason = LE_CACHE_REASON_RENDER_FAILED;
      } else {
        lc->state = LE_CACHE_FAILED_RETRYING;
      }
    }
    /* ABORTED: the revision moved; the ordinary schedule path re-renders. */
    atomic_store_explicit(&job->a_state, LE_CACHE_JOB_EMPTY,
                          memory_order_release);
  }
}

/* ---- scheduling (control thread) ---- */

/* A revision detects stale content, but cannot make a racing PCM read safe.
 * The callback's end-of-block mirror excludes pending autonomous writes;
 * the existing command publication ticket excludes a newly queued writer.
 * These checks remain valid throughout a chunk: its sole control producer
 * cannot submit another command while copying. */
static int le_cache_source_readable(le_engine* e, int32_t channel) {
  return le_engine_commands_settled(e) && atomic_load_explicit(
      &e->tracks[channel].a_cache_source_readable, memory_order_acquire);
}

static int le_cache_copy_key_matches(le_engine* e, const le_cache_job* job) {
  /* A source copy is also torn by any write under it, which bumps the
   * revision even where the key would come back (seqlock, [B5]). */
  if (job->kind == LE_CACHE_KIND_SOURCE) {
    return le_ca_source_current(e, job) &&
           atomic_load_explicit(&e->tracks[job->channel].a_audio_rev,
                                memory_order_acquire) == job->copy_rev;
  }
  le_track* tr = &e->tracks[job->channel];
  le_lane* ln = &tr->lanes[job->lane < 0 ? 0 : job->lane];
  const uint64_t fp = job->kind == LE_CACHE_KIND_TRACK
      ? le_track_pre_fingerprint(e, job->channel)
      : le_lane_pre_fx_fingerprint(e, job->channel, job->lane);
  const uint32_t vol = job->kind == LE_CACHE_KIND_TRACK
      ? f32_to_bits(1.0f)
      : atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
  const le_wet_entry key = {.audio_rev = job->audio_rev,
                            .chain_fp = job->chain_fp,
                            .vol_bits = job->vol_bits,
                            .len = job->len,
                            .out_len = job->len};
  return le_wet_entry_key_matches(&key,
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire),
      fp, vol, load_i32(&ln->a_len));
}

/* One lane's scheduler pass: derive the current key, drive the settle
 * debounce [B2][B3], publish a retained match, or enqueue a render when the
 * gates allow. Every "don't cache" outcome degrades to live — never blocks
 * audio. */
static void le_cache_schedule_lane(le_engine* e, struct le_fx_cache* c,
                                   int64_t cap, int t, int l) {
  le_track* tr = &e->tracks[t];
  le_lane* ln = &tr->lanes[l];
  le_lane_cache* lc = &c->lanes[t][l];
  if (!le_cache_source_readable(e, t)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  /* Chain snapshot (atomics -> locals) + its identity.
   *
   * Only the PRE PREFIX is rendered (slice 3e): a Pre entry is part of what
   * the take plays back, so printing it once from the dry pool is exactly the
   * accepted "prepared from original sources". The Post entries are
   * deliberately left out — their tails have to be able to drain past a Stop
   * and a baked tail cannot — so `count` here is the Pre count, and a chain
   * with no Pre entry has nothing to print and stays live. */
  const int32_t total = load_i32(&ln->a_fx_count);
  int32_t count = load_i32(&ln->a_fx_pre_count);
  if (count < 0) count = 0;
  if (count > total) count = total;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
  int32_t types[LE_FX_MAX];
  int32_t raw_en[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int has_builtin = 0;
  int has_plugin = 0;
  for (int32_t s = 0; s < count; ++s) {
    types[s] = load_i32(&ln->a_fx_type[s]);
    raw_en[s] = load_i32(&ln->a_fx_enabled[s]) ? 1 : 0;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      params[s][p] = load_f32(&ln->a_fx_param[s][p]);
    }
    if (types[s] == LE_FX_PLUGIN) {
      has_plugin = 1;
    } else if (types[s] != LE_FX_NONE) {
      has_builtin = 1;
    }
  }

  /* Plugin-bearing chains are never cached: an offline render would pass the
   * plugin dry. Permanently live with the reason stated — never silent. The
   * retained entries stay (LRU reclaims them; removing the plugin restores
   * the old fingerprint and they become hot again). */
  if (has_plugin) {
    lc->state = LE_CACHE_GAVE_UP;
    lc->reason = LE_CACHE_REASON_PLUGIN;
    return;
  }
  /* lc->reason is deliberately NOT cleared here: a RENDER_FAILED give-up
   * keeps reporting its reason until the key-change re-arm below releases it
   * (the documented "reason meaningful while state == GAVE_UP" contract). */

  const int32_t len = load_i32(&ln->a_len);
  if (len <= 0 || !has_builtin) {
    /* Nothing to cache: no content, or the chain is empty/dry (an empty
     * chain is already zero FX CPU). Content-less lanes free their retained
     * entries eagerly — their revision can never match again. */
    if (len <= 0) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(e, c, LE_CACHE_KIND_LANE, t, l, i);
      }
    }
    lc->state = LE_CACHE_LIVE;
    return;
  }

  const uint32_t rev =
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  const uint32_t vol_bits =
      atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
  le_fx_chan chan[LE_FX_MAX];
  int32_t chan_any = 0;
  memset(chan, 0, sizeof(chan));
  le_fx_chan_snapshot(chan, &chan_any, count, ln->a_fx_chan_in,
                      ln->a_fx_chan_out, ln->a_fx_chan_gl_bits,
                      ln->a_fx_chan_gr_bits, ln->a_fx_chan_level_bits);
  const uint64_t fp =
      le_ca_snapshot_fp(count, chain_on, types, raw_en, params, chan);
  /* Cross-check against the canonical atomic fold: a mismatch means the audio
   * thread published a type/count change mid-snapshot — skip this tick rather
   * than schedule a torn chain (the next tick reads it settled). */
  if (fp != le_lane_pre_fx_fingerprint(e, t, l)) return;

  /* Settle debounce [B2][B3]: any key change (content, chain, enabled bits,
   * volume — D-VOL) restarts the window; a change also re-arms a lane that
   * gave up on render failures. */
  const uint64_t now = atomic_load_explicit(&e->a_frames, memory_order_relaxed);
  const uint64_t key_hash = le_ca_key_hash(rev, fp, vol_bits, len);
  if (!lc->has_key || key_hash != lc->last_key_hash) {
    lc->has_key = 1;
    lc->last_key_hash = key_hash;
    lc->key_stable_frames = now;
    lc->fail_count = 0;
    if (lc->state == LE_CACHE_GAVE_UP) lc->state = LE_CACHE_LIVE;
    lc->reason = LE_CACHE_REASON_NONE; /* a changed key re-arms the lane */
  }

  /* A retained entry matching the CURRENT key publishes immediately — the
   * cache-hot path for toggled pairs [B2] (zero re-render on an off/on
   * stomp). */
  for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
    le_wet_entry* ent = lc->entries[i];
    if (ent == NULL) continue;
    if (le_wet_entry_key_matches(ent, rev, fp, vol_bits, len)) {
      ent->last_used = c->lru_clock;
      if (atomic_load_explicit(&ln->a_wet, memory_order_relaxed) != ent) {
        atomic_store_explicit(&ln->a_wet, ent, memory_order_release);
      }
      lc->state = LE_CACHE_CACHED;
      return;
    }
  }

  if (lc->job_pending) {
    lc->state = LE_CACHE_RENDERING;
    return;
  }
  if (lc->state == LE_CACHE_GAVE_UP) return; /* until the key changes */

  /* Enqueue gates [R2](a): stable transport only — never while capturing,
   * and never while an overdub layer is in flight (the punch fade tail and
   * the post-punch drain still write the live buffers under that flag).
   * le_effective_state (engine_core.h) is the same predicate every other
   * control-side decision uses — the unacked-flip window included. */
  const int32_t est = le_effective_state(tr);
  if (est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  if (atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  const float* src = ln->pool[load_i32(&ln->a_live)];
  if (src == NULL) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const uint64_t settle =
      (uint64_t)((int64_t)sr * LE_CACHE_SETTLE_MS / 1000);
  if (now - lc->key_stable_frames < settle) {
    if (lc->state != LE_CACHE_FAILED_RETRYING) lc->state = LE_CACHE_LIVE;
    return;
  }

  /* Memory cap: the whole job footprint (mono enqueue copy + the stereo wet
   * it will produce) is accounted up front; eviction makes room (LRU), and a
   * budget that cannot fit degrades to live and retries later. */
  const int64_t job_bytes = le_ca_job_bytes(LE_CACHE_KIND_LANE, len, 1, len);
  if (!le_cache_ensure_budget(e, c, cap, job_bytes)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  le_cache_job* job = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    if (atomic_load_explicit(&c->jobs[j].a_state, memory_order_acquire) ==
        LE_CACHE_JOB_EMPTY) {
      job = &c->jobs[j];
      break;
    }
  }
  if (job == NULL) {
    lc->state = LE_CACHE_LIVE; /* queue full; retry next tick */
    return;
  }

  /* Copy-at-enqueue [R2](a), CHUNKED: the dry buffer is allocated here, but
   * the PCM stages one bounded chunk per tick (le_cache_copy_step) so this
   * UI-poll-driven path never blocks on one giant memcpy. Each chunk requires
   * settled command ownership and callback-published readable PCM. The full
   * content/recipe key is rechecked between chunks and at completion. */
  float* dry = (float*)malloc((size_t)len * sizeof(float));
  if (dry == NULL) {
    lc->fail_count++;
    lc->state = lc->fail_count >= LE_CACHE_FAIL_GIVE_UP
                    ? LE_CACHE_GAVE_UP
                    : LE_CACHE_FAILED_RETRYING;
    if (lc->state == LE_CACHE_GAVE_UP) {
      lc->reason = LE_CACHE_REASON_RENDER_FAILED;
    }
    return;
  }

  job->kind = LE_CACHE_KIND_LANE;
  job->channel = t;
  job->lane = l;
  job->lanes = 1;
  job->audio_rev = rev;
  job->chain_fp = fp;
  job->vol_bits = vol_bits;
  job->vol = bits_to_f32(vol_bits);
  job->len = len;
  job->sample_rate = sr;
  job->fx_cap = e->fx_delay_frames;
  /* The channel handling the fingerprint above was taken over, not a fresh
   * read: the job must render exactly the chain its key names. */
  le_fx_frozen_fill(&job->chain, count, count, chain_on, types, raw_en, params,
                    chan, chan_any);
  job->copy_pos = 0;
  job->dry = dry;
  job->wet = NULL;
  c->used_bytes += job_bytes;
  lc->job_pending = 1;
  lc->state = LE_CACHE_RENDERING;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_COPYING,
                        memory_order_release);
}

/* One TRACK's scheduler pass: the whole-track Pre print (slice 3e).
 *
 * The part scheduler's shape, with three differences that are the whole
 * feature: the render covers the track's Pre run rather than a part's, its
 * source is the combination the parts' prints make rather than one dry
 * recording, and it refuses outright unless every part carries a wholly-Pre
 * chain — a part with a Post entry would otherwise have that entry baked, and
 * a baked tail cannot drain past a Stop, which is the promise that part's own
 * switch makes.
 *
 * Every "don't print" outcome degrades to live and sounds identical. */
static void le_cache_schedule_track(le_engine* e, struct le_fx_cache* c,
                                    int64_t cap, int t) {
  le_track* tr = &e->tracks[t];
  le_fx_bus* b = &tr->bus;
  le_lane_cache* lc = &c->tracks[t];
  lc->reason = LE_CACHE_REASON_NONE;
  if (!le_cache_source_readable(e, t)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  const int32_t total = load_i32(&b->a_fx_count);
  int32_t count = load_i32(&b->a_fx_pre_count);
  if (count < 0) count = 0;
  if (count > total) count = total;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  const int32_t chain_on = load_i32(&b->a_fx_chain_enabled);
  int32_t types[LE_FX_MAX];
  int32_t raw_en[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int has_builtin = 0;
  int has_plugin = 0;
  for (int32_t s = 0; s < count; ++s) {
    types[s] = load_i32(&b->a_fx_type[s]);
    raw_en[s] = load_i32(&b->a_fx_enabled[s]) ? 1 : 0;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      params[s][p] = load_f32(&b->a_fx_param[s][p]);
    }
    if (types[s] == LE_FX_PLUGIN) {
      has_plugin = 1;
    } else if (types[s] != LE_FX_NONE) {
      has_builtin = 1;
    }
  }
  if (has_plugin) {
    lc->state = LE_CACHE_GAVE_UP;
    lc->reason = LE_CACHE_REASON_PLUGIN;
    return;
  }

  const int32_t len = load_i32(&tr->lanes[0].a_len);
  /* Nothing to print: no Pre run, no content, or a part carrying a Post
   * entry. The last is a permanent state for as long as that entry lives, and
   * the track's Pre run simply runs live — the same signal, at live cost. */
  if (len <= 0 || !has_builtin || !le_track_pre_printable(e, t)) {
    if (len > 0 && has_builtin) {
      lc->reason = LE_CACHE_REASON_PART_POST;
      for (int lane = 0; lane < le_lanes_active(tr); ++lane) {
        le_lane* ln = &tr->lanes[lane];
        const int n = load_i32(&ln->a_fx_count);
        for (int slot = 0; slot < n && slot < LE_FX_MAX; ++slot)
          if (load_i32(&ln->a_fx_type[slot]) == LE_FX_PLUGIN)
            lc->reason = LE_CACHE_REASON_PLUGIN;
      }
    }
    if (len <= 0 || !has_builtin) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(e, c, LE_CACHE_KIND_TRACK, t, 0, i);
      }
    }
    lc->state = LE_CACHE_LIVE;
    return;
  }

  const uint32_t rev =
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  le_fx_chan chan[LE_FX_MAX];
  int32_t chan_any = 0;
  memset(chan, 0, sizeof(chan));
  le_fx_chan_snapshot(chan, &chan_any, count, b->a_fx_chan_in, b->a_fx_chan_out,
                      b->a_fx_chan_gl_bits, b->a_fx_chan_gr_bits,
                      b->a_fx_chan_level_bits);
  /* The canonical key, not a snapshot fold: a track's key spans every part as
   * well as its own chain, so there is one reader of it and the cross-check
   * the part scheduler makes has nothing to compare against. A concurrent
   * publish moves the key and the [B5] check at collection discards the
   * render, which is the same protection by a different route. */
  const uint64_t fp = le_track_pre_fingerprint(e, t);
  /* A whole-track job's source already carries every part's level, so unity
   * stands in for the part scheduler's volume term. */
  const uint32_t vol_bits = f32_to_bits(1.0f);

  const uint64_t now = atomic_load_explicit(&e->a_frames, memory_order_relaxed);
  const uint64_t key_hash = le_ca_key_hash(rev, fp, vol_bits, len);
  if (!lc->has_key || key_hash != lc->last_key_hash) {
    lc->has_key = 1;
    lc->last_key_hash = key_hash;
    lc->key_stable_frames = now;
    lc->fail_count = 0;
    if (lc->state == LE_CACHE_GAVE_UP) lc->state = LE_CACHE_LIVE;
    lc->reason = LE_CACHE_REASON_NONE;
  }

  for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
    le_wet_entry* ent = lc->entries[i];
    if (ent == NULL) continue;
    if (le_wet_entry_key_matches(ent, rev, fp, vol_bits, len)) {
      ent->last_used = c->lru_clock;
      if (atomic_load_explicit(&tr->a_track_wet, memory_order_relaxed) != ent) {
        atomic_store_explicit(&tr->a_track_wet, ent, memory_order_release);
      }
      lc->state = LE_CACHE_CACHED;
      return;
    }
  }

  if (lc->job_pending) {
    lc->state = LE_CACHE_RENDERING;
    return;
  }
  if (lc->state == LE_CACHE_GAVE_UP) return;

  const int32_t est = le_effective_state(tr);
  if (est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  if (atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  /* Every part must be ready to contribute: its own print published, or an
   * empty chain whose dry recording stands in for one. A part still settling
   * simply defers the track by a tick. */
  const int32_t lanes = le_lanes_active(tr);
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &tr->lanes[l];
    if (atomic_load_explicit(&ln->a_wet, memory_order_acquire) != NULL) {
      continue;
    }
    if (load_i32(&ln->a_fx_count) > 0 ||
        ln->pool[load_i32(&ln->a_live)] == NULL) {
      lc->state = LE_CACHE_LIVE;
      return;
    }
  }

  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const uint64_t settle = (uint64_t)((int64_t)sr * LE_CACHE_SETTLE_MS / 1000);
  if (now - lc->key_stable_frames < settle) {
    if (lc->state != LE_CACHE_FAILED_RETRYING) lc->state = LE_CACHE_LIVE;
    return;
  }

  const int64_t job_bytes = le_ca_job_bytes(LE_CACHE_KIND_TRACK, len, 1, len);
  if (!le_cache_ensure_budget(e, c, cap, job_bytes)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  le_cache_job* job = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    if (atomic_load_explicit(&c->jobs[j].a_state, memory_order_acquire) ==
        LE_CACHE_JOB_EMPTY) {
      job = &c->jobs[j];
      break;
    }
  }
  if (job == NULL) {
    lc->state = LE_CACHE_LIVE;
    return;
  }

  float* src = (float*)malloc((size_t)len * 2 * sizeof(float));
  if (src == NULL) {
    lc->fail_count++;
    lc->state = lc->fail_count >= LE_CACHE_FAIL_GIVE_UP
                    ? LE_CACHE_GAVE_UP
                    : LE_CACHE_FAILED_RETRYING;
    if (lc->state == LE_CACHE_GAVE_UP) {
      lc->reason = LE_CACHE_REASON_RENDER_FAILED;
    }
    return;
  }

  job->kind = LE_CACHE_KIND_TRACK;
  job->channel = t;
  job->lane = -1;
  job->lanes = 1;
  job->audio_rev = rev;
  job->chain_fp = fp;
  job->vol_bits = vol_bits;
  job->vol = 1.0f;
  job->len = len;
  job->sample_rate = sr;
  job->fx_cap = e->fx_delay_frames;
  le_fx_frozen_fill(&job->chain, count, count, chain_on, types, raw_en, params,
                    chan, chan_any);
  job->copy_pos = 0;
  job->dry = src;
  job->wet = NULL;
  c->used_bytes += job_bytes;
  lc->job_pending = 1;
  lc->state = LE_CACHE_RENDERING;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_COPYING,
                        memory_order_release);
}

/* One TRACK's Transpose pass (#1179 Part 3a): publish its retained renders
 * when every lane holds one for the current key, else schedule one job that
 * renders every active lane at that key after the 100 ms settle. Entries stay
 * while the pitch returns to 0 or is bypassed (LRU reclaims them), so a step
 * back or an Undo to a rendered take is cache-hot. A job the budget cannot
 * host is refused with the reason and the track stays dry, reported. */
static void le_cache_schedule_source(le_engine* e, struct le_fx_cache* c,
                                     int64_t cap, int t) {
  le_track* tr = &e->tracks[t];
  le_lane_cache* lc = &c->src_tracks[t];
  const int32_t st = load_i32(&tr->a_transpose_st);
  const int32_t len = load_i32(&tr->lanes[0].a_len);
  const int32_t lanes = le_lanes_active(tr);
  if (len <= 0) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(e, c, LE_CACHE_KIND_SOURCE, t, l, i);
      }
    }
  }
  /* What the track wants: its pitch unless bypassed, and a stretch to its
   * span when it plays over another one with Pitch Unchanged (Part 4a-ii). */
  const int32_t want_st = load_i32(&e->a_transpose_bypass) ? 0 : st;
  const int32_t want_out = len > 0 ? le_track_want_out(e, tr) : 0;
  if (len <= 0 || (want_st == 0 && want_out == len) ||
      !le_cache_source_readable(e, t)) {
    if (!lc->job_pending) lc->state = LE_CACHE_LIVE;
    return;
  }
  const uint32_t rev =
      atomic_load_explicit(&tr->a_src_key, memory_order_acquire);
  const uint32_t copy_rev =
      atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  const uint64_t now = atomic_load_explicit(&e->a_frames, memory_order_relaxed);
  const uint64_t key_hash = le_ca_key_hash(
      rev, (uint64_t)(uint32_t)want_st | ((uint64_t)(uint32_t)want_out << 32),
      (uint32_t)lanes, len);
  if (!lc->has_key || key_hash != lc->last_key_hash) {
    lc->has_key = 1;
    lc->last_key_hash = key_hash;
    lc->key_stable_frames = now;
    lc->reason = LE_CACHE_REASON_NONE;
    if (lc->state == LE_CACHE_GAVE_UP) lc->state = LE_CACHE_LIVE;
  }
  le_wet_entry* hit[LE_MAX_LANES];
  int all = lanes > 0;
  for (int l = 0; l < lanes && all; ++l) {
    hit[l] = NULL;
    for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
      le_wet_entry* ent = c->src_lanes[t][l].entries[i];
      if (ent != NULL && le_src_entry_fits(ent, rev, len, want_st, want_out)) {
        hit[l] = ent;
      }
    }
    all = hit[l] != NULL;
  }
  if (all) {
    /* Every retained render is already published; the callback picks it. */
    for (int l = 0; l < lanes; ++l) hit[l]->last_used = c->lru_clock;
    lc->state = LE_CACHE_CACHED;
    return;
  }
  if (lc->job_pending) {
    lc->state = LE_CACHE_RENDERING;
    return;
  }
  if (lc->state == LE_CACHE_GAVE_UP) return; /* until the key changes */
  const int32_t est = le_effective_state(tr);
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  if ((est != LE_TRACK_PLAYING && est != LE_TRACK_STOPPED) ||
      atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire) ||
      now - lc->key_stable_frames <
          (uint64_t)((int64_t)sr * LE_CACHE_SOURCE_SETTLE_MS / 1000)) {
    lc->state = LE_CACHE_LIVE;
    return;
  }
  const int64_t job_bytes =
      le_ca_job_bytes(LE_CACHE_KIND_SOURCE, len, lanes, want_out);
  if (!le_cache_ensure_budget(e, c, cap, job_bytes)) {
    lc->state = LE_CACHE_GAVE_UP; /* re-armed by any key change */
    lc->reason = LE_CACHE_REASON_BUDGET;
    return;
  }
  le_cache_job* job = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS && job == NULL; ++j) {
    if (atomic_load_explicit(&c->jobs[j].a_state, memory_order_acquire) ==
        LE_CACHE_JOB_EMPTY) {
      job = &c->jobs[j];
    }
  }
  float* dry = job != NULL
                   ? (float*)malloc((size_t)lanes * (size_t)len * sizeof(float))
                   : NULL;
  if (dry == NULL) {
    lc->state = LE_CACHE_LIVE; /* queue full or no memory: retry next tick */
    return;
  }
  memset(job->src, 0, sizeof(job->src));
  job->kind = LE_CACHE_KIND_SOURCE;
  job->channel = t;
  job->lane = -1;
  job->lanes = lanes;
  job->semitones = want_st;
  job->out_len = want_out;
  job->audio_rev = rev;
  job->copy_rev = copy_rev;
  job->chain_fp = 0;
  job->vol_bits = 0;
  job->len = len;
  job->sample_rate = sr;
  job->copy_pos = 0;
  job->dry = dry;
  job->wet = NULL;
  c->used_bytes += job_bytes;
  lc->job_pending = 1;
  lc->state = LE_CACHE_RENDERING;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_COPYING,
                        memory_order_release);
}

/* Advances every COPYING job by one bounded chunk [R2](a). The source
 * pointer is re-resolved per chunk on this same control thread — the only
 * thread that swaps a_live or reallocs pool slots — so a chunk can never
 * read a freed buffer. Settled commands and the callback's readable fact
 * exclude autonomous PCM writes; a changed recipe/content key discards the
 * job before the next chunk. On completion the job
 * becomes QUEUED and the worker takes over. */
/* Stages one chunk of a whole-track job's source: the COMBINATION of the
 * track's parts over frames [from, from + n).
 *
 * Each part contributes its own PRINTED material — its published print where
 * it has one, its dry recording at level where its chain is empty — placed by
 * its pan and skipped when muted. A part's print already carries its level
 * (D-VOL bakes it in front of the chain) and is unpanned, exactly the two
 * facts this needs.
 *
 * Control thread, like the dry copy it sits beside, and safe for the same
 * reason: this is the only thread that publishes or retracts a part's print
 * and the only one that swaps a_live, so a source resolved here cannot be
 * freed under it. The part's key is re-checked per chunk; if it moved, the
 * assembly is abandoned and the track simply plays live.
 *
 * Returns 0 when the chunk could not be staged. */
static int le_cache_assemble_chunk(le_engine* e, le_cache_job* job,
                                   int32_t from, int32_t n) {
  le_track* tr = &e->tracks[job->channel];
  const int32_t lanes = le_lanes_active(tr);
  memset(job->dry + 2 * (size_t)from, 0, (size_t)n * 2 * sizeof(float));
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &tr->lanes[l];
    if (load_i32(&ln->a_muted)) continue;
    const float gl = load_f32(&ln->a_pan_gl_bits);
    const float gr = load_f32(&ln->a_pan_gr_bits);
    le_wet_entry* ent =
        atomic_load_explicit(&ln->a_wet, memory_order_acquire);
    if (ent != NULL) {
      /* The part's print. Its key must still be the one the job was keyed
       * against, or the combination this assembles is not the one published. */
      if (!le_wet_entry_key_matches(
              ent, job->audio_rev, le_lane_pre_fx_fingerprint(e, job->channel, l),
              atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed),
              job->len)) {
        return 0;
      }
      for (int32_t f = from; f < from + n; ++f) {
        job->dry[2 * f] += ent->pcm[2 * f] * gl;
        job->dry[2 * f + 1] += ent->pcm[2 * f + 1] * gr;
      }
      continue;
    }
    /* No print: only an EMPTY chain is allowed here, and its dry recording at
     * level IS its printed material. A part with a chain and no print means
     * the render cannot describe the track — the scheduler refuses those, so
     * reaching one here is a key that moved. */
    if (load_i32(&ln->a_fx_count) > 0) return 0;
    const float* src = ln->pool[load_i32(&ln->a_live)];
    if (src == NULL) return 0;
    const float vol = load_f32(&ln->a_vol_bits);
    for (int32_t f = from; f < from + n; ++f) {
      const float v = src[f] * vol;
      job->dry[2 * f] += v * gl;
      job->dry[2 * f + 1] += v * gr;
    }
  }
  return 1;
}

static void le_cache_copy_step(le_engine* e, struct le_fx_cache* c) {
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    le_cache_job* job = &c->jobs[j];
    if (atomic_load_explicit(&job->a_state, memory_order_relaxed) !=
        LE_CACHE_JOB_COPYING) {
      continue;
    }
    le_track* tr = &e->tracks[job->channel];
    int discard = !le_cache_source_readable(e, job->channel) ||
                  !le_cache_copy_key_matches(e, job);
    if (!discard && job->kind == LE_CACHE_KIND_SOURCE) {
      int32_t n = job->len - job->copy_pos;
      if (n > LE_CACHE_COPY_CHUNK_FRAMES) n = LE_CACHE_COPY_CHUNK_FRAMES;
      for (int32_t l = 0; l < job->lanes && !discard; ++l) {
        le_lane* ln = &tr->lanes[l];
        const float* src = ln->pool[load_i32(&ln->a_live)];
        discard = src == NULL;
        if (!discard) {
          memcpy(job->dry + (size_t)l * (size_t)job->len + job->copy_pos,
                 src + job->copy_pos, (size_t)n * sizeof(float));
        }
      }
      if (!discard) {
        job->copy_pos += n;
        if (job->copy_pos < job->len) continue; /* more chunks next tick */
        atomic_thread_fence(memory_order_acquire);
        discard = !le_cache_copy_key_matches(e, job);
      }
    } else if (!discard && job->kind == LE_CACHE_KIND_TRACK) {
      int32_t n = job->len - job->copy_pos;
      if (n > LE_CACHE_COPY_CHUNK_FRAMES) n = LE_CACHE_COPY_CHUNK_FRAMES;
      discard = !le_cache_assemble_chunk(e, job, job->copy_pos, n);
      if (!discard) {
        job->copy_pos += n;
        if (job->copy_pos < job->len) continue; /* more chunks next tick */
        atomic_thread_fence(memory_order_acquire);
        discard = !le_cache_copy_key_matches(e, job);
      }
    } else if (!discard) {
      le_lane* ln = &tr->lanes[job->lane];
      const float* src = ln->pool[load_i32(&ln->a_live)];
      discard = src == NULL;
      if (discard) goto copy_done;
      int32_t n = job->len - job->copy_pos;
      if (n > LE_CACHE_COPY_CHUNK_FRAMES) n = LE_CACHE_COPY_CHUNK_FRAMES;
      memcpy(job->dry + job->copy_pos, src + job->copy_pos,
             (size_t)n * sizeof(float));
      job->copy_pos += n;
      if (job->copy_pos < job->len) continue; /* more chunks next tick */
      /* Completion: reject a stale content or recipe key. PCM ownership was
       * established before copying; this fence is not a lock for PCM. */
      atomic_thread_fence(memory_order_acquire);
      discard = !le_cache_copy_key_matches(e, job);
    }
  copy_done:
    if (discard) {
      c->used_bytes -=
          le_ca_job_bytes(job->kind, job->len, job->lanes, job->out_len);
      free(job->dry);
      job->dry = NULL;
      le_lane_cache* book = le_ca_book(c, job->kind, job->channel, job->lane);
      book->job_pending = 0;
      book->state = LE_CACHE_LIVE;
      atomic_store_explicit(&job->a_state, LE_CACHE_JOB_EMPTY,
                            memory_order_release);
      continue;
    }
    atomic_store_explicit(&job->a_state, LE_CACHE_JOB_QUEUED,
                          memory_order_release);
  }
}

/* ---- offline chain rendering (shared with the render recipe) ---- */

void le_fx_frozen_fill(le_fx_frozen_chain* c, int32_t count, int32_t pre,
                       int32_t chain_on, const int32_t* types,
                       const int32_t* enabled,
                       const float params[LE_FX_MAX][LE_FX_PARAMS],
                       const le_fx_chan* chan, int32_t chan_any) {
  memset(c, 0, sizeof(*c));
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  if (pre < 0) pre = 0;
  if (pre > count) pre = count;
  c->count = count;
  c->pre = pre;
  for (int32_t s = 0; s < count; ++s) {
    c->type[s] = types[s];
    c->effective[s] = chain_on && enabled[s];
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) c->params[s][p] = params[s][p];
  }
  c->chan_any = chan_any;
  for (int32_t s = 0; s < LE_FX_MAX; ++s) c->chan[s] = chan[s];
}

void le_fx_frozen_capture(le_fx_frozen_chain* c, _Atomic int32_t* count,
                          _Atomic int32_t* pre, _Atomic int32_t* chain_on,
                          _Atomic int32_t* type, _Atomic int32_t* enabled,
                          _Atomic uint32_t (*param)[LE_FX_PARAMS],
                          _Atomic int32_t* chan_in, _Atomic int32_t* chan_out,
                          _Atomic uint32_t* gl, _Atomic uint32_t* gr,
                          _Atomic uint32_t* level) {
  int32_t n = load_i32(count);
  if (n < 0) n = 0;
  if (n > LE_FX_MAX) n = LE_FX_MAX;
  int32_t types[LE_FX_MAX];
  int32_t en[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int32_t s = 0; s < n; ++s) {
    types[s] = load_i32(&type[s]);
    en[s] = load_i32(&enabled[s]) ? 1 : 0;
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) params[s][p] = load_f32(&param[s][p]);
  }
  le_fx_chan chan[LE_FX_MAX];
  int32_t chan_any = 0;
  memset(chan, 0, sizeof(chan));
  le_fx_chan_snapshot(chan, &chan_any, n, chan_in, chan_out, gl, gr, level);
  le_fx_frozen_fill(c, n, load_i32(pre), load_i32(chain_on), types, en, params,
                    chan, chan_any);
}

int le_fx_frozen_has(const le_fx_frozen_chain* c, int32_t from, int32_t to,
                     int32_t type) {
  if (to > c->count) to = c->count;
  for (int32_t s = from < 0 ? 0 : from; s < to; ++s) {
    if (type == LE_FX_NONE ? c->type[s] != LE_FX_NONE : c->type[s] == type) {
      return 1;
    }
  }
  return 0;
}

void le_fx_frozen_bits(const le_fx_frozen_chain* c, int32_t from, int32_t to,
                       int32_t out[LE_FX_MAX]) {
  for (int32_t s = 0; s < LE_FX_MAX; ++s) {
    out[s] = s >= from && s < to && s < c->count && c->effective[s];
  }
}

int32_t le_fx_frozen_state_init(le_fx_state* fx, const le_fx_frozen_chain* c,
                                int32_t from, int32_t to, int32_t cap) {
  int32_t bits[LE_FX_MAX];
  le_fx_frozen_bits(c, from, to, bits);
  /* Seed the enable-crossfade runtime per EFFECTIVE bit, mirroring the live
   * chain's settled state exactly: enabled slots settled wet (no fade-in at
   * frame 0), disabled slots settled bypass (no 5 ms fade-out the live chain
   * would not have). */
  for (int s = 0; s < LE_FX_MAX; ++s) {
    if (bits[s]) {
      le_fx_enable_seed_settled(fx, s);
    } else {
      le_fx_enable_force_bypass(fx, s);
    }
  }
  /* The channel cache the live chain reads per buffer, frozen with it. */
  fx->chan_any = c->chan_any;
  for (int s = 0; s < LE_FX_MAX; ++s) fx->chan[s] = c->chan[s];
  int32_t rc = LE_OK;
  for (int32_t s = 0; s < c->count; ++s) {
    /* Match the live chain's slot state exactly: the SET_*_FX ring handler
     * runs le_fx_entry_reset on the audio thread when a type lands, so the
     * fresh state starts from that same reset (a raw calloc zero differs —
     * e.g. the octaver's shift smoother seeds at unison 0.5, not 0.0). A
     * hosted plugin's offline slot stays NULL and renders dry. */
    le_fx_entry_reset(fx, s);
    /* Only the entries this state processes own buffers (review L5). */
    if (s >= from && s < to && c->type[s] != LE_FX_NONE &&
        c->type[s] != LE_FX_PLUGIN &&
        le_fx_prepare(fx, s, c->type[s], cap) != LE_OK) {
      rc = LE_ERR_INVALID; /* OOM on a ring/octaver heap: a real failure, not
                            * a silent dry-slot degradation */
    }
  }
  return rc;
}

int32_t le_fx_print(const le_fx_frozen_chain* c, int32_t count,
                    const float* src, int stereo, float vol, int32_t len,
                    int32_t sample_rate, int32_t cap, float* out,
                    int (*abort_fn)(void*), void* arg) {
  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) return LE_ERR_INVALID;
  if (count > c->count) count = c->count;
  int32_t rc = le_fx_frozen_state_init(fx, c, 0, count, cap);
  int32_t bits[LE_FX_MAX];
  le_fx_frozen_bits(c, 0, count, bits);
  /* RENDER-TWICE-KEEP-SECOND: pass 1 is exactly the chain's first live lap,
   * so the kept pass matches a live chain that engaged at the previous loop
   * top, with tails that wrap the loop boundary baked in. */
  for (int pass = 0; pass < 2 && rc == LE_OK; ++pass) {
    for (int32_t f = 0; f < len; ++f) {
      if ((f % LE_CACHE_ABORT_CHECK_FRAMES) == 0 && abort_fn != NULL &&
          abort_fn(arg)) {
        rc = LE_ERR_NOT_READY;
        break;
      }
      float l;
      float r;
      if (stereo) {
        l = src[2 * f];
        r = src[2 * f + 1];
      } else {
        l = src[f] * vol;
        r = l;
      }
      fx_apply_chain(fx, sample_rate, cap, &l, &r, count, c->type, c->params,
                     bits);
      if (pass == 1) {
        out[2 * f] = l;
        out[2 * f + 1] = r;
      }
    }
  }
  le_fx_state_free_buffers(fx); /* the shared offline-state teardown */
  free(fx);
  return rc;
}

int le_cache_shutting_down(le_engine* engine) {
  struct le_fx_cache* c = engine->cache;
  return c != NULL && atomic_load_explicit(&c->a_shutdown, memory_order_acquire);
}

int le_cache_source_ready(le_engine* engine, int32_t channel) {
  return le_cache_source_readable(engine, channel);
}

/* ---- the render worker [B6] ---- */

/* Picks the next queued job for a lane currently audible [B6], or NULL with
 * the first queued stopped-lane job in *out_fallback. */
static le_cache_job* le_cache_pick(le_engine* e, struct le_fx_cache* c,
                                   le_cache_job** out_fallback) {
  le_cache_job* fallback = NULL;
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    le_cache_job* job = &c->jobs[j];
    if (atomic_load_explicit(&job->a_state, memory_order_acquire) !=
        LE_CACHE_JOB_QUEUED) {
      continue;
    }
    const int32_t st = load_i32(&e->tracks[job->channel].a_state);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) return job;
    if (fallback == NULL) fallback = job;
  }
  *out_fallback = fallback;
  return NULL;
}

/* Renders one job: dry x volume through the engine's own fx_apply_chain on a
 * worker-owned heap le_fx_state — the perf_render pattern, no forked DSP.
 * RENDER-TWICE-KEEP-SECOND: the loop is processed twice back-to-back and only
 * the second pass is kept, so delay/reverb tails that wrap the loop boundary
 * are baked in (pass 1 is exactly the chain's first live lap, so the kept
 * pass matches a live chain that engaged at the previous loop top). Aborts
 * on an a_audio_rev bump for its lane or on shutdown [B5], checked once per
 * LE_CACHE_ABORT_CHECK_FRAMES block. */
/* Renders a Transpose job: each lane's take through the stretch shim as one
 * lap of a loop (cyclic pre-roll and run-out, so the render loops as
 * seamlessly as the take), at the job's pitch, exact length, fixed seed.
 * Checks between lanes whether the key moved (a second step, a content
 * change) and aborts so the re-keyed job runs next. */
static void le_cache_render_source(le_engine* e, struct le_fx_cache* c,
                                   le_cache_job* job) {
  int32_t outcome = LE_CACHE_JOB_DONE;
  for (int32_t l = 0; l < job->lanes && outcome == LE_CACHE_JOB_DONE; ++l) {
    if (atomic_load_explicit(&c->a_shutdown, memory_order_acquire) ||
        !le_ca_source_current(e, job)) {
      outcome = LE_CACHE_JOB_ABORTED;
      break;
    }
    job->src[l] = (float*)malloc((size_t)job->out_len * sizeof(float));
    if (job->src[l] == NULL ||
        le_stretch_render_loop(job->dry + (size_t)l * (size_t)job->len,
                               job->len, job->out_len, job->sample_rate,
                               (float)job->semitones,
                               8000.0f / (float)job->sample_rate, 1,
                               LE_CACHE_SOURCE_SEED,
                               job->sample_rate * LE_CACHE_SOURCE_FOLD_MS / 1000,
                               job->src[l]) != LE_STRETCH_OK) {
      outcome = LE_CACHE_JOB_FAILED;
    }
  }
  if (outcome != LE_CACHE_JOB_DONE) {
    for (int32_t l = 0; l < job->lanes; ++l) {
      free(job->src[l]);
      job->src[l] = NULL;
    }
  }
  atomic_store_explicit(&job->a_state, outcome, memory_order_release);
}

typedef struct le_cache_abort_ctx {
  struct le_fx_cache* c;
  le_track* tr;
  uint32_t audio_rev;
} le_cache_abort_ctx;

static int le_cache_job_aborted(void* arg) {
  const le_cache_abort_ctx* a = (const le_cache_abort_ctx*)arg;
  return atomic_load_explicit(&a->c->a_shutdown, memory_order_acquire) ||
         atomic_load_explicit(&a->tr->a_audio_rev, memory_order_acquire) !=
             a->audio_rev;
}

static void le_cache_render(le_engine* e, struct le_fx_cache* c,
                            le_cache_job* job) {
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_RUNNING,
                        memory_order_release);
  if (job->kind == LE_CACHE_KIND_SOURCE) {
    le_cache_render_source(e, c, job);
    return;
  }
  float* wet = (float*)malloc(2u * (size_t)job->len * sizeof(float));
  if (wet == NULL) {
    atomic_store_explicit(&job->a_state, LE_CACHE_JOB_FAILED,
                          memory_order_release);
    return;
  }
  /* A part's job stages its mono recording and bakes its level in front of
   * the chain (D-VOL); a whole-track job stages the already-combined stereo
   * pair, with every part's level already inside it. */
  le_cache_abort_ctx abort_ctx = {c, &e->tracks[job->channel], job->audio_rev};
  const int32_t rc = le_fx_print(
      &job->chain, job->chain.count, job->dry, job->kind == LE_CACHE_KIND_TRACK,
      job->vol, job->len, job->sample_rate, job->fx_cap, wet,
      le_cache_job_aborted, &abort_ctx);
  if (rc != LE_OK) {
    free(wet);
    atomic_store_explicit(
        &job->a_state,
        rc == LE_ERR_NOT_READY ? LE_CACHE_JOB_ABORTED : LE_CACHE_JOB_FAILED,
        memory_order_release);
    return;
  }
  job->wet = wet;
  atomic_store_explicit(&job->a_state, LE_CACHE_JOB_DONE,
                        memory_order_release);
}

static void le_ca_worker_main(void* arg) {
  le_engine* e = (le_engine*)arg;
  struct le_fx_cache* c = e->cache; /* stable: shutdown joins before free */
#if defined(__linux__)
  /* E9: SCHED_OTHER at nice +10, so an eight-lane Transpose render yields to
   * the UI thread (nice is per thread on Linux; the audio thread is FIFO). */
  setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 10);
#endif
  /* Idle backoff: 1 ms while work is flowing, doubling to a 32 ms ceiling
   * when the queue stays empty — ~30 wakeups/s idle instead of ~1000, which
   * matters on the battery/appliance targets. Pickup latency stays far below
   * the 250 ms settle debounce, and shutdown join latency is bounded by one
   * ceiling sleep. */
  int idle_ms = 1;
  /* Prints for audible lanes come first; a render recipe (engine_render.c)
   * takes one slice next, then prints for stopped lanes. Aging: once
   * LE_RENDER_MAX_YIELDS audible prints have gone ahead of a waiting recipe,
   * the recipe's next slice goes first, so continuous re-keys cannot starve
   * it and a slice never holds an audible print back by more than one. */
  int yields = 0;
  while (!atomic_load_explicit(&c->a_shutdown, memory_order_acquire)) {
    le_cache_job* fallback = NULL;
    le_cache_job* job = le_cache_pick(e, c, &fallback);
    if (le_render_worker_choice(job != NULL, le_render_worker_ready(e),
                                &yields)) {
      idle_ms = 1;
      le_render_worker_step(e);
      continue;
    }
    if (job == NULL) job = fallback;
    if (job == NULL) {
      le_ca_sleep_ms(idle_ms);
      if (idle_ms < 32) idle_ms *= 2;
      continue;
    }
    idle_ms = 1;
    le_cache_render(e, c, job);
  }
}

/* ---- lifecycle + tick ---- */

void le_cache_init(le_engine* engine) {
  if (engine == NULL || engine->cache != NULL) return;
  struct le_fx_cache* c =
      (struct le_fx_cache*)calloc(1, sizeof(struct le_fx_cache));
  if (c == NULL) return; /* caching disabled; everything plays live */
  c->engine = engine;
  engine->cache = c;
  if (!le_ca_thread_start(&c->worker, engine)) {
    engine->cache = NULL;
    free(c);
    return;
  }
  c->worker_started = 1;
}

void le_cache_shutdown(le_engine* engine) {
  if (engine == NULL || engine->cache == NULL) return;
  struct le_fx_cache* c = engine->cache;
  /* Join-before-free [R2](d): the worker observes the flag at its next
   * per-block abort check, so a mid-render join is bounded. */
  atomic_store_explicit(&c->a_shutdown, 1, memory_order_release);
  if (c->worker_started) le_ca_thread_join(c->worker);
  /* A render recipe on this worker cannot finish now: fail it with DEVICE
   * and drop its byte charge with the books it was charged to. */
  le_render_on_cache_shutdown(engine);
  /* Every caller guarantees the audio thread is stopped here, so the frees
   * below need no quiescent window — retract everything into the graveyard,
   * then force-sweep it, so a later restart can never observe a dangling
   * entry and nothing leaks. */
  le_cache_free_all_entries(engine, c);
  le_cache_sweep_graveyard(engine, c, 1);
  for (int j = 0; j < LE_CACHE_JOB_SLOTS; ++j) {
    free(c->jobs[j].dry);
    free(c->jobs[j].wet);
    for (int l = 0; l < LE_MAX_LANES; ++l) free(c->jobs[j].src[l]);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &engine->tracks[t].lanes[l];
      atomic_store_explicit(&ln->a_wet, NULL, memory_order_release);
      store_i32(&ln->a_cache_active, 0);
    }
    /* The whole-track print too, or a restart would observe a dangling
     * pointer the free above already released. */
    atomic_store_explicit(&engine->tracks[t].a_track_wet, NULL,
                          memory_order_release);
    store_i32(&engine->tracks[t].a_track_cache_active, 0);
    /* Transpose's views of the renders just freed (#1179): the audio thread
     * is stopped, so these are plain resets; the track plays dry on restart
     * until its render lands again. */
    le_track* tr = &engine->tracks[t];
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_SRC_CANDIDATES; ++i) {
        atomic_store_explicit(&tr->lanes[l].a_src[i], NULL,
                              memory_order_release);
      }
      atomic_store_explicit(&tr->a_turn_src[l], NULL, memory_order_release);
      atomic_store_explicit(&tr->a_src_pin[l], NULL, memory_order_release);
      store_i32(&tr->a_src_out, 0);
      tr->src_ent[l] = NULL;
      tr->turn_ent[l] = NULL;
    }
    tr->transpose_eff = 0;
    store_i32(&tr->a_transpose_eff, 0);
  }
  engine->cache = NULL;
  free(c);
}

void le_cache_evict_lanes(le_engine* engine, int32_t channel, int32_t from,
                          int32_t to) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) return;
  if (from < 0) from = 0;
  if (to > LE_MAX_LANES) to = LE_MAX_LANES;
  struct le_fx_cache* c = engine->cache;
  for (int32_t l = from; l < to; ++l) {
    le_lane* ln = &engine->tracks[channel].lanes[l];
    if (c != NULL) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(engine, c, LE_CACHE_KIND_LANE, channel, l, i);
      }
      /* The lane's key identity dies with its entries: a re-grown lane is
       * reset to defaults and must re-register (and re-settle) from scratch.
       * job_pending is deliberately left alone — an in-flight render is
       * collected and then reclaimed by the tick's deactivated-lane sweep. */
      c->lanes[channel][l].has_key = 0;
      if (!c->lanes[channel][l].job_pending) {
        c->lanes[channel][l].state = LE_CACHE_LIVE;
      }
    }
    /* Belt and braces: no published entry may outlive the shrink even if the
     * bookkeeping lost track of it (retraction only — the entry object stays
     * owned by the tables/graveyard above). */
    atomic_store_explicit(&ln->a_wet, NULL, memory_order_release);
  }
}

void le_cache_tick(le_engine* engine) {
  struct le_fx_cache* c = engine->cache;
  if (c == NULL) return;
  const int64_t cap =
      atomic_load_explicit(&engine->a_fx_cache_cap, memory_order_relaxed);
  c->lru_clock++;
  le_cache_sweep_graveyard(engine, c, 0); /* passive quiescent frees [R2](c) */
  le_cache_copy_step(engine, c);          /* chunked enqueue copies [R2](a) */
  le_render_tick(engine);                 /* the render recipe's staging */
  le_cache_collect(engine, c, cap);
  if (cap <= 0) {
    /* Caching disabled: free everything; lanes report live. In-flight jobs
     * finish and are discarded by the collect above on later ticks. */
    le_cache_free_all_entries(engine, c);
    for (int t = 0; t < LE_MAX_TRACKS; ++t) {
      for (int l = 0; l < LE_MAX_LANES; ++l) {
        if (!c->lanes[t][l].job_pending) c->lanes[t][l].state = LE_CACHE_LIVE;
      }
      if (!c->tracks[t].job_pending) c->tracks[t].state = LE_CACHE_LIVE;
      if (!c->src_tracks[t].job_pending) c->src_tracks[t].state = LE_CACHE_LIVE;
    }
    return;
  }
  for (int t = 0; t < engine->track_count; ++t) {
    const int32_t lanes = le_lanes_active(&engine->tracks[t]);
    for (int l = 0; l < lanes; ++l) {
      le_cache_schedule_lane(engine, c, cap, t, l);
    }
    /* A lane deactivated by a count shrink is never scheduled again — its
     * retained entries would otherwise linger until LRU pressure. Reclaim
     * them here (cheap NULL checks in the steady state). */
    for (int l = lanes; l < LE_MAX_LANES; ++l) {
      for (int i = 0; i < LE_CACHE_ENTRIES_PER_LANE; ++i) {
        le_cache_drop_entry(engine, c, LE_CACHE_KIND_LANE, t, l, i);
      }
    }
    /* The track's own print AFTER its parts', because it is rendered over
     * their printed material: a part that settles this tick is available to
     * the track on the next one. */
    le_cache_schedule_track(engine, c, cap, t);
    le_cache_schedule_source(engine, c, cap, t);
  }
  /* The cap may have shrunk since entries were installed. */
  (void)le_cache_ensure_budget(engine, c, cap, 0);
}

/* ---- FFI telemetry (log/test-only in v3 [R27]) ---- */

/* The shared per-lane fill both accessors read through — no drain here, so
 * the batch form pays for one drain regardless of lane count and can never
 * drift from what the per-lane form reports. */
static void le_cache_fill_info(le_engine* engine, int32_t channel, int32_t lane,
                               le_lane_cache_info* out) {
  memset(out, 0, sizeof(*out));
  le_track* tr = &engine->tracks[channel];
  le_lane* ln = &tr->lanes[lane];
  out->audio_rev = atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  out->engaged = load_i32(&ln->a_cache_active); /* relaxed telemetry read */
  le_wet_entry* w = atomic_load_explicit(&ln->a_wet, memory_order_relaxed);
  out->entry_frames = w != NULL ? w->len : 0;
  if (engine->cache != NULL) {
    const le_lane_cache* lc = &engine->cache->lanes[channel][lane];
    out->state = lc->state;
    out->reason = lc->reason;
    out->renders = lc->renders;
  } else {
    out->state = LE_CACHE_LIVE;
  }
}

/* The whole-track print's telemetry (slice 3e), the lane query's twin. Its
 * `reason` is the one place the engine says WHY a track's Pre run is running
 * live rather than printed — a part carrying a Post entry, a hosted plugin, a
 * budget that does not fit, a render that failed. */
int32_t le_engine_get_track_cache(le_engine* engine, int32_t channel,
                                  le_lane_cache_info* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine); /* polling drives the cache, as for a lane */
  memset(out, 0, sizeof(*out));
  le_track* tr = &engine->tracks[channel];
  out->audio_rev = atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  out->engaged = load_i32(&tr->a_track_cache_active);
  le_wet_entry* w =
      atomic_load_explicit(&tr->a_track_wet, memory_order_relaxed);
  out->entry_frames = w != NULL ? w->len : 0;
  if (engine->cache != NULL) {
    const le_lane_cache* lc = &engine->cache->tracks[channel];
    out->state = lc->state;
    out->reason = lc->reason;
    out->renders = lc->renders;
  } else {
    out->state = LE_CACHE_LIVE;
  }
  return LE_OK;
}

int32_t le_engine_get_transpose_cache(le_engine* engine, int32_t channel,
                                      le_lane_cache_info* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine); /* polling drives the cache */
  memset(out, 0, sizeof(*out));
  le_track* tr = &engine->tracks[channel];
  out->audio_rev = atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
  out->engaged = load_i32(&tr->a_transpose_eff) != 0;
  le_wet_entry* w =
      atomic_load_explicit(&tr->a_src_pin[0], memory_order_acquire);
  out->entry_frames = w != NULL ? w->out_len : 0;
  if (engine->cache != NULL) {
    const le_lane_cache* lc = &engine->cache->src_tracks[channel];
    out->state = lc->state;
    out->reason = lc->reason;
    out->renders = lc->renders;
  }
  return LE_OK;
}

int32_t le_engine_get_lane_cache(le_engine* engine, int32_t channel,
                                 int32_t lane, le_lane_cache_info* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  /* Polling this drives the cache: drain -> tick (collect/schedule). */
  le_engine_drain_events(engine);
  le_cache_fill_info(engine, channel, lane, out);
  return LE_OK;
}

int32_t le_engine_get_all_lane_caches(le_engine* engine,
                                      le_lane_cache_info* out,
                                      int32_t capacity) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  const int32_t need = engine->track_count * LE_MAX_LANES;
  if (capacity < need) return LE_ERR_INVALID;
  /* ONE drain (and its scheduler tick) for the whole sweep — the entire point
   * of the batch form (#418). */
  le_engine_drain_events(engine);
  for (int32_t t = 0; t < engine->track_count; ++t) {
    for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
      le_cache_fill_info(engine, t, l, &out[t * LE_MAX_LANES + l]);
    }
  }
  return need;
}

int32_t le_engine_set_fx_cache_cap(le_engine* engine, int64_t bytes) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (bytes < 0) bytes = 0;
  atomic_store_explicit(&engine->a_fx_cache_cap, bytes, memory_order_relaxed);
  /* Apply immediately (evict down / free all) rather than waiting a poll. */
  le_cache_tick(engine);
  return LE_OK;
}

int64_t le_engine_fx_cache_used_bytes(le_engine* engine) {
  if (engine == NULL || engine->cache == NULL) return 0;
  return engine->cache->used_bytes;
}

uint32_t le_engine_track_audio_rev(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return 0;
  }
  return atomic_load_explicit(&engine->tracks[channel].a_audio_rev,
                              memory_order_acquire);
}
