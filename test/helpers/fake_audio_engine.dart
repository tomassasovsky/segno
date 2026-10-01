import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart';

/// A controllable in-memory [AudioEngine] for tests.
///
/// Records interactions and returns scripted results/snapshots, so cubit and
/// widget tests never touch the native audio device.
class FakeAudioEngine implements AudioEngine {
  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) =>
      const OutputFxSnapshot();

  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  /// Optional per-call results consumed in order by [start] (then falls back
  /// to [startResult]). Lets tests script a failed pin followed by a default
  /// open without replacing the whole fake.
  List<EngineResult>? startResults;

  /// Snapshot returned by [snapshot].
  EngineSnapshot _nextSnapshot = const EngineSnapshot.initial().copyWith(
    outputChannels: 2,
    outputBusCount: 1,
  );
  EngineSnapshot get nextSnapshot => _nextSnapshot;
  set nextSnapshot(EngineSnapshot value) {
    _nextSnapshot = value;
    publishedMode = null;
  }

  bool commandsAreSettled = true;
  bool publishLengthCommands = true;
  bool publishModeCommands = true;
  bool publishMixCommands = true;
  bool publishRecordImages = true;

  /// When false, a test-supplied snapshot remains the performance arm truth.
  bool publishPerfCommands = true;
  EngineResult mixResult = EngineResult.ok;
  EngineMixSettings? lastMix;
  RecordImage? lastRecordImage;
  int publishedMixRevision = 0;
  final Map<(int, int), StereoMix> liveMix = {};
  final Map<(int, int), StereoMix> sourceImages = {};
  final Map<int, RecordImage> pendingImages = {};
  final Map<int, int> imageRevisions = {};
  final Map<int, int> publishedLengths = {};
  LooperMode? publishedMode;

  /// Whether the snapshot reports the capture drain self-stopped on a failed
  /// write (#652). Overlaid onto [nextSnapshot] so a test can flip it mid-run
  /// without rebuilding the whole snapshot.
  bool perfStopped = false;

  /// The device name reported while running.
  String runningDeviceName = 'Fake Device';

  bool _running = false;

  /// The most recent config passed to [start].
  EngineConfig? lastConfig;

  /// Call counters for assertions.
  int startCalls = 0;
  int stopCalls = 0;
  int measureLatencyCalls = 0;
  int disposeCalls = 0;
  int recordCalls = 0;
  int stopTrackCalls = 0;
  int playCalls = 0;
  int clearCalls = 0;
  int undoCalls = 0;
  int redoCalls = 0;

  /// Last looper parameter values seen.
  double? lastVolume;
  bool? lastMuted;

  /// Last record offset (latency compensation) applied, in frames.
  int? lastRecordOffset;

  @override
  String get version => 'fake-engine 0.0.0';

  @override
  String get deviceName => _running ? runningDeviceName : '';

  @override
  EngineResult start(EngineConfig config) {
    startCalls++;
    lastConfig = config;
    final queued = startResults;
    final result = (queued != null && queued.isNotEmpty)
        ? queued.removeAt(0)
        : startResult;
    if (result.isOk) _running = true;
    return result;
  }

  @override
  EngineResult stop() {
    stopCalls++;
    _running = false;
    return EngineResult.ok;
  }

  @override
  CallbackTelemetry callbackTelemetry() => CallbackTelemetry.empty;

  @override
  bool get commandsSettled => commandsAreSettled;

  @override
  EngineSnapshot snapshot() => _LengthSnapshot(
    this,
    nextSnapshot,
    publishedLengths,
    publishedMode,
    publishedMixRevision,
    perfStopped: perfStopped,
    perfArmed: publishPerfCommands ? _publishedPerfArmed : null,
    perfFollowOutput: _frozenPerfFollowOutput,
    perfCaptureBus: _frozenPerfCaptureBus,
    perfCaptureMask: _frozenPerfCaptureMask,
    perfOutputEnabledMask: _frozenPerfOutputEnabledMask,
    perfOutputLevel: _frozenPerfOutputLevel,
    perfOutputMuted: _frozenPerfOutputMuted,
  );

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() => loopback;

  /// Devices returned by [enumerateDevices].
  List<AudioDevice> devices = const [];

  @override
  List<AudioDevice> enumerateDevices() => devices;

  /// Drivers returned by [enumerateAsioDrivers].
  List<AudioDevice> asioDrivers = const [];

  @override
  List<AudioDevice> enumerateAsioDrivers() => asioDrivers;

  @override
  EngineResult measureLatency() {
    measureLatencyCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) {
    recordCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    if (!image.isValid) return EngineResult.invalid;
    final result = record(channel: channel);
    if (!result.isOk) return result;
    lastRecordImage = image;
    pendingImages[channel] = image;
    if (publishRecordImages) publishImage(channel);
    return EngineResult.ok;
  }

  /// Simulates the callback publishing the frozen image at capture start.
  void publishImage(int channel) {
    final image = pendingImages.remove(channel);
    if (image == null) return;
    for (final entry in image.lanes.entries) {
      final key = (channel, entry.key);
      sourceImages[key] = entry.value;
      _composeLane(key);
    }
    imageRevisions[channel] = image.revision;
  }

  @override
  EngineResult setMix(EngineMixSettings settings) {
    if (!settings.isValid) return EngineResult.invalid;
    if (!mixResult.isOk) return mixResult;
    lastMix = settings;
    if (publishMixCommands) publishMix();
    return EngineResult.ok;
  }

  /// Simulates callback publication after an accepted mix request.
  void publishMix() {
    final settings = lastMix;
    if (settings == null) return;
    laneInput.addAll(settings.laneInputs);
    laneOutput.addAll(settings.laneOutputs);
    laneCount.addAll(settings.laneCounts);
    liveMix.addAll(settings.lanes);
    sourceImages.addAll(settings.images);
    settings.lanes.keys
        .followedBy(settings.images.keys)
        .toSet()
        .forEach(_composeLane);
    for (final entry in settings.monitors.entries) {
      monitorVolume[entry.key] = entry.value.gain;
      monitorPan[entry.key] = entry.value.pan;
    }
    inputTrim.addAll(settings.trims);
    trackSolo.addAll(settings.solos);
    for (final entry in settings.outputs.entries) {
      outputLevel[entry.key] = entry.value.level;
      outputMuted[entry.key] = entry.value.muted;
      outputMono[entry.key] = entry.value.mono;
      outputBalance[entry.key] = entry.value.balance;
    }
    publishedMixRevision = settings.revision;
  }

  void _composeLane((int, int) key) {
    final live = liveMix[key] ?? (gain: 1.0, pan: 0.0);
    final source = sourceImages[key] ?? (gain: 1.0, pan: 0.0);
    laneVol[key] = live.gain * source.gain;
    lanePan[key] = (live.pan + source.pan).clamp(-1.0, 1.0);
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    stopTrackCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    playCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    clearCalls++;
    return EngineResult.ok;
  }

  /// Counts undoable clears separately from destructive ones, so a test can
  /// tell a user clear (which must leave a way back) from a session-load one.
  int clearUndoableCalls = 0;

  @override
  EngineResult clearUndoable({int channel = 0}) {
    clearUndoableCalls++;
    return EngineResult.ok;
  }

  /// What the next [undo] would do; stands in for the engine's restore-point
  /// bookkeeping.
  bool undoRestoresClearResult = false;

  @override
  bool undoRestoresClear({int channel = 0}) => undoRestoresClearResult;

  @override
  bool redoReclears({int channel = 0}) => false;

  @override
  bool clearRestorePending({int channel = 0}) => false;

  /// Result returned by the history preflight until a test changes it.
  EngineResult nextHistoryModeGate = EngineResult.ok;

  /// Ordered history preflights, retaining the full group mask and direction.
  final List<({int channels, bool redo})> historyModeGateCalls = [];

  /// Result returned by [undo] until a test changes it.
  EngineResult nextUndoResult = EngineResult.ok;

  /// Result returned by [redo] until a test changes it.
  EngineResult nextRedoResult = EngineResult.ok;

  @override
  EngineResult historyModeGate({required int channels, required bool redo}) {
    historyModeGateCalls.add((channels: channels, redo: redo));
    return nextHistoryModeGate;
  }

  @override
  EngineResult undo({int channel = 0}) {
    undoCalls++;
    return nextUndoResult;
  }

  @override
  EngineResult redo({int channel = 0}) {
    redoCalls++;
    return nextRedoResult;
  }

  /// Per-channel active lane count passed to [setLaneCount].
  final Map<int, int> laneCount = {};

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    laneCount[channel] = count;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) volume passed to [setLaneVolume].
  final Map<(int, int), double> laneVol = {};

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    laneVol[(channel, lane)] = volume;
    lastVolume = volume;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) pan passed to [setLanePan].
  final Map<(int, int), double> lanePan = {};

  @override
  EngineResult setLanePan({
    required double pan,
    int channel = 0,
    int lane = 0,
  }) {
    lanePan[(channel, lane)] = pan;
    return EngineResult.ok;
  }

  /// Per-track solo passed to [setTrackSolo].
  final Map<int, bool> trackSolo = {};

  @override
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    trackSolo[channel] = solo;
    return EngineResult.ok;
  }

  /// Per-input capture trim (linear gain) passed to [setInputTrim].
  final Map<int, double> inputTrim = {};

  @override
  EngineResult setInputTrim({required int input, required double gain}) {
    inputTrim[input] = gain;
    return EngineResult.ok;
  }

  /// Per-bus facts passed to the output setters (slice 3b).
  final Map<int, double> outputLevel = {};
  final Map<int, bool> outputMuted = {};
  final Map<int, bool> outputMono = {};
  final Map<int, double> outputBalance = {};

  /// How many times [cutSound] ran.
  int cutSoundCalls = 0;

  /// The last policy passed to [setPerfFollowOutput].
  bool? perfFollowOutput;

  @override
  EngineResult setOutputLevel({required int bus, required double level}) {
    outputLevel[bus] = level;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMute({required int bus, required bool muted}) {
    outputMuted[bus] = muted;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMono({required int bus, required bool mono}) {
    outputMono[bus] = mono;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputBalance({required int bus, required double balance}) {
    outputBalance[bus] = balance;
    return EngineResult.ok;
  }

  @override
  EngineResult cutSound() {
    cutSoundCalls++;
    return EngineResult.ok;
  }

  @override
  EngineResult setPerfFollowOutput({required bool follow}) {
    perfFollowOutput = follow;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) mute passed to [setLaneMute].
  final Map<(int, int), bool> laneMute = {};

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    laneMute[(channel, lane)] = muted;
    lastMuted = muted;
    return EngineResult.ok;
  }

  /// Per-(channel, lane) recorded input channel passed to [setLaneInput].
  final Map<(int, int), int> laneInput = {};

  /// Per-(channel, lane) output mask passed to [setLaneOutput].
  final Map<(int, int), int> laneOutput = {};

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    laneInput[(channel, lane)] = inputChannel;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    laneOutput[(channel, lane)] = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    return EngineResult.ok;
  }

  /// The last value passed to [setQuantize].
  bool? lastQuantize;

  @override
  EngineResult setQuantize({required bool enabled}) {
    lastQuantize = enabled;
    return EngineResult.ok;
  }

  /// Per-track quantize overrides passed to [setTrackQuantize].
  final Map<int, bool?> trackQuantize = {};

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    trackQuantize[channel] = enabled;
    return EngineResult.ok;
  }

  /// Per-track division overrides passed to [setTrackQuantizeDiv].
  final Map<int, GridDivision?> trackQuantizeDiv = {};

  @override
  EngineResult setTrackQuantizeDiv({
    required int channel,
    required GridDivision? div,
  }) {
    trackQuantizeDiv[channel] = div;
    return EngineResult.ok;
  }

  /// Per-track feedback overrides passed to [setTrackOverdubFeedback].
  final Map<int, double?> trackOverdubFeedback = {};

  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) {
    trackOverdubFeedback[channel] = feedback;
    return EngineResult.ok;
  }

  /// Per-track forced multiples passed to [setTrackMultiple].
  final Map<int, int> trackMultiple = {};

  /// The last value passed to [setDefaultMultiple].
  int? lastDefaultMultiple;

  /// The last values passed to [setRecDub] / [setAutoRecord].
  bool? lastRecDub;
  bool? lastAutoRecord;

  /// The last value passed to [setMasterGain].
  double? lastMasterGain;

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    trackMultiple[channel] = multiple;
    return EngineResult.ok;
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    lastDefaultMultiple = multiple;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    lastRecDub = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setMasterGain(double gain) {
    lastMasterGain = gain;
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    return EngineResult.ok;
  }

  /// The last value passed to [setTempo].
  double? lastTempoBpm;

  /// The last `(num, den)` passed to [setTimeSignature].
  (int, int)? lastTimeSignature;

  /// The number of [tapTempo] calls.
  int tapTempoCallCount = 0;

  /// The last value passed to [setSyncTempo].
  bool? lastSyncTempo;

  /// The last value passed to [setQuantizeDiv].
  GridDivision? lastQuantizeDiv;

  /// The last value passed to [setClickMode].
  ClickMode? lastClickMode;

  /// The last value passed to [setClickOutput].
  int? lastClickOutput;

  /// The last value passed to [setClickVolume].
  double? lastClickVolume;

  /// The last value passed to [setCountIn].
  int? lastCountIn;

  /// Exact session tempo restores in call order.
  final List<({double bpm, TempoSource source})> tempoRestores = [];

  @override
  EngineResult restoreTempo({
    required double bpm,
    required TempoSource source,
  }) {
    tempoRestores.add((bpm: bpm, source: source));
    return EngineResult.ok;
  }

  @override
  EngineResult setTempo(double bpm) {
    lastTempoBpm = bpm;
    return EngineResult.ok;
  }

  @override
  EngineResult setTimeSignature(int num, int den) {
    lastTimeSignature = (num, den);
    return EngineResult.ok;
  }

  @override
  EngineResult tapTempo() {
    tapTempoCallCount++;
    return EngineResult.ok;
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    lastSyncTempo = on;
    return EngineResult.ok;
  }

  @override
  EngineResult setQuantizeDiv(GridDivision div) {
    lastQuantizeDiv = div;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickMode(ClickMode mode) {
    lastClickMode = mode;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickOutput(int mask) {
    lastClickOutput = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickVolume(double volume) {
    lastClickVolume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setCountIn(int bars) {
    lastCountIn = bars;
    return EngineResult.ok;
  }

  /// Per-track length presets passed to [setTrackLengthPreset].
  final Map<int, int> trackLengthPreset = {};

  @override
  EngineResult setTrackLengthPreset({required int channel, required int bars}) {
    trackLengthPreset[channel] = bars;
    if (publishLengthCommands) publishedLengths[channel] = bars;
    return EngineResult.ok;
  }

  /// The last atomic preset vector, and the scripted result for its call.
  List<int>? lastTrackLengthPresets;
  EngineResult trackLengthPresetsResult = EngineResult.ok;

  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    lastTrackLengthPresets = List<int>.of(bars);
    if (!trackLengthPresetsResult.isOk) return trackLengthPresetsResult;
    for (var channel = 0; channel < bars.length; channel++) {
      trackLengthPreset[channel] = bars[channel];
      if (publishLengthCommands) publishedLengths[channel] = bars[channel];
    }
    return EngineResult.ok;
  }

  /// The last value passed to [setLooperMode].
  LooperMode? lastLooperMode;

  /// What [looperModeGate] answers; tests set it to exercise a refusal.
  LooperModeGate nextLooperModeGate = LooperModeGate.open;

  @override
  LooperModeGate looperModeGate(LooperMode mode) => nextLooperModeGate;

  @override
  EngineResult setLooperMode(LooperMode mode) {
    lastLooperMode = mode;
    return EngineResult.ok;
  }

  /// The last atomic mode/preset request, and the scripted result.
  (LooperMode, List<int>)? lastModeWithPresets;
  EngineResult modeWithPresetsResult = EngineResult.ok;

  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) {
    lastModeWithPresets = (mode, List<int>.of(bars));
    if (!modeWithPresetsResult.isOk) return modeWithPresetsResult;
    lastLooperMode = mode;
    if (publishModeCommands) publishedMode = mode;
    for (var channel = 0; channel < bars.length; channel++) {
      trackLengthPreset[channel] = bars[channel];
      if (publishLengthCommands) publishedLengths[channel] = bars[channel];
    }
    return EngineResult.ok;
  }

  /// The last channel passed to [crownPrimary].
  int? lastCrownedChannel;

  @override
  EngineResult crownPrimary({required int channel}) {
    lastCrownedChannel = channel;
    return EngineResult.ok;
  }

  /// Per-track One Shot flags passed to [setOneShot].
  final Map<int, bool> trackOneShot = {};

  @override
  EngineResult setOneShot({required int channel, required bool oneShot}) {
    trackOneShot[channel] = oneShot;
    return EngineResult.ok;
  }

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    for (var channel = 0; channel < 8; channel++) {
      if ((channels & (1 << channel)) != 0) trackOneShot[channel] = oneShot;
    }
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      EngineResult.ok;

  @override
  EngineResult setOverdubFeedback(double feedback) => EngineResult.ok;

  /// Per-(channel, lane, index) effect type passed to [setLaneFx].
  final Map<(int, int, int), TrackEffectType> laneFx = {};

  /// Per-(channel, lane) active chain length passed to [setLaneFxCount].
  final Map<(int, int), int> laneFxCount = {};

  /// Per-(channel, lane, index, param) value passed to [setLaneFxParam].
  final Map<(int, int, int, int), double> laneFxParam = {};

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED, modeled like the real engine: a type CHANGE re-seeds the
    // slot's enabled flag synchronously, so enabled bits pushed before the
    // type/count commands get clobbered here exactly as they would natively.
    if (laneFx[(channel, lane, index)] != type) {
      laneFxEnabled[(channel, lane, index)] = true;
    }
    laneFx[(channel, lane, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  }) {
    // D-ENSEED's second half: entering slots seed enabled.
    for (var s = laneFxCount[(channel, lane)] ?? 0; s < count; s++) {
      laneFxEnabled[(channel, lane, s)] = true;
    }
    laneFxCount[(channel, lane)] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    laneFxParam[(channel, lane, index, param)] = value;
    return EngineResult.ok;
  }

  /// Per-(channel, lane, index) flag passed to [setLaneFxEnabled].
  final Map<(int, int, int), bool> laneFxEnabled = {};

  /// Per-(channel, lane) flag passed to [setLaneFxChainEnabled].
  final Map<(int, int), bool> laneFxChainEnabled = {};

  @override
  EngineResult setLaneFxEnabled({
    required int channel,
    required int lane,
    required int index,
    required bool enabled,
  }) {
    laneFxEnabled[(channel, lane, index)] = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) {
    laneFxChainEnabled[(channel, lane)] = enabled;
    return EngineResult.ok;
  }

  // ---- Track-stage + Master insert chains (FX v3), recorded so app tests
  // can assert the bootstrap restore + bloc pushes. ----

  /// Per-(channel, index) effect type passed to [setTrackFx].
  final Map<(int, int), TrackEffectType> trackFx = {};

  /// Per-channel active chain length passed to [setTrackFxCount].
  final Map<int, int> trackFxCount = {};

  /// Per-(channel, index, param) value passed to [setTrackFxParam].
  final Map<(int, int, int), double> trackFxParam = {};

  /// Per-(channel, index) flag passed to [setTrackFxEnabled].
  final Map<(int, int), bool> trackFxEnabled = {};

  /// Per-channel flag passed to [setTrackFxChainEnabled].
  final Map<int, bool> trackFxChainEnabled = {};

  /// Per-index effect type passed to [setOutputFx] on bus 0.
  final Map<int, TrackEffectType> masterFx = {};

  /// Bus 0's active chain length passed to [setOutputFxCount].
  int? masterFxCount;

  /// Per-(index, param) value passed to [setOutputFxParam] on bus 0.
  final Map<(int, int), double> masterFxParam = {};

  /// Per-index flag passed to [setOutputFxEnabled] on bus 0.
  final Map<int, bool> masterFxEnabled = {};

  /// Bus 0's flag passed to [setOutputFxChainEnabled].
  bool? masterFxChainEnabled;

  @override
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED re-seed on type change — see [setLaneFx].
    if (trackFx[(channel, index)] != type) {
      trackFxEnabled[(channel, index)] = true;
    }
    trackFx[(channel, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxCount({required int channel, required int count}) {
    // D-ENSEED entering-slot seed — see [setLaneFxCount].
    for (var s = trackFxCount[channel] ?? 0; s < count; s++) {
      trackFxEnabled[(channel, s)] = true;
    }
    trackFxCount[channel] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) {
    trackFxParam[(channel, index, param)] = value;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) {
    trackFxEnabled[(channel, index)] = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxChainEnabled({
    required int channel,
    required bool enabled,
  }) {
    trackFxChainEnabled[channel] = enabled;
    return EngineResult.ok;
  }

  // Only bus 0 is addressed by the app today (FxStage.master), so the fake
  // records that bus and ignores the rest.
  @override
  EngineResult setOutputFx({
    required int bus,
    required int index,
    required TrackEffectType type,
  }) {
    if (bus != 0) return EngineResult.ok;
    // D-ENSEED re-seed on type change — see [setLaneFx].
    if (masterFx[index] != type) {
      masterFxEnabled[index] = true;
    }
    masterFx[index] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxCount({required int bus, required int count}) {
    if (bus != 0) return EngineResult.ok;
    // D-ENSEED entering-slot seed — see [setLaneFxCount].
    for (var s = masterFxCount ?? 0; s < count; s++) {
      masterFxEnabled[s] = true;
    }
    masterFxCount = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) {
    if (bus == 0) masterFxParam[(index, param)] = value;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) {
    if (bus == 0) masterFxEnabled[index] = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxChainEnabled({
    required int bus,
    required bool enabled,
  }) {
    if (bus == 0) masterFxChainEnabled = enabled;
    return EngineResult.ok;
  }

  /// Per-input enabled flag passed to [setMonitorInputEnabled].
  final Map<int, bool> monitorInputEnabled = {};

  /// The input the tuner is armed on, or `-1`. Mirrors the native gate, so a
  /// test can assert that a closed face leaves nothing running.
  int tunerInput = -1;

  @override
  EngineResult setTunerInput({required int input}) {
    tunerInput = input;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorInputEnabled[input] = enabled;
    return EngineResult.ok;
  }

  /// Per-input monitor output mask passed to [setMonitorInputOutput].
  final Map<int, int> monitorOutput = {};

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    monitorOutput[input] = mask;
    return EngineResult.ok;
  }

  /// Per-input monitor volume passed to [setMonitorInputVolume].
  final Map<int, double> monitorVolume = {};

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) {
    monitorVolume[input] = volume;
    return EngineResult.ok;
  }

  /// Per-input monitor mute passed to [setMonitorInputMute].
  final Map<int, bool> monitorMute = {};

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    monitorMute[input] = muted;
    return EngineResult.ok;
  }

  /// Per-input monitor pan passed to [setMonitorInputPan].
  final Map<int, double> monitorPan = {};

  @override
  EngineResult setMonitorInputPan({required int input, required double pan}) {
    monitorPan[input] = pan;
    return EngineResult.ok;
  }

  /// Per-input conditioning enabled flag passed to
  /// [setInputConditioningEnabled].
  final Map<int, bool> conditioningEnabled = {};

  /// Per-(input, param) conditioning value passed to
  /// [setInputConditioningParam].
  final Map<(int, InputConditioningParam), double> conditioningParam = {};

  @override
  EngineResult setInputConditioningEnabled({
    required int input,
    required bool enabled,
  }) {
    conditioningEnabled[input] = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) {
    conditioningParam[(input, param)] = value;
    return EngineResult.ok;
  }

  /// Per-(input, index) effect type passed to [setMonitorInputFx].
  final Map<(int, int), TrackEffectType> monitorFx = {};

  /// Per-input active chain length passed to [setMonitorInputFxCount].
  final Map<int, int> monitorFxCount = {};

  /// Per-(input, index, param) value passed to [setMonitorInputFxParam].
  final Map<(int, int, int), double> monitorFxParam = {};

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED re-seed on type change — see [setLaneFx].
    if (monitorFx[(input, index)] != type) {
      monitorFxEnabled[(input, index)] = true;
    }
    monitorFx[(input, index)] = type;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    // D-ENSEED entering-slot seed — see [setLaneFxCount].
    for (var s = monitorFxCount[input] ?? 0; s < count; s++) {
      monitorFxEnabled[(input, s)] = true;
    }
    monitorFxCount[input] = count;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    monitorFxParam[(input, index, param)] = value;
    return EngineResult.ok;
  }

  /// Per-(input, index) flag passed to [setMonitorInputFxEnabled].
  final Map<(int, int), bool> monitorFxEnabled = {};

  /// Per-input flag passed to [setMonitorInputFxChainEnabled].
  final Map<int, bool> monitorFxChainEnabled = {};

  @override
  EngineResult setMonitorInputFxEnabled({
    required int input,
    required int index,
    required bool enabled,
  }) {
    monitorFxEnabled[(input, index)] = enabled;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxChainEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorFxChainEnabled[input] = enabled;
    return EngineResult.ok;
  }

  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;

  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;

  /// Per-lane wet-cache states this fake reports, keyed by `(channel, lane)`;
  /// anything unseeded reads as [LaneCacheState.live].
  final Map<(int, int), LaneCacheState> seededLaneCacheStates = {};

  /// How many batched [laneCacheStates] sweeps ran — lets a widget test prove
  /// the telemetry gate stops the engine read, not just the rendering.
  int laneCacheSweeps = 0;

  @override
  Map<(int, int), LaneCacheState> laneCacheStates() {
    laneCacheSweeps++;
    final states = <(int, int), LaneCacheState>{};
    for (var t = 0; t < nextSnapshot.tracks.length; t++) {
      for (var l = 0; l < kMaxLanes; l++) {
        states[(t, l)] = seededLaneCacheStates[(t, l)] ?? LaneCacheState.live;
      }
    }
    return states;
  }

  /// Per-output structural gate passed to [setOutputEnabled].
  final Map<int, bool> outputEnabled = {};

  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    outputEnabled[output] = enabled;
    return EngineResult.ok;
  }

  @override
  Float32List readVisual() => Float32List(0);

  /// How many times [readTrackVisual] was called — the copy across the
  /// engine boundary the waveform readers are meant to take once per
  /// content change, not once per poll.
  int trackVisualReads = 0;

  @override
  Float32List readTrackVisual(int channel) {
    trackVisualReads++;
    return Float32List(0);
  }

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  /// PCM returned by [exportTrackLane], keyed by `(channel, lane)` — empty
  /// (the pre-existing default) unless a test seeds it, matching a real
  /// engine reporting nothing settled to export for that lane.
  final Map<(int, int), Float32List> laneExports = {};

  @override
  Float32List exportTrackLane(int channel, int lane) =>
      laneExports[(channel, lane)] ?? Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => EngineResult.ok;

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) =>
      EngineResult.ok;

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) => ordinal == 0
      ? laneExports[(channel, lane)] ?? Float32List(0)
      : Float32List(0);

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    if (ordinal == 0) laneExports[(channel, lane)] = Float32List.fromList(pcm);
    return EngineResult.ok;
  }

  @override
  EngineResult finalizeLayers(int channel, int undoCount, int redoCount) =>
      EngineResult.ok;

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) =>
      EngineResult.ok;

  // --- Performance recording capture ---

  /// Call counters for [perfArm] / [perfDisarm].
  int perfArmCalls = 0;
  int perfDisarmCalls = 0;

  /// Result returned by [perfArm].
  EngineResult perfArmResult = EngineResult.ok;

  /// Result returned by [perfDisarm].
  EngineResult perfDisarmResult = EngineResult.ok;

  /// The `captureDir` passed to the most recent [perfArm] call.
  String? lastPerfCaptureDir;

  bool? _publishedPerfArmed;
  bool? _frozenPerfFollowOutput;
  int? _frozenPerfCaptureBus;
  int? _frozenPerfCaptureMask;
  int? _frozenPerfOutputEnabledMask;
  double? _frozenPerfOutputLevel;
  bool? _frozenPerfOutputMuted;

  @override
  EngineResult perfArm(String captureDir) {
    perfArmCalls++;
    lastPerfCaptureDir = captureDir;
    if (!perfArmResult.isOk) return perfArmResult;
    if (!publishPerfCommands) return EngineResult.ok;
    final source = nextSnapshot;
    final channels = source.outputChannels;
    if (channels <= 0 || channels > 32) return EngineResult.invalid;
    final available = (1 << channels) - 1;
    final enabled = source.outputEnabledMask & available;
    if (enabled == 0) return EngineResult.invalid;
    final firstChannel = (enabled & -enabled).bitLength - 1;
    final bus = firstChannel ~/ 2;
    _frozenPerfCaptureBus = bus;
    _frozenPerfCaptureMask = enabled & (0x3 << (2 * bus));
    _frozenPerfOutputEnabledMask = source.outputEnabledMask;
    _frozenPerfFollowOutput = perfFollowOutput ?? source.perfFollowOutput;
    _frozenPerfOutputLevel =
        outputLevel[bus] ??
        (bus < source.outputLevels.length ? source.outputLevels[bus] : 1);
    _frozenPerfOutputMuted =
        outputMuted[bus] ??
        (bus < source.outputMuted.length && source.outputMuted[bus]);
    _publishedPerfArmed = true;
    return EngineResult.ok;
  }

  @override
  EngineResult perfDisarm() {
    perfDisarmCalls++;
    if (!perfDisarmResult.isOk) return perfDisarmResult;
    if (publishPerfCommands) _publishedPerfArmed = false;
    return EngineResult.ok;
  }

  @override
  int? volumeFreeBytes(String path) => freeBytes;

  /// What [volumeFreeBytes] reports; `null` models a platform that cannot
  /// answer.
  int? freeBytes = 1 << 40;

  /// Result returned by [renderBegin].
  EngineResult renderBeginResult = EngineResult.ok;

  /// The `captureDir` passed to the most recent [renderBegin] call.
  String? lastRenderCaptureDir;

  /// Progress reported by [renderPoll].
  PerformanceRenderProgress renderProgress = PerformanceRenderProgress.empty;

  /// Track statuses reported by [renderTrackStatuses].
  List<PerformanceRenderTrackStatus> renderStatuses = const [];

  @override
  EngineResult renderBegin(String captureDir) {
    lastRenderCaptureDir = captureDir;
    return renderBeginResult;
  }

  @override
  PerformanceRenderProgress renderPoll() => renderProgress;

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() => renderStatuses;

  @override
  EngineResult renderCancel() => EngineResult.ok;

  // --- Plugin hosting (scan: part 2; slots: part 3) ---

  @override
  EngineResult scanBegin({bool rescan = false}) {
    pluginScanCount++;
    return EngineResult.ok;
  }

  @override
  PluginScanProgress scanPoll() => PluginScanProgress(
    done: !pluginScanPending,
    found: pluginScanPending ? 0 : pluginScanResults.length,
    scanned: pluginScanPending ? 0 : pluginScanResults.length,
    total: pluginScanResults.length,
  );

  /// What a scan finds. Seed it to stand a plugin catalog up in a widget
  /// test without a real host.
  List<PluginDescriptor> pluginScanResults = const [];

  /// Holds a scan open, so a test can observe the state DURING one.
  ///
  /// Without this every poll reports `done: true` and no test can render a
  /// mid-scan surface — which is how "Looking for plugins…" and the browse
  /// row it disables went untested.
  bool pluginScanPending = false;

  /// How many scans were started, for asserting a rescan did not happen.
  int pluginScanCount = 0;

  @override
  List<PluginDescriptor> scanResults() => pluginScanResults;

  @override
  EngineResult scanCancel() => EngineResult.ok;

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle('fake-plugin');

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle('fake-plugin');

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) => EngineResult.ok;

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) =>
      EngineResult.ok;

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) => const [];

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) => 0;

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) => null;

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) => EngineResult.ok;

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) => EngineResult.ok;

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) => EngineResult.ok;

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) => false;

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) => Uint8List(0);

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) =>
      EngineResult.ok;

  @override
  void dispose() => disposeCalls++;

  /// Channels passed to [cancelArm], in call order.
  final List<int> cancelledArms = [];

  @override
  EngineResult cancelArm({required int channel}) {
    cancelledArms.add(channel);
    return EngineResult.ok;
  }

  /// Channels passed to [finalizeTake], in call order.
  final List<int> finalizedTakes = [];

  /// The result [finalizeTake] returns — override with
  /// [EngineResult.invalid] to model the engine refusing (a defining take).
  EngineResult finalizeTakeResult = EngineResult.ok;

  @override
  EngineResult finalizeTake({required int channel}) {
    finalizedTakes.add(channel);
    return finalizeTakeResult;
  }
}

class _LengthSnapshot extends EngineSnapshot {
  _LengthSnapshot(
    FakeAudioEngine engine,
    EngineSnapshot source,
    Map<int, int> lengths,
    LooperMode? mode,
    int mixRevision, {
    required bool perfStopped,
    required bool? perfArmed,
    required bool? perfFollowOutput,
    required int? perfCaptureBus,
    required int? perfCaptureMask,
    required int? perfOutputEnabledMask,
    required double? perfOutputLevel,
    required bool? perfOutputMuted,
  }) : super(
         isRunning: source.isRunning,
         sampleRate: source.sampleRate,
         bufferFrames: source.bufferFrames,
         framesProcessed: source.framesProcessed,
         xrunCount: source.xrunCount,
         inputRms: source.inputRms,
         inputPeak: source.inputPeak,
         outputRms: source.outputRms,
         latencyState: source.latencyState,
         measuredLatencyMs: source.measuredLatencyMs,
         outputPeak: source.outputPeak,
         devicePresent: source.devicePresent,
         inputChannels: source.inputChannels,
         outputChannels: source.outputChannels,
         excludedInputMask: source.excludedInputMask,
         inputClipMask: source.inputClipMask,
         inputCondMask: source.inputCondMask,
         masterLengthFrames: source.masterLengthFrames,
         masterPositionFrames: source.masterPositionFrames,
         recordOffsetFrames: source.recordOffsetFrames,
         fxAddedLatencyFrames: source.fxAddedLatencyFrames,
         masterGain: source.masterGain,
         tunerHz: source.tunerHz,
         tunerConfidence: source.tunerConfidence,
         tunerInput: source.tunerInput,
         activeBackend: source.activeBackend,
         outputEnabledMask: source.outputEnabledMask,
         isPerfArmed: perfArmed ?? source.isPerfArmed,
         perfFrames: source.perfFrames,
         perfOverruns: source.perfOverruns,
         perfZeroFilledFrames: source.perfZeroFilledFrames,
         perfStopped: perfStopped || source.perfStopped,
         perfFollowOutput: perfFollowOutput ?? source.perfFollowOutput,
         perfCaptureBus: perfCaptureBus ?? source.perfCaptureBus,
         perfCaptureMask: perfCaptureMask ?? source.perfCaptureMask,
         perfOutputEnabledMask:
             perfOutputEnabledMask ?? source.perfOutputEnabledMask,
         perfOutputLevel: perfOutputLevel ?? source.perfOutputLevel,
         perfOutputMuted: perfOutputMuted ?? source.perfOutputMuted,
         tempoBpm: source.tempoBpm,
         tempoSource: source.tempoSource,
         tsNum: source.tsNum,
         tsDen: source.tsDen,
         syncTempo: source.syncTempo,
         quantizeDiv: source.quantizeDiv,
         loopBars: source.loopBars,
         currentBeat: source.currentBeat,
         clickMode: source.clickMode,
         clickMask: source.clickMask,
         clickVolume: source.clickVolume,
         countInBars: source.countInBars,
         countingIn: source.countingIn,
         countInBeatsLeft: source.countInBeatsLeft,
         looperMode: mode ?? source.looperMode,
         primaryTrack: source.primaryTrack,
         quantize: source.quantize,
         autoRecord: source.autoRecord,
         overdubFeedback: source.overdubFeedback,
         mixRevision: mixRevision,
         inputPeaks: source.inputPeaks,
         monitorPeaks: source.monitorPeaks,
         outputPeaks: source.outputPeaks,
         tracks: [
           for (var channel = 0; channel < source.tracks.length; channel++)
             _LengthTrack(
               source.tracks[channel],
               lengths[channel],
               imageRevision: engine.imageRevisions[channel],
               solo: engine.trackSolo[channel],
             ),
         ],
       );
}

class _LengthTrack extends TrackSnapshot {
  _LengthTrack(
    TrackSnapshot source,
    int? bars, {
    int? imageRevision,
    bool? solo,
  }) : super(
         imageRevision: imageRevision ?? source.imageRevision,
         solo: solo ?? source.solo,
         peakL: source.peakL,
         peakR: source.peakR,
         state: source.state,
         volume: source.volume,
         muted: source.muted,
         lengthFrames: source.lengthFrames,
         undoDepth: source.undoDepth,
         rms: source.rms,
         peak: source.peak,
         clearRestore: source.clearRestore,
         redoDepth: source.redoDepth,
         multiple: source.multiple,
         inputMask: source.inputMask,
         outputMask: source.outputMask,
         layerInFlight: source.layerInFlight,
         pending: source.pending,
         lengthPresetBars: bars ?? source.lengthPresetBars,
         oneShot: source.oneShot,
         settledTakeId: source.settledTakeId,
         restoreState: source.restoreState,
         positionFrames: source.positionFrames,
         pendingTrigger: source.pendingTrigger,
         quantizeOverride: source.quantizeOverride,
         quantizeDivOverride: source.quantizeDivOverride,
         overdubFeedbackOverride: source.overdubFeedbackOverride,
         lanes: source.lanes,
       );
}
