/*
 * collision_voice.c — the Collision device (collision_voice.h).
 */
#include "collision_voice.h"

#include <math.h>
#include <string.h>

#include "synth_voice.h" /* LE_SYNTH_BEND, LE_SYNTH_MOD, LE_SYNTH_PRESSURE */

#define CV_PI 3.14159265358979f
#define CV_C4 261.6256f
#define CV_MASK (LE_COLLISION_PIPE - 1)

enum {
  LE_COLLISION_VOICE_FREE = 0,
  LE_COLLISION_VOICE_HELD,
  LE_COLLISION_VOICE_RELEASED,
  LE_COLLISION_VOICE_SUSTAINED,
  LE_COLLISION_VOICE_FADING
};

enum { ENV_ATTACK = 0, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE, ENV_IDLE };

/* ---- parameters ---- */

typedef struct cv_param_def {
  float def, lo, hi;
  int integer;
  int raw; /* 1: a matrix amount sent as is, 0: a knob over [lo, hi] */
} cv_param_def;

static cv_param_def res_field(int32_t r, int32_t f) {
  switch (f) {
    case LE_COLLISION_R_ON: return (cv_param_def){r == 0 ? 1.0f : 0.0f, 0.0f, 1.0f, 1, 0};
    case LE_COLLISION_R_TYPE: return (cv_param_def){0.0f, 0.0f, 6.0f, 1, 0};
    case LE_COLLISION_R_QUALITY: return (cv_param_def){2.0f, 0.0f, 3.0f, 1, 0};
    case LE_COLLISION_R_TUNE: return (cv_param_def){0.0f, -48.0f, 48.0f, 1, 0};
    case LE_COLLISION_R_FINE: return (cv_param_def){0.0f, -50.0f, 50.0f, 0, 0};
    case LE_COLLISION_R_TUNE_KEY: return (cv_param_def){1.0f, -2.0f, 2.0f, 0, 1};
    case LE_COLLISION_R_PITCH_ENV:
    case LE_COLLISION_R_MATERIAL:
    case LE_COLLISION_R_BRIGHTNESS:
    case LE_COLLISION_R_INHARMONICS:
    case LE_COLLISION_R_PAN:
    case LE_COLLISION_R_PAN_KEY:
      return (cv_param_def){0.0f, -1.0f, 1.0f, 0, 0};
    case LE_COLLISION_R_PITCH_ENV_VEL:
    case LE_COLLISION_R_DECAY_VEL:
    case LE_COLLISION_R_MATERIAL_VEL:
    case LE_COLLISION_R_RADIUS_VEL:
    case LE_COLLISION_R_INHARMONICS_VEL:
    case LE_COLLISION_R_OPENING_VEL:
      return (cv_param_def){0.0f, -5.0f, 5.0f, 0, 1};
    case LE_COLLISION_R_DECAY_KEY:
    case LE_COLLISION_R_MATERIAL_KEY:
    case LE_COLLISION_R_RADIUS_KEY:
      return (cv_param_def){0.0f, -2.0f, 2.0f, 0, 1};
    case LE_COLLISION_R_PITCH_ENV_TIME:
    case LE_COLLISION_R_RATIO:
    case LE_COLLISION_R_HIT_RANDOM:
      return (cv_param_def){0.0f, 0.0f, 1.0f, 0, 0};
    case LE_COLLISION_R_OFF_DECAY: return (cv_param_def){1.0f, 0.0f, 1.0f, 0, 0};
    case LE_COLLISION_R_VOLUME: return (cv_param_def){0.7071f, 0.0f, 1.0f, 0, 0};
    default: return (cv_param_def){0.5f, 0.0f, 1.0f, 0, 0};
  }
}

static cv_param_def lfo_field(int32_t f) {
  switch (f) {
    case LE_COLLISION_L_ON:
    case LE_COLLISION_L_SYNC:
      return (cv_param_def){0.0f, 0.0f, 1.0f, 1, 0};
    case LE_COLLISION_L_RETRIGGER: return (cv_param_def){1.0f, 0.0f, 1.0f, 1, 0};
    case LE_COLLISION_L_SHAPE: return (cv_param_def){0.0f, 0.0f, 6.0f, 1, 0};
    case LE_COLLISION_L_SYNC_RATE: return (cv_param_def){4.0f, 0.0f, 21.0f, 1, 0};
    case LE_COLLISION_L_RATE_KEY: return (cv_param_def){0.0f, -2.0f, 2.0f, 0, 1};
    case LE_COLLISION_L_PHASE: return (cv_param_def){0.0f, 0.0f, 360.0f, 0, 0};
    case LE_COLLISION_L_DEPTH_VEL:
    case LE_COLLISION_L_AMOUNT1:
    case LE_COLLISION_L_AMOUNT2:
      return (cv_param_def){0.0f, -5.0f, 5.0f, 0, 1};
    case LE_COLLISION_L_TARGET1:
    case LE_COLLISION_L_TARGET2:
      return (cv_param_def){0.0f, 0.0f, 16.0f, 1, 0};
    default: return (cv_param_def){0.5f, 0.0f, 1.0f, 0, 0};
  }
}

static cv_param_def param_def(int32_t p) {
  if (p >= LE_COLLISION_RES1 && p < LE_COLLISION_STRUCTURE) {
    const int32_t i = p - LE_COLLISION_RES1;
    return res_field(i / LE_COLLISION_R_FIELDS, i % LE_COLLISION_R_FIELDS);
  }
  if (p >= LE_COLLISION_LFO1 && p < LE_COLLISION_BEND_RANGE) {
    return lfo_field((p - LE_COLLISION_LFO1) % LE_COLLISION_L_FIELDS);
  }
  switch (p) {
    case LE_COLLISION_MALLET_ON:
    case LE_COLLISION_RETRIGGER:
      return (cv_param_def){1.0f, 0.0f, 1.0f, 1, 0};
    case LE_COLLISION_NOISE_ON:
    case LE_COLLISION_STRUCTURE:
      return (cv_param_def){0.0f, 0.0f, 1.0f, 1, 0};
    case LE_COLLISION_NOISE_FILTER: return (cv_param_def){0.0f, 0.0f, 3.0f, 1, 0};
    case LE_COLLISION_MALLET_VOLUME_VEL:
    case LE_COLLISION_MALLET_STIFFNESS_VEL:
    case LE_COLLISION_MALLET_NOISE_VEL:
    case LE_COLLISION_NOISE_VOLUME_VEL:
    case LE_COLLISION_NOISE_FREQ_ENV:
    case LE_COLLISION_BEND_AMOUNT:
    case LE_COLLISION_WHEEL_AMOUNT1:
    case LE_COLLISION_WHEEL_AMOUNT2:
    case LE_COLLISION_PRESSURE_AMOUNT1:
    case LE_COLLISION_PRESSURE_AMOUNT2:
    case LE_COLLISION_SLIDE_AMOUNT1:
    case LE_COLLISION_SLIDE_AMOUNT2:
      return (cv_param_def){0.0f, -5.0f, 5.0f, 0, 1};
    case LE_COLLISION_NOISE_FREQ_VEL: return (cv_param_def){0.0f, -8.0f, 8.0f, 0, 1};
    case LE_COLLISION_MALLET_VOLUME_KEY:
    case LE_COLLISION_MALLET_STIFFNESS_KEY:
    case LE_COLLISION_MALLET_NOISE_KEY:
    case LE_COLLISION_NOISE_VOLUME_KEY:
    case LE_COLLISION_NOISE_FREQ_KEY:
      return (cv_param_def){0.0f, -2.0f, 2.0f, 0, 1};
    case LE_COLLISION_BEND_RANGE: return (cv_param_def){2.0f, 0.0f, 24.0f, 1, 0};
    case LE_COLLISION_NOTE_BEND_RANGE: return (cv_param_def){48.0f, 0.0f, 48.0f, 1, 0};
    case LE_COLLISION_BEND_TARGET:
    case LE_COLLISION_WHEEL_TARGET1:
    case LE_COLLISION_WHEEL_TARGET2:
    case LE_COLLISION_PRESSURE_TARGET1:
    case LE_COLLISION_PRESSURE_TARGET2:
    case LE_COLLISION_SLIDE_TARGET1:
    case LE_COLLISION_SLIDE_TARGET2:
      return (cv_param_def){0.0f, 0.0f, 17.0f, 1, 0};
    case LE_COLLISION_POLYPHONY: return (cv_param_def){4.0f, 0.0f, 8.0f, 1, 0};
    case LE_COLLISION_VOLUME: return (cv_param_def){0.7071f, 0.0f, 1.0f, 0, 0};
    case LE_COLLISION_NOISE_SUSTAIN: return (cv_param_def){0.0f, 0.0f, 1.0f, 0, 0};
    case LE_COLLISION_NOISE_ATTACK: return (cv_param_def){0.0f, 0.0f, 1.0f, 0, 0};
    default: return (cv_param_def){0.5f, 0.0f, 1.0f, 0, 0};
  }
}

float le_collision_default(int32_t param) {
  if (param < 0 || param >= LE_COLLISION_PARAMS) return 0.0f;
  return param_def(param).def;
}

float le_collision_clamp(int32_t param, float value) {
  if (param < 0 || param >= LE_COLLISION_PARAMS) return 0.0f;
  const cv_param_def p = param_def(param);
  if (value != value) return p.def;
  if (p.integer) value = roundf(value);
  return value < p.lo ? p.lo : value > p.hi ? p.hi : value;
}

static float vf(const le_collision* d, int32_t p) { return d->values[p]; }
static int32_t vi(const le_collision* d, int32_t p) { return (int32_t)d->values[p]; }
static float rf(const le_collision* d, int32_t r, int32_t f) { return d->values[LE_COLLISION_RES(r, f)]; }
static int32_t ri(const le_collision* d, int32_t r, int32_t f) { return (int32_t)d->values[LE_COLLISION_RES(r, f)]; }
static float lf(const le_collision* d, int32_t l, int32_t f) { return d->values[LE_COLLISION_LFO(l, f)]; }
static int32_t li(const le_collision* d, int32_t l, int32_t f) { return (int32_t)d->values[LE_COLLISION_LFO(l, f)]; }

static float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

/* A knob's place on the engine's 0..127 scale: a 0..1 knob by the 128 / 126
 * rule (Filter Q by 127 / 126), a ranged one by its range, Fine Tune and the
 * bipolar knobs with 0 at 64 (63 steps up, 63.5 down), Radius inverted. */
static float m_of(int32_t p, float v) {
  if (p >= LE_COLLISION_RES1 && p < LE_COLLISION_STRUCTURE) {
    switch ((p - LE_COLLISION_RES1) % LE_COLLISION_R_FIELDS) {
      case LE_COLLISION_R_FINE: return v == 0.0f ? 64.0f : 1.27f * clampf(v, -50.0f, 50.0f) + 63.5f;
      case LE_COLLISION_R_PITCH_ENV:
      case LE_COLLISION_R_PITCH_ENV_VEL:
      case LE_COLLISION_R_MATERIAL:
      case LE_COLLISION_R_BRIGHTNESS:
      case LE_COLLISION_R_INHARMONICS:
      case LE_COLLISION_R_PAN:
        v = clampf(v, -1.0f, 1.0f);
        return v >= 0.0f ? 64.0f + 63.0f * v : 63.5f + 63.5f * v;
      case LE_COLLISION_R_RADIUS:
        v = clampf(v, 0.0f, 1.0f);
        return 1.0f - v <= 0.5f ? 127.0f * (1.0f - v) : 127.0f - 126.0f * v;
      default: break;
    }
  }
  const cv_param_def q = param_def(p);
  if (q.lo == 0.0f && q.hi == 1.0f) {
    v = clampf(v, 0.0f, 1.0f);
    if (p == LE_COLLISION_NOISE_Q && v <= 0.5f) return 127.0f * v;
    return v <= 0.5f ? 128.0f * v : 126.0f * v + 1.0f;
  }
  return 127.0f * (clampf(v, q.lo, q.hi) - q.lo) / (q.hi - q.lo);
}

/* The knob's position as a fraction, taken down to its whole step, as the
 * exponential curve reads it. */
/* fit: the master volume is not taken down to its step (Vibes Basic's
 * level) */
static int smooth_param(int32_t p) {
  /* fit: and the pitch envelope's time (penv-t75's sweep) */
  if (p >= LE_COLLISION_RES1 && p < LE_COLLISION_STRUCTURE &&
      (p - LE_COLLISION_RES1) % LE_COLLISION_R_FIELDS == LE_COLLISION_R_PITCH_ENV_TIME) return 1;
  return p == LE_COLLISION_VOLUME;
}

static float u_of(int32_t p, float v) {
  if (smooth_param(p)) return m_of(p, v) / 127.0f;
  return floorf(m_of(p, v) + 1e-4f) / 127.0f;
}

/* The same for the linear, square and cube curves, which put step 64 at
 * exactly the middle. */
static float u_mid(int32_t p, float v) {
  const float m = smooth_param(p) ? m_of(p, v) : floorf(m_of(p, v) + 1e-4f);
  return m == 64.0f ? 0.5f : m / 127.0f;
}

static float k_exp(const le_collision* d, int32_t p, float lo, float hi) {
  return lo * powf(hi / lo, u_of(p, d->values[p]));
}
static float k_lin(const le_collision* d, int32_t p, float lo, float hi) {
  return lo + (hi - lo) * u_mid(p, d->values[p]);
}
static float k_sq(const le_collision* d, int32_t p, float lo, float hi) {
  const float u = u_mid(p, d->values[p]);
  return lo + (hi - lo) * u * u;
}

/* ---- the modes ---- */

static float beam_root(int32_t k) {
  /* the roots of cos b cosh b = 1, by Newton from (k + 1/2) pi */
  float b = ((float)k + 0.5f) * CV_PI;
  for (int32_t it = 0; it < 20 && k <= 4; ++it) {
    const float f = cosf(b) * coshf(b) - 1.0f;
    const float df = -sinf(b) * coshf(b) + cosf(b) * sinhf(b);
    b -= f / df;
  }
  return b;
}

/* The mode count of each quality. */
static const int32_t kModes[4] = {4, 16, 30, 70};

/* Fills r's ratios and shape indices for its type, quality and ratio. */
static void build_modes(le_collision_res* r, int32_t type, int32_t n, float aspect, uint8_t* mm, uint8_t* nn,
                        float* ratio) {
  if (type == 2) { /* string */
    for (int32_t k = 0; k < n; ++k) ratio[k] = (float)(k + 1), mm[k] = (uint8_t)(k + 1), nn[k] = 0;
  } else if (type == 0) { /* beam: free-free */
    const float b1 = beam_root(1);
    for (int32_t k = 0; k < n; ++k) {
      const float b = beam_root(k + 1);
      ratio[k] = (b / b1) * (b / b1);
      mm[k] = (uint8_t)(k + 1);
      nn[k] = 0;
    }
  } else if (type == 1) { /* marimba: a tuned bar, five partials then its asymptote */
    /* fit: 10.67 and 19.17 measured; past the fifth, sqrt 2 (k + 3/2) pi
     * over the free beam's first root (type-1's sixth partial at 37.3) */
    static const float tuned[5] = {1.0f, 3.96f, 10.67f, 19.17f, 27.0f};
    for (int32_t k = 0; k < n; ++k) {
      const float b = 1.41421356f * ((float)k + 1.5f) * CV_PI / beam_root(1);
      ratio[k] = k < 5 ? tuned[k] : b * b;
      mm[k] = (uint8_t)(k + 1);
      nn[k] = 0;
    }
  } else { /* membrane, plate: rectangular, side ratio `aspect` */
    const int plate = type == 4;
    int32_t got = 0;
    /* the engine's grid of candidates: m up to floor(sqrt(N a)) + 1, n up to
     * floor(sqrt(N / a)) + 1 */
    int32_t mmax = (int32_t)sqrtf((float)n * aspect), nmax = (int32_t)sqrtf((float)n / aspect);
    if ((float)((mmax + 1) * (mmax + 1)) == (float)n * aspect) mmax++;
    if ((float)((nmax + 1) * (nmax + 1)) == (float)n / aspect) nmax++;
    mmax++;
    nmax++;
    const float base = plate ? (1.0f + aspect * aspect) : sqrtf(1.0f + aspect * aspect);
    for (int32_t m = 1; m <= mmax && m < 256; ++m) {
      for (int32_t q = 1; q <= nmax && q < 256; ++q) {
        const float s = (float)(m * m) + aspect * aspect * (float)(q * q);
        const float f = (plate ? s : sqrtf(s)) / base;
        /* keep the n lowest, sorted */
        if (got < n || f < ratio[got - 1]) {
          int32_t at = got < n ? got++ : got - 1;
          while (at > 0 && ratio[at - 1] > f) {
            ratio[at] = ratio[at - 1];
            mm[at] = mm[at - 1];
            nn[at] = nn[at - 1];
            at--;
          }
          ratio[at] = f;
          mm[at] = (uint8_t)m;
          nn[at] = (uint8_t)q;
        }
      }
    }
    for (int32_t k = got; k < n; ++k) ratio[k] = ratio[got - 1], mm[k] = mm[got - 1], nn[k] = nn[got - 1];
  }
  (void)r;
}

/* A mode's shape at x along the bar (and y across, for 2-D types), read off
 * the grid the engine samples it on: N + 2 points from end to end for a bar
 * of N modes, read linearly; G x G points for a membrane or plate, G =
 * floor(sqrt N) + 3, read bilinearly. */
static float shape(int32_t type, int32_t m, int32_t n, float x, int32_t modes) {
  if (type == 3 || type == 4) {
    int32_t s = (int32_t)sqrtf((float)modes);
    if ((s + 1) * (s + 1) <= modes) s++;
    const float span = (float)(s + 2); /* G - 1 */
    const float tx = clampf(x, 0.0f, 1.0f) * span, ty = 0.44375f * span;
    const float ix = fminf(floorf(tx), span - 1.0f), iy = floorf(ty);
    const float fx = tx - ix, fy = ty - iy;
    const float a = CV_PI * (float)m / span, b = CV_PI * (float)n / span;
    const float x0 = sinf(a * ix), x1 = sinf(a * (ix + 1.0f));
    const float y0 = sinf(b * iy), y1 = sinf(b * (iy + 1.0f));
    return (x0 + fx * (x1 - x0)) * (y0 + fy * (y1 - y0));
  }
  const float span = (float)(modes | 1); /* N + 1 for the even mode counts */
  const float t = clampf(x, 0.0f, 1.0f) * (float)(modes + 1);
  const float j = fminf(floorf(t), (float)modes);
  const float f = t - j, a = CV_PI * (float)m / span;
  const float s0 = sinf(a * j), s1 = sinf(a * (j + 1.0f));
  return s0 + f * (s1 - s0);
}

/* ---- voices ---- */

static int sounding(const le_collision_voice* v) {
  return v->state == LE_COLLISION_VOICE_HELD || v->state == LE_COLLISION_VOICE_RELEASED ||
         v->state == LE_COLLISION_VOICE_SUSTAINED;
}

static void fade_voice(le_collision_voice* v) {
  if (v->state == LE_COLLISION_VOICE_FREE) return;
  v->state = LE_COLLISION_VOICE_FADING;
  if (v->fade_left <= 0) v->fade_left = v->fade_len;
}

static int32_t voice_count(const le_collision* d) {
  int32_t n = 2 * vi(d, LE_COLLISION_POLYPHONY);
  if (n < 1) n = 1;
  if (n > d->voice_limit) n = d->voice_limit;
  return n;
}

static int32_t note_count(const le_collision* d) {
  int32_t n = 0;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

static le_collision_voice* oldest(le_collision* d, int32_t state) {
  le_collision_voice* old = NULL;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    le_collision_voice* v = &d->voices[i];
    if (v->state == state && (old == NULL || v->serial < old->serial)) old = v;
  }
  return old;
}

static le_collision_voice* free_slot(le_collision* d) {
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_COLLISION_VOICE_FREE) return &d->voices[i];
  }
  return oldest(d, LE_COLLISION_VOICE_FADING);
}

int32_t le_collision_init(le_collision* d, int32_t sample_rate) {
  if (d == NULL || sample_rate <= 0) return -1;
  memset(d, 0, sizeof(*d));
  d->sample_rate = sample_rate;
  d->bpm = 120.0f;
  d->voice_limit = LE_COLLISION_VOICE_SLOTS;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) d->voices[i].r[0].amp_n = d->voices[i].r[1].amp_n = -1;
  for (int32_t p = 0; p < LE_COLLISION_PARAMS; ++p) d->values[p] = le_collision_default(p);
  d->gain = -1.0f;
  d->lim_rel = d->lim_fast = d->lim_slow = 1.0f;
  return 0;
}

int32_t le_collision_latency(const le_collision* d) { return d == NULL ? 0 : d->sample_rate / 1000; }

void le_collision_set_values(le_collision* d, const float* values) {
  if (d == NULL || values == NULL) return;
  for (int32_t p = 0; p < LE_COLLISION_PARAMS; ++p) d->values[p] = le_collision_clamp(p, values[p]);
  d->serial_values++;
}

void le_collision_set_tempo(le_collision* d, float bpm) {
  if (d != NULL && bpm > 0.0f && bpm == bpm) d->bpm = bpm;
}

/* ---- biquads ---- */

static void bq_set(le_collision_bq* q, float b0, float b1, float b2, float a0, float a1, float a2) {
  q->b0 = b0 / a0;
  q->b1 = b1 / a0;
  q->b2 = b2 / a0;
  q->a1 = a1 / a0;
  q->a2 = a2 / a0;
}

static float bq_tick(le_collision_bq* q, float x) {
  const float y = q->b0 * x + q->b1 * q->x1 + q->b2 * q->x2 - q->a1 * q->y1 - q->a2 * q->y2;
  q->x2 = q->x1;
  q->x1 = x;
  q->y2 = q->y1;
  q->y1 = y;
  return y;
}

/* RBJ low-pass, high-pass and band-pass (constant skirt: its peak gain is
 * q) at f Hz, quality q. */
static void bq_filter(le_collision_bq* bq, int32_t type, float f, float q, float rate) {
  f = clampf(f, 0.0003f * rate, 0.45f * rate);
  q = clampf(q, 0.05f, 100.0f);
  const float w = 2.0f * CV_PI * f / rate, c = cosf(w), s = sinf(w), a = s / (2.0f * q);
  if (type == 0) bq_set(bq, (1.0f - c) / 2.0f, 1.0f - c, (1.0f - c) / 2.0f, 1.0f + a, -2.0f * c, 1.0f - a);
  else if (type == 1) bq_set(bq, (1.0f + c) / 2.0f, -(1.0f + c), (1.0f + c) / 2.0f, 1.0f + a, -2.0f * c, 1.0f - a);
  else bq_set(bq, s / 2.0f, 0.0f, -s / 2.0f, 1.0f + a, -2.0f * c, 1.0f - a);
}

/* ---- the matrix ---- */

/* fit: a chooser's amount moves a resonator's pitch by an eighth of an
 * octave a unit (lfo-pitch, Music Box Slide); every other destination takes
 * it in its own unit */
static float psc(int32_t target) {
  return target == LE_COLLISION_D_R1_PITCH || target == LE_COLLISION_D_R2_PITCH ? 0.125f : 1.0f;
}

/* This tick's destination sums for voice v: the knobs' own routes, then the
 * choosers (LFOs, bend, wheel, pressure; slide stored only). */
static void matrix(const le_collision* d, le_collision_voice* v) {
  float* t = v->dest;
  memset(t, 0, sizeof(v->dest));
  const float key = (float)(v->note - 60) / 12.0f + vf(d, LE_COLLISION_BEND_RANGE) / 12.0f * d->bend;
  const float vel = v->vel;
  t[LE_COLLISION_D_MALLET_VOLUME] =
      vf(d, LE_COLLISION_MALLET_VOLUME_VEL) * vel + vf(d, LE_COLLISION_MALLET_VOLUME_KEY) * key;
  t[LE_COLLISION_D_STIFFNESS] =
      vf(d, LE_COLLISION_MALLET_STIFFNESS_VEL) * vel + vf(d, LE_COLLISION_MALLET_STIFFNESS_KEY) * key;
  t[LE_COLLISION_D_MALLET_NOISE] =
      vf(d, LE_COLLISION_MALLET_NOISE_VEL) * vel + vf(d, LE_COLLISION_MALLET_NOISE_KEY) * key;
  t[LE_COLLISION_D_NOISE_VOLUME] =
      vf(d, LE_COLLISION_NOISE_VOLUME_VEL) * vel + vf(d, LE_COLLISION_NOISE_VOLUME_KEY) * key;
  t[LE_COLLISION_D_NOISE_FREQ] = vf(d, LE_COLLISION_NOISE_FREQ_VEL) * vel + vf(d, LE_COLLISION_NOISE_FREQ_KEY) * key;
  for (int32_t r = 0; r < 2; ++r) {
    const int32_t o = r * (LE_COLLISION_D_R2_PITCH - LE_COLLISION_D_R1_PITCH);
    const int32_t ko = r * (LE_COLLISION_D_R2_DECAY - LE_COLLISION_D_R1_DECAY);
    t[LE_COLLISION_D_R1_PITCH + o] += rf(d, r, LE_COLLISION_R_TUNE_KEY) * key;
    t[LE_COLLISION_D_R1_PAN + o] += rf(d, r, LE_COLLISION_R_PAN_KEY) * key;
    t[LE_COLLISION_D_R1_OPENING + o] += rf(d, r, LE_COLLISION_R_OPENING_VEL) * vel;
    t[LE_COLLISION_D_R1_DECAY + ko] =
        rf(d, r, LE_COLLISION_R_DECAY_VEL) * vel + rf(d, r, LE_COLLISION_R_DECAY_KEY) * key;
    t[LE_COLLISION_D_R1_MATERIAL + ko] =
        rf(d, r, LE_COLLISION_R_MATERIAL_VEL) * vel + rf(d, r, LE_COLLISION_R_MATERIAL_KEY) * key;
    t[LE_COLLISION_D_R1_RADIUS + ko] =
        rf(d, r, LE_COLLISION_R_RADIUS_VEL) * vel + rf(d, r, LE_COLLISION_R_RADIUS_KEY) * key;
    t[LE_COLLISION_D_R1_INHARMONICS + ko] = rf(d, r, LE_COLLISION_R_INHARMONICS_VEL) * vel;
  }
  for (int32_t l = 0; l < 2; ++l) {
    const int32_t o = 2 * l;
    t[LE_COLLISION_D_LFO1_RATE + o] += lf(d, l, LE_COLLISION_L_RATE_KEY) * key;
    t[LE_COLLISION_D_LFO1_DEPTH + o] += lf(d, l, LE_COLLISION_L_DEPTH_VEL) * vel;
    const float out = li(d, l, LE_COLLISION_L_ON) ? v->lfo[l].out : 0.0f;
    const int32_t t1 = li(d, l, LE_COLLISION_L_TARGET1), t2 = li(d, l, LE_COLLISION_L_TARGET2);
    if (t1 > 0 && t1 < LE_COLLISION_D_CHOOSER) t[t1] += lf(d, l, LE_COLLISION_L_AMOUNT1) * out * psc(t1);
    if (t2 > 0 && t2 < LE_COLLISION_D_CHOOSER) t[t2] += lf(d, l, LE_COLLISION_L_AMOUNT2) * out * psc(t2);
  }
  static const int32_t kChooser[5][2] = {{LE_COLLISION_BEND_TARGET, LE_COLLISION_BEND_AMOUNT},
                                         {LE_COLLISION_WHEEL_TARGET1, LE_COLLISION_WHEEL_AMOUNT1},
                                         {LE_COLLISION_WHEEL_TARGET2, LE_COLLISION_WHEEL_AMOUNT2},
                                         {LE_COLLISION_PRESSURE_TARGET1, LE_COLLISION_PRESSURE_AMOUNT1},
                                         {LE_COLLISION_PRESSURE_TARGET2, LE_COLLISION_PRESSURE_AMOUNT2}};
  const float src[5] = {d->bend, d->mod, d->mod, d->pressure, d->pressure};
  for (int32_t k = 0; k < 5; ++k) {
    const int32_t target = vi(d, kChooser[k][0]);
    if (target > 0 && target < LE_COLLISION_D_CHOOSER) t[target] += vf(d, kChooser[k][1]) * src[k] * psc(target);
  }
}

/* ---- the strike ---- */

static void strike_res(le_collision* d, le_collision_voice* v, int32_t r, int fresh) {
  le_collision_res* rs = &v->r[r];
  if (fresh) {
    memset(rs->v1, 0, sizeof(rs->v1));
    memset(rs->v2, 0, sizeof(rs->v2));
    memset(rs->om, 0, sizeof(rs->om));
    memset(rs->fw, 0, sizeof(rs->fw));
    memset(rs->bw, 0, sizeof(rs->bw));
    rs->bleed.x1 = rs->bleed.x2 = rs->bleed.y1 = rs->bleed.y2 = 0.0f;
    rs->rf_x1 = rs->rf_y1 = rs->hp_x = rs->hp_y = 0.0f;
    rs->pitch = 99.0f; /* forces the coefficients */
  }
  /* the pitch envelope: |A| 2^(V v), falling to 0 over its time */
  const float a = k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_PITCH_ENV), -1.0f, 1.0f);
  const float vv = k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_PITCH_ENV_VEL), -1.0f, 1.0f);
  rs->pe_amp = a * exp2f(vv * v->vel);
  const float tm = k_exp(d, LE_COLLISION_RES(r, LE_COLLISION_R_PITCH_ENV_TIME), 0.001f, 10.0f);
  /* fit: an exponential segment, overshooting 0 by 3.14 % of its depth so
   * that it lands there at its time (penv-1) */
  const float len = fmaxf(tm * (float)d->sample_rate, 1.0f);
  rs->pe_left = (int32_t)len;
  rs->pe_x = 1.0313935f;
  rs->pe_mul = expf(-3.4906588f * (float)LE_COLLISION_TICK / len);
  rs->pe = rs->pe_left > 0 ? rs->pe_amp * (rs->pe_x - 0.0313935f) : 0.0f;
  /* the hit's random offset, drawn at each strike */
  rs->hit_rand = 0.0f;
  const float ru = u_mid(LE_COLLISION_RES(r, LE_COLLISION_R_HIT_RANDOM), rf(d, r, LE_COLLISION_R_HIT_RANDOM));
  if (ru > 0.0f) {
    const float u1 = fmaxf((float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f, 1e-7f);
    const float u2 = (float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f;
    rs->hit_rand = sqrtf(-2.0f * logf(u1)) * cosf(2.0f * CV_PI * u2);
  }
  rs->released = -1; /* the next tick sets the coefficients for this hit */
}

/* The hit position: the knob plus the Hit destination, held to the knob's
 * window, then the strike's random offset: a normal draw times 0.2 u^2 (u
 * the Hit < Random knob), its scale cut to the distance to the edge it heads
 * for, reflected back off that edge, then held within 0.02 of the ends. */
static float hit_at(const le_collision* d, const le_collision_voice* v, int32_t r) {
  const float hit_m = floorf(64.0f + 31.5f * clampf(rf(d, r, LE_COLLISION_R_HIT), 0.0f, 1.0f));
  const int32_t po = r * (LE_COLLISION_D_R2_PITCH - LE_COLLISION_D_R1_PITCH);
  const float hit = clampf(0.05f + 0.9f * (hit_m == 64.0f ? 0.5f : hit_m / 127.0f) + v->dest[LE_COLLISION_D_R1_HIT + po], 0.5f, 0.72323f);
  const float z = v->r[r].hit_rand;
  if (z == 0.0f) return hit;
  const float ru = u_mid(LE_COLLISION_RES(r, LE_COLLISION_R_HIT_RANDOM), rf(d, r, LE_COLLISION_R_HIT_RANDOM));
  const float s = 0.2f * ru * ru;
  float x = hit + fminf(s, z > 0.0f ? 1.0f - hit : hit) * z;
  if (x > 1.0f) x = 2.0f - x;
  if (x < 0.0f) x = -x;
  return clampf(x, 0.02f, 0.98f);
}

/* The resonator's coefficients at pitch `pitch` (octaves). */
static void tune_res(le_collision* d, le_collision_voice* v, int32_t r, float pitch, int released) {
  le_collision_res* rs = &v->r[r];
  const float rate = (float)d->sample_rate;
  int32_t type = ri(d, r, LE_COLLISION_R_TYPE);
  if (r == 1 && type == 6) type = 5; /* resonator 2 has no tube */
  const float* t = v->dest;
  const int32_t ko = r * (LE_COLLISION_D_R2_DECAY - LE_COLLISION_D_R1_DECAY);
  const int32_t po = r * (LE_COLLISION_D_R2_PITCH - LE_COLLISION_D_R1_PITCH);
  float T = k_exp(d, LE_COLLISION_RES(r, LE_COLLISION_R_DECAY), 0.05f, 35.0f);
  if (released) {
    const float u = u_mid(LE_COLLISION_RES(r, LE_COLLISION_R_OFF_DECAY), rf(d, r, LE_COLLISION_R_OFF_DECAY));
    /* fit: the knob runs inverted, 0 keeping the decay and 1 cutting it to 50 ms */
    const float c = (1.0f - u) * (1.0f - u) * (1.0f - u);
    T = 0.05f + (T - 0.05f) * c;
  }
  /* the decay's routes keep the decay time within 10 ms and the knob's
   * 35 s, and no mode rings longer than that */
  const float dd = clampf(t[LE_COLLISION_D_R1_DECAY + ko], log2f(0.01f / T), log2f(35.0f / T));
  const float vol = k_sq(d, LE_COLLISION_RES(r, LE_COLLISION_R_VOLUME), 0.0f, 2.0f);
  const float pan = clampf(k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_PAN), -1.0f, 1.0f) +
                               t[LE_COLLISION_D_R1_PAN + po], -1.0f, 1.0f);
  rs->gain_l = vol * fminf(1.0f, 1.0f - pan);
  rs->gain_r = vol * fminf(1.0f, 1.0f + pan);
  const float amp = 1.011f;
  const float f0 = CV_C4 * exp2f(pitch);
  if (type >= 5) {
    /* the pipe (all harmonics) or the tube (odd ones, the far end closed) */
    const int tube = type == 6;
    rs->kind = tube ? 3 : 2;
    /* each line delays sr / (K f0) + 0.75 samples: the reading's sr / (K f0) - 0.75 plus the
     * 1.5 samples its 5-tap read sits behind its nominal point */
    rs->delay = clampf(rate / ((tube ? 4.0f : 2.0f) * f0) + 0.75f, 3.5f, (float)(LE_COLLISION_PIPE - 3));
    rs->loss = expf(-4.0f / (T * f0 * exp2f(dd)));
    /* the knob runs inverted, 0 the widest */
    const float radius = k_exp(d, LE_COLLISION_RES(r, LE_COLLISION_R_RADIUS), 0.005f, 0.4f) /
                         exp2f(t[LE_COLLISION_D_R1_RADIUS + ko]);
    float o = tube ? 1.0f
                   : clampf(k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_OPENING), 0.005f, 1.0f) *
                                exp2f(t[LE_COLLISION_D_R1_OPENING + po]), 0.1f, 1.0f);
    const float k = fminf(344.0f / (rate * radius), 2.827f);
    const float P = (k + o) * o, M = (k - o) * o, c = 1.0f / (P + 1.0f);
    const float sgn = tube ? -1.0f : 1.0f;
    rs->rf_b0 = sgn * c * (1.0f - P);
    rs->rf_b1 = -sgn * c * (1.0f + M);
    rs->rf_a1 = c * (M - 1.0f);
    rs->gain_l *= amp;
    rs->gain_r *= amp;
    rs->pitch = pitch;
    return;
  }
  rs->kind = 1;
  int32_t n = kModes[ri(d, r, LE_COLLISION_R_QUALITY)];
  float ratio[LE_COLLISION_MODES];
  uint8_t mm[LE_COLLISION_MODES], nn[LE_COLLISION_MODES];
  const float aspect = k_exp(d, LE_COLLISION_RES(r, LE_COLLISION_R_RATIO), 1.0f, 20.0f);
  build_modes(rs, type, n, aspect, mm, nn, ratio);
  const float inh = k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_INHARMONICS), -1.0f, 1.0f) +
                    0.2f * t[LE_COLLISION_D_R1_INHARMONICS + ko];
  const float chi = clampf(inh * inh * inh, -1.0f, 1.0f);
  const float mat = clampf(k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_MATERIAL), -1.0f, 1.0f) +
                               t[LE_COLLISION_D_R1_MATERIAL + ko], -1.0f, 1.0f);
  const float bright = k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_BRIGHTNESS), -1.0f, 1.0f);
  const float ml = floorf(64.0f + 31.5f * clampf(rf(d, r, LE_COLLISION_R_LISTEN_L), 0.0f, 1.0f));
  const float mr = floorf(64.0f + 31.5f * clampf(rf(d, r, LE_COLLISION_R_LISTEN_R), 0.0f, 1.0f));
  const float xl = 0.01f + 0.98f * (ml == 64.0f ? 0.5f : ml / 127.0f);
  const float xr = 0.01f + 0.98f * (mr == 64.0f ? 0.5f : mr / 127.0f);
  const float hit = hit_at(d, v, r);
  int32_t used = 0;
  float top_w = 0.0f, top_b = 0.0f, top_g = 0.0f;
  for (int32_t k = 0; k < n; ++k) {
    const float rk = powf(ratio[k], 1.0f + chi);
    const float w = 2.0f * CV_PI * f0 * rk;
    if (w >= (5.0f * CV_PI / 6.0f) * rate) break;
    const float lr = log2f(fmaxf(ratio[k], 1e-6f));
    const float e = mat >= 0.0f ? (5.0f - lr) * mat - dd : -mat * lr - dd;
    const float alpha = fmaxf(8.0f / T * exp2f(e), 8.0f / 35.0f);
    const float th = w / rate;
    const float g = alpha * sinf(th) * (CV_PI / (CV_PI - th)) / w;
    /* a pitch move keeps the mode's amplitude: its newer state scales by the
     * old frequency over the new, its step from the older state stays */
    if (rs->pitch < 90.0f && k < rs->n && rs->om[k] > 0.0f) {
      const float r = rs->om[k] / w;
      rs->v2[k] += (r - 1.0f) * rs->v1[k];
      rs->v1[k] *= r;
    }
    rs->om[k] = w;
    rs->a1[k] = -2.0f * cosf(th) / (1.0f + g);
    rs->a2[k] = (1.0f - g) / (1.0f + g);
    const float B = powf(ratio[k] / 4.0f, bright) * exp2f(pitch);
    const float G = g * amp * B / (2.0f * alpha * (1.0f + g));
    rs->e[k] = 0.5f * shape(type, mm[k], nn[k], hit, n);
    rs->gl[k] = 3000.0f * G * 0.5f * shape(type, mm[k], nn[k], xl, n);
    rs->gr[k] = 3000.0f * G * 0.5f * shape(type, mm[k], nn[k], xr, n);
    used = k + 1;
    top_w = th;
    top_b = B;
    top_g = g;
  }
  for (int32_t k = used; k < rs->n; ++k) rs->v1[k] = rs->v2[k] = rs->om[k] = 0.0f;
  rs->n = used;
  /* the bleed: a heavily damped resonator at the highest mode, when every
   * mode fitted */
  rs->bleed_g = 0.0f;
  if (used == n && used > 0) {
    /* fit: Exp(0.001, 1), not the 0.01 the reading gave (the dense
     * membrane's highs, dn-hp and dn-mnoise-0; Music Box Basic, Noisy Pad,
     * Marimba Classic) */
    const float bl = k_exp(d, LE_COLLISION_RES(r, LE_COLLISION_R_BLEED), 0.001f, 1.0f);
    const float c = cosf(top_w);
    const float g = fminf(32.0f * top_g, 0.95f);
    bq_set(&rs->bleed, (1.0f + c) / 2.0f, -(1.0f + c), (1.0f + c) / 2.0f, 1.0f + g, -2.0f * c, 1.0f - g);
    rs->bleed_g = amp * top_b * bl;
  }
  rs->pitch = pitch;
}

static void tick_lfos(le_collision* d, le_collision_voice* v, int advance);

static void env_go(le_collision_voice* v, int32_t seg, float to, float seconds, float rate) {
  v->env_seg = seg;
  const float n = fmaxf(seconds * rate, 1.0f);
  v->env_step = (to - v->env) / n;
}

static void start_voice(le_collision* d, le_collision_voice* v, uint32_t origin, int32_t note, int32_t velocity,
                        int fresh) {
  const float rate = (float)d->sample_rate;
  const int same = !fresh && v->note == note;
  v->state = LE_COLLISION_VOICE_HELD;
  v->note = note;
  v->origin = origin;
  v->serial = ++d->serial;
  v->vel = (float)(velocity - 64) / 63.0f;
  v->fade_left = 0;
  v->fade_len = (int32_t)lroundf(0.001f * rate);
  v->quiet = 0;
  v->tick_left = 0;
  if (fresh) {
    v->rng = 0x2545f491u ^ (uint32_t)(v->serial * 2654435761u);
    memset(&v->pulse, 0, sizeof(v->pulse));
    memset(&v->mnoise, 0, sizeof(v->mnoise));
    memset(&v->nf1, 0, sizeof(v->nf1));
    memset(&v->nf2, 0, sizeof(v->nf2));
    v->nf_left = -1;
    v->env = 0.0f;
    for (int32_t l = 0; l < 2; ++l) v->lfo[l].out = v->lfo[l].rnd = v->lfo[l].rnd_prev = 0.0f;
  }
  /* the LFOs at their start: their phases, then their values from the
   * knob routes (the matrix without them), then the matrix */
  for (int32_t l = 0; l < 2; ++l) {
    if (li(d, l, LE_COLLISION_L_RETRIGGER) || fresh) {
      v->lfo[l].ph = (double)(lf(d, l, LE_COLLISION_L_PHASE) / 360.0f);
      v->lfo[l].rnd_prev = v->lfo[l].rnd; /* 0 on a fresh strike */
      v->lfo[l].rnd = 2.0f * (float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f - 1.0f;
    }
  }
  if (fresh) {
    matrix(d, v);
    tick_lfos(d, v, 0);
  }
  matrix(d, v);
  /* the mallet's pulse: a critically damped low-pass struck once */
  if (vi(d, LE_COLLISION_MALLET_ON)) {
    const float fs = clampf(k_exp(d, LE_COLLISION_MALLET_STIFFNESS, 2.0f, 5000.0f) *
                                exp2f(0.9803f * v->dest[LE_COLLISION_D_STIFFNESS]), 10.0f, 20000.0f);
    const float th = fminf(2.0f * CV_PI * fs / rate, 2.9919932f);
    const float a = sinf(th), c = cosf(th), K = rate / (4000.0f * th);
    bq_set(&v->pulse, K * (1.0f - c) / 2.0f, K * (1.0f - c), K * (1.0f - c) / 2.0f, 1.0f + a, -2.0f * c, 1.0f - a);
    v->pulse_in = k_exp(d, LE_COLLISION_MALLET_VOLUME, 0.001f, 1.0f) *
                  exp2f(0.9685f * v->dest[LE_COLLISION_D_MALLET_VOLUME]);
    bq_filter(&v->mnoise, 1, k_exp(d, LE_COLLISION_MALLET_NOISE_COLOR, 250.0f, 25000.0f), 0.7f, rate);
    v->pulse_len = (int32_t)(4.0f * rate / fs);
  } else {
    v->pulse_len = 0;
  }
  /* the noise source's envelope (idle while the source is off) */
  if (vi(d, LE_COLLISION_NOISE_ON)) {
    env_go(v, ENV_ATTACK, 1.0f, k_exp(d, LE_COLLISION_NOISE_ATTACK, 0.0005f, 20.0f), rate);
  } else {
    v->env_seg = ENV_IDLE;
    v->env = v->env_step = 0.0f;
  }
  for (int32_t r = 0; r < 2; ++r) strike_res(d, v, r, fresh || !same);
  v->age = 0;
  v->blk_n = 0;
  v->blk_pk = 0.0f;
}

static void release_voice(le_collision* d, le_collision_voice* v) {
  v->state = LE_COLLISION_VOICE_RELEASED;
  if (vi(d, LE_COLLISION_NOISE_ON) && v->env_seg != ENV_IDLE) {
    env_go(v, ENV_RELEASE, 0.0f, k_exp(d, LE_COLLISION_NOISE_RELEASE, 0.002f, 60.0f), (float)d->sample_rate);
  }
  (void)0; /* the off decay: the next tick sees the gate move */
}

static void let_go(le_collision* d, le_collision_voice* v) {
  if (d->sustain_n > 0) v->state = LE_COLLISION_VOICE_SUSTAINED;
  else release_voice(d, v);
}

int32_t le_collision_note_on(le_collision* d, uint32_t origin, int32_t note, int32_t velocity, int chord) {
  if (d == NULL || note < 0 || note > 127 || velocity < 1 || velocity > 127) return -1;
  if (!chord) {
    for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
      le_collision_voice* v = &d->voices[i];
      if (v->state == LE_COLLISION_VOICE_HELD && v->origin == origin) let_go(d, v);
    }
  }
  /* mono: the voice moves to the new key; Retrigger (Smart): a repeated
   * key strikes its own voice again */
  le_collision_voice* v = NULL;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS && v == NULL; ++i) {
    le_collision_voice* u = &d->voices[i];
    if (!sounding(u)) continue;
    if (vi(d, LE_COLLISION_POLYPHONY) == 0 || (vi(d, LE_COLLISION_RETRIGGER) && u->note == note)) v = u;
  }
  if (v != NULL) {
    start_voice(d, v, origin, note, velocity, 0);
    return 0;
  }
  const int32_t count = voice_count(d);
  /* a full device restarts its oldest note's own slot, as the engine's
   * voices are reused (fit: Bell Plate Long's phrase); a cut of the slot
   * count (the engine's limit) fades the rest */
  if (note_count(d) >= count) {
    le_collision_voice* o = oldest(d, LE_COLLISION_VOICE_RELEASED);
    if (o == NULL) o = oldest(d, LE_COLLISION_VOICE_SUSTAINED);
    if (o == NULL) o = oldest(d, LE_COLLISION_VOICE_HELD);
    if (o != NULL && note_count(d) == count) {
      d->stolen++;
      start_voice(d, o, origin, note, velocity, 1);
      return 0;
    }
  }
  while (note_count(d) >= count) {
    le_collision_voice* o = oldest(d, LE_COLLISION_VOICE_RELEASED);
    if (o == NULL) o = oldest(d, LE_COLLISION_VOICE_SUSTAINED);
    if (o == NULL) o = oldest(d, LE_COLLISION_VOICE_HELD);
    if (o == NULL) break;
    fade_voice(o);
    d->stolen++;
  }
  v = free_slot(d);
  if (v != NULL) start_voice(d, v, origin, note, velocity, 1);
  return 0;
}

void le_collision_note_off(le_collision* d, uint32_t origin) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    le_collision_voice* v = &d->voices[i];
    if (v->state == LE_COLLISION_VOICE_HELD && v->origin == origin) let_go(d, v);
  }
}

static void release_sustained(le_collision* d) {
  if (d->sustain_n > 0) return;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    if (d->voices[i].state == LE_COLLISION_VOICE_SUSTAINED) release_voice(d, &d->voices[i]);
  }
}

int32_t le_collision_sustain(le_collision* d, uint32_t origin, int on) {
  if (d == NULL) return -1;
  int32_t at = -1;
  for (int32_t i = 0; i < d->sustain_n; ++i) {
    if (d->sustain[i] == origin) at = i;
  }
  if (!on) {
    if (at >= 0) {
      d->sustain[at] = d->sustain[--d->sustain_n];
      release_sustained(d);
    }
    return 0;
  }
  if (at >= 0) return 0;
  if (d->sustain_n >= LE_COLLISION_SUSTAIN_MAX) {
    d->sustain_refused++;
    return -1;
  }
  d->sustain[d->sustain_n++] = origin;
  return 0;
}

void le_collision_expression(le_collision* d, int32_t kind, float value) {
  if (d == NULL || value != value) return;
  const float lo = kind == LE_SYNTH_BEND ? -1.0f : 0.0f;
  value = clampf(value, lo, 1.0f);
  if (kind == LE_SYNTH_BEND) d->bend = value;
  else if (kind == LE_SYNTH_MOD) d->mod = value;
  else if (kind == LE_SYNTH_PRESSURE) d->pressure = value;
}

void le_collision_release_matching(le_collision* d, uint32_t mask, uint32_t value) {
  if (d == NULL) return;
  for (int32_t i = d->sustain_n - 1; i >= 0; --i) {
    if ((d->sustain[i] & mask) == value) d->sustain[i] = d->sustain[--d->sustain_n];
  }
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    le_collision_voice* v = &d->voices[i];
    if (v->state == LE_COLLISION_VOICE_HELD && (v->origin & mask) == value) {
      let_go(d, v);
    } else if (v->state == LE_COLLISION_VOICE_SUSTAINED && d->sustain_n == 0) {
      release_voice(d, v);
    }
  }
}

int32_t le_collision_held(const le_collision* d, uint32_t origin) {
  if (d == NULL) return 0;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    const le_collision_voice* v = &d->voices[i];
    if (v->state == LE_COLLISION_VOICE_HELD && v->origin == origin) return 1;
  }
  return 0;
}

void le_collision_cut(le_collision* d) {
  if (d == NULL) return;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) fade_voice(&d->voices[i]);
  d->sustain_n = 0;
  d->bend = d->mod = d->pressure = 0.0f;
}

int32_t le_collision_fade_oldest(le_collision* d) {
  if (d == NULL) return 0;
  le_collision_voice* old = NULL;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    le_collision_voice* v = &d->voices[i];
    if (sounding(v) && (old == NULL || v->serial < old->serial)) old = v;
  }
  if (old == NULL) return 0;
  fade_voice(old);
  d->stolen++;
  return 1;
}

int32_t le_collision_active(const le_collision* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) n += sounding(&d->voices[i]);
  return n;
}

int32_t le_collision_fading(const le_collision* d) {
  if (d == NULL) return 0;
  int32_t n = 0;
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) n += d->voices[i].state == LE_COLLISION_VOICE_FADING;
  return n;
}

void le_collision_set_voice_limit(le_collision* d, int32_t limit) {
  if (d == NULL || limit < 1) return;
  d->voice_limit = limit > LE_COLLISION_VOICE_SLOTS ? LE_COLLISION_VOICE_SLOTS : limit;
  while (le_collision_active(d) > d->voice_limit) {
    if (!le_collision_fade_oldest(d)) break;
  }
}

/* ---- the control tick ---- */

/* The synced LFO lengths in whole notes, in the order of Live's menu: its
 * note values from the longest down. */
static float lfo_length(int32_t s) {
  static const float kLen[22] = {8.0f,         6.0f,         4.0f,        3.0f,         2.0f,          1.5f,
                                 1.0f,         0.75f,        0.5f,        0.375f,       1.0f / 3.0f,   0.3125f,
                                 0.25f,        0.1875f,      1.0f / 6.0f, 0.125f,       1.0f / 12.0f,  0.0625f,
                                 1.0f / 24.0f, 0.03125f,     1.0f / 48.0f, 0.015625f};
  return kLen[s < 0 ? 0 : s > 21 ? 21 : s];
}

/* Each LFO's output: moved on a tick when `advance`, else at its phase. */
static void tick_lfos(le_collision* d, le_collision_voice* v, int advance) {
  const float dt = (float)LE_COLLISION_TICK / (float)d->sample_rate;
  for (int32_t l = 0; l < 2; ++l) {
    le_collision_lfo* o = &v->lfo[l];
    if (!li(d, l, LE_COLLISION_L_ON)) {
      o->out = 0.0f;
      continue;
    }
    const int32_t shape = li(d, l, LE_COLLISION_L_SHAPE);
    float hz = li(d, l, LE_COLLISION_L_SYNC)
                   ? d->bpm / (240.0f * lfo_length(li(d, l, LE_COLLISION_L_SYNC_RATE)))
                   /* fit: the free rate is not taken down to its step */
                   : 0.01f * powf(1000.0f, m_of(LE_COLLISION_LFO(l, LE_COLLISION_L_RATE),
                                                lf(d, l, LE_COLLISION_L_RATE)) / 127.0f);
    hz = fminf(hz * exp2f(v->dest[LE_COLLISION_D_LFO1_RATE + 2 * l]), 10.0f);
    if (shape == 5) hz *= 2.0f; /* sample and hold runs at twice the rate */
    if (advance) o->ph += (double)fminf(hz * dt, 0.5f);
    if (o->ph >= 1.0) {
      o->ph -= floor(o->ph);
      o->rnd_prev = o->rnd;
      o->rnd = 2.0f * (float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f - 1.0f;
    }
    const float p = (float)o->ph;
    float y;
    switch (shape) {
      case 0: y = sinf(2.0f * CV_PI * p); break;
      case 1: y = p < 0.5f ? -1.0f : 1.0f; break;
      case 2: y = p < 0.5f ? 4.0f * p - 1.0f : 3.0f - 4.0f * p; break;
      case 3: y = 2.0f * p - 1.0f; break;
      case 4: y = 1.0f - 2.0f * p; break;
      case 5: y = o->rnd; break;
      default: y = o->rnd_prev + (o->rnd - o->rnd_prev) * p; break;
    }
    const float depth = k_lin(d, LE_COLLISION_LFO(l, LE_COLLISION_L_DEPTH), 0.0f, 1.0f);
    o->out = clampf(y * exp2f(v->dest[LE_COLLISION_D_LFO1_DEPTH + 2 * l]) * depth, -1.0f, 1.0f);
  }
}

/* One biquad's unnormalised coefficients b0 b1 b2 a0 a1 a2 (RBJ; the
 * band-pass of constant skirt). */
static void bq_raw(float* q, int32_t type, float f, float qq, float rate) {
  f = clampf(f, 0.0003f * rate, 0.45f * rate);
  qq = clampf(qq, 0.05f, 100.0f);
  const float w = 2.0f * CV_PI * f / rate, c = cosf(w), s = sinf(w), a = s / (2.0f * qq);
  if (type == 0) q[0] = q[2] = (1.0f - c) / 2.0f, q[1] = 1.0f - c;
  else if (type == 1) q[0] = q[2] = (1.0f + c) / 2.0f, q[1] = -(1.0f + c);
  else q[0] = s / 2.0f, q[1] = 0.0f, q[2] = -s / 2.0f;
  q[3] = 1.0f + a;
  q[4] = -2.0f * c;
  q[5] = 1.0f - a;
}

/* The noise filters' coefficients at the envelope's current value: q1 the
 * first filter, q2 the low-pass of the LP + HP pair. */
static void noise_raw(const le_collision* d, const le_collision_voice* v, float* q1, float* q2) {
  const float rate = (float)d->sample_rate;
  const int32_t type = vi(d, LE_COLLISION_NOISE_FILTER);
  const float f = k_exp(d, LE_COLLISION_NOISE_FREQ, 50.0f, 18000.0f) * exp2f(v->dest[LE_COLLISION_D_NOISE_FREQ]) *
                  exp2f(vf(d, LE_COLLISION_NOISE_FREQ_ENV) * v->env);
  if (type == 3) {
    const float w = k_lin(d, LE_COLLISION_NOISE_Q, 0.5f, 9.0f);
    bq_raw(q1, 1, clampf(f / exp2f(0.5f * w), 50.0f, 18000.0f), 0.707f, rate);
    bq_raw(q2, 0, clampf(f * exp2f(0.5f * w), 50.0f, 18000.0f), 0.707f, rate);
  } else {
    bq_raw(q1, type, f, k_exp(d, LE_COLLISION_NOISE_Q, 0.2f, 3.0f), rate);
    memcpy(q2, q1, sizeof(float) * 6);
  }
}

static void tick_voice(le_collision* d, le_collision_voice* v) {
  const float rate = (float)d->sample_rate;
  /* the noise source off: its envelope idle, so the voice can end */
  if (!vi(d, LE_COLLISION_NOISE_ON)) {
    v->env_seg = ENV_IDLE;
    v->env = v->env_step = 0.0f;
  }
  tick_lfos(d, v, 1);
  matrix(d, v);
  const int released = v->state == LE_COLLISION_VOICE_RELEASED || v->state == LE_COLLISION_VOICE_FADING;
  for (int32_t r = 0; r < 2; ++r) {
    if (!ri(d, r, LE_COLLISION_R_ON)) {
      v->r[r].kind = 0;
      continue;
    }
    le_collision_res* rs = &v->r[r];
    const float pe = rs->pe;
    const float pitch = clampf((float)ri(d, r, LE_COLLISION_R_TUNE) / 12.0f +
                                   k_lin(d, LE_COLLISION_RES(r, LE_COLLISION_R_FINE), -0.5f, 0.5f) / 12.0f +
                                   v->dest[LE_COLLISION_D_R1_PITCH + r * (LE_COLLISION_D_R2_PITCH - LE_COLLISION_D_R1_PITCH)] + pe,
                               -5.0f, 5.5833f);
    /* the coefficients follow pitch moves above 0.00083 octave, the gate,
     * the knobs and the matrix's resonator routes */
    const int32_t ko = r * (LE_COLLISION_D_R2_DECAY - LE_COLLISION_D_R1_DECAY);
    const int32_t po = r * (LE_COLLISION_D_R2_PITCH - LE_COLLISION_D_R1_PITCH);
    const float key[7] = {v->dest[LE_COLLISION_D_R1_DECAY + ko], v->dest[LE_COLLISION_D_R1_MATERIAL + ko],
                          v->dest[LE_COLLISION_D_R1_RADIUS + ko], v->dest[LE_COLLISION_D_R1_INHARMONICS + ko],
                          v->dest[LE_COLLISION_D_R1_PAN + po], v->dest[LE_COLLISION_D_R1_OPENING + po],
                          v->dest[LE_COLLISION_D_R1_HIT + po]};
    /* a pitch move retunes the modes at most every 6 ticks (the engine's 200
     * samples) */
    rs->since += LE_COLLISION_TICK;
    int moved = (fabsf(pitch - rs->pitch) > 0.00083f && rs->since >= 6 * LE_COLLISION_TICK) || rs->kind == 0 ||
                released != rs->released || rs->serial != d->serial_values || rs->pitch > 90.0f;
    for (int32_t k = 0; k < 7 && !moved; ++k) moved = fabsf(key[k] - rs->key[k]) > 1e-4f;
    if (moved) {
      tune_res(d, v, r, pitch, released);
      rs->since = 0;
      rs->released = released;
      rs->serial = d->serial_values;
      memcpy(rs->key, key, sizeof(key));
    }
    /* the pitch envelope falls across this tick */
    if (rs->pe != 0.0f) {
      rs->pe_left -= LE_COLLISION_TICK;
      rs->pe_x *= rs->pe_mul;
      rs->pe = rs->pe_left > 0 ? rs->pe_amp * (rs->pe_x - 0.0313935f) : 0.0f;
    }
  }
}

/* ---- rendering ---- */

static float lagrange5(const float* line, int32_t w, float dl) {
  const int32_t i0 = (int32_t)floorf(dl) - 2;
  const float x = dl - (float)i0;
  float y = 0.0f;
  for (int32_t k = 0; k < 5; ++k) {
    float h = 1.0f;
    for (int32_t j = 0; j < 5; ++j) {
      if (j != k) h *= (x - (float)j) / (float)(k - j);
    }
    y += h * line[(w - i0 - k) & CV_MASK];
  }
  return y;
}

/* One sample of resonator rs on input x: its left and right, and in *raw
 * the tap resonator 2 hears in series. */
static void res_tick(le_collision_res* rs, float x, float rate, float* l, float* r, float* raw) {
  if (rs->kind == 1) {
    float sl = 0.0f, sr = 0.0f;
    for (int32_t k = 0; k < rs->n; ++k) {
      const float vn = rs->e[k] * x - rs->a1[k] * rs->v1[k] - rs->a2[k] * rs->v2[k];
      const float d = vn - rs->v2[k];
      rs->v2[k] = rs->v1[k];
      rs->v1[k] = vn;
      sl += rs->gl[k] * d;
      sr += rs->gr[k] * d;
    }
    if (rs->bleed_g > 0.0f) {
      const float b = rs->bleed_g * bq_tick(&rs->bleed, x);
      sl += b;
      sr += b;
    }
    *raw = sl + sr; /* the outputs' sum, the bleed's included */
    *l = sl;
    *r = sr;
    return;
  }
  if (rs->kind >= 2) {
    /* the excitation end: the input through a 30 Hz high-pass, against the
     * returning wave; the far end's reflection filter */
    const float hw = 2.0f * CV_PI * 30.0f / rate;
    const float ha = (2.0f - hw) / (2.0f + hw), hb = 2.0f / (2.0f + hw);
    rs->hp_y = hb * (x - rs->hp_x) + ha * rs->hp_y;
    rs->hp_x = x;
    const float back = lagrange5(rs->bw, rs->w, rs->delay);
    rs->fw[rs->w] = rs->hp_y - 0.999f * back;
    const float arrive = lagrange5(rs->fw, rs->w, rs->delay);
    const float y = rs->rf_b0 * arrive + rs->rf_b1 * rs->rf_x1 - rs->rf_a1 * rs->rf_y1;
    rs->rf_x1 = arrive;
    rs->rf_y1 = y;
    rs->bw[rs->w] = rs->loss * y;
    rs->w = (rs->w + 1) & CV_MASK;
    *l = *r = y;
    *raw = 2.0f * y;
    return;
  }
  *l = *r = *raw = 0.0f;
}

static void render_voice(le_collision* d, le_collision_voice* v, float* left, float* right, int32_t frames) {
  const float rate = (float)d->sample_rate;
  const int mallet = vi(d, LE_COLLISION_MALLET_ON), noise = vi(d, LE_COLLISION_NOISE_ON);
  const int serial = vi(d, LE_COLLISION_STRUCTURE) == 0;
  if (!v->r[0].kind) v->r[0].gain_l = v->r[0].gain_r = 0.0f;
  if (!v->r[1].kind) v->r[1].gain_l = v->r[1].gain_r = 0.0f;
  const float nvol = k_exp(d, LE_COLLISION_NOISE_VOLUME, 0.001f, 1.0f);
  const float sus = k_sq(d, LE_COLLISION_NOISE_SUSTAIN, 0.0f, 1.0f);
  const int32_t quiet_end = (int32_t)(0.05f * rate);
  const float fade_step = 1.0f / (float)(v->fade_len > 0 ? v->fade_len : 1);
  int32_t settle = v->pulse_len;
  for (int32_t r = 0; r < 2; ++r) {
    if (v->r[r].kind >= 2) settle += 2 * (int32_t)v->r[r].delay + 8;
  }
  int32_t i = 0;
  while (i < frames && v->state != LE_COLLISION_VOICE_FREE) {
    if (v->tick_left <= 0) {
      tick_voice(d, v);
      v->tick_left = LE_COLLISION_TICK;
    }
    const int32_t n = v->tick_left < frames - i ? v->tick_left : frames - i;
    const float w_noise = mallet ? powf(atanf(k_lin(d, LE_COLLISION_MALLET_NOISE, -4.0f, 4.0f) +
                                              0.9685f * v->dest[LE_COLLISION_D_MALLET_NOISE]) / CV_PI + 0.5f,
                                        3.0f)
                                 : 0.0f;
    const float ng = nvol * exp2f(v->dest[LE_COLLISION_D_NOISE_VOLUME]);
    const float in2 = exp2f(v->dest[LE_COLLISION_D_R2_INPUT]);
    const float vg = exp2f(v->dest[LE_COLLISION_D_VOLUME]);
    const int held = v->state == LE_COLLISION_VOICE_HELD || v->state == LE_COLLISION_VOICE_SUSTAINED;
    for (int32_t s = 0; s < n; ++s) {
      float x = 0.0f;
      if (mallet) {
        const float p = bq_tick(&v->pulse, v->pulse_in);
        v->pulse_in = 0.0f;
        const float nz = bq_tick(&v->mnoise, 2.0f * (float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f - 1.0f);
        x = p * ((1.0f - w_noise) + w_noise * nz);
      }
      if (noise && v->env_seg != ENV_IDLE) {
        /* the envelope: attack to 1, decay to sustain, hold, release */
        v->env += v->env_step;
        if (v->env_seg == ENV_ATTACK && v->env >= 1.0f) {
          v->env = 1.0f;
          env_go(v, ENV_DECAY, sus, k_exp(d, LE_COLLISION_NOISE_DECAY, 0.002f, 60.0f), rate);
        } else if (v->env_seg == ENV_DECAY && v->env <= sus) {
          v->env = sus;
          v->env_seg = ENV_SUSTAIN;
          v->env_step = 0.0f;
          if (!held) env_go(v, ENV_RELEASE, 0.0f, k_exp(d, LE_COLLISION_NOISE_RELEASE, 0.002f, 60.0f), rate);
        } else if (v->env_seg == ENV_RELEASE && v->env <= 0.0f) {
          v->env = 0.0f;
          v->env_seg = ENV_IDLE;
          v->env_step = 0.0f;
        }
        /* the filters: set at the strike and when a knob moves; then, if the
         * envelope or a route moves the cutoff, stepped to the new values
         * every 10 ms (as the engine's own update; fit: Toy Piano Bells,
         * noise-env) */
        if (v->nf_left < 0 || v->nf_serial != d->serial_values ||
            (--v->nf_left <= 0 && (vf(d, LE_COLLISION_NOISE_FREQ_ENV) != 0.0f ||
                                   v->dest[LE_COLLISION_D_NOISE_FREQ] != 0.0f))) {
          v->nf_serial = d->serial_values;
          float q[12];
          noise_raw(d, v, q, q + 6);
          bq_set(&v->nf1, q[0], q[1], q[2], q[3], q[4], q[5]);
          bq_set(&v->nf2, q[6], q[7], q[8], q[9], q[10], q[11]);
        }
        if (v->nf_left <= 0) v->nf_left = d->sample_rate / 100;
        float z = 2.0f * (float)((v->rng = v->rng * 1664525u + 1013904223u) >> 8) / 16777216.0f - 1.0f;

        z = bq_tick(&v->nf1, z);
        if (vi(d, LE_COLLISION_NOISE_FILTER) == 3) z = bq_tick(&v->nf2, z);
        x += z * v->env * ng;
      }
      float l1 = 0.0f, r1 = 0.0f, l2 = 0.0f, r2 = 0.0f, t1 = 0.0f, t2 = 0.0f;
      if (v->r[0].kind) res_tick(&v->r[0], x, rate, &l1, &r1, &t1);
      if (v->r[1].kind) {
        /* 1 > 2: resonator 1's own output (L + R, before its amp); 1 + 2:
         * the exciter */
        res_tick(&v->r[1], (serial ? t1 : x) * in2, rate, &l2, &r2, &t2);
      }
      float g = vg;
      if (v->state == LE_COLLISION_VOICE_FADING) g *= fade_step * (float)(v->fade_left > s ? v->fade_left - s : 0);
      /* each resonator's volume and pan ramp to their values over 2 ms, from
       * where the slot's last note left them (a slot never played starts
       * at the knobs' own, without the key's or the matrix's pan) (fit: the
       * phrase renders' side signal) */
      for (int32_t q = 0; q < 2; ++q) {
        le_collision_res* rq = &v->r[q];
        if (rq->amp_n < 0) {
          const float vol = k_sq(d, LE_COLLISION_RES(q, LE_COLLISION_R_VOLUME), 0.0f, 2.0f) * (rq->kind >= 2 ? 1.011f : 1.0f);
          const float p0 = k_lin(d, LE_COLLISION_RES(q, LE_COLLISION_R_PAN), -1.0f, 1.0f);
          rq->amp_l = vol * fminf(1.0f, 1.0f - p0);
          rq->amp_r = vol * fminf(1.0f, 1.0f + p0);
          rq->amp_n = 0;
          rq->amp_tl = rq->amp_tr = -1.0f;
        }
        if (rq->gain_l != rq->amp_tl || rq->gain_r != rq->amp_tr) {
          rq->amp_tl = rq->gain_l;
          rq->amp_tr = rq->gain_r;
          rq->amp_n = d->sample_rate / 500;
          rq->amp_sl = (rq->gain_l - rq->amp_l) / (float)rq->amp_n;
          rq->amp_sr = (rq->gain_r - rq->amp_r) / (float)rq->amp_n;
        }
        if (rq->amp_n > 0) {
          rq->amp_l += rq->amp_sl;
          rq->amp_r += rq->amp_sr;
          if (--rq->amp_n == 0) rq->amp_l = rq->amp_tl, rq->amp_r = rq->amp_tr;
        }
      }
      float yl = g * (v->r[0].amp_l * l1 + v->r[1].amp_l * l2), yr = g * (v->r[0].amp_r * r1 + v->r[1].amp_r * r2);
      yl = yl == yl ? clampf(yl, -1e6f, 1e6f) : 0.0f;
      yr = yr == yr ? clampf(yr, -1e6f, 1e6f) : 0.0f;
      if (v->age < settle) v->age++;
      left[i + s] += yl;
      right[i + s] += yr;
      /* fit: a voice, held or not, ends at the first 512-sample block whose
       * resonator outputs (before their volumes) stay below 6e-6 once its
       * exciters are spent (Live's renders stop at about -94 dBFS) */
      v->blk_pk = fmaxf(v->blk_pk, fmaxf(fmaxf(fabsf(l1), fabsf(r1)), fmaxf(fabsf(l2), fabsf(r2))));
      if (++v->blk_n >= 512) {
        const int dead = v->blk_pk < 6e-6f && v->age >= settle &&
                         (v->env_seg == ENV_IDLE || (v->env_seg == ENV_SUSTAIN && v->env <= 0.0f));
        v->blk_n = 0;
        v->blk_pk = 0.0f;
        if (dead) {
          v->state = LE_COLLISION_VOICE_FREE;
          return;
        }
      }
      /* fit: a released voice ends after 50 ms below -100 dBFS */
      if (v->state == LE_COLLISION_VOICE_RELEASED) {
        v->quiet = fmaxf(fabsf(yl), fabsf(yr)) < 1e-5f && v->env_seg == ENV_IDLE && v->age >= settle ? v->quiet + 1 : 0;
        if (v->quiet >= quiet_end) {
          v->state = LE_COLLISION_VOICE_FREE;
          return;
        }
      }
    }
    v->tick_left -= n;
    i += n;
    if (v->state == LE_COLLISION_VOICE_FADING) {
      v->fade_left -= n;
      if (v->fade_left <= 0) v->state = LE_COLLISION_VOICE_FREE;
    }
  }
}

void le_collision_render(le_collision* d, float* left, float* right, int32_t frames) {
  if (d == NULL || left == NULL || right == NULL || frames <= 0) return;
  memset(left, 0, sizeof(float) * (size_t)frames);
  memset(right, 0, sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < LE_COLLISION_VOICE_SLOTS; ++i) {
    le_collision_voice* v = &d->voices[i];
    if (v->state != LE_COLLISION_VOICE_FREE) render_voice(d, v, left, right, frames);
  }
  /* the master volume, Sq(0, 2), smoothed over 1 ms, then the bundle's x4
   * (fit: the renders sit 12 dB above the voices' sum), then a look-ahead
   * peak limiter at 1 (fit: renders that would pass 1 hold their peaks at
   * exactly 1 with little distortion, measured from the lim-* renders,
   * mvol-08, mvol-09, serial-m03 and serial-m04). The engine's output lags
   * the strike by 16 samples (a third of a millisecond); the limiter delays
   * it 1 ms more. The gain a sample needs (1 over its peak, at most 1) is
   * taken as the least over the 1 ms ahead and the third of a millisecond
   * behind; the gain released from it rises towards 1 with a 5.3 ms time
   * constant and falls at once to it, then is smoothed with a 0.225 ms one;
   * a slow gain, never more than 0.79 dB down, falls at once to the need
   * and rises back with a 197 ms one; the lower of the two applies. */
  const float target = k_sq(d, LE_COLLISION_VOLUME, 0.0f, 2.0f);
  if (d->gain < 0.0f) d->gain = target;
  const float rate = (float)d->sample_rate;
  const float a = 1.0f / (0.001f * rate);
  const uint32_t ahead = (uint32_t)(d->sample_rate / 1000), lag = (uint32_t)(d->sample_rate / 3000);
  const uint32_t span = ahead + lag; /* the window: the need's least over span + 1 samples */
  const float rel = 1.0f - expf(-1.0f / (0.0053f * rate));
  const float att = 1.0f - expf(-1.0f / (0.000225f * rate));
  const float slow = 1.0f - expf(-1.0f / (0.197f * rate));
  const float floor_slow = 0.91310f; /* -0.79 dB */
  const uint32_t mask = LE_COLLISION_LIM_RING - 1;
  for (int32_t s = 0; s < frames; ++s) {
    d->gain += a * (target - d->gain);
    const uint32_t n = d->lim_n++;
    d->lim_l[n & mask] = 4.0f * d->gain * left[s];
    d->lim_r[n & mask] = 4.0f * d->gain * right[s];
    /* the limiter sees the output 16 samples late, as it leaves the engine */
    const uint32_t j = n - lag;
    const float pk = fmaxf(fabsf(d->lim_l[j & mask]), fabsf(d->lim_r[j & mask]));
    const float need = pk > 1.0f ? 1.0f / pk : 1.0f;
    while (d->lim_tail != d->lim_head && d->lim_qv[(d->lim_tail - 1) & mask] >= need) d->lim_tail--;
    d->lim_qv[d->lim_tail & mask] = need;
    d->lim_qi[d->lim_tail & mask] = j;
    d->lim_tail++;
    while ((int32_t)(j - d->lim_qi[d->lim_head & mask]) > (int32_t)span) d->lim_head++;
    const float t = d->lim_qv[d->lim_head & mask];
    d->lim_rel = fminf(t, d->lim_rel + (1.0f - d->lim_rel) * rel);
    d->lim_fast += (d->lim_rel - d->lim_fast) * att;
    const float ts = fmaxf(t, floor_slow);
    d->lim_slow = ts < d->lim_slow ? ts : d->lim_slow + (1.0f - d->lim_slow) * slow;
    const float g = fminf(d->lim_fast, d->lim_slow);
    /* the sample 1 ms behind the window's front, 16 + 1 ms behind the input */
    const uint32_t o = j - ahead;
    left[s] = clampf(d->lim_l[o & mask] * g, -1.0f, 1.0f);
    right[s] = clampf(d->lim_r[o & mask] * g, -1.0f, 1.0f);
  }
}
