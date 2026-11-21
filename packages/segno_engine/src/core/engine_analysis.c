/* engine_analysis.c — beat analysis of a free first take (#1936); see
 * engine_analysis.h. The audio thread only writes the ring and a few
 * atomics; everything that allocates or takes time runs on the worker. */
#include "engine_analysis.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "audio_ring.h"
#include "le_aubio.h"

/* The ring holds about 2.7 s at 48 kHz: the worker drains it every
 * LE_ANALYSIS_PERIOD_NS, so it only fills when the worker is starved. */
#define LE_ANALYSIS_RING (1u << 17)
#define LE_ANALYSIS_PERIOD_NS 5000000L
/* The samples the worker takes from the ring at a time. */
#define LE_ANALYSIS_CHUNK 4096

/* The tempo window the bar choice considers (the plan's D6), and the bar
 * counts. */
#define LE_ANALYSIS_BPM_MIN 60.0
#define LE_ANALYSIS_BPM_MAX 200.0
static const int32_t kBarCandidates[] = {1, 2, 4, 8, 16};
#define LE_ANALYSIS_CANDIDATES \
  ((int)(sizeof(kBarCandidates) / sizeof(kBarCandidates[0])))
/* A winner must score at least this, and beat the runner-up by this much;
 * otherwise the take has no clear beat and the answer is 0. */
#define LE_ANALYSIS_MIN_SCORE 0.05f
#define LE_ANALYSIS_MIN_MARGIN 0.02f
/* The live estimate shows only once aubio's confidence reaches this and its
 * tempo has held within LE_ANALYSIS_EST_DRIFT for LE_ANALYSIS_EST_HOLD_S:
 * its tempo alone means nothing (it reads ~122 BPM on silence, a held tone
 * and noise alike), and a take with a clear beat reaches it within ~10 s. */
#define LE_ANALYSIS_EST_CONF 0.2f
#define LE_ANALYSIS_EST_DRIFT 0.03f
#define LE_ANALYSIS_EST_HOLD_S 2

struct le_analysis {
  int32_t sample_rate;
  int32_t hop;
  int32_t win;
  le_audio_ring ring;

  /* Audio thread -> worker. A take is numbered by its begin; an end names
   * the take and the loop it closed as, with a sequence the answer echoes. */
  _Atomic uint32_t a_take;     /* takes begun */
  _Atomic uint32_t a_end_seq;  /* ends requested */
  _Atomic uint32_t a_end_take; /* the take the latest end closed */
  _Atomic int32_t a_end_len;
  _Atomic int32_t a_end_num;
  _Atomic int32_t a_end_dropped; /* the take lost samples to a full ring */
  int32_t dropped;               /* audio thread: this take lost samples */
  uint32_t end_seq;              /* audio thread: the last end posted */

  /* Worker -> audio thread. */
  _Atomic uint32_t a_result_seq; /* the end the answer is for */
  _Atomic int32_t a_result_bars;
  _Atomic uint32_t a_est_bpm_bits;
  _Atomic uint32_t a_est_conf_bits;

  /* Worker state. */
  pthread_t thread;
  int running;
  _Atomic int a_stop;
  uint32_t take_seen; /* takes whose begin marker the worker passed */
  uint32_t handled_end;
  le_onset_odf* odf_maker;
  le_beat_tracker* tracker;
  float* hop_buf;
  int32_t hop_fill;
  float* odf;
  int32_t odf_len;
  int32_t odf_cap;
  float* chunk;
  /* The estimate's run: the tempo it holds near, and for how many hops. */
  float est_ref;
  int32_t est_run;
};

static uint32_t le_bits(float v) {
  uint32_t u;
  memcpy(&u, &v, sizeof u);
  return u;
}

static float le_float(uint32_t u) {
  float v;
  memcpy(&v, &u, sizeof v);
  return v;
}

/* ---- the bar choice ---- */

/* Circular autocorrelation of [x] (n values, mean removed, energy [e0]) at
 * a fractional [lag], linearly interpolated: 1 at lag 0. */
static float le_acf(const float* x, int32_t n, double e0, double lag) {
  if (n <= 0 || !(e0 > 0.0)) return 0.0f;
  double l = fmod(lag, (double)n);
  if (l < 0.0) l += n;
  const int32_t l0 = (int32_t)l;
  const double frac = l - l0;
  double a = 0.0, b = 0.0;
  for (int32_t i = 0; i < n; ++i) {
    a += (double)x[i] * x[(i + l0) % n];
    b += (double)x[i] * x[(i + l0 + 1) % n];
  }
  return (float)(((1.0 - frac) * a + frac * b) / e0);
}

int32_t le_analysis_choose_bars(const float* odf, int32_t n, int32_t hop,
                                int32_t len, int32_t ts_num,
                                int32_t sample_rate) {
  if (odf == NULL || n < 16 || hop <= 0 || len <= 0 || ts_num <= 0 ||
      sample_rate <= 0) {
    return 0;
  }
  float* x = (float*)malloc((size_t)n * sizeof(float));
  if (x == NULL) return 0;
  double mean = 0.0;
  for (int32_t i = 0; i < n; ++i) mean += odf[i];
  mean /= n;
  double e0 = 0.0;
  for (int32_t i = 0; i < n; ++i) {
    x[i] = (float)(odf[i] - mean);
    e0 += (double)x[i] * x[i];
  }
  float best = -1e9f, second = -1e9f;
  int32_t best_bars = 0;
  for (int c = 0; c < LE_ANALYSIS_CANDIDATES; ++c) {
    const int32_t bars = kBarCandidates[c];
    const double bpm =
        60.0 * sample_rate * (double)bars * ts_num / (double)len;
    if (bpm < LE_ANALYSIS_BPM_MIN || bpm > LE_ANALYSIS_BPM_MAX) continue;
    /* The beat in hops. A take whose beats repeat at this period scores
     * high on its multiples and low half-way between them: that is what
     * tells a beat from its half (whose midpoints are beats too) and its
     * double (whose multiples are half off-beats). */
    const double beat = (double)len / ((double)bars * ts_num) / hop;
    if (beat < 1.0) continue;
    int32_t k_max = (int32_t)((double)n / beat) - 1;
    if (k_max > 16) k_max = 16;
    if (k_max < 1) k_max = 1;
    double on = 0.0, off = 0.0;
    for (int32_t k = 1; k <= k_max; ++k) {
      on += le_acf(x, n, e0, k * beat);
      off += le_acf(x, n, e0, (k - 0.5) * beat);
    }
    const float score = (float)((on - off) / k_max);
    if (score > best) {
      second = best;
      best = score;
      best_bars = bars;
    } else if (score > second) {
      second = score;
    }
  }
  free(x);
  if (best_bars == 0 || best < LE_ANALYSIS_MIN_SCORE) return 0;
  if (second > -1e8f && best - second < LE_ANALYSIS_MIN_MARGIN) return 0;
  return best_bars;
}

/* ---- the worker ---- */

static void le_analysis_clear_estimate(le_analysis* a) {
  a->est_run = 0;
  a->est_ref = 0.0f;
  atomic_store_explicit(&a->a_est_bpm_bits, le_bits(0.0f),
                        memory_order_relaxed);
  atomic_store_explicit(&a->a_est_conf_bits, le_bits(0.0f),
                        memory_order_relaxed);
}

/* Publishes the tracker's estimate once it is confident and steady (see
 * LE_ANALYSIS_EST_CONF), else 0; the confidence as it is. */
static void le_analysis_estimate_hop(le_analysis* a) {
  const float bpm = le_beat_tracker_bpm(a->tracker);
  const float conf = le_beat_tracker_confidence(a->tracker);
  const int32_t hold = LE_ANALYSIS_EST_HOLD_S * a->sample_rate / a->hop;
  float shown = 0.0f;
  if (!(conf >= LE_ANALYSIS_EST_CONF) || !(bpm > 0.0f)) {
    a->est_run = 0;
  } else if (a->est_run == 0 ||
             fabsf(bpm - a->est_ref) > LE_ANALYSIS_EST_DRIFT * a->est_ref) {
    a->est_ref = bpm;
    a->est_run = 1;
  } else {
    a->est_run++;
    if (a->est_run >= hold) shown = bpm;
  }
  atomic_store_explicit(&a->a_est_bpm_bits, le_bits(shown),
                        memory_order_relaxed);
  atomic_store_explicit(&a->a_est_conf_bits, le_bits(conf),
                        memory_order_relaxed);
}

static void le_analysis_new_take(le_analysis* a) {
  a->take_seen++;
  a->hop_fill = 0;
  a->odf_len = 0;
  le_onset_odf_free(a->odf_maker);
  a->odf_maker = le_onset_odf_new(a->win, a->hop);
  le_beat_tracker_free(a->tracker);
  a->tracker = le_beat_tracker_new(a->win, a->hop, a->sample_rate);
  le_analysis_clear_estimate(a);
}

static void le_analysis_hop(le_analysis* a) {
  if (a->odf_maker != NULL && a->odf_len < a->odf_cap) {
    a->odf[a->odf_len++] = le_onset_odf_step(a->odf_maker, a->hop_buf);
  }
  if (a->tracker != NULL) {
    le_beat_tracker_step(a->tracker, a->hop_buf);
    le_analysis_estimate_hop(a);
  }
}

/* Drains the ring; returns whether it popped anything. */
static int le_analysis_drain(le_analysis* a) {
  int any = 0;
  for (;;) {
    const size_t got =
        le_audio_ring_pop(&a->ring, a->chunk, LE_ANALYSIS_CHUNK);
    if (got == 0) break;
    any = 1;
    for (size_t i = 0; i < got; ++i) {
      const float s = a->chunk[i];
      if (isnan(s)) { /* a take's begin marker */
        le_analysis_new_take(a);
        continue;
      }
      if (a->take_seen == 0) continue;
      a->hop_buf[a->hop_fill++] = s;
      if (a->hop_fill == a->hop) {
        le_analysis_hop(a);
        a->hop_fill = 0;
      }
    }
  }
  return any;
}

static void le_analysis_answer(le_analysis* a) {
  const uint32_t seq =
      atomic_load_explicit(&a->a_end_seq, memory_order_acquire);
  if (seq == a->handled_end) return;
  const uint32_t take =
      atomic_load_explicit(&a->a_end_take, memory_order_relaxed);
  /* Everything the take pushed came before its end: drained by now. */
  (void)le_analysis_drain(a);
  if (take != a->take_seen) return; /* its marker is not through yet */
  int32_t bars = 0;
  if (!atomic_load_explicit(&a->a_end_dropped, memory_order_relaxed)) {
    bars = le_analysis_choose_bars(
        a->odf, a->odf_len, a->hop,
        atomic_load_explicit(&a->a_end_len, memory_order_relaxed),
        atomic_load_explicit(&a->a_end_num, memory_order_relaxed),
        a->sample_rate);
  }
  a->handled_end = seq;
  le_analysis_clear_estimate(a); /* the take is over: no estimate is live */
  atomic_store_explicit(&a->a_result_bars, bars, memory_order_relaxed);
  atomic_store_explicit(&a->a_result_seq, seq, memory_order_release);
}

static void* le_analysis_main(void* arg) {
  le_analysis* a = (le_analysis*)arg;
  while (!atomic_load_explicit(&a->a_stop, memory_order_acquire)) {
    (void)le_analysis_drain(a);
    le_analysis_answer(a);
    const struct timespec ts = {0, LE_ANALYSIS_PERIOD_NS};
    nanosleep(&ts, NULL);
  }
  return NULL;
}

/* ---- lifecycle ---- */

/* The hop nearest 10.7 ms (512 at 48 kHz), a power of two. */
static int32_t le_analysis_hop_for(int32_t sample_rate) {
  int32_t hop = 64;
  while (hop * 2 <= sample_rate / 70) hop *= 2;
  return hop;
}

le_analysis* le_analysis_create(int32_t sample_rate, int32_t max_loop_frames) {
  if (sample_rate <= 0 || max_loop_frames <= 0) return NULL;
  le_analysis* a = (le_analysis*)calloc(1, sizeof(le_analysis));
  if (a == NULL) return NULL;
  a->sample_rate = sample_rate;
  a->hop = le_analysis_hop_for(sample_rate);
  a->win = a->hop * 2;
  a->odf_cap = max_loop_frames / a->hop + 2;
  a->odf = (float*)calloc((size_t)a->odf_cap, sizeof(float));
  a->hop_buf = (float*)calloc((size_t)a->hop, sizeof(float));
  a->chunk = (float*)calloc(LE_ANALYSIS_CHUNK, sizeof(float));
  if (a->odf == NULL || a->hop_buf == NULL || a->chunk == NULL ||
      !le_audio_ring_alloc(&a->ring, LE_ANALYSIS_RING)) {
    le_analysis_destroy(a);
    return NULL;
  }
  a->running = pthread_create(&a->thread, NULL, le_analysis_main, a) == 0;
  if (!a->running) {
    le_analysis_destroy(a);
    return NULL;
  }
  return a;
}

void le_analysis_destroy(le_analysis* a) {
  if (a == NULL) return;
  if (a->running) {
    atomic_store_explicit(&a->a_stop, 1, memory_order_release);
    pthread_join(a->thread, NULL);
  }
  le_onset_odf_free(a->odf_maker);
  le_beat_tracker_free(a->tracker);
  le_audio_ring_release(&a->ring);
  free(a->odf);
  free(a->hop_buf);
  free(a->chunk);
  free(a);
}

/* ---- the audio thread ---- */

void le_analysis_begin(le_analysis* a) {
  if (a == NULL) return;
  const float marker = NAN;
  a->dropped = !le_audio_ring_push_frame(&a->ring, &marker, 1);
  atomic_fetch_add_explicit(&a->a_take, 1u, memory_order_relaxed);
}

void le_analysis_push(le_analysis* a, const float* mono, int32_t n) {
  if (a == NULL || n <= 0) return;
  if (!le_audio_ring_push_frame(&a->ring, mono, (size_t)n)) a->dropped = 1;
}

void le_analysis_end(le_analysis* a, int32_t len, int32_t ts_num) {
  if (a == NULL) return;
  atomic_store_explicit(&a->a_end_len, len, memory_order_relaxed);
  atomic_store_explicit(&a->a_end_num, ts_num, memory_order_relaxed);
  atomic_store_explicit(&a->a_end_dropped, a->dropped, memory_order_relaxed);
  atomic_store_explicit(
      &a->a_end_take,
      atomic_load_explicit(&a->a_take, memory_order_relaxed),
      memory_order_relaxed);
  a->end_seq++;
  atomic_store_explicit(&a->a_end_seq, a->end_seq, memory_order_release);
}

void le_analysis_abort(le_analysis* a) {
  if (a == NULL) return;
  /* A begin with nothing after it: the worker restarts and answers none. */
  const float marker = NAN;
  (void)le_audio_ring_push_frame(&a->ring, &marker, 1);
  atomic_fetch_add_explicit(&a->a_take, 1u, memory_order_relaxed);
}

int le_analysis_result(le_analysis* a, int32_t* bars) {
  if (a == NULL) return 1; /* no analysis: nothing to wait for */
  if (atomic_load_explicit(&a->a_result_seq, memory_order_acquire) !=
      a->end_seq) {
    return 0;
  }
  *bars = atomic_load_explicit(&a->a_result_bars, memory_order_relaxed);
  return 1;
}

void le_analysis_estimate(le_analysis* a, float* bpm, float* confidence) {
  *bpm = 0.0f;
  *confidence = 0.0f;
  if (a == NULL) return;
  *bpm = le_float(atomic_load_explicit(&a->a_est_bpm_bits,
                                       memory_order_relaxed));
  *confidence = le_float(atomic_load_explicit(&a->a_est_conf_bits,
                                              memory_order_relaxed));
}
