/*
 * fuzz_backing_decode.c — fuzz target for the app's audio-file decoder
 * (#1200 plan review, M2): le_backing_probe_file and le_backing_decode_file
 * over arbitrary bytes.
 *
 * Two ways to run it:
 *   - libFuzzer (clang with -fsanitize=fuzzer,address -DLE_LIBFUZZER): the
 *     LLVMFuzzerTestOneInput entry point below, for long local campaigns;
 *   - the built-in driver (every other build, including gcc): a fixed-seed
 *     mutation loop, SEGNO_FUZZ_ITERATIONS inputs (default 3000), over a
 *     seed corpus of every accepted and every refused variant: WAV PCM
 *     16/24/32 and float32 plain and EXTENSIBLE, 8-bit, 64-bit float,
 *     mu-law, A-law, ADPCM, short and long fact chunks, RIFX, RF64, plus
 *     every file in src/test/fixtures/backing (MP3s, MP2, AIFF, FLAC, Wave64
 *     and the review's reproducers). Mutations reach the whole file: bit and
 *     byte edits anywhere, extreme 16- and 32-bit values, chunk-size edits
 *     after anything that looks like a chunk id, repeated spans, splices
 *     from other seeds, runs of 0x00 or 0xFF, truncation (P2 review M1).
 *     Each input has a 10 s watchdog: a hang is a failure, not a stall.
 *     run_native_tests.sh runs it in every configuration, so the ASan job
 *     (which also enables UBSan) fuzzes it on every push; SEGNO_FUZZ_SEED
 *     varies the run for longer local campaigns.
 *
 * Every input must return a le_result without a crash, a hang or a
 * sanitizer report; an accepted decode must stay inside the cap and hold
 * only finite samples.
 */
#include <dirent.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
    const int32_t frames = le_backing_buffer_frames(b);
    if (frames <= 0 || frames > LE_BACKING_MAX_SECONDS * 48000) {
      ++g_violations;
    }
    const float* pcm = le_backing_buffer_pcm(b);
    for (int64_t i = 0; frames > 0 && i < (int64_t)frames * 2; ++i) {
      if (!isfinite(pcm[i])) {
        ++g_violations;
        break;
      }
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

/* A WAV: format [tag] (0xFFFE: EXTENSIBLE with subformat [sub]), [bits],
 * [ch], [rate], [frames] of a ramp; a `fact` chunk of [fact] bytes ahead of
 * the data when [fact] >= 0. */
static size_t make_wav(uint8_t* out, size_t cap, int tag, int sub, int bits,
                       int ch, uint32_t rate, int frames, int fact) {
  const size_t data = (size_t)frames * (size_t)ch * (size_t)(bits / 8 > 0 ? bits / 8 : 1);
  const size_t fmt = tag == 0xFFFE ? 40 : 16;
  const size_t fact_len = fact >= 0 ? 8 + (size_t)fact + ((size_t)fact & 1) : 0;
  const size_t total = 12 + 8 + fmt + fact_len + 8 + data;
  if (total > cap) return 0;
  memset(out, 0, total);
  memcpy(out, "RIFF", 4);
  put32(out + 4, (uint32_t)(total - 8));
  memcpy(out + 8, "WAVEfmt ", 8);
  put32(out + 16, (uint32_t)fmt);
  uint8_t* f = out + 20;
  put16(f, (uint16_t)tag);
  put16(f + 2, (uint16_t)ch);
  put32(f + 4, rate);
  put32(f + 8, rate * (uint32_t)ch * (uint32_t)bits / 8u);
  put16(f + 12, (uint16_t)(ch * bits / 8));
  put16(f + 14, (uint16_t)bits);
  if (tag == 0xFFFE) {
    static const uint8_t tail[14] = {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80,
                                     0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
    put16(f + 16, 22);
    put16(f + 18, (uint16_t)bits);
    put32(f + 20, ch == 1 ? 4u : 3u);
    put16(f + 24, (uint16_t)sub);
    memcpy(f + 26, tail, sizeof(tail));
  }
  uint8_t* at = f + fmt;
  if (fact >= 0) {
    memcpy(at, "fact", 4);
    put32(at + 4, (uint32_t)fact);
    if (fact >= 4) put32(at + 8, (uint32_t)frames);
    at += fact_len;
  }
  memcpy(at, "data", 4);
  put32(at + 4, (uint32_t)data);
  for (size_t i = 0; i < data; ++i) at[8 + i] = (uint8_t)(i * 37u);
  if (tag == 3 || (tag == 0xFFFE && sub == 3)) {
    /* Finite floats, so an accepted seed decodes. */
    for (size_t i = 0; i + 4 <= data; i += 4) {
      const float v = 0.25f * (float)((int)(i % 97) - 48) / 48.0f;
      memcpy(at + 8 + i, &v, 4);
    }
  }
  return total;
}

static size_t read_file(const char* path, uint8_t* out, size_t cap) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  const size_t n = fread(out, 1, cap, f);
  fclose(f);
  return n;
}

#define MAX_INPUT (96 * 1024)
#define MAX_SEEDS 64

static uint8_t g_seeds[MAX_SEEDS][MAX_INPUT];
static size_t g_seed_len[MAX_SEEDS];
static int g_nseeds;

static uint8_t* next_seed(void) {
  return g_nseeds < MAX_SEEDS ? g_seeds[g_nseeds] : NULL;
}
static void keep_seed(size_t n) {
  if (n > 0 && g_nseeds < MAX_SEEDS) g_seed_len[g_nseeds++] = n;
}

static void build_seeds(void) {
  /* {tag, sub, bits}: accepted first, then refused. */
  static const int formats[][3] = {
      {1, 0, 16},      {1, 0, 24},      {1, 0, 32}, {3, 0, 32},
      {0xFFFE, 1, 16}, {0xFFFE, 1, 24}, {0xFFFE, 3, 32},
      {1, 0, 8},       {3, 0, 64},      {7, 0, 8},  {6, 0, 8},
      {2, 0, 4},       {0x11, 0, 4},    {0xFFFE, 2, 16}};
  for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); ++i) {
    uint8_t* s = next_seed();
    if (s == NULL) return;
    keep_seed(make_wav(s, MAX_INPUT, formats[i][0], formats[i][1],
                       formats[i][2], 1 + (int)(i % 2),
                       i % 3 == 0 ? 44100u : 48000u, 300, -1));
  }
  /* fact chunks of 0, 1, 4 and 12 bytes; a 192 kHz file that halves. */
  const int facts[] = {0, 1, 4, 12};
  for (size_t i = 0; i < sizeof(facts) / sizeof(facts[0]); ++i) {
    uint8_t* s = next_seed();
    if (s == NULL) return;
    keep_seed(make_wav(s, MAX_INPUT, 3, 0, 32, 1, 48000, 200, facts[i]));
  }
  uint8_t* s = next_seed();
  if (s != NULL) keep_seed(make_wav(s, MAX_INPUT, 1, 0, 16, 2, 192000u, 2000, -1));
  /* Other RIFF-likes. */
  static const char* magics[] = {"RIFX", "RF64"};
  for (size_t i = 0; i < 2; ++i) {
    s = next_seed();
    if (s == NULL) return;
    const size_t n = make_wav(s, MAX_INPUT, 1, 0, 16, 1, 48000, 200, -1);
    memcpy(s, magics[i], 4);
    keep_seed(n);
  }
  /* Every fixture: MP3s, MP2, AIFF, FLAC, Wave64 and the reproducers. */
  const char* dir = "src/test/fixtures/backing";
  DIR* d = opendir(dir);
  if (d != NULL) {
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
      if (e->d_name[0] == '.' || strstr(e->d_name, ".md") != NULL) continue;
      char path[1024];
      snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
      s = next_seed();
      if (s == NULL) break;
      keep_seed(read_file(path, s, MAX_INPUT));
    }
    closedir(d);
  }
}

static void on_alarm(int sig) {
  (void)sig;
  static const char msg[] =
      "fuzz_backing_decode: an input ran over 10 s (a hang); it is left in "
      "TMPDIR\n";
  if (write(2, msg, sizeof(msg) - 1) < 0) _exit(98);
  _exit(99);
}

int main(void) {
  build_seeds();
  if (g_nseeds < 20) {
    printf("fuzz_backing_decode: only %d seeds (run from the package root)\n",
           g_nseeds);
    return 1;
  }
  const char* env = getenv("SEGNO_FUZZ_ITERATIONS");
  const int iterations = env != NULL ? atoi(env) : 3000;
  const char* seed_env = getenv("SEGNO_FUZZ_SEED");
  if (seed_env != NULL) g_seed ^= (uint32_t)strtoul(seed_env, NULL, 10) * 2654435761u;
  if (g_seed == 0) g_seed = 1;
  signal(SIGALRM, on_alarm);
  static const uint32_t extremes[] = {
      0u,          1u,          2u,          3u,      0x7FFFFFFFu, 0x80000000u,
      0xFFFFFFFFu, 0xFFFFFFFEu, 0x10000u,    0xFFFFu, 8u,          16u,
      24u,         32u,         64u,         384000u, 8000u,       44100u};
  const size_t nx = sizeof(extremes) / sizeof(extremes[0]);
  static uint8_t input[MAX_INPUT * 2];
  for (int it = 0; it < iterations; ++it) {
    const int k = (int)(rnd() % (uint32_t)g_nseeds);
    size_t n = g_seed_len[k];
    memcpy(input, g_seeds[k], n);
    const int edits = 1 + (int)(rnd() % 6);
    for (int e = 0; e < edits; ++e) {
      switch (rnd() % 9) {
        case 0: /* flip a bit anywhere */
          input[rnd() % n] ^= (uint8_t)(1u << (rnd() % 8));
          break;
        case 1: /* truncate, sometimes */
          if (rnd() % 4 == 0) n = 1 + rnd() % n;
          break;
        case 2: /* an extreme 32-bit value, anywhere or in the header */
        case 3: { /* or a 16-bit one */
          const size_t width = (rnd() % 2) ? 4 : 2;
          const size_t span = (rnd() % 3 == 0) ? n : (n < 256 ? n : 256);
          const size_t at = rnd() % span;
          const uint32_t v = extremes[rnd() % nx];
          if (at + width <= n) {
            if (width == 4) put32(input + at, v);
            else put16(input + at, (uint16_t)v);
          }
          break;
        }
        case 4: /* a random byte anywhere */
          input[rnd() % n] = (uint8_t)rnd();
          break;
        case 5: /* repeat a span */
          if (n < MAX_INPUT) {
            const size_t at = rnd() % n;
            size_t len = 1 + rnd() % (n - at);
            if (len > MAX_INPUT - n) len = MAX_INPUT - n;
            memmove(input + at + len, input + at, n - at);
            n += len;
          }
          break;
        case 6: { /* splice from another seed */
          const int k2 = (int)(rnd() % (uint32_t)g_nseeds);
          const size_t from = rnd() % g_seed_len[k2];
          size_t len = rnd() % (g_seed_len[k2] - from + 1);
          const size_t at = rnd() % n;
          if (at + len > MAX_INPUT) len = MAX_INPUT - at;
          memcpy(input + at, g_seeds[k2] + from, len);
          if (at + len > n) n = at + len;
          break;
        }
        case 7: /* a chunk size after something that looks like a chunk id */
          for (int t = 0; t < 16; ++t) {
            const size_t at = rnd() % n;
            if (at + 8 <= n && input[at] >= 'A' && input[at] <= 'z' &&
                input[at + 1] >= ' ' && input[at + 2] >= ' ' &&
                input[at + 3] >= ' ') {
              put32(input + at + 4,
                    extremes[rnd() % nx] + (uint32_t)(rnd() % 3) - 1u);
              break;
            }
          }
          break;
        default: { /* a run of 0x00 or 0xFF */
          const size_t at = rnd() % n;
          size_t len = 1 + rnd() % 64;
          if (at + len > n) len = n - at;
          memset(input + at, (rnd() % 2) ? 0xFF : 0x00, len);
          break;
        }
      }
      if (n == 0) n = 1;
    }
    alarm(10);
    LLVMFuzzerTestOneInput(input, n);
    alarm(0);
  }
  remove(g_path);
  printf("fuzz_backing_decode: %d seeds, %d inputs, %d violations\n", g_nseeds,
         iterations, g_violations);
  if (g_violations != 0) return 1;
  printf("ALL PASSED\n");
  return 0;
}

#endif /* LE_LIBFUZZER */
