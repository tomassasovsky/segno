/*
 * engine_telemetry.h — the audio callback's self-measurement (#722).
 *
 * A monotonic clock read and a handful of relaxed atomic accumulators: how long
 * the engine takes to service one hardware period, how that compares to the
 * period, and how far apart the device's callbacks arrive. Published through
 * le_engine_get_callback_telemetry as le_callback_telemetry (segno_engine_api.h
 * has the "what and why", including why the unit is a PERIOD SERVICE and not a
 * callback); this header is the mechanism.
 *
 * DESIGN CONSTRAINT: on healthy hardware every judged field reads ZERO —
 * late_periods, gap_events, max_gap_us, xruns. An instrument that cries wolf on
 * a working rig is worse than no instrument, because the bench then chases what
 * it reports. The two places that could have gone wrong are both handled here:
 * the period-service accumulator (so a sub-period block is never judged against
 * a deadline that excludes the engine's fixed per-block overhead) and the
 * nominal-period gap threshold (so the normal burst-then-wait rhythm of a split
 * duplex loop is not read as starvation).
 *
 * REAL-TIME CONTRACT. le_cb_timing_note runs INSIDE the device callback and
 * obeys the same rules as engine_process.c: no allocation, no lock, no
 * unbounded loop, and no syscall beyond the two monotonic clock reads the
 * caller makes around it (clock_gettime(CLOCK_MONOTONIC) is a vDSO read on
 * Linux and a commpage read on Apple platforms — no kernel entry). Everything
 * it touches is a relaxed atomic on a struct that lives inside le_engine, so
 * there is no fence and no contention, and the reader tolerates a torn view
 * across fields exactly like every other metering atomic in this engine.
 *
 * WRITER OWNERSHIP, precisely (it is NOT uniformly single-writer):
 *   - the duration/gap fields (a_calls, a_periods, a_late_periods,
 *     a_gap_events, a_total_ns, a_max_ns, a_max_gap_ns, a_bucket[]) are written
 *     ONLY by the device callback thread. That is what licenses the
 *     load-compare-store maxima below: there is no second writer to lose a race
 *     to.
 *   - a_xruns[] is MULTI-writer. le_engine_note_backend_xrun fires from
 *     whichever thread noticed the dropout — the ALSA data-loop thread (same
 *     thread as the callback) but also the ASIO driver's message thread — while
 *     the audio thread may be running le_cb_window_reset for an arm. Both sides
 *     use atomic RMW/store, so no value ever tears; the residual imprecision is
 *     that a dropout landing within a hair of an arm boundary may be counted in
 *     the window on either side of it. A one-event ambiguity at a boundary is
 *     immaterial to an instrument whose windows are minutes long, and paying
 *     for a lock on the RT path to remove it would be absurd. The same applies
 *     to an in-flight period service straddling an arm.
 *   - a_timeline_break is a one-bit handshake in the other direction: the
 *     device-NOTIFICATION thread raises it, the callback thread consumes it.
 *     It exists precisely so that the first bullet stays true — a reroute has
 *     to invalidate last_entry_ns / svc_frames / svc_ns, and the notification
 *     thread writing those directly would make them multi-writer and cost the
 *     unsynchronised maxima their justification. Worst case on a lost race is
 *     that the break is honoured one callback later, which is one callback of
 *     stale timeline on a device that just disappeared.
 *
 * HEADER-ONLY on purpose. A new .c TU would have to be added to six build
 * descriptions (CMakeLists, the macOS podspec forwarders, the SPM forwarders,
 * the native test runner, …); static inline in a header that engine_private.h
 * already pulls in costs nothing and drifts nowhere.
 *
 * Gate: -DLE_CALLBACK_TELEMETRY=0 (engine_telemetry_gate.h) compiles the timing
 * path out to nothing, makes the callers skip their clock reads, drops the
 * dropout-hook install, and removes the hook call sites from the vendored ALSA
 * recovery branches — the audio path is then exactly the pre-#722 build. The
 * per-kind DROPOUT TALLY is deliberately NOT gated: it costs two relaxed adds
 * on a path that only runs once a dropout has already happened, it is what
 * keeps the kinds summing to xrun_count in every build, and gating it would
 * silently take the pre-#722 ASIO overload counter away too. Default ON.
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
/* engine_private.h includes this header, and engine_fx.h includes THAT, so
 * <windows.h> now lands in every C++ translation unit that touches the DSP
 * types — including vst3/test/host_harness.cpp, which calls std::min. Stock
 * <windows.h> defines min/max as macros, which turns `std::min(` into MSVC
 * C2589; NOMINMAX suppresses them. Guarded, so a TU that already set it is
 * left alone, and defined HERE rather than in the build files because this
 * header is what drags <windows.h> in — a -DNOMINMAX would have to be
 * repeated in every consumer's build description (CMake, the podspec, the SPM
 * target, the native test runner) and would drift the first time one was
 * missed. Deliberately NOT WIN32_LEAN_AND_MEAN: that would apply to the whole
 * TU, including the <windows.h> miniaudio.h pulls in a few lines further down
 * engine_private.h, and miniaudio documents it as excluding symbols it then
 * has to redefine by hand (STGM_READ, the whole WinMM surface). Nothing here
 * needs more than QueryPerformanceCounter/Frequency, but nothing here is worth
 * changing what the audio backend sees either. */
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <time.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* How late the device may be before it counts as starved, as a fraction of the
 * NOMINAL period: 3/2. Anything under this is the ordinary jitter of a duplex
 * loop that services a period in a burst of callbacks and then waits. */
#define LE_CB_GAP_NUM 3u
#define LE_CB_GAP_DEN 2u

/* How long a counted backend recovery is allowed to explain away a gap, in
 * nominal periods. A recovery stalls the loop for a moment, and that stall must
 * not be double-counted as independent starvation — but the licence has to
 * expire, or one early xrun would silently swallow a genuine stall minutes
 * later. Four periods is comfortably longer than any recover+prepare and far
 * shorter than the stalls this instrument is looking for. */
#define LE_CB_GAP_SUPPRESS_PERIODS 4u

/* Monotonic nanoseconds. Never wall-clock (CLOCK_REALTIME / the system time):
 * that clock STEPS — an NTP correction, a DST-less timezone database update or
 * a user setting the date can move it backwards or forwards by seconds, and a
 * single step would manufacture a phantom multi-period stall (or hide a real
 * one) in the gap detector.
 *
 * CLOCK_MONOTONIC is itself NTP-SLEWED — CLOCK_MONOTONIC_RAW is the unslewed
 * one — and that is fine here, deliberately: slewing only rescales the rate,
 * never steps it, and ntpd/chrony bound the slew at 500 ppm. Against the 667 us
 * period this instrument judges, 500 ppm is ~0.3 ns, six orders of magnitude
 * below the 333 us of slack between the nominal period and the 1.5-period gap
 * threshold. What matters for a deadline instrument is monotonicity and no
 * steps, not agreement with TAI. The RAW clock would also cost more (it is not
 * always a plain vDSO read) and would drift against every other timestamp in
 * the system for no measurable gain.
 *
 * The Windows arm exists for completeness (the shipping Windows build runs the
 * ASIO backend, which does not call this). */
static inline uint64_t le_now_ns(void) {
#if defined(_WIN32)
  /* QueryPerformanceFrequency is fixed at boot and, since Windows 7, is a
   * usermode read of shared data — so it is simply called every time rather
   * than cached in a function-local `static`. That cache was a lazy
   * read-check-write with no synchronisation: benign (every writer stores the
   * identical value) but a formal data race, and on a WASAPI build this sits on
   * the audio thread, where "benign race" is a phrase worth not having to
   * defend. Two shared-data reads instead of one, on a path that is not
   * compiled into the shipping Windows backend at all. */
  LARGE_INTEGER freq;
  LARGE_INTEGER now;
  QueryPerformanceFrequency(&freq);
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
  _Atomic uint64_t a_periods;
  _Atomic uint64_t a_late_periods;
  _Atomic uint64_t a_gap_events;
  _Atomic uint64_t a_total_ns; /* summed service durations; for the mean */
  _Atomic uint64_t a_max_ns;
  _Atomic uint64_t a_max_gap_ns;
  _Atomic uint64_t a_bucket[LE_CB_BUCKETS];
  _Atomic uint64_t a_xruns[LE_XRUN_KINDS];
} le_cb_window;

/* The whole telemetry state, embedded in le_engine. */
typedef struct le_cb_timing {
  /* Negotiated device parameters. Written by the CONTROL thread only while the
   * device is shut (le_engine_configure seeds zeros; le_engine_start publishes
   * the real ones), read by the audio thread — the same discipline
   * le_engine.sample_rate already follows. Either being 0 means INERT: an
   * engine that never opened a device has no deadline to miss, so the native
   * test pump cannot manufacture one. */
  int32_t sample_rate;
  uint32_t period_frames; /* the NOMINAL hardware period */
  uint64_t period_ns;     /* period_frames / sample_rate */
  uint64_t gap_limit_ns;  /* LE_CB_GAP_NUM/DEN of period_ns */
  uint64_t gap_suppress_window_ns;

  /* Audio thread only. The previous callback's entry stamp for the gap detector
   * (0 = none yet, so the first callback after a start reports no gap rather
   * than one the size of the process's uptime), and the in-flight period
   * service: frames and time accumulated since the last one committed. */
  uint64_t last_entry_ns;
  uint32_t svc_frames;
  uint64_t svc_ns;

  /* When a backend recovery was last counted (le_now_ns), or 0. Consumed by
   * the next callback's gap check, and only honoured inside
   * gap_suppress_window_ns — see LE_CB_GAP_SUPPRESS_PERIODS. Written from the
   * thread that noticed the dropout. */
  _Atomic uint64_t a_gap_suppress_ns;

  /* Non-zero = the callback stream was interrupted and the timeline above is
   * stale; the next callback must drop it instead of measuring against it.
   * Raised by le_cb_timing_note_timeline_break from the DEVICE-NOTIFICATION
   * thread, consumed by the audio thread inside le_cb_timing_note — which is
   * why it is an atomic flag rather than the notification thread reaching in
   * and clearing last_entry_ns / svc_* directly: those three are single-writer
   * audio-thread state, and that ownership is exactly what licenses the
   * unsynchronised load-compare-store maxima elsewhere in this file. A flag
   * costs one relaxed load per callback and keeps the invariant intact. */
  _Atomic int a_timeline_break;

  le_cb_window session;
  le_cb_window armed;
} le_cb_timing;

static inline void le_cb_window_reset(le_cb_window* w) {
  atomic_store_explicit(&w->a_calls, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_periods, 0u, memory_order_relaxed);
  atomic_store_explicit(&w->a_late_periods, 0u, memory_order_relaxed);
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

/* Seeds the negotiated rate + nominal period and clears BOTH windows — a fresh
 * device session is a fresh measurement, exactly like a_xruns (which
 * le_engine_configure_callback_budget clears in the same breath, so the flat
 * tally and the per-kind windows can never disagree). A non-positive rate or
 * period leaves the instrument inert. */
static inline void le_cb_timing_configure(le_cb_timing* t, int32_t sample_rate,
                                          int32_t period_frames) {
  if (t == NULL) return;
  t->last_entry_ns = 0;
  t->svc_frames = 0;
  t->svc_ns = 0;
  atomic_store_explicit(&t->a_gap_suppress_ns, 0u, memory_order_relaxed);
  atomic_store_explicit(&t->a_timeline_break, 0, memory_order_relaxed);
  le_cb_window_reset(&t->session);
  le_cb_window_reset(&t->armed);
  if (sample_rate <= 0 || period_frames <= 0) {
    t->sample_rate = 0;
    t->period_frames = 0;
    t->period_ns = 0;
    t->gap_limit_ns = 0;
    t->gap_suppress_window_ns = 0;
    return;
  }
  t->sample_rate = sample_rate;
  t->period_frames = (uint32_t)period_frames;
  t->period_ns =
      ((uint64_t)period_frames * 1000000000ull) / (uint64_t)sample_rate;
  t->gap_limit_ns = t->period_ns * LE_CB_GAP_NUM / LE_CB_GAP_DEN;
  t->gap_suppress_window_ns = t->period_ns * LE_CB_GAP_SUPPRESS_PERIODS;
}

/* Declares the callback TIMELINE broken: the next callback reports no gap and
 * starts a fresh period service. Measurements already accumulated are NOT
 * touched — a reroute does not undo the lateness observed before it.
 *
 * Called when the device notification path says the callback stream is about to
 * stop coming: stopped / rerouted / interruption_began (engine_miniaudio.c).
 * miniaudio handles a reroute or an interruption INTERNALLY — it reinitialises
 * the device and resumes the data callback without the engine restarting — so
 * without this the first callback after the switch is measured against the
 * entry stamp from before it. On macOS, changing the default output device
 * mid-session is a ~200 ms hole: exactly one phantom gap_event, and max_gap_us
 * pinned at 200000 for the rest of the device session. That is the "instrument
 * cries wolf on a healthy rig" failure this whole file is built to avoid, and
 * le_engine_start's configure was the only reset before this (#722, review
 * finding 5).
 *
 * THE COMPLETE SET of pre-stall state is the three timeline fields
 * (last_entry_ns, svc_frames, svc_ns) plus the suppressor stamp. The first
 * three are audio-thread-owned, so they are cleared by the audio thread when it
 * observes the flag; a_gap_suppress_ns is already atomic and is cleared right
 * here, because a recovery licensed before the reroute has nothing to do with
 * the stream that comes back after it. Nothing else in le_cb_timing carries
 * history across the break: the negotiated rate/period and their derived
 * thresholds are unchanged by a reroute (miniaudio re-opens with the same
 * requested config; a device that came back with a different period would need
 * a full le_engine_start, which reconfigures anyway), and the two windows are
 * the measurement itself.
 *
 * Thread-agnostic and RT-safe: two relaxed stores. */
static inline void le_cb_timing_note_timeline_break(le_cb_timing* t) {
  if (t == NULL) return;
  atomic_store_explicit(&t->a_gap_suppress_ns, 0u, memory_order_relaxed);
  atomic_store_explicit(&t->a_timeline_break, 1, memory_order_relaxed);
}

/* Clears the armed window. Called from the AUDIO thread when it applies
 * LE_CMD_PERF_ARM, so the window starts at the exact callback the capture taps
 * go live on — not at whatever moment the control thread got around to it. */
static inline void le_cb_timing_reset_armed(le_cb_timing* t) {
  if (t == NULL) return;
  le_cb_window_reset(&t->armed);
}

/* One completed period service: `dur_ns` of work covering `budget_ns` of audio.
 * budget_ns is derived from the frames actually covered, so a service that ran
 * long because it absorbed two periods' frames is judged against two periods. */
static inline void le_cb_window_note_service(le_cb_window* w, uint64_t dur_ns,
                                             uint64_t budget_ns,
                                             uint64_t bucket_ns) {
  atomic_fetch_add_explicit(&w->a_periods, 1u, memory_order_relaxed);
  atomic_fetch_add_explicit(&w->a_total_ns, dur_ns, memory_order_relaxed);
  /* Load-compare-store rather than a CAS loop: only the callback thread writes
   * this field (see the ownership note at the top), so there is no race. */
  if (dur_ns > atomic_load_explicit(&w->a_max_ns, memory_order_relaxed)) {
    atomic_store_explicit(&w->a_max_ns, dur_ns, memory_order_relaxed);
  }
  if (dur_ns > budget_ns) {
    atomic_fetch_add_explicit(&w->a_late_periods, 1u, memory_order_relaxed);
  }
  {
    uint64_t idx = dur_ns / bucket_ns;
    if (idx >= (uint64_t)LE_CB_BUCKETS) idx = (uint64_t)LE_CB_BUCKETS - 1u;
    atomic_fetch_add_explicit(&w->a_bucket[idx], 1u, memory_order_relaxed);
  }
}

static inline void le_cb_window_note_gap(le_cb_window* w, uint64_t gap_ns) {
  atomic_fetch_add_explicit(&w->a_gap_events, 1u, memory_order_relaxed);
  if (gap_ns > atomic_load_explicit(&w->a_max_gap_ns, memory_order_relaxed)) {
    atomic_store_explicit(&w->a_max_gap_ns, gap_ns, memory_order_relaxed);
  }
}

/* Records one callback: [entry_ns, exit_ns) over `frames`, plus the gap back to
 * the previous entry. `armed` mirrors a_perf_armed so the armed window only
 * accumulates while a capture is live.
 *
 * The callback is folded into the in-flight PERIOD SERVICE, which commits once
 * it covers at least a nominal period's frames — that is the deadline the
 * engine actually has to meet, and the only framing under which the fixed
 * per-block cost of le_engine_process is amortised honestly (segno_engine_api.h
 * spells out why neither per-callback deadline works).
 *
 * Monotonic clock, so exit < entry cannot happen — the clamp is defensive
 * against a synthetic (test) pair, not against the clock. */
static inline void le_cb_timing_note(le_cb_timing* t, uint64_t entry_ns,
                                     uint64_t exit_ns, uint32_t frames,
                                     int armed) {
#if LE_CALLBACK_TELEMETRY
  if (t == NULL || t->sample_rate <= 0 || t->period_frames == 0 || frames == 0) {
    return;
  }
  const uint64_t dur_ns = exit_ns > entry_ns ? exit_ns - entry_ns : 0u;

  /* A reroute / interruption / stop happened since the last callback, so the
   * timeline is stale (see le_cb_timing_note_timeline_break). Drop it HERE, on
   * the thread that owns these three fields, rather than from the notification
   * thread that raised the flag. A relaxed load per callback; the branch is
   * never taken on a rig nobody is unplugging. */
  if (atomic_load_explicit(&t->a_timeline_break, memory_order_relaxed) != 0) {
    atomic_store_explicit(&t->a_timeline_break, 0, memory_order_relaxed);
    t->last_entry_ns = 0;
    t->svc_frames = 0;
    t->svc_ns = 0;
  }

  atomic_fetch_add_explicit(&t->session.a_calls, 1u, memory_order_relaxed);
  if (armed) {
    atomic_fetch_add_explicit(&t->armed.a_calls, 1u, memory_order_relaxed);
  }

  /* ---- gap detector, against the NOMINAL period ---- */
  uint64_t gap_ns = 0u;
  if (t->last_entry_ns != 0u && entry_ns > t->last_entry_ns) {
    gap_ns = entry_ns - t->last_entry_ns;
  }
  t->last_entry_ns = entry_ns;
  if (gap_ns > t->gap_limit_ns) {
    /* A gap a counted recovery already explains is not independent evidence —
     * but only while the licence is fresh, or one early xrun would swallow a
     * genuine stall much later in the session. */
    const uint64_t suppress_ns =
        atomic_exchange_explicit(&t->a_gap_suppress_ns, 0u,
                                 memory_order_relaxed);
    const int explained = suppress_ns != 0u && entry_ns >= suppress_ns &&
                          (entry_ns - suppress_ns) <= t->gap_suppress_window_ns;
    if (!explained) {
      le_cb_window_note_gap(&t->session, gap_ns);
      if (armed) le_cb_window_note_gap(&t->armed, gap_ns);
    }
  }

  /* ---- period service ---- */
  t->svc_frames += frames;
  t->svc_ns += dur_ns;
  if (t->svc_frames >= t->period_frames) {
    const uint64_t budget_ns =
        ((uint64_t)t->svc_frames * 1000000000ull) / (uint64_t)t->sample_rate;
    uint64_t bucket_ns = budget_ns / (uint64_t)LE_CB_BUCKETS;
    if (bucket_ns == 0) bucket_ns = 1; /* no divide-by-zero on a tiny period */
    le_cb_window_note_service(&t->session, t->svc_ns, budget_ns, bucket_ns);
    if (armed) {
      le_cb_window_note_service(&t->armed, t->svc_ns, budget_ns, bucket_ns);
    }
    t->svc_frames = 0;
    t->svc_ns = 0;
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
 * NOT behind LE_CALLBACK_TELEMETRY, unlike the timing path: this runs only once
 * a dropout has already happened, so it has no steady-state cost; gating it
 * would leave xrun_count moving in a gated build with no breakdown to explain
 * it, and would silently remove the ASIO overload tally that predates #722.
 *
 * The per-kind counts therefore account for every dropout of a kind THIS BUILD
 * KNOWS, but they do not necessarily sum to xrun_count: le_engine_note_backend_
 * xrun bumps the flat tally before this range check, so an unrecognised kind
 * increments xrun_count with no bucket to land in. That is the deliberate
 * order — xrun_count's job is "a real dropout happened", and an unclassifiable
 * one still happened. No backend produces such a kind today (ALSA passes 0/1/2,
 * ASIO passes 3), so the sum holds in practice; it is a guarantee about the
 * future, not about today.
 *
 * Also stamps the gap suppressor: the recovery this reports is about to show up
 * as a long entry-to-entry gap, and one physical dropout must not be counted
 * twice under two different names. */
static inline void le_cb_timing_note_xrun(le_cb_timing* t, int32_t kind,
                                          int armed) {
  if (t == NULL || kind < 0 || kind >= LE_XRUN_KINDS) return;
  atomic_fetch_add_explicit(&t->session.a_xruns[kind], 1u,
                            memory_order_relaxed);
  if (armed) {
    atomic_fetch_add_explicit(&t->armed.a_xruns[kind], 1u, memory_order_relaxed);
  }
  atomic_store_explicit(&t->a_gap_suppress_ns, le_now_ns(),
                        memory_order_relaxed);
}

/* Control-thread read of one window into its ABI projection (nanoseconds folded
 * down to microseconds; see le_cb_window_snapshot). Field-wise relaxed loads, so
 * a reader may see a one-service-stale mix — exactly what every other published
 * atomic in this engine already promises. */
static inline void le_cb_window_read(const le_cb_window* w,
                                     le_cb_window_snapshot* out) {
  const uint64_t periods =
      atomic_load_explicit(&w->a_periods, memory_order_relaxed);
  const uint64_t total_ns =
      atomic_load_explicit(&w->a_total_ns, memory_order_relaxed);
  out->calls = atomic_load_explicit(&w->a_calls, memory_order_relaxed);
  out->periods = periods;
  out->late_periods =
      atomic_load_explicit(&w->a_late_periods, memory_order_relaxed);
  out->gap_events = atomic_load_explicit(&w->a_gap_events, memory_order_relaxed);
  out->max_us =
      (uint32_t)(atomic_load_explicit(&w->a_max_ns, memory_order_relaxed) /
                 1000u);
  out->mean_us = periods > 0 ? (uint32_t)(total_ns / periods / 1000u) : 0u;
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

/* Fills the whole ABI projection. Shared by le_engine_get_callback_telemetry
 * and the disarm summary so the two can never report different numbers. */
static inline void le_cb_timing_read(const le_cb_timing* t,
                                     le_callback_telemetry* out) {
  out->budget_us = (uint32_t)(t->period_ns / 1000u);
  le_cb_window_read(&t->session, &out->session);
  le_cb_window_read(&t->armed, &out->armed);
}

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_TELEMETRY_H */
