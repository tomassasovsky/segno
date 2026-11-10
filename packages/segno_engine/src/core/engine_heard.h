/*
 * engine_heard.h — the heard image's cross-TU seam (#1713).
 *
 * The data model and its lockstep rule are documented with le_heard in
 * engine_private.h. This header is the private contract between the
 * engine's own TUs: the control thread's lifecycle helpers (called beside
 * every pool-slot allocation, resize, retire and free of a lane's clean
 * slot), and the audio thread's capture log, its post-pass and the content
 * operations it replays. Not the FFI surface: le_engine_heard_attach and
 * le_engine_set_lane_source are declared in segno_engine_api.h.
 */
#ifndef SEGNO_ENGINE_HEARD_H
#define SEGNO_ENGINE_HEARD_H

#include "engine_private.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- either thread (callers own the slot under the clean slot's rules) ---- */

/* Lane (ch, l)'s heard image for pool slot [slot]: both planes, or NULL in
 * both when the slot holds none. */
static inline int le_heard_planes(const le_engine* e, int32_t ch, int32_t l,
                                  int32_t slot, float** pl, float** pr) {
  const le_heard* h = &e->heard[ch][l];
  *pl = le_heard_plane(h, 0, slot);
  *pr = le_heard_plane(h, 1, slot);
  return *pl != NULL;
}

static inline int le_heard_has(const le_engine* e, int32_t ch, int32_t l,
                               int32_t slot) {
  return slot >= 0 && slot < LE_POOL_SLOTS &&
         le_heard_plane(&e->heard[ch][l], 0, slot) != NULL;
}

/* Whether lane (ch, l) holds an image in any slot (a_slots, relaxed). */
static inline int le_heard_any(const le_engine* e, int32_t ch, int32_t l) {
  return atomic_load_explicit(&((le_engine*)e)->heard[ch][l].a_slots,
                              memory_order_relaxed) > 0;
}

/* Whether any active lane of [ch] holds an image in [slot]. */
int le_heard_track_has(const le_engine* e, int32_t ch, int32_t slot);

/* Whether lane (ch, l) plays its heard image now: it holds one, its source
 * is HEARD and its live slot holds one. The cache does not print such a
 * lane; a whole-track print takes its image as the part's material. */
int le_heard_lane_plays(const le_engine* e, int32_t ch, int32_t l);

/* ---- control thread ---- */

/* How le_heard_match lets go of planes it replaces or drops: at once (the
 * callback cannot name the slot), or through the retire queue (an EMPTY
 * track's live slot, which a block that emptied it may still hold). */
enum { LE_HEARD_FREE = 0, LE_HEARD_RETIRE = 1 };

/* Makes slot [slot] of lane (ch, l) hold a heard image, or none, to match
 * its clean slot. [want] 0 drops the planes. [want] 1 keeps planes already
 * the clean slot's size (and what they hold: like a REUSED clean slot, the
 * caller writes them whole before they are read), else maps fresh zeroed
 * ones of pool_cap[slot] frames, untouched. A slot whose clean buffer is
 * missing holds none. Returns 0 only when [want] could not be served (the
 * slot is then left with none). */
int le_heard_match(le_engine* e, int32_t ch, int32_t l, int32_t slot, int want,
                   int how);

/* The live slot of every active lane of [ch] matched to [mask] (lane l wants
 * an image when bit l is set) for a fresh capture. [zero]: the capture zeroes
 * its clean live slots (one over a master, or deferred); the image's planes
 * are then replaced by zeroed ones, from the lane's heard zero spare when it
 * has one. A defining capture (no master) keeps cap-sized planes as they are,
 * as it keeps its clean slot: it writes from frame 0 and never reads past
 * what it wrote. Called once the clean live slots are prepared, before the
 * command that starts the capture is posted. The track is EMPTY, so dropped
 * or replaced planes are retired. Returns 0 if an allocation failed (that
 * lane records clean only). */
int le_heard_prepare_capture(le_engine* e, int32_t ch, uint32_t mask,
                             int zero);

/* Whether le_heard_prepare_capture on [t] would REPLACE planes that exist
 * (dropping them is safe against a block still writing them: the table
 * entry goes NULL and the buffer is retired). le_capture_prep_touches_pcm's
 * share for the images (#1146). */
int le_heard_capture_replaces(le_engine* e, int32_t ch, uint32_t mask,
                              int zero);

/* A shadow slot (an overdub's undo layer) for every active lane of [ch]:
 * an image where the lane's live slot holds one (or is being attached),
 * none elsewhere. Called beside the clean slot's allocation. A lane in
 * [standby_mask] took its clean standby for the slot, and takes its heard
 * standby too when that is ready. Returns the lanes whose planes came from
 * a standby (already faulted in). */
uint32_t le_heard_match_shadow(le_engine* e, int32_t ch, int32_t slot,
                               uint32_t standby_mask);

/* Installs [pl] and [pr] (fresh mappings of [cap] frames, the clean slot's
 * size) as slot [slot]'s planes, freeing what it held: for a caller that
 * allocated them before a point it may not fail past. The slot must not be
 * one the callback can name. */
void le_heard_adopt(le_engine* e, int32_t ch, int32_t l, int32_t slot,
                    float* pl, float* pr, int32_t cap);

/* Two fresh untouched mappings of [frames] frames, or neither (returns 0). */
int le_heard_alloc_planes(int32_t frames, float** pl, float** pr);

/* le_lane_shrink_slot's twin. */
void le_heard_shrink(le_engine* e, int32_t ch, int32_t l, int32_t slot,
                     int32_t frames);

/* Frees every plane and spare of lane (ch, l): the lane's clean slots are
 * being freed with nothing able to read them (removed lanes, configure,
 * destroy). */
void le_heard_free_lane(le_engine* e, int32_t ch, int32_t l);

/* Moves lane (ch, l)'s heard standby into [slot] when the clean standby was
 * just taken there (le_lane_take_standby) and the heard one is ready and the
 * same size. Returns whether it did; otherwise the caller matches the slot. */
int le_heard_take_standby(le_engine* e, int32_t ch, int32_t l, int32_t slot);

/* Heard standbys and zero spares, kept beside the clean ones
 * (le_keep_standbys, le_keep_zero_spares): a standby where the lane's live
 * slot holds an image, a zero spare on an EMPTY track's lane whose input
 * runs a chain. [keep] is the clean standby's verdict and [want] its size. */
void le_heard_keep_standby(le_engine* e, int32_t ch, int32_t l, int keep,
                           int32_t want);
void le_heard_keep_zero_spare(le_engine* e, int32_t ch, int32_t l, int want);

/* Bytes a standby of [frames] frames costs for lane (ch, l): the clean
 * buffer, plus two planes when its live slot holds an image. */
size_t le_heard_standby_bytes(const le_engine* e, int32_t ch, int32_t l,
                              int32_t frames);

/* Reaps finished attaches (le_engine_heard_attach): frees the planes of one
 * the callback refused. le_engine_drain_events calls it. */
void le_heard_settle_attaches(le_engine* e);

/* Whether an attach posted on any lane of [ch] has not been handled yet: the
 * callback may be writing that lane's slot entries, so nothing else may. */
int le_heard_attach_pending(const le_engine* e, int32_t ch);

/* Fills out[] with the buffers of lane (ch, l)'s slot [slot]: the clean one,
 * then the image's planes when it holds one. Returns the count (0 when the
 * clean buffer is missing). For the helpers that treat every buffer of a
 * slot alike (prefaulting). */
int le_lane_slot_buffers(const le_engine* e, int32_t ch, int32_t l,
                         int32_t slot, float* out[1 + LE_HEARD_PLANES]);

/* ---- audio thread ---- */

/* The block's heard facts (le_engine.heard_trk, heard_lanes, heard_inputs),
 * the logs emptied, and the input chains a capturing heard lane records added
 * to the block's jobs [par] after the monitored ones. Called once per
 * callback, after le_engine_process queues the monitor jobs and before the
 * frame loop. Returns whether any lane holds an image this block (a heard
 * block: le_engine_process mixes it with mix_tracks_frame_heard). Each
 * heard lane's source change is logged at [frame] (LE_PLOG_HEARD_SOURCE). */
int le_heard_block_begin(le_engine* e, int tc, const int32_t* lane_n,
                         le_fx_par* par, const float* in, int ch_in,
                         uint32_t excluded, const int* mon_has_fx,
                         const int32_t* mon_fx_count, uint64_t frame);

/* Whether track [t] may write its clean take in the coming block, as far as
 * the block's start can tell (le_heard_block_begin). */
int le_heard_track_may_write(le_engine* e, int t);

/* ---- the rendered tails (#1713 part 3, engine_heard_tail.c) ---- */

/* Callback: track [t]'s pass wrote loop position [pos] at FX clock [clock]
 * (le_heard_post, per write record). */
void le_heard_tail_note_write(le_engine* e, int t, uint32_t clock,
                              int32_t pos);
/* Callback, after each post-pass: the sub-block's input for every input a
 * capturing heard lane records, into its ring. */
void le_heard_tail_post(le_engine* e, const le_fx_par* par, const float* in,
                        int ch_in, uint32_t excluded);
/* Callback, at a heard block's start: a pass that stopped writing ends
 * (LE_EVT_HEARD_TAIL), and a published tail adds what is due. */
void le_heard_tail_block(le_engine* e, int tc);
/* Control: an LE_EVT_HEARD_TAIL from the event ring. */
void le_heard_tail_event(le_engine* e, const le_command* evt);
/* Control, from le_engine_drain_events: maps the inputs' rings, publishes
 * rendered tails and frees spent ones. */
void le_heard_tail_poll(le_engine* e);
/* Cache worker: whether a tail waits to be rendered, and render one. */
int le_heard_tail_worker_ready(le_engine* e);
void le_heard_tail_worker_step(le_engine* e);
/* Control, with no callback and the cache worker joined (configure,
 * destroy): every tail and ring freed. */
void le_heard_tail_free_all(le_engine* e);

/* A performance arm (LE_CMD_PERF_ARM, callback): every lane's source is
 * logged again at its next heard block. */
void le_heard_perf_armed(le_engine* e);

/* Logs frame [i]'s writes for track [t] (see le_heard_rec). */
static inline void le_heard_log_write(le_engine* e, int t, int32_t live,
                                      int32_t rec_w, int32_t wdub, float g,
                                      float fb, int32_t shadow,
                                      int32_t seam_w) {
  le_heard_log* lg = &e->heard_log[t];
  if (lg->n >= LE_HEARD_LOG_CAP) {
    lg->dropped++;
    return;
  }
  le_heard_rec* r = &lg->rec[lg->n++];
  r->i = (uint32_t)e->heard_i;
  r->kind = LE_HEARD_REC_WRITE;
  r->pad = 0;
  r->slot = (int16_t)live;
  r->slot2 = (int16_t)shadow;
  r->a = rec_w;
  r->b = wdub;
  r->c = seam_w;
  r->g = g;
  r->fb = fb;
}

/* A content operation on track [t]'s clean slots, made on its images too:
 * logged when it happens inside the first frame loop (replayed after that
 * frame's writes by le_heard_post), applied at once anywhere else (a
 * command, the block start, a closed device). A no-op for a track none of
 * whose lanes holds an image. */
void le_heard_op(le_engine* e, le_track* t, le_heard_rec op);

/* The seam fold (#728) of track [t]'s live slot over [len] by [F] frames,
 * made on its images (le_heard_op), and with [shadow] first the same fold of
 * its in-flight overdub shadow, as le_seam_fold_dub_shadow makes it. Kept
 * out of the folds themselves so the plain mixer compiles as before. */
void le_heard_seam_fold(le_engine* e, le_track* t, int32_t len, int32_t F,
                        int shadow);

/* The post-pass: every logged record of the block, in order, on the planes,
 * with each lane's input chain output for the frame ([par]'s monitor rows,
 * where the chain ran; the input itself where its chain is empty), times
 * the input's capture trim. [b0] is the block's first frame in the
 * callback's buffers. Then each log is emptied. */
void le_heard_post(le_engine* e, const le_fx_par* par, uint32_t b0,
                   const float* in, int ch_in, const float* in_trim,
                   uint32_t excluded);

/* The block-start half of the punch-out drain (le_dub_run_copy) on the
 * images: copies [run] frames at [w0] between live and the shadow on every
 * lane holding both. */
void le_heard_run_copy(le_engine* e, le_track* t, int32_t live, int32_t shadow,
                       int32_t w0, int32_t run, int shadow_to_live);

/* le_truncate_capture_tail's twin: zeroes the images' frames at the write
 * positions [pos] maps captured frames [from, to) to. Block start. */
void le_heard_truncate(le_engine* e, le_track* t, int64_t from, int64_t to,
                       int32_t offset, int32_t known_len);

/* LE_CMD_HEARD_ATTACH's handler (see le_heard.attach). */
void le_heard_attach_apply(le_engine* e, int32_t ch, int32_t l);

#ifdef LE_NATIVE_TESTS
/* Native tests only: every fresh take on every lane records an image, so the
 * whole suite exercises the lockstep with each lane's clean take
 * (le_test_heard_check after every callback). 1 plays it CLEAN (the suite's
 * own sound unchanged); 2 plays it HEARD, so wherever a lane has no chain
 * the suite's sound checks also check the image's playback. */
extern int le_test_heard_force;
extern void (*le_test_heard_check)(le_engine*);
#endif

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_HEARD_H */
