#include "controller.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "params.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "segno_fx_state.h"

#include "fx_slot.h"
#include "segno_engine_api.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace segno_vst3 {

namespace {

void toString128(const char* text, String128 out) {
  UString(out, 128).fromAscii(text);
}

/* A setting's value at normalized [v], by its descriptor's curve. */
double settingValue(const le_fx_param_desc& d, double v) {
  const double lo = d.at_min;
  const double hi = d.at_max;
  switch (d.curve) {
    case LE_FX_CURVE_EXPONENTIAL:
      return lo * std::pow(hi / lo, v);
    case LE_FX_CURVE_RECIPROCAL:
      return 1.0 / (1.0 / lo + (1.0 / hi - 1.0 / lo) * v);
    case LE_FX_CURVE_REVERB_TIME: {
      const double t = v < 1.0 ? (v + lo) / (1.0 - v) : hi;
      return t > hi ? hi : t;
    }
    default:
      return lo + (hi - lo) * v;
  }
}

ParameterInfo infoOf(const char* title, ParamID id, const le_fx_param_desc& desc) {
  ParameterInfo info{};
  info.id = id;
  toString128(title, info.title);
  toString128(title, info.shortTitle);
  info.stepCount = desc.steps > 1 ? desc.steps - 1 : 0;
  info.defaultNormalizedValue = desc.def;
  info.flags = ParameterInfo::kCanAutomate;
  return info;
}

/* One of the kind's settings: its value shown in its unit. */
class SettingParameter : public Parameter {
 public:
  SettingParameter(const char* title, ParamID id, const le_fx_param_desc& desc)
      : Parameter(infoOf(title, id, desc)), desc_(desc) {}

  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    char text[64];
    format(v, text, sizeof(text));
    toString128(text, string);
  }

  bool fromString(const TChar*, ParamValue&) const SMTG_OVERRIDE { return false; }

 private:
  void format(ParamValue v, char* text, size_t size) const {
    if (((desc_.flags & LE_FX_PARAM_OFF_AT_MIN) && v <= 0.0) ||
        ((desc_.flags & LE_FX_PARAM_OFF_AT_MAX) && v >= 1.0)) {
      std::snprintf(text, size, "Off");
      return;
    }
    if (desc_.unit == LE_FX_UNIT_CHOICE) {
      const int n = desc_.steps > 1 ? desc_.steps : 2;
      std::snprintf(text, size, "%ld", std::lround(v * (n - 1)) + 1);
      return;
    }
    const double x = settingValue(desc_, v);
    switch (desc_.unit) {
      case LE_FX_UNIT_PERCENT:
        std::snprintf(text, size, "%.0f %%", x);
        break;
      case LE_FX_UNIT_MS:
        std::snprintf(text, size, x < 10.0 ? "%.2f ms" : "%.0f ms", x);
        break;
      case LE_FX_UNIT_HZ:
        if (x >= 1000.0) {
          std::snprintf(text, size, "%.2f kHz", x / 1000.0);
        } else {
          std::snprintf(text, size, x < 10.0 ? "%.2f Hz" : "%.0f Hz", x);
        }
        break;
      case LE_FX_UNIT_SEMITONES:
        std::snprintf(text, size, "%+.0f st", x);
        break;
      case LE_FX_UNIT_TIMES:
        std::snprintf(text, size, "%.1f x", x);
        break;
      case LE_FX_UNIT_DB:
        std::snprintf(text, size, "%.1f dB", x);
        break;
      case LE_FX_UNIT_RATIO:
        std::snprintf(text, size, "%.1f : 1", x);
        break;
      case LE_FX_UNIT_SECONDS:
        std::snprintf(text, size, "%.2f s", x);
        break;
      default:
        std::snprintf(text, size, "%.2f", x);
        break;
    }
  }

  le_fx_param_desc desc_;
};

/* The placement: -1..1, centre in the middle. */
class PlacementParameter : public Parameter {
 public:
  PlacementParameter()
      : Parameter(STR16("Balance / Pan"), kPlacementId, nullptr, 0.5, 0,
                  ParameterInfo::kCanAutomate) {}
  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    const long p = std::lround(placementFromNormalized(v) * 100.0f);
    char text[16];
    if (p == 0) {
      std::snprintf(text, sizeof(text), "C");
    } else {
      std::snprintf(text, sizeof(text), "%ld%c", p < 0 ? -p : p, p < 0 ? 'L' : 'R');
    }
    toString128(text, string);
  }
};

/* The entry's level, shown in dB. */
class LevelParameter : public Parameter {
 public:
  LevelParameter()
      : Parameter(STR16("Level"), kLevelId, nullptr, levelToNormalized(1.0f), 0,
                  ParameterInfo::kCanAutomate) {}
  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    const float level = levelFromNormalized(v);
    char text[16];
    if (level <= 0.0f) {
      std::snprintf(text, sizeof(text), "-inf dB");
    } else {
      std::snprintf(text, sizeof(text), "%.1f dB", 20.0 * std::log10(level));
    }
    toString128(text, string);
  }
};

/* "low_cut" as "Low cut". */
void titleOf(const char* key, char* out, size_t size) {
  size_t i = 0;
  for (; key[i] != '\0' && i + 1 < size; ++i) {
    const char c = key[i] == '_' ? ' ' : key[i];
    out[i] = i == 0 ? (char)std::toupper((unsigned char)c) : c;
  }
  out[i] = '\0';
}

}  // namespace

FUnknown* Controller::createInstance(void* context) {
  return static_cast<IEditController*>(
      new Controller(static_cast<const FxKind*>(context)));
}

tresult PLUGIN_API Controller::initialize(FUnknown* context) {
  const tresult result = EditController::initialize(context);
  if (result != kResultOk) return result;
  const int32_t n = segno_fx_width(kind_->type);
  for (int32_t p = 0; p < n; ++p) {
    le_fx_param_desc desc;
    if (le_fx_param_info(kind_->type, p, &desc) != LE_OK) continue;
    char title[LE_FX_PARAM_KEY_CHARS];
    titleOf(desc.key, title, sizeof(title));
    parameters.addParameter(new SettingParameter(title, (ParamID)p, desc));
  }
  auto* input = new StringListParameter(STR16("Input"), kInputId, nullptr,
                                        ParameterInfo::kCanAutomate | ParameterInfo::kIsList);
  input->appendString(STR16("Stereo"));
  input->appendString(STR16("Left"));
  input->appendString(STR16("Right"));
  input->appendString(STR16("Mono sum"));
  parameters.addParameter(input);
  auto* output = new StringListParameter(STR16("Output"), kOutputId, nullptr,
                                         ParameterInfo::kCanAutomate | ParameterInfo::kIsList);
  output->appendString(STR16("Stereo"));
  output->appendString(STR16("Mono"));
  parameters.addParameter(output);
  parameters.addParameter(new PlacementParameter());
  parameters.addParameter(new LevelParameter());
  parameters.addParameter(STR16("Bypass"), nullptr, 1, 0,
                          ParameterInfo::kCanAutomate | ParameterInfo::kIsBypass,
                          kBypassId);
  return kResultOk;
}

tresult PLUGIN_API Controller::setComponentState(IBStream* stream) {
  if (stream == nullptr) return kInvalidArgument;
  FxPluginState s;
  // Settings the state leaves out are the kind's defaults, as the
  // processor runs them.
  segno_fx_defaults(kind_->type, s.params);
  const auto read = [stream](uint8_t* into, int32 size) {
    int32 got = 0;
    return stream->read(into, size, &got) == kResultOk ? got : -1;
  };
  if (!readState(read, s) || s.kind != kind_->type) return kResultFalse;
  const int32_t n = segno_fx_width(kind_->type);
  for (int32_t p = 0; p < n; ++p) setParamNormalized((ParamID)p, s.params[p]);
  setParamNormalized(kInputId, inputToNormalized(s.input));
  setParamNormalized(kOutputId, outputToNormalized(s.output));
  setParamNormalized(kPlacementId, placementToNormalized(s.placement));
  setParamNormalized(kLevelId, levelToNormalized(s.level));
  setParamNormalized(kBypassId, s.enabled != 0 ? 0.0 : 1.0);
  return kResultOk;
}

}  // namespace segno_vst3
