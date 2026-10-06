/* Instrument note rings across two threads (#1197 Part 2a, PR #1234 review
 * M1): a control thread posts note-on/note-off pairs while an audio thread
 * drains in a hot loop. Each pair is posted the moment the note-on ring is
 * empty, so the drain often peeks the note ring just before the pair lands
 * and the release ring just after: without the published high-water mark it
 * applies the note-off before its own note-on, and the voice stays held
 * forever. Every origin gets its release, so any voice still HELD at the end
 * is a stuck note. Built by run_native_tests.sh in every configuration,
 * including the ThreadSanitizer job (fewer pairs there). */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "engine_instruments.h"
#include "engine_private.h"
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
#else
#define RACE_PAIRS 300000
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

int main(void) {
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
  printf("ALL PASSED\n");
  return 0;
}
