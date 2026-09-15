/*
 * engine_internal.h — non-public engine entry points for deterministic tests.
 *
 * These let native tests drive the looper DSP with synthetic buffers, without
 * opening an audio device. Not part of the FFI surface (excluded from ffigen).
 */
#ifndef SEGNO_ENGINE_INTERNAL_H
#define SEGNO_ENGINE_INTERNAL_H

#include <stdint.h>

#include "le_device_backend.h"  /* le_device_backend (le_select_backend return) */
#include "segno_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Selects the device backend for a requested le_audio_backend (le_config.backend).
 * In this build the only implementation is the miniaudio backend, so every input
 * returns it; the opt-in ASIO branch lands in Part 2. The default build never
 * references an ASIO symbol. Not part of the FFI surface. */
const le_device_backend* le_select_backend(int32_t backend);

/* Publishes the "device present + running" lifecycle flags after a backend's
 * start() succeeds (release stores, mirroring the miniaudio backend). Exists so a
 * device backend implemented in a C++ TU (the opt-in ASIO backend) can mark the
 * engine started without including the _Atomic struct definition in
 * engine_private.h, keeping all atomic access in C. Not part of the FFI surface. */
void le_engine_mark_started(le_engine* engine);

/* Increments the published xrun (dropout) tally by one, as an
 * LE_XRUN_BACKEND_OVERLOAD. Called from a device backend's overload
 * notification — the ASIO driver's kAsioOverload message. A C helper for the
 * same reason as le_engine_mark_started (C++ backend TUs avoid the _Atomic
 * field). Relaxed atomic; safe off any thread. Not part of the FFI surface. */
void le_engine_note_xrun(le_engine* engine);

/* The general form of the above: records one backend dropout of `kind` (an
 * le_xrun_kind) into xrun_count AND into the per-kind telemetry windows (#722).
 * The ALSA data loop calls this through the miniaudio backend's hook for its
 * -EPIPE recoveries and slipped-playback resyncs, which is what finally makes
 * xrun_count non-zero on Linux. Relaxed atomics only — safe to call from the
 * device's data-loop thread. Not part of the FFI surface. */
void le_engine_note_backend_xrun(le_engine* engine, int32_t kind);

/* Records one device-callback span, [entry_ns, exit_ns) over `frames`, taken
 * with le_now_ns around the backend's call into le_engine_process (#722).
 * `frames` is this callback's own block size, which is NOT its own deadline:
 * the duplex loop splits one hardware period across several callbacks, so
 * le_cb_timing_note sums consecutive spans into one PERIOD SERVICE and judges
 * that total against the frames it covered. The nominal period seeded by
 * le_engine_configure_callback_budget is the batching unit and the gap
 * threshold; `frames` only tells the accumulator how much of one this callback
 * carried. (Deriving a per-callback deadline from `frames` alone is exactly the
 * false positive that fix 1be46380 removed — a 16-frame tail block would get
 * 166 us for overhead a 64-frame block absorbs inside 666 us, and would read as
 * late on perfectly healthy hardware.) Called ON the audio thread from the
 * backend's data callback and RT-safe by construction (engine_telemetry.h).
 * Exposed here (rather than poking engine->cb_timing) so a backend TU need not
 * touch the _Atomic struct, and so native tests can feed synthetic spans. Not
 * part of the FFI surface. */
void le_engine_note_callback_span(le_engine* engine, uint64_t entry_ns,
                                  uint64_t exit_ns, uint32_t frames);

/* Breaks the callback TIMELINE without touching the accumulated measurements:
 * the next callback reports no entry-to-entry gap and starts a fresh period
 * service (#722, review finding 5). Called from the device-notification path
 * whenever the callback stream is about to be interrupted — a stop, a device
 * reroute, or a system audio interruption — because miniaudio reinitialises
 * internally and resumes the data callback with the PRE-stall entry stamp still
 * held. Without this, one macOS default-device switch mid-session manufactures
 * a single ~200 ms gap: gap_events goes to 1 and max_gap_us stays pinned there
 * for the rest of the device session, violating the "healthy rig reads zeros"
 * constraint and sending the bench after a phantom stall.
 *
 * Safe off ANY thread: it only raises a flag the audio thread consumes, so the
 * timeline fields keep their single-writer ownership (see engine_telemetry.h).
 * Not part of the FFI surface. */
void le_engine_note_callback_timeline_break(le_engine* engine);

/* Opens a fresh callback-telemetry session at the negotiated `sample_rate` and
 * NOMINAL `period_frames`: clears both windows AND the flat a_xruns tally (they
 * are two views of the same events and must never disagree), then arms the
 * instrument. The period is what the period-service accumulator batches to and
 * what the gap detector is measured against — a per-block threshold would fire
 * on the normal burst-then-wait rhythm of a split duplex loop. Called by
 * le_engine_start once the backend reports both — deliberately NOT by
 * le_engine_configure, which seeds inert zeros instead, so an engine that never
 * opened a device (the native test pump) measures nothing. Control thread only,
 * while the device is shut. Not part of the FFI surface. */
void le_engine_configure_callback_budget(le_engine* engine,
                                         int32_t sample_rate,
                                         int32_t period_frames);

/* Publishes "device lost" (a_device_present = 0, a_running untouched) so the
 * control layer drives reconnection. Mirrors the miniaudio device-notification
 * callback; called by the ASIO reset-request / sample-rate-change handlers so a
 * driver reconfigured out from under us recovers via stop -> start rather than
 * going silent. Relaxed atomic; safe off the driver's message thread. Not part
 * of the FFI surface. */
void le_engine_mark_device_lost(le_engine* engine);

/* Allocates the track buffers and sets engine parameters WITHOUT opening a
 * device. Used by le_engine_start and by tests. `input_channels` /
 * `output_channels` are each clamped to LE_MAX_CHANNELS and `max_loop_frames` to
 * a positive value. Returns LE_OK or LE_ERR_INVALID. */
int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t input_channels, int32_t output_channels,
                            int32_t max_loop_frames);

/* Processes one interleaved block: drains commands, advances the loop, records/
 * overdubs/mixes, and publishes metering. This is exactly what the miniaudio
 * data callback invokes, exposed so tests can call it directly. */
void le_engine_process(le_engine* engine, float* output, const float* input,
                       uint32_t frames);

/* Runs the master-bus per-frame step (master gain -> feed-forward limiter ->
 * output metering) on out[f*ch_out .. +ch_out) in isolation, with explicit gain /
 * limiter params, so the limiter dynamics can be unit-tested without a full block.
 * Reads/updates engine->lim_gain. Not part of the FFI surface. */
void le_engine_master_bus_frame_for_test(le_engine* engine, float* out,
                                         uint32_t f, int ch_out,
                                         float master_gain, int limiter_on,
                                         float limiter_ceiling, float lim_release,
                                         float* out_sumsq, float* frame_out_peak);

/* Classifies a capture device by name into a loopback kind (name heuristic
 * only; backend built-in loopback detection is context-level). Pure and
 * unit-testable. */
le_loopback_kind le_classify_capture_device(const char* name);

/* Whether a Core Audio channel label marks a loopback channel (case-insensitive
 * substring "loopback"). Pure and unit-testable; a NULL/blank label is not a
 * loopback. */
int le_label_is_loopback(const char* label);

/* Sightings an entry of the channel-count memo is trusted for before it is read
 * again (engine_devices.c, where the rationale for a per-entry countdown lives).
 * Exposed so the stability test can run enumeration PAST the TTL and cover the
 * re-read branch, rather than hardcoding a pass count that a retune would leave
 * short without failing anything. Not part of the FFI surface. */
#define LE_CHANNEL_CACHE_TTL 32

/* TEST SEAM into the channel-count memo (engine_devices.c): runs the memo's
 * decision core for (key, capture) with `query` standing in for the expensive
 * live device query (called with `env`; returns the channel count, 0 =
 * failed). Lets a test script answers — in particular the persistent-failure
 * case behind the negative TTL (#649), which no real device on a CI box can be
 * made to produce on demand. Shares the live table, so tests must use keys no
 * real device id can collide with. Control thread only, like the memo. */
int32_t le_channel_memo_for_test(const char* key, int capture,
                                 int32_t (*query)(void* env), void* env);

/* YIN pitch detector for the PSOLA octaver (mode >= 0.5). Runs the cumulative-
 * mean-normalized difference function over `n` contiguous samples of `x` at `sr`
 * Hz, searching the vocal band (~60-1000 Hz), and returns a sub-sample period
 * estimate (parabolic-interpolated, in samples) in *out_period and a voicing
 * confidence in [0,1] (1 = perfectly periodic) in *out_voiced. Returns 1 when the
 * frame reads as confidently voiced, else 0 (silence or aperiodic). Pure (no
 * engine state) and unit-tested directly so the octave-error guard is verifiable
 * independently of the lossy grain synthesis. Defined in engine.c. */
int le_psola_detect(const float* x, int n, int sr, float* out_period,
                    float* out_voiced);

/* The same detector over an explicit [min_hz, max_hz] band, which is what the
 * tuner needs and the octaver does not: the band is derived from `sr`, so
 * decimating the signal rescales BOTH ends and never lowers the floor on its
 * own. Bass low B is 30.87 Hz, well under the octaver's ~60 Hz floor.
 *
 * Lags are `sr/max_hz` .. `sr/min_hz`, so cost is proportional to the WIDTH of
 * the band in samples — which is why the tuner hands it a decimated signal:
 * the same 30 Hz floor is 200 lags at 6 kHz against 1600 at 48 kHz.
 * [le_psola_detect] is this function at (60, 1000). */
int le_psola_detect_band(const float* x, int n, int sr, int min_hz, int max_hz,
                         float* out_period, float* out_voiced);

/* The read side of the tuner's device-rate refinement ring: copies its
 * LE_TUNER_RAW samples into `out` oldest-first, which is the contiguous
 * chronological window the refinement pass walks. The ring is circular (a
 * shifting FIFO cost 8188 bytes memmoved per frame — see tuner_raw in
 * engine_private.h), so this is where the wrap is untangled, and exposing it
 * is what lets a test pin that a wrapped ring reads back exactly what the
 * shifting version did. Returns 0 and leaves `out` untouched until the ring
 * has filled once. Defined in engine_process.c. */
int le_tuner_raw_window(const le_engine* e, float* out);

/* ---- ASIO bridge math (pure, platform-agnostic; defined in engine.c) ---- *
 *
 * ASIO hands the device callback non-interleaved, per-channel blocks in the
 * driver's native sample format, whereas le_engine_process works on one
 * interleaved f32 buffer. These two helpers absorb both differences and are the
 * riskiest part of the ASIO backend, so they live in the portable core (no ASIO
 * headers) and are unit-tested off-thread without any hardware. */

/* Native sample format of one ASIO channel block, mirroring the ASIOSampleType
 * values the backend actually handles (all little-endian). */
typedef enum le_sample_fmt {
  LE_SMP_I16, /* ASIOSTInt16LSB   — 16-bit signed PCM */
  LE_SMP_I24, /* ASIOSTInt24LSB   — packed 24-bit signed PCM (3 bytes/sample) */
  LE_SMP_I32, /* ASIOSTInt32LSB   — 32-bit signed PCM */
  LE_SMP_F32, /* ASIOSTFloat32LSB — 32-bit float */
} le_sample_fmt;

/* Scatters one ASIO input channel's native block into the interleaved f32 buffer
 * le_engine_process reads: for each frame f, converts native_block[f] (format
 * `fmt`) to f32 and writes it to out_interleaved[f * channel_count + chan]. The
 * block holds `frames` samples; the source stride is the format's byte width. */
void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count,
                        int frames);

/* Gathers channel `chan` out of the interleaved f32 buffer le_engine_process
 * produced (in_interleaved[f * channel_count + chan]) and writes it, converted
 * to `fmt` (clamped to the format's range), into one ASIO output channel's
 * native block. The inverse of le_deinterleave_in for f32 (exact round-trip). */
void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count,
                       int frames);

/* Snaps a requested buffer size to a size the ASIO driver actually allows, given
 * its (min, max, preferred, granularity) from ASIOGetBufferSize. granularity:
 *   -1 => powers of two only (snap to the nearest power of two in [min,max]);
 *    0 => the driver offers only `preferred` (always returned);
 *   >0 => linear steps from `min` (snap to the nearest min + k*granularity).
 * A request outside [min,max] (un-honorable) falls back to `preferred`. Pure and
 * unit-tested; used once at open so the device never fails over a chip choice. */
int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity);

/* Per-channel name provider: returns input channel [channel]'s label (or NULL
 * if unavailable). `ctx` is caller state (e.g. an ASIO driver handle or, in
 * tests, a fixed name table). */
typedef const char* (*le_channel_name_fn)(void* ctx, int channel);

/* Builds the excluded-input-channel bitmask from a name provider: bit c is set
 * when get_name(ctx, c) matches le_label_is_loopback. The platform-agnostic
 * core of every label probe (only the name *source* is OS-specific), so it is
 * pure and unit-testable with a fake provider. Channels >= LE_MAX_CHANNELS and
 * a NULL provider yield no bits. Not part of the FFI surface. */
uint32_t le_excluded_mask_from_names(le_channel_name_fn get_name, void* ctx,
                                     int channel_count);

/* Overrides the excluded-input-channel mask without opening a device, so the
 * capture-average / monitoring / SET_INPUT_MASK exclusion paths can be tested
 * deterministically. Not part of the FFI surface. */
void le_engine_set_excluded_input_mask_for_test(le_engine* engine,
                                                uint32_t mask);

/* Begins a round-trip latency measurement without a device (configured-gated,
 * like the looper commands), so the harness's loopback-channel detection can be
 * tested deterministically. Not part of the FFI surface. */
int32_t le_engine_begin_latency_for_test(le_engine* engine);

/* Whether lane [lane] of track [channel] has its live loop buffer allocated.
 * Lets a test assert lazy lane allocation (idle lanes stay unallocated). Returns
 * 0 for out-of-range indices. Not part of the FFI surface. */
int le_engine_lane_buffer_allocated_for_test(le_engine* engine, int32_t channel,
                                             int32_t lane);

/* Allocated frames of lane [lane]'s pool slot [slot] (slot < 0 selects the
 * lane's live slot; 0 = unallocated; -1 = out of range). Lets tests assert the
 * undo-layer quantized sizing and the full-cap live-buffer invariant. Not part
 * of the FFI surface. */
int32_t le_engine_lane_slot_cap_for_test(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t slot);

/* Copies up to [max_frames] frames of lane [lane]'s LIVE loop buffer
 * (pool[a_live]) into [out], for the #697 restoration tests to inspect what a
 * loop-close restoration pass published. Returns the number of frames copied
 * (min of the recorded length and [max_frames]), or 0 for out-of-range indices
 * or an unallocated/empty live slot. Control-thread test seam; not part of the
 * FFI surface. */
int32_t le_engine_read_lane_live_for_test(le_engine* engine, int32_t channel,
                                          int32_t lane, float* out,
                                          int32_t max_frames);

/* Forces track [channel]'s active lane count to [count] WITHOUT allocating the
 * new lanes' buffers, so a test can drive the audio thread into the window where
 * lane_count claims more lanes than are allocated and assert the real-time
 * null-guard keeps it silent (never dereferences a NULL pool). Not part of the
 * FFI surface. */
void le_engine_set_lane_count_unsafe_for_test(le_engine* engine,
                                              int32_t channel, int32_t count);

/* Drives track [channel] lane [lane]'s effect chain once with an explicit stereo
 * pair (*l, *r), writing the processed pair back in place. The device paths seed
 * the chain l == r from a mono source, so this is the only way a test can feed a
 * decorrelated (l != r) input — e.g. an impulse on one channel only — to prove
 * each delay-ringed slot keeps independent left/right ring state. Reads the
 * lane's published chain config (type/params/count); the caller must have drained
 * any pending SET_*_FX commands so the entries' DSP state is reset. Not part of
 * the FFI surface. */
void le_engine_lane_fx_chain_for_test(le_engine* engine, int32_t channel,
                                      int32_t lane, float* l, float* r);

/* ---- performance-recording capture test seams ----
 * Part 1 has no drain thread (that lands in part 2), so these are the only way
 * to read back what le_perf_arm's rings actually captured — draining the
 * master/monitor rings for a native test's bit-parity assertions. Not part of
 * the FFI surface. */

/* Pops up to `max_frames` frames (each `le_engine_perf_master_channels_for_test`
 * samples wide) from the master capture ring into `out` (interleaved),
 * returning the number of frames popped. 0 if not armed or the ring is empty.
 */
int32_t le_engine_perf_master_pop_for_test(le_engine* engine, float* out,
                                           int32_t max_frames);

/* The master ring's frame width (1 or 2), or 0 if never armed. Lets a test
 * interpret le_engine_perf_master_pop_for_test's interleaving without
 * hardcoding the channel count the current output-enable state produced. */
int32_t le_engine_perf_master_channels_for_test(le_engine* engine);

/* Pops up to `max_frames` STEREO frames from monitor input [input]'s capture
 * ring into `out` (interleaved l, r), returning the number of frames popped. 0
 * if [input] was not captured (out of range, or not in the frozen mask) or the
 * ring is empty. */
int32_t le_engine_perf_monitor_pop_for_test(le_engine* engine, int32_t input,
                                            float* out, int32_t max_frames);

/* ---- perf-drain test seams (perf_drain.h; part 2) ---- */

struct le_perf_drain; /* opaque; full definition in perf_drain.c */

/* Whether the drain thread stopped itself early (a disk-full write failure)
 * rather than running until le_perf_drain_stop was called. Only safe to call
 * up until the corresponding le_perf_drain_stop — that call frees `drain`, so
 * a `drain` pointer retained past it is a use-after-free. Not part of the FFI
 * surface. */
/* Whether the capture drain thread stopped ITSELF because a write failed
 * (disk full, quota, read-only remount, I/O error).
 *
 * No longer test-only: this is published on the engine snapshot as
 * `perf_stopped` so the app can react. Without that the thread stopped
 * silently -- the capture stayed "armed", its handles stayed open, and finalize
 * never ran, which is how a runaway capture left 105GB of unfinalized .pcm
 * (#640, #652). */
int le_perf_drain_self_stopped(struct le_perf_drain* drain);

/* Forces every subsequent PCM write attempt (across every drain thread in the
 * process) to fail, deterministically simulating a full disk without needing a
 * real one. Disabled by default; a test must re-disable it (pass 0) before the
 * next test runs. Not part of the FFI surface.
 *
 * SCOPE, because getting this wrong sends a test author hunting a drain bug
 * that is not there: only perf_drain.c's le_pd_write consults the flag, so it
 * covers the PCM and silence-fill writes and NOTHING else. It does NOT make
 * the SIDECAR fail — le_pd_write_sidecar goes out through a raw descriptor
 * that never looks at the flag — and it does not make le_pd_flush fail. That
 * exemption is deliberate and load-bearing: it is what lets a test force a PCM
 * failure and then read the resulting `stopped_early` marker back out of a
 * cleanly written performance.json. */
void le_perf_drain_force_write_failure_for_test(int enabled);

/* The same seam with a BYTE BUDGET instead of a switch: the next `bytes` bytes
 * of PCM/silence-fill writing succeed, and everything after that fails. Pass a
 * negative value to restore the unlimited production behaviour (the default);
 * 0 is exactly what le_perf_drain_force_write_failure_for_test(1) sets, and
 * the two share one global, so a test must reset whichever it used before the
 * next test runs. Same SCOPE caveat as above — only le_pd_write_some consults
 * it, so the sidecar and le_pd_flush stay unaffected. Not part of the FFI
 * surface.
 *
 * WHY A BUDGET AND NOT A SWITCH (#718): a positive budget smaller than the
 * write in flight produces a SHORT WRITE — bytes on disk, failure reported —
 * which is how a real filling disk behaves and what the boolean, failing at
 * zero bytes every time, could never reach. The zero-fill catch-up's byte
 * accounting only differs from the all-or-nothing case there. Safe to call
 * from the mid-cycle hook (i.e. on the drain thread), which is how a test
 * arms it mid-pad. */
void le_perf_drain_set_write_budget_for_test(int64_t bytes);

/* Runs `fn(ctx)` on the drain thread inside every drain cycle, at the one
 * instant that matters for #710: after the capture rings have been drained
 * and before the silence-fill catch-up runs. It exists to make the cycle's
 * elapsed-then-drain ordering testable — a hook that pushes frames and bumps
 * a_perf_frames from there stands in for the audio thread producing while a
 * slow cycle writes, which is otherwise a microsecond-wide race no test can
 * hit on purpose. Process-global, NULL (disabled) by default; a test must
 * clear it (pass NULL) before the next test runs. Not part of the FFI
 * surface. */
void le_perf_drain_set_mid_cycle_hook_for_test(void (*fn)(void*), void* ctx);

/* ---- perf-render test seams (perf_render.c; part 8) ---- */

/* Forces the offline render worker's dry-stem write (only) to fail for a
 * single channel, deterministically simulating a transient I/O error on that
 * one write without touching the filesystem or the wet-stem write, and
 * without affecting any other channel's dry write in the same render. Pass
 * the channel id to fail, or -1 to disable. Process-global, disabled (-1) by
 * default; a test must re-disable it (pass -1) before the next test runs.
 * Not part of the FFI surface. */
void le_perf_render_force_dry_write_failure_for_test(int32_t channel);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_INTERNAL_H */
