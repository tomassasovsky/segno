/*
 * controller.h — a Segno plugin's edit controller: the kind's settings,
 * the entry's channel handling and its bypass as host parameters
 * (params.h), each value shown in the unit the console shows it in
 * (le_fx_param_info).
 */
#pragma once

#include "public.sdk/source/vst/vsteditcontroller.h"
#include "segno_fx_kinds.h"

namespace segno_vst3 {

class Controller : public Steinberg::Vst::EditController {
 public:
  explicit Controller(const FxKind* kind) : kind_(kind) {}

  /* [context] is the FxKind the factory registered the class with. */
  static Steinberg::FUnknown* createInstance(void* context);

  Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setComponentState(Steinberg::IBStream* state) SMTG_OVERRIDE;

 private:
  const FxKind* kind_;
};

}  // namespace segno_vst3
