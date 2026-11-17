/*
 * controller.h — a Segno plugin's edit controller: the kind's settings,
 * the entry's channel handling and its bypass as host parameters
 * (params.h), each value shown in the unit the console shows it in
 * (le_fx_param_info). Its editor is the kind's pedal (editor.h).
 */
#pragma once

#include <atomic>
#include <vector>

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
  Steinberg::IPlugView* PLUGIN_API createView(Steinberg::FIDString name) SMTG_OVERRIDE;
  /* Also redraws the open editor, for a change from the host. */
  Steinberg::tresult PLUGIN_API setParamNormalized(Steinberg::Vst::ParamID tag,
                                                   Steinberg::Vst::ParamValue value)
      SMTG_OVERRIDE;
  void editorAttached(Steinberg::Vst::EditorView* editor) SMTG_OVERRIDE;
  void editorRemoved(Steinberg::Vst::EditorView* editor) SMTG_OVERRIDE;
  void editorDestroyed(Steinberg::Vst::EditorView* editor) SMTG_OVERRIDE;

 private:
  /* Redraws what shows [tag] in every open editor; on the editor thread. */
  void refreshEditors(Steinberg::Vst::ParamID tag);

  const FxKind* kind_;
  /* The open editors, touched only on the editor thread (editor.h), and
   * how many there are, which any thread reads. */
  std::vector<Steinberg::Vst::EditorView*> editors_;
  std::atomic<int> editorCount_{0};
};

}  // namespace segno_vst3
