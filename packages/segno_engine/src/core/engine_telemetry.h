/*
 * engine_telemetry.h — the audio callback's self-measurement (#722).
 *
 * A monotonic clock read and a handful of relaxed atomic accumulators: how long
 * each device callback took, how that compares to the period deadline, and how
 * far apart consecutive callbacks arrived. Published on the snapshot as
 * le_cb_window_snapshot (segno_engine_api.h has the "what and why"); this header
 * is the mechanism.
 *
 * REAL-TIME CONTRACT. le_cb_timing_note runs INSIDE the device callback and
 * obeys the same rules as engine_process.c: no allocation, no lock, no
 * unbounded loop, and no syscall beyond the two monotonic clock reads the
 * caller makes around it (clock_gettime(CLOCK_MONOTONIC) is a vDSO read on
 * Linux and a commpage read on Apple platforms — no kernel entry). Everything
 * it touches is a relaxed atomic on a struct that lives inside le_engine, so
 * there is no fence and no contention: the audio thread is the only writer, and
 * the snapshot reader tolerates a torn view across fields exactly like every
 * other metering atomic in this engine.
 *
 * HEADER-ONLY on purpose. A new .c TU would have to be added to six build
 * descriptions (CMakeLists, the macOS podspec forwarders, the SPM forwarders,
 * the native test runner, …); static inline in a header that engine_private.h
 * already pulls in costs nothing and drifts nowhere.
 *
 * Gate: -DLE_CALLBACK_TELEMETRY=0 compiles every accumulate out to nothing and
 * makes the callers skip their clock reads, leaving the RT path bit-identical
 * to the pre-#722 build. Default ON — the whole point is that the appliance
 * ships with it.
 *
 * Purely internal: NOT part of the FFI surface (only the le_cb_window_snapshot
 * it fills is) and not seen by ffigen.
 */
#ifndef SEGNO_ENGINE_TELEMETRY_H
#define SEGNO_ENGINE_TELEMETRY_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "segno_engine_api.h" /* LE_CB_BUCKETS, LE_XRUN_KINDS, le_cb_window_snapshot */

#ifndef LE_CALLBACK_TELEMETRY
#define LE_CALLBACK_TELEMETRY 1
#endif

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

/* One accumulation window. Single writer (the device callback thread), many
 * relaxed readers; see the RT note at the top for why relaxed is right. */
typedef struct le_cb_window {
  _Atomic uint64_t a_calls;
  _Atomic uint64_t a_late_calls;
  _Atomic uint64_t a_gap_events;
  _Atomic uint64_t a_total_ns; /* only ever read to derive a mean */
  _Atomic uint64_t a_max_ns;
  _Atomic uint64_t a_max_gap_ns;
  _Atomic uint32_t a_bucket[LE_CB_BUCKETS];
  _Atomic uint32_t a_xruns[LE_XRUN_KINDS];
} le_cb_window;

/* The whole telemetry state, embedded in le_engine. */
typedef struct le_cb_timing {
  /* Deadline math. Written by the CONTROL thread only while the device is shut
   * (le_engine_configure / le_engine_start), read by the audio thread; that is
   * the same discipline le_engine.sample_rate and friends already follow. */
  uint64_t budget_ns;    /* one period: frames / sample_rate. 0 = inert */
  uint64_t bucket_ns;    /* budget_ns / LE_CB_BUCKETS */
  uint64_t gap_limit_ns; /* 1.5 periods — beyond this the device starved */
  /* Audio thread only: the previous callback's entry stamp, for the gap
   * detector. 0 = no previous callback (the first one after a start reports no
   * gap rather than a gap the size of the process's uptime). */
  uint64_t last_entry_ns;
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

/* Seeds the deadline from the negotiated device period and clears BOTH windows
 * — a fresh device session is a fresh measurement, exactly like a_xruns. A
 * non-positive period or rate leaves budget_ns at 0, which makes every note
 * below a no-op: an engine that never opened a device has no deadline to miss,
 * and the native test pump must not manufacture one. */
static inline void le_cb_timing_configure(le_cb_timing* t, int32_t period_frames,
                                          int32_t sample_rate) {
  if (t == NULL) return;
  t->last_entry_ns = 0;
  le_cb_window_reset(&t->session);
  le_cb_window_reset(&t->armed);
  if (period_frames <= 0 || sample_rate <= 0) {
    t->budget_ns = 0;
    t->bucket_ns = 0;
    t->gap_limit_ns = 0;
    return;
  }
  t->budget_ns = ((uint64_t)period_frames * 1000000000ull) /
                 (uint64_t)sample_rate;
  t->bucket_ns = t->budget_ns / LE_CB_BUCKETS;
  if (t->bucket_ns == 0) t->bucket_ns = 1; /* absurdly small period; no divide-by-0 */
  t->gap_limit_ns = t->budget_ns + t->budget_ns / 2; /* 1.5 periods */
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
  /* Load-compare-store rather than a CAS loop: the audio thread is the only
   * writer of this field, so there is nothing to lose a race to. */
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

/* Records one callback: [entry_ns, exit_ns) plus the gap back to the previous
 * entry. `armed` mirrors a_perf_armed so the armed window only accumulates
 * while a capture is live. Monotonic clock, so exit < entry cannot happen — the
 * clamp is defensive against a synthetic (test) pair, not against the clock. */
static inline void le_cb_timing_note(le_cb_timing* t, uint64_t entry_ns,
                                     uint64_t exit_ns, int armed) {
#if LE_CALLBACK_TELEMETRY
  if (t == NULL || t->budget_ns == 0) return;
  const uint64_t dur_ns = exit_ns > entry_ns ? exit_ns - entry_ns : 0u;
  uint64_t gap_ns = 0u;
  if (t->last_entry_ns != 0u && entry_ns > t->last_entry_ns) {
    gap_ns = entry_ns - t->last_entry_ns;
  }
  t->last_entry_ns = entry_ns;
  le_cb_window_note(&t->session, dur_ns, gap_ns, t->budget_ns, t->bucket_ns,
                    t->gap_limit_ns);
  if (armed) {
    le_cb_window_note(&t->armed, dur_ns, gap_ns, t->budget_ns, t->bucket_ns,
                      t->gap_limit_ns);
  }
#else
  (void)t;
  (void)entry_ns;
  (void)exit_ns;
  (void)armed;
#endif
}

/* Records one backend dropout of `kind` (le_xrun_kind). Called from whichever
 * thread the backend noticed it on — the ALSA data-loop thread for the -EPIPE
 * recoveries, the ASIO message thread for an overload — so it is relaxed and
 * thread-agnostic. Unknown kinds are ignored rather than clamped: silently
 * folding a future kind into an existing bucket would corrupt the reading. */
static inline void le_cb_timing_note_xrun(le_cb_timing* t, int32_t kind,
                                          int armed) {
#if LE_CALLBACK_TELEMETRY
  if (t == NULL || kind < 0 || kind >= LE_XRUN_KINDS) return;
  atomic_fetch_add_explicit(&t->session.a_xruns[kind], 1u,
                            memory_order_relaxed);
  if (armed) {
    atomic_fetch_add_explicit(&t->armed.a_xruns[kind], 1u, memory_order_relaxed);
  }
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

/* Every dropout kind in `w`, summed — what le_snapshot.xrun_count reports. */
static inline uint32_t le_cb_window_xrun_total(const le_cb_window* w) {
  uint32_t total = 0;
  for (int i = 0; i < LE_XRUN_KINDS; ++i) {
    total += atomic_load_explicit(&w->a_xruns[i], memory_order_relaxed);
  }
  return total;
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_TELEMETRY_H */
