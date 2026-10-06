/*
 * engine_decode.c — the app's one audio-file decoder (#1200 Part 2, plan
 * review M2/M3): WAV and MP3 through miniaudio's built-in decoders, band-
 * limited rate conversion, a streaming probe, and the memory guard that
 * keeps a decode from pushing the appliance into the OOM killer.
 *
 * Every function here runs on a control or worker thread (in practice a
 * Dart background isolate), never on the audio thread, and touches no
 * engine state. The contract is in segno_engine_api.h
 * (le_backing_decode_file, le_backing_probe_file).
 *
 * Untrusted input. These functions parse files a performer brings on a USB
 * drive. They run in the app's process, so a decoder fault would end the
 * audio. Mitigations, by layer: the formats are limited to WAV and MP3
 * (miniaudio's FLAC decoder is compiled out: CVE-2024-41147, an
 * out-of-bounds write in its LPC path, is unfixed in the vendored 0.11.21);
 * the WAV decoder runs without its metadata parser (ma_decoder opens files
 * with ma_dr_wav_init_file, flags 0), so CVE-2026-32837 (the BEXT parser)
 * is unreachable; every rate, channel count and length is range-checked
 * before it sizes anything; a decode error mid-stream is a refusal; and a
 * fuzz target (src/test/fuzz_backing_decode.c) runs under ASan in CI. A
 * file is decoded once at import (the probe); later decodes read the
 * managed internal copy that already passed.
 */
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"
#include "engine_private.h"
#include "miniaudio.h"
#include "restore_halfband.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Accepted source rates and channels. */
#define LE_DECODE_MIN_RATE 8000
#define LE_DECODE_MAX_RATE 384000
/* Decoded float bytes per file byte, at most: an 8 kbit/s MP3 at 48 kHz
 * stereo expands 384x. A stated length beyond what the file could hold at
 * this ratio is a lie, refused before it sizes an allocation. */
#define LE_DECODE_MAX_EXPANSION 512

static int64_t le_file_bytes(const char* path) {
#if defined(_WIN32)
  struct _stat64 st;
  return _stat64(path, &st) == 0 ? (int64_t)st.st_size : -1;
#else
  struct stat st;
  return stat(path, &st) == 0 ? (int64_t)st.st_size : -1;
#endif
}

#ifdef LE_NATIVE_TESTS
int64_t (*le_test_mem_available_hook)(void) = NULL;
#endif

/* ---- the memory guard ---- */

/* Bytes the kernel says can be allocated without swapping, or -1 when
 * unknown (not Linux, or /proc unreadable): unknown is not refused, as on a
 * desktop development build. */
static int64_t le_mem_available(void) {
#ifdef LE_NATIVE_TESTS
  if (le_test_mem_available_hook != NULL) return le_test_mem_available_hook();
#endif
#if defined(__linux__)
  FILE* f = fopen("/proc/meminfo", "r");
  if (f == NULL) return -1;
  char line[128];
  int64_t kb = -1;
  while (fgets(line, sizeof(line), f) != NULL) {
    long long v = 0;
    if (sscanf(line, "MemAvailable: %lld kB", &v) == 1) {
      kb = (int64_t)v;
      break;
    }
  }
  fclose(f);
  return kb < 0 ? -1 : kb * 1024;
#else
  return -1;
#endif
}

/* Whether [bytes] more can be allocated and still leave LE_MEM_RESERVE_BYTES
 * for loops, capture and the system. */
static int le_mem_allows(int64_t bytes) {
  const int64_t avail = le_mem_available();
  return avail < 0 || avail - bytes >= LE_MEM_RESERVE_BYTES;
}

/* ---- offline sample-rate conversion ----
 *
 * A polyphase Kaiser-windowed sinc with exact rational phases. For a ratio
 * r = min(1, out / in) the kernel is r * sinc(r x) under a Kaiser window
 * (beta 10.06, about 100 dB of stop band) of half-width H = ceil(32 / r)
 * input samples, so its transition spans 0.45 r .. 0.55 r of the input rate
 * whatever the ratio, and every one of the out / gcd(in, out) phases is
 * normalised to unity DC gain. Reductions below one half are refused: the
 * decoder halves first through the exact half-band decimator.
 *
 * Why not a library: miniaudio's resampler is linear interpolation behind a
 * low-order low-pass; the vendored Signalsmith KaiserSincN kernel forces
 * exact zeros at integer offsets, which is only right when its cutoff is the
 * input Nyquist, so it cannot band-limit a reduction (measured: 1.09-2.0 DC
 * gain off phase 0); the pitch/time read head is a two-tap varispeed. */

#define LE_RS_BETA 10.06
#define LE_RS_HALF_WIDTH 32
#define LE_RS_MAX_PHASES 8192

static double le_rs_bessel_i0(double x) {
  double sum = 1.0, term = 1.0;
  const double q = x * x / 4.0;
  for (int k = 1; k < 64; ++k) {
    term *= q / ((double)k * (double)k);
    sum += term;
    if (term < sum * 1e-17) break;
  }
  return sum;
}

static int64_t le_rs_gcd(int64_t a, int64_t b) {
  while (b != 0) {
    const int64_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

int64_t le_resample_frames(int64_t in_frames, int32_t in_rate,
                           int32_t out_rate) {
  if (in_frames <= 0 || in_rate <= 0 || out_rate <= 0) return 0;
  return in_frames * (int64_t)out_rate / (int64_t)in_rate;
}

int32_t le_resample_offline(const float* in, int32_t in_stride,
                            int32_t in_frames, int32_t in_rate, float* out,
                            int32_t out_stride, int32_t out_frames,
                            int32_t out_rate) {
  if (in == NULL || out == NULL || in_stride <= 0 || out_stride <= 0 ||
      in_frames <= 0 || in_rate <= 0 || out_rate <= 0 ||
      (int64_t)out_rate * 2 < (int64_t)in_rate ||
      out_frames != le_resample_frames(in_frames, in_rate, out_rate)) {
    return LE_ERR_INVALID;
  }
  if (in_rate == out_rate) {
    for (int32_t t = 0; t < in_frames; ++t) {
      out[(size_t)t * out_stride] = in[(size_t)t * in_stride];
    }
    return LE_OK;
  }
  const int64_t g = le_rs_gcd(in_rate, out_rate);
  const int64_t phases = out_rate / g;
  if (phases > LE_RS_MAX_PHASES) return LE_ERR_INVALID;
  const double r = out_rate < in_rate ? (double)out_rate / in_rate : 1.0;
  const int32_t half = (int32_t)ceil(LE_RS_HALF_WIDTH / r);
  const int32_t taps = 2 * half;
  /* table[k][j]: weight of input i - half + 1 + j for the output whose input
   * position is i + k / phases. */
  float* table = (float*)malloc((size_t)phases * (size_t)taps * sizeof(float));
  if (table == NULL) return LE_ERR_CAPACITY;
  const double i0_beta = le_rs_bessel_i0(LE_RS_BETA);
  for (int64_t k = 0; k < phases; ++k) {
    const double frac = (double)k / (double)phases;
    double sum = 0.0;
    float* row = table + k * taps;
    for (int32_t j = 0; j < taps; ++j) {
      const double x = (double)(j - half + 1) - frac;
      const double u = x / half;
      double w = 0.0;
      if (u > -1.0 && u < 1.0) {
        const double px = M_PI * r * x;
        const double sinc = x == 0.0 ? 1.0 : sin(px) / px;
        w = r * sinc * le_rs_bessel_i0(LE_RS_BETA * sqrt(1.0 - u * u)) /
            i0_beta;
      }
      row[j] = (float)w;
      sum += w;
    }
    for (int32_t j = 0; j < taps; ++j) row[j] = (float)(row[j] / sum);
  }
  for (int32_t t = 0; t < out_frames; ++t) {
    const int64_t num = (int64_t)t * in_rate;
    const int64_t i = num / out_rate;
    const float* row = table + ((num % out_rate) / g) * taps;
    const int64_t first = i - half + 1;
    double acc = 0.0;
    int32_t j0 = 0, j1 = taps;
    if (first < 0) j0 = (int32_t)-first;
    if (first + taps > in_frames) j1 = (int32_t)(in_frames - first);
    for (int32_t j = j0; j < j1; ++j) {
      acc += (double)in[(size_t)(first + j) * in_stride] * row[j];
    }
    out[(size_t)t * out_stride] = (float)acc;
  }
  free(table);
  return LE_OK;
}

/* ---- opening and reading ---- */

typedef struct le_decode_src {
  ma_decoder dec;
  int32_t rate, channels;
  int64_t stated; /* 0 when the format does not state a length */
} le_decode_src;

/* Opens [path] and validates what its header claims. */
static int32_t le_decode_open(const char* path, le_decode_src* s) {
  if (path == NULL || path[0] == '\0') return LE_ERR_INVALID;
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
  if (ma_decoder_init_file(path, &cfg, &s->dec) != MA_SUCCESS) {
    return LE_ERR_INVALID;
  }
  s->rate = (int32_t)s->dec.outputSampleRate;
  s->channels = (int32_t)s->dec.outputChannels;
  ma_uint64 stated = 0;
  if (ma_decoder_get_length_in_pcm_frames(&s->dec, &stated) != MA_SUCCESS) {
    stated = 0;
  }
  s->stated = stated > (ma_uint64)INT64_MAX ? INT64_MAX : (int64_t)stated;
  const int64_t bytes = le_file_bytes(path);
  if (s->channels < 1 || s->channels > 2 || s->rate < LE_DECODE_MIN_RATE ||
      s->rate > LE_DECODE_MAX_RATE ||
      s->dec.outputFormat != ma_format_f32 || bytes <= 0 ||
      s->stated > bytes * LE_DECODE_MAX_EXPANSION /
                      ((int64_t)s->channels * (int64_t)sizeof(float))) {
    ma_decoder_uninit(&s->dec);
    return LE_ERR_INVALID;
  }
  return LE_OK;
}

/* Reads up to [want] frames into [buf] (interleaved, the source's channels).
 * Returns the frames read, or a negative le_result on a decode error. A
 * short read is the end of the stream. */
static int64_t le_decode_read(le_decode_src* s, float* buf, int64_t want) {
  int64_t got = 0;
  while (got < want) {
    ma_uint64 read = 0;
    const ma_result r = ma_decoder_read_pcm_frames(
        &s->dec, buf + (size_t)got * (size_t)s->channels,
        (ma_uint64)(want - got), &read);
    got += (int64_t)read;
    if (r == MA_AT_END || (r == MA_SUCCESS && read == 0)) break;
    if (r != MA_SUCCESS) return LE_ERR_INVALID;
  }
  return got;
}

#define LE_DECODE_CHUNK 4096

/* For a format that states no length: decodes through once to count the
 * frames (into a scratch chunk, nothing retained), then rewinds. */
static int32_t le_decode_count(le_decode_src* s, float* chunk, int64_t cap) {
  int64_t total = 0;
  for (;;) {
    const int64_t n = le_decode_read(s, chunk, LE_DECODE_CHUNK);
    if (n < 0) return (int32_t)n;
    total += n;
    if (total > cap) return LE_ERR_TOO_LONG;
    if (n < LE_DECODE_CHUNK) break;
  }
  if (total == 0 || ma_decoder_seek_to_pcm_frame(&s->dec, 0) != MA_SUCCESS) {
    return LE_ERR_INVALID;
  }
  s->stated = total;
  return LE_OK;
}

/* ---- the probe: validate the whole file and peak it, retaining no PCM ---- */

int32_t le_backing_probe_file(const char* path, le_backing_decode_info* info,
                              float* peaks, int32_t buckets) {
  if (info == NULL || (peaks == NULL && buckets != 0) || buckets < 0) {
    return LE_ERR_INVALID;
  }
  memset(info, 0, sizeof(*info));
  le_decode_src s;
  int32_t rc = le_decode_open(path, &s);
  if (rc != LE_OK) return rc;
  const int64_t cap = (int64_t)LE_BACKING_MAX_SECONDS * s.rate;
  float* chunk = (float*)malloc(sizeof(float) * LE_DECODE_CHUNK * 2);
  if (chunk == NULL) {
    rc = LE_ERR_CAPACITY;
  } else if (s.stated > cap) {
    rc = LE_ERR_TOO_LONG;
  } else if (s.stated == 0) {
    rc = le_decode_count(&s, chunk, cap);
  }
  const int64_t total = s.stated;
  if (rc == LE_OK) {
    for (int32_t k = 0; k < buckets; ++k) peaks[k] = 0.0f;
    int64_t at = 0;
    for (;;) {
      const int64_t n = le_decode_read(&s, chunk, LE_DECODE_CHUNK);
      if (n < 0) { rc = (int32_t)n; break; }
      for (int64_t f = 0; f < n && buckets > 0 && total > 0; ++f) {
        int64_t k = (at + f) * buckets / total;
        if (k >= buckets) k = buckets - 1;
        for (int c = 0; c < s.channels; ++c) {
          const float a = fabsf(chunk[f * s.channels + c]);
          if (a > peaks[k]) peaks[k] = a;
        }
      }
      at += n;
      if (at > cap) { rc = LE_ERR_TOO_LONG; break; }
      if (n < LE_DECODE_CHUNK) break;
    }
    /* A file that decodes to a different length than it states is damaged. */
    if (rc == LE_OK && (at == 0 || at != total)) {
      rc = LE_ERR_INVALID;
    }
    if (rc == LE_OK) {
      info->source_frames = at;
    }
  }
  info->source_rate = s.rate;
  info->source_channels = s.channels;
  free(chunk);
  ma_decoder_uninit(&s.dec);
  return rc;
}

/* ---- the full decode ---- */

int32_t le_backing_decode_file(const char* path, int32_t sample_rate,
                               int64_t start_frame, int32_t max_frames,
                               le_backing_buffer** out,
                               le_backing_decode_info* info) {
  if (out != NULL) *out = NULL;
  if (info != NULL) memset(info, 0, sizeof(*info));
  if (out == NULL || sample_rate < LE_DECODE_MIN_RATE ||
      sample_rate > LE_DECODE_MAX_RATE || start_frame < 0 || max_frames < 0) {
    return LE_ERR_INVALID;
  }
  le_decode_src s;
  int32_t rc = le_decode_open(path, &s);
  if (rc != LE_OK) return rc;
  if (info != NULL) {
    info->source_rate = s.rate;
    info->source_channels = s.channels;
  }
  const int64_t cap = (int64_t)LE_BACKING_MAX_SECONDS * s.rate;
  const int whole = start_frame == 0 && max_frames == 0;
  if (s.stated == 0) {
    float* chunk = (float*)malloc(sizeof(float) * LE_DECODE_CHUNK * 2);
    rc = chunk == NULL ? LE_ERR_CAPACITY : le_decode_count(&s, chunk, cap);
    free(chunk);
    if (rc != LE_OK) {
      ma_decoder_uninit(&s.dec);
      return rc;
    }
  }
  float* src = NULL;
  float* plane[2] = {NULL, NULL};
  le_backing_buffer* b = NULL;
  int64_t frames = 0;

  /* How many source frames to read. A whole-file read is capped and refused
   * past the cap; a bounded read (a preview, a part) stops where asked. */
  int64_t want = cap + 1;
  if (!whole) {
    if (start_frame >= s.stated) {
      rc = LE_ERR_INVALID;
      goto done;
    }
    if (max_frames > 0) {
      /* Output frames at the engine rate, plus the converter's reach. */
      want = (int64_t)max_frames * s.rate / sample_rate + 512;
      if (want > cap) want = cap;
    }
    if (start_frame > 0 &&
        ma_decoder_seek_to_pcm_frame(&s.dec, (ma_uint64)start_frame) !=
            MA_SUCCESS) {
      rc = LE_ERR_INVALID;
      goto done;
    }
  } else if (s.stated > cap) {
    rc = LE_ERR_TOO_LONG;
    goto done;
  }
  /* One allocation for the source: the stated length when there is one, so
   * no growth copy ever doubles the peak. */
  int64_t size = want;
  if (s.stated - start_frame < size) size = s.stated - start_frame;
  const int64_t out_estimate =
      size * (int64_t)sample_rate / s.rate + 1;
  if (!le_mem_allows((size + out_estimate) * 2 * (int64_t)sizeof(float))) {
    rc = LE_ERR_CAPACITY;
    goto done;
  }
  src = (float*)malloc((size_t)size * (size_t)s.channels * sizeof(float));
  if (src == NULL) {
    rc = LE_ERR_CAPACITY;
    goto done;
  }
  frames = le_decode_read(&s, src, size);
  if (frames < 0) {
    rc = (int32_t)frames;
    goto done;
  }
  if (frames == 0) {
    rc = LE_ERR_INVALID;
    goto done;
  }
  if (whole) {
    if (frames > cap) {
      rc = LE_ERR_TOO_LONG;
      goto done;
    }
    /* A file that decodes to a different length than it states is damaged. */
    if (frames != s.stated) {
      rc = LE_ERR_INVALID;
      goto done;
    }
  } else if (info != NULL && s.stated > start_frame + frames) {
    info->truncated = 1;
  }
  if (info != NULL) info->source_frames = frames;

  int32_t rate = s.rate;
  const float* conv_in = src;
  int32_t conv_stride = s.channels;
  /* Exact halving while the reduction is below one half (a 192 kHz file on
   * a 48 kHz engine); this one path works on planes. */
  if ((int64_t)rate > 2 * (int64_t)sample_rate) {
    for (int c = 0; c < s.channels; ++c) {
      plane[c] = (float*)malloc((size_t)frames * sizeof(float));
      if (plane[c] == NULL) {
        rc = LE_ERR_CAPACITY;
        goto done;
      }
      for (int64_t f = 0; f < frames; ++f) {
        plane[c][f] = src[f * s.channels + c];
      }
    }
    free(src);
    src = NULL;
    while ((int64_t)rate > 2 * (int64_t)sample_rate) {
      if (rate % 2 != 0) {
        rc = LE_ERR_INVALID;
        goto done;
      }
      const int64_t half = (frames + 1) / 2;
      for (int c = 0; c < s.channels; ++c) {
        float* y = (float*)malloc((size_t)half * sizeof(float));
        if (y == NULL) {
          rc = LE_ERR_CAPACITY;
          goto done;
        }
        le_halfband_decimate(plane[c], (uint32_t)frames, y);
        free(plane[c]);
        plane[c] = y;
      }
      frames = half;
      rate /= 2;
    }
  }
  /* Convert the whole read straight into the interleaved output; a bounded
   * read (which read only what its output can reach) then keeps its first
   * max_frames. */
  const int64_t full = le_resample_frames(frames, rate, sample_rate);
  if (full <= 0 || full > INT32_MAX) {
    rc = full <= 0 ? LE_ERR_INVALID : LE_ERR_TOO_LONG;
    goto done;
  }
  const int64_t out_frames =
      max_frames > 0 && full > max_frames ? max_frames : full;
  b = (le_backing_buffer*)calloc(1, sizeof(*b));
  if (b != NULL) {
    b->pcm = (float*)malloc((size_t)full * 2u * sizeof(float));
  }
  if (b == NULL || b->pcm == NULL) {
    rc = LE_ERR_CAPACITY;
    goto done;
  }
  for (int side = 0; side < 2 && rc == LE_OK; ++side) {
    const int c = s.channels == 2 ? side : 0;
    const float* in = plane[0] != NULL ? plane[c] : conv_in + c;
    const int32_t stride = plane[0] != NULL ? 1 : conv_stride;
    rc = le_resample_offline(in, stride, (int32_t)frames, rate, b->pcm + side,
                             2, (int32_t)full, sample_rate);
  }
  if (rc == LE_OK) {
    b->frames = (int32_t)out_frames;
    b->sample_rate = sample_rate;
    *out = b;
    b = NULL;
  }
done:
  le_backing_buffer_free(b);
  free(src);
  free(plane[0]);
  free(plane[1]);
  ma_decoder_uninit(&s.dec);
  return rc;
}
