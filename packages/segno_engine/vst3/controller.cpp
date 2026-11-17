#include "controller.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "editor.h"
#include "value_text.h"
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif
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

/* One of the kind's settings, its value as the console prints it. */
class SettingParameter : public Parameter {
 public:
  SettingParameter(int32_t type, const char* title, ParamID id, const le_fx_param_desc& desc)
      : Parameter(infoOf(title, id, desc)), type_(type) {}

  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    toString128(valueText(type_, getInfo().id, v).c_str(), string);
  }

  bool fromString(const TChar*, ParamValue&) const SMTG_OVERRIDE { return false; }

 private:
  int32_t type_;
};

/* The input or the output: its choices by the console's names, shown as
 * the processor reads them. */
class ChannelChoiceParameter : public StringListParameter {
 public:
  ChannelChoiceParameter(const TChar* title, ParamID id, int32_t positions)
      : StringListParameter(title, id, nullptr,
                            ParameterInfo::kCanAutomate | ParameterInfo::kIsList) {
    for (int32_t k = 0; k < positions; ++k) {
      const std::string name = valueText(0, id, (double)k / (positions - 1));
      String128 text;
      toString128(name.c_str(), text);
      appendString(text);
    }
  }

  /* By the position the processor plays (params.h, nearest), where the
   * SDK's list would name the one below. */
  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    toString128(valueText(0, getInfo().id, v).c_str(), string);
  }
};

/* The balance or pan and the level, their values as the console prints
 * them. */
class ChannelParameter : public Parameter {
 public:
  ChannelParameter(const TChar* title, ParamID id, ParamValue initial)
      : Parameter(title, id, nullptr, initial, 0, ParameterInfo::kCanAutomate) {}
  void toString(ParamValue v, String128 string) const SMTG_OVERRIDE {
    toString128(valueText(0, getInfo().id, v).c_str(), string);
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
    parameters.addParameter(new SettingParameter(kind_->type, title, (ParamID)p, desc));
  }
  parameters.addParameter(new ChannelChoiceParameter(STR16("Input"), kInputId, 4));
  parameters.addParameter(new ChannelChoiceParameter(STR16("Output"), kOutputId, 2));
  parameters.addParameter(
      new ChannelParameter(STR16("Balance / Pan"), kPlacementId, placementToNormalized(0.0f)));
  parameters.addParameter(
      new ChannelParameter(STR16("Level"), kLevelId, levelToNormalized(1.0f)));
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

IPlugView* PLUGIN_API Controller::createView(FIDString name) {
  if (name == nullptr || std::strcmp(name, ViewType::kEditor) != 0) return nullptr;
#ifdef __APPLE__
  return createFaceEditor(this, kind_->type);
#else
  return nullptr;
#endif
}

tresult PLUGIN_API Controller::setParamNormalized(ParamID tag, ParamValue value) {
  const tresult result = EditController::setParamNormalized(tag, value);
#ifdef __APPLE__
  if (onEditorThread()) {
    refreshEditors(tag);
  } else {
    // A host that sets a value from another thread: the editors redraw on
    // their own, the controller kept alive until then.
    struct Pending {
      Controller* controller;
      ParamID tag;
    };
    addRef();
    dispatch_async_f(dispatch_get_main_queue(), new Pending{this, tag}, [](void* context) {
      auto* pending = static_cast<Pending*>(context);
      pending->controller->refreshEditors(pending->tag);
      pending->controller->release();
      delete pending;
    });
  }
#endif
  return result;
}

void Controller::refreshEditors(ParamID tag) {
#ifdef __APPLE__
  for (EditorView* editor : editors_) refreshFaceEditor(editor, tag);
#else
  (void)tag;
#endif
}

void Controller::editorAttached(EditorView* editor) { editors_.push_back(editor); }

void Controller::editorRemoved(EditorView* editor) {
  editors_.erase(std::remove(editors_.begin(), editors_.end(), editor), editors_.end());
}

void Controller::editorDestroyed(EditorView* editor) { editorRemoved(editor); }

}  // namespace segno_vst3
