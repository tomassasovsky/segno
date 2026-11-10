import 'package:looper_repository/src/models/track_effect.dart';

/// What one instance of each kind charges the audio thread's worst block, in
/// nanoseconds per frame: each kind's share of the worst block with eight in
/// one chain (`bench_fx_cpu --table`).
///
/// Measured on the console (Pi 5, SCHED_FIFO 70, segno.service stopped,
/// `bench_fx_cpu --paced --cpu 3 --table --blocks 2000`, #1508) at 44.1, 48,
/// 88.2 and 96 kHz, each at 32- and 64-frame periods, and charged the
/// largest of the eight, so admission is not under-charged at any of them.
/// A figure stays the charge even when a rerun of the same run came back
/// lower (the reverb's 234 and the wah's 51 at 44.1 kHz, the filter's 138
/// at 44.1 kHz / 32, the Degrade's 103 at 96 kHz / 64): the console did run
/// that block. Where a kind's heaviest use is not the table's still chain (the
/// swept LPF, the Mode delay's Dub voicing, a moving Mod or Room reverb),
/// the charge is the heavier scenario's, from `bench_fx_cpu
/// --kind`, measured the same way.
///
/// Per frame because both the cost and the budget scale with the block: at
/// another rate the same work fits a different share of real time
/// ([fxBudgetNs]). The kinds that run oversampled charge by the rate
/// instead ([kFxOversampledCostNs]), and so do the PSOLA kinds
/// ([kFxPsolaCostNs]); the phase-vocoder kinds charge per hop quarter
/// ([kFxHopCostUs]).
const Map<TrackEffectType, int> kFxKindCostNs = {
  TrackEffectType.none: 0,
  TrackEffectType.drive: 35,
  TrackEffectType.filter: 138,
  TrackEffectType.delay: 42,
  TrackEffectType.tremolo: 52,
  // On the hop: charged per quarter ([kFxHopCostUs]), not per frame.
  TrackEffectType.octaver: 0,
  TrackEffectType.echo: 144,
  TrackEffectType.reverb: 234,
  TrackEffectType.eq: 88,
  TrackEffectType.compressor: 76,
  TrackEffectType.transient: 79,
  TrackEffectType.hpGate: 45,
  TrackEffectType.doubler: 52,
  TrackEffectType.chorus: 78,
  TrackEffectType.wah: 51,
  // The overdrive, distortion and vinyl run oversampled, and their charge
  // depends on the rate: kFxOversampledCostNs.
  // At 96 kHz / 64, where a rerun measured 73 still and 88 with its hold
  // moving; about 40 at 44.1 and 48 kHz.
  TrackEffectType.degrade: 103,
  // Swept by its LFO, which redesigns the ladder every sample (`--kind
  // lpflfo` at 44.1 kHz); still, 128 at most.
  TrackEffectType.lpf: 145,
  TrackEffectType.spring: 108,
  TrackEffectType.dubVerb: 221,
  TrackEffectType.ambVerb: 272,
  // On the hop ([kFxHopCostUs]), or PSOLA ([kFxPsolaCostNs]).
  TrackEffectType.whammy: 0,
  TrackEffectType.dualOctaver: 0,
  TrackEffectType.smartTune: 0,
  TrackEffectType.pumper: 63,
  // AB<< at 1/4T, so its reads land far back in the ring.
  TrackEffectType.slicer: 103,
  // The Dub voicing's heaviest case (`--kind dubdelay` at 44.1 kHz, moving):
  // gliding Res-Freq at L/R Ratio 50 %, which redesigns its filters every 32
  // frames (#1477). Still, RES LO L/R charges 118 at most and the Dub 115.
  TrackEffectType.modeDelay: 169,
  // The Amp+Cab's clipper runs oversampled: kFxOversampledCostNs.
  // The phaser at full depth, its heaviest mode, still or with its settings
  // moving (`--kind mod`). A mode change runs both modes for 1024 frames.
  TrackEffectType.mod: 81,
  // BOX, the most early taps, its Length gliding (`--kind roomverb`,
  // moving). Still, the same eight charge 420 at most.
  TrackEffectType.roomVerb: 685,
};

/// What the waveshapers that run oversampled (#1547) charge, in nanoseconds
/// per frame: `low` at 44.1 and 48 kHz, `high` at 88.2 kHz and up, where
/// they run fewer times over (8x and 4x the Overdrive and the Amp+Cab's
/// clipper, 4x and 2x the Vinyl, 2x and 1x the Distortion; engine_fx.c,
/// le_os_stages).
///
/// Measured on the console as [kFxKindCostNs] is: `low` the largest of
/// 44.1 and 48 kHz at 32- and 64-frame periods, `high` of 88.2 and 96 kHz.
/// The Amp+Cab's cabinet runs twice the taps at 96 kHz.
///
/// The overdrive's figures are its console figures (812 and 481) scaled by
/// what its small-signal refit (#1663: two one-poles around the clipped
/// part at the curve's rate, and the tone's shelf and bell) added on an
/// M4 Pro, the larger of two runs: 1.11 times at 44.1 and 48 kHz and 1.15
/// times at 96 kHz, until the console measures them again.
const Map<TrackEffectType, ({int low, int high})> kFxOversampledCostNs = {
  TrackEffectType.overdrive: (low: 905, high: 555),
  TrackEffectType.distortion: (low: 400, high: 272),
  TrackEffectType.vinyl: (low: 381, high: 203),
  TrackEffectType.ampCab: (low: 434, high: 441),
};

/// What the PSOLA kinds charge, in nanoseconds per frame: the octaver in
/// PSOLA mode (its mode setting at 1) and the Smart Tune, the octaver's
/// PSOLA with its shift worked out once a detection lands. Their kernel runs
/// at 48 kHz at every rate (#1547) and works on every kernel sample, so they
/// cost per frame by the rate, not per hop: `low` at 44.1 and 48 kHz, `high`
/// at 88.2 kHz and up, where a frame carries about half a kernel sample.
/// Measured on the console as [kFxKindCostNs] is, but as a kind on the hop:
/// the larger of one instance's increment and an eighth of eight's, per
/// frame, the larger of the two kinds; `low` the largest of 44.1 and 48 kHz
/// at 32 and 64 frames, `high` of 88.2 and 96 kHz.
const ({int low, int high}) kFxPsolaCostNs = (low: 2380, high: 1387);

/// What a phase-vocoder kind charges, in microseconds for each quarter of
/// its hop that lands in a block. Its kernel runs at 48 kHz at every rate
/// (#1547) and does a hop's frame work by quarters, one every
/// [kFxHopQuarterFrames] kernel samples, so a block up to 64 frames takes one
/// quarter at 48 kHz and up but can take two at 44.1 kHz, where a 64-frame
/// block carries 69.7 kernel samples ([fxEntryCostNs]).
///
/// Measured on the console as [kFxKindCostNs] is: the larger of one
/// instance's increment and an eighth of eight's, the largest of the runs
/// where a block takes one quarter (all but 44.1 kHz / 64; 88.2 kHz / 64 is
/// the heaviest). At 44.1 kHz / 64 the octaver, which takes two, measures
/// 129 us.
const Map<TrackEffectType, double> kFxHopCostUs = {
  // The phase vocoder.
  TrackEffectType.octaver: 76,
  // The octaver's phase vocoder, its settings mapped.
  TrackEffectType.whammy: 75,
  // The octaver's phase vocoder with both voices, and its low band (#1467:
  // a crossover, two taps and a sliced pitch detection on every sample),
  // on a bass line in its heaviest setting (High Mode off, the band
  // playing; on, the band only listens).
  TrackEffectType.dualOctaver: 78,
};

/// The pitch kinds' kernel rate (engine_fx.c, fx_octaver_run).
const int kFxPitchKernelRate = 48000;

/// The kernel samples between two quarters of the phase vocoder's hop
/// (LE_PV_HOP / 4).
const int kFxHopQuarterFrames = 64;

/// The engine with eight tracks playing, one input monitored and no effects:
/// the console's worst block, a fixed part and a part for each frame, in
/// microseconds. Fitted to the largest of 44.1, 48, 88.2 and 96 kHz: 44 us
/// at 32 frames (43.8 measured) and 76 us at 64 (75.9 measured).
const double kFxBaseFixedUs = 12;

/// The engine's worst block's part for each frame ([kFxBaseFixedUs]).
const double kFxBaseFrameUs = 1;

/// The block a per-block cost is spread over at most ([_perBlock]), and the
/// block the charges default to.
const int kFxBenchPeriod = 64;

/// The share of each block the worst block may fill (#887, Architecture 10):
/// 80 %, leaving the rest to the callback's own jitter.
const double kFxBudgetShare = 0.8;

/// The rate the charges default to.
const int kFxBenchRate = 96000;

/// What [fx] charges, in nanoseconds per frame at [sampleRate] and
/// [period]-frame blocks: its kind's ([kFxKindCostNs], [kFxOversampledCostNs]
/// or [kFxPsolaCostNs] at the rate, or [kFxHopCostUs] for each hop quarter a
/// block can take, spread over the block): what one instance costs while it
/// runs. Which instances the rig is charged for, those on and those a control
/// can turn on, is the repository's (`LooperRepository.fxCostNs`, #1723). A
/// hosted plugin charges nothing here; its cost is its own.
int fxEntryCostNs(
  TrackEffect fx, {
  int period = kFxBenchPeriod,
  int sampleRate = kFxBenchRate,
}) {
  if (fx is! BuiltInEffect) return 0;
  final rate = sampleRate > 0 ? sampleRate : kFxBenchRate;
  final low = rate < 88200;
  final psola =
      fx.type == TrackEffectType.smartTune ||
      (fx.type == TrackEffectType.octaver && fx.params[3] >= 0.5);
  if (psola) return low ? kFxPsolaCostNs.low : kFxPsolaCostNs.high;
  final hop = kFxHopCostUs[fx.type];
  if (hop != null) {
    final frames = _perBlock(period);
    final kernel = frames * kFxPitchKernelRate / rate;
    final quarters = (kernel / kFxHopQuarterFrames).ceil();
    return (hop * 1000 * quarters / frames).ceil();
  }
  final oversampled = kFxOversampledCostNs[fx.type];
  if (oversampled != null) return low ? oversampled.low : oversampled.high;
  return kFxKindCostNs[fx.type] ?? 0;
}

/// What [chain] charges with every entry in it running ([fxEntryCostNs]),
/// in nanoseconds per frame.
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
    (kFxBudgetShare * 1e9 / sampleRate).floor() - fxBaseNs(period);

/// What the engine itself charges the worst block, in nanoseconds per frame
/// at [period]-frame blocks ([kFxBaseFixedUs], [kFxBaseFrameUs]).
int fxBaseNs(int period) {
  final frames = _perBlock(period);
  return ((kFxBaseFixedUs + kFxBaseFrameUs * frames) * 1000 / frames).ceil();
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
