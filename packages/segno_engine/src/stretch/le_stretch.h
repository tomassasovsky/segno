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
 * measured by the July spike's allocation counter, which bench_pitch_time does
 * not yet repeat). Create and destroy on a control or worker thread.
 *
 * Buffers are planar: in[channel][frame], out[channel][frame].
 *
 * No C++ exception crosses this boundary: every function is noexcept in C++
 * and catches inside, so an allocation failure returns NULL or
 * LE_STRETCH_ERR_ALLOC instead of unwinding into C frames.
 */
#ifndef LE_STRETCH_H
#define LE_STRETCH_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
#define LE_STRETCH_NOEXCEPT noexcept
#else
#define LE_STRETCH_NOEXCEPT
#endif

typedef struct le_stretch le_stretch;

/* Argument bounds. A render is one lane (mono or stereo); 16 channels holds a
 * whole track's eight stereo lanes in one instance. The rate bound keeps the
 * preset block sizes (0.1-0.12 s of samples) to a few MiB. An offline render's
 * time ratio lies in [1 / LE_STRETCH_MAX_RATIO, LE_STRETCH_MAX_RATIO], four
 * octaves of tempo either way; the bound keeps every frame count the render
 * derives from the ratio finite and in range (a ratio of 1e-12 or 1e12 used
 * to overflow the double-to-integer conversions). */
#define LE_STRETCH_MAX_CHANNELS 16
#define LE_STRETCH_MAX_SAMPLE_RATE 384000
#define LE_STRETCH_MAX_RATIO 16.0

/* Return codes (deliberately not segno_engine_api.h's le_result, so this header
 * stays usable without the engine). */
#define LE_STRETCH_OK 0
#define LE_STRETCH_ERR_INVALID (-1)
#define LE_STRETCH_ERR_ALLOC (-2)

/* `cheaper` selects presetCheaper (block 0.1 s, interval 0.04 s) over
 * presetDefault (0.12 s / 0.03 s). `seed` fixes the phase-randomization RNG:
 * two instances with the same seed, preset, rate and input render identical
 * output. NULL on bad arguments (channels outside 1..LE_STRETCH_MAX_CHANNELS,
 * sample_rate outside 1..LE_STRETCH_MAX_SAMPLE_RATE) or allocation failure. */
le_stretch* le_stretch_create(int32_t channels, int32_t sample_rate,
                              int32_t cheaper,
                              uint32_t seed) LE_STRETCH_NOEXCEPT;
void le_stretch_destroy(le_stretch* s) LE_STRETCH_NOEXCEPT;
void le_stretch_reset(le_stretch* s) LE_STRETCH_NOEXCEPT;

int32_t le_stretch_channels(const le_stretch* s) LE_STRETCH_NOEXCEPT;
int32_t le_stretch_block_samples(const le_stretch* s) LE_STRETCH_NOEXCEPT;
int32_t le_stretch_interval_samples(const le_stretch* s) LE_STRETCH_NOEXCEPT;
int32_t le_stretch_input_latency(const le_stretch* s) LE_STRETCH_NOEXCEPT;
int32_t le_stretch_output_latency(const le_stretch* s) LE_STRETCH_NOEXCEPT;

/* Pitch shift in semitones; `tonality_limit` in cycles per sample (0 = none;
 * the upstream README recommends 8000 / sample_rate to keep more timbre). */
void le_stretch_set_semitones(le_stretch* s, float semitones,
                              float tonality_limit) LE_STRETCH_NOEXCEPT;

/* Streaming: consumes n_in input frames and produces n_out output frames; the
 * time ratio is n_out / n_in over time (the library has no ratio parameter). */
void le_stretch_process(le_stretch* s, const float* const* in, int32_t n_in,
                        float* const* out, int32_t n_out) LE_STRETCH_NOEXCEPT;
/* Pre-roll: provides previous input without producing output. `rate` is input
 * frames per output frame (1 / ratio). Ideally block + interval frames. */
void le_stretch_seek(le_stretch* s, const float* const* in, int32_t n_in,
                     double rate) LE_STRETCH_NOEXCEPT;
/* Reads the remaining output after the last input; ideally output_latency frames. */
void le_stretch_flush(le_stretch* s, float* const* out,
                      int32_t n_out) LE_STRETCH_NOEXCEPT;

/* Offline exact-length render: `in_frames` frames become exactly `out_frames`
 * frames at time ratio `ratio` (= out / in nominally; the caller chooses
 * out_frames, which is what makes a rendered lap tile the clock exactly) with
 * `semitones` of pitch shift. `cyclic != 0` treats the input as one lap of a
 * loop: the pre-roll and the run-out are the lap's own tail and head, so the
 * output loops as seamlessly as a seam-folded take; 0 pads with silence (a
 * one-shot file). Control thread; allocates the stretcher (about 1.1 MiB for
 * mono at 96 kHz) plus block + interval frames of scratch per channel,
 * streaming from in[] and into out[] (no copy of the lap); deterministic for a
 * given seed, preset, sample rate and input. LE_STRETCH_ERR_INVALID on bad
 * arguments or an out_frames the ratio cannot fill, LE_STRETCH_ERR_ALLOC on
 * allocation failure. */
int32_t le_stretch_render_offline(const float* const* in, int32_t in_frames,
                                  int32_t channels, int32_t sample_rate,
                                  double ratio, float semitones,
                                  float tonality_limit, int32_t cheaper,
                                  uint32_t seed, int32_t cyclic,
                                  float* const* out,
                                  int32_t out_frames) LE_STRETCH_NOEXCEPT;

/* A pitch-shifted, time-stretched LOOP of one mono lap (Transpose, #1179
 * Part 3a; the stretch, Part 4a-ii): the `frames`-frame lap rendered
 * cyclically to `out_frames` frames (ratio out_frames / frames, 1 for a
 * plain Transpose) plus `fold` more, which continue past the lap's end into
 * its head again; those are then folded over the head (a crossfade that
 * holds the level of the two correlated renders), so out[out_frames - 1] ->
 * out[0] continues the stretcher's own output and the loop point is
 * seamless (a pitch shift's phase does not come back round exactly, so the
 * plain cyclic render alone steps at the wrap). `fold` is clamped to what
 * the run-out holds and to half the lap. Deterministic for a given seed,
 * preset, sample rate and input: the cache worker and the offline renderer
 * both call this one function. */
int32_t le_stretch_render_loop(const float* in, int32_t frames,
                               int32_t out_frames,
                               int32_t sample_rate, float semitones,
                               float tonality_limit, int32_t cheaper,
                               uint32_t seed, int32_t fold,
                               float* out) LE_STRETCH_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#endif /* LE_STRETCH_H */
