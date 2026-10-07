import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart';

class _FakeLane {
  int inputChannel = -1;
  int outputMask = 0x3;
  double volume = 1;
  bool muted = false;
  double pan = 0;

  /// Ordinal-ordered layer buffers (undo… live … redo). Its length is the
  /// owning track's image count; a single-layer lane holds just the live
  /// buffer.
  List<Float32List> layers = [Float32List(0)];
}

class _FakeTrack {
  TrackState state = TrackState.empty;

  /// The content revision; every seed is a write and bumps it.
  int audioRev = 0;
  int multiple = 1;
  int lengthFrames = 0;

  /// The raw undo stack count: the split of [history] and the live ordinal.
  int undoCount = 0;
  int redoDepth = 0;

  /// The undo depth the snapshot publishes when it differs from [undoCount]
  /// (the engine reads 0 while a Clear restore is in flight); null publishes
  /// [undoCount].
  int? publishedUndoDepth;

  /// The track's history entries ([AudioEngine.exportHistory] order); its
  /// length is `undoCount + redoDepth`.
  List<HistoryEntry> history = const [];
  bool solo = false;
  bool reversed = false;
  final List<_FakeLane> lanes = [_FakeLane()];

  int get liveIndex => undoCount;

  // Lane-0 conveniences (the single-lane accessors the setters/seed use).
  double volume = 1;
  bool get muted => lanes[0].muted;
  set muted(bool m) => lanes[0].muted = m;
  Float32List liveOf(int lane) => lanes[lane].layers[liveIndex];
}

/// A stateful in-memory [AudioEngine] that models the looper state, settings,
/// and per-track PCM closely enough to exercise the session repository's
/// save/load without the native engine.
class FakeSessionEngine implements AudioEngine {
  FakeSessionEngine({this.channels = 1, this.sampleRate = 48000});

  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) =>
      const OutputFxSnapshot();

  final int channels;
  final int sampleRate;

  // 8 tracks, matching the real engine's LE_MAX_TRACKS (segno_engine_api.h) —
  // needed to exercise B5c's Free-mode 8-independent-lengths round trip.
  final List<_FakeTrack> _tracks = List.generate(8, (_) => _FakeTrack());
  int masterLength = 0;
  int mixRevision = 0;

  /// The session-level looper mode reported by [snapshot] (B5c). Mutable so a
  /// test can seed a non-default mode before calling
  /// `SessionRepository.save`, exercising the real `_sessionFrom` wiring.
  LooperMode looperMode = LooperMode.multi;

  /// The session-level crowned primary track reported by [snapshot] (B5c,
  /// D18); `-1` = none.
  int primaryTrack = -1;

  /// Per-track record timing and decay overrides reported by [snapshot]
  /// (slice 2b), keyed by channel; absent = inherit.
  final Map<int, bool> quantizeOverride = {};
  final Map<int, GridDivision> quantizeDivOverride = {};
  final Map<int, double> overdubFeedbackOverride = {};

  /// The record start gate and the global overdub feedback reported by
  /// [snapshot] (slice 2b).
  bool quantize = false;
  double overdubFeedback = 1;

  // ---- tempo grid + click + count-in (A1/A2, threaded to Session v4 by A7)
  // ----
  // Mutable so a test can seed non-default grid state before calling
  // `SessionRepository.save`, exercising the actual `_sessionFrom` wiring
  // rather than trusting it by inspection. Defaults mirror
  // `EngineSnapshot`'s own tempo-free defaults.
  double tempoBpm = 0;
  TempoSource tempoSource = TempoSource.none;
  int tsNum = 4;
  int tsDen = 4;
  GridDivision quantizeDiv = GridDivision.off;
  ClickMode clickMode = ClickMode.off;
  int clickMask = 0;
  double clickVolume = 1;
  int countInBars = 0;

  /// While > 0, every snapshot reports track 0's undo layer as in flight and
  /// decrements — simulating the punch-out fade-tail/drain window a capture
  /// must wait out.
  int layerInFlightPolls = 0;

  /// Seeds a playing track with [pcm] on lane 0 and sets the base loop length
  /// from it. Seed consistent tracks (same base) — the last call wins.
  void seedTrack(
    int channel,
    Float32List pcm, {
    int multiple = 1,
    double volume = 1,
    double trackVolume = 1,
    bool muted = false,
    bool reversed = false,
  }) {
    final frames = pcm.length ~/ channels;
    final track = _tracks[channel]
      ..reversed = reversed
      ..volume = trackVolume
      ..state = TrackState.playing
      ..multiple = multiple
      ..lengthFrames = frames
      ..undoCount = 0
      ..redoDepth = 0
      ..publishedUndoDepth = null
      ..history = const [];
    track.audioRev++;
    track.lanes[0]
      ..layers = [pcm]
      ..volume = volume
      ..muted = muted
      ..inputChannel = 0;
    masterLength = frames ~/ multiple;
  }

  /// Seeds a playing single-lane track with an ordinal-ordered [layers] stack
  /// and its shared [undoDepth] / [redoDepth] — exercises overdub-layer capture.
  /// The live buffer is `layers[undoDepth]`. [history] defaults to one overdub
  /// layer per undo/redo entry; a history with redo-side Peel markers names
  /// fewer images than entries. [publishedUndoDepth] makes the snapshot
  /// publish a different undo depth than the raw [undoDepth], as the engine
  /// does while a Clear restore is in flight.
  void seedLayers(
    int channel,
    List<Float32List> layers, {
    int undoDepth = 0,
    int redoDepth = 0,
    int? publishedUndoDepth,
    List<HistoryEntry>? history,
    int multiple = 1,
    double volume = 1,
    bool muted = false,
  }) {
    final frames = layers[undoDepth].length ~/ channels;
    final track = _tracks[channel]
      ..state = TrackState.playing
      ..multiple = multiple
      ..lengthFrames = frames
      ..undoCount = undoDepth
      ..redoDepth = redoDepth
      ..publishedUndoDepth = publishedUndoDepth
      ..history =
          history ??
          List.filled(
            undoDepth + redoDepth,
            const HistoryEntry(HistoryKind.layer),
          );
    track.audioRev++;
    track.lanes[0]
      ..layers = List.of(layers)
      ..volume = volume
      ..muted = muted
      ..inputChannel = 0;
    masterLength = frames ~/ multiple;
  }

  /// Adds a further lane [lane] to an already-seeded playing track, so a
  /// multi-lane capture can be exercised. Lanes must share the track's length.
  void seedLane(
    int channel,
    int lane,
    Float32List pcm, {
    double volume = 1,
    bool muted = false,
    int outputMask = 0x3,
    int? inputChannel,
  }) {
    final track = _tracks[channel];
    track.audioRev++;
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane]
      ..layers = [pcm]
      ..volume = volume
      ..muted = muted
      ..outputMask = outputMask
      ..inputChannel = inputChannel ?? lane;
  }

  @override
  int trackAudioRev(int channel) =>
      channel < 0 || channel >= _tracks.length ? 0 : _tracks[channel].audioRev;

  @override
  CallbackTelemetry callbackTelemetry() => CallbackTelemetry.empty;

  @override
  bool get commandsSettled => true;

  @override
  EngineSnapshot snapshot() => EngineSnapshot(
    isRunning: true,
    sampleRate: sampleRate,
    bufferFrames: 128,
    framesProcessed: 0,
    xrunCount: 0,
    inputRms: 0,
    inputPeak: 0,
    outputRms: 0,
    latencyState: LatencyState.idle,
    measuredLatencyMs: -1,
    masterLengthFrames: masterLength,
    mixRevision: mixRevision,
    tempoBpm: tempoBpm,
    tempoSource: tempoSource,
    tsNum: tsNum,
    tsDen: tsDen,
    quantizeDiv: quantizeDiv,
    clickMode: clickMode,
    clickMask: clickMask,
    clickVolume: clickVolume,
    countInBars: countInBars,
    looperMode: looperMode,
    primaryTrack: primaryTrack,
    quantize: quantize,
    overdubFeedback: overdubFeedback,
    tracks: [
      for (final (i, t) in _tracks.indexed)
        TrackSnapshot(
          state: t.state,
          volume: t.volume,
          muted: t.muted,
          lengthFrames: t.lengthFrames,
          undoDepth: t.publishedUndoDepth ?? t.undoCount,
          redoDepth: t.redoDepth,
          rms: 0,
          peak: 0,
          multiple: t.multiple,
          quantizeOverride: quantizeOverride[i],
          quantizeDivOverride: quantizeDivOverride[i],
          overdubFeedbackOverride: overdubFeedbackOverride[i],
          layerInFlight: i == 0 && _consumeInFlightPoll(),
          solo: t.solo,
          reversed: t.reversed,
          lanes: [
            for (final lane in t.lanes)
              LaneSnapshot(
                inputChannel: lane.inputChannel,
                outputMask: lane.outputMask,
                volume: lane.volume,
                muted: lane.muted,
                pan: lane.pan,
                lengthFrames: t.lengthFrames,
                rms: 0,
                peak: 0,
              ),
          ],
        ),
    ],
  );

  bool _consumeInFlightPoll() {
    if (layerInFlightPolls <= 0) return false;
    layerInFlightPolls--;
    return true;
  }

  @override
  Float32List exportTrack(int channel) =>
      Float32List.fromList(_tracks[channel].liveOf(0));

  @override
  Float32List exportTrackLane(int channel, int lane) {
    final track = _tracks[channel];
    if (lane < 0 || lane >= track.lanes.length) return Float32List(0);
    return Float32List.fromList(track.liveOf(lane));
  }

  /// How many layers have been exported, so a test can tell a read that
  /// copies audio from one that does not.
  int exportedLayers = 0;

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    exportedLayers++;
    final track = _tracks[channel];
    if (lane < 0 || lane >= track.lanes.length) return Float32List(0);
    final layers = track.lanes[lane].layers;
    if (ordinal < 0 || ordinal >= layers.length) return Float32List(0);
    return Float32List.fromList(layers[ordinal]);
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) =>
      importTrackLane(channel, 0, pcm);

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) {
    final track = _tracks[channel];
    if (track.state != TrackState.empty) return EngineResult.invalid;
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane].layers = [Float32List.fromList(pcm)];
    track.lengthFrames = pcm.length ~/ channels;
    return EngineResult.ok;
  }

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    // Not exercised by the session repository (importing is the looper's job);
    // an inert success keeps the interface satisfied.
    return EngineResult.ok;
  }

  @override
  TrackHistory exportHistory(int channel) => TrackHistory(
    _tracks[channel].history,
    undoCount: _tracks[channel].undoCount,
  );

  @override
  EngineResult finalizeHistory(int channel, TrackHistory history) =>
      EngineResult.ok;

  /// Puts track [channel] in [state] without touching its audio, as a
  /// transport press or a punch-in does.
  void setTrackState(int channel, TrackState state) =>
      _tracks[channel].state = state;

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) {
    if (baseFrames <= 0) return EngineResult.invalid;
    masterLength = baseFrames;
    for (final track in _tracks) {
      if (track.state == TrackState.empty && track.lengthFrames > 0) {
        track
          ..multiple = track.lengthFrames ~/ baseFrames
          ..state = TrackState.stopped;
      }
    }
    return EngineResult.ok;
  }

  @override
  EngineResult clear({int channel = 0}) {
    _tracks[channel]
      ..state = TrackState.empty
      ..multiple = 1
      ..lengthFrames = 0
      ..undoCount = 0
      ..redoDepth = 0
      ..publishedUndoDepth = null
      ..history = const []
      ..lanes.clear();
    _tracks[channel].lanes.add(_FakeLane());
    if (_tracks.every((t) => t.state == TrackState.empty)) masterLength = 0;
    return EngineResult.ok;
  }

  /// Erases exactly like [clear]. This fake models the session-load path, which
  /// never restores a cleared take, so the restore point is not modelled — the
  /// engine's own tests cover it.
  @override
  EngineResult clearUndoable({int channel = 0}) => clear(channel: channel);

  @override
  bool undoRestoresClear({int channel = 0}) => false;

  @override
  bool redoReclears({int channel = 0}) => false;

  @override
  bool clearRestorePending({int channel = 0}) => false;

  @override
  EngineResult historyModeGate({required int channels, required bool redo}) =>
      EngineResult.ok;

  @override
  EngineResult setLaneCount({required int channel, required int count}) =>
      EngineResult.ok;

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    _tracks[channel].lanes[lane].volume = volume;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    _tracks[channel].muted = muted;
    return EngineResult.ok;
  }

  @override
  EngineResult setLanePan({
    required double pan,
    int channel = 0,
    int lane = 0,
  }) {
    final track = _tracks[channel];
    while (track.lanes.length <= lane) {
      track.lanes.add(_FakeLane());
    }
    track.lanes[lane].pan = pan;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    _tracks[channel].solo = solo;
    return EngineResult.ok;
  }

  @override
  EngineResult setInputTrim({required int input, required double gain}) =>
      EngineResult.ok;
  @override
  EngineResult setOutputLevel({required int bus, required double level}) =>
      EngineResult.ok;
  @override
  EngineResult setOutputMute({required int bus, required bool muted}) =>
      EngineResult.ok;
  @override
  EngineResult setOutputMono({required int bus, required bool mono}) =>
      EngineResult.ok;
  @override
  EngineResult setOutputBalance({required int bus, required double balance}) =>
      EngineResult.ok;
  @override
  EngineResult cutSound() => EngineResult.ok;
  @override
  EngineResult setPerfFollowOutput({required bool follow}) => EngineResult.ok;

  // ---- unused by SessionRepository: inert defaults ----
  @override
  String get version => 'fake';
  @override
  String get deviceName => 'fake';
  @override
  EngineResult start(EngineConfig config) => EngineResult.ok;
  @override
  EngineResult stop() => EngineResult.ok;
  @override
  ReopenResult reopen(EngineConfig config) => (
    result: EngineResult.ok,
    outcome: ReopenOutcome.retained,
    droppedTracks: 0,
  );
  @override
  LoopbackInfo detectLoopback() => const LoopbackInfo.none();
  @override
  List<AudioDevice> enumerateDevices() => const [];
  @override
  List<AudioDevice> enumerateAsioDrivers() => const [];
  @override
  EngineResult measureLatency() => EngineResult.ok;
  final _fxRevisions = <(FxOwner, int, int), int>{};

  @override
  EngineResult setFxRecipe({
    required FxOwner owner,
    required FxRecipe recipe,
    required int revision,
    int channel = 0,
    int lane = 0,
  }) {
    if (!recipe.isValid || revision <= 0) return EngineResult.invalid;
    _fxRevisions[(owner, channel, lane)] = revision;
    return EngineResult.ok;
  }

  @override
  int fxRecipeRevision({
    required FxOwner owner,
    int channel = 0,
    int lane = 0,
  }) => _fxRevisions[(owner, channel, lane)] ?? 0;

  @override
  PluginSlotHandle? preparePlugin({required String pluginId}) => null;

  @override
  EngineResult discardPreparedPlugin(PluginSlotHandle slot) =>
      EngineResult.invalid;

  @override
  EngineResult preparePluginParam(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) => EngineResult.invalid;

  @override
  EngineResult record({int channel = 0}) => EngineResult.ok;

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    if (!image.isValid) return EngineResult.invalid;
    return record(channel: channel);
  }

  @override
  RequestAdmission toggleFade({
    required int channel,
    required double seconds,
  }) => (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission installFade({
    required int channel,
    required FadeImage image,
  }) => (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission toggleReverse({required int channel}) =>
      (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission installReverse({
    required int channel,
    required bool reversed,
  }) => (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission setSpeed(SpeedFactor factor) =>
      (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission transposeStep({required int channel, required int delta}) =>
      (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission installTranspose({
    required int channel,
    required int semitones,
  }) => (result: EngineResult.invalid, request: 0);

  @override
  RequestAdmission setTransposeBypass({required bool bypassed}) =>
      (result: EngineResult.invalid, request: 0);

  @override
  EngineResult? readRequestResult(int request) => EngineResult.invalid;

  @override
  EngineResult setMix(EngineMixSettings settings) {
    if (!settings.isValid) return EngineResult.invalid;
    for (final entry in settings.trackLevels.entries) {
      _tracks[entry.key].volume = entry.value;
    }
    mixRevision = settings.revision;
    return EngineResult.ok;
  }

  @override
  EngineResult stopTrack({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult play({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult undo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult redo({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult peel({int channel = 0}) => EngineResult.ok;
  @override
  EngineResult setRecordOffset(int frames) => EngineResult.ok;
  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackMultiple({
    required int channel,
    required int multiple,
  }) => EngineResult.ok;
  @override
  EngineResult setDefaultMultiple({required int multiple}) => EngineResult.ok;
  @override
  EngineResult setRecDub({required bool enabled}) => EngineResult.ok;
  @override
  EngineResult setMasterGain(double gain) => EngineResult.ok;
  @override
  EngineResult restoreTempo({
    required double bpm,
    required TempoSource source,
  }) => EngineResult.ok;

  @override
  EngineResult setTempo(double bpm) => EngineResult.ok;
  @override
  EngineResult setTimeSignature(int num, int den) => EngineResult.ok;
  @override
  EngineResult tapTempo() => EngineResult.ok;
  @override
  EngineResult setSyncTempo({required bool on}) => EngineResult.ok;
  @override
  EngineResult setClickMode(ClickMode mode) => EngineResult.ok;
  @override
  EngineResult setClickOutput(int mask) => EngineResult.ok;
  // The backing player (#1200) is not this fake's concern: every call is
  // accepted and nothing is loaded.
  @override
  EngineResult backingLoad(
    DecodedAudio audio, {
    required int item,
    required bool play,
  }) => EngineResult.ok;

  @override
  EngineResult backingStageNext(DecodedAudio? audio, {required int item}) =>
      EngineResult.ok;

  @override
  EngineResult backingClear() => EngineResult.ok;

  @override
  EngineResult backingTransport(BackingTransportOp op) => EngineResult.ok;

  @override
  EngineResult backingSeek(int frame) => EngineResult.ok;

  @override
  EngineResult setBackingEnd(BackingEnd mode) => EngineResult.ok;

  @override
  EngineResult setBackingOutput(int mask) => EngineResult.ok;

  @override
  EngineResult setBackingLevel(double gain) => EngineResult.ok;

  @override
  EngineResult setBackingPan(double pan) => EngineResult.ok;

  @override
  EngineResult setClickPan(double pan) => EngineResult.ok;

  @override
  BackingState backingState() => const BackingState();

  @override
  EngineResult setClickVolume(double volume) => EngineResult.ok;
  @override
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackLengthPreset({
    required int channel,
    required int bars,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackLengthPresets(List<int> bars) => EngineResult.ok;
  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) =>
      EngineResult.ok;
  @override
  LooperModeGate looperModeGate(LooperMode mode) => LooperModeGate.open;
  @override
  EngineResult setLooperMode(LooperMode mode) => EngineResult.ok;
  @override
  EngineResult crownPrimary({required int channel}) => EngineResult.ok;
  @override
  EngineResult setOneShot({required int channel, required bool oneShot}) =>
      EngineResult.ok;

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      EngineResult.ok;
  @override
  EngineResult setOverdubFeedback(double feedback) => EngineResult.ok;
  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
    int preCount = 0,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxEnabled({
    required int channel,
    required int lane,
    required int index,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setLaneFxChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxEnabled({
    required int input,
    required int index,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxChainEnabled({
    required int input,
    required bool enabled,
  }) => EngineResult.ok;

  // ---- Track-stage + Master insert chains (FX v3 part 1b): no repository
  // consumes these yet (part 3 wires the domain model), so plain ok stubs. ----
  @override
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackFxCount({
    required int channel,
    required int count,
    int preCount = 0,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setTrackFxChainEnabled({
    required int channel,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setOutputFx({
    required int bus,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setOutputFxCount({required int bus, required int count}) =>
      EngineResult.ok;
  @override
  EngineResult setOutputFxParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setOutputFxEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setOutputFxChainEnabled({
    required int bus,
    required bool enabled,
  }) => EngineResult.ok;

  @override
  EngineResult setAllTracksFx({
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;

  @override
  EngineResult setAllTracksFxCount({required int count}) => EngineResult.ok;

  @override
  EngineResult setAllTracksFxParam({
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;

  @override
  EngineResult setAllTracksFxEnabled({
    required int index,
    required bool enabled,
  }) => EngineResult.ok;

  @override
  EngineResult setAllTracksFxChainEnabled({required bool enabled}) =>
      EngineResult.ok;

  @override
  EngineResult setLaneFxChannels({
    required int channel,
    required int lane,
    required int index,
    required FxChannels channels,
  }) => EngineResult.ok;

  @override
  EngineResult setMonitorInputFxChannels({
    required int input,
    required int index,
    required FxChannels channels,
  }) => EngineResult.ok;

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

  /// The input the tuner is armed on, or `-1`. Mirrors the native gate, so a
  /// test can assert that a closed face leaves nothing running.
  int tunerInput = -1;

  /// The last tuner mute mask sent.
  int tunerMuteMask = 0;

  @override
  EngineResult setTunerMute({required int inputMask}) {
    tunerMuteMask = inputMask;
    return EngineResult.ok;
  }

  @override
  EngineResult setTunerInput({required int input}) {
    tunerInput = input;
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputOutput({
    required int input,
    required int mask,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputMute({
    required int input,
    required bool muted,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputPan({
    required int input,
    required double pan,
  }) => EngineResult.ok;
  @override
  EngineResult setInputConditioningEnabled({
    required int input,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) => EngineResult.ok;
  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) => EngineResult.ok;
  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;
  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;
  @override
  Map<(int, int), LaneCacheState> laneCacheStates() => const {};
  @override
  EngineResult setOutputEnabled({
    required int output,
    required bool enabled,
  }) => EngineResult.ok;
  @override
  EngineResult perfArm(String captureDir) => EngineResult.ok;
  @override
  EngineResult perfDisarm() => EngineResult.ok;

  @override
  bool syncDirectory(String path) => path.isNotEmpty;

  @override
  VolumeSpace? volumeSpace(String path) => freeBytes == null
      ? null
      : VolumeSpace(totalBytes: totalBytes, freeBytes: freeBytes!);

  /// What [volumeSpace] reports as free; `null` models a platform that
  /// cannot answer.
  int? freeBytes = 1 << 40;

  /// What [volumeSpace] reports as the volume's size.
  int totalBytes = 2 << 40;
  @override
  EngineResult renderBegin(String captureDir) => EngineResult.ok;
  @override
  PerformanceRenderProgress renderPoll() => PerformanceRenderProgress.empty;
  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() => const [];
  @override
  EngineResult renderCancel() => EngineResult.ok;
  @override
  EngineResult scanBegin({bool rescan = false}) => EngineResult.ok;
  @override
  PluginScanProgress scanPoll() => PluginScanProgress.empty;
  @override
  List<PluginDescriptor> scanResults() => const [];
  @override
  EngineResult scanCancel() => EngineResult.ok;
  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => null;
  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => null;
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
  Float32List readVisual() => Float32List(0);
  @override
  Float32List readTrackVisual(int channel) => Float32List(0);
  @override
  void dispose() {}

  /// Channels passed to [cancelArm], in call order.
  final List<int> cancelledArms = [];

  @override
  EngineResult cancelArm({required int channel}) {
    cancelledArms.add(channel);
    return EngineResult.ok;
  }

  @override
  EngineResult stopRecordControl({required int channel}) => EngineResult.ok;

  @override
  EngineResult cancelCountIn() => EngineResult.ok;

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
