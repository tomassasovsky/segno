import 'package:looper_repository/src/models/track_effect.dart';

/// What one instance of each kind charges the audio thread's worst block, in
/// nanoseconds per frame (96 kHz, 64-frame periods): each kind's share of
/// the worst block with eight in one chain, or one alone for a kind on the
/// hop (`bench_fx_cpu --table`).
///
/// Measured on the console (Pi 5, SCHED_FIFO 70) where a console bench
/// exists: the octaver (69 us alone after the hop split), the overdrive,
/// distortion, vinyl, degrade, LPF and spring (#1433). The rest are the
/// arm64 CI runner's table times 1.75, the console's ratio to it on the
/// octaver and on the rig itself, until the console's own table replaces
/// them.
///
/// Per frame because both the cost and the budget scale with the block: at
/// another rate the same work fits a different share of real time
/// ([fxBudgetNs]).
const Map<TrackEffectType, int> kFxKindCostNs = {
  TrackEffectType.none: 0,
  TrackEffectType.drive: 84,
  TrackEffectType.filter: 110,
  TrackEffectType.delay: 28,
  TrackEffectType.tremolo: 37,
  TrackEffectType.octaver: 1078,
  TrackEffectType.echo: 142,
  TrackEffectType.reverb: 156,
  TrackEffectType.eq: 63,
  TrackEffectType.compressor: 56,
  TrackEffectType.transient: 46,
  TrackEffectType.hpGate: 33,
  TrackEffectType.doubler: 40,
  TrackEffectType.chorus: 67,
  TrackEffectType.wah: 30,
  TrackEffectType.overdrive: 122,
  TrackEffectType.distortion: 227,
  TrackEffectType.vinyl: 97,
  TrackEffectType.degrade: 47,
  TrackEffectType.lpf: 55,
  TrackEffectType.spring: 95,
};

/// The octaver in PSOLA mode (its mode setting at 1): 84 us alone on the
/// console with the YIN slicing (#913), 1.25 times its phase vocoder.
const int kFxPsolaCostNs = 1350;

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
