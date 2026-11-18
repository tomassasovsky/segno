/*
 * value_text.h — a Segno plugin's parameter values as the console prints
 * them (#1815): a setting as the effect page's controls do (units and
 * decimals by its descriptor, a choice by its name), the input and output by
 * the names of their choices, the balance as its readout, the level in dB.
 *
 * The console's own strings are Dart (lib/l10n/localized.dart,
 * fxParamValueText, in English); this is their port. test/value_texts.json,
 * which test/vst3_faces writes from the Dart and keeps current, holds what
 * the console prints for every parameter of every kind at 41 settings and at
 * each position of a stepped one, and binding_test.cpp checks each plugin's
 * text against it, so the two cannot drift.
 */
#pragma once

#include <cstdint>
#include <string>

namespace segno_vst3 {

/* Parameter [id] (params.h) of a plugin of engine type [type] at
 * normalized value [v]. */
std::string valueText(int32_t type, uint32_t id, double v);

}  // namespace segno_vst3
