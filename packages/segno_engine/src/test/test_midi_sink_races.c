/*
 * test_midi_sink_races.c - concurrency tests for the native MIDI input sink
 * (#1228 Part 1; le_midi_port.h), the quiescence protocol of the instruments
 * plan review H2.
 *
 * Threads stand in for the real ones: a producer for a capture's OS MIDI
 * thread (le_midi_sink_push and le_midi_sink_mark_lost, the two bracketed
 * writers, on a struct that begins with a le_midi_sink, the
 * layout midi.c pins for struct le_midi), an audio thread running
 * le_engine_process, and the main thread as the control thread attaching,
 * moving, detaching and destroying.
 *
 *   1. Producer and audio thread run while the control thread attaches the
 *      capture to rotating ports, re-attaches it in place and detaches it,
 *      100 000 times. Exact accounting: every push that reported success is
 *      drained by the audio thread as current or stale (none lost, none
 *      double-counted), and nothing remains in any ring.
 *   2. A producer pushes while the control thread creates an engine, attaches
 *      the capture and destroys the engine, 2 000 times: destroy must wait
 *      for any push in flight, so no push ever writes a freed engine.
 *
 * Both run in the plain suite (the accounting is a functional property) and
 * in the native-tests-tsan job (NATIVE_TESTS_ONLY=races
 * EXTRA_CFLAGS="-fsanitize=thread -g"), where TSAN checks that every
 * cross-thread access is the atomic the header claims. The ASAN job runs the
 * destroy race against freed memory.
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "engine_private.h" /* le_engine (the ports, for the final check) */
#include "le_midi_port.h"
#include "segno_engine_api.h"

static int g_failures = 0;

#define CHECK(cond)                                      \
  do {                                                   \
    if (!(cond)) {                                       \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                      \
    }                                                    \
  } while (0)

typedef struct fake_capture {
  le_midi_sink sink; /* first, like struct le_midi */
} fake_capture;

typedef struct race_ctx {
  fake_capture capture;
  le_engine* engine;
  _Atomic int stop;
  _Atomic uint64_t pushed; /* successful pushes */
} race_ctx;

static void* producer_main(void* arg) {
  race_ctx* c = (race_ctx*)arg;
  uint64_t t = 0;
  while (!atomic_load_explicit(&c->stop, memory_order_acquire)) {
    if (le_midi_sink_push(&c->capture.sink, 0xF8, 0, 0, ++t)) {
      atomic_fetch_add_explicit(&c->pushed, 1u, memory_order_relaxed);
    }
    /* The other bracketed writer: every write a MIDI thread makes into
     * engine memory (the lost mark here; the clock relay and Thru rings
     * later) sits inside the same enter/leave bracket as the push. */
    if ((t & 63u) == 0u) le_midi_sink_mark_lost(&c->capture.sink);
  }
  return NULL;
}

/* Spins until the producer has completed another successful push, so each
 * phase races a producer that is really writing. Bounded. */
static void wait_for_push(race_ctx* c) {
  const uint64_t before = atomic_load(&c->pushed);
  for (long spin = 0; spin < 50000000L && atomic_load(&c->pushed) == before;
       ++spin) {
  }
}

static void* audio_main(void* arg) {
  race_ctx* c = (race_ctx*)arg;
  float in[32] = {0}, out[32];
  while (!atomic_load_explicit(&c->stop, memory_order_acquire)) {
    le_engine_process(c->engine, out, in, 32);
  }
  return NULL;
}

static void test_attach_detach_against_producer_and_audio(void) {
  printf("test_attach_detach_against_producer_and_audio\n");
  static race_ctx c;
  memset(&c, 0, sizeof(c));
  c.engine = le_engine_create();
  CHECK(c.engine != NULL);
  le_engine_configure(c.engine, 48000, 1, 1, 1000);
  pthread_t producer, audio;
  pthread_create(&producer, NULL, producer_main, &c);
  pthread_create(&audio, NULL, audio_main, &c);
  le_midi* m = (le_midi*)(void*)&c.capture;
  /* Each round of four: attach to a port, re-attach in place (a new
   * generation), move to another port, detach that port. */
  for (int i = 0; i < 100000; ++i) {
    const int port = (i / 4) % LE_MAX_MIDI_PORTS;
    const int other = (port + 3) % LE_MAX_MIDI_PORTS;
    switch (i % 4) {
      case 0:
      case 1: le_engine_attach_midi_input(c.engine, m, port); break;
      case 2: le_engine_attach_midi_input(c.engine, m, other); break;
      default: le_engine_detach_midi_input(c.engine, other); break;
    }
    if (i % 1000 < 3) wait_for_push(&c);
  }
  atomic_store_explicit(&c.stop, 1, memory_order_release);
  pthread_join(producer, NULL);
  pthread_join(audio, NULL);
  /* One more block on this thread drains what the audio thread left. */
  float in[32] = {0}, out[32];
  le_engine_process(c.engine, out, in, 32);
  le_snapshot s;
  memset(&s, 0, sizeof(s));
  le_engine_get_snapshot(c.engine, &s);
  const uint64_t pushed = atomic_load(&c.pushed);
  CHECK(pushed > 0);
  CHECK((uint64_t)s.midi_in_events + (uint64_t)s.midi_in_stale == pushed);
  for (int p = 0; p < LE_MAX_MIDI_PORTS; ++p) {
    CHECK(atomic_load(&c.engine->midi_ports[p].tail) ==
          atomic_load(&c.engine->midi_ports[p].head));
  }
  printf("  pushed %llu, current %u, stale %u, overflow blocks %u\n",
         (unsigned long long)pushed, s.midi_in_events, s.midi_in_stale,
         s.midi_in_overflows);
  le_engine_destroy(c.engine);
}

static void test_destroy_against_producer(void) {
  printf("test_destroy_against_producer\n");
  static race_ctx c;
  memset(&c, 0, sizeof(c));
  pthread_t producer;
  pthread_create(&producer, NULL, producer_main, &c);
  le_midi* m = (le_midi*)(void*)&c.capture;
  for (int i = 0; i < 2000; ++i) {
    le_engine* e = le_engine_create();
    CHECK(e != NULL);
    le_engine_attach_midi_input(e, m, i % LE_MAX_MIDI_PORTS);
    /* Destroy only once the producer is demonstrably writing this engine. */
    wait_for_push(&c);
    le_engine_destroy(e);
    CHECK(atomic_load_explicit(&c.capture.sink.port, memory_order_acquire) ==
          NULL);
  }
  atomic_store_explicit(&c.stop, 1, memory_order_release);
  pthread_join(producer, NULL);
  CHECK(atomic_load(&c.pushed) > 0);
}

int main(void) {
  test_attach_detach_against_producer_and_audio();
  test_destroy_against_producer();
  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
