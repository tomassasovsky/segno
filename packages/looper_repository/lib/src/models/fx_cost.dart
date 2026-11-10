import 'package:looper_repository/src/models/track_effect.dart';

/// The settings the console's cost tables were measured at, in the order of
/// each table's figures ([kFxSettingCostNs], [kFxPsolaCostNs], [kFxBaseUs]):
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
/// nanoseconds per frame: each kind's share of the worst block with eight in
/// one chain (`bench_fx_cpu --table`), the larger of one instance's p99
/// increment over the empty chain and an eighth of eight's.
///
/// Measured on the console (Pi 5, SCHED_FIFO 70, segno.service stopped,
/// `bench_fx_cpu --paced --cpu 3 --table --blocks 2000 --rate R --period P`)
/// at each of [kFxCostSettings] for #1508, and again at 48 kHz / 32 for
/// #1724. Where a kind's heaviest use is not the table's still chain, the
/// charge is the heavier scenario's (`bench_fx_cpu --kind`, its chain and
/// moving runs, measured the same way): the LPF swept by its LFO (`lpflfo`),
/// the Mode delay's Dub voicing gliding (`dubdelay`), the Mod and the Room
/// reverb with their settings moving. The High-pass changed after #1508
/// (#1644) and charges only #1724's runs.
///
/// These kinds do the same work a frame at every setting, so a lower reading
/// at one is the bench's noise (one instance's p99 at 32 frames moves by a
/// few microseconds, a hundred nanoseconds a frame): each charges the largest
/// it measured at a setting the Device page offers (44.1, 48 and 96 kHz,
/// AudioSetupState.sampleRates), the console did run that block. The kinds
/// whose work depends on the setting are in [kFxSettingCostNs].
const Map<TrackEffectType, int> kFxKindCostNs = {
  TrackEffectType.none: 0,
  TrackEffectType.drive: 35,
  TrackEffectType.filter: 166,
  TrackEffectType.delay: 42,
  TrackEffectType.tremolo: 52,
  TrackEffectType.echo: 144,
  TrackEffectType.reverb: 234,
  TrackEffectType.eq: 88,
  TrackEffectType.compressor: 76,
  TrackEffectType.transient: 73,
  TrackEffectType.hpGate: 122,
  TrackEffectType.doubler: 52,
  TrackEffectType.chorus: 78,
  TrackEffectType.wah: 60,
  TrackEffectType.degrade: 103,
  TrackEffectType.lpf: 200,
  TrackEffectType.spring: 116,
  TrackEffectType.dubVerb: 221,
  TrackEffectType.ambVerb: 272,
  TrackEffectType.pumper: 63,
  TrackEffectType.slicer: 103,
  TrackEffectType.modeDelay: 179,
  TrackEffectType.mod: 113,
  TrackEffectType.roomVerb: 735,
};

/// What the kinds whose work depends on the setting charge, in nanoseconds
/// per frame at each of [kFxCostSettings], measured as [kFxKindCostNs] is.
/// The Overdrive and the Amp changed after #1508 (#1663, #1664) and charge
/// only #1724's runs, at all eight.
///
/// A kind on the hop (the octaver, the Whammy, the Dual Octaver) does a
/// quarter of its hop in every block up to 64 frames, so it costs more a
/// frame at 32 frames than at 64. At 44.1 kHz a 64-frame block can take two
/// quarters, a 32-frame block's cost a frame, so there they charge the
/// larger of their 64- and 32-frame figures (2,000 blocks do not always
/// catch the two-quarter one). The Overdrive, the
/// Distortion and the Vinyl run fewer times over at 88.2 kHz and up (#1547),
/// so they cost less a frame there; the Amp's clipper does too, but its
/// cabinet runs twice the taps at 96 kHz, so it does not.
const Map<TrackEffectType, List<int>> kFxSettingCostNs = {
  TrackEffectType.octaver: [2172, 2172, 2048, 969, 1942, 1182, 1923, 1140],
  TrackEffectType.whammy: [2049, 2049, 1846, 965, 1933, 1170, 1852, 1151],
  TrackEffectType.dualOctaver: [2174, 2174, 1942, 1110, 2009, 1210, 1950, 1154],
  TrackEffectType.overdrive: [904, 861, 903, 860, 522, 513, 540, 533],
  TrackEffectType.distortion: [400, 393, 407, 392, 248, 247, 266, 272],
  TrackEffectType.vinyl: [381, 374, 375, 374, 201, 200, 192, 203],
  TrackEffectType.ampCab: [632, 563, 579, 491, 663, 479, 700, 504],
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
/// each of [kFxCostSettings], measured as [kFxKindCostNs] is. Between and
/// below the two block lengths a rate was measured at, the base is the line
/// through them: a fixed part and a part for each frame ([fxBaseNs]).
const List<double> kFxBaseUs = [42.3, 74.8, 45.4, 73.5, 43.1, 74.4, 43.8, 75.9];

/// The kinds that keep running after they are switched off, until their tail
/// has drained (engine_fx.c, `le_fx_type_drains`: the delay, the echo, the
/// Mode delay and the reverbs). Switching one off frees nothing until then,
/// so the budget charges one an alternation turns off as if it ran (#1723).
const Set<TrackEffectType> kFxDrainingKinds = {
  TrackEffectType.delay,
  TrackEffectType.echo,
  TrackEffectType.modeDelay,
  TrackEffectType.reverb,
  TrackEffectType.spring,
  TrackEffectType.dubVerb,
  TrackEffectType.ambVerb,
  TrackEffectType.roomVerb,
};

/// Whether [fx] keeps running after it is switched off ([kFxDrainingKinds]).
bool fxDrains(TrackEffect fx) =>
    fx is BuiltInEffect && kFxDrainingKinds.contains(fx.type);

/// The block a per-block cost is spread over at most ([_perBlock]), and the
/// block the charges default to.
const int kFxBenchPeriod = 64;

/// The share of each block the worst block may fill (#1724): 77 %.
///
/// Set from the console's measured p99.9 with a safety margin of a tenth of
/// the block. In the app at 48 kHz / 32 (build 236, four of Ed's Racks on
/// two inputs, four takes playing, the screens drawing), the audio thread's
/// p99.9 service was 1.16 times what this file charges for the same rig,
/// its own base included: the app's ALSA I/O, its playback and the screens'
/// memory traffic cost the callback more than the bench's engine does. A
/// share s puts the p99.9 at 1.16 s of the block at the limit; 0.9 / 1.16
/// is 0.773, so 0.77. The engine counts the services past it
/// (`over_share_periods`, LE_CB_OVER_SHARE_NUM / DEN).
const double kFxBudgetShare = 0.77;

/// The rate the charges default to.
const int kFxBenchRate = 96000;

/// Which of [kFxCostSettings] a device at [sampleRate] and [period]-frame
/// blocks is charged at: the measured rate nearest to [sampleRate] on the
/// same side of 88.2 kHz, where the oversampled kinds and the pitch kernel
/// change how much they run (engine_fx.c, le_os_stages), at 32 frames below
/// 64 and at 64 from there ([_perBlock]: a longer block costs no more per
/// frame).
int fxCostSetting(int sampleRate, int period) {
  final rate = sampleRate > 0 ? sampleRate : kFxBenchRate;
  final frames = _perBlock(period) < kFxBenchPeriod ? 32 : kFxBenchPeriod;
  int distance(int i) => (kFxCostSettings[i].rate - rate).abs();
  var best = -1;
  for (var i = 0; i < kFxCostSettings.length; i++) {
    final s = kFxCostSettings[i];
    if (s.period != frames || (s.rate < 88200) != (rate < 88200)) continue;
    if (best < 0 || distance(i) < distance(best)) best = i;
  }
  return best;
}

/// What [fx] charges, in nanoseconds per frame at [sampleRate] and
/// [period]-frame blocks while it runs: its kind's figure ([kFxKindCostNs]),
/// or at the setting ([fxCostSetting]) for a kind whose work depends on it
/// ([kFxSettingCostNs], [kFxPsolaCostNs]). Outside what was measured the
/// figure only grows: a block under 32 frames charges the 32-frame figure
/// times 32 over its length (a hop quarter or a block's own work lands in
/// every block), and a rate under 44.1 kHz charges a setting kind's 44.1 kHz
/// figure times 44.1 kHz over the rate (its 48 kHz kernel runs more samples
/// a frame). Which instances the rig is charged for, those on and those a
/// control can turn on, is the repository's (`LooperRepository.fxCostNs`,
/// #1723). A hosted plugin charges nothing here; its cost is its own.
int fxEntryCostNs(
  TrackEffect fx, {
  int period = kFxBenchPeriod,
  int sampleRate = kFxBenchRate,
}) {
  if (fx is! BuiltInEffect) return 0;
  final frames = _perBlock(period);
  final short = frames < 32 ? 32 / frames : 1.0;
  final rate = sampleRate > 0 ? sampleRate : kFxBenchRate;
  final slow = rate < 44100 ? 44100 / rate : 1.0;
  final at = fxCostSetting(sampleRate, period);
  final psola =
      fx.type == TrackEffectType.smartTune ||
      (fx.type == TrackEffectType.octaver && fx.params[3] >= 0.5);
  if (psola) return (kFxPsolaCostNs[at] * short * slow).ceil();
  final bySetting = kFxSettingCostNs[fx.type];
  if (bySetting != null) return (bySetting[at] * short * slow).ceil();
  return ((kFxKindCostNs[fx.type] ?? 0) * short).ceil();
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
    (kFxBudgetShare * 1e9 / sampleRate).floor() -
    fxBaseNs(sampleRate, period: period);

/// What the engine itself charges the worst block, in nanoseconds per frame
/// at [sampleRate] and [period]-frame blocks: the line through the rate's
/// two measured blocks ([kFxBaseUs]), a fixed part and a part for each
/// frame, at the block up to 64 frames ([_perBlock]).
int fxBaseNs(int sampleRate, {int period = kFxBenchPeriod}) {
  final at32 = fxCostSetting(sampleRate, 32);
  final at64 = fxCostSetting(sampleRate, kFxBenchPeriod);
  final perFrame = (kFxBaseUs[at64] - kFxBaseUs[at32]) / 32;
  final fixed = kFxBaseUs[at32] - 32 * perFrame;
  final frames = _perBlock(period);
  return ((fixed + perFrame * frames) * 1000 / frames).ceil();
}

/// What handing the monitor chains to the effects workers costs the
/// callback's block, in microseconds, by the number of workers (#1515): the
/// wake, the claims and the join (2.5 us a block in the spike), plus the time
/// the workers lose to their late start, shared by every core
/// (docs/plan/2026-10-29-feat-multicore-effects-plan.md, section 7: 70, 81
/// and 97 ns a frame at 64-frame blocks).
const Map<int, double> kFxHandoffUs = {1: 4.48, 2: 5.184, 3: 6.208};

/// What each track's job adds to the callback's own share, in nanoseconds
/// per frame, when the track chains run as jobs (#1729): the mixer records
/// every lane's frame for its track's job, and after the join the callback
/// sums every track onto the outputs, work the monitor jobs' handoff
/// ([kFxHandoffUs]) does not have.
///
/// Set from the console (build 238, 48 kHz / 32, two workers,
/// `bench_rt_faults --track-racks K`, #1729): Ed's Racks on 3 and 5 tracks
/// ran with no late period and no xrun, on 6 and 7 with 66 and 87 late
/// periods in 120 s, more than the 42 in 200 s of #1724's run at the
/// limit. The per-job charge that admits 5 and refuses 6 at the 77 % share
/// lies between 348 and 727 ns; this is near its middle. Four input racks
/// beside three track racks, which this refuses too, ran 72 late periods and
/// 2 xruns.
const int kFxTrackJobNs = 500;

/// What the effects charge the audio thread's worst block, in nanoseconds
/// per frame, at [period]-frame blocks with [workers] effects workers
/// beside the callback (#1515): the chains that stay on the callback
/// ([serial]) plus the critical path of the [jobs], the chains the workers
/// share: one monitor input's non-empty chain each (#1515), and one track's
/// lanes' and own chains each, when one of them is non-empty (#1729).
///
/// With C cores (the callback and the workers) any greedy claiming finishes
/// the jobs within J/C + (1 - 1/C) p of their release (Graham's bound for
/// list scheduling, in any order), J their sum and p the largest, plus the
/// handoff ([kFxHandoffUs]) and, for each of the jobs that is a track's
/// ([trackJobs] of them), [kFxTrackJobNs]. One job's work never splits
/// across cores, which the second term pays for. With no workers, or fewer
/// than two jobs (the engine then runs them on the callback), it is every
/// chain summed: the rule before #1515.
int fxLoadNs({
  required int serial,
  required Iterable<int> jobs,
  int workers = 0,
  int period = kFxBenchPeriod,
  int trackJobs = 0,
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
  return serial + handoff + trackJobs * kFxTrackJobNs + path;
}

/// The frames a per-block cost spreads over: the block below the bench's
/// 64, where a hop quarter and the engine's fixed work land in every
/// block; the bench's 64 above it, where a longer block runs several hop
/// stages and mixes proportionally more (engine_fx.h, LE_PV_HOP).
int _perBlock(int period) =>
    period > 0 && period < kFxBenchPeriod ? period : kFxBenchPeriod;
