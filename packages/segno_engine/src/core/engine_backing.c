/*
 * engine_backing.c — the backing player's buffers and control-thread API
 * (#1200). The contract is in segno_engine_api.h; the voice itself (the
 * command handlers and the per-frame read) is in engine_process.c, the
 * audio-thread translation unit.
 *
 * Ownership. A buffer is the caller's until le_engine_backing_load or
 * le_engine_backing_stage_next accepts it. From then on it is listed in
 * engine->backing_owned until the control thread frees it, which happens in
 * exactly two ways:
 *   - the callback stores it in an a_backing_dead slot once it will never
 *     read it again, and le_backing_collect frees it;
 *   - le_backing_release frees it with the callback stopped (configure,
 *     reopen, destroy): a buffer still queued in the command ring (which
 *     configure and reopen re-initialise) is freed here too.
 * The audio thread never allocates or frees.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h"
#include "engine_private.h"
#include "miniaudio.h"
#include "restore_halfband.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int32_t le_backing_buffer_from_pcm(const float* interleaved, int32_t frames,
                                   int32_t channels, int32_t sample_rate,
                                   le_backing_buffer** out) {
  if (out != NULL) *out = NULL;
  if (interleaved == NULL || out == NULL || frames <= 0 || channels < 1 ||
      channels > 2 || sample_rate <= 0) {
    return LE_ERR_INVALID;
  }
  const size_t n = (size_t)frames * (size_t)channels;
  for (size_t i = 0; i < n; ++i) {
    if (!isfinite(interleaved[i])) return LE_ERR_INVALID;
  }
  le_backing_buffer* b = (le_backing_buffer*)calloc(1, sizeof(*b));
  if (b == NULL) return LE_ERR_CAPACITY;
  b->pcm = (float*)malloc((size_t)frames * 2u * sizeof(float));
  if (b->pcm == NULL) {
    free(b);
    return LE_ERR_CAPACITY;
  }
  if (channels == 2) {
    memcpy(b->pcm, interleaved, (size_t)frames * 2u * sizeof(float));
  } else {
    for (int32_t f = 0; f < frames; ++f) {
      b->pcm[2 * f] = interleaved[f];
      b->pcm[2 * f + 1] = interleaved[f];
    }
  }
  b->frames = frames;
  b->sample_rate = sample_rate;
  *out = b;
  return LE_OK;
}

/* ---- offline sample-rate conversion (#1200 Part 2) ----
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
 * low-order low-pass; the vendored Signalsmith KaiserSincN kernel is built
 * for full-band interpolation (it forces exact zeros at integer offsets,
 * which is only right when the cutoff is the input Nyquist), so it cannot
 * band-limit a reduction; the pitch/time read head is a two-tap varispeed. */

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

int32_t le_resample_offline(const float* const* in, int32_t in_frames,
                            int32_t channels, int32_t in_rate,
                            float* const* out, int32_t out_frames,
                            int32_t out_rate) {
  if (in == NULL || out == NULL || in_frames <= 0 || channels <= 0 ||
      in_rate <= 0 || out_rate <= 0 ||
      (int64_t)out_rate * 2 < (int64_t)in_rate ||
      out_frames != le_resample_frames(in_frames, in_rate, out_rate)) {
    return LE_ERR_INVALID;
  }
  for (int32_t c = 0; c < channels; ++c) {
    if (in[c] == NULL || out[c] == NULL) return LE_ERR_INVALID;
  }
  if (in_rate == out_rate) {
    for (int32_t c = 0; c < channels; ++c) {
      memcpy(out[c], in[c], (size_t)in_frames * sizeof(float));
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
  for (int32_t c = 0; c < channels; ++c) {
    const float* x = in[c];
    for (int32_t t = 0; t < out_frames; ++t) {
      const int64_t num = (int64_t)t * in_rate;
      const int64_t i = num / out_rate;
      const float* row = table + ((num % out_rate) / g) * taps;
      const int64_t first = i - half + 1;
      double acc = 0.0;
      int32_t j0 = 0, j1 = taps;
      if (first < 0) j0 = (int32_t)-first;
      if (first + taps > in_frames) j1 = (int32_t)(in_frames - first);
      for (int32_t j = j0; j < j1; ++j) acc += (double)x[first + j] * row[j];
      out[c][t] = (float)acc;
    }
  }
  free(table);
  return LE_OK;
}

/* ---- decoding (#1200 Part 2) ---- */

/* Reads the whole file into interleaved float32 at its own rate and channel
 * count. Refuses more than two channels, and anything over the cap: from the
 * stated length before reading when the format states one, else as soon as
 * the read passes the cap (never holding more than cap + 1 frames). */
static int32_t le_backing_read_file(const char* path, float** pcm,
                                    int64_t* frames, int32_t* rate,
                                    int32_t* channels) {
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
  ma_decoder dec;
  if (ma_decoder_init_file(path, &cfg, &dec) != MA_SUCCESS) {
    return LE_ERR_INVALID;
  }
  int32_t rc = LE_OK;
  float* buf = NULL;
  int64_t got = 0;
  const int32_t ch = (int32_t)dec.outputChannels;
  const int32_t sr = (int32_t)dec.outputSampleRate;
  const int64_t cap = (int64_t)LE_BACKING_MAX_SECONDS * (sr > 0 ? sr : 1);
  ma_uint64 stated = 0;
  int64_t size = 0;
  if (ch < 1 || ch > 2 || sr <= 0) {
    rc = LE_ERR_INVALID;
    goto done;
  }
  if (ma_decoder_get_length_in_pcm_frames(&dec, &stated) == MA_SUCCESS &&
      (int64_t)stated > cap) {
    rc = LE_ERR_TOO_LONG;
    goto done;
  }
  size = stated > 0 ? (int64_t)stated + 1 : (int64_t)sr * 30;
  for (;;) {
    if (buf == NULL || got == size) {
      if (buf != NULL) size *= 2;
      if (size > cap + 1) size = cap + 1;
      float* grown =
          (float*)realloc(buf, (size_t)size * (size_t)ch * sizeof(float));
      if (grown == NULL) {
        rc = LE_ERR_CAPACITY;
        goto done;
      }
      buf = grown;
    }
    ma_uint64 read = 0;
    const ma_result r = ma_decoder_read_pcm_frames(
        &dec, buf + (size_t)got * (size_t)ch, (ma_uint64)(size - got), &read);
    got += (int64_t)read;
    if (got > cap) {
      rc = LE_ERR_TOO_LONG;
      goto done;
    }
    if (r == MA_AT_END || (r == MA_SUCCESS && read == 0)) break;
    if (r != MA_SUCCESS) {
      rc = LE_ERR_INVALID;
      goto done;
    }
  }
  if (got == 0) rc = LE_ERR_INVALID;
done:
  ma_decoder_uninit(&dec);
  if (rc != LE_OK) {
    free(buf);
    return rc;
  }
  *pcm = buf;
  *frames = got;
  *rate = sr;
  *channels = ch;
  return LE_OK;
}

/* Replaces each plane with its exact 2:1 half-band decimation. */
static int32_t le_backing_halve(float* plane[2], int ch, int64_t* frames) {
  const int64_t half = (*frames + 1) / 2;
  for (int c = 0; c < ch; ++c) {
    float* y = (float*)malloc((size_t)half * sizeof(float));
    if (y == NULL) return LE_ERR_CAPACITY;
    le_halfband_decimate(plane[c], (uint32_t)*frames, y);
    free(plane[c]);
    plane[c] = y;
  }
  *frames = half;
  return LE_OK;
}

/* Replaces each plane with its band-limited conversion to [to] Hz. */
static int32_t le_backing_convert(float* plane[2], int ch, int64_t* frames,
                                  int32_t from, int32_t to) {
  const int64_t n = le_resample_frames(*frames, from, to);
  if (n <= 0 || n > INT32_MAX) return LE_ERR_TOO_LONG;
  float* y[2] = {NULL, NULL};
  int32_t rc = LE_OK;
  for (int c = 0; c < ch && rc == LE_OK; ++c) {
    y[c] = (float*)malloc((size_t)n * sizeof(float));
    if (y[c] == NULL) rc = LE_ERR_CAPACITY;
  }
  if (rc == LE_OK) {
    const int32_t s = le_resample_offline((const float* const*)plane,
                                          (int32_t)*frames, ch, from, y,
                                          (int32_t)n, to);
    if (s != LE_OK) rc = s;
  }
  for (int c = 0; c < ch; ++c) {
    if (rc == LE_OK) {
      free(plane[c]);
      plane[c] = y[c];
    } else {
      free(y[c]);
    }
  }
  if (rc == LE_OK) *frames = n;
  return rc;
}

int32_t le_backing_decode_file(const char* path, int32_t sample_rate,
                               le_backing_buffer** out, int32_t* source_rate,
                               int32_t* source_channels) {
  if (out != NULL) *out = NULL;
  if (path == NULL || path[0] == '\0' || out == NULL || sample_rate <= 0) {
    return LE_ERR_INVALID;
  }
  float* pcm = NULL;
  int64_t frames = 0;
  int32_t rate = 0, ch = 0;
  int32_t rc = le_backing_read_file(path, &pcm, &frames, &rate, &ch);
  if (rc != LE_OK) return rc;
  if (source_rate != NULL) *source_rate = rate;
  if (source_channels != NULL) *source_channels = ch;

  /* Planar copies, one per side, that the conversion stages work on. */
  float* plane[2] = {NULL, NULL};
  for (int c = 0; c < ch && rc == LE_OK; ++c) {
    plane[c] = (float*)malloc((size_t)frames * sizeof(float));
    if (plane[c] == NULL) rc = LE_ERR_CAPACITY;
  }
  if (rc == LE_OK) {
    for (int64_t f = 0; f < frames; ++f) {
      for (int c = 0; c < ch; ++c) plane[c][f] = pcm[f * ch + c];
    }
  }
  free(pcm);
  /* Exact halving while the reduction is below one half (a 192 kHz file on
   * a 48 kHz engine), then one band-limited conversion. */
  while (rc == LE_OK && (int64_t)rate > 2 * (int64_t)sample_rate) {
    if (rate % 2 != 0) {
      rc = LE_ERR_INVALID;
    } else {
      rc = le_backing_halve(plane, ch, &frames);
      rate /= 2;
    }
  }
  if (rc == LE_OK && rate != sample_rate) {
    rc = le_backing_convert(plane, ch, &frames, rate, sample_rate);
  }
  if (rc == LE_OK && frames > INT32_MAX) rc = LE_ERR_TOO_LONG;
  le_backing_buffer* b = NULL;
  if (rc == LE_OK) {
    b = (le_backing_buffer*)calloc(1, sizeof(*b));
    if (b != NULL) {
      b->pcm = (float*)malloc((size_t)frames * 2u * sizeof(float));
    }
    if (b == NULL || b->pcm == NULL) {
      free(b);
      b = NULL;
      rc = LE_ERR_CAPACITY;
    }
  }
  if (rc == LE_OK) {
    const float* right = ch == 2 ? plane[1] : plane[0];
    for (int64_t f = 0; f < frames; ++f) {
      b->pcm[2 * f] = plane[0][f];
      b->pcm[2 * f + 1] = right[f];
    }
    b->frames = (int32_t)frames;
    b->sample_rate = sample_rate;
    *out = b;
  }
  free(plane[0]);
  free(plane[1]);
  return rc;
}

int32_t le_backing_buffer_frames(const le_backing_buffer* buffer) {
  return buffer == NULL ? 0 : buffer->frames;
}

int32_t le_backing_buffer_rate(const le_backing_buffer* buffer) {
  return buffer == NULL ? 0 : buffer->sample_rate;
}

int32_t le_backing_buffer_peaks(const le_backing_buffer* buffer, float* out,
                                int32_t buckets) {
  if (buffer == NULL || out == NULL || buckets <= 0) return LE_ERR_INVALID;
  for (int32_t k = 0; k < buckets; ++k) {
    const int64_t a = (int64_t)buffer->frames * k / buckets;
    const int64_t z = (int64_t)buffer->frames * (k + 1) / buckets;
    float peak = 0.0f;
    for (int64_t f = a; f < z; ++f) {
      const float l = fabsf(buffer->pcm[2 * f]);
      const float r = fabsf(buffer->pcm[2 * f + 1]);
      if (l > peak) peak = l;
      if (r > peak) peak = r;
    }
    out[k] = peak;
  }
  return buckets;
}

void le_backing_buffer_free(le_backing_buffer* buffer) {
  if (buffer == NULL) return;
  free(buffer->pcm);
  free(buffer);
}

/* ---- the control-thread registry ---- */

static int le_backing_owned_index(const le_engine* e,
                                  const le_backing_buffer* b) {
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    if (e->backing_owned[i] == b) return i;
  }
  return -1;
}

static int le_backing_owned_count(const le_engine* e) {
  int n = 0;
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    if (e->backing_owned[i] != NULL) ++n;
  }
  return n;
}

static int64_t le_backing_bytes(const le_backing_buffer* b) {
  return b == NULL ? 0 : (int64_t)b->frames * 2 * (int64_t)sizeof(float);
}

static int64_t le_backing_owned_bytes(const le_engine* e) {
  int64_t n = 0;
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    n += le_backing_bytes(e->backing_owned[i]);
  }
  return n;
}

/* Frees every buffer the callback has returned. Control thread. */
static void le_backing_collect(le_engine* e) {
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    le_backing_buffer* b = atomic_exchange_explicit(
        &e->a_backing_dead[i], (le_backing_buffer*)NULL, memory_order_acquire);
    if (b == NULL) continue;
    const int k = le_backing_owned_index(e, b);
    if (k >= 0) e->backing_owned[k] = NULL;
    le_backing_buffer_free(b);
  }
}

void le_backing_release(le_engine* e, int keep_loaded) {
  le_backing_collect(e);
  le_backing_buffer* keep_cur = keep_loaded ? e->backing_cur.buf : NULL;
  le_backing_buffer* keep_next = keep_loaded ? e->backing_next : NULL;
  for (int i = 0; i < LE_BACKING_MAX_BUFFERS; ++i) {
    le_backing_buffer* b = e->backing_owned[i];
    if (b == NULL || b == keep_cur || b == keep_next) continue;
    le_backing_buffer_free(b);
    e->backing_owned[i] = NULL;
  }
  e->backing_fade = (le_backing_voice){0};
  atomic_store_explicit(&e->a_backing_fade_owns, 0, memory_order_relaxed);
  /* The ring was re-initialised: nothing posted is still in it. */
  e->backing_posted =
      atomic_load_explicit(&e->a_backing_applied, memory_order_relaxed);
  e->backing_cur = (le_backing_voice){.buf = keep_cur};
  e->backing_next = keep_next;
  if (keep_cur == NULL) e->backing_item = -1;
  if (keep_next == NULL) e->backing_next_item = -1;
  e->backing_state = LE_BACKING_STOPPED;
  store_i32(&e->a_backing_item, e->backing_item);
  store_i32(&e->a_backing_next_item, e->backing_next_item);
  store_i32(&e->a_backing_transport, LE_BACKING_STOPPED);
  store_i32(&e->a_backing_position, 0);
  store_i32(&e->a_backing_frames, keep_cur != NULL ? keep_cur->frames : 0);
}

/* ---- the API ---- */

/* Registers [buffer] and posts it with [code]. */
static int32_t le_backing_post_buffer(le_engine* e, int32_t code,
                                      le_backing_buffer* buffer, int32_t item,
                                      int32_t play) {
  if (!atomic_load_explicit(&e->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (buffer != NULL && (buffer->sample_rate != e->sample_rate ||
                         le_backing_owned_index(e, buffer) >= 0)) {
    return LE_ERR_INVALID;
  }
  /* Read before collecting: a buffer the callback hands back after these
   * reads is collected below, so "nothing in transit" is never stale.
   * `applied` first: the callback sets `fade_owns` before its release
   * increment of `applied`, so a count that shows the post applied also
   * shows the fade that the post started (review of #1222, L5). */
  const int applied_all =
      atomic_load_explicit(&e->a_backing_applied, memory_order_acquire) ==
      e->backing_posted;
  const int fading =
      atomic_load_explicit(&e->a_backing_fade_owns, memory_order_acquire) != 0;
  const int in_transit = !applied_all || fading;
  le_backing_collect(e);
  int slot = -1;
  if (buffer != NULL) {
    slot = le_backing_owned_index(e, NULL);
    const int over_budget = le_backing_owned_bytes(e) + le_backing_bytes(buffer) >
                            LE_BACKING_BUDGET_BYTES;
    if (slot < 0 || over_budget) {
      return in_transit ? LE_ERR_NOT_READY : LE_ERR_CAPACITY;
    }
    e->backing_owned[slot] = buffer;
  }
  const int32_t rc = le_push_cmd(
      e, (le_command){.code = code, .backing = {buffer, item, play ? 1 : 0}});
  if (rc != LE_OK && slot >= 0) e->backing_owned[slot] = NULL;
  if (rc == LE_OK && buffer != NULL) e->backing_posted++;
  return rc;
}

int32_t le_engine_backing_load(le_engine* engine, le_backing_buffer* buffer,
                               int32_t item, int32_t play) {
  if (engine == NULL || buffer == NULL) return LE_ERR_INVALID;
  return le_backing_post_buffer(engine, LE_CMD_BACKING_LOAD, buffer, item,
                                play);
}

int32_t le_engine_backing_stage_next(le_engine* engine,
                                     le_backing_buffer* buffer, int32_t item) {
  if (engine == NULL) return LE_ERR_INVALID;
  return le_backing_post_buffer(engine, LE_CMD_BACKING_STAGE_NEXT, buffer,
                                buffer != NULL ? item : -1, 0);
}

int32_t le_engine_backing_clear(le_engine* engine) {
  return le_push(engine, LE_CMD_BACKING_CLEAR, 0, 0.0f);
}

int32_t le_engine_backing_transport(le_engine* engine, int32_t op) {
  if (op < LE_BACKING_OP_PLAY || op > LE_BACKING_OP_STOP) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_BACKING_TRANSPORT, op, 0.0f);
}

int32_t le_engine_backing_seek(le_engine* engine, int32_t frame) {
  return le_push(engine, LE_CMD_BACKING_SEEK, frame < 0 ? 0 : frame, 0.0f);
}

int32_t le_engine_backing_set_end(le_engine* engine, int32_t mode) {
  if (engine == NULL || mode < LE_BACKING_END_STOP ||
      mode > LE_BACKING_END_NEXT) {
    return LE_ERR_INVALID;
  }
  store_i32(&engine->a_backing_end_mode, mode);
  return LE_OK;
}

int32_t le_engine_backing_set_output(le_engine* engine, int32_t mask) {
  if (engine == NULL) return LE_ERR_INVALID;
  atomic_store_explicit(&engine->a_backing_mask, (uint32_t)mask,
                        memory_order_relaxed);
  return LE_OK;
}

int32_t le_engine_backing_set_level(le_engine* engine, float gain) {
  if (engine == NULL || isnan(gain)) return LE_ERR_INVALID;
  if (gain < 0.0f) gain = 0.0f;
  if (gain > LE_MAX_GAIN) gain = LE_MAX_GAIN;
  store_f32(&engine->a_backing_level_bits, gain);
  return LE_OK;
}

static int32_t le_store_pan(le_engine* engine, _Atomic uint32_t* slot,
                            float pan) {
  if (engine == NULL || isnan(pan)) return LE_ERR_INVALID;
  if (pan < -1.0f) pan = -1.0f;
  if (pan > 1.0f) pan = 1.0f;
  store_f32(slot, pan);
  return LE_OK;
}

int32_t le_engine_backing_set_pan(le_engine* engine, float pan) {
  return le_store_pan(engine, engine ? &engine->a_backing_pan_bits : NULL, pan);
}

int32_t le_engine_set_click_pan(le_engine* engine, float pan) {
  return le_store_pan(engine, engine ? &engine->a_click_pan_bits : NULL, pan);
}

int32_t le_engine_backing_state(le_engine* engine, le_backing_state* out) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  le_backing_collect(engine);
  out->epoch = atomic_load_explicit(&engine->a_backing_epoch,
                                    memory_order_acquire);
  out->item = load_i32(&engine->a_backing_item);
  out->next_item = load_i32(&engine->a_backing_next_item);
  out->transport = load_i32(&engine->a_backing_transport);
  out->position = load_i32(&engine->a_backing_position);
  out->frames = load_i32(&engine->a_backing_frames);
  out->end_count = atomic_load_explicit(&engine->a_backing_end_count,
                                        memory_order_relaxed);
  out->last_end = load_i32(&engine->a_backing_last_end);
  out->end_mode = load_i32(&engine->a_backing_end_mode);
  out->mask = atomic_load_explicit(&engine->a_backing_mask,
                                   memory_order_relaxed);
  out->level = load_f32(&engine->a_backing_level_bits);
  out->pan = load_f32(&engine->a_backing_pan_bits);
  out->click_pan = load_f32(&engine->a_click_pan_bits);
  out->owned = le_backing_owned_count(engine);
  out->owned_bytes = le_backing_owned_bytes(engine);
  return LE_OK;
}
