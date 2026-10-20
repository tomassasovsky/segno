/*
 * le_clock_follow.h - the MIDI clock follower (#1228 Part 2; plan D3).
 *
 * Pure value logic in the shape of le_midi_clock.h: no engine state, no
 * atomics, no allocation, no clock reads. The audio thread feeds it the
 * timestamped Timing Clock and transport bytes of the selected source port
 * (le_midi_ports_drain) and asks it once per block whether the clock was
 * lost; the unit tests drive the same functions with synthetic timestamps.
 *
 * Acquisition (PR #1259 review M1): a least-squares line through the pulse
 * times, not a median of intervals, so a source that stamps pulses on audio
 * block edges (intervals of one or two blocks, never the period) is seeded
 * from the span of its timestamps. Synced is reached once the fitted tempo's
 * standard error is below 0.15 BPM, after at least one beat of intervals (six
 * equal block-edge intervals can alias 100 BPM to 107.67) and at most four.
 * A fit whose newest half has a different slope spans a tempo change and is
 * cut back to that half. The fit seeds a second-order delay-locked loop (F.
 * Adriaensen, "Using a DLL to filter time", LAC 2005; the filter JACK uses
 * for period times), 0.2 Hz wide, and its residual spread seeds the jitter
 * estimate.
 *
 * Tracking: each pulse's error against the prediction updates the jitter
 * estimate (errors past the outlier bar, max(2 ms, 2.5 sigma), do not). An
 * isolated interval on a whole multiple of the period after an on-time pulse
 * counts the pulses it missed; two in a row are a master that moved to half,
 * a third (...) of its tempo (PR #1236 delta review DH1). A run of errors of
 * one sign beyond max(2 ms, 1 sigma) whose last six average past the outlier
 * bar is classified (the average, not each error, because block-edge jitter
 * is a sawtooth that dips under any single bar every few pulses): a line
 * fitted through the run with the old slope, whole periods late, is pulses
 * dropped without a mark (count them, keep the period); a slope several
 * standard errors from the old one is a tempo step (re-fit a line over the
 * run and the pulses that follow, as at acquisition); the classifier costs
 * O(run length) per pulse. So the pulse count stays exact for anchors and
 * Song Position, also on block-edge sources where a single interval cannot
 * tell a drop from jitter.
 *
 * Late delivery (PR #1259 delta review DH1): a stall of the reader or the
 * bus holds the pulses that fall in it and delivers them together. A pulse
 * within a quarter period of the previous one is part of such a burst:
 * counted, its time kept from the loop, runs and fits. A pulse late past the
 * outlier bar (in a re-fit or acquisition: half a period off a line that
 * knows its period) is held one pulse: if a burst follows, or the next
 * pulse is less than half as late, it was late delivery and is counted
 * without its time; otherwise it is processed as the evidence it is (a
 * drop, a step, a whole multiple). A re-fit counts pulses its line finds
 * whole periods late only once its period is known to 1 %.
 *
 * Loss: silence for max(6 periods, 250 ms) while Synced, decided at the
 * deadline whether or not a pulse arrives in the same block (review L1), or
 * the device going away. A Lost follower keeps its period and readout until
 * pulses return.
 *
 * Units: MIDI clock is 24 pulses per QUARTER note; the engine's tempo is in
 * time-signature DENOMINATOR notes per minute (tempo_grid.h). The follower
 * works in quarter-note periods and converts with ts_den / 4 at its edges:
 * the valid window is the engine's 30..300 BPM clamp in the current
 * denominator, and le_clock_follow_engine_bpm is in the engine's unit.
 */
#ifndef SEGNO_ENGINE_CLOCK_FOLLOW_H
#define SEGNO_ENGINE_CLOCK_FOLLOW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pulses per quarter note, fixed by the MIDI spec. */
#define LE_CLOCK_FOLLOW_PPQN 24

/* Follower states. The values are the external half of le_clock_state
 * (segno_engine_api.h); INTERNAL is the engine's, never the follower's. */
#define LE_CLOCK_FOLLOW_WAITING 1
#define LE_CLOCK_FOLLOW_SYNCED 2
#define LE_CLOCK_FOLLOW_LOST 3

/* Event bits returned by le_clock_follow_pulse and le_clock_follow_check. */
#define LE_CLOCK_EVENT_SYNCED 1u     /* became Synced (an acquisition) */
#define LE_CLOCK_EVENT_REACQUIRED 2u /* a tempo step: re-fitting the period */
#define LE_CLOCK_EVENT_LOST 4u       /* Synced -> Lost */
#define LE_CLOCK_EVENT_WAITING 8u    /* Synced -> Waiting (silence after Stop) */

#define LE_CLOCK_FOLLOW_OUTLIERS 64

/* A least-squares line through (pulse index, time). Times are relative to
 * t0 so the sums keep their precision. */
/* Points a fit holds: four beats of intervals and the first pulse. */
#define LE_CLOCK_FIT_POINTS (4 * LE_CLOCK_FOLLOW_PPQN + 1)

typedef struct le_clock_fit {
  uint64_t t0;
  int32_t n;    /* points */
  int32_t k;    /* index of the last point */
  double sk, st, skk, skt, stt;
  /* The points themselves, so a fit that spans a tempo change can be cut
   * back to the part after it. */
  int32_t pk[LE_CLOCK_FIT_POINTS];
  uint64_t pt[LE_CLOCK_FIT_POINTS];
} le_clock_fit;

typedef struct le_clock_follow {
  int32_t state;
  int32_t ts_den;       /* the denominator the window and units use */
  int32_t stopped;      /* the last transport byte was Stop */
  int32_t out_of_range; /* a steady clock outside the valid window */
  int32_t have_last;
  int32_t gap;          /* messages were lost since the last pulse */
  uint64_t last_t;      /* the last pulse's time, ns */
  /* A pulse that arrived late enough to be either a late delivery (a burst
   * of the pulses held behind it follows within a quarter period) or real
   * evidence (a drop, a step): counted, its timing held for one pulse. */
  int32_t deferred;
  uint64_t def_t, def_prev;
  double def_iv;
  /* Acquisition, and re-fitting after a tempo step. */
  le_clock_fit fit;
  int32_t refit;        /* Synced, but the period is being re-fitted */
  int32_t n_oor;
  double oor_prev;
  /* Tracking. */
  double period;  /* the quarter-note pulse period, ns */
  double pred;    /* the predicted time of the next pulse, ns */
  double var;     /* the jitter estimate, ns^2 */
  double e_prev;  /* the previous pulse's error, ns */
  int32_t since;  /* pulses since the last acquisition */
  int32_t out_count, out_sign, n_out;
  int32_t out_armed;    /* the run's errors averaged past the outlier bar */
  double out_e[LE_CLOCK_FOLLOW_OUTLIERS];    /* the run's errors, ns */
  uint64_t out_t[LE_CLOCK_FOLLOW_OUTLIERS]; /* the run's pulse times */
  double out_t0;        /* where the loop placed the pulse before the run
                         * (its own line, not that pulse's noisy time) */
  double out_period;    /* the period when the run began */
  int32_t multi_prev;    /* k of the previous interval if it counted k >= 2
                          * pulses, else 0 */
  double multi_iv;       /* that interval, ns */
  int32_t multi_extra;   /* extra pulses the latest whole-multiple interval
                          * counted, and intervals since it: taken back if a
                          * tempo step re-seeds right after it */
  int32_t since_multi;
  uint64_t pulses;       /* every pulse received or counted as missed */
  uint32_t reacquisitions;
  float display_bpm;     /* engine unit, 0.1 BPM with hysteresis; 0 = none */
  double est_mean;       /* a one-beat running mean of the estimate */
  double est_var;        /* its wander around that mean, over eight beats */
  int32_t display_hold;  /* pulses the rounded estimate has differed from
                          * the readout */
} le_clock_follow;

/* Waiting for clock, everything cleared. `ts_den` is 4 or 8 (any value <= 0
 * reads as 4). */
void le_clock_follow_reset(le_clock_follow* f, int32_t ts_den);

/* The denominator changed: the window and the published units follow. */
void le_clock_follow_set_den(le_clock_follow* f, int32_t ts_den);

/* One Timing Clock (0xF8) received at `t_ns`. Returns LE_CLOCK_EVENT_* bits.
 * A pulse with the same time as the previous one (two in one packet or one
 * read) is counted; an earlier time is ignored. */
uint32_t le_clock_follow_pulse(le_clock_follow* f, uint64_t t_ns);

/* Start (0xFA), Continue (0xFB) or Stop (0xFC). The follower only remembers
 * whether the master is stopped: silence after a Stop is Waiting, not loss. */
void le_clock_follow_transport(le_clock_follow* f, uint8_t status);

/* Messages were lost before the next pulse (the port's gap mark): no
 * interval may span it, and once Synced the pulses it hid are counted. */
void le_clock_follow_gap(le_clock_follow* f);

/* The source device went away, or another capture now feeds the source
 * port: Synced becomes Lost (returning LE_CLOCK_EVENT_LOST), Lost stays
 * Lost with its period and readout, Waiting stays Waiting. Only the
 * acquisition state restarts (PR #1259 review M2). */
uint32_t le_clock_follow_lost(le_clock_follow* f);

/* Whether the follower's tempo may be written as the session tempo: Synced,
 * not re-fitting, and tracked for a whole beat since the last acquisition or
 * re-fit (the first estimate of a coarse source is not published). */
int le_clock_follow_tempo_ready(const le_clock_follow* f);

/* Checks for silence at `now_ns`: no pulse for max(6 periods, 250 ms) while
 * Synced is Lost, or Waiting after a Stop. Returns the event bit. */
uint32_t le_clock_follow_check(le_clock_follow* f, uint64_t now_ns);

/* The master's tempo in quarter notes per minute, or 0 before acquisition. */
double le_clock_follow_quarter_bpm(const le_clock_follow* f);

/* The same tempo in the engine's unit (denominator notes per minute). */
double le_clock_follow_engine_bpm(const le_clock_follow* f);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_CLOCK_FOLLOW_H */
