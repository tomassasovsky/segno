import 'package:looper_repository/src/models/track_effect.dart';

/// The settings the console's cost tables were measured at, in the order of
/// each table's figures ([kFxKindCostNs], [kFxPsolaCostNs], [kFxBaseUs]):
/// 44.1, 48, 88.2 and 96 kHz, each at 32- and 64-frame periods. A device is
/// charged at the one it runs at ([fxCostSetting]), not at the worst of the
/// eight (#1724).
const List<({int rate, int period})> kFxCostSettings = [
  (rate: 44100, period: 32),
  (rate: 44100, period: 64),
  (rate: 48000, period: 32),
  (rate: 48000, period: 64),
  (rate: 88200, period: 32),
  (rate: 88200, period: 64),
  (rate: 96000, period: 32),
  (rate: 96000, period: 64),
];

/// What one instance of each kind charges the audio thread's worst block, in
/// nanoseconds per frame, at each of [kFxCostSettings]: each kind's share of
/// the worst block with eight in one chain (`bench_fx_cpu --table`), the
/// larger of one instance's p99 increment over the empty chain and an eighth
/// of eight's.
///
/// Measured on the console (Pi 5, SCHED_FIFO 70, segno.service stopped,
/// `bench_fx_cpu --paced --cpu 3 --table --blocks 2000 --rate R --period P`)
/// for #1508, and again at 48 kHz / 32 for #1724; where a setting was run
/// more than once, the larger figure stays the charge: the console did run
/// that block. Where a kind's heaviest use is not the table's still chain,
/// the charge is the heavier scenario's (`bench_fx_cpu --kind`, its chain
/// and moving runs, measured the same way): the LPF swept by its LFO
/// (`lpflfo`), the Mode delay's Dub voicing gliding (`dubdelay`), the Mod
/// and the Room reverb with their settings moving. The Overdrive, the Amp
/// and the High-pass changed after #1508 (#1663, #1664, #1644) and charge
/// only #1724's runs.
///
/// Per frame because both the cost and the budget scale with the block. A
/// kind on the hop (the octaver, the Whammy, the Dual Octaver) does a quarter
/// of its hop in a block up to 64 frames, and two at 44.1 kHz / 64, so its
/// figure per frame is larger at 32 frames than at 64; one that runs
/// oversampled (the Overdrive, the Distortion, the Vinyl, the Amp) runs
/// fewer times over at 88.2 kHz and up (#1547). Both are in the measured figures. The octaver
/// in PSOLA mode and the Smart Tune charge [kFxPsolaCostNs].
const Map<TrackEffectType, List<int>> kFxKindCostNs = {
  TrackEffectType.none: [0, 0, 0, 0, 0, 0, 0, 0],
  TrackEffectType.drive: [34, 32, 31, 35, 30, 32, 24, 29],
  TrackEffectType.filter: [166, 122, 130, 122, 123, 123, 122, 124],
  TrackEffectType.delay: [42, 37, 40, 37, 39, 42, 32, 36],
  TrackEffectType.tremolo: [52, 47, 49, 48, 47, 48, 41, 47],
  TrackEffectType.octaver: [2172, 2016, 2048, 969, 1942, 1182, 1923, 1140],
  TrackEffectType.echo: [144, 134, 137, 140, 135, 136, 137, 135],
  TrackEffectType.reverb: [176, 234, 139, 123, 199, 179, 170, 139],
  TrackEffectType.eq: [88, 86, 84, 83, 85, 83, 84, 81],
  TrackEffectType.compressor: [76, 69, 71, 71, 70, 70, 63, 68],
  TrackEffectType.transient: [73, 67, 69, 68, 79, 72, 62, 67],
  TrackEffectType.hpGate: [69, 96, 122, 60, 72, 66, 79, 80],
  TrackEffectType.doubler: [50, 52, 48, 44, 44, 44, 39, 44],
  TrackEffectType.chorus: [78, 65, 72, 66, 65, 66, 59, 64],
  TrackEffectType.wah: [60, 34, 37, 36, 36, 36, 29, 34],
  TrackEffectType.overdrive: [904, 861, 903, 860, 522, 513, 540, 533],
  TrackEffectType.distortion: [400, 393, 407, 392, 248, 247, 266, 272],
  TrackEffectType.vinyl: [381, 374, 375, 374, 201, 200, 192, 203],
  TrackEffectType.degrade: [59, 38, 40, 39, 39, 39, 66, 103],
  TrackEffectType.lpf: [176, 191, 200, 144, 276, 143, 147, 141],
  TrackEffectType.spring: [103, 96, 116, 93, 99, 98, 108, 104],
  TrackEffectType.dubVerb: [208, 211, 212, 221, 218, 206, 193, 216],
  TrackEffectType.ambVerb: [272, 246, 196, 205, 221, 268, 229, 216],
  TrackEffectType.whammy: [2049, 1503, 1846, 965, 1933, 1170, 1852, 1151],
  TrackEffectType.dualOctaver: [2174, 1584, 1942, 1110, 2009, 1210, 1950, 1154],
  TrackEffectType.pumper: [63, 60, 62, 62, 57, 61, 55, 60],
  TrackEffectType.slicer: [101, 99, 103, 103, 93, 102, 85, 101],
  TrackEffectType.modeDelay: [172, 179, 169, 153, 157, 158, 160, 158],
  TrackEffectType.ampCab: [632, 563, 579, 491, 663, 479, 700, 504],
  TrackEffectType.mod: [88, 76, 113, 75, 179, 105, 113, 80],
  TrackEffectType.roomVerb: [660, 677, 735, 642, 829, 674, 669, 660],
  // PSOLA only: kFxPsolaCostNs.
  TrackEffectType.smartTune: [0, 0, 0, 0, 0, 0, 0, 0],
};

/// What the PSOLA kinds charge, in nanoseconds per frame at each of
/// [kFxCostSettings]: the octaver in PSOLA mode (its mode setting at 1) and
/// the Smart Tune, the larger of the two, measured as [kFxKindCostNs] is.
/// Their kernel runs at 48 kHz at every rate (#1547), so a frame at 88.2 kHz
/// and up carries about half a kernel sample.
const List<int> kFxPsolaCostNs = [
  2380,
  2299,
  1949,
  1865,
  1387,
  1328,
  1221,
  1225,
];

/// The engine with eight tracks playing, one input monitored and no effects:
/// the console's worst block (the table's base p99), in microseconds, at
/// each of [kFxCostSettings], measured as [kFxKindCostNs] is.
const List<double> kFxBaseUs = [42.3, 74.8, 45.4, 73.5, 43.1, 74.4, 43.8, 75.9];

/// The block a per-block cost is spread over at most ([_perBlock]), and the
/// block the charges default to.
const int kFxBenchPeriod = 64;

/// The share of each block the worst block may fill (#1724): 75 %.
///
/// Set from the console's measured p99.9 with a safety margin of a tenth of
/// the block. In the app at 48 kHz / 32 (build 236, four of Ed's Racks on
/// two inputs, four takes playing, the screens drawing), the audio thread's
/// p99.9 service was 1.18 times what this file charges for the same rig,
/// its own base included: the app's ALSA I/O, its playback and the screens'
/// memory traffic cost the callback more than the bench's engine does. A
/// share s puts the p99.9 at 1.18 s of the block at the limit; 0.9 / 1.18
/// is 0.76, rounded down to 0.75. The engine counts the services past it
/// (`over_share_periods`, LE_CB_OVER_SHARE_NUM / DEN).
const double kFxBudgetShare = 0.75;

/// The rate the charges default to.
const int kFxBenchRate = 96000;

/// Which of [kFxCostSettings] a device at [sampleRate] and [period]-frame
/// blocks is charged at: the measured rate nearest to [sampleRate], at 32
/// frames below 64 and at 64 from there ([_perBlock]: a longer block costs
/// no more per frame). The Device page offers no block below 32
/// (AudioSetupState.bufferSizes).
int fxCostSetting(int sampleRate, int period) {
  final rate = sampleRate > 0 ? sampleRate : kFxBenchRate;
  final frames = _perBlock(period) < kFxBenchPeriod ? 32 : kFxBenchPeriod;
  int distance(int i) => (kFxCostSettings[i].rate - rate).abs();
  var best = -1;
  for (var i = 0; i < kFxCostSettings.length; i++) {
    if (kFxCostSettings[i].period != frames) continue;
    if (best < 0 || distance(i) < distance(best)) best = i;
  }
  return best;
}

/// What [fx] charges, in nanoseconds per frame at [sampleRate] and
/// [period]-frame blocks: its kind's figure at that setting
/// ([kFxKindCostNs], or [kFxPsolaCostNs] for PSOLA), whether or not it is
/// on, so switching a pedal on is never refused. A hosted plugin charges
/// nothing here; its cost is its own.
int fxEntryCostNs(
  TrackEffect fx, {
  int period = kFxBenchPeriod,
  int sampleRate = kFxBenchRate,
}) {
  if (fx is! BuiltInEffect) return 0;
  final at = fxCostSetting(sampleRate, period);
  final psola =
      fx.type == TrackEffectType.smartTune ||
      (fx.type == TrackEffectType.octaver && fx.params[3] >= 0.5);
  if (psola) return kFxPsolaCostNs[at];
  return kFxKindCostNs[fx.type]?[at] ?? 0;
}

/// What [chain] charges ([fxEntryCostNs]), in nanoseconds per frame.
int fxChainCostNs(
  Iterable<TrackEffect> chain, {
  int period = kFxBenchPeriod,
  int sampleRate = kFxBenchRate,
}) => chain.fold(
  0,
  (sum, fx) => sum + fxEntryCostNs(fx, period: period, sampleRate: sampleRate),
);

/// What the effects may charge in all, in nanoseconds per frame, at
/// [sampleRate] and [period]-frame blocks: the budget's share of a frame
/// less the engine's own cost.
int fxBudgetNs(int sampleRate, {int period = kFxBenchPeriod}) =>
    (kFxBudgetShare * 1e9 / sampleRate).floor() -
    fxBaseNs(sampleRate, period: period);

/// What the engine itself charges the worst block, in nanoseconds per frame
/// at [sampleRate] and [period]-frame blocks ([kFxBaseUs]).
int fxBaseNs(int sampleRate, {int period = kFxBenchPeriod}) {
  final us = kFxBaseUs[fxCostSetting(sampleRate, period)];
  return (us * 1000 / _perBlock(period)).ceil();
}

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
/// share (one monitor input's non-empty chain each).
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
  // Every chain is a job, a free one too (a hosted plugin, a rack of
  // passthroughs): the engine releases a round for it all the same.
  final costs = jobs.toList();
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
