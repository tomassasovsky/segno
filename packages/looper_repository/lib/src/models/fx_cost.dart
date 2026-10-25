import 'package:looper_repository/src/models/track_effect.dart';

/// What one instance of each kind charges the audio thread's worst block, in
/// nanoseconds per frame (96 kHz, 64-frame periods): each kind's share of
/// the worst block with eight in one chain, or one alone for a kind on the
/// hop (`bench_fx_cpu --table`).
///
/// Measured on the console (Pi 5, SCHED_FIFO 70) where a console bench
/// exists: the overdrive,
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
  // On the hop: charged per block ([kFxHopCostUs]), not per frame.
  TrackEffectType.octaver: 0,
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
  // The console's 55 for the still filter, x 1.08: the swept one (its
  // ladder redesigned every sample) over the still one on CI arm64.
  TrackEffectType.lpf: 59,
  TrackEffectType.spring: 95,
  // CI arm64, an eighth of eight in one chain (6.2 and 6.1 us), x 1.75.
  TrackEffectType.dubVerb: 170,
  TrackEffectType.ambVerb: 167,
  // On the hop, as the octaver whose kernel it runs ([kFxHopCostUs]).
  TrackEffectType.whammy: 0,
  TrackEffectType.dualOctaver: 0,
  // As the tremolo, which it matches eight for eight on the bench.
  TrackEffectType.pumper: 37,
  // CI arm64, an eighth of eight in one chain (2.5 us, AB<< at 1/4T so its
  // reads land far back in the ring), x 1.75.
  TrackEffectType.slicer: 68,
  // CI arm64, an eighth of eight in one chain (2.15 us, RES LO L/R at 1/4
  // with both taps voiced), x 1.75, scaled by the Dub voicing's heaviest
  // case: gliding Res-Freq at L/R Ratio 50 %, which redesigns its filters
  // every 32 frames, runs 4.89 us an instance where RES LO L/R runs 3.93
  // in the same run (#1477).
  TrackEffectType.modeDelay: 73,
  // CI arm64, an eighth of eight in one chain (13.75 us, drive 93.5 % on
  // the 4x12"), x 1.75. A cabinet change runs both cabinets for 1024
  // frames, about a third more for those blocks.
  TrackEffectType.ampCab: 376,
  // CI arm64, an eighth of eight in one chain while their settings move
  // (3.27 us, the phaser at full depth, its heaviest mode), x 1.75. A mode
  // change runs both modes for 1024 frames.
  TrackEffectType.mod: 90,
};

/// What a kind on the hop charges, in microseconds a block: its frame's work
/// is split across the blocks of its hop by quarters, so a quarter lands in
/// one block whatever the block's length below 64 frames. The octaver's
/// phase vocoder is 69 us alone on the console after the hop split; PSOLA
/// 84 us with the YIN slicing (#913).
const Map<TrackEffectType, double> kFxHopCostUs = {
  TrackEffectType.octaver: 69,
  // The octaver's phase vocoder, its settings mapped; CI measures the two
  // alike (41 against 40 us alone).
  TrackEffectType.whammy: 69,
  // The octaver's phase vocoder, its settings mapped. Octave 2's shift runs
  // in the quarter the octaver spends on its envelope when it holds the
  // formants (the Dual Octaver moves them), and both voices share one
  // inverse FFT, so the heaviest quarter stays the octaver's.
  TrackEffectType.dualOctaver: 69,
};

/// The octaver in PSOLA mode (its mode setting at 1), per block.
const double kFxPsolaCostUs = 84;

/// The engine with eight tracks playing, one input monitored and no effects:
/// the console's worst block, 73 us at 96 kHz, mostly per block.
const double kFxBaseCostUs = 73;

/// The block the per-frame charges were measured at.
const int kFxBenchPeriod = 64;

/// The share of each block the worst block may fill (#887, Architecture 10):
/// 80 %, leaving the rest to the callback's own jitter.
const double kFxBudgetShare = 0.8;

/// What [fx] charges, in nanoseconds per frame at [period]-frame blocks:
/// its kind's ([kFxKindCostNs], or [kFxHopCostUs] spread over the block),
/// whether or not it is on, so switching a pedal on is never refused. A
/// hosted plugin charges nothing here; its cost is its own.
int fxEntryCostNs(TrackEffect fx, {int period = kFxBenchPeriod}) {
  if (fx is! BuiltInEffect) return 0;
  final hop = fx.type == TrackEffectType.octaver && fx.params[3] >= 0.5
      ? kFxPsolaCostUs
      : kFxHopCostUs[fx.type];
  if (hop != null) return (hop * 1000 / _perBlock(period)).ceil();
  return kFxKindCostNs[fx.type] ?? 0;
}

/// What [chain] charges ([fxEntryCostNs]), in nanoseconds per frame.
int fxChainCostNs(
  Iterable<TrackEffect> chain, {
  int period = kFxBenchPeriod,
}) => chain.fold(0, (sum, fx) => sum + fxEntryCostNs(fx, period: period));

/// What the effects may charge in all, in nanoseconds per frame, at
/// [sampleRate] and [period]-frame blocks: the budget's share of a frame
/// less the engine's own cost.
int fxBudgetNs(int sampleRate, {int period = kFxBenchPeriod}) =>
    (kFxBudgetShare * 1e9 / sampleRate).floor() -
    (kFxBaseCostUs * 1000 / _perBlock(period)).ceil();

/// The frames a per-block cost spreads over: the block below the bench's
/// 64, where a hop quarter and the engine's fixed work land in every
/// block; the bench's 64 above it, where a longer block runs several hop
/// stages and mixes proportionally more (engine_fx.h, LE_PV_HOP).
int _perBlock(int period) =>
    period > 0 && period < kFxBenchPeriod ? period : kFxBenchPeriod;
