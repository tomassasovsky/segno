/*
 * test_engine_races.c — concurrency tests for the callback telemetry (#739).
 *
 * engine_telemetry.h documents a writer-ownership contract that is NOT
 * uniformly single-writer (see the WRITER OWNERSHIP note at its top), and the
 * rest of the native suite never exercises it: test_engine_core.c drives the
 * engine from synthetic single-threaded pumps, so a TSAN run over that suite
 * would be a green light checking nothing. This binary exists to make the
 * contract machine-checkable — it races the exact thread pairs the ownership
 * note names, through the real header functions, with pthreads standing in for
 * the device-callback / device-notification / ASIO-message / control threads:
 *
 *   1. le_cb_timing_note_timeline_break (notification thread) against a
 *      le_cb_timing_note loop (callback thread), asserting a raised break is
 *      NEVER dropped outright: every raise is consumed by a later callback in
 *      bounded time while notes hammer concurrently, and each counted consume
 *      is proven to be a real timeline reset (a no-gap call across a
 *      10-period jump) by exact accounting, not inferred. That is a
 *      functional liveness property TSAN cannot express, so this test runs in
 *      the plain suite too. (It is deliberately NOT claimed to distinguish
 *      the exchange from a load-then-store consume: the lossy interleaving
 *      needs a raise to land inside an in-flight consume, and any handshake
 *      precise enough for exact accounting serializes the two. What keeps the
 *      exchange honest is TSAN plus this file racing the real functions, so
 *      any weakening of the flag to non-atomic state becomes a reported
 *      race.)
 *   2. le_cb_timing_note_xrun (the ASIO message thread's role) against
 *      le_cb_timing_reset_armed (the audio thread's arm path) — the documented
 *      multi-writer case for a_xruns[].
 *   3. a control-thread le_cb_timing_read against a running callback loop —
 *      the torn-but-sane view every published atomic in this engine promises.
 *
 * CI runs this binary twice: inside the plain native-tests job (functional
 * properties) and as the ONLY binary of the native-tests-tsan job
 * (`NATIVE_TESTS_ONLY=races EXTRA_CFLAGS="-fsanitize=thread -g"`), where TSAN
 * checks that every cross-thread access really is the relaxed atomic the
 * header claims. Deliberately a DEDICATED binary rather than the whole suite
 * under TSAN: the suite is mostly single-threaded, so sanitizing it buys
 * minutes and checks nothing this file does not.
 *
 * Every test is bounded by fixed iteration counts (plus a per-round timeout in
 * test 1 so a regression fails instead of hanging); the whole binary runs in a
 * few hundred ms unsanitized.
 *
 * The telemetry is header-only, so this compiles from engine_telemetry.h alone
 * — no engine TU list to keep in sync with CMakeLists.txt.
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

#include "engine_telemetry.h"
#include "segno_engine_api.h"

static int g_failures = 0;

#define CHECK(cond)                                      \
  do {                                                   \
    if (!(cond)) {                                       \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                      \
    }                                                    \
  } while (0)

/* Same convention as test_engine_core.c: an assertion that can only hold when
 * LE_CALLBACK_TELEMETRY is on (the gate compiles the accumulating path of
 * le_cb_timing_note out to nothing). Evaluated and discarded when gated off so
 * locals stay "used". The ungated paths — the break RAISE, the dropout tally,
 * configure, read — stay under plain CHECK in both builds. */
#if LE_CALLBACK_TELEMETRY
#define CHECK_TIMING(cond) CHECK(cond)
#else
#define CHECK_TIMING(cond) ((void)(cond))
#endif

/* 48 kHz, 480-frame period: period_ns = 10 ms, gap_limit = 15 ms. Timestamps
 * below are synthetic (the telemetry only ever compares them to each other),
 * so the tests are deterministic in what they FEED, and concurrent only in
 * WHEN. */
enum { RACE_SAMPLE_RATE = 48000, RACE_PERIOD_FRAMES = 480 };

/* ------------------------------------------------------------------------ */
/* 1. timeline break raised against the callback loop: never lost.          */
/* ------------------------------------------------------------------------ */

typedef struct {
  le_cb_timing* t;
  _Atomic int primed; /* the priming note call landed; raises may begin */
  _Atomic int stop;
  /* Callback-thread calls that observed (consumed) a break, detected via the
   * gap detector: every iteration jumps entry by 10 periods, so a call that
   * records NO gap can only have had last_entry_ns reset by a consumed break.
   * Exclusive per call: a consumed break zeroes gap_ns, an unconsumed jump
   * records exactly one gap, so calls == gaps + consumed at the end (the
   * priming call is outside the counted loop). */
  _Atomic uint64_t consumed;
  _Atomic uint64_t calls;
#if !LE_CALLBACK_TELEMETRY
  _Atomic uint64_t gated_iters; /* fixed-count loop in the gate-off build */
#endif
} break_race_shared;

static void* break_race_callback_thread(void* arg) {
  break_race_shared* s = (break_race_shared*)arg;
  le_cb_timing* t = s->t;
  const uint64_t jump = t->period_ns * 10u; /* always > gap_limit_ns */
  const uint64_t dur = t->period_ns / 4u;
  uint64_t entry = 1000000u;
  uint64_t prev_gaps = 0u;
  /* Prime last_entry_ns BEFORE the raiser is released: the very first note
   * call reports no gap by design (last_entry_ns == 0), so a break consumed
   * by it would be indistinguishable from "first call". Priming first, and
   * only then letting the raiser start, means every no-gap call in the loop
   * below is a consumed break and nothing else. */
  le_cb_timing_note(t, entry, entry + dur, t->period_frames, 0);
  entry += jump;
  atomic_store_explicit(&s->primed, 1, memory_order_release);
  while (!atomic_load_explicit(&s->stop, memory_order_acquire)) {
    le_cb_timing_note(t, entry, entry + dur, t->period_frames, 0);
    atomic_fetch_add_explicit(&s->calls, 1u, memory_order_relaxed);
    const uint64_t gaps =
        atomic_load_explicit(&t->session.a_gap_events, memory_order_relaxed);
    if (gaps == prev_gaps) {
      atomic_fetch_add_explicit(&s->consumed, 1u, memory_order_relaxed);
    }
    prev_gaps = gaps;
    entry += jump;
#if !LE_CALLBACK_TELEMETRY
    /* le_cb_timing_note is compiled out, so no break is ever consumed and the
     * handshake below cannot run; loop a fixed count instead so the gate-off
     * build still races the raise against the (empty) note path. */
    if (atomic_fetch_add_explicit(&s->gated_iters, 1u, memory_order_relaxed) >
        200000u) {
      break;
    }
#endif
  }
  return NULL;
}

static void test_race_timeline_break_never_lost(void) {
  printf("test_race_timeline_break_never_lost\n");
  static le_cb_timing t;
  le_cb_timing_configure(&t, RACE_SAMPLE_RATE, RACE_PERIOD_FRAMES);

  /* Deterministic warm-up of the property the race then hammers: a break
   * makes the next 10-period jump report no gap; without one it reports one.
   * (Single-threaded, so this holds for exchange AND load-then-store alike —
   * the concurrent handshake below is what tells them apart.) */
  const uint64_t jump = t.period_ns * 10u;
  const uint64_t dur = t.period_ns / 4u;
  le_cb_timing_note(&t, 1u * jump, 1u * jump + dur, t.period_frames, 0);
  le_cb_timing_note_timeline_break(&t);
  le_cb_timing_note_timeline_break(&t); /* macOS: began + rerouted, coalesced */
  le_cb_timing_note(&t, 2u * jump, 2u * jump + dur, t.period_frames, 0);
  CHECK_TIMING(atomic_load_explicit(&t.session.a_gap_events,
                                    memory_order_relaxed) == 0u);
  le_cb_timing_note(&t, 3u * jump, 3u * jump + dur, t.period_frames, 0);
  CHECK_TIMING(atomic_load_explicit(&t.session.a_gap_events,
                                    memory_order_relaxed) == 1u);

  le_cb_timing_configure(&t, RACE_SAMPLE_RATE, RACE_PERIOD_FRAMES);
  break_race_shared s;
  s.t = &t;
  atomic_init(&s.primed, 0);
  atomic_init(&s.stop, 0);
  atomic_init(&s.consumed, 0u);
  atomic_init(&s.calls, 0u);
#if !LE_CALLBACK_TELEMETRY
  atomic_init(&s.gated_iters, 0u);
#endif
  pthread_t cb;
  CHECK(pthread_create(&cb, NULL, break_race_callback_thread, &s) == 0);
  while (!atomic_load_explicit(&s.primed, memory_order_acquire)) { /* spin */
  }

#if LE_CALLBACK_TELEMETRY
  /* This thread is the device-notification thread. Per round: raise a break,
   * then require that SOME later callback consumes one — a raise may coalesce
   * with a still-standing flag (by design), but after our raise the flag is
   * certainly up, so a consume must follow. A consume side that drops raises
   * (a stale cached read, a consume that only fires once, a cleared flag with
   * no reset behind it) parks `consumed` and the bounded wait fails the test
   * instead of hanging it. */
  enum { BREAK_ROUNDS = 20000 };
  const uint64_t round_timeout_ns = 2000000000ull; /* 2 s: generous, bounded */
  int timed_out = 0;
  for (int i = 0; i < BREAK_ROUNDS && !timed_out; ++i) {
    const uint64_t before =
        atomic_load_explicit(&s.consumed, memory_order_relaxed);
    le_cb_timing_note_timeline_break(&t);
    const uint64_t t0 = le_now_ns();
    while (atomic_load_explicit(&s.consumed, memory_order_relaxed) == before) {
      if (le_now_ns() - t0 > round_timeout_ns) {
        timed_out = 1;
        break;
      }
    }
  }
  CHECK(!timed_out); /* a raised break was lost (or the callback loop died) */
  atomic_store_explicit(&s.stop, 1, memory_order_release);
  CHECK(pthread_join(cb, NULL) == 0);

  const uint64_t calls = atomic_load_explicit(&s.calls, memory_order_relaxed);
  const uint64_t consumed =
      atomic_load_explicit(&s.consumed, memory_order_relaxed);
  const uint64_t gaps =
      atomic_load_explicit(&t.session.a_gap_events, memory_order_relaxed);
  /* Every counted call either consumed a break or recorded exactly one gap;
   * and a consume needs a raise, so consumed can never exceed the rounds. */
  CHECK(calls == gaps + consumed);
  CHECK(consumed <= (uint64_t)BREAK_ROUNDS);
  CHECK(consumed > 0u);
#else
  /* Gate-off: the raise still compiles (it is not behind the gate) but the
   * consume side is gone. Race them anyway for a sanitized gate-off build,
   * then pin the gate's contract: nothing accumulated, and the LAST raise is
   * left standing because nothing can consume it. */
  for (int i = 0; i < 20000; ++i) {
    le_cb_timing_note_timeline_break(&t);
  }
  atomic_store_explicit(&s.stop, 1, memory_order_release);
  CHECK(pthread_join(cb, NULL) == 0);
  CHECK(atomic_load_explicit(&t.a_timeline_break, memory_order_relaxed) == 1);
  CHECK(atomic_load_explicit(&t.session.a_calls, memory_order_relaxed) == 0u);
  CHECK(atomic_load_explicit(&t.session.a_gap_events, memory_order_relaxed) ==
        0u);
#endif
}

/* ------------------------------------------------------------------------ */
/* 2. xrun tally (ASIO message thread) against the arm-path window reset.   */
/* ------------------------------------------------------------------------ */

typedef struct {
  le_cb_timing* t;
  _Atomic int go;
  _Atomic int done;
} xrun_race_shared;

enum { XRUN_ITERS_PER_KIND = 50000 };

static void* xrun_writer_thread(void* arg) {
  xrun_race_shared* s = (xrun_race_shared*)arg;
  while (!atomic_load_explicit(&s->go, memory_order_acquire)) { /* spin */
  }
  for (int i = 0; i < XRUN_ITERS_PER_KIND * LE_XRUN_KINDS; ++i) {
    le_cb_timing_note_xrun(s->t, (int32_t)(i % LE_XRUN_KINDS), 1);
  }
  atomic_store_explicit(&s->done, 1, memory_order_release);
  return NULL;
}

static void test_race_xrun_vs_armed_reset(void) {
  printf("test_race_xrun_vs_armed_reset\n");
  static le_cb_timing t;
  le_cb_timing_configure(&t, RACE_SAMPLE_RATE, RACE_PERIOD_FRAMES);

  xrun_race_shared s;
  s.t = &t;
  atomic_init(&s.go, 0);
  atomic_init(&s.done, 0);
  pthread_t writer;
  CHECK(pthread_create(&writer, NULL, xrun_writer_thread, &s) == 0);
  atomic_store_explicit(&s.go, 1, memory_order_release);

  /* This thread is the audio thread applying LE_CMD_PERF_ARM over and over:
   * the documented concurrent writer to armed.a_xruns[]. Bounded by the
   * writer's fixed iteration count. */
  while (!atomic_load_explicit(&s.done, memory_order_acquire)) {
    le_cb_timing_reset_armed(&t);
  }
  CHECK(pthread_join(writer, NULL) == 0);

  /* The dropout tally is deliberately ungated, so these hold in every build.
   * The session window is never reset here, and atomic RMW cannot tear or
   * drop increments no matter how the resets interleave — that exactness is
   * the property the ownership note buys with atomics instead of a lock. */
  for (int k = 0; k < LE_XRUN_KINDS; ++k) {
    CHECK(atomic_load_explicit(&t.session.a_xruns[k], memory_order_relaxed) ==
          (uint64_t)XRUN_ITERS_PER_KIND);
    /* The armed window was concurrently cleared, so only <= is promised — the
     * residual boundary ambiguity the header documents as immaterial. */
    CHECK(atomic_load_explicit(&t.armed.a_xruns[k], memory_order_relaxed) <=
          (uint64_t)XRUN_ITERS_PER_KIND);
  }
}

/* ------------------------------------------------------------------------ */
/* 3. control-thread read against a running callback loop.                  */
/* ------------------------------------------------------------------------ */

typedef struct {
  le_cb_timing* t;
  _Atomic int go;
  _Atomic int done;
  uint64_t xruns_noted; /* written before done, read after join */
} read_race_shared;

enum { READ_RACE_CALLS = 100000, READ_RACE_XRUN_EVERY = 4096 };

static void* read_race_callback_thread(void* arg) {
  read_race_shared* s = (read_race_shared*)arg;
  le_cb_timing* t = s->t;
  const uint64_t dur = t->period_ns / 2u; /* half the budget: never late */
  uint64_t entry = 1000000u;
  uint64_t xruns = 0u;
  while (!atomic_load_explicit(&s->go, memory_order_acquire)) { /* spin */
  }
  for (int i = 0; i < READ_RACE_CALLS; ++i) {
    /* Entry advances by exactly one nominal period: a healthy rig, so every
     * judged field must read zero no matter when the reader looks. */
    le_cb_timing_note(t, entry, entry + dur, t->period_frames, 1);
    entry += t->period_ns;
    if ((i % READ_RACE_XRUN_EVERY) == 0) {
      le_cb_timing_note_xrun(t, 0, 1);
      xruns++;
    }
  }
  s->xruns_noted = xruns;
  atomic_store_explicit(&s->done, 1, memory_order_release);
  return NULL;
}

static void test_race_read_vs_callback_loop(void) {
  printf("test_race_read_vs_callback_loop\n");
  static le_cb_timing t;
  le_cb_timing_configure(&t, RACE_SAMPLE_RATE, RACE_PERIOD_FRAMES);

  read_race_shared s;
  s.t = &t;
  atomic_init(&s.go, 0);
  atomic_init(&s.done, 0);
  s.xruns_noted = 0u;
  pthread_t cb;
  CHECK(pthread_create(&cb, NULL, read_race_callback_thread, &s) == 0);
  atomic_store_explicit(&s.go, 1, memory_order_release);

  /* This thread is the control thread polling the ABI snapshot mid-flight.
   * The promise is a torn-but-sane view: counters may be a service stale but
   * can never go backwards, tear, or show a judged failure on a healthy rig.
   * Violations are counted (not CHECKed) in the loop so a systematic failure
   * prints once, not ten thousand times. */
  uint64_t reads = 0u;
  uint64_t violations = 0u;
  uint64_t prev_calls = 0u;
  uint64_t prev_periods = 0u;
  le_callback_telemetry snap;
  do {
    le_cb_timing_read(&t, &snap);
    reads++;
    if (snap.budget_us != (uint32_t)(t.period_ns / 1000u)) violations++;
    if (snap.session.calls < prev_calls) violations++;          /* monotonic */
    if (snap.session.periods < prev_periods) violations++;      /* monotonic */
    if (snap.session.periods > snap.session.calls) violations++; /* read order */
    if (snap.session.late_periods != 0u) violations++; /* healthy rig: zero */
    if (snap.session.gap_events != 0u) violations++;   /* healthy rig: zero */
    if (snap.session.max_us > t.period_ns / 2u / 1000u) violations++;
    prev_calls = snap.session.calls;
    prev_periods = snap.session.periods;
  } while (!atomic_load_explicit(&s.done, memory_order_acquire));
  CHECK(pthread_join(cb, NULL) == 0);
  CHECK(violations == 0u);
  CHECK(reads > 0u);

  /* Final totals, read through the same ABI projection the FFI surface uses.
   * frames == period_frames, so every call commits exactly one period whose
   * service time is dur — which also pins the whole histogram into one known
   * bucket (dur / (budget/8) = 4). */
  le_cb_timing_read(&t, &snap);
  CHECK_TIMING(snap.session.calls == (uint64_t)READ_RACE_CALLS);
  CHECK_TIMING(snap.session.periods == (uint64_t)READ_RACE_CALLS);
  CHECK_TIMING(snap.armed.calls == (uint64_t)READ_RACE_CALLS);
  CHECK_TIMING(snap.session.mean_us == (uint32_t)(t.period_ns / 2u / 1000u));
  CHECK_TIMING(snap.session.max_us == (uint32_t)(t.period_ns / 2u / 1000u));
  CHECK_TIMING(snap.session.buckets[4] == (uint64_t)READ_RACE_CALLS);
  CHECK(snap.session.late_periods == 0u);
  CHECK(snap.session.gap_events == 0u);
  CHECK(snap.session.xruns[0] == s.xruns_noted); /* ungated: exact everywhere */
}

int main(void) {
  test_race_timeline_break_never_lost();
  test_race_xrun_vs_armed_reset();
  test_race_read_vs_callback_loop();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
