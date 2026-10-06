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
/* The loop's bandwidth. The least-squares seed is within about 0.15 BPM, so
 * the loop needs no wider start-up phase (a 0.5 Hz start let block-edge
 * jitter move the estimate by 0.2 BPM for seconds after Synced). */
#define LE_CF_BANDWIDTH_HZ 0.2
#define LE_CF_SETTLE_PULSES 48                      /* jitter estimate warm-up */
#define LE_CF_OUTLIER_FLOOR_NS 2e6                  /* 2 ms */
/* 2.5 sigma: block-edge jitter is bounded (uniform within one block, so at
 * most 1.7 sigma off the line), and a lower bar makes a dropped pulse on such
 * a source a steady outlier run instead of slipping under the threshold. */
#define LE_CF_OUTLIER_SIGMAS 2.5
#define LE_CF_STEP_OUTLIERS 6 /* the run members averaged */
/* Run verdicts: the fitted slope this many standard errors from the old
 * period is a step; under LE_CF_DROP_Z (and on the old line) a drop; between,
 * the run keeps collecting (a longer run has a smaller error). */
#define LE_CF_STEP_Z 4.0
#define LE_CF_DROP_Z 2.0
#define LE_CF_LOSS_PERIODS 6.0
/* Acquisition and re-fit: Synced once the fitted tempo's standard error is
 * below this, after at least six intervals and at most four beats. */
#define LE_CF_FIT_SE_BPM 0.15
#define LE_CF_FIT_MIN_INTERVALS LE_CLOCK_FOLLOW_PPQN
#define LE_CF_FIT_MAX_INTERVALS (4 * LE_CLOCK_FOLLOW_PPQN)
/* Hidden pulses an unmarked drop may have taken, at most. */
#define LE_CF_MAX_HIDDEN 3
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

/* The engine-unit tempo of a pulse period. */
static double le_cf_bpm_of(double period, int32_t den) {
  return 60.0 * LE_CF_NS / (period * LE_CLOCK_FOLLOW_PPQN) * (double)den / 4.0;
}

/* ---- the least-squares line ---------------------------------------------- */

static void le_cf_fit_start(le_clock_fit* fit, uint64_t t) {
  fit->t0 = t;
  fit->n = 1;
  fit->k = 0;
  fit->sk = fit->st = fit->skk = fit->skt = fit->stt = 0.0;
  fit->pk[0] = 0;
  fit->pt[0] = t;
}

static void le_cf_fit_add(le_clock_fit* fit, int32_t k, uint64_t t) {
  const double x = (double)k;
  const double y = (double)(int64_t)(t - fit->t0);
  if (fit->n < LE_CLOCK_FIT_POINTS) {
    fit->pk[fit->n] = k;
    fit->pt[fit->n] = t;
  }
  fit->n++;
  fit->k = k;
  fit->sk += x;
  fit->st += y;
  fit->skk += x * x;
  fit->skt += x * y;
  fit->stt += y * y;
}

/* Slope (the period), intercept and the slope's standard error; 0 when the
 * line is not determined yet. */
static int le_cf_fit_solve(const le_clock_fit* fit, double* slope,
                           double* intercept, double* se) {
  if (fit->n < 3) return 0;
  const double n = (double)fit->n;
  const double sxx = fit->skk - fit->sk * fit->sk / n;
  if (!(sxx > 0.0)) return 0;
  const double sxy = fit->skt - fit->sk * fit->st / n;
  const double syy = fit->stt - fit->st * fit->st / n;
  *slope = sxy / sxx;
  *intercept = (fit->st - *slope * fit->sk) / n;
  double resid = (syy - *slope * sxy) / (n - 2.0);
  if (resid < 0.0) resid = 0.0;
  *se = sqrt(resid / sxx);
  return 1;
}

/* The fitted time of index `k`, absolute ns. */
static double le_cf_fit_at(const le_clock_fit* fit, double slope,
                           double intercept, double k) {
  return (double)fit->t0 + intercept + slope * k;
}

/* ---- readout ------------------------------------------------------------- */

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

/* ---- state helpers -------------------------------------------------------- */

static void le_cf_clear_runs(le_clock_follow* f) {
  f->out_count = 0;
  f->out_sign = 0;
  f->n_out = 0;
  f->out_armed = 0;
  f->multi_prev = 0;
  f->multi_extra = 0;
}

/* Forgets the pulse run and any fit in progress (not the tempo). */
static void le_cf_drop_run(le_clock_follow* f) {
  f->have_last = 0;
  f->gap = 0;
  f->refit = 0;
  f->n_oor = 0;
  memset(&f->fit, 0, sizeof(f->fit));
  le_cf_clear_runs(f);
}

/* Hands the fitted line to the loop: Synced tracking from the next pulse. */
static void le_cf_take_fit(le_clock_follow* f, double slope, double intercept) {
  f->period = slope;
  f->pred = le_cf_fit_at(&f->fit, slope, intercept, (double)f->fit.k + 1.0);
  f->var = 0.0;
  f->e_prev = 0.0;
  f->since = 0;
  f->refit = 0;
  le_cf_clear_runs(f);
  f->display_bpm = 0.0f;
  le_cf_update_display(f);
}

/* A fit that spans a tempo change (it began before a step, or the step came
 * while it was re-fitting) has a slope between the two tempos. Its newest
 * half alone shows it: a slope more than three of its own standard errors
 * away. Then the fit is cut back to that half and goes on collecting. */
static int le_cf_fit_cut_kink(le_clock_fit* fit, double slope) {
  const int32_t n = fit->n;
  if (n < 12 || n > LE_CLOCK_FIT_POINTS) return 0;
  const int32_t from = n - n / 2;
  double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (int32_t i = from; i < n; ++i) {
    const double x = (double)(fit->pk[i] - fit->pk[from]);
    const double y = (double)(int64_t)(fit->pt[i] - fit->pt[from]);
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
    syy += y * y;
  }
  const double m = (double)(n - from);
  const double vxx = sxx - sx * sx / m;
  if (!(vxx > 0.0)) return 0;
  const double vxy = sxy - sx * sy / m;
  const double vyy = syy - sy * sy / m;
  const double recent = vxy / vxx;
  double resid = (vyy - recent * vxy) / (m - 2.0);
  if (resid < 0.0) resid = 0.0;
  /* Floored at 10 ppm (0.001 BPM at 120): a clean clock's rounding to whole
   * ns must not read as a change. */
  const double se = fmax(sqrt(resid / vxx), 1e-5 * slope);
  if (fabs(recent - slope) <= 3.0 * se) return 0;
  const int32_t k0 = fit->pk[from];
  int32_t pk[LE_CLOCK_FIT_POINTS];
  uint64_t pt[LE_CLOCK_FIT_POINTS];
  const int32_t keep = n - from;
  for (int32_t i = 0; i < keep; ++i) {
    pk[i] = fit->pk[from + i] - k0;
    pt[i] = fit->pt[from + i];
  }
  le_cf_fit_start(fit, pt[0]);
  for (int32_t i = 1; i < keep; ++i) le_cf_fit_add(fit, pk[i], pt[i]);
  return 1;
}

/* Whether a fit is good enough to hand over. A fit cut back at a tempo
 * change is not, yet. */
static int le_cf_fit_done(le_clock_follow* f, double slope, double se) {
  const int32_t intervals = f->fit.n - 1;
  if (intervals < LE_CF_FIT_MIN_INTERVALS) return 0;
  if (intervals >= LE_CF_FIT_MAX_INTERVALS) return 1;
  const double bpm = le_cf_bpm_of(slope, f->ts_den);
  if (bpm * se / slope >= LE_CF_FIT_SE_BPM) return 0;
  return !le_cf_fit_cut_kink(&f->fit, slope);
}

/* Starts re-fitting the period after a tempo step, from the run's times:
 * `t0` is the last pulse before the run and `ts` the run (oldest first). */
static void le_cf_begin_refit(le_clock_follow* f, uint64_t t0,
                              const uint64_t* ts, int32_t n) {
  le_cf_fit_start(&f->fit, t0);
  for (int32_t i = 0; i < n; ++i) le_cf_fit_add(&f->fit, i + 1, ts[i]);
  double slope = 0.0, intercept = 0.0, se = 0.0;
  if (le_cf_fit_solve(&f->fit, &slope, &intercept, &se) && slope > 0.0) {
    f->period = slope;
    f->pred = le_cf_fit_at(&f->fit, slope, intercept, (double)f->fit.k + 1.0);
  }
  f->refit = 1;
  f->since = 0;
  f->e_prev = 0.0;
  le_cf_clear_runs(f);
  f->reacquisitions++;
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

/* Silence past the loss limit while Synced: Lost, or Waiting after a Stop. */
static uint32_t le_cf_silence(le_clock_follow* f) {
  le_cf_drop_run(f);
  if (f->stopped) {
    f->state = LE_CLOCK_FOLLOW_WAITING;
    return LE_CLOCK_EVENT_WAITING;
  }
  f->state = LE_CLOCK_FOLLOW_LOST;
  return LE_CLOCK_EVENT_LOST;
}

static double le_cf_loss_limit(const le_clock_follow* f) {
  return fmax(LE_CF_LOSS_PERIODS * f->period, LE_CF_LOSS_FLOOR_NS);
}

/* Not Synced: extend the acquisition line, or start it again. */
static uint32_t le_cf_acquire(le_clock_follow* f, double iv, uint64_t t) {
  if (f->gap) { /* no acquisition line spans a loss */
    f->gap = 0;
    le_cf_fit_start(&f->fit, t);
    return 0u;
  }
  if (iv > 0.0 && !le_cf_in_window(iv, f->ts_den)) {
    /* A steady clock outside the window is reported as out of range, not
     * just left Waiting: six consistent intervals in a row. */
    if (f->n_oor > 0 && fabs(iv / f->oor_prev - 1.0) < 0.1) {
      f->n_oor++;
    } else {
      f->n_oor = 1;
    }
    f->oor_prev = iv;
    if (f->n_oor >= 6) f->out_of_range = 1;
    le_cf_fit_start(&f->fit, t);
    return 0u;
  }
  f->n_oor = 0;
  double slope = 0.0, intercept = 0.0, se = 0.0;
  int32_t k = f->fit.k + 1;
  if (f->fit.n - 1 >= LE_CF_FIT_MIN_INTERVALS &&
      le_cf_fit_solve(&f->fit, &slope, &intercept, &se) && slope > 0.0) {
    /* Where a line of at least a beat says this pulse falls: whole periods
     * late, pulses the source dropped, counted. Before a beat, and for a
     * pulse early by any amount (a stray, which the kink cut removes from
     * the line if the clock moved), pulses are taken in order and the span
     * of the timestamps settles the slope: pulses on audio-block edges
     * scatter a third of a period at 174 BPM, too much for a shorter line
     * to judge. */
    const double off = (double)t - le_cf_fit_at(&f->fit, slope, intercept, k);
    if (off > 0.5 * slope) {
      const double hidden = floor(off / slope + 0.5);
      k += (int32_t)hidden;
      f->pulses += (uint64_t)hidden;
    }
  }
  le_cf_fit_add(&f->fit, k, t);
  if (!le_cf_fit_solve(&f->fit, &slope, &intercept, &se) ||
      !le_cf_in_window(slope, f->ts_den) || !le_cf_fit_done(f, slope, se)) {
    return 0u;
  }
  f->out_of_range = 0;
  f->state = LE_CLOCK_FOLLOW_SYNCED;
  le_cf_take_fit(f, slope, intercept);
  return LE_CLOCK_EVENT_SYNCED;
}

/* Synced, re-fitting after a tempo step: the line's slope is the period. */
static uint32_t le_cf_refit_pulse(le_clock_follow* f, uint64_t t) {
  double slope = f->period, intercept = 0.0, se = 0.0;
  int32_t k = f->fit.k + 1;
  if (le_cf_fit_solve(&f->fit, &slope, &intercept, &se)) {
    const double off = (double)t - le_cf_fit_at(&f->fit, slope, intercept, k);
    const double hidden = floor(off / slope + 0.5);
    if (hidden >= 1.0) {
      /* Pulses were missed while re-fitting: count them. */
      k += (int32_t)hidden;
      f->pulses += (uint64_t)hidden;
    }
  }
  f->pulses++;
  le_cf_fit_add(&f->fit, k, t);
  if (le_cf_fit_solve(&f->fit, &slope, &intercept, &se) && slope > 0.0) {
    f->period = slope;
    f->pred = le_cf_fit_at(&f->fit, slope, intercept, (double)k + 1.0);
    if (le_cf_fit_done(f, slope, se)) le_cf_take_fit(f, slope, intercept);
  }
  return 0u;
}

/* A run of same-sign errors: dropped pulses or a tempo step? A line fitted
 * freely through the run's times has the old period's slope after a drop
 * (the run sits whole periods late) and a different slope after a step (the
 * error grows pulse by pulse). The slope is compared with its own standard
 * error, so block-edge jitter (a third of a period at 174 BPM) cannot pass
 * for a step, nor a step's growing error for a whole-period drop; while
 * neither is clear the run keeps collecting.
 * Returns 0 (still collecting), 1 (resolved: a drop) or 2 (a step). */
static int le_cf_classify_run(le_clock_follow* f, int32_t* hidden) {
  const int32_t m = f->n_out;
  const double t0 = f->out_t0;
  const double p_old = f->out_period;
  double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (int32_t i = 0; i < m; ++i) {
    const double x = (double)(i + 1);
    const double y = (double)f->out_t[i] - t0;
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
    syy += y * y;
  }
  const double n = (double)m;
  const double vxx = sxx - sx * sx / n;
  const double vxy = sxy - sx * sy / n;
  const double vyy = syy - sy * sy / n;
  const double p = vxy / vxx;
  double resid = (vyy - p * vxy) / (n - 2.0);
  if (resid < 0.0) resid = 0.0;
  /* The slope's error, floored at the jitter the loop measured: a run of
   * six on a sawtooth can line up by chance. */
  const double sigma = sqrt(f->var);
  const double se = fmax(sqrt(resid / vxx), sigma / sqrt(vxx));
  const double z = fabs(p - p_old) / fmax(se, 1.0);
  /* The hidden pulses fell before run member j (the run can open with a
   * pulse that was merely late before the drop). */
  int32_t best_h = 0;
  double best_a = INFINITY;
  for (int32_t h = 1; h <= LE_CF_MAX_HIDDEN; ++h) {
    for (int32_t j = 0; j < m; ++j) {
      double sum = 0.0;
      for (int32_t i = 0; i < m; ++i) {
        const double idx = (double)(i + 1 + (i >= j ? h : 0));
        const double r = (double)f->out_t[i] - t0 - idx * p_old;
        sum += r * r;
      }
      if (sum < best_a) {
        best_a = sum;
        best_h = h;
      }
    }
  }
  /* A drop also needs the run to sit on the old line h periods on: its
   * residual no larger than a quarter period. */
  const int on_line = sqrt(best_a / n) < 0.25 * p_old;
  *hidden = best_h;
  if (z > LE_CF_STEP_Z) return 2;
  if (z < LE_CF_DROP_Z && on_line) return 1;
  return 0;
}

static uint32_t le_cf_resolve_run(le_clock_follow* f, int verdict,
                                  int32_t best_h) {
  const int32_t m = f->n_out;
  const double t0 = f->out_t0;
  const double p_old = f->out_period;
  if (verdict == 1) {
    /* Dropped without a mark: count the hidden pulses, keep the period, and
     * put the phase back on the old line. */
    f->pulses += (uint64_t)best_h;
    f->period = p_old;
    f->pred = t0 + (double)(m + best_h + 1) * p_old;
    f->e_prev = 0.0;
    le_cf_clear_runs(f);
    return 0u;
  }
  /* A tempo step. A whole-multiple interval just before this run was the
   * step's first interval, not missed pulses: take its extra count back. */
  if (f->multi_extra > 0 && f->since_multi <= f->out_count + 1) {
    f->pulses -= (uint64_t)f->multi_extra;
  }
  uint64_t ts[LE_CLOCK_FOLLOW_OUTLIERS];
  memcpy(ts, f->out_t, sizeof(uint64_t) * (size_t)m);
  le_cf_begin_refit(f, (uint64_t)llround(f->out_t0), ts, m);
  return LE_CLOCK_EVENT_REACQUIRED;
}

uint32_t le_clock_follow_pulse(le_clock_follow* f, uint64_t t_ns) {
  if (f == NULL) return 0u;
  if (!f->have_last) {
    f->have_last = 1;
    f->gap = 0;
    f->last_t = t_ns;
    f->pulses++;
    if (f->state != LE_CLOCK_FOLLOW_SYNCED) le_cf_fit_start(&f->fit, t_ns);
    return 0u;
  }
  if (t_ns < f->last_t) return 0u; /* out of order: ignored */
  if (t_ns == f->last_t) {
    /* Two pulses with one time (one packet, one read): still a pulse. But
     * if the interval just before counted pulses as missed, this is one of
     * them, delivered late with the next: already counted. */
    if (f->state == LE_CLOCK_FOLLOW_SYNCED && !f->refit &&
        f->multi_extra > 0 && f->since_multi == 0) {
      f->multi_extra--;
      f->multi_prev = f->multi_prev > 2 ? f->multi_prev - 1 : 0;
      return 0u;
    }
    f->pulses++;
    if (f->state != LE_CLOCK_FOLLOW_SYNCED) {
      if (f->fit.n > 0) le_cf_fit_add(&f->fit, f->fit.k + 1, t_ns);
    } else if (f->refit) {
      le_cf_fit_add(&f->fit, f->fit.k + 1, t_ns);
    } else {
      f->pred += f->period;
    }
    return 0u;
  }
  const uint64_t prev = f->last_t;
  const double iv = (double)(t_ns - prev);
  uint32_t events = 0u;
  if (f->state == LE_CLOCK_FOLLOW_SYNCED && iv >= le_cf_loss_limit(f)) {
    /* The deadline passed before this pulse: the same loss the check would
     * have found a block earlier (review L1). This pulse starts again. */
    events = le_cf_silence(f);
    f->have_last = 1;
    f->last_t = t_ns;
    f->pulses++;
    le_cf_fit_start(&f->fit, t_ns);
    return events;
  }
  f->last_t = t_ns;

  if (f->state != LE_CLOCK_FOLLOW_SYNCED) {
    f->pulses++;
    return le_cf_acquire(f, iv, t_ns);
  }
  if (f->refit) return le_cf_refit_pulse(f, t_ns);

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
       * after all; take its extra count back and re-fit the new period. */
      f->pulses -= (uint64_t)(f->multi_prev - 1);
      f->pulses++;
      const uint64_t pair[2] = {prev, t_ns};
      le_cf_begin_refit(f, prev - (uint64_t)f->multi_iv, pair, 2);
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
  const int settled = f->since >= LE_CF_SETTLE_PULSES;
  const int outlier = fabs(e) > threshold && settled;
  /* Run membership is looser than the outlier bar: one sigma of the same
   * sign. The run is resolved once its last six errors average beyond the
   * bar, so a sawtooth of block-edge jitter riding on a dropped pulse's
   * whole-period error still builds a run. */
  const int member =
      settled && fabs(e) > fmax(LE_CF_OUTLIER_FLOOR_NS, sigma);
  if (member && f->n_out >= LE_CLOCK_FOLLOW_OUTLIERS) {
    f->out_sign = 0; /* a run this long resolved nothing: start it here */
  }
  if (member) {
    const int sign = e > 0.0 ? 1 : -1;
    if (sign != f->out_sign) {
      f->out_count = 0;
      f->out_sign = sign;
      f->n_out = 0;
      f->out_armed = 0;
      /* The run is judged against the loop's own line: where it predicted
       * the pulse before this one. A coarse source's quantization of that
       * single pulse would otherwise bias every hypothesis. */
      f->out_t0 = f->pred - (count - 1.0) * period - period;
      f->out_period = period;
    }
    f->out_count++;
    if (f->n_out < LE_CLOCK_FOLLOW_OUTLIERS) {
      f->out_e[f->n_out] = e;
      f->out_t[f->n_out] = t_ns;
      f->n_out++;
    }
  } else {
    f->out_count = 0;
    f->out_sign = 0;
    f->n_out = 0;
    f->out_armed = 0;
  }
  if (member && f->n_out >= LE_CF_STEP_OUTLIERS) {
    if (!f->out_armed) {
      double mean = 0.0;
      for (int32_t i = f->n_out - LE_CF_STEP_OUTLIERS; i < f->n_out; ++i) {
        mean += fabs(f->out_e[i]);
      }
      f->out_armed = mean / (double)LE_CF_STEP_OUTLIERS > threshold;
    }
    if (f->out_armed) {
      int32_t hidden = 0;
      const int verdict = le_cf_classify_run(f, &hidden);
      if (verdict != 0) return le_cf_resolve_run(f, verdict, hidden);
    }
  }

  const double bandwidth = LE_CF_BANDWIDTH_HZ;
  const double omega = LE_CF_TWO_PI * bandwidth * period / LE_CF_NS;
  const double b = 1.4142135623730951 * omega;
  const double c = omega * omega;
  f->pred += period + b * e;
  f->period = period + c * e;
  if (fabs(e) <= threshold) {
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
  if (was_synced) f->state = LE_CLOCK_FOLLOW_LOST;
  le_cf_drop_run(f);
  return was_synced ? LE_CLOCK_EVENT_LOST : 0u;
}

uint32_t le_clock_follow_check(le_clock_follow* f, uint64_t now_ns) {
  if (f == NULL || f->state != LE_CLOCK_FOLLOW_SYNCED || !f->have_last) {
    return 0u;
  }
  if (now_ns <= f->last_t ||
      (double)(now_ns - f->last_t) < le_cf_loss_limit(f)) {
    return 0u;
  }
  return le_cf_silence(f);
}

int le_clock_follow_tempo_ready(const le_clock_follow* f) {
  return f != NULL && f->state == LE_CLOCK_FOLLOW_SYNCED && !f->refit &&
         f->since >= LE_CLOCK_FOLLOW_PPQN;
}

double le_clock_follow_quarter_bpm(const le_clock_follow* f) {
  if (f == NULL || !(f->period > 0.0)) return 0.0;
  return 60.0 * LE_CF_NS / (f->period * LE_CLOCK_FOLLOW_PPQN);
}

double le_clock_follow_engine_bpm(const le_clock_follow* f) {
  if (f == NULL) return 0.0;
  return le_clock_follow_quarter_bpm(f) * (double)le_cf_den(f->ts_den) / 4.0;
}
