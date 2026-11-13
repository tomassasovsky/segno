/*
 * params.h — the parameters of a Segno plugin, and how each maps onto the
 * engine entry it runs.
 *
 * Ids 0 to n - 1 are the kind's settings, in the engine's order: id p is
 * params[p] of the chain entry (le_fx_param_info(type, p)), and its
 * normalized value IS the engine's 0..1 setting, with no conversion. So an
 * engine parameter's identity (entry, index) is the plugin's parameter id,
 * and automation of a setting in a host addresses what the console logs as
 * LE_PLOG_SET_LANE_FX_PARAM for the same index.
 *
 * The entry's channel handling (FxChannels) and its enable bit follow at
 * fixed ids past every kind's settings:
 *
 *   1000 Input      le_fx_chan_in: stereo, left, right, mono sum (k / 3)
 *   1001 Output     le_fx_chan_out: stereo, mono (k / 1)
 *   1002 Placement  balance or pan, -1..1 as (x + 1) / 2
 *   1003 Level      0..LE_FX_LEVEL_MAX as level / LE_FX_LEVEL_MAX
 *   1100 Bypass     the engine's enable bit, inverted (kIsBypass)
 *
 * The bypass runs the engine's own switch: a delay or reverb drains its
 * tail, every other kind crossfades over LE_FX_ENABLE_RAMP_MS.
 */
#pragma once

#include <cmath>
#include <cstdint>

#include "pluginterfaces/vst/vsttypes.h"

namespace segno_vst3 {

enum : Steinberg::Vst::ParamID {
  kInputId = 1000,
  kOutputId = 1001,
  kPlacementId = 1002,
  kLevelId = 1003,
  kBypassId = 1100,
};

constexpr float kLevelMax = 4.0f; /* LE_FX_LEVEL_MAX */

inline int32_t inputFromNormalized(double v) {
  const long k = std::lround(v * 3.0);
  return (int32_t)(k < 0 ? 0 : k > 3 ? 3 : k);
}
inline double inputToNormalized(int32_t k) { return k / 3.0; }
inline int32_t outputFromNormalized(double v) { return v >= 0.5 ? 1 : 0; }
inline double outputToNormalized(int32_t k) { return k != 0 ? 1.0 : 0.0; }
inline float placementFromNormalized(double v) { return (float)(v * 2.0 - 1.0); }
inline double placementToNormalized(float p) { return ((double)p + 1.0) / 2.0; }
inline float levelFromNormalized(double v) { return (float)(v * kLevelMax); }
inline double levelToNormalized(float l) { return (double)l / kLevelMax; }

}  // namespace segno_vst3
