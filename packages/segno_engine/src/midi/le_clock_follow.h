/*
 * le_clock_follow.h - the MIDI clock follower (#1228 Part 2; plan D3).
 *
 * Pure value logic in the shape of le_midi_clock.h: no engine state, no
 * atomics, no allocation, no clock reads. The audio thread feeds it the
 * timestamped Timing Clock and transport bytes of the selected source port
 * (le_midi_ports_drain) and asks it once per block whether the clock was
 * lost; the unit tests drive the same functions with synthetic timestamps.
 *
 * The estimate: the median of six consecutive valid pulse intervals seeds a
 * second-order delay-locked loop (F. Adriaensen, "Using a DLL to filter time",
 * LAC 2005; the filter JACK uses for period times), 0.5 Hz wide for the first
 * eight beats after an acquisition and 0.2 Hz after. Each pulse's error
 * against the prediction updates a jitter estimate; an error beyond
 * max(2 ms, 4 sigma) is an outlier, and six consecutive outliers of one sign
 * mean the master changed tempo: the loop re-seeds from the median of the
 * intervals since the first of them. An isolated pulse interval close to a
 * whole multiple of the period, after a pulse that was on time, counts the
 * missed pulses (a dropped 0xF8 on USB or a DIN framing error), so the pulse
 * count stays exact. Two such intervals in a row are not drops but a master
 * that moved to half, a third (...) of its tempo: the extra pulses counted
 * one interval earlier are taken back and the loop re-seeds at the new
 * period (PR #1236 delta review DH1). The tuning was checked against the jitter models of the PR
 * #1236 review (docs/plan/2026-10-06-midi-clock-follower-probe.c).
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
#define LE_CLOCK_EVENT_REACQUIRED 2u /* re-seeded after a tempo step */
#define LE_CLOCK_EVENT_LOST 4u       /* Synced -> Lost */
#define LE_CLOCK_EVENT_WAITING 8u    /* Synced -> Waiting (silence after Stop) */

#define LE_CLOCK_FOLLOW_OUTLIERS 64

typedef struct le_clock_follow {
  int32_t state;
  int32_t ts_den;       /* the denominator the window and units use */
  int32_t stopped;      /* the last transport byte was Stop */
  int32_t out_of_range; /* a steady clock outside the valid window */
  int32_t have_last;
  int32_t gap;          /* messages were lost since the last pulse */
  uint64_t last_t;      /* the last pulse's time, ns */
  /* Acquisition. */
  double acq[6];
  int32_t n_acq;
  int32_t n_oor;
  double oor_prev;
  /* Tracking. */
  double period;  /* the quarter-note pulse period, ns */
  double pred;    /* the predicted time of the next pulse, ns */
  double var;     /* the jitter estimate, ns^2 */
  double e_prev;  /* the previous pulse's error, ns */
  int32_t since;  /* pulses since the last acquisition */
  int32_t out_count, out_sign, n_out;
  double out_iv[LE_CLOCK_FOLLOW_OUTLIERS];
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

/* One Timing Clock (0xF8) received at `t_ns`. Returns LE_CLOCK_EVENT_* bits. */
uint32_t le_clock_follow_pulse(le_clock_follow* f, uint64_t t_ns);

/* Start (0xFA), Continue (0xFB) or Stop (0xFC). The follower only remembers
 * whether the master is stopped: silence after a Stop is Waiting, not loss. */
void le_clock_follow_transport(le_clock_follow* f, uint8_t status);

/* Messages were lost before the next pulse (the port's gap mark): no
 * interval may span it, and once Synced the pulses it hid are counted. */
void le_clock_follow_gap(le_clock_follow* f);

/* The source device went away: Lost if Synced, otherwise Waiting. Returns
 * LE_CLOCK_EVENT_LOST when it ended a Synced run. */
uint32_t le_clock_follow_lost(le_clock_follow* f);

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
