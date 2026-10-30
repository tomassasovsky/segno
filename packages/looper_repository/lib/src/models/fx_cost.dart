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
  // On the hop, charged per block ([kFxHopCostUs]).
  TrackEffectType.whammy: 0,
  TrackEffectType.dualOctaver: 0,
  TrackEffectType.smartTune: 0,
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
  // CI arm64, an eighth of eight in one chain while their settings move
  // (23.5 us, BOX, the most early taps, its Length gliding), x 1.75. Still,
  // the same eight run 13.5 us an instance.
  TrackEffectType.roomVerb: 643,
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
  // The octaver's phase vocoder with both voices, and its low band (#1467:
  // a crossover, two taps and a sliced pitch detection on every sample),
  // on a bass line in its heaviest setting (High Mode off, the band
  // playing; on, the band only listens). CI arm64, one instance alone
  // (44.6 us), x 1.75 and rounded up, until the console's own table
  // replaces it.
  TrackEffectType.dualOctaver: 79,
  // The octaver's PSOLA, its shift worked out once a detection lands.
  TrackEffectType.smartTune: kFxPsolaCostUs,
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

/// What handing the monitor chains to the effects workers costs the
/// callback's block, in microseconds, by the number of workers (#1515): the
/// wake, the claims and the join (2.5 us a block in the spike), plus the time
/// the workers lose to their late start, shared by every core
/// (docs/plan/2026-10-29-feat-multicore-effects-plan.md, section 7: 70, 81
/// and 97 ns a frame at 64-frame blocks).
const Map<int, double> kFxHandoffUs = {1: 4.48, 2: 5.184, 3: 6.208};

/// What the effects charge the audio thread's worst block, in nanoseconds
/// per frame, at [period]-frame blocks with [workers] effects workers
/// beside the callback (#1515): the chains that stay on the callback
/// ([serial]) plus the critical path of the [jobs], the chains the workers
/// share (one monitor input's chain each).
///
/// With C cores (the callback and the workers) any greedy claiming finishes
/// the jobs within J/C + (1 - 1/C) p of their release (Graham's bound for
/// list scheduling, in any order), J their sum and p the largest, plus the
/// handoff ([kFxHandoffUs]). One job's work never splits across cores, which
/// the second term pays for. With no workers, or fewer than two jobs (the
/// engine then runs them on the callback), it is every chain summed: the
/// rule before #1515.
int fxLoadNs({
  required int serial,
  required Iterable<int> jobs,
  int workers = 0,
  int period = kFxBenchPeriod,
}) {
  final costs = [
    for (final job in jobs)
      if (job > 0) job,
  ];
  final sum = costs.fold(0, (a, b) => a + b);
  final handoffUs = kFxHandoffUs[workers > 3 ? 3 : workers];
  if (handoffUs == null || costs.length < 2) return serial + sum;
  final cores = workers + 1;
  final largest = costs.reduce((a, b) => a > b ? a : b);
  final handoff = (handoffUs * 1000 / _perBlock(period)).ceil();
  final path = (sum + (cores - 1) * largest + cores - 1) ~/ cores;
  return serial + handoff + path;
}

/// The frames a per-block cost spreads over: the block below the bench's
/// 64, where a hop quarter and the engine's fixed work land in every
/// block; the bench's 64 above it, where a longer block runs several hop
/// stages and mixes proportionally more (engine_fx.h, LE_PV_HOP).
int _perBlock(int period) =>
    period > 0 && period < kFxBenchPeriod ? period : kFxBenchPeriod;
