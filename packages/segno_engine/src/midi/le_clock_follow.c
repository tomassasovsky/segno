/*
 * le_clock_follow.c - see le_clock_follow.h.
 *
 * Pure value logic: safe on the audio thread (no allocation, no locks, no
 * I/O), bounded work per call.
 */
#include "le_clock_follow.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#define LE_CF_TWO_PI 6.283185307179586
#define LE_CF_NS 1e9
/* The engine's tempo clamp (tempo_grid.h), in the denominator unit. */
#define LE_CF_BPM_MIN 30.0
#define LE_CF_BPM_MAX 300.0
/* Margin on the valid interval window. */
#define LE_CF_MARGIN 0.02
/* Tracking constants (plan D3). */
#define LE_CF_FAST_PULSES (8 * LE_CLOCK_FOLLOW_PPQN) /* 0.5 Hz for 8 beats */
#define LE_CF_SETTLE_PULSES 48                      /* jitter estimate warm-up */
#define LE_CF_OUTLIER_FLOOR_NS 2e6                  /* 2 ms */
#define LE_CF_OUTLIER_SIGMAS 4.0
#define LE_CF_STEP_OUTLIERS 6
#define LE_CF_LOSS_PERIODS 6.0
#define LE_CF_LOSS_FLOOR_NS 250e6 /* 250 ms */
/* The displayed value moves once the estimate is more than 0.08 BPM from it:
 * the 0.05 rounding half-step plus 0.03 of margin, so jitter around a value
 * does not flicker the readout and a real 0.1 BPM change still shows. */
#define LE_CF_DISPLAY_HYSTERESIS 0.08
/* ...widened to 2.5 times the estimate's recent wander around its one-beat
 * mean, so a coarse source (pulses on audio-block edges) does not flip the
 * readout. A rounded value that differs from the readout for a whole beat is
 * shown anyway, so a wide band can never leave the readout on a wrong tenth
 * or lag a tempo ramp by more than a beat. */
#define LE_CF_DISPLAY_SIGMAS 2.5
#define LE_CF_DISPLAY_MEAN LE_CLOCK_FOLLOW_PPQN          /* one beat */
#define LE_CF_DISPLAY_WANDER (8 * LE_CLOCK_FOLLOW_PPQN)  /* eight beats */
#define LE_CF_DISPLAY_HOLD LE_CLOCK_FOLLOW_PPQN          /* one beat */

static int32_t le_cf_den(int32_t ts_den) { return ts_den > 0 ? ts_den : 4; }

/* The pulse period of a tempo `bpm` in the engine's unit, in ns. */
static double le_cf_period_for(double bpm, int32_t den) {
  const double quarter_bpm = bpm * 4.0 / (double)den;
  return 60.0 * LE_CF_NS / (quarter_bpm * LE_CLOCK_FOLLOW_PPQN);
}

static int le_cf_in_window(double iv, int32_t den) {
  const double lo = le_cf_period_for(LE_CF_BPM_MAX, den) * (1.0 - LE_CF_MARGIN);
  const double hi = le_cf_period_for(LE_CF_BPM_MIN, den) * (1.0 + LE_CF_MARGIN);
  return iv >= lo && iv <= hi;
}

static double le_cf_median(const double* v, int32_t n) {
  double s[LE_CLOCK_FOLLOW_OUTLIERS];
  for (int32_t i = 0; i < n; ++i) {
    double x = v[i];
    int32_t j = i;
    while (j > 0 && s[j - 1] > x) {
      s[j] = s[j - 1];
      --j;
    }
    s[j] = x;
  }
  return (n & 1) ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2]);
}

static void le_cf_update_display(le_clock_follow* f) {
  const double bpm = le_clock_follow_engine_bpm(f);
  if (!(bpm > 0.0)) return;
  if (f->display_bpm == 0.0f) {
    f->est_mean = bpm;
    f->est_var = 0.0;
  } else {
    const double d = bpm - f->est_mean;
    f->est_mean += d / (double)LE_CF_DISPLAY_MEAN;
    f->est_var += (d * d - f->est_var) / (double)LE_CF_DISPLAY_WANDER;
  }
  const double band = fmax(LE_CF_DISPLAY_HYSTERESIS,
                           LE_CF_DISPLAY_SIGMAS * sqrt(f->est_var));
  const float rounded = (float)(floor(bpm * 10.0 + 0.5) / 10.0);
  f->display_hold = rounded != f->display_bpm ? f->display_hold + 1 : 0;
  if (f->display_bpm == 0.0f || f->display_hold >= LE_CF_DISPLAY_HOLD ||
      (fabs(bpm - (double)f->display_bpm) > band &&
       rounded != f->display_bpm)) {
    f->display_bpm = rounded;
    f->display_hold = 0;
  }
}

/* Re-seeds the loop at `period`, pulse `t`: after a tempo step. */
static void le_cf_reseed(le_clock_follow* f, double period, uint64_t t) {
  f->period = period;
  f->pred = (double)t + period;
  f->var = 0.0;
  f->e_prev = 0.0;
  f->since = 0;
  f->out_count = 0;
  f->out_sign = 0;
  f->n_out = 0;
  f->multi_prev = 0;
  f->multi_extra = 0;
  f->reacquisitions++;
  f->display_bpm = 0.0f;
  le_cf_update_display(f);
}

/* Forgets the acquisition run and the last pulse (not the tempo). */
static void le_cf_drop_run(le_clock_follow* f) {
  f->have_last = 0;
  f->gap = 0;
  f->n_acq = 0;
  f->n_oor = 0;
  f->out_count = 0;
  f->out_sign = 0;
  f->n_out = 0;
  f->multi_prev = 0;
}

void le_clock_follow_reset(le_clock_follow* f, int32_t ts_den) {
  if (f == NULL) return;
  memset(f, 0, sizeof(*f));
  f->state = LE_CLOCK_FOLLOW_WAITING;
  f->ts_den = le_cf_den(ts_den);
}

void le_clock_follow_set_den(le_clock_follow* f, int32_t ts_den) {
  if (f == NULL) return;
  const int32_t den = le_cf_den(ts_den);
  if (den == f->ts_den) return;
  f->ts_den = den;
  f->display_bpm = 0.0f;
  if (f->state == LE_CLOCK_FOLLOW_SYNCED) le_cf_update_display(f);
}

static uint32_t le_cf_acquire(le_clock_follow* f, double iv, uint64_t t) {
  if (!le_cf_in_window(iv, f->ts_den)) {
    f->n_acq = 0;
    /* A steady clock outside the window is reported as out of range, not
     * just left Waiting: six consistent intervals in a row. */
    if (f->n_oor > 0 && fabs(iv / f->oor_prev - 1.0) < 0.1) {
      f->n_oor++;
    } else {
      f->n_oor = 1;
    }
    f->oor_prev = iv;
    if (f->n_oor >= 6) f->out_of_range = 1;
    return 0u;
  }
  f->n_oor = 0;
  f->acq[f->n_acq++] = iv;
  if (f->n_acq < 6) return 0u;
  f->period = le_cf_median(f->acq, 6);
  f->pred = (double)t + f->period;
  f->var = 0.0;
  f->e_prev = 0.0;
  f->since = 0;
  f->n_acq = 0;
  f->out_count = 0;
  f->out_sign = 0;
  f->n_out = 0;
  f->out_of_range = 0;
  f->multi_prev = 0;
  f->state = LE_CLOCK_FOLLOW_SYNCED;
  f->display_bpm = 0.0f;
  le_cf_update_display(f);
  return LE_CLOCK_EVENT_SYNCED;
}

uint32_t le_clock_follow_pulse(le_clock_follow* f, uint64_t t_ns) {
  if (f == NULL) return 0u;
  if (!f->have_last) {
    f->have_last = 1;
    f->gap = 0;
    f->last_t = t_ns;
    f->pulses++;
    return 0u;
  }
  if (t_ns <= f->last_t) return 0u; /* out of order: ignored */
  const double iv = (double)(t_ns - f->last_t);
  f->last_t = t_ns;

  if (f->state != LE_CLOCK_FOLLOW_SYNCED) {
    f->pulses++;
    if (f->gap) { /* no acquisition interval spans a loss */
      f->gap = 0;
      f->n_acq = 0;
      return 0u;
    }
    return le_cf_acquire(f, iv, t_ns);
  }

  const double period = f->period;
  const double sigma = sqrt(f->var);
  const double threshold = fmax(LE_CF_OUTLIER_FLOOR_NS,
                                LE_CF_OUTLIER_SIGMAS * sigma);
  const double ratio = iv / period;
  const double whole = floor(ratio + 0.5);
  double count = 1.0;
  if (f->gap) {
    /* A known loss: count what it hid. */
    count = whole < 1.0 ? 1.0 : whole;
    f->gap = 0;
    f->multi_prev = 0;
  } else if (sigma < period / 6.0 && f->since >= LE_CF_SETTLE_PULSES &&
             whole >= 2.0 && fabs(ratio - whole) < 0.25 &&
             fabs(f->e_prev) < threshold) {
    if (f->multi_prev >= 2) {
      /* Two whole-multiple intervals in a row: the master moved to an
       * integer fraction of its tempo. The previous interval was one pulse
       * after all; take its extra count back and follow the new period. */
      f->pulses -= (uint64_t)(f->multi_prev - 1);
      f->pulses++;
      const double pair[2] = {f->multi_iv, iv};
      le_cf_reseed(f, le_cf_median(pair, 2), t_ns);
      return LE_CLOCK_EVENT_REACQUIRED;
    }
    /* An isolated interval on a whole multiple after an on-time pulse:
     * missed pulses, not a tempo step (a step grows the error gradually).
     * Held one interval: a second in a row is a tempo division. */
    count = whole;
    f->multi_prev = (int32_t)whole;
    f->multi_iv = iv;
    f->multi_extra = (int32_t)whole - 1;
    f->since_multi = -1;
  } else {
    f->multi_prev = 0;
  }
  f->since_multi++;
  if (count > 1.0) f->pred += (count - 1.0) * period;
  f->pulses += (uint64_t)count;

  const double e = (double)t_ns - f->pred;
  f->e_prev = e;
  const int outlier = fabs(e) > threshold && f->since >= LE_CF_SETTLE_PULSES;
  if (outlier) {
    const int sign = e > 0.0 ? 1 : -1;
    if (sign == f->out_sign) {
      f->out_count++;
    } else {
      f->out_count = 1;
      f->out_sign = sign;
      f->n_out = 0;
    }
    if (f->n_out < LE_CLOCK_FOLLOW_OUTLIERS) f->out_iv[f->n_out++] = iv;
  } else {
    f->out_count = 0;
    f->out_sign = 0;
    f->n_out = 0;
  }
  if (f->out_count >= LE_CF_STEP_OUTLIERS && f->n_out >= 3) {
    /* The master changed tempo: re-seed from the new intervals only. A
     * whole-multiple interval just before this run was the step's first
     * interval, not missed pulses: take its extra count back. */
    if (f->multi_extra > 0 && f->since_multi <= f->out_count + 1) {
      f->pulses -= (uint64_t)f->multi_extra;
    }
    le_cf_reseed(f, le_cf_median(f->out_iv, f->n_out), t_ns);
    return LE_CLOCK_EVENT_REACQUIRED;
  }

  const double bandwidth = f->since < LE_CF_FAST_PULSES ? 0.5 : 0.2;
  const double omega = LE_CF_TWO_PI * bandwidth * period / LE_CF_NS;
  const double b = 1.4142135623730951 * omega;
  const double c = omega * omega;
  f->pred += period + b * e;
  f->period = period + c * e;
  if (!outlier || f->since < LE_CF_SETTLE_PULSES) {
    f->var += (e * e - f->var) / (double)LE_CF_SETTLE_PULSES;
  }
  f->since++;

  /* A loop driven far outside the window is not following anything real. */
  if (!le_cf_in_window(f->period, f->ts_den)) {
    f->state = LE_CLOCK_FOLLOW_WAITING;
    le_cf_drop_run(f);
    return 0u;
  }
  le_cf_update_display(f);
  return 0u;
}

void le_clock_follow_transport(le_clock_follow* f, uint8_t status) {
  if (f == NULL) return;
  if (status == 0xFCu) {
    f->stopped = 1;
  } else if (status == 0xFAu || status == 0xFBu) {
    f->stopped = 0;
  }
}

void le_clock_follow_gap(le_clock_follow* f) {
  if (f != NULL) f->gap = 1;
}

uint32_t le_clock_follow_lost(le_clock_follow* f) {
  if (f == NULL) return 0u;
  const int was_synced = f->state == LE_CLOCK_FOLLOW_SYNCED;
  f->state = was_synced ? LE_CLOCK_FOLLOW_LOST : LE_CLOCK_FOLLOW_WAITING;
  le_cf_drop_run(f);
  return was_synced ? LE_CLOCK_EVENT_LOST : 0u;
}

uint32_t le_clock_follow_check(le_clock_follow* f, uint64_t now_ns) {
  if (f == NULL || f->state != LE_CLOCK_FOLLOW_SYNCED || !f->have_last) {
    return 0u;
  }
  const double limit = fmax(LE_CF_LOSS_PERIODS * f->period, LE_CF_LOSS_FLOOR_NS);
  if (now_ns <= f->last_t || (double)(now_ns - f->last_t) < limit) return 0u;
  le_cf_drop_run(f);
  if (f->stopped) {
    f->state = LE_CLOCK_FOLLOW_WAITING;
    return LE_CLOCK_EVENT_WAITING;
  }
  f->state = LE_CLOCK_FOLLOW_LOST;
  return LE_CLOCK_EVENT_LOST;
}

double le_clock_follow_quarter_bpm(const le_clock_follow* f) {
  if (f == NULL || !(f->period > 0.0)) return 0.0;
  return 60.0 * LE_CF_NS / (f->period * LE_CLOCK_FOLLOW_PPQN);
}

double le_clock_follow_engine_bpm(const le_clock_follow* f) {
  if (f == NULL) return 0.0;
  return le_clock_follow_quarter_bpm(f) * (double)le_cf_den(f->ts_den) / 4.0;
}
