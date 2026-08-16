/*
 * engine_telemetry.h — the audio callback's self-measurement (#722).
 *
 * A monotonic clock read and a handful of relaxed atomic accumulators: how long
 * each device callback took, how that compares to the deadline that callback's
 * own frame count implies, and how far apart consecutive callbacks arrived.
 * Published on the snapshot as le_cb_window_snapshot (segno_engine_api.h has the
 * "what and why"); this header is the mechanism.
 *
 * REAL-TIME CONTRACT. le_cb_timing_note runs INSIDE the device callback and
 * obeys the same rules as engine_process.c: no allocation, no lock, no
 * unbounded loop, and no syscall beyond the two monotonic clock reads the
 * caller makes around it (clock_gettime(CLOCK_MONOTONIC) is a vDSO read on
 * Linux and a commpage read on Apple platforms — no kernel entry). Everything
 * it touches is a relaxed atomic on a struct that lives inside le_engine, so
 * there is no fence and no contention, and the snapshot reader tolerates a torn
 * view across fields exactly like every other metering atomic in this engine.
 *
 * WRITER OWNERSHIP, precisely (it is NOT uniformly single-writer):
 *   - the duration/gap fields (a_calls, a_late_calls, a_gap_events, a_total_ns,
 *     a_max_ns, a_max_gap_ns, a_bucket[]) are written ONLY by the device
 *     callback thread. That is what licenses the load-compare-store maxima
 *     below: there is no second writer to lose a race to.
 *   - a_xruns[] is MULTI-writer. le_engine_note_backend_xrun fires from
 *     whichever thread noticed the dropout — the ALSA data-loop thread (same
 *     thread as the callback) but also the ASIO driver's message thread — while
 *     the audio thread may be running le_cb_window_reset for an arm. Both sides
 *     use atomic RMW/store, so no value ever tears; the residual imprecision is
 *     that a dropout landing within a hair of an arm boundary may be counted in
 *     the window on either side of it. A one-event ambiguity at a boundary is
 *     immaterial to an instrument whose windows are minutes long, and paying
 *     for a lock on the RT path to remove it would be absurd.
 *
 * HEADER-ONLY on purpose. A new .c TU would have to be added to six build
 * descriptions (CMakeLists, the macOS podspec forwarders, the SPM forwarders,
 * the native test runner, …); static inline in a header that engine_private.h
 * already pulls in costs nothing and drifts nowhere.
 *
 * Gate: -DLE_CALLBACK_TELEMETRY=0 (engine_telemetry_gate.h) compiles every
 * accumulate out to nothing, makes the callers skip their clock reads, drops
 * the dropout-hook install, and removes the hook call sites from the vendored
 * ALSA recovery branches — the audio path is then exactly the pre-#722 build.
 * Default ON: the appliance ships with it, which is the whole point.
 *
 * Purely internal: NOT part of the FFI surface (only the le_cb_window_snapshot
 * it fills is) and not seen by ffigen.
 */
#ifndef SEGNO_ENGINE_TELEMETRY_H
#define SEGNO_ENGINE_TELEMETRY_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "engine_telemetry_gate.h" /* LE_CALLBACK_TELEMETRY (shared with miniaudio_impl.c) */
#include "segno_engine_api.h" /* LE_CB_BUCKETS, LE_XRUN_KINDS, le_cb_window_snapshot */

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Monotonic nanoseconds. Never wall-clock: a stepped or slewed clock would
 * manufacture phantom stalls. The Windows arm exists for completeness (the
 * shipping Windows build runs the ASIO backend, which does not call this). */
static inline uint64_t le_now_ns(void) {
#if defined(_WIN32)
  static LARGE_INTEGER freq = {{0, 0}};
  LARGE_INTEGER now;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&now);
  if (freq.QuadPart <= 0) return 0;
  /* Split to avoid overflowing the 64-bit intermediate on a long uptime. */
  return (uint64_t)(now.QuadPart / freq.QuadPart) * 1000000000ull +
         (uint64_t)((now.QuadPart % freq.QuadPart) * 1000000000ll /
                    freq.QuadPart);
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

/* One accumulation window. Counters are 64-bit throughout: a 32-bit bucket at
 * ~1500 callbacks/second wraps inside about a month, and this instrument is
 * meant to be readable on an appliance that has been up since the last OTA. */
typedef struct le_cb_window {
  _Atomic uint64_t a_calls;
  _Atomic uint64_t a_late_calls;
  _Atomic uint64_t a_gap_events;
  _Atomic uint64_t a_total_ns; /* only ever read to derive a mean */
  _Atomic uint64_t a_max_ns;
  _Atomic uint64_t a_max_gap_ns;
  _Atomic uint64_t a_bucket[LE_CB_BUCKETS];
  _Atomic uint64_t a_xruns[LE_XRUN_KINDS];
} le_cb_window;

/* The whole telemetry state, embedded in le_engine. */
typedef struct le_cb_timing {
  /* Negotiated device rate. Written by the CONTROL thread only while the device
   * is shut (le_engine_configure seeds 0; le_engine_start publishes the real
   * one), read by the audio thread — the same discipline le_engine.sample_rate
   * already follows. 0 = INERT: an engine that never opened a device has no
   * deadline to miss, so the native test pump cannot manufacture one. */
  int32_t sample_rate;
  /* Audio thread only. last_entry_ns is the previous callback's entry stamp for
   * the gap detector (0 = none yet, so the first callback after a start reports
   * no gap rather than a gap the size of the process's uptime); last_budget_ns
   * is that callback's deadline, which is the interval the device was expected
   * to come back within. */
  uint64_t last_entry_ns;
  uint64_t last_budget_ns;
  /* Published for the snapshot: the deadline the most recent callback was
   * judged against. Not derived from le_snapshot.buffer_frames — see
   * le_cb_timing_note for why the two are not the same number. */
  _Atomic uint64_t a_budget_ns;
  /* Set by a counted backend recovery, consumed by the next callback: the stall
   * a recovery causes IS the xrun already counted, and letting it also fire the
   * gap detector would double-count one physical dropout and blow out
   * max_gap_us. Written from the ALSA data-loop thread (the same thread as the
   * callback) and cleared by an atomic exchange in the callback. */
  _Atomic int32_t a_gap_suppress;
  le_cb_window session;
  le_cb_window armed;
} le_cb_timing;

static inline void le_cb_window_reset(le_cb_window* w) {
  atomic_store_explicit(&w->a_calls, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_late_calls, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_gap_events, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_total_ns, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_max_ns, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_max_gap_ns, 0u, memory_order_relaxed);
  for (int i = 0; i < LE_CB_BUCKETS; ++i) {
    atomic_store_explicit(&w->a_bucket[i], 0u, memory_order_relaxed);
  }
  for (int i = 0; i < LE_XRUN_KINDS; ++i) {
    atomic_store_explicit(&w->a_xruns[i], 0u, memory_order_relaxed);
  }
}

/* Seeds the negotiated rate and clears BOTH windows — a fresh device session is
 * a fresh measurement, exactly like a_xruns (which le_engine_configure_callback_
 * budget clears in the same breath, so the flat tally and the per-kind windows
 * can never disagree). A non-positive rate leaves the instrument inert. */
static inline void le_cb_timing_configure(le_cb_timing* t, int32_t sample_rate) {
  if (t == NULL) return;
  t->sample_rate = sample_rate > 0 ? sample_rate : 0;
  t->last_entry_ns = 0;
  t->last_budget_ns = 0;
  atomic_store_explicit(&t->a_budget_ns, 0u, memory_order_relaxed);
  atomic_store_explicit(&t->a_gap_suppress, 0, memory_order_relaxed);
  le_cb_window_reset(&t->session);
  le_cb_window_reset(&t->armed);
}

/* Clears the armed window. Called from the AUDIO thread when it applies
 * LE_CMD_PERF_ARM, so the window starts at the exact callback the capture taps
 * go live on — not at whatever moment the control thread got around to it. */
static inline void le_cb_timing_reset_armed(le_cb_timing* t) {
  if (t == NULL) return;
  le_cb_window_reset(&t->armed);
}

static inline void le_cb_window_note(le_cb_window* w, uint64_t dur_ns,
                                     uint64_t gap_ns, uint64_t budget_ns,
                                     uint64_t bucket_ns, uint64_t gap_limit_ns) {
  atomic_fetch_add_explicit(&w->a_calls, 1u, memory_order_relaxed);
  atomic_fetch_add_explicit(&w->a_total_ns, dur_ns, memory_order_relaxed);
  /* Load-compare-store rather than a CAS loop: only the callback thread writes
   * this field (see the ownership note at the top), so there is no race. */
  if (dur_ns > atomic_load_explicit(&w->a_max_ns, memory_order_relaxed)) {
    atomic_store_explicit(&w->a_max_ns, dur_ns, memory_order_relaxed);
  }
  if (dur_ns > budget_ns) {
    atomic_fetch_add_explicit(&w->a_late_calls, 1u, memory_order_relaxed);
  }
  {
    uint64_t idx = dur_ns / bucket_ns;
    if (idx >= (uint64_t)LE_CB_BUCKETS) idx = (uint64_t)LE_CB_BUCKETS - 1u;
    atomic_fetch_add_explicit(&w->a_bucket[idx], 1u, memory_order_relaxed);
  }
  if (gap_ns > gap_limit_ns) {
    atomic_fetch_add_explicit(&w->a_gap_events, 1u, memory_order_relaxed);
    if (gap_ns > atomic_load_explicit(&w->a_max_gap_ns, memory_order_relaxed)) {
      atomic_store_explicit(&w->a_max_gap_ns, gap_ns, memory_order_relaxed);
    }
  }
}

/* Records one callback: [entry_ns, exit_ns) over `frames`, plus the gap back to
 * the previous entry. `armed` mirrors a_perf_armed so the armed window only
 * accumulates while a capture is live.
 *
 * THE DEADLINE COMES FROM `frames`, NOT from the device's period. They are not
 * the same number on the path this exists to measure: miniaudio's duplex loop
 * drives the callback in min(capture, playback) chunks, further split by the
 * converter and by short readi() returns, so a callback routinely handles a
 * fraction of a playback period. Judging such a callback against a full-period
 * budget would under-report late_calls, push the whole histogram left, and hold
 * every entry gap under one period so the starvation detector never fired —
 * i.e. the instrument would report "all clear" on a device that is struggling.
 * The gap threshold uses the PREVIOUS callback's budget, since that is the
 * interval the device was expected to come back within.
 *
 * Monotonic clock, so exit < entry cannot happen — the clamp is defensive
 * against a synthetic (test) pair, not against the clock. */
static inline void le_cb_timing_note(le_cb_timing* t, uint64_t entry_ns,
                                     uint64_t exit_ns, uint32_t frames,
                                     int armed) {
#if LE_CALLBACK_TELEMETRY
  if (t == NULL || t->sample_rate <= 0 || frames == 0) return;
  const uint64_t budget_ns =
      ((uint64_t)frames * 1000000000ull) / (uint64_t)t->sample_rate;
  if (budget_ns == 0) return; /* sub-nanosecond block: nothing to judge */
  uint64_t bucket_ns = budget_ns / (uint64_t)LE_CB_BUCKETS;
  if (bucket_ns == 0) bucket_ns = 1; /* no divide-by-zero on a tiny block */

  const uint64_t dur_ns = exit_ns > entry_ns ? exit_ns - entry_ns : 0u;
  uint64_t gap_ns = 0u;
  if (t->last_entry_ns != 0u && entry_ns > t->last_entry_ns) {
    gap_ns = entry_ns - t->last_entry_ns;
  }
  /* A gap that a counted backend recovery already explains is not independent
   * evidence — drop it so gap_events stays a signal in its own right (and so
   * max_gap_us is not permanently pinned by the first xrun of the session). */
  if (atomic_exchange_explicit(&t->a_gap_suppress, 0, memory_order_relaxed) !=
      0) {
    gap_ns = 0u;
  }
  const uint64_t gap_limit_ns =
      t->last_budget_ns + t->last_budget_ns / 2u; /* 1.5 of the last period */

  t->last_entry_ns = entry_ns;
  t->last_budget_ns = budget_ns;
  atomic_store_explicit(&t->a_budget_ns, budget_ns, memory_order_relaxed);

  le_cb_window_note(&t->session, dur_ns, gap_ns, budget_ns, bucket_ns,
                    gap_limit_ns);
  if (armed) {
    le_cb_window_note(&t->armed, dur_ns, gap_ns, budget_ns, bucket_ns,
                      gap_limit_ns);
  }
#else
  (void)t;
  (void)entry_ns;
  (void)exit_ns;
  (void)frames;
  (void)armed;
#endif
}

/* Records one backend dropout of `kind` (le_xrun_kind). Called from whichever
 * thread the backend noticed it on — the ALSA data-loop thread for the -EPIPE
 * recoveries, the ASIO message thread for an overload — so it is relaxed and
 * thread-agnostic (see the ownership note at the top for what that costs).
 * Unknown kinds are ignored rather than clamped: silently folding a future kind
 * into an existing bucket would corrupt the reading.
 *
 * Also arms the gap suppressor: the recovery this reports is about to show up
 * as a long entry-to-entry gap, and one physical dropout must not be counted
 * twice under two different names. */
static inline void le_cb_timing_note_xrun(le_cb_timing* t, int32_t kind,
                                          int armed) {
#if LE_CALLBACK_TELEMETRY
  if (t == NULL || kind < 0 || kind >= LE_XRUN_KINDS) return;
  atomic_fetch_add_explicit(&t->session.a_xruns[kind], 1u,
                            memory_order_relaxed);
  if (armed) {
    atomic_fetch_add_explicit(&t->armed.a_xruns[kind], 1u, memory_order_relaxed);
  }
  atomic_store_explicit(&t->a_gap_suppress, 1, memory_order_relaxed);
#else
  (void)t;
  (void)kind;
  (void)armed;
#endif
}

/* Control-thread read of one window into its ABI projection (nanoseconds folded
 * down to microseconds; see le_cb_window_snapshot). Field-wise relaxed loads,
 * like every other snapshot read — a reader may see a one-callback-stale mix,
 * which is exactly what le_engine_get_snapshot already promises. */
static inline void le_cb_window_read(const le_cb_window* w,
                                     le_cb_window_snapshot* out) {
  const uint64_t calls = atomic_load_explicit(&w->a_calls, memory_order_relaxed);
  const uint64_t total_ns =
      atomic_load_explicit(&w->a_total_ns, memory_order_relaxed);
  out->calls = calls;
  out->late_calls = atomic_load_explicit(&w->a_late_calls, memory_order_relaxed);
  out->gap_events = atomic_load_explicit(&w->a_gap_events, memory_order_relaxed);
  out->max_us =
      (uint32_t)(atomic_load_explicit(&w->a_max_ns, memory_order_relaxed) /
                 1000u);
  out->mean_us = calls > 0 ? (uint32_t)(total_ns / calls / 1000u) : 0u;
  out->max_gap_us =
      (uint32_t)(atomic_load_explicit(&w->a_max_gap_ns, memory_order_relaxed) /
                 1000u);
  for (int i = 0; i < LE_CB_BUCKETS; ++i) {
    out->buckets[i] = atomic_load_explicit(&w->a_bucket[i], memory_order_relaxed);
  }
  for (int i = 0; i < LE_XRUN_KINDS; ++i) {
    out->xruns[i] = atomic_load_explicit(&w->a_xruns[i], memory_order_relaxed);
  }
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_TELEMETRY_H */
