/*
 * binding_test.cpp — every control of every pedal-face editor (#1815) drives
 * a real parameter of its plugin.
 *
 * Reads the faces' layout (faces/faces.json, which test/vst3_faces keeps
 * current) and loads the built bundle as a host does. For each face, the
 * plugin of its engine type must exist, and each control's parameter must be
 * one its edit controller lists: the footswitch the bypass, a choice's
 * buttons or menu one per position of a stepped parameter, a knob or a slider
 * with one picture per position of a stepped parameter, or the layout's
 * frame count of a continuous one.
 *
 * Every parameter but the bypass must have exactly one control that sets it
 * (a knob of a choice only shows it: the panel's selector sets it), and the
 * bypass exactly one, the footswitch; so no parameter is left out of a
 * window, nor offered twice.
 *
 * Every plugin's value text (getParamStringByValue) must be what the console
 * prints (value_text.h): test/value_texts.json holds the console's for every
 * parameter of every kind, at k / samples and at each position of a stepped
 * one.
 *
 * With --editors, the bundle must also hold the faces' pictures: every
 * plugin with a face opens an editor of the layout's size, and every other
 * plugin none (the host's own controls). Without it, no plugin may open one
 * (a bundle built without the pictures, as on Linux).
 *
 * Usage: segno_vst3_binding_test <Segno.vst3> <faces.json> <value_texts.json>
 *        [--editors]
 */
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "json_read.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/utility/stringconvert.h"
#include "../segno_fx_kinds.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

int failures = 0;

void fail(int type, const char* what, int param) {
  std::printf("type %d: %s (param %d)\n", type, what, param);
  ++failures;
}

const segno_vst3::FxKind* kindOf(int type) {
  for (const auto& kind : segno_vst3::kFxKinds) {
    if (kind.type == type) return &kind;
  }
  return nullptr;
}

IPtr<IEditController> controllerOf(const VST3::Hosting::Module::Ptr& module,
                                   const segno_vst3::FxKind& kind) {
  static HostApplication host;
  const uint32_t* c = kind.controller;
  TUID tuid = INLINE_UID(c[0], c[1], c[2], c[3]);
  auto controller =
      module->getFactory().createInstance<IEditController>(VST3::UID::fromTUID(tuid));
  if (controller && controller->initialize(&host) != kResultOk) return nullptr;
  return controller;
}

/* The whole of [path], or an empty string. */
std::string readFile(const char* path) {
  std::ifstream file(path);
  std::stringstream text;
  text << file.rdbuf();
  return text.str();
}

/* [controller]'s text for [id] at [v], in UTF-8. */
std::string textOf(IEditController* controller, ParamID id, double v) {
  String128 text{};
  if (controller->getParamStringByValue(id, v, text) != kResultOk) return "(none)";
  return Steinberg::Vst::StringConvert::convert(text);
}

/* [value]'s string, in full, its escapes undone (the Dart encoder escapes
 * only a quote, a backslash and control characters, which no text holds). */
std::string stringOf(const le_json_value* value) {
  if (value == nullptr || value->type != LE_JSON_STRING) return "(missing)";
  std::string out;
  for (int i = 0; i < value->string_len; ++i) {
    const char c = value->string_start[i];
    if (c == '\\' && i + 1 < value->string_len) {
      out += value->string_start[++i];
    } else {
      out += c;
    }
  }
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: %s <Segno.vst3> <faces.json> <value_texts.json> [--editors]\n",
                 argv[0]);
    return 2;
  }
  const bool editors = argc > 4 && std::strcmp(argv[4], "--editors") == 0;
  std::string error;
  auto module = VST3::Hosting::Module::create(argv[1], error);
  if (!module) {
    std::fprintf(stderr, "cannot load %s: %s\n", argv[1], error.c_str());
    return 2;
  }
  const std::string json = readFile(argv[2]);
  std::vector<le_json_value> nodes(1 << 16);
  le_json_arena arena{nodes.data(), (int)nodes.size(), 0};
  const le_json_value* manifest = le_json_parse(json.c_str(), &arena);
  if (manifest == nullptr) {
    std::fprintf(stderr, "cannot read %s\n", argv[2]);
    return 2;
  }
  const int frames = (int)le_json_number(le_json_get(manifest, "frames"), 0);
  const le_json_value* faces = le_json_get(manifest, "faces");
  std::map<int, const le_json_value*> faceOf;
  for (int f = 0; f < le_json_length(faces); ++f) {
    const le_json_value* face = le_json_at(faces, f);
    faceOf[(int)le_json_number(le_json_get(face, "type"), -1)] = face;
  }

  int controls = 0;
  for (const auto& [type, face] : faceOf) {
    const segno_vst3::FxKind* kind = kindOf(type);
    if (kind == nullptr) {
      fail(type, "no plugin of this type", -1);
      continue;
    }
    auto controller = controllerOf(module, *kind);
    if (!controller) {
      fail(type, "no controller", -1);
      continue;
    }
    std::map<ParamID, ParameterInfo> params;
    for (int32 i = 0; i < controller->getParameterCount(); ++i) {
      ParameterInfo info{};
      controller->getParameterInfo(i, info);
      params[info.id] = info;
    }
    const le_json_value* list = le_json_get(face, "controls");
    std::map<ParamID, int> setters; /* controls that set each parameter */
    for (int i = 0; i < le_json_length(list); ++i, ++controls) {
      const le_json_value* c = le_json_at(list, i);
      char control[32] = "";
      le_json_string(le_json_get(c, "control"), control, sizeof(control));
      const int param = (int)le_json_number(le_json_get(c, "param"), -1);
      if (!le_json_bool(le_json_get(c, "display"), 0)) ++setters[(ParamID)param];
      const auto found = params.find((ParamID)param);
      if (found == params.end()) {
        fail(type, "no such parameter", param);
        continue;
      }
      const ParameterInfo& info = found->second;
      const int positions = info.stepCount + 1;
      const int count = (int)le_json_number(le_json_get(c, "frames"), 0);
      if (std::strcmp(control, "footswitch") == 0) {
        if ((info.flags & ParameterInfo::kIsBypass) == 0) fail(type, "footswitch not bypass", param);
      } else if (std::strcmp(control, "knob") == 0 || std::strcmp(control, "slider") == 0) {
        if (count != (info.stepCount > 0 ? positions : frames)) {
          fail(type, "pictures do not match the parameter's positions", param);
        }
      } else if (std::strcmp(control, "buttons") == 0) {
        if (info.stepCount == 0 || count != positions ||
            le_json_length(le_json_get(c, "buttons")) != positions) {
          fail(type, "buttons do not match the parameter's positions", param);
        }
      } else if (std::strcmp(control, "select") == 0) {
        if (info.stepCount == 0 || count != positions ||
            le_json_length(le_json_get(c, "names")) != positions) {
          fail(type, "menu does not match the parameter's positions", param);
        }
      } else {
        fail(type, "unknown control", param);
      }
    }
    for (const auto& [id, info] : params) {
      const int count = setters.count(id) != 0 ? setters[id] : 0;
      if (count != 1) {
        fail(type, count == 0 ? "a parameter with no control" : "a parameter with two controls",
             (int)id);
      }
    }
    controller->terminate();
  }

  /* Every plugin's value texts against the console's. */
  const std::string textsJson = readFile(argv[3]);
  std::vector<le_json_value> textNodes(1 << 17);
  le_json_arena textArena{textNodes.data(), (int)textNodes.size(), 0};
  const le_json_value* texts = le_json_parse(textsJson.c_str(), &textArena);
  if (texts == nullptr) {
    std::fprintf(stderr, "cannot read %s\n", argv[3]);
    return 2;
  }
  const int samples = (int)le_json_number(le_json_get(texts, "samples"), 0);
  const le_json_value* kinds = le_json_get(texts, "kinds");
  int checked = 0;
  for (int k = 0; k < le_json_length(kinds); ++k) {
    const le_json_value* entry = le_json_at(kinds, k);
    const int type = (int)le_json_number(le_json_get(entry, "type"), -1);
    const segno_vst3::FxKind* kind = kindOf(type);
    auto controller = kind != nullptr ? controllerOf(module, *kind) : nullptr;
    if (!controller) {
      fail(type, "no plugin for its value texts", -1);
      continue;
    }
    const le_json_value* params = le_json_get(entry, "params");
    for (int p = 0; p < le_json_length(params); ++p) {
      const le_json_value* param = le_json_at(params, p);
      const ParamID id = (ParamID)le_json_number(le_json_get(param, "param"), -1);
      const auto check = [&](const le_json_value* list, int last) {
        for (int i = 0; i <= last; ++i, ++checked) {
          const double v = (double)i / last;
          const std::string want = stringOf(le_json_at(list, i));
          const std::string got = textOf(controller, id, v);
          if (got != want) {
            std::printf("type %d: param %u at %d/%d reads \"%s\", the console \"%s\"\n", type,
                        id, i, last, got.c_str(), want.c_str());
            ++failures;
          }
        }
      };
      check(le_json_get(param, "texts"), samples);
      if (const le_json_value* positions = le_json_get(param, "positions")) {
        check(positions, le_json_length(positions) - 1);
      }
    }
    controller->terminate();
  }

  /* Which plugins open an editor, and at what size. */
  for (const auto& kind : segno_vst3::kFxKinds) {
    auto controller = controllerOf(module, kind);
    if (!controller) continue;
    IPlugView* view = controller->createView(ViewType::kEditor);
    const auto face = faceOf.find(kind.type);
    const bool wanted = editors && face != faceOf.end();
    if ((view != nullptr) != wanted) {
      fail(kind.type, wanted ? "no editor" : "an editor without a face", -1);
    }
    if (view != nullptr && face != faceOf.end()) {
      ViewRect r;
      view->getSize(&r);
      const le_json_value* size = le_json_get(face->second, "size");
      if (r.getWidth() != (int32)le_json_number(le_json_at(size, 0), 0) ||
          r.getHeight() != (int32)le_json_number(le_json_at(size, 1), 0)) {
        fail(kind.type, "editor size differs from the layout", -1);
      }
    }
    if (view != nullptr) view->release();
    controller->terminate();
  }

  std::printf("%zu faces, %d controls, %d value texts, editors %s: %s\n", faceOf.size(),
              controls, checked, editors ? "required" : "absent",
              failures == 0 ? "ok" : "FAILED");
  return failures == 0 ? 0 : 1;
}
