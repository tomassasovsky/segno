import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart';

/// A controllable in-memory [AudioEngine] for repository tests.
class FakeAudioEngine implements AudioEngine {
  /// Snapshot returned by [snapshot] (mutate between ticks in tests).
  EngineSnapshot _nextSnapshot = const EngineSnapshot.initial();
  EngineSnapshot get nextSnapshot => _nextSnapshot;
  set nextSnapshot(EngineSnapshot value) {
    _nextSnapshot = value;
    publishedMode = null;
  }

  LooperMode? publishedMode;
  bool commandsAreSettled = true;
  bool publishClickCommands = true;
  bool publishLengthCommands = true;
  bool publishModeCommands = true;
  final Map<int, int> publishedLengths = {};

  /// Device name reported by [deviceName].
  String deviceNameValue = 'Fake Device';

  /// Records the command names forwarded to the engine, in order.
  final List<String> calls = <String>[];

  double? lastVolume;
  bool? lastMuted;
  EngineConfig? lastConfig;

  /// Result returned by [start].
  EngineResult startResult = EngineResult.ok;

  @override
  String get version => 'fake-engine';

  @override
  String get deviceName => deviceNameValue;

  @override
  EngineResult start(EngineConfig config) {
    lastConfig = config;
    calls.add('start');
    if (startResult.isOk) {
      pendingMix = null;
      pendingImages.clear();
      imageRevisions.clear();
      mixRevision = 0;
      liveMix.clear();
      sourceImages.clear();
      recipes.clear();
      recipeRevisions.clear();
      pendingRecipeRevisions.clear();
    }
    return startResult;
  }

  @override
  EngineResult stop() {
    calls.add('stop');
    return EngineResult.ok;
  }

  /// How many times [snapshot] was called — the FFI walk a periodic reader
  /// must not pay per tick.
  int snapshotCalls = 0;

  @override
  bool get commandsSettled =>
      commandsAreSettled && pendingRecipeRevisions.isEmpty;

  @override
  EngineSnapshot snapshot() {
    snapshotCalls++;
    return _LengthSnapshot(nextSnapshot, publishedLengths, publishedMode, this);
  }

  @override
  CallbackTelemetry callbackTelemetry() => nextCallbackTelemetry;

  /// The value [callbackTelemetry] returns.
  CallbackTelemetry nextCallbackTelemetry = CallbackTelemetry.empty;

  /// Loopback detection result returned by [detectLoopback].
  LoopbackInfo loopback = const LoopbackInfo.none();

  @override
  LoopbackInfo detectLoopback() {
    calls.add('detectLoopback');
    return loopback;
  }

  /// Devices returned by [enumerateDevices].
  List<AudioDevice> devices = const [];

  @override
  List<AudioDevice> enumerateDevices() {
    calls.add('enumerateDevices');
    return devices;
  }

  /// Drivers returned by [enumerateAsioDrivers].
  List<AudioDevice> asioDrivers = const [];

  @override
  List<AudioDevice> enumerateAsioDrivers() {
    calls.add('enumerateAsioDrivers');
    return asioDrivers;
  }

  @override
  EngineResult measureLatency() {
    calls.add('measureLatency');
    return EngineResult.ok;
  }

  /// Last channel seen by a channel-scoped command.
  int? lastChannel;

  EngineResult mixResult = EngineResult.ok;
  EngineResult recordResult = EngineResult.ok;
  bool publishMixCommands = true;
  bool publishRecordImages = true;
  int mixRevision = 0;
  final Map<(int, int), StereoMix> liveMix = {};
  final Map<(int, int), StereoMix> sourceImages = {};
  void composeLane((int, int) key) {
    final live = liveMix[key] ?? (gain: 1.0, pan: 0.0);
    final source = sourceImages[key] ?? (gain: 1.0, pan: 0.0);
    laneVol[key] = live.gain * source.gain;
    lanePan[key] = (live.pan + source.pan).clamp(-1.0, 1.0);
  }

  final Map<int, double> trackLevels = {};
  EngineMixSettings? pendingMix;
  final Map<int, RecordImage> pendingImages = {};
  RecordImage? lastRecordImage;
  final Map<int, int> imageRevisions = {};

  @override
  EngineResult setMix(EngineMixSettings settings) {
    calls.add('setMix');
    if (!settings.isValid) return EngineResult.invalid;
    if (!mixResult.isOk) return mixResult;
    pendingMix = settings;
    if (publishMixCommands) publishMix();
    return EngineResult.ok;
  }

  void publishMix() {
    final settings = pendingMix;
    if (settings == null) return;
    laneInput.addAll(settings.laneInputs);
    laneOutput.addAll(settings.laneOutputs);
    laneCount.addAll(settings.laneCounts);
    liveMix.addAll(settings.lanes);
    sourceImages.addAll(settings.images);
    <(int, int)>{
      ...settings.lanes.keys,
      ...settings.images.keys,
    }.forEach(composeLane);
    for (final e in settings.monitors.entries) {
      monitorVolume[e.key] = e.value.gain;
      monitorPan[e.key] = e.value.pan;
    }
    inputTrim.addAll(settings.trims);
    trackSolo.addAll(settings.solos);
    trackLevels.addAll(settings.trackLevels);
    for (final e in settings.outputs.entries) {
      outputLevel[e.key] = e.value.level;
      outputMuted[e.key] = e.value.muted;
      outputMono[e.key] = e.value.mono;
      outputBalance[e.key] = e.value.balance;
    }
    mixRevision = settings.revision;
    pendingMix = null;
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    lastRecordImage = image;
    final result = record(channel: channel);
    if (!result.isOk) return result;
    pendingImages[channel] = image;
    if (publishRecordImages) publishImage(channel);
    return EngineResult.ok;
  }

  void publishImage(int channel) {
    final image = pendingImages.remove(channel);
    if (image == null) return;
    // The native capture start force-unmutes every lane on the track.
    for (final key in laneMute.keys.where((key) => key.$1 == channel)) {
      laneMute[key] = false;
    }
    for (final e in image.lanes.entries) {
      sourceImages[(channel, e.key)] = e.value;
      composeLane((channel, e.key));
    }
    for (final e in image.laneFx.entries) {
      recipes[(FxOwner.lane, channel, e.key)] = e.value;
    }
    imageRevisions[channel] = image.revision;
  }

  @override
  EngineResult record({int channel = 0}) {
    lastChannel = channel;
    calls.add('record');
    return recordResult;
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    lastChannel = channel;
    calls.add('stopTrack');
    return EngineResult.ok;
  }

  @override
  EngineResult play({int channel = 0}) {
    lastChannel = channel;
    calls.add('play');
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    lastChannel = channel;
    calls.add('clear');
    return EngineResult.ok;
  }

  @override
  EngineResult clearUndoable({int channel = 0}) {
    lastChannel = channel;
    calls.add('clearUndoable');
    return nextClearUndoableResult;
  }

  EngineResult nextClearUndoableResult = EngineResult.ok;

  /// What the next [undo] would do. Tests set this to stand in for the engine's
  /// restore-point bookkeeping, which the real engine owns.
  bool undoRestoresClearResult = false;

  /// Per-channel override of [undoRestoresClearResult]: when set, only these
  /// channels restore a clear on their next undo.
  Set<int>? undoRestoresClearChannels;

  /// The channels whose next redo re-applies a clear.
  Set<int> redoReclearsChannels = {};

  /// The channels whose frozen restore point is still to be filed.
  Set<int> clearRestorePendingChannels = {};

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
    calls.add('historyModeGate');
    historyModeGateCalls.add((channels: channels, redo: redo));
    return nextHistoryModeGate;
  }

  @override
  bool clearRestorePending({int channel = 0}) =>
      clearRestorePendingChannels.contains(channel);

  @override
  bool redoReclears({int channel = 0}) {
    calls.add('redoReclears');
    return redoReclearsChannels.contains(channel);
  }

  @override
  bool undoRestoresClear({int channel = 0}) {
    lastChannel = channel;
    calls.add('undoRestoresClear');
    final channels = undoRestoresClearChannels;
    return channels == null
        ? undoRestoresClearResult
        : channels.contains(channel);
  }

  @override
  EngineResult undo({int channel = 0}) {
    lastChannel = channel;
    calls.add('undo');
    return nextUndoResult;
  }

  @override
  EngineResult redo({int channel = 0}) {
    lastChannel = channel;
    calls.add('redo');
    return nextRedoResult;
  }

  /// Per-channel active lane count passed to [setLaneCount].
  final Map<int, int> laneCount = {};

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    laneCount[channel] = count;
    calls.add('setLaneCount');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) volume passed to [setLaneVolume].
  final Map<(int, int), double> laneVol = {};

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    laneVol[(channel, lane)] = volume;
    lastVolume = volume;
    lastChannel = channel;
    calls.add('setLaneVolume');
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
    lastChannel = channel;
    calls.add('setLaneMute');
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
    calls.add('setLanePan');
    return EngineResult.ok;
  }

  /// Per-track solo passed to [setTrackSolo].
  final Map<int, bool> trackSolo = {};

  @override
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    trackSolo[channel] = solo;
    calls.add('setTrackSolo');
    return EngineResult.ok;
  }

  /// Per-input capture trim passed to [setInputTrim].
  final Map<int, double> inputTrim = {};

  @override
  EngineResult setInputTrim({required int input, required double gain}) {
    inputTrim[input] = gain;
    calls.add('setInputTrim');
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
    calls.add('setOutputLevel');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMute({required int bus, required bool muted}) {
    outputMuted[bus] = muted;
    calls.add('setOutputMute');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMono({required int bus, required bool mono}) {
    outputMono[bus] = mono;
    calls.add('setOutputMono');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputBalance({required int bus, required double balance}) {
    outputBalance[bus] = balance;
    calls.add('setOutputBalance');
    return EngineResult.ok;
  }

  @override
  EngineResult cutSound() {
    cutSoundCalls++;
    calls.add('cutSound');
    return EngineResult.ok;
  }

  @override
  EngineResult setPerfFollowOutput({required bool follow}) {
    perfFollowOutput = follow;
    calls.add('setPerfFollowOutput');
    return EngineResult.ok;
  }

  /// Per-input monitor pan passed to [setMonitorInputPan].
  final Map<int, double> monitorPan = {};

  @override
  EngineResult setMonitorInputPan({required int input, required double pan}) {
    monitorPan[input] = pan;
    calls.add('setMonitorInputPan');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) recorded input channel passed to [setLaneInput].
  final Map<(int, int), int> laneInput = {};

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    laneInput[(channel, lane)] = inputChannel;
    lastChannel = channel;
    calls.add('setLaneInput');
    return EngineResult.ok;
  }

  /// Per-(channel, lane) output mask passed to [setLaneOutput].
  final Map<(int, int), int> laneOutput = {};

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    laneOutput[(channel, lane)] = mask;
    lastChannel = channel;
    calls.add('setLaneOutput');
    return EngineResult.ok;
  }

  int? lastRecordOffset;

  @override
  EngineResult setRecordOffset(int frames) {
    lastRecordOffset = frames;
    calls.add('setRecordOffset');
    return EngineResult.ok;
  }

  bool? lastQuantize;

  @override
  EngineResult setQuantize({required bool enabled}) {
    lastQuantize = enabled;
    calls.add('setQuantize');
    return EngineResult.ok;
  }

  final Map<int, bool?> trackQuantize = {};

  @override
  EngineResult setTrackQuantize({
    required int channel,
    required bool? enabled,
  }) {
    trackQuantize[channel] = enabled;
    calls.add('setTrackQuantize');
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
    calls.add('setTrackQuantizeDiv');
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
    calls.add('setTrackOverdubFeedback');
    return EngineResult.ok;
  }

  final Map<int, int> trackMultiple = {};
  int? lastDefaultMultiple;
  bool? lastRecDub;
  bool? lastAutoRecord;
  double? lastMasterGain;

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    trackMultiple[channel] = multiple;
    calls.add('setTrackMultiple');
    return EngineResult.ok;
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    lastDefaultMultiple = multiple;
    calls.add('setDefaultMultiple');
    return EngineResult.ok;
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    lastRecDub = enabled;
    calls.add('setRecDub');
    return EngineResult.ok;
  }

  @override
  EngineResult setMasterGain(double gain) {
    lastMasterGain = gain;
    calls.add('setMasterGain');
    return EngineResult.ok;
  }

  @override
  EngineResult setAutoRecord({required bool enabled}) {
    lastAutoRecord = enabled;
    calls.add('setAutoRecord');
    return EngineResult.ok;
  }

  // ---- TempoControl ----

  double? lastTempoBpm;
  (int, int)? lastTimeSignature;
  bool? lastSyncTempo;
  GridDivision? lastQuantizeDiv;
  ClickMode? lastClickMode;
  int? lastClickOutput;
  double? lastClickVolume;
  int? lastCountIn;

  /// Exact session tempo restores in call order.
  final List<({double bpm, TempoSource source})> tempoRestores = [];

  @override
  EngineResult restoreTempo({
    required double bpm,
    required TempoSource source,
  }) {
    tempoRestores.add((bpm: bpm, source: source));
    calls.add('restoreTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setTempo(double bpm) {
    lastTempoBpm = bpm;
    calls.add('setTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setTimeSignature(int num, int den) {
    lastTimeSignature = (num, den);
    calls.add('setTimeSignature');
    return EngineResult.ok;
  }

  @override
  EngineResult tapTempo() {
    calls.add('tapTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    lastSyncTempo = on;
    calls.add('setSyncTempo');
    return EngineResult.ok;
  }

  @override
  EngineResult setQuantizeDiv(GridDivision div) {
    lastQuantizeDiv = div;
    calls.add('setQuantizeDiv');
    return EngineResult.ok;
  }

  @override
  EngineResult setClickMode(ClickMode mode) {
    lastClickMode = mode;
    calls.add('setClickMode');
    return EngineResult.ok;
  }

  @override
  EngineResult setClickOutput(int mask) {
    lastClickOutput = mask;
    calls.add('setClickOutput');
    return EngineResult.ok;
  }

  @override
  EngineResult setClickVolume(double volume) {
    lastClickVolume = volume;
    if (publishClickCommands) {
      nextSnapshot = nextSnapshot.copyWith(clickVolume: volume);
    }
    calls.add('setClickVolume');
    return EngineResult.ok;
  }

  @override
  EngineResult setCountIn(int bars) {
    lastCountIn = bars;
    calls.add('setCountIn');
    return EngineResult.ok;
  }

  final Map<int, int> trackLengthPreset = {};

  @override
  EngineResult setTrackLengthPreset({required int channel, required int bars}) {
    trackLengthPreset[channel] = bars;
    calls.add('setTrackLengthPreset');
    if (publishLengthCommands) publishedLengths[channel] = bars;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    calls.add('setTrackLengthPresets');
    for (var channel = 0; channel < bars.length; channel++) {
      trackLengthPreset[channel] = bars[channel];
      if (publishLengthCommands) publishedLengths[channel] = bars[channel];
    }
    return EngineResult.ok;
  }

  // ---- LooperModeControl ----

  LooperMode? lastLooperMode;

  /// What [looperModeGate] answers; tests set it to exercise a refusal.
  LooperModeGate nextLooperModeGate = LooperModeGate.open;

  @override
  LooperModeGate looperModeGate(LooperMode mode) {
    calls.add('looperModeGate');
    return nextLooperModeGate;
  }

  @override
  EngineResult setLooperMode(LooperMode mode) {
    lastLooperMode = mode;
    calls.add('setLooperMode');
    return switch (nextLooperModeGate) {
      LooperModeGate.capturing ||
      LooperModeGate.queued ||
      LooperModeGate.spans => EngineResult.invalid,
      LooperModeGate.open || LooperModeGate.playing => EngineResult.ok,
    };
  }

  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) {
    final result = setLooperMode(mode);
    if (!result.isOk) return result;
    if (publishModeCommands) publishedMode = mode;
    return setTrackLengthPresets(bars);
  }

  /// The last channel passed to [crownPrimary].
  int? lastCrownedChannel;

  @override
  EngineResult crownPrimary({required int channel}) {
    lastCrownedChannel = channel;
    calls.add('crownPrimary');
    return EngineResult.ok;
  }

  /// Per-track One Shot flags passed to [setOneShot].
  final Map<int, bool> trackOneShot = {};

  @override
  EngineResult setOneShot({required int channel, required bool oneShot}) {
    trackOneShot[channel] = oneShot;
    calls.add('setOneShot');
    return EngineResult.ok;
  }

  /// The last values passed to [setLimiter] / [setOverdubFeedback].
  bool? lastLimiterEnabled;
  double? lastLimiterCeiling;
  double? lastOverdubFeedback;

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    for (var channel = 0; channel < 8; channel++) {
      if ((channels & (1 << channel)) != 0) trackOneShot[channel] = oneShot;
    }
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) {
    lastLimiterEnabled = enabled;
    lastLimiterCeiling = ceiling;
    calls.add('setLimiter');
    return EngineResult.ok;
  }

  @override
  EngineResult setOverdubFeedback(double feedback) {
    lastOverdubFeedback = feedback;
    calls.add('setOverdubFeedback');
    return EngineResult.ok;
  }

  /// Per-(channel, lane, index) effect type passed to [setLaneFx].
  final Map<(int, int, int), TrackEffectType> laneFx = {};

  /// Per-(channel, lane) active chain length passed to [setLaneFxCount].
  final Map<(int, int), int> laneFxCount = {};

  /// Per-(channel, lane) leading Pre run passed to [setLaneFxCount].
  final Map<(int, int), int> laneFxPreCount = {};

  /// Per-(channel, lane, index, param) value passed to [setLaneFxParam].
  final Map<(int, int, int, int), double> laneFxParam = {};

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED, modeled like the real engine: an actual type CHANGE re-seeds
    // the slot's enabled flag to true, synchronously in this setter — so a
    // repository that pushes enabled bits BEFORE the type/count commands has
    // them clobbered here and fails tests exactly as it would on the native
    // engine (the migrated-disabled-bit bug class).
    if (laneFx[(channel, lane, index)] != type) {
      laneFxEnabled[(channel, lane, index)] = true;
    }
    laneFx[(channel, lane, index)] = type;
    calls.add('setLaneFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
    int preCount = 0,
  }) {
    // D-ENSEED's second half: a slot ENTERING the active window seeds
    // enabled, synchronously, like the engine's le_fx_seed_entering_slots.
    for (var s = laneFxCount[(channel, lane)] ?? 0; s < count; s++) {
      laneFxEnabled[(channel, lane, s)] = true;
    }
    laneFxCount[(channel, lane)] = count;
    // Clamped as the native setter clamps it, so a test asserting the pushed
    // split reads what the engine would actually store.
    laneFxPreCount[(channel, lane)] = preCount < 0
        ? 0
        : (preCount > count ? count : preCount);
    calls.add('setLaneFxCount');
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
    calls.add('setLaneFxParam');
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
    calls.add('setLaneFxEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) {
    laneFxChainEnabled[(channel, lane)] = enabled;
    calls.add('setLaneFxChainEnabled');
    return EngineResult.ok;
  }

  // ---- Track-stage + Master insert chains (FX v3 part 1b), recorded so
  // repository tests can assert the four-stage pushes. ----

  /// Per-(channel, index) effect type passed to [setTrackFx].
  final Map<(int, int), TrackEffectType> trackFx = {};

  /// Per-channel active chain length passed to [setTrackFxCount].
  final Map<int, int> trackFxCount = {};

  /// Per-channel leading Pre run passed to [setTrackFxCount].
  final Map<int, int> trackFxPreCount = {};

  /// Per-(channel, index, param) value passed to [setTrackFxParam].
  final Map<(int, int, int), double> trackFxParam = {};

  /// Per-(channel, index) flag passed to [setTrackFxEnabled].
  final Map<(int, int), bool> trackFxEnabled = {};

  /// Per-channel flag passed to [setTrackFxChainEnabled].
  final Map<int, bool> trackFxChainEnabled = {};

  /// Per-(bus, index) effect type passed to [setOutputFx].
  final Map<(int, int), TrackEffectType> outputFx = {};

  /// Per-bus active chain length passed to [setOutputFxCount].
  final Map<int, int> outputFxCount = {};

  /// Per-(bus, index, param) value passed to [setOutputFxParam].
  final Map<(int, int, int), double> outputFxParam = {};

  /// Per-(bus, index) flag passed to [setOutputFxEnabled].
  final Map<(int, int), bool> outputFxEnabled = {};

  /// Per-bus flag passed to [setOutputFxChainEnabled].
  final Map<int, bool> outputFxChainEnabled = {};

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
    calls.add('setTrackFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxCount({
    required int channel,
    required int count,
    int preCount = 0,
  }) {
    // D-ENSEED entering-slot seed — see [setLaneFxCount].
    for (var s = trackFxCount[channel] ?? 0; s < count; s++) {
      trackFxEnabled[(channel, s)] = true;
    }
    trackFxCount[channel] = count;
    trackFxPreCount[channel] = preCount < 0
        ? 0
        : (preCount > count ? count : preCount);
    calls.add('setTrackFxCount');
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
    calls.add('setTrackFxParam');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) {
    trackFxEnabled[(channel, index)] = enabled;
    calls.add('setTrackFxEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxChainEnabled({
    required int channel,
    required bool enabled,
  }) {
    trackFxChainEnabled[channel] = enabled;
    calls.add('setTrackFxChainEnabled');
    return EngineResult.ok;
  }

  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) =>
      const OutputFxSnapshot();

  @override
  EngineResult setOutputFx({
    required int bus,
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED re-seed on type change — see [setLaneFx].
    if (outputFx[(bus, index)] != type) {
      outputFxEnabled[(bus, index)] = true;
    }
    outputFx[(bus, index)] = type;
    calls.add('setOutputFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxCount({required int bus, required int count}) {
    // D-ENSEED entering-slot seed — see [setLaneFxCount].
    for (var s = outputFxCount[bus] ?? 0; s < count; s++) {
      outputFxEnabled[(bus, s)] = true;
    }
    outputFxCount[bus] = count;
    calls.add('setOutputFxCount');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) {
    outputFxParam[(bus, index, param)] = value;
    calls.add('setOutputFxParam');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) {
    outputFxEnabled[(bus, index)] = enabled;
    calls.add('setOutputFxEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxChainEnabled({
    required int bus,
    required bool enabled,
  }) {
    outputFxChainEnabled[bus] = enabled;
    calls.add('setOutputFxChainEnabled');
    return EngineResult.ok;
  }

  /// Chain entry types passed to [setAllTracksFx], by index.
  final Map<int, TrackEffectType> allTracksFx = {};

  /// The active chain length passed to [setAllTracksFxCount].
  int allTracksFxCount = 0;

  /// Params passed to [setAllTracksFxParam], by (index, param).
  final Map<(int, int), double> allTracksFxParam = {};

  /// Per-entry flags passed to [setAllTracksFxEnabled].
  final Map<int, bool> allTracksFxEnabled = {};

  /// The flag passed to [setAllTracksFxChainEnabled].
  bool? allTracksFxChainEnabled;

  @override
  EngineResult setAllTracksFx({
    required int index,
    required TrackEffectType type,
  }) {
    // D-ENSEED re-seed on type change — see [setLaneFx].
    if (allTracksFx[index] != type) allTracksFxEnabled[index] = true;
    allTracksFx[index] = type;
    calls.add('setAllTracksFx');
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxCount({required int count}) {
    for (var s = allTracksFxCount; s < count; s++) {
      allTracksFxEnabled[s] = true;
    }
    allTracksFxCount = count;
    calls.add('setAllTracksFxCount');
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxParam({
    required int index,
    required int param,
    required double value,
  }) {
    allTracksFxParam[(index, param)] = value;
    calls.add('setAllTracksFxParam');
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxEnabled({
    required int index,
    required bool enabled,
  }) {
    allTracksFxEnabled[index] = enabled;
    calls.add('setAllTracksFxEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxChainEnabled({required bool enabled}) {
    allTracksFxChainEnabled = enabled;
    calls.add('setAllTracksFxChainEnabled');
    return EngineResult.ok;
  }

  /// Per-(channel, lane, index) channel handling passed to
  /// [setLaneFxChannels].
  final Map<(int, int, int), FxChannels> laneFxChannels = {};

  /// Per-(input, index) channel handling passed to
  /// [setMonitorInputFxChannels].
  final Map<(int, int), FxChannels> monitorFxChannels = {};

  @override
  EngineResult setLaneFxChannels({
    required int channel,
    required int lane,
    required int index,
    required FxChannels channels,
  }) {
    laneFxChannels[(channel, lane, index)] = channels;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxChannels({
    required int input,
    required int index,
    required FxChannels channels,
  }) {
    monitorFxChannels[(input, index)] = channels;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxChannels({
    required int channel,
    required int index,
    required FxChannels channels,
  }) => EngineResult.ok;

  @override
  EngineResult setOutputFxChannels({
    required int bus,
    required int index,
    required FxChannels channels,
  }) => EngineResult.ok;

  @override
  EngineResult setAllTracksFxChannels({
    required int index,
    required FxChannels channels,
  }) => EngineResult.ok;

  /// Per-input enabled flag passed to [setMonitorInputEnabled].
  final Map<int, bool> monitorInputEnabled = {};

  /// The input the tuner is armed on, or `-1`. Mirrors the native gate, so a
  /// test can assert that a closed face leaves nothing running.
  int tunerInput = -1;

  @override
  EngineResult setTunerInput({required int input}) {
    tunerInput = input;
    calls.add('setTunerInput');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorInputEnabled[input] = enabled;
    calls.add('setMonitorInputEnabled');
    return EngineResult.ok;
  }

  /// Per-input monitor output mask passed to [setMonitorInputOutput].
  final Map<int, int> monitorOutput = {};

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    monitorOutput[input] = mask;
    calls.add('setMonitorInputOutput');
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
    calls.add('setMonitorInputVolume');
    return EngineResult.ok;
  }

  /// Per-input monitor mute passed to [setMonitorInputMute].
  final Map<int, bool> monitorMute = {};

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    monitorMute[input] = muted;
    calls.add('setMonitorInputMute');
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
    calls.add('setInputConditioningEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) {
    conditioningParam[(input, param)] = value;
    calls.add('setInputConditioningParam');
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
    calls.add('setMonitorInputFx');
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
    calls.add('setMonitorInputFxCount');
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
    calls.add('setMonitorInputFxParam');
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
    calls.add('setMonitorInputFxEnabled');
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxChainEnabled({
    required int input,
    required bool enabled,
  }) {
    monitorFxChainEnabled[input] = enabled;
    calls.add('setMonitorInputFxChainEnabled');
    return EngineResult.ok;
  }

  /// Overridable fingerprints so a test can drive the divergence-detection path
  /// without a real engine; default to the empty-chain basis.
  int laneFingerprint = FxFingerprint.offset;
  int monitorFingerprint = FxFingerprint.offset;

  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      laneFingerprint;

  @override
  int monitorFxFingerprint({required int input}) => monitorFingerprint;

  /// Per-lane cache states this fake reports, keyed by `(channel, lane)`;
  /// anything unseeded reads as [LaneCacheState.live].
  final Map<(int, int), LaneCacheState> seededLaneCacheStates = {};

  /// How many batched [laneCacheStates] sweeps ran, in call order — how a
  /// test proves the telemetry gate actually stops the engine read rather
  /// than just hiding the result, and that a poll runs exactly one sweep.
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
    calls.add('setOutputEnabled');
    return EngineResult.ok;
  }

  @override
  Float32List exportTrack(int channel) {
    calls.add('exportTrack');
    return Float32List(0);
  }

  @override
  Float32List exportTrackLane(int channel, int lane) {
    calls.add('exportTrackLane');
    return Float32List(0);
  }

  /// Lane-0 live PCM passed to [importLayer], keyed by channel — kept for the
  /// single-lane assertions existing tests make.
  final Map<int, Float32List> importedTracks = {};

  /// Live-buffer (ordinal 0) PCM passed to [importLayer], keyed by
  /// `(channel, lane)`. Sufficient for the single-layer restore assertions.
  final Map<(int, int), Float32List> importedLanes = {};

  /// Every layer PCM passed to [importLayer], keyed by
  /// `(channel, lane, ordinal)`.
  final Map<(int, int, int), Float32List> importedLayers = {};

  /// `(undoCount, redoCount)` passed to [finalizeLayers], keyed by channel.
  final Map<int, (int, int)> finalizedLayers = {};

  /// Result returned by [importLayer] once any [importFailCountdown] is spent.
  EngineResult importResult = EngineResult.ok;

  /// If `> 0`, the first import (lane 0, ordinal 0) returns
  /// [EngineResult.invalid] this many times (decrementing) before honoring
  /// [importResult] — exercises the posted-clear ack retry in `applySession`.
  int importFailCountdown = 0;

  @override
  EngineResult importTrack(int channel, Float32List pcm) =>
      importTrackLane(channel, 0, pcm);

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) =>
      importLayer(channel, lane, 0, pcm);

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    calls.add('exportLayer');
    return Float32List(0);
  }

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    calls.add('importLayer');
    // Only the very first import (lane 0, ordinal 0) races the clear ack.
    if (lane == 0 && ordinal == 0 && importFailCountdown > 0) {
      importFailCountdown--;
      return EngineResult.invalid;
    }
    if (importResult.isOk) {
      importedLayers[(channel, lane, ordinal)] = pcm;
      if (ordinal == 0) {
        importedLanes[(channel, lane)] = pcm;
        if (lane == 0) importedTracks[channel] = pcm;
      }
    }
    return importResult;
  }

  @override
  EngineResult finalizeLayers(int channel, int undoCount, int redoCount) {
    calls.add('finalizeLayers');
    finalizedLayers[channel] = (undoCount, redoCount);
    return EngineResult.ok;
  }

  /// Base frames passed to the last [commitSession].
  int? committedBaseFrames;

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) {
    calls.add('commitSession');
    committedBaseFrames = baseFrames;
    return EngineResult.ok;
  }

  /// Result returned by [perfArm] / [perfDisarm].
  EngineResult perfArmResult = EngineResult.ok;
  EngineResult perfDisarmResult = EngineResult.ok;

  /// The `captureDir` passed to the most recent [perfArm] call.
  String? lastPerfCaptureDir;

  @override
  EngineResult perfArm(String captureDir) {
    calls.add('perfArm');
    lastPerfCaptureDir = captureDir;
    return perfArmResult;
  }

  @override
  EngineResult perfDisarm() {
    calls.add('perfDisarm');
    return perfDisarmResult;
  }

  @override
  EngineResult renderBegin(String captureDir) {
    calls.add('renderBegin');
    return EngineResult.ok;
  }

  @override
  PerformanceRenderProgress renderPoll() => PerformanceRenderProgress.empty;

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() => const [];

  @override
  EngineResult renderCancel() {
    calls.add('renderCancel');
    return EngineResult.ok;
  }

  @override
  void dispose() => calls.add('dispose');

  /// Waveform returned by [readVisual] (mutate in tests).
  Float32List visual = Float32List(0);

  @override
  Float32List readVisual() {
    calls.add('readVisual');
    return visual;
  }

  @override
  Float32List readTrackVisual(int channel) {
    calls.add('readTrackVisual');
    return visual;
  }

  /// Descriptors returned by [scanResults] once a scan has begun.
  List<PluginDescriptor> pluginScanResults = const [];

  /// Optional override for [scanPoll]; defaults to a finished scan that found
  /// every entry in [pluginScanResults].
  PluginScanProgress? scanProgressOverride;

  /// Result returned by [scanBegin] (set to a non-ok value to exercise the
  /// catalog's begin-failure path).
  EngineResult scanBeginResult = EngineResult.ok;

  bool _scanning = false;

  @override
  EngineResult scanBegin({bool rescan = false}) {
    calls.add('scanBegin');
    if (!scanBeginResult.isOk) return scanBeginResult;
    _scanning = true;
    return scanBeginResult;
  }

  @override
  PluginScanProgress scanPoll() =>
      scanProgressOverride ??
      PluginScanProgress(
        done: true,
        found: pluginScanResults.length,
        scanned: pluginScanResults.length,
        total: pluginScanResults.length,
      );

  @override
  List<PluginDescriptor> scanResults() =>
      _scanning ? pluginScanResults : const [];

  @override
  EngineResult scanCancel() {
    _scanning = false;
    calls.add('scanCancel');
    return EngineResult.ok;
  }

  /// Handle returned by [setLanePlugin] / [setMonitorPlugin]; set to `null` to
  /// simulate a load failure.
  PluginSlotHandle? nextSlotHandle = MockPluginSlotHandle('fake-plugin');

  /// Atomic structural recipes and callback-applied identities.
  final Map<(FxOwner, int, int), FxRecipe> recipes = {};
  final Map<(FxOwner, int, int), int> recipeRevisions = {};
  final Map<(FxOwner, int, int), int> pendingRecipeRevisions = {};
  EngineResult nextRecipeResult = EngineResult.ok;
  bool publishRecipes = true;

  @override
  EngineResult setFxRecipe({
    required FxOwner owner,
    required FxRecipe recipe,
    required int revision,
    int channel = 0,
    int lane = 0,
  }) {
    calls.add('setFxRecipe');
    if (!recipe.isValid || revision == 0) return EngineResult.invalid;
    final result = nextRecipeResult;
    if (!result.isOk) return result;
    final key = (owner, channel, lane);
    if (pendingRecipeRevisions.containsKey(key)) return EngineResult.notReady;
    recipes[key] = recipe;
    pendingRecipeRevisions[key] = revision;
    if (publishRecipes) publishRecipe(key);
    return result;
  }

  void publishRecipe((FxOwner, int, int) key) {
    final revision = pendingRecipeRevisions.remove(key);
    if (revision != null) recipeRevisions[key] = revision;
  }

  @override
  int fxRecipeRevision({
    required FxOwner owner,
    int channel = 0,
    int lane = 0,
  }) => recipeRevisions[(owner, channel, lane)] ?? 0;

  @override
  PluginSlotHandle? preparePlugin({required String pluginId}) {
    calls.add('preparePlugin');
    return nextSlotHandle;
  }

  @override
  EngineResult discardPreparedPlugin(PluginSlotHandle slot) {
    calls.add('discardPreparedPlugin');
    return EngineResult.ok;
  }

  @override
  EngineResult preparePluginParam(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    calls.add('preparePluginParam');
    preparedPluginParams.add((slot: slot, paramId: paramId, value: value));
    return EngineResult.ok;
  }

  /// Values applied to detached hosts before their complete recipe is admitted.
  final List<({PluginSlotHandle slot, int paramId, double value})>
  preparedPluginParams = [];

  /// Plugin ids passed to [setLanePlugin], keyed by `(channel, lane, index)`.
  final Map<(int, int, int), String> lanePlugins = {};

  /// Plugin ids passed to [setMonitorPlugin], keyed by `(input, index)`.
  final Map<(int, int), String> monitorPlugins = {};

  /// Param surface returned by [pluginParamInfos] (the loaded plugin's knobs).
  List<PluginParamInfo> nextParamInfos = const [];

  /// Live values [pluginParamGet] returns, keyed by param id — lets a test
  /// simulate an editor moving a param (the D-SYNC inbound read-back).
  final Map<int, double> nextParamValues = {};

  /// Display strings [pluginParamValueText] returns, keyed by
  /// `(paramId, value)` — lets a test seed discrete step labels / continuous
  /// readouts. An absent key returns null (no text), as the real ABI does.
  final Map<(int, double), String> paramValueTexts = {};

  /// Every `(slot, paramId, value)` triple passed to [pluginParamSet], in call
  /// order — so a test can assert the RT-queued sets and their ordering.
  final List<({PluginSlotHandle slot, int paramId, double value})>
  pluginParamSets = [];

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) {
    calls.add('setLanePlugin');
    lanePlugins[(channel, lane, index)] = pluginId;
    return nextSlotHandle;
  }

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) {
    calls.add('setMonitorPlugin');
    monitorPlugins[(input, index)] = pluginId;
    return nextSlotHandle;
  }

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) {
    calls.add('clearLanePlugin');
    return EngineResult.ok;
  }

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) {
    calls.add('clearMonitorPlugin');
    return EngineResult.ok;
  }

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) {
    calls.add('pluginParamInfos');
    return nextParamInfos;
  }

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    calls.add('pluginParamGet');
    return nextParamValues[paramId] ?? 0;
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    calls.add('pluginParamValueText');
    return paramValueTexts[(paramId, value)];
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    calls.add('pluginParamSet');
    pluginParamSets.add((slot: slot, paramId: paramId, value: value));
    return EngineResult.ok;
  }

  /// Slots whose (fake) native editor is currently open.
  final Set<PluginSlotHandle> openEditors = {};

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    calls.add('pluginEditorOpen');
    openEditors.add(slot);
    return EngineResult.ok;
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    calls.add('pluginEditorClose');
    openEditors.remove(slot);
    return EngineResult.ok;
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) => openEditors.contains(slot);

  /// Fake opaque state returned by [pluginStateGet] (configure per test); the
  /// last blob passed to [pluginStateSet] is recorded for assertions.
  Uint8List nextState = Uint8List(0);
  final List<Uint8List> stateSets = [];

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) {
    calls.add('pluginStateGet');
    return nextState;
  }

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    calls.add('pluginStateSet');
    stateSets.add(state);
    return EngineResult.ok;
  }

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

  @override
  int? volumeFreeBytes(String path) => freeBytes;

  /// What [volumeFreeBytes] reports; `null` models a platform that cannot
  /// answer.
  int? freeBytes = 1 << 40;
}

class _LengthSnapshot extends EngineSnapshot {
  _LengthSnapshot(
    EngineSnapshot source,
    Map<int, int> lengths,
    LooperMode? mode,
    FakeAudioEngine engine,
  ) : super(
        mixRevision: engine.mixRevision,
        inputPeaks: source.inputPeaks,
        monitorPeaks: source.monitorPeaks,
        outputPeaks: source.outputPeaks,
        outputBusCount: source.outputBusCount,
        outputLevels: source.outputLevels,
        outputMuted: source.outputMuted,
        outputMono: source.outputMono,
        outputBalances: source.outputBalances,
        tailResetRev: source.tailResetRev,
        perfFollowOutput: source.perfFollowOutput,
        perfCaptureBus: source.perfCaptureBus,
        perfOutputLevel: source.perfOutputLevel,
        perfOutputMuted: source.perfOutputMuted,
        perfCaptureMask: source.perfCaptureMask,
        perfOutputEnabledMask: source.perfOutputEnabledMask,
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
        isPerfArmed: source.isPerfArmed,
        perfFrames: source.perfFrames,
        perfOverruns: source.perfOverruns,
        perfZeroFilledFrames: source.perfZeroFilledFrames,
        perfStopped: source.perfStopped,
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
        tracks: [
          for (var channel = 0; channel < source.tracks.length; channel++)
            _LengthTrack(
              source.tracks[channel],
              lengths[channel],
              engine,
              channel,
            ),
        ],
      );
}

class _LengthTrack extends TrackSnapshot {
  _LengthTrack(
    TrackSnapshot source,
    int? bars,
    FakeAudioEngine engine,
    int channel,
  ) : super(
        imageRevision: engine.imageRevisions[channel] ?? source.imageRevision,
        solo: engine.trackSolo[channel] ?? source.solo,
        peakL: source.peakL,
        peakR: source.peakR,
        state: source.state,
        volume: engine.trackLevels[channel] ?? source.volume,
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
        lanes: [
          for (var lane = 0; lane < source.lanes.length; lane++)
            _MixLane(source.lanes[lane], engine, (channel, lane)),
        ],
      );
}

class _MixLane extends LaneSnapshot {
  _MixLane(LaneSnapshot source, FakeAudioEngine engine, (int, int) key)
    : super(
        inputChannel: source.inputChannel,
        outputMask: source.outputMask,
        volume: engine.laneVol[key] ?? source.volume,
        pan: engine.lanePan[key] ?? source.pan,
        muted: source.muted,
        lengthFrames: source.lengthFrames,
        rms: source.rms,
        peak: source.peak,
        recoverable: source.recoverable,
      );
}
