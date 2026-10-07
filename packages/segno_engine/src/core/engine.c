/*
 * engine.c — the engine's control-thread core, after the S1 split.
 *
 * What remains here: engine lifecycle (le_engine_create / destroy / configure /
 * start / stop / mark_started), the lane / monitor reset helpers, the shared
 * low-level helpers declared in engine_core.h (le_track_set_len, le_mask_to_channel,
 * valid_channel, le_push), the version / device-name / measure-latency thin
 * wrappers, and the deterministic-test entry points (engine_internal.h).
 *
 * The rest of the original monolith now lives in sibling TUs, all behind the
 * unchanged segno_engine_api.h ABI:
 *   - engine_process.c   the real-time core (le_engine_process, transport state
 *                        machine, apply_command, latency harness) — the one
 *                        audio-thread TU, where the no-alloc/no-lock RT contract
 *                        holds.
 *   - engine_commands.c  control-thread command producers (the FFI setters,
 *                        record/undo machinery, lazy fx/lane allocation).
 *   - engine_fx.c        the effects DSP island (kernels, octaver, reverb, chain).
 *   - engine_devices.c   device discovery, loopback detection, backend selection.
 *   - engine_snapshot.c  published-state snapshots + visualization reads.
 *   - engine_session.c   session export / import / commit.
 *   - engine_convert.c   pure sample-format conversion + ASIO buffer math.
 *
 * Multi-track model (unchanged): a shared master loop clock plus N independent
 * tracks; the first to finish recording defines the master length, and one-level
 * undo stays RT-safe because the pre-overdub snapshot is taken on the calling
 * (Dart) thread (engine_commands.c) so the audio thread only swaps a buffer index.
 */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h" /* le_audio_ring_release (capture-ring teardown) */
#include "engine_cache.h" /* le_cache_init/shutdown (wet-cache lifecycle) */
#include "engine_render.h" /* le_render_destroy (render recipe jobs) */
#include "engine_restore.h" /* le_restore_init/shutdown (restoration worker) */
#include "engine_core.h" /* shared low-level helpers: le_push, valid_channel, ... */
#include "../host/plugin_slot.h" /* le_plugin_slot_destroy (teardown of slots) */
#include "engine_fx.h" /* effects DSP island: chain runner, reset/free, latency */
#include "engine_internal.h"
#include "engine_miniaudio.h"
#include "engine_platform.h"
#include "engine_private.h"
#include "le_midi_clock.h" /* le_midi_clock_reset (C1 clock-send generator) */
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "segno_engine_api.h"
#include "miniaudio.h"
#include "perf_drain.h" /* le_perf_drain_stop (reconfigure/destroy teardown) */
#include "perf_render.h" /* le_perf_render_cancel (reconfigure/destroy teardown) */
#include "tempo_grid.h" /* LE_GRID_DIV_OFF (grid-off quantize default) */

/* All platform-specific behavior (CoreAudio channel labels, JACK port-pinning,
 * PipeWire quantum forcing) lives behind the engine_platform.h seam, implemented
 * per OS in engine_apple.c / engine_linux.c / engine_windows.c. This file is
 * platform-agnostic — no #if defined(__APPLE__|__linux__|_WIN32) behavior. */


/* struct le_engine and its nested types (le_fx_state, le_lane,
 * le_monitor_input, le_track) plus LE_RING_CAPACITY / LE_POOL_SLOTS now live in
 * engine_private.h, shared with the per-OS translation units (engine_linux.c /
 * engine_apple.c / engine_windows.c). */

/* The float/double <-> atomic-bits helpers (f32_to_bits / load_f32 / …) and the
 * int32 helpers (load_i32 / store_i32) are static inline in engine_private.h,
 * shared by every engine TU. comp_pos and le_lanes_active are static inline in
 * engine_core.h. */

/* Publishes a recorded length onto every active lane of a track (all lanes of a
 * track share the one transport, so they share the length). Declared in
 * engine_core.h. */
void le_track_set_len(le_track* t, int32_t len) {
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) store_i32(&t->lanes[l].a_len, len);
}

/* Ensures a pool slot holds >= [frames] frames (control thread; declared in
 * engine_core.h). Undo layers are quantized to the loop length, so a reused
 * slot may need to grow before serving a longer track — or to the full
 * max_loop_frames before becoming a recording target. Replaces rather than
 * preserves: every consumer writes the slot whole before it is read. */
int le_lane_ensure_slot(le_lane* ln, int32_t slot, int32_t frames) {
  if (frames <= 0) return 0;
  if (ln->pool[slot] != NULL && ln->pool_cap[slot] >= frames) return 1;
  free(ln->pool[slot]);
  ln->pool[slot] = (float*)calloc((size_t)frames, sizeof(float));
  ln->pool_cap[slot] = ln->pool[slot] != NULL ? frames : 0;
  return ln->pool[slot] != NULL;
}

/* Shrinks an over-allocated slot to `frames`, PRESERVING the leading `frames`
 * samples (the counterpart to le_lane_ensure_slot's grow-by-replace). Only the
 * control thread may call it, and only for a slot the audio thread no longer
 * holds — a retired undo layer, whose cap-sized buffer would otherwise pin the
 * whole recording cap for the session (see le_handle_retired). A failed realloc
 * keeps the oversized buffer: correct, just not yet reclaimed. */
void le_lane_shrink_slot(le_lane* ln, int32_t slot, int32_t frames) {
  if (frames <= 0 || ln->pool[slot] == NULL) return;
  if (ln->pool_cap[slot] <= frames) return;
  float* p = (float*)realloc(ln->pool[slot], (size_t)frames * sizeof(float));
  if (p == NULL) return;
  ln->pool[slot] = p;
  ln->pool_cap[slot] = frames;
}

/* Lowest set bit of `mask` as a channel index, or -1 when no bit is set. Used to
 * collapse a legacy track input bitmask into lane 0's single input channel. */
int32_t le_mask_to_channel(uint32_t mask) {
  if (mask == 0u) return -1;
  int32_t c = 0;
  while (!(mask & 1u)) {
    mask >>= 1;
    ++c;
  }
  return c;
}


int valid_channel(le_engine* e, int32_t ch) {
  return ch >= 0 && ch < e->track_count;
}

/* The entire audio-thread core — le_engine_process plus the transport state
 * machine (finalize_* / handle_* / close_active_capture), apply_command,
 * le_latency_resolve, le_fx_route, le_flush_denormals, and the latency / auto-
 * record tuning constants — moved to engine_process.c (S1). The miniaudio data +
 * notification callbacks, device-config build, and device lifecycle live behind
 * the device-backend seam in engine_miniaudio.c. This file keeps the control-
 * thread lifecycle dispatch (configure/start/stop/create/destroy) and the lane /
 * monitor reset helpers; the looper/effects setters are in engine_commands.c. */

/* ---- configuration / lifecycle ---- */

/* Resets a lane's SETTINGS — routing, live mix, mute, effects, metering and
 * cache bookkeeping — to defaults (recording hardware input [input_channel]),
 * clearing its effect DSP state and releasing its delay lines. Leaves the
 * lane's MATERIAL alone: the pool buffers, a_live, a_len, a_recoverable and
 * the recorded source image (image_gain / image_pan describe how the take was
 * captured, and travel with it). The published mix is recomposed from the
 * default live mix and the retained image, the same composition the audio
 * thread's le_publish_lane_mix performs. Control thread only, device closed:
 * used by le_engine_configure (through le_lane_reset) and by a retained
 * reopen (le_engine_reopen_configured), where the repository replays its
 * routing and mix afterwards. */
void le_lane_reset_settings(le_lane* ln, int32_t input_channel) {
  /* Wet cache (part 2): a reset lane has no cached identity, so retract any
   * published entry pointer. Never a leak: the entry object itself stays
   * owned (and eventually freed) by engine_cache.c's per-lane bookkeeping —
   * configure's reset runs after le_cache_shutdown already freed and nulled
   * everything, and a mid-session (re)activation via le_engine_set_lane_count
   * leaves the entry in the cache's tables for the tick's deactivated-lane
   * reclaim / LRU to collect. */
  atomic_store_explicit(&ln->a_wet, NULL, memory_order_release);
  store_i32(&ln->a_cache_active, 0);
  ln->cache_fp_entry = NULL; /* audio-local fp-verdict cache dies with it */
  ln->cache_fp_gen = 0;
  le_lane_fx_gen_bump(ln); /* the reset rewrites the whole chain below */
  atomic_store_explicit(&ln->a_input_channel, input_channel,
                        memory_order_relaxed);
  atomic_store_explicit(&ln->a_output_mask, 0x3u, memory_order_relaxed);
  ln->live_level = 1.0f;
  ln->live_pan = 0.0f;
  {
    const float pan =
        fmaxf(-1.0f, fminf(1.0f, ln->live_pan + ln->image_pan));
    float gl;
    float gr;
    le_pan_gains(pan, &gl, &gr);
    store_f32(&ln->a_vol_bits, ln->live_level * ln->image_gain);
    store_f32(&ln->a_pan_bits, pan);
    store_f32(&ln->a_pan_gl_bits, gl);
    store_f32(&ln->a_pan_gr_bits, gr);
  }
  store_i32(&ln->a_muted, 0);
  ln->pending_mute = 0;
  store_f32(&ln->a_rms_bits, 0.0f);
  store_f32(&ln->a_peak_bits, 0.0f);
  atomic_store_explicit(&ln->a_fx_recipe_revision, 0, memory_order_relaxed);
  store_i32(&ln->a_fx_count, 0);
  store_i32(&ln->a_fx_chain_enabled, 1);
  ln->fx_count_pushed = 0;
  ln->fx.enable_clear_cooldown = 0;
  ln->fx.chan_any = 0;
  for (int s = 0; s < LE_FX_MAX; ++s) {
    ln->fx_type_pushed[s] = LE_FX_NONE;
    store_i32(&ln->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&ln->a_fx_param[s][p], 0.0f);
    }
    /* Enable flags default 1 with the crossfade runtime SETTLED at that
     * target, so a fresh chain does not fade in on first use. */
    store_i32(&ln->a_fx_enabled[s], 1);
    /* Channel handling defaults (slice 3e): stereo in, stereo out, centre and
     * unity — the shape the audio thread reads as "nothing to do". */
    store_i32(&ln->a_fx_chan_in[s], LE_FX_CHAN_IN_STEREO);
    store_i32(&ln->a_fx_chan_out[s], LE_FX_CHAN_OUT_STEREO);
    store_f32(&ln->a_fx_chan_pan_bits[s], 0.0f);
    store_f32(&ln->a_fx_chan_gl_bits[s], 1.0f);
    store_f32(&ln->a_fx_chan_gr_bits[s], 1.0f);
    store_f32(&ln->a_fx_chan_level_bits[s], 1.0f);
    le_fx_enable_seed_settled(&ln->fx, s);
    free(ln->fx.delay[s][0]);
    ln->fx.delay[s][0] = NULL;
    free(ln->fx.delay[s][1]);
    ln->fx.delay[s][1] = NULL;
    le_fx_free_octaver(&ln->fx, s);
    le_fx_entry_reset(&ln->fx, s);
    /* Destroy any hosted plugin slot too. Reset runs from le_engine_configure
     * while the device is closed (no audio thread), so a direct destroy is safe
     * — mirrors le_engine_destroy. Without this, a start→stop→start or any
     * reconfigure leaks the live IPluginHost and its loaded plugin binary. */
    le_plugin_slot_destroy(
        atomic_load_explicit(&ln->fx.plugin[s], memory_order_relaxed));
    atomic_store_explicit(&ln->fx.plugin[s], NULL, memory_order_relaxed);
  }
}

/* Resets a lane entirely — its settings (le_lane_reset_settings) AND its
 * material bookkeeping: the lane holds nothing afterwards. Does NOT touch the
 * pool buffers — the caller owns allocation. Used at configure and when a
 * lane is (re)activated by a growing lane count. */
void le_lane_reset(le_lane* ln, int32_t input_channel) {
  ln->image_gain = 1.0f;
  ln->image_pan = 0.0f;
  le_lane_reset_settings(ln, input_channel);
  store_i32(&ln->a_live, 0);
  store_i32(&ln->a_len, 0);
  store_i32(&ln->a_recoverable, 0); /* #595: a reset lane holds nothing */
}

/* Resets a live monitor input to defaults: disabled, full stereo output, unity
 * volume, unmuted, and an empty (clean) single chain — clearing its effect DSP
 * state and releasing its delay lines. Used at configure. */
static void le_monitor_input_reset(le_monitor_input* m) {
  store_i32(&m->a_enabled, 0);
  atomic_store_explicit(&m->a_output_mask, 0x3u, memory_order_relaxed);
  store_f32(&m->a_vol_bits, 1.0f);
  store_f32(&m->a_pan_bits, 0.0f);
  store_f32(&m->a_pan_gl_bits, 1.0f);
  store_f32(&m->a_pan_gr_bits, 1.0f);
  store_i32(&m->a_muted, 0);
  store_f32(&m->a_peak_bits, 0.0f);
  atomic_store_explicit(&m->a_fx_recipe_revision, 0, memory_order_relaxed);
  store_i32(&m->a_fx_count, 0);
  store_i32(&m->a_fx_chain_enabled, 1);
  m->fx_count_pushed = 0;
  m->fx.enable_clear_cooldown = 0;
  m->fx.chan_any = 0;
  for (int s = 0; s < LE_FX_MAX; ++s) {
    m->fx_type_pushed[s] = LE_FX_NONE;
    store_i32(&m->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&m->a_fx_param[s][p], 0.0f);
    }
    /* Enable flags default 1, crossfade runtime settled (see le_lane_reset). */
    store_i32(&m->a_fx_enabled[s], 1);
    /* Channel handling defaults (slice 3e): stereo in, stereo out, centre and
     * unity — the shape the audio thread reads as "nothing to do". */
    store_i32(&m->a_fx_chan_in[s], LE_FX_CHAN_IN_STEREO);
    store_i32(&m->a_fx_chan_out[s], LE_FX_CHAN_OUT_STEREO);
    store_f32(&m->a_fx_chan_pan_bits[s], 0.0f);
    store_f32(&m->a_fx_chan_gl_bits[s], 1.0f);
    store_f32(&m->a_fx_chan_gr_bits[s], 1.0f);
    store_f32(&m->a_fx_chan_level_bits[s], 1.0f);
    le_fx_enable_seed_settled(&m->fx, s);
    free(m->fx.delay[s][0]);
    m->fx.delay[s][0] = NULL;
    free(m->fx.delay[s][1]);
    m->fx.delay[s][1] = NULL;
    le_fx_free_octaver(&m->fx, s);
    le_fx_entry_reset(&m->fx, s);
    /* Destroy any hosted plugin slot too (see le_lane_reset) — otherwise a
     * reconfigure leaks the monitor input's live plugin host + binary. */
    le_plugin_slot_destroy(
        atomic_load_explicit(&m->fx.plugin[s], memory_order_relaxed));
    atomic_store_explicit(&m->fx.plugin[s], NULL, memory_order_relaxed);
  }
}

/* Resets a bus-stage chain owner (a track's Track-stage chain or the engine's
 * Master insert, le_fx_bus) to defaults: empty chain, every enable flag 1 —
 * clearing its effect DSP state and releasing its delay lines, exactly the
 * chain block of le_monitor_input_reset. An empty chain is the dry path, so a
 * fresh engine and an old session behave bit-identically. Used at configure. */
static void le_fx_bus_reset(le_fx_bus* b) {
  atomic_store_explicit(&b->a_fx_recipe_revision, 0, memory_order_relaxed);
  store_i32(&b->a_fx_count, 0);
  store_i32(&b->a_fx_pre_count, 0);
  store_i32(&b->a_fx_chain_enabled, 1);
  b->fx_count_pushed = 0;
  b->fx.enable_clear_cooldown = 0;
  b->fx.chan_any = 0;
  for (int s = 0; s < LE_FX_MAX; ++s) {
    b->fx_type_pushed[s] = LE_FX_NONE;
    store_i32(&b->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&b->a_fx_param[s][p], 0.0f);
    }
    /* Enable flags default 1, crossfade runtime settled (see le_lane_reset). */
    store_i32(&b->a_fx_enabled[s], 1);
    /* Channel handling defaults (slice 3e): stereo in, stereo out, centre and
     * unity — the shape the audio thread reads as "nothing to do". */
    store_i32(&b->a_fx_chan_in[s], LE_FX_CHAN_IN_STEREO);
    store_i32(&b->a_fx_chan_out[s], LE_FX_CHAN_OUT_STEREO);
    store_f32(&b->a_fx_chan_pan_bits[s], 0.0f);
    store_f32(&b->a_fx_chan_gl_bits[s], 1.0f);
    store_f32(&b->a_fx_chan_gr_bits[s], 1.0f);
    store_f32(&b->a_fx_chan_level_bits[s], 1.0f);
    le_fx_enable_seed_settled(&b->fx, s);
    free(b->fx.delay[s][0]);
    b->fx.delay[s][0] = NULL;
    free(b->fx.delay[s][1]);
    b->fx.delay[s][1] = NULL;
    le_fx_free_octaver(&b->fx, s);
    le_fx_entry_reset(&b->fx, s);
    /* No plugin-slot loading targets the bus owners yet (built-in effects
     * only through the track/master setters), but destroy defensively like
     * the lane/monitor resets so a future seam cannot leak here. */
    le_plugin_slot_destroy(
        atomic_load_explicit(&b->fx.plugin[s], memory_order_relaxed));
    atomic_store_explicit(&b->fx.plugin[s], NULL, memory_order_relaxed);
  }
}

/* Resets one output bus (slice 3b): unity, unmuted, stereo, centred, empty
 * chain. */
static void le_output_bus_reset(le_output_bus* o) {
  store_f32(&o->a_level_bits, 1.0f);
  store_i32(&o->a_muted, 0);
  store_i32(&o->a_mono, 0);
  store_f32(&o->a_balance_bits, 0.0f);
  store_f32(&o->a_bal_gl_bits, 1.0f);
  store_f32(&o->a_bal_gr_bits, 1.0f);
  le_fx_bus_reset(&o->fx);
}

/* Clamps a requested device shape to the engine's working ranges: the one
 * place the defaults live, so le_engine_configure and the reopen retention
 * test (le_engine_reopen_configured) compare like with like. */
static void le_clamp_shape(int32_t* sample_rate, int32_t* input_channels,
                           int32_t* output_channels,
                           int32_t* max_loop_frames) {
  if (*input_channels <= 0) *input_channels = 2;
  if (*input_channels > LE_MAX_CHANNELS) *input_channels = LE_MAX_CHANNELS;
  if (*output_channels <= 0) *output_channels = 2;
  if (*output_channels > LE_MAX_CHANNELS) *output_channels = LE_MAX_CHANNELS;
  if (*sample_rate <= 0) *sample_rate = 48000;
  /* Default cap of 30 s/track keeps total memory modest across all tracks
   * (live + undo). Longer loops are configurable; stream-to-disk is deferred. */
  if (*max_loop_frames <= 0) *max_loop_frames = *sample_rate * 30;
}

/* Joins every background worker and ends a performance capture BEFORE any
 * other engine field moves — the first step of both le_engine_configure and
 * a retained reopen. */
static void le_engine_quiesce_workers(le_engine* engine) {
  /* Loop-stage wet cache (part 2, [R2](d)): join the render worker and free
   * every cache allocation BEFORE any pool buffer is freed or re-pointed —
   * the worker's enqueue copies read pool memory, and the entries' wet buffers
   * are about to lose their owner struct. Re-initialized by
   * le_engine_reset_runtime once the pools are settled. */
  le_fx_recipe_collect(engine, 1);
  le_cache_shutdown(engine);
  le_bounce_abandon_all(engine); /* #1202: no callback will apply them */
  /* Offline restoration worker (#697 S9, [R2](d)): join before the pools are
   * touched — its enqueue copies read pool memory. */
  le_restore_shutdown(engine);

  /* Performance-recording capture: stop and join the drain thread — if
   * still armed here, the engine is being reconfigured mid-session (a
   * device/sample-rate change) — BEFORE touching ANY other engine field
   * below. The drain thread is a real background thread (unlike the rest of
   * the engine's state, which the audio thread alone would otherwise
   * race) and reads engine->sample_rate / perf.master_channels /
   * perf.input_mask directly (safe only because they are fixed for the
   * whole armed session); mutating them first and stopping the thread
   * second would let it observe a torn or already-new value mid-flush. The
   * rings themselves are freed after (mirrors the ring-drop below): the
   * device is stopped during configure (no audio thread), so freeing is
   * race-free once the drain thread — the rings' other reader — has been
   * joined here. A retained reopen ends the capture the same way: the
   * device the take was recorded through is gone (DEVICE_CHANGED, #1140). */
  if (engine->perf.drain != NULL) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DEVICE_CHANGED);
    engine->perf.drain = NULL;
  }
  /* An active render is independent of the arm/drain lifecycle above, but
   * still owned by this engine's perf struct (about to be zeroed below) —
   * cancel+join it first so a reconfigure never orphans its worker thread
   * (uncancellable, unpollable, and leaked once the handle is lost). */
  le_perf_render_cancel(engine);
  le_audio_ring_release(&engine->perf.master_ring);
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_audio_ring_release(&engine->perf.monitor_ring[c]);
  }
  /* Layers staged after the drain thread died (its self-stop on a write
   * failure precedes the final drain cycle) are still heap-owned by this
   * ring — free them before the struct zero below loses the pointers. */
  le_layer_staging_ring_drain_free(&engine->perf.layer_staging_ring);
  engine->perf = (le_perf_capture){0};
  store_i32(&engine->a_perf_armed, 0);
  atomic_store_explicit(&engine->a_perf_frames, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_overruns, 0u, memory_order_relaxed);
  /* a_perf_zero_filled_frames is deliberately NOT cleared here (#710).
   * le_perf_arm resets it, so a fresh capture always starts at zero — this
   * store would be redundant, and worse than redundant: a device change
   * reconfigures the engine between the drain thread's final cycle and the
   * app's finalize, and the app reads this counter at `done` precisely to
   * catch a glitch from that last cycle. Clearing it here would erase the one
   * reading the app came for, on exactly the abnormal stop most likely to
   * have glitched. */
}

/* Empties the engine of recorded MATERIAL: every lane's pool buffers, the
 * undo/redo history, each track's content state, multiple and take identity,
 * the Fade envelopes, the loop clock's length and the crown. Everything a
 * retained reopen (#1140) keeps is exactly what this function touches —
 * le_engine_reset_runtime below never writes any of it, so the two together
 * are le_engine_configure and le_engine_reset_runtime alone is the retained
 * reopen. Returns 0 when lane 0's live buffer could not be allocated. */
static int le_engine_reset_material(le_engine* engine,
                                    int32_t max_loop_frames) {
  /* Speed resets with the material (#1179, plan decision 9). */
  engine->speed_numer = 1;
  engine->speed_denom = 1;
  store_i32(&engine->a_speed_ratio, le_speed_pack(1, 1));
  engine->transpose_bypass = 0;
  store_i32(&engine->a_transpose_bypass, 0);
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    /* Track transport: one lane active by default, empty, one base loop. */
    atomic_store_explicit(&tr->lane_count, 1, memory_order_release);
    tr->undo_count = 0;
    tr->redo_count = 0;
    store_i32(&tr->a_state, LE_TRACK_EMPTY);
    tr->fade = (le_fade){1.0, 1.0f, 0.0f};
    tr->fade_sample = 1.0f;
    tr->fade_generation = 1;
    atomic_store(&tr->a_fade_revision, 0);
    atomic_store(&tr->a_fade_generation, 1);
    store_f32(&tr->a_fade_amount, 1.0f);
    store_f32(&tr->a_fade_target, 1.0f);
    store_f32(&tr->a_fade_seconds, 0.0f);
    /* The lifetime field is rewritten by le_engine_reset_runtime once it has
     * bumped the lifetime; the next snapshot read refreshes the rest. */
    tr->fade_cache = (le_fade_image){1, 1, 0, engine->fade_lifetime, 1};
    tr->fade_cache_revision = 0;
    /* direction is material (#1162): a reopen keeps it; so is the rate */
    tr->head = (le_read_head){0, 0.0, 1.0};
    store_i32(&tr->a_reversed, 0);
    store_i32(&tr->a_head_rate_milli, 1000);
    tr->transpose_st = 0; /* pitch is material too (#1179) */
    store_i32(&tr->a_transpose_st, 0);
    le_track_forget_slot_keys(tr); /* no slot holds a keyed take any more */
    tr->pass_key = 0;
    store_i32(&tr->a_undo_depth, 0);
    store_i32(&tr->a_clear_restore, 0);
    store_i32(&tr->a_redo_depth, 0);
    store_i32(&tr->a_peel_depth, 0);
    store_i32(&tr->a_multiple, 1);
    store_i32(&tr->a_sync_divisor, 0); /* B3: per-track, resets like a_multiple */
    tr->take_seq = 0; /* #819: fresh session, take ids restart at 1 */
    store_i32(&tr->a_settled_take_id, 0);
    tr->empty_len = 0;
    tr->clear_restore_slot = -1;
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &tr->lanes[l];
      /* Free any buffers from a previous configuration. */
      for (int i = 0; i < LE_POOL_SLOTS; ++i) {
        free(ln->pool[i]);
        ln->pool[i] = NULL;
        ln->pool_cap[i] = 0;
      }
      ln->image_gain = 1.0f;
      ln->image_pan = 0.0f;
      store_i32(&ln->a_live, 0);
      store_i32(&ln->a_len, 0);
      store_i32(&ln->a_recoverable, 0); /* #595: an empty lane holds nothing */
    }
    /* Only lane 0 is active by default; allocate its live buffer now at the
     * full recording cap (further lanes' buffers and all undo snapshots
     * allocate lazily, undo layers at the loop-length quantum). */
    if (!le_lane_ensure_slot(&tr->lanes[0], 0, max_loop_frames)) return 0;
    /* Free mode (B2b): each track's own clock resets alongside the master's —
     * a fresh configure/session must never carry a stale established length
     * from a previous run into the first Free-mode recording. */
    le_loop_clock_reset(&tr->free_clock);
  }
  /* Every track is EMPTY now, and an empty rig has no crown: the first take
   * completed on the reconfigured rig is crowned by le_primary_reconcile, and
   * a designation left over from before the restart must not pre-empt it
   * (it would also make le_is_reestablishing_primary force that track's next
   * take to one base loop). Same rule the audio thread keeps live. */
  store_i32(&engine->a_primary_track, -1);
  le_loop_clock_reset(&engine->clock);
  store_i32(&engine->a_master_len, 0);
  /* The loop-derived half of the tempo grid dies with the loop; the SETTINGS
   * (tempo, signature, sync, granularity) persist, see le_engine_create. */
  engine->grid_total_beats = 0;
  store_i32(&engine->a_loop_bars, 0);
  return 1;
}

/* Resets every RUNTIME field for a new device session — the command/event
 * rings and their counters, per-track pending/launch/count-in/seam/dub
 * bookkeeping, the lane/monitor/bus settings the repository replays, the
 * transport POSITION (never the loop length), visualization, the device
 * shape, workers — and marks the engine configured. Never writes material:
 * see le_engine_reset_material for the exact boundary. Device closed; the
 * caller has already quiesced the workers. */
static void le_engine_reset_runtime(le_engine* engine, int32_t sample_rate,
                                    int32_t input_channels,
                                    int32_t output_channels,
                                    int32_t max_loop_frames) {
  /* Lane buffers are mono: one input channel in, routed out via the mask. */
  engine->track_count = LE_MAX_TRACKS;
  atomic_store_explicit(&engine->a_record_timing_default, 0, memory_order_seq_cst);
  atomic_store_explicit(&engine->a_quantize_div, 0, memory_order_seq_cst);
  atomic_store_explicit(&engine->a_record_timing_revision, 0, memory_order_seq_cst);
  atomic_store_explicit(&engine->a_record_timing_result, LE_OK, memory_order_seq_cst);
  engine->record_timing_posted_revision = 0;
  engine->record_timing_command = 0;
  engine->record_timing_publish_pending = 0;
  engine->record_timing_cache = (le_record_timing_readback){.result = LE_OK};
  /* Control's in-flight Speed view dies with the ring; the factor is
   * material (le_engine_reset_material) and survives a retained reopen. */
  engine->speed_posted = 0;
  engine->speed_pending_one = engine->speed_numer == engine->speed_denom;
  atomic_store_explicit(&engine->a_speed_applied, 0, memory_order_relaxed);
  engine->bypass_posted = 0;
  engine->bypass_pending = engine->transpose_bypass;
  atomic_store_explicit(&engine->a_bypass_applied, 0, memory_order_relaxed);
  /* Every Fade admission is bound to the lifetime it read; a new session
   * invalidates them all, so nothing posted against the old device replays. */
  ++engine->fade_lifetime;
  for (int i = 0; i < LE_RING_CAPACITY; ++i) engine->receipts[i].request = 0;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    engine->tracks[t].fade_cache.lifetime = engine->fade_lifetime;
  }
  /* Mode is a persistent setting; only request receipts reset with the ring. */
  atomic_store_explicit(&engine->a_click_mode_revision, 0, memory_order_relaxed);
  store_i32(&engine->a_click_mode_result, LE_OK);
  engine->click_mode_posted_revision = 0;
  engine->click_mode_command = 0;
  engine->click_mode_publish_pending = 0;
  atomic_store_explicit(&engine->a_record_start_revision, 0, memory_order_relaxed);
  store_i32(&engine->a_record_start_result, LE_OK);
  engine->record_start_posted_revision = 0;
  engine->record_start_command = 0;
  engine->record_start_publish_pending = 0;

  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    store_f32(&tr->a_gain_bits, 1.0f);
    /* Meters settle to silence with everything else (#655). */
    store_f32(&tr->a_trk_rms_bits, 0.0f);
    store_f32(&tr->a_trk_peak_bits, 0.0f);
    store_i32(&tr->a_play_pos, 0);
    store_i32(&tr->a_pending, 0);
    store_i32(&tr->a_pending_launch, 0);
    store_i32(&tr->a_launch_grace, 0);
    store_i32(&tr->a_pending_trigger, -1);
    store_i32(&tr->a_length_preset_bars, 0); /* AUTO */
    store_i32(&tr->a_one_shot, 0); /* B4: per-track setting, resets like the
                                    * length preset above (not by clear —
                                    * see le_engine_set_one_shot's doc) */
    store_i32(&tr->a_quantize_div_override, -1); /* slice 2b: inherit */
    store_f32(&tr->a_overdub_fb_bits, -1.0f);    /* slice 2b: inherit */
    tr->fb_cur = 1.0f;
    tr->sounding_frames = 0;
    tr->head.origin = 0.0;
    /* Reverse runtime (#1162): the turn window and control's in-flight view
     * die with the ring; the direction and rate are material (above). */
    tr->turn_left = 0;
    tr->turn_frames = 0;
    tr->prev_head = tr->head;
    tr->reverse_posted = 0;
    tr->transpose_posted = 0;
    tr->transpose_pending = tr->transpose_st;
    atomic_store_explicit(&tr->a_transpose_applied, 0, memory_order_relaxed);
    tr->reverse_pending = 0;
    atomic_store_explicit(&tr->a_reverse_applied, 0, memory_order_relaxed);
    tr->once_ended = 0;
    tr->once_current_pass = 0;
    tr->length_preset_target_frames = 0;
    tr->pending_record = 0;
    tr->pending_trigger = 0;
    tr->record_pos = 0;
    tr->record_start = 0;
    tr->start_iter = 0;
    tr->od_gain = 0.0f;
    tr->xfade_capture = 0;
    /* ...and the trailing seam overlap (#728), for the same reason and then
     * some. Both are per-take audio-thread deferrals indexed off the OLD
     * length and living in the OLD live slot. Left armed across a configure
     * (which FREES and reallocates every pool buffer while resetting the
     * track to EMPTY), the next process block would write live input into
     * the freshly allocated buffer of a track that reads EMPTY, at an index
     * that means nothing there, and F frames later fold it into [0, F) —
     * breaking the invariant le_begin_empty_capture / le_prepare_new_capture
     * rely on (an EMPTY track's buffer is theirs alone to prepare). Worse
     * after a sample-rate change: the armed count no longer matches
     * seam_xfade_frames, so seam_len + (F_new - seam_capture) can land BELOW
     * seam_len, inside real loop content. A retained reopen drops the take
     * that owned them first (le_engine_reopen_settle). */
    tr->seam_capture = 0;
    tr->seam_len = 0;
    /* Per-pass layer capture + its control-side bookkeeping: a new session
     * starts from a clean slate — no armed shadows, no in-flight layer, no
     * queued taps, counters equal. (A retained reopen has already filed or
     * reverted whatever was in flight — le_engine_reopen_file_retired /
     * le_engine_reopen_settle — so these are plain resets there too.) */
    tr->dub_slot = -1;
    tr->pending_capture_shadow = 0;
    tr->dub_spare = -1;
    tr->dub_retire_slot = -1;
    tr->dub_count = -1;
    tr->dub_phase = 0;
    tr->dub_len = 0;
    tr->dub_offset = 0;
    tr->dub_draining = 0;
    tr->dub_gen_audio = 0;
    atomic_store_explicit(&tr->a_layer_in_flight, 0, memory_order_relaxed);
    atomic_store_explicit(&tr->a_cache_source_readable, 0, memory_order_relaxed);
    tr->outstanding_count = 0;
    tr->queued_undo = 0;
    tr->dub_punch_out_posted = 0;
    tr->perf_source_slot = -1;
    tr->perf_source_id = 0;
    tr->clear_restore_pending = 0;
    tr->clear_restore_generation = 0;
    atomic_store_explicit(&tr->a_clear_revision, 0, memory_order_relaxed);
    atomic_store_explicit(&tr->a_clear_generation, 0, memory_order_relaxed);
    atomic_store_explicit(&tr->a_clear_fade_amount, 0, memory_order_relaxed);
    atomic_store_explicit(&tr->a_clear_len, 0, memory_order_relaxed);
    atomic_store_explicit(&tr->a_clear_master_len, 0, memory_order_relaxed);
    tr->cancel_pending = 0;
    tr->depth_republish = 0;
    tr->pending_lane_trim = 0; /* #595: no un-route pending a post-drain trim */
    tr->state_cmds_posted = 0;
    tr->clear_cmd_ack = 0;
    tr->pending_target = LE_TRACK_EMPTY;
    tr->pending_len = 0;
    tr->pending_master_len = 0;
    tr->empty_command = 0;
    store_i32(&tr->a_state_acks, 0);
    tr->dub_generation = 0;
    atomic_store_explicit(&engine->a_record_timing_track[t], -1,
                          memory_order_seq_cst);
    engine->record_timing_cache.track_timing[t] = -1;
    engine->target_multiple[t] = 0; /* inherit the global default multiple */

    for (int l = 0; l < LE_MAX_LANES; ++l) {
      /* Lane l defaults to recording hardware input channel l; lane 0 thus
       * records input 0 and plays 0 + 1, preserving the prior single-track
       * stereo behaviour. Material (buffers, a_live/a_len, source image)
       * is not this function's to touch. */
      le_lane_reset_settings(&tr->lanes[l], l);
    }
    /* Track-stage chain (part 1b): defaults empty/enabled alongside the
     * lanes, so a reconfigured engine is dry at every stage. */
    le_fx_bus_reset(&tr->bus);
  }
  atomic_store(&engine->a_mix_revision, 0);
  engine->lane_growth_command = 0;
  engine->input_routing_command = 0;
  engine->clock_commands_posted = 0;
  atomic_store_explicit(&engine->a_clock_commands_applied, 0, memory_order_relaxed);
  engine->commands_posted = 0;
  engine->commands_applied = 0;
  atomic_store_explicit(&engine->a_commands_published, 0, memory_order_relaxed);
  /* The queue is discarded below: accepted-but-unapplied recording-start
   * edits must not survive only in control-side record decisions. The last
   * callback-confirmed recording-start pair is preserved. */

  engine->sample_rate = sample_rate;
  engine->in_channels = input_channels;
  engine->out_channels = output_channels;
  engine->max_loop_frames = max_loop_frames;
  engine->fx_delay_frames = sample_rate; /* 1 s of delay line per slot */

  /* Drop any stale traffic from a previous configuration — BOTH rings. The
   * command ring can hold presses made while the device was stopped/lost
   * (le_push still accepts them); replaying them onto the reset tracks at the
   * next start would fire surprise records and desync the
   * state_cmds_posted/a_state_acks counters. Retired-layer events reference
   * freed slots and restarted generations (a retained reopen filed them
   * first). The device is stopped, so re-initialising the SPSC rings is
   * race-free. */
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  le_ring_init(&engine->evt_ring, engine->evt_storage, LE_RING_CAPACITY);
  /* NOT redundant with the `engine->perf = (le_perf_capture){0}` reset in
   * le_engine_quiesce_workers: a zero-struct leaves capacity/mask/buffer at
   * 0/0/NULL, which is not a working ring — these calls are what actually
   * point log_ring/log_ctrl_ring back at their storage arrays with the right
   * capacity, the same way the two le_ring_init calls above are load-bearing
   * despite ring/evt_ring also having just been implicitly zeroed by the
   * surrounding struct resets. */
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);

  /* Latency-measurement capture window (~100 ms): the audio thread fills it with
   * the input-magnitude envelope, the resolver cross-correlates it. */
  free(engine->lat_buf);
  engine->lat_buf_cap = sample_rate / LE_LATENCY_CAPTURE_DIV;
  engine->lat_buf = (float*)calloc((size_t)engine->lat_buf_cap, sizeof(float));
  engine->lat_buf_pos = 0;
  if (engine->lat_buf == NULL) engine->lat_buf_cap = 0;
  /* Transport POSITION only: the loop clock's length is material
   * (le_engine_reset_material). A new session always starts at the loop
   * head, which is also where a retained reopen parks its stopped loops. */
  engine->clock.position = 0;
  engine->loop_iteration = 0;
  engine->transport_held = 0; /* #262: fresh transport, no hold latched */
  store_i32(&engine->a_master_pos, 0);
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    engine->tracks[t].free_clock.position = 0;
    engine->tracks[t].free_iteration = 0;
  }

  /* Loop visualization: clear the master + per-track loop rings. */
  engine->loop_viz_bucket = -1;
  engine->loop_viz_accum = 0.0f;
  for (int i = 0; i < LE_VIZ_POINTS; ++i) {
    store_f32(&engine->a_loop_viz[i], 0.0f);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    engine->track_viz_accum[t] = 0.0f;
    engine->track_viz_bucket[t] = -1; /* no per-track bucket accumulated yet */
    for (int i = 0; i < LE_VIZ_POINTS; ++i) {
      store_f32(&engine->a_track_viz[t][i], 0.0f);
    }
  }

  store_i32(&engine->a_record_offset, 0); /* re-measured per session */
  /* Tempo grid: only the transient state resets per session. The SETTINGS
   * (tempo, signature, sync, quantize granularity — and the tempo's source,
   * which travels with its value per the D6 dead-tempo rule) are seeded in
   * le_engine_create and persist across start/stop, exactly like the 2f0513a
   * stack's tempo/metronome settings did; the LOOP-DERIVED grid (bars, total
   * beats) is material and lives with the loop. */
  engine->frame_clock = 0;
  engine->last_tap_frame = 0;
  engine->has_tap = 0;
  engine->grid_prev_beat = -1;
  store_i32(&engine->a_current_beat, 0);
  /* Click + count-in (A2): the RUNNING state (voice envelope, free-run beat
   * phase, an in-progress count-in) resets per session; the settings persist
   * like the tempo settings above. */
  engine->click_remaining = 0;
  engine->click_len = 0;
  engine->click_phase = 0.0f;
  engine->click_freq = 0.0f;
  engine->click_grid_gate = 0;
  engine->click_free_running = 0;
  engine->click_free_frame = 0;
  engine->click_free_fpb = 0;
  engine->click_free_beat = 0;
  engine->count_in_total = 0;
  engine->count_in_elapsed = 0;
  engine->count_in_beats = 0;
  engine->count_in_beat = 0;
  engine->count_in_fpb = 0.0;
  memset(engine->launch_action, 0, sizeof(engine->launch_action));
  memset(engine->launch_order, 0, sizeof(engine->launch_order));
  memset(engine->launch_grace, 0, sizeof(engine->launch_grace));
  engine->launch_count = 0;
  engine->launch_committing = 0;
  engine->launch_stopped_mask = 0;
  store_i32(&engine->a_counting_in, 0);
  store_i32(&engine->a_count_in_beats_left, 0);
  /* MIDI clock send (C1): the RUNNING generator state resets per session,
   * exactly like the click/count-in state above — a fresh configure must
   * never carry a stale active-run frame count (or an unpaired Stop owed)
   * into the next session. The SETTING (a_clock_send) persists, seeded once
   * in le_engine_create like a_looper_mode/a_primary_track. */
  le_midi_clock_reset(&engine->midi_clock);
  /* MIDI clock sync (#1228): the source persists; its follower starts over
   * (a new sample rate or session re-acquires rather than trusting a stale
   * phase). */
  if (engine->clock_source >= 0) {
    le_clock_follow_reset(&engine->clock_follow, load_i32(&engine->a_ts_den));
    store_i32(&engine->a_clock_state, LE_CLOCK_STATE_WAITING);
  }
  /* Callback telemetry + the flat dropout tally (#722), cleared together and
   * per session. Rate 0 = INERT on purpose: the device is not open yet at
   * configure time (le_engine_start calls le_engine_configure_callback_budget
   * with the negotiated rate once it is), and an engine driven by the native
   * test pump has no device deadline to miss and must not manufacture one.
   * Deliberately NOT seeded from a_buffer_frames here — on a restart that
   * atomic still holds the PREVIOUS session's period until le_engine_start
   * republishes it, so reading it would arm the instrument against a stale
   * deadline for the length of the open. */
  le_engine_configure_callback_budget(engine, 0, 0);
  store_f32(&engine->a_master_gain_bits, 1.0f); /* unity on every fresh start */
  /* Limiter off by default (the app enables it); ceiling just below full scale.
   * Overdub feedback unity by default == classic additive overdub. */
  store_i32(&engine->a_limiter_enabled, 0);
  store_f32(&engine->a_limiter_ceiling_bits, 0.99f);
  engine->lim_gain = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, 1.0f);

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_in_channels, input_channels);
  store_i32(&engine->a_out_channels, output_channels);
  /* Default to the miniaudio backend; le_engine_start republishes the negotiated
   * backend after device open (ASIO on Windows, miniaudio on macOS/Linux). */
  store_i32(&engine->a_active_backend, LE_BACKEND_MINIAUDIO);
  /* Re-derived per device open in le_engine_start; default to none excluded. */
  atomic_store_explicit(&engine->a_excluded_input_mask, 0u,
                        memory_order_relaxed);
  /* Structural output gate: every output enabled by default (absence of any gate
   * == all outputs on). The control thread clears bits via LE_CMD_SET_OUTPUT_
   * ENABLED; the audio thread skips a cleared output in the mix fan-out. */
  atomic_store_explicit(&engine->a_output_enabled_mask, 0xFFFFFFFFu,
                        memory_order_relaxed);

  /* Tuner: disarmed. -1 rather than 0 because 0 is a real channel, and a
   * tuner that silently analyses input 1 on every boot is a CPU cost nobody
   * asked for. */
  atomic_store_explicit(&engine->a_tuner_input, -1, memory_order_relaxed);
  atomic_store_explicit(&engine->a_tuner_mute_mask, 0u, memory_order_relaxed);

  /* Per-input live monitors: all disabled by default (each defaults to full
   * stereo output, empty chain). Inputs are monitored only when explicitly
   * routed through the per-input monitor graph (le_engine_set_monitor_input). */
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_monitor_input_reset(&engine->monitors[c]);
  }
  /* Capture trim, solo and the per-channel meters (slice 3): unity, off and
   * silent on every (re)configure; the caller re-applies its intent. */
  for (int c = 0; c < LE_MAX_CHANNELS; ++c) {
    store_f32(&engine->a_in_trim_bits[c], 1.0f);
    store_f32(&engine->a_in_peak_ch_bits[c], 0.0f);
    store_f32(&engine->a_out_peak_ch_bits[c], 0.0f);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    store_i32(&engine->tracks[t].a_solo, 0);
    memset(&engine->tracks[t].pending_image, 0, sizeof(le_record_image));
    atomic_store(&engine->tracks[t].a_image_revision, 0);
    atomic_store(&engine->tracks[t].a_pending_image_revision, 0);
    engine->tracks[t].pending_fx = NULL;
    store_f32(&engine->tracks[t].a_trk_peak_l_bits, 0.0f);
    store_f32(&engine->tracks[t].a_trk_peak_r_bits, 0.0f);
  }

  /* Per-input conditioning stages (input conditioning, S1): defaults (all
   * disabled) + the conditioned-copy scratch for the new channel count. The
   * device is closed during configure, so both the seed and the realloc are
   * race-free. A failed allocation leaves cond_buf NULL — the audio thread
   * then simply keeps the raw path (conditioning silently off). */
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_cond_seed_defaults(&engine->cond[c], sample_rate);
  }
  free(engine->cond_buf);
  engine->cond_buf_cap =
      (int64_t)LE_COND_SCRATCH_FRAMES * (int64_t)input_channels;
  engine->cond_buf =
      (float*)calloc((size_t)engine->cond_buf_cap, sizeof(float));
  if (engine->cond_buf == NULL) engine->cond_buf_cap = 0;
  /* Raw-fallback telemetry: per session, like a_xruns above. */
  atomic_store_explicit(&engine->a_cond_fallback_blocks, 0u,
                        memory_order_relaxed);

  /* Input clip ("HOT") detector (input clip, S2): fresh session, no input is
   * HOT and no rail-run is in progress. Plain fields are race-free here (the
   * device is closed during configure), same as the cond seeds above. */
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    engine->clip_run[c] = 0;
    engine->clip_hold_until[c] = 0;
  }
  atomic_store_explicit(&engine->a_input_clip_mask, 0u, memory_order_relaxed);

  /* Output buses (slice 3b): defaults empty/enabled/unity, same rationale as
   * the per-track bus resets above. */
  for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
    le_output_bus_reset(&engine->outputs[k]);
  }
  /* The All tracks recorded-mix chain (slice 3e): one config, one DSP
   * instance per output bus. The config resets like any other bus-stage
   * chain; every instance's own state is cleared beside it, because a
   * configure can change how many buses the device has and a stale instance
   * would carry the previous device's filter memory into the new one. */
  le_fx_bus_reset(&engine->all_tracks);
  for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
    for (int s = 0; s < LE_FX_MAX; ++s) {
      le_fx_entry_reset(&engine->all_tracks_fx[k], s);
      le_fx_enable_seed_settled(&engine->all_tracks_fx[k], s);
      free(engine->all_tracks_fx[k].delay[s][0]);
      engine->all_tracks_fx[k].delay[s][0] = NULL;
      free(engine->all_tracks_fx[k].delay[s][1]);
      engine->all_tracks_fx[k].delay[s][1] = NULL;
      le_fx_free_octaver(&engine->all_tracks_fx[k], s);
    }
    engine->all_tracks_fx[k].enable_clear_cooldown = 0;
  }
  /* a_perf_follow_output is a preference, not device state: it survives a
   * (re)configure and is zero only from le_engine_create's calloc. */

  /* Loop-stage wet cache (part 2): fresh state + worker for the new session.
   * The cap (a_fx_cache_cap) is a SETTING seeded in le_engine_create and
   * deliberately not reset here, like the tempo/click settings above. */
  le_cache_init(engine);
  le_restore_init(engine); /* #697 S9: offline loop-close restoration worker */
  atomic_store_explicit(&engine->a_configured, 1, memory_order_release);
}

int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t input_channels, int32_t output_channels,
                            int32_t max_loop_frames) {
  if (engine == NULL || engine->fade_lifetime == UINT64_MAX) return LE_ERR_INVALID;
  le_clamp_shape(&sample_rate, &input_channels, &output_channels,
                 &max_loop_frames);
  le_engine_quiesce_workers(engine);
  if (!le_engine_reset_material(engine, max_loop_frames)) return LE_ERR_INVALID;
  le_engine_reset_runtime(engine, sample_rate, input_channels,
                          output_channels, max_loop_frames);
  return LE_OK;
}

/* Decides a reopen negotiating [sample_rate] / [max_loop_frames] (already
 * clamped), per the owner decisions on #1140 and the standing delivery rules
 * (keep recorded material; drop only the uncertain state, with a notice).
 * Material is kept only at the same rate and the same cap: no resampling, no
 * buffer regrowth — a mismatch clears the whole engine. Otherwise every track
 * is retained except those whose control-side bookkeeping no longer matches
 * what the audio thread applied: a state command (CLEAR / UNDO_TO_EMPTY /
 * REDO_FROM_EMPTY) posted but not acked, a cancelled take whose event never
 * landed, a Clear mailbox still awaiting its report, or a Session import
 * whose commit never applied (an EMPTY track carrying a length). Those tracks
 * are named in *drop_mask and dropped the way a take still capturing is
 * (le_engine_reopen_settle); the rest keep their loops. An undo tap merely
 * QUEUED behind an in-flight layer is control-side intent, not half-applied
 * state: the retained path drops the tap with the pass it was waiting on
 * (le_engine_reopen_file_retired). */
static int32_t le_engine_reopen_outcome(le_engine* engine, int32_t sample_rate,
                                        int32_t max_loop_frames,
                                        uint32_t* drop_mask) {
  *drop_mask = 0u;
  if (sample_rate != engine->sample_rate) return LE_REOPEN_CLEARED_RATE;
  if (max_loop_frames != engine->max_loop_frames) return LE_REOPEN_CLEARED_CAP;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    const int pending =
        tr->state_cmds_posted >
            atomic_load_explicit(&tr->a_state_acks, memory_order_acquire) ||
        tr->cancel_pending || tr->clear_restore_pending ||
        (load_i32(&tr->a_state) == LE_TRACK_EMPTY &&
         load_i32(&tr->lanes[0].a_len) > 0); /* imported, never committed */
    if (pending) *drop_mask |= 1u << t;
  }
  return *drop_mask ? LE_REOPEN_RETAINED_PARTIAL : LE_REOPEN_RETAINED;
}

int32_t le_engine_reopen_configured(le_engine* engine, int32_t sample_rate,
                                    int32_t input_channels,
                                    int32_t output_channels,
                                    int32_t max_loop_frames, int32_t* outcome,
                                    int32_t* dropped_track_mask) {
  if (engine == NULL || outcome == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING; /* never configured: le_engine_start's job */
  }
  if (engine->fade_lifetime == UINT64_MAX) return LE_ERR_INVALID;
  le_clamp_shape(&sample_rate, &input_channels, &output_channels,
                 &max_loop_frames);
  uint32_t drop_mask = 0u;
  const int32_t decision = le_engine_reopen_outcome(engine, sample_rate,
                                                    max_loop_frames, &drop_mask);
  *outcome = decision;
  if (dropped_track_mask != NULL) *dropped_track_mask = (int32_t)drop_mask;
  if (decision == LE_REOPEN_CLEARED_RATE || decision == LE_REOPEN_CLEARED_CAP) {
    return le_engine_configure(engine, sample_rate, input_channels,
                               output_channels, max_loop_frames);
  }
  /* Retained: end the capture and join the workers first (as configure does),
   * then settle the material while the event ring and the audio thread's
   * dub/seam bookkeeping are still intact — the runtime reset afterwards
   * re-initialises both rings. */
  le_engine_quiesce_workers(engine);
  le_engine_reopen_file_retired(engine, drop_mask);
  le_engine_reopen_settle(engine, drop_mask);
  le_engine_reset_runtime(engine, sample_rate, input_channels,
                          output_channels, max_loop_frames);
  return LE_OK;
}

const char* le_version(void) {
  return "segno_engine 0.3.0 (miniaudio " MA_VERSION_STRING ")";
}

/* Loopback detection + device enumeration moved to engine_devices.c (S1). */

/* Loopback channel exclusion is per-OS: macOS reads Core Audio channel labels
 * (engine_apple.c), Linux/Windows exclude nothing for now. The mask is fetched
 * through le_platform_excluded_input_mask (engine_platform.h) at device open. */

void le_engine_set_now_fn_for_test(le_engine* engine, uint64_t (*fn)(void*),
                                   void* ctx) {
  if (engine == NULL) return;
  engine->now_fn = fn;
  engine->now_ctx = ctx;
}

void le_engine_set_excluded_input_mask_for_test(le_engine* engine,
                                                uint32_t mask) {
  if (engine == NULL) return;
  atomic_store_explicit(&engine->a_excluded_input_mask, mask,
                        memory_order_relaxed);
}

int le_engine_lane_buffer_allocated_for_test(le_engine* engine, int32_t channel,
                                             int32_t lane) {
  if (engine == NULL) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (lane < 0 || lane >= LE_MAX_LANES) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  return ln->pool[load_i32(&ln->a_live)] != NULL ? 1 : 0;
}

int32_t le_engine_lane_slot_cap_for_test(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t slot) {
  if (engine == NULL) return -1;
  if (channel < 0 || channel >= engine->track_count) return -1;
  if (lane < 0 || lane >= LE_MAX_LANES) return -1;
  if (slot < 0) {
    /* slot < 0 selects the lane's LIVE slot. */
    slot = load_i32(&engine->tracks[channel].lanes[lane].a_live);
  }
  if (slot >= LE_POOL_SLOTS) return -1;
  return engine->tracks[channel].lanes[lane].pool_cap[slot];
}

int32_t le_engine_read_lane_live_for_test(le_engine* engine, int32_t channel,
                                          int32_t lane, float* out,
                                          int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames <= 0) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (lane < 0 || lane >= LE_MAX_LANES) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  const float* src = ln->pool[load_i32(&ln->a_live)];
  int32_t len = load_i32(&ln->a_len);
  if (src == NULL || len <= 0) return 0;
  if (len > max_frames) len = max_frames;
  memcpy(out, src, (size_t)len * sizeof(float));
  return len;
}

void le_engine_set_lane_count_unsafe_for_test(le_engine* engine,
                                              int32_t channel, int32_t count) {
  if (engine == NULL) return;
  if (channel < 0 || channel >= engine->track_count) return;
  if (count < 1) count = 1;
  if (count > LE_MAX_LANES) count = LE_MAX_LANES;
  atomic_store_explicit(&engine->tracks[channel].lane_count, count, memory_order_release); /* no buffer allocation */
}

void le_engine_lane_fx_chain_for_test(le_engine* engine, int32_t channel,
                                      int32_t lane, float* l, float* r) {
  if (engine == NULL || l == NULL || r == NULL) return;
  if (channel < 0 || channel >= engine->track_count) return;
  if (lane < 0 || lane >= LE_MAX_LANES) return;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t count = load_i32(&ln->a_fx_count);
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t enabled[LE_FX_MAX];
  const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
  for (int s = 0; s < count; ++s) {
    types[s] = load_i32(&ln->a_fx_type[s]);
    enabled[s] = chain_on && load_i32(&ln->a_fx_enabled[s]);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      params[s][p] = load_f32(&ln->a_fx_param[s][p]);
    }
  }
  fx_apply_chain(&ln->fx, engine->sample_rate, engine->fx_delay_frames, l, r,
                 count, types, params, enabled);
}

/* Loopback detection, device enumeration / id resolution, and backend selection
 * (le_select_backend + the ASIO-driver enumeration stub) moved to
 * engine_devices.c (S1). The ASIO bridge math (deinterleave / interleave /
 * pick_buffer) lives in engine_convert.c. */

void le_engine_mark_started(le_engine* engine) {
  if (engine == NULL) return;
  atomic_store_explicit(&engine->a_device_present, 1, memory_order_release);
  atomic_store_explicit(&engine->a_running, 1, memory_order_release);
}

void le_engine_note_xrun(le_engine* engine) {
  le_engine_note_backend_xrun(engine, LE_XRUN_BACKEND_OVERLOAD);
}

void le_engine_note_backend_xrun(le_engine* engine, int32_t kind) {
  if (engine == NULL) return;
  /* Relaxed throughout: a monotonically-increasing dropout tally read by the
   * snapshot poller — no other state is ordered against it. Called from a
   * device backend's own thread (the ASIO message thread for an overload; the
   * ALSA data-loop thread for an -EPIPE recovery), never from inside
   * le_engine_process; exists as a C helper so a C++ backend TU need not touch
   * the _Atomic fields directly (mirrors le_engine_mark_started).
   *
   * The armed flag comes from the PUBLISHED atomic, not engine->perf.armed:
   * that mirror is audio-thread-local and these callers do not own it. Reading
   * it here — at the moment of the dropout — is what makes the armed-window
   * attribution exact rather than "whenever the control thread next polled".
   *
   * ORDER MATTERS, and it is deliberate: the flat tally is bumped BEFORE
   * le_cb_timing_note_xrun range-checks `kind`, so a kind this build does not
   * recognise still moves xrun_count even though no per-kind bucket can hold
   * it. xrun_count answers "did a real dropout happen", and an unclassifiable
   * dropout still happened — dropping it would make the headline number
   * under-report reality, which is the failure #722 exists to end. The cost is
   * that the kinds sum to xrun_count only for kinds this build knows; that is
   * what segno_engine_api.h documents, and no backend passes anything else
   * today (ALSA passes 0/1/2, ASIO passes 3). */
  atomic_fetch_add_explicit(&engine->a_xruns, 1u, memory_order_relaxed);
  le_cb_timing_note_xrun(
      &engine->cb_timing, kind,
      atomic_load_explicit(&engine->a_perf_armed, memory_order_relaxed) != 0);
}

void le_engine_note_callback_timeline_break(le_engine* engine) {
  if (engine == NULL) return;
  le_cb_timing_note_timeline_break(&engine->cb_timing);
}

void le_engine_note_callback_span(le_engine* engine, uint64_t entry_ns,
                                  uint64_t exit_ns, uint32_t frames) {
  if (engine == NULL) return;
  le_cb_timing_note(
      &engine->cb_timing, entry_ns, exit_ns, frames,
      atomic_load_explicit(&engine->a_perf_armed, memory_order_relaxed) != 0);
}

void le_engine_configure_callback_budget(le_engine* engine,
                                         int32_t sample_rate,
                                         int32_t period_frames) {
  if (engine == NULL) return;
  /* The flat tally and the per-kind windows are two views of the same events,
   * so they are cleared TOGETHER and nowhere else. Clearing only the windows
   * here would leave xrun_count carrying dropouts the breakdown no longer
   * shows — a reading that looks like a bug in the instrument. */
  atomic_store_explicit(&engine->a_xruns, 0u, memory_order_relaxed);
  le_cb_timing_configure(&engine->cb_timing, sample_rate, period_frames);
}

void le_engine_mark_device_lost(le_engine* engine) {
  if (engine == NULL) return;
  /* Flip presence to 0 while a_running stays 1 (running-but-disconnected),
   * mirroring the miniaudio device-notification callback (relaxed store; a lone
   * presence flag carrying no other state). The Dart layer reads device_present
   * == 0 as "lost" and drives reconnection (stop -> start) from the control
   * thread — the only correct place to tear down and re-open a device, never the
   * driver's callback/message thread. Used by the ASIO reset-request and
   * sample-rate-change notifications so a driver reconfigured by another app
   * recovers instead of going silent. */
  atomic_store_explicit(&engine->a_device_present, 0, memory_order_relaxed);
}

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  le_ring_init(&engine->evt_ring, engine->evt_storage, LE_RING_CAPACITY);
  le_ring_init(&engine->midi_clock_ring, engine->midi_clock_ring_storage,
              LE_MIDI_CLOCK_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  /* Tempo-grid SETTINGS: seeded once here (not reset by configure on each
   * start — the 2f0513a persistence pattern). Everything defaults to
   * grid-off values: no tempo (0 = unset, source none), 4/4, sync on,
   * quantize granularity OFF (deliberately unlike the old stack's BAR
   * default) — so an untouched engine behaves exactly like the tempo-free
   * build. */
  store_f32(&engine->a_tempo_bpm_bits, 0.0f);
  store_i32(&engine->a_ts_num, 4);
  store_i32(&engine->a_ts_den, 4);
  store_i32(&engine->a_sync_tempo, 1);
  store_i32(&engine->a_quantize_div, LE_GRID_DIV_OFF);
  store_i32(&engine->a_tempo_source, LE_TEMPO_SOURCE_NONE);
  engine->grid_prev_beat = -1;
  /* Click + count-in SETTINGS (A2): same seeded-once persistence as the tempo
   * settings. Mode off, mask 0 (unrouted), volume unity, count-in off — with
   * these defaults no click code past one dormant compare ever runs. */
  store_i32(&engine->a_click_mode, LE_CLICK_OFF);
  atomic_store_explicit(&engine->a_click_mask, 0u, memory_order_relaxed);
  store_f32(&engine->a_click_volume_bits, 1.0f);
  store_i32(&engine->a_record_start, 0);
  /* Looper mode SETTING (B2a, D4): same seeded-once persistence as the
   * tempo/click settings above. MULTI (0) is both the enum's zero value and
   * calloc's zero-fill, so this store is redundant against the allocation —
   * kept explicit anyway, matching every sibling setting here, so the
   * default is legible at the seed site rather than implied by calloc. */
  store_i32(&engine->a_looper_mode, LE_LOOPER_MODE_MULTI);
  /* Primary track (B3, D18 as revised): -1 (none) until the first completed
   * take or an explicit crown. Unlike a_looper_mode it does NOT survive
   * configure(): configure empties every track, and an empty rig has no
   * crown (le_engine_configure resets it alongside the tracks; the audio
   * thread's le_primary_reconcile keeps that invariant afterwards). -1 is
   * NOT calloc's zero-fill, so this store is load-bearing. */
  store_i32(&engine->a_primary_track, -1);
  /* MIDI clock send SETTING (Phase C, D15): same seeded-once persistence as
   * the looper mode / primary track above. Off (0), kept explicit for the
   * same legibility reason as a_looper_mode's redundant store. */
  store_i32(&engine->a_clock_send, 0);
  /* MIDI clock sync (#1228): Internal, the follower idle. */
  engine->clock_source = -1;
  store_i32(&engine->a_clock_source, -1);
  engine->clock_source_requested = -1;
  store_i32(&engine->a_clock_state, LE_CLOCK_STATE_INTERNAL);
  engine->now_fn = NULL;
  store_f32(&engine->a_master_gain_bits, 1.0f); /* unity until set */
  for (int c = 0; c < LE_MAX_CHANNELS; ++c) {
    store_f32(&engine->a_in_trim_bits[c], 1.0f); /* unity until set */
  }
  store_i32(&engine->a_limiter_enabled, 0);     /* off until the app enables it */
  store_f32(&engine->a_limiter_ceiling_bits, 0.99f);
  engine->lim_gain = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, 1.0f); /* classic additive overdub */
  atomic_store_explicit(&engine->a_output_enabled_mask, 0xFFFFFFFFu,
                        memory_order_relaxed); /* all outputs on until set */
  /* Loop-stage wet cache budget (part 2): a SETTING with the seeded-once
   * persistence of the tempo/click settings above. The appliance-tuned
   * default; 0 disables caching outright (le_engine_set_fx_cache_cap). */
  atomic_store_explicit(&engine->a_fx_cache_cap, LE_CACHE_DEFAULT_CAP_BYTES,
                        memory_order_relaxed);
  return engine;
}

void le_engine_destroy(le_engine* engine) {
  if (engine == NULL) return;
  /* No capture may write a port of a freed engine (#1228, review H2): each
   * detach waits until its producer has no push in flight. */
  for (int p = 0; p < LE_MAX_MIDI_PORTS; ++p) {
    le_midi_port_unbind(&engine->midi_ports[p]);
  }
  /* Release the device + context through the backend that opened it. NULL until
   * the first successful start; close() is idempotent, so a create→destroy with
   * no start (and a stop→destroy) are both safe. */
  if (engine->backend != NULL) {
    engine->backend->close(engine);
  }
  /* Loop-stage wet cache (part 2, [R2](d)): the device is closed (no audio
   * thread), so join the render worker and free every cache allocation
   * BEFORE the pool frees below — a destroy that lands mid-render must
   * never free a buffer the worker still reads (the ASan
   * destroy-during-active-render test pins exactly this ordering). */
  le_fx_recipe_collect(engine, 1);
  le_cache_shutdown(engine);
  le_bounce_abandon_all(engine); /* #1202: no callback will apply them */
  le_restore_shutdown(engine); /* #697 S9: join before the pool frees below */
  le_render_destroy(engine); /* render recipe jobs (#1202): worker joined */
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &engine->tracks[t].lanes[l];
      for (int i = 0; i < LE_POOL_SLOTS; ++i) {
        free(ln->pool[i]);
      }
      for (int s = 0; s < LE_FX_MAX; ++s) {
        free(ln->fx.delay[s][0]);
        free(ln->fx.delay[s][1]);
        le_fx_free_octaver(&ln->fx, s);
        /* The device is already closed (no audio thread), so any hosted plugin
         * slot — including one left behind by a stalled-callback clear — can be
         * destroyed directly without the quiescent handshake. */
        le_plugin_slot_destroy(
            atomic_load_explicit(&ln->fx.plugin[s], memory_order_relaxed));
      }
    }
    /* Track-stage chain (part 1b): same per-slot teardown as the lanes. */
    for (int s = 0; s < LE_FX_MAX; ++s) {
      free(engine->tracks[t].bus.fx.delay[s][0]);
      free(engine->tracks[t].bus.fx.delay[s][1]);
      le_fx_free_octaver(&engine->tracks[t].bus.fx, s);
      le_plugin_slot_destroy(atomic_load_explicit(
          &engine->tracks[t].bus.fx.plugin[s], memory_order_relaxed));
    }
  }
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    for (int s = 0; s < LE_FX_MAX; ++s) {
      free(engine->monitors[c].fx.delay[s][0]);
      free(engine->monitors[c].fx.delay[s][1]);
      le_fx_free_octaver(&engine->monitors[c].fx, s);
      le_plugin_slot_destroy(atomic_load_explicit(
          &engine->monitors[c].fx.plugin[s], memory_order_relaxed));
    }
  }
  /* Output bus chains (slice 3b) and the All tracks instances (slice 3e). */
  for (int s = 0; s < LE_FX_MAX; ++s) {
    for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
      free(engine->outputs[k].fx.fx.delay[s][0]);
      free(engine->outputs[k].fx.fx.delay[s][1]);
      le_fx_free_octaver(&engine->outputs[k].fx.fx, s);
      free(engine->all_tracks_fx[k].delay[s][0]);
      free(engine->all_tracks_fx[k].delay[s][1]);
      le_fx_free_octaver(&engine->all_tracks_fx[k], s);
    }
    for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
      le_plugin_slot_destroy(atomic_load_explicit(
          &engine->outputs[k].fx.fx.plugin[s], memory_order_relaxed));
    }
  }
  free(engine->lat_buf);
  free(engine->cond_buf); /* conditioned-copy scratch (input conditioning) */
  /* The device is already closed (no audio thread), so the performance-capture
   * rings — including any left retracted-but-allocated by a disarm that could
   * not confirm quiescence — can be freed directly, without the handshake. The
   * drain thread is a plain background thread (not the audio callback) and may
   * still be alive if a prior disarm bailed out on the quiescent wait, so stop
   * and join it first — it is the rings' last reader. */
  if (engine->perf.drain != NULL) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
    engine->perf.drain = NULL;
  }
  /* Layers staged after the drain thread died (self-stop on write failure)
   * have no consumer left — free them now that the thread is joined. */
  le_layer_staging_ring_drain_free(&engine->perf.layer_staging_ring);
  /* Same reasoning as the reconfigure teardown above: cancel+join any active
   * render before this engine (and its perf.render handle) is freed. */
  le_perf_render_cancel(engine);
  le_audio_ring_release(&engine->perf.master_ring);
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_audio_ring_release(&engine->perf.monitor_ring[c]);
  }
  le_platform_on_engine_teardown(); /* Linux restores PipeWire's dynamic quantum */
  free(engine);
}

static int32_t le_engine_publish_and_start(le_engine* engine,
                                           const le_device_backend* be,
                                           const le_config* config,
                                           const le_device_open_result* info);

int32_t le_engine_start(le_engine* engine, const le_config* config) {
  if (engine == NULL || config == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }

  /* Open the device through the selected backend (ASIO on Windows, miniaudio on
   * macOS/Linux). The backend builds the device config, resolves pins/loopback,
   * opens the device, and reports the negotiated parameters back. A requested
   * ASIO open that fails (no/missing driver, driver busy, init failure) is NOT
   * silently retried on another backend: Windows is ASIO-only, so the failure
   * surfaces (the app lands stopped and shows the no-driver / ASIO4ALL
   * affordance) rather than dropping to system audio behind the user's back. */
  const le_device_backend* be = le_select_backend(config->backend);
  le_device_open_result info;
  const int32_t open_result = be->open(engine, config, &info);
  if (open_result != LE_OK) {
    return open_result;
  }

  /* Remember the backend before start() publishes a_running, so the invariant
   * "running implies backend set" holds for any concurrent stop()/snapshot. */
  engine->backend = be;

  if (le_engine_configure(engine, info.sample_rate, info.input_channels,
                          info.output_channels,
                          config->max_loop_frames) != LE_OK) {
    be->close(engine);
    return LE_ERR_INVALID;
  }
  return le_engine_publish_and_start(engine, be, config, &info);
}

int32_t le_engine_reopen(le_engine* engine, const le_config* config,
                         int32_t* outcome, int32_t* dropped_track_mask) {
  if (engine == NULL || config == NULL || outcome == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  /* Open first, exactly as le_engine_start does. A failed open changes
   * NOTHING: the material is still held and still stopped, so the supervisor
   * can simply try again on its next tick. */
  const le_device_backend* be = le_select_backend(config->backend);
  le_device_open_result info;
  const int32_t open_result = be->open(engine, config, &info);
  if (open_result != LE_OK) return open_result;
  engine->backend = be;

  const int32_t rc = le_engine_reopen_configured(
      engine, info.sample_rate, info.input_channels, info.output_channels,
      config->max_loop_frames, outcome, dropped_track_mask);
  if (rc != LE_OK) {
    be->close(engine);
    return rc;
  }
  /* A start failure closes the device and reports LE_ERR_DEVICE with the
   * material already settled (retained and stopped, cleared, or partly
   * dropped per *outcome), so the next attempt can still retain it. */
  return le_engine_publish_and_start(engine, be, config, &info);
}

/* The device-session tail shared by le_engine_start and le_engine_reopen:
 * publishes the negotiated parameters (the runtime reset left them at
 * defaults), arms the callback telemetry, derives the loopback exclusion and
 * starts the callback. On a start failure the device is closed and
 * LE_ERR_DEVICE returned; the engine stays configured. */
static int32_t le_engine_publish_and_start(le_engine* engine,
                                           const le_device_backend* be,
                                           const le_config* config,
                                           const le_device_open_result* info_p) {
  const le_device_open_result info = *info_p;
  store_i32(&engine->a_active_backend, info.active_backend);
  store_i32(&engine->a_buffer_frames, info.buffer_frames);
  /* Callback telemetry (#722): arm the instrument at the negotiated rate.
   * le_engine_configure above deliberately left it inert, so this is the single
   * point where a device session's measurement begins; it clears both windows
   * and a_xruns together, so the numbers a bench reads always belong to the
   * device session in front of it. Still before start(), so the callback cannot
   * be running yet — nothing races this write. */
  le_engine_configure_callback_budget(engine, info.sample_rate,
                                      info.buffer_frames);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  engine->lat_active = 0;
  engine->lat_emit_remaining = 0;
  engine->lat_buf_pos = 0;

  strncpy(engine->device_name, info.device_name,
          sizeof(engine->device_name) - 1);
  engine->device_name[sizeof(engine->device_name) - 1] = '\0';

  /* Exclude any loopback-labelled capture channels, computed from the resolved
   * capture-device UID: our explicit capture id when one was pinned/loopback-
   * routed (capture_id_set, set by the backend), else the system default input
   * (on string-id backends the id union is the UID string). */
  const char* capture_uid =
      engine->capture_id_set ? (const char*)&engine->capture_id : NULL;
  const uint32_t excluded_mask =
      le_platform_excluded_input_mask(capture_uid, info.input_channels);
  /* relaxed: a lone published value, matching the other configuration atomics
   * (a_sample_rate, etc.) and the relaxed audio-thread / snapshot reads. */
  atomic_store_explicit(&engine->a_excluded_input_mask, excluded_mask,
                        memory_order_relaxed);

  if (be->start(engine) != LE_OK) {
    be->close(engine);
    return LE_ERR_DEVICE;
  }
  /* Per-OS post-start hook: Linux repins the JACK ports to the selected
   * interface (overriding miniaudio's connect-to-every-physical-port default)
   * so channels map to that device only. No-op elsewhere. */
  le_platform_after_device_start(engine, config);
  return LE_OK;
}

/* Settles a bus-stage chain owner's DISABLED slots' enable ramps at bypass —
 * the le_fx_bus twin of the per-lane/per-monitor settle loops in
 * le_engine_stop below. Control-thread only, with the device stopped. */
static void le_fx_bus_settle_bypass(le_fx_bus* b) {
  const int32_t chain_on = load_i32(&b->a_fx_chain_enabled);
  for (int s = 0; s < LE_FX_MAX; ++s) {
    if (!(chain_on && load_i32(&b->a_fx_enabled[s]))) {
      le_fx_enable_force_bypass(&b->fx, s);
    }
  }
}

int32_t le_engine_stop(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  /* Release the device through the backend that opened it (always set while
   * running). */
  if (engine->backend != NULL) {
    engine->backend->stop(engine);
  }
  engine->device_name[0] = '\0';
  atomic_store_explicit(&engine->a_device_present, 0, memory_order_release);
  atomic_store_explicit(&engine->a_running, 0, memory_order_release);
  /* Settle every DISABLED fx slot's enable ramp at bypass now that the audio
   * thread is gone: a disable landing just before the stop could otherwise
   * strand its crossfade mid-fade, and a restart would resume a stale tail
   * without the settled-edge reset [B7]. Enabled slots keep their DSP state
   * across stop/start, as they always have. Safe: the device (and its
   * callback) is stopped, so the control thread owns the fx state here. */
  for (int t = 0; t < engine->track_count; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &engine->tracks[t].lanes[l];
      const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
      for (int s = 0; s < LE_FX_MAX; ++s) {
        if (!(chain_on && load_i32(&ln->a_fx_enabled[s]))) {
          le_fx_enable_force_bypass(&ln->fx, s);
        }
      }
    }
  }
  for (int c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_monitor_input* m = &engine->monitors[c];
    const int32_t chain_on = load_i32(&m->a_fx_chain_enabled);
    for (int s = 0; s < LE_FX_MAX; ++s) {
      if (!(chain_on && load_i32(&m->a_fx_enabled[s]))) {
        le_fx_enable_force_bypass(&m->fx, s);
      }
    }
  }
  /* Track-stage + Master chains (part 1b): same settle as the lane/monitor
   * owners above. */
  for (int t = 0; t < engine->track_count; ++t) {
    le_fx_bus_settle_bypass(&engine->tracks[t].bus);
  }
  for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
    le_fx_bus_settle_bypass(&engine->outputs[k].fx);
  }
  /* The All tracks instances share one config's flags (slice 3e). */
  {
    const int32_t chain_on = load_i32(&engine->all_tracks.a_fx_chain_enabled);
    for (int s = 0; s < LE_FX_MAX; ++s) {
      if (chain_on && load_i32(&engine->all_tracks.a_fx_enabled[s])) continue;
      for (int k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
        le_fx_enable_force_bypass(&engine->all_tracks_fx[k], s);
      }
    }
  }
  /* Loop-stage wet cache (part 2, [R2](d)): the device (and its callback) is
   * stopped, so join the render worker and release every cache allocation
   * now — no pool or wet buffer may be freed with the worker alive, and a
   * stopped engine has no cached playback to serve. The next start's
   * configure re-initializes it. */
  le_fx_recipe_collect(engine, 1);
  le_cache_shutdown(engine);
  le_bounce_abandon_all(engine); /* #1202: no callback will apply them */
  le_restore_shutdown(engine); /* #697 S9: join the restoration worker on stop */
  /* Per-OS teardown on stop (not only destroy) so a forced quantum doesn't
   * outlive a running engine for other PipeWire clients. No-op off Linux. */
  le_platform_on_engine_teardown();
  return LE_OK;
}

/* Published-state snapshots + visualization reads (le_engine_get_snapshot /
 * get_track / get_lane / read_visual / read_track_visual, with le_max_fx_latency
 * and the track-snapshot fill) moved to engine_snapshot.c (S1). */

const char* le_engine_device_name(le_engine* engine) {
  if (engine == NULL) return "";
  return engine->device_name;
}

int32_t le_engine_post_command(le_engine* engine, int32_t code, int32_t arg_i,
                               float arg_f) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  /* Click mode requires the typed single-flight receipt. Raw posts cannot
   * bypass that reservation or publish revisionless competing settings. */
  if (code == LE_CMD_RESET_TRANSFORMS) return LE_ERR_INVALID;
  if (code == LE_CMD_FADE) return LE_ERR_INVALID;
  if (code == LE_CMD_REVERSE) return LE_ERR_INVALID;
  if (code == LE_CMD_SET_SPEED) return LE_ERR_INVALID;
  if (code == LE_CMD_TRANSPOSE || code == LE_CMD_TRANSPOSE_BYPASS) {
    return LE_ERR_INVALID;
  }
  if (code == LE_CMD_RENDER_FREEZE) return LE_ERR_INVALID;
  if (code == LE_CMD_BOUNCE || code == LE_CMD_BOUNCE_RECOVER) return LE_ERR_INVALID;
  if (code == LE_CMD_SET_CLICK_MODE) return LE_ERR_INVALID;
  if (code == LE_CMD_SET_RECORD_START) return LE_ERR_INVALID;
  if (code == LE_CMD_SET_LOOPER_MODE) {
    return le_push_cmd(engine, (le_command){.code = code,
                                           .presets = {.mode = arg_i}});
  }
  const le_command cmd = {.code = code, .arg_i = arg_i, .arg_f = arg_f};
  return le_push_cmd(engine, cmd);
}

int32_t le_engine_measure_latency(le_engine* engine) {
  return le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

/* ---- looper control (push gated on `configured`, so tests work device-free) */

#ifdef LE_NATIVE_TESTS
void (*le_test_fade_hook)(le_engine*, int) = NULL;
void (*le_test_stop_record_hook)(le_engine*, int) = NULL;
void (*le_test_record_timing_hook)(le_engine*, int) = NULL;
void (*le_test_click_mode_hook)(le_engine*, int) = NULL;
void (*le_test_record_start_hook)(le_engine*, int) = NULL;
void (*le_test_peel_hook)(le_engine*, int) = NULL;
void (*le_test_midi_dispatch_hook)(le_engine*, int, int,
                                   const le_midi_port_event*) = NULL;
#endif

int32_t le_push_cmd(le_engine* engine, le_command cmd) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (!le_ring_push(&engine->ring, cmd)) return LE_ERR_INVALID;
  engine->commands_posted++;
  if (cmd.code == LE_CMD_SET_INPUT_MASK || cmd.code == LE_CMD_SET_LANE_INPUT ||
      cmd.code == LE_CMD_SET_MIX) engine->input_routing_command = engine->commands_posted;
  return LE_OK;
}

int32_t le_engine_commands_settled(le_engine* engine) {
  if (engine == NULL ||
      !atomic_load_explicit(&engine->a_configured, memory_order_acquire)) return 0;
  return engine->commands_posted ==
         atomic_load_explicit(&engine->a_commands_published, memory_order_acquire);
}

int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i, float arg_f) {
  le_command cmd = {.code = code, .arg_i = arg_i, .arg_f = arg_f};
  return le_push_cmd(engine, cmd);
}

int32_t le_engine_begin_latency_for_test(le_engine* engine) {
  /* Configured-gated (like the looper commands) so the harness's loopback
   * detection can be driven without opening a device. */
  return le_push(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}
