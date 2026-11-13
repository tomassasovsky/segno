/*
 * processor.h — a Segno plugin's audio processor: one built-in effect kind
 * run by the engine's own effects island (engine_fx.c).
 *
 * It runs the kind on a slot of its own (fx_slot.h), set up the way the
 * offline render (perf_render.c) sets up a slot that holds an effect at
 * arm: its buffers prepared, the slot reset, a Pumper's glide or an
 * octaver's smoothers settled at its settings, its enable ramp settled at
 * its enable bit, and its channel handling on the slot. Every frame runs
 * fx_apply_chain on the slot clocked as the engine clocks a chain, so a
 * render here is the engine's render of the same input.
 *
 * The clock is the host's sample position plus the state's clock offset
 * while the host plays, and counts on by itself while it does not; the
 * tempo follows the host's. So with the offset and beat of a take (written
 * by a Live export) a clock LFO, an octaver's hops and a beat-locked kind
 * fall where the console's did.
 */
#pragma once

#include <mutex>

#include "fx_slot.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "segno_fx_kinds.h"
#include "segno_fx_state.h"

namespace segno_vst3 {

class Processor : public Steinberg::Vst::AudioEffect {
 public:
  explicit Processor(const FxKind* kind);
  ~Processor() SMTG_OVERRIDE;

  /* [context] is the FxKind the factory registered the class with. */
  static Steinberg::FUnknown* createInstance(void* context);

  Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API terminate() SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setBusArrangements(
      Steinberg::Vst::SpeakerArrangement* inputs, Steinberg::int32 numIns,
      Steinberg::Vst::SpeakerArrangement* outputs,
      Steinberg::int32 numOuts) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API canProcessSampleSize(
      Steinberg::int32 symbolicSampleSize) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setupProcessing(
      Steinberg::Vst::ProcessSetup& setup) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setActive(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE;
  Steinberg::uint32 PLUGIN_API getTailSamples() SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;

 private:
  /* The slot from scratch at the current state, as the offline render
   * makes one per stem. Allocates; never on the audio thread while it
   * runs. */
  bool build();
  void freeSlot();
  /* The state's channel handling onto the slot. */
  void applyChannels();
  /* One parameter change, at the frame it lands on. */
  void applyParam(Steinberg::Vst::ParamID id, double value);
  /* The host's position and tempo at the block's first frame [base]. */
  void followHost(const Steinberg::Vst::ProcessContext* ctx, uint32_t base,
                  bool moved);

  const FxKind* kind_;
  int32_t width_ = 0;
  int32_t sr_ = 48000;
  FxPluginState state_;
  /* A state the host handed over while the slot runs: process() takes it
   * at its next block. */
  FxPluginState pending_;
  bool hasPending_ = false;
  std::mutex pendingLock_;

  segno_fx_slot* slot_ = nullptr;
  /* The slot's tempo: quarter notes a frame and the time signature. */
  float qpf_ = 0.0f;
  int32_t num_ = 4;
  int32_t den_ = 4;
  /* The clock the next block starts on when the host gives no position. */
  uint32_t nextClock_ = 0;
  bool wasPlaying_ = false;
};

}  // namespace segno_vst3
