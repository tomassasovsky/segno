/*
 * aas_parts.h — the parts Analog and Tension share (SEG-109): the knob
 * curves of their engine, its envelope, its LFO waves and tempo divisions,
 * and its multimode filter with the formant types and the drive.
 *
 * Both devices' behavior is in docs/brainstorm/2026-11-24-ableton-devices-
 * brainstorm-doc.md ("Analog: behavior", "Tension: behavior"); the two
 * engines are built from the same modules, so their devices here use the
 * same code. Header-only (static inline), pure, real-time safe.
 */
#ifndef SEGNO_AAS_PARTS_H
#define SEGNO_AAS_PARTS_H

#include <math.h>
#include <stdint.h>

#define LE_AAS_PI 3.14159265358979f

/* ---- the knob curves ---- */

static inline float le_aas_clamp(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

/* A knob position 0..1 on the engine's 0..127 scale (0.5 is exactly 64),
 * as a fraction of full scale. */
static inline float le_aas_knob(float v) {
  v = le_aas_clamp(v, 0.0f, 1.0f);
  const float m = v <= 0.5f ? 128.0f * v : 126.0f * v + 1.0f;
  return m / 127.0f;
}

static inline float le_aas_exp(float lo, float hi, float v) { return lo * powf(hi / lo, le_aas_knob(v)); }
static inline float le_aas_lin(float lo, float hi, float v) { return lo + (hi - lo) * le_aas_knob(v); }
static inline float le_aas_sq(float lo, float hi, float v) {
  const float u = le_aas_knob(v);
  return lo + (hi - lo) * u * u;
}

/* A bipolar amount: its magnitude through the curve, then its sign. */
static inline float le_aas_bsq(float hi, float v) {
  return (v < 0.0f ? -1.0f : 1.0f) * le_aas_sq(0.0f, hi, fabsf(v));
}
/* Through the fourth power of its magnitude (the filter envelope's depth). */
static inline float le_aas_bq4(float hi, float v) {
  const float u = le_aas_knob(fabsf(v));
  return (v < 0.0f ? -1.0f : 1.0f) * hi * u * u * u * u;
}
static inline float le_aas_blin(float hi, float v) {
  return (v < 0.0f ? -1.0f : 1.0f) * le_aas_lin(0.0f, hi, fabsf(v));
}

/* ---- noise ---- */

static inline uint32_t le_aas_xs(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}
static inline float le_aas_unit(uint32_t* s) { return (float)(le_aas_xs(s) >> 8) * (1.0f / 16777216.0f); }
static inline float le_aas_bipolar(uint32_t* s) { return 2.0f * le_aas_unit(s) - 1.0f; }

/* ---- the envelope ---- */

/* Its segments: attack, decay, the sustain stage, the stage after the
 * sustain time, release, done, and a retrigger's drop before its attack. */
enum { LE_AAS_SEG_ATTACK = 0, LE_AAS_SEG_DECAY, LE_AAS_SEG_SUSTAIN, LE_AAS_SEG_POST, LE_AAS_SEG_RELEASE,
       LE_AAS_SEG_IDLE, LE_AAS_SEG_DROP };

/* Its knobs, in Analog's stored order (LE_ANALOG_ENV_*). */
enum { LE_AAS_ENV_EXP = 0, LE_AAS_ENV_LOOP, LE_AAS_ENV_FREE_RUN, LE_AAS_ENV_LEGATO, LE_AAS_ENV_ATTACK_VEL,
       LE_AAS_ENV_ATTACK, LE_AAS_ENV_DECAY, LE_AAS_ENV_VEL, LE_AAS_ENV_SUSTAIN, LE_AAS_ENV_SUSTAIN_TIME,
       LE_AAS_ENV_RELEASE, LE_AAS_ENV_FIELDS };

typedef struct le_aas_env {
  int32_t seg;  /* LE_AAS_SEG_* */
  int32_t left; /* samples left in the segment, -1 holding */
  float y, y0, to, c, step;
  float scale;  /* velocity's level scale */
} le_aas_env;

/* The envelope's settings, from its knobs. */
typedef struct le_aas_env_set {
  float attack, decay, release, sustain, sustain_time; /* seconds, level */
  int exp_, loop, free_run;
  float vel_level, vel_time; /* 0..8 */
} le_aas_env_set;

static inline le_aas_env_set le_aas_env_read(const float* k) {
  le_aas_env_set e;
  e.attack = le_aas_exp(0.005f, 15.0f, k[LE_AAS_ENV_ATTACK]);
  e.decay = le_aas_exp(0.005f, 15.0f, k[LE_AAS_ENV_DECAY]);
  e.release = le_aas_exp(0.005f, 15.0f, k[LE_AAS_ENV_RELEASE]);
  e.sustain = le_aas_lin(0.0f, 1.0f, k[LE_AAS_ENV_SUSTAIN]);
  e.sustain_time = le_aas_exp(0.1f, 1000.0f, k[LE_AAS_ENV_SUSTAIN_TIME]);
  e.exp_ = (int)k[LE_AAS_ENV_EXP];
  e.loop = (int)k[LE_AAS_ENV_LOOP];
  e.free_run = (int)k[LE_AAS_ENV_FREE_RUN];
  e.vel_level = le_aas_lin(0.0f, 8.0f, k[LE_AAS_ENV_VEL]);
  e.vel_time = le_aas_lin(0.0f, 8.0f, k[LE_AAS_ENV_ATTACK_VEL]);
  return e;
}

static inline void le_aas_env_segment(le_aas_env* e, int32_t seg, float to, float seconds, int exp_, float rate) {
  e->seg = seg;
  e->y0 = e->y;
  e->to = to;
  int32_t n = (int32_t)(seconds * rate);
  if (n < 1) n = 1;
  e->left = n;
  e->step = (to - e->y) / (float)n;
  e->c = exp_ ? 3.4906588f / (float)n : 0.0f;
  if (e->c > 1.0f) e->c = 1.0f;
}

static inline float le_aas_env_attack_time(const le_aas_env_set* p, float vel) {
  return p->attack * exp2f(-p->vel_time * (vel - 0.5f));
}

static inline void le_aas_env_start(le_aas_env* e, const le_aas_env_set* p, float vel, float rate,
                                    int from_current) {
  e->scale = exp2f(p->vel_level * (vel - 0.5f));
  if (!from_current) e->y = 0.0f;
  le_aas_env_segment(e, LE_AAS_SEG_ATTACK, e->scale, le_aas_env_attack_time(p, vel), p->exp_, rate);
}

/* A retrigger: a straight fall to 0 over 0.7 ms, then the attack (fit:
 * Analog's glide renders' dip at the key change). */
static inline void le_aas_env_drop(le_aas_env* e, const le_aas_env_set* p, float vel, float rate) {
  e->scale = exp2f(p->vel_level * (vel - 0.5f));
  if (e->seg == LE_AAS_SEG_IDLE) e->y = 0.0f;
  le_aas_env_segment(e, LE_AAS_SEG_DROP, 0.0f, 0.0007f, 0, rate);
}

/* fit (the Analog envelope renders): the sustain stage is a fall from the
 * sustain level to 0 over Sustain Time (its top position holds); loop
 * mode 1 repeats attack and decay while the gate is held; mode 2 attack,
 * decay and release; mode 3 lets the sustain fall like mode 0, and at the
 * gate's end rises again over the attack time before the release. */
static inline void le_aas_env_release(le_aas_env* e, const le_aas_env_set* p, float vel, float rate) {
  if (e->seg == LE_AAS_SEG_IDLE || e->seg == LE_AAS_SEG_RELEASE) return;
  if (p->loop == 3 && !(e->seg == LE_AAS_SEG_POST && e->left >= 0)) {
    le_aas_env_segment(e, LE_AAS_SEG_POST, e->scale, le_aas_env_attack_time(p, vel), p->exp_, rate);
    return;
  }
  le_aas_env_segment(e, LE_AAS_SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
}

/* The segment after `seg` ends. `held`: the gate is on. */
static inline void le_aas_env_next(le_aas_env* e, const le_aas_env_set* p, int held, float vel, float rate) {
  switch (e->seg) {
    case LE_AAS_SEG_ATTACK:
      le_aas_env_segment(e, LE_AAS_SEG_DECAY, p->sustain * e->scale, p->decay, p->exp_, rate);
      break;
    case LE_AAS_SEG_DECAY:
      if (p->loop == 1 && held) {
        le_aas_env_segment(e, LE_AAS_SEG_ATTACK, e->scale, le_aas_env_attack_time(p, vel), p->exp_, rate);
      } else if (p->free_run || p->loop == 2) {
        le_aas_env_segment(e, LE_AAS_SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
      } else if (p->sustain_time >= 999.0f) {
        e->seg = LE_AAS_SEG_SUSTAIN;
        e->left = -1;
      } else {
        le_aas_env_segment(e, LE_AAS_SEG_SUSTAIN, 0.0f, p->sustain_time, p->exp_, rate);
      }
      break;
    case LE_AAS_SEG_SUSTAIN:
      if (p->loop == 3) {
        /* waits at 0 for the gate's end */
        e->seg = LE_AAS_SEG_POST;
        e->left = -1;
      } else {
        e->seg = LE_AAS_SEG_IDLE;
      }
      e->y = 0.0f;
      break;
    case LE_AAS_SEG_DROP:
      le_aas_env_segment(e, LE_AAS_SEG_ATTACK, e->scale, le_aas_env_attack_time(p, vel), p->exp_, rate);
      break;
    case LE_AAS_SEG_POST:
      /* mode 3's rise at the gate's end, then the release */
      le_aas_env_segment(e, LE_AAS_SEG_RELEASE, 0.0f, p->release, p->exp_, rate);
      break;
    case LE_AAS_SEG_RELEASE:
      if (p->loop == 2 && held) {
        le_aas_env_segment(e, LE_AAS_SEG_ATTACK, e->scale, le_aas_env_attack_time(p, vel), p->exp_, rate);
      } else {
        e->seg = LE_AAS_SEG_IDLE;
        e->y = 0.0f;
      }
      break;
    default:
      break;
  }
}

static inline float le_aas_env_tick(le_aas_env* e, const le_aas_env_set* p, int held, float vel, float rate) {
  if (e->seg == LE_AAS_SEG_IDLE) return 0.0f;
  if (e->left < 0) return e->seg == LE_AAS_SEG_SUSTAIN ? (e->y = p->sustain * e->scale) : e->y;
  if (e->c > 0.0f) {
    /* toward an overshoot so the one-pole lands on the target in time */
    e->y = e->y * (1.0f - e->c) + e->c * (e->y0 + 1.0313935f * (e->to - e->y0));
  } else {
    e->y += e->step;
  }
  if (--e->left <= 0) {
    e->y = e->to;
    le_aas_env_next(e, p, held, vel, rate);
  }
  return e->y;
}

/* ---- the LFO ---- */

/* The tempo divisions 0..23 in beats per cycle: 16 beats down to an
 * eighth of a beat, each dotted, straight and triplet (fit: Analog's brass
 * presets' LFO pan, whose divisions 3 and 4 run 6 and 4 s at 120 BPM). */
static inline float le_aas_sync_beats(int32_t s) {
  static const float beats[8] = {16.0f, 8.0f, 4.0f, 2.0f, 1.0f, 0.5f, 0.25f, 0.125f};
  if (s < 0) s = 0;
  if (s > 23) s = 23;
  const int32_t kind = s % 3;
  const float b = beats[s / 3];
  return kind == 0 ? 1.5f * b : kind == 1 ? b : b * 2.0f / 3.0f;
}

/* Sine, triangle, rectangle, sample and hold, noise at phase p; w the
 * pulse width, sh this cycle's random value and sh_prev the last one's. */
static inline float le_aas_lfo_shape(int32_t wave, double p, float w, float sh, float sh_prev) {
  switch (wave) {
    case 0: return sinf(2.0f * LE_AAS_PI * (float)p);
    case 1: {
      /* starts at its top (fit: the lfo-wave renders); the fall lasts w of
       * the cycle */
      const float x = (float)p;
      return x < w ? 1.0f - 2.0f * x / w : -1.0f + 2.0f * (x - w) / (1.0f - w);
    }
    case 2: return p < w ? 1.0f : -1.0f;
    case 3: return sh; /* sample and hold */
    /* fit: noise ramps from one cycle's random value to the next (the
     * lfo-wave renders) */
    default: return sh_prev + (sh - sh_prev) * (float)p;
  }
}

/* ---- the multimode filter ---- */

/* Types 0..9: LP12, LP24, BP6, BP12, Notch 2, Notch 4, HP12, HP24,
 * Formant 6, Formant 12. */
typedef struct le_aas_filter {
  float s[3][2];  /* the 2-pole stages (the formants': three) */
  float g[3], k;  /* their coefficients (one g but for the formants) */
  float level[3]; /* the formants' band levels */
} le_aas_filter;

/* The coefficients for types 0..7 at fc Hz and resonance q. */
static inline void le_aas_filter_set(le_aas_filter* f, int32_t type, float fc, float q, float rate) {
  /* fit: BP12's and Notch4's two stages each take the full Q (Analog's
   * BP12 and Notch4 renders); LP24's and HP24's take sqrt(Q) each. The
   * clamp to 100 is the stage's, after the sqrt (LP24 at full Q). Below,
   * the core takes the Q its modulation asks for: a negative envelope on Q
   * damps the stage to near silence (fit: Analog's Rhythmic Iron, whose
   * chain 2 at a hard A5 drives Q to 1e-5; a floor of 0.01 left it 16 to
   * 39 dB too bright at 2 to 10 kHz). 1e-6 only keeps k finite. */
  const float qs = fminf(type == 1 || type == 7 ? sqrtf(q) : q, 100.0f);
  f->g[0] = tanf(LE_AAS_PI * fc / rate);
  f->k = 1.0f / fmaxf(qs, 1e-6f);
}

/* The formant filter's vowels, Peterson and Barney's adult-male averages
 * (1952): F1..F3 in Hz and their levels in dB, for i, I, E, ae, a, open o,
 * U, u, ^ and the r-coloured vowel. fit: a's F1 at 660 Hz, not their 730,
 * where the formant renders put it. */
static const float kLeAasVowelHz[10][3] = {
    {270.0f, 2290.0f, 3010.0f}, {390.0f, 1990.0f, 2550.0f}, {530.0f, 1840.0f, 2480.0f},
    {660.0f, 1720.0f, 2410.0f}, {660.0f, 1090.0f, 2440.0f}, {570.0f, 840.0f, 2410.0f},
    {440.0f, 1020.0f, 2240.0f}, {300.0f, 870.0f, 2240.0f},  {640.0f, 1190.0f, 2390.0f},
    {490.0f, 1350.0f, 1690.0f}};
static const float kLeAasVowelDb[10][3] = {
    {-4.0f, -24.0f, -28.0f}, {-3.0f, -23.0f, -27.0f}, {-2.0f, -17.0f, -24.0f}, {-1.0f, -12.0f, -22.0f},
    {-1.0f, -5.0f, -28.0f},  {0.0f, -7.0f, -34.0f},   {-1.0f, -12.0f, -34.0f}, {-3.0f, -19.0f, -43.0f},
    {-1.0f, -10.0f, -27.0f}, {-5.0f, -15.0f, -20.0f}};

/* The formant types' coefficients: three band-passes at a vowel's
 * formants. The Q knob's position (plus its modulation e_q, 64 steps an
 * octave) picks the vowel, 0..9 across the knob; the cutoff knob moves all
 * three an octave either way of a 270 Hz reference, by its whole steps,
 * and the cutoff modulation e_cut moves them smoothly. Formant 6 (type 8)
 * rings at Q 20, Formant 12 at 45. */
static inline void le_aas_formant_set(le_aas_filter* f, int32_t type, float cutoff_knob, float q_knob,
                                      float e_cut, float e_q, float rate) {
  const float m_q = roundf(le_aas_knob(q_knob) * 127.0f);
  const float m_c = roundf(le_aas_knob(cutoff_knob) * 127.0f);
  const float vowel = 0.072f * (le_aas_clamp(m_q + 64.0f * e_q, 1.0f, 126.0f) - 1.0f);
  const int32_t i0 = vowel >= 9.0f ? 8 : (int32_t)vowel;
  const float w = vowel - (float)i0;
  const float ref = fmaxf(270.0f * exp2f(e_cut + 2.0f * m_c / 127.0f - 1.0f), 20.0f);
  const float q = type == 8 ? 20.0f : 45.0f;
  for (int32_t b = 0; b < 3; ++b) {
    const float hz = kLeAasVowelHz[i0][b] + w * (kLeAasVowelHz[i0 + 1][b] - kLeAasVowelHz[i0][b]);
    const float l0 = powf(10.0f, kLeAasVowelDb[i0][b] / 20.0f), l1 = powf(10.0f, kLeAasVowelDb[i0 + 1][b] / 20.0f);
    const float fh = le_aas_clamp(hz / 270.0f * ref, 10.0f, 0.49f * rate);
    f->g[b] = tanf(LE_AAS_PI * fh / rate);
    /* the band node peaks at q: each band at 1 / q peaks at unity */
    f->level[b] = 8.0f / sqrtf(q) * (l0 + w * (l1 - l0)) * (b == 1 ? -1.0f : 1.0f);
  }
  f->k = 1.0f / q;
}

/* The 2-pole core: low, band, notch or high, Q per stage. */
static inline float le_aas_core(float* s, float x, float g, float k, int32_t type) {
  const float h = 1.0f / (1.0f + g * (g + k));
  const float b = (g * (x - s[1]) + s[0]) * h;
  const float l = s[1] + g * b;
  s[0] = 2.0f * b - s[0];
  s[1] = 2.0f * l - s[1];
  switch (type) {
    case 0: return l;
    case 1: return b; /* fit: the band node itself, peaking at Q */
    case 2: return x - k * b;
    default: return x - k * b - l;
  }
}

/* One sample through a filter of `type`. */
static inline float le_aas_filter_tick(le_aas_filter* f, int32_t type, float x) {
  if (type >= 8) {
    return f->level[0] * le_aas_core(f->s[0], x, f->g[0], f->k, 1) +
           f->level[1] * le_aas_core(f->s[1], x, f->g[1], f->k, 1) +
           f->level[2] * le_aas_core(f->s[2], x, f->g[2], f->k, 1);
  }
  x = le_aas_core(f->s[0], x, f->g[0], f->k, type / 2);
  if (type % 2 == 1) x = le_aas_core(f->s[1], x, f->g[0], f->k, type / 2);
  return x;
}

/* Drive after the filter: unchanged up to 1, bending smoothly toward a
 * ceiling beyond (0 off, 1..3 symmetric, 4..6 asymmetric). */
static inline float le_aas_drive(float x, int32_t mode) {
  static const float kGain[7] = {1.0f, 1.0f, 1.41421356f, 2.0f, 1.0f, 1.41421356f, 2.0f};
  static const float kPos[7] = {0.0f, 8.0f, 4.0f, 2.0f, 4.0f, 2.0f, 1.3f};
  if (mode <= 0) return x;
  const float u = kGain[mode] * x;
  const float a = fabsf(u);
  if (a <= 1.0f) return u;
  const float L = u > 0.0f ? kPos[mode] : (mode >= 4 ? 8.0f : kPos[mode]);
  const float r = 1.0f + (a - 1.0f) / (3.0f * (L - 1.0f));
  const float y = L - (L - 1.0f) / (r * r * r);
  return u > 0.0f ? y : -y;
}

#endif /* SEGNO_AAS_PARTS_H */
