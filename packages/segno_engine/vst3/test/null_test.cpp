/*
 * null_test.cpp — every Segno plugin against the engine's offline render
 * (#1804).
 *
 * For each kind and each case below it writes a one-track capture whose
 * lane 0 carries the kind as its only effect at arm, has the engine render
 * it (le_perf_render_begin, the render the console runs after a take: the
 * same code, built with the console's tanhf and powf), then plays the dry
 * stem that render wrote through the plugin, loaded from the built bundle
 * as a host loads it, with the state a Live export writes for that entry.
 * The plugin's output, folded to mono as a stem is, is compared with the
 * wet stem, sample for sample.
 *
 * Cases:
 *   default   the kind's defaults
 *   varied    other settings, a mono output, a balance and a level, on
 *             chain slot 5 behind five empty entries
 *   switched  the defaults; at 1.5 s the first setting moves to 0.8, at
 *             2.0 s the effect is switched off, at 3.0 s on again (the
 *             engine reads these from events.log, the plugin as parameter
 *             changes at those frames)
 *
 * The capture's PERF_ARMED clock and its tempo anchor at frame 0 are not
 * zero, so the clock offset and beat offset of the state are exercised.
 *
 * Usage: segno_vst3_null_test <Segno.vst3> [--kind TYPE] [--block N]
 *        [--keep DIR]
 * Prints one line per kind and case: the peak difference in dBFS ("exact"
 * when bit-identical). Exits non-zero when a difference passes -120 dBFS.
 */
#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../params.h"
#include "../segno_fx_kinds.h"
#include "../segno_fx_state.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"

#include "../fx_slot.h"
#include "capture_log.h"
#include "segno_engine_api.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

constexpr int32_t kRate = 48000;
constexpr int32_t kFrames = 6 * kRate;
constexpr uint32_t kArmClock = 1234567u;  /* the engine frame of capture frame 0 */
constexpr double kArmBeat = 37.25;        /* the beat there */
constexpr double kBpm = 120.0;
constexpr float kFail = 1e-6f;            /* -120 dBFS */

/* A take to play through: plucked notes from 82 to 660 Hz with their
 * harmonics, a noise burst, and silence at the end for the tails. */
std::vector<float> testSignal() {
  std::vector<float> x(kFrames, 0.0f);
  const double notes[] = {82.41, 110.0, 146.83, 196.0, 329.63, 659.26, 98.0, 220.0};
  uint32_t seed = 12345;
  for (int k = 0; k < 8; ++k) {
    const int start = k * kRate / 2;
    for (int i = 0; i < kRate; ++i) {
      const int f = start + i;
      if (f >= 4 * kRate) break;
      const double t = (double)i / kRate;
      const double env = std::exp(-3.0 * t) * (i < 48 ? i / 48.0 : 1.0);
      double s = 0;
      for (int h = 1; h <= 6; ++h) {
        s += std::sin(2 * M_PI * notes[k] * h * t) / (h * h);
      }
      x[f] += (float)(0.35 * env * s);
    }
  }
  for (int i = 0; i < kRate / 10; ++i) {
    seed = seed * 1664525u + 1013904223u;
    const float n = ((int32_t)seed / 2147483648.0f);
    x[(size_t)(4.2 * kRate) + i] += 0.2f * n * (1.0f - (float)i / (kRate / 10));
  }
  return x;
}

void writeWavMono(const std::string& path, const std::vector<float>& x) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (f == nullptr) {
    std::fprintf(stderr, "cannot write %s\n", path.c_str());
    std::exit(2);
  }
  const uint32_t data = (uint32_t)(x.size() * 4);
  const uint32_t riff = 36 + data;
  const uint16_t fmt = 3, ch = 1, align = 4, bits = 32;
  const uint32_t fmtLen = 16, rate = kRate, bytes = kRate * 4;
  std::fwrite("RIFF", 1, 4, f);
  std::fwrite(&riff, 4, 1, f);
  std::fwrite("WAVEfmt ", 1, 8, f);
  std::fwrite(&fmtLen, 4, 1, f);
  std::fwrite(&fmt, 2, 1, f);
  std::fwrite(&ch, 2, 1, f);
  std::fwrite(&rate, 4, 1, f);
  std::fwrite(&bytes, 4, 1, f);
  std::fwrite(&align, 2, 1, f);
  std::fwrite(&bits, 2, 1, f);
  std::fwrite("data", 1, 4, f);
  std::fwrite(&data, 4, 1, f);
  std::fwrite(x.data(), 4, x.size(), f);
  std::fclose(f);
}

/* A mono float WAV's samples, by its chunks. */
std::vector<float> readWavMono(const std::string& path) {
  std::vector<float> out;
  FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return out;
  char head[12];
  if (std::fread(head, 1, 12, f) != 12 || std::memcmp(head, "RIFF", 4) != 0) {
    std::fclose(f);
    return out;
  }
  char id[4];
  uint32_t len = 0;
  while (std::fread(id, 1, 4, f) == 4 && std::fread(&len, 4, 1, f) == 1) {
    if (std::memcmp(id, "data", 4) == 0) {
      out.resize(len / 4);
      out.resize(std::fread(out.data(), 4, out.size(), f));
      break;
    }
    std::fseek(f, (long)(len + (len & 1)), SEEK_CUR);
  }
  std::fclose(f);
  return out;
}

struct Case {
  const char* name;
  segno_vst3::FxPluginState state;
  const char* channelsJson; /* the manifest's "channels", or "" */
  bool switched;
};

std::string paramsJson(const segno_vst3::FxPluginState& s) {
  std::string out = "[";
  char num[32];
  for (int p = 0; p < s.paramCount; ++p) {
    std::snprintf(num, sizeof(num), "%s%.9g", p ? ", " : "", s.params[p]);
    out += num;
  }
  return out + "]";
}

constexpr int32_t kSwitchParamAt = 3 * kRate / 2;
constexpr int32_t kOffAt = 2 * kRate;
constexpr int32_t kOnAt = 3 * kRate;
constexpr float kSwitchParamTo = 0.8f;

/* The engine's wet stem of [c] over [dry] (written as the lane's loop), and
 * the dry stem the render made of it. Empty when the render fails. */
bool renderEngine(const std::string& dir, int32_t type, const Case& c,
                  const std::vector<float>& input, std::vector<float>& dryOut,
                  std::vector<float>& wetOut) {
  mkdir(dir.c_str(), 0755);
  mkdir((dir + "/loops").c_str(), 0755);
  writeWavMono(dir + "/loops/track0-lane0.wav", input);
  std::string empties;
  for (int i = 0; i < c.state.slot; ++i) empties += "{\"type\": 0, \"params\": []}, ";
  char manifest[8192];
  std::snprintf(
      manifest, sizeof(manifest),
      "{\"sample_rate\": %d, \"capture_frames\": %d, \"armSnapshot\": "
      "{\"followOutput\": false, \"captureMask\": 1, \"fxStagesVersion\": 1, "
      "\"tracks\": [{\"channel\": 0, \"lanes\": [{\"lane\": 0, \"deferred\": "
      "false, \"pcmRef\": \"loops/track0-lane0.wav\", \"effects\": [%s{\"type\": "
      "%d, \"params\": %s%s%s}]}]}]}, \"disarmSnapshot\": {\"tracks\": []}, "
      "\"layers\": []}",
      kRate, kFrames, empties.c_str(), type, paramsJson(c.state).c_str(),
      c.channelsJson[0] ? ", \"channels\": " : "", c.channelsJson);
  FILE* mf = std::fopen((dir + "/performance.json").c_str(), "wb");
  std::fputs(manifest, mf);
  std::fclose(mf);

  std::vector<capture_log_change> changes;
  if (c.switched) {
    if (c.state.paramCount > 0) changes.push_back({kSwitchParamAt, 0, kSwitchParamTo});
    changes.push_back({kOffAt, -1, 0.0f});
    changes.push_back({kOnAt, -1, 1.0f});
  }
  if (!capture_log_write((dir + "/events.log").c_str(), kRate, kArmClock, kArmBeat,
                         (float)(kBpm / 60.0 / kRate), changes.data(),
                         (int)changes.size())) {
    return false;
  }

  le_engine* e = le_engine_create();
  if (le_perf_render_begin(e, dir.c_str()) != LE_OK) {
    le_engine_destroy(e);
    return false;
  }
  int32_t done = 0;
  for (int i = 0; i < 600000 && !done; ++i) {
    le_perf_render_poll(e, &done, nullptr, nullptr);
    if (!done) usleep(1000);
  }
  int32_t channel = -1, ok = 0;
  le_perf_render_track_status(e, 0, &channel, &ok);
  le_engine_destroy(e);
  if (!done || !ok) return false;
  dryOut = readWavMono(dir + "/stems/dry/track0.wav");
  wetOut = readWavMono(dir + "/stems/wet/track0.wav");
  return !dryOut.empty() && dryOut.size() == wetOut.size();
}

/* [input] through the plugin of [kind] in [block]-frame blocks, folded to
 * mono. */
bool renderPlugin(const VST3::Hosting::Module::Ptr& module,
                  const segno_vst3::FxKind& kind, const Case& c,
                  const std::vector<float>& input, int block,
                  std::vector<float>& out, std::string& why) {
  const uint32_t* p = kind.processor;
  TUID tuid = INLINE_UID(p[0], p[1], p[2], p[3]);
  const VST3::UID uid = VST3::UID::fromTUID(tuid);
  auto component = module->getFactory().createInstance<IComponent>(uid);
  if (!component) {
    why = "no processor class";
    return false;
  }
  static HostApplication host;
  if (component->initialize(&host) != kResultOk) {
    why = "initialize";
    return false;
  }
  FUnknownPtr<IAudioProcessor> processor(component);

  uint8_t bytes[segno_vst3::kStateHeaderBytes + 4 * segno_vst3::kStateMaxParams];
  const int n = segno_vst3::encodeState(c.state, bytes);
  MemoryStream stream(bytes, n);
  if (component->setState(&stream) != kResultOk) {
    why = "setState";
    return false;
  }

  /* The controller takes the same state and shows the same values. */
  TUID cid;
  component->getControllerClassId(cid);
  auto controller =
      module->getFactory().createInstance<IEditController>(VST3::UID::fromTUID(cid));
  if (!controller || controller->initialize(&host) != kResultOk) {
    why = "controller";
    return false;
  }
  MemoryStream cstream(bytes, n);
  if (controller->setComponentState(&cstream) != kResultOk) {
    why = "setComponentState";
    return false;
  }
  for (int i = 0; i < c.state.paramCount; ++i) {
    if ((float)controller->getParamNormalized((ParamID)i) != c.state.params[i]) {
      why = "controller value";
      return false;
    }
  }
  controller->terminate();

  SpeakerArrangement stereo = SpeakerArr::kStereo;
  processor->setBusArrangements(&stereo, 1, &stereo, 1);
  component->activateBus(kAudio, kInput, 0, true);
  component->activateBus(kAudio, kOutput, 0, true);
  ProcessSetup setup{kOffline, kSample32, 4096, (double)kRate};
  processor->setupProcessing(setup);
  component->setActive(true);
  processor->setProcessing(true);

  std::vector<float> inL(block), inR(block), outL(block), outR(block);
  float* ins[2] = {inL.data(), inR.data()};
  float* outs[2] = {outL.data(), outR.data()};
  AudioBusBuffers inBus{};
  inBus.numChannels = 2;
  inBus.channelBuffers32 = ins;
  AudioBusBuffers outBus{};
  outBus.numChannels = 2;
  outBus.channelBuffers32 = outs;
  ProcessContext ctx{};
  ctx.state = ProcessContext::kPlaying | ProcessContext::kTempoValid |
              ProcessContext::kProjectTimeMusicValid | ProcessContext::kTimeSigValid;
  ctx.sampleRate = kRate;
  ctx.tempo = kBpm;
  ctx.timeSigNumerator = 4;
  ctx.timeSigDenominator = 4;

  out.assign(input.size(), 0.0f);
  for (size_t f0 = 0; f0 < input.size(); f0 += block) {
    const int len = (int)std::min<size_t>(block, input.size() - f0);
    for (int i = 0; i < len; ++i) inL[i] = inR[i] = input[f0 + i];
    ParameterChanges changes;
    auto at = [&](int32_t frame, ParamID id, double value) {
      if (frame < (int32_t)f0 || frame >= (int32_t)f0 + len) return;
      int32 index = 0;
      IParamValueQueue* q = changes.addParameterData(id, index);
      q->addPoint(frame - (int32_t)f0, value, index);
    };
    if (c.switched) {
      if (c.state.paramCount > 0) at(kSwitchParamAt, 0, kSwitchParamTo);
      at(kOffAt, segno_vst3::kBypassId, 1.0);
      at(kOnAt, segno_vst3::kBypassId, 0.0);
    }
    ctx.projectTimeSamples = (TSamples)f0;
    ctx.projectTimeMusic = (double)f0 * kBpm / 60.0 / kRate;
    ProcessData data{};
    data.processMode = kOffline;
    data.symbolicSampleSize = kSample32;
    data.numSamples = len;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &inBus;
    data.outputs = &outBus;
    data.inputParameterChanges = &changes;
    data.processContext = &ctx;
    if (processor->process(data) != kResultOk) {
      why = "process";
      return false;
    }
    for (int i = 0; i < len; ++i) out[f0 + i] = 0.5f * (outL[i] + outR[i]);
  }
  processor->setProcessing(false);
  component->setActive(false);
  component->terminate();
  return true;
}

std::vector<Case> casesFor(int32_t type, int32_t width) {
  segno_vst3::FxPluginState base;
  base.kind = type;
  base.hopSeed = segno_fx_lane_hop_seed(0, 0);
  base.clockOffset = kArmClock;
  base.beatOffset = kArmBeat;
  base.paramCount = width;
  segno_fx_defaults(type, base.params);

  segno_vst3::FxPluginState varied = base;
  for (int p = 0; p < width; ++p) {
    le_fx_param_desc d;
    le_fx_param_info(type, p, &d);
    double v = std::fmod(0.31 + 0.47 * p, 1.0) * 0.8 + 0.1;
    if (d.steps > 1) v = std::round(v * (d.steps - 1)) / (d.steps - 1);
    varied.params[p] = (float)v;
  }
  varied.slot = 5;
  varied.output = 1;
  varied.placement = 0.35f;
  varied.level = 1.4f;
  return {
      {"default", base, "", false},
      {"varied", varied,
       "{\"input\": \"stereo\", \"output\": \"mono\", \"placement\": 0.35, "
       "\"level\": 1.4}",
       false},
      {"switched", base, "", true},
  };
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <Segno.vst3> [--kind TYPE] [--block N] [--keep DIR]\n",
                 argv[0]);
    return 2;
  }
  int onlyKind = 0;
  int block = 128;
  std::string keep;
  for (int i = 2; i + 1 < argc; i += 2) {
    if (std::strcmp(argv[i], "--kind") == 0) onlyKind = std::atoi(argv[i + 1]);
    if (std::strcmp(argv[i], "--block") == 0) block = std::atoi(argv[i + 1]);
    if (std::strcmp(argv[i], "--keep") == 0) keep = argv[i + 1];
  }
  std::string error;
  auto module = VST3::Hosting::Module::create(argv[1], error);
  if (!module) {
    std::fprintf(stderr, "cannot load %s: %s\n", argv[1], error.c_str());
    return 2;
  }
  int effectClasses = 0;
  for (const auto& info : module->getFactory().classInfos()) {
    if (info.category() == kVstAudioEffectClass) ++effectClasses;
  }
  std::printf("%s: %d effect classes\n", argv[1], effectClasses);
  if (effectClasses != segno_vst3::kFxKindCount) {
    std::fprintf(stderr, "expected %d\n", segno_vst3::kFxKindCount);
    return 1;
  }

  char tmpl[] = "/tmp/segno-null-XXXXXX";
  const std::string root = keep.empty() ? std::string(mkdtemp(tmpl)) : keep;
  mkdir(root.c_str(), 0755);
  const std::vector<float> input = testSignal();
  int failures = 0;
  std::printf("%-22s %-9s %10s %10s %10s %8s\n", "kind", "case", "residual",
              "wet peak", "wet - dry", "latency");
  for (const segno_vst3::FxKind& kind : segno_vst3::kFxKinds) {
    if (onlyKind != 0 && kind.type != onlyKind) continue;
    const int32_t width = segno_fx_width(kind.type);
    for (const Case& c : casesFor(kind.type, width)) {
      const std::string dir = root + "/" + std::to_string(kind.type) + "-" + c.name;
      std::vector<float> dry, wet, plugin;
      if (!renderEngine(dir, kind.type, c, input, dry, wet)) {
        std::printf("%-22s %-9s engine render failed\n", kind.name, c.name);
        ++failures;
        continue;
      }
      std::string why;
      if (!renderPlugin(module, kind, c, dry, block, plugin, why)) {
        std::printf("%-22s %-9s plugin failed: %s\n", kind.name, c.name, why.c_str());
        ++failures;
        continue;
      }
      float worst = 0.0f, peak = 0.0f, effect = 0.0f;
      size_t at = 0;
      for (size_t i = 0; i < wet.size(); ++i) {
        const float d = std::fabs(plugin[i] - wet[i]);
        if (d > worst) {
          worst = d;
          at = i;
        }
        peak = std::fmax(peak, std::fabs(wet[i]));
        effect = std::fmax(effect, std::fabs(wet[i] - dry[i]));
      }
      char residual[32];
      if (worst == 0.0f) {
        std::snprintf(residual, sizeof(residual), "exact");
      } else {
        std::snprintf(residual, sizeof(residual), "%.1f dB", 20.0 * std::log10(worst));
      }
      int latency = 0;
      {
        segno_fx_slot_config probe{};
        probe.type = kind.type;
        probe.sr = kRate;
        probe.level = 1.0f;
        probe.enabled = 1;
        segno_fx_slot* slot = segno_fx_slot_new(&probe);
        latency = segno_fx_slot_latency(slot);
        segno_fx_slot_free(slot);
      }
      std::printf("%-22s %-9s %10s %7.1f dB %7.1f dB %8d", kind.name, c.name,
                  residual, 20.0 * std::log10(std::fmax(peak, 1e-12f)),
                  20.0 * std::log10(std::fmax(effect, 1e-12f)), latency);
      if (worst > kFail) {
        std::printf("  FAIL (first at frame %zu)", at);
        ++failures;
      }
      std::printf("\n");
      if (!keep.empty()) writeWavMono(dir + "/plugin.wav", plugin);
    }
  }
  std::printf(failures ? "%d FAILED\n" : "ALL PASSED\n", failures);
  return failures ? 1 : 0;
}
