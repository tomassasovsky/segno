/* Instrument note rings across two threads (#1197 Part 2a, PR #1234 review
 * M1): a control thread posts note-on/note-off pairs while an audio thread
 * drains in a hot loop. Each pair is posted the moment the note-on ring is
 * empty, so the drain often peeks the note ring just before the pair lands
 * and the release ring just after: without the published high-water mark it
 * applies the note-off before its own note-on, and the voice stays held
 * forever. Every origin gets its release, so any voice still HELD at the end
 * is a stuck note.
 *
 * The second scenario (#1197 Part 2c) runs MIDI routing for real: a MIDI
 * thread pushes Note On/Note Off pairs into a capture's sink, the audio
 * thread runs le_engine_process, and the control thread republishes the
 * route tables (moving the range and the channel, adding and removing a
 * remap) and, in the second half, re-attaches the capture. Every Note On is followed by its Note
 * Off or by a loss, so no MIDI voice may stay held, and TSAN checks the
 * route-table handover.
 *
 * Built by run_native_tests.sh in every configuration, including the
 * ThreadSanitizer job (fewer iterations there). */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_instruments.h"
#include "engine_private.h"
#include "le_midi_port.h"
#include "segno_engine_api.h"
#include "synth_voice.h"

#if defined(__SANITIZE_THREAD__)
#define RACE_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define RACE_TSAN 1
#endif
#endif
#ifdef RACE_TSAN
#define RACE_PAIRS 20000
#define ROUTE_PUBLISHES 2000
#else
#define RACE_PAIRS 300000
#define ROUTE_PUBLISHES 40000
#endif

static le_engine* g_engine;
static atomic_int g_done;

static int note_ring_empty(le_engine* e) {
  return atomic_load_explicit(&e->inst_ring.head, memory_order_acquire) ==
         atomic_load_explicit(&e->inst_ring.tail, memory_order_acquire);
}

static void* producer(void* arg) {
  (void)arg;
  for (uint32_t o = 1; o <= RACE_PAIRS; ++o) {
    while (!note_ring_empty(g_engine)) {
    }
    while (le_engine_instrument_note_on(g_engine, 0, o, 60, 100) != LE_OK) {
    }
    while (le_engine_instrument_note_off(g_engine, o) != LE_OK) {
    }
  }
  atomic_store(&g_done, 1);
  return NULL;
}

static void* consumer(void* arg) {
  (void)arg;
  while (!atomic_load(&g_done)) le_instruments_block(g_engine, 0);
  return NULL;
}

static int rings_scenario(void) {
  g_engine = le_engine_create();
  if (g_engine == NULL ||
      le_engine_configure(g_engine, 48000, 2, 2, 48000) != LE_OK ||
      le_engine_set_instrument(g_engine, 0, le_synth_patch_find("pad"), NULL) != LE_OK) {
    printf("FAIL: setup\n");
    return 1;
  }
  le_instruments_block(g_engine, 0); /* apply the patch */
  le_synth* s = (le_synth*)g_engine->synth;
  le_synth_set_voice_limit(s, LE_SYNTH_MAX_VOICES);
  pthread_t p, c;
  pthread_create(&c, NULL, consumer, NULL);
  pthread_create(&p, NULL, producer, NULL);
  pthread_join(p, NULL);
  pthread_join(c, NULL);
  for (int k = 0; k < 8; ++k) le_instruments_block(g_engine, 0); /* drain */
  int held = 0;
  for (int i = 0; i < s->voice_count; ++i) held += s->voices[i].state == 1;
  printf("instrument rings: %d pairs, %d stuck notes\n", RACE_PAIRS, held);
  le_engine_destroy(g_engine);
  if (held != 0) {
    printf("FAIL: a note-off was applied before its own note-on\n");
    return 1;
  }
  return 0;
}

/* ---- MIDI routing against route publishes and re-attaches ---- */

typedef struct route_capture {
  le_midi_sink sink; /* first, like struct le_midi */
} route_capture;

static route_capture g_capture;
static atomic_int g_stop;
static atomic_ullong g_pairs;

static void* midi_main(void* arg) {
  (void)arg;
  uint64_t t = 0;
  uint8_t note = 0;
  while (!atomic_load(&g_stop)) {
    note = (uint8_t)((note + 7u) & 0x7Fu);
    const uint8_t ch = (uint8_t)(note & 1u);
    if (!le_midi_sink_push(&g_capture.sink, (uint8_t)(0x90u | ch), note, 100, ++t)) {
      continue;
    }
    /* Its Note Off: pushed, or lost to a full ring (a loss the drain
     * answers by releasing the port's notes), or the capture moved. */
    for (int tries = 0; tries < 1000; ++tries) {
      if (le_midi_sink_push(&g_capture.sink, (uint8_t)(0x80u | ch), note, 0, ++t)) {
        break;
      }
    }
    atomic_fetch_add_explicit(&g_pairs, 1u, memory_order_relaxed);
  }
  return NULL;
}

static void* audio_main(void* arg) {
  (void)arg;
  float in[64] = {0}, out[64];
  while (!atomic_load(&g_stop)) le_engine_process(g_engine, out, in, 32);
  return NULL;
}

static int routing_scenario(void) {
  memset(&g_capture, 0, sizeof(g_capture));
  g_engine = le_engine_create();
  if (g_engine == NULL ||
      le_engine_configure(g_engine, 48000, 2, 2, 48000) != LE_OK ||
      le_engine_set_instrument(g_engine, 0, le_synth_patch_find("pad"), NULL) != LE_OK ||
      le_engine_set_instrument(g_engine, 1, le_synth_patch_find("keys"), NULL) != LE_OK) {
    printf("FAIL: routing setup\n");
    return 1;
  }
  le_midi* m = (le_midi*)(void*)&g_capture;
  le_engine_attach_midi_input(g_engine, m, 2);
  le_inst_routes r;
  memset(&r, 0, sizeof(r));
  for (int k = 0; k < 2; ++k) {
    r.inst[k].midi_enabled = 1;
    r.inst[k].port = 2;
    r.inst[k].high = 127;
  }
  le_engine_set_instrument_routes(g_engine, &r);
  /* The callback is now the only reader of the tables, as when started. */
  atomic_store(&g_engine->a_running, 1);
  pthread_t midi, audio;
  pthread_create(&audio, NULL, audio_main, NULL);
  pthread_create(&midi, NULL, midi_main, NULL);
  int published = 0, refused = 0;
  for (int i = 0; published < ROUTE_PUBLISHES; ++i) {
    r.inst[0].low = (int32_t)(i % 64);
    r.inst[0].channel = i % 3;
    r.inst[1].midi_enabled = (i & 4) == 0;
    r.inst[1].remap_count = i & 1;
    r.inst[1].remaps[0] = (le_inst_remap){2, 0, LE_INST_REMAP_NOTE, (uint8_t)(i & 0x7F), 2, {40, 47}};
    const int32_t rc = le_engine_set_instrument_routes(g_engine, &r);
    if (rc == LE_OK) {
      ++published;
    } else if (rc == LE_ERR_NOT_READY) {
      ++refused;
    } else {
      printf("FAIL: route publish returned %d\n", rc);
      atomic_store(&g_stop, 1);
      break;
    }
    /* Rebinds only in the second half: an attach is a seq_cst handover the
     * MIDI thread then carries to the audio thread, which would hide a
     * missing release on the table flip in the first half from TSAN. */
    if (published >= ROUTE_PUBLISHES / 2 && i % 500 == 0) {
      le_engine_attach_midi_input(g_engine, m, 2); /* rebind */
    }
  }
  atomic_store(&g_stop, 1);
  pthread_join(midi, NULL);
  pthread_join(audio, NULL);
  float in[64] = {0}, out[64];
  le_engine_process(g_engine, out, in, 32); /* drain what is left */
  le_synth* s = (le_synth*)g_engine->synth;
  int held = 0;
  for (int i = 0; i < s->voice_count; ++i) {
    held += s->voices[i].state == 1 &&
            (s->voices[i].origin & LE_INST_CONTROL_ORIGIN) == 0u;
  }
  le_snapshot snap;
  memset(&snap, 0, sizeof(snap));
  le_engine_get_snapshot(g_engine, &snap);
  printf("instrument routing: %llu pairs, %d publishes (%d not ready), %u "
         "overflow blocks, %d stuck notes\n",
         (unsigned long long)atomic_load(&g_pairs), published, refused,
         snap.midi_in_overflows, held);
  atomic_store(&g_engine->a_running, 0);
  le_engine_destroy(g_engine);
  if (atomic_load(&g_pairs) == 0 || held != 0) {
    printf("FAIL: a MIDI note stayed held under routing\n");
    return 1;
  }
  return 0;
}

int main(void) {
  if (rings_scenario() != 0 || routing_scenario() != 0) return 1;
  printf("ALL PASSED\n");
  return 0;
}
