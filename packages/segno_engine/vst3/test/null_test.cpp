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
 *   switched  the defaults; the first setting moves to 0.8 inside a block
 *             near 1.5 s, the effect is switched off (Enabled) on a block
 *             boundary near 2.0 s and on again inside a block near 3.0 s,
 *             then off and on again 1 ms later (inside the ramp) near
 *             3.5 s
 *   starts-off  the defaults, the entry off at arm, switched on inside a
 *             block near 1.0 s; the stopped host's pre-roll leaves the
 *             plugin on, and the host's automation turns it off at the
 *             first frame it plays, as Live sends an envelope's value
 *   The engine reads the changes from events.log, the plugin as parameter
 *   changes at those frames, so a switch nulls only if the plugin's Enabled
 *   is the engine's switch: its ramp, a delay's or a reverb's drain, the
 *   fresh start of a re-enable, a latency-bearing kind's warm-up and its
 *   undelayed input while off.
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
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>
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

/* A parameter as packages/daw_export lists it for a Live set
 * (segno_vst3_plugins.dart): its name, VST3 step count, default and
 * whether it is a list, by id. */
struct DartParameter {
  std::string name;
  int steps;
  double def;
  bool list;
};
using DartParameters = std::map<ParamID, DartParameter>;

/* The Dart table of each kind's parameters, plus the channel parameters
 * every plugin has, read from the file the export is generated with
 * (SEGNO_DART_PLUGINS). The null test checks every plugin's controller
 * against it, so an exported set names and steps the parameters the
 * plugin has. */
std::map<int, DartParameters> dartPlugins() {
  std::ifstream in(SEGNO_DART_PLUGINS);
  std::stringstream text;
  text << in.rdbuf();
  const std::string dart = text.str();
  auto params = [&](const std::string& body, ParamID first, bool keyed) {
    DartParameters out;
    ParamID id = first;
    const std::string tail =
        R"(SegnoParameter\('([^']+)'(?:, steps: (\d+))?(?:, defaultValue: ([-0-9.e]+))?(, list: true)?\))";
    const std::regex entry(keyed ? R"((\d+): )" + tail : tail);
    for (std::sregex_iterator i(body.begin(), body.end(), entry), end; i != end; ++i) {
      const std::smatch& m = *i;
      const int k = keyed ? 1 : 0;
      const DartParameter p{m[k + 1], m[k + 2].matched ? std::stoi(m[k + 2]) : 0,
                            m[k + 3].matched ? std::stod(m[k + 3]) : 0.0, m[k + 4].matched};
      out[keyed ? (ParamID)std::stoi(m[1]) : id++] = p;
    }
    return out;
  };
  std::map<int, DartParameters> plugins;
  std::smatch channels;
  DartParameters channel;
  if (std::regex_search(dart, channels,
                        std::regex(R"(segnoChannelParameters = \{([\s\S]*?)\};)"))) {
    channel = params(channels[1], 0, true);
  }
  const std::regex plugin(
      R"((\d+): SegnoPlugin\([\s\S]*?parameters: \[([\s\S]*?)\],?\s*\))");
  for (std::sregex_iterator i(dart.begin(), dart.end(), plugin), end; i != end; ++i) {
    DartParameters p = params((*i)[2], 0, false);
    p.insert(channel.begin(), channel.end());
    plugins[std::stoi((*i)[1])] = p;
  }
  return plugins;
}

/* Whether [controller]'s parameters are [expected]: same ids, names, step
 * counts, defaults and lists. */
bool sameParameters(IEditController* controller, const DartParameters& expected,
                    std::string& why) {
  size_t seen = 0;
  for (int32 i = 0; i < controller->getParameterCount(); ++i) {
    ParameterInfo info{};
    controller->getParameterInfo(i, info);
    std::string title;
    for (int k = 0; k < 128 && info.title[k] != 0; ++k) title += (char)info.title[k];
    const auto it = expected.find(info.id);
    if (it == expected.end() || it->second.name != title ||
        it->second.steps != info.stepCount ||
        it->second.list != ((info.flags & ParameterInfo::kIsList) != 0) ||
        std::fabs(it->second.def - info.defaultNormalizedValue) > 1e-6) {
      why = "parameter " + std::to_string(info.id) + " (" + title +
            ") differs from segno_vst3_plugins.dart";
      return false;
    }
    ++seen;
  }
  if (seen != expected.size()) {
    why = "segno_vst3_plugins.dart lists parameters the plugin does not have";
    return false;
  }
  return true;
}

/* One change during the take, at capture frame [frame]: setting [param]
 * to [value], or (param -1) the entry's switch to [value] != 0. */
struct Change {
  int32_t frame;
  int32_t param;
  float value;
};

struct Case {
  const char* name;
  segno_vst3::FxPluginState state;
  const char* channelsJson; /* the manifest's "channels", or "" */
  std::vector<Change> changes;
  /* The host's pre-roll leaves the plugin on, and its first playing block
   * sets the state's switch at frame 0. */
  bool presetSwitch = false;
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
      "%d, \"params\": %s%s%s%s}]}]}]}, \"disarmSnapshot\": {\"tracks\": []}, "
      "\"layers\": []}",
      kRate, kFrames, empties.c_str(), type, paramsJson(c.state).c_str(),
      c.channelsJson[0] ? ", \"channels\": " : "", c.channelsJson,
      c.state.enabled ? "" : ", \"enabled\": false");
  FILE* mf = std::fopen((dir + "/performance.json").c_str(), "wb");
  std::fputs(manifest, mf);
  std::fclose(mf);

  std::vector<capture_log_change> changes;
  for (const Change& k : c.changes) {
    if (k.param < c.state.paramCount) changes.push_back({k.frame, k.param, k.value});
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
  dryOut = readWavMono(dir + "/stems/dry/track0-lane0.wav");
  wetOut = readWavMono(dir + "/stems/wet/track0-lane0.wav");
  return !dryOut.empty() && dryOut.size() == wetOut.size();
}

/* [input] through the plugin of [kind] in [block]-frame blocks, folded to
 * mono. */
bool renderPlugin(const VST3::Hosting::Module::Ptr& module,
                  const segno_vst3::FxKind& kind, const Case& c,
                  const std::vector<float>& input, int block,
                  std::vector<float>& out, int& latency, std::string& why) {
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
  static const std::map<int, DartParameters> dart = dartPlugins();
  const auto listed = dart.find(kind.type);
  if (listed == dart.end()) {
    why = "not in segno_vst3_plugins.dart";
    return false;
  }
  if (!sameParameters(controller, listed->second, why)) return false;
  controller->terminate();

  SpeakerArrangement stereo = SpeakerArr::kStereo;
  processor->setBusArrangements(&stereo, 1, &stereo, 1);
  component->activateBus(kAudio, kInput, 0, true);
  component->activateBus(kAudio, kOutput, 0, true);
  ProcessSetup setup{kOffline, kSample32, 4096, (double)kRate};
  processor->setupProcessing(setup);
  component->setActive(true);
  processor->setProcessing(true);
  latency = (int)processor->getLatencySamples();

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

  /* A second of a stopped host first, with signal through it, as Live
   * runs a plugin while its transport stands: the plugin starts again as
   * at arm when the host plays, so this must not show in the render. */
  {
    ProcessContext stopped = ctx;
    stopped.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid;
    uint32_t noise = 777;
    for (int f0 = 0; f0 < kRate; f0 += block) {
      for (int i = 0; i < block; ++i) {
        noise = noise * 1664525u + 1013904223u;
        inL[i] = inR[i] = 0.3f * ((int32_t)noise / 2147483648.0f);
      }
      ParameterChanges left;
      if (c.presetSwitch && f0 == 0) {
        /* Whatever the host left the switch at: on. */
        int32 index = 0;
        left.addParameterData(segno_vst3::kEnabledId, index)->addPoint(0, 1.0, index);
      }
      ProcessData data{};
      data.inputParameterChanges = &left;
      data.processMode = kRealtime;
      data.symbolicSampleSize = kSample32;
      data.numSamples = block;
      data.numInputs = 1;
      data.numOutputs = 1;
      data.inputs = &inBus;
      data.outputs = &outBus;
      data.processContext = &stopped;
      processor->process(data);
    }
  }
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
    if (c.presetSwitch) at(0, segno_vst3::kEnabledId, c.state.enabled);
    for (const Change& k : c.changes) {
      if (k.param < c.state.paramCount) {
        at(k.frame, k.param < 0 ? segno_vst3::kEnabledId : (ParamID)k.param, k.value);
      }
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

std::vector<Case> casesFor(int32_t type, int32_t width, int32_t block) {
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
  /* A frame near [seconds] on a block boundary, or [into] frames into
   * that block. */
  const auto near = [block](double seconds, int32_t into) {
    return (int32_t)(seconds * kRate) / block * block + into;
  };
  const int32_t inside = block / 2 > 0 ? block / 2 : 1;
  const int32_t offAgain = near(3.5, inside / 2 + 1);
  segno_vst3::FxPluginState off = base;
  off.enabled = 0;
  return {
      {"default", base, "", {}},
      {"varied", varied,
       "{\"input\": \"stereo\", \"output\": \"mono\", \"placement\": 0.35, "
       "\"level\": 1.4}",
       {}},
      {"switched", base, "",
       {{near(1.5, block / 3 + 1), 0, 0.8f},
        {near(2.0, 0), -1, 0.0f},
        {near(3.0, inside), -1, 1.0f},
        {offAgain, -1, 0.0f},
        {offAgain + kRate / 1000, -1, 1.0f}}},
      {"starts-off", off, "", {{near(1.0, inside), -1, 1.0f}}, true},
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
  /* The captures (about 300 MB) go when the test ends, unless kept. */
  struct Cleanup {
    std::string dir;
    ~Cleanup() {
      if (!dir.empty()) std::filesystem::remove_all(dir);
    }
  } cleanup{keep.empty() ? root : std::string()};
  const std::vector<float> input = testSignal();
  int failures = 0;
  std::printf("%-22s %-10s %10s %10s %10s %8s\n", "kind", "case", "residual",
              "wet peak", "wet - dry", "latency");
  for (const segno_vst3::FxKind& kind : segno_vst3::kFxKinds) {
    if (onlyKind != 0 && kind.type != onlyKind) continue;
    const int32_t width = segno_fx_width(kind.type);
    for (const Case& c : casesFor(kind.type, width, block)) {
      const std::string dir = root + "/" + std::to_string(kind.type) + "-" + c.name;
      std::vector<float> dry, wet, plugin;
      if (!renderEngine(dir, kind.type, c, input, dry, wet)) {
        std::printf("%-22s %-10s engine render failed\n", kind.name, c.name);
        ++failures;
        continue;
      }
      std::string why;
      int reported = 0;
      if (!renderPlugin(module, kind, c, dry, block, plugin, reported, why)) {
        std::printf("%-22s %-10s plugin failed: %s\n", kind.name, c.name, why.c_str());
        ++failures;
        continue;
      }
      int latency = 0;
      {
        segno_fx_slot_config probe{};
        probe.type = kind.type;
        probe.slot = c.state.slot;
        probe.sr = kRate;
        probe.level = 1.0f;
        probe.enabled = 1;
        segno_fx_slot* slot = segno_fx_slot_new(&probe);
        latency = segno_fx_slot_latency(slot);
        segno_fx_slot_free(slot);
      }
      /* The plugin reports its latency at every rate, the kind's largest
       * (processor.h), and delays its output by the rest. */
      const size_t pad = reported >= latency ? (size_t)(reported - latency) : 0;
      float worst = 0.0f, peak = 0.0f, effect = 0.0f;
      size_t at = 0;
      for (size_t i = 0; i + pad < wet.size(); ++i) {
        const float d = std::fabs(plugin[i + pad] - wet[i]);
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
      std::printf("%-22s %-10s %10s %7.1f dB %7.1f dB %8d", kind.name, c.name,
                  residual, 20.0 * std::log10(std::fmax(peak, 1e-12f)),
                  20.0 * std::log10(std::fmax(effect, 1e-12f)), reported);
      const int largest = std::max((int)segno_fx_reported_latency(kind.type), latency);
      if (worst > kFail || reported != largest) {
        if (reported != largest) std::printf("  reports latency %d", reported);
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
