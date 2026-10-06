/*
 * engine_snapshot.c — the read side: published-state snapshots + visualization
 * reads (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: control thread (a render-rate poll from Dart). Every function
 * here only LOADS the per-field atomics the audio thread publishes — it never
 * mutates engine state — so a reader may see a one-frame-stale mix across fields,
 * which is fine for metering / UI. le_max_fx_latency scans the published fx
 * type/count atomics (the only race-free seam; see its comment). Behaviour
 * unchanged.
 */
#include <stdint.h>
#include <string.h> /* memset — the NULL-engine telemetry read */

#include "engine_core.h"    /* le_lanes_active */
#include "engine_fx.h"      /* le_octaver_latency */
#include "engine_internal.h" /* le_perf_drain_self_stopped */
#include "engine_private.h" /* le_engine, le_track, le_lane, load/store helpers */
#include "segno_engine_api.h"

/* SC sequence + SC tuple fields give one bounded, race-free copy. A full
 * snapshot alone refreshes the sole control thread's last coherent cache. */
le_record_timing_readback le_record_timing_read(le_engine* e, int refresh_cache) {
  le_record_timing_readback result = e->record_timing_cache;
  const uint32_t first = atomic_load_explicit(&e->a_record_timing_revision,
                                              memory_order_seq_cst);
  if (first & 1u) return result;
  le_record_timing_readback candidate = {
    .default_timing = atomic_load_explicit(&e->a_record_timing_default, memory_order_seq_cst),
    .remembered_division = atomic_load_explicit(&e->a_quantize_div, memory_order_seq_cst),
    .revision = first,
    .result = atomic_load_explicit(&e->a_record_timing_result, memory_order_seq_cst),
  };
  for (int c = 0; c < LE_MAX_TRACKS; ++c)
    candidate.track_timing[c] = atomic_load_explicit(&e->a_record_timing_track[c],
                                                    memory_order_seq_cst);
#ifdef LE_NATIVE_TESTS
  if (le_test_record_timing_hook) le_test_record_timing_hook(e, 3);
#endif
  const uint32_t last = atomic_load_explicit(&e->a_record_timing_revision,
                                             memory_order_seq_cst);
  if (first == last && !(last & 1u)) {
    result = candidate;
    if (refresh_cache) e->record_timing_cache = candidate;
  }
  return result;
}

static void le_fade_read(le_engine* engine, le_track* tr, le_track_snapshot* out) {
  const uint64_t first = atomic_load_explicit(&tr->a_fade_revision, memory_order_seq_cst);
  if (!(first & 1u)) {
    le_fade_image v = {0};
    uint32_t bits = atomic_load_explicit(&tr->a_fade_amount, memory_order_seq_cst);
    memcpy(&v.amount, &bits, sizeof(bits));
#ifdef LE_NATIVE_TESTS
    if (le_test_fade_hook) le_test_fade_hook(engine, 2);
#endif
    bits = atomic_load_explicit(&tr->a_fade_target, memory_order_seq_cst);
    memcpy(&v.target, &bits, sizeof(bits));
    bits = atomic_load_explicit(&tr->a_fade_seconds, memory_order_seq_cst);
    memcpy(&v.full_travel_seconds, &bits, sizeof(bits));
    v.lifetime = engine->fade_lifetime;
    v.generation = atomic_load_explicit(&tr->a_fade_generation, memory_order_seq_cst);
    const uint64_t last = atomic_load_explicit(&tr->a_fade_revision, memory_order_seq_cst);
    if (first == last) {
      tr->fade_cache = v;
      tr->fade_cache_revision = last;
    }
  }
  out->fade = tr->fade_cache;
  out->fade_revision = tr->fade_cache_revision;
}

static void le_timing_track_fields(le_track_snapshot* out, int code) {
  out->quantize_override = code < 0 ? -1 : code != 0;
  out->quantize_div_override = code < 0 ? -1 : code > 0 ? code - 1 : 0;
}

/* Lane 0's input channel as a legacy track input bitmask (1 << channel, or 0
 * when lane 0 records no input). */
static uint32_t le_lane_input_bits(le_lane* ln) {
  const int32_t ic = load_i32(&ln->a_input_channel);
  return ic >= 0 ? (1u << ic) : 0u;
}

/* Fills a track snapshot from the track's transport plus lane 0's content (the
 * backward-compatible per-track view). When [active] is false the track index
 * is past track_count; report an empty track. */
static void le_fill_track_snapshot(le_engine* engine, int32_t ch,
                                   int active, le_track_snapshot* out) {
  le_track* tr = &engine->tracks[ch];
  le_lane* l0 = &tr->lanes[0];
  out->state = active ? load_i32(&tr->a_state) : LE_TRACK_EMPTY;
  out->volume = load_f32(&tr->a_gain_bits);
  le_fade_read(engine, tr, out);
  out->muted = load_i32(&l0->a_muted);
  out->length_frames = load_i32(&l0->a_len);
  out->multiple = load_i32(&tr->a_multiple);
  out->undo_depth = load_i32(&tr->a_undo_depth);
  out->clear_restore = load_i32(&tr->a_clear_restore);
  out->redo_depth = load_i32(&tr->a_redo_depth);
  out->peel_depth = load_i32(&tr->a_peel_depth);
  /* The TRACK's level, summed across its lanes -- NOT lane 0's, which is what
   * this reported until #655 and which under-read any track playing more than
   * one layer. Per-lane figures are still published on the lane snapshots
   * below for anything that wants them individually. */
  out->rms = load_f32(&tr->a_trk_rms_bits);
  out->peak = load_f32(&tr->a_trk_peak_bits);
  out->input_mask = le_lane_input_bits(l0);
  out->output_mask =
      atomic_load_explicit(&l0->a_output_mask, memory_order_relaxed);
  out->lane_count = le_lanes_active(tr);
  out->layer_in_flight =
      atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire);
  /* Acquire pairs with the arm's release store, so the trigger read below
   * is the one published with this arm. */
  out->pending = atomic_load_explicit(&tr->a_pending, memory_order_acquire);
  out->pending_launch = active ? load_i32(&tr->a_pending_launch) : 0;
  out->count_in_cancel_grace = active && load_i32(&tr->a_launch_grace) != 0;
  out->length_preset_bars = load_i32(&tr->a_length_preset_bars);
  out->sync_divisor = load_i32(&tr->a_sync_divisor);
  out->one_shot = load_i32(&tr->a_one_shot);
  out->reversed = load_i32(&tr->a_reversed); /* #1162 */
  /* Timing fields are filled below from one coherent callback tuple. */
  /* The caller fills timing from one coherent family tuple. */
  out->overdub_feedback_override = load_f32(&tr->a_overdub_fb_bits);
  /* Mixer facts (slice 3): solo and the post-fader stereo peaks. */
  out->solo = load_i32(&tr->a_solo);
  out->image_revision = atomic_load_explicit(&tr->a_image_revision, memory_order_acquire);
  out->peak_l = load_f32(&tr->a_trk_peak_l_bits);
  out->peak_r = load_f32(&tr->a_trk_peak_r_bits);
  out->settled_take_id =
      active ? atomic_load_explicit(&tr->a_settled_take_id, memory_order_acquire)
             : 0;
  out->restore_state = active ? load_i32(&tr->a_restore_state) : 0;
  out->position_frames = active ? load_i32(&tr->a_play_pos) : 0;
  out->pending_trigger =
      active && out->pending ? load_i32(&tr->a_pending_trigger) : -1;
}

/* Max added latency (frames) across every active octaver in any record-route or
 * monitor lane chain — the value the snapshot surfaces so the UI can warn about
 * monitoring lag (part 5). Scanned here on the control thread (a render-rate
 * poll) rather than cached on an fx-change atomic: an fx's type and count are
 * committed by the audio thread's ring handler, so a control-thread setter can't
 * see the post-commit chain — a pull-time scan of the published a_fx_type /
 * a_fx_count atomics is the only race-free seam. The audio thread never reads
 * this. Today only the octaver contributes (le_octaver_latency); the max keeps
 * it forward-compatible, and a chain with no octaver yields 0. */
static int32_t le_max_fx_latency(le_engine* engine) {
  int32_t max_lat = 0;
  for (int32_t t = 0; t < engine->track_count; ++t) {
    le_track* tr = &engine->tracks[t];
    for (int32_t l = 0; l < le_lanes_active(tr); ++l) {
      le_lane* ln = &tr->lanes[l];
      int32_t n = load_i32(&ln->a_fx_count);
      if (n > LE_FX_MAX) n = LE_FX_MAX;
      /* A bypassed slot settles into a full skip (fx_apply_chain) and adds
       * no real delay, so disabled slots must not keep the monitoring-lag
       * warning alive. Granularity: the ~5 ms ramp is far below this
       * render-rate poll's resolution. */
      const int32_t chain_on = load_i32(&ln->a_fx_chain_enabled);
      for (int32_t s = 0; s < n; ++s) {
        if (!(chain_on && load_i32(&ln->a_fx_enabled[s]))) continue;
        const int32_t lat =
            le_fx_added_latency(&ln->fx, s, load_i32(&ln->a_fx_type[s]));
        if (lat > max_lat) max_lat = lat;
      }
    }
  }
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_monitor_input* m = &engine->monitors[c];
    int32_t n = load_i32(&m->a_fx_count);
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    const int32_t chain_on = load_i32(&m->a_fx_chain_enabled);
    for (int32_t s = 0; s < n; ++s) {
      if (!(chain_on && load_i32(&m->a_fx_enabled[s]))) continue;
      const int32_t lat =
          le_fx_added_latency(&m->fx, s, load_i32(&m->a_fx_type[s]));
      if (lat > max_lat) max_lat = lat;
    }
  }
  return max_lat;
}

/* The FNV-1a byte fold (le_fx_fp_u32) is shared from engine_core.h — one
 * definition for this canonical fold, the wet cache's enqueue-snapshot fold
 * (engine_cache.c), and, mirrored, the Dart trackChainFingerprint. */

/* Order-sensitive fingerprint of a published fx chain (a_fx_count active of the
 * a_fx_type / a_fx_param arrays plus the two enable-flag levels). Fold order
 * (D-FPEMPTY, pinned — the Dart mirror fxChainFingerprint folds the same
 * positions): the chain-enabled bit first, but only for a NON-empty chain, so
 * an empty chain still hashes to the FNV offset basis (chain-disabled empty ≡
 * enabled empty ≡ dry — the documented empty-chain invariant); then per entry
 * its type, its slot-enabled bit, and (built-ins only) its LE_FX_PARAMS
 * float-bit params — a plugin entry (LE_FX_PLUGIN) folds type + enabled bit
 * only. The Dart repository computes the identical hash over its cache. */
static uint64_t le_fx_chain_fingerprint(
    int32_t count, _Atomic int32_t* a_type,
    _Atomic uint32_t (*a_param)[LE_FX_PARAMS], _Atomic int32_t* a_enabled,
    _Atomic int32_t* a_chain_enabled) {
  uint64_t h = 0xcbf29ce484222325ULL; /* FNV-1a 64-bit offset basis */
  int32_t n = count;
  if (n < 0) n = 0;
  if (n > LE_FX_MAX) n = LE_FX_MAX;
  if (n > 0) {
    h = le_fx_fp_u32(h, load_i32(a_chain_enabled) ? 1u : 0u);
  }
  for (int32_t i = 0; i < n; ++i) {
    const int32_t type = load_i32(&a_type[i]);
    h = le_fx_fp_u32(h, (uint32_t)type);
    h = le_fx_fp_u32(h, load_i32(&a_enabled[i]) ? 1u : 0u);
    if (type == LE_FX_PLUGIN) continue; /* plugin params live in the host */
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      h = le_fx_fp_u32(
          h, atomic_load_explicit(&a_param[i][p], memory_order_relaxed));
    }
  }
  return h;
}

uint64_t le_engine_lane_fx_fingerprint(le_engine* engine, int32_t channel,
                                       int32_t lane) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count ||
      lane < 0 || lane >= LE_MAX_LANES) {
    return 0;
  }
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  return le_fx_chain_fingerprint(load_i32(&ln->a_fx_count), ln->a_fx_type,
                                 ln->a_fx_param, ln->a_fx_enabled,
                                 &ln->a_fx_chain_enabled);
}

uint64_t le_lane_pre_fx_fingerprint(le_engine* engine, int32_t channel,
                                    int32_t lane) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count ||
      lane < 0 || lane >= LE_MAX_LANES) {
    return 0;
  }
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t pre = load_i32(&ln->a_fx_pre_count);
  const int32_t count = load_i32(&ln->a_fx_count);
  if (pre > count) pre = count; /* a torn read is a live fallback, never a lie */
  uint64_t h = le_fx_chain_fingerprint(pre, ln->a_fx_type, ln->a_fx_param,
                                       ln->a_fx_enabled,
                                       &ln->a_fx_chain_enabled);
  /* The channel handling too (slice 3e): the render applies it, so a change
   * to an input choice, a placement or a level makes the published print as
   * stale as a param change does. */
  le_fx_chan chan[LE_FX_MAX];
  int32_t chan_any = 0;
  memset(chan, 0, sizeof(chan));
  le_fx_chan_snapshot(chan, &chan_any, pre, ln->a_fx_chan_in,
                      ln->a_fx_chan_out, ln->a_fx_chan_gl_bits,
                      ln->a_fx_chan_gr_bits, ln->a_fx_chan_level_bits);
  for (int32_t s = 0; s < pre; ++s) h = le_fx_chan_fold(h, &chan[s]);
  return h;
}

/* Whether track [channel]'s Pre run can be rendered at all (slice 3e).
 *
 * Every active part's chain must be WHOLLY PRE. A part carrying a Post entry
 * makes the track's Pre run permanently live, because the render would
 * otherwise have to cover that Post entry — it is upstream of the track's
 * chain — and a baked Post tail cannot drain past a Stop, which is the
 * promise that part's own switch makes. Reported through the cache's usual
 * "why is this live" channel rather than silently.
 *
 * A part whose chain is EMPTY is fine: its dry recording is its own printed
 * material. */
int le_track_pre_printable(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) return 0;
  le_track* t = &engine->tracks[channel];
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) {
    le_lane* ln = &t->lanes[l];
    int32_t count = load_i32(&ln->a_fx_count);
    if (count < 0) count = 0;
    if (count > LE_FX_MAX) count = LE_FX_MAX;
    int32_t pre = load_i32(&ln->a_fx_pre_count);
    if (pre < 0) pre = 0;
    if (pre > count) pre = count;
    if (count > pre) return 0; /* a Post entry on a part */
    for (int slot = 0; slot < count; ++slot)
      if (load_i32(&ln->a_fx_type[slot]) == LE_FX_PLUGIN) return 0;
  }
  return 1;
}

/* The whole-track print's key (slice 3e): everything that moves the combined
 * material a track's Pre run is rendered over.
 *
 * Folded in order: the track's Pre-run fingerprint and its channel handling,
 * the active part count, then per part its own Pre-prefix fingerprint (which
 * already carries that part's channel handling), its full chain length — so a
 * Post entry appearing moves the key even though the prefix did not — its
 * level, its pan gains and its mute. Level, pan and mute are inside the sum
 * and cannot be applied after it, so they belong to the key.
 *
 * Solo is deliberately absent: it gates the track as a whole, so the audio
 * thread applies it to the rendered pair exactly as it applies it live. */
uint64_t le_track_pre_fingerprint(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) return 0;
  le_track* t = &engine->tracks[channel];
  le_fx_bus* b = &t->bus;
  int32_t pre = load_i32(&b->a_fx_pre_count);
  const int32_t count = load_i32(&b->a_fx_count);
  if (pre > count) pre = count; /* a torn read is a live fallback, never a lie */
  uint64_t h = le_fx_chain_fingerprint(pre, b->a_fx_type, b->a_fx_param,
                                       b->a_fx_enabled, &b->a_fx_chain_enabled);
  le_fx_chan chan[LE_FX_MAX];
  int32_t chan_any = 0;
  memset(chan, 0, sizeof(chan));
  le_fx_chan_snapshot(chan, &chan_any, pre, b->a_fx_chan_in, b->a_fx_chan_out,
                      b->a_fx_chan_gl_bits, b->a_fx_chan_gr_bits,
                      b->a_fx_chan_level_bits);
  for (int32_t s = 0; s < pre; ++s) h = le_fx_chan_fold(h, &chan[s]);

  const int32_t n = le_lanes_active(t);
  h = le_fx_fp_u32(h, (uint32_t)n);
  for (int32_t l = 0; l < n; ++l) {
    le_lane* ln = &t->lanes[l];
    const uint64_t lane_fp = le_lane_pre_fx_fingerprint(engine, channel, l);
    h = le_fx_fp_u32(h, (uint32_t)lane_fp);
    h = le_fx_fp_u32(h, (uint32_t)(lane_fp >> 32));
    h = le_fx_fp_u32(h, (uint32_t)load_i32(&ln->a_fx_count));
    h = le_fx_fp_u32(
        h, atomic_load_explicit(&ln->a_vol_bits, memory_order_relaxed));
    h = le_fx_fp_u32(
        h, atomic_load_explicit(&ln->a_pan_gl_bits, memory_order_relaxed));
    h = le_fx_fp_u32(
        h, atomic_load_explicit(&ln->a_pan_gr_bits, memory_order_relaxed));
    h = le_fx_fp_u32(h, load_i32(&ln->a_muted) ? 1u : 0u);
  }
  return h;
}

uint64_t le_engine_monitor_fx_fingerprint(le_engine* engine, int32_t input) {
  if (engine == NULL || input < 0 || input >= LE_MAX_MONITORED_INPUTS) return 0;
  le_monitor_input* m = &engine->monitors[input];
  return le_fx_chain_fingerprint(load_i32(&m->a_fx_count), m->a_fx_type,
                                 m->a_fx_param, m->a_fx_enabled,
                                 &m->a_fx_chain_enabled);
}

void le_engine_get_snapshot(le_engine* engine, le_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  /* Collect retired per-pass undo layers (and replenish shadow spares) on the
   * UI's poll cadence, so undo depths stay fresh and queued undo taps apply. */
  le_engine_drain_events(engine);
  const le_record_timing_readback timing = le_record_timing_read(engine, 1);
  out->record_timing_revision = timing.revision;
  out->record_timing_result = timing.result;
  out->running = atomic_load_explicit(&engine->a_running, memory_order_acquire);
  out->device_present =
      atomic_load_explicit(&engine->a_device_present, memory_order_acquire);
  out->sample_rate = load_i32(&engine->a_sample_rate);
  out->buffer_frames = load_i32(&engine->a_buffer_frames);
  out->input_channels = load_i32(&engine->a_in_channels);
  out->output_channels = load_i32(&engine->a_out_channels);
  out->excluded_input_mask =
      atomic_load_explicit(&engine->a_excluded_input_mask, memory_order_relaxed);
  out->frames_processed =
      atomic_load_explicit(&engine->a_frames, memory_order_relaxed);
  out->xrun_count = atomic_load_explicit(&engine->a_xruns, memory_order_relaxed);
  out->input_rms = load_f32(&engine->a_in_rms_bits);
  out->tuner_hz = load_f32(&engine->a_tuner_hz_bits);
  out->tuner_confidence = load_f32(&engine->a_tuner_conf_bits);
  out->tuner_input = load_i32(&engine->a_tuner_input);
  out->input_peak = load_f32(&engine->a_in_peak_bits);
  out->output_rms = load_f32(&engine->a_out_rms_bits);
  out->latency_state = load_i32(&engine->a_latency_state);
  out->measured_latency_ms = bits_to_f64(
      atomic_load_explicit(&engine->a_latency_ms_bits, memory_order_relaxed));
  out->master_length_frames = load_i32(&engine->a_master_len);
  out->master_position_frames = load_i32(&engine->a_master_pos);
  out->record_offset_frames = load_i32(&engine->a_record_offset);
  out->fx_added_latency_frames = le_max_fx_latency(engine);
  out->master_gain = load_f32(&engine->a_master_gain_bits);
  out->active_backend = load_i32(&engine->a_active_backend);
  out->output_enabled_mask =
      atomic_load_explicit(&engine->a_output_enabled_mask, memory_order_relaxed);
  out->perf_armed = load_i32(&engine->a_perf_armed);
  out->perf_frames =
      atomic_load_explicit(&engine->a_perf_frames, memory_order_relaxed);
  out->perf_overruns =
      atomic_load_explicit(&engine->a_perf_overruns, memory_order_relaxed);
  out->perf_zero_filled_frames = atomic_load_explicit(
      &engine->a_perf_zero_filled_frames, memory_order_relaxed);
  /* No drain (never armed, or already disarmed) reads as "not stopped" -- the
   * flag describes a live capture that died, not the absence of one. */
  out->perf_stopped =
      engine->perf.drain ? le_perf_drain_self_stopped(engine->perf.drain) : 0;
  out->track_count = engine->track_count;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_fill_track_snapshot(engine, t, t < engine->track_count,
                           &out->tracks[t]);
    le_timing_track_fields(&out->tracks[t], timing.track_timing[t]);
    out->record_timing_overrides[t] = timing.track_timing[t];
  }
  /* Tempo grid (trailing block; grid-off defaults read 0/4/4/1/0/0/0/0). */
  out->tempo_bpm = load_f32(&engine->a_tempo_bpm_bits);
  out->ts_num = load_i32(&engine->a_ts_num);
  out->ts_den = load_i32(&engine->a_ts_den);
  out->sync_tempo = load_i32(&engine->a_sync_tempo);
  out->quantize_div = timing.remembered_division;
  out->tempo_source = load_i32(&engine->a_tempo_source);
  out->loop_bars = load_i32(&engine->a_loop_bars);
  out->current_beat = load_i32(&engine->a_current_beat);
  /* Click + count-in (trailing block; click-off defaults read 0/0/1/0/0/0). */
  /* A command receipt is sampled only after commands_settled acquired the
   * callback boundary, synchronously before the sole producer posts another. */
  out->click_mode = load_i32(&engine->a_click_mode);
  out->click_mode_revision = atomic_load_explicit(&engine->a_click_mode_revision,
                                                 memory_order_relaxed);
  out->click_mode_result = load_i32(&engine->a_click_mode_result);
  out->click_mask =
      atomic_load_explicit(&engine->a_click_mask, memory_order_relaxed);
  out->click_volume = load_f32(&engine->a_click_volume_bits);
  out->mix_revision = atomic_load_explicit(&engine->a_mix_revision, memory_order_acquire);
  const int32_t record_start = load_i32(&engine->a_record_start);
  out->count_in_bars = record_start > 0 ? record_start : 0;
  out->auto_record = record_start < 0;
  out->record_start_revision = atomic_load_explicit(&engine->a_record_start_revision,
                                                   memory_order_relaxed);
  out->record_start_result = load_i32(&engine->a_record_start_result);
  out->counting_in = load_i32(&engine->a_counting_in);
  out->count_in_beats_left = load_i32(&engine->a_count_in_beats_left);
  /* Looper mode (B2a, D4; trailing block; default reads 0 = MULTI). */
  out->looper_mode = load_i32(&engine->a_looper_mode);
  /* Primary track (B3, D18; trailing block; default reads -1 = none). */
  out->primary_track = load_i32(&engine->a_primary_track);
  /* MIDI clock (Phase C, D15; trailing block; default reads 0 = OFF). */
  out->clock_mode = load_i32(&engine->a_clock_mode);
  /* Native MIDI input sink totals (#1228 Part 1; trailing block). */
  out->midi_in_events =
      atomic_load_explicit(&engine->a_midi_in_events, memory_order_relaxed);
  out->midi_in_stale =
      atomic_load_explicit(&engine->a_midi_in_stale, memory_order_relaxed);
  out->midi_in_overflows =
      atomic_load_explicit(&engine->a_midi_in_overflows, memory_order_relaxed);
  out->midi_in_lost =
      atomic_load_explicit(&engine->a_midi_in_lost, memory_order_relaxed);
  uint32_t attached = 0u;
  for (int p = 0; p < LE_MAX_MIDI_PORTS; ++p) {
    if (atomic_load_explicit(&engine->midi_ports[p].a_owner,
                             memory_order_acquire) != NULL) {
      attached |= 1u << p;
    }
  }
  out->midi_in_attached_mask = attached;
  out->midi_in_rebinds =
      atomic_load_explicit(&engine->a_midi_in_rebinds, memory_order_relaxed);
  /* Input clip + conditioning activity (input clip, S2; trailing block).
   * The clip mask is the audio thread's published verdict; the cond mask is
   * derived here from the published per-input enables intersected with the
   * loopback exclusion — the same gate the audio thread applies before
   * running a stage, so a bit is set iff the stage actually runs. */
  out->input_clip_mask =
      atomic_load_explicit(&engine->a_input_clip_mask, memory_order_relaxed);
  uint32_t cond_mask = 0u;
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (load_i32(&engine->cond[c].a_enabled) &&
        !(out->excluded_input_mask & (1u << c))) {
      cond_mask |= 1u << c;
    }
  }
  out->input_cond_mask = cond_mask;
  out->output_peak = load_f32(&engine->a_out_peak_bits);
  /* Record start settings (slice 2b; trailing block): control-side plain
   * ints, read on the same thread that writes them. */
  out->quantize = timing.default_timing != 0;
  out->overdub_feedback = load_f32(&engine->a_overdub_fb_bits);
  /* Output buses (slice 3b; trailing block). */
  out->output_bus_count = (out->output_channels + 1) / 2;
  for (int32_t k = 0; k < LE_MAX_OUTPUT_BUSES; ++k) {
    out->output_level[k] = load_f32(&engine->outputs[k].a_level_bits);
    out->output_muted[k] = load_i32(&engine->outputs[k].a_muted);
    out->output_mono[k] = load_i32(&engine->outputs[k].a_mono);
    out->output_balance[k] = load_f32(&engine->outputs[k].a_balance_bits);
  }
  out->tail_reset_rev =
      atomic_load_explicit(&engine->a_tail_reset_rev, memory_order_relaxed);
  const int perf_armed =
      atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire);
  out->perf_follow_output = perf_armed ? engine->perf.follow_output
                                       : load_i32(&engine->a_perf_follow_output);
  if (perf_armed) {
    out->perf_capture_bus = engine->perf.master_out_ch[0] >= 0
                                ? engine->perf.master_out_ch[0] / 2
                                : -1;
  } else {
    int32_t out_ch[2];
    out->perf_capture_bus =
        le_perf_first_enabled_pair(engine, out_ch) > 0 ? out_ch[0] / 2 : -1;
  }
  out->perf_output_level = perf_armed ? engine->perf.output_level : 1.0f;
  out->perf_output_muted = perf_armed ? engine->perf.output_muted : 0;
  out->perf_capture_mask = 0;
  out->perf_output_enabled_mask = perf_armed ? engine->perf.output_enabled_mask : 0;
  if (perf_armed) {
    for (int i = 0; i < engine->perf.master_channels; ++i)
      out->perf_capture_mask |= 1u << engine->perf.master_out_ch[i];
  }
  /* Per-channel meters and trim (slice 3; trailing block). */
  for (int32_t c = 0; c < LE_MAX_CHANNELS; ++c) {
    out->input_peaks[c] = load_f32(&engine->a_in_peak_ch_bits[c]);
    out->output_peaks[c] = load_f32(&engine->a_out_peak_ch_bits[c]);
    out->input_trim[c] = load_f32(&engine->a_in_trim_bits[c]);
    out->monitor_peaks[c] =
        c < LE_MAX_MONITORED_INPUTS ? load_f32(&engine->monitors[c].a_peak_bits)
                                    : 0.0f;
  }
  /* The audio-callback telemetry (#722) is deliberately NOT read here — it has
   * its own entry point below. Anything on this struct is projected into the
   * app's render-rate state, whose equality drives the rebuild dedupe, and a
   * counter that ticks on every audio callback would defeat it. */
}

void le_engine_get_callback_telemetry(le_engine* engine,
                                      le_callback_telemetry* out) {
  if (out == NULL) return;
  if (engine == NULL) {
    memset(out, 0, sizeof(*out));
    return;
  }
  /* Pure relaxed loads — and, unlike le_engine_get_snapshot above, NO
   * le_engine_drain_events: a diagnostic read has no business collecting
   * retired undo layers as a side effect. */
  le_cb_timing_read(&engine->cb_timing, out);
}

void le_engine_get_track(le_engine* engine, int32_t channel,
                         le_track_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  if (channel < 0 || channel >= engine->track_count) {
    out->state = LE_TRACK_EMPTY;
    out->volume = 1.0f;
    out->muted = 0;
    out->length_frames = 0;
    out->multiple = 1;
    out->undo_depth = 0;
    out->clear_restore = 0;
    out->redo_depth = 0;
    out->peel_depth = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    out->input_mask = 0x1u;
    out->output_mask = 0x3u;
    out->lane_count = 1;
    out->layer_in_flight = 0;
    out->pending = 0;
    out->length_preset_bars = 0;
    out->sync_divisor = 0;
    out->one_shot = 0;
    out->solo = 0;
    out->image_revision = 0;
    out->peak_l = 0.0f;
    out->peak_r = 0.0f;
    out->settled_take_id = 0;
    out->restore_state = 0;
    out->position_frames = 0;
    out->pending_trigger = -1;
    out->quantize_override = -1;
    out->quantize_div_override = -1;
    out->overdub_feedback_override = -1.0f;
    return;
  }
  const le_record_timing_readback timing = le_record_timing_read(engine, 0);
  le_fill_track_snapshot(engine, channel, 1, out);
  le_timing_track_fields(out, timing.track_timing[channel]);
}

void le_engine_get_lane(le_engine* engine, int32_t channel, int32_t lane,
                        le_lane_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  if (channel < 0 || channel >= engine->track_count || lane < 0 ||
      lane >= LE_MAX_LANES) {
    out->input_channel = -1;
    out->output_mask = 0x3u;
    out->volume = 1.0f;
    out->muted = 0;
    out->length_frames = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    out->recoverable = 0;
    out->pan = 0.0f;
    return;
  }
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  out->input_channel = load_i32(&ln->a_input_channel);
  out->output_mask =
      atomic_load_explicit(&ln->a_output_mask, memory_order_relaxed);
  out->volume = load_f32(&ln->a_vol_bits);
  out->muted = load_i32(&ln->a_muted);
  out->length_frames = load_i32(&ln->a_len);
  out->rms = load_f32(&ln->a_rms_bits);
  out->peak = load_f32(&ln->a_peak_bits);
  out->recoverable = load_i32(&ln->a_recoverable); /* #595 */
  out->pan = load_f32(&ln->a_pan_bits);
}

int32_t le_engine_read_visual(le_engine* engine, float* out,
                              int32_t max_points) {
  if (engine == NULL || out == NULL || max_points <= 0) return 0;
  const int32_t n = max_points < LE_VIZ_POINTS ? max_points : LE_VIZ_POINTS;
  /* Loop-indexed, bucket 0 = loop start. A bucket updated concurrently is
   * benign for a waveform. */
  for (int32_t i = 0; i < n; ++i) {
    out[i] = load_f32(&engine->a_loop_viz[i]);
  }
  return n;
}

int32_t le_engine_read_track_visual(le_engine* engine, int32_t channel,
                                    float* out, int32_t max_points) {
  if (engine == NULL || out == NULL || max_points <= 0) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  const int32_t n = max_points < LE_VIZ_POINTS ? max_points : LE_VIZ_POINTS;
  for (int32_t i = 0; i < n; ++i) {
    out[i] = load_f32(&engine->a_track_viz[channel][i]);
  }
  return n;
}
