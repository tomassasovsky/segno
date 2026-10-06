import 'dart:typed_data';

import 'package:segno_engine/src/audio_device.dart';
import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/engine_config.dart';
import 'package:segno_engine/src/engine_snapshot.dart';
import 'package:segno_engine/src/fx_fingerprint.dart';
import 'package:segno_engine/src/fx_recipe.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';
import 'package:segno_engine/src/history_entry.dart';
import 'package:segno_engine/src/input_conditioning_param.dart';
import 'package:segno_engine/src/lane_cache.dart';
import 'package:segno_engine/src/loopback_info.dart';
import 'package:segno_engine/src/mix_settings.dart';
import 'package:segno_engine/src/output_fx_snapshot.dart';
import 'package:segno_engine/src/perf_target.dart';
import 'package:segno_engine/src/performance_render_progress.dart';
import 'package:segno_engine/src/plugin_descriptor.dart';
import 'package:segno_engine/src/track_effect.dart';
import 'package:segno_engine/src/volume_space.dart';

/// In-memory [AudioEngine] that simulates a multichannel interface for UI
/// development and manual testing without real hardware.
///
/// Reports [inputChannels] × [outputChannels] (default 18 × 20), enumerates a
/// single duplex device, and reflects lane / monitor routing in [snapshot].
class MockAudioEngine implements AudioEngine {
  /// Creates a [MockAudioEngine].
  MockAudioEngine({
    int inputChannels = defaultInputChannels,
    int outputChannels = defaultOutputChannels,
    String? deviceLabel,
  }) : inputChannels = inputChannels,
       outputChannels = outputChannels,
       deviceLabel =
           deviceLabel ??
           'Mock Interface (${inputChannels}i${outputChannels}o)';

  /// The input the tuner is armed on, or `-1`. Mirrors the native gate.
  int _tunerInput = -1;

  /// The pitch a mock arm reports, in Hz (`0` = no pitch). A test seam: the
  /// mock analyses nothing, so a test drives the reading directly.
  double tunerHz = 0;

  @override
  EngineResult setTunerInput({required int input}) {
    _tunerInput = input < 0 || input >= inputChannels ? -1 : input;
    return EngineResult.ok;
  }

  /// Default mock input channel count (Focusrite 18i20 class).
  static const int defaultInputChannels = 18;

  /// Default mock output channel count.
  static const int defaultOutputChannels = 20;

  /// Shared id for the mock playback and capture device entries.
  static const String deviceId = 'mock-interface';

  /// Negotiated input channel count while running.
  final int inputChannels;

  /// Negotiated output channel count while running.
  final int outputChannels;

  /// Human-readable label for [deviceName] and [enumerateDevices].
  final String deviceLabel;

  /// Sensible defaults for booting straight into the looper on the dev flavor.
  EngineConfig get defaultConfig => EngineConfig(
    sampleRate: 48000,
    bufferFrames: 128,
    inputChannels: inputChannels,
    outputChannels: outputChannels,
    playbackDeviceId: deviceId,
    captureDeviceId: deviceId,
  );

  bool _running = false;
  EngineConfig? _activeConfig;
  int _framesProcessed = 0;
  LatencyState _latencyState = LatencyState.idle;
  double _measuredLatencyMs = -1;
  int _recordOffsetFrames = 0;
  double _masterGain = 1;
  bool _perfArmed = false;
  int _perfFrames = 0;

  // ---- tempo grid + click/count-in (TempoControl) ----
  //
  // Mirrors the native engine's persistence model (engine.c:552-571): these
  // are SETTINGS, seeded once (here, at construction) and left untouched by
  // start()/stop() — unlike e.g. _masterGain, which the native engine resets
  // to unity on every fresh start.
  double _tempoBpm = 0;
  TempoSource _tempoSource = TempoSource.none;
  int _tsNum = 4;
  int _tsDen = 4;
  bool _syncTempo = true;
  GridDivision _quantizeDiv = GridDivision.off;
  RecordTiming _recordTiming = RecordTiming.immediately;
  int _recordTimingRevision = 0;
  ClickMode _clickMode = ClickMode.off;
  int _clickModeRevision = 0;
  int _recordStartRevision = 0;
  bool _soundStart = false;
  int _clickMask = 0;
  double _clickVolume = 1;
  int _countInBars = 0;

  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (bars.length != LE_MAX_TRACKS ||
        bars.any((value) => value < 0 || value > LE_LENGTH_PRESET_MAX_BARS)) {
      return EngineResult.invalid;
    }
    for (var channel = 0; channel < bars.length; channel++) {
      _tracks[channel].lengthPresetBars = bars[channel];
    }
    return EngineResult.ok;
  }

  // ---- looper mode (LooperModeControl, B2a) ----
  //
  // Same seeded-once persistence as the tempo/click settings above. Unlike
  // the native engine, this mock does NOT replicate the D4 content lock
  // (mirroring the mock's existing choice not to replicate D6's tempo lock
  // either) — it is a simplified simulation for UI development/manual
  // testing, not a byte-for-byte reimplementation of native's business
  // rules; the lock gate is covered by the native C tests.
  LooperMode _looperMode = LooperMode.multi;

  /// The crowned primary track (B3/B5c, D18): `-1` = none (default). Same
  /// seeded-once persistence as [_looperMode] above — mirrors the native
  /// engine's `a_primary_track`, which `le_engine_create` seeds once and
  /// `configure()` never resets. There is no "un-crown" call, matching
  /// native.
  int _primaryTrack = -1;

  /// Wall-clock timestamp of the previous [tapTempo] call, `null` before the
  /// first tap or after a fresh [start]. The mock has no audio-thread frame
  /// clock, so it uses real elapsed time as the tap interval (the native
  /// engine uses block-granular `frame_clock`, `engine_process.c:282-305`).
  DateTime? _lastTapAt;

  /// Tempo clamp bounds, mirroring `tempo_grid.h`'s `LE_GRID_TEMPO_MIN`/`MAX`
  /// (not in the generated bindings — `tempo_grid.h` is not an ffigen entry
  /// point, only `segno_engine_api.h` is).
  static const double _minTempoBpm = 30;
  static const double _maxTempoBpm = 300;

  /// Whether `{num, den}` is one of the 17 Sheeran-verified time signatures
  /// (mirrors `tempo_grid.h`'s `le_grid_signature_valid`): `den == 4` takes
  /// `num` 2..7, `den == 8` takes `num` 5..15; anything else is invalid.
  static bool _isValidTimeSignature(int num, int den) {
    if (den == 4) return num >= 2 && num <= 7;
    if (den == 8) return num >= 5 && num <= 15;
    return false;
  }

  final List<_MockTrack> _tracks = List<_MockTrack>.generate(
    LE_MAX_TRACKS,
    (_) => _MockTrack(),
  );

  /// Per-input capture trim (`setInputTrim`), linear, default unity. Held
  /// across start/stop like the lane volumes above (the native engine resets
  /// it on configure; the mock is a simplified simulation).
  final List<double> _inputTrim = List<double>.filled(LE_MAX_CHANNELS, 1);

  /// The capture trim the mock holds for [input] (linear), or `1` for an
  /// out-of-range input. A read-back seam like [monitorInputPan]: the engine
  /// snapshot carries no trim (the repository keeps its own dB intent), so
  /// tests read the mock directly.
  double inputTrimOf({required int input}) =>
      input < 0 || input >= LE_MAX_CHANNELS ? 1 : _inputTrim[input];

  /// Per-input monitor pan (`setMonitorInputPan`), `-1..1`, default centre.
  final List<double> _monitorPan = List<double>.filled(LE_MAX_CHANNELS, 0);

  /// Output bus facts (slice 3b), one slot per bus the engine can address;
  /// the snapshot publishes the first `(outputs + 1) ~/ 2`. Reset to their
  /// defaults by every (re)start like the native engine.
  final List<double> _outputLevel = List<double>.filled(LE_MAX_OUTPUT_BUSES, 1);
  final List<bool> _outputMuted = List<bool>.filled(LE_MAX_OUTPUT_BUSES, false);
  final List<bool> _outputMono = List<bool>.filled(LE_MAX_OUTPUT_BUSES, false);
  final List<double> _outputBalance = List<double>.filled(
    LE_MAX_OUTPUT_BUSES,
    0,
  );

  /// How many times [cutSound] ran; published as the snapshot's
  /// `tailResetRev` like the native counter.
  int _tailResetRev = 0;

  /// The pending capture policy ([setPerfFollowOutput]) and the one frozen
  /// by the current arm.
  bool _perfFollowPending = false;
  bool _perfFollowArmed = false;

  /// Recorded [cutSound] calls, for test assertions.
  int cutSoundCalls = 0;

  /// The monitor pan the mock holds for [input] (`-1..1`), or `0` for an
  /// out-of-range input. A read-back seam: the engine snapshot carries no
  /// per-monitor pan, so tests read the mock directly.
  double monitorInputPan({required int input}) =>
      input < 0 || input >= LE_MAX_CHANNELS ? 0 : _monitorPan[input];

  int get _negotiatedInputs {
    final requested = _activeConfig?.inputChannels ?? 0;
    return requested > 0 ? requested : inputChannels;
  }

  int get _negotiatedOutputs {
    final requested = _activeConfig?.outputChannels ?? 0;
    return requested > 0 ? requested : outputChannels;
  }

  @override
  String get version => 'mock-engine 0.0.0';

  @override
  String get deviceName => _running ? deviceLabel : '';

  @override
  EngineResult start(EngineConfig config) {
    if (_running) return EngineResult.alreadyRunning;
    _activeConfig = config;
    _running = true;
    _clickModeRevision = 0;
    _recordStartRevision = 0;
    _framesProcessed = 0;
    _latencyState = LatencyState.idle;
    _measuredLatencyMs = -1;
    _masterGain = 1; // unity on every fresh start, mirroring the native engine
    _perfArmed = false; // disarmed on every fresh start/reconfigure
    _perfFrames = 0;
    // The output destinations go back to their defaults on a fresh start,
    // like the native engine's configure. The capture policy deliberately
    // does NOT: it is a preference, not device state.
    _outputLevel.fillRange(0, _outputLevel.length, 1);
    _outputMuted.fillRange(0, _outputMuted.length, false);
    _outputMono.fillRange(0, _outputMono.length, false);
    _outputBalance.fillRange(0, _outputBalance.length, 0);
    // The tap-tempo pair state is transient (per-session), unlike the tempo
    // grid/click SETTINGS above it, which persist across start/stop —
    // mirrors engine.c:371-372 (has_tap/last_tap_frame reset on configure).
    _lastTapAt = null;
    return EngineResult.ok;
  }

  @override
  EngineResult stop() {
    if (!_running) return EngineResult.notRunning;
    _running = false;
    _lastSampleRate = _activeConfig?.sampleRate ?? 48000;
    _activeConfig = null;
    return EngineResult.ok;
  }

  /// The sample rate of the most recent session, for [reopen]'s retention
  /// test; `null` until the first [start].
  int? _lastSampleRate;

  /// Mirrors the native retention rule on the mock's (contentless) tracks:
  /// the same sample rate retains, another clears, nothing is ever dropped
  /// (the mock posts no state commands), and the lifecycle preconditions
  /// match [start]/[stop]. Tracks, lanes and settings the real engine resets
  /// are reset exactly as [start] does.
  @override
  ReopenResult reopen(EngineConfig config) {
    if (_running) {
      return (
        result: EngineResult.alreadyRunning,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
      );
    }
    final previous = _lastSampleRate;
    if (previous == null) {
      return (
        result: EngineResult.notRunning,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
      );
    }
    final requested = config.sampleRate > 0 ? config.sampleRate : 48000;
    final outcome = requested == previous
        ? ReopenOutcome.retained
        : ReopenOutcome.clearedRate;
    return (result: start(config), outcome: outcome, droppedTracks: 0);
  }

  @override
  CallbackTelemetry callbackTelemetry() => nextCallbackTelemetry;

  /// The value [callbackTelemetry] returns. Settable so a caller can rehearse
  /// a reading (a late-callback window, a dropout count) without a device.
  CallbackTelemetry nextCallbackTelemetry = CallbackTelemetry.empty;

  @override
  bool get commandsSettled => true;

  @override
  EngineSnapshot snapshot() {
    if (_running) {
      final buffer = _activeConfig?.bufferFrames ?? 128;
      _framesProcessed += buffer;
      if (_perfArmed) _perfFrames += buffer;
    }
    final inputs = _running ? _negotiatedInputs : 0;
    final outputs = _running ? _negotiatedOutputs : 0;
    return EngineSnapshot(
      mixRevision: _mixRevision,
      isRunning: _running,
      devicePresent: _running,
      sampleRate: _activeConfig?.sampleRate ?? 48000,
      bufferFrames: _activeConfig?.bufferFrames ?? 128,
      inputChannels: inputs,
      outputChannels: outputs,
      framesProcessed: _framesProcessed,
      xrunCount: 0,
      inputRms: 0,
      tunerHz: _tunerInput >= 0 ? tunerHz : 0,
      tunerConfidence: _tunerInput >= 0 && tunerHz > 0 ? 1 : 0,
      tunerInput: _tunerInput,
      inputPeak: 0,
      outputRms: 0,
      latencyState: _latencyState,
      measuredLatencyMs: _measuredLatencyMs,
      recordOffsetFrames: _recordOffsetFrames,
      masterGain: _masterGain,
      // The mock echoes the requested backend as the negotiated one (ASIO
      // "succeeds"), so the requested-ASIO/reality-miniaudio fallback is NOT
      // exercised here — the widget test seeds that state directly.
      activeBackend: _running
          ? (_activeConfig?.backend ?? AudioBackend.miniaudio)
          : AudioBackend.miniaudio,
      isPerfArmed: _perfArmed,
      perfFrames: _perfFrames,
      outputBusCount: (outputs + 1) ~/ 2,
      outputLevels: _outputLevel.sublist(0, (outputs + 1) ~/ 2),
      outputMuted: _outputMuted.sublist(0, (outputs + 1) ~/ 2),
      outputMono: _outputMono.sublist(0, (outputs + 1) ~/ 2),
      outputBalances: _outputBalance.sublist(0, (outputs + 1) ~/ 2),
      tailResetRev: _tailResetRev,
      perfFollowOutput: _perfArmed ? _perfFollowArmed : _perfFollowPending,
      // The mock models no structural output gate, so the first destination
      // is always the one a capture would read.
      perfCaptureBus: outputs > 0 ? 0 : -1,
      // perfOverruns / perfZeroFilledFrames default to 0: the mock models no
      // ring capacity and no drain thread, so nothing ever overflows and no
      // silence is ever substituted.
      tempoBpm: _tempoBpm,
      tempoSource: _tempoSource,
      tsNum: _tsNum,
      tsDen: _tsDen,
      syncTempo: _syncTempo,
      quantizeDiv: _quantizeDiv,
      quantize: _recordTiming.quantize,
      recordTimingRevision: _recordTimingRevision,
      // loopBars/currentBeat/countingIn/countInBeatsLeft stay at their
      // grid-off/idle defaults (0/false): the mock runs no real transport, so
      // there is no live loop or count-in to derive them from.
      clickMode: _clickMode,
      clickModeRevision: _clickModeRevision,
      clickMask: _clickMask,
      clickVolume: _clickVolume,
      countInBars: _countInBars,
      autoRecord: _soundStart,
      recordStartRevision: _recordStartRevision,
      looperMode: _looperMode,
      primaryTrack: _primaryTrack,
      // One entry per negotiated channel, like the native projection; all
      // zero because the mock processes no audio.
      inputPeaks: List<double>.filled(inputs, 0),
      monitorPeaks: List<double>.filled(inputs, 0),
      outputPeaks: List<double>.filled(outputs, 0),
      tracks: [for (final track in _tracks) track.snapshot()],
    );
  }

  @override
  LoopbackInfo detectLoopback() => const LoopbackInfo.none();

  @override
  List<AudioDevice> enumerateDevices() => [
    AudioDevice(
      id: deviceId,
      name: deviceLabel,
      isDefault: true,
      isInput: false,
    ),
    AudioDevice(
      id: deviceId,
      name: deviceLabel,
      isDefault: true,
      isInput: true,
    ),
  ];

  @override
  List<AudioDevice> enumerateAsioDrivers() => const [
    // One deterministic fake duplex driver (18 in / 20 out), so UI development
    // and tests can drive the ASIO backend selector without real hardware. The
    // buffer/rate sets are a small fake of what a driver probe reports.
    AudioDevice(
      id: 'mock-asio',
      name: 'Mock ASIO Device',
      isDefault: false,
      isInput: false,
      inputChannels: 18,
      outputChannels: 20,
      bufferSizes: [128, 256, 512],
      sampleRates: [48000, 96000],
    ),
  ];

  /// Deterministic fixed scan result for UI development and tests: one VST3 and
  /// one CLAP plugin, plus one failed entry (empty id) so the failed-scan path
  /// can be exercised without real hardware.
  static const List<PluginDescriptor> mockScanResults = [
    PluginDescriptor(
      id: '0102030405060708090A0B0C0D0E0F10',
      name: 'Mock Reverb',
      vendor: 'Segno Labs',
      path: '/Library/Audio/Plug-Ins/VST3/Mock Reverb.vst3',
      format: PluginFormat.vst3,
      version: 0x00010200, // 1.2.0
    ),
    PluginDescriptor(
      id: 'com.segno.mock-delay',
      name: 'Mock Delay',
      vendor: 'Segno Labs',
      path: '/Library/Audio/Plug-Ins/CLAP/Mock Delay.clap',
      format: PluginFormat.clap,
      version: 0x00000300, // 0.3.0
    ),
    PluginDescriptor(
      id: '', // failed entry
      name: 'Broken Plugin.clap',
      vendor: '',
      path: '/Library/Audio/Plug-Ins/CLAP/Broken Plugin.clap',
      format: PluginFormat.clap,
      version: 0,
    ),
  ];

  bool _scanStarted = false;

  @override
  EngineResult scanBegin({bool rescan = false}) {
    _scanStarted = true;
    return EngineResult.ok;
  }

  @override
  PluginScanProgress scanPoll() => _scanStarted
      ? PluginScanProgress(
          done: true,
          found: mockScanResults.length,
          scanned: mockScanResults.length,
          total: mockScanResults.length,
        )
      : PluginScanProgress.empty;

  @override
  List<PluginDescriptor> scanResults() =>
      _scanStarted ? mockScanResults : const [];

  @override
  EngineResult scanCancel() {
    _scanStarted = false;
    return EngineResult.ok;
  }

  /// Complete recipes accepted by the in-memory engine.
  final fxRecipes = <(FxOwner, int, int), FxRecipe>{};
  final _fxRecipeRevisions = <(FxOwner, int, int), int>{};

  @override
  EngineResult setFxRecipe({
    required FxOwner owner,
    required FxRecipe recipe,
    required int revision,
    int channel = 0,
    int lane = 0,
  }) {
    final running = _requireRunning();
    if (!running.isOk) return running;
    if (!recipe.isValid ||
        revision <= 0 ||
        revision > 0xffffffff ||
        lane < 0 ||
        lane >= 8 ||
        channel < 0 ||
        (owner == FxOwner.lane || owner == FxOwner.track) && channel >= 8 ||
        owner == FxOwner.monitor && channel >= 32 ||
        owner == FxOwner.output && channel >= 16 ||
        owner == FxOwner.allTracks && channel != 0 ||
        owner != FxOwner.lane && lane != 0 ||
        (owner == FxOwner.monitor ||
                owner == FxOwner.output ||
                owner == FxOwner.allTracks) &&
            recipe.preCount != 0) {
      return EngineResult.invalid;
    }
    fxRecipes[(owner, channel, lane)] = recipe;
    _fxRecipeRevisions[(owner, channel, lane)] = revision;
    return EngineResult.ok;
  }

  @override
  int fxRecipeRevision({
    required FxOwner owner,
    int channel = 0,
    int lane = 0,
  }) => _fxRecipeRevisions[(owner, channel, lane)] ?? 0;

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
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle(pluginId);

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => MockPluginSlotHandle(pluginId);

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
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) =>
      MockPluginSlotHandle.mockParams;

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    if (slot is! MockPluginSlotHandle) return 0;
    return slot.paramValue(paramId);
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    if (slot is! MockPluginSlotHandle) return null;
    return slot.paramValueText(paramId, value);
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    return slot.setParamValue(paramId, value);
  }

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.editorOpen = true;
    return EngineResult.ok;
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.editorOpen = false;
    return EngineResult.ok;
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) =>
      slot is MockPluginSlotHandle && slot.editorOpen;

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) =>
      slot is MockPluginSlotHandle ? slot.stateBlob : Uint8List(0);

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    if (slot is! MockPluginSlotHandle) return EngineResult.invalid;
    slot.stateBlob = Uint8List.fromList(state);
    return EngineResult.ok;
  }

  @override
  EngineResult measureLatency() {
    if (!_running) return EngineResult.notRunning;
    _latencyState = LatencyState.done;
    _measuredLatencyMs = 5.3;
    return EngineResult.ok;
  }

  int _mixRevision = 0;

  // This silent device mock has no recorded tracks. Fade refuses empty
  // material, matching its TrackSnapshot.empty projection.
  @override
  RequestAdmission toggleFade({
    required int channel,
    required double seconds,
  }) => (
    result: _running ? EngineResult.invalid : EngineResult.notRunning,
    request: 0,
  );
  @override
  RequestAdmission installFade({
    required int channel,
    required FadeImage image,
  }) => (
    result: _running ? EngineResult.invalid : EngineResult.notRunning,
    request: 0,
  );
  // Reverse refuses empty material the same way.
  @override
  RequestAdmission toggleReverse({required int channel}) => (
    result: _running ? EngineResult.invalid : EngineResult.notRunning,
    request: 0,
  );
  @override
  RequestAdmission installReverse({
    required int channel,
    required bool reversed,
  }) => (
    result: _running ? EngineResult.invalid : EngineResult.notRunning,
    request: 0,
  );
  @override
  EngineResult? readRequestResult(int request) => EngineResult.invalid;

  @override
  EngineResult setMix(EngineMixSettings settings) {
    if (!settings.isValid) return EngineResult.invalid;
    final result = _requireRunning();
    if (!result.isOk) return result;
    for (final e in settings.laneInputs.entries) {
      _tracks[e.key.$1].laneAt(e.key.$2).inputChannel = e.value;
    }
    for (final e in settings.laneOutputs.entries) {
      _tracks[e.key.$1].laneAt(e.key.$2).outputMask = e.value;
    }
    for (final e in settings.laneCounts.entries) {
      _tracks[e.key].laneCount = e.value;
    }
    for (final e in settings.lanes.entries) {
      _tracks[e.key.$1].laneAt(e.key.$2)
        ..liveLevel = e.value.gain
        ..livePan = e.value.pan
        ..compose();
    }
    for (final e in settings.images.entries) {
      _tracks[e.key.$1].laneAt(e.key.$2)
        ..imageGain = e.value.gain
        ..imagePan = e.value.pan
        ..compose();
    }
    for (final e in settings.monitors.entries) {
      setMonitorInputVolume(input: e.key, volume: e.value.gain);
      setMonitorInputPan(input: e.key, pan: e.value.pan);
    }
    for (final e in settings.trims.entries) {
      _inputTrim[e.key] = e.value;
    }
    for (final e in settings.trackLevels.entries) {
      _tracks[e.key].volume = e.value;
    }
    for (final e in settings.solos.entries) {
      _tracks[e.key].solo = e.value;
    }
    for (final e in settings.outputs.entries) {
      setOutputLevel(bus: e.key, level: e.value.level);
      setOutputMute(bus: e.key, muted: e.value.muted);
      setOutputMono(bus: e.key, mono: e.value.mono);
      setOutputBalance(bus: e.key, balance: e.value.balance);
    }
    _mixRevision = settings.revision;
    return EngineResult.ok;
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    if (!image.isValid || channel < 0 || channel >= LE_MAX_TRACKS) {
      return EngineResult.invalid;
    }
    final result = record(channel: channel);
    if (!result.isOk) return result;
    for (final e in image.lanes.entries) {
      _tracks[channel].laneAt(e.key)
        ..imageGain = e.value.gain
        ..imagePan = e.value.pan
        ..compose();
    }
    for (final entry in image.laneFx.entries) {
      fxRecipes[(FxOwner.lane, channel, entry.key)] = entry.value;
    }
    _tracks[channel].imageRevision = image.revision;
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) => _requireRunning();

  @override
  EngineResult stopTrack({int channel = 0}) => _requireRunning();

  @override
  EngineResult play({int channel = 0}) => _requireRunning();

  @override
  EngineResult clear({int channel = 0}) => _requireRunning();

  @override
  EngineResult clearUndoable({int channel = 0}) => _requireRunning();

  /// The mock keeps no undo history, so it never offers a restore.
  @override
  bool undoRestoresClear({int channel = 0}) => false;

  @override
  bool redoReclears({int channel = 0}) => false;

  @override
  bool clearRestorePending({int channel = 0}) => false;

  /// The mock keeps no history that could conflict with the current mode.
  @override
  EngineResult historyModeGate({required int channels, required bool redo}) =>
      EngineResult.ok;

  @override
  EngineResult undo({int channel = 0}) => _requireRunning();

  @override
  EngineResult redo({int channel = 0}) => _requireRunning();

  /// The mock keeps no overdub layers, so there is never one to peel.
  @override
  EngineResult peel({int channel = 0}) {
    final running = _requireRunning();
    return running.isOk ? EngineResult.invalid : running;
  }

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneCount = count.clamp(1, kMaxLanes);
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneVolume(
    double volume, {
    int channel = 0,
    int lane = 0,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).volume = volume.clamp(0.0, LE_MAX_GAIN);
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).muted = muted;
    return EngineResult.ok;
  }

  @override
  EngineResult setLanePan({
    required double pan,
    int channel = 0,
    int lane = 0,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    if (lane < 0 || lane >= kMaxLanes) return EngineResult.invalid;
    _tracks[channel].laneAt(lane).pan = pan.clamp(-1.0, 1.0);
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    _tracks[channel].solo = solo;
    return EngineResult.ok;
  }

  // ---- Output buses (slice 3b): direct stores, no running gate. ----

  @override
  EngineResult setOutputLevel({required int bus, required double level}) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    _outputLevel[bus] = level.isNaN ? 0 : level.clamp(0.0, 1.0);
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMute({required int bus, required bool muted}) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    _outputMuted[bus] = muted;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputMono({required int bus, required bool mono}) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    _outputMono[bus] = mono;
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputBalance({required int bus, required double balance}) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    _outputBalance[bus] = balance.isNaN ? 0 : balance.clamp(-1.0, 1.0);
    return EngineResult.ok;
  }

  /// The mock runs no transport and holds no chain DSP state, so the call
  /// count and the revision bump are the observables.
  @override
  EngineResult cutSound() {
    final result = _requireRunning();
    if (!result.isOk) return result;
    cutSoundCalls++;
    _tailResetRev++;
    return EngineResult.ok;
  }

  // A direct store like the enable setters: no running gate.
  @override
  EngineResult setInputTrim({required int input, required double gain}) {
    if (input < 0 || input >= LE_MAX_CHANNELS) return EngineResult.invalid;
    // NaN lands on silence, not on unity, mirroring the native clamp.
    _inputTrim[input] = gain.isNaN ? 0 : gain.clamp(0.0, LE_MAX_INPUT_TRIM);
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).inputChannel = inputChannel;
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tracks[channel].laneAt(lane).outputMask = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordOffset(int frames) {
    _recordOffsetFrames = frames < 0 ? 0 : frames;
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (trackOverrides.keys.any((c) => c < 0 || c >= 8) ||
        (editMask & ~0x1ff) != 0 ||
        (defaultTiming.quantize &&
            defaultTiming.division != rememberedDivision)) {
      return EngineResult.invalid;
    }
    _recordTiming = defaultTiming;
    _quantizeDiv = rememberedDivision;
    for (var channel = 0; channel < _tracks.length; channel++) {
      _tracks[channel].recordTiming = trackOverrides[channel];
    }
    _recordTimingRevision = (_recordTimingRevision + 2) & 0xffffffff;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) => _requireRunning();

  @override
  EngineResult cancelArm({required int channel}) => _requireRunning();

  @override
  EngineResult stopRecordControl({required int channel}) => _requireRunning();

  @override
  EngineResult cancelCountIn() => _requireRunning();

  @override
  EngineResult finalizeTake({required int channel}) => _requireRunning();

  @override
  EngineResult setTrackMultiple({
    required int channel,
    required int multiple,
  }) => _requireRunning();

  @override
  EngineResult setDefaultMultiple({required int multiple}) => _requireRunning();

  @override
  EngineResult setRecDub({required bool enabled}) => _requireRunning();

  @override
  EngineResult setMasterGain(double gain) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _masterGain = gain.clamp(0.0, 1.0);
    return EngineResult.ok;
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) =>
      _requireRunning();

  @override
  EngineResult setOutputEnabled({
    required int output,
    required bool enabled,
  }) => _requireRunning();

  @override
  EngineResult setOverdubFeedback(double feedback) => _requireRunning();

  // ---- tempo grid + click/count-in (TempoControl) ----

  @override
  EngineResult setTempo(double bpm) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _tempoBpm = bpm.clamp(_minTempoBpm, _maxTempoBpm);
    _tempoSource = TempoSource.manual;
    return EngineResult.ok;
  }

  @override
  EngineResult restoreTempo({
    required double bpm,
    required TempoSource source,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (!bpm.isFinite ||
        source == TempoSource.external ||
        (source == TempoSource.none
            ? bpm != 0
            : bpm < _minTempoBpm || bpm > _maxTempoBpm)) {
      return EngineResult.invalid;
    }
    _tempoBpm = bpm;
    _tempoSource = source;
    _lastTapAt = null;
    return EngineResult.ok;
  }

  @override
  EngineResult setTimeSignature(int num, int den) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (!_isValidTimeSignature(num, den)) return EngineResult.invalid;
    _tsNum = num;
    _tsDen = den;
    return EngineResult.ok;
  }

  @override
  EngineResult tapTempo() {
    final result = _requireRunning();
    if (!result.isOk) return result;
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null) {
      final intervalMs = now.difference(last).inMicroseconds / 1000.0;
      if (intervalMs > 0) {
        final bpm = 60000.0 / intervalMs;
        if (bpm >= _minTempoBpm && bpm <= _maxTempoBpm) {
          _tempoBpm = bpm;
          _tempoSource = TempoSource.tapped;
        }
      }
    }
    _lastTapAt = now;
    return EngineResult.ok;
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _syncTempo = on;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickMode(ClickMode mode) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    // The mock has no capture state or callback; its receipt completes here.
    // Actual capture refusal and deferred publication use PumpedNativeEngine.
    _clickMode = mode;
    _clickModeRevision = (_clickModeRevision + 1) & 0xffffffff;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickOutput(int mask) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _clickMask = mask;
    return EngineResult.ok;
  }

  @override
  EngineResult setClickVolume(double volume) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    _clickVolume = volume.clamp(0.0, LE_MAX_GAIN);
    return EngineResult.ok;
  }

  @override
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (!const [0, 1, 2, 4].contains(countInBars) ||
        countInBars > 0 && soundStart) {
      return EngineResult.invalid;
    }
    _countInBars = countInBars;
    _soundStart = soundStart;
    _recordStartRevision = (_recordStartRevision + 1) & 0xffffffff;
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackLengthPreset({
    required int channel,
    required int bars,
  }) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    if (bars < 0 || bars > LE_LENGTH_PRESET_MAX_BARS) {
      return EngineResult.invalid;
    }
    // The mock models no real transport/capacity, so unlike the native
    // engine's D17 allocation guard, every in-range value is accepted.
    _tracks[channel].lengthPresetBars = bars;
    return EngineResult.ok;
  }

  // ---- looper mode (LooperModeControl, B2a) ----

  /// The mock keeps no takes, so every change is open.
  @override
  LooperModeGate looperModeGate(LooperMode mode) => LooperModeGate.open;

  @override
  EngineResult setLooperMode(LooperMode mode) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    // No content rules here — the mock holds no takes to measure.
    _looperMode = mode;
    return EngineResult.ok;
  }

  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) {
    final result = setTrackLengthPresets(bars);
    if (!result.isOk) return result;
    _looperMode = mode;
    return EngineResult.ok;
  }

  @override
  EngineResult crownPrimary({required int channel}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    _primaryTrack = channel;
    return EngineResult.ok;
  }

  @override
  EngineResult setOneShot({required int channel, required bool oneShot}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    _tracks[channel].oneShot = oneShot;
    return EngineResult.ok;
  }

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (channels <= 0 || channels >= (1 << LE_MAX_TRACKS)) {
      return EngineResult.invalid;
    }
    for (var channel = 0; channel < LE_MAX_TRACKS; channel++) {
      if ((channels & (1 << channel)) != 0) _tracks[channel].oneShot = oneShot;
    }
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
    int preCount = 0,
  }) => _requireRunning();

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  /// Recorded [setLaneFxEnabled] calls, in order, for test assertions.
  final laneFxEnabledCalls =
      <({int channel, int lane, int index, bool enabled})>[];

  /// Recorded [setLaneFxChainEnabled] calls, in order, for test assertions.
  final laneFxChainEnabledCalls = <({int channel, int lane, bool enabled})>[];

  // The enable setters mirror the native works-while-stopped contract
  // (direct atomic stores, no ring): they validate ranges and succeed whether
  // or not the mock is running — unlike the ring-backed FX setters above,
  // which keep the mock's running gate.
  @override
  EngineResult setLaneFxEnabled({
    required int channel,
    required int lane,
    required int index,
    required bool enabled,
  }) {
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    if (lane < 0 || lane >= LE_MAX_LANES) return EngineResult.invalid;
    if (index < 0 || index >= LE_FX_MAX) return EngineResult.invalid;
    laneFxEnabledCalls.add(
      (channel: channel, lane: lane, index: index, enabled: enabled),
    );
    return EngineResult.ok;
  }

  @override
  EngineResult setLaneFxChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) {
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    if (lane < 0 || lane >= LE_MAX_LANES) return EngineResult.invalid;
    laneFxChainEnabledCalls.add(
      (channel: channel, lane: lane, enabled: enabled),
    );
    return EngineResult.ok;
  }

  // ---- Track-stage (per-track stereo bus) chain (FX v3 part 1b) ----
  // Mirrors the lane family: ring-backed setters keep the running gate,
  // enable flips record + succeed while stopped (direct-store contract).

  @override
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setTrackFxCount({
    required int channel,
    required int count,
    int preCount = 0,
  }) => _requireRunning();

  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  /// Recorded [setTrackFxEnabled] calls, in order, for test assertions.
  final trackFxEnabledCalls = <({int channel, int index, bool enabled})>[];

  /// Recorded [setTrackFxChainEnabled] calls, in order, for test assertions.
  final trackFxChainEnabledCalls = <({int channel, bool enabled})>[];

  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) {
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    if (index < 0 || index >= LE_FX_MAX) return EngineResult.invalid;
    trackFxEnabledCalls.add(
      (channel: channel, index: index, enabled: enabled),
    );
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxChainEnabled({
    required int channel,
    required bool enabled,
  }) {
    if (channel < 0 || channel >= LE_MAX_TRACKS) return EngineResult.invalid;
    trackFxChainEnabledCalls.add((channel: channel, enabled: enabled));
    return EngineResult.ok;
  }

  // ---- Output bus chains (slice 3b): same split as the track
  // family above. ----

  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) =>
      const OutputFxSnapshot();

  @override
  EngineResult setOutputFx({
    required int bus,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setOutputFxCount({required int bus, required int count}) =>
      _requireRunning();

  @override
  EngineResult setOutputFxParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  /// Recorded [setOutputFxEnabled] calls, in order, for test assertions.
  final outputFxEnabledCalls = <({int bus, int index, bool enabled})>[];

  /// Recorded [setOutputFxChainEnabled] calls, in order, for test assertions.
  final outputFxChainEnabledCalls = <({int bus, bool enabled})>[];

  @override
  EngineResult setOutputFxEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    if (index < 0 || index >= LE_FX_MAX) return EngineResult.invalid;
    outputFxEnabledCalls.add((bus: bus, index: index, enabled: enabled));
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxChainEnabled({
    required int bus,
    required bool enabled,
  }) {
    if (bus < 0 || bus >= LE_MAX_OUTPUT_BUSES) return EngineResult.invalid;
    outputFxChainEnabledCalls.add((bus: bus, enabled: enabled));
    return EngineResult.ok;
  }

  /// Recorded [setAllTracksFx] calls, in order, for test assertions.
  final allTracksFxCalls = <({int index, TrackEffectType type})>[];

  /// Recorded [setAllTracksFxCount] calls, in order.
  final allTracksFxCountCalls = <int>[];

  @override
  EngineResult setAllTracksFx({
    required int index,
    required TrackEffectType type,
  }) {
    if (index < 0 || index >= kTrackEffectMax) return EngineResult.invalid;
    allTracksFxCalls.add((index: index, type: type));
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxCount({required int count}) {
    allTracksFxCountCalls.add(count);
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxParam({
    required int index,
    required int param,
    required double value,
  }) {
    if (index < 0 || index >= kTrackEffectMax) return EngineResult.invalid;
    if (param < 0 || param >= kTrackEffectParams) return EngineResult.invalid;
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxEnabled({
    required int index,
    required bool enabled,
  }) {
    if (index < 0 || index >= kTrackEffectMax) return EngineResult.invalid;
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxChainEnabled({required bool enabled}) =>
      EngineResult.ok;

  /// Recorded channel-handling calls, in order, for test assertions.
  final fxChannelsCalls = <({String stage, int index, FxChannels channels})>[];

  @override
  EngineResult setLaneFxChannels({
    required int channel,
    required int lane,
    required int index,
    required FxChannels channels,
  }) {
    fxChannelsCalls.add((stage: 'lane', index: index, channels: channels));
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxChannels({
    required int input,
    required int index,
    required FxChannels channels,
  }) {
    fxChannelsCalls.add((stage: 'monitor', index: index, channels: channels));
    return EngineResult.ok;
  }

  @override
  EngineResult setTrackFxChannels({
    required int channel,
    required int index,
    required FxChannels channels,
  }) {
    fxChannelsCalls.add((stage: 'track', index: index, channels: channels));
    return EngineResult.ok;
  }

  @override
  EngineResult setOutputFxChannels({
    required int bus,
    required int index,
    required FxChannels channels,
  }) {
    fxChannelsCalls.add((stage: 'output', index: index, channels: channels));
    return EngineResult.ok;
  }

  @override
  EngineResult setAllTracksFxChannels({
    required int index,
    required FxChannels channels,
  }) {
    fxChannelsCalls.add((stage: 'allTracks', index: index, channels: channels));
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputOutput({
    required int input,
    required int mask,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputMute({
    required int input,
    required bool muted,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputPan({required int input, required double pan}) {
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) {
      return EngineResult.invalid;
    }
    _monitorPan[input] = pan.clamp(-1.0, 1.0);
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) => _requireRunning();

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) => _requireRunning();

  /// Recorded [setInputConditioningEnabled] calls, in order, for test
  /// assertions.
  final inputConditioningEnabledCalls = <({int input, bool enabled})>[];

  /// Recorded [setInputConditioningParam] calls, in order, for test assertions.
  final inputConditioningParamCalls =
      <({int input, InputConditioningParam param, double value})>[];

  // Conditioning setters record their calls and work while stopped (a direct
  // atomic publish native-side), so a repository/cubit test can assert what was
  // pushed without a running device — the same posture as the FX-enable twins
  // above.
  @override
  EngineResult setInputConditioningEnabled({
    required int input,
    required bool enabled,
  }) {
    if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) {
      return EngineResult.invalid;
    }
    inputConditioningEnabledCalls.add((input: input, enabled: enabled));
    return EngineResult.ok;
  }

  @override
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) {
    if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) {
      return EngineResult.invalid;
    }
    inputConditioningParamCalls.add(
      (input: input, param: param, value: value),
    );
    return EngineResult.ok;
  }

  /// Recorded [setMonitorInputFxEnabled] calls, in order, for test assertions.
  final monitorInputFxEnabledCalls = <({int input, int index, bool enabled})>[];

  /// Recorded [setMonitorInputFxChainEnabled] calls, in order, for test
  /// assertions.
  final monitorInputFxChainEnabledCalls = <({int input, bool enabled})>[];

  // Monitor twins of the lane enable setters: same works-while-stopped
  // contract (see setLaneFxEnabled above).
  @override
  EngineResult setMonitorInputFxEnabled({
    required int input,
    required int index,
    required bool enabled,
  }) {
    if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) {
      return EngineResult.invalid;
    }
    if (index < 0 || index >= LE_FX_MAX) return EngineResult.invalid;
    monitorInputFxEnabledCalls.add(
      (input: input, index: index, enabled: enabled),
    );
    return EngineResult.ok;
  }

  @override
  EngineResult setMonitorInputFxChainEnabled({
    required int input,
    required bool enabled,
  }) {
    if (input < 0 || input >= LE_MAX_MONITORED_INPUTS) {
      return EngineResult.invalid;
    }
    monitorInputFxChainEnabledCalls.add((input: input, enabled: enabled));
    return EngineResult.ok;
  }

  // The mock runs no DSP and holds no engine-side chain, so every chain
  // fingerprints to the empty-chain basis (the repository owns the real cache).
  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      FxFingerprint.offset;

  @override
  int monitorFxFingerprint({required int input}) => FxFingerprint.offset;

  /// Per-lane cache states this mock reports, keyed by `(channel, lane)`.
  /// There is no cache in the mock engine, so a test that cares about the
  /// debug telemetry seeds this directly; anything unseeded reads as
  /// [LaneCacheState.live], which is also what a real engine with caching
  /// disabled reports.
  final Map<(int, int), LaneCacheState> seededLaneCacheStates = {};

  @override
  Map<(int, int), LaneCacheState> laneCacheStates() {
    final states = <(int, int), LaneCacheState>{};
    for (var t = 0; t < _tracks.length; t++) {
      for (var l = 0; l < kMaxLanes; l++) {
        states[(t, l)] = seededLaneCacheStates[(t, l)] ?? LaneCacheState.live;
      }
    }
    return states;
  }

  @override
  Float32List readVisual() => Float32List(0);

  @override
  Float32List readTrackVisual(int channel) => Float32List(0);

  @override
  Float32List exportTrack(int channel) => Float32List(0);

  @override
  Float32List exportTrackLane(int channel, int lane) => Float32List(0);

  @override
  EngineResult importTrack(int channel, Float32List pcm) => _requireRunning();

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) =>
      _requireRunning();

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) => Float32List(0);

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) => _requireRunning();

  @override
  TrackHistory exportHistory(int channel) => TrackHistory.none;

  @override
  EngineResult finalizeHistory(int channel, TrackHistory history) =>
      _requireRunning();

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) =>
      _requireRunning();

  /// The capture directory of the most recent [perfArm] call, for test
  /// assertions. `null` until the first arm.
  String? lastPerfCaptureDir;

  /// The target of the most recent [perfArm] call. `null` until the first.
  PerfTarget? lastPerfTarget;

  @override
  EngineResult perfArm(PerfTarget target) {
    final captureDir = target.captureDir;
    if (captureDir.isEmpty) return EngineResult.invalid;
    lastPerfTarget = target;
    final result = _requireRunning();
    if (!result.isOk) return result;
    if (!_perfArmed) _perfFollowArmed = _perfFollowPending; // frozen per take
    _perfArmed = true; // idempotent: re-arming just keeps it armed
    lastPerfCaptureDir = captureDir;
    return EngineResult.ok;
  }

  @override
  EngineResult setPerfFollowOutput({required bool follow}) {
    _perfFollowPending = follow;
    return EngineResult.ok;
  }

  @override
  EngineResult perfDisarm() {
    _perfArmed = false; // idempotent: disarming an unarmed mock is a no-op
    return EngineResult.ok;
  }

  /// What [volumeSpace] reports. `null` models a platform that cannot
  /// answer; set a reading to model a volume of that size with that much room.
  VolumeSpace? volumeSpaceValue = const VolumeSpace(
    totalBytes: 2 << 40, // 2 TiB, half of it
    freeBytes: 1 << 40, // free: plenty, by default
  );

  @override
  VolumeSpace? volumeSpace(String path) =>
      path.isEmpty ? null : volumeSpaceValue;

  /// Every directory [syncDirectory] was asked to sync, in order.
  final List<String> syncedDirectories = [];

  @override
  bool syncDirectory(String path) {
    if (path.isEmpty) return false;
    syncedDirectories.add(path);
    return true;
  }

  /// The `captureDir` passed to the most recent [renderBegin] call, for test
  /// assertions. `null` until the first render.
  String? lastRenderCaptureDir;

  /// The per-track outcomes [renderTrackStatuses] reports once a render has
  /// started — set this before calling [renderBegin] to model a specific
  /// scenario (e.g. a partial-success render).
  List<PerformanceRenderTrackStatus> mockRenderTrackStatuses = const [];

  bool _renderStarted = false;

  @override
  EngineResult renderBegin(String captureDir) {
    if (captureDir.isEmpty) return EngineResult.invalid;
    if (_renderStarted) return EngineResult.alreadyRunning;
    _renderStarted = true;
    lastRenderCaptureDir = captureDir;
    return EngineResult.ok;
  }

  @override
  PerformanceRenderProgress renderPoll() =>
      // The mock has no real worker thread — a "started" render is already
      // done, 100%, the instant it starts. That happens to be the same value
      // as "never started" (PerformanceRenderProgress.empty), so there is
      // nothing for _renderStarted to distinguish here; it still gates
      // renderTrackStatuses below.
      PerformanceRenderProgress.empty;

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() =>
      _renderStarted ? mockRenderTrackStatuses : const [];

  @override
  EngineResult renderCancel() {
    _renderStarted = false;
    return EngineResult.ok;
  }

  @override
  void dispose() {
    _running = false;
    _activeConfig = null;
  }

  EngineResult _requireRunning() =>
      _running ? EngineResult.ok : EngineResult.notRunning;
}

/// A deterministic [PluginSlotHandle] returned by [MockAudioEngine], carrying
/// the loaded plugin id so tests and UI development can assert on it, plus a
/// small set of fake parameters with mutable values.
class MockPluginSlotHandle implements PluginSlotHandle {
  /// Creates a [MockPluginSlotHandle] for [pluginId], seeded with the default
  /// value of each [mockParams] entry.
  MockPluginSlotHandle(this.pluginId)
    : _values = {for (final p in mockParams) p.id: p.def},
      stateBlob = Uint8List.fromList('mock-state:$pluginId'.codeUnits);

  /// The id of the plugin this handle was loaded from.
  final String pluginId;

  final Map<int, double> _values;

  /// Whether this slot's (fake) native editor window is open. Toggled by
  /// [MockAudioEngine.pluginEditorOpen] / `pluginEditorClose`.
  bool editorOpen = false;

  /// The slot's fake opaque state — deterministic + non-empty (derived from
  /// [pluginId]) so D-P1 capture/restore round-trips in tests.
  Uint8List stateBlob;

  /// The deterministic fake parameter set every mock plugin exposes: three
  /// automatable knobs ranged 0..1, mirroring the native StubHost.
  static const List<PluginParamInfo> mockParams = [
    PluginParamInfo(
      id: 100,
      name: 'Mock Gain',
      unit: 'dB',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01, // automatable
    ),
    PluginParamInfo(
      id: 200,
      name: 'Mock Tone',
      unit: '',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01,
    ),
    PluginParamInfo(
      id: 300,
      name: 'Mock Mix',
      unit: '',
      min: 0,
      max: 1,
      def: 0.5,
      stepCount: 0,
      flags: 0x01,
    ),
  ];

  /// The current value of parameter [paramId], or `0` if unknown.
  double paramValue(int paramId) => _values[paramId] ?? 0;

  /// A deterministic display string for [paramId] at [value] (the value in the
  /// param's own unit), or null for an unknown id — the mock stand-in for the
  /// plugin's own value-to-text formatting.
  String? paramValueText(int paramId, double value) {
    for (final param in mockParams) {
      if (param.id != paramId) continue;
      final text = value.toStringAsFixed(2);
      return param.unit.isEmpty ? text : '$text ${param.unit}';
    }
    return null;
  }

  /// Sets parameter [paramId] to [value]; unknown ids report invalid.
  EngineResult setParamValue(int paramId, double value) {
    if (!_values.containsKey(paramId)) return EngineResult.invalid;
    _values[paramId] = value;
    return EngineResult.ok;
  }
}

class _MockLane {
  double liveLevel = 1;
  double livePan = 0;
  double imageGain = 1;
  double imagePan = 0;
  void compose() {
    volume = liveLevel * imageGain;
    pan = (livePan + imagePan).clamp(-1.0, 1.0);
  }

  int inputChannel = -1;
  int outputMask = 0x3;
  double volume = 1;
  bool muted = false;
  double pan = 0;

  /// The engine-owned "holds restorable audio" flag (#595). The mock never
  /// records, so it stays `false` — exposed so [TrackSnapshot.lanes] carries
  /// the field with the same default shape the native snapshot publishes for
  /// a lane that captured nothing.
  bool recoverable = false;
}

class _MockTrack {
  RecordTiming? recordTiming;
  double volume = 1;
  int laneCount = 1;
  final List<_MockLane> _lanes = List<_MockLane>.generate(
    kMaxLanes,
    (_) => _MockLane(),
  );

  /// The DEFINING-recording length preset (A6, D17): `0` = AUTO.
  int lengthPresetBars = 0;

  /// Solo (`setTrackSolo`). Held across start/stop like [oneShot] below.
  bool solo = false;

  /// One Shot (song-mode-spec.md §2, B4/B5c): `true` = play once then stop.
  /// Not reset on stop/start, mirroring [lengthPresetBars]'s existing
  /// (native-inaccurate) mock treatment above — the mock is a simplified
  /// simulation, not a byte-for-byte reimplementation of the native
  /// engine's `configure()` reset (see `LooperModeControl.setOneShot`'s
  /// doc).
  bool oneShot = false;

  /// The currently-settled take id (#819). The mock does not simulate the
  /// audio thread's take lifecycle, so this stays at its default `0` unless a
  /// test sets it directly to exercise the disarm-image take-identity seam.
  int settledTakeId = 0;
  int imageRevision = 0;

  _MockLane laneAt(int lane) => _lanes[lane.clamp(0, kMaxLanes - 1)];

  TrackSnapshot snapshot() {
    final lanes = [
      for (var i = 0; i < laneCount; i++)
        LaneSnapshot(
          inputChannel: _lanes[i].inputChannel,
          outputMask: _lanes[i].outputMask,
          volume: _lanes[i].volume,
          muted: _lanes[i].muted,
          lengthFrames: 0,
          rms: 0,
          peak: 0,
          recoverable: _lanes[i].recoverable,
          pan: _lanes[i].pan,
        ),
    ];
    final lane0 = lanes.isEmpty ? const LaneSnapshot.empty() : lanes.first;
    final inputMask = lane0.inputChannel >= 0 ? 1 << lane0.inputChannel : 0;
    return TrackSnapshot(
      state: TrackState.empty,
      volume: volume,
      muted: lane0.muted,
      lengthFrames: 0,
      undoDepth: 0,
      rms: 0,
      peak: 0,
      inputMask: inputMask,
      outputMask: lane0.outputMask,
      lengthPresetBars: lengthPresetBars,
      oneShot: oneShot,
      quantizeOverride: recordTiming?.quantize,
      quantizeDivOverride: recordTiming?.division,
      settledTakeId: settledTakeId,
      solo: solo,
      imageRevision: imageRevision,
      lanes: lanes,
    );
  }
}
