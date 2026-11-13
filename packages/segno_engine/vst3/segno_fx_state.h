/*
 * segno_fx_state.h — the state every Segno plugin saves and restores.
 *
 * Processor::getState writes it, Processor::setState and
 * Controller::setComponentState read it, and a host stores it in its
 * project (Live: Vst3Preset/ProcessorState, hex). packages/daw_export
 * writes the same bytes for an exported take (segno_vst3_state.dart), so
 * any change here changes both, and the version moves.
 *
 * Little-endian, 4-byte fields except the beat:
 *
 *   0  char[4] magic "SGFX"
 *   4  u32     version (1)
 *   8  i32     kind: the le_fx_type this plugin runs; a state of another
 *              kind is refused
 *  12  i32     slot: the entry's index in its chain on the console
 *              (0..LE_FX_MAX - 1). Where a kind staggers its work (an
 *              octaver's hop, a kind's update cadence) and seeds its noise
 *              depends on the owner and the slot, so the plugin runs the
 *              kind on that slot.
 *  16  i32     hop seed: the chain owner's octaver hop quarter
 *              (le_fx_lane_hop_seed for a lane, le_fx_bus_hop_seed for a
 *              track's bus)
 *  20  u32     clock offset: the engine frame the host's sample 0 stands
 *              for (a take's PERF_ARMED FX clock), so clock LFOs and hops
 *              fall where the console's did
 *  24  f64     beat offset: the beat, in quarter notes, at the host's
 *              sample 0 (the arm's tempo anchor)
 *  32  i32     input: le_fx_chan_in (stereo, left, right, mono sum)
 *  36  i32     output: le_fx_chan_out (stereo, mono)
 *  40  f32     placement: balance (stereo out) or pan (mono out), -1..1
 *  44  f32     level: the entry's gain, 0..LE_FX_LEVEL_MAX
 *  48  i32     enabled: 1 on, 0 bypassed (the engine's enable bit)
 *  52  i32     n: settings that follow
 *  56  f32[n]  the kind's settings, each 0..1 (the engine's params)
 *
 * A state with fewer settings than the kind reads keeps the defaults for
 * the rest; extra ones are ignored. At most LE_FX_PARAMS settings.
 */
#pragma once

#include <cstdint>
#include <cstring>

#include "segno_engine_api.h" /* LE_FX_MAX, LE_FX_PARAMS */

namespace segno_vst3 {

constexpr uint32_t kStateVersion = 1;
constexpr int kStateHeaderBytes = 56;
constexpr int kStateMaxSlot = LE_FX_MAX - 1;
constexpr int kStateMaxParams = LE_FX_PARAMS;

struct FxPluginState {
  int32_t kind = 0;
  int32_t slot = 0;
  int32_t hopSeed = 0;
  uint32_t clockOffset = 0;
  double beatOffset = 0.0;
  int32_t input = 0;
  int32_t output = 0;
  float placement = 0.0f;
  float level = 1.0f;
  int32_t enabled = 1;
  int32_t paramCount = 0;
  float params[kStateMaxParams] = {};
};

inline void putU32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}
inline uint32_t getU32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
inline void putF32(uint8_t* p, float v) {
  uint32_t u;
  std::memcpy(&u, &v, 4);
  putU32(p, u);
}
inline float getF32(const uint8_t* p) {
  const uint32_t u = getU32(p);
  float v;
  std::memcpy(&v, &u, 4);
  return v;
}

/* The bytes of [s] into [out], which holds kStateHeaderBytes + 4 *
 * kStateMaxParams. Returns how many were written. */
inline int encodeState(const FxPluginState& s, uint8_t* out) {
  std::memcpy(out, "SGFX", 4);
  putU32(out + 4, kStateVersion);
  putU32(out + 8, (uint32_t)s.kind);
  putU32(out + 12, (uint32_t)s.slot);
  putU32(out + 16, (uint32_t)s.hopSeed);
  putU32(out + 20, s.clockOffset);
  uint64_t beat;
  std::memcpy(&beat, &s.beatOffset, 8);
  putU32(out + 24, (uint32_t)beat);
  putU32(out + 28, (uint32_t)(beat >> 32));
  putU32(out + 32, (uint32_t)s.input);
  putU32(out + 36, (uint32_t)s.output);
  putF32(out + 40, s.placement);
  putF32(out + 44, s.level);
  putU32(out + 48, (uint32_t)s.enabled);
  const int n = s.paramCount < 0 ? 0
                : s.paramCount > kStateMaxParams ? kStateMaxParams
                                                 : s.paramCount;
  putU32(out + 52, (uint32_t)n);
  for (int i = 0; i < n; ++i) putF32(out + kStateHeaderBytes + 4 * i, s.params[i]);
  return kStateHeaderBytes + 4 * n;
}

/* The number of settings the header [in] (kStateHeaderBytes) announces, or
 * -1 when it is not a state's header (wrong magic or version, a count out
 * of range). */
inline int32_t stateParamCount(const uint8_t* in) {
  if (std::memcmp(in, "SGFX", 4) != 0 || getU32(in + 4) != kStateVersion) return -1;
  const int32_t n = (int32_t)getU32(in + 52);
  return n >= 0 && n <= kStateMaxParams ? n : -1;
}

/* Reads [len] bytes of [in] into [s]: the header, then its settings.
 * Returns false for a state that is not one (wrong magic or version, a
 * count past kStateMaxParams, short). [s].params past the count are left
 * as the caller set them. */
inline bool decodeState(const uint8_t* in, int len, FxPluginState& s) {
  if (len < kStateHeaderBytes) return false;
  const int32_t n = stateParamCount(in);
  if (n < 0 || len < kStateHeaderBytes + 4 * n) return false;
  s.kind = (int32_t)getU32(in + 8);
  s.slot = (int32_t)getU32(in + 12);
  if (s.slot < 0 || s.slot > kStateMaxSlot) return false;
  s.hopSeed = (int32_t)getU32(in + 16);
  s.clockOffset = getU32(in + 20);
  const uint64_t beat =
      (uint64_t)getU32(in + 24) | ((uint64_t)getU32(in + 28) << 32);
  std::memcpy(&s.beatOffset, &beat, 8);
  s.input = (int32_t)getU32(in + 32);
  s.output = (int32_t)getU32(in + 36);
  s.placement = getF32(in + 40);
  s.level = getF32(in + 44);
  s.enabled = (int32_t)getU32(in + 48);
  s.paramCount = n;
  for (int i = 0; i < s.paramCount; ++i) {
    s.params[i] = getF32(in + kStateHeaderBytes + 4 * i);
  }
  return true;
}

/* Reads a whole state from [read], a function that reads up to [size]
 * bytes into [into] and returns how many it read: the header first, then
 * exactly the settings it announces, so a host's stream is never asked for
 * more than the state holds. */
template <typename Read>
inline bool readState(Read read, FxPluginState& s) {
  uint8_t bytes[kStateHeaderBytes + 4 * kStateMaxParams];
  if (read(bytes, kStateHeaderBytes) != kStateHeaderBytes) return false;
  const int32_t n = stateParamCount(bytes);
  if (n < 0) return false;
  if (n > 0 && read(bytes + kStateHeaderBytes, 4 * n) != 4 * n) return false;
  return decodeState(bytes, kStateHeaderBytes + 4 * n, s);
}

}  // namespace segno_vst3
