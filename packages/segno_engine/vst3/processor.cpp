#include "processor.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

#include "params.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace segno_vst3 {

namespace {

/* One parameter change inside a block. */
struct ParamEvent {
  int32 offset;
  ParamID id;
  double value;
};
constexpr int kMaxEvents = 512;

}  // namespace

Processor::Processor(const FxKind* kind) : kind_(kind) {
  const uint32_t* c = kind->controller;
  setControllerClass(FUID(c[0], c[1], c[2], c[3]));
  width_ = segno_fx_width(kind->type);
  state_.kind = kind->type;
  state_.paramCount = width_;
  float defaults[kStateMaxParams];
  segno_fx_defaults(kind->type, defaults);
  for (int32_t p = 0; p < width_; ++p) state_.params[p] = defaults[p];
  nextClock_ = state_.clockOffset;
}

Processor::~Processor() { freeSlot(); }

FUnknown* Processor::createInstance(void* context) {
  return static_cast<IAudioProcessor*>(
      new Processor(static_cast<const FxKind*>(context)));
}

tresult PLUGIN_API Processor::initialize(FUnknown* context) {
  const tresult result = AudioEffect::initialize(context);
  if (result != kResultOk) return result;
  addAudioInput(STR16("Stereo In"), SpeakerArr::kStereo);
  addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
  return kResultOk;
}

tresult PLUGIN_API Processor::terminate() {
  freeSlot();
  return AudioEffect::terminate();
}

tresult PLUGIN_API Processor::setBusArrangements(SpeakerArrangement* inputs,
                                                 int32 numIns,
                                                 SpeakerArrangement* outputs,
                                                 int32 numOuts) {
  if (numIns != 1 || numOuts != 1 || inputs[0] != outputs[0]) return kResultFalse;
  if (inputs[0] != SpeakerArr::kStereo && inputs[0] != SpeakerArr::kMono) {
    return kResultFalse;
  }
  return AudioEffect::setBusArrangements(inputs, numIns, outputs, numOuts);
}

tresult PLUGIN_API Processor::canProcessSampleSize(int32 symbolicSampleSize) {
  return symbolicSampleSize == kSample32 ? kResultTrue : kResultFalse;
}

tresult PLUGIN_API Processor::setupProcessing(ProcessSetup& setup) {
  const tresult result = AudioEffect::setupProcessing(setup);
  if (result != kResultOk) return result;
  sr_ = (int32_t)std::lround(setup.sampleRate);
  if (sr_ <= 0) sr_ = 48000;
  latency_ = segno_fx_latency(kind_->type, sr_);
  return kResultOk;
}

void Processor::freeSlot() {
  segno_fx_slot_free(slot_);
  slot_ = nullptr;
}

void Processor::applyChannels() {
  segno_fx_slot_set_channels(slot_, state_.input, state_.output, state_.placement,
                             state_.level);
}

bool Processor::build() {
  freeSlot();
  segno_fx_slot_config c{};
  c.type = kind_->type;
  c.slot = state_.slot;
  c.sr = sr_;
  c.hop_seed = state_.hopSeed;
  c.clock = nextClock_;
  c.beat = state_.beatOffset;
  c.qpf = qpf_;
  c.num = num_;
  c.den = den_;
  c.input = state_.input;
  c.output = state_.output;
  c.placement = state_.placement;
  c.level = state_.level;
  /* A kind that delays its output switches in the plugin (process()), so
   * its slot always runs. */
  c.enabled = latency_ > 0 ? 1 : state_.enabled;
  c.params = state_.params;
  c.count = width_;
  slot_ = segno_fx_slot_new(&c);
  bypassMix_ = latency_ > 0 && state_.enabled == 0 ? 1.0f : 0.0f;
  for (auto& line : dryLine_) line.assign((size_t)(latency_ > 0 ? latency_ : 1), 0.0f);
  dryPos_ = 0;
  return slot_ != nullptr;
}

tresult PLUGIN_API Processor::setActive(TBool state) {
  if (state) {
    {
      std::lock_guard<std::mutex> lock(pendingLock_);
      if (hasPending_) {
        state_ = pending_;
        hasPending_ = false;
      }
    }
    nextClock_ = state_.clockOffset;
    wasPlaying_ = false;
    qpf_ = (float)(120.0 / 60.0 / sr_);
    num_ = 4;
    den_ = 4;
    if (!build()) return kResultFalse;
  } else {
    freeSlot();
  }
  return AudioEffect::setActive(state);
}

uint32 PLUGIN_API Processor::getLatencySamples() {
  /* The same whether the entry is on or bypassed: bypassed, a kind that
   * delays its output passes its input delayed as much (process()). */
  return (uint32)latency_;
}

uint32 PLUGIN_API Processor::getTailSamples() {
  /* A delay or a reverb rings on after its input stops; the rest end with
   * their latency. */
  if (segno_fx_drains(kind_->type)) {
    return kInfiniteTail;
  }
  return getLatencySamples();
}

void Processor::applyParam(ParamID id, double value) {
  switch (id) {
    case kInputId:
      state_.input = inputFromNormalized(value);
      applyChannels();
      return;
    case kOutputId:
      state_.output = outputFromNormalized(value);
      applyChannels();
      return;
    case kPlacementId:
      state_.placement = placementFromNormalized(value);
      applyChannels();
      return;
    case kLevelId:
      state_.level = levelFromNormalized(value);
      applyChannels();
      return;
    case kBypassId:
      state_.enabled = value < 0.5 ? 1 : 0;
      if (latency_ == 0) segno_fx_slot_set_enabled(slot_, state_.enabled);
      return;
    default:
      if (id < (ParamID)width_) {
        state_.params[id] = (float)value;
        segno_fx_slot_set_param(slot_, (int32_t)id, (float)value);
      }
      return;
  }
}

void Processor::followHost(const ProcessContext* ctx, uint32_t base, bool moved) {
  float qpf = qpf_;
  int32_t num = num_;
  int32_t den = den_;
  if (ctx != nullptr && (ctx->state & ProcessContext::kTempoValid) && ctx->tempo > 0) {
    qpf = (float)(ctx->tempo / 60.0 / sr_);
  }
  if (ctx != nullptr && (ctx->state & ProcessContext::kTimeSigValid)) {
    num = ctx->timeSigNumerator;
    den = ctx->timeSigDenominator;
  }
  const double expected = segno_fx_slot_beat_at(slot_, base);
  const bool playing = ctx != nullptr && (ctx->state & ProcessContext::kPlaying);
  const bool changed = qpf != qpf_ || num != num_ || den != den_;
  if (playing && (ctx->state & ProcessContext::kProjectTimeMusicValid)) {
    /* Re-anchored where the host moves, changes tempo or leaves our beat
     * by more than a hundredth of a beat, so a steady transport keeps one
     * anchor, as a capture's render does. */
    const double beat = ctx->projectTimeMusic + state_.beatOffset;
    if (moved || changed || std::fabs(expected - beat) > 0.01) {
      segno_fx_slot_set_tempo(slot_, base, beat, qpf, num, den);
    }
  } else if (changed) {
    segno_fx_slot_set_tempo(slot_, base, expected, qpf, num, den);
  }
  qpf_ = qpf;
  num_ = num;
  den_ = den;
}

tresult PLUGIN_API Processor::process(ProcessData& data) {
  if (slot_ == nullptr) return kResultOk;
  if (pendingLock_.try_lock()) {
    if (hasPending_) {
      const bool rebuilt = pending_.slot != state_.slot;
      const bool moved = pending_.hopSeed != state_.hopSeed ||
                         pending_.clockOffset != state_.clockOffset ||
                         pending_.beatOffset != state_.beatOffset;
      state_ = pending_;
      hasPending_ = false;
      if (rebuilt) {
        /* Another chain slot is another slot: made afresh, which allocates.
         * A host hands a state over before it activates the plugin, so
         * this is a preset loaded while it plays. */
        build();
      } else {
        segno_fx_slot_set_enabled(slot_, state_.enabled);
        for (int32_t p = 0; p < width_; ++p) {
          segno_fx_slot_set_param(slot_, p, state_.params[p]);
        }
        applyChannels();
        if (moved) segno_fx_slot_reseed(slot_, state_.hopSeed);
      }
    }
    pendingLock_.unlock();
  }
  if (slot_ == nullptr) return kResultOk;

  const uint64_t fpMode = segno_fx_flush_denormals();
  const int32 n = data.numSamples;
  const ProcessContext* ctx = data.processContext;
  const bool playing = ctx != nullptr && (ctx->state & ProcessContext::kPlaying);
  const uint32_t base =
      playing ? state_.clockOffset + (uint32_t)(int64_t)ctx->projectTimeSamples
              : nextClock_;
  followHost(ctx, base, base != nextClock_ || playing != wasPlaying_);
  wasPlaying_ = playing;

  ParamEvent events[kMaxEvents];
  int count = 0;
  if (IParameterChanges* changes = data.inputParameterChanges) {
    const int32 queues = changes->getParameterCount();
    for (int32 q = 0; q < queues; ++q) {
      IParamValueQueue* queue = changes->getParameterData(q);
      if (queue == nullptr) continue;
      const int32 points = queue->getPointCount();
      for (int32 k = 0; k < points && count < kMaxEvents; ++k) {
        int32 offset = 0;
        ParamValue value = 0;
        if (queue->getPoint(k, offset, value) != kResultTrue) continue;
        int i = count++;
        /* Kept in frame order, each queue's own order kept. */
        while (i > 0 && events[i - 1].offset > offset) {
          events[i] = events[i - 1];
          --i;
        }
        events[i] = {offset, queue->getParameterId(), value};
      }
    }
  }

  int next = 0;
  float* inL = nullptr;
  float* inR = nullptr;
  float* outL = nullptr;
  float* outR = nullptr;
  if (n > 0 && data.numInputs > 0 && data.numOutputs > 0 &&
      data.inputs[0].numChannels > 0 && data.outputs[0].numChannels > 0) {
    AudioBusBuffers& in = data.inputs[0];
    AudioBusBuffers& out = data.outputs[0];
    inL = in.channelBuffers32[0];
    inR = in.numChannels > 1 ? in.channelBuffers32[1] : inL;
    outL = out.channelBuffers32[0];
    outR = out.numChannels > 1 ? out.channelBuffers32[1] : nullptr;
  }
  for (int32 i = 0; i < n; ++i) {
    while (next < count && events[next].offset <= i) {
      applyParam(events[next].id, events[next].value);
      ++next;
    }
    if (outL == nullptr) continue;
    float l = inL[i];
    float r = inR[i];
    if (latency_ > 0) {
      /* A kind that delays its output: its slot always runs, and its
       * bypass crossfades, over the engine's ramp, to the input delayed as
       * much, so the host's delay compensation holds either way. */
      float& dl = dryLine_[0][(size_t)dryPos_];
      float& dr = dryLine_[1][(size_t)dryPos_];
      const float delayedL = dl;
      const float delayedR = dr;
      dl = l;
      dr = r;
      if (++dryPos_ == latency_) dryPos_ = 0;
      segno_fx_slot_frame(slot_, base + (uint32_t)i, &l, &r);
      const float target = state_.enabled ? 0.0f : 1.0f;
      if (bypassMix_ != target) {
        const float step = 1000.0f / (5.0f * (float)sr_); /* LE_FX_ENABLE_RAMP_MS */
        bypassMix_ = target > bypassMix_ ? std::fmin(target, bypassMix_ + step)
                                         : std::fmax(target, bypassMix_ - step);
      }
      if (bypassMix_ >= 1.0f) {
        l = delayedL;
        r = delayedR;
      } else if (bypassMix_ > 0.0f) {
        l += (delayedL - l) * bypassMix_;
        r += (delayedR - r) * bypassMix_;
      }
    } else {
      segno_fx_slot_frame(slot_, base + (uint32_t)i, &l, &r);
    }
    if (outR != nullptr) {
      outL[i] = l;
      outR[i] = r;
    } else {
      /* A mono bus takes the pair's fold-down, as a stem does. */
      outL[i] = 0.5f * (l + r);
    }
  }
  while (next < count) {
    applyParam(events[next].id, events[next].value);
    ++next;
  }
  if (outL != nullptr) {
    data.outputs[0].silenceFlags = 0;
  }
  nextClock_ = base + (uint32_t)(n > 0 ? n : 0);
  segno_fx_restore_fp_mode(fpMode);
  return kResultOk;
}

tresult PLUGIN_API Processor::setState(IBStream* stream) {
  if (stream == nullptr) return kInvalidArgument;
  FxPluginState s;
  segno_fx_defaults(kind_->type, s.params);
  const auto read = [stream](uint8_t* into, int32 size) {
    int32 got = 0;
    return stream->read(into, size, &got) == kResultOk ? got : -1;
  };
  if (!readState(read, s) || s.kind != kind_->type) return kResultFalse;
  s.paramCount = width_;
  std::lock_guard<std::mutex> lock(pendingLock_);
  if (slot_ == nullptr) {
    state_ = s;
  } else {
    pending_ = s;
    hasPending_ = true;
  }
  return kResultOk;
}

tresult PLUGIN_API Processor::getState(IBStream* stream) {
  if (stream == nullptr) return kInvalidArgument;
  FxPluginState s;
  {
    std::lock_guard<std::mutex> lock(pendingLock_);
    s = hasPending_ ? pending_ : state_;
  }
  uint8_t bytes[kStateHeaderBytes + 4 * kStateMaxParams];
  const int32 n = encodeState(s, bytes);
  int32 written = 0;
  if (stream->write(bytes, n, &written) != kResultOk || written != n) {
    return kResultFalse;
  }
  return kResultOk;
}

}  // namespace segno_vst3
