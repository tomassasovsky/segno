import 'package:looper_repository/src/models/track_effect.dart';

/// What one instance of each kind charges the audio thread's worst block, in
/// nanoseconds per frame: `bench_fx_cpu --table` on the console (Pi 5,
/// 96 kHz, 64-frame periods, SCHED_FIFO 70), each kind's share of the worst
/// block with eight in one chain, or one alone for a kind on the hop.
///
/// Per frame because both the cost and the budget scale with the block:
/// at another rate the same work fits a different share of real time
/// ([fxBudgetNs]).
const Map<TrackEffectType, int> kFxKindCostNs = {
  TrackEffectType.none: 0,
  TrackEffectType.drive: 0,
  TrackEffectType.filter: 0,
  TrackEffectType.delay: 0,
  TrackEffectType.tremolo: 0,
  TrackEffectType.octaver: 0,
  TrackEffectType.echo: 0,
  TrackEffectType.reverb: 0,
  TrackEffectType.eq: 0,
  TrackEffectType.compressor: 0,
  TrackEffectType.transient: 0,
  TrackEffectType.hpGate: 0,
  TrackEffectType.doubler: 0,
  TrackEffectType.chorus: 0,
  TrackEffectType.wah: 0,
  TrackEffectType.overdrive: 0,
  TrackEffectType.distortion: 0,
  TrackEffectType.vinyl: 0,
  TrackEffectType.degrade: 0,
  TrackEffectType.lpf: 0,
  TrackEffectType.spring: 0,
};

/// The octaver in PSOLA mode (its mode setting at 1), which costs more than
/// its phase vocoder ([kFxKindCostNs]).
const int kFxPsolaCostNs = 0;

/// The engine with eight tracks playing, one input monitored and no effects:
/// the console's worst block (73 us at 96 kHz, 64 frames), per frame.
const int kFxBaseCostNs = 1140;

/// The share of each block the worst block may fill (#887, Architecture 10):
/// 80 %, leaving the rest to the callback's own jitter.
const double kFxBudgetShare = 0.8;

/// The kinds whose sound changes every lap (a free-running LFO or noise),
/// which a lane never prints and so always plays live.
const Set<TrackEffectType> _freeRunning = {
  TrackEffectType.doubler,
  TrackEffectType.chorus,
  TrackEffectType.vinyl,
  TrackEffectType.degrade,
};

/// What [fx] charges, in nanoseconds per frame: its kind's
/// ([kFxKindCostNs]), whether or not it is on, so switching a pedal on is
/// never refused. A hosted plugin charges nothing here; its cost is its
/// own.
int fxEntryCostNs(TrackEffect fx) => switch (fx) {
  BuiltInEffect(:final type, :final params)
      when type == TrackEffectType.octaver && params[3] >= 0.5 =>
    kFxPsolaCostNs,
  BuiltInEffect(:final type) => kFxKindCostNs[type] ?? 0,
  PluginEffect() => 0,
};

/// What [chain] charges ([fxEntryCostNs]), in nanoseconds per frame.
int fxChainCostNs(Iterable<TrackEffect> chain) =>
    chain.fold(0, (sum, fx) => sum + fxEntryCostNs(fx));

/// What a lane's [chain] charges: its free-running kinds only. The rest
/// plays from the lane's print.
int fxLaneCostNs(Iterable<TrackEffect> chain) => fxChainCostNs(
  chain.where((fx) => fx is BuiltInEffect && _freeRunning.contains(fx.type)),
);

/// What the effects may charge in all, in nanoseconds per frame, at
/// [sampleRate]: the budget's share of a frame less the engine's own cost.
int fxBudgetNs(int sampleRate) =>
    (kFxBudgetShare * 1e9 / sampleRate).floor() - kFxBaseCostNs;
