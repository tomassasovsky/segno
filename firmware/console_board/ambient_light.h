/*
 * ambient_light.h - the light sensor on J22 (#1564), as the console board
 * reads it: whether one is fitted, and the light it sees, smoothed over
 * seconds, in the pedal link's AMBIENT units.
 *
 * The circuit (segno-hardware, hardware/segno_wiring.md): a Vishay TEPT5600
 * NPN phototransistor, its lens sanded flat and glued flush in the faceplate,
 * with its collector on J22's +3V3 and its emitter on GP28 (ADC2), and a load
 * resistor (2.2 k as fitted) from GP28 to ground with 100 nF across it, both
 * at the J22 end of the lead. The photocurrent through the load is the
 * voltage the ADC reads.
 *
 * The board reports that reading, not lux. The sensor's gain is not known
 * here: Vishay's bins span 9x, and sanding the lens off lowers the gain by
 * an unmeasured factor. So the board only smooths the raw reading and says
 * it on a log scale; the app turns it into brightness through two points the
 * owner captures in Settings (a dark room and a bright room), and the load
 * resistor can be swapped for one that suits the measured gain without
 * touching this firmware.
 *
 * Plain C99 with no Arduino dependencies: console_board.ino owns the pins,
 * the ADC and the pad pulls, and feeds this unit readings. The host test
 * (firmware/test/test_ambient_light.c) runs it as-is.
 */
#ifndef SEGNO_AMBIENT_LIGHT_H
#define SEGNO_AMBIENT_LIGHT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Above this the sensor's collector-emitter voltage is under about 0.3 V and
 * its response compresses: the top of the range. A bright room that reads
 * here needs a smaller load resistor. */
#define AMBIENT_TOP_COUNTS 3700u

/* One reading every AMBIENT_SAMPLE_MS; AMBIENT_WINDOW of them make one
 * second's mean, which takes out mains-driven flicker (100/120 Hz) and LED
 * dimmer PWM. */
#define AMBIENT_SAMPLE_MS 10u
#define AMBIENT_WINDOW 100u

/* The median of the last AMBIENT_MEDIAN seconds, so anything shorter than
 * about half of that (a hand passing, a shadow, a strobe hit) never reaches
 * the level at all; then an exponential average that moves
 * AMBIENT_SMOOTHING of the way each second, about a 3 s time constant. */
#define AMBIENT_MEDIAN 5u
#define AMBIENT_SMOOTHING 0.3f

/* The reported level moves only when the smoothed reading has moved this
 * many level steps from it: 4 of the 16 per doubling, about 19 %. Darkness
 * is reported as 0 exactly. Whether the sensor is at the top of its range
 * follows the median alone, so it changes no faster than the median does,
 * and while it is the level is the top exactly. */
#define AMBIENT_HYSTERESIS 4

/* The pad-pull probe that tells a fitted sensor from an open pin, every
 * AMBIENT_PROBE_MS. A pin that follows the pull-up into the top quarter and
 * the pull-down into the bottom quarter has nothing on it: the thresholds
 * leave the weak pad pulls (50 to 80 k) a wide margin against the ADC's
 * sampling load. A fitted load holds the pin near its own reading, the two
 * pulls moving it apart by at most about 1 V (22 k, the largest load the
 * docs allow) and usually 0.15 V (2.2 k), never the 1.6 V between the
 * thresholds. A pin at ground even with the pull-up on is shorted there: the
 * pull-up still lifts a fitted 1 k load about 0.04 V. */
#define AMBIENT_PROBE_MS 2000u
#define AMBIENT_PROBE_RAIL 3000u
#define AMBIENT_PROBE_FLOOR 1000u
#define AMBIENT_PROBE_GROUNDED 20u

typedef struct ambient_light {
  uint8_t probed;       /* a probe has given a verdict */
  uint8_t fitted;       /* the current verdict */
  uint8_t disagreed;    /* consecutive probes against the current verdict */
  uint32_t sum;         /* this second's readings */
  uint16_t samples;
  float history[AMBIENT_MEDIAN]; /* the last seconds' levels, fractional */
  uint8_t history_len;
  uint8_t history_pos;
  float smoothed;
  uint8_t have_level;
  uint8_t above;        /* the median second is at the top of the range */
  uint8_t level;        /* the reported level, PEDAL_AMBIENT_STEPS_PER_DOUBLING per doubling */
} ambient_light;

void ambient_light_init(ambient_light *a);

/* The fractional level for a reading in ADC counts: 16 * log2(counts), 0 at
 * or below one count, capped at AMBIENT_TOP_COUNTS. */
float ambient_light_level_of(float counts);

/* The level at the top of the range (190). */
uint8_t ambient_light_top_level(void);

/* Whether one probe found a sensor: the readings with the pad's pull-up and
 * with its pull-down on. */
int ambient_light_probe_fitted(uint16_t with_pull_up, uint16_t with_pull_down);

/* Records a probe. The first verdict holds at once; after that a change
 * needs two probes in a row, and starts the smoothing over. */
void ambient_light_probe(ambient_light *a, uint16_t with_pull_up, uint16_t with_pull_down);

/* Feeds one reading (counts, pulls off). Ignored while no sensor is fitted. */
void ambient_light_sample(ambient_light *a, uint16_t counts);

/* Whether there is anything to report yet: a verdict, and with a sensor its
 * first second. */
int ambient_light_ready(const ambient_light *a);

/* What AMBIENT carries: a PEDAL_AMBIENT_* value and the level (0 without a
 * sensor). Meaningful once ambient_light_ready(). */
uint8_t ambient_light_sensor(const ambient_light *a);
uint8_t ambient_light_level(const ambient_light *a);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_AMBIENT_LIGHT_H */
