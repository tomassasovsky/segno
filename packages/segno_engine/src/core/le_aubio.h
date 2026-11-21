/* le_aubio.h — the engine's door to the vendored aubio subset (#1936).
 *
 * aubio (GPL-3.0-or-later, third_party/aubio/) supplies the onset detection
 * function and the causal tempo tracker the beat analysis runs on. Every
 * aubio type and macro stays inside le_aubio.c, which compiles the subset as
 * one translation unit; the engine sees only these plain-C handles.
 *
 * Not real-time: each constructor allocates, and the analysis worker
 * (engine_analysis.c) is the only caller. Never call these from the audio
 * thread. */
#ifndef SEGNO_LE_AUBIO_H
#define SEGNO_LE_AUBIO_H

#ifdef __cplusplus
extern "C" {
#endif

/* Spectral flux over a [win]-sample Hann window advanced by [hop] samples:
 * how much the spectrum's energy rose since the last hop, the usual onset
 * strength signal for beat and tempo work. */
typedef struct le_onset_odf le_onset_odf;
le_onset_odf* le_onset_odf_new(int win, int hop);
void le_onset_odf_free(le_onset_odf* o);
/* Takes the next [hop] samples and returns the onset strength (>= 0). */
float le_onset_odf_step(le_onset_odf* o, const float* hop_samples);

/* aubio's causal beat tracker (Davies & Plumbley) over spectral flux, at
 * [sample_rate]. */
typedef struct le_beat_tracker le_beat_tracker;
le_beat_tracker* le_beat_tracker_new(int win, int hop, int sample_rate);
void le_beat_tracker_free(le_beat_tracker* t);
/* Takes the next [hop] samples. */
void le_beat_tracker_step(le_beat_tracker* t, const float* hop_samples);
/* The current tempo estimate in BPM, 0 before one exists. */
float le_beat_tracker_bpm(le_beat_tracker* t);
/* How sure the tracker is of [le_beat_tracker_bpm]: 0 with no estimate;
 * larger is surer (aubio's own scale). */
float le_beat_tracker_confidence(le_beat_tracker* t);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_LE_AUBIO_H */
