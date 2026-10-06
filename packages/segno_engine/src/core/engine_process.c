/*
 * engine_process.c — THE AUDIO-THREAD TU.
 *
 * Everything the device callback runs lives here and nowhere else: the real-time
 * contract holds for this whole file — no malloc/free, no locks, no syscalls, no
 * unbounded loops. le_engine_process is the block processor the miniaudio / ASIO
 * data callback pumps; it drains the SPSC command ring (apply_command), advances
 * the transport state machine (the finalize_* / handle_* helpers), records /
 * overdubs / mixes, runs the per-lane effect chains (fx_apply_chain), resolves the
 * loopback latency harness, and publishes metering + visualization atomics.
 *
 * Split verbatim out of engine.c (S1) behind the unchanged ABI. The transport
 * handlers live here rather than in a separate engine_transport.c because they run
 * ON the audio thread (invoked only by apply_command and le_engine_process); the
 * control-thread record/undo entry points (le_engine_record etc.) are in
 * engine_commands.c. Shared low-level helpers (valid_channel, le_track_set_len,
 * comp_pos, le_lanes_active) come from engine_core.h; the chain runner from
 * engine_fx.h.
 */
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "audio_ring.h"      /* le_audio_ring_push_frame (performance capture) */
#include "engine_core.h"     /* valid_channel, le_track_set_len, le_mask_to_channel */
#include "engine_fx.h"       /* fx_apply_chain, le_fx_entry_reset */
#include "engine_internal.h" /* le_engine_process prototype */
#include "engine_private.h"  /* le_engine + the published atomics */
#include "le_midi_clock.h"   /* le_midi_clock_advance (C1 24-PPQN clock-send) */
#include "lockfree_ring.h"   /* le_command, le_ring_pop, le_ring_push */
#include "loop_clock.h"      /* le_loop_clock_* */
#include "segno_engine_api.h"
#include "perf_log_ring.h" /* le_perf_log_ring_push, le_perf_log_code (perf event log) */
#include "tempo_grid.h"    /* le_grid_* (pure tempo/bar/subdivision math) */

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
#include <pmmintrin.h> /* _MM_SET_DENORMALS_ZERO_MODE (DAZ) */
#include <xmmintrin.h> /* _MM_SET_FLUSH_ZERO_MODE (FTZ) */
#endif

/* Flush denormals to zero on the audio thread. Decaying FX tails (reverb/delay/
 * phase-vocoder) trend toward ~1e-30, and denormal arithmetic can be orders of
 * magnitude slower — a CPU spike that shows up as a buffer underrun (dropout /
 * click), not as wrong audio. FTZ+DAZ make the FPU treat those as zero. Per
 * thread, so we set it each callback (negligible cost). No-op where unsupported;
 * the inaudible denormals simply remain. */
static inline void le_flush_denormals(void) {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || \
    defined(_M_IX86)
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#elif defined(__aarch64__)
  uint64_t fpcr;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
  fpcr |= (1ull << 24); /* FZ: flush-to-zero */
  __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr));
#endif
}

/* The loopback-latency-harness and auto-record tuning constants (LE_LATENCY_* /
 * LE_AUTO_RECORD_THRESHOLD) live in engine_core.h — shared with le_engine_configure
 * (engine.c), which sizes the latency capture buffer from LE_LATENCY_CAPTURE_DIV. */

/* ---- command handlers (audio thread) ---- */

/* Defined with the per-pass capture machinery below; every path that moves a
 * track into OVERDUBBING calls it so the layer capture is armed. */
static void le_dub_session_start(le_engine* e, le_track* t);

/* Defined below; handle_record's count-in cancel-race grace window (code-
 * review fix) reuses this full "return a track to EMPTY, and if the whole
 * rig is now empty, reset the master/grid too" reset rather than hand-
 * rolling a partial one. */
static void handle_clear(le_engine* e, int32_t ch, int freeze, uint64_t frame);
static void le_primary_reconcile(le_engine* e);
static void sync_grid_to_loop(le_engine* e, int32_t len);
static void apply_undo_to_empty(le_engine* e, int32_t ch, uint64_t frame);
static void le_restore_multiple_or_divisor(le_track* t, int32_t base,
                                           int32_t len);

/* Performance event log (part 3, docs/design/performance-event-log-format.md):
 * pushes one entry into perf.log_ring, tagged with `frame` — the capture
 * frame it occurred at, same epoch as a_perf_frames/the PCM taps below. No-op
 * when not armed; a full ring drops the entry and bumps a dedicated overrun
 * atomic (tracked apart from a_perf_overruns, the PCM-tap counter — a dropped
 * log entry and a dropped audio sample are different failure modes). RT-safe:
 * no allocation, no blocking, mirrors the audio-tap discipline below. */
void le_plog_push(le_engine* e, uint64_t frame, le_command cmd) {
  if (!e->perf.armed) return;
  le_perf_log_entry entry = {.frame = frame};
  if (!le_log_extract(&cmd, &entry.cmd)) return;
  if (!le_perf_log_ring_push(&e->perf.log_ring, entry)) {
    atomic_fetch_add_explicit(&e->a_perf_log_overruns, 1u,
                              memory_order_relaxed);
  }
}

/* Whether the transport is HELD: no track is playing, recording, or
 * overdubbing, so the loop clock sits at the top (advance_transport_frame's
 * idle branch). The audio-thread twin of le_transport_active on the control
 * side — the unpark rule below fires only from this state. */
static int le_transport_held(le_engine* e) {
  for (int32_t c = 0; c < e->track_count; ++c) {
    const int32_t st = load_i32(&e->tracks[c].a_state);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_RECORDING ||
        st == LE_TRACK_OVERDUBBING) {
      return 0;
    }
  }
  return 1;
}

static void le_reset_track_playback(le_track* t) {
  t->playback_offset = 0;
  t->turn_left = 0; /* a parked origin has no old head to mix (#1162) */
  t->once_ended = 0;
  t->once_current_pass = 0;
  t->sounding_frames = 0;
}

/* A track's clock position and its own read length: the shared clock plus
 * its multiple's segment (a Sync division folds the primary's phase into its
 * shorter slice through the modulo in le_direction_index), or the private
 * clock in Free/Song. *len_out is 0 when the track has no material; the
 * position is 0 when no clock is established yet (imported material before
 * the commit). Recording and grid arms keep the musical clock: only reads go
 * through here. */
static int64_t le_track_base_position(le_engine* e, le_track* t,
                                      int32_t* len_out) {
  const int32_t len = load_i32(&t->lanes[0].a_len);
  *len_out = len;
  if (len <= 0) return 0;
  if (e->clock.length > 0) {
    int64_t position = e->clock.position;
    if (load_i32(&t->a_sync_divisor) < 2) {
      int32_t k = load_i32(&t->a_multiple);
      if (k < 1) k = 1;
      position += (int64_t)(((e->loop_iteration - t->start_iter) % (uint64_t)k) *
                            (uint64_t)e->clock.length);
    }
    return position;
  }
  if (t->free_clock.length > 0) return t->free_clock.position;
  return 0;
}

/* The dry index this track reads at its current clock position, in its own
 * direction and from its own origin (#1162; engine_direction.h). Playback can
 * have an origin of its own after Once or a Reverse turn. */
static int32_t le_track_read_index(le_engine* e, le_track* t) {
  int32_t len;
  const int64_t base = le_track_base_position(e, t, &len);
  if (len <= 0) return 0;
  return le_direction_index(t->reversed, t->playback_offset, base, len);
}

/* Only an explicit launch after automatic end restarts the audio. History
 * restoration and ordinary manual Stop keep their separate phase rules. The
 * relaunch starts at the read lap's start in the track's direction (0
 * forward, len - 1 reversed) by re-origining from the current clock position
 * — the same origin rule in every mode, so Free/Song no longer rewinds its
 * private clock (nothing else observed that rewind). */
static void le_restart_once(le_engine* e, le_track* t) {
  if (!t->once_ended) return;
  le_reset_track_playback(t);
  int32_t len;
  const int64_t base = le_track_base_position(e, t, &len);
  if (len <= 0) return;
  t->playback_offset = le_direction_origin(
      t->reversed, le_direction_lap_start(t->reversed, len), base, len);
}

/* The unpark rule: starting to record or play ANYTHING while the transport is
 * held resumes the parked loop — each manually stopped content track returns to
 * PLAYING with its mute preserved (mute silences, park freezes; unparking
 * un-freezes). Callers latch le_transport_held BEFORE mutating state and call
 * this after the start lands. Each resume logs a synthetic LE_CMD_PLAY so a
 * performance-log replay reproduces the resumes a live listener heard. */
static void le_unpark_stopped(le_engine* e, uint64_t frame) {
  for (int32_t c = 0; c < e->track_count; ++c) {
    le_track* t = &e->tracks[c];
    if (load_i32(&t->a_state) != LE_TRACK_STOPPED) continue;
    if (e->launch_committing && (e->launch_stopped_mask & (1u << c))) continue;
    if (t->once_ended) continue; /* an automatic end needs its own launch */
    if (load_i32(&t->lanes[0].a_len) <= 0) continue;
    store_i32(&t->a_state, LE_TRACK_PLAYING);
    le_plog_push(e, frame, (le_command){.code = LE_CMD_PLAY, .arg_i = c});
  }
}

/* The auto-unmute rule, at the one point every capture start funnels through
 * (immediate presses, quantized fires, sound-activated triggers): a muted
 * track unmutes the moment it starts recording — a capture is never silent.
 * Clears any pending mute too (the capture start supersedes it). Lanes that
 * actually flip log a synthetic unmute so a perf-log replay matches. */
static void le_apply_capture_image(le_engine* e, le_track* t, uint64_t frame);

static void le_fade_log(le_engine* e, int ch, uint64_t frame) {
  const le_fade* fade = &e->tracks[ch].fade;
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_FADE,
      .fade_log = {ch, (float)fade->amount, fade->target, fade->seconds}});
}

/* The capture lost exact provenance for this track's live slot (#1143): a slot
 * became live without a staged image, or an image-sourced slot is being
 * written. Logs 323/0 so the derived stem fails instead of replaying PCM the
 * capture cannot name; musical state is unchanged. */
static void le_perf_source_lost(le_engine* e, le_track* t, uint64_t frame) {
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_SOURCE_TRANSPORT,
      .restore_log = {(int32_t)(t - e->tracks), 0, LE_TRACK_EMPTY, 0}});
  t->perf_source_id = 0;
}

/* The direction fact (#1162, LE_PLOG_REVERSE): the exact dry index the
 * callback continues from at `frame` (-1 on a reset, which carries no
 * anchor) and the turn window still mixing the old head. */
static void le_reverse_log(le_engine* e, le_track* t, uint64_t frame,
                           int32_t read_index, int32_t turn_frames) {
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_REVERSE,
      .reverse_log = {(int32_t)(t - e->tracks), t->reversed, read_index,
                      turn_frames}});
}

/* Direction dies with the material (#1162): forward, origin parked, no turn
 * in flight, published and logged. Printed renders need no clearing here —
 * every caller is a content transition that re-keys them. */
static void le_direction_reset(le_engine* e, le_track* t, uint64_t frame) {
  t->reversed = 0;
  t->playback_offset = 0;
  t->turn_left = 0;
  store_i32(&t->a_reversed, 0);
  le_reverse_log(e, t, frame, -1, 0);
}

/* Every material reset: Fade and direction (#1162) go forward together. Also
 * runs for LE_CMD_RESET_TRANSFORMS (82), which is safe for the provenance
 * fields only because 82 is pushed solely on EMPTY tracks (engine_session.c
 * import paths); a future non-EMPTY caller must not reset provenance here
 * (#1143 plan, E8). */
static void le_transform_reset(le_engine* e, le_track* t, uint64_t frame) {
  t->perf_source_slot = -1; /* the next live slot is looked up afresh */
  t->perf_source_id = 0;
  t->fade = (le_fade){1, 1, 0};
  t->fade_sample = 1;
  if (t->fade_generation != UINT64_MAX) ++t->fade_generation;
  le_fade_log(e, (int)(t - e->tracks), frame);
  le_direction_reset(e, t, frame);
}

static void le_fade_publish(le_engine* e, le_track* t) {
  atomic_fetch_add_explicit(&t->a_fade_revision, 1, memory_order_seq_cst);
#ifdef LE_NATIVE_TESTS
  if (t == &e->tracks[0] && le_test_fade_hook) le_test_fade_hook(e, 1);
#else
  (void)e;
#endif
  float amount = (float)t->fade.amount;
  uint32_t bits;
  memcpy(&bits, &amount, sizeof(bits));
  atomic_store_explicit(&t->a_fade_amount, bits, memory_order_seq_cst);
  memcpy(&bits, &t->fade.target, sizeof(bits));
  atomic_store_explicit(&t->a_fade_target, bits, memory_order_seq_cst);
  memcpy(&bits, &t->fade.seconds, sizeof(bits));
  atomic_store_explicit(&t->a_fade_seconds, bits, memory_order_seq_cst);
  atomic_store_explicit(&t->a_fade_generation, t->fade_generation, memory_order_seq_cst);
  atomic_fetch_add_explicit(&t->a_fade_revision, 1, memory_order_seq_cst);
}

static void le_capture_start_unmute(le_engine* e, le_track* t,
                                    uint64_t frame) {
  le_apply_capture_image(e, t, frame);
  const int32_t ch = (int32_t)(t - e->tracks);
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    t->lanes[l].pending_mute = 0;
    if (load_i32(&t->lanes[l].a_muted) == 0) continue;
    store_i32(&t->lanes[l].a_muted, 0);
    le_plog_push(e, frame,
                 (le_command){.code = LE_CMD_SET_LANE_MUTE,
                              .lanef = {ch, l, 0.0f}});
  }
}

/* Lands the mutes deferred during a capture (LE_CMD_SET_LANE_MUTE's capturing
 * branch) now that the capture is ending. Returns the (possibly overridden)
 * end state: a pending mute forces OVERDUBBING down to PLAYING — the user
 * asked for silence mid-take, so the capture must not continue into a rec/dub
 * auto-overdub over it. `apply` = 0 drops the pendings without muting (the
 * nothing-captured -> EMPTY path: a mute on no content is meaningless, and an
 * empty track always comes back unmuted). Applied lanes log the mute at the
 * landing frame, keeping the perf-log replay faithful. */
static int32_t le_consume_pending_mutes(le_engine* e, le_track* t,
                                        int32_t end_state, int apply,
                                        uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  int any = 0;
  for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
    if (!t->lanes[l].pending_mute) continue;
    t->lanes[l].pending_mute = 0;
    any = 1;
    if (!apply) continue;
    store_i32(&t->lanes[l].a_muted, 1);
    le_plog_push(e, frame,
                 (le_command){.code = LE_CMD_SET_LANE_MUTE,
                              .lanef = {ch, l, 1.0f}});
  }
  if (any && apply && end_state == LE_TRACK_OVERDUBBING) {
    return LE_TRACK_PLAYING;
  }
  return end_state;
}

/* ---- tempo grid + click + count-in (audio thread) ----
 *
 * Grid state + locks (A1) and the click voice + count-in built on them (A2);
 * the musical arm machinery is a later part. Everything here is dormant with
 * the grid-off/click-off defaults — the pure math lives in tempo_grid.c;
 * these helpers wire it to engine state. None of these commands is
 * perf-logged: the tempo commands change no audible output in this part, and
 * the click (slice 3b) is captured only as audio, as part of the output bus
 * it is routed to — a replay rebuilds the take from the capture, so logging
 * the click's configuration would be noise the renderer must ignore. */

/* Click voice constants (recovered 2f0513a values): a 30 ms linearly decaying
 * sine burst at 0.25 amplitude — 1000 Hz on beats, 1500 Hz on the bar
 * downbeat. */
#define LE_CLICK_AMP 0.25f
#define LE_CLICK_MS 30
#define LE_CLICK_FREQ_BEAT 1000.0f
#define LE_CLICK_FREQ_DOWNBEAT 1500.0f
#define LE_CLICK_TWO_PI 6.28318530717958647692f

/* (Re)starts the click burst for a beat that begins this frame. */
static void trigger_click(le_engine* e, int downbeat) {
  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  e->click_len = sr * LE_CLICK_MS / 1000;
  if (e->click_len < 1) e->click_len = 1;
  e->click_remaining = e->click_len;
  e->click_phase = 0.0f;
  e->click_freq = downbeat ? LE_CLICK_FREQ_DOWNBEAT : LE_CLICK_FREQ_BEAT;
}

/* Drops an in-progress count-in back to idle (cancel and commit both funnel
 * through here). The current click burst, if any, decays out naturally — only
 * future beats stop. */
static void le_count_in_reset(le_engine* e) {
  for (int c = 0; c < e->track_count; ++c) {
    if (e->launch_action[c]) {
      e->tracks[c].pending_image.revision = 0;
      e->tracks[c].pending_fx = NULL;
      e->tracks[c].pending_capture_shadow = 0;
    }
    e->launch_action[c] = 0;
    /* A commit keeps each member's pending flag until its grace flag is
     * stored (le_count_in_commit), so a control thread never reads both as
     * clear while the launch is still cancellable; a cancellation clears it
     * here, since no grace follows. */
    if (!e->launch_committing) store_i32(&e->tracks[c].a_pending_launch, 0);
  }
  e->launch_count = 0;
  e->launch_stopped_mask = 0;
  e->count_in_total = 0;
  e->count_in_elapsed = 0;
  e->count_in_beats = 0;
  e->count_in_beat = 0;
  store_i32(&e->a_counting_in, 0);
  store_i32(&e->a_count_in_beats_left, 0);
}

/* Starts the common stopped-launch clock. Beat boundaries render from their index
 * against the frozen nominal frames-per-beat, so the recording starts exactly
 * bars * ts_num * fpb frames after the press — the bar-1 downbeat. Returns 1
 * when counting began, 0 on a degenerate grid (caller records immediately). */
static int le_count_in_begin(le_engine* e, int32_t bars) {
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  const double fpb = le_grid_frames_per_beat_unit(&g);
  if (fpb <= 0.0) return 0; /* degenerate: nothing to click against */
  const int32_t beats = bars * num;
  e->count_in_fpb = fpb;
  e->count_in_beats = beats;
  e->count_in_total = (int32_t)llround((double)beats * fpb);
  if (e->count_in_total < 1) e->count_in_total = 1;
  e->count_in_elapsed = 0;
  e->count_in_beat = 0;
  store_i32(&e->a_counting_in, 1);
  store_i32(&e->a_count_in_beats_left, beats);
  return 1;
}

/* Retire exactly one pending launch. Keep the shared phase while siblings
 * remain; cancel/requeue is a new insertion, never a reused array position. */
static int le_launch_remove(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch) || !e->launch_action[ch]) return 0;
  if (e->launch_action[ch] == 2 || e->launch_action[ch] == 3) e->launch_stopped_mask |= 1u << ch;
  e->launch_action[ch] = 0;
  store_i32(&e->tracks[ch].a_pending_launch, 0);
  e->tracks[ch].pending_image.revision = 0;
  e->tracks[ch].pending_fx = NULL;
  e->tracks[ch].pending_capture_shadow = 0;
  for (int i = 0; i < e->launch_count; ++i) {
    if (e->launch_order[i] != ch) continue;
    for (int j = i + 1; j < e->launch_count; ++j)
      e->launch_order[j - 1] = e->launch_order[j];
    --e->launch_count;
    break;
  }
  if (e->launch_count == 0) le_count_in_reset(e);
  return 1;
}

static int le_launch_defer(le_engine* e, int32_t ch, int action) {
  if (e->launch_committing) return 0;
  if (le_launch_remove(e, ch)) return 1;
  if (e->count_in_total == 0) {
    const int bars = load_i32(&e->a_record_start);
    if (!le_transport_held(e) || bars <= 0 || !le_count_in_begin(e, bars))
      return 0;
  }
  e->launch_action[ch] = action;
  e->launch_order[e->launch_count++] = ch;
  e->launch_stopped_mask &= ~(1u << ch);
  store_i32(&e->tracks[ch].a_pending_launch, action);
  return 1;
}

/* The D6 tempo lock: manual tempo / signature changes (and taps) are ignored
 * while any track has content AND a grid exists (loop_bars > 0 or
 * tempo_source != none). Only clearing every track releases it — a paused or
 * stopped track still holds the lock, and a derived tempo's source loop being
 * cleared does not (the surviving grid keeps the lock while siblings play).
 * Deliberate: content recorded free-form (sync off) with a manually-set
 * tempo also locks — the tempo was audible context for the take, and
 * pre-stretch there is no way to honor a change (D6's safe reading; matches
 * the Sheeran, which locks tempo after any recording).
 * The loop_bars half of the disjunct is defensive redundancy today: every
 * path that sets loop_bars > 0 also leaves tempo_source != none (sync
 * derivation marks DERIVED; the round-to-bars path requires a source), so no
 * reachable state distinguishes it. It stays per the plan's literal predicate
 * as a belt against future states that might break that invariant.
 *
 * EXTENSION (code-review fix, A2): also locked while a count-in is running
 * (count_in_total > 0), even though the defining track is still EMPTY at
 * that point (it only becomes RECORDING at le_count_in_commit) — the
 * "any_content" test above would otherwise miss this window entirely. The
 * count-in's click schedule (count_in_fpb/count_in_beats/count_in_total) is
 * already frozen from the CURRENT tempo the instant it begins
 * (le_count_in_begin); letting a tempo/signature change through mid-count
 * would leave the audible click counting the OLD rate while
 * sync_grid_to_loop later built the finalized loop's beat grid from the NEW
 * one — a silent mismatch between what was heard and what was recorded.
 * This is D6's same "tempo is locked once it's audibly committed to" spirit,
 * just extended one edge earlier: the count-in IS the commitment moment, not
 * the first captured sample. */
static int le_tempo_locked(le_engine* e) {
  if (e->count_in_total > 0) return 1;
  int any_content = 0;
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (load_i32(&e->tracks[t].a_state) != LE_TRACK_EMPTY) {
      any_content = 1;
      break;
    }
  }
  if (!any_content) return 0;
  return load_i32(&e->a_loop_bars) > 0 ||
         load_i32(&e->a_tempo_source) != LE_TEMPO_SOURCE_NONE;
}

/* Transport edits such as exact tempo restore require a stopped rig.
 * Mode switches additionally validate spans, then stop eligible playback
 * inside their own command so refusal cannot leave partially stopped tracks. */
static int le_transport_edit_blocked(le_engine* e) {
  if (e->count_in_total > 0) return 1;
  for (int32_t t = 0; t < e->track_count; ++t) {
    le_track* tr = &e->tracks[t];
    const int32_t st = load_i32(&tr->a_state);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) return 1;
    if (tr->pending_record) return 1;
    if (st == LE_TRACK_PLAYING && load_i32(&tr->lanes[0].a_len) > 0) return 1;
  }
  return 0;
}

static int le_looper_mode_switch_blocked(le_engine* e, int32_t mode) {
  if (e->count_in_total > 0) return 1;
  for (int32_t c = 0; c < e->track_count; ++c) {
    le_track* t = &e->tracks[c];
    const int32_t state = load_i32(&t->a_state);
    if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING ||
        t->pending_record || load_i32(&t->a_layer_in_flight)) return 1;
  }
  if (mode != LE_LOOPER_MODE_FREE && mode != LE_LOOPER_MODE_SONG) {
    const int32_t primary = le_mode_base_channel(e, mode);
    if (primary >= 0) {
      const int32_t base = load_i32(&e->tracks[primary].lanes[0].a_len);
      for (int32_t t = 0; t < e->track_count; ++t) {
        if (!le_mode_span_fits(mode, base,
                              load_i32(&e->tracks[t].lanes[0].a_len))) return 1;
      }
    }
  }
  return 0;
}

/* Lands a looper-mode switch (LE_CMD_SET_LOOPER_MODE) on a stopped rig,
 * re-clocking recorded takes for the target without touching their audio:
 *   - into SONG/FREE: every take runs its own clock at its unchanged length
 *     and the shared master goes dormant (those modes record and play on
 *     per-track clocks — finalize_master's free-mode branch);
 *   - into MULTI/SYNC/BAND: the shared master is (re)established from the
 *     base take's span (le_mode_base_channel: the shortest take for Multi,
 *     the primary for Sync/Band) and each take's multiple or division is
 *     re-derived from its length (le_restore_multiple_or_divisor), the
 *     per-track clocks going dormant.
 * Every playhead restarts from the top — the rig is stopped, as the gate
 * guarantees. An empty rig only records the new mode. */
static void le_apply_mode_switch(le_engine* e, int32_t m) {
  const int32_t prev = load_i32(&e->a_looper_mode);
  if (prev == m) return;
  store_i32(&e->a_looper_mode, m);
  const int to_free = m == LE_LOOPER_MODE_FREE || m == LE_LOOPER_MODE_SONG;
  /* Free/Song put the shared master DORMANT, and that must happen whether or
   * not anything is recorded — before the "nothing to re-clock" return below.
   * An undo-to-empty deliberately keeps the master so redo can restore
   * through it, so an empty-looking rig can still be carrying a live clock;
   * leaving it running here let the next Free take be rounded to the erased
   * take's length and play on its clock rather than its own. Both halves of
   * this function then leave the master a pure function of the mode. */
  if (to_free) {
    le_loop_clock_reset(&e->clock);
    e->loop_iteration = 0;
    store_i32(&e->a_master_len, 0);
    store_i32(&e->a_master_pos, 0);
    /* The grid dies with the master it measured: a shared bar count means
     * nothing once every take runs its own clock. The TEMPO and its source
     * survive, exactly as at handle_clear's all-empty reset (D6). */
    store_i32(&e->a_loop_bars, 0);
    store_i32(&e->a_current_beat, 0);
    e->grid_total_beats = 0;
    e->grid_prev_beat = -1;
    e->loop_viz_bucket = -1;
  }
  const int32_t primary = le_mode_base_channel(e, m);
  if (primary < 0) return; /* nothing recorded: nothing to re-clock */
  if (!to_free) {
    const int32_t base = load_i32(&e->tracks[primary].lanes[0].a_len);
    le_loop_clock_set_length(&e->clock, base);
    e->loop_iteration = 0;
    store_i32(&e->a_master_len, base);
    store_i32(&e->a_master_pos, 0);
    e->loop_viz_bucket = -1;
    /* The shared grid follows the master, as it does at a defining
     * finalize: an existing tempo rounds the bar count, none derives one. */
    sync_grid_to_loop(e, base);
  }
  for (int32_t t = 0; t < e->track_count; ++t) {
    le_track* tr = &e->tracks[t];
    const int32_t len = load_i32(&tr->lanes[0].a_len);
    tr->start_iter = 0;
    tr->free_iteration = 0;
    tr->playback_offset = 0;
    tr->sounding_frames = 0;
    e->trk_play_pos[t] = 0;
    e->track_viz_bucket[t] = -1;
    if (len <= 0) {
      le_loop_clock_reset(&tr->free_clock);
      continue;
    }
    if (to_free) {
      le_loop_clock_set_length(&tr->free_clock, len);
      store_i32(&tr->a_multiple, 1);
      store_i32(&tr->a_sync_divisor, 0);
    } else {
      le_loop_clock_reset(&tr->free_clock);
      le_restore_multiple_or_divisor(
          tr, load_i32(&e->tracks[primary].lanes[0].a_len), len);
    }
  }
  le_primary_reconcile(e);
}

/* MIDI clock send gate (C1, D15): whether le_midi_clock_advance may emit
 * ANYTHING this block. Manual-verified (docs/plan/2026-07-22-song-mode-
 * spec.md, "MIDI clock" section): send is active only in Multi/Sync/Band —
 * Song and Free stay completely silent regardless of clock_mode. Unlike
 * le_looper_mode_switch_blocked above (gating whether a MODE SWITCH
 * may land), this reads the CURRENT mode every block to gate whether
 * clock OUTPUT fires — the two are deliberately different predicates over
 * the same a_looper_mode field. */
static int le_clock_send_gate_open(le_engine* e) {
  if (load_i32(&e->a_clock_mode) != LE_CLOCK_SEND) return 0;
  const int32_t mode = load_i32(&e->a_looper_mode);
  return mode == LE_LOOPER_MODE_MULTI || mode == LE_LOOPER_MODE_SYNC ||
        mode == LE_LOOPER_MODE_BAND;
}

/* Two-tap tempo (modernized from 2f0513a): the interval between this tap and
 * the previous one, in frames of e->frame_clock (block-granular — taps arrive
 * via the ring, which drains at block start, so finer resolution would be
 * fiction). Intervals outside the 30..300 BPM window are ignored, so a stale
 * first tap never produces an absurd tempo. The lock is checked by the caller
 * (a locked tap is ignored WHOLESALE — not even recorded, so unlocking does
 * not inherit half of a stale tap pair). */
static void handle_tap(le_engine* e) {
  const uint64_t now = e->frame_clock;
  if (e->has_tap) {
    const uint64_t interval = now - e->last_tap_frame;
    const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
    if (interval > 0) {
      const double bpm = 60.0 * (double)sr / (double)interval;
      if (bpm >= (double)LE_GRID_TEMPO_MIN &&
          bpm <= (double)LE_GRID_TEMPO_MAX) {
        store_f32(&e->a_tempo_bpm_bits, (float)bpm);
        store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_TAPPED);
      }
    }
  }
  e->last_tap_frame = now;
  e->has_tap = 1;
}

/* Establishes the loop<->grid relationship for a freshly defined master loop
 * (modernized from 2f0513a's sync_tempo_to_loop, generic over signatures and
 * following D7's precedence — the loop's AUDIO length is never altered):
 *   - sync off: no grid (loop_bars 0, tempo untouched) — free-form.
 *   - sync on, tempo already set (manual/tapped/derived): round the loop to a
 *     whole-bar COUNT of the existing grid; the tempo is NOT re-derived and
 *     NOT snapped (deliberate change from the old stack, which snapped the
 *     displayed tempo to the loop).
 *   - sync on, no tempo (source none): derive the tempo from the loop (whole
 *     bars in the current signature, BPM in 30..300 nearest 120) and mark the
 *     source derived.
 * The beat grid then divides the loop exactly (grid_total_beats over len),
 * whatever the nominal BPM says — the loop is the truth once it exists. */
static void sync_grid_to_loop(le_engine* e, int32_t len) {
  e->grid_prev_beat = -1; /* re-arm beat publication at the next frame */
  if (!load_i32(&e->a_sync_tempo) || len <= 0) {
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  int32_t bars = 0;
  if (load_i32(&e->a_tempo_source) == LE_TEMPO_SOURCE_NONE) {
    const float bpm = le_grid_derive_bpm(len, num, sr, &bars);
    if (bpm <= 0.0f || bars < 1) { /* degenerate input: stay grid-free */
      e->grid_total_beats = 0;
      store_i32(&e->a_loop_bars, 0);
      return;
    }
    store_f32(&e->a_tempo_bpm_bits, bpm);
    store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_DERIVED);
  } else {
    const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                             load_i32(&e->a_ts_den), sr};
    bars = le_grid_bars_for_loop(&g, len);
    if (bars < 1) bars = 1;
  }
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
}

/* Bar count is part of the recorded musical grid. It cannot be inferred
 * from a tempo that may have clamped, or from a future-capture preference. */
static void le_restore_musical_grid(le_engine* e, int32_t bars) {
  e->grid_prev_beat = -1;
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * load_i32(&e->a_ts_num);
  store_i32(&e->a_current_beat, 0);
}

/* ---- track length presets (A6, D17; song-mode-spec.md §1) ----
 *
 * A per-track preset on the DEFINING (first/master) recording, orthogonal to
 * le_effective_multiple (which fixes a NON-defining track's length once a
 * master already exists — engine_private.h). Two hooks implement the full
 * preset x click-mode matrix with no change to the AUTO path:
 *   - le_arm_length_preset_target, called once when a defining recording
 *     actually begins (handle_record's EMPTY branch and le_count_in_commit),
 *     latches this take's auto-finalize target in frames, or 0 when none
 *     applies.
 *   - The target (if any) is consumed in advance_transport_frame (auto-
 *     finalizes into overdub at exactly N bars) or at finalize_master (an
 *     unarmed take with an N-bars preset derives tempo from length / N).
 * See le_engine_set_track_length_preset's header doc for the matrix itself. */

/* Arms (or clears) track [t]'s auto-finalize target for the CURRENT defining
 * take. Only armed — target_frames > 0 — when ALL of: an N-bars preset is set,
 * loop<->grid sync is on (a preset is dormant without a grid, matching a
 * plain grid-off recording), the click is audible during recording (any mode
 * but off), and a tempo is already established (source != none) — the auto-
 * finalize frame count requires a known frames-per-bar, which requires a
 * tempo. Reads click_mode / tempo ONCE here, at record-start commitment (like
 * le_count_in_begin's frozen schedule): a later mid-take change never moves
 * this take's target. Left at 0 (no auto-finalize) covers AUTO, N-bars with
 * click off, and N-bars with click on but no tempo yet — all three finalize
 * through the length-preset-derive-tempo path in finalize_master instead
 * (the A6 fallback for the no-tempo edge case, documented on the header). */
static void le_arm_length_preset_target(le_engine* e, le_track* t) {
  t->length_preset_target_frames = 0;
  const int32_t bars = load_i32(&t->a_length_preset_bars);
  if (bars <= 0) return; /* AUTO: no target, ever */
  if (!load_i32(&e->a_sync_tempo)) return; /* grid disabled: preset dormant */
  if (load_i32(&e->a_click_mode) == LE_CLICK_OFF) return;
  if (load_i32(&e->a_tempo_source) == LE_TEMPO_SOURCE_NONE) return;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  const double fpbar = le_grid_frames_per_bar(&g);
  if (!(fpbar > 0.0)) return;
  const double target = (double)bars * fpbar;
  if (!(target >= 1.0)) return;
  /* Re-validate against capacity with the LIVE grid (code-review fix): the
   * D17 allocation guard in le_engine_set_track_length_preset only checked
   * the signature at SET time, worst-case 30 BPM. Nothing stops a signature
   * (or tempo) change between setting the preset and actually recording — no
   * track has content yet, so D6's lock does not apply — and this take's
   * live grid can need far more frames than the guard ever saw. Using the
   * ACTUAL live-computed target here (not another worst-case estimate) is
   * the precise, correct check: this is exactly the frame count the auto-
   * finalize would need to reach. If it can't fit, leave the target unarmed
   * so the take degrades cleanly to the click-off derive-from-length path at
   * finalize (the same fallback already used for the no-tempo edge case)
   * instead of arming a target that can never fire — which would otherwise
   * leave a stale length_preset_target_frames for finalize_master to trip
   * over silently (the bug this guard fixes). */
  if (target > (double)e->max_loop_frames) return;
  t->length_preset_target_frames = (int32_t)llround(target);
}

/* The N-bars length-preset finalize override, used by finalize_master in
 * place of sync_grid_to_loop whenever a defining take with an N-bars preset
 * finalizes WITHOUT having reached its auto-finalize target (click was off,
 * so no target was ever armed; or click was on but no tempo existed yet at
 * record start — the A6 fallback). Per the manual's explicit rule for this
 * preset, tempo is derived from the ACTUAL recorded length divided by `bars`
 * UNCONDITIONALLY — even over an existing manual/tapped tempo, unlike AUTO's
 * D7 "never re-derive an existing tempo" precedence. The loop's AUDIO length
 * is never altered; only bars/tempo are set to describe it. Mirrors
 * sync_grid_to_loop's guard shape (sync off / degenerate input -> grid-free)
 * so the two stay easy to compare. */
static void le_apply_length_preset_tempo(le_engine* e, int32_t len,
                                         int32_t bars) {
  e->grid_prev_beat = -1; /* re-arm beat publication at the next frame */
  if (!load_i32(&e->a_sync_tempo) || len <= 0 || bars <= 0) {
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const float bpm = le_grid_bpm_for_length(len, bars, num, sr);
  if (bpm <= 0.0f) { /* degenerate input: stay grid-free, like sync_grid_to_loop */
    e->grid_total_beats = 0;
    store_i32(&e->a_loop_bars, 0);
    return;
  }
  store_f32(&e->a_tempo_bpm_bits, bpm);
  store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_DERIVED);
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
}

/* Per-frame beat publication, loop-driven: once a grid exists the beat index
 * derives from the master position so beats divide the loop exactly (the
 * 2f0513a loop-synced branch; the free-running branch lives in click_frame).
 * Dormant-grid cost is the single grid_total_beats compare. Note: with the
 * default sync-on, a grid derives at the first defining finalize, so the
 * per-frame divide runs from then on — the same cost profile as the old
 * stack's loop-synced metronome.
 *
 * A2: this is also the loop-locked click scheduler. `click_on` is the frame's
 * click audibility gate; a beat transition while it holds retriggers the
 * click voice (downbeat pitch on beat 0 of the bar). grid_prev_beat/
 * a_current_beat are tracked EVERY frame a grid+loop exist, regardless of
 * click_on — only the trigger_click call below is gated — so grid_prev_beat
 * always holds the TRUE current beat, click on or off.
 *
 * A RISE of the gate (click_on flips 0->1) re-arms grid_prev_beat to -1, but
 * ONLY when `pos == 0` — the loop top, which is the one case where a rising
 * gate should click immediately: the held-transport resume (le_transport_
 * held parks the clock at 0 the whole time it's held, so grid_prev_beat is
 * already sitting at 0 from the continuous tracking above and would
 * otherwise suppress the resume's downbeat — the -1 re-arm forces it back
 * out). Any OTHER gate rise — most notably a punch-in overdub starting
 * mid-loop under LE_CLICK_REC (handle_record's PLAYING/STOPPED branch begins
 * capturing at the CURRENT transport position, not a beat boundary) — must
 * NOT get this treatment: firing immediately there would click at whatever
 * arbitrary phase the punch landed on, not a real beat (confirmed bug:
 * 300 BPM, punch mid-beat fired a click ~112 ms after the true beat onset).
 * Leaving grid_prev_beat alone on those rises is exactly right, because it
 * is already the CURRENT beat (continuous tracking, above) — so `beat !=
 * grid_prev_beat` below stays false and no spurious click fires; the click
 * naturally picks up at the next REAL boundary once the beat actually
 * changes.
 *
 * #1050: a loop with NO grid (sync off: sync_grid_to_loop left
 * grid_total_beats at 0) takes the same path with the beat read off the loop
 * position at the nominal tempo instead — beat k at k * nominal_fpb, the
 * frames-per-beat the free-running scheduler clicked the defining take with
 * (llround(60 * sr / bpm), the caller's per-block value; 0 when no tempo is
 * set, which leaves this a no-op). Beat k of that take therefore lands where
 * it was played, on every cycle and for every later recording, instead of
 * the free-running scheduler re-anchoring at each record press. The loop top
 * starts the count again, so a loop that is not a whole number of beats has
 * a short last beat. */
static inline void grid_beat_frame(le_engine* e, int32_t pos, int click_on,
                                   int32_t nominal_fpb) {
  if (e->clock.length <= 0) return;
  if (e->grid_total_beats <= 0 && nominal_fpb <= 0) return;
  if (click_on != e->click_grid_gate) {
    if (click_on && pos == 0) e->grid_prev_beat = -1;
    e->click_grid_gate = click_on;
  }
  const int32_t beat =
      e->grid_total_beats > 0
          ? le_grid_beat_at(pos, e->clock.length, e->grid_total_beats)
          : pos / nominal_fpb;
  if (beat != e->grid_prev_beat) {
    e->grid_prev_beat = beat;
    const int32_t num = load_i32(&e->a_ts_num);
    const int32_t bar_beat = num > 0 ? beat % num : 0;
    /* A grid-free loop publishes its beat only while the click sounds, as
     * the free-running scheduler it replaces did: with the click off it has
     * no beat to show (test_commit_session_resets_stale_grid). */
    if (e->grid_total_beats > 0 || click_on) {
      store_i32(&e->a_current_beat, bar_beat);
    }
    if (click_on) trigger_click(e, bar_beat == 0);
  }
}

/* Loads the loop-locked subdivision ratio for the CURRENT quantize division
 * (A3), or returns 0 when subdivision arming is inactive — division off, no
 * loop-locked grid (grid_total_beats == 0: sync off / free-form loop), or no
 * loop. Inactive means the boolean loop-top machinery stands alone, exactly
 * the pre-A3 behavior. Reads the LIVE a_quantize_div on purpose: a granularity
 * change while an arm is pending re-evaluates on the very next check (D8), and
 * a change to OFF reverts the pending fire to the loop top with no extra
 * bookkeeping. */
static int le_live_subdiv_ratio(le_engine* e, int32_t ch, int64_t* num,
                                int64_t* den) {
  int32_t div = load_i32(&e->a_quantize_div);
  /* Per-track division (slice 2b): the track's own override, read live like
   * the global it replaces, so an armed track follows its own grid. */
  if (ch >= 0 && ch < e->track_count) {
    const int32_t ov = load_i32(&e->tracks[ch].a_quantize_div_override);
    if (ov >= 0) div = ov;
  }
  if (div == LE_GRID_DIV_OFF || e->grid_total_beats <= 0 ||
      e->clock.length <= 0) {
    return 0;
  }
  return le_grid_loop_subdiv_ratio(e->grid_total_beats,
                                   load_i32(&e->a_ts_num),
                                   load_i32(&e->a_ts_den), div, num, den);
}

/* An unlocked tempo/signature change can land over a SURVIVING grid (all
 * tracks empty but the master kept for redo — the undo-to-empty edge, or a
 * whole-rig clear that was undone). Recompute the bar count and beat grid
 * against the surviving master so the published grid stays coherent with the
 * new value. Deliberately bypasses sync_grid_to_loop: the sync toggle only
 * governs future finalizes and must never destroy a live grid. */
static void regrid_surviving_master(le_engine* e) {
  if (e->clock.length <= 0 || load_i32(&e->a_loop_bars) <= 0) return;
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  int32_t num = load_i32(&e->a_ts_num);
  if (num <= 0) num = 4;
  const le_tempo_grid g = {load_f32(&e->a_tempo_bpm_bits), num,
                           load_i32(&e->a_ts_den), sr};
  int32_t bars = le_grid_bars_for_loop(&g, e->clock.length);
  if (bars < 1) bars = 1;
  store_i32(&e->a_loop_bars, bars);
  e->grid_total_beats = bars * num;
  e->grid_prev_beat = -1;
}

/* Primary-track reconcile (accepted design, slice 1; revises D18's
 * never-auto-assign reading). a_primary_track is THE FIRST COMPLETED
 * RECORDING until an explicit handoff (LE_CMD_CROWN_PRIMARY):
 *   - nothing crowned and some track holds a completed take -> crown the
 *     lowest such track. Called after every content change, so at a live
 *     finalize exactly one track can have just completed, and "lowest"
 *     only breaks the tie a session import (every track at once) creates;
 *   - every track empty (or still on its first, uncompleted take) -> no crown.
 *     An empty session has none, and a take in progress is not a recording
 *     yet;
 *   - otherwise the designation is left alone: clearing or undoing the
 *     primary while a sibling holds audio keeps it crowned (D18's re-record
 *     rule — its next take re-establishes it as exactly one base loop, see
 *     le_is_reestablishing_primary), and the app draws the crown on the
 *     lowest content-bearing track meanwhile.
 * A completed take is any state but EMPTY and RECORDING: OVERDUBBING implies
 * a finalized base. Audio thread only; eight relaxed loads, no allocation. */
static void le_primary_reconcile(le_engine* e) {
  int32_t first = -1;
  for (int32_t k = 0; k < e->track_count; ++k) {
    const int32_t st = load_i32(&e->tracks[k].a_state);
    if (st != LE_TRACK_EMPTY && st != LE_TRACK_RECORDING) {
      first = k;
      break;
    }
  }
  const int32_t primary = load_i32(&e->a_primary_track);
  if (first < 0) {
    if (primary >= 0) store_i32(&e->a_primary_track, -1);
  } else if (primary < 0) {
    store_i32(&e->a_primary_track, first);
  }
}

/* Audio-thread reset when a track loses its take. Other tracks keep both
 * their published waveform and their in-progress bucket. */
static void reset_track_viz(le_engine* e, int32_t ch) {
  e->track_viz_bucket[ch] = -1;
  e->track_viz_accum[ch] = 0.0f;
  for (int i = 0; i < LE_VIZ_POINTS; ++i) {
    store_f32(&e->a_track_viz[ch][i], 0.0f);
  }
}

static void finalize_master(le_engine* e, le_track* t, int32_t end_state,
                            uint64_t frame) {
  /* A mute deferred during the take lands with the finalize (and blocks a
   * rec/dub continuation into OVERDUBBING — see le_consume_pending_mutes). */
  end_state = le_consume_pending_mutes(e, t, end_state, 1, frame);
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  /* The master loop length is established (or re-established, on a hand-off
   * finalize) right here — this is the live-record-path call site for the
   * LE_PLOG_LOOP_LENGTH_LOCKED transport fact (the other is LE_CMD_COMMIT_
   * SESSION, for session import). */
  le_plog_push(e, frame,
              (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED, .arg_i = len});
  /* Free/Song mode (B2b + B4, index Architecture §4): this track's OWN
   * clock, not the shared master. Neither mode has a single shared loop
   * (song-mode-spec §1: Free is "four un-synced, independently playing"
   * tracks; Song is "four looper tracks that can vary in length and be
   * played back independently" — §2's engine-consequences note calls Song's
   * transport "structurally identical" to Free's) — up to 8 independent
   * lengths, each established by that track's own defining recording, so
   * e->clock / a_master_len / loop_iteration must stay untouched here
   * (dormant at whatever they already are — 0 in practice: a switch INTO
   * Free/Song resets the master on the way in (le_apply_mode_switch), and
   * le_engine_configure / handle_clear reset it alongside every track
   * whenever the rig goes fully empty, so no Multi-mode residue can reach a
   * Free/Song-mode finalize). sync_grid_to_loop / le_apply_length_preset_tempo are Multi
   * mode's "this ONE loop derives/rounds THE session tempo" logic (D7) —
   * with several independent lengths there is no single loop to derive a
   * session-wide tempo from, so neither runs for a Free/Song-mode finalize:
   * BPM/signature stay exactly what the session already has (D7: session-
   * wide, set manually/tapped, never derived from one of several independent
   * per-track lengths — song-mode-spec §2 Q6 confirms Song, like Free, has
   * no per-section tempo). This does NOT disable quantize/length presets in
   * Free/Song mode — le_arm_length_preset_target's auto-finalize target
   * (consumed above this function, in advance_transport_frame) is a pure
   * function of the GLOBAL tempo grid (tempo_grid.h takes bpm/signature/
   * sample_rate as parameters, never track-bound state) and already
   * composes per-track unmodified; only the POST-hoc "derive/round the
   * session tempo from THIS take's length" step below is Multi-mode-only. */
  const int32_t mode = load_i32(&e->a_looper_mode);
  const int free_mode = mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  if (free_mode) {
    le_loop_clock_set_length(&t->free_clock, len);
    t->free_iteration = 0; /* this track's own loop just (re)started */
    /* Re-arm this track's own viz bucket cursor (mirrors the loop_viz_bucket
     * re-arm master finalizes get for free by always being preceded by an
     * all-empty reset — see le_engine_configure / handle_clear doc). */
    e->track_viz_bucket[(int32_t)(t - e->tracks)] = -1;
  } else {
    le_loop_clock_set_length(&e->clock, len);
    e->loop_iteration = 0; /* the base loop just (re)started */
    store_i32(&e->a_master_len, len);
  }
  le_track_set_len(t, len);
  store_i32(&t->a_multiple, 1); /* the defining track is one base loop */
  store_i32(&t->a_sync_divisor, 0); /* a defining track is never a division */
  le_audio_rev_bump(t); /* [R1] record finalize: fresh content */
  atomic_store_explicit(&t->a_state, end_state, memory_order_release);
  le_primary_reconcile(e); /* the first completed take takes the crown */
  t->start_iter = 0;
  e->trk_play_pos[(int32_t)(t - e->tracks)] = 0; /* the loop (re)starts here */
  /* This track leaves RECORDING here regardless of end_state — even the
   * OVERDUBBING case is a record-to-overdub toggle, not a continuation of the
   * same recording. The take id (#819) both rides the RECORD_END payload and
   * publishes to a_settled_take_id, so the snapshot names this exact take as
   * the settled one. */
  {
    const int32_t fm_ch = (int32_t)(t - e->tracks);
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_RECORD_END,
                             .take = {.channel = fm_ch,
                                      .take_id = t->take_seq}});
    store_i32(&t->a_settled_take_id, t->take_seq);
  }
  /* A6/D17: an N-bars length preset that finalizes WITHOUT its auto-finalize
   * target having been armed (click was off, or click was on but no tempo
   * existed at record start — le_arm_length_preset_target) derives tempo from
   * the actual length / N instead of the normal AUTO path. An armed target
   * (target reached on time, OR an early press that disarms it — D17) takes
   * the normal path unchanged: on-time, the existing tempo already makes len
   * round back to bars == N; early, the shorter take rounds to whatever bars
   * it actually spans, exactly the "early press disarms the preset" rule.
   * Free mode (see above): skipped outright — no session-tempo derivation
   * from a single independent length. */
  const int32_t preset_bars = load_i32(&t->a_length_preset_bars);
  if (!free_mode) {
    if (preset_bars > 0 && t->length_preset_target_frames == 0) {
      le_apply_length_preset_tempo(e, len, preset_bars);
    } else {
      sync_grid_to_loop(e, len);
    }
  }
  t->length_preset_target_frames = 0; /* consumed; the next take re-arms */
  if (end_state == LE_TRACK_OVERDUBBING) le_dub_session_start(e, t);
}

/* Seam-crossfade overlap length (~10 ms): the frames captured past the loop
 * point and folded into the head. Also the minimum half-loop the master must
 * span to be eligible (it needs head + tail room plus steady audio between). */
static int32_t seam_xfade_frames(const le_engine* e) {
  const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  return sr / 100;
}

/* Whether the seam overlap [len, len + F) actually fits every active lane's
 * LIVE buffer, and the loop is long enough to host head + tail with steady
 * audio between (#728). Undo can swap a loop-length-quantized snapshot slot
 * into a_live, so the recording cap is NOT a safe bound — the slot's own
 * allocated capacity is. Returns F when the fold may run, 0 otherwise; every
 * seam path gates on this, so no path can read or write past a lane buffer. */
static int32_t seam_room(const le_engine* e, le_track* t, int32_t len) {
  const int32_t F = seam_xfade_frames(e);
  if (F <= 0 || len < 2 * F) return 0;
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    le_lane* ln = &t->lanes[l];
    const int32_t live = load_i32(&ln->a_live);
    if (ln->pool[live] == NULL) continue; /* lazily NULL: nothing to fold */
    if (ln->pool_cap[live] < len + F) return 0;
  }
  return F;
}

/* The equal-gain (linear) seam fold, the ONE crossfade every loop seam gets
 * (#728). Morphs each head sample [0, F) from the captured continuation
 * [len, len + F) — which follows len-1 naturally — into the original head, so
 * the wrap len-1 -> 0 is continuous. Equal-gain, not equal-power, because the
 * two signals are the performance and its own continuation, i.e. highly
 * correlated: linear weights sum to exactly 1.0 so correlated material passes
 * at unity, where equal-power (sin/cos) would bump it to sqrt(2)x (+3 dB) at
 * mid-fade (#256). Callers gate on seam_room; the per-lane capacity check
 * below repeats it against the live slot AS OF NOW, because the control thread
 * can swap a shorter loop-length-quantized undo slot into a_live in between. */
static void le_seam_fold(le_track* t, int32_t len, int32_t F) {
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    const int32_t live = load_i32(&t->lanes[l].a_live);
    float* b = t->lanes[l].pool[live];
    if (b == NULL || t->lanes[l].pool_cap[live] < len + F) continue;
    le_seam_fold_head(b, b + len, F);
  }
}

/* Applies the SAME fold to an in-flight overdub undo shadow (#728). When a
 * take finalizes straight into OVERDUBBING (rec/dub — the common press) the
 * dub's backup-on-write starts saving pre-values immediately, and a quantized
 * rec/dub finalizes ON the loop top, so during the F overlap frames the write
 * head sweeps 0..F-1 and the shadow captures the head BEFORE the fold rewrites
 * it. Without this the first undo would swap in a layer whose head still
 * splices — a silent revert to the pre-#728 behaviour, undoable only by
 * undoing again.
 *
 * The shadow holds the pre-pass image, and the corrected pre-pass image is the
 * FOLDED head: the continuation belongs to the take that just finalized, i.e.
 * to exactly the content the shadow is an image of. So this is the identical
 * arithmetic on the identical pre-value, just stored in the shadow — the
 * continuation is read from the live slot because the shadow is loop-length
 * quantized and has no [len, len + F) region of its own.
 *
 * Positions of [0, F) this pass has NOT backed up yet are folded speculatively
 * and that is harmless: every shadow position is written exactly once before
 * the layer retires — by backup-on-write when the trajectory reaches it, or by
 * le_dub_block_update's drain walk, which enumerates precisely the uncovered
 * set — and both copy from the live slot, which by then is folded. Gated on
 * a_layer_in_flight so a merely pre-armed spare is never touched.
 *
 * KNOWN GAP: a layer that RETIRES before the fold runs keeps its un-folded
 * head, so that one undo step reverts to the pre-#728 seam. The trigger is
 * plainer than it looks — no re-punch and no merge needed, just a PUNCH-OUT
 * inside the first F/2 frames after the finalize. od_fade_frames is the same
 * sr/100 as F, so a dub punched out at frame p has only ramped to p/F and
 * decays back to 0 by frame 2p; LE_DRAIN_CHUNK (32768 samples) then drains the
 * whole remaining pass in a single block, and the layer retires while the fold
 * is still counting down. Measured at 48 kHz (F = 480): punch-out at 64 or 192
 * leaves the raw seam (score 204x, step 0.352), at 240 or 600 the folded one
 * (1.6x, 0.003) — pinned both ways by
 * test_loop_seam_gap_when_dub_retires_before_the_fold. Low severity and the
 * numbers say so: the head that survives is the honest raw seam of the take at
 * its true peak, a step rather than garbage, and only on the undo path. */
static void le_seam_fold_dub_shadow(le_track* t, int32_t len, int32_t F) {
  const int32_t slot = t->dub_slot;
  if (slot < 0 || !load_i32(&t->a_layer_in_flight)) return;
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    le_lane* ln = &t->lanes[l];
    const int32_t live = load_i32(&ln->a_live);
    /* Structural, not currently reachable: track_acquire_slot excludes `live`
     * when it arms a shadow, so slot != live. If that ever stopped holding,
     * folding here would run le_seam_fold's arithmetic a SECOND time over the
     * same head — the one way this function could corrupt rather than merely
     * miss. Cheaper to rule out than to reason about. */
    if (slot == live) continue;
    const float* b = ln->pool[live];
    float* sb = ln->pool[slot];
    if (b == NULL || sb == NULL) continue;
    /* The second audio-thread read of the non-atomic pool_cap (#728) — see the
     * invariant stated at the `cap` snapshot in mix_tracks_frame. That
     * argument covers the LIVE slot; this one also reads a SHADOW slot's cap,
     * and the same "never resized under the audio thread" property holds for
     * it: track_acquire_slot excludes live, both history stacks and
     * outstanding_slots when it picks a shadow, so le_lane_ensure_slot can
     * never grow a slot that is armed as dub_slot, and le_lane_shrink_slot
     * runs only from le_handle_retired — after the audio thread has cleared
     * dub_slot and pushed the retire event, i.e. after it can no longer name
     * the slot. So (pointer, cap) is immutable here too. */
    if (ln->pool_cap[live] < len + F || ln->pool_cap[slot] < F) continue;
    le_seam_fold_head(sb, b + len, F);
  }
}

/* Requests finalize of the *defining master* at its current length. When the
 * loop is long enough and the buffer has room, this defers the finalize: the
 * track keeps RECORDING F more frames so the seam can be crossfaded (see
 * finalize_master_xfade), preserving the recorded length exactly. Otherwise
 * (short loop, no room, or a finalize already in flight) it finalizes now. */
static void request_master_finalize(le_engine* e, le_track* t,
                                    int32_t end_state, uint64_t frame) {
  if (t->xfade_capture > 0) return; /* already deferring — ignore re-entry */
  const int32_t len = t->record_pos;
  const int32_t F = seam_room(e, t, len);
  if (F > 0 && len + F <= e->max_loop_frames) {
    t->xfade_len = len;
    t->xfade_end_state = end_state;
    t->xfade_capture = F; /* stay RECORDING; the per-frame advance counts down */
  } else {
    finalize_master(e, t, end_state, frame);
  }
}

/* Sync/Band quantize decision (B3, D16): the nearest valid ratio to how much
 * [len] was actually captured relative to the primary's [base] length,
 * returned as a power-of-two exponent p in [-2,2] over the supported set
 * {1/4, 1/2, 1, 2, 4} — p >= 0 means a multiple (k = 1<<p); p < 0 means a
 * division (n = 1<<-p). Log2-nearest, not linear-nearest: the ratio set is
 * geometric (equally spaced in log2), so this is genuinely the "closest"
 * match — and, deliberately unlike Multi's AUTO round-up-only rule, it can
 * round DOWN a take that ran long, truncating rather than padding with
 * silence. This matches the manual's "every later [Sync/Band] track is AUTO
 * (Bars)" (song-mode-spec.md §1): it snaps to the nearest grid point, not
 * always the next one up. A take far outside the set (near-zero or many
 * loops long) still clamps to the nearest END of the range rather than
 * being rejected. */
static int32_t le_sync_ratio_pow(int32_t len, int32_t base) {
  if (len <= 0 || base <= 0) return 0;
  const double p = log2((double)len / (double)base);
  int32_t pi = (int32_t)llround(p);
  if (pi < -2) pi = -2;
  if (pi > 2) pi = 2;
  return pi;
}

/* Sync/Band quantize decision (B3, D16), adversarial-review BUG 1 + BUG 2
 * fix: chooses BOTH the multiple/divisor AND validates it fits, so no
 * caller can apply an unsafe result. Writes *out_k (>= 1) and
 * *out_divisor (0 = ordinary multiple of *out_k base loops; 2 or 4 = a
 * division, *out_k inertly 1) for a track that captured [len] frames
 * against the primary's [base]-frame length, with the buffer physically
 * capped at [max_loop_frames] (a lane's pool is allocated ONCE at that
 * size in le_engine_configure — le_track_set_len only ever publishes the
 * logical length, it never grows the buffer).
 *
 * BUG 1 (memory safety): the multiple leg (p >= 0, k = 1/2/4) used to call
 * le_track_set_len(t, k * base) with NO clamp against max_loop_frames,
 * unlike the ordinary (non-Sync) path a few lines below in
 * finalize_new_track, which already has `maxk = max_loop_frames / base;
 * if (k > maxk) k = maxk;`. Without it, a large primary (e.g. any base
 * over max_loop_frames/4) let a non-primary track's nearest-ratio match
 * publish a_len larger than the lane's actual allocated capacity —
 * mix_tracks_frame's `lbuf[seg_base[t] + trk_pos[t]]` then reads out of
 * bounds on the audio thread. Fixed here with the IDENTICAL clamp the
 * ordinary path already trusts.
 *
 * BUG 2 (audio correctness): the division leg used to accept ANY p < 0
 * candidate and compute div_len = llround(base / n) independently at
 * write time (here) and read time (sync_division_positions_frame) with
 * nothing forcing n * div_len == base. Whenever the primary's length isn't
 * evenly divisible by n — the ORDINARY case for a freely-recorded primary,
 * not a rare edge case (e.g. base=17, n=4 -> div_len=llround(4.25)=4, but
 * 4*4=16=/=17) — the fixed-length `pos % div_len` read repeats or skips
 * exactly one buffer index every single primary cycle: a permanent,
 * audible stutter for the life of the track. Fixed by only ever OFFERING a
 * division that tiles EXACTLY: step the requested divisor down (4 -> 2)
 * and, if the primary's length is odd (no divisor in {2,4} can ever tile
 * it exactly), fall all the way back to an ordinary 1x multiple instead of
 * publishing an inexact division. This is the "reject and fall back"
 * option (vs. a remainder-distributing read mapping in the spirit of
 * le_grid_beat_at/tempo_grid.c) — simpler, and every division this
 * function ever hands back is now PROVABLY exact (base % divisor == 0),
 * not just "close", so sync_division_positions_frame's read needs no
 * rounding at all (see its updated doc). */
static void le_sync_choose_ratio(int32_t len, int32_t base,
                                 int32_t max_loop_frames, int32_t* out_k,
                                 int32_t* out_divisor) {
  const int32_t p = le_sync_ratio_pow(len, base);
  if (p >= 0) {
    int32_t k = 1 << p; /* 1, 2, or 4 base loops */
    const int32_t maxk = max_loop_frames / base;
    if (maxk >= 1 && k > maxk) k = maxk; /* BUG 1: identical to the below */
    if (k < 1) k = 1;
    *out_k = k;
    *out_divisor = 0;
    return;
  }
  for (int32_t n = 1 << (-p); n >= 2; n /= 2) {
    if (base % n == 0) { /* BUG 2: only ever offer an EXACT division */
      *out_k = 1;
      *out_divisor = n;
      return;
    }
  }
  *out_k = 1; /* base doesn't divide evenly by 2 (let alone 4): no valid
               * division exists — fall back to an ordinary 1x multiple,
               * always exact and always within capacity (base itself is
               * already <= max_loop_frames, the invariant every defining
               * take's own auto-finalize already enforces). */
  *out_divisor = 0;
}

/* Recomputes a_multiple / a_sync_divisor for a track whose length is being
 * REINSTATED directly (LE_CMD_REDO_FROM_EMPTY / LE_CMD_RESTORE_CLEAR)
 * rather than freshly finalized — these paths restore a previously-decided
 * length; they don't re-run finalize_new_track's decision. Mirrors the
 * codebase's existing "recompute from len/base rather than store it
 * redundantly" choice for `multiple` (le_hist_entry.multiple is likewise
 * write-only, never read back). k = len/base >= 1 is the ordinary multiple
 * path, byte-identical to before B3. len < base (k rounds to 0) means the
 * restored track was a B3 Sync/Band DIVISION: since le_sync_choose_ratio
 * (post-BUG-2-fix) only ever creates a division where base % divisor == 0
 * EXACTLY, the divisor is recovered exactly too (len == base/4 tests
 * first; anything else that got here — len < base — can only be base/2,
 * the sole remaining possibility the write side could have produced), not
 * guessed by a fuzzy log2 threshold. */
static void le_restore_multiple_or_divisor(le_track* t, int32_t base,
                                           int32_t len) {
  if (base <= 0) base = len > 0 ? len : 1;
  const int32_t k = len / base;
  if (k >= 1) {
    store_i32(&t->a_multiple, k);
    store_i32(&t->a_sync_divisor, 0);
    return;
  }
  const int32_t n = (len > 0 && base % 4 == 0 && len * 4 == base) ? 4 : 2;
  store_i32(&t->a_sync_divisor, n);
  store_i32(&t->a_multiple, 1); /* inert alongside a nonzero divisor */
}

/* Both clear undo and base-take redo can cross an empty-rig mode change.
 * Historical audio keeps its span; the current mode owns the clock model. */
static void le_restore_track_clock(le_engine* e, le_track* t, int32_t len,
                                    int32_t saved_master_len, uint64_t frame) {
  le_reset_track_playback(t);
  const int32_t mode = load_i32(&e->a_looper_mode);
  if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
    le_loop_clock_set_length(&t->free_clock, len);
    t->free_iteration = 0;
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_sync_divisor, 0);
    return;
  }
  /* A surviving sibling keeps the grid. Otherwise restore the saved grid,
   * or establish one from a take recorded without a shared master. */
  if (e->clock.length == 0) {
    const int32_t base = saved_master_len > 0 ? saved_master_len : len;
    le_plog_push(e, frame, (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED,
                                       .arg_i = base});
    le_loop_clock_set_length(&e->clock, base);
    e->loop_iteration = 0;
    store_i32(&e->a_master_len, base);
    sync_grid_to_loop(e, base);
  }
  le_loop_clock_reset(&t->free_clock);
  t->free_iteration = 0;
  le_restore_multiple_or_divisor(t, e->clock.length, len);
}

/* Adversarial-review BUG 4 fix: whether channel [ch] IS the crowned primary
 * in Sync/Band mode — regardless of whether it is currently "established"
 * (le_sync_quantize_active deliberately excludes ch == primary from its
 * own gate). Used by finalize_new_track to force the primary's OWN
 * re-record to exactly one base loop instead of the ordinary auto-round-up
 * whenever it lands here (e->clock.length > 0 already — i.e. this is NOT
 * the primary's first-ever defining take, which goes through
 * finalize_master instead and is untouched by this).
 *
 * Concretely: clearing the primary while a dependent Sync track survives
 * keeps e->clock alive (handle_clear only resets it when EVERY track is
 * empty) — a_primary_track itself also survives, per D18. Re-recording the
 * primary then hits finalize_new_track (e->clock.length is nonzero), and
 * without this check it would auto-round like any other track — landing
 * a_multiple at 2 or 4 if the new take doesn't match the old base exactly,
 * silently "un-establishing" the primary (le_sync_quantize_active's
 * a_multiple == 1 check would start failing) for every FUTURE Sync/Band
 * recording, with zero user-visible signal. D18: the primary is a
 * deliberate, persistent designation — its re-record must always
 * re-establish as exactly one base loop. e->clock.length itself is
 * deliberately left UNTOUCHED (unlike a true fresh defining recording,
 * finalize_master): a sibling may already be phase-locked to it, so this
 * truncates any overflow past one base loop (the same "can round DOWN"
 * behavior le_sync_choose_ratio already has for ordinary non-primary
 * tracks) rather than ever changing the shared base a sibling depends on.
 * A useful side effect: this also closes the "someone else recorded
 * first, defining e->clock, before the primary's own first take"
 * mis-ordering le_sync_quantize_active's doc used to flag as a documented
 * limitation — the primary now always lands at multiple == 1 there too. */
static inline int le_is_reestablishing_primary(le_engine* e, int32_t ch) {
  const int32_t mode = load_i32(&e->a_looper_mode);
  if (mode != LE_LOOPER_MODE_SYNC && mode != LE_LOOPER_MODE_BAND) return 0;
  return load_i32(&e->a_primary_track) == ch;
}

/* Finalizes a non-defining track that recorded freely across one or more base
 * loops. A track that captured nothing (never reached the loop top) returns
 * to EMPTY. Three length policies, mutually exclusive:
 *   - Sync/Band with an established primary (le_sync_quantize_active, D16):
 *     snaps to the nearest valid multiple-or-division of the PRIMARY's
 *     length, chosen AND capacity/exactness-validated in one call
 *     (le_sync_choose_ratio — le_effective_multiple is bypassed entirely,
 *     "every later track is AUTO", song-mode-spec.md §1). A division
 *     publishes a_sync_divisor and sizes the track's OWN buffer to exactly
 *     that (exact, by construction) fraction — see
 *     sync_division_positions_frame for how it plays back phase-locked to
 *     the primary's top.
 *   - Sync/Band, but [t] IS the crowned primary re-recording into an
 *     e->clock a sibling keeps alive (le_is_reestablishing_primary, BUG 4):
 *     forced to exactly one base loop — see that predicate's doc.
 *   - Otherwise (today's behavior, unchanged): rounds the length UP to the
 *     nearest whole base loop (the locked #4 behaviour), per
 *     le_effective_multiple (engine_private.h — shared with the control
 *     thread's first-wrap pre-arm gate, which predicts this finalize). */
static void finalize_new_track(le_engine* e, le_track* t, int32_t end_state,
                               uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t base = e->clock.length > 0 ? e->clock.length : 1;
  if (t->record_pos <= 0) { /* nothing captured */
    /* Drop (not apply) any mute deferred during the void take: an EMPTY
     * track always comes back unmuted. */
    le_consume_pending_mutes(e, t, end_state, 0, frame);
    reset_track_viz(e, ch);
    le_audio_rev_bump(t); /* [R1] record finalize (void take -> EMPTY) */
    store_i32(&t->a_state, LE_TRACK_EMPTY);
    le_transform_reset(e, t, frame);
    le_track_set_len(t, 0);
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_sync_divisor, 0);
    t->record_pos = 0;
    /* RECORD_ABORT, not RECORD_END (#264): nothing was captured, so this take
     * has no content and no disarm image of its own. Why that distinction is
     * load-bearing lives with the rule it protects — perf_render.c's
     * RECORD_END scan, and LE_PLOG_RECORD_ABORT's own declaration. */
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_RECORD_ABORT, .arg_i = ch});
    return;
  }
  /* A mute deferred during the take lands with the finalize (and blocks a
   * rec/dub continuation into OVERDUBBING — see le_consume_pending_mutes). */
  end_state = le_consume_pending_mutes(e, t, end_state, 1, frame);
  if (le_sync_quantize_active(e, ch)) {
    /* le_sync_quantize_active guarantees the primary's OWN recorded length
     * is exactly one base loop, so `base` (e->clock.length) IS the
     * primary's length here — no separate lookup needed. */
    int32_t k, divisor;
    le_sync_choose_ratio(t->record_pos, base, e->max_loop_frames, &k,
                        &divisor);
    if (divisor > 0) {
      store_i32(&t->a_sync_divisor, divisor);
      store_i32(&t->a_multiple, 1); /* inert alongside a nonzero divisor */
      le_track_set_len(t, base / divisor); /* exact: base % divisor == 0 */
    } else {
      store_i32(&t->a_sync_divisor, 0);
      store_i32(&t->a_multiple, k);
      le_track_set_len(t, k * base);
    }
  } else if (le_is_reestablishing_primary(e, ch)) {
    /* BUG 4: the primary re-recording over a master a sibling kept alive —
     * always exactly one base loop, e->clock.length untouched. */
    store_i32(&t->a_sync_divisor, 0);
    store_i32(&t->a_multiple, 1);
    le_track_set_len(t, base);
  } else {
    /* A forced multiple fixes the length to exactly K base loops; 0 (auto)
     * rounds up to whole base loops based on how much was recorded. */
    const int32_t forced = le_effective_multiple(e, ch);
    int32_t k = forced > 0 ? forced : (t->record_pos + base - 1) / base;
    const int32_t maxk = e->max_loop_frames / base;
    if (k < 1) k = 1;
    if (maxk >= 1 && k > maxk) k = maxk;
    store_i32(&t->a_sync_divisor, 0);
    store_i32(&t->a_multiple, k);
    le_track_set_len(t, k * base);
  }
  /* #728: the seam. A non-defining take gets NO crossfade from this function —
   * its head holds the moment the take started and its tail the moment it
   * ended, a whole lap apart, so every playback wrap splices. Arm the trailing
   * overlap capture: the performance keeps being written into
   * [len, len + F) for F more frames and is then folded into the head, exactly
   * as the defining master's deferred finalize does. Unlike the master this
   * does NOT delay the state change — playback (or overdub) starts on this
   * press as before, and only the buffer is smoothed a few ms later.
   *
   * Armed only when the take actually FILLED its length: the compensated write
   * head must sit exactly at `len`, so the F frames that follow really are the
   * continuation of position len-1. Two cases are refused, both correctly,
   * because in neither does a continuation of position len-1 exist:
   *
   *   - The take STOPPED EARLY. Auto rounds the length UP, so [record_pos, len)
   *     stays the digital silence le_prepare_new_capture wrote; the wrap is a
   *     silence cut, a different artifact with a different fix (#730), and
   *     folding a continuation of the wrong sample onto the head would only
   *     add a second one.
   *
   *   - a_record_offset > 0 — i.e. EVERY latency-calibrated rig. Compensation
   *     writes input frame i at position i - offset, so a take that ran to
   *     `len` leaves its head at len - offset and the last `offset` frames of
   *     the buffer as those same prepared zeros. record_pos - offset == len
   *     therefore cannot hold on the auto path (auto rounds up, so len >=
   *     record_pos, and the equality needs offset <= 0), and on the fixed-
   *     multiple path only when record_start happens to equal offset. So the
   *     fold silently does not run there, and that is the honest outcome: the
   *     buffer's true last sample is at len - offset - 1 and what follows it is
   *     already IN the loop, not past it — there is nothing to capture and no
   *     seam of the assumed shape to smooth. Refusing leaves such a take
   *     exactly as it was before #728; giving the offset path a seam of its own
   *     means first fixing the trailing-zeros gap it shares with #730, which is
   *     a length/round-up direction call, not a crossfade one. Pinned by
   *     test_loop_seam_not_armed_with_record_offset. */
  const int32_t new_len = load_i32(&t->lanes[0].a_len);
  const int32_t seam_f = seam_room(e, t, new_len);
  if (seam_f > 0 && t->record_pos - load_i32(&e->a_record_offset) == new_len) {
    t->seam_len = new_len;
    t->seam_capture = seam_f;
  }
  le_audio_rev_bump(t); /* [R1] record finalize: fresh content */
  store_i32(&t->a_state, end_state);
  /* A non-defining take is a completed take too: if the crown went with a
   * cleared or undone sibling while this take was in progress, it lands
   * here (a defining take goes through finalize_master's own call). */
  le_primary_reconcile(e);
  t->record_pos = 0;
  /* Take id (#819): logged in the RECORD_END payload and published as the
   * settled take so the disarm manifest can anchor by identity. */
  le_plog_push(e, frame,
               (le_command){.code = LE_PLOG_RECORD_END,
                            .take = {.channel = ch, .take_id = t->take_seq}});
  store_i32(&t->a_settled_take_id, t->take_seq);
  if (end_state == LE_TRACK_OVERDUBBING) le_dub_session_start(e, t);
}
/* ---- per-pass undo layer capture (audio thread) ----
 *
 * While a track overdubs, every in-place write first saves the pre-value into
 * the armed shadow slot (same slot index on every lane, lockstep). The write
 * trajectory visits each of the track's dub_len positions exactly once per
 * dub_len frames, so dub_count == dub_len means the shadow holds a complete
 * pre-pass image; it is then retired through the evt_ring (the control thread
 * stacks it as one undo layer) and the pre-posted spare takes over. A punch-out
 * mid-pass leaves live authoritative (writes were in place); once the punch
 * envelope has decayed the uncovered remainder is bulk-copied live -> shadow in
 * bounded chunks (le_dub_block_update) and the completed layer retires. */

/* Begins (or continues) a dub capture session when a track enters OVERDUBBING.
 * A session already in flight (re-punch-in during the fade tail or the drain)
 * keeps its capture state untouched — the coverage stays coherent and the
 * passes merge into one layer; a fresh session latches the pass length and the
 * record offset (a mid-dub offset change would tear the trajectory) and arms
 * the spare. dub_count = -1 defers the start-point latch to the first write,
 * so no entry path (press, quantize fire, rec/dub or auto finalize) needs
 * position math here. */
static void le_dub_session_start(le_engine* e, le_track* t) {
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if (len <= 0) return;
  /* [R1] entry into OVERDUBBING (the single funnel: finalize-to-overdub and
   * punch-in both land here). Bumped in the same command drain that flips the
   * state — BEFORE this block's frame loop performs any in-place write — so
   * no overdub write ever happens under the old revision. A re-punch during
   * the fade tail / drain (the in-flight early-return below) bumps too:
   * writes resume, so the content epoch moves again. */
  le_audio_rev_bump(t);
  if (load_i32(&t->a_layer_in_flight)) {
    /* A re-punch while the previous layer is still in flight. Two cases:
     *  - Fade-tail continuation (od_gain > 0): writes never stopped, so the
     *    shadow's coverage is still contiguous — keep capturing into it; the
     *    passes merge into one coherent layer.
     *  - Gap / drain re-punch (od_gain == 0 with a partial shadow): writes
     *    stopped and the transport moved on, so resuming the old coverage
     *    would leave holes — and a drain running underneath would copy the
     *    NEW dub's audio into the OLD layer's uncovered remainder (a torn
     *    snapshot). Discard the partial coverage and restart the capture on
     *    the same slot: the new session's first pass re-covers it fully. The
     *    interrupted partial pass simply stops being separately undoable —
     *    every undo boundary still restores a state that actually existed. */
    if (t->od_gain <= 0.0f && t->dub_slot >= 0 &&
        (t->dub_draining ||
         (t->dub_count > 0 && t->dub_count < t->dub_len))) {
      t->dub_draining = 0;
      t->dub_count = -1;
      t->dub_phase = 0;
    }
    return;
  }
  t->dub_len = len;
  t->dub_offset = load_i32(&e->a_record_offset);
  t->dub_phase = 0;
  if (t->dub_slot < 0 && t->dub_spare >= 0) {
    t->dub_slot = t->dub_spare;
    t->dub_spare = -1;
  }
  t->dub_count = -1;
  atomic_store_explicit(&t->a_layer_in_flight, 1, memory_order_release);
}

/* Tries to push a parked retired layer into the evt_ring (audio thread).
 * Wait-free: on a full ring the slot simply stays parked for the next block —
 * never blocked, never dropped. */
static void le_dub_try_retire(le_engine* e, le_track* t, uint64_t frame) {
  if (t->dub_retire_slot < 0) return;
  const le_command evt = {.code = LE_EVT_LAYER_RETIRED,
                          .evt = {(int32_t)(t - e->tracks), t->dub_retire_slot,
                                  t->dub_gen_audio}};
  if (le_ring_push(&e->evt_ring, evt)) {
    t->dub_retire_slot = -1;
    /* Same payload shape as the evt_ring push above (LE_EVT_LAYER_RETIRED's
     * `evt` arm), just tagged with the capture frame and a distinct code
     * (LE_PLOG_LAYER_RETIRED) for the perf log — the two rings serve
     * different consumers (control-thread undo stacking vs. the drain
     * thread's events.log) and must not be confused. */
    le_plog_push(e, frame,
                (le_command){.code = LE_PLOG_LAYER_RETIRED, .evt = evt.evt});
  }
}

/* Drops the track's armed shadow slots (audio thread) — a fresh capture or a
 * redo-from-empty may change the loop length, and a leftover slot could be
 * sized for the OLD length (undo layers are loop-length-quantized). The
 * control side reclaimed `outstanding` when it posted the triggering command,
 * so the slots return to the pool cleanly; correctly-sized replacements arrive
 * via the poll-driven replenish once a dub session runs. */
static void le_dub_drop_armed(le_track* t) {
  t->pending_capture_shadow = 0;
  t->dub_slot = -1;
  t->dub_spare = -1;
  t->dub_retire_slot = -1;
  t->dub_count = -1;
  t->dub_phase = 0;
  t->dub_draining = 0;
  /* An in-flight seam overlap is indexed off the OLD length and lives in the
   * OLD live slot, so it is stale for exactly the same reasons (#728); the
   * next finalize arms a fresh one. */
  t->seam_capture = 0;
}

/* A deferred fresh start owns a cap-sized initial shadow before its trigger
 * can fire. Preserve only that explicitly prepared slot across dropping the
 * previous take's shadows; adoption performs no allocation or sample copy. */
static void le_start_capture_shadows(le_track* t) {
  const int pending = t->pending_image.revision != 0
      ? t->pending_capture_shadow : 0;
  le_dub_drop_armed(t);
  if (pending > 0) t->dub_slot = pending - 1;
}

/* Pass boundary (dub_phase wrapped): hand a complete shadow to the retire
 * queue and arm the pre-posted spare for the next pass. With the retire queue
 * still occupied (evt ring full) the complete shadow stays frozen — writes
 * continue un-backed and the passes merge coherently into one layer. With no
 * spare on hand the boundary is skipped the same way. */
static void le_dub_boundary(le_engine* e, le_track* t, uint64_t frame) {
  if (t->dub_draining) return; /* the armed shadow belongs to the old session */
  if (t->dub_slot >= 0 && t->dub_count >= t->dub_len) {
    if (t->dub_retire_slot >= 0) return; /* frozen: retire is stuck */
    t->dub_retire_slot = t->dub_slot;
    t->dub_slot = -1;
    le_audio_rev_bump(t); /* [R1] a completed overdub pass retired */
    le_dub_try_retire(e, t, frame);
  }
  if (t->dub_slot < 0 && t->dub_spare >= 0) {
    t->dub_slot = t->dub_spare;
    t->dub_spare = -1;
    t->dub_count = -1; /* first write of the new pass latches the start */
  }
}

/* One contiguous run of the dub trajectory walk, copied between the live slot
 * and the armed shadow on every active lane. The walk enumerates the write
 * positions of a pass in the order the write head visited them: a trajectory
 * point (vpos in [0, base), vseg in [0, k)) maps to the buffer index
 * vseg * base + comp_pos(vpos, off, base), exactly as mix_tracks_frame's wdub
 * does, so a run stays contiguous until the segment ends (vpos wraps) or the
 * compensated position wraps (vpos == off). Copies at most `max_run` frames,
 * advances the cursor and returns the run length (>= 1). `shadow_to_live`
 * reverts (the reopen settle); the drain copies live -> shadow. The ONE
 * definition of the walk, so the drain and the revert cannot drift. */
static int32_t le_dub_run_copy(le_track* t, int32_t base, int32_t k,
                               int32_t off, int32_t* vpos, int32_t* vseg,
                               int32_t max_run, int shadow_to_live) {
  int32_t run = base - *vpos;
  if (*vpos < off && off - *vpos < run) run = off - *vpos;
  if (run > max_run) run = max_run;
  const int32_t w0 = *vseg * base + comp_pos(*vpos, off, base);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &t->lanes[l];
    float* lb = ln->pool[load_i32(&ln->a_live)];
    float* sb = ln->pool[t->dub_slot];
    if (lb == NULL || sb == NULL) continue;
    if (shadow_to_live) {
      memcpy(lb + w0, sb + w0, (size_t)run * sizeof(float));
    } else {
      memcpy(sb + w0, lb + w0, (size_t)run * sizeof(float));
    }
  }
  *vpos += run;
  if (*vpos >= base) {
    *vpos = 0;
    *vseg = (*vseg + 1) % k;
  }
  return run;
}

/* Once-per-block dub maintenance for every track (audio thread; also runs for
 * frames == 0 calls so the host tests' drain(e) pump advances it): retries
 * parked retires, and — once a punched-out session's fade tail has decayed —
 * drains the uncovered remainder of the in-flight layer live -> shadow in
 * LE_DRAIN_CHUNK-bounded runs, retires it, and clears the flight flag. The
 * retire event is pushed BEFORE the flag clears (the release pairs with the
 * control thread's acquire), so a control thread that sees flag == 0 after
 * draining the evt_ring is guaranteed to hold every layer. */
static void le_dub_block_update(le_engine* e, uint64_t frame) {
  /* Free/Song mode (B2b, adversarial-review BUG 1 fix; broadened to SONG by
   * B4): `base` moved INSIDE the loop and computed per-track (mirroring
   * mix_tracks_frame's trk_len[t]) instead of being read once from
   * e->clock.length. e->clock stays permanently dormant (length 0) in
   * Free/Song mode, so a single outer `base` meant every guard below that
   * gates on `base > 0` could never pass for a Free/Song-mode track —
   * regardless of that track's own established free_clock.length — leaving
   * a partially-covered overdub shadow's drain permanently un-armed:
   * dub_draining never sets, the shadow never retires, a_layer_in_flight
   * never clears, and the shadow's pool slot never returns to the shared
   * bounded pool. A real-time-thread resource leak, proven empirically (a
   * throwaway repro: Free-mode track, punch in, overdub < 1 lap, punch out,
   * settle — layer_in_flight stuck at 1 forever). Pinned by
   * test_free_mode_dub_layer_retires_not_stuck (and its Song-mode twin,
   * test_song_mode_dub_layer_retires_not_stuck). */
  const int32_t mode = load_i32(&e->a_looper_mode);
  const int free_mode = mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  for (int32_t ti = 0; ti < e->track_count; ++ti) {
    le_track* t = &e->tracks[ti];
    le_dub_try_retire(e, t, frame);
    if (!load_i32(&t->a_layer_in_flight)) continue;
    const int32_t st = load_i32(&t->a_state);
    if (st == LE_TRACK_OVERDUBBING || t->od_gain > 0.0f) continue; /* writing */
    const int32_t base = free_mode ? t->free_clock.length : e->clock.length;

    /* Punch-out complete. A partially covered shadow drains: the un-backed
     * positions were never written this pass, so live still holds their
     * pre-pass values and any copy order works — the trajectory walk just
     * enumerates exactly the uncovered set. */
    if (t->dub_slot >= 0 && t->dub_count > 0 && t->dub_count < t->dub_len &&
        !t->dub_draining && base > 0) {
      t->dub_draining = 1;
      const int32_t k0 = load_i32(&t->a_multiple) > 0
                             ? load_i32(&t->a_multiple)
                             : 1;
      const int64_t ahead = (int64_t)t->dub_start_vpos + t->dub_count;
      t->dub_vpos = (int32_t)(ahead % base);
      t->dub_vseg = (int32_t)((t->dub_start_vseg + ahead / base) % k0);
    }
    if (t->dub_draining && base > 0) {
      const int32_t k = load_i32(&t->a_multiple) > 0 ? load_i32(&t->a_multiple)
                                                     : 1;
      const int32_t off = t->dub_offset > 0 ? t->dub_offset % base : 0;
      const int32_t lanes = le_lanes_active(t);
      /* The copy runs per lane, so the RT budget is frames x lanes — scale the
       * chunk down so a multi-lane track drains the same bytes per block as a
       * mono one (LE_DRAIN_CHUNK samples per track per callback). */
      int32_t budget = LE_DRAIN_CHUNK / lanes;
      if (budget < 1) budget = 1;
      while (budget > 0 && t->dub_count < t->dub_len) {
        int32_t max_run = budget;
        if (max_run > t->dub_len - t->dub_count) {
          max_run = t->dub_len - t->dub_count;
        }
        const int32_t run = le_dub_run_copy(t, base, k, off, &t->dub_vpos,
                                            &t->dub_vseg, max_run, 0);
        t->dub_count += run;
        budget -= run;
      }
      if (t->dub_count >= t->dub_len) t->dub_draining = 0;
    }
    if (t->dub_draining) continue; /* more chunks next block */

    /* Retire a complete shadow (drained, or frozen at punch-out). */
    if (t->dub_slot >= 0 && t->dub_count >= t->dub_len &&
        t->dub_retire_slot < 0) {
      t->dub_retire_slot = t->dub_slot;
      t->dub_slot = -1;
      le_audio_rev_bump(t); /* [R1] the punch-out pass retired (post-drain) */
      le_dub_try_retire(e, t, frame);
    }
    /* Session fully wound down: every layer retired and collected-able. */
    if (t->dub_retire_slot < 0 && (t->dub_slot < 0 || t->dub_count <= 0)) {
      atomic_store_explicit(&t->a_layer_in_flight, 0, memory_order_release);
    }
  }
}

/* Drops a track whole at a reopen: the take it was capturing, or the
 * bookkeeping a state command the audio thread never applied had already
 * moved. EMPTY, nothing recoverable, fresh Fade; a defining take leaves the
 * clock unset. A fresh capture started on an empty history
 * (le_begin_empty_capture clears redo and drops a cleared history), and a
 * pending Clear/Undo/Redo has pre-mutated the stacks it was about to apply,
 * so neither history is worth keeping. */
static void le_reopen_drop_track(le_engine* e, le_track* t) {
  le_audio_rev_bump(t); /* [R1] reopen: the take is gone */
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  store_i32(&t->a_sync_divisor, 0);
  t->undo_count = 0;
  t->redo_count = 0;
  t->empty_len = 0;
  t->clear_restore_slot = -1;
  store_i32(&t->a_undo_depth, 0);
  store_i32(&t->a_clear_restore, 0);
  store_i32(&t->a_redo_depth, 0);
  store_i32(&t->a_peel_depth, 0);
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    store_i32(&t->lanes[l].a_recoverable, 0);
    t->lanes[l].pending_mute = 0;
  }
  le_transform_reset(e, t, 0); /* nothing left to fade; new generation */
  /* Free/Song: a track reading EMPTY never carries an established clock of
   * its own (handle_clear's invariant). */
  le_loop_clock_reset(&t->free_clock);
  t->free_iteration = 0;
}

/* Retained reopen (#1140), audio-side half — see engine_core.h. Control
 * thread, device closed: the audio thread is gone, so its fields are owned
 * here and nothing below is RT-bounded. le_engine_reopen_file_retired has
 * already filed every complete pass, so an armed shadow left with coverage is
 * a PARTIAL pass. Owner decisions (2026-10-05): loops come back STOPPED,
 * recording never resumes, a partial pass is discarded. Standing delivery
 * rules: keep recorded material, drop only the uncertain state — so a track
 * named in `drop_mask` goes, and only that track. */
void le_engine_reopen_settle(le_engine* e, uint32_t drop_mask) {
  if (e == NULL) return;
  const int32_t mode = load_i32(&e->a_looper_mode);
  const int free_mode =
      mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG;
  int dropped_any = 0;
  for (int32_t ch = 0; ch < e->track_count; ++ch) {
    le_track* t = &e->tracks[ch];
    const int32_t st = load_i32(&t->a_state);
    /* A take still capturing is dropped whole: a first recording (defining
     * or not, including one parked in its deferred seam crossfade) and a
     * just-finalized take whose trailing seam fold (#728) has not landed
     * (`xfade_capture > 0` is RECORDING). So is a track whose state command
     * the audio thread never saw. Recording never resumes. */
    const int drop = st == LE_TRACK_RECORDING || t->seam_capture > 0 ||
                     (drop_mask & (1u << ch)) != 0;

    /* An in-progress overdub pass: every write of the pass saved its pre-value
     * into the armed shadow at the same index, so walking the covered
     * trajectory shadow -> live puts the pre-pass image back sample-exactly
     * on every lane. A drain that was mid-flight copied live -> shadow for
     * positions the pass never wrote, so those copy back unchanged. A pass
     * running without an armed shadow (spare starvation) cannot be reverted
     * and stays merged — the same coherent result it has today. */
    if (!drop && t->dub_slot >= 0 && t->dub_len > 0 && t->dub_count > 0 &&
        t->dub_count < t->dub_len) {
      const int32_t base = free_mode ? t->free_clock.length : e->clock.length;
      if (base > 0) {
        int32_t k = load_i32(&t->a_multiple);
        if (k < 1) k = 1;
        const int32_t off = t->dub_offset > 0 ? t->dub_offset % base : 0;
        int32_t vpos = t->dub_start_vpos;
        int32_t vseg = t->dub_start_vseg;
        int32_t left = t->dub_count;
        while (left > 0) {
          left -= le_dub_run_copy(t, base, k, off, &vpos, &vseg, left, 1);
        }
        le_audio_rev_bump(t); /* [R1] reopen: the partial pass is reverted */
      }
    }

    if (drop) {
      le_reopen_drop_track(e, t);
      dropped_any = 1;
    } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING ||
               st == LE_TRACK_STOPPED) {
      store_i32(&t->a_state, load_i32(&t->lanes[0].a_len) > 0
                                 ? LE_TRACK_STOPPED
                                 : LE_TRACK_EMPTY);
      /* Fade: frozen at whatever the last callback left. frames = 0 makes
       * le_fade_tick re-origin the ramp at that amount, so it resumes toward
       * the unchanged target at the unchanged full-travel seconds — no
       * wall-clock catch-up for the time the device was gone. */
      t->fade.frames = 0;
    }
    /* EMPTY stays as it is: a cleared history remains restorable. */

    /* Park at the loop head: a later Play starts every loop from frame 0
     * through the ordinary handle_play / unpark path, the same transport
     * fact LE_CMD_COMMIT_SESSION establishes for a recalled Session. */
    le_reset_track_playback(t);
    t->start_iter = 0;
    t->record_pos = 0;
    t->record_start = 0;
    t->od_gain = 0.0f;
    t->xfade_capture = 0;
    le_dub_drop_armed(t); /* also clears seam_capture + pending shadow */
    atomic_store_explicit(&t->a_layer_in_flight, 0, memory_order_release);
    store_i32(&t->a_play_pos, 0);
    e->trk_play_pos[ch] = 0;
    le_fade_publish(e, t);
  }
  e->clock.position = 0;
  e->loop_iteration = 0;
  store_i32(&e->a_master_pos, 0);
  for (int32_t ch = 0; ch < e->track_count; ++ch) {
    e->tracks[ch].free_clock.position = 0;
    e->tracks[ch].free_iteration = 0;
  }
  /* A drop that leaves every track EMPTY resets the master so a new loop can
   * be defined — exactly handle_clear's rule (a rig that was already all
   * EMPTY, e.g. undone to empty with its redo pending, keeps its master: no
   * drop happened, nothing changed). The loop-derived grid dies with it; the
   * tempo value and source survive (D6). */
  if (dropped_any) {
    int all_empty = 1;
    for (int32_t ch = 0; ch < e->track_count; ++ch) {
      if (load_i32(&e->tracks[ch].a_state) != LE_TRACK_EMPTY) all_empty = 0;
    }
    if (all_empty) {
      le_loop_clock_reset(&e->clock);
      store_i32(&e->a_master_len, 0);
      store_i32(&e->a_loop_bars, 0);
      e->grid_total_beats = 0;
    }
  }
  /* A rig that kept content keeps (or, lacking one, gains) its crown; a
   * dropped take uncrowns nothing a clear would not have. */
  le_primary_reconcile(e);
}

/* There is a single input stream, so only one track may capture at a time.
 * Closes any track (other than `except_ch`) that is currently RECORDING or
 * OVERDUBBING, finalizing the master loop if the closed track was the defining
 * recording. Called before starting a new capture. */
static void close_active_capture(le_engine* e, int32_t except_ch,
                                 uint64_t frame) {
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (t == except_ch) continue;
    le_track* tr = &e->tracks[t];
    const int32_t st = load_i32(&tr->a_state);
    if (st != LE_TRACK_RECORDING && st != LE_TRACK_OVERDUBBING) continue;
    /* The hand-off supersedes any armed (quantized) end on the closed track:
     * the finalize it was waiting for happens right here, so a stale pending
     * would re-fire at the next boundary on the now-PLAYING track and start a
     * spurious overdub — the same reasoning as le_apply_mute_cmd's punch-out
     * clear. */
    tr->pending_record = 0;
    tr->pending_trigger = 0;
    store_i32(&tr->a_pending, 0);
    if (st == LE_TRACK_RECORDING) {
      if (e->launch_committing && e->launch_grace[t] == 1) {
        apply_undo_to_empty(e, t, frame);
        e->launch_grace[t] = 0;
        store_i32(&tr->a_launch_grace, 0);
        continue;
      }
      if (e->clock.length == 0) {
        /* Hand-off is immediate (one capturer): if this master was mid seam-
         * crossfade deferral, lock its intended length and finalize now without
         * the crossfade rather than keep it recording alongside the new track. */
        if (tr->xfade_capture > 0) {
          tr->record_pos = tr->xfade_len;
          tr->xfade_capture = 0;
        }
        /* Provably already 0 on this branch — a trailing seam overlap is armed
         * only by finalize_new_track, which is only reachable with a defining
         * loop, and this is the no-loop one (#728). Cleared anyway so the
         * per-take deferral reset here is exhaustive by CONSTRUCTION rather
         * than by that argument, which no assertion holds up. */
        tr->seam_capture = 0;
        finalize_master(e, tr, LE_TRACK_PLAYING, frame); /* defines the master loop */
      } else {
        finalize_new_track(e, tr, LE_TRACK_PLAYING, frame); /* round up to whole loops */
      }
    } else if (st == LE_TRACK_OVERDUBBING) {
      store_i32(&tr->a_state, LE_TRACK_PLAYING);
    }
  }
}

/* Acts on a record/overdub press: finalizes any other capture (one-capturer
 * hand-off), then advances this track's state machine. */
static void handle_record(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  if (!e->launch_committing && le_launch_remove(e, ch)) return;
  if (!e->launch_committing && e->launch_grace[ch]) {
    const int action = e->launch_grace[ch];
    e->launch_grace[ch] = 0;
    store_i32(&e->tracks[ch].a_launch_grace, 0);
    if (action == 1 && load_i32(&e->tracks[ch].a_state) == LE_TRACK_RECORDING) {
      apply_undo_to_empty(e, ch, frame);
    } else if (action == 2 || action == 3) {
      store_i32(&e->tracks[ch].a_state, LE_TRACK_STOPPED);
    }
    return;
  }
  const int initial = load_i32(&e->tracks[ch].a_state);
  /* Overdub is unavailable while Reverse is on (#1162): the write head, its
   * latency compensation and the per-pass shadow are forward-only, so a
   * punch-in on a reversed track is dropped here whatever queued it — a grid
   * or sound arm that fired after the toggle, or a Count-in member. Control
   * already refuses the press with LE_ERR_REVERSED; this closes the window. */
  if ((initial == LE_TRACK_STOPPED || initial == LE_TRACK_PLAYING) &&
      e->tracks[ch].reversed) return;
  if ((initial == LE_TRACK_EMPTY || initial == LE_TRACK_STOPPED ||
       initial == LE_TRACK_PLAYING) &&
      le_launch_defer(e, ch, initial == LE_TRACK_EMPTY ? 1 : 3)) return;
  /* Latched BEFORE any state mutation: a capture start from a held transport
   * unparks the whole loop (le_unpark_stopped) after it lands. */
  const int was_held = le_transport_held(e);
  close_active_capture(e, ch, frame);
  le_track* t = &e->tracks[ch];
  switch (load_i32(&t->a_state)) {
    case LE_TRACK_EMPTY:
      le_reset_track_playback(t);
      /* A fresh capture may define a new loop length: leftover armed shadow
       * slots (sized for the previous loop) are dropped; control reclaimed
       * them when it posted this command/arm. */
      le_start_capture_shadows(t);
      /* First record overall (no master yet) defines the master loop; otherwise
       * the new track records freely from the loop top. Both are RECORDING,
       * distinguished by clock.length. */
      if (e->clock.length == 0) {
        t->record_pos = 0;
        t->record_start = 0;
        le_loop_clock_reset(&e->clock);
        le_transform_reset(e, t, frame);
        store_i32(&t->a_state, LE_TRACK_RECORDING);
        le_arm_length_preset_target(e, t); /* A6: may arm an N-bars target */
      } else {
        /* New track over an existing master: begin capturing immediately at the
         * current loop phase — no waiting for the loop top. record_pos seeds to
         * the master position and start_iter to the current iteration, so it
         * stays equal to (loop_iteration - start_iter)*base + position; buffer
         * writes are therefore phase-locked to the master. Spans one or more
         * base loops, rounded up on stop — or exactly K with a fixed multiple
         * (auto-finalized), where the write head wraps into K*base so a
         * mid-loop take keeps the audio played past the loop top. The slice
         * before the press stays silent (zeroed on the control thread) until
         * a fixed-multiple take wraps around and fills it. */
        t->record_pos = e->clock.position;
        t->record_start = t->record_pos;
        t->start_iter = e->loop_iteration;
        le_transform_reset(e, t, frame);
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      }
      /* The transport fact: this track actually began recording THIS frame —
       * whether from an immediate press (frame == the buffer-start tag from
       * apply_command) or a deferred quantized/sound-triggered fire (frame ==
       * the exact sample index from inside the per-frame loop). Its take id is
       * bumped here (#819): one new monotonic id per take begun on this track. */
      t->take_seq++;
      le_plog_push(e, frame,
                  (le_command){.code = LE_PLOG_RECORD_START, .arg_i = ch});
      /* Auto-unmute + unpark: a capture never starts silent, and starting one
       * from a held transport resumes the whole loop. */
      le_capture_start_unmute(e, t, frame);
      if (was_held) le_unpark_stopped(e, frame);
      break;
    case LE_TRACK_RECORDING: {
      /* Second press finalizes. In rec/dub mode it continues into overdub
       * instead of playback; the shadow slot pre-armed during RECORDING (see
       * le_engine_record / le_engine_drain_events) lets this first wrap's pass
       * back up on write and retire as its own undo layer, unless the loop was
       * too short for that post to land (then it merges — see le_dub_boundary).
       * A stop press ends in playback/stopped (handle_stop), never overdub. */
      const int32_t end = e->rec_dub ? LE_TRACK_OVERDUBBING : LE_TRACK_PLAYING;
      if (e->clock.length == 0) {
        request_master_finalize(e, t, end, frame); /* defers for the seam crossfade */
      } else {
        finalize_new_track(e, t, end, frame);
      }
      break;
    }
    case LE_TRACK_PLAYING:
    case LE_TRACK_STOPPED:
      /* Punch-in: arm the per-pass layer capture (the shadow slots were posted
       * by le_engine_record before this command). Auto-unmute first — an
       * overdub over a Stop-muted (or parked-muted) track must be audible —
       * and unpark the loop when this start is what wakes a held transport. */
      le_restart_once(e, t);
      le_capture_start_unmute(e, t, frame);
      store_i32(&t->a_state, LE_TRACK_OVERDUBBING);
      le_dub_session_start(e, t);
      if (was_held) le_unpark_stopped(e, frame);
      break;
    case LE_TRACK_OVERDUBBING:
      store_i32(&t->a_state, LE_TRACK_PLAYING);
      /* Punch-out is a capture end: land any mute deferred during the dub. */
      le_consume_pending_mutes(e, t, LE_TRACK_PLAYING, 1, frame);
      break;
    default:
      break;
  }
}

/* Logical Stop's cancellation half. Unlike the FX handoff's DISARM sweep,
 * this leaves unrelated grid/Sound arms and older live captures alone. */
static int le_cancel_count_in(le_engine* e, uint64_t frame) {
  int canceled = e->count_in_total > 0;
  if (canceled) le_count_in_reset(e);
  for (int c = 0; c < e->track_count; ++c) {
    if (!e->launch_grace[c]) continue;
    canceled = 1;
    handle_record(e, c, frame);
  }
  return canceled;
}

/* The audio-thread body of an undo past the base take (LE_CMD_UNDO_TO_EMPTY,
 * and the cancelled take of LE_CMD_CANCEL_TAKE): the track reads content-less
 * while its live slot keeps the audio for redo, and the master grid survives
 * because redo needs it. The caller acks the state command. */
static void apply_undo_to_empty(le_engine* e, int32_t ch, uint64_t frame) {
  le_track* t = &e->tracks[ch];
  le_reset_track_playback(t);
  le_audio_rev_bump(t); /* [R1] undo to empty: content-less from here */
  t->record_pos = 0;
  t->start_iter = 0;
  t->pending_record = 0;
  t->od_gain = 0.0f;
  t->xfade_capture = 0;
  t->seam_capture = 0; /* #728 */
  t->length_preset_target_frames = 0; /* a stale armed target dies with it */
  /* The capture (if any) is gone: a mute deferred during it must not
   * ambush some future capture's end. */
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    t->lanes[l].pending_mute = 0;
  }
  store_i32(&t->a_pending, 0);
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_transform_reset(e, t, frame);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  store_i32(&t->a_sync_divisor, 0); /* B3: division state dies too */
  /* Free mode (B2b): same invariant-preserving reset as handle_clear's —
   * a track reading EMPTY must never carry an established free_clock.
   * Cheap no-op outside Free mode (already dormant there). */
  le_loop_clock_reset(&t->free_clock);
  t->free_iteration = 0;
  reset_track_viz(e, ch);
  e->trk_play_pos[ch] = 0;
  /* The to-EMPTY edge case of undo (LE_PLOG_UNDO, not a raw copy of the
   * command — every undo path, common in-track swap or this one, logs the
   * same semantic code so a downstream consumer never needs to know which
   * internal path fired). */
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_UNDO, .arg_i = ch});
  /* And the raw command at its exact apply frame (events.log version 6,
   * #1143): emptying is exact silence from here, not lost provenance — the
   * offline renderer appends a silence segment, as it does for LE_CMD_CLEAR.
   * Also logged for a cancelled take, which empties through this same body. */
  le_plog_push(e, frame, (le_command){.code = LE_CMD_UNDO_TO_EMPTY, .arg_i = ch});
  le_primary_reconcile(e); /* undoing the last take uncrowns */
}

/* Applies LE_CMD_FINALIZE_TAKE (le_engine_finalize_take, #405): ends the
 * addressed track's live take NOW — or does nothing. The control side already
 * refused every wrong state; this re-check makes the guarantee hold across
 * the one-block window between that guard and this apply, where a
 * fixed-multiple auto-finalize, an arm firing, or a count-in commit could
 * have moved the state. Where LE_CMD_RECORD's meaning depends on the state it
 * lands on, every branch here either ends a capture or does nothing:
 * - RECORDING, non-defining (clock.length > 0): finalize_new_track, the exact
 *   quantize-off second-press finalize — round UP to whole base loops, the
 *   silence tail seam-treated (#730), RECORD_END logged there. Always to
 *   PLAYING, never rec/dub's continue-into-overdub: FX mode's transport is
 *   inert, so the punch-out would be unreachable.
 * - RECORDING, defining (clock.length == 0): refuse — a mode switch must
 *   never set the session's grid. This is the race backstop for a count-in
 *   commit landing in the same block: capture-survives, exactly the
 *   documented defining-take fallback.
 * - anything else: strict no-op. */
static void handle_finalize_take(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  if (load_i32(&t->a_state) != LE_TRACK_RECORDING) return;
  if (e->clock.length == 0) return; /* the defining take keeps running */
  finalize_new_track(e, t, LE_TRACK_PLAYING, frame);
}

static void handle_stop(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  /* A stop press during a count-in cancels it (D9). The stop then proceeds
   * normally — a no-op on the idle transport a count-in requires. */
  if (e->count_in_total > 0) le_count_in_reset(e);
  le_track* t = &e->tracks[ch];
  const int32_t st = load_i32(&t->a_state);
  if (st == LE_TRACK_RECORDING) {
    if (e->clock.length == 0) {
      request_master_finalize(e, t, LE_TRACK_STOPPED, frame); /* defers for crossfade */
    } else {
      finalize_new_track(e, t, LE_TRACK_STOPPED, frame); /* round up to whole loops */
    }
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) {
    store_i32(&t->a_state, LE_TRACK_STOPPED);
    /* Stopping an overdub ends its capture: land any deferred mute. */
    le_consume_pending_mutes(e, t, LE_TRACK_STOPPED, 1, frame);
  }
}

/* Clears every effect tail on [fx] (slice 3b, Cut all sound): the DSP state
 * of every typed slot and its delay rings, at once. Settings and the enable
 * runtime stay, so an engaged effect carries on from silence. A hosted
 * plugin has no reset seam and keeps its own tail.
 *
 * RT note: this is the one place that clears rings WITHOUT the
 * LE_FX_ENABLE_CLEAR_SPACING stagger a chain stomp uses, and deliberately.
 * Deferring a slot's clear means passing it DRY until its turn, and dry is
 * the wrong output for a fully wet effect: a full-wet delay on a live
 * monitor would burst the raw input at full level for the deferral window,
 * at the instant the user asked for silence. The stagger exists for a stomp,
 * which repeats per chain and can be held down; Cut is one deliberate event,
 * and the work is bounded by the allocated rings. Worst-case callback
 * latency still requires device validation. */
static void le_fx_state_clear_tails(le_fx_state* fx, _Atomic int32_t* types,
                                    int fx_cap) {
  for (int s = 0; s < LE_FX_MAX; ++s) {
    if (load_i32(&types[s]) == LE_FX_NONE) continue;
    le_fx_entry_reset(fx, s);
    le_fx_entry_clear_rings(fx, s, fx_cap);
  }
}

/* Clears the tails of chain slots [first, last) on [fx] (slice 3e).
 *
 * The accepted design: "Printed Pre stops with its recording." A Pre entry
 * belongs to the take, so when the take stops sounding its delay/reverb tail
 * has to stop with it — unlike a Post entry, whose tail drains past a Stop.
 * While the print is engaged that happens for free (the tail is inside the
 * rendered audio and the lane simply stops reading it); this is the same
 * behaviour on the live fallback, where the Pre slots really are running.
 *
 * Same no-stagger reasoning as le_fx_state_clear_tails: a Stop is one
 * deliberate event, and deferring a full-wet slot's clear would pass its dry
 * input through at full level exactly when the player asked for silence. */
static void le_fx_state_clear_tails_range(le_fx_state* fx,
                                          _Atomic int32_t* types, int first,
                                          int last, int fx_cap) {
  if (first < 0) first = 0;
  if (last > LE_FX_MAX) last = LE_FX_MAX;
  for (int s = first; s < last; ++s) {
    if (load_i32(&types[s]) == LE_FX_NONE) continue;
    le_fx_entry_reset(fx, s);
    le_fx_entry_clear_rings(fx, s, fx_cap);
  }
}

/* Cut all sound (accepted design): every audible recorded track stops (a
 * take in progress finalizes as a Stop would), the count-in is cancelled,
 * and every chain's tail is cleared. Monitors keep their preferences. */
static void handle_cut_sound(le_engine* e, uint64_t frame) {
  /* Retire the pulse already sounding. Future beats still follow the
   * existing scheduler and click preferences. */
  e->click_remaining = 0;
  e->click_phase = 0.0f;
  const int fx_cap = e->fx_delay_frames;
  for (int32_t ch = 0; ch < e->track_count; ++ch) {
    le_track* t = &e->tracks[ch];
    /* Cancel every pending gesture, including empty sound/grid arms and
     * quantized punch-outs on nonempty tracks. Keep their captured PCM. */
    t->pending_record = 0;
    t->pending_trigger = 0;
    t->pending_image.revision = 0;
    t->pending_capture_shadow = 0;
    store_i32(&t->a_pending, 0);
    const int32_t st = load_i32(&t->a_state);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_PLAYING ||
        st == LE_TRACK_OVERDUBBING) {
      /* Synthetic per-track stop, the le_one_shot_stop precedent (#420): the
       * log is a record of what a listener heard, and a Cut stops these
       * tracks as surely as a stop press would. perf_render does not
       * reconstruct transport from it today (it reads RECORD_END and the
       * audibility commands), so this buys the log's faithfulness, not a
       * behaviour change. */
      le_plog_push(e, frame, (le_command){.code = LE_CMD_STOP, .arg_i = ch});
      handle_stop(e, ch, frame);
    }
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &t->lanes[l];
      le_fx_state_clear_tails(&ln->fx, ln->a_fx_type, fx_cap);
    }
    le_fx_state_clear_tails(&t->bus.fx, t->bus.a_fx_type, fx_cap);
  }
  if (e->count_in_total > 0) le_count_in_reset(e);
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_fx_state_clear_tails(&e->monitors[c].fx, e->monitors[c].a_fx_type,
                            fx_cap);
  }
  const int bus_n = (e->out_channels + 1) / 2;
  for (int k = 0; k < bus_n && k < LE_MAX_OUTPUT_BUSES; ++k) {
    le_fx_state_clear_tails(&e->outputs[k].fx.fx, e->outputs[k].fx.a_fx_type,
                            fx_cap);
    /* The All tracks instance on the same destination (slice 3e): one config,
     * so every instance reads the same types. */
    le_fx_state_clear_tails(&e->all_tracks_fx[k], e->all_tracks.a_fx_type,
                            fx_cap);
  }
  atomic_fetch_add_explicit(&e->a_tail_reset_rev, 1u, memory_order_relaxed);
}

static void handle_play(le_engine* e, int32_t ch, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  if (!e->launch_committing && le_launch_remove(e, ch)) return;
  if (!e->launch_committing && e->launch_grace[ch]) {
    handle_record(e, ch, frame); /* the same cancellation-only grace */
    return;
  }
  if (load_i32(&e->tracks[ch].a_state) == LE_TRACK_STOPPED &&
      le_launch_defer(e, ch, 2)) return;
  const int was_held = le_transport_held(e);
  le_track* t = &e->tracks[ch];
  if (load_i32(&t->a_state) == LE_TRACK_STOPPED) {
    le_restart_once(e, t);
    store_i32(&t->a_state, LE_TRACK_PLAYING);
    /* Playing anything from a held transport unparks the entire loop. */
    if (was_held) le_unpark_stopped(e, frame);
  }
}

/* Applies one lane-mute command, capture-aware. Muting a CAPTURING track
 * punches the capture out (mirroring rec-stop's finalize-then-mute — recording
 * into silence is never meaningful) and defers the mute itself to the capture
 * end via pending_mute, so a capturing track is never observed muted: the
 * mute lands exactly when the capture ends (le_consume_pending_mutes),
 * including across a deferred master-finalize crossfade. The punch-out is
 * logged as the RECORD it is; the deferred mute logs when it lands. Unmutes
 * (and mutes on non-capturing tracks) apply immediately and log verbatim. */
static void le_apply_mute_cmd(le_engine* e, int32_t ch, int32_t lane,
                              int muting, const le_command* cmd,
                              uint64_t frame) {
  le_track* t = &e->tracks[ch];
  le_lane* ln = &t->lanes[lane];
  const int32_t st = load_i32(&t->a_state);
  if (muting &&
      (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING)) {
    ln->pending_mute = 1;
    /* The punch-out supersedes any armed (quantized) action on this track —
     * exactly as apply_command's LE_CMD_RECORD case clears it for a real
     * press. A stale arm would re-fire at the next loop top on the now-
     * PLAYING track and start a spurious overdub (whose capture-start
     * auto-unmute would then override the very mute being applied here). */
    t->pending_record = 0;
    t->pending_trigger = 0;
    store_i32(&t->a_pending, 0);
    /* A master finalize already deferring (xfade_capture > 0) will consume
     * the pending at its completion — no second punch-out. */
    if (t->xfade_capture == 0) {
      le_plog_push(e, frame,
                   (le_command){.code = LE_CMD_RECORD, .arg_i = ch});
      handle_record(e, ch, frame);
    }
    return;
  }
  ln->pending_mute = 0;
  store_i32(&ln->a_muted, muting ? 1 : 0);
  le_plog_push(e, frame, *cmd);
}

static void handle_clear(le_engine* e, int32_t ch, int freeze, uint64_t frame) {
  if (!valid_channel(e, ch)) return;
  le_launch_remove(e, ch);
  e->launch_grace[ch] = 0;
  store_i32(&e->tracks[ch].a_launch_grace, 0);
  le_track* t = &e->tracks[ch];
  const float fade_amount = t->fade.amount;
  int32_t frozen_len = 0, frozen_master_len = 0;
  le_reset_track_playback(t);
  /* A user clear on a capturing track (accepted design, slice 2): freeze the
   * take STOPPED at the clear boundary first — the same finalize a stop press
   * runs, so a defining take still sets the grid and a later take keeps its
   * whole-loop span with silence past what was captured — then report what
   * the restore point needs and erase as usual. The
   * capture is never resumed: undo brings the frozen take back STOPPED. */
  if (freeze) {
    const int32_t st = load_i32(&t->a_state);
    if (st == LE_TRACK_RECORDING && t->record_pos <= 0) {
      /* Nothing captured yet: nothing to freeze, and no one-frame master. */
    } else if (st == LE_TRACK_RECORDING) {
      if (e->clock.length == 0) {
        if (t->xfade_capture > 0) {
          t->record_pos = t->xfade_len; /* lock the intended length, no fade */
          t->xfade_capture = 0;
        }
        finalize_master(e, t, LE_TRACK_STOPPED, frame);
      } else {
        finalize_new_track(e, t, LE_TRACK_STOPPED, frame);
        t->seam_capture = 0; /* nothing to fold into an erased take */
      }
    } else if (st == LE_TRACK_OVERDUBBING) {
      /* The pass ends here; its writes were in place, so the live slot holds
       * base + layers + the partial pass, which is what comes back. */
      store_i32(&t->a_state, LE_TRACK_STOPPED);
      le_consume_pending_mutes(e, t, LE_TRACK_STOPPED, 0, frame);
    }
    frozen_len = load_i32(&t->a_state) == LE_TRACK_STOPPED
                     ? load_i32(&t->lanes[0].a_len) : 0;
    frozen_master_len = load_i32(&e->a_master_len);
  }
  le_audio_rev_bump(t); /* [R1] clear: the track's content is gone */
  t->record_pos = 0;
  t->start_iter = 0;
  t->pending_record = 0;
  t->od_gain = 0.0f;
  t->xfade_capture = 0; /* cancel any in-flight seam-crossfade deferral */
  t->seam_capture = 0;  /* and any trailing seam overlap capture (#728) */
  /* Same class of per-take audio-thread-local deferral state as xfade_capture
   * above (A6): a stale armed target from an aborted take must not survive
   * into whatever the track records next. Defensive — le_arm_length_preset_
   * target already unconditionally overwrites this at the START of every
   * defining take, so a clear between takes has no reachable window where a
   * stale value would be read, but it costs nothing to reset it here too. */
  t->length_preset_target_frames = 0;
  store_i32(&t->a_pending, 0);
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_transform_reset(e, t, frame);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  /* B3, D18: the track's own division state dies with its content — a
   * re-record decides fresh. The PRIMARY DESIGNATION itself is session-level
   * state (a_primary_track), not per-track, and is deliberately untouched
   * here even when [t] is the primary being cleared (D18: persists through
   * clear; no auto-reassignment). */
  store_i32(&t->a_sync_divisor, 0);
  /* Free mode (B2b): this track's own clock (if it had one established)
   * dies with its content, exactly like the master dies with the last
   * track's content below — unconditional and cheap (a no-op reset when
   * already dormant, i.e. every mode but Free), so "a track reading EMPTY
   * has a dormant free_clock" is an invariant provable by construction
   * rather than by tracing every path that can reach EMPTY (this one, and
   * LE_CMD_UNDO_TO_EMPTY below). */
  le_loop_clock_reset(&t->free_clock);
  t->free_iteration = 0;
  reset_track_viz(e, ch);
  e->trk_play_pos[ch] = 0;
  /* Drop the per-pass capture wholesale: the control thread reclaimed every
   * posted shadow slot when it pushed this clear and bumped the generation (we
   * mirror the bump), so an already-pushed retire event from before the clear
   * reads as stale and is never re-stacked. */
  t->dub_slot = -1;
  t->dub_spare = -1;
  t->pending_capture_shadow = 0;
  t->dub_retire_slot = -1;
  t->dub_count = -1;
  t->dub_phase = 0;
  t->dub_draining = 0;
  t->dub_gen_audio++;
  atomic_store_explicit(&t->a_layer_in_flight, 0, memory_order_release);
  /* A cleared track comes back unmuted: the next recording is always audible
   * rather than silently muted by a leftover Stop (or a pending mid-capture
   * mute whose capture this clear just destroyed). */
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    store_i32(&t->lanes[l].a_muted, 0);
    t->lanes[l].pending_mute = 0;
  }
  /* If every track is now empty, reset the master so a new loop can be defined.
   * Buffers are not zeroed here (RT-unsafe); a re-record overwrites a full loop
   * before the track is heard, so stale data never plays. This runs BEFORE the
   * ack bump below: the bump's release pairs with le_effective_state's acquire,
   * so a control thread that has seen this clear acked is guaranteed to also
   * see the master reset — e.g. the first-wrap pre-arm gate reading
   * a_master_len after an internal grid-redefine clear must read 0, never the
   * dead grid's length (a stale read there would pre-arm, and strand a
   * cap-sized slot on, the defining capture the gate exists to skip). */
  int all_empty = 1;
  for (int32_t k = 0; k < e->track_count; ++k) {
    if (load_i32(&e->tracks[k].a_state) != LE_TRACK_EMPTY) {
      all_empty = 0;
      break;
    }
  }
  if (all_empty) {
    le_loop_clock_reset(&e->clock);
    e->loop_iteration = 0;
    store_i32(&e->a_master_len, 0);
    store_i32(&e->a_master_pos, 0);
    /* The grid dies with its loop — but ONLY the loop-derived part. The tempo
     * value and its source survive (D6 dead-tempo survival: the next defining
     * loop rounds to the surviving tempo instead of re-deriving), and this
     * all-empty reset is also exactly what releases the D6 tempo lock. */
    store_i32(&e->a_loop_bars, 0);
    store_i32(&e->a_current_beat, 0);
    e->grid_total_beats = 0;
    e->grid_prev_beat = -1;
    /* The tap pair dies with the lock: a tap latched before the D6 lock
     * engaged must not pair with the first tap after this release (a
     * record+clear span inside the 0.2–2 s window would otherwise publish a
     * plausible-looking but meaningless TAPPED tempo). */
    e->has_tap = 0;
    e->last_tap_frame = 0;
    /* Clear the loop waveform so a re-record starts from silence. */
    e->loop_viz_bucket = -1;
    for (int i = 0; i < LE_VIZ_POINTS; ++i) {
      store_f32(&e->a_loop_viz[i], 0.0f);
      for (int t = 0; t < e->track_count; ++t) {
        store_f32(&e->a_track_viz[t][i], 0.0f);
      }
    }
  }
  le_primary_reconcile(e); /* the last take's clear takes the crown with it */
  /* Publish before the acknowledgement. Unlike the event ring, this one-slot
   * mailbox remains available until control can attach the matching point. */
  uint32_t bits;
  memcpy(&bits, &fade_amount, sizeof(bits));
  atomic_fetch_add_explicit(&t->a_clear_revision, 1, memory_order_seq_cst);
  atomic_store_explicit(&t->a_clear_generation, t->dub_gen_audio, memory_order_seq_cst);
  atomic_store_explicit(&t->a_clear_fade_amount, bits, memory_order_seq_cst);
  atomic_store_explicit(&t->a_clear_len, frozen_len, memory_order_seq_cst);
  atomic_store_explicit(&t->a_clear_master_len, frozen_master_len, memory_order_seq_cst);
  atomic_fetch_add_explicit(&t->a_clear_revision, 1, memory_order_seq_cst);
  atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
  /* Undo/redo stacks and each lane's a_live are reset by le_engine_clear on the
   * control thread; the audio thread only resets the state/transport here. */
}

/* Per-lane / per-monitor effects DSP (the effect kernels, the phase-vocoder /
 * PSOLA octaver, the Freeverb reverb, and the chain runner) moved to engine_fx.c
 * (S1). The cross-TU surface and the PV/PSOLA tuning constants live in
 * engine_fx.h. */

/* Completes a deferred crossfade-finalize of the defining master (set up by
 * request_master_finalize once xfade_capture frames of overlap are captured):
 * folds that overlap into the head with the shared equal-gain seam fold, then
 * finalizes the loop at exactly `len` (length, and so tempo/quantize, are
 * preserved — the overlap is scratch, never part of the loop). */
static void finalize_master_xfade(le_engine* e, le_track* t, uint64_t frame) {
  const int32_t len = t->xfade_len;
  le_seam_fold(t, len, seam_xfade_frames(e));
  t->record_pos = len; /* finalize at the intended length, not len+F */
  t->xfade_capture = 0;
  finalize_master(e, t, t->xfade_end_state, frame);
}

/* Keep the recorded source image independent of live faders. Only the
 * effective values enter meters, render caches and primitive performance logs. */
static void le_publish_lane_mix(le_engine* e, int ch, int l, uint64_t frame,
                                int gain_changed, int pan_changed) {
  le_lane* ln = &e->tracks[ch].lanes[l];
  const float gain = ln->live_level * ln->image_gain;
  const float pan = fmaxf(-1.0f, fminf(1.0f, ln->live_pan + ln->image_pan));
  float gl, gr;
  le_pan_gains(pan, &gl, &gr);
  store_f32(&ln->a_vol_bits, gain);
  store_f32(&ln->a_pan_bits, pan);
  store_f32(&ln->a_pan_gl_bits, gl);
  store_f32(&ln->a_pan_gr_bits, gr);
  if (gain_changed) le_plog_push(e, frame, (le_command){
      .code = LE_CMD_SET_LANE_VOLUME, .lanef = {ch, l, gain}});
  if (pan_changed) le_plog_push(e, frame, (le_command){
      .code = LE_CMD_SET_LANE_PAN, .lanef = {ch, l, pan}});
}

/* Generation survives a take that starts and ends between two polls. */
static void le_apply_capture_image(le_engine* e, le_track* t, uint64_t frame) {
  const le_record_image image = t->pending_image;
  if (image.revision == 0) return;
  t->pending_image.revision = 0;
  le_fx_recipe_apply(e, t->pending_fx, frame);
  t->pending_fx = NULL;
  const int ch = (int)(t - e->tracks);
  e->capture_image_dirty |= 1u << ch;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    if (!(image.lane_mask & (1u << l))) continue;
    t->lanes[l].image_gain = image.gain[l];
    t->lanes[l].image_pan = image.pan[l];
    le_publish_lane_mix(e, ch, l, frame, 1, 1);
  }
  atomic_store_explicit(&t->a_image_revision, image.revision, memory_order_release);
}

/* Stores a pan or balance [v] (NaN reads as centre; clamped to -1..1) with
 * its precomputed gains, for the lane, monitor and output bus handlers. */
static inline void le_store_pan(_Atomic uint32_t* pan_bits,
                                _Atomic uint32_t* gl_bits,
                                _Atomic uint32_t* gr_bits, float v) {
  if (!(v >= -1.0f)) v = v < -1.0f ? -1.0f : 0.0f;
  if (v > 1.0f) v = 1.0f;
  float gl;
  float gr;
  le_pan_gains(v, &gl, &gr);
  store_f32(gl_bits, gl);
  store_f32(gr_bits, gr);
  store_f32(pan_bits, v);
}

/* Sums a lane/monitor's processed (l, r) pair into the masked channels of ONE
 * frame's channel slice [o]: the left on the first masked channel and the
 * right on the second; any further masked channels — and the lone channel
 * when only one is masked — get the (l + r)/2 sum, so no routed output is
 * ever dropped. A mono source has l == r, so a single masked channel gets l,
 * two get (l, r) == (l, l), and extras get the mid == l: identical to plain
 * mono routing.
 *
 * Split out of le_fx_route (slice 3e) so the recorded tracks can be routed
 * into a scratch frame instead of the output buffer when the All tracks chain
 * has something on it — the stage runs on the recorded mix per destination,
 * which is exactly this array. */
static void le_fx_route_frame(float* o, int ch_out, uint32_t mask, float l,
                              float r) {
  const float mid = 0.5f * (l + r);
  int n = 0;
  for (int c = 0; c < ch_out; ++c) {
    if (mask & (1u << c)) n++;
  }
  if (n == 0) return;
  int idx = 0;
  for (int c = 0; c < ch_out; ++c) {
    if (!(mask & (1u << c))) continue;
    o[c] += (n == 1) ? mid : (idx == 0) ? l : (idx == 1) ? r : mid;
    idx++;
  }
}

static void le_fx_route(float* out, int f, int ch_out, uint32_t mask, float l,
                        float r) {
  le_fx_route_frame(out + (size_t)f * (size_t)ch_out, ch_out, mask, l, r);
}

/* Drops the last `drop` captured frames of a RECORDING non-defining track
 * (audio thread; A3's quantized record END, round-down case): zeroes them in
 * every lane's live buffer — mirroring the record write head's own mapping,
 * including the fixed-multiple wrap — and rewinds record_pos, so the finalize
 * that follows lands exactly on the rounded-down grid boundary. The zeroed
 * region was silence before the capture began (le_prepare_new_capture memsets
 * the take's buffers), so this restores the pre-capture state. Bounded: a
 * round-down drop is under half a subdivision unit (<= half a bar), a
 * one-shot cost on the press's apply, not a per-frame one. */
static void le_truncate_capture_tail(le_engine* e, le_track* t, int32_t drop) {
  if (drop <= 0 || drop > t->record_pos) return;
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t offset = load_i32(&e->a_record_offset);
  const int32_t k = le_effective_multiple(e, ch);
  const int32_t known_len =
      (k >= 1 && e->clock.length > 0) ? k * e->clock.length : 0;
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    float* b = t->lanes[l].pool[load_i32(&t->lanes[l].a_live)];
    if (b == NULL) continue;
    for (int64_t p = (int64_t)t->record_pos - drop; p < t->record_pos; ++p) {
      int64_t w = p - offset; /* the same mapping the write head used */
      if (w < 0) continue;    /* latency-window frames were never written */
      if (known_len > 0 && w >= known_len) w %= known_len;
      if (w >= e->max_loop_frames) continue;
      b[(int32_t)w] = 0.0f;
    }
  }
  t->record_pos -= drop;
}

static void le_apply_one_shot(le_track* t, int enabled) {
  const int32_t state = load_i32(&t->a_state);
  if (enabled && !load_i32(&t->a_one_shot) &&
      (state == LE_TRACK_PLAYING || state == LE_TRACK_OVERDUBBING)) {
    t->once_current_pass = 1;
  } else if (!enabled) {
    t->once_current_pass = 0;
  }
  store_i32(&t->a_one_shot, enabled);
}

/* Coupled recording-start edits cancel signal arms in the same command as
 * the setting; grid/section arms belong to other controls and stay pending. */
static void le_cancel_signal_arms(le_engine* e) {
  for (int32_t c = 0; c < e->track_count; ++c) {
    le_track* t = &e->tracks[c];
    if (t->pending_record && t->pending_trigger == 1) {
      t->pending_record = 0;
      t->pending_trigger = 0;
      store_i32(&t->a_pending, 0);
    }
  }
}


/* Performance event log emission (part 3): the audited subset of LE_CMD_* that
 * affects audibility gets logged verbatim (same code, same union arm) at
 * `frame` — the elapsed-frames-since-arm value at the START of the buffer
 * currently being processed (apply_command runs once per le_engine_process
 * call, before the per-frame loop, so this is as fine-grained as a
 * ring-applied command can be tagged; see docs/design/performance-event-log-
 * format.md for why finer isn't meaningful here). Excluded, with the audit
 * rationale: LE_CMD_MEASURE_LATENCY (a device-calibration workflow, not a
 * performance action); LE_CMD_SET_RECORD_OFFSET (a calibration/config value,
 * not something changed mid-performance); LE_CMD_ARM/LE_CMD_DISARM (scheduling
 * intent only — the eventual fire is what's logged, as LE_PLOG_RECORD_START,
 * sample-accurately from inside the per-frame loop below); LE_CMD_DUB_SHADOW
 * (internal shadow-pool bookkeeping, not itself an audible change);
 * LE_CMD_PERF_ARM/LE_CMD_PERF_DISARM (meta — arming/disarming the capture
 * session isn't part of what the session captures);
 * LE_CMD_FINALIZE_TAKE (the ARM/DISARM rationale from the other side: the
 * command is finalize intent, and the transport fact it causes — RECORD_END,
 * or RECORD_ABORT for a cancelled count-in — is what is logged, from
 * finalize_new_track / handle_finalize_take). A command that changes
 * output but isn't logged here is a standing review-checklist item (the
 * umbrella plan). */

/* Validate every affected source before publishing any route or count. */
static int le_apply_routing(le_engine* e, const le_mix_settings* mix,
                            uint64_t frame) {
  if (!le_mix_valid(e, mix)) return 0;
  uint32_t sources = mix->source_track_mask | mix->lane_count_mask;
  for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES; ++i)
    if (mix->routing_input_mask & (UINT64_C(1) << i)) sources |= 1u << (i / LE_MAX_LANES);
  int blocked = 0;
  for (int ch = 0; ch < e->track_count; ++ch) {
    if (!(sources & (1u << ch))) continue;
    le_track* t = &e->tracks[ch];
    if (mix->lane_count_mask & (1u << ch)) {
      for (int l = le_lanes_active(t); l < mix->lane_count[ch]; ++l) {
        const int live = load_i32(&t->lanes[l].a_live);
        if (t->lanes[l].pool[live] == NULL ||
            t->lanes[l].pool_cap[live] < e->max_loop_frames) blocked = 1;
      }
    }
    const int st = load_i32(&t->a_state);
    if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
        t->pending_record || load_i32(&t->a_layer_in_flight) ||
        (e->launch_action[ch] != 0)) blocked = 1;
  }
  if (blocked) return 0; /* refuse the whole batch before any observable write */
  for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES; ++i) {
    const uint64_t bit = UINT64_C(1) << i;
    const int ch = i / LE_MAX_LANES, l = i % LE_MAX_LANES;
    if (mix->routing_input_mask & bit) {
      store_i32(&e->tracks[ch].lanes[l].a_input_channel, mix->lane_input[i]);
      le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_LANE_INPUT,
        .lanei = {ch, l, mix->lane_input[i]}});
    }
    if (mix->routing_output_mask & bit) {
      atomic_store_explicit(&e->tracks[ch].lanes[l].a_output_mask,
                            mix->lane_output[i], memory_order_relaxed);
      le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_LANE_OUTPUT,
        .lanei = {ch, l, (int32_t)mix->lane_output[i]}});
    }
  }
  for (int ch = 0; ch < e->track_count; ++ch)
    if (mix->lane_count_mask & (1u << ch))
      atomic_store_explicit(&e->tracks[ch].lane_count, mix->lane_count[ch], memory_order_release);
  return 1;
}

/* A length edit's playhead map (#1168): index i of the old image reads
 * (i - start) mod len in the new one, so the kept material continues at the
 * same sample and an omitted region lands at the same phase of the kept one. */
static int32_t le_length_map(int64_t i, int32_t start, int32_t len) {
  int64_t m = (i - start) % len;
  if (m < 0) m += len;
  return (int32_t)m;
}

/* LE_CMD_SET_LENGTH accepted (#1168): one drain, before any frame of this
 * block is mixed, swaps the image, the length, the multiple or division and,
 * when the track holds the rig's only content, the master. The clock position
 * goes through the edit's map too, so a zero origin stays zero (the forward
 * segment math is unchanged); the origin is then re-derived from the mapped
 * read index, so a Once relaunch or a reversed track keeps reading on from it.
 * A Reverse turn still mixing the old head snaps. */
static void le_length_apply(le_engine* e, le_track* t, const le_command* cmd,
                            const le_length_fit* fit, uint64_t frame) {
  const int32_t ch = (int32_t)(t - e->tracks);
  const int32_t len = cmd->length.len;
  const int32_t start = cmd->length.start;
  int32_t old_len;
  const int64_t old_pos = le_track_base_position(e, t, &old_len);
  const int32_t index = le_length_map(
      le_direction_index(t->reversed, t->playback_offset, old_pos, old_len),
      start, len);
  const int32_t pos = le_length_map(old_pos, start, len);
  le_dub_drop_armed(t); /* idle shadows sized for the old length */
  for (int32_t l = le_lanes_active(t) - 1; l >= 0; --l) {
    atomic_store_explicit(&t->lanes[l].a_live, cmd->length.pool_slot,
                          memory_order_release);
  }
  le_track_set_len(t, len);
  store_i32(&t->a_multiple, cmd->length.multiple);
  store_i32(&t->a_sync_divisor, cmd->length.divisor);
  const int32_t mode = load_i32(&e->a_looper_mode);
  if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
    le_loop_clock_set_length(&t->free_clock, len);
    t->free_clock.position = pos;
  } else if (cmd->length.reclock > 0) {
    le_plog_push(e, frame, (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED,
                                       .arg_i = len});
    le_loop_clock_set_length(&e->clock, len);
    e->clock.position = pos;
    e->loop_iteration = 0;
    t->start_iter = 0;
    store_i32(&e->a_master_len, len);
    le_restore_musical_grid(e, fit->bars); /* the verdict kept the tempo */
    e->loop_viz_bucket = -1;
  } else if (cmd->length.divisor == 0 && e->clock.length > 0) {
    /* The segment the mapped position sits in, counted from the current
     * iteration (unsigned arithmetic: only differences are ever read). */
    const int32_t base = e->clock.length;
    const int64_t d = (int64_t)pos - e->clock.position;
    int64_t seg = d / base;
    if (d < 0 && d % base != 0) seg -= 1; /* floor */
    seg %= cmd->length.multiple;
    if (seg < 0) seg += cmd->length.multiple;
    t->start_iter = e->loop_iteration - (uint64_t)seg;
  }
  t->turn_left = 0;
  int32_t new_len;
  const int64_t new_pos = le_track_base_position(e, t, &new_len);
  t->playback_offset = le_direction_origin(t->reversed, index, new_pos, len);
  e->trk_play_pos[ch] =
      le_length_map(e->trk_play_pos[ch] % old_len, start, len);
  reset_track_viz(e, ch);
  le_audio_rev_bump(t); /* [R1] length edit: other audio */
  le_plog_push(e, frame, (le_command){.code = LE_PLOG_LENGTH,
      .length_log = {ch, cmd->length.pool_slot, len, cmd->length.image_id}});
}

static void apply_command_image(le_engine* e, const le_command* cmd,
                                uint64_t frame, int preserve_image);
static void apply_command(le_engine* e, const le_command* cmd, uint64_t frame) {
  apply_command_image(e, cmd, frame, 0);
}
static void apply_command_image(le_engine* e, const le_command* cmd,
                                uint64_t frame, int preserve_image) {
  switch (cmd->code) {
    case LE_CMD_SET_LANE_COUNT: {
      const int ch = cmd->lanei.channel;
      if (ch < 0 || ch >= e->track_count) break;
      le_mix_settings mix = {.revision = 1, .lane_count_mask = 1u << ch};
      mix.lane_count[ch] = cmd->lanei.value;
      (void)le_apply_routing(e, &mix, frame);
      break;
    }
    case LE_CMD_SET_MIX: {
      const le_mix_settings* mix = &cmd->mix;
      if (!le_apply_routing(e, mix, frame)) break;
      for (int ch = 0; ch < e->track_count; ++ch) {
        if (!(mix->track_gain_mask & (1u << ch))) continue;
        store_f32(&e->tracks[ch].a_gain_bits, mix->track_gain[ch]);
        le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_VOLUME,
            .arg_i = ch, .arg_f = mix->track_gain[ch]});
      }
      /* Emit only applied primitive facts; events.log's 16-byte payload must
       * never receive the much larger in-process batch arm. */
      for (int i = 0; i < LE_MAX_TRACKS * LE_MAX_LANES; ++i) {
        const uint64_t bit = UINT64_C(1) << i;
        if (!((mix->lane_mask | mix->image_mask) & bit)) continue;
        const int ch = i / LE_MAX_LANES, l = i % LE_MAX_LANES;
        le_lane* ln = &e->tracks[ch].lanes[l];
        if (mix->lane_mask & bit) {
          ln->live_level = mix->lane_gain[i];
          ln->live_pan = mix->lane_pan[i];
        }
        if (mix->image_mask & bit) {
          ln->image_gain = mix->image_gain[i];
          ln->image_pan = mix->image_pan[i];
        }
        le_publish_lane_mix(e, ch, l, frame, 1, 1);
      }
      for (int i = 0; i < LE_MAX_CHANNELS; ++i) {
        if (mix->monitor_mask & (1u << i)) {
          le_command c = {.code = LE_CMD_SET_MONITOR_INPUT_VOLUME,
                          .arg_i = i, .arg_f = mix->monitor_gain[i]};
          apply_command(e, &c, frame);
          c = (le_command){.code = LE_CMD_SET_MONITOR_INPUT_PAN,
                           .lanef = {i, 0, mix->monitor_pan[i]}};
          apply_command(e, &c, frame);
        }
        if (mix->trim_mask & (1u << i)) store_f32(&e->a_in_trim_bits[i], mix->input_trim[i]);
      }
      for (int i = 0; i < e->track_count; ++i) {
        if (!(mix->solo_mask & (1u << i))) continue;
        const le_command c = {.code = LE_CMD_SET_TRACK_SOLO, .arg_i = i,
                              .arg_f = (mix->solo_values & (1u << i)) ? 1.0f : 0.0f};
        apply_command(e, &c, frame);
      }
      for (int i = 0; i < LE_MAX_OUTPUT_BUSES; ++i) {
        if (!(mix->output_mask & (1u << i))) continue;
        le_command c = {.code = LE_CMD_SET_OUTPUT_LEVEL,
                         .lanef = {i, 0, mix->output_level[i]}};
        apply_command(e, &c, frame);
        c = (le_command){.code = LE_CMD_SET_OUTPUT_MUTE,
                          .lanef = {i, 0, (mix->output_muted & (1u << i)) != 0}};
        apply_command(e, &c, frame);
        c = (le_command){.code = LE_CMD_SET_OUTPUT_MONO,
                          .lanef = {i, 0, (mix->output_mono & (1u << i)) != 0}};
        apply_command(e, &c, frame);
        c = (le_command){.code = LE_CMD_SET_OUTPUT_BALANCE,
                          .lanef = {i, 0, mix->output_balance[i]}};
        apply_command(e, &c, frame);
      }
      atomic_store_explicit(&e->a_mix_revision, mix->revision, memory_order_release);
      break;
    }
    case LE_CMD_SET_FX_RECIPE:
      le_fx_recipe_apply(e, cmd->recipe, frame);
      break;
    case LE_CMD_RECORD_IMAGE: {
      const int ch = cmd->record_image.channel;
      if (!le_image_valid(e, ch, &cmd->record_image.image)) break;
      e->tracks[ch].pending_image = cmd->record_image.image;
      e->tracks[ch].pending_fx = cmd->record_image.recipes;
      e->tracks[ch].pending_capture_shadow = 0;
      le_command action = {.code = cmd->record_image.action};
      if (action.code == LE_CMD_RECORD) {
        action.clock.value = ch;
        action.clock.sequence = cmd->record_image.sequence;
      } else if (action.code == LE_CMD_ARM) {
        action.arg_i = ch;
        action.arg_f = cmd->record_image.trigger;
      } else break;
      apply_command_image(e, &action, frame, 1);
      break;
    }
    case LE_CMD_MEASURE_LATENCY: {
      const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
      e->lat_active = 1;
      /* Emit for ~10 ms so the pulse survives D/A → cable → A/D. */
      e->lat_emit_remaining = sr / LE_LATENCY_PULSE_DIV;
      e->lat_buf_pos = 0; /* start a fresh capture window */
      store_i32(&e->a_latency_state, LE_LATENCY_MEASURING);
      /* A loopback measurement requires a physical out->in cable, which forms a
       * feedback loop with input monitoring (out -> cable -> in -> monitor ->
       * out). No explicit monitor suppression is needed — and we must NOT touch
       * m->a_enabled here: while measuring, the pulse path takes over the output
       * and `continue`s each frame (see le_engine_process), bypassing
       * mix_monitors_frame entirely, so no monitored input ever reaches the
       * output during the pulse. Snapshotting + zeroing a_enabled here (and
       * restoring it at completion) used to revert a saved-monitor enable that
       * the launch restore applies asynchronously mid-measurement, leaving that
       * input silent until a manual toggle. lat_active alone is the gate. */
      break;
    }
    case LE_CMD_RECORD:
      if (cmd->clock.cancel_count_in &&
          !e->launch_action[cmd->arg_i] && !e->launch_grace[cmd->arg_i]) {
        /* Its countdown was already canceled. The exact same press cannot
         * create a new countdown/capture under a newly applied pair. */
        if (cmd->clock.sequence != 0) atomic_store_explicit(
            &e->a_clock_commands_applied, cmd->clock.sequence, memory_order_release);
        break;
      }
      if (!preserve_image && valid_channel(e, cmd->arg_i))
        e->tracks[cmd->arg_i].pending_image.revision = 0;
      le_plog_push(e, frame, *cmd);
      if (valid_channel(e, cmd->arg_i)) {
        e->tracks[cmd->arg_i].pending_record = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
      handle_record(e, cmd->arg_i, frame);
      if (cmd->clock.sequence != 0) {
        atomic_store_explicit(&e->a_clock_commands_applied, cmd->clock.sequence,
                              memory_order_release);
      }
      break;
    case LE_CMD_CANCEL_COUNT_IN:
      le_cancel_count_in(e, frame);
      break;
    case LE_CMD_STOP_RECORD_CONTROL: {
      if (!valid_channel(e, cmd->arg_i)) break;
      if (le_cancel_count_in(e, frame)) break;
      le_track* t = &e->tracks[cmd->arg_i];
      const int state = load_i32(&t->a_state);
      if (state != LE_TRACK_RECORDING && state != LE_TRACK_OVERDUBBING) break;
      /* Reuse the existing grid-end rounding/arming body, not a new scheduler.
       * Refused/stale end intents cannot turn a completed capture into a start. */
      le_command finish = {.code = LE_CMD_RECORD, .arg_i = cmd->arg_i};
      if (cmd->arg_f == 1.0f) finish.code = LE_CMD_ARM;
      else if (cmd->arg_f == 2.0f) finish.code = LE_CMD_DISARM;
      else if (cmd->arg_f != 0.0f) break;
      apply_command(e, &finish, frame);
      break;
    }
    case LE_CMD_FINALIZE_TAKE:
      /* Not logged verbatim (the ARM/DISARM rationale in the audited-subset
       * note above): the transport fact it causes — RECORD_END, or
       * RECORD_ABORT for a cancelled count-in — is logged where it lands.
       * Deliberately does NOT touch pending_record/a_pending: this command
       * can never consume anyone's arm (the control side refuses while one
       * is live). */
      handle_finalize_take(e, cmd->arg_i, frame);
      break;
    case LE_CMD_ARM:
      if (!preserve_image && valid_channel(e, cmd->arg_i))
        e->tracks[cmd->arg_i].pending_image.revision = 0;
      if (valid_channel(e, cmd->arg_i)) {
        le_track* t = &e->tracks[cmd->arg_i];
        /* arg_f carries the trigger: 0 = grid (quantize), 1 = input level
         * (sound-activated auto-record), 2 = Band section transport (B3b) —
         * see LE_CMD_ARM's doc, segno_engine_api.h. Only 0/1/2 are ever
         * pushed (le_engine_record / le_engine_toggle_section); the >= 1.5
         * split keeps 1.0f mapping to 1 exactly, unchanged from before B3b. */
        const int trig = cmd->arg_f >= 1.5f ? 2 : (cmd->arg_f != 0.0f ? 1 : 0);
        int64_t sn, sd;
        if (trig == 0 && load_i32(&t->a_state) == LE_TRACK_RECORDING &&
            e->clock.length > 0 &&
            le_live_subdiv_ratio(e, cmd->arg_i, &sn, &sd)) {
          /* Quantized record END (D8): the capture must end on the NEAREST
           * loop-locked subdivision boundary. Strictly nearer behind ->
           * truncate right now (drop the tail past that boundary and finalize);
           * nearer ahead — or the exact midpoint, which rounds up — -> keep
           * capturing and let the per-frame boundary check fire the finalize.
           * A truncation must leave at least one whole subdivision unit of
           * capture (min 1 unit); anything shorter rounds up instead. Only the
           * non-defining path: the defining master (clock.length == 0 while it
           * records) never arms its end — its finalize keeps the seam-crossfade
           * machinery and A1's whole-bar rounding.
           *
           * DESIGN DECISION (code review, A3 follow-up) — min-1-unit's scope
           * under a live granularity change: this check runs ONCE, here, at
           * the press — using whichever division is live AT THE PRESS. When
           * it fails (round-down would leave < 1 unit) the arm falls through
           * to the plain pending_record wait below, which is STATELESS: no
           * target boundary or armed division is latched anywhere, so the
           * eventual fire re-reads le_live_subdiv_ratio's CURRENT value (via
           * advance_transport_frame's boundary check) at the moment it
           * actually fires — the same "live division, no latching" rule as
           * every other pending re-evaluation in A3 (the record-START and
           * granularity-change-while-armed tests rely on exactly this). A
           * granularity change during the wait (e.g. QUARTER -> SIXTEENTH)
           * is therefore honored immediately, on the SIXTEENTH's own next
           * boundary — which can be a shorter span, in SIXTEENTH units, than
           * the QUARTER unit the original press's min-1-unit check reasoned
           * about. This is chosen deliberately (option (a) of two): "min 1
           * unit" means "at least one unit of whichever division is live
           * when the boundary fires", not a length invariant carried from
           * the press — latching the press-time target length (option (b))
           * would need new per-track state (the target unit length, or an
           * armed-division snapshot) purely to serve a rare
           * disarm-mid-granularity-change edge case, contradicting A3's
           * minimal-ABI-growth, no-latched-arm-state design throughout.
           * Pinned by test_quantize_div_min_one_unit_reevaluates_on_
           * granularity_change. */
          const int32_t len = e->clock.length;
          const int32_t pos = e->clock.position;
          const int32_t idx = le_grid_loop_subdiv_at(pos, len, sn, sd);
          const int32_t pb = le_grid_loop_subdiv_start(idx, len, sn, sd);
          const int32_t nb = le_grid_loop_next_subdiv(pos, len, sn, sd);
          const int32_t behind = pos - pb;
          const int32_t ahead = nb > pos ? nb - pos : 0;
          /* record_pos is phase-locked to the master, so the boundary behind
           * sits exactly `behind` frames back on the capture timeline. The
           * span check is the rational min-1-unit test:
           * span >= len/subdivs  <=>  span * sub_num >= len * sub_den. */
          const int64_t span =
              (int64_t)(t->record_pos - behind) - (int64_t)t->record_start;
          if (behind >= 0 && behind < ahead &&
              span * sn >= (int64_t)len * sd) {
            le_truncate_capture_tail(e, t, behind);
            /* The truncated boundary is `behind` frames EARLIER than `frame`
             * (this ARM command's buffer-start perf-log tag): `frame` and
             * `pos` are read at the same instant (perf_frame_base is
             * snapshotted before the ring drains, clock.position is
             * unchanged since the previous buffer — see le_engine_process),
             * so the boundary's own perf-log frame is frame - behind, not
             * frame itself. Passing the raw (too-late) `frame` here would
             * inflate finalize_new_track's LE_PLOG_RECORD_END tag by `behind`
             * frames, and perf_render.c's le_pr_record_end_phase folds that
             * tag straight into (end_frame - start_frame) — an export render
             * of a round-down-truncated take would start its finalized
             * segment `behind` frames late, at the wrong loop phase. Live
             * playback is unaffected (it reads clock.position directly, not
             * this log tag) — export-render only. `frame` only grows while
             * perf recording is armed (0 otherwise) and `behind` is bounded
             * to under one subdivision unit, so underflow should not occur,
             * but the subtraction is clamped defensively rather than trusted
             * to never see it. */
            const uint64_t end_frame =
                frame > (uint64_t)behind ? frame - (uint64_t)behind : 0;
            handle_record(e, cmd->arg_i, end_frame); /* finalize at the boundary */
            break;
          }
        }
        t->pending_record = 1;
        t->pending_trigger = trig;
        /* Trigger first, then the flag with release: the snapshot reads the
         * flag with acquire and only then the trigger, so it never pairs a
         * fresh arm with the previous arm's trigger. */
        store_i32(&t->a_pending_trigger, trig);
        atomic_store_explicit(&t->a_pending, 1, memory_order_release);
      }
      break;
    case LE_CMD_DISARM:
      if (valid_channel(e, cmd->arg_i)) {
        if (e->launch_action[cmd->arg_i] == 1)
          le_plog_push(e, frame, (le_command){.code = LE_PLOG_RECORD_ABORT,
                                             .arg_i = cmd->arg_i});
        le_launch_remove(e, cmd->arg_i);
        if (e->launch_grace[cmd->arg_i]) handle_record(e, cmd->arg_i, frame);
        e->tracks[cmd->arg_i].pending_image.revision = 0;
        e->tracks[cmd->arg_i].pending_capture_shadow = 0;
        e->tracks[cmd->arg_i].pending_record = 0;
        e->tracks[cmd->arg_i].pending_trigger = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
      break;
    case LE_CMD_STOP:
      le_plog_push(e, frame, *cmd);
      handle_stop(e, cmd->arg_i, frame);
      break;
    case LE_CMD_PLAY:
      le_plog_push(e, frame, *cmd);
      handle_play(e, cmd->arg_i, frame);
      break;
    case LE_CMD_CLEAR:
      le_plog_push(e, frame, *cmd);
      /* arg_f = 1: a user clear on a capturing track freezes the take first
       * (le_clear_track); internal clears and session load pass 0. */
      handle_clear(e, cmd->arg_i, cmd->arg_f != 0.0f, frame);
      break;
    case LE_CMD_CANCEL_TAKE: {
      /* le_engine_undo while RECORDING (accepted design, slice 2): finalize
       * the take exactly as a press would — grid, tempo derivation and loop
       * span included — then empty the track around that content so redo
       * plays it immediately. Not logged verbatim: RECORD_END and UNDO land
       * where they happen. */
      const int32_t ch = cmd->arg_i;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      if (load_i32(&t->a_state) != LE_TRACK_RECORDING) {
        /* A count-in still running, or a take that already ended: nothing to
         * cancel, but the control thread's state command wants its ack and
         * its report (a 0 length: nothing to redo, the flag clears). */
        if (e->launch_action[ch] != 0) {
          le_launch_remove(e, ch);
        }
        const le_command none = {.code = LE_EVT_TAKE_CANCELLED,
                                 .lanei = {ch, 0, 0}};
        (void)le_ring_push(&e->evt_ring, none);
        atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
        break;
      }
      if (t->xfade_capture > 0) {
        t->record_pos = t->xfade_len; /* the intended length, no fade */
        t->xfade_capture = 0;
      }
      int32_t len = 0;
      if (t->record_pos <= 0) {
        /* Nothing captured: the take never established anything, so the
         * track simply reads empty again. Not handle_clear: that bumps the
         * audio thread's layer generation, which only a control-side clear
         * matches, and a mismatch drops every later retired layer. */
        if (e->clock.length == 0) {
          apply_undo_to_empty(e, ch, frame);
        } else {
          finalize_new_track(e, t, LE_TRACK_PLAYING, frame); /* void: EMPTY */
        }
      } else {
        if (e->clock.length == 0) {
          finalize_master(e, t, LE_TRACK_PLAYING, frame);
        } else {
          finalize_new_track(e, t, LE_TRACK_PLAYING, frame);
          t->seam_capture = 0; /* nothing to fold into a held take */
        }
        len = load_i32(&t->lanes[0].a_len);
        apply_undo_to_empty(e, ch, frame);
      }
      const le_command evt = {.code = LE_EVT_TAKE_CANCELLED,
                              .lanei = {ch, 0, len}};
      (void)le_ring_push(&e->evt_ring, evt); /* a full ring: no redo */
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_DUB_SHADOW: {
      /* A shadow slot for per-pass layer capture (buffers already allocated by
       * the control thread; visible via the ring's release/acquire). Arm it
       * directly when no pass is mid-flight; otherwise park it as the spare a
       * boundary rotation will pick up — arming mid-pass would tear coverage. */
      const int32_t ch = cmd->lanei.channel;
      const int32_t slot = cmd->lanei.value;
      if (!valid_channel(e, ch) || slot < 0 || slot >= LE_POOL_SLOTS) break;
      le_track* t = &e->tracks[ch];
      if (load_i32(&t->a_state) == LE_TRACK_EMPTY &&
          t->pending_image.revision != 0 &&
          (t->pending_record ||
           (e->launch_action[ch] != 0))) {
        t->pending_capture_shadow = slot + 1;
        break;
      }
      const int mid_pass =
          (load_i32(&t->a_state) == LE_TRACK_OVERDUBBING ||
           t->od_gain > 0.0f) &&
          t->dub_phase > 0;
      if (t->dub_slot < 0 && !mid_pass && !t->dub_draining) {
        t->dub_slot = slot;
        t->dub_count = -1;
      } else if (t->dub_spare < 0) {
        t->dub_spare = slot;
      }
      break;
    }
    case LE_CMD_UNDO_TO_EMPTY: {
      /* Undo past the base layer: the track reads as content-less (the control
       * thread keeps its live slot on the redo stack for resurrection) while
       * the master grid deliberately survives — redo needs it; a full reset
       * stays Clear's job (handle_clear's all-empty check). */
      if (!valid_channel(e, cmd->arg_i)) break;
      le_track* t = &e->tracks[cmd->arg_i];
      apply_undo_to_empty(e, cmd->arg_i, frame);
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_REDO_FROM_EMPTY: {
      /* Reinstate an undone-to-empty track: the control thread already swapped
       * a_live back to the base content; restore length/multiple/state here.
       * start_iter = 0 keeps the COMMIT_SESSION segment convention. */
      const int32_t ch = cmd->lanei.channel;
      const int32_t len = cmd->lanei.value;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      if (load_i32(&t->a_state) == LE_TRACK_EMPTY && len > 0) {
        const int was_held = le_transport_held(e);
        /* The restored loop may differ in length from whatever the leftover
         * armed shadows were sized for — drop them (control reclaimed). */
        le_dub_drop_armed(t);
        le_restore_track_clock(e, t, len, 0, frame);
        le_track_set_len(t, len);
        t->start_iter = 0;
        store_i32(&t->a_state, LE_TRACK_PLAYING);
        le_primary_reconcile(e); /* a redone first take is a first take */
        /* The from-EMPTY edge case of redo (LE_PLOG_REDO — see the UNDO_TO_
         * EMPTY case above for why every redo path logs the same code). */
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_REDO, .arg_i = ch});
        /* A resurrect that starts playback from a held transport unparks the
         * whole loop, like any other start. */
        if (was_held) le_unpark_stopped(e, frame);
      }
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_RESTORE_CLEAR: {
      /* Undo of an undoable clear: the control thread already swapped a_live
       * back to the erased take and pushed the mute restore ahead of us; put the
       * transport back here. Distinct from REDO_FROM_EMPTY on two counts — the
       * state may be STOPPED rather than PLAYING, and the grid may need
       * re-establishing rather than merely reading. */
      const int32_t ch = cmd->restore.channel;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      const int32_t len = cmd->restore.len;
      if (load_i32(&t->a_state) == LE_TRACK_EMPTY && len > 0) {
        /* The restored loop may differ in length from whatever the leftover
         * armed shadows were sized for — drop them (control reclaimed). */
        le_dub_drop_armed(t);
        le_restore_track_clock(e, t, len, cmd->restore.master_len, frame);
        le_track_set_len(t, len);
        t->start_iter = 0;
        t->fade = (le_fade){cmd->restore.fade_amount, cmd->restore.fade_amount, 0};
        t->fade_sample = cmd->restore.fade_amount;
        /* Capture provenance needs nothing here (#1143): the restored slot's
         * staged image is in perf.slot_image, and mix_tracks_frame logs it at
         * the first frame it mixes the slot PLAYING or STOPPED. */
        if (t->fade_generation != UINT64_MAX) t->fade_generation++;
        le_fade_log(e, ch, frame);
        store_i32(&t->a_state, cmd->restore.state);
        le_primary_reconcile(e); /* a restored only take is crowned again */
        /* The clear-restore edge case of undo: same semantic code as every
         * other undo path (see LE_CMD_UNDO_TO_EMPTY), so a downstream consumer
         * never needs to know which internal path fired. */
        le_plog_push(e, frame, (le_command){.code = LE_PLOG_UNDO, .arg_i = ch});
      }
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    /* Undo/redo swaps are handled on the control thread (le_engine_undo/redo),
     * not via the command ring; only the state flips above ride it. */
    case LE_CMD_SET_VOLUME: {
      if (!valid_channel(e, cmd->arg_i)) break;
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      store_f32(&e->tracks[cmd->arg_i].a_gain_bits, v);
      le_plog_push(e, frame, (le_command){.code = LE_CMD_SET_VOLUME,
          .arg_i = cmd->arg_i,
          .arg_f = v});
      break;
    }
    case LE_CMD_SET_MUTE:
      if (valid_channel(e, cmd->arg_i)) {
        /* Track-addressed mute maps to lane 0 (backward compatibility),
         * capture-aware like the per-lane command below. */
        le_apply_mute_cmd(e, cmd->arg_i, 0, cmd->arg_f != 0.0f, cmd, frame);
      }
      break;
    /* ---- tempo grid (see the helper block above finalize_master). Not
     * perf-logged: in this part none of these changes audible output. */
    case LE_CMD_RESTORE_TEMPO: {
      if (!le_restored_tempo_valid(cmd->arg_f, cmd->arg_i) ||
          le_transport_edit_blocked(e)) break;
      store_f32(&e->a_tempo_bpm_bits, cmd->arg_f);
      store_i32(&e->a_tempo_source, cmd->arg_i);
      e->has_tap = 0;
      e->last_tap_frame = 0;
      if (cmd->arg_i == LE_TEMPO_SOURCE_NONE) {
        le_restore_musical_grid(e, 0);
      } else {
        regrid_surviving_master(e);
      }
      break;
    }
    case LE_CMD_SET_TEMPO: {
      if (le_tempo_locked(e)) break; /* D6: rejected (no-op) while locked */
      float bpm = cmd->arg_f;
      /* NaN-rejecting clamp: !(x >= MIN) is true for NaN as well as for low
       * values, so a non-finite bpm can never reach the grid math (a NaN
       * interval would spin le_grid_next_boundary forever). */
      if (!(bpm >= LE_GRID_TEMPO_MIN)) {
        bpm = LE_GRID_TEMPO_MIN;
      } else if (bpm > LE_GRID_TEMPO_MAX) {
        bpm = LE_GRID_TEMPO_MAX;
      }
      store_f32(&e->a_tempo_bpm_bits, bpm);
      store_i32(&e->a_tempo_source, LE_TEMPO_SOURCE_MANUAL);
      regrid_surviving_master(e);
      break;
    }
    case LE_CMD_SET_TIME_SIGNATURE: {
      if (le_tempo_locked(e)) break; /* D6: rejected (no-op) while locked */
      const int32_t num = cmd->arg_i;
      const int32_t den = (int32_t)cmd->arg_f;
      /* Re-validated here (the exported wrapper already rejects) so a raw
       * le_engine_post_command can never publish an unsupported signature. */
      if (!le_grid_signature_valid(num, den)) break;
      store_i32(&e->a_ts_num, num);
      store_i32(&e->a_ts_den, den);
      /* Unlocked with a surviving grid (the undo-to-empty edge): recompute
       * bars AND beats against the surviving master — a new signature changes
       * the bar length, so keeping the old bar count would be as stale as
       * counting the old numerator. */
      regrid_surviving_master(e);
      break;
    }
    case LE_CMD_TAP_TEMPO:
      if (!le_tempo_locked(e)) handle_tap(e); /* D6: taps ignored wholesale */
      break;
    case LE_CMD_SET_SYNC_TEMPO:
      /* A settings toggle, deliberately not locked: it only governs FUTURE
       * defining-loop finalizes (sync_grid_to_loop), never a live grid. */
      store_i32(&e->a_sync_tempo, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    case LE_CMD_RESET_TRANSFORMS:
      if (valid_channel(e, cmd->arg_i)) le_transform_reset(e, &e->tracks[cmd->arg_i], frame);
      break;
    case LE_CMD_FADE: {
      le_track* t = &e->tracks[cmd->fade.channel];
      const le_fade_image* image = &cmd->fade.image;
      const int accepted = image->lifetime == e->fade_lifetime &&
          image->generation == t->fade_generation &&
          t->fade_generation != UINT64_MAX &&
          load_i32(&t->lanes[0].a_len) > 0 &&
          (cmd->fade.install || load_i32(&t->a_state) != LE_TRACK_EMPTY);
      if (accepted) {
        if (cmd->fade.install) {
          t->fade.amount = image->amount;
          t->fade.target = image->target;
        } else {
          t->fade.target = t->fade.target == 0 ? 1 : 0;
        }
        t->fade.seconds = image->full_travel_seconds;
        t->fade.frames = 0;
        le_fade_log(e, cmd->fade.channel, frame);
      }
      atomic_store_explicit(&e->receipts[cmd->fade.slot].result,
                             accepted ? LE_OK : LE_ERR_INVALID, memory_order_relaxed);
      break;
    }
    case LE_CMD_REVERSE: {
      /* Reverse (#1162): flip (or install) the read direction at the current
       * position. Accepted only on material that can be read backward
       * safely: a length, no punch tail still writing (od_gain, see the
       * overdub write in mix_tracks_frame), no deferred master finalize, and
       * a state that is not writing — install additionally accepts the
       * imported EMPTY track of a Session recall, before its commit. A seam
       * capture window is fine: the trailing fold writes at seam_w,
       * independent of the read pair. */
      le_track* t = &e->tracks[cmd->reverse.channel];
      const int32_t st = load_i32(&t->a_state);
      int32_t len;
      const int64_t base = le_track_base_position(e, t, &len);
      const int writing = st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING;
      const int accepted = len > 0 && t->od_gain == 0.0f &&
          t->xfade_capture == 0 && !writing &&
          (cmd->reverse.install || st == LE_TRACK_PLAYING ||
           st == LE_TRACK_STOPPED);
      if (accepted) {
        const int target = cmd->reverse.install ? cmd->reverse.target != 0
                                                : !t->reversed;
        int32_t cur = le_direction_index(t->reversed, t->playback_offset,
                                         base, len);
        int32_t turn = 0;
        const int turned = target != t->reversed;
        if (turned && t->turn_left > 0 && target == t->turn_reversed) {
          /* Back to the pre-turn direction inside the turn window: cancel
           * the turn. The old head has kept reading all along, so it takes
           * over alone and the net-zero gesture plays the material it would
           * have played without either toggle. */
          t->reversed = target;
          t->playback_offset = t->turn_offset;
          t->turn_left = 0;
          cur = le_direction_index(target, t->playback_offset, base, len);
        } else if (turned) {
          /* The old head keeps reading for one turn window while the new one
           * takes over — the value is continuous at the turn (same sample)
           * but its slope flips, which clicks on low material. Equal-gain,
           * the seam length (~10 ms); a loop too short to host it snaps,
           * like the punch fade. Nothing sounds on a STOPPED track, so there
           * is no old head to mix and a later Play starts clean. */
          const int32_t F = seam_xfade_frames(e);
          turn = st == LE_TRACK_PLAYING && len >= 2 * F ? F : 0;
          t->turn_reversed = t->reversed;
          t->turn_offset = t->playback_offset;
          t->turn_frames = turn;
          t->turn_left = turn;
          t->reversed = target;
          t->playback_offset = le_direction_origin(target, cur, base, len);
        }
        if (turned) {
          /* A printed Pre render never plays reversed: disengage every print
           * so the live chains take over through the settled-bypass
           * re-enable path [B7]; forward tracks re-engage at their next lap
           * start. */
          store_i32(&t->a_track_cache_active, 0);
          for (int l = 0; l < LE_MAX_LANES; ++l) {
            store_i32(&t->lanes[l].a_cache_active, 0);
          }
        }
        store_i32(&t->a_reversed, t->reversed);
        le_reverse_log(e, t, frame, cur, turn);
      }
      atomic_store_explicit(&e->receipts[cmd->reverse.slot].result,
                             accepted ? LE_OK : LE_ERR_INVALID,
                             memory_order_relaxed);
      /* Release after a_reversed: control's le_effective_reversed reads the
       * count first (acquire) and then trusts the published direction. */
      atomic_fetch_add_explicit(&t->a_reverse_applied, 1, memory_order_release);
      break;
    }
    case LE_CMD_SET_LENGTH: {
      /* A length edit or its Undo/Redo (#1168). Control admitted it against
       * its effective view; the rig may have moved since (a sibling started
       * capturing, a crown or mode landed, a fresh take's seam fold or a punch
       * tail still writes), so the verdict is recomputed here on the applied
       * rig and must match the payload. The verdict is published before the
       * state ack, which the control drain waits for before filing history. */
      const int32_t ch = cmd->length.channel;
      if (!valid_channel(e, ch)) break;
      le_track* t = &e->tracks[ch];
      const int32_t st = load_i32(&t->a_state);
      int32_t verdict = LE_ERR_NOT_READY;
      le_length_fit fit;
      if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) &&
          load_i32(&t->lanes[0].a_len) > 0 && t->od_gain == 0.0f &&
          t->seam_capture == 0 && t->xfade_capture == 0 &&
          !load_i32(&t->a_layer_in_flight) &&
          atomic_load_explicit(&t->a_audio_rev, memory_order_relaxed) ==
              cmd->length.audio_rev) {
        int others = 0;
        for (int32_t c = 0; c < e->track_count; ++c) {
          if (c != ch && load_i32(&e->tracks[c].a_state) != LE_TRACK_EMPTY) {
            others = 1;
          }
        }
        verdict = le_length_fit_check(load_i32(&e->a_looper_mode),
                                      e->clock.length,
                                      load_i32(&e->a_loop_bars), others,
                                      load_i32(&e->a_primary_track) == ch,
                                      cmd->length.len, e->max_loop_frames,
                                      &fit);
        if (verdict == LE_OK && (fit.multiple != cmd->length.multiple ||
                                 fit.divisor != cmd->length.divisor ||
                                 fit.reclock != cmd->length.reclock)) {
          verdict = LE_ERR_NOT_READY;
        }
      }
      if (verdict == LE_OK) le_length_apply(e, t, cmd, &fit, frame);
      store_i32(&t->a_length_result, verdict);
      if (cmd->length.receipt >= 0) {
        atomic_store_explicit(&e->receipts[cmd->length.receipt].result,
                              verdict, memory_order_relaxed);
      }
      atomic_fetch_add_explicit(&t->a_state_acks, 1, memory_order_release);
      break;
    }
    case LE_CMD_SET_RECORD_TIMING: {
      const le_record_timing_settings* v = &cmd->timing.settings;
      int accepted = le_record_timing_valid(v);
      for (int c = 0; c < e->track_count && accepted; ++c) {
        const int state = load_i32(&e->tracks[c].a_state);
        if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) accepted = 0;
      }
      atomic_store_explicit(&e->a_record_timing_revision, cmd->timing.revision - 1u, memory_order_seq_cst);
#ifdef LE_NATIVE_TESTS
      if (le_test_record_timing_hook) le_test_record_timing_hook(e, 1);
#endif
      if (accepted) {
        atomic_store_explicit(&e->a_record_timing_default, v->default_timing, memory_order_seq_cst);
        atomic_store_explicit(&e->a_quantize_div, v->remembered_division, memory_order_seq_cst);
#ifdef LE_NATIVE_TESTS
        if (le_test_record_timing_hook) le_test_record_timing_hook(e, 2);
#endif
        for (int c = 0; c < LE_MAX_TRACKS; ++c) {
          const int code = v->track_timing[c];
          atomic_store_explicit(&e->a_record_timing_track[c], code, memory_order_seq_cst);
          atomic_store_explicit(&e->tracks[c].a_quantize_div_override,
                                code < 0 ? -1 : code > 0 ? code - 1 : 0,
                                memory_order_seq_cst);
          const int affected = (v->edit_mask & (2u << c)) ||
              ((v->edit_mask & 1u) && code < 0);
          const int effective = code < 0 ? v->default_timing : code;
          le_track* t = &e->tracks[c];
          if (affected && effective == 0 && t->pending_record && t->pending_trigger == 0) {
            t->pending_image.revision = 0;
            t->pending_capture_shadow = 0;
            t->pending_record = 0;
            t->pending_trigger = 0;
            store_i32(&t->a_pending, 0);
          }
        }
      }
      atomic_store_explicit(&e->a_record_timing_result, accepted ? LE_OK : LE_ERR_INVALID, memory_order_seq_cst);
      e->record_timing_publish_revision = cmd->timing.revision;
      e->record_timing_publish_pending = 1;
      break;
    }

    /* ---- looper mode (B2a, D4; see le_looper_mode_switch_blocked above).
     * Mode selection is not performance logged. */
    case LE_CMD_SET_LOOPER_MODE: {
      const int32_t m = cmd->presets.mode;
      const int32_t count = cmd->presets.count;
      const int changing = m != load_i32(&e->a_looper_mode);
      /* Validate EVERYTHING against preceding commands before the first
       * stop or setting write. A refused edit cannot strand stopped tracks. */
      if (m >= LE_LOOPER_MODE_MULTI && m <= LE_LOOPER_MODE_FREE &&
          (count == 0 ||
           le_length_presets_check(e, cmd->presets.bars, count) == LE_OK) &&
          (!changing || !le_looper_mode_switch_blocked(e, m))) {
        if (changing) {
          for (int32_t c = 0; c < e->track_count; ++c) {
            if (load_i32(&e->tracks[c].a_state) != LE_TRACK_PLAYING ||
                load_i32(&e->tracks[c].lanes[0].a_len) <= 0) continue;
            le_plog_push(e, frame,
                         (le_command){.code = LE_CMD_STOP, .arg_i = c});
            handle_stop(e, c, frame);
          }
          le_apply_mode_switch(e, m);
        }
        for (int32_t c = 0; c < count; ++c) {
          store_i32(&e->tracks[c].a_length_preset_bars, cmd->presets.bars[c]);
        }
      }
      if (cmd->presets.sequence != 0) {
        atomic_store_explicit(&e->a_clock_commands_applied, cmd->presets.sequence,
                              memory_order_release);
      }
      break;
    }
    /* ---- primary track (B3, D18; see LE_CMD_CROWN_PRIMARY's doc,
     * segno_engine_api.h). Accepted in ANY mode — the crown is a persistent
     * per-session designation, not gated by a pending mode switch or by mode
     * itself; it simply has no effect outside Sync/Band
     * (le_sync_quantize_active). Not perf-logged, for the same reason as
     * LE_CMD_SET_LOOPER_MODE above. */
    case LE_CMD_CROWN_PRIMARY: {
      if (valid_channel(e, cmd->arg_i)) store_i32(&e->a_primary_track, cmd->arg_i);
      if (cmd->clock.sequence != 0) {
        atomic_store_explicit(&e->a_clock_commands_applied, cmd->clock.sequence,
                              memory_order_release);
      }
      break;
    }
    /* Once is a setting in every mode. A change during existing playback
     * finishes that pass; it does not demand a fresh full playback lap. */
    case LE_CMD_SET_ONE_SHOT: {
      if (!valid_channel(e, cmd->arg_i)) break;
      le_apply_one_shot(&e->tracks[cmd->arg_i], cmd->arg_f != 0.0f);
      break;
    }
    case LE_CMD_SET_ONE_SHOT_MASK: {
      const uint32_t channels = (uint32_t)cmd->arg_i;
      const uint32_t valid = (1u << e->track_count) - 1u;
      if (channels == 0 || (channels & ~valid) != 0) break;
      for (int32_t c = 0; c < e->track_count; ++c) {
        if (channels & (1u << c)) {
          le_apply_one_shot(&e->tracks[c], cmd->arg_f != 0.0f);
        }
      }
      break;
    }
    /* ---- MIDI clock (Phase C/E, D15; see LE_CMD_SET_CLOCK_MODE's doc,
     * segno_engine_api.h). Not perf-logged, for the same reason as
     * LE_CMD_SET_LOOPER_MODE above. */
    case LE_CMD_SET_CLOCK_MODE: {
      const int32_t m = cmd->arg_i;
      /* Re-validated here (the exported wrapper already rejects RECEIVE and
       * anything else) so a raw le_engine_post_command can never publish an
       * unimplemented/out-of-range clock mode. */
      if (m != LE_CLOCK_OFF && m != LE_CLOCK_SEND) break;
      store_i32(&e->a_clock_mode, m);
      break;
    }
    /* ---- click + count-in (A2; see the helper block above finalize_master).
     * Not perf-logged: the click never reaches the performance capture (it
     * sums after the perf tap by design), so its configuration is invisible
     * to a replay of the captured performance. Click mode has an explicit
     * callback receipt; output and gain retain their existing validation. */
    case LE_CMD_SET_CLICK_MODE: {
      const int32_t m = cmd->click.mode;
      int accepted = m >= LE_CLICK_OFF && m <= LE_CLICK_PLAY_REC;
      for (int c = 0; c < e->track_count && accepted; ++c) {
        const int state = load_i32(&e->tracks[c].a_state);
        if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) accepted = 0;
      }
      if (accepted) store_i32(&e->a_click_mode, m);
      store_i32(&e->a_click_mode_result, accepted ? LE_OK : LE_ERR_INVALID);
      e->click_mode_publish_revision = cmd->click.revision;
      e->click_mode_publish_pending = 1;
#ifdef LE_NATIVE_TESTS
      if (le_test_click_mode_hook) le_test_click_mode_hook(e, 1);
#endif
      break;
    }
    case LE_CMD_SET_CLICK_OUTPUT:
      atomic_store_explicit(&e->a_click_mask, cmd->trackmask.mask,
                            memory_order_relaxed);
      break;
    case LE_CMD_SET_CLICK_VOLUME: {
      float v = cmd->arg_f;
      /* NaN-rejecting clamp (same rationale as LE_CMD_SET_TEMPO's). */
      if (!(v >= 0.0f)) {
        v = 0.0f;
      } else if (v > LE_MAX_GAIN) {
        v = LE_MAX_GAIN;
      }
      store_f32(&e->a_click_volume_bits, v);
      break;
    }
    case LE_CMD_SET_RECORD_START: {
      const int value = cmd->record_start.value;
      const int kind = cmd->record_start.edit_kind;
      int accepted = (value == -1 || value == 0 || value == 1 || value == 2 || value == 4) &&
          kind >= LE_RECORD_START_COUNT_IN && kind <= LE_RECORD_START_RESTORE;
      for (int c = 0; c < e->track_count && accepted; ++c) {
        const int state = load_i32(&e->tracks[c].a_state);
        if (state == LE_TRACK_RECORDING || state == LE_TRACK_OVERDUBBING) accepted = 0;
      }
      if (accepted) {
        store_i32(&e->a_record_start, value);
        if (kind == LE_RECORD_START_RESTORE ||
            (kind == LE_RECORD_START_COUNT_IN && value > 0) ||
            (kind == LE_RECORD_START_SOUND && value >= 0)) le_cancel_signal_arms(e);
        if (e->count_in_total > 0 && (kind != LE_RECORD_START_SOUND || value < 0))
          le_count_in_reset(e);
      }
      store_i32(&e->a_record_start_result, accepted ? LE_OK : LE_ERR_INVALID);
      e->record_start_publish_revision = cmd->record_start.revision;
      e->record_start_publish_pending = 1;
#ifdef LE_NATIVE_TESTS
      if (le_test_record_start_hook) le_test_record_start_hook(e, 1);
#endif
      break;
    }
    /* ---- track length presets (A6, D17; see the helper block above
     * finalize_master). Not perf-logged, like the tempo grid / click block
     * above — state only, no direct audible effect at the moment it's set. */
    case LE_CMD_SET_LENGTH_PRESETS:
      if (le_length_presets_check(e, cmd->presets.bars,
                                  cmd->presets.count) == LE_OK) {
        for (int32_t c = 0; c < cmd->presets.count; ++c) {
          store_i32(&e->tracks[c].a_length_preset_bars, cmd->presets.bars[c]);
        }
      }
      break;
    case LE_CMD_SET_LENGTH_PRESET: {
      if (!valid_channel(e, cmd->arg_i)) break;
      int32_t bars = (int32_t)cmd->arg_f;
      if (bars < 0) bars = 0;
      if (bars > LE_LENGTH_PRESET_MAX_BARS) bars = LE_LENGTH_PRESET_MAX_BARS;
      store_i32(&e->tracks[cmd->arg_i].a_length_preset_bars, bars);
      break;
    }
    case LE_CMD_SET_TUNER_INPUT: {
      /* Out-of-range disarms rather than clamping: clamping would silently
       * tune a channel the caller did not ask for. */
      int32_t in = cmd->arg_i;
      if (in < 0 || in >= e->in_channels) in = -1;
      store_i32(&e->a_tuner_input, in);
      /* Reset the analysis state on every change, including a disarm: a
       * window half-full of the previous input would otherwise produce one
       * bogus reading on the new one. */
      e->tuner_fill = 0;
      e->tuner_acc = 0.0f;
      e->tuner_acc_n = 0;
      e->tuner_raw_fill = 0;
      e->tuner_raw_pos = 0;
      /* An in-flight sliced detection is abandoned for the same reason: it is
       * mid-way through a window of the PREVIOUS input. */
      e->tuner_pass.phase = LE_TUNER_PHASE_IDLE;
      store_f32(&e->a_tuner_hz_bits, 0.0f);
      store_f32(&e->a_tuner_conf_bits, 0.0f);
      break;
    }
    case LE_CMD_SET_MASTER_GAIN: {
      le_plog_push(e, frame, *cmd);
      float g = cmd->arg_f;
      if (g < 0.0f) g = 0.0f;
      if (g > 1.0f) g = 1.0f;
      store_f32(&e->a_master_gain_bits, g);
      break;
    }
    case LE_CMD_SET_RECORD_OFFSET: {
      const int32_t frames = cmd->arg_i > 0 ? cmd->arg_i : 0;
      store_i32(&e->a_record_offset, frames);
      /* An explicitly set offset (a restored measurement, or a manual override)
       * is a known round-trip, so publish it as a completed measurement — the
       * UI then shows the loaded latency instead of "not measured". */
      if (frames > 0) {
        const int32_t osr = e->sample_rate > 0 ? e->sample_rate : 48000;
        atomic_store_explicit(
            &e->a_latency_ms_bits,
            f64_to_bits((double)frames * 1000.0 / (double)osr),
            memory_order_relaxed);
        store_i32(&e->a_latency_state, LE_LATENCY_DONE);
      }
      break;
    }
    /* Track + 32-bit mask, carried in the typed `trackmask` union arm. */
    case LE_CMD_SET_INPUT_MASK: {
      const int32_t ch = cmd->trackmask.channel;
      if (!valid_channel(e, ch)) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->in_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->in_channels) - 1u);
      /* A lane can never record from a loopback-excluded channel. The legacy
       * track input mask collapses to lane 0's single input channel: the lowest
       * valid, non-excluded bit (or -1 when none remain). */
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      const uint32_t m = cmd->trackmask.mask & valid & ~excluded;
      store_i32(&e->tracks[ch].lanes[0].a_input_channel, le_mask_to_channel(m));
      break;
    }
    case LE_CMD_SET_OUTPUT_MASK: {
      const int32_t ch = cmd->trackmask.channel;
      if (!valid_channel(e, ch)) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[0].a_output_mask,
                            cmd->trackmask.mask & valid, memory_order_relaxed);
      break;
    }
    /* FX type / count, addressed by (channel, lane) in the typed `fx` / `fxcount`
     * union arms. */
    case LE_CMD_SET_LANE_FX: {
      const int32_t ch = cmd->fx.channel;
      const int32_t lane = cmd->fx.lane;
      const int32_t index = cmd->fx.index;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES ||
          index < 0 || index >= LE_FX_MAX) {
        break;
      }
      le_plog_push(e, frame, *cmd);
      le_lane* ln = &e->tracks[ch].lanes[lane];
      store_i32(&ln->a_fx_type[index], cmd->fx.type);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      le_fx_entry_reset(&ln->fx, index);
      /* Wet-cache fast path: the published type just moved, so the chain
       * identity did too. The control setter already bumped, but a raw
       * le_engine_post_command bypasses it — this bump covers that hatch. */
      le_lane_fx_gen_bump(ln);
      break;
    }
    case LE_CMD_SET_LANE_FX_COUNT: {
      const int32_t ch = cmd->fxcount.channel;
      const int32_t lane = cmd->fxcount.lane;
      int32_t count = cmd->fxcount.count;
      int32_t pre = cmd->fxcount.pre_count;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      if (pre < 0) pre = 0;
      if (pre > count) pre = count;
      /* The two stores cannot be made atomic together, and NEITHER order is
       * safe for a reader in both directions — count-first lies while the
       * chain shrinks, pre-first lies while it grows. So every reader clamps
       * pre to the count it read alongside it instead (snapshot_lane_fx,
       * le_lane_pre_fx_fingerprint), and a torn pair costs at most one
       * buffer of live fallback. The raw le_engine_post_command hatch reaches
       * this handler too, so the clamps live here as well as in the setter. */
      le_lane* ln = &e->tracks[ch].lanes[lane];
      store_i32(&ln->a_fx_pre_count, pre);
      store_i32(&ln->a_fx_count, count);
      /* Wet-cache fast path: covers the raw-post hatch (see SET_LANE_FX). */
      le_lane_fx_gen_bump(ln);
      break;
    }
    /* ---- multi-lane routing commands ----
     * Each addresses its lane by (channel, lane): SET_LANE_INPUT/OUTPUT carry an
     * int payload (input channel / 32-bit mask) in the `lanei` arm;
     * SET_LANE_VOLUME/MUTE carry a float in the `lanef` arm. */
    case LE_CMD_SET_LANE_INPUT: {
      const int32_t ch = cmd->lanei.channel;
      const int32_t lane = cmd->lanei.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      int32_t in_ch = cmd->lanei.value;
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* Reject an out-of-range or loopback-excluded channel by recording
       * nothing, so a lane never captures our own output. */
      if (in_ch < 0 || in_ch >= e->in_channels ||
          (excluded & (1u << in_ch))) {
        in_ch = -1;
      }
      store_i32(&e->tracks[ch].lanes[lane].a_input_channel, in_ch);
      break;
    }
    case LE_CMD_SET_LANE_OUTPUT: {
      const int32_t ch = cmd->lanei.channel;
      const int32_t lane = cmd->lanei.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[lane].a_output_mask,
                            (uint32_t)cmd->lanei.value & valid,
                            memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_LANE_VOLUME: {
      const int32_t ch = cmd->lanef.channel;
      const int32_t lane = cmd->lanef.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      float v = cmd->lanef.value;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      e->tracks[ch].lanes[lane].live_level = v;
      le_publish_lane_mix(e, ch, lane, frame, 1, 0);
      break;
    }
    case LE_CMD_SET_LANE_MUTE: {
      const int32_t ch = cmd->lanef.channel;
      const int32_t lane = cmd->lanef.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      le_apply_mute_cmd(e, ch, lane, cmd->lanef.value != 0.0f, cmd, frame);
      break;
    }
    case LE_CMD_SET_LANE_PAN: {
      const int32_t ch = cmd->lanef.channel;
      const int32_t lane = cmd->lanef.lane;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      float v = cmd->lanef.value;
      if (!(v >= -1.0f)) v = v < -1.0f ? -1.0f : 0.0f; /* NaN -> centre */
      if (v > 1.0f) v = 1.0f;
      e->tracks[ch].lanes[lane].live_pan = v;
      le_publish_lane_mix(e, ch, lane, frame, 0, 1);
      break;
    }
    case LE_CMD_SET_TRACK_SOLO: {
      const int32_t ch = cmd->arg_i;
      if (!valid_channel(e, ch)) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->tracks[ch].a_solo, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    }
    /* ---- per-input live monitor ----
     * SET_MONITOR_INPUT carries the input index + enabled bit in the generic
     * { arg_i, arg_f } arm (input-level gate only). The per-lane monitor commands
     * mirror the track lane commands and reuse the same typed arms (fx / fxcount /
     * lanei / lanef); their `channel` field holds the input index. */
    case LE_CMD_SET_MONITOR_INPUT: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* A loopback-excluded input is never monitored (it carries our output). */
      const int on = (excluded & (1u << input)) ? 0 : (cmd->arg_f != 0.0f);
      store_i32(&e->monitors[input].a_enabled, on);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX: {
      const int32_t input = cmd->fx.channel; /* `channel` holds the input index */
      const int32_t index = cmd->fx.index;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS || index < 0 ||
          index >= LE_FX_MAX) {
        break;
      }
      le_plog_push(e, frame, *cmd);
      le_monitor_input* m = &e->monitors[input];
      store_i32(&m->a_fx_type[index], cmd->fx.type);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      le_fx_entry_reset(&m->fx, index);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX_COUNT: {
      const int32_t input = cmd->fxcount.channel;
      int32_t count = cmd->fxcount.count;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->monitors[input].a_fx_count, count);
      break;
    }
    /* ---- Per-input conditioning stage (input conditioning, S1) ----
     * This thread is the sole owner of the stage's biquad/envelope state, so
     * both commands recompute it here, in lockstep with the config change.
     * Loopback exclusion is deliberately NOT folded into the stored enable
     * (unlike SET_MONITOR_INPUT): the per-block conditioning pass masks
     * excluded channels out itself, so an input that stops being loopback
     * (device change) needs no re-push. Not perf-logged (upstream of capture:
     * recorded PCM already embodies the conditioning; nothing replays it). */
    case LE_CMD_SET_INPUT_COND: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_input_cond* c = &e->cond[input];
      const int on = cmd->arg_f != 0.0f ? 1 : 0;
      const int was = load_i32(&c->a_enabled);
      store_i32(&c->a_enabled, on);
      /* Enable EDGE: fresh coefficients + zeroed filter/envelope state, so a
       * re-engaged stage never rings with stale history. */
      if (on && !was) le_cond_prepare(c, e->sample_rate);
      break;
    }
    case LE_CMD_SET_INPUT_COND_PARAM: {
      const int32_t input = cmd->lanef.channel;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_cond_update_param(&e->cond[input], cmd->lanef.lane, cmd->lanef.value,
                           e->sample_rate);
      break;
    }
    /* ---- Track-stage + output bus chains ----
     * The bus twins of the lane/monitor FX cases above — same typed arms,
     * same lockstep DSP reset on a type change. Track chains remain
     * manifest-only; output chains log their edits for selected-destination
     * performance reconstruction. */
    case LE_CMD_SET_TRACK_FX: {
      const int32_t ch = cmd->fx.channel;
      const int32_t index = cmd->fx.index;
      if (!valid_channel(e, ch) || index < 0 || index >= LE_FX_MAX) break;
      le_fx_bus* b = &e->tracks[ch].bus;
      store_i32(&b->a_fx_type[index], cmd->fx.type);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      le_fx_entry_reset(&b->fx, index);
      break;
    }
    case LE_CMD_SET_TRACK_FX_COUNT: {
      const int32_t ch = cmd->fxcount.channel;
      int32_t count = cmd->fxcount.count;
      int32_t pre = cmd->fxcount.pre_count;
      if (!valid_channel(e, ch)) break;
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      if (pre < 0) pre = 0;
      if (pre > count) pre = count;
      /* Every reader clamps pre to the count it read alongside it — see the
       * lane handler for why neither store order is tear-safe. */
      store_i32(&e->tracks[ch].bus.a_fx_pre_count, pre);
      store_i32(&e->tracks[ch].bus.a_fx_count, count);
      break;
    }
    case LE_CMD_SET_ALL_TRACKS_FX: {
      const int32_t index = cmd->fx.index;
      if (index < 0 || index >= LE_FX_MAX) break;
      store_i32(&e->all_tracks.a_fx_type[index], cmd->fx.type);
      /* One config, one instance per bus: every instance's DSP state resets,
       * or a destination would keep the previous effect's filter memory. */
      for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
        le_fx_entry_reset(&e->all_tracks_fx[k], index);
      }
      break;
    }
    case LE_CMD_SET_ALL_TRACKS_FX_COUNT: {
      int32_t count = cmd->fxcount.count;
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->all_tracks.a_fx_count, count);
      break;
    }
    case LE_CMD_SET_OUTPUT_FX: {
      const int32_t bus = cmd->fx.channel;
      const int32_t index = cmd->fx.index;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      if (index < 0 || index >= LE_FX_MAX) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->outputs[bus].fx.a_fx_type[index], cmd->fx.type);
      le_fx_entry_reset(&e->outputs[bus].fx.fx, index);
      break;
    }
    case LE_CMD_SET_OUTPUT_FX_COUNT: {
      const int32_t bus = cmd->fxcount.channel;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      int32_t count = cmd->fxcount.count;
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->outputs[bus].fx.a_fx_count, count);
      break;
    }
    case LE_CMD_SET_OUTPUT_LEVEL: {
      const int32_t bus = cmd->lanef.channel;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      le_plog_push(e, frame, *cmd);
      float v = cmd->lanef.value;
      if (!(v >= 0.0f)) v = 0.0f;
      if (v > 1.0f) v = 1.0f;
      store_f32(&e->outputs[bus].a_level_bits, v);
      break;
    }
    case LE_CMD_SET_OUTPUT_MUTE: {
      const int32_t bus = cmd->lanef.channel;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->outputs[bus].a_muted, cmd->lanef.value != 0.0f ? 1 : 0);
      break;
    }
    case LE_CMD_SET_OUTPUT_MONO: {
      const int32_t bus = cmd->lanef.channel;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->outputs[bus].a_mono, cmd->lanef.value != 0.0f ? 1 : 0);
      break;
    }
    case LE_CMD_SET_OUTPUT_BALANCE: {
      const int32_t bus = cmd->lanef.channel;
      if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) break;
      le_plog_push(e, frame, *cmd);
      le_store_pan(&e->outputs[bus].a_balance_bits,
                   &e->outputs[bus].a_bal_gl_bits,
                   &e->outputs[bus].a_bal_gr_bits, cmd->lanef.value);
      break;
    }
    case LE_CMD_CUT_SOUND:
      le_plog_push(e, frame, *cmd);
      handle_cut_sound(e, frame);
      break;
    case LE_CMD_SET_MONITOR_INPUT_OUTPUT: {
      const int32_t input = cmd->trackmask.channel;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->monitors[input].a_output_mask,
                            cmd->trackmask.mask & valid, memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_VOLUME: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > LE_MAX_GAIN) v = LE_MAX_GAIN;
      store_f32(&e->monitors[input].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_MUTE: {
      const int32_t input = cmd->arg_i;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      store_i32(&e->monitors[input].a_muted, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_PAN: {
      const int32_t input = cmd->lanef.channel;
      if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) break;
      le_plog_push(e, frame, *cmd);
      le_store_pan(&e->monitors[input].a_pan_bits,
                   &e->monitors[input].a_pan_gl_bits,
                   &e->monitors[input].a_pan_gr_bits, cmd->lanef.value);
      break;
    }
    case LE_CMD_SET_OUTPUT_ENABLED: {
      const int32_t output = cmd->arg_i;
      if (output < 0 || output >= LE_MAX_CHANNELS) break;
      le_plog_push(e, frame, *cmd);
      /* Structural gate: set/clear the output's bit. Stored masks are untouched
       * (D6), so re-enabling restores the routing. A bit for an output beyond the
       * device channel count is stored but never sounded (the mix iterates only
       * [0, ch_out)). */
      uint32_t mask = atomic_load_explicit(&e->a_output_enabled_mask,
                                           memory_order_relaxed);
      if (cmd->arg_f != 0.0f) {
        mask |= (1u << output);
      } else {
        mask &= ~(1u << output);
      }
      atomic_store_explicit(&e->a_output_enabled_mask, mask,
                            memory_order_relaxed);
      break;
    }
    /* Performance-recording capture: zero-payload — the control thread already
     * published the ring set + frozen config directly into e->perf (see
     * segno_engine_api.h's LE_CMD_PERF_ARM doc) before pushing this command,
     * so applying it is just flipping the audio-thread-local mirror plus the
     * atomic the snapshot reads. */
    case LE_CMD_PERF_ARM:
      /* Callback telemetry (#722): the armed window starts HERE, on the audio
       * thread, at the exact callback the taps go live on — not at whatever
       * later moment the control thread would have got to it. Cleared before
       * the flag flips so this callback's own span (recorded at the end of
       * le_engine_process, after this drain) already lands inside it. */
      le_cb_timing_reset_armed(&e->cb_timing);
      {
        const int bus = e->perf.master_out_ch[0] / 2;
        le_engine_get_output_fx_snapshot(e, bus, &e->perf.output_fx);
        e->perf.output_level = load_f32(&e->outputs[bus].a_level_bits);
        e->perf.output_muted = load_i32(&e->outputs[bus].a_muted);
        e->perf.output_enabled_mask = atomic_load_explicit(&e->a_output_enabled_mask, memory_order_relaxed);
      }
      /* Provenance at arm (#1143): whatever is live now is the arm snapshot's
       * (image 0); anything that becomes live later goes through
       * perf.slot_image. An EMPTY track has no source until a slot is mixed.
       * A slot whose table entry is already nonzero was swapped in between
       * le_perf_arm (which zeroed the table) and this apply: the arm snapshot
       * predates it, so it is left unresolved (-1) and rule 1 logs its 322 at
       * the first mixed frame. Acquire on a_live pairs with that publish so a
       * seen swap implies a seen entry. */
      for (int t = 0; t < e->track_count; ++t) {
        le_track* tr = &e->tracks[t];
        tr->perf_source_slot = -1;
        tr->perf_source_id = 0;
        if (load_i32(&tr->a_state) == LE_TRACK_EMPTY) continue;
        const int32_t live = atomic_load_explicit(&tr->lanes[0].a_live,
                                                  memory_order_acquire);
        if (atomic_load_explicit(&e->perf.slot_image[t][live],
                                 memory_order_relaxed) == 0) {
          tr->perf_source_slot = live;
        }
      }
      e->perf.armed = 1;
      atomic_store_explicit(&e->a_perf_armed, 1, memory_order_release);
      /* Transport fact (#262): the master loop phase at THIS frame — capture
       * frame 0 (le_perf_arm reset a_perf_frames to 0 before posting this
       * command, so `frame` is 0 here). Logged AFTER e->perf.armed flips so
       * le_plog_push does not no-op. This is the exact anchor the offline
       * renderer's arm image needs; the control thread's armSnapshot.clockFrame
       * was sampled an unbounded I/O gap earlier and is race-stale. Carries the
       * loop iteration too, so a multi-loop arm image's sub-cycle is resolved
       * (#260). Free/Song or armed-from-silence: clock.length == 0, so all
       * three fields read 0 (no master phase to anchor). */
      le_plog_push(e, frame,
                   (le_command){.code = LE_PLOG_PERF_ARMED,
                                .perf_arm = {
                                    .position = e->clock.position,
                                    .master_len = e->clock.length,
                                    .iteration = (int32_t)e->loop_iteration,
                                }});
      for (int t = 0; t < e->track_count; ++t) {
        le_fade_log(e, t, frame);
        /* A track already reversed at arm logs its direction and the index
         * capture frame 0 reads (#1162); forward is the renderer's default. */
        le_track* tr = &e->tracks[t];
        if (tr->reversed) {
          le_reverse_log(e, tr, frame, le_track_read_index(e, tr), 0);
        }
      }
      break;
    case LE_CMD_PERF_DISARM:
      /* Stop touching the rings for good before le_perf_disarm's quiescent
       * wait starts counting buffer boundaries. */
      e->perf.armed = 0;
      atomic_store_explicit(&e->a_perf_armed, 0, memory_order_release);
      break;
    case LE_CMD_COMMIT_SESSION: {
      const int32_t base = cmd->session.base_frames;
      const int32_t bars = cmd->session.loop_bars;
      if (base <= 0 || bars < 0 || bars > INT32_MAX / 15) break;
      /* KNOWN GAP (B2b; B4 extends the same guard to SONG), guarded
       * (adversarial-review BUG 2 fix): this command establishes ONE shared
       * `base` length for every imported track via a whole-loop multiple —
       * correct for Multi/Sync/Band, but Free AND Song mode have no single
       * shared loop to import onto (song-mode-spec §2: Song's transport is
       * "structurally identical" to Free's — independent per-track lengths,
       * no shared grid). The control-thread wrapper (le_engine_commit_
       * session, engine_session.c) already rejects this outright when
       * a_looper_mode is FREE or SONG, so this command should never reach
       * here in either mode from the normal session-import path — but
       * le_engine_post_command is a raw FFI escape hatch that can post ANY
       * command directly, bypassing that wrapper. Without this second
       * guard, a raw post here would set e->clock / a_master_len to a
       * nonzero value while FREE/SONG — the exact invariant ("the shared
       * master clock stays permanently dormant in this mode") every other
       * Free/Song-mode code path in this file depends on staying true
       * (advance_transport_frame's shared-clock tick and mix_tracks_frame's
       * Multi-mode defaults would otherwise spuriously activate alongside
       * the per-track Free/Song-mode paths). It would ALSO, independently,
       * leave imported tracks marked PLAYING with no established free_clock
       * of their own — reproducing the exact "playback stuck reading
       * position 0 forever" bug class this PR already found and fixed once
       * in mix_tracks_frame. Free/Song-mode session import (restoring each
       * track's own free_clock from the manifest, per D12's phase-marked
       * freeLengthFrames field) is out of B2b/B4's engine-only scope — the
       * part-2 plan has no B2b/B4 manifest/session task (that lands with
       * A7/B5c) — so this simply declines the whole commit rather than
       * corrupting state or silently mishandling it. */
      {
        const int32_t mode = load_i32(&e->a_looper_mode);
        if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) break;
      }
      /* Establish the master loop and park every imported track (EMPTY with a
       * loaded length) at its whole-loop multiple. The PCM and per-track length
       * were written by le_engine_import_track before this command was posted,
       * so they are visible here (the ring publishes them release/acquire).
       * This IS the "loop length locked" transport fact for the import path
       * (the other call site is finalize_master, for the live-record path) —
       * logged as that semantic fact, not a redundant raw copy of this
       * command, so a downstream consumer never needs to know which path
       * established the length. */
      le_plog_push(
          e, frame,
          (le_command){.code = LE_PLOG_LOOP_LENGTH_LOCKED, .arg_i = base});
      le_loop_clock_set_length(&e->clock, base);
      e->loop_iteration = 0;
      store_i32(&e->a_master_len, base);
      /* Restore the actual saved grid, including an explicitly grid-free
       * loop and a bar count whose derived BPM reached the tempo clamp. */
      le_restore_musical_grid(e, bars);
      for (int32_t t = 0; t < e->track_count; ++t) {
        le_track* tr = &e->tracks[t];
        if (load_i32(&tr->a_state) != LE_TRACK_EMPTY) continue;
        const int32_t len = load_i32(&tr->lanes[0].a_len);
        if (len <= 0) continue;
        int32_t k = len / base;
        if (k < 1) k = 1;
        store_i32(&tr->a_multiple, k);
        /* Session import never encodes a B3 Sync/Band division (out of this
         * part's manifest scope, deferred to B5c like every other B3 UI/
         * session surface) — always the ordinary whole-multiple path, and
         * defensively zeroed so a track that was a division before some
         * prior clear+reimport cycle never leaks a stale divisor. */
        store_i32(&tr->a_sync_divisor, 0);
        tr->start_iter = 0;
        /* Parked at the loop head, so a Play in this same drain starts at
         * the lap start of an installed direction (#1162). */
        le_reset_track_playback(tr);
        store_i32(&tr->a_state, LE_TRACK_STOPPED);
      }
      /* A session that saved no crown still gets one: its lowest recorded
       * track. A saved crown is pushed by the control thread before or
       * after this and wins either way (reconcile never moves a live crown). */
      le_primary_reconcile(e);
      break;
    }
    default:
      break;
  }
}

/* Resolves a captured latency measurement: cross-correlates the input-magnitude
 * envelope (lat_buf) with the emitted pulse — a length-M boxcar — via a sliding
 * sum, and publishes the peak lag as the round-trip record offset. Integrating
 * over the whole pulse locks onto the sustained echo and rejects the brief
 * crosstalk/noise a first-over-threshold test mis-locked onto. Audio-thread,
 * one-shot at end of capture; bounded (<= lat_buf_cap iterations). */
static void le_latency_resolve(le_engine* e, int sr) {
  const int32_t m = sr / LE_LATENCY_PULSE_DIV; /* pulse length in frames */
  const int32_t n = e->lat_buf_pos;            /* frames captured */
  if (e->lat_buf == NULL || n <= m) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  double window = 0.0;
  for (int32_t i = 0; i < m; ++i) window += e->lat_buf[i];
  double best = window;
  double total = window;
  int32_t best_lag = 0;
  int32_t count = 1;
  for (int32_t lag = 1; lag + m <= n; ++lag) {
    window += e->lat_buf[lag + m - 1] - e->lat_buf[lag - 1];
    total += window;
    ++count;
    if (window > best) {
      best = window;
      best_lag = lag;
    }
  }
  const double avg = total / (double)count;
  /* The echo's correlation peak must stand clearly above the baseline — a
   * level-independent test that works for weak loopback levels; the tiny
   * absolute floor rejects pure silence. */
  if (best < (double)LE_LATENCY_PEAK_RATIO * avg || best / (double)m < 1e-4) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  store_i32(&e->a_record_offset, best_lag);
  atomic_store_explicit(&e->a_latency_ms_bits,
                        f64_to_bits((double)best_lag * 1000.0 / (double)sr),
                        memory_order_relaxed);
  store_i32(&e->a_latency_state, LE_LATENCY_DONE);
}

/* ---- per-frame steps of le_engine_process ----
 *
 * Each is `static inline` so the compiler folds it back into the per-frame loop
 * with no call overhead — the decomposition is for readability and unit-testing
 * (engine_internal.h can expose thin wrappers), not a structural change to the
 * hot path. They run in the order called in le_engine_process: the additive mix
 * is already in `out[f*ch_out + c]` when master_bus_frame runs. */

/* The same push for the master capture from a bus's pair before its level
 * (slice 3b): the default tap, so the PA's level does not reach the take. */
static inline void perf_push_master(le_engine* e, const float s[2]) {
  if (!e->perf.armed) return;
  if (!le_audio_ring_push_frame(&e->perf.master_ring, s,
                                (size_t)e->perf.master_channels)) {
    atomic_fetch_add_explicit(&e->a_perf_overruns, 1u, memory_order_relaxed);
  }
}

static inline void perf_tap_master_pair(le_engine* e, int bus, float l,
                                        float r) {
  /* master_out_ch is the enabled channel(s) of this pair, frozen at arm: a
   * mono capture may be the pair's right channel. */
  const float s[2] = {e->perf.master_out_ch[0] == 2 * bus ? l : r, r};
  perf_push_master(e, s);
}

static inline void snapshot_bus_fx(le_fx_bus* b, int32_t* bus_fx_count,
                                   int32_t* bus_fx_pre_count,
                                   int32_t bus_fx_type[LE_FX_MAX],
                                   float bus_fx_params[LE_FX_MAX][LE_FX_PARAMS],
                                   int32_t bus_fx_enabled[LE_FX_MAX],
                                   int* bus_has_fx);


static inline void snapshot_output_bus(le_output_bus* ob, int bus, int ch_out,
                                       uint32_t out_enabled,
                                       le_obus_snap* sn) {
  int32_t unused_pre = 0; /* an output chain is wholly Post */
  snapshot_bus_fx(&ob->fx, &sn->fx_count, &unused_pre, sn->fx_type,
                  sn->fx_params, sn->fx_enabled, &sn->has_fx);
  sn->level = load_f32(&ob->a_level_bits);
  sn->muted = load_i32(&ob->a_muted);
  sn->mono = load_i32(&ob->a_mono);
  sn->gl = load_f32(&ob->a_bal_gl_bits);
  sn->gr = load_f32(&ob->a_bal_gr_bits);
  const int c0 = 2 * bus;
  sn->en_l = (out_enabled & (1u << c0)) != 0;
  sn->en_r = c0 + 1 < ch_out && (out_enabled & (1u << (c0 + 1))) != 0;
  sn->active = sn->has_fx || sn->level != 1.0f || sn->muted || sn->mono ||
               sn->gl != 1.0f || sn->gr != 1.0f;
}

/* One output bus for one frame (slice 3b): its chain over the pair, the
 * pre-level performance tap when it is the captured bus, then Mono or
 * balance, level and mute. Runs after every source summed onto the outputs,
 * before the global master gain and limiter. A disabled channel of the pair
 * is never written, and Mono averages the enabled channels only, so a pair
 * with one jack disabled keeps its level. The pair is read without that gate
 * because nothing sums into a disabled channel anyway (the frame starts
 * zeroed and every source masks by out_enabled), so the two are equivalent
 * and this is the shorter one.
 *
 * That upstream masking is also why the capture tap below and the jack gate
 * interact the way they do: disabling an output is the ROUTING GRAPH
 * (le_engine_set_output_enabled), so nothing reaches that channel and a take
 * capturing this bus loses it too; the bus MUTE is a gain applied after the
 * tap, so it never reaches the take. Two PA-side controls, deliberately
 * different, pinned by test_perf_capture_first_bus_with_enabled_channel. A
 * single-channel last bus processes its channel as l == r. */
static inline void output_bus_frame(le_engine* e, float* out, uint32_t f,
                                    int ch_out, int sr, int fx_cap, int bus,
                                    const le_obus_snap* sn, int tap_here) {
  float* o = out + (size_t)f * (size_t)ch_out;
  const int c0 = 2 * bus;
  const int c1 = c0 + 1 < ch_out ? c0 + 1 : -1;
  float l = o[c0];
  float r = c1 >= 0 ? o[c1] : l;
  if (sn->has_fx) {
    fx_apply_chain(&e->outputs[bus].fx.fx, sr, fx_cap, &l, &r, sn->fx_count,
                   sn->fx_type, sn->fx_params, sn->fx_enabled);
  }
  if (tap_here) {
    const float gain = e->perf.follow_output ? (sn->muted ? 0.0f : sn->level) : 1.0f;
    perf_tap_master_pair(e, bus, l * gain, r * gain);
  }
  if (sn->mono) {
    const int n = (sn->en_l ? 1 : 0) + (sn->en_r ? 1 : 0);
    const float mid = n == 2 ? 0.5f * (l + r) : (sn->en_l ? l : r);
    l = mid;
    r = mid;
  } else {
    l *= sn->gl;
    r *= sn->gr;
  }
  if (sn->muted) {
    l = 0.0f;
    r = 0.0f;
  } else if (sn->level != 1.0f) {
    l *= sn->level;
    r *= sn->level;
  }
  if (sn->en_l) o[c0] = l;
  if (c1 >= 0 && sn->en_r) o[c1] = r;
}

/* Master bus for one output frame: global gain, then the feed-forward peak
 * limiter (instant attack / smooth release, bit-transparent below the ceiling),
 * then output metering. Accumulates *out_sumsq and tracks *frame_out_peak (both
 * start at the caller's per-block / per-frame seed). */
static inline void master_bus_frame(le_engine* e, float* out, uint32_t f,
                                    int ch_out, float master_gain, int limiter_on,
                                    float limiter_ceiling, float lim_release,
                                    float* out_sumsq, float* frame_out_peak,
                                    float* out_peak_ch) {
  /* Apply the global master gain post-mix, before metering and the loop-viz
   * tap, so meters and the waveform reflect what the listener actually hears.
   * The latency-calibration pulse path bypasses this (it `continue`s the frame),
   * keeping the measurement tone at its fixed amplitude. */
  if (master_gain != 1.0f) {
    for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] *= master_gain;
  }

  /* Master peak limiter (feed-forward, no lookahead): find this frame's peak,
   * compute the gain that would pin it to the ceiling, and apply it. Instant
   * attack — if the needed gain is below the current one, clamp down this very
   * frame so nothing exceeds the ceiling (no overshoot); smooth release back
   * toward unity. Below the ceiling the gain rests at 1.0, so the path is
   * bit-transparent when nothing is clipping. */
  if (limiter_on) {
    float peak = 0.0f;
    for (int c = 0; c < ch_out; ++c) {
      const float a = fabsf(out[f * ch_out + c]);
      if (a > peak) peak = a;
    }
    float target = 1.0f;
    if (peak > limiter_ceiling && peak > 0.0f) target = limiter_ceiling / peak;
    if (target < e->lim_gain) {
      e->lim_gain = target; /* instant attack: no sample over the ceiling */
    } else {
      e->lim_gain += (target - e->lim_gain) * lim_release;
    }
    if (e->lim_gain != 1.0f) {
      for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] *= e->lim_gain;
    }
  }

  /* Output metering for this frame. */
  for (int c = 0; c < ch_out; ++c) {
    const float sample = out[f * ch_out + c];
    *out_sumsq += sample * sample;
    const float sa = fabsf(sample);
    if (sa > *frame_out_peak) *frame_out_peak = sa;
    if (sa > out_peak_ch[c]) out_peak_ch[c] = sa;
  }
}

/* Performance-recording capture taps (le_perf_arm/disarm, segno_engine_api.h):
 * copy the post-limiter master output and each captured monitor input's
 * post-FX signal into their pre-published rings. Both are no-ops when not
 * armed (`e->perf.armed`, the audio-thread-local mirror of a_perf_armed);
 * neither ever blocks or allocates — a full ring just drops the frame and
 * bumps the shared overrun atomic. */

/* Tap for the master bus: [master_out_ch] selects the first enabled output
 * pair frozen at arm (mono when only one channel was captured). */
static inline void perf_tap_monitor_frame(le_engine* e, int input, float l,
                                          float r) {
  const float s[2] = {l, r};
  if (!le_audio_ring_push_frame(&e->perf.monitor_ring[input], s, 2)) {
    atomic_fetch_add_explicit(&e->a_perf_overruns, 1u, memory_order_relaxed);
  }
}

/* ---- click + count-in per-frame steps (A2) ----
 *
 * The click sums into its masked output channels BEFORE the output buses
 * (slice 3b), so a destination's chain, level and mute process it, the
 * master gain and limiter apply to it, output metering and the loop viz see
 * it, and a performance capture contains it when it is routed to the
 * captured bus (accepted design). */

/* The frame's click audibility gate (le_click_mode semantics). `st` is the
 * frame's per-track state snapshot from mix_tracks_frame. A count-in overrides
 * every mode but OFF: the whole point of counting is hearing it. */
static inline int le_click_gate(const le_engine* e, int32_t mode, int tc,
                                const int32_t* st) {
  if (e->count_in_total > 0) return 1;
  switch (mode) {
    case LE_CLICK_REC:
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_RECORDING || st[t] == LE_TRACK_OVERDUBBING) {
          return 1;
        }
      }
      return 0;
    case LE_CLICK_REC_FIRST:
      /* Only the DEFINING first-layer recording (no master yet). */
      if (e->clock.length != 0) return 0;
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_RECORDING) return 1;
      }
      return 0;
    case LE_CLICK_PLAY_REC:
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_RECORDING ||
            st[t] == LE_TRACK_OVERDUBBING) {
          return 1;
        }
      }
      return 0;
    default:
      return 0;
  }
}

/* Clear the table before invoking normal start bodies: no re-arm, one
 * sample boundary, insertion order independent of track index. Earlier fresh
 * captures are retired without finalization by close_active_capture. */
static void le_count_in_commit(le_engine* e, uint64_t frame) {
  int32_t order[LE_MAX_TRACKS], actions[LE_MAX_TRACKS];
  const int count = e->launch_count;
  const uint32_t stopped = e->launch_stopped_mask;
  for (int i = 0; i < count; ++i) {
    order[i] = e->launch_order[i];
    actions[i] = e->launch_action[order[i]];
    e->launch_action[order[i]] = 0; /* keep the member's prepared image */
  }
  /* Set before the reset so it leaves a_pending_launch to the member loop
   * below: a DISARM control posts while a member reads neither pending nor
   * in grace would drain against launch_grace and empty the take unticketed
   * (#1146). The start bodies below already run under this flag. */
  e->launch_committing = 1;
  le_count_in_reset(e);
  e->launch_stopped_mask = stopped;
  const int mode = load_i32(&e->a_looper_mode);
  const int primary = mode == LE_LOOPER_MODE_BAND
      ? load_i32(&e->a_primary_track) : -1;
  int section = -1;
  if (mode == LE_LOOPER_MODE_SONG || mode == LE_LOOPER_MODE_BAND) {
    for (int i = 0; i < count; ++i)
      if (order[i] != primary) section = order[i];
    if (section >= 0) for (int c = 0; c < e->track_count; ++c)
      if (c != section && c != primary) e->launch_stopped_mask |= 1u << c;
  }
  for (int i = 0; i < count; ++i) {
    const int ch = order[i], action = actions[i];
    const int state = load_i32(&e->tracks[ch].a_state);
    if ((action == 1 && state != LE_TRACK_EMPTY) ||
        (action != 1 && state != LE_TRACK_STOPPED && state != LE_TRACK_PLAYING))
      continue;
    if (action == 2) handle_play(e, ch, frame);
    else handle_record(e, ch, frame);
    e->launch_grace[ch] = action;
    /* Grace before pending, both release: le_ticket_launch_cancel reads
     * pending first (acquire), so a clear it observes implies the grace store
     * is visible, and the member is cancellable-and-ticketed at every instant. */
    atomic_store_explicit(&e->tracks[ch].a_launch_grace, action,
                          memory_order_release);
    atomic_store_explicit(&e->tracks[ch].a_pending_launch, 0,
                          memory_order_release);
  }
  /* Members skipped above (no longer in a launchable state) get no grace:
   * their pending flag, kept by the reset, clears here. */
  for (int32_t c = 0; c < e->track_count; ++c) {
    atomic_store_explicit(&e->tracks[c].a_pending_launch, 0,
                          memory_order_release);
  }
  /* Section exclusion changes playback, not capture ownership. A later Play
   * must not finalize an earlier capture; only a subsequent capture does so. */
  if (section >= 0) for (int c = 0; c < e->track_count; ++c) {
    if (c != section && c != primary &&
        load_i32(&e->tracks[c].a_state) == LE_TRACK_PLAYING) {
      store_i32(&e->tracks[c].a_state, LE_TRACK_STOPPED);
      e->launch_grace[c] = 0;
      store_i32(&e->tracks[c].a_launch_grace, 0);
    }
  }
  e->launch_committing = 0;
  e->launch_stopped_mask = 0;
  e->click_free_running = 1;
  e->click_free_frame = 0;
  e->click_free_beat = 0;
}

/* Advances the count-in / free-running click schedulers and synthesizes the
 * click voice into the masked output channels for one frame. `click_on` is
 * the frame's audibility gate (le_click_gate). Dormant cost with the
 * defaults: the single fused compare at the top (all three terms are
 * audio-thread-local ints that read 0). */
static inline void click_frame(le_engine* e, float* out, uint32_t f,
                               int ch_out, int click_on, uint32_t mask,
                               float vol, int sr, uint64_t frame) {
  /* click_free_running joins the fuse so a gate that fell while no burst was
   * sounding still gets its one clean-up pass (the free-run reset below) —
   * after that the whole term reads 0 again and this stays one compare. */
  if ((click_on | e->count_in_total | e->click_remaining |
       e->click_free_running) == 0) {
    return;
  }

  if (e->count_in_total > 0) {
    /* Counting in: beats render from their index against the frozen nominal
     * fpb (no accumulation drift), audible in every mode but OFF. */
    if (e->count_in_beat < e->count_in_beats &&
        e->count_in_elapsed >=
            (int32_t)llround((double)e->count_in_beat * e->count_in_fpb)) {
      const int32_t num = load_i32(&e->a_ts_num);
      const int32_t bar_beat = num > 0 ? e->count_in_beat % num : 0;
      if (click_on) trigger_click(e, bar_beat == 0);
      store_i32(&e->a_current_beat, bar_beat);
      store_i32(&e->a_count_in_beats_left,
                e->count_in_beats - e->count_in_beat);
      e->count_in_beat++;
    }
    e->count_in_elapsed++;
    if (e->count_in_elapsed >= e->count_in_total) {
      le_count_in_commit(e, frame); /* the downbeat: recording starts */
    }
  } else {
    /* Free-running scheduler: with no loop yet (the defining recording) and
     * a tempo set, the beat phase runs on the nominal grid, re-anchoring its
     * downbeat whenever it activates. Once a loop exists, grid_beat_frame
     * schedules the click whether or not sync gave it a grid (#1050): a
     * free-run there restarted the count at every record press. */
    const int free_run = click_on && e->clock.length <= 0;
    if (!free_run) {
      e->click_free_running = 0;
    } else {
      if (!e->click_free_running) {
        e->click_free_running = 1;
        e->click_free_frame = 0;
        e->click_free_beat = 0;
      }
      if (e->click_free_frame == 0) {
        /* Beat boundary: refresh fpb from the published tempo (a pre-content
         * tempo change retunes the next beat), click, publish the beat. */
        const float bpm = load_f32(&e->a_tempo_bpm_bits);
        if (bpm > 0.0f) {
          const int32_t fpb = (int32_t)llround(60.0 * (double)sr / (double)bpm);
          e->click_free_fpb = fpb > 0 ? fpb : 1;
          const int32_t num = load_i32(&e->a_ts_num);
          trigger_click(e, e->click_free_beat == 0);
          store_i32(&e->a_current_beat,
                    num > 0 ? e->click_free_beat % num : 0);
        } else {
          e->click_free_fpb = 0; /* no tempo: nothing to click against */
        }
      }
      if (e->click_free_fpb > 0 && ++e->click_free_frame >= e->click_free_fpb) {
        e->click_free_frame = 0;
        const int32_t num = load_i32(&e->a_ts_num);
        e->click_free_beat = num > 0 ? (e->click_free_beat + 1) % num : 0;
      }
    }
  }

  /* Synthesis: one sample of the decaying sine burst, summed into the masked
   * channels only. Post-master-bus by design — see the block comment above. */
  if (e->click_remaining > 0) {
    const float env = (float)e->click_remaining / (float)e->click_len;
    const float s = LE_CLICK_AMP * env * sinf(e->click_phase) * vol;
    e->click_phase += LE_CLICK_TWO_PI * e->click_freq / (float)sr;
    if (e->click_phase > LE_CLICK_TWO_PI) e->click_phase -= LE_CLICK_TWO_PI;
    e->click_remaining--;
    if (mask != 0u) {
      float* o = out + (size_t)f * (size_t)ch_out;
      for (int c = 0; c < ch_out; ++c) {
        if (mask & (1u << c)) o[c] += s;
      }
    }
  }
}

/* Mixed output follows the master clock. Track waveforms below use their
 * own full read coordinates, matching the playhead published in the snapshot. */
static inline void viz_tap_frame(le_engine* e, int32_t pos,
                                 float frame_out_peak) {
  if (e->clock.length <= 0) return;
  int32_t bucket = (int32_t)((int64_t)pos * LE_VIZ_POINTS / e->clock.length);
  if (bucket >= LE_VIZ_POINTS) bucket = LE_VIZ_POINTS - 1;
  if (bucket != e->loop_viz_bucket) {
    const int32_t prev = e->loop_viz_bucket;
    if (prev >= 0 && prev < LE_VIZ_POINTS) {
      store_f32(&e->a_loop_viz[prev], e->loop_viz_accum);
    }
    e->loop_viz_bucket = bucket;
    e->loop_viz_accum = 0.0f;
  }
  if (frame_out_peak > e->loop_viz_accum) e->loop_viz_accum = frame_out_peak;
}

/* The mixer already resolves each track's multiple, division or private
 * clock. Bucket that same read index over its full finalized length. Only
 * sounding tracks sweep: a stopped track keeps its shape for later selection.
 * A first recording gets its shape on playback, once its length is stable.
 * Audio-thread local accumulation and bounded atomic publication only. */
static inline void track_viz_tap_frame(le_engine* e, int tc,
                                       const int32_t* st,
                                       const float* frame_trk_peak) {
  for (int t = 0; t < tc; ++t) {
    if (st[t] != LE_TRACK_PLAYING && st[t] != LE_TRACK_OVERDUBBING) continue;
    const int32_t len = load_i32(&e->tracks[t].lanes[0].a_len);
    if (len <= 0) continue;
    int32_t bucket = (int32_t)((int64_t)e->trk_play_pos[t] * LE_VIZ_POINTS / len);
    if (bucket >= LE_VIZ_POINTS) bucket = LE_VIZ_POINTS - 1;
    if (bucket != e->track_viz_bucket[t]) {
      const int32_t prev = e->track_viz_bucket[t];
      if (prev >= 0 && prev < LE_VIZ_POINTS) {
        store_f32(&e->a_track_viz[t][prev], e->track_viz_accum[t]);
      }
      e->track_viz_bucket[t] = bucket;
      e->track_viz_accum[t] = 0.0f;
    }
    if (frame_trk_peak[t] > e->track_viz_accum[t]) {
      e->track_viz_accum[t] = frame_trk_peak[t];
    }
  }
}

/* One Shot's stop (B4; every mode since slice 2b): the same audible
 * transition as a manual Stop press on a sounding track — handle_stop's
 * PLAYING/OVERDUBBING -> STOPPED branch, pending mutes landing the same way,
 * an overdub in flight ending its capture and draining/retiring through the
 * ordinary dub machinery.
 *
 * Synthetic LE_CMD_STOP (#420): apply_command logs a manual Stop before
 * handle_stop runs — without an entry here a perf-log replay hears the
 * track playing forever past the wrap. Same replays-match-what-a-listener-
 * heard rule as le_unpark_stopped's synthetic LE_CMD_PLAY and
 * le_capture_start_unmute's synthetic LE_CMD_SET_LANE_MUTE. Deliberately NO
 * LE_PLOG_RECORD_END for a wrap mid-overdub: a manual Stop on an OVERDUBBING
 * track pushes none either — RECORD_END means "left RECORDING"
 * (perf_log_ring.h), a state the callers never admit, and the dub pass's
 * end is already logged when its layer retires (LE_PLOG_LAYER_RETIRED) — so
 * emitting one would make the wrap's log DIFFER from a manual stop's and
 * hand perf_render's RECORD_START/END pairing an unpaired END. */
static void le_one_shot_stop(le_engine* e, le_track* t, int32_t ch,
                             uint64_t frame) {
  t->once_ended = 1;
  t->once_current_pass = 0;
  t->sounding_frames = 0;
  le_plog_push(e, frame, (le_command){.code = LE_CMD_STOP, .arg_i = ch});
  store_i32(&t->a_state, LE_TRACK_STOPPED);
  le_consume_pending_mutes(e, t, LE_TRACK_STOPPED, 1, frame);
}

/* Free/Song mode (B2b, broadened to SONG by B4): advances track [ch]'s own
 * clock by one frame, mirroring le_loop_clock_tick's per-master-clock shape
 * but scoped to a single track — ticks (and bumps the track's own wrap
 * counter) only while that track is actually sounding (PLAYING or
 * OVERDUBBING); a RECORDING, STOPPED, or EMPTY track's own clock holds its
 * position (no "hold the whole rig at the top" concept per-track in either
 * mode — a stopped Free/Song-mode track simply pauses and resumes where it
 * left off, same as playback silently skipping it in mix_tracks_frame while
 * stopped). No-op (by construction) when this track's clock isn't
 * established yet (length <= 0): a track still on its own first/defining
 * recording never reaches PLAYING/OVERDUBBING before finalize_master sets
 * free_clock, so this is a defensive belt more than a reachable guard.
 *
 * Free/Song Once stops at this track's own wrap. Shared modes use their
 * playback coordinate in le_shared_clock_one_shots. A track that wraps stops:
 * the transition mirrors handle_stop's own PLAYING/OVERDUBBING -> STOPPED
 * branch exactly (same pending-mute landing via le_consume_pending_mutes),
 * so an overdub in flight ends its capture and drains/retires through the
 * ordinary dub machinery — a manual Stop press produces byte-identical
 * downstream behavior. Checked AFTER free_iteration bumps: a one-shot track
 * still completed the lap (iteration count stays meaningful for viz/debug),
 * it simply never starts a second one. */
static inline void advance_track_clock_frame(le_engine* e, int32_t ch,
                                             int32_t state, uint64_t frame) {
  le_track* t = &e->tracks[ch];
  if (t->free_clock.length <= 0) return;
  if (state != LE_TRACK_PLAYING && state != LE_TRACK_OVERDUBBING) return;
  if (le_loop_clock_tick(&t->free_clock)) t->free_iteration++;
  /* Once stops when the READ lap ends — the index the next frame would read
   * is the lap start in the track's direction (#1162). Identical to "the
   * private clock wrapped" for a forward track with a parked origin. */
  if (load_i32(&t->a_one_shot)) {
    int32_t len;
    const int64_t base = le_track_base_position(e, t, &len);
    if (len > 0 && le_direction_index(t->reversed, t->playback_offset, base,
                                      len) ==
                       le_direction_lap_start(t->reversed, len)) {
      le_one_shot_stop(e, t, ch, frame);
    }
  }
}

/* One Shot in the shared-clock modes (accepted design, slice 2b; the
 * Multi/Sync/Band half of le_engine_set_one_shot's doc). Called once per
 * ticking frame AFTER the grid and section arms have fired, so the arms see
 * the states they were queued against (a punch-out lands as a punch-out, a
 * section stop stays a stop, and a held transport is measured before any
 * Once stop could fake one). A one-shot track that is sounding stops when
 * its own read coordinate returns to zero. Ordinarily that follows the shared
 * segment/division rules; after an automatic-end relaunch it includes the
 * track's playback origin, leaving the musical capture grid untouched.
 * Two guards keep the stop from cutting a pass short:
 *   - sounding_frames counts the frames the track has been sounding and is
 *     reset while it is not; a lap end only stops a track that has sounded
 *     for a whole lap (k * base, or the division's length), so a take
 *     finalized mid-lap (this frame included) plays its first full lap. When
 *     Once is enabled during playback, once_current_pass instead permits the
 *     current pass to finish without requiring another full lap;
 *   - a track whose grid arm fired this frame into OVERDUBBING (a punch-in,
 *     or a rec/dub finalize) is skipped: the queued pass wins, and Once ends
 *     the track at that pass's end.
 * No-op with no master (Free/Song keep e->clock dormant and tick their own
 * clocks through advance_track_clock_frame). */
static inline void le_shared_clock_one_shots(le_engine* e, int tc,
                                             const uint8_t* fired,
                                             uint64_t frame) {
  const int32_t base = e->clock.length;
  if (base <= 0) return;
  for (int t = 0; t < tc; ++t) {
    le_track* tr = &e->tracks[t];
    const int32_t st = load_i32(&tr->a_state);
    if (st != LE_TRACK_PLAYING && st != LE_TRACK_OVERDUBBING) {
      tr->sounding_frames = 0;
      continue;
    }
    tr->sounding_frames++;
    if (!load_i32(&tr->a_one_shot)) continue;
    if (fired[t] && st == LE_TRACK_OVERDUBBING) continue;
    const int32_t len = load_i32(&tr->lanes[0].a_len);
    /* The read lap's start in the track's own direction (#1162): 0 forward,
     * len - 1 reversed — "finishes the current pass" either way. */
    const int lap_end = len > 0 && le_track_read_index(e, tr) ==
                                       le_direction_lap_start(tr->reversed, len);
    if (lap_end &&
        (tr->once_current_pass || tr->sounding_frames >= (uint64_t)len)) {
      le_one_shot_stop(e, tr, t, frame);
    }
  }
}

/* Fires a Band section-transport arm (B3b, trigger 2, LE_CMD_ARM's doc): the
 * arm carries no explicit "which direction" — it's a TOGGLE of whatever a
 * press on this track would currently do, exactly like handle_record's own
 * per-state dispatch. STOPPED starts it (mirrors handle_play); PLAYING,
 * OVERDUBBING, or RECORDING stops/finalizes it (handle_stop already covers
 * all three). EMPTY has nothing to toggle — the arm simply expires with no
 * effect (a section reaches this call only after its own defining recording
 * has finalized in practice, but this stays correct even if that invariant
 * is ever violated). */
static void le_fire_section_arm(le_engine* e, int32_t ch, uint64_t frame) {
  const int32_t st = load_i32(&e->tracks[ch].a_state);
  if (st == LE_TRACK_STOPPED) {
    handle_play(e, ch, frame);
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING ||
            st == LE_TRACK_RECORDING) {
    handle_stop(e, ch, frame);
  }
}

/* Advances the record heads and then the master transport for one frame. An
 * auto-multiple track grows freely (rounded up only on stop); a fixed-multiple
 * track auto-finalizes after exactly K base loops, and a track recorded over an
 * existing master continues into overdub when it auto-finalizes. When the loop
 * crosses its top, fires the loop-top (quantize) pending records on the grid;
 * with nothing active, holds the transport at the top. [st] is the frame's
 * per-track state snapshot. */
static inline void advance_transport_frame(le_engine* e, int tc,
                                           const int32_t* st, uint64_t frame) {
  for (int t = 0; t < tc; ++t) {
    if (st[t] != LE_TRACK_RECORDING) continue;
    le_track* tr = &e->tracks[t];
    if (e->clock.length == 0) {
      tr->record_pos++;
      if (tr->xfade_capture > 0) {
        /* Deferred seam crossfade: keep capturing the overlap past the loop
         * point, then fold it into the head and finalize at the intended
         * length. The buffer room was checked when the deferral was armed. */
        if (--tr->xfade_capture == 0) finalize_master_xfade(e, tr, frame);
      } else if (tr->length_preset_target_frames > 0 &&
                 tr->record_pos >= tr->length_preset_target_frames) {
        /* A6/D17: N-bars + click-on auto-finalize — exactly N bars' worth of
         * frames were captured (target armed at record start by
         * le_arm_length_preset_target). Finalizes into overdub UNCONDITIONALLY
         * — the manual's "auto-finishes... and starts overdubbing" is not
         * gated on rec_dub like a manual second press would be. Deferred via
         * request_master_finalize (not a direct finalize_master call) so the
         * seam gets the same click-free crossfade as a manual press. */
        request_master_finalize(e, tr, LE_TRACK_OVERDUBBING, frame);
      } else if (tr->record_pos >= e->max_loop_frames) {
        finalize_master(e, tr, LE_TRACK_PLAYING, frame);
      }
    } else {
      tr->record_pos++;
      const int32_t eff = le_effective_multiple(e, t);
      const int32_t base = e->clock.length;
      if (eff >= 1 && tr->record_pos - tr->record_start >= eff * base) {
        finalize_new_track(e, tr, LE_TRACK_OVERDUBBING, frame);
      } else if (tr->record_pos >= e->max_loop_frames) {
        finalize_new_track(e, tr, LE_TRACK_OVERDUBBING, frame);
      }
    }
  }
  if (e->clock.length > 0) {
    int any_active = 0;
    for (int t = 0; t < tc; ++t) {
      if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_RECORDING ||
          st[t] == LE_TRACK_OVERDUBBING) {
        any_active = 1;
        break;
      }
    }
    if (any_active) {
      e->transport_held = 0; /* #262: transport is running; re-arm the hold edge */
      const int wrapped = le_loop_clock_tick(&e->clock);
      if (wrapped) {
        e->loop_iteration++;
        /* A grid-free loop can be shorter than one nominal beat, leaving
         * its beat index at zero throughout. Re-arm on the actual wrap so
         * every loop top clicks even without a beat-index transition. */
        if (e->grid_total_beats <= 0) e->grid_prev_beat = -1;
      }
      /* Which tracks' grid arms fire on this tick: read by the Once check
       * below, which runs after the arms so it sees what they did. */
      uint8_t fired[LE_MAX_TRACKS] = {0};
      /* Grid-armed fire check. The loop top (wrap) is every division's
       * boundary AND the layer boundary, so it fires everything — the exact
       * pre-A3 behavior, and the whole behavior when the quantize division is
       * OFF. With a division set and a loop-locked grid live, a mid-loop
       * subdivision boundary — the first frame whose loop-locked subdivision
       * index differs from the previous frame's (le_grid_loop_subdiv_at over
       * the ACTUAL length, never nominal-BPM multiples) — also fires, except
       * an overdubbing track's punch-out, which stays at the layer boundary
       * (D8: overdub end unchanged). Reading the live division here is what
       * re-evaluates a pending arm on a granularity change: the next check
       * simply uses the new division, and OFF reverts to loop-top-only.
       * Stateless per-frame index compare, gated on an actual trigger-0
       * pending so the dormant cost is a few flag reads. */
      /* Per track since slice 2b: each armed track is checked against ITS
       * OWN effective division (le_live_subdiv_ratio's override), so two
       * armed tracks can fire on different grids in the same lap. The wrap
       * still fires every one of them. */
      for (int qt = 0; qt < tc; ++qt) {
        le_track* pt = &e->tracks[qt];
        if (!pt->pending_record || pt->pending_trigger != 0) continue;
        int boundary = wrapped;
        /* A Sync/Band force-arm begins a DEFINING take, and
         * finalize_new_track's division-playback formula reads a phase locked
         * to the primary's loop top — which only holds if the take began
         * there. A subdivision boundary would start it a quarter (or an
         * eighth) into the primary's cycle and the sub-loop would play
         * rotated by that much. The same rule the Band section transport
         * states a dozen lines below; here it is keyed on the ARM's nature,
         * so it covers a per-track division and a global one alike. */
        const int sync_defining_arm =
            load_i32(&pt->a_state) == LE_TRACK_EMPTY &&
            le_sync_quantize_active(e, qt);
        if (!boundary && !sync_defining_arm) {
          int64_t sn, sd;
          if (le_live_subdiv_ratio(e, qt, &sn, &sd)) {
            const int32_t p = e->clock.position; /* just ticked to p >= 1 */
            boundary =
                le_grid_loop_subdiv_at(p, e->clock.length, sn, sd) !=
                le_grid_loop_subdiv_at(p - 1, e->clock.length, sn, sd);
          }
        }
        /* Fire the grid-armed pending record so a deferred start/finalize/
         * overdub lands exactly on the grid. Signal-triggered arms fire in
         * process_input_frame, not here. handle_record enforces the
         * one-capturer hand-off. */
        if (boundary &&
            (wrapped || load_i32(&pt->a_state) != LE_TRACK_OVERDUBBING)) {
          pt->pending_record = 0;
          store_i32(&pt->a_pending, 0);
          handle_record(e, qt, frame);
          fired[qt] = 1;
        }
      }
      /* Band section transport (B3b, trigger 2): fires ONLY on the true
       * primary-track loop top (`wrapped`) — deliberately NOT on a
       * subdivision `boundary` like trigger 0 above. The spec's "quantized
       * to the primary track" (song-mode-spec.md §2 Q3, §3's STOP-pedal
       * table) means the primary's CYCLE, not a musical subdivision of it;
       * with mode/primary established this way, the primary defines
       * e->clock (le_sync_quantize_active), so a wrap here IS "the primary
       * track returns to its beginning". */
      if (wrapped) {
        for (int qt = 0; qt < tc; ++qt) {
          if (e->tracks[qt].pending_record &&
              e->tracks[qt].pending_trigger == 2) {
            e->tracks[qt].pending_record = 0;
            store_i32(&e->tracks[qt].a_pending, 0);
            le_fire_section_arm(e, qt, frame);
          }
        }
      }
      /* Once (slice 2b): a one-shot track whose own lap ended on this tick
       * stops here, after the arms above have done what they were queued
       * for. */
      le_shared_clock_one_shots(e, tc, fired, frame);
    } else {
      /* Nothing is playing or recording: hold the transport at the top so the
       * next play starts from the beginning rather than looping in silence.
       * Resetting each track's start_iter keeps multi-loop tracks aligned to
       * their first segment on the next play. */
      /* Transport fact (#262), edge-triggered: log the hold once, at the frame
       * it begins, carrying the position the clock is pinned FROM (read BEFORE
       * the reset below). Subsequent held frames find the latch set and stay
       * silent. Lets the renderer see a clock the engine froze mid-capture
       * rather than silently running its phase math forward. */
      if (!e->transport_held) {
        le_plog_push(e, frame,
                     (le_command){.code = LE_PLOG_TRANSPORT_HELD,
                                  .arg_i = e->clock.position});
        e->transport_held = 1;
      }
      e->clock.position = 0;
      e->loop_iteration = 0;
      for (int t = 0; t < tc; ++t) {
        e->tracks[t].start_iter = 0;
        e->tracks[t].playback_offset = 0;
        e->tracks[t].turn_left = 0; /* a parked origin has no old head */
        e->tracks[t].sounding_frames = 0; /* the next launch is a fresh lap */
      }
    }
  }
  /* Free/Song mode (B2b, index Architecture §4; broadened to SONG by B4):
   * each track's own clock advances independently of the shared master
   * above, which stays permanently dormant (e->clock.length == 0) in either
   * mode — a single guarded call so this diff stays inspectable at a
   * glance, and provably UNREACHABLE (not merely untested) when
   * a_looper_mode is neither FREE nor SONG. */
  {
    const int32_t mode = load_i32(&e->a_looper_mode);
    if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
      for (int t = 0; t < tc; ++t) {
        advance_track_clock_frame(e, t, st[t], frame);
      }
    }
  }
}

/* ---- per-block setup snapshots ----
 *
 * The per-lane / per-monitor effect chains are snapshotted ONCE per buffer: the
 * control thread applies fx edits at buffer granularity, so the audio thread
 * reads each lane's published type/count/params once here and works off the
 * stack copy until a deferred capture publishes a new image; that boundary
 * refreshes only the affected track. has_fx gates the
 * chain so a lane with no effects skips it. `static inline` so these fold into
 * le_engine_process; out-params are the caller's stack arrays. */

/* Snapshots every active track LANE's effect chain into the caller's arrays.
 * fx_enabled carries the per-slot EFFECTIVE enable bit (D-EFFBITS:
 * chain-enabled && slot-enabled) — the only enable view the audio thread ever
 * consumes; fx_apply_chain never distinguishes chain from slot. has_fx gating
 * is UNCHANGED by the enable flags: a lane with a disabled chain still enters
 * fx_apply_chain so in-flight enable ramps can settle — only settled slots
 * are skipped, inside the chain (D-BITEXACT). */
static inline void snapshot_lane_fx(
    le_engine* e, int tc, uint32_t track_mask, const int32_t* lane_n,
    int32_t fx_count[][LE_MAX_LANES], int32_t fx_pre_count[][LE_MAX_LANES],
    int32_t fx_type[][LE_MAX_LANES][LE_FX_MAX],
    float fx_params[][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS],
    int32_t fx_enabled[][LE_MAX_LANES][LE_FX_MAX], int has_fx[][LE_MAX_LANES]) {
  for (int t = 0; t < tc; ++t) {
    if (!(track_mask & (1u << t))) continue;
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      has_fx[t][l] = 0;
      int32_t n = load_i32(&ln->a_fx_count);
      if (n < 0) n = 0;
      if (n > LE_FX_MAX) n = LE_FX_MAX;
      fx_count[t][l] = n;
      /* The Pre/Post split (slice 3e). Clamped against the count read in this
       * same snapshot, because the two atomics are published by separate
       * stores and either order can be read torn: an over-long Pre run would
       * have the frame treat Post entries as printed and skip them. */
      int32_t pre = load_i32(&ln->a_fx_pre_count);
      if (pre < 0) pre = 0;
      if (pre > n) pre = n;
      fx_pre_count[t][l] = pre;
      const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
      for (int s = 0; s < n; ++s) {
        const int32_t ty = load_i32(&ln->a_fx_type[s]);
        fx_type[t][l][s] = ty;
        if (ty != LE_FX_NONE) has_fx[t][l] = 1;
        fx_enabled[t][l][s] = chain_on && load_i32(&ln->a_fx_enabled[s]);
        for (int p = 0; p < LE_FX_PARAMS; ++p) {
          fx_params[t][l][s][p] = load_f32(&ln->a_fx_param[s][p]);
        }
      }
      le_fx_chan_snapshot(ln->fx.chan, &ln->fx.chan_any, n, ln->a_fx_chan_in,
                          ln->a_fx_chan_out, ln->a_fx_chan_gl_bits,
                          ln->a_fx_chan_gr_bits, ln->a_fx_chan_level_bits);
      /* A slot the chain will NOT process this buffer (chain skipped, beyond
       * the active count, or LE_FX_NONE) cannot advance its enable ramp; if
       * its effective bit is 0, settle it to bypass now so a processing gap
       * never strands a ramp mid-fade — resumption then always re-enters
       * through fx_apply_chain's clean settled-edge reset [B7]. Enabled
       * slots keep their state (engaged effects have always persisted
       * across gaps). Audio-thread write to audio-owned DSP state. */
      for (int s = 0; s < LE_FX_MAX; ++s) {
        if (le_fx_enable_settled_bypassed(&ln->fx, s)) continue;
        const int unprocessed =
            !has_fx[t][l] || s >= n || fx_type[t][l][s] == LE_FX_NONE;
        if (unprocessed && !(chain_on && load_i32(&ln->a_fx_enabled[s]))) {
          le_fx_enable_force_bypass(&ln->fx, s);
        }
      }
    }
  }
}

/* Snapshots each hardware input's single live-monitor chain: the input-level
 * enable (gated by loopback exclusion) plus the chain's output mask / volume /
 * mute / effects — the monitor mirror of snapshot_lane_fx, one chain per input,
 * including the per-slot effective enable bits (D-EFFBITS). */
static inline void snapshot_monitor_fx(
    le_engine* e, int ch_in, uint32_t excluded, int* mon_on, uint32_t* mon_out,
    float* mon_vol, int* mon_mut, int32_t* mon_fx_count,
    int32_t mon_fx_type[][LE_FX_MAX],
    float mon_fx_params[][LE_FX_MAX][LE_FX_PARAMS],
    int32_t mon_fx_enabled[][LE_FX_MAX], int* mon_has_fx, float* mon_gl,
    float* mon_gr) {
  for (int c = 0; c < ch_in && c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_monitor_input* m = &e->monitors[c];
    mon_on[c] = load_i32(&m->a_enabled) && !(excluded & (1u << c));
    mon_out[c] = atomic_load_explicit(&m->a_output_mask, memory_order_relaxed);
    mon_vol[c] = load_f32(&m->a_vol_bits);
    mon_gl[c] = load_f32(&m->a_pan_gl_bits);
    mon_gr[c] = load_f32(&m->a_pan_gr_bits);
    mon_mut[c] = load_i32(&m->a_muted);
    mon_has_fx[c] = 0;
    int32_t n = load_i32(&m->a_fx_count);
    if (n < 0) n = 0;
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    mon_fx_count[c] = n;
    const int32_t chain_on = load_i32(&m->a_fx_chain_enabled);
    for (int s = 0; s < n; ++s) {
      const int32_t ty = load_i32(&m->a_fx_type[s]);
      mon_fx_type[c][s] = ty;
      if (ty != LE_FX_NONE) mon_has_fx[c] = 1;
      mon_fx_enabled[c][s] = chain_on && load_i32(&m->a_fx_enabled[s]);
      for (int p = 0; p < LE_FX_PARAMS; ++p) {
        mon_fx_params[c][s][p] = load_f32(&m->a_fx_param[s][p]);
      }
    }
    le_fx_chan_snapshot(m->fx.chan, &m->fx.chan_any, n, m->a_fx_chan_in,
                        m->a_fx_chan_out, m->a_fx_chan_gl_bits,
                        m->a_fx_chan_gr_bits, m->a_fx_chan_level_bits);
    /* Settle unprocessed disabled slots (see snapshot_lane_fx). The monitor
     * chain additionally stops running while the input is off or muted
     * (mix_monitors_frame), so those gaps are covered here too. */
    for (int s = 0; s < LE_FX_MAX; ++s) {
      if (le_fx_enable_settled_bypassed(&m->fx, s)) continue;
      const int unprocessed = !mon_on[c] || mon_mut[c] || !mon_has_fx[c] ||
                              s >= n || mon_fx_type[c][s] == LE_FX_NONE;
      if (unprocessed && !(chain_on && load_i32(&m->a_fx_enabled[s]))) {
        le_fx_enable_force_bypass(&m->fx, s);
      }
    }
  }
}

/* Snapshots one bus-stage chain owner (a track's Track-stage chain or the
 * Master insert, le_fx_bus) into the caller's arrays — the exact chain block
 * of snapshot_lane_fx / snapshot_monitor_fx for the new owners, including the
 * effective enable bits (D-EFFBITS) and the settle-unprocessed-disabled-slots
 * pass. *has_fx is the topology gate: FALSE when the chain is empty
 * (a_fx_count == 0, or every active entry is LE_FX_NONE), and D-TRACKROUTE
 * keys routing off exactly this bit — an empty chain must leave the
 * legacy path untouched (bit-identical), while enabled-ness only ever toggles
 * DSP inside fx_apply_chain, never topology. */
static inline void snapshot_bus_fx(le_fx_bus* b, int32_t* bus_fx_count,
                                   int32_t* bus_fx_pre_count,
                                   int32_t bus_fx_type[LE_FX_MAX],
                                   float bus_fx_params[LE_FX_MAX][LE_FX_PARAMS],
                                   int32_t bus_fx_enabled[LE_FX_MAX],
                                   int* bus_has_fx) {
  *bus_has_fx = 0;
  int32_t n = load_i32(&b->a_fx_count);
  if (n < 0) n = 0;
  if (n > LE_FX_MAX) n = LE_FX_MAX;
  *bus_fx_count = n;
  /* The Pre/Post split, clamped against the count read beside it — the lane
   * rule (slice 3e). Only the TRACK instance ever carries a non-zero one. */
  int32_t pre = load_i32(&b->a_fx_pre_count);
  if (pre < 0) pre = 0;
  if (pre > n) pre = n;
  *bus_fx_pre_count = pre;
  const int32_t chain_on = load_i32(&b->a_fx_chain_enabled);
  for (int s = 0; s < n; ++s) {
    const int32_t ty = load_i32(&b->a_fx_type[s]);
    bus_fx_type[s] = ty;
    if (ty != LE_FX_NONE) *bus_has_fx = 1;
    bus_fx_enabled[s] = chain_on && load_i32(&b->a_fx_enabled[s]);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      bus_fx_params[s][p] = load_f32(&b->a_fx_param[s][p]);
    }
  }
  le_fx_chan_snapshot(b->fx.chan, &b->fx.chan_any, n, b->a_fx_chan_in,
                      b->a_fx_chan_out, b->a_fx_chan_gl_bits,
                      b->a_fx_chan_gr_bits, b->a_fx_chan_level_bits);
  /* Settle unprocessed disabled slots (see snapshot_lane_fx): an empty bus
   * chain runs nothing at all, so every disabled slot's ramp settles here. */
  for (int s = 0; s < LE_FX_MAX; ++s) {
    if (le_fx_enable_settled_bypassed(&b->fx, s)) continue;
    const int unprocessed =
        !*bus_has_fx || s >= n || bus_fx_type[s] == LE_FX_NONE;
    if (unprocessed && !(chain_on && load_i32(&b->a_fx_enabled[s]))) {
      le_fx_enable_force_bypass(&b->fx, s);
    }
  }
}

/* The All tracks chain's DSP state is NOT its config block's `fx` — one
 * config drives one instance per output bus (slice 3e) — so its per-buffer
 * cache and its settled bypasses are applied to every instance here, after
 * snapshot_bus_fx has read the shared config. */
static inline void snapshot_all_tracks_instances(le_engine* e, int ch_out,
                                                 int32_t count, int has_fx,
                                                 const int32_t* fx_type) {
  le_fx_bus* b = &e->all_tracks;
  const int32_t chain_on = load_i32(&b->a_fx_chain_enabled);
  int bus_n = (ch_out + 1) / 2;
  if (bus_n > LE_MAX_OUTPUT_BUSES) bus_n = LE_MAX_OUTPUT_BUSES;
  for (int k = 0; k < bus_n; ++k) {
    le_fx_chan_snapshot(e->all_tracks_fx[k].chan, &e->all_tracks_fx[k].chan_any,
                        count, b->a_fx_chan_in, b->a_fx_chan_out,
                        b->a_fx_chan_gl_bits, b->a_fx_chan_gr_bits,
                        b->a_fx_chan_level_bits);
    for (int s = 0; s < LE_FX_MAX; ++s) {
      const int unprocessed =
          !has_fx || s >= count || fx_type[s] == LE_FX_NONE;
      if (unprocessed && !(chain_on && load_i32(&b->a_fx_enabled[s]))) {
        le_fx_enable_force_bypass(&e->all_tracks_fx[k], s);
      }
    }
  }
}

/* Snapshots every track's Track-stage chain (le_track.bus) — the per-track
 * fan-out of snapshot_bus_fx. trk_has_fx[t] false (the empty chain, the
 * default and the migration state) keeps mix_tracks_frame's per-lane routing
 * path bit-identical to today: the bus accumulator must not engage at all. */
static inline void snapshot_track_fx(
    le_engine* e, int tc, int32_t* trk_fx_count, int32_t* trk_fx_pre_count,
    int32_t trk_fx_type[][LE_FX_MAX],
    float trk_fx_params[][LE_FX_MAX][LE_FX_PARAMS],
    int32_t trk_fx_enabled[][LE_FX_MAX], int* trk_has_fx) {
  for (int t = 0; t < tc; ++t) {
    snapshot_bus_fx(&e->tracks[t].bus, &trk_fx_count[t], &trk_fx_pre_count[t],
                    trk_fx_type[t], trk_fx_params[t], trk_fx_enabled[t],
                    &trk_has_fx[t]);
  }
}

/* Per-buffer wet-cache snapshot (FX v3 part 2): loads each lane's published
 * entry ONCE (acquire) and re-derives the lane's current cache key —
 * {a_audio_rev [R1], chain fingerprint (params + enabled), a_vol_bits (D-VOL),
 * a_len} — accepting the entry only when EVERY field matches. cache_ent[t][l]
 * is the buffer-stable verdict the mix step consumes (NULL = play live). Any
 * mismatch clears the lane's audio-local cache_active flag right here, so an
 * edit falls back to live processing within the same buffer [B4] — the chain
 * re-enters through the enable machinery's clean settled-bypass re-enable
 * edge (reset + staggered ring clear + warmup + ramp [B7]), which is what
 * makes the fallback click-free while the documented tail-drop happens.
 * Cost when the cache is idle: one relaxed pointer load per lane. The
 * fingerprint recompute (le_lane_pre_fx_fingerprint — pure atomic loads +
 * FNV math, RT-safe) runs only while an entry is published. */
static inline void snapshot_lane_cache(
    le_engine* e, int tc, const int32_t* lane_n,
    const le_wet_entry* cache_ent[][LE_MAX_LANES]) {
  for (int t = 0; t < tc; ++t) {
    le_track* tr = &e->tracks[t];
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &tr->lanes[l];
      cache_ent[t][l] = NULL;
      const le_wet_entry* w =
          atomic_load_explicit(&ln->a_wet, memory_order_acquire);
      int ok = w != NULL;
      if (ok) {
        /* The full key check via the ONE shared predicate — with the
         * fingerprint term served from the audio-local verdict cache while
         * the lane's chain-edit generation (a_fx_gen) is unchanged, so a
         * cached steady state costs one relaxed load instead of a ~40-load
         * FNV refold per buffer. Any chain edit bumps the generation and
         * forces the full refold the same buffer. */
        const uint32_t rev =
            atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
        const uint32_t vol =
            atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed);
        const int32_t len = load_i32(&ln->a_len);
        const uint32_t gen =
            atomic_load_explicit(&ln->a_fx_gen, memory_order_relaxed);
        if (w == ln->cache_fp_entry && gen == ln->cache_fp_gen) {
          ok = le_wet_entry_key_matches(w, rev, w->chain_fp, vol, len);
        } else {
          ok = le_wet_entry_key_matches(
              w, rev, le_lane_pre_fx_fingerprint(e, t, l), vol, len);
          if (ok) { /* remember the passed fp verdict for this {entry, gen} */
            ln->cache_fp_entry = w;
            ln->cache_fp_gen = gen;
          }
        }
      }
      if (ok) {
        cache_ent[t][l] = w;
      } else if (load_i32(&ln->a_cache_active)) {
        store_i32(&ln->a_cache_active, 0); /* same-buffer live fallback [B4] */
      }
    }
  }
}

/* Each TRACK's whole-track print, checked once per buffer (slice 3e) — the
 * lane check's twin, with one deliberate difference: there is no verdict
 * memo. A track's key spans every part's chain, level, pan and mute as well
 * as its own Pre run, so a memo would need a generation bump on some fifteen
 * setters and a single missed one would play a render that no longer
 * describes the track. The refold is gated on a published entry instead, so a
 * track with no print — every track until something is put on its Pre run —
 * costs one relaxed load. */
static inline void snapshot_track_cache(le_engine* e, int tc,
                                        const le_wet_entry* track_ent[]) {
  for (int t = 0; t < tc; ++t) {
    le_track* tr = &e->tracks[t];
    track_ent[t] = NULL;
    const le_wet_entry* w =
        atomic_load_explicit(&tr->a_track_wet, memory_order_acquire);
    if (w == NULL) {
      if (load_i32(&tr->a_track_cache_active)) {
        store_i32(&tr->a_track_cache_active, 0);
      }
      continue;
    }
    const uint32_t rev =
        atomic_load_explicit(&tr->a_audio_rev, memory_order_acquire);
    /* Unity stands in for the volume term: every part's level is inside the
     * rendered combination, so there is no separate one to key on. */
    const int ok = le_wet_entry_key_matches(w, rev, le_track_pre_fingerprint(e, t),
                                            f32_to_bits(1.0f),
                                            load_i32(&tr->lanes[0].a_len));
    if (ok) {
      track_ent[t] = w;
    } else if (load_i32(&tr->a_track_cache_active)) {
      store_i32(&tr->a_track_cache_active, 0); /* same-buffer live fallback */
    }
  }
}

/* ---- per-frame core steps ----
 *
 * The fused heart of the per-frame loop, lifted into named steps. Each is
 * `static inline` and takes the per-block snapshot arrays (filled by the setup
 * steps above) plus the per-frame index, so the moved code is byte-identical to
 * the pre-S2 inline body — only the surrounding declarations became parameters. */

/* Per-frame input stage: input metering, sound-activated (input-level) record
 * firing, and the loopback latency harness. Returns 1 when the latency harness
 * owns this frame (it has written `out`; the caller must skip the rest of the
 * frame), else 0. */
/* ---- Chromatic tuner (LE_CMD_SET_TUNER_INPUT) ------------------------------
 *
 * Boxcar-decimate the armed input, run YIN over the decimated window, then
 * refine the coarse lag against a device-rate ring. Two structural rules keep
 * the whole thing off the callback's critical path, because the Tuner face
 * being open is an ordinary thing for a performer to do and a missed deadline
 * is an audible click:
 *
 * 1. NOTHING here is O(window) per frame. The device-rate ring is circular
 *    (see tuner_raw in engine_private.h); the decimated window still slides by
 *    a whole hop, but only once per hop.
 * 2. NO analysis runs to completion inside one callback. Both difference
 *    functions are resumable and are advanced by a per-frame budget
 *    (tuner_slice), so the ~184k serial double accumulates one detection costs
 *    at 96 kHz are spread over the ~30 blocks of its own hop instead of
 *    landing in one 333 us period.
 *
 * The needle sees the same numbers, roughly half a hop later — a pass is
 * 36-47% of its hop's budget, so ~10 ms at 96 kHz and ~16 ms at 48 kHz — on
 * top of the ~128 ms window the estimate already averages over. Against a
 * result consumed at a ~43 ms cadence that is invisible. */

/* Copies the tuner's device-rate ring into `out` (LE_TUNER_RAW floats), oldest
 * sample first — the contiguous chronological window the shifting FIFO used to
 * hand out directly. Returns 0, leaving `out` untouched, until the ring has
 * filled once. Audio thread; also the seam the ring's wrap is tested through. */
int le_tuner_raw_window(const le_engine* e, float* out) {
  if (e->tuner_raw_fill < LE_TUNER_RAW) return 0;
  /* Full, so the next write index is also the oldest sample. */
  const size_t head = (size_t)(LE_TUNER_RAW - e->tuner_raw_pos);
  memcpy(out, e->tuner_raw + e->tuner_raw_pos, sizeof(float) * head);
  if (e->tuner_raw_pos > 0) {
    memcpy(out + head, e->tuner_raw, sizeof(float) * (size_t)e->tuner_raw_pos);
  }
  return 1;
}

static inline void tuner_publish(le_engine* e, float hz, float conf) {
  store_f32(&e->a_tuner_hz_bits, hz);
  store_f32(&e->a_tuner_conf_bits, conf);
}

/* Refines a coarse period (in DEVICE-rate samples) against the frozen
 * device-rate window, by walking the plain difference function over a narrow
 * window of lags around it and interpolating the minimum.
 *
 * Plain difference rather than YIN's normalized form: the octave decision has
 * already been made by the coarse pass, and cumulative-mean normalization
 * exists to make that decision. All this pass has to do is locate a minimum it
 * is already sitting next to.
 *
 * Declines (begin returns 0, and the caller publishes the coarse estimate)
 * when the lag is too long for the ring to hold enough of it — which is the
 * low end, where the coarse estimate is already sub-cent. */
static int tuner_refine_begin(le_tuner_pass* p) {
  const int n = LE_TUNER_RAW;
  const int lo = (int)p->coarse - LE_TUNER_DECIM;
  const int hi = (int)p->coarse + LE_TUNER_DECIM + 1;
  if (lo < 2 || hi >= n / 2) return 0;
  const int integ = n - hi;
  if (integ < hi) return 0; /* fewer than two periods: not worth it */
  p->lo = lo;
  p->hi = hi;
  p->integ = integ;
  p->tau = lo;
  p->best = 0;
  return 1;
}

/* Accumulates lags until at least `budget` inner iterations are spent (one
 * whole lag always runs). Returns 1 once every lag is in. */
static int tuner_refine_step(le_tuner_pass* p, long budget) {
  const float* x = p->raw;
  while (p->tau <= p->hi) {
    const int tau = p->tau;
    double sum = 0.0;
    for (int i = 0; i < p->integ; ++i) {
      const float df = x[i] - x[i + tau];
      sum += (double)df * (double)df;
    }
    const int k = tau - p->lo;
    p->d[k] = (float)sum;
    if (tau == p->lo || p->d[k] < p->d[p->best]) p->best = k;
    ++p->tau;
    budget -= p->integ;
    if (budget <= 0) break;
  }
  return p->tau > p->hi;
}

/* Interpolates the completed refinement's minimum, or hands back the coarse
 * period when the minimum sits on an edge of the searched band. */
static float tuner_refine_finish(const le_tuner_pass* p) {
  if (p->best == 0 || p->best == p->hi - p->lo) return p->coarse;
  const float s0 = p->d[p->best - 1];
  const float s1 = p->d[p->best];
  const float s2 = p->d[p->best + 1];
  const float denom = s0 + s2 - 2.0f * s1;
  float refined = (float)(p->lo + p->best);
  if (fabsf(denom) > 1e-9f) refined += 0.5f * (s0 - s2) / denom;
  return refined;
}

/* Starts a detection at a hop boundary: freezes both analysis windows (the
 * live ones keep moving under a pass that outlives this block) and opens the
 * coarse YIN pass. A window the detector declines — silence, or a band the
 * window is too short for — is settled here and now: "no pitch this frame" is
 * published as 0 Hz rather than held, because the UI decides how long to keep
 * showing the last good note and it cannot make that call if the engine hides
 * the gaps. */
static void tuner_begin(le_engine* e, int sr, int sr_d) {
  le_tuner_pass* p = &e->tuner_pass;
  p->sr = sr;
  memcpy(p->win, e->tuner_win, sizeof(p->win));
  if (!le_yin_begin(&p->yin, p->win, LE_TUNER_WIN, sr_d, LE_TUNER_MIN_HZ,
                    LE_TUNER_MAX_HZ, p->dp,
                    (int)(sizeof(p->dp) / sizeof(p->dp[0])))) {
    tuner_publish(e, 0.0f, 0.0f);
    return; /* stays IDLE: the next hop starts a fresh pass */
  }
  /* After le_yin_begin, not before: an armed tuner pointed at a silent input
   * takes the silence-floor early-out above, and freezing the device-rate ring
   * for it would be 8 KB of memcpy per hop that nothing ever reads. The freeze
   * instant is still this frame, so the refinement sees the same audio it
   * would have. le_yin_begin reads p->win only. */
  p->raw_valid = le_tuner_raw_window(e, p->raw);
  p->phase = LE_TUNER_PHASE_COARSE;
}

/* Peak-picks the finished coarse pass and either hands over to the refinement
 * or publishes the coarse estimate as it stands. */
static void tuner_coarse_done(le_engine* e) {
  le_tuner_pass* p = &e->tuner_pass;
  float period = 0.0f;
  le_yin_finish(&p->yin, &period, &p->conf);
  if (period <= 0.0f) {
    /* (0 Hz, 0 conf) is what "no pitch" looks like everywhere else in this
     * pipeline — tuner_begin's rejection publishes exactly that. Carrying
     * p->conf through here would emit a (0 Hz, conf > 0) pair nothing else
     * produces and no reader expects. Very nearly unreachable, since
     * tau >= minlag >= 2; le_yin_finish's parabolic step only guards
     * fabsf(denom) > 1e-9f, so a near-flat dp triple could still take it. */
    tuner_publish(e, 0.0f, 0.0f);
    p->phase = LE_TUNER_PHASE_IDLE;
    return;
  }
  /* The coarse period is in decimated samples; the refinement works at the
   * device rate, so scale before handing it over and divide by the device rate
   * on the way out. */
  p->coarse = period * (float)LE_TUNER_DECIM;
  if (!p->raw_valid || !tuner_refine_begin(p)) {
    tuner_publish(e, (float)p->sr / p->coarse, p->conf);
    p->phase = LE_TUNER_PHASE_IDLE;
    return;
  }
  p->phase = LE_TUNER_PHASE_REFINE;
}

/* One block's worth of detection work: LE_TUNER_WORK_PER_FRAME inner
 * iterations per device frame, spent on whichever phase the in-flight pass is
 * in and carried across the coarse -> refine handover so a block is never left
 * half idle. Returns with the pass suspended mid-lag-loop; the next block
 * resumes it. */
static void tuner_slice(le_engine* e, uint32_t frames) {
  le_tuner_pass* p = &e->tuner_pass;
  long budget = (long)frames * LE_TUNER_WORK_PER_FRAME;
  while (budget > 0 && p->phase != LE_TUNER_PHASE_IDLE) {
    if (p->phase == LE_TUNER_PHASE_COARSE) {
      const int32_t was = p->yin.tau;
      const int done = le_yin_step(&p->yin, budget);
      budget -= (long)(p->yin.tau - was) * p->yin.integ;
      if (!done) return;
      tuner_coarse_done(e);
    } else {
      const int32_t was = p->tau;
      const int done = tuner_refine_step(p, budget);
      budget -= (long)(p->tau - was) * p->integ;
      if (!done) return;
      tuner_publish(e, (float)p->sr / tuner_refine_finish(p), p->conf);
      p->phase = LE_TUNER_PHASE_IDLE;
    }
  }
}

/* Called once per block, and the first line is the whole cost when nothing is
 * armed.
 *
 * A boxcar of exactly LE_TUNER_DECIM is both the decimator and its own
 * anti-alias filter: its frequency response nulls at multiples of the
 * decimated rate, which is precisely where aliasing would fold in from. */
static void tuner_tap_block(le_engine* e, const float* in, uint32_t frames,
                            int ch_in, int sr) {
  const int32_t input = load_i32(&e->a_tuner_input);
  const int sr_d = sr / LE_TUNER_DECIM;
  /* Any block this function declines to tap is a gap in the analysis window.
   * A pass frozen across one would resume and publish a pitch derived entirely
   * from audio captured before the gap — arithmetically valid, silently
   * stale. Cheaper to abandon it and let the next hop start a fresh one: the
   * point of the slicing is that a pass costs one hop, not that any particular
   * pass has to survive. */
  if (input < 0 || input >= ch_in || in == NULL || sr_d <= LE_TUNER_MIN_HZ) {
    e->tuner_pass.phase = LE_TUNER_PHASE_IDLE;
    return;
  }
  /* Belt-and-braces: a device-rate change invalidates a frozen pass, since its
   * window was captured at the old rate and both the lag geometry and the
   * published Hz derive from it. Unreachable today — le_engine_configure
   * stores a_tuner_input = -1 and le_engine_start always calls it, so any
   * device (re)open disarms the tuner, and re-arming resets phase to IDLE —
   * but the check costs one comparison and what it prevents is a wrong
   * published pitch. */
  if (e->tuner_pass.phase != LE_TUNER_PHASE_IDLE && e->tuner_pass.sr != sr) {
    e->tuner_pass.phase = LE_TUNER_PHASE_IDLE;
  }

  for (uint32_t f = 0; f < frames; ++f) {
    const float raw = in[f * (uint32_t)ch_in + (uint32_t)input];

    /* Device-rate ring, kept in step with the decimated one so a detection
     * always has the same audio available at both rates. One store, no shift:
     * le_tuner_raw_window untangles the wrap for the reader. */
    e->tuner_raw[e->tuner_raw_pos] = raw;
    if (++e->tuner_raw_pos >= LE_TUNER_RAW) e->tuner_raw_pos = 0;
    if (e->tuner_raw_fill < LE_TUNER_RAW) ++e->tuner_raw_fill;

    e->tuner_acc += raw;
    if (++e->tuner_acc_n < LE_TUNER_DECIM) continue;
    const float s = e->tuner_acc / (float)LE_TUNER_DECIM;
    e->tuner_acc = 0.0f;
    e->tuner_acc_n = 0;

    if (e->tuner_fill < LE_TUNER_WIN) e->tuner_win[e->tuner_fill++] = s;
    if (e->tuner_fill < LE_TUNER_WIN) continue;

    /* Hop boundary. A pass still in flight keeps the window it froze and this
     * hop simply does not start one; it would cost nothing but one skipped
     * refresh, and no supported period reaches it. Two independent things
     * have to hold for that, and only the first is about the budget:
     *
     *   - a pass must finish within the hop it started in. tuner_slice gets
     *     LE_TUNER_WORK_PER_FRAME per device frame and a hop is
     *     LE_TUNER_HOP * LE_TUNER_DECIM = 2048 frames, so a hop is worth ~393k
     *     iterations against a worst-case pass of ~184k — the ~2x headroom
     *     LE_TUNER_WORK_PER_FRAME is chosen for. This holds at any block size,
     *     since the budget is per frame.
     *   - a block must not span two hop boundaries. tuner_slice runs ONCE per
     *     block, after this loop, but hops are counted per frame inside it: a
     *     block longer than 2048 frames would cross two boundaries with no
     *     slice in between — so the second would find the first's pass still
     *     in flight and skip it however large the budget is. Raising the
     *     budget would NOT buy headroom here; only a hop longer than the
     *     block does. No shipped path negotiates a period that large: the
     *     generic chooser offers [64, 128, 256, 512] (bufferSizes in
     *     audio_setup_state.dart) and an ASIO driver substitutes its own
     *     list, but none of them lands above a hop. If one ever did, the
     *     single consequence is that the needle refreshes every second hop
     *     instead of every hop — ~86 ms rather than ~43 ms, still far finer
     *     than a needle needs to look continuous. Nothing is wrong, only
     *     coarser. */
    if (e->tuner_pass.phase == LE_TUNER_PHASE_IDLE) tuner_begin(e, sr, sr_d);

    /* Slide by one hop, so the next detect costs one memmove rather than one
     * per decimated sample. */
    memmove(e->tuner_win, e->tuner_win + LE_TUNER_HOP,
            sizeof(float) * (size_t)(LE_TUNER_WIN - LE_TUNER_HOP));
    e->tuner_fill = LE_TUNER_WIN - LE_TUNER_HOP;
  }

  tuner_slice(e, frames);
}

static inline int process_input_frame(le_engine* e, const float* in,
                                      const float* in_c, float* out, uint32_t f,
                                      int ch_in, int ch_out, int tc,
                                      int sr, uint32_t excluded, float* in_sumsq,
                                      float* in_peak, float* in_peak_ch,
                                      float* out_sumsq,
                                      uint64_t perf_frame_base) {
  float frame_mag = 0.0f; /* max |input| over real (non-loopback) channels */
  float loop_mag = 0.0f;  /* max |input| over loopback channels (latency tap) */
  for (int c = 0; c < ch_in; ++c) {
    const float s = in ? in[f * ch_in + c] : 0.0f;
    const float a = fabsf(s);
    if (excluded & (1u << c)) {
      /* Loopback channels carry our own output back; not recorded/monitored/
       * metered, but they are the round-trip path the latency harness times. */
      if (a > loop_mag) loop_mag = a;
      continue;
    }
    if (a > frame_mag) frame_mag = a;
    if (a > in_peak_ch[c]) in_peak_ch[c] = a;
    *in_sumsq += s * s;
  }
  if (frame_mag > *in_peak) *in_peak = frame_mag;

  /* Signal arms listen only to their selected, real recording sources. Input
   * conditioning precedes this buffer; meters/latency above remain raw. Never
   * substitute input zero when a route disappears. Cancellation remains a
   * control action even when no selected source is currently usable. */
  for (int qt = 0; qt < tc; ++qt) {
    le_track* t = &e->tracks[qt];
    if (!t->pending_record || t->pending_trigger != 1) continue;
    float magnitude = 0.0f;
    for (int l = 0; l < le_lanes_active(t); ++l) {
      const int source = load_i32(&t->lanes[l].a_input_channel);
      if (source < 0 || source >= ch_in || source >= 32 ||
          (excluded & (1u << source))) continue;
      const float value = in_c ? fabsf(in_c[f * ch_in + source]) : 0.0f;
      if (value > magnitude) magnitude = value;
    }
    if (magnitude > LE_AUTO_RECORD_THRESHOLD) {
      t->pending_record = 0;
      t->pending_trigger = 0;
      store_i32(&t->a_pending, 0);
      handle_record(e, qt, perf_frame_base + f);
    }
  }

  /* The latency pulse returns on the loopback channels when the interface has
   * them (e.g. a Scarlett's "Loop 1/2"); otherwise (a physical cable, or a
   * routed loopback capture device) it returns on the normal inputs. */
  const float lat_mag = excluded != 0u ? loop_mag : frame_mag;

  /* Latency harness takes over the output entirely while measuring. It emits a
   * quiet ~10 ms pulse at the start of a fixed capture window, records the
   * input-magnitude envelope across that window, then cross-correlates it with
   * the pulse to find the round-trip by the correlation peak (le_latency_resolve).
   * The peak — integrated over the whole pulse — locks onto the real echo and
   * ignores the brief direct/crosstalk bleed a first-over-threshold test
   * mis-reported (especially on low-latency JACK graphs). */
  if (e->lat_active) {
    float broadcast = 0.0f;
    if (e->lat_emit_remaining > 0) {
      /* A tone burst (not a DC level): AC-coupled interface inputs high-pass a
       * constant pulse down to edge transients, leaving nothing to correlate.
       * A 1 kHz burst returns as a sustained AC signal. */
      const int32_t emitted =
          (sr / LE_LATENCY_PULSE_DIV) - e->lat_emit_remaining;
      const float phase = 2.0f * 3.14159265f * LE_LATENCY_TONE_HZ *
                          (float)emitted / (float)sr;
      broadcast = LE_LATENCY_PULSE_AMP * sinf(phase);
      e->lat_emit_remaining--;
    }
    if (e->lat_buf != NULL && e->lat_buf_pos < e->lat_buf_cap) {
      e->lat_buf[e->lat_buf_pos++] = lat_mag;
    }
    /* Resolve on the same frame the window fills (not the next): the two
     * conditions overlap on the fill frame, so this is intentionally not an
     * `else`. */
    if (e->lat_buf == NULL || e->lat_buf_pos >= e->lat_buf_cap) {
      le_latency_resolve(e, sr);
      e->lat_active = 0;
      /* No monitor enable state to restore: the measurement never touched
       * a_enabled (see the LE_CMD_MEASURE_LATENCY comment). Monitoring resumes
       * on its own now that lat_active is clear and the per-frame mix — which
       * the pulse path bypassed — runs again. */
    }
    for (int c = 0; c < ch_out; ++c) {
      out[f * ch_out + c] = broadcast;
      *out_sumsq += broadcast * broadcast;
    }
    return 1;
  }
  return 0;
}

/* Per-frame live monitoring: each enabled hardware input runs its clean live
 * sample through its single (stageless) effect chain at its volume and sums into
 * the outputs its mask selects — an empty chain routes the clean sample (the dry
 * path), an FX chain its processed signal (stereo-aware: a reverb spreads across
 * the first two masked outputs). [out_enabled] is the structural output gate,
 * intersected with the mask so a disabled output is never a target. Live and
 * independent of every track; never recorded. Effects run every frame so delay
 * tails / LFO phase stay continuous. */
static inline void mix_monitors_frame(
    le_engine* e, const float* in, float* out, uint32_t f, int ch_in, int ch_out,
    int sr, int fx_cap, uint32_t out_enabled, const int* mon_on,
    const int* mon_mut, const int* mon_has_fx, const int32_t* mon_fx_count,
    int32_t mon_fx_type[][LE_FX_MAX],
    float mon_fx_params[][LE_FX_MAX][LE_FX_PARAMS],
    int32_t mon_fx_enabled[][LE_FX_MAX], const float* mon_vol,
    const uint32_t* mon_out, const float* mon_gl, const float* mon_gr,
    float* mon_peak) {
  if (in) {
    for (int c = 0; c < ch_in && c < LE_MAX_MONITORED_INPUTS; ++c) {
      const int captured =
          e->perf.armed && (e->perf.input_mask & (1u << c)) != 0;
      if (!mon_on[c] || mon_mut[c]) {
        if (captured) perf_tap_monitor_frame(e, c, 0.0f, 0.0f);
        continue;
      }
      const float clean = in[f * ch_in + c];
      float ml = clean;
      float mr = clean;
      if (mon_has_fx[c]) {
        fx_apply_chain(&e->monitors[c].fx, sr, fx_cap, &ml, &mr, mon_fx_count[c],
                       mon_fx_type[c], mon_fx_params[c], mon_fx_enabled[c]);
      }
      ml *= mon_vol[c] * mon_gl[c];
      mr *= mon_vol[c] * mon_gr[c];
      if (captured) perf_tap_monitor_frame(e, c, ml, mr);
      const uint32_t routed = mon_out[c] & out_enabled;
      le_fx_route(out, f, ch_out, routed, ml, mr);
      if (routed) {
        const float ma = fabsf(ml) > fabsf(mr) ? fabsf(ml) : fabsf(mr);
        if (ma > mon_peak[c]) mon_peak[c] = ma;
      }
    }
  }
}

/* Free/Song mode (B2b, broadened to SONG by B4): fills the per-track
 * effective read position / clock length for one frame. Every entry
 * defaults to the shared master's own (pos, e->clock.length) — Multi/Sync/
 * Band's exact values — so a caller that never invokes this (every mode but
 * Free/Song) stays byte-for-byte on the master path; within Free/Song mode,
 * a track whose own clock isn't established yet (still on its first/
 * defining recording) also keeps the default, which is moot —
 * mix_tracks_frame never reads trk_pos/trk_len for a RECORDING track (see
 * rec_w, below). Single guarded call from mix_tracks_frame, mirroring
 * advance_track_clock_frame's per-track scoping above but for the READ side
 * (this does not advance anything; le_engine_process calls it before
 * advance_transport_frame ticks free_clock, so it reads this frame's
 * pre-advance position — exactly like `pos` itself). */
static inline void free_track_positions_frame(le_engine* e, int tc,
                                              int32_t* trk_pos,
                                              int32_t* trk_len) {
  for (int t = 0; t < tc; ++t) {
    const le_loop_clock* c = &e->tracks[t].free_clock;
    if (c->length <= 0) continue; /* not yet established: keep the default */
    trk_pos[t] = c->position;
    trk_len[t] = c->length;
  }
}

/* Sync/Band division read (B3, D16): overrides trk_pos[t]/trk_len[t] for
 * every track [t] with an active division (a_sync_divisor > 0) — the
 * "generalized phase within primary" the seg_base/multiple math (in
 * mix_tracks_frame, below) cannot express, since a division's OWN buffer is
 * SHORTER than the base loop, not a multiple of it. trk_len[t] is
 * e->clock.length / divisor (le_sync_quantize_active guarantees the primary
 * is exactly one base loop whenever a division was created, so no separate
 * lookup is needed); trk_pos[t] is `pos % trk_len[t]`, folding the
 * primary's CURRENT phase into the division's own shorter cycle.
 *
 * base / divisor is an EXACT integer division with NO remainder here —
 * adversarial-review BUG 2 fix: le_sync_choose_ratio (finalize_new_track)
 * now only ever publishes a divisor that tiles the primary's length
 * exactly (base % divisor == 0), stepping down (4 -> 2) or falling back to
 * an ordinary multiple otherwise, rather than this function's old
 * `llround(base / n)` — which, whenever the primary's length wasn't evenly
 * divisible by n (the ORDINARY case for a freely-recorded primary, not a
 * rare edge case), silently repeated or skipped one buffer index every
 * single cycle: an audible, permanent stutter. With base % divisor == 0
 * guaranteed on write, `pos % trk_len[t]` now tiles PROVABLY exactly:
 * over one full primary cycle (pos sweeping 0..base-1), it visits every
 * one of the divisor's own trk_len[t] indices exactly `divisor` times,
 * with no repeats and no skips, for any pos — not just at pos == 0.
 *
 * Deliberately anchored to `pos` (the primary's live phase), not a running
 * iteration/segment count like the multiple path's seg_base: whenever pos
 * == 0 (the primary's loop top), pos % trk_len[t] == 0 too, for ANY
 * trk_len[t] > 0 — so a division track's own loop-top ALWAYS coincides
 * with the primary's, on every primary cycle, regardless of how many times
 * either has wrapped. A half-length division therefore completes exactly 2
 * of its own loops per 1 primary loop, phase-aligned at the start — the
 * behavior a musician expects from a half-length loop layered under a
 * full-length one. (seg_base itself already reads 0 for these tracks with
 * no changes needed: finalize_new_track sets a_multiple to 1 for a
 * division, so the existing `seg = (iter - start_iter) % 1` collapses to 0
 * unconditionally.)
 *
 * Per-track, not mode-gated (mirrors free_track_positions_frame's shape but
 * checks per-track state instead of a single outer mode flag): a_sync_
 * divisor is only ever set nonzero by finalize_new_track under le_sync_
 * quantize_active, which requires SYNC/BAND, so this is mutually exclusive
 * with Free mode's own per-track free_clock by construction — cheap
 * (a single comparison) on every track that isn't a division. */
static inline void sync_division_positions_frame(le_engine* e, int tc,
                                                  int32_t pos,
                                                  int32_t* trk_pos,
                                                  int32_t* trk_len) {
  const int32_t base = e->clock.length;
  if (base <= 0) return;
  for (int t = 0; t < tc; ++t) {
    const int32_t n = load_i32(&e->tracks[t].a_sync_divisor);
    if (n < 2) continue;
    const int32_t len = base / n; /* exact: le_sync_choose_ratio guarantees
                                    * base % n == 0 for every divisor it
                                    * ever publishes */
    if (len < 1) continue; /* defensive; unreachable given the guarantee */
    trk_len[t] = len;
    trk_pos[t] = pos % len;
  }
}

/* Per-frame capture + additive playback mix: snapshots each track's per-lane
 * playback state, records / overdubs the live input into the lane buffers at the
 * latency-compensated write head, and sums every audible lane (through its
 * effect chain) into `out`. Fills [st] (the per-track state snapshot the
 * transport advance reads) and accumulates [frame_trk_peak] (per-track) and the
 * [lane_sumsq] / [lane_peak] metering. [pos] is the playhead (read by the caller
 * before the transport advances). */
static inline void mix_tracks_frame(
    le_engine* e, const float* in, float* out, uint32_t f, int ch_in,
    int ch_out, int tc, int sr, int fx_cap, uint32_t excluded,
    uint32_t out_enabled, float overdub_fb,
    float od_step, int32_t od_fade_frames, int32_t pos, const int32_t* lane_n,
    const int* lane_fx_any,
    int has_fx[][LE_MAX_LANES], int32_t fx_count[][LE_MAX_LANES],
    int32_t fx_pre_count[][LE_MAX_LANES],
    int32_t fx_type[][LE_MAX_LANES][LE_FX_MAX],
    float fx_params[][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS],
    int32_t fx_enabled[][LE_MAX_LANES][LE_FX_MAX], const int* trk_has_fx,
    const int32_t* trk_fx_count, int32_t trk_fx_type[][LE_FX_MAX],
    float trk_fx_params[][LE_FX_MAX][LE_FX_PARAMS],
    int32_t trk_fx_enabled[][LE_FX_MAX], const int32_t* trk_fx_pre_count,
    const le_wet_entry* track_cache_ent[], int at_has_fx, int32_t at_fx_count,
    const int32_t* at_fx_type,
    const float at_fx_params[LE_FX_MAX][LE_FX_PARAMS],
    const int32_t* at_fx_enabled,
    const le_wet_entry* cache_ent[][LE_MAX_LANES],
    float lane_sumsq[][LE_MAX_LANES], float lane_peak[][LE_MAX_LANES],
    int32_t* st, float* frame_trk_peak, float* trk_sumsq, float* trk_peak,
    float* trk_lpeak, float* trk_rpeak, const float* in_trim, const int* solo,
    int any_solo, uint64_t perf_frame_base) {
  /* The All tracks recorded-mix stage (slice 3e). While the chain has
   * something on it the tracks route HERE instead of straight to `out`, and
   * the loop after the track loop runs the chain once per output bus over
   * that bus's recorded contribution before adding it in. An empty chain
   * skips all of it and the routing path stays bit-identical to the
   * pre-slice-3e engine (topology keys off emptiness, like the track bus).
   *
   * The scratch is per FRAME, not per block: the stage runs inside this
   * frame, so nothing needs to outlive it. */
  float rec[LE_MAX_CHANNELS];
  if (at_has_fx) {
    for (int c = 0; c < ch_out && c < LE_MAX_CHANNELS; ++c) rec[c] = 0.0f;
  }

  /* Capture the callback-owned live selection for this frame. Record/arm
   * and transport transitions can occur within a block; Undo publishes its
   * source-image selection through the same callback owner. */
  float* buf[LE_MAX_TRACKS][LE_MAX_LANES];
  /* The pointer and allocated capacity describe the same live pool slot.
   * Control preparation never replaces a slot the callback may still read:
   * active/inactive lane changes wait for the structural command's final
   * end-of-block acknowledgment, capture preparation excludes active writers,
   * and retired slots return through the event handoff. A revision detects
   * changed content; it does not provide this buffer-lifetime guarantee. */
  int32_t cap[LE_MAX_TRACKS][LE_MAX_LANES];
  float vol[LE_MAX_TRACKS][LE_MAX_LANES];
  float pan_gl[LE_MAX_TRACKS][LE_MAX_LANES];
  float pan_gr[LE_MAX_TRACKS][LE_MAX_LANES];
  int mut[LE_MAX_TRACKS][LE_MAX_LANES];
  int32_t lane_in[LE_MAX_TRACKS][LE_MAX_LANES];
  uint32_t out_mask[LE_MAX_TRACKS][LE_MAX_LANES];

  /* IDLE TRACK SKIP. An EMPTY or STOPPED track's lane body is provably a
   * no-op: it never enters the RECORDING / OVERDUBBING / PLAYING write
   * branches, so `loopsample` is 0; `audible` is false, so nothing is routed
   * and nothing lands on the track bus; and the meters it feeds (lane_peak,
   * lane_sumsq, frame_trk_peak, trk_mix) all fold that same 0. Running it
   * anyway cost six relaxed atomic loads plus the whole body PER LANE PER
   * FRAME — 7.4 ns a lane, so 49 empty lanes burned ~7 us of a 333 us
   * callback. Both the snapshot loop below and the lane loop skip together
   * (they are the only readers of buf/cap/vol/mut/lane_in/out_mask, so a
   * skipped track's entries are simply never read).
   *
   * THE THREE THINGS THAT STILL HAVE TO RUN, and why each is excluded here:
   *  - The #728 seam capture (`lbuf[seam_w] = insample`) writes on a track
   *    whose state has ALREADY returned to PLAYING/STOPPED, so state alone is
   *    not enough: seam_capture > 0 keeps the track out of the skip.
   *  - An effect chain must keep ticking on silence (delay tails, LFO phase),
   *    which is the documented run-on-silence rule; lane_fx_any keeps any
   *    track holding one out of the skip. (The TRACK-stage chain and its
   *    a_recoverable / meter publishing all live OUTSIDE the lane loop and
   *    are untouched by this.)
   *  - od_gain is the punch-out tail. It can only drive a write from inside
   *    the OVERDUBBING/PLAYING branch, which an EMPTY/STOPPED track cannot
   *    reach — but it is checked anyway so the skip stays provable from the
   *    guard alone. It is read one frame stale (this loop runs before the
   *    envelope advances below), which is safe in the only direction that
   *    matters: od_gain rises only while OVERDUBBING, a state that is not
   *    skippable, so a stale read can hold a track OUT of the skip but never
   *    let a writing one in. */
  int idle[LE_MAX_TRACKS];
  int32_t live_idx[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    st[t] = load_i32(&e->tracks[t].a_state);
    /* The edge out of sounding, wherever it came from — a stop press, a
     * finalize, a clear, a Cut. "Printed Pre stops with its recording", so
     * each lane's Pre slots lose their tails here while its Post slots keep
     * theirs and drain. One compare per track per frame; the clear itself
     * only runs on the edge, and only over slots that carry a tail. */
    if ((st[t] == LE_TRACK_STOPPED || st[t] == LE_TRACK_EMPTY) &&
        e->tracks[t].proc_prev_state != st[t]) {
      for (int l = 0; l < lane_n[t]; ++l) {
        if (fx_pre_count[t][l] <= 0) continue;
        le_lane* pl = &e->tracks[t].lanes[l];
        le_fx_state_clear_tails_range(&pl->fx, pl->a_fx_type, 0,
                                      fx_pre_count[t][l], fx_cap);
      }
      /* The track's own Pre run is part of the take in the same way, so its
       * tails stop with the recording too — printed or live. Its Post run is
       * untouched and drains. */
      if (trk_fx_pre_count[t] > 0) {
        le_fx_state_clear_tails_range(&e->tracks[t].bus.fx,
                                      e->tracks[t].bus.a_fx_type, 0,
                                      trk_fx_pre_count[t], fx_cap);
      }
    }
    e->tracks[t].proc_prev_state = st[t];
    /* trk_has_fx keeps a track with a TRACK-stage chain out of the skip. The
     * chain itself runs outside this loop either way, but bus_mask is built
     * INSIDE it — so a skipped track routes its own tail to nothing, and a
     * Stop would silence a Post reverb that the accepted tail contract says
     * drains. The lane-chain clause below covers a track whose PARTS carry
     * chains; this covers the canonical whole-track case, where the parts are
     * plain and every effect sits on the track. */
    idle[t] = (st[t] == LE_TRACK_EMPTY || st[t] == LE_TRACK_STOPPED) &&
              !lane_fx_any[t] && !trk_has_fx[t] &&
              e->tracks[t].seam_capture == 0 && e->tracks[t].od_gain == 0.0f;
    /* Lane 0's live slot, loaded ONCE for this frame and shared by the mixer
     * below and the capture-provenance tracker further down (#1143): the fact
     * must name the slot this very frame mixes, never a swap published between
     * two loads. Acquire pairs with le_track_publish_live's release so the
     * perf.slot_image entry stored before the publish is visible. Loaded for
     * idle (STOPPED) tracks too: a swap under STOPPED is logged as a silent
     * source change, then followed through Play by 323. */
    live_idx[t] = atomic_load_explicit(&e->tracks[t].lanes[0].a_live,
                                       memory_order_acquire);
    if (idle[t]) continue;
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      const int32_t live = l == 0 ? live_idx[t] : load_i32(&ln->a_live);
      buf[t][l] = ln->pool[live];
      cap[t][l] = ln->pool_cap[live];
      vol[t][l] = load_f32(&ln->a_vol_bits);
      pan_gl[t][l] = load_f32(&ln->a_pan_gl_bits);
      pan_gr[t][l] = load_f32(&ln->a_pan_gr_bits);
      mut[t][l] = load_i32(&ln->a_muted);
      lane_in[t][l] = load_i32(&ln->a_input_channel);
      out_mask[t][l] =
          atomic_load_explicit(&ln->a_output_mask, memory_order_relaxed);
    }
  }
#ifdef LE_NATIVE_TESTS
  if (le_test_fade_hook) le_test_fade_hook(e, 5);
#endif
  /* Latency compensation: captured input is recorded this many frames earlier so
   * it aligns with what the player heard. Monitoring stays live (it is no longer
   * folded into the loop buffer at the playhead). */
  const int32_t offset = load_i32(&e->a_record_offset);

  /* Per-track read base for this frame: a track of multiple k plays its k-th
   * base-loop segment, cycling relative to where its recording began. k == 1
   * (the common case) collapses to the master position. */
  int32_t seg_base[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    if (e->clock.length > 0) {
      int32_t k = load_i32(&e->tracks[t].a_multiple);
      if (k < 1) k = 1;
      const uint64_t seg =
          (e->loop_iteration - e->tracks[t].start_iter) % (uint64_t)k;
      seg_base[t] = (int32_t)seg * e->clock.length;
    } else {
      seg_base[t] = 0;
    }
  }

  /* Free/Song mode (B2b, broadened to SONG by B4): each track with its own
   * established clock reads/writes at ITS OWN position and against ITS OWN
   * length below, not the shared master's — single guarded call
   * (free_track_positions_frame) so this is the only place mix_tracks_frame
   * diverges from the Multi/Sync/Band path; every trk_pos[t]/trk_len[t]
   * entry equals pos/e->clock.length verbatim whenever the call is skipped
   * (mode is neither FREE nor SONG) or a specific track's own clock isn't
   * established yet, so the per-track loop below is byte-for-byte the
   * master path in every case but an active Free/Song-mode track. */
  int32_t trk_pos[LE_MAX_TRACKS];
  int32_t trk_len[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    trk_pos[t] = pos;
    trk_len[t] = e->clock.length;
  }
  {
    const int32_t mode = load_i32(&e->a_looper_mode);
    if (mode == LE_LOOPER_MODE_FREE || mode == LE_LOOPER_MODE_SONG) {
      free_track_positions_frame(e, tc, trk_pos, trk_len);
    }
  }
  /* Sync/Band divisions (B3): per-track, so this always runs (mutually
   * exclusive with Free mode's per-track override above by construction —
   * see sync_division_positions_frame's doc). */
  sync_division_positions_frame(e, tc, pos, trk_pos, trk_len);
  /* A track reading from its own origin (an automatic-end relaunch) or in
   * its own direction (Reverse, #1162) rewrites the pair from its read index.
   * Keeping the (seg_base, trk_pos) representation means live/cached PCM,
   * metering, the print engage edges and trk_play_pos all follow without
   * further edits. A forward track with a parked origin keeps the master
   * path byte-identical. Fresh recording never uses it.
   *
   * turn_old[t] is the pre-turn head's index while a Reverse turn is still
   * mixing (-1 otherwise) and turn_x[t] the new head's equal-gain weight. */
  int32_t turn_old[LE_MAX_TRACKS];
  float turn_x[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    le_track* tr = &e->tracks[t];
    turn_old[t] = -1;
    turn_x[t] = 1.0f;
    if (trk_len[t] <= 0 || !(tr->reversed || tr->playback_offset != 0 ||
                             tr->turn_left > 0)) continue;
    if (st[t] != LE_TRACK_PLAYING && st[t] != LE_TRACK_OVERDUBBING) continue;
    int32_t len;
    const int64_t base = le_track_base_position(e, tr, &len);
    if (len <= 0) continue;
    const int32_t index =
        le_direction_index(tr->reversed, tr->playback_offset, base, len);
    seg_base[t] = index - index % trk_len[t];
    trk_pos[t] = index % trk_len[t];
    if (tr->turn_left > 0) {
      turn_old[t] = le_direction_index(tr->turn_reversed, tr->turn_offset,
                                       base, len);
      turn_x[t] = le_direction_turn_mix(tr->turn_frames - tr->turn_left,
                                        tr->turn_frames);
    }
  }
  /* Each track's read index for THIS frame, kept for the block-end publish of
   * a_play_pos (le_track_snapshot.position_frames): the one place the mode's
   * position rule is already resolved, so the app never re-derives it. */
  for (int t = 0; t < tc; ++t) {
    if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) {
      e->trk_play_pos[t] = seg_base[t] + trk_pos[t];
    } /* a stopped track HOLDS its last read index; an empty one publishes 0 */
    /* Capture provenance (#1143): which PCM this frame's mix of track [t]
     * comes from, as a callback-applied fact. The mixer's own live slot for
     * this frame (live_idx) is the application boundary. */
    le_track* tr = &e->tracks[t];
    if (!e->perf.armed) continue;
    const int32_t live0 = live_idx[t];
    const uint64_t frame = perf_frame_base + f;
    if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_STOPPED) {
      const int32_t len = load_i32(&tr->lanes[0].a_len);
      const int32_t phase = len > 0 ? e->trk_play_pos[t] % len : 0;
      if (live0 != tr->perf_source_slot) {
        /* A slot became live: its staged image is the source from this frame
         * (322 below). No image means provenance is lost whether the previous
         * source was an image or the arm snapshot: 323/0, unconditionally. */
        tr->perf_source_slot = live0;
        tr->perf_source_id = atomic_load_explicit(
            &e->perf.slot_image[t][live0], memory_order_relaxed);
        if (tr->perf_source_id == 0) le_perf_source_lost(e, tr, frame);
        tr->perf_source_state = -1;
      }
      if (tr->perf_source_id != 0 &&
          (tr->perf_source_state != st[t] ||
           (st[t] == LE_TRACK_PLAYING && tr->perf_source_next_pos != phase))) {
        le_plog_push(e, frame, (le_command){
            .code = tr->perf_source_state < 0 ? LE_PLOG_SOURCE_APPLIED
                                              : LE_PLOG_SOURCE_TRANSPORT,
            .restore_log = {t, tr->perf_source_id, st[t], phase}});
      }
      tr->perf_source_state = st[t];
      /* The phase steps in the track's direction (#1162), so continuous
       * reversed playback logs no transport facts. */
      tr->perf_source_next_pos =
          len > 0 ? (tr->reversed ? (phase + len - 1) % len : (phase + 1) % len)
                  : 0;
    } else if (st[t] == LE_TRACK_RECORDING || st[t] == LE_TRACK_OVERDUBBING) {
      /* The written slot is uncaptured material: an image source ends here
       * (D4), and so does a staged image that is overwritten before it was
       * ever mixed PLAYING or STOPPED (restore, then record in one block).
       * The slot itself becomes the snapshot-provenance source, so RECORD_END
       * and the retired-layer facts take over with no table lookup. */
      if (tr->perf_source_id != 0 ||
          (live0 != tr->perf_source_slot &&
           atomic_load_explicit(&e->perf.slot_image[t][live0],
                                memory_order_relaxed) != 0)) {
        le_perf_source_lost(e, tr, frame);
      }
      tr->perf_source_slot = live0;
    } /* EMPTY: no fact; le_transform_reset already dropped the source */
  }

  /* The looper mix is additive: clear this output frame, then sum every active
   * lane's mono contribution into the output channels its mask selects. */
  for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] = 0.0f;

  for (int t = 0; t < tc; ++t) {
    /* The punch fade only engages once the loop is long enough to host a full
     * fade-in plus fade-out tail with steady audio between them; shorter loops
     * (sub-20 ms — not musically a loop) snap straight to the target,
     * preserving the exact unfaded write the deterministic tests rely on.
     * Per-track (trk_len[t]) so a Free-mode track's own length governs its
     * own punch fade instead of the (always-0) master's — identical to
     * `e->clock.length >= 2 * od_fade_frames` in every other mode, since
     * trk_len[t] == e->clock.length there. */
    const int od_fade_on = trk_len[t] >= 2 * od_fade_frames;
    /* Advance this track's overdub punch envelope once per frame (shared by
     * every lane): ramp toward 1 while OVERDUBBING, toward 0 otherwise. When a
     * punch-out flips the state to PLAYING the envelope is still > 0, so the
     * write below keeps layering a tapering tail until it reaches 0 — a
     * click-free punch-out (the player's still-live input fades out, rather than
     * the loop cutting at the punch point). */
    const float od_target = (st[t] == LE_TRACK_OVERDUBBING) ? 1.0f : 0.0f;
    float od_gain = e->tracks[t].od_gain;
    if (!od_fade_on) {
      od_gain = od_target;
    } else if (od_gain < od_target) {
      od_gain += od_step;
      if (od_gain > od_target) od_gain = od_target;
    } else if (od_gain > od_target) {
      od_gain -= od_step;
      if (od_gain < od_target) od_gain = od_target;
    }
    e->tracks[t].od_gain = od_gain;
    /* Overdub decay (slice 2b): this track's own feedback override, or the
     * global coefficient, reached through the same ramp as the punch
     * envelope so a live change never steps the retained layer at the write
     * head. Snaps like od_gain on a loop too short to host the ramp. */
    float trk_fb = e->tracks[t].fb_cur;
    {
      const float ov = load_f32(&e->tracks[t].a_overdub_fb_bits);
      const float fb_target = ov >= 0.0f ? ov : overdub_fb;
      if (!od_fade_on) {
        trk_fb = fb_target;
      } else if (trk_fb < fb_target) {
        trk_fb += od_step;
        if (trk_fb > fb_target) trk_fb = fb_target;
      } else if (trk_fb > fb_target) {
        trk_fb -= od_step;
        if (trk_fb < fb_target) trk_fb = fb_target;
      }
      e->tracks[t].fb_cur = trk_fb;
    }

    /* Per-pass layer capture for this frame, shared by every lane: the write
     * position uses the session-latched offset (a mid-dub offset change must
     * not tear the trajectory), and `backing` says whether the armed shadow is
     * still collecting pre-values (it stops once complete — frozen — or while
     * an old pass drains). The first backed-up write latches the pass's start
     * point for the drain walk. */
    le_track* tr = &e->tracks[t];

    /* Recording write head for this frame, shared by every lane (or -1 when
     * nothing may be written). The defining track writes linearly. A new
     * track over the master is phase-locked (record_pos == segment*base +
     * position) and latency-compensated by dropping the first `offset`
     * frames so it aligns with what the player heard. With a fixed multiple
     * the final length (K*base) is already known, so the head wraps into it:
     * audio captured past the loop top lands at its heard phase instead of
     * beyond the final length, where finalize would silently orphan it (a
     * mid-loop take used to lose everything recorded after the top). Auto
     * (K == 0) stays linear — finalize rounds the length up instead, so
     * nothing is dropped. A negative head (capture inside the latency window
     * of a press near the top) stays dropped: the pre-press slice is silent
     * by design. */
    int32_t rec_w = -1;
    if (st[t] == LE_TRACK_RECORDING) {
      if (e->clock.length == 0) {
        rec_w = tr->record_pos;
      } else {
        rec_w = tr->record_pos - offset;
        const int32_t k = le_effective_multiple(e, t);
        const int32_t known_len = k >= 1 ? k * e->clock.length : 0;
        if (known_len > 0 && rec_w >= known_len) rec_w %= known_len;
      }
      if (rec_w >= e->max_loop_frames) rec_w = -1;
    }

    const int dub_writes =
        (st[t] == LE_TRACK_OVERDUBBING || st[t] == LE_TRACK_PLAYING) &&
        od_gain > 0.0f && trk_len[t] > 0;
    int32_t wdub = 0;
    int backing = 0;
    if (dub_writes) {
      wdub = seg_base[t] + comp_pos(trk_pos[t], tr->dub_offset, trk_len[t]);
      backing = tr->dub_slot >= 0 && !tr->dub_draining && tr->dub_len > 0 &&
                tr->dub_count < tr->dub_len;
      if (backing && tr->dub_count < 0) {
        tr->dub_count = 0;
        tr->dub_start_vpos = trk_pos[t];
        tr->dub_start_vseg = seg_base[t] / trk_len[t];
      }
    }

    /* #728 trailing seam overlap: a just-finalized non-defining take is still
     * capturing its own continuation into [seam_len, seam_len + F) — the
     * region seam_room already proved fits every live lane buffer. The
     * countdown and the fold run after the lane loop below. */
    const int32_t seam_f = seam_xfade_frames(e);
    const int32_t seam_w =
        tr->seam_capture > 0 ? tr->seam_len + (seam_f - tr->seam_capture) : -1;

    /* Track-stage stereo bus (FX v3 part 1b, D-TRACKROUTE): live only while
     * the track's chain is non-empty. Audible lanes then sum their post-
     * lane-chain (wl, wr) pairs here instead of routing individually, and OR
     * their enabled masks into the union the wet result routes through. */
    float bus_l = 0.0f;
    float bus_r = 0.0f;
    uint32_t bus_mask = 0u;

    /* The whole-track Pre print (slice 3e). It ENGAGES at the track's own
     * loop top — every part shares that index — so the swap is click-free by
     * construction and no transport state is touched: the loop does not
     * restart. The edge settles every part's chain slots and the track's own
     * Pre slots to bypass, so a later fallback re-enters through the enable
     * machinery's clean path rather than resuming a stale tail.
     *
     * While engaged the parts contribute NOTHING to the bus: their audio is
     * inside the render, and a bypassed slot is unity passthrough rather than
     * silence, so leaving them summing would play the track's material twice.
     * They keep being read for metering. */
    const le_wet_entry* tce = track_cache_ent[t];
    const int32_t trk_rp = seg_base[t] + trk_pos[t];
    /* A print engages only at the FORWARD lap start (index 0, with or without
     * a relaunch origin) and never on a reversed track (#1162): reversing a
     * loop reverses the recording, not its effects, so the live chains run
     * forward over the backward read. */
    if (tce != NULL && st[t] == LE_TRACK_PLAYING && !tr->reversed &&
        !load_i32(&tr->a_track_cache_active) && trk_rp == 0) {
      store_i32(&tr->a_track_cache_active, 1);
      for (int l = 0; l < lane_n[t]; ++l) {
        le_lane* el = &e->tracks[t].lanes[l];
        for (int sfx = 0; sfx < fx_count[t][l]; ++sfx) {
          le_fx_enable_force_bypass(&el->fx, sfx);
        }
      }
      for (int sfx = 0; sfx < trk_fx_pre_count[t]; ++sfx) {
        le_fx_enable_force_bypass(&tr->bus.fx, sfx);
      }
    }
    const int track_printed =
        tce != NULL && load_i32(&tr->a_track_cache_active);
    if (track_printed) {
      /* The engage edge can land mid-buffer, so mask the printed slots'
       * effective bits for the rest of it too — a force-bypassed slot whose
       * bit is still 1 would ramp itself back in on the next sample. */
      for (int l = 0; l < lane_n[t]; ++l) {
        for (int sfx = 0; sfx < fx_count[t][l]; ++sfx) {
          fx_enabled[t][l][sfx] = 0;
        }
      }
      for (int sfx = 0; sfx < trk_fx_pre_count[t]; ++sfx) {
        trk_fx_enabled[t][sfx] = 0;
      }
    }
    /* This track's lanes summed for THIS frame -- folded into the block
     * accumulators after the lane loop (#655). */
    float trk_mix = 0.0f;
    /* What the track sends per side this frame (post-fader, post-pan; the
     * bus after its chain when the track has one) — the Mixer's meter. */
    float trk_l = 0.0f;
    float trk_r = 0.0f;

    /* Idle track (see the idle[] derivation at the snapshot loop above): the
     * whole lane body folds to zero, and its snapshot was skipped with it.
     * Everything AFTER this loop still runs — the track-stage chain on its
     * seeded (0, 0) bus, the punch envelope, the seam countdown. */
    for (int l = 0; !idle[t] && l < lane_n[t]; ++l) {
      /* Clean single-input capture: a lane records exactly its assigned hardware
       * input — never an average of several — or silence when it has no input,
       * an out-of-range/loopback-excluded channel, or no allocated buffer.
       * Sibling lanes are never merged. */
      const int32_t ic = lane_in[t][l];
      float insample = 0.0f;
      if (in && ic >= 0 && ic < ch_in && !(excluded & (1u << ic))) {
        /* The capture trim (slice 3) scales only what records: the monitor
         * path, the meters and the trigger read the untrimmed input. */
        insample = in[f * ch_in + ic] * in_trim[ic];
      }

      /* Real-time null-guard: a lane whose buffer is not yet allocated (the
       * lazy-alloc window, or a count/alloc mismatch) records and plays nothing
       * rather than dereferencing a NULL pool. */
      float* lbuf = buf[t][l];
      if (lbuf == NULL) continue;

      float loopsample = 0.0f;
      if (st[t] == LE_TRACK_RECORDING) {
        if (rec_w >= 0) lbuf[rec_w] = insample;
      } else if (st[t] == LE_TRACK_OVERDUBBING || st[t] == LE_TRACK_PLAYING) {
        /* Mix the existing loop (read before write). Layer the live input at the
         * compensated position, scaled by the punch envelope so it ramps in on
         * punch-in and out on punch-out (od_gain keeps the write alive for the
         * fade-out tail after the state has already returned to PLAYING).
         * od_gain == 0 in steady playback, so this is a plain read.
         * trk_pos[t] (Free mode, B2b): this track's own clock position;
         * equals pos otherwise. */
        loopsample = lbuf[seg_base[t] + trk_pos[t]];
        /* Reverse turn (#1162): the pre-turn head fades out over the window
         * as the new head fades in — both read this same lane's material. */
        if (turn_old[t] >= 0) {
          loopsample = loopsample * turn_x[t] +
                       lbuf[turn_old[t]] * (1.0f - turn_x[t]);
        }
        if (od_gain > 0.0f) {
          /* Backup-on-write: save the pre-value into the armed shadow first —
           * the incremental per-pass undo snapshot (same slot on every lane,
           * lockstep). Live stays authoritative; the shadow becomes one undo
           * layer when the pass completes (or drains after punch-out). */
          if (backing) {
            float* sb = e->tracks[t].lanes[l].pool[tr->dub_slot];
            if (sb != NULL) sb[wdub] = lbuf[wdub];
          }
          /* Feedback scales the existing content at the write head before the new
           * layer is summed in, bounding runaway buildup. fb == 1.0 (the default)
           * is the classic additive `+= insample`. trk_fb is this track's own
           * (ramped) coefficient, the global one when it inherits. */
          lbuf[wdub] = lbuf[wdub] * trk_fb + insample * od_gain;
        }
      }
      /* #728 trailing overlap capture: a just-finalized non-defining take keeps
       * writing its continuation past the loop point for F frames, exactly as
       * the defining master's deferred finalize does. Folded (and stopped)
       * after the lane loop. */
      if (seam_w >= 0 && seam_w < cap[t][l]) lbuf[seam_w] = insample;

      /* The lane's mono output: its dry loop content at the lane's playback
       * volume while it sounds, silence otherwise, run through the lane's whole
       * (stageless) effects chain on its `fx` state. Effects run every frame the
       * lane has them (even on silence) so delay tails and LFO phase stay
       * continuous. Two gates (slice 3b; accepted tail distinctions): `fed`
       * — the lane is playing and not gated — feeds the chain; `gate_ok` —
       * not muted, not soloed away — lets the chain's output through. So a
       * Stop or Clear cuts the feed and the lane's Post tail drains through
       * the same route, while a Mute (or another track's solo) gates the
       * lane entirely, tail included, and its player continues underneath.
       * EXCEPTION (part 2): while cached playback is engaged below, the live
       * chain is skipped entirely — its state was settled to bypass at the
       * engage edge, and a fallback re-enters through the clean re-enable
       * path instead of resuming a stale tail. */
      const int gate_ok = !mut[t][l] && (!any_solo || solo[t]);
      const int audible =
          (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
          gate_ok;
      /* The lane's wet pair reaches its route while fed, or while a chain
       * may still hold a tail and the gate is open. */
      const int routes = audible || (has_fx[t][l] && gate_ok);
      le_lane* ln = &e->tracks[t].lanes[l];

      /* The printed Pre stage (slice 3e), rendered by the loop-stage cache
       * (part 2). The per-buffer snapshot already verified the published
       * entry's full key against the lane's current one (snapshot_lane_cache
       * — a mismatch cleared cache_active there, the same-buffer live
       * fallback [B4]). The print ENGAGES only at the lane's own loop
       * boundary (read position 0), never mid-cycle, so the swap is
       * click-free by construction and IS the accepted "switch at an
       * audio-safe boundary"; the engage edge settles the PRE slots to
       * bypass so a later fallback re-enters through the enable machinery's
       * clean re-enable path (reset + ring clear + warmup + ramp [B7])
       * rather than resuming a stale tail.
       *
       * What is printed is exactly entries [0, fx_pre_count): the take's own
       * processing, rendered from the dry pool at pre-chain volume (D-VOL).
       * The Post entries keep running LIVE over it, because a Post tail has
       * to be able to drain past a Stop and a baked one cannot — that is why
       * this is a prefix render and not the whole chain. Mute routes nothing
       * but stays engaged; unmute resumes printed (Pre tails are part of the
       * periodic render — the small documented difference from live [R5]).
       * Meters above keep reading the dry loopsample either way.
       *
       * PERIODIC-RENDER SEMANTICS (the general form of that [R5] note, part
       * of the [B4] listen check): cached playback replays ONE baked lap, so
       * anything in the chain that free-runs across laps diverges from an
       * uncached engine over time — an LFO whose rate is not loop-locked
       * repeats the baked sweep each lap instead of evolving, and a tail
       * longer than the loop carries exactly one lap of accumulation instead
       * of building wash. Inherent to caching a loop (not a bug); the parity
       * tests pin the first cached lap, and the listen check owns the rest.
       *
       * Engagement additionally requires the track to be PLAYING: engaging a
       * STOPPED lane would force-bypass its silently-ticking chain (wiping
       * tail/LFO continuity) for playback nobody hears. */
      const le_wet_entry* wce = cache_ent[t][l];
      const int32_t rp = seg_base[t] + trk_pos[t];
      if (wce != NULL && st[t] == LE_TRACK_PLAYING && !tr->reversed &&
          !load_i32(&ln->a_cache_active) && rp == 0) {
        store_i32(&ln->a_cache_active, 1);
        for (int s = 0; s < fx_pre_count[t][l]; ++s) {
          le_fx_enable_force_bypass(&ln->fx, s);
        }
      }
      const int printed = wce != NULL && load_i32(&ln->a_cache_active);
      float wl;
      float wr;
      if (printed) {
        /* The engage edge can land mid-buffer, so zero the printed slots'
         * effective bits for the REST of this buffer too: a force-bypassed
         * slot whose bit is still 1 would see want != target on the very
         * next sample and ramp itself back in, printing its Pre entry a
         * second time over audio that already carries it. */
        for (int s = 0; s < fx_pre_count[t][l]; ++s) {
          fx_enabled[t][l][s] = 0;
        }
        if (audible && rp >= 0 && rp < wce->len) {
          wl = wce->pcm[2 * rp];
          wr = wce->pcm[2 * rp + 1];
        } else {
          wl = 0.0f;
          wr = 0.0f;
        }
      } else {
        wl = audible ? loopsample * vol[t][l] : 0.0f;
        wr = wl;
      }
      /* One pass over the whole chain either way. The printed Pre slots are
       * settled bypasses by now, so they cost a bit-exact skip (D-BITEXACT)
       * and the Post entries downstream of them process normally.
       *
       * A whole-track print covers this part's chain entirely, so it is
       * skipped rather than walked: its state was settled to bypass at that
       * engage edge and a fallback re-enters through the clean path. */
      if (has_fx[t][l] && !track_printed) {
        fx_apply_chain(&ln->fx, sr, fx_cap, &wl, &wr, fx_count[t][l],
                       fx_type[t][l], fx_params[t][l], fx_enabled[t][l]);
      }
      /* Pan (slice 3): placement of the lane's pair, after the chain and
       * after the cache (the cache holds the unpanned render). The gains
       * were computed when the pan was set; centre is exact unity, so an
       * unpanned lane stays bit-identical. */
      wl *= pan_gl[t][l];
      wr *= pan_gr[t][l];
      if (!trk_has_fx[t]) {
        const float gain = load_f32(&tr->a_gain_bits) * tr->fade_sample;
        wl *= gain;
        wr *= gain;
        /* Empty Track chain (the default and the migration state): the legacy
         * per-lane routing runs untouched — bit-identical to the pre-part-1b
         * engine (D-TRACKROUTE's fingerprint invariant). */
        if (routes) {
          const uint32_t routed = out_mask[t][l] & out_enabled;
          if (at_has_fx) {
            le_fx_route_frame(rec, ch_out, routed, wl, wr);
          } else {
            le_fx_route(out, f, ch_out, routed, wl, wr);
          }
          /* The meter reads what reaches an output: a lane routed to
           * nothing (or only to disabled outputs) sends nothing. */
          if (routed) {
            trk_l += wl;
            trk_r += wr;
          }
        }
      } else {
        /* Non-empty Track chain: accumulate onto the stereo bus instead.
         * Topology keys off EMPTINESS, not enabled — a chain-disabled but
         * non-empty chain stays on this bus path (part 1a's bypass makes it
         * dry), so a stomp toggles DSP, never routing. The bus routes via
         * the union of the gate-open lanes' destinations, playing or not:
         * a Stop leaves the union intact so the chain's tail drains, a Mute
         * takes the lane's route out of it (the track's own chain is gated
         * with the track; only the shared output chains drain under Mute,
         * see the accepted tail distinctions). */
        if (routes && !track_printed) {
          bus_l += wl;
          bus_r += wr;
        }
        /* The routing union is built from the parts either way: the printed
         * pair reaches exactly the destinations the parts would have. */
        if (gate_ok) bus_mask |= out_mask[t][l] & out_enabled;
      }

      const float la = fabsf(loopsample);
      if (la > lane_peak[t][l]) lane_peak[t][l] = la;
      if (la > frame_trk_peak[t]) frame_trk_peak[t] = la;
      lane_sumsq[t][l] += loopsample * loopsample;
      /* The track's own level is the SUM of its lanes, not lane 0's (#655).
       * frame_trk_peak above is a max, which the visualizer wants; a meter
       * wants what the lanes add up to, because that is what a listener
       * hears when several layers play together.
       *
       * Sums the same dry `loopsample` the per-lane meters read, rather than
       * the audible/routed value: that keeps this a pure "all lanes instead
       * of lane 0" fix and does not quietly introduce a new mute semantic
       * that nobody asked for. */
      trk_mix += loopsample;
    }
    {
      const float ma = fabsf(trk_mix);
      if (ma > trk_peak[t]) trk_peak[t] = ma;
      trk_sumsq[t] += trk_mix * trk_mix;
    }

    /* Track-stage chain (D-TRACKROUTE): runs ONCE per track per frame,
     * every frame the chain is non-empty — even when no lane is audible (the
     * bus stays at its seeded 0, 0) — so delay tails and LFO phase stay
     * continuous, mirroring the lane chains' run-on-silence rule above. The
     * wet pair routes via the union of the gate-open lanes' destinations,
     * so the chain's tail keeps reaching the outputs after a Stop and is
     * gated by a Mute (slice 3b tail distinctions). Meters
     * (lane_peak / lane_sumsq / frame_trk_peak above) keep reading the dry
     * loopsample, untouched by this stage. */
    if (track_printed) {
      /* The rendered combination replaces the parts' sum. Gated the way a
       * part's print is: a stopped or soloed-away track feeds its chain
       * silence, so the Post run drains exactly as it does live. Each part's
       * own mute is already inside the render. */
      const int track_audible =
          (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
          (!any_solo || solo[t]);
      if (track_audible && trk_rp >= 0 && trk_rp < tce->len) {
        bus_l = tce->pcm[2 * trk_rp];
        bus_r = tce->pcm[2 * trk_rp + 1];
      } else {
        bus_l = 0.0f;
        bus_r = 0.0f;
      }
    }
    if (trk_has_fx[t]) {
      fx_apply_chain_with_gain(&tr->bus.fx, sr, fx_cap, &bus_l, &bus_r,
                     trk_fx_count[t], trk_fx_type[t], trk_fx_params[t],
                     trk_fx_enabled[t], trk_fx_pre_count[t],
                     load_f32(&tr->a_gain_bits) * tr->fade_sample);
      if (at_has_fx) {
        le_fx_route_frame(rec, ch_out, bus_mask, bus_l, bus_r);
      } else {
        le_fx_route(out, f, ch_out, bus_mask, bus_l, bus_r);
      }
      if (bus_mask) {
        trk_l = bus_l;
        trk_r = bus_r;
      }
    }
    {
      const float al = fabsf(trk_l);
      const float ar = fabsf(trk_r);
      if (al > trk_lpeak[t]) trk_lpeak[t] = al;
      if (ar > trk_rpeak[t]) trk_rpeak[t] = ar;
    }

    /* Advance the per-pass capture once per written frame (all lanes share the
     * one write head): count tracks the shadow's coverage, phase the pass
     * boundary — where a complete shadow retires and the spare takes over. */
    if (dub_writes && tr->dub_len > 0) {
      if (backing) tr->dub_count++;
      tr->dub_phase++;
      if (tr->dub_phase >= tr->dub_len) {
        tr->dub_phase = 0;
        le_dub_boundary(e, tr, perf_frame_base + f);
      }
    }

    /* #728: the trailing overlap capture completes here (once per frame per
     * track, all lanes having just written this frame's sample) and folds the
     * captured continuation into the head. The two folds touch disjoint
     * regions of the live slot (the shadow one only READS [len, len + F)),
     * so their order is immaterial. */
    /* The Reverse turn window counts down once per frame per track (#1162),
     * sounding or not: a toggle on a muted or soon-stopped track must not
     * leave a stale old head for a later Play to mix. */
    if (tr->turn_left > 0) --tr->turn_left;
    if (seam_w >= 0 && --tr->seam_capture == 0) {
      le_seam_fold_dub_shadow(tr, tr->seam_len, seam_f);
      le_seam_fold(tr, tr->seam_len, seam_f);
      /* [R1] seam fold: an in-place content write, and the only one in the
       * new-track path that does NOT already ride a finalize bump. The master
       * path folds and then calls finalize_master, which bumps; here the
       * finalize bumped F frames ago, so without this the wet cache would key
       * the un-crossfaded head as current — a copy spanning the fold would
       * publish torn content, and one completing just before it would replay
       * exactly the click this fold removes. */
      le_audio_rev_bump(tr);
    }
  }

  /* The All tracks stage: one chain, one instance per destination. The
   * accepted design's "single shared chain applied after the loop tracks are
   * combined" — and only them: live monitoring, the click and the output
   * chains all join after this, which is what makes this stage different from
   * an output chain.
   *
   * Per bus because slice 3b made output selection per source: a track on
   * Main and a track on Monitor are two different recorded mixes, and one
   * shared instance would have to send each track's audio to the other's
   * jacks. Every bus of the device runs, fed or not, so a tail that started
   * on one keeps draining while nothing new arrives — the same run-on-silence
   * rule the lane and track chains follow.
   *
   * A single-channel last bus processes its channel as l == r and writes only
   * that channel, exactly as output_bus_frame does. */
  if (at_has_fx) {
    float* o = out + (size_t)f * (size_t)ch_out;
    const int bus_n = (ch_out + 1) / 2;
    for (int k = 0; k < bus_n && k < LE_MAX_OUTPUT_BUSES; ++k) {
      const int c0 = 2 * k;
      const int c1 = c0 + 1 < ch_out ? c0 + 1 : -1;
      float l = rec[c0];
      float r = c1 >= 0 ? rec[c1] : l;
      fx_apply_chain(&e->all_tracks_fx[k], sr, fx_cap, &l, &r, at_fx_count,
                     at_fx_type, at_fx_params, at_fx_enabled);
      /* The chain keeps ticking on silence so tails can finish, but a
       * disabled physical jack must not receive stored or crossfed sound. */
      if (out_enabled & (1u << c0)) o[c0] += l;
      if (c1 >= 0 && (out_enabled & (1u << c1))) o[c1] += r;
    }
  }
}

/* Test seam: drive one output frame through master_bus_frame (master gain ->
 * feed-forward limiter -> metering) with explicit params, so the limiter dynamics
 * (transparent below the ceiling, instant-attack clamp above, smooth release) can
 * be exercised in isolation. Mirrors what le_engine_process calls per frame. Not
 * part of the FFI surface. */
void le_engine_master_bus_frame_for_test(le_engine* e, float* out, uint32_t f,
                                         int ch_out, float master_gain,
                                         int limiter_on, float limiter_ceiling,
                                         float lim_release, float* out_sumsq,
                                         float* frame_out_peak) {
  float out_peak_ch[LE_MAX_CHANNELS] = {0};
  master_bus_frame(e, out, f, ch_out, master_gain, limiter_on, limiter_ceiling,
                   lim_release, out_sumsq, frame_out_peak, out_peak_ch);
}

/* ---- the real-time DSP core ---- */

void le_engine_process(le_engine* e, float* output, const float* input,
                       uint32_t frames) {
  le_flush_denormals(); /* per-thread; cheap to reassert every callback */

  const int ch_in = e->in_channels > 0 ? e->in_channels : 1;
  const int ch_out = e->out_channels > 0 ? e->out_channels : 1;
  const int tc = e->track_count;
  float* out = output;
  const float* in = input;

  /* Snapshot the perf-log frame base once, before this buffer's frame count
   * is added to a_perf_frames below (see the end of this function) — every
   * command drained this call applies at the top of THIS buffer, so they all
   * share this one frame tag. Reading a_perf_frames here is safe with no
   * ordering ceremony: only this thread ever writes it. */
  const uint64_t perf_frame_base =
      atomic_load_explicit(&e->a_perf_frames, memory_order_relaxed);

  le_command cmd;
  while (le_ring_pop(&e->ring, &cmd)) {
    apply_command(e, &cmd, perf_frame_base);
    e->commands_applied++; /* rejected and no-op commands settle too */
  }

  /* Close the count-in cancel-race grace window (code-review fix) right
   * after this block's command drain: it is open for exactly one block's
   * worth of draining — the block immediately following the commit that set
   * it (engine_private.h / le_count_in_commit have the full rationale) —
   * whether or not a matching press showed up to consume it. */
  for (int c = 0; c < tc; ++c) {
    e->launch_grace[c] = 0;
    store_i32(&e->tracks[c].a_launch_grace, 0);
  }

  /* Per-pass undo layer maintenance: retry parked retires and advance the
   * post-punch-out drain. Runs every call — including frames == 0 pumps (the
   * host tests' drain helper) — so a completed layer always retires. */
  le_dub_block_update(e, perf_frame_base);

  /* Global master output gain, read once per block after draining the ring so a
   * mid-block change applies from the next block (no per-frame atomic load). */
  const float master_gain = load_f32(&e->a_master_gain_bits);

  /* Master limiter + overdub feedback, read once per block (same rationale). */
  const int limiter_on = load_i32(&e->a_limiter_enabled) != 0;
  const float limiter_ceiling = load_f32(&e->a_limiter_ceiling_bits);
  const float overdub_fb = load_f32(&e->a_overdub_fb_bits);

  /* Click bus settings, read once per block (same rationale; the click's
   * volume is its ONLY gain stage — deliberately outside the master bus). */
  const int32_t click_mode = load_i32(&e->a_click_mode);
  const uint32_t click_mask =
      atomic_load_explicit(&e->a_click_mask, memory_order_relaxed);
  const float click_vol = load_f32(&e->a_click_volume_bits);
  /* ~50 ms release toward unity once the signal drops below the ceiling. */
  float lim_release = 1.0f / (0.05f * (float)(e->sample_rate > 0
                                                  ? e->sample_rate
                                                  : 48000));
  if (lim_release > 1.0f) lim_release = 1.0f;

  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  /* The nominal frames-per-beat grid_beat_frame counts a grid-free loop in
   * (#1050), read once per block: the free-running scheduler's own formula,
   * so the loop's beats sit where the defining take's clicks did. */
  const float nominal_bpm = load_f32(&e->a_tempo_bpm_bits);
  const int32_t nominal_fpb =
      nominal_bpm > 0.0f
          ? (int32_t)llround(60.0 * (double)sr / (double)nominal_bpm)
          : 0;
  /* Overdub punch declick: ramp the layered input in/out over ~10 ms so a punch
   * (in or out, including the instant rec/dub auto-dub) never bakes a step into
   * the loop buffer. One linear step per frame, settling in od_fade_frames. */
  int32_t od_fade_frames = sr / 100;
  if (od_fade_frames < 1) od_fade_frames = 1;
  const float od_step = 1.0f / (float)od_fade_frames;
  /* Loopback-labelled input channels are never recorded, monitored, or
   * metered (they carry our own output and would otherwise inflate the meter). */
  const uint32_t excluded =
      atomic_load_explicit(&e->a_excluded_input_mask, memory_order_relaxed);
  int active_in = 0;
  for (int c = 0; c < ch_in; ++c) {
    if (!(excluded & (1u << c))) ++active_in;
  }

  /* ---- Per-input conditioning stage (input conditioning, S1) ----
   * HPF + hum notches + downward expander, run ONCE per block per enabled
   * input into the preallocated conditioned copy of the interleaved input,
   * upstream of BOTH the lane fan-out and the monitor split (WYSIWYG: the
   * performer hears exactly what records, and N lanes recording one input
   * capture identical samples for one run of the DSP). `in_c` is what the
   * lane capture, the monitors, the tuner, and the sound-activated record
   * trigger read; metering / the latency harness keep reading the RAW `in`
   * (process_input_frame). Loopback-excluded channels are never conditioned
   * — the harness's round-trip correlation cannot be shaved by the HPF.
   * Zero added buffering latency by construction (IIR + no-lookahead
   * envelope; see engine_cond.c). Dormant cost: at most
   * LE_MAX_MONITORED_INPUTS relaxed loads per block. A block larger than the
   * scratch (only the native tests' synthetic mega-blocks) falls back to the
   * raw path for that block rather than allocating on the audio thread. */
  const float* in_c = in;
  if (in != NULL) {
    uint32_t cond_mask = 0u;
    const int cond_ch =
        ch_in < LE_MAX_MONITORED_INPUTS ? ch_in : LE_MAX_MONITORED_INPUTS;
    for (int c = 0; c < cond_ch; ++c) {
      if (load_i32(&e->cond[c].a_enabled) && !(excluded & (1u << c))) {
        cond_mask |= 1u << c;
      }
    }
    if (cond_mask != 0u) {
      if (e->cond_buf != NULL &&
          (int64_t)frames * (int64_t)ch_in <= e->cond_buf_cap) {
        memcpy(e->cond_buf, in,
               sizeof(float) * (size_t)frames * (size_t)ch_in);
        for (int c = 0; c < cond_ch; ++c) {
          if (cond_mask & (1u << c)) {
            le_cond_process_block(&e->cond[c], e->cond_buf + c, frames, ch_in);
          }
        }
        in_c = e->cond_buf;
      } else if (frames > 0) {
        /* Conditioning WANTED but impossible this block (oversized period or
         * a failed scratch allocation): raw fallback, COUNTED — silent
         * per-block alternation between conditioned and raw would click
         * (stale filter states across the gaps), so the counter is how a
         * bench/test proves this path never fires on a real backend. No RT
         * assert: the audio callback must never abort. */
        atomic_fetch_add_explicit(&e->a_cond_fallback_blocks, 1u,
                                  memory_order_relaxed);
      }
    }
  }

  /* ---- Input clip ("HOT") detector (input clip, S2) ----
   * Always on, no params, and deliberately on the RAW `in` — never `in_c` —
   * so a clipped input flags HOT even when the conditioning stage has ducked
   * or notched what records (HOT reflects the ADC; see the LE_CLIP_* doc).
   * LE_CLIP_RUN consecutive samples at |s| >= LE_CLIP_LEVEL latch the input's
   * bit for LE_CLIP_HOLD_MS of engine time (the a_frames timeline), refreshed
   * while the rail persists; the run counter carries across blocks so a run
   * split by a block boundary still latches. Loopback-excluded channels never
   * flag (they carry our own output — a hot master would read as a hot
   * input). Holds decay with processed frames, so the mask is recomputed and
   * published once per non-empty block whether or not input flows. */
  if (frames > 0) {
    const uint64_t clip_now =
        atomic_load_explicit(&e->a_frames, memory_order_relaxed);
    const uint64_t clip_hold = (uint64_t)sr * LE_CLIP_HOLD_MS / 1000u;
    const int clip_ch =
        ch_in < LE_MAX_MONITORED_INPUTS ? ch_in : LE_MAX_MONITORED_INPUTS;
    uint32_t clip_mask = 0u;
    for (int c = 0; c < clip_ch; ++c) {
      if (excluded & (1u << c)) {
        e->clip_run[c] = 0;
        e->clip_hold_until[c] = 0;
        continue;
      }
      if (in != NULL) {
        int32_t run = e->clip_run[c];
        for (uint32_t f = 0; f < frames; ++f) {
          if (fabsf(in[f * (uint32_t)ch_in + (uint32_t)c]) >= LE_CLIP_LEVEL) {
            if (++run >= LE_CLIP_RUN) {
              /* Latched (or refreshed): hold from THIS sample. Cap the run so
               * a sustained rail cannot overflow the counter. */
              e->clip_hold_until[c] = clip_now + f + 1u + clip_hold;
              run = LE_CLIP_RUN;
            }
          } else {
            run = 0;
          }
        }
        e->clip_run[c] = run;
      }
      /* HOT while the hold outlives this block's end (clip_now is the frame
       * count BEFORE this block; a_frames is bumped below). */
      if (e->clip_hold_until[c] > clip_now + frames) clip_mask |= 1u << c;
    }
    atomic_store_explicit(&e->a_input_clip_mask, clip_mask,
                          memory_order_relaxed);
  }

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;
  float out_peak = 0.0f;
  /* Per-lane metering accumulators (each track's snapshot mirrors lane 0). */
  float lane_sumsq[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};
  float lane_peak[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};
  /* The TRACK's own level: its lanes summed per frame, then accumulated over
   * the block the same way the per-lane figures are (#655). */
  float trk_sumsq[LE_MAX_TRACKS] = {0};
  float trk_peak[LE_MAX_TRACKS] = {0};
  /* Post-fader stereo peaks per track (slice 3), see le_track_snapshot. */
  float trk_lpeak[LE_MAX_TRACKS] = {0};
  float trk_rpeak[LE_MAX_TRACKS] = {0};

  /* Active lane count per track (control-thread plain int; clamped once). */
  int32_t lane_n[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) lane_n[t] = le_lanes_active(&e->tracks[t]);

  /* Per-lane effect chains, snapshotted once per buffer (see snapshot_lane_fx).
   * has_fx gates the playback pass so lanes with no effects skip the chain;
   * fx_enabled carries the per-slot effective enable bits (D-EFFBITS). */
  /* In the engine, not on this thread's stack — see [le_fx_snapshot]. The
   * aliases below keep every reader below reading the same names it did when
   * these were locals. */
  le_fx_snapshot* const snap = &e->fx_snap;
  int32_t(*const fx_count)[LE_MAX_LANES] = snap->lane_count;
  int32_t(*const fx_pre_count)[LE_MAX_LANES] = snap->lane_pre_count;
  int32_t(*const fx_type)[LE_MAX_LANES][LE_FX_MAX] = snap->lane_type;
  float(*const fx_params)[LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS] =
      snap->lane_params;
  int32_t(*const fx_enabled)[LE_MAX_LANES][LE_FX_MAX] = snap->lane_enabled;
  int(*const has_fx)[LE_MAX_LANES] = snap->lane_has;
  snapshot_lane_fx(e, tc, (1u << tc) - 1u, lane_n, fx_count, fx_pre_count, fx_type, fx_params,
                   fx_enabled, has_fx);
  /* "Does ANY lane of this track carry a chain?", folded once per buffer.
   * mix_tracks_frame's per-frame idle-track skip needs it (a chain must keep
   * ticking on silence — tails and LFO phase — so a track with one runs its
   * lane body every frame however silent it is), and folding it there would
   * put an 8-iteration scan back on the very path the skip exists to avoid. */
  int lane_fx_any[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) {
    lane_fx_any[t] = 0;
    for (int l = 0; l < lane_n[t]; ++l) {
      if (has_fx[t][l]) {
        lane_fx_any[t] = 1;
        break;
      }
    }
  }

  /* Track-stage chains (part 1b), snapshotted once per buffer like the lane
   * chains above (see snapshot_track_fx). trk_has_fx is the D-TRACKROUTE
   * topology gate: false (empty chain) keeps the per-lane routing path
   * bit-identical; true engages the per-track stereo bus. */
  int32_t* const trk_fx_count = snap->trk_count;
  int32_t* const trk_fx_pre_count = snap->trk_pre_count;
  int32_t(*const trk_fx_type)[LE_FX_MAX] = snap->trk_type;
  float(*const trk_fx_params)[LE_FX_MAX][LE_FX_PARAMS] = snap->trk_params;
  int32_t(*const trk_fx_enabled)[LE_FX_MAX] = snap->trk_enabled;
  int* const trk_has_fx = snap->trk_has;
  snapshot_track_fx(e, tc, trk_fx_count, trk_fx_pre_count, trk_fx_type,
                    trk_fx_params, trk_fx_enabled, trk_has_fx);

  /* The All tracks recorded-mix chain (slice 3e), one config for every
   * destination. at_has_fx is this stage's topology gate, the track bus's
   * rule exactly: false (empty chain) leaves the tracks routing straight to
   * the outputs as before. */
  int32_t* const at_fx_type = snap->at_type;
  float(*const at_fx_params)[LE_FX_PARAMS] = snap->at_params;
  int32_t* const at_fx_enabled = snap->at_enabled;
  snap->at_pre_count = 0; /* the recorded-mix chain is wholly Post */
  snapshot_bus_fx(&e->all_tracks, &snap->at_count, &snap->at_pre_count,
                  at_fx_type, at_fx_params, at_fx_enabled, &snap->at_has);
  const int32_t at_fx_count = snap->at_count;
  const int at_has_fx = snap->at_has;
  snapshot_all_tracks_instances(e, ch_out, at_fx_count, at_has_fx, at_fx_type);

  /* Loop-stage wet cache (part 2), snapshotted once per buffer (see
   * snapshot_lane_cache): the per-lane published-entry pointer + full key
   * verdict. NULL everywhere until a render publishes — one relaxed load per
   * lane of dormant cost. */
  const le_wet_entry* cache_ent[LE_MAX_TRACKS][LE_MAX_LANES];
  snapshot_lane_cache(e, tc, lane_n, cache_ent);

  /* Each track's whole-track print (slice 3e), same shape, one entry per
   * track. NULL everywhere until a render publishes — one relaxed load per
   * track of dormant cost. */
  const le_wet_entry* track_cache_ent[LE_MAX_TRACKS];
  snapshot_track_cache(e, tc, track_cache_ent);


  /* Per-input live monitor chain, snapshotted once per buffer (see
   * snapshot_monitor_fx). mon_on gates the whole input (loopback exclusion +
   * enable); mute/volume/output/chain drive the single chain. */
  int mon_on[LE_MAX_MONITORED_INPUTS] = {0};
  uint32_t mon_out[LE_MAX_MONITORED_INPUTS];
  float mon_vol[LE_MAX_MONITORED_INPUTS];
  float mon_gl[LE_MAX_MONITORED_INPUTS];
  float mon_gr[LE_MAX_MONITORED_INPUTS];
  float mon_peak[LE_MAX_MONITORED_INPUTS] = {0};
  float in_peak_ch[LE_MAX_CHANNELS] = {0};
  float out_peak_ch[LE_MAX_CHANNELS] = {0};
  int mon_mut[LE_MAX_MONITORED_INPUTS];
  int32_t* const mon_fx_count = snap->mon_count;
  int32_t(*const mon_fx_type)[LE_FX_MAX] = snap->mon_type;
  float(*const mon_fx_params)[LE_FX_MAX][LE_FX_PARAMS] = snap->mon_params;
  int32_t(*const mon_fx_enabled)[LE_FX_MAX] = snap->mon_enabled;
  int* const mon_has_fx = snap->mon_has;
  snapshot_monitor_fx(e, ch_in, excluded, mon_on, mon_out, mon_vol, mon_mut,
                      mon_fx_count, mon_fx_type, mon_fx_params, mon_fx_enabled,
                      mon_has_fx, mon_gl, mon_gr);

  /* Structural output gate, read once per block (a mid-block toggle applies from
   * the next block — RT-safe, no mid-buffer artifact). Intersected into every
   * routing mask so a disabled output is never summed into, while the stored
   * lane/monitor masks stay untouched (re-enabling restores them). */
  const uint32_t out_enabled =
      atomic_load_explicit(&e->a_output_enabled_mask, memory_order_relaxed);

  /* Output buses (slice 3b), snapshotted once per buffer: each bus's chain
   * (see snapshot_bus_fx; an empty chain skips the chain call, and a bus at
   * unity, stereo, centred and unmuted passes bit-exact) and its facts. */
  const int bus_n = (ch_out + 1) / 2;
  le_obus_snap* const obus = snap->obus;
  for (int k = 0; k < bus_n && k < LE_MAX_OUTPUT_BUSES; ++k) {
    snapshot_output_bus(&e->outputs[k], k, ch_out, out_enabled, &obus[k]);
  }
  /* Both policies tap the selected bus after its chain. Follow additionally
   * applies the bus level/mute, leaving Mono/Balance and hardware master
   * controls outside the take. Not armed: no bus taps (perf_bus is -1). */

  /* master_out_ch[0] >= 0 whenever armed (le_perf_arm refuses with no
   * enabled pair), but -1 / 2 truncates to 0 in C, which would tap bus 0 as
   * if it were the capture bus — cheap to rule out, and it keeps this in
   * step with the snapshot's own guard. */
  const int perf_bus = e->perf.armed && e->perf.master_out_ch[0] >= 0
                           ? e->perf.master_out_ch[0] / 2
                           : -1;


  const int fx_cap = e->fx_delay_frames;

  /* Block-constant mix facts (slice 3), read once here like master_gain: the
   * capture trim per input (a direct store; a mid-block change applies from
   * the next block) and the solos of EVERY track, idle ones included, since
   * one soloed track gates every other track's routing. */
  float in_trim[LE_MAX_CHANNELS];
  for (int c = 0; c < ch_in && c < LE_MAX_CHANNELS; ++c) {
    in_trim[c] = load_f32(&e->a_in_trim_bits[c]);
  }
  int solo[LE_MAX_TRACKS];
  int any_solo = 0;
  for (int t = 0; t < tc; ++t) {
    solo[t] = load_i32(&e->tracks[t].a_solo);
    if (solo[t]) any_solo = 1;
  }

  /* Command-drain publications are already included above. Deferred sound,
   * grid and count-in starts can publish another image inside this block. */
  e->capture_image_dirty = 0;
  for (uint32_t f = 0; f < frames; ++f) {
    for (int t = 0; t < tc; ++t)
      e->tracks[t].fade_sample = le_fade_tick(&e->tracks[t].fade, sr);
    /* Input metering + sound-activated record + latency harness. When the harness
     * owns the frame it has already written `out`, so skip the rest. */
    if (process_input_frame(e, in, in_c, out, f, ch_in, ch_out, tc, sr,
                            excluded, &in_sumsq, &in_peak, in_peak_ch,
                            &out_sumsq, perf_frame_base)) {
      continue;
    }

    /* The playhead, read before the transport advances below; also feeds the viz
     * tap. Per-frame outputs of the mix step: st[] (states, for the transport)
     * and the per-track / per-output peaks (for the viz tap — frame_out_peak is
     * filled later by master_bus_frame). */
    const int32_t pos = e->clock.position;
    int32_t st[LE_MAX_TRACKS];
    float frame_out_peak = 0.0f;
    float frame_trk_peak[LE_MAX_TRACKS] = {0};

    /* A deferred image becomes audible at its actual start frame, independent
     * of callback size. Refresh only the affected lane recipes (including
     * channel and enable views); old printed entries must not survive that
     * source/recipe change. Grid/count-in starts after mixing are seen here on
     * the following frame, sound starts above on this same frame. */
    if (e->capture_image_dirty) {
      const uint32_t dirty = e->capture_image_dirty;
      e->capture_image_dirty = 0;
      snapshot_lane_fx(e, tc, dirty, lane_n, fx_count, fx_pre_count, fx_type,
                       fx_params, fx_enabled, has_fx);
      for (int t = 0; t < tc; ++t) {
        if (!(dirty & (1u << t))) continue;
        lane_fx_any[t] = 0;
        for (int l = 0; l < lane_n[t]; ++l) {
          lane_fx_any[t] |= has_fx[t][l];
          cache_ent[t][l] = NULL;
        }
        track_cache_ent[t] = NULL;
        /* Printed playback masks the track Pre bits in this block's view.
         * Restore them too when the image makes that print ineligible, so
         * the live fallback enters the same enable ramp as a split block. */
        snapshot_bus_fx(&e->tracks[t].bus, &trk_fx_count[t],
                         &trk_fx_pre_count[t], trk_fx_type[t],
                         trk_fx_params[t], trk_fx_enabled[t], &trk_has_fx[t]);
      }
    }

    /* Per-lane capture + additive playback mix (see mix_tracks_frame).
     * Reads the CONDITIONED input (in_c): the conditioning stage sits
     * upstream of the lane write by design (WYSIWYG). */
    mix_tracks_frame(e, in_c, out, f, ch_in, ch_out, tc, sr, fx_cap, excluded,
                     out_enabled, overdub_fb, od_step, od_fade_frames, pos,
                     lane_n, lane_fx_any, has_fx, fx_count, fx_pre_count,
                     fx_type, fx_params, fx_enabled,
                     trk_has_fx, trk_fx_count, trk_fx_type, trk_fx_params,
                     trk_fx_enabled, trk_fx_pre_count, track_cache_ent,
                     at_has_fx, at_fx_count, at_fx_type,
                     at_fx_params, at_fx_enabled, cache_ent, lane_sumsq,
                     lane_peak, st,
                     frame_trk_peak, trk_sumsq, trk_peak, trk_lpeak, trk_rpeak,
                     in_trim, solo, any_solo, perf_frame_base);


    /* Per-input live monitoring (see mix_monitors_frame). Reads the
     * CONDITIONED input (in_c): conditioned-clean IS the input's clean, for
     * every consumer at once (WYSIWYG with the lane capture above). */
    mix_monitors_frame(e, in_c, out, f, ch_in, ch_out, sr, fx_cap, out_enabled,
                       mon_on, mon_mut, mon_has_fx, mon_fx_count, mon_fx_type,
                       mon_fx_params, mon_fx_enabled, mon_vol, mon_out, mon_gl,
                       mon_gr, mon_peak);

    /* The click, THEN the output buses, then the master bus (gain + limiter
     * + output metering), then the loop-viz tap, then advance the record
     * heads and master transport — see the static-inline step definitions
     * above le_engine_process. The latency-calibration pulse path bypassed
     * all of this via `continue` above. Dormant click cost: the click_on
     * ternary here plus click_frame's fused compare.
     *
     * The click sums in BEFORE the buses (slice 3b): a destination's chain,
     * level and mute process every source routed there, the click included
     * (accepted design), and the master gain, the limiter, the output
     * metering and the loop viz all see it, where before slice 3b none of
     * them did. click_mask & out_enabled: a structurally disabled output
     * never carries click energy, like every other source's fan-out. */
    const int click_on =
        click_mode != LE_CLICK_OFF ? le_click_gate(e, click_mode, tc, st) : 0;
    grid_beat_frame(e, pos, click_on, nominal_fpb); /* dormant-grid cost: one int compare */
    click_frame(e, out, f, ch_out, click_on, click_mask & out_enabled,
                click_vol, sr, perf_frame_base + f);
    /* Output buses (slice 3b): chain, the pre-level capture tap, level,
     * Mono, balance, mute, per pair, over everything summed above. */
    for (int k = 0; k < bus_n && k < LE_MAX_OUTPUT_BUSES; ++k) {
      const int tap_here = k == perf_bus;
      if (!obus[k].active && !tap_here) continue;
      output_bus_frame(e, out, f, ch_out, sr, fx_cap, k, &obus[k], tap_here);
    }
    master_bus_frame(e, out, f, ch_out, master_gain, limiter_on, limiter_ceiling,
                     lim_release, &out_sumsq, &frame_out_peak, out_peak_ch);
    if (frame_out_peak > out_peak) out_peak = frame_out_peak;

    viz_tap_frame(e, pos, frame_out_peak);
    track_viz_tap_frame(e, tc, st, frame_trk_peak);
    advance_transport_frame(e, tc, st, perf_frame_base + f);
  }

  /* Input RMS is normalised by the active (non-loopback) channel count only. */
  const uint32_t total_in = frames * (uint32_t)active_in;
  const uint32_t total_out = frames * (uint32_t)ch_out;
  store_f32(&e->a_in_rms_bits,
            total_in ? sqrtf(in_sumsq / (float)total_in) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  /* Per-channel meters (slice 3): the channels the device has; configure
   * zeroed every entry, so nothing stale survives a smaller device. */
  for (int c = 0; c < ch_in && c < LE_MAX_CHANNELS; ++c) {
    store_f32(&e->a_in_peak_ch_bits[c], in_peak_ch[c]);
    store_f32(&e->monitors[c].a_peak_bits, mon_peak[c]);
  }
  for (int c = 0; c < ch_out && c < LE_MAX_CHANNELS; ++c) {
    store_f32(&e->a_out_peak_ch_bits[c], out_peak_ch[c]);
  }
  store_f32(&e->a_out_rms_bits,
            total_out ? sqrtf(out_sumsq / (float)total_out) : 0.0f);
  store_f32(&e->a_out_peak_bits, out_peak);
  /* The tuner reads the CONDITIONED input too — pitch detection benefits from
   * the hum notches exactly like the lane capture does. */
  tuner_tap_block(e, in_c, frames, ch_in, sr);
  for (int t = 0; t < tc; ++t) {
    /* Lane buffers are mono: one loop sample accumulated per frame. The shared
     * write head publishes the same growing length onto every active lane. */
    const int32_t tstate = load_i32(&e->tracks[t].a_state);
    const int recording = tstate == LE_TRACK_RECORDING;
    /* #595: an overdub writes the lanes too (backup-on-write + layer sum). */
    const int capturing = recording || tstate == LE_TRACK_OVERDUBBING;
    const int32_t rp = e->tracks[t].record_pos;
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      store_f32(&ln->a_rms_bits,
                frames ? sqrtf(lane_sumsq[t][l] / (float)frames) : 0.0f);
      store_f32(&ln->a_peak_bits, lane_peak[t][l]);
      if (recording) store_i32(&ln->a_len, rp > 0 ? rp : 0);
      /* #595: latch "this lane captured audio it could still give back" on
       * exactly the WRITING lanes — the in-range-input predicate mirrors the
       * per-frame capture in mix_tracks_frame (an out-of-range or unrouted
       * lane writes nothing and must not read recoverable: a_len alone can't
       * tell, the shared write head grows it on every active lane). Reads the
       * same a_input_channel that loop read this block — commands drain
       * before the frame loop, so the value cannot have moved. Once per
       * block, store-once (the load guard keeps the steady state read-only).
       * Cleared only on the control thread (history death / lane reset). */
      if (capturing && !load_i32(&ln->a_recoverable)) {
        const int32_t ic = load_i32(&ln->a_input_channel);
        if (ic >= 0 && ic < ch_in) store_i32(&ln->a_recoverable, 1);
      }
    }
    store_f32(&e->tracks[t].a_trk_rms_bits,
              frames ? sqrtf(trk_sumsq[t] / (float)frames) : 0.0f);
    store_f32(&e->tracks[t].a_trk_peak_bits, trk_peak[t]);
    if (!e->tracks[t].pending_record &&
        !(e->launch_action[t] != 0)) {
      e->tracks[t].pending_image.revision = 0;
      e->tracks[t].pending_capture_shadow = 0;
    }
    store_f32(&e->tracks[t].a_trk_peak_l_bits, trk_lpeak[t]);
    store_f32(&e->tracks[t].a_trk_peak_r_bits, trk_rpeak[t]);
    /* The track's own playhead: the write head while its take is still being
     * defined (no length to play against yet), the mixer's read index
     * otherwise — see le_track_snapshot.position_frames. */
    store_i32(&e->tracks[t].a_play_pos,
              tstate == LE_TRACK_EMPTY ? 0
              : recording              ? rp
                                       : e->trk_play_pos[t]);
  }
  store_i32(&e->a_master_pos, e->clock.position);
  atomic_fetch_add_explicit(&e->a_frames, (uint64_t)frames,
                            memory_order_relaxed);
  /* Tap-tempo frame clock, advanced once per block (taps arrive via the ring,
   * which drains before the frame loop, so block granularity IS the command's
   * real timing resolution — no per-frame work on the hot path). */
  e->frame_clock += (uint64_t)frames;
  /* Elapsed-frames-since-arm, batched once per block like a_frames above
   * (armed is fixed for the whole call — commands drain before the frame
   * loop starts) rather than a per-frame atomic add. Counts every frame this
   * call processed, including ones the latency harness diverted, so it reads
   * as wall-clock frames since arm, not samples the master tap actually
   * captured. */
  /* RELEASE, not relaxed (#710): this add is the drain thread's "the rings
   * already hold this many frames" signal, and the whole silence-fill
   * decision rests on it. Every capture tap earlier in this call published
   * its frames with a RELEASE store on the ring's tail — but release is
   * one-way. It orders the sample writes before that tail store; it does
   * NOT stop a later relaxed store from becoming visible first. A relaxed
   * fetch_add here could therefore be observed by the drain BEFORE the tail
   * stores it is meant to vouch for, on any weakly-ordered machine (the Pi 5
   * console, Apple Silicon) — the drain would read a frame count the rings
   * cannot yet show it and pad silence over audio that is genuinely there.
   * Releasing here makes the drain's ACQUIRE load of a_perf_frames
   * synchronize-with this add, so everything sequenced before it — every
   * tail store — is visible to the pops that follow. */
  if (e->perf.armed) {
    atomic_fetch_add_explicit(&e->a_perf_frames, (uint64_t)frames,
                              memory_order_release);
  }

  /* MIDI clock send (C1, D15). BLOCK granularity, like the tap-tempo frame
   * clock above: the emitter is driven once per le_engine_process call with
   * this call's whole frame count, not per-sample — MIDI clock's practical
   * timing tolerance is well inside one audio block (a few ms at typical
   * buffer sizes), and every other block-rate decision in this function
   * (limiter params, click bus settings, master gain) already uses this same
   * granularity. `transport_active` reads the states AFTER this block's
   * transport advances above, so a track that started/stopped mid-block is
   * reflected from the very next call — le_transport_held is the exact
   * negation this needs (see its own doc for why it's the audio-thread twin
   * of le_transport_active on the control side). Bytes are appended to
   * midi_clock_ring (RT-safe: bounded push, no allocation/lock/syscall) for
   * whatever forwards them to le_midi_out_send — see le_midi_clock.h. */
  {
    int32_t num = load_i32(&e->a_ts_num);
    if (num <= 0) num = 4;
    uint8_t clock_bytes[32];
    const int32_t clock_n = le_midi_clock_advance(
        &e->midi_clock, (int32_t)frames, load_f32(&e->a_tempo_bpm_bits), num,
        load_i32(&e->a_ts_den), sr, !le_transport_held(e),
        le_clock_send_gate_open(e), clock_bytes, (int32_t)sizeof(clock_bytes));
    for (int32_t i = 0; i < clock_n; ++i) {
      if (!le_ring_push(&e->midi_clock_ring,
                        (le_command){.code = clock_bytes[i]})) {
        atomic_fetch_add_explicit(&e->a_midi_clock_overruns, 1u,
                                  memory_order_relaxed);
      }
    }
  }
  for (int t = 0; t < e->track_count; ++t) {
    le_track* tr = &e->tracks[t];
    const int state = load_i32(&tr->a_state);
    const int readable =
        (state == LE_TRACK_PLAYING || state == LE_TRACK_STOPPED) &&
        !tr->pending_record && !tr->seam_capture && !tr->xfade_capture &&
        tr->od_gain == 0.0f && !load_i32(&tr->a_layer_in_flight) &&
        !(e->launch_action[t] != 0);
    atomic_store_explicit(&tr->a_pending_image_revision, tr->pending_image.revision, memory_order_release);
    atomic_store_explicit(&tr->a_cache_source_readable, readable,
                           memory_order_release);
  }
  /* Session capture waits on publication, not a ring that becomes empty
   * before its last command is applied. Release covers every snapshot store
   * above; the control-side query acquires it before reading that snapshot. */
  if (e->record_timing_publish_pending) {
    atomic_store_explicit(&e->a_record_timing_revision,
                          e->record_timing_publish_revision, memory_order_seq_cst);
    e->record_timing_publish_pending = 0;
  }
  if (e->click_mode_publish_pending) {
    atomic_store_explicit(&e->a_click_mode_revision,
                          e->click_mode_publish_revision, memory_order_relaxed);
    e->click_mode_publish_pending = 0;
  }
  if (e->record_start_publish_pending) {
    atomic_store_explicit(&e->a_record_start_revision,
                          e->record_start_publish_revision, memory_order_relaxed);
    e->record_start_publish_pending = 0;
  }
  for (int t = 0; t < tc; ++t) le_fade_publish(e, &e->tracks[t]);
  atomic_store_explicit(&e->a_commands_published, e->commands_applied,
                         memory_order_release);
}
