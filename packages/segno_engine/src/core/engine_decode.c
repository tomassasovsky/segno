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
 * audio. Mitigations, by layer:
 *   - a whitelist checked by our own header parse BEFORE miniaudio sees the
 *     file (see "the format whitelist" below): WAV PCM 16/24/32 and float32,
 *     plain or EXTENSIBLE, and MPEG Layer III; every chunk inside the file;
 *   - miniaudio opened on exactly that backend, through read and seek
 *     callbacks that refuse a seek outside the file and fail after a bounded
 *     amount of work, so no header can make it loop;
 *   - compiled out: FLAC (CVE-2024-41147, unfixed in the vendored 0.11.21)
 *     and MPEG Layer I/II (MA_DR_MP3_ONLY_MP3); the WAV metadata parser is
 *     never asked for, so CVE-2026-32837 (BEXT) is unreachable;
 *   - every rate, channel count and length is range-checked before it sizes
 *     anything; a decode error mid-stream and a non-finite sample are
 *     refusals;
 *   - a fuzz driver (src/test/fuzz_backing_decode.c) mutating whole files
 *     over every accepted and refused variant runs under ASan and UBSan.
 * A file is decoded once at import (the probe); later decodes read the
 * managed internal copy that already passed.
 */
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>
#if defined(_WIN32)
#include <windows.h>
#endif
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"
#include "engine_private.h"
#include "miniaudio.h"
#include "restore_halfband.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Accepted source rates (P2 review M2: 192 kHz bounds a decode's peak). */
#define LE_DECODE_MIN_RATE 8000
#define LE_DECODE_MAX_RATE 192000
/* Decoded float bytes per file byte, at most: an 8 kbit/s MP3 at 48 kHz
 * stereo expands 384x. A stated length beyond what the file could hold at
 * this ratio is a lie, refused before it sizes an allocation. */
#define LE_DECODE_MAX_EXPANSION 512

static int64_t le_file_bytes(const char* path) {
#if defined(_WIN32)
  struct _stat64 st;
  return _stat64(path, &st) == 0 ? (int64_t)st.st_size : -1;
#else
  /* A regular file only: a FIFO or a device would block a read for ever. */
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode) ? (int64_t)st.st_size
                                                     : -1;
#endif
}

#ifdef LE_NATIVE_TESTS
int64_t (*le_test_mem_available_hook)(void) = NULL;
int64_t le_test_decode_budget = 0;
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
 * (beta 10.06, about 100 dB of stop band for this stage; the half-band
 * halving ahead of it stops at -78 dB) of half-width H = ceil(32 / r)
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

/* Converts [out_frames] outputs starting at index [out_first] of the output
 * grid, from [in_frames] inputs whose first is frame [in_origin] of the
 * source (both grids start together at frame 0). The whole-file case is
 * in_origin 0, out_first 0; a bounded read passes where it started, so it
 * computes exactly the samples the whole-file conversion would. */
static int32_t le_resample_span(const float* in, int32_t in_stride,
                                int64_t in_frames, int32_t in_rate,
                                int64_t in_origin, float* out,
                                int32_t out_stride, int64_t out_first,
                                int64_t out_frames, int32_t out_rate) {
  if (in_rate == out_rate) {
    for (int64_t t = 0; t < out_frames; ++t) {
      const int64_t i = out_first + t - in_origin;
      out[(size_t)t * out_stride] =
          i >= 0 && i < in_frames ? in[(size_t)i * in_stride] : 0.0f;
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
  for (int64_t t = 0; t < out_frames; ++t) {
    const int64_t num = (out_first + t) * (int64_t)in_rate;
    const int64_t i = num / out_rate - in_origin;
    const float* row = table + ((num % out_rate) / g) * taps;
    const int64_t first = i - half + 1;
    double acc = 0.0;
    int64_t j0 = 0, j1 = taps;
    if (first < 0) j0 = -first;
    if (first + taps > in_frames) j1 = in_frames - first;
    for (int64_t j = j0; j < j1; ++j) {
      acc += (double)in[(size_t)(first + j) * in_stride] * row[j];
    }
    out[(size_t)t * out_stride] = (float)acc;
  }
  free(table);
  return LE_OK;
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
  return le_resample_span(in, in_stride, in_frames, in_rate, 0, out,
                          out_stride, 0, out_frames, out_rate);
}

/* ---- the format whitelist: our own header parse, before miniaudio ----
 *
 * Only these reach a miniaudio decoder (P2 review H1, H2, M1):
 *   - RIFF/WAVE with one `fmt ` chunk of format 1 (PCM, 16/24/32-bit) or 3
 *     (IEEE float, 32-bit), plain or WAVE_FORMAT_EXTENSIBLE with the PCM or
 *     float subformat; 1 or 2 channels; a block align that matches; every
 *     chunk up to `data` inside the file; a `fact` chunk of at least 4 bytes;
 *   - MPEG-1/2/2.5 Layer III, after any ID3v2 tags, whose first frame header
 *     is followed by a second consistent one (or the end of the file).
 * Everything else is refused before a decoder sees it: LE_ERR_UNSUPPORTED
 * for a format outside the list (8-bit or 64-bit WAV, ADPCM, mu-law,
 * A-law, RIFX, RF64, BW64, Wave64, AIFF, FLAC, Ogg, MPEG Layer I/II, more
 * than two channels, a rate outside 8-192 kHz or one the converter cannot
 * reach from every engine rate), LE_ERR_INVALID for a file that claims to
 * be in the list but is inconsistent. miniaudio is then opened on exactly
 * that backend (no fallback across decoders), through read and seek
 * callbacks that refuse a seek outside the file and stop after a bounded
 * amount of work, so no header can make a decoder loop for ever. */

#define LE_DECODE_MAX_CHUNKS 1024
#define LE_DECODE_MAX_ID3_TAGS 4
#define LE_DECODE_MAX_LEAD 65536

typedef enum le_file_kind {
  LE_FILE_WAV = 1,
  LE_FILE_MP3 = 2,
} le_file_kind;

typedef struct le_io {
  FILE* f;
  int64_t size;   /* file bytes */
  int64_t base;   /* where the stream miniaudio sees starts (after ID3v2) */
  int64_t pos;    /* position relative to base */
  int64_t work;   /* bytes read plus a fixed cost per seek */
  int64_t budget; /* work allowed before every read and seek fails */
} le_io;

typedef struct le_decode_src {
  le_io io;
  ma_decoder dec;
  int dec_open;
  le_file_kind kind;
  int32_t rate, channels;
  int64_t stated; /* 0 when the format does not state a length */
} le_decode_src;

static uint16_t le_rd16(const uint8_t* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t le_rd32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static int le_io_seek_abs(le_io* io, int64_t at) {
#if defined(_WIN32)
  return _fseeki64(io->f, (__int64)at, SEEK_SET) == 0;
#else
  return fseeko(io->f, (off_t)at, SEEK_SET) == 0;
#endif
}

/* Reads exactly [n] bytes at absolute offset [at]; 0 when the file is
 * shorter. For the header parse only. */
static int le_io_peek(le_io* io, int64_t at, void* out, size_t n) {
  if (at < 0 || at > io->size || (int64_t)n > io->size - at) return 0;
  return le_io_seek_abs(io, at) && fread(out, 1, n, io->f) == n;
}

static int le_decode_rate_pair_ok(int64_t in, int64_t out);

/* Rates a whole source can be decoded at: every one an engine may run. */
static const int32_t k_le_engine_rates[] = {44100, 48000, 88200, 96000};

/* A source rate in range that converts to every engine rate. */
static int le_decode_rate_ok(int64_t rate) {
  if (rate < LE_DECODE_MIN_RATE || rate > LE_DECODE_MAX_RATE) return 0;
  for (size_t i = 0;
       i < sizeof(k_le_engine_rates) / sizeof(k_le_engine_rates[0]); ++i) {
    if (!le_decode_rate_pair_ok(rate, k_le_engine_rates[i])) return 0;
  }
  return 1;
}

/* KSDATAFORMAT_SUBTYPE_* after the 16-bit format tag. */
static const uint8_t k_le_ks_guid_tail[14] = {0x00, 0x00, 0x00, 0x00, 0x10,
                                              0x00, 0x80, 0x00, 0x00, 0xAA,
                                              0x00, 0x38, 0x9B, 0x71};

static int32_t le_wav_check(le_io* io, int32_t* rate, int32_t* channels) {
  uint8_t h[12];
  if (!le_io_peek(io, 0, h, sizeof(h))) return LE_ERR_INVALID;
  if (memcmp(h + 8, "WAVE", 4) != 0) return LE_ERR_INVALID;
  int have_fmt = 0;
  int32_t align = 0;
  int64_t pos = 12;
  for (int chunks = 0; pos + 8 <= io->size; ++chunks) {
    if (chunks >= LE_DECODE_MAX_CHUNKS) return LE_ERR_INVALID;
    uint8_t ch[8];
    if (!le_io_peek(io, pos, ch, sizeof(ch))) return LE_ERR_INVALID;
    const int64_t size = le_rd32(ch + 4);
    pos += 8;
    /* A chunk is never bigger than what is left of the file (H2). */
    if (size > io->size - pos) return LE_ERR_INVALID;
    if (memcmp(ch, "fmt ", 4) == 0) {
      if (have_fmt || size < 16) return LE_ERR_INVALID;
      uint8_t f[40] = {0};
      if (!le_io_peek(io, pos, f, (size_t)(size < 40 ? size : 40))) {
        return LE_ERR_INVALID;
      }
      uint16_t tag = le_rd16(f);
      const int32_t nch = le_rd16(f + 2);
      const int64_t sr = le_rd32(f + 4);
      const int32_t block = le_rd16(f + 12);
      const int32_t bits = le_rd16(f + 14);
      if (tag == 0xFFFE) {
        if (size < 40 || le_rd16(f + 16) < 22) return LE_ERR_INVALID;
        const int32_t valid = le_rd16(f + 18);
        if (valid > bits) return LE_ERR_INVALID;
        if (memcmp(f + 26, k_le_ks_guid_tail, sizeof(k_le_ks_guid_tail)) !=
            0) {
          return LE_ERR_UNSUPPORTED;
        }
        tag = le_rd16(f + 24);
      }
      const int pcm = tag == 1 && (bits == 16 || bits == 24 || bits == 32);
      const int flt = tag == 3 && bits == 32;
      if (!pcm && !flt) return LE_ERR_UNSUPPORTED;
      if (nch < 1 || nch > 2 || !le_decode_rate_ok(sr)) {
        return LE_ERR_UNSUPPORTED;
      }
      if (block != nch * bits / 8) return LE_ERR_INVALID;
      have_fmt = 1;
      align = block;
      *rate = (int32_t)sr;
      *channels = nch;
    } else if (memcmp(ch, "fact", 4) == 0) {
      /* miniaudio's dr_wav reads four bytes of it and underflows the rest of
       * a shorter one into an endless seek (H2). */
      if (size < 4) return LE_ERR_INVALID;
    } else if (memcmp(ch, "data", 4) == 0) {
      /* dr_wav stops at the first data chunk; so does this check. */
      if (!have_fmt || size < align) return LE_ERR_INVALID;
      return LE_OK;
    }
    pos += size + (size & 1);
  }
  return LE_ERR_INVALID; /* no fmt or no data chunk */
}

/* An MPEG audio frame header's length in bytes, or 0 when [h] is not a
 * Layer III header (*layer gets the layer bits for any synced header). */
static int32_t le_mp3_frame_bytes(const uint8_t* h, int* layer, int* version,
                                  int* rate_index) {
  static const int16_t k_mpeg1[15] = {0,   32,  40,  48,  56,  64,  80, 96,
                                      112, 128, 160, 192, 224, 256, 320};
  static const int16_t k_mpeg2[15] = {0,  8,  16, 24,  32,  40,  48, 56,
                                      64, 80, 96, 112, 128, 144, 160};
  static const int32_t k_rates[3] = {44100, 48000, 32000};
  *layer = 0;
  if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0) return 0;
  const int ver = (h[1] >> 3) & 3; /* 0: 2.5, 2: 2, 3: 1 */
  *layer = (h[1] >> 1) & 3;        /* 1: Layer III, 2: II, 3: I */
  const int bitrate = h[2] >> 4;
  const int sr = (h[2] >> 2) & 3;
  if (ver == 1 || *layer == 0 || bitrate == 15 || sr == 3) {
    *layer = 0;
    return 0;
  }
  *version = ver;
  *rate_index = sr;
  if (*layer != 1 || bitrate == 0) return 0; /* not III, or free format */
  int32_t rate = k_rates[sr];
  if (ver == 2) rate /= 2;
  if (ver == 0) rate /= 4;
  const int32_t kbps = ver == 3 ? k_mpeg1[bitrate] : k_mpeg2[bitrate];
  const int32_t per = ver == 3 ? 144 : 72;
  return per * kbps * 1000 / rate + ((h[2] >> 1) & 1);
}

static int32_t le_mp3_check(le_io* io) {
  int64_t pos = 0;
  for (int tags = 0;; ++tags) {
    uint8_t t[10];
    if (!le_io_peek(io, pos, t, sizeof(t)) || memcmp(t, "ID3", 3) != 0) break;
    if (tags >= LE_DECODE_MAX_ID3_TAGS) return LE_ERR_INVALID;
    if ((t[6] | t[7] | t[8] | t[9]) & 0x80) return LE_ERR_INVALID;
    const int64_t body = ((int64_t)t[6] << 21) | ((int64_t)t[7] << 14) |
                         ((int64_t)t[8] << 7) | (int64_t)t[9];
    pos += 10 + body + ((t[5] & 0x10) ? 10 : 0);
    if (pos >= io->size) return LE_ERR_INVALID;
  }
  /* The first Layer III header followed by a consistent second one (or the
   * end of the file), within the first LE_DECODE_MAX_LEAD bytes: encoders
   * pad a tag beyond its stated size. Anything else is not an MP3. */
  int64_t window = io->size - pos;
  if (window > LE_DECODE_MAX_LEAD + 4) window = LE_DECODE_MAX_LEAD + 4;
  if (window < 4) return LE_ERR_UNSUPPORTED;
  uint8_t* w = (uint8_t*)malloc((size_t)window);
  if (w == NULL) return LE_ERR_CAPACITY;
  int32_t rc = LE_ERR_UNSUPPORTED;
  if (le_io_peek(io, pos, w, (size_t)window)) {
    for (int64_t at = 0; at + 4 <= window; ++at) {
      int layer = 0, ver = 0, sr = 0;
      const int32_t bytes = le_mp3_frame_bytes(w + at, &layer, &ver, &sr);
      if (bytes <= 0) continue;
      const int64_t next = pos + at + bytes;
      if (next + 4 > io->size) {
        io->base = pos + at;
        rc = LE_OK;
        break;
      }
      uint8_t n[4];
      int layer2 = 0, ver2 = 0, sr2 = 0;
      if (le_io_peek(io, next, n, sizeof(n)) &&
          le_mp3_frame_bytes(n, &layer2, &ver2, &sr2) > 0 && ver2 == ver &&
          sr2 == sr) {
        io->base = pos + at;
        rc = LE_OK;
        break;
      }
    }
  }
  free(w);
  /* An ID3v1 tag ends the stream 128 bytes early: the decoder's frame sync
   * otherwise takes its "TAG" for a broken frame and refuses a short file
   * outright (review L4). */
  uint8_t tag[3];
  if (rc == LE_OK && io->size - io->base >= 128 &&
      le_io_peek(io, io->size - 128, tag, sizeof(tag)) &&
      memcmp(tag, "TAG", 3) == 0) {
    io->size -= 128;
  }
  return rc;
}

/* ---- bounded I/O for miniaudio ---- */

#define LE_DECODE_SEEK_COST 4096

static ma_result le_io_read(ma_decoder* d, void* out, size_t n, size_t* got) {
  le_io* io = (le_io*)d->pUserData;
  if (got != NULL) *got = 0;
  const int64_t left = io->size - io->base - io->pos;
  if (left <= 0) return MA_AT_END;
  if ((int64_t)n > left) n = (size_t)left;
  io->work += (int64_t)n;
  if (io->work > io->budget) return MA_IO_ERROR;
  const size_t r = fread(out, 1, n, io->f);
  io->pos += (int64_t)r;
  if (got != NULL) *got = r;
  if (r < n && ferror(io->f)) return MA_IO_ERROR;
  return r == 0 ? MA_AT_END : MA_SUCCESS;
}

/* Never outside the stream: a seek past its end fails instead of succeeding
 * on a regular file, which is what let a crafted chunk size loop (H2). */
static ma_result le_io_seek(ma_decoder* d, ma_int64 offset,
                            ma_seek_origin origin) {
  le_io* io = (le_io*)d->pUserData;
  const int64_t length = io->size - io->base;
  int64_t to = offset;
  if (origin == ma_seek_origin_current) to = io->pos + offset;
  if (origin == ma_seek_origin_end) to = length + offset;
  if (to < 0 || to > length) return MA_BAD_SEEK;
  io->work += LE_DECODE_SEEK_COST;
  if (io->work > io->budget) return MA_IO_ERROR;
  if (!le_io_seek_abs(io, io->base + to)) return MA_BAD_SEEK;
  io->pos = to;
  return MA_SUCCESS;
}

static FILE* le_open_read(const char* path) {
#if defined(_WIN32)
  wchar_t wide[1024];
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide,
                          (int)(sizeof(wide) / sizeof(wide[0]))) <= 0) {
    return NULL;
  }
  return _wfopen(wide, L"rb");
#else
  return fopen(path, "rb");
#endif
}

static void le_decode_close(le_decode_src* s) {
  if (s->dec_open) ma_decoder_uninit(&s->dec);
  s->dec_open = 0;
  if (s->io.f != NULL) fclose(s->io.f);
  s->io.f = NULL;
}

/* Opens [path]: our own header check first, then miniaudio on exactly that
 * backend through the bounded callbacks. */
static int32_t le_decode_open(const char* path, le_decode_src* s) {
  memset(s, 0, sizeof(*s));
  if (path == NULL || path[0] == '\0') return LE_ERR_INVALID;
  const int64_t bytes = le_file_bytes(path);
  if (bytes <= 0) return LE_ERR_INVALID; /* missing, empty or not regular */
  s->io.f = le_open_read(path);
  if (s->io.f == NULL) return LE_ERR_INVALID;
  s->io.size = bytes;
  uint8_t magic[4] = {0};
  int32_t rc = LE_ERR_UNSUPPORTED;
  int32_t rate = 0, channels = 0;
  if (!le_io_peek(&s->io, 0, magic, sizeof(magic))) {
    rc = LE_ERR_INVALID;
  } else if (memcmp(magic, "RIFF", 4) == 0) {
    s->kind = LE_FILE_WAV;
    rc = le_wav_check(&s->io, &rate, &channels);
  } else {
    s->kind = LE_FILE_MP3;
    rc = le_mp3_check(&s->io);
  }
  if (rc != LE_OK) {
    le_decode_close(s);
    return rc;
  }
  /* Each pass over the file (the header, a length scan, the decode, a
   * rewind) reads it about once: eight passes is generous for a real file
   * and finite for a crafted one. */
  s->io.budget = 8 * (s->io.size - s->io.base) + 64ll * 1024 * 1024;
#ifdef LE_NATIVE_TESTS
  if (le_test_decode_budget > 0) s->io.budget = le_test_decode_budget;
#endif
  if (!le_io_seek_abs(&s->io, s->io.base)) {
    le_decode_close(s);
    return LE_ERR_INVALID;
  }
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
  cfg.encodingFormat =
      s->kind == LE_FILE_WAV ? ma_encoding_format_wav : ma_encoding_format_mp3;
  if (ma_decoder_init(le_io_read, le_io_seek, &s->io, &cfg, &s->dec) !=
      MA_SUCCESS) {
    le_decode_close(s);
    return LE_ERR_INVALID;
  }
  s->dec_open = 1;
  s->rate = (int32_t)s->dec.outputSampleRate;
  s->channels = (int32_t)s->dec.outputChannels;
  ma_uint64 stated = 0;
  if (ma_decoder_get_length_in_pcm_frames(&s->dec, &stated) != MA_SUCCESS) {
    stated = 0;
  }
  s->stated = stated > (ma_uint64)INT64_MAX ? INT64_MAX : (int64_t)stated;
  /* What miniaudio reports must agree with the header check (a WAV), and be
   * in range whatever the format (an MP3 states no rate up front). */
  if (s->channels < 1 || s->channels > 2 || !le_decode_rate_ok(s->rate) ||
      s->dec.outputFormat != ma_format_f32 ||
      (s->kind == LE_FILE_WAV &&
       (s->rate != rate || s->channels != channels)) ||
      s->stated > bytes * LE_DECODE_MAX_EXPANSION /
                      ((int64_t)s->channels * (int64_t)sizeof(float))) {
    rc = s->channels > 2 || !le_decode_rate_ok(s->rate) ? LE_ERR_UNSUPPORTED
                                                        : LE_ERR_INVALID;
    le_decode_close(s);
    return rc;
  }
  return LE_OK;
}

/* The largest sample magnitude a decode accepts: 60 dB over full scale. A
 * float WAV can hold any finite value, and one near FLT_MAX overflows the
 * converter's sum to Inf, so anything this far out is damaged, not loud. */
#define LE_DECODE_MAX_ABS 1024.0f

/* Reads up to [want] frames into [buf] (interleaved, the source's channels).
 * Returns the frames read, or a negative le_result on a decode error or a
 * sample that is non-finite or beyond LE_DECODE_MAX_ABS (H3: one NaN would
 * poison the output-bus FX for good). A short read is the end of the
 * stream. */
static int64_t le_decode_read(le_decode_src* s, float* buf, int64_t want) {
  int64_t got = 0;
  while (got < want) {
    ma_uint64 read = 0;
    float* at = buf + (size_t)got * (size_t)s->channels;
    const ma_result r = ma_decoder_read_pcm_frames(
        &s->dec, at, (ma_uint64)(want - got), &read);
    const size_t n = (size_t)read * (size_t)s->channels;
    for (size_t i = 0; i < n; ++i) {
      /* Written so a NaN fails it too. */
      if (!(fabsf(at[i]) <= LE_DECODE_MAX_ABS)) return LE_ERR_INVALID;
    }
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
  le_decode_close(&s);
  return rc;
}

/* ---- the full decode ---- */

/* Exact 2:1 halvings before the converter, for a reduction below one half. */
static int le_decode_halvings(int64_t in, int64_t out) {
  int k = 0;
  while (in > 2 * out) {
    in /= 2;
    ++k;
  }
  return k;
}

/* Whether [in] Hz converts to [out] Hz: even rates through every halving,
 * then at most LE_RS_MAX_PHASES converter phases (P2 review L1). */
static int le_decode_rate_pair_ok(int64_t in, int64_t out) {
  if (in <= 0 || out <= 0) return 0;
  while (in > 2 * out) {
    if (in % 2 != 0) return 0;
    in /= 2;
  }
  return in == out || out / le_rs_gcd(in, out) <= LE_RS_MAX_PHASES;
}

/* Source frames read either side of a bounded read, per halving level: the
 * converter (64 taps a side at most) and each half-band stage (29) reach no
 * further, so a bounded read equals the whole-file decode sample for sample
 * (P2 review L2). */
#define LE_DECODE_MARGIN 256

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
  float* src = NULL;
  float* plane[2] = {NULL, NULL};
  float* chunk = NULL;
  le_backing_buffer* b = NULL;
  const int ch = s.channels;
  if (!le_decode_rate_pair_ok(s.rate, sample_rate)) {
    rc = LE_ERR_UNSUPPORTED;
    goto done;
  }
  const int64_t cap = (int64_t)LE_BACKING_MAX_SECONDS * s.rate;
  const int whole = start_frame == 0 && max_frames == 0;
  if (s.stated == 0) {
    chunk = (float*)malloc(sizeof(float) * LE_DECODE_CHUNK * 2);
    rc = chunk == NULL ? LE_ERR_CAPACITY : le_decode_count(&s, chunk, cap);
    if (rc != LE_OK) goto done;
  }
  const int k = le_decode_halvings(s.rate, sample_rate);
  const int64_t margin = (int64_t)LE_DECODE_MARGIN << k;
  if (whole && s.stated > cap) {
    rc = LE_ERR_TOO_LONG;
    goto done;
  }
  if (!whole && start_frame >= s.stated) {
    rc = LE_ERR_INVALID;
    goto done;
  }
  /* The source span to read, [from, end): the whole file, or a bounded read
   * with the converter's reach either side (from a multiple of 2^k, so the
   * halvings line up with the whole file's). A bounded read never reads
   * more than the cap. */
  int64_t from = 0, end = s.stated;
  if (!whole) {
    from = start_frame - margin;
    if (from < 0) from = 0;
    from &= ~(((int64_t)1 << k) - 1);
    if (max_frames > 0) {
      /* Two output frames' worth of slack over the exact span. */
      const int64_t per = ((int64_t)s.rate + sample_rate - 1) / sample_rate;
      const int64_t reach =
          start_frame +
          ((int64_t)max_frames * s.rate + sample_rate - 1) / sample_rate +
          2 * per + margin;
      if (reach < end) end = reach;
    }
    if (end - from > cap + 2 * margin) end = from + cap + 2 * margin;
  }
  const int64_t size = end - from;
  /* The decode's peak, checked before anything is allocated (M2): the
   * source (interleaved, or the planes it is read into for halving) plus the
   * larger of one channel's first halving and the stereo output. */
  const int64_t out_estimate = size * (int64_t)sample_rate / s.rate + 1;
  int64_t peak = size * ch + 2 * out_estimate;
  if (k > 0 && size * ch + size / 2 + 1 > peak) peak = size * ch + size / 2 + 1;
  if (!le_mem_allows(peak * (int64_t)sizeof(float))) {
    rc = LE_ERR_CAPACITY;
    goto done;
  }
  if (from > 0 &&
      ma_decoder_seek_to_pcm_frame(&s.dec, (ma_uint64)from) != MA_SUCCESS) {
    rc = LE_ERR_INVALID;
    goto done;
  }
  int64_t frames = 0;
  if (k == 0) {
    src = (float*)malloc((size_t)size * (size_t)ch * sizeof(float));
    if (src == NULL) {
      rc = LE_ERR_CAPACITY;
      goto done;
    }
    frames = le_decode_read(&s, src, size);
  } else {
    /* Halving works on planes: read straight into them, a chunk at a time,
     * so the interleaved source never exists beside them. */
    if (chunk == NULL) chunk = (float*)malloc(sizeof(float) * LE_DECODE_CHUNK * 2);
    for (int c = 0; c < ch; ++c) {
      plane[c] = (float*)malloc((size_t)size * sizeof(float));
    }
    if (chunk == NULL || plane[0] == NULL || (ch == 2 && plane[1] == NULL)) {
      rc = LE_ERR_CAPACITY;
      goto done;
    }
    while (frames < size) {
      int64_t want = size - frames;
      if (want > LE_DECODE_CHUNK) want = LE_DECODE_CHUNK;
      const int64_t n = le_decode_read(&s, chunk, want);
      if (n < 0) {
        frames = n;
        break;
      }
      for (int64_t f = 0; f < n; ++f) {
        for (int c = 0; c < ch; ++c) plane[c][frames + f] = chunk[f * ch + c];
      }
      frames += n;
      if (n < want) break;
    }
  }
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
  }
  if (info != NULL) info->source_frames = frames;

  /* Exact halvings (a 192 kHz file on a 48 kHz engine). */
  int32_t rate = s.rate;
  for (int h = 0; h < k; ++h) {
    const int64_t half = (frames + 1) / 2;
    for (int c = 0; c < ch; ++c) {
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
  /* Output on the whole file's grid: the whole file's length there, and the
   * first output at or after start_frame. */
  int64_t whole_frames = s.stated;
  for (int h = 0; h < k; ++h) whole_frames = (whole_frames + 1) / 2;
  const int64_t grid = le_resample_frames(whole_frames, rate, sample_rate);
  const int64_t first =
      ((int64_t)start_frame * sample_rate + s.rate - 1) / s.rate;
  int64_t count = grid - first;
  if (max_frames > 0 && count > max_frames) count = max_frames;
  if (end < s.stated) {
    /* A read clipped short of the file keeps only what it fully reaches. */
    const int64_t reached = (end - margin) * sample_rate / s.rate;
    if (first + count > reached) count = reached - first;
  }
  /* A bounded read can start where no output frame of the whole file's
   * grid begins (the last source frame of a reduction): that is an empty
   * read, not a damaged file (review of #1223, L5). */
  if (count < 0 || (count == 0 && whole)) {
    rc = LE_ERR_INVALID;
    goto done;
  }
  if (count < 0) count = 0;
  if (count > INT32_MAX) {
    rc = LE_ERR_TOO_LONG;
    goto done;
  }
  if (info != NULL && !whole && first + count < grid) info->truncated = 1;
  b = (le_backing_buffer*)calloc(1, sizeof(*b));
  if (b != NULL) {
    b->pcm = (float*)malloc((size_t)(count > 0 ? count : 1) * 2u * sizeof(float));
  }
  if (b == NULL || b->pcm == NULL) {
    rc = LE_ERR_CAPACITY;
    goto done;
  }
  for (int side = 0; side < 2 && rc == LE_OK && count > 0; ++side) {
    const int c = ch == 2 ? side : 0;
    const float* in = k > 0 ? plane[c] : src + c;
    const int32_t stride = k > 0 ? 1 : ch;
    rc = le_resample_span(in, stride, frames, rate, from >> k, b->pcm + side,
                          2, first, count, sample_rate);
  }
  if (rc == LE_OK) {
    b->frames = (int32_t)count;
    b->sample_rate = sample_rate;
    *out = b;
    b = NULL;
  }
done:
  le_backing_buffer_free(b);
  free(src);
  free(chunk);
  free(plane[0]);
  free(plane[1]);
  le_decode_close(&s);
  return rc;
}
