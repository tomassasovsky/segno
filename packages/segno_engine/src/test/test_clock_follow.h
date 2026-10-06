/* test_clock_follow.h - the MIDI clock follower (#1228 Part 2;
 * src/midi/le_clock_follow.h). Included by test_midi_core.c.
 *
 * The jitter models are the PR #1236 review's (its dll.c probe), seeded so
 * every run sees the same pulses: uniform random +-1 ms, 1 ms USB-frame
 * quantization, pulses quantized to 512-frame / 44.1 kHz block edges (a
 * source that emits clock per audio buffer), and those edges plus 0.5 ms of
 * noise. Times are ns. */

#include <math.h>

#include "le_clock_follow.h"

static uint64_t cf_rng = 12345u;
static double cf_urand(void) {
  cf_rng = cf_rng * 6364136223846793005ull + 1442695040888963407ull;
  return (double)((cf_rng >> 11) & ((1ull << 53) - 1)) / (double)(1ull << 53);
}

typedef double (*cf_jitter)(double t_s);
static double cf_j_none(double t) { (void)t; return 0.0; }
static double cf_j_uniform(double t) { (void)t; return (cf_urand() - 0.5) * 0.002; }
static double cf_j_usb(double t) { return ceil(t * 1000.0) / 1000.0 - t; }
static double cf_j_block(double t) {
  const double b = 512.0 / 44100.0;
  return ceil(t / b) * b - t;
}
static double cf_j_block_noise(double t) {
  return cf_j_block(t) + (cf_urand() - 0.5) * 0.001;
}

typedef struct cf_run {
  uint32_t reacquisitions;
  double max_err;      /* |engine bpm - truth| after 5 s, outside the step */
  double settle_s;     /* time after the step to within 0.1 BPM, or -1 */
  double seeded_ms;    /* the period right after the first re-acquisition */
  uint64_t sent;       /* pulses the source produced (dropped ones too) */
  uint64_t counted;    /* the follower's pulse count */
  int synced;
  int display_changes; /* readout changes after 5 s, outside the step */
  float display_end;   /* the readout at the end */
} cf_run;

/* 60 s of quarter-note clock at bpm1, switching to bpm2 at `step_s`, with
 * pulse number `drop` (1-based) lost on the way. 4/4. */
static cf_run cf_simulate(cf_jitter j, double bpm1, double bpm2, double step_s,
                          uint64_t drop) {
  cf_rng = 12345u;
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  cf_run r = {0u, 0.0, -1.0, 0.0, 0u, 0u, 0, 0, 0.0f};
  float shown = 0.0f;
  double tt = 0.0;
  while (tt < 60.0) {
    const double bpm = tt < step_s ? bpm1 : bpm2;
    const double t = tt + j(tt);
    tt += 60.0 / (bpm * LE_CLOCK_FOLLOW_PPQN);
    r.sent++;
    if (drop != 0 && r.sent == drop) continue;
    /* Offset by a second: a monotonic timestamp is never negative. */
    const uint32_t ev =
        le_clock_follow_pulse(&f, (uint64_t)llround((t + 1.0) * 1e9));
    if ((ev & LE_CLOCK_EVENT_REACQUIRED) && r.reacquisitions++ == 0) {
      r.seeded_ms = f.period / 1e6;
    }
    if (f.state != LE_CLOCK_FOLLOW_SYNCED) continue;
    r.synced = 1;
    const double est = le_clock_follow_engine_bpm(&f);
    if (tt > step_s && r.settle_s < 0.0 && fabs(est - bpm2) < 0.1) {
      r.settle_s = tt - step_s;
    }
    if (tt > 5.0 && !(tt > step_s && tt < step_s + 4.0)) {
      const double err = fabs(est - bpm);
      if (err > r.max_err) r.max_err = err;
      if (shown != 0.0f && f.display_bpm != shown) r.display_changes++;
    }
    shown = f.display_bpm;
  }
  r.counted = f.pulses;
  r.display_end = f.display_bpm;
  return r;
}

static void test_clock_follow_jitter_models(void) {
  printf("test_clock_follow_jitter_models\n");
  const double bpms[] = {90.0, 120.0, 124.9, 174.0};
  for (int i = 0; i < 4; ++i) {
    const double b = bpms[i];
    /* The readout settles at most once after 5 s and then holds still (the
     * PR #1236 delta review's DL1 measured 2-3 flips a minute on block-edge
     * sources with a fixed 0.15 BPM band). */
    cf_run r = cf_simulate(cf_j_uniform, b, b, 999.0, 0);
    CHECK(r.synced && r.reacquisitions == 0 && r.max_err < 0.06);
    CHECK(r.display_changes <= 1 && fabs(r.display_end - b) < 0.11);
    r = cf_simulate(cf_j_usb, b, b, 999.0, 0);
    CHECK(r.synced && r.reacquisitions == 0 && r.max_err < 0.04);
    CHECK(r.display_changes <= 1 && fabs(r.display_end - b) < 0.11);
    r = cf_simulate(cf_j_block, b, b, 999.0, 0);
    CHECK(r.synced && r.reacquisitions == 0 && r.max_err < 0.25);
    CHECK(r.display_changes <= 1 && r.counted == r.sent);
    r = cf_simulate(cf_j_block_noise, b, b, 999.0, 0);
    CHECK(r.synced && r.reacquisitions == 0 && r.max_err < 0.25);
    CHECK(r.display_changes <= 1 && r.counted == r.sent);
    if (r.max_err >= 0.25 || r.reacquisitions != 0) {
      printf("  at %.1f BPM: err %.3f, reacq %u\n", b, r.max_err,
             r.reacquisitions);
    }
  }
}

/* A tempo step re-seeds from the new intervals only: 120 -> 100 seeds the
 * 100 BPM period (25 ms), not the mean of old and new. */
static void test_clock_follow_tempo_step(void) {
  printf("test_clock_follow_tempo_step\n");
  cf_run r = cf_simulate(cf_j_uniform, 120.0, 100.0, 30.0, 0);
  CHECK(r.reacquisitions == 1);
  CHECK(fabs(r.seeded_ms - 25.0) < 0.5);
  CHECK(r.settle_s >= 0.0 && r.settle_s < 1.5);
  CHECK(r.max_err < 0.1);
  r = cf_simulate(cf_j_usb, 174.0, 90.0, 30.0, 0);
  CHECK(r.reacquisitions == 1 && r.settle_s >= 0.0 && r.settle_s < 1.5);
}

/* A bus stall delays four pulses in a row by 4 ms: outliers of one sign,
 * but not a tempo step, so no re-acquisition and the tempo holds. */
static double cf_stall_from = 20.0;
static double cf_j_stall(double t) {
  const double p = 60.0 / (120.0 * LE_CLOCK_FOLLOW_PPQN);
  const double u = (cf_urand() - 0.5) * 0.002;
  return (t >= cf_stall_from && t < cf_stall_from + 3.5 * p) ? u + 0.004 : u;
}

static void test_clock_follow_stall_is_not_a_step(void) {
  printf("test_clock_follow_stall_is_not_a_step\n");
  cf_run r = cf_simulate(cf_j_stall, 120.0, 120.0, 999.0, 0);
  CHECK(r.reacquisitions == 0);
  CHECK(r.max_err < 0.1);
}

/* A master that moves to half, a third (...) of its tempo is followed, not
 * read as every other pulse missing (PR #1236 delta review DH1), and the
 * pulse count stays exact through the step, on every source model. */
static void test_clock_follow_integer_divisions(void) {
  printf("test_clock_follow_integer_divisions\n");
  const double steps[][2] = {{120.0, 60.0}, {150.0, 50.0}, {174.0, 87.0}};
  const cf_jitter models[] = {cf_j_uniform, cf_j_usb, cf_j_block,
                              cf_j_block_noise};
  for (int i = 0; i < 3; ++i) {
    for (int m = 0; m < 4; ++m) {
      cf_run r = cf_simulate(models[m], steps[i][0], steps[i][1], 30.0, 0);
      CHECK(r.reacquisitions == 1);
      CHECK(r.settle_s >= 0.0 && r.settle_s < 1.5);
      CHECK(r.counted == r.sent);
      CHECK(r.max_err < 0.3);
      CHECK(r.display_changes <= 2);
    }
  }
}

/* Seconds after a tempo glide from b1 (until t1) to b2 (at t2) ends until
 * the readout shows b2, or -1. The DLL follows a glide without re-seeding,
 * so this is the readout's own lag. */
static double cf_readout_lag(double b1, double b2, double t1, double t2) {
  cf_rng = 12345u;
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  double tt = 0.0;
  while (tt < 40.0) {
    const double bpm = tt < t1 ? b1 : tt > t2 ? b2 : b1 + (b2 - b1) * (tt - t1) / (t2 - t1);
    const double t = tt + cf_j_uniform(tt);
    tt += 60.0 / (bpm * LE_CLOCK_FOLLOW_PPQN);
    le_clock_follow_pulse(&f, (uint64_t)llround((t + 1.0) * 1e9));
    if (tt > t2 && fabs(f.display_bpm - b2) < 0.11) return tt - t2;
  }
  return -1.0;
}

/* The readout follows a ramp and a change right after Synced within two
 * seconds and never rests on a wrong tenth (its band is wide only against
 * flicker, and a beat-long difference is shown anyway). */
static void test_clock_follow_readout_follows_glides(void) {
  printf("test_clock_follow_readout_follows_glides\n");
  double lag = cf_readout_lag(120.0, 126.0, 0.31, 0.32); /* before 2 beats */
  CHECK(lag >= 0.0 && lag < 2.0);
  lag = cf_readout_lag(120.0, 126.0, 10.0, 26.0);
  CHECK(lag >= 0.0 && lag < 2.0);
  lag = cf_readout_lag(128.0, 100.0, 10.0, 20.0);
  CHECK(lag >= 0.0 && lag < 2.0);
}

/* A dropped pulse is counted, not mistaken for a slow pulse. */
static void test_clock_follow_dropped_pulse_counted(void) {
  printf("test_clock_follow_dropped_pulse_counted\n");
  cf_run r = cf_simulate(cf_j_uniform, 120.0, 120.0, 999.0, 600);
  CHECK(r.counted == r.sent);
  CHECK(r.reacquisitions == 0 && r.max_err < 0.06);
  r = cf_simulate(cf_j_usb, 120.0, 120.0, 999.0, 600);
  CHECK(r.counted == r.sent);
}

/* Feeds `n` pulses of a steady quarter-note clock from `t0`. */
static uint64_t cf_feed(le_clock_follow* f, double quarter_bpm, uint64_t t0,
                        int n, uint32_t* events) {
  const double p = 60e9 / (quarter_bpm * LE_CLOCK_FOLLOW_PPQN);
  uint64_t t = t0;
  for (int i = 0; i < n; ++i) {
    t = t0 + (uint64_t)llround(i * p);
    const uint32_t ev = le_clock_follow_pulse(f, t);
    if (events != NULL) *events |= ev;
  }
  return t;
}

static void test_clock_follow_acquisition_and_units(void) {
  printf("test_clock_follow_acquisition_and_units\n");
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
  uint32_t ev = 0u;
  /* Six intervals need seven pulses. */
  cf_feed(&f, 120.0, 1000000000ull, 6, &ev);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING && ev == 0u);
  CHECK(le_clock_follow_pulse(&f, 1000000000ull + 125000000ull) ==
        LE_CLOCK_EVENT_SYNCED);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED);
  CHECK(fabs(le_clock_follow_engine_bpm(&f) - 120.0) < 0.001);
  CHECK(f.display_bpm == 120.0f);
  CHECK(f.pulses == 7u);

  /* 6/8: the same quarter-note clock is 240 in Segno's eighth-note unit. */
  le_clock_follow_reset(&f, 8);
  cf_feed(&f, 120.0, 0u, 7, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED);
  CHECK(fabs(le_clock_follow_engine_bpm(&f) - 240.0) < 0.001);
  CHECK(fabs(le_clock_follow_quarter_bpm(&f) - 120.0) < 0.001);
  CHECK(f.display_bpm == 240.0f);
  /* Changing the signature changes the published unit, not the clock. */
  le_clock_follow_set_den(&f, 4);
  CHECK(fabs(le_clock_follow_engine_bpm(&f) - 120.0) < 0.001);
  CHECK(f.display_bpm == 120.0f);

  /* 6/8 with a 160 quarter-note clock is 320 eighth notes: out of range. */
  le_clock_follow_reset(&f, 8);
  cf_feed(&f, 160.0, 0u, 40, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
  CHECK(f.out_of_range == 1);
  /* The same clock in 4/4 is 160: in range. */
  le_clock_follow_reset(&f, 4);
  cf_feed(&f, 160.0, 0u, 7, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED && f.out_of_range == 0);
}

/* An interval outside the window (90 ms at 120 BPM, beyond 30 BPM's 85 ms)
 * restarts acquisition: six fresh valid intervals are needed. */
static void test_clock_follow_invalid_interval_resets_acquisition(void) {
  printf("test_clock_follow_invalid_interval_resets_acquisition\n");
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  const uint64_t last = cf_feed(&f, 120.0, 0u, 5, NULL); /* 4 intervals */
  const uint64_t after = last + 90000000ull;
  CHECK(le_clock_follow_pulse(&f, after) == 0u);
  cf_feed(&f, 120.0, after + 20833333ull, 5, NULL); /* 5 more intervals */
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
  CHECK(le_clock_follow_pulse(&f, after + 6u * 20833333ull) ==
        LE_CLOCK_EVENT_SYNCED);
}

static void test_clock_follow_loss_and_stop(void) {
  printf("test_clock_follow_loss_and_stop\n");
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  const uint64_t last = cf_feed(&f, 120.0, 0u, 48, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED);
  /* At 120 BPM six periods are 125 ms, so the 250 ms floor rules. */
  CHECK(le_clock_follow_check(&f, last + 249000000ull) == 0u);
  CHECK(le_clock_follow_check(&f, last + 250000000ull) == LE_CLOCK_EVENT_LOST);
  CHECK(f.state == LE_CLOCK_FOLLOW_LOST);
  CHECK(f.display_bpm == 120.0f); /* the last tempo is kept */
  /* Pulses return: re-acquired. */
  uint32_t ev = 0u;
  const uint64_t again = cf_feed(&f, 120.0, last + 1000000000ull, 7, &ev);
  CHECK((ev & LE_CLOCK_EVENT_SYNCED) && f.state == LE_CLOCK_FOLLOW_SYNCED);
  /* Silence after a Stop is Waiting, not loss. */
  le_clock_follow_transport(&f, 0xFC);
  CHECK(le_clock_follow_check(&f, again + 300000000ull) ==
        LE_CLOCK_EVENT_WAITING);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
  /* A Start clears it; the device going away while Synced is Lost at once. */
  le_clock_follow_transport(&f, 0xFA);
  cf_feed(&f, 120.0, again + 1000000000ull, 7, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED);
  CHECK(le_clock_follow_lost(&f) == LE_CLOCK_EVENT_LOST);
  CHECK(f.state == LE_CLOCK_FOLLOW_LOST);
  CHECK(le_clock_follow_lost(&f) == 0u);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
}

/* A known loss (the port's gap mark) counts the pulses it hid even before
 * the jitter estimate has settled. */
static void test_clock_follow_gap_counts_hidden_pulses(void) {
  printf("test_clock_follow_gap_counts_hidden_pulses\n");
  le_clock_follow f;
  le_clock_follow_reset(&f, 4);
  const double p = 60e9 / (120.0 * LE_CLOCK_FOLLOW_PPQN);
  cf_feed(&f, 120.0, 0u, 10, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED && f.pulses == 10u);
  le_clock_follow_gap(&f);
  /* Pulses 10, 11 and 12 were lost; pulse 13 arrives. */
  CHECK(le_clock_follow_pulse(&f, (uint64_t)llround(13 * p)) == 0u);
  CHECK(f.pulses == 14u);
  CHECK(f.state == LE_CLOCK_FOLLOW_SYNCED);
  /* A gap during acquisition restarts it instead. */
  le_clock_follow_reset(&f, 4);
  cf_feed(&f, 120.0, 0u, 4, NULL);
  le_clock_follow_gap(&f);
  cf_feed(&f, 120.0, (uint64_t)llround(6 * p), 6, NULL);
  CHECK(f.state == LE_CLOCK_FOLLOW_WAITING);
  CHECK(le_clock_follow_pulse(&f, (uint64_t)llround(12 * p)) ==
        LE_CLOCK_EVENT_SYNCED);
  (void)cf_j_none;
}

static void run_clock_follow_tests(void) {
  test_clock_follow_jitter_models();
  test_clock_follow_tempo_step();
  test_clock_follow_stall_is_not_a_step();
  test_clock_follow_integer_divisions();
  test_clock_follow_readout_follows_glides();
  test_clock_follow_dropped_pulse_counted();
  test_clock_follow_acquisition_and_units();
  test_clock_follow_invalid_interval_resets_acquisition();
  test_clock_follow_loss_and_stop();
  test_clock_follow_gap_counts_hidden_pulses();
}
