/*
 * fuzz_backing_decode.c — fuzz target for the app's audio-file decoder
 * (#1200 plan review, M2): le_backing_probe_file and le_backing_decode_file
 * over arbitrary bytes.
 *
 * Two ways to run it:
 *   - libFuzzer (clang with -fsanitize=fuzzer,address -DLE_LIBFUZZER): the
 *     LLVMFuzzerTestOneInput entry point below, for long local campaigns;
 *   - the built-in driver (every other build, including gcc): a fixed-seed
 *     mutation loop over a seed corpus built here (WAV headers with bogus
 *     sizes, rates and chunk lengths, truncations, ID3 and RIFF garbage, the
 *     MP3 and FLAC fixtures), SEGNO_FUZZ_ITERATIONS inputs (default 2000).
 *     run_native_tests.sh runs it in every configuration, so the ASan job is
 *     a bounded fuzz run on every push.
 *
 * Every input must return a le_result without a crash or a sanitizer
 * report; an accepted decode must stay inside the cap.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "segno_engine_api.h"

static char g_path[512];

static void fuzz_path(void) {
  if (g_path[0] != '\0') return;
  const char* tmp = getenv("TMPDIR");
  if (tmp == NULL || tmp[0] == '\0') tmp = "/tmp";
  snprintf(g_path, sizeof(g_path), "%s/segno_fuzz_decode_%ld.bin", tmp,
           (long)rand());
}

static int g_violations;

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  fuzz_path();
  FILE* f = fopen(g_path, "wb");
  if (f == NULL) return 0;
  if (size > 0) fwrite(data, 1, size, f);
  fclose(f);
  le_backing_decode_info info;
  float peaks[16];
  const int32_t probe = le_backing_probe_file(g_path, &info, peaks, 16);
  if (probe == LE_OK &&
      info.source_frames > (int64_t)LE_BACKING_MAX_SECONDS * info.source_rate) {
    ++g_violations;
  }
  le_backing_buffer* b = NULL;
  if (le_backing_decode_file(g_path, 48000, 0, 0, &b, &info) == LE_OK) {
    if (le_backing_buffer_frames(b) <= 0 ||
        le_backing_buffer_frames(b) > LE_BACKING_MAX_SECONDS * 48000) {
      ++g_violations;
    }
  }
  le_backing_buffer_free(b);
  b = NULL;
  if (le_backing_decode_file(g_path, 44100, 100, 4800, &b, &info) == LE_OK &&
      le_backing_buffer_frames(b) > 4800) {
    ++g_violations;
  }
  le_backing_buffer_free(b);
  return 0;
}

#ifndef LE_LIBFUZZER

static uint32_t g_seed = 0x0dec0de1u;
static uint32_t rnd(void) {
  g_seed ^= g_seed << 13;
  g_seed ^= g_seed >> 17;
  g_seed ^= g_seed << 5;
  return g_seed;
}

static void put16(uint8_t* p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (8 * i));
}

/* A canonical WAV: [fmt] code, [bits], [ch], [rate], [frames] of a ramp. */
static size_t make_wav(uint8_t* out, size_t cap, int fmt, int bits, int ch,
                       uint32_t rate, int frames) {
  const size_t data = (size_t)frames * (size_t)ch * (size_t)(bits / 8);
  if (44 + data > cap) return 0;
  memcpy(out, "RIFF", 4);
  put32(out + 4, (uint32_t)(36 + data));
  memcpy(out + 8, "WAVEfmt ", 8);
  put32(out + 16, 16);
  put16(out + 20, (uint16_t)fmt);
  put16(out + 22, (uint16_t)ch);
  put32(out + 24, rate);
  put32(out + 28, rate * (uint32_t)ch * (uint32_t)(bits / 8));
  put16(out + 32, (uint16_t)(ch * bits / 8));
  put16(out + 34, (uint16_t)bits);
  memcpy(out + 36, "data", 4);
  put32(out + 40, (uint32_t)data);
  for (size_t i = 0; i < data; ++i) out[44 + i] = (uint8_t)(i * 37u);
  return 44 + data;
}

static size_t read_fixture(const char* path, uint8_t* out, size_t cap) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  const size_t n = fread(out, 1, cap, f);
  fclose(f);
  return n;
}

#define MAX_INPUT (64 * 1024)
#define SEEDS 10

int main(void) {
  static uint8_t seed[SEEDS][MAX_INPUT];
  size_t seed_len[SEEDS] = {0};
  seed_len[0] = make_wav(seed[0], MAX_INPUT, 1, 16, 1, 48000, 1000);
  seed_len[1] = make_wav(seed[1], MAX_INPUT, 1, 24, 2, 44100, 500);
  seed_len[2] = make_wav(seed[2], MAX_INPUT, 3, 32, 2, 96000, 300);
  seed_len[3] = make_wav(seed[3], MAX_INPUT, 1, 8, 1, 8000, 2000);
  seed_len[4] = make_wav(seed[4], MAX_INPUT, 3, 64, 1, 192000, 200);
  seed_len[5] = read_fixture("src/test/fixtures/backing/sine1k_44k1_stereo.mp3",
                             seed[5], MAX_INPUT);
  seed_len[6] = read_fixture("src/test/fixtures/backing/sine1k_44k1_mono.flac",
                             seed[6], MAX_INPUT);
  /* ID3v2 garbage ahead of the MP3. */
  memcpy(seed[7], "ID3\x04\x00\x00\x00\x00\x10\x00", 10);
  for (int i = 10; i < 2058; ++i) seed[7][i] = (uint8_t)(i * 13);
  if (seed_len[5] + 2058 <= MAX_INPUT) {
    memcpy(seed[7] + 2058, seed[5], seed_len[5]);
    seed_len[7] = seed_len[5] + 2058;
  }
  /* A WAV whose data chunk claims 4 GB, and one with a fmt chunk too short. */
  seed_len[8] = make_wav(seed[8], MAX_INPUT, 1, 16, 2, 48000, 100);
  put32(seed[8] + 40, 0xFFFFFFFFu);
  seed_len[9] = make_wav(seed[9], MAX_INPUT, 1, 16, 1, 48000, 100);
  put32(seed[9] + 16, 2);

  const char* env = getenv("SEGNO_FUZZ_ITERATIONS");
  const int iterations = env != NULL ? atoi(env) : 2000;
  static uint8_t input[MAX_INPUT];
  for (int it = 0; it < iterations; ++it) {
    const int k = (int)(rnd() % SEEDS);
    size_t n = seed_len[k];
    if (n == 0) continue;
    memcpy(input, seed[k], n);
    const int edits = 1 + (int)(rnd() % 8);
    for (int e = 0; e < edits; ++e) {
      switch (rnd() % 6) {
        case 0: /* flip a byte */
          input[rnd() % n] ^= (uint8_t)(1u << (rnd() % 8));
          break;
        case 1: /* truncate */
          n = 1 + rnd() % n;
          break;
        case 2: /* a header field: a 32-bit value somewhere in the first 64 */
          if (n >= 8) put32(input + (rnd() % (n < 64 ? n - 4 : 60)), rnd());
          break;
        case 3: /* an extreme 32-bit value */
          if (n >= 8) {
            static const uint32_t extremes[] = {0u, 1u, 0x7FFFFFFFu,
                                                0x80000000u, 0xFFFFFFFFu, 3u};
            put32(input + (rnd() % (n < 64 ? n - 4 : 60)),
                  extremes[rnd() % 6]);
          }
          break;
        case 4: /* a random byte anywhere */
          input[rnd() % n] = (uint8_t)rnd();
          break;
        default: /* duplicate a span (a repeated chunk) */
          if (n < MAX_INPUT / 2) {
            const size_t at = rnd() % n, len = 1 + rnd() % (n - at);
            memmove(input + at + len, input + at, n - at);
            n += len;
          }
          break;
      }
    }
    LLVMFuzzerTestOneInput(input, n);
  }
  remove(g_path);
  printf("fuzz_backing_decode: %d inputs, %d violations\n", iterations,
         g_violations);
  if (g_violations != 0) return 1;
  printf("ALL PASSED\n");
  return 0;
}

#endif /* LE_LIBFUZZER */
