/*
 * test_perf_drain_races.c — the capture drain against a running callback
 * (#1198 Part 2), for ThreadSanitizer.
 *
 * test_engine_core.c drives the drain from a single-threaded pump, so a TSAN
 * run over it would check nothing about the threads that actually share the
 * capture: the audio callback pushing into the rings and publishing
 * a_perf_frames, the drain thread popping them and rolling parts over, and a
 * control thread reading snapshots. This binary runs those three at once on
 * the production engine (no test hooks compiled in), with parts small enough
 * that the drain seals and opens many of them mid-take, then checks that
 * every frame landed in a sealed part whose header sizes match its file.
 *
 * It runs in the plain native suite (the functional check) and in the
 * native-tests-tsan job (NATIVE_TESTS_ONLY=races, -fsanitize=thread).
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segno_engine_api.h"

static int g_failures = 0;
#define CHECK(c)                                                       \
  do {                                                                 \
    if (!(c)) {                                                        \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);     \
      ++g_failures;                                                    \
    }                                                                  \
  } while (0)

#define RACE_BLOCK 256
#define RACE_BLOCKS 400
#define RACE_PART_FRAMES 4096

static le_engine* g_engine;
static _Atomic int g_audio_done;

static void sleep_ms(int ms) {
  struct timespec ts = {0, (long)ms * 1000000L};
  nanosleep(&ts, NULL);
}

/* The callback's role: real-time-paced blocks of a ramp on input 0, which is
 * monitored to both outputs and captured as its own stream. */
static void* audio_thread(void* arg) {
  (void)arg;
  float in[RACE_BLOCK * 2];
  float out[RACE_BLOCK * 2];
  for (int b = 0; b < RACE_BLOCKS; ++b) {
    for (int i = 0; i < RACE_BLOCK * 2; ++i) {
      in[i] = (float)((b * RACE_BLOCK + i / 2) % 1000) * 0.0005f;
    }
    le_engine_process(g_engine, out, in, RACE_BLOCK);
    sleep_ms(5); /* ~51 kHz: the drain keeps up, as it must on a device */
  }
  atomic_store_explicit(&g_audio_done, 1, memory_order_release);
  return NULL;
}

/* A control thread reading published capture state while both run. */
static void* control_thread(void* arg) {
  (void)arg;
  le_snapshot s;
  uint64_t last = 0;
  while (!atomic_load_explicit(&g_audio_done, memory_order_acquire)) {
    le_engine_get_snapshot(g_engine, &s);
    CHECK(s.perf_frames >= last); /* the frame clock never runs backwards */
    last = s.perf_frames;
    sleep_ms(2);
  }
  return NULL;
}

static long file_size(const char* path) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return -1;
  long n = -1;
  if (fseek(f, 0, SEEK_END) == 0) n = ftell(f);
  fclose(f);
  return n;
}

static uint32_t data_size_of(const char* path) {
  unsigned char h[84];
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0xFFFFFFFFu;
  const size_t n = fread(h, 1, sizeof(h), f);
  fclose(f);
  if (n != sizeof(h)) return 0xFFFFFFFFu;
  return (uint32_t)h[80] | ((uint32_t)h[81] << 8) | ((uint32_t)h[82] << 16) |
         ((uint32_t)h[83] << 24);
}

/* Sums the frames of every part of `stream`, checking each is sealed: its
 * header's data size equals the bytes after the header. */
static uint64_t stream_frames(const char* dir, const char* stream,
                              int channels, int* parts) {
  uint64_t frames = 0;
  *parts = 0;
  for (int index = 1;; ++index) {
    char path[800];
    snprintf(path, sizeof(path), "%s/%s-%03d.wav", dir, stream, index);
    const long size = file_size(path);
    if (size < 0) break;
    CHECK(data_size_of(path) == (uint32_t)(size - LE_PERF_PART_HEADER_BYTES));
    frames += (uint64_t)(size - LE_PERF_PART_HEADER_BYTES) /
              ((uint64_t)channels * sizeof(float));
    ++*parts;
  }
  return frames;
}

int main(void) {
  char dir[512];
  const char* tmp = getenv("TMPDIR");
  snprintf(dir, sizeof(dir), "%s/segno_drain_race_%ld", tmp ? tmp : "/tmp",
           (long)time(NULL));

  g_engine = le_engine_create();
  CHECK(le_engine_configure(g_engine, 48000, 2, 2, 1000) == LE_OK);
  CHECK(le_engine_set_monitor_input(g_engine, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(g_engine, 0, 3) == LE_OK);
  float out[RACE_BLOCK * 2];
  float in[RACE_BLOCK * 2] = {0};
  le_engine_process(g_engine, out, in, 0);

  le_perf_target target;
  memset(&target, 0, sizeof(target));
  target.capture_dir = dir;
  target.volume_generation = -1;
  target.part_bytes =
      LE_PERF_PART_HEADER_BYTES + (uint64_t)RACE_PART_FRAMES * 2 * 4;
  CHECK(le_perf_arm(g_engine, &target) == LE_OK);
  le_engine_process(g_engine, out, in, 0); /* apply the arm */

  pthread_t audio, control;
  pthread_create(&audio, NULL, audio_thread, NULL);
  pthread_create(&control, NULL, control_thread, NULL);
  pthread_join(audio, NULL);
  pthread_join(control, NULL);

  CHECK(le_perf_disarm(g_engine) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(g_engine, &s);
  const uint64_t elapsed = s.perf_frames;
  CHECK(elapsed == (uint64_t)RACE_BLOCK * RACE_BLOCKS);

  int master_parts = 0;
  int input_parts = 0;
  /* Whatever the drain could not keep up with is zero-filled, so every
   * stream holds exactly the elapsed frames, in sealed parts. */
  CHECK(stream_frames(dir, "master", 2, &master_parts) == elapsed);
  CHECK(stream_frames(dir, "input-0", 2, &input_parts) == elapsed);
  const int expected_parts =
      (int)((elapsed + RACE_PART_FRAMES - 1) / RACE_PART_FRAMES);
  CHECK(master_parts == expected_parts);
  CHECK(input_parts == expected_parts);

  le_engine_destroy(g_engine);
  if (g_failures == 0) printf("ALL PASSED\n");
  return g_failures == 0 ? 0 : 1;
}
