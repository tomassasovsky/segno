/*
 * le_stretch.h — C ABI over the vendored Signalsmith Stretch library (#1179).
 *
 * The library (third_party/signalsmith-stretch, MIT, header-only C++) is the
 * engine's pitch-preserving time-stretch and pitch-shift. The engine core is C,
 * so this is the ONE translation unit that includes the template
 * (le_stretch.cpp); everything else, the cache worker, the offline renderer,
 * the import Adapt seam and the bench, calls through these plain C functions.
 *
 * Nothing here is real-time safe except le_stretch_process / _seek / _flush on
 * an already created instance (the library allocates in configure only;
 * measured in the July spike and re-measured by the bench). Create and destroy
 * on a control or worker thread.
 *
 * Buffers are planar: in[channel][frame], out[channel][frame].
 */
#ifndef LE_STRETCH_H
#define LE_STRETCH_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_stretch le_stretch;

/* Return codes (deliberately not segno_engine_api.h's le_result, so this header
 * stays usable without the engine). */
#define LE_STRETCH_OK 0
#define LE_STRETCH_ERR_INVALID (-1)
#define LE_STRETCH_ERR_ALLOC (-2)

/* `cheaper` selects presetCheaper (block 0.1 s, interval 0.04 s) over
 * presetDefault (0.12 s / 0.03 s). `seed` fixes the phase-randomization RNG:
 * two instances with the same seed, preset, rate and input render identical
 * output. NULL on bad arguments or allocation failure. */
le_stretch* le_stretch_create(int32_t channels, int32_t sample_rate,
                              int32_t cheaper, uint32_t seed);
void le_stretch_destroy(le_stretch* s);
void le_stretch_reset(le_stretch* s);

int32_t le_stretch_channels(const le_stretch* s);
int32_t le_stretch_block_samples(const le_stretch* s);
int32_t le_stretch_interval_samples(const le_stretch* s);
int32_t le_stretch_input_latency(const le_stretch* s);
int32_t le_stretch_output_latency(const le_stretch* s);

/* Pitch shift in semitones; `tonality_limit` in cycles per sample (0 = none;
 * the upstream README recommends 8000 / sample_rate to keep more timbre). */
void le_stretch_set_semitones(le_stretch* s, float semitones,
                              float tonality_limit);

/* Streaming: consumes n_in input frames and produces n_out output frames; the
 * time ratio is n_out / n_in over time (the library has no ratio parameter). */
void le_stretch_process(le_stretch* s, const float* const* in, int32_t n_in,
                        float* const* out, int32_t n_out);
/* Pre-roll: provides previous input without producing output. `rate` is input
 * frames per output frame (1 / ratio). Ideally block + interval frames. */
void le_stretch_seek(le_stretch* s, const float* const* in, int32_t n_in,
                     double rate);
/* Reads the remaining output after the last input; ideally output_latency frames. */
void le_stretch_flush(le_stretch* s, float* const* out, int32_t n_out);

/* Offline exact-length render: `in_frames` frames become exactly `out_frames`
 * frames at time ratio `ratio` (= out / in nominally; the caller chooses
 * out_frames, which is what makes a rendered lap tile the clock exactly) with
 * `semitones` of pitch shift. `cyclic != 0` treats the input as one lap of a
 * loop: the pre-roll and the run-out are the lap's own tail and head, so the
 * output loops as seamlessly as a seam-folded take; 0 pads with silence (a
 * one-shot file). Control thread; allocates; deterministic for a given seed,
 * preset, sample rate and input. */
int32_t le_stretch_render_offline(const float* const* in, int32_t in_frames,
                                  int32_t channels, int32_t sample_rate,
                                  double ratio, float semitones,
                                  float tonality_limit, int32_t cheaper,
                                  uint32_t seed, int32_t cyclic,
                                  float* const* out, int32_t out_frames);

#ifdef __cplusplus
}
#endif
#endif /* LE_STRETCH_H */
