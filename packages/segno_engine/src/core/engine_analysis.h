/* engine_analysis.h — beat analysis of a free first take (#1936).
 *
 * While a defining take records with no tempo, the audio thread copies the
 * take's input (mono) into a lock-free ring; a worker thread drains it and
 * computes the onset strength per hop (spectral flux, le_aubio.h) and a live
 * tempo estimate. When the take closes, the worker scores the take's whole
 * bar counts the plan allows (1, 2, 4, 8 and 16 bars whose tempo falls
 * between 60 and 200 BPM) by how well the onsets repeat at each one's beat,
 * and answers with the winner, or 0 when none is clearly better.
 *
 * Threads: create and destroy on the control thread; begin, push, end,
 * result and abort on the audio thread only (wait-free, no allocation);
 * the estimate on any thread. */
#ifndef SEGNO_ENGINE_ANALYSIS_H
#define SEGNO_ENGINE_ANALYSIS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_analysis le_analysis;

/* The analysis for [sample_rate], able to hold a take of [max_loop_frames];
 * NULL when it cannot be made (the engine then derives tempo as before). */
le_analysis* le_analysis_create(int32_t sample_rate, int32_t max_loop_frames);
void le_analysis_destroy(le_analysis* a);

/* Audio thread: a new take starts; what was pushed before is discarded. */
void le_analysis_begin(le_analysis* a);
/* Audio thread: the take's next [n] samples. A full ring drops them, and
 * the take's answer is then 0. */
void le_analysis_push(le_analysis* a, const float* mono, int32_t n);
/* Audio thread: the take closed at [len] frames in [ts_num]/x: answer which
 * bar count it holds. */
void le_analysis_end(le_analysis* a, int32_t len, int32_t ts_num);
/* Audio thread: the take was dropped (cleared, voided): no answer. */
void le_analysis_abort(le_analysis* a);
/* Audio thread: 1 once the answer to the latest end is ready, with the
 * chosen bars in [*bars] (0: no clear choice); 0 while it is not. */
int le_analysis_result(le_analysis* a, int32_t* bars);

/* Any thread: the live estimate of the take being recorded (#1936 part 5):
 * its tempo in BPM and the tracker's confidence, both 0 with none. */
void le_analysis_estimate(le_analysis* a, float* bpm, float* confidence);

/* The bar choice itself, exposed for tests: scores [bars] candidates over
 * the onset strengths [odf] (n hops of [hop] frames) of a [len]-frame loop
 * in [ts_num]/x at [sample_rate]. Returns the chosen bars, or 0. */
int32_t le_analysis_choose_bars(const float* odf, int32_t n, int32_t hop,
                                int32_t len, int32_t ts_num,
                                int32_t sample_rate);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_ANALYSIS_H */
