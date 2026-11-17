/*
 * editor.h — a Segno plugin's editor: its pedal as the console draws it
 * (#1815), with working knobs, choices and footswitch.
 *
 * The art is the console's own: test/vst3_faces renders each kind's face
 * (lib/looper/view/fx/stomp) and the controls beside it into pictures, and
 * faces/faces.json, which it keeps current, says where each control is and
 * which parameter it drives. install.sh renders the pictures and the build
 * bundles them with the manifest in Contents/Resources/faces. The editor
 * draws the still background and, over it, the picture of each control at
 * its parameter's value, and sets parameters through the edit controller
 * (beginEdit, performEdit, endEdit), so a host records automation from it.
 *
 * macOS only (an NSView). Elsewhere, for a kind no console pedal stands for,
 * and for a bundle built without the pictures, there is no editor and the
 * host shows its own controls.
 */
#pragma once

#include <cstdint>

#include "pluginterfaces/gui/iplugview.h"
#include "public.sdk/source/vst/vsteditcontroller.h"

namespace segno_vst3 {

/* The editor of a plugin of engine type [type], or nullptr when the bundle
 * holds no face for it. */
Steinberg::IPlugView* createFaceEditor(Steinberg::Vst::EditController* controller,
                                       int32_t type);

/* Redraws [editor], one createFaceEditor made, after a parameter changed. */
void refreshFaceEditor(Steinberg::Vst::EditorView* editor);

}  // namespace segno_vst3
