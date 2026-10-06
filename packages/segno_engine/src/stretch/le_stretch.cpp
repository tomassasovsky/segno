/*
 * le_stretch.cpp — the one C++ translation unit that includes Signalsmith
 * Stretch (see le_stretch.h). Vendored at
 * packages/segno_engine/third_party/signalsmith-stretch (tag 1.1.0, MIT); the
 * relative include keeps every build (CMake, CocoaPods forwarder, SPM
 * forwarder, run_native_tests.sh, the bench) free of a new include path.
 *
 * Exception safety: every exported function is noexcept, and every one that
 * reaches the library or allocates catches everything inside, so a
 * std::bad_alloc or std::length_error becomes NULL / LE_STRETCH_ERR_ALLOC
 * instead of unwinding into C frames (which ends in std::terminate). The
 * getters only read geometry stored at configure time and cannot throw.
 */
#include "le_stretch.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <new>
#include <vector>

#include "../../third_party/signalsmith-stretch/signalsmith-stretch.h"

struct le_stretch {
  signalsmith::stretch::SignalsmithStretch<float> st;
  int32_t channels;
  int32_t sample_rate;
  int32_t cheaper;
  explicit le_stretch(uint32_t seed) : st((long)seed), channels(0),
                                       sample_rate(0), cheaper(0) {}
};

namespace {

/* Frames fed to the stretcher per process() call by the offline render; the
 * output side of a call is at most this many frames plus two (rounding). */
constexpr int32_t kRenderChunk = 512;

le_stretch* create_or_throw(int32_t channels, int32_t sample_rate,
                            int32_t cheaper, uint32_t seed) {
  std::unique_ptr<le_stretch> s(new le_stretch(seed));
  s->channels = channels;
  s->sample_rate = sample_rate;
  s->cheaper = cheaper;
  if (cheaper) {
    s->st.presetCheaper(channels, (float)sample_rate);
  } else {
    s->st.presetDefault(channels, (float)sample_rate);
  }
  return s.release();
}

/* The offline render (see le_stretch.h). Arguments are already validated.
 * Throws only what allocation throws; the exported wrapper catches.
 *
 * The stretcher sees a virtual input of W + in_frames + W frames, W = block +
 * interval: W frames of pre-roll (the lap's tail when cyclic, silence
 * otherwise), the lap, then W frames of run-out (the lap's head when cyclic,
 * silence otherwise). It is never materialised: the lap is fed straight from
 * in[], and only chunks that touch the pre-roll or the run-out are assembled
 * in a W-frame scratch. On the output side, the first `discard` frames and
 * anything past out_frames go to a small sink; every chunk wholly inside the
 * requested window is written straight into out[].
 *
 * Alignment (library README, "Seeking and starting"): after a seek of W
 * frames the processing time sits input_latency frames before in[0], so the
 * output that precedes in[0]'s content is output_latency + input_latency *
 * ratio frames: `discard`. The run-out carries the processing time past the
 * end of the lap before the flush drains output_latency frames of tail. */
int32_t render_offline(const float* const* in, int32_t in_frames,
                       int32_t channels, int32_t sample_rate, double ratio,
                       float semitones, float tonality_limit, int32_t cheaper,
                       uint32_t seed, int32_t cyclic, float* const* out,
                       int32_t out_frames) {
  std::unique_ptr<le_stretch> s(
      create_or_throw(channels, sample_rate, cheaper, seed));
  s->st.setTransposeSemitones(semitones, tonality_limit);

  const int32_t W = s->st.blockSamples() + s->st.intervalSamples();
  const int32_t in_lat = s->st.inputLatency();
  const int32_t out_lat = s->st.outputLatency();
  const int64_t in_end = (int64_t)in_frames + W; /* lap + run-out */
  const int64_t out_target = std::llround((double)in_end * ratio);
  const int64_t total_out = out_target + out_lat;
  const int64_t discard =
      out_lat + (int64_t)std::llround((double)in_lat * ratio);
  if (discard + out_frames > total_out) {
    return LE_STRETCH_ERR_INVALID; /* out_frames inconsistent with ratio */
  }

  /* At most kRenderChunk input frames per call, and few enough that the
   * output side stays near kRenderChunk too when ratio > 1. */
  const int32_t step_in = std::max<int32_t>(
      1, (int32_t)std::min<double>(kRenderChunk, kRenderChunk / ratio));
  const int32_t out_step_max =
      (int32_t)std::ceil((double)step_in * ratio) + 2;
  const size_t in_scratch = (size_t)std::max(W, step_in);
  const size_t out_scratch = (size_t)std::max(out_lat, out_step_max);

  std::vector<float> in_buf((size_t)channels * in_scratch);
  std::vector<float> out_buf((size_t)channels * out_scratch);
  std::vector<const float*> in_ptr((size_t)channels);
  std::vector<float*> out_ptr((size_t)channels);

  /* Virtual input frame k in [-W, in_end): the lap, wrapped when cyclic. */
  const auto sample_at = [&](int32_t c, int64_t k) -> float {
    if (k >= 0 && k < in_frames) return in[c][k];
    if (!cyclic) return 0.0f;
    int64_t m = k % in_frames;
    if (m < 0) m += in_frames;
    return in[c][m];
  };
  /* Points in_ptr at n virtual frames from k: in[] itself when they lie in
   * the lap, otherwise a copy in the scratch. */
  const auto point_input = [&](int64_t k, int32_t n) {
    const bool in_lap = k >= 0 && k + n <= in_frames;
    for (int32_t c = 0; c < channels; ++c) {
      if (in_lap) {
        in_ptr[(size_t)c] = in[c] + k;
        continue;
      }
      float* dst = in_buf.data() + (size_t)c * in_scratch;
      for (int32_t i = 0; i < n; ++i) dst[i] = sample_at(c, k + i);
      in_ptr[(size_t)c] = dst;
    }
  };
  /* Copies the part of a scratch output chunk at stream frame `at` that
   * falls inside [discard, discard + out_frames) into out[]. */
  const auto keep_output = [&](int64_t at, int32_t n) {
    const int64_t from = std::max<int64_t>(at, discard);
    const int64_t to = std::min<int64_t>(at + n, discard + out_frames);
    if (from >= to) return;
    for (int32_t c = 0; c < channels; ++c) {
      const float* src = out_buf.data() + (size_t)c * out_scratch + (from - at);
      std::copy(src, src + (to - from), out[c] + (from - discard));
    }
  };

  point_input(-W, W);
  s->st.seek(in_ptr.data(), (int)W, 1.0 / ratio);

  int64_t q = 0;        /* next virtual input frame */
  int64_t produced = 0; /* output frames so far */
  while (q < in_end) {
    const int32_t n_in = (int32_t)std::min<int64_t>(step_in, in_end - q);
    const int64_t target = std::llround((double)(q + n_in) * ratio);
    const int32_t n_out = (int32_t)(target - produced);
    point_input(q, n_in);
    const bool direct =
        produced >= discard && produced + n_out <= discard + out_frames;
    for (int32_t c = 0; c < channels; ++c) {
      out_ptr[(size_t)c] = direct ? out[c] + (produced - discard)
                                  : out_buf.data() + (size_t)c * out_scratch;
    }
    s->st.process(in_ptr.data(), (int)n_in, out_ptr.data(), (int)n_out);
    if (!direct) keep_output(produced, n_out);
    q += n_in;
    produced = target;
  }
  for (int32_t c = 0; c < channels; ++c) {
    out_ptr[(size_t)c] = out_buf.data() + (size_t)c * out_scratch;
  }
  s->st.flush(out_ptr.data(), (int)out_lat);
  keep_output(produced, out_lat);
  return LE_STRETCH_OK;
}

}  // namespace

extern "C" {

le_stretch* le_stretch_create(int32_t channels, int32_t sample_rate,
                              int32_t cheaper, uint32_t seed) noexcept {
  if (channels <= 0 || channels > LE_STRETCH_MAX_CHANNELS) return nullptr;
  if (sample_rate <= 0 || sample_rate > LE_STRETCH_MAX_SAMPLE_RATE) {
    return nullptr;
  }
  try {
    return create_or_throw(channels, sample_rate, cheaper, seed);
  } catch (...) {
    return nullptr;
  }
}

void le_stretch_destroy(le_stretch* s) noexcept { delete s; }

void le_stretch_reset(le_stretch* s) noexcept {
  if (s == nullptr) return;
  try {
    s->st.reset();
  } catch (...) {
  }
}

int32_t le_stretch_channels(const le_stretch* s) noexcept {
  return s != nullptr ? s->channels : 0;
}
int32_t le_stretch_block_samples(const le_stretch* s) noexcept {
  return s != nullptr ? s->st.blockSamples() : 0;
}
int32_t le_stretch_interval_samples(const le_stretch* s) noexcept {
  return s != nullptr ? s->st.intervalSamples() : 0;
}
int32_t le_stretch_input_latency(const le_stretch* s) noexcept {
  return s != nullptr ? s->st.inputLatency() : 0;
}
int32_t le_stretch_output_latency(const le_stretch* s) noexcept {
  return s != nullptr ? s->st.outputLatency() : 0;
}

void le_stretch_set_semitones(le_stretch* s, float semitones,
                              float tonality_limit) noexcept {
  if (s == nullptr) return;
  try {
    s->st.setTransposeSemitones(semitones, tonality_limit);
  } catch (...) {
  }
}

void le_stretch_process(le_stretch* s, const float* const* in, int32_t n_in,
                        float* const* out, int32_t n_out) noexcept {
  if (s == nullptr || in == nullptr || out == nullptr) return;
  if (n_in < 0 || n_out < 0) return;
  try {
    s->st.process(in, (int)n_in, out, (int)n_out);
  } catch (...) {
  }
}

void le_stretch_seek(le_stretch* s, const float* const* in, int32_t n_in,
                     double rate) noexcept {
  if (s == nullptr || in == nullptr || n_in <= 0) return;
  try {
    s->st.seek(in, (int)n_in, rate);
  } catch (...) {
  }
}

void le_stretch_flush(le_stretch* s, float* const* out,
                      int32_t n_out) noexcept {
  if (s == nullptr || out == nullptr || n_out <= 0) return;
  try {
    s->st.flush(out, (int)n_out);
  } catch (...) {
  }
}

int32_t le_stretch_render_offline(const float* const* in, int32_t in_frames,
                                  int32_t channels, int32_t sample_rate,
                                  double ratio, float semitones,
                                  float tonality_limit, int32_t cheaper,
                                  uint32_t seed, int32_t cyclic,
                                  float* const* out,
                                  int32_t out_frames) noexcept {
  if (in == nullptr || out == nullptr) return LE_STRETCH_ERR_INVALID;
  if (in_frames <= 0 || out_frames <= 0) return LE_STRETCH_ERR_INVALID;
  if (channels <= 0 || channels > LE_STRETCH_MAX_CHANNELS) {
    return LE_STRETCH_ERR_INVALID;
  }
  if (sample_rate <= 0 || sample_rate > LE_STRETCH_MAX_SAMPLE_RATE) {
    return LE_STRETCH_ERR_INVALID;
  }
  if (!(ratio >= 1.0 / LE_STRETCH_MAX_RATIO && ratio <= LE_STRETCH_MAX_RATIO) ||
      !std::isfinite(semitones)) {
    return LE_STRETCH_ERR_INVALID;
  }
  for (int32_t c = 0; c < channels; ++c) {
    if (in[c] == nullptr || out[c] == nullptr) return LE_STRETCH_ERR_INVALID;
  }
  try {
    return render_offline(in, in_frames, channels, sample_rate, ratio,
                          semitones, tonality_limit, cheaper, seed, cyclic,
                          out, out_frames);
  } catch (...) {
    return LE_STRETCH_ERR_ALLOC;
  }
}

int32_t le_stretch_render_loop(const float* in, int32_t frames,
                               int32_t sample_rate, float semitones,
                               float tonality_limit, int32_t cheaper,
                               uint32_t seed, int32_t fold,
                               float* out) noexcept {
  if (in == nullptr || out == nullptr || frames <= 1 || fold < 0) {
    return LE_STRETCH_ERR_INVALID;
  }
  if (sample_rate <= 0 || sample_rate > LE_STRETCH_MAX_SAMPLE_RATE) {
    return LE_STRETCH_ERR_INVALID;
  }
  try {
    /* What the run-out can carry past the lap at ratio 1: W - in_lat. */
    std::unique_ptr<le_stretch> probe(
        create_or_throw(1, sample_rate, cheaper, seed));
    const int32_t room = probe->st.blockSamples() + probe->st.intervalSamples() -
                         probe->st.inputLatency();
    probe.reset();
    fold = std::min(fold, std::min(room, frames / 2));
    std::vector<float> tmp((size_t)frames + (size_t)fold);
    const float* ins[1] = {in};
    float* outs[1] = {tmp.data()};
    const int32_t rc = le_stretch_render_offline(
        ins, frames, 1, sample_rate, 1.0, semitones, tonality_limit, cheaper,
        seed, 1, outs, frames + fold);
    if (rc != LE_STRETCH_OK) return rc;
    std::copy(tmp.begin(), tmp.begin() + frames, out);
    for (int32_t k = 0; k < fold; ++k) {
      const double x = (double)k / (double)fold * 1.5707963267948966;
      out[k] = (float)(tmp[(size_t)k] * std::sin(x) +
                       tmp[(size_t)frames + (size_t)k] * std::cos(x));
    }
    return LE_STRETCH_OK;
  } catch (...) {
    return LE_STRETCH_ERR_ALLOC;
  }
}

} /* extern "C" */
