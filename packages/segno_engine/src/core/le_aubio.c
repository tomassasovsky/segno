/* le_aubio.c — the vendored aubio subset as one translation unit, behind
 * le_aubio.h (#1936). See third_party/README.md for what is vendored and how
 * the sources were adapted. No engine header is included here: aubio's
 * private macros (MIN, MAX, ABS, ...) stay in this file. */
#define HAVE_STDLIB_H 1
#define HAVE_STDIO_H 1
#define HAVE_MATH_H 1
#define HAVE_STRING_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDARG_H 1
#define HAVE_C99_VARARGS_MACROS 1

#include "../../third_party/aubio/src/fvec.c"
#include "../../third_party/aubio/src/cvec.c"
#include "../../third_party/aubio/src/lvec.c"
#include "../../third_party/aubio/src/mathutils.c"
#include "../../third_party/aubio/src/musicutils.c"
#include "../../third_party/aubio/src/utils/log.c"
#include "../../third_party/aubio/src/utils/scale.c"
#include "../../third_party/aubio/src/utils/hist.c"
#include "../../third_party/aubio/src/spectral/ooura_fft8g.c"
#include "../../third_party/aubio/src/spectral/fft.c"
#include "../../third_party/aubio/src/spectral/phasevoc.c"
#include "../../third_party/aubio/src/spectral/specdesc.c"
#include "../../third_party/aubio/src/spectral/statistics.c"
#include "../../third_party/aubio/src/temporal/filter.c"
#include "../../third_party/aubio/src/temporal/biquad.c"
#include "../../third_party/aubio/src/onset/peakpicker.c"
#include "../../third_party/aubio/src/tempo/beattracking.c"
#include "../../third_party/aubio/src/tempo/tempo.c"

#include "le_aubio.h"

struct le_onset_odf {
  aubio_pvoc_t* pvoc;
  aubio_specdesc_t* desc;
  fvec_t* in;
  cvec_t* spectrum;
  fvec_t* out;
};

le_onset_odf* le_onset_odf_new(int win, int hop) {
  if (win <= 0 || hop <= 0 || hop > win) return NULL;
  le_onset_odf* o = (le_onset_odf*)calloc(1, sizeof(le_onset_odf));
  if (o == NULL) return NULL;
  o->pvoc = new_aubio_pvoc((uint_t)win, (uint_t)hop);
  o->desc = new_aubio_specdesc("specflux", (uint_t)win);
  o->in = new_fvec((uint_t)hop);
  o->spectrum = new_cvec((uint_t)win);
  o->out = new_fvec(1);
  if (!o->pvoc || !o->desc || !o->in || !o->spectrum || !o->out) {
    le_onset_odf_free(o);
    return NULL;
  }
  return o;
}

void le_onset_odf_free(le_onset_odf* o) {
  if (o == NULL) return;
  if (o->pvoc) del_aubio_pvoc(o->pvoc);
  if (o->desc) del_aubio_specdesc(o->desc);
  if (o->in) del_fvec(o->in);
  if (o->spectrum) del_cvec(o->spectrum);
  if (o->out) del_fvec(o->out);
  free(o);
}

float le_onset_odf_step(le_onset_odf* o, const float* hop_samples) {
  memcpy(o->in->data, hop_samples, o->in->length * sizeof(smpl_t));
  aubio_pvoc_do(o->pvoc, o->in, o->spectrum);
  aubio_specdesc_do(o->desc, o->spectrum, o->out);
  const float v = o->out->data[0];
  return v > 0.0f ? v : 0.0f;
}

struct le_beat_tracker {
  aubio_tempo_t* tempo;
  fvec_t* in;
  fvec_t* out;
};

le_beat_tracker* le_beat_tracker_new(int win, int hop, int sample_rate) {
  if (win <= 0 || hop <= 0 || hop > win || sample_rate <= 0) return NULL;
  le_beat_tracker* t = (le_beat_tracker*)calloc(1, sizeof(le_beat_tracker));
  if (t == NULL) return NULL;
  t->tempo = new_aubio_tempo("specflux", (uint_t)win, (uint_t)hop,
                             (uint_t)sample_rate);
  t->in = new_fvec((uint_t)hop);
  t->out = new_fvec(1);
  if (!t->tempo || !t->in || !t->out) {
    le_beat_tracker_free(t);
    return NULL;
  }
  return t;
}

void le_beat_tracker_free(le_beat_tracker* t) {
  if (t == NULL) return;
  if (t->tempo) del_aubio_tempo(t->tempo);
  if (t->in) del_fvec(t->in);
  if (t->out) del_fvec(t->out);
  free(t);
}

void le_beat_tracker_step(le_beat_tracker* t, const float* hop_samples) {
  memcpy(t->in->data, hop_samples, t->in->length * sizeof(smpl_t));
  aubio_tempo_do(t->tempo, t->in, t->out);
}

float le_beat_tracker_bpm(le_beat_tracker* t) {
  return t->tempo ? aubio_tempo_get_bpm(t->tempo) : 0.0f;
}

float le_beat_tracker_confidence(le_beat_tracker* t) {
  return t->tempo ? aubio_tempo_get_confidence(t->tempo) : 0.0f;
}
