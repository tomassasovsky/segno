/*
 * le_stretch.cpp — the one C++ translation unit that includes Signalsmith
 * Stretch (see le_stretch.h). Vendored at
 * packages/segno_engine/third_party/signalsmith-stretch (tag 1.1.0, MIT); the
 * relative include keeps every build (CMake, CocoaPods forwarder, SPM
 * forwarder, run_native_tests.sh, the bench) free of a new include path.
 */
#include "le_stretch.h"

#include <algorithm>
#include <cmath>
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

extern "C" {

le_stretch* le_stretch_create(int32_t channels, int32_t sample_rate,
                              int32_t cheaper, uint32_t seed) {
  if (channels <= 0 || sample_rate <= 0) return nullptr;
  le_stretch* s = new (std::nothrow) le_stretch(seed);
  if (s == nullptr) return nullptr;
  s->channels = channels;
  s->sample_rate = sample_rate;
  s->cheaper = cheaper;
  if (cheaper) {
    s->st.presetCheaper(channels, (float)sample_rate);
  } else {
    s->st.presetDefault(channels, (float)sample_rate);
  }
  return s;
}

void le_stretch_destroy(le_stretch* s) { delete s; }

void le_stretch_reset(le_stretch* s) {
  if (s != nullptr) s->st.reset();
}

int32_t le_stretch_channels(const le_stretch* s) {
  return s != nullptr ? s->channels : 0;
}
int32_t le_stretch_block_samples(const le_stretch* s) {
  return s != nullptr ? s->st.blockSamples() : 0;
}
int32_t le_stretch_interval_samples(const le_stretch* s) {
  return s != nullptr ? s->st.intervalSamples() : 0;
}
int32_t le_stretch_input_latency(const le_stretch* s) {
  return s != nullptr ? s->st.inputLatency() : 0;
}
int32_t le_stretch_output_latency(const le_stretch* s) {
  return s != nullptr ? s->st.outputLatency() : 0;
}

void le_stretch_set_semitones(le_stretch* s, float semitones,
                              float tonality_limit) {
  if (s != nullptr) s->st.setTransposeSemitones(semitones, tonality_limit);
}

void le_stretch_process(le_stretch* s, const float* const* in, int32_t n_in,
                        float* const* out, int32_t n_out) {
  if (s == nullptr || in == nullptr || out == nullptr) return;
  if (n_in < 0 || n_out < 0) return;
  s->st.process(in, (int)n_in, out, (int)n_out);
}

void le_stretch_seek(le_stretch* s, const float* const* in, int32_t n_in,
                     double rate) {
  if (s == nullptr || in == nullptr || n_in <= 0) return;
  s->st.seek(in, (int)n_in, rate);
}

void le_stretch_flush(le_stretch* s, float* const* out, int32_t n_out) {
  if (s == nullptr || out == nullptr || n_out <= 0) return;
  s->st.flush(out, (int)n_out);
}

int32_t le_stretch_render_offline(const float* const* in, int32_t in_frames,
                                  int32_t channels, int32_t sample_rate,
                                  double ratio, float semitones,
                                  float tonality_limit, int32_t cheaper,
                                  uint32_t seed, int32_t cyclic,
                                  float* const* out, int32_t out_frames) {
  if (in == nullptr || out == nullptr) return LE_STRETCH_ERR_INVALID;
  if (in_frames <= 0 || out_frames <= 0 || channels <= 0 || sample_rate <= 0) {
    return LE_STRETCH_ERR_INVALID;
  }
  if (!(ratio > 0.0) || !std::isfinite(ratio) || !std::isfinite(semitones)) {
    return LE_STRETCH_ERR_INVALID;
  }
  for (int32_t c = 0; c < channels; ++c) {
    if (in[c] == nullptr || out[c] == nullptr) return LE_STRETCH_ERR_INVALID;
  }
  le_stretch* s = le_stretch_create(channels, sample_rate, cheaper, seed);
  if (s == nullptr) return LE_STRETCH_ERR_ALLOC;
  s->st.setTransposeSemitones(semitones, tonality_limit);

  /* The processing time starts input_latency frames before the first frame we
   * feed (library README, "Seeking and starting"). We seek with W = block +
   * interval frames of pre-roll (the lap's own tail when cyclic, silence
   * otherwise), which leaves the processing time input_latency frames before
   * in[0]; the output that precedes in[0]'s content is therefore
   * output_latency + input_latency * ratio frames, discarded below. The run-out
   * after the last input frame is another W frames (the lap's head when
   * cyclic), so the processing time passes the end of the input before the
   * flush, and the flush drains output_latency frames of tail. */
  const int32_t W = s->st.blockSamples() + s->st.intervalSamples();
  const int32_t in_lat = s->st.inputLatency();
  const int32_t out_lat = s->st.outputLatency();
  const int32_t padded = in_frames + 2 * W;
  const int64_t total_out =
      (int64_t)std::llround((double)(in_frames + W) * ratio) + out_lat;
  const int64_t discard = out_lat + (int64_t)std::llround((double)in_lat * ratio);
  if (discard + out_frames > total_out) {
    le_stretch_destroy(s);
    return LE_STRETCH_ERR_INVALID; /* out_frames inconsistent with ratio */
  }

  std::vector<std::vector<float>> pad((size_t)channels);
  std::vector<std::vector<float>> acc((size_t)channels);
  std::vector<const float*> pad_ptr((size_t)channels);
  std::vector<float*> acc_ptr((size_t)channels);
  try {
    for (int32_t c = 0; c < channels; ++c) {
      pad[(size_t)c].assign((size_t)padded, 0.0f);
      acc[(size_t)c].assign((size_t)total_out + 1024, 0.0f);
      float* p = pad[(size_t)c].data();
      const float* src = in[c];
      for (int32_t k = 0; k < W; ++k) {
        if (cyclic) {
          /* the lap's tail (wrapping if the lap is shorter than W) */
          int64_t idx = (int64_t)in_frames - W + k;
          idx %= in_frames;
          if (idx < 0) idx += in_frames;
          p[k] = src[idx];
          p[W + in_frames + k] = src[k % in_frames];
        }
      }
      std::copy(src, src + in_frames, p + W);
    }
  } catch (...) {
    le_stretch_destroy(s);
    return LE_STRETCH_ERR_ALLOC;
  }

  for (int32_t c = 0; c < channels; ++c) pad_ptr[(size_t)c] = pad[(size_t)c].data();
  s->st.seek(pad_ptr.data(), (int)W, 1.0 / ratio);

  int64_t in_pos = W;             /* next pad frame to feed */
  const int64_t in_end = padded;  /* in + run-out */
  int64_t produced = 0;
  const int64_t out_target = total_out - out_lat; /* before the flush */
  double carry = 0.0;
  const int32_t chunk = 512;
  while (produced < out_target) {
    int32_t n_out = (int32_t)std::min<int64_t>(chunk, out_target - produced);
    const double want = carry + (double)n_out / ratio;
    int32_t n_in = (int32_t)want;
    carry = want - (double)n_in;
    if (in_pos + n_in > in_end) n_in = (int32_t)(in_end - in_pos);
    if (n_in < 0) n_in = 0;
    for (int32_t c = 0; c < channels; ++c) {
      pad_ptr[(size_t)c] = pad[(size_t)c].data() + in_pos;
      acc_ptr[(size_t)c] = acc[(size_t)c].data() + produced;
    }
    s->st.process(pad_ptr.data(), (int)n_in, acc_ptr.data(), (int)n_out);
    in_pos += n_in;
    produced += n_out;
  }
  if (in_pos < in_end) {
    /* rounding leftover: feed it with no output requested */
    for (int32_t c = 0; c < channels; ++c) {
      pad_ptr[(size_t)c] = pad[(size_t)c].data() + in_pos;
      acc_ptr[(size_t)c] = acc[(size_t)c].data() + produced;
    }
    s->st.process(pad_ptr.data(), (int)(in_end - in_pos), acc_ptr.data(), 0);
    in_pos = in_end;
  }
  for (int32_t c = 0; c < channels; ++c) {
    acc_ptr[(size_t)c] = acc[(size_t)c].data() + produced;
  }
  s->st.flush(acc_ptr.data(), (int)out_lat);
  produced += out_lat;

  for (int32_t c = 0; c < channels; ++c) {
    const float* a = acc[(size_t)c].data() + discard;
    std::copy(a, a + out_frames, out[c]);
  }
  le_stretch_destroy(s);
  return LE_STRETCH_OK;
}

} /* extern "C" */
