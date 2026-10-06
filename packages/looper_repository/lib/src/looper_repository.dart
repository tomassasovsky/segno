import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import 'package:looper_repository/src/models/audio_config.dart';
import 'package:looper_repository/src/models/engine_reopened.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/fx_chain_envelope.dart';
import 'package:looper_repository/src/models/fx_slot_ids.dart';
import 'package:looper_repository/src/models/input_monitor.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/lane.dart';
import 'package:looper_repository/src/models/looper_state.dart';
import 'package:looper_repository/src/models/mix_settings_snapshot.dart';
import 'package:looper_repository/src/models/output_setup.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart'
    show PluginDescriptor, PluginParamInfo, pluginParamInfoFromEngine;
import 'package:looper_repository/src/models/session_rig.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:looper_repository/src/models/tuner_reading.dart';
import 'package:looper_repository/src/plugin_catalog.dart';
import 'package:looper_repository/src/settings_receipt.dart';
import 'package:segno_engine/segno_engine.dart'
    hide
        AudioBackend,
        AudioDevice,
        BuiltInEffect,
        EngineConfig,
        FxChannelInput,
        FxChannelOutput,
        FxChannels,
        FxPlacement,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        PluginDescriptor,
        PluginEffect,
        PluginParamInfo,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        fxPreCount;

/// The history action the player requested.
enum RecoveryAction {
  /// Recover the previous edit.
  undo,

  /// Reapply the last undone edit.
  redo,
}

/// A recovery refused before changing the current session.
class RecoveryRefusal {
  /// Creates a refusal for the requested [action].
  const RecoveryRefusal({required this.action, required this.result});

  /// The requested direction through history.
  final RecoveryAction action;

  /// Whether the recording does not fit or an earlier command is pending.
  final EngineResult result;
}

class _TimingIntent {
  _TimingIntent(
    this.defaultTiming,
    this.rememberedDivision,
    Map<int, RecordTiming> overrides,
  ) : overrides = Map.unmodifiable(overrides);
  final RecordTiming defaultTiming;
  final GridDivision rememberedDivision;
  final Map<int, RecordTiming> overrides;
}

class _LengthIntent {
  _LengthIntent(this.defaultBars, Map<int, int> overrides, this.mode)
    : overrides = Map.unmodifiable(overrides);
  final int defaultBars;
  final Map<int, int> overrides;
  final LooperMode mode;

  _LengthIntent withMode(LooperMode next) =>
      _LengthIntent(defaultBars, overrides, next);
}

/// Builds the production [AudioEngine] backed by the native segno engine.
///
/// Lets the composition root obtain an engine without naming or importing the
/// engine package's concrete types: the returned value is held as the
/// [AudioEngine] interface and handed straight to [LooperRepository] /
/// `SessionRepository`.
AudioEngine createNativeAudioEngine() => NativeAudioEngine();

/// Builds a deterministic mock [AudioEngine] for the mock flavor, plus the
/// domain [EngineConfig] mirroring the mock's defaults so the caller can
/// auto-start straight into the looper.
///
/// The mock's own engine-typed default config is read field-by-field and mapped
/// to the domain [EngineConfig] here, so neither the caller nor this signature
/// ever names the engine's config type.
({AudioEngine engine, EngineConfig startConfig}) createMockEngine() {
  final engine = MockAudioEngine();
  final defaults = engine.defaultConfig;
  return (
    engine: engine,
    startConfig: EngineConfig(
      sampleRate: defaults.sampleRate,
      bufferFrames: defaults.bufferFrames,
      inputChannels: defaults.inputChannels,
      outputChannels: defaults.outputChannels,
      playbackDeviceId: defaults.playbackDeviceId,
      captureDeviceId: defaults.captureDeviceId,
    ),
  );
}

/// The Click stage's linear gain ceiling; unity is half of its travel.
const double kMaxClickGain = 2;

/// Owns the [AudioEngine] and is the single source of looper truth.
///
/// Polls the engine snapshot on a ticker, projects it into a [LooperState], and
/// publishes distinct states on [looperState]. Looper commands are forwarded to
/// the engine. The bloc layer depends on this repository, never on the engine.
class LooperRepository {
  /// Creates a [LooperRepository] driving [engine].
  ///
  /// [ticker] drives snapshot polling; when omitted a periodic stream at
  /// [pollInterval] (~60 Hz) is used. Injecting a ticker makes tests
  /// deterministic.
  LooperRepository({
    required AudioEngine engine,
    Stream<void>? ticker,
    Duration pollInterval = const Duration(milliseconds: 16),
    Stream<void>? reconnectTicker,
    Duration reconnectInterval = const Duration(seconds: 1),
  }) : _engine = engine,
       _ticker = ticker,
       _pollInterval = pollInterval,
       _reconnectTicker = reconnectTicker,
       _reconnectInterval = reconnectInterval {
    _controller = StreamController<LooperState>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  final AudioEngine _engine;
  final Stream<void>? _ticker;
  Duration _pollInterval;

  /// Fired when the repository changes a lane's chain or resets a remembered
  /// true mute on its own initiative. The bloc persists the resulting lane
  /// envelope, including mute, so a take's state survives a restart.
  ///
  /// UI-driven structural chain edits do NOT fire this: the bloc already
  /// persists those at the edit, and the bloc is the single settings writer for
  /// chains, so double-writing is avoided. One listener (the looper bloc); a
  /// later subscriber replaces it.
  void Function(int channel, int lane)? onLaneChainChanged;

  /// The plugin scan catalog over this repository's engine (lazily created so
  /// the scan thread only spins up when something asks for plugins). The
  /// `appVersion` cache key is a placeholder until part 7 persists the cache.
  late final PluginCatalog pluginCatalog = PluginCatalog(
    engine: _engine,
    appVersion: '0.0.0',
  );
  final Stream<void>? _reconnectTicker;
  final Duration _reconnectInterval;
  late final StreamController<LooperState> _controller;

  /// Broadcasts the input whose monitor-owned state a caller just changed.
  final StreamController<int> _monitorChanges =
      StreamController<int>.broadcast();

  /// Broadcasts the input whose monitor chain just took a PARAMETER write,
  /// throttled to [monitorParamAnnounceInterval] — see [monitorParamChanges].
  final StreamController<int> _monitorParamChanges =
      StreamController<int>.broadcast();

  /// A later device start has replayed its accepted FX recipes to the callback.
  /// Settings writers use only their own pending edit targets when it fires.
  final StreamController<({int mixGeneration, int sessionRevision})>
  _fxReplayConfirmed = StreamController.broadcast();

  /// Never emitted by the first start: a cold boot must read its saved chains
  /// before it can write any of them back.
  Stream<({int mixGeneration, int sessionRevision})> get fxReplayConfirmed =>
      _fxReplayConfirmed.stream;

  /// Per-input open throttle windows for [_monitorParamChanged]: while an
  /// input's timer runs, further param writes only mark it dirty.
  final Map<int, Timer> _paramAnnounceWindows = {};

  /// Inputs written again inside their open window; each gets one trailing
  /// announce when the window closes, so a sweep's LAST value always lands.
  final Set<int> _paramAnnounceDirty = {};
  StreamSubscription<void>? _tickerSub;
  Timer? _pollTimer;
  LooperState? _last;

  // Native session import stages PCM/history while tracks remain EMPTY. Keep
  // the cleared public vector until callback commit or acknowledged cleanup.
  List<Track>? _importTracks;
  int? _applyingSessionRevision;

  bool get _sessionAudioReserved =>
      _applyingSessionRevision != null ||
      _importTracks != null ||
      _sessionBootStartBlocked;
  EngineConfig? _lastEngineConfig;

  /// The last reconnect's verdict on the recorded loops, projected onto
  /// [EngineStatus.reopen]. `null` from a deliberate [startEngine] on, and
  /// from the moment a NEW device loss is observed: a verdict belongs to the
  /// reopen that produced it, never to a later return the engine handles by
  /// itself (a reroute or interruption the backend absorbs without a reopen).
  EngineReopened? _lastReopen;

  /// The last reopen's rig replay was refused and rolled back through
  /// [stopEngine], so no device return will ever show its verdict. The next
  /// successful [startEngine] carries it instead of clearing it, so the
  /// player is still told what happened to the loops (rule 3: no silent
  /// changes). One start only; the one after clears as usual.
  bool _reopenVerdictPending = false;

  /// Whether the user intends the engine to be running (set on a successful
  /// [startEngine], cleared on [stopEngine]). The reconnect supervisor only
  /// recovers a device the user did not deliberately stop.
  bool _intendRunning = false;

  /// Single-flight scan behind both recoveries: started the first time a
  /// restored chain surfaces a plugin that cannot be resolved — unavailable
  /// on a lane or a monitor ([_recoverUnavailablePlugins]), unnamed on a bus
  /// ([_recoverUnavailablePlugins]) — then reused so the plugin dirs are
  /// scanned at most once per session.
  ///
  /// The bus recovery runs whether or not the engine is running, so this can
  /// first be set with it stopped. Scanning does not touch the device.
  Future<List<PluginDescriptor>>? _restoredPluginScan;

  /// The accepted quantize-recording state, re-applied to the engine on every
  /// successful (re)start so it survives device changes and reconnects.
  bool get _quantize => _timing.live.defaultTiming.quantize;

  /// Accepted per-track record timing overrides (absent => follow the
  /// default). Re-applied on every successful (re)start.
  Map<int, RecordTiming> get _trackRecordTiming => _timing.live.overrides;

  /// The default overdub decay in percent and the per-track overrides
  /// (absent => follow the default). Remembered and re-applied on every
  /// successful (re)start; the engine takes them as feedback coefficients
  /// ([feedbackOfDecay]).
  int _overdubDecay = 0;
  final Map<int, int> _trackOverdubDecay = {};
  int _restartOverdubDecay = 0;
  final Map<int, int> _restartTrackOverdubDecay = {};

  /// Durable default and override membership to replay after device
  /// replacement.
  ({int defaultPercent, Map<int, int> trackOverrides}) get decayRestartIntent =>
      (
        defaultPercent: _restartOverdubDecay,
        trackOverrides: Map.unmodifiable(_restartTrackOverdubDecay),
      );

  /// Projects authored Released values without changing current audible decay.
  void setDecayRestartIntent({
    required int defaultPercent,
    required Map<int, int> trackOverrides,
  }) {
    if (defaultPercent < 0 ||
        defaultPercent > 100 ||
        trackOverrides.entries.any(
          (e) => e.key < 0 || e.key >= 8 || e.value < 0 || e.value > 100,
        )) {
      throw ArgumentError('Invalid durable decay intent');
    }
    _restartOverdubDecay = defaultPercent;
    _restartTrackOverdubDecay
      ..clear()
      ..addAll(trackOverrides);
  }

  late final _oneShot = SettingsReceipt<_OneShotIntent>(
    _OneShotIntent(const {}, defaultValue: false),
    send: _sendOneShot,
    running: () => _intendRunning,
    publish: () => _reproject(forcePublication: true),
  );

  /// An uncertain receipt owes its Released vector until Retry or restart.
  bool get oneShotRecoveryRequired => _oneShot.recoveryRequired;

  /// Durable membership for engine restart and named session capture.
  ({bool defaultOneShot, Map<int, bool> trackOverrides})
  get oneShotRestartIntent => (
    defaultOneShot: _oneShot.restart.defaultValue,
    trackOverrides: _oneShot.restart.overrides,
  );

  /// Playback refusals and autonomous restart uncertainty.
  Stream<EngineResult> get oneShotFailures => _oneShot.failures;

  /// Per-track forced loop multiples (absent => auto). The global rec/dub and
  /// auto-record (sound-activated) flags. All re-applied on every (re)start.
  final Map<int, int> _trackMultiple = {};
  int _defaultMultiple = 0;
  bool _recDub = false;
  late final _recordStart =
      SettingsReceipt<({int countInBars, bool soundStart})>(
        (countInBars: 0, soundStart: false),
        send: _sendRecordStart,
        running: () => _intendRunning,
        publish: () => _reproject(forcePublication: true),
      );
  // The native edit kind of the request being sent; replays restore.
  RecordStartEditKind _recordStartEdit = RecordStartEditKind.restore;
  final _recordingInputRequired = StreamController<int>.broadcast();

  /// A fresh capture the engine refused with [EngineResult.notReady]: the
  /// one-block window after an Undo-to-empty, Clear or cancelled take in which
  /// the callback may still hold the track's buffers (#1146). Retried exactly
  /// once from the poll, after a further callback block has published; a
  /// second refusal is reported on [recordRefusals].
  _RecordRetry? _recordRetry;
  bool _retryingRecord = false;
  bool _retrySuperseded = false;
  final _recordRefusals = StreamController<int>.broadcast();
  final _overdubRefusals = StreamController<int>.broadcast();

  /// The desired global master output gain (`0..1`), re-applied to the engine
  /// on every successful (re)start so it survives device changes and
  /// reconnects. Unity (`1.0`) until set.
  double _masterGain = 1;

  /// The desired master peak-limiter state, re-applied to the engine on every
  /// successful (re)start (a fresh start resets the limiter to off). `final`
  /// only because nothing writes the limiter yet — it is the state the engine
  /// is actually driven with, not a constant callers may assume; see
  /// [limiterEnabled] for why it is cached at all.
  final bool _limiterEnabled = true;
  final double _limiterCeiling = 0.99;

  /// The record-latency compensation offset (frames), last set explicitly or
  /// captured from an engine measurement. Remembered and re-applied on every
  /// (re)start so a device change / reconnect keeps the round-trip compensation
  /// — a fresh start resets the engine's offset to 0. Zero (no compensation)
  /// until set or measured.
  int _recordOffset = 0;

  /// The tuner's armed input, or `-1` when disarmed. Re-applied on every
  /// (re)start so an arm survives a reconnect under an open Tuner face; `-1`
  /// is the resting value, since the face disarms on its way out, so nothing
  /// resumes analysing behind a face nobody is looking at.
  int _tunerInput = -1;

  /// Musical settings retained across device restarts and restored sessions.
  /// Explicit edits and session recall update the desired tempo. Stopping the
  /// engine captures its final tapped/derived tempo and source for reconnect.
  /// Live session saves use the engine's settled snapshot as one clock record.
  double _tempoBpm = 0;
  TempoSource _tempoSource = TempoSource.none;
  int _tsNum = 4;
  int _tsDen = 4;
  bool _syncTempo = true;
  GridDivision get _quantizeDiv => _timing.live.rememberedDivision;
  late final _clickMode = SettingsReceipt<ClickMode>(
    ClickMode.off,
    send: _sendClickMode,
    running: () => _intendRunning,
    publish: () => _reproject(forcePublication: true),
  );
  int _clickMask = 0;
  late final _clickVolume = SettingsReceipt<double>(
    1,
    send: _sendClickVolume,
    running: () => _intendRunning,
    publish: () => _reproject(forcePublication: true),
  );
  bool _sessionBootStartBlocked = false;

  /// Whether a loaded rig still owes its complete boot settings image.
  bool get sessionBootRecoveryRequired => _sessionBootStartBlocked;

  /// Prevents restart while session boot persistence or recovery is pending.
  void blockStartForSessionBoot() => _sessionBootStartBlocked = true;

  /// Releases the session boot fence only after its image and bindings commit.
  void clearSessionBootStartBlock() => _sessionBootStartBlocked = false;

  /// The five-mode axis (B2a, D4). Remembered and re-applied on every
  /// successful (re)start, exactly like the tempo grid settings above: the
  /// native engine seeds it once in `le_engine_create` and never resets it in
  /// `le_engine_configure`, so this field only matters for re-establishing
  /// state on a genuinely fresh engine instance. Unlike [_tempoBpm], `multi`
  /// (the zero value) IS pushed on every (re)start — there is no "unset"
  /// sentinel to special-case, mirroring [_syncTempo] / [_quantizeDiv].
  /// Never reset on [clear]: the plan specifies no engine-side "revert to
  /// Multi" event, so the mode simply persists across a clear-all the same
  /// way it persists across a device restart.
  LooperMode get _looperMode => _length.live.mode;

  /// An explicit crown ([crownPrimary]) requested while the engine was not
  /// running, held until the next start pushes it; `null` when nothing is
  /// pending. The ENGINE owns the crown itself (it crowns the first completed
  /// take and clears the crown when the session empties), so unlike
  /// [_looperMode] nothing is re-applied on a later restart: a restart empties
  /// the rig, and an empty rig has no crown.
  int? _pendingCrown;

  /// Future-recording length: absent track overrides inherit the default;
  /// explicit zero is Custom Auto. Multi shares the default while retaining
  /// independent-mode overrides without applying them.
  int get _defaultLengthPreset => _length.live.defaultBars;
  Map<int, int> get _trackLengthPreset => _length.live.overrides;

  /// Whether an uncertain length receipt owes its vector until Retry or a
  /// restart lands it.
  bool get lengthRecoveryRequired => _length.recoveryRequired;

  /// Durable presets for restart and session capture, projected to Released.
  ({int defaultBars, Map<int, int> trackOverrides, LooperMode mode})
  get lengthRestartIntent => (
    defaultBars: _length.restart.defaultBars,
    trackOverrides: _length.restart.overrides,
    mode: _length.restart.mode,
  );

  /// Whether a take is capturing: a running engine with a track recording or
  /// overdubbing. A stopped engine's last snapshot never locks a setting.
  /// Armed and counting-in tracks do not lock.
  bool get captureLocked =>
      _intendRunning &&
      _engine.snapshot().tracks.any(
        (track) =>
            track.state == TrackState.recording ||
            track.state == TrackState.overdubbing,
      );

  /// Capture locks Record length; see [captureLocked].
  bool get recordLengthCaptureLocked => captureLocked;

  static int _clampPresetBars(int bars) => bars.clamp(0, 64);

  int _effectiveLengthPreset(int channel) => _looperMode == LooperMode.multi
      ? _defaultLengthPreset
      : _trackLengthPreset[channel] ?? _defaultLengthPreset;

  List<int> _lengthPresetsFor(
    LooperMode mode, {
    int? defaultBars,
    Map<int, int>? overrides,
  }) {
    final inherited = defaultBars ?? _defaultLengthPreset;
    final custom = overrides ?? _trackLengthPreset;
    return [
      for (var channel = 0; channel < 8; channel++)
        if (mode == LooperMode.multi)
          inherited
        else
          custom[channel] ?? inherited,
    ];
  }

  late final _mix =
      SettingsReceipt<_MixIntent>(
          _mixIntent(),
          send: _sendMix,
          running: () => _intendRunning,
          publish: () => _reproject(forcePublication: true),
          accepted: _acceptMix,
        )
        // Receipt refusals and uncertainty join the admission refusals.
        ..failures.listen(_mixFailure);

  /// Whether the next mix command replays every control, not only changes.
  bool _mixReplay = false;
  int _mixRevision = 0;
  int _mixGeneration = 0;

  /// Changes at every engine lifetime and session replacement boundary.
  /// Unlike sessionRevision, this also fences stop, reconnect and disposal.
  int get mixGeneration => _mixGeneration;

  bool _mixRecoveryStartBlocked = false;

  /// Prevents any device-control path from restarting audio while the saved
  /// mix's exact checkpoint still needs recovery.
  void blockStartForMixRecovery() => _mixRecoveryStartBlocked = true;

  /// Releases the start fence only after the checkpoint was restored.
  void clearMixRecoveryStartBlock() => _mixRecoveryStartBlocked = false;

  /// Detached confirmed controls, without the immutable recorded image.
  MixSettingsSnapshot get mixSettingsSnapshot => MixSettingsSnapshot(
    trackPans: _trackPan,
    trackLevels: _trackVolume,
    laneLevels: _laneVolume,
    monitorLevels: _monitorVolume,
    inputSetup: _inputSetup,
    outputSetup: _outputSetup,
    trackSolos: _trackSolo,
    laneInputs: _laneInput,
    laneOutputs: _laneOutput,
    laneCounts: _laneCount,
  );

  /// Validates a detached candidate before durable storage is touched.
  EngineResult validateMixSettings(MixSettingsSnapshot value) {
    if (!value.isValid) return EngineResult.invalid;
    for (var channel = 0; channel < 8; channel++) {
      final count = value.laneCounts[channel] ?? 1;
      final sourceChanged =
          count != laneCount(channel) ||
          List.generate(kMaxLanes, (lane) => lane).any(
            (lane) =>
                (value.laneInputs[(channel, lane)] ?? lane) !=
                (_laneInput[(channel, lane)] ?? lane),
          );
      if (sourceChanged && recordingInputsLocked(channel)) {
        return EngineResult.invalid;
      }
      for (final lower in value.inputSetup.pairs.keys) {
        if (!sourceChanged && _inputSetup.pairs.containsKey(lower)) continue;
        final selected = {
          for (var lane = 0; lane < count; lane++)
            value.laneInputs[(channel, lane)] ?? lane,
        };
        if (selected.contains(lower) != selected.contains(lower + 1)) {
          return EngineResult.invalid;
        }
      }
    }
    for (final lower in {
      ...value.inputSetup.pairs.keys,
      ..._inputSetup.pairs.keys,
    }) {
      if (value.inputSetup.pairs.containsKey(lower) !=
              _inputSetup.pairs.containsKey(lower) &&
          (_inputPairLocked(lower) || _inputPairLocked(lower + 1))) {
        return EngineResult.invalid;
      }
    }
    return EngineResult.ok;
  }

  /// Publishes all live controls in one bounded native command. Recorded
  /// source images are retained from the current confirmed repository.
  EngineResult applyMixSettings(MixSettingsSnapshot value) {
    final valid = validateMixSettings(value);
    if (!valid.isOk) return _mixFailure(valid);
    final next = _mixIntent()
      ..input = value.inputSetup
      ..output = value.outputSetup;
    next.inputs
      ..clear()
      ..addAll(value.laneInputs);
    next.routes
      ..clear()
      ..addAll(value.laneOutputs);
    next.counts
      ..clear()
      ..addAll(value.laneCounts);
    for (var channel = 0; channel < 8; channel++) {
      final before = laneCount(channel);
      final after = next.counts[channel] ?? 1;
      if (before == after) continue;
      final first = before < after ? before : after;
      next.images.removeWhere((key, _) => key.$1 == channel && key.$2 >= first);
      next.balances.removeWhere(
        (key, _) => key.$1 == channel && key.$2 >= first,
      );
    }
    next.pans
      ..clear()
      ..addAll(value.trackPans);
    next.trackLevels
      ..clear()
      ..addAll(value.trackLevels);
    next.levels
      ..clear()
      ..addAll(value.laneLevels);
    next.monitorLevels
      ..clear()
      ..addAll(value.monitorLevels);
    next.solos
      ..clear()
      ..addAll(value.trackSolos);
    return _requestMix(next);
  }

  final _mixSettingsFailures = StreamController<EngineResult>.broadcast();
  final Map<int, _PendingImage> _pendingImages = {};
  int _imageRevision = 0;

  /// Refused edits and publication failures. Cancellation is quiet.
  Stream<EngineResult> get mixSettingsFailures => _mixSettingsFailures.stream;

  /// Whether the last accepted edit has a published result.
  bool get mixSettingsSettled => _mix.settled;

  /// An uncertain mix receipt owes its vector until Retry or a restart lands
  /// it. Audio keeps running.
  bool get mixRecoveryRequired => _mix.recoveryRequired;

  /// Retry: running, re-sends the owed vector in full; stopped, stages it.
  /// Never stops audio.
  EngineResult recoverMixSettings() {
    _mixReplay = true;
    final result = _mix.recover();
    _mixReplay = false;
    _reproject();
    return result;
  }

  EngineResult _mixFailure(EngineResult result) {
    if (!_mixSettingsFailures.isClosed) _mixSettingsFailures.add(result);
    return result;
  }

  _MixIntent _mixIntent() => _MixIntent(
    pans: _trackPan,
    trackLevels: _trackVolume,
    solos: _trackSolo,
    levels: _laneVolume,
    images: _laneBasePan,
    balances: _laneBalance,
    monitorLevels: _monitorVolume,
    input: _inputSetup,
    output: _outputSetup,
    inputs: _laneInput,
    routes: _laneOutput,
    counts: _laneCount,
  );

  void _acceptMix(_MixIntent value) {
    final changedMonitors = <int>{
      for (final input in {..._monitorVolume.keys, ...value.monitorLevels.keys})
        if ((_monitorVolume[input] ?? 1) != (value.monitorLevels[input] ?? 1))
          input,
    };
    _trackPan
      ..clear()
      ..addAll(value.pans);
    _trackSolo
      ..clear()
      ..addAll(value.solos);
    _trackVolume
      ..clear()
      ..addAll(value.trackLevels);
    _laneVolume
      ..clear()
      ..addAll(value.levels);
    _laneBasePan
      ..clear()
      ..addAll(value.images);
    _laneBalance
      ..clear()
      ..addAll(value.balances);
    _monitorVolume
      ..clear()
      ..addAll(value.monitorLevels);
    _inputSetup = value.input;
    _outputSetup = value.output;
    _laneInput
      ..clear()
      ..addAll(value.inputs);
    _laneOutput
      ..clear()
      ..addAll(value.routes);
    _laneCount
      ..clear()
      ..addAll(value.counts);
    changedMonitors.forEach(_monitorChanged);
  }

  EngineMixSettings _mixPayload(_MixIntent next, {bool replay = false}) {
    final old = _mixIntent();
    final lanes = <(int, int), StereoMix>{};
    final images = <(int, int), StereoMix>{};
    final monitors = <int, StereoMix>{};
    final trims = <int, double>{};
    final solos = <int, bool>{};
    final trackLevels = <int, double>{};
    final inputRoutes = <(int, int), int>{};
    final outputRoutes = <(int, int), int>{};
    final counts = <int, int>{};
    final sourceTracks = <int>{};
    final changedPairs = {...old.input.pairs.keys, ...next.input.pairs.keys}
        .where(
          (lower) =>
              old.input.pairs.containsKey(lower) !=
              next.input.pairs.containsKey(lower),
        )
        .toSet();
    final count = _engine.snapshot().tracks.length;
    for (var ch = 0; ch < count; ch++) {
      if (replay || (next.trackLevels[ch] ?? 1) != (old.trackLevels[ch] ?? 1)) {
        trackLevels[ch] = next.trackLevels[ch] ?? 1;
      }
      final nextCount = next.counts[ch] ?? 1;
      if (replay || nextCount != (old.counts[ch] ?? 1)) counts[ch] = nextCount;
      for (var lane = 0; lane < kMaxLanes; lane++) {
        final key = (ch, lane);
        final input = next.inputs[key] ?? lane;
        if (replay || input != (old.inputs[key] ?? lane)) {
          inputRoutes[key] = input;
        }
        if (replay || (next.routes[key] ?? 3) != (old.routes[key] ?? 3)) {
          outputRoutes[key] = next.routes[key] ?? 3;
        }
        if (lane < nextCount &&
            changedPairs.any((lower) => input == lower || input == lower + 1)) {
          sourceTracks.add(ch);
        }
        final value = next.laneMix(key);
        if (replay || value != old.laneMix(key)) lanes[key] = value;
        final source = next.laneImage(key);
        if (replay || source != old.laneImage(key)) images[key] = source;
      }
      if (replay || (next.solos[ch] ?? false) != (old.solos[ch] ?? false)) {
        solos[ch] = next.solos[ch] ?? false;
      }
    }
    for (var input = 0; input < kMaxChannels; input++) {
      final value = next.monitorMix(input);
      if (replay || value != old.monitorMix(input)) monitors[input] = value;
      if (replay || next.input.trimDbOf(input) != old.input.trimDbOf(input)) {
        trims[input] = inputTrimGainOfDb(next.input.trimDbOf(input));
      }
    }
    final outputs = <int, OutputMix>{};
    for (var bus = 0; bus < kMaxOutputBuses; bus++) {
      final value = next.output.of(bus);
      if (replay || value != old.output.of(bus)) {
        outputs[bus] = (
          level: value.level,
          muted: value.muted,
          mono: value.mono,
          balance: value.balance,
        );
      }
    }
    _mixRevision = (_mixRevision + 1) & 0xffffffff;
    if (_mixRevision == 0) _mixRevision = 1;
    return EngineMixSettings(
      revision: _mixRevision,
      trackLevels: trackLevels,
      lanes: lanes,
      images: images,
      monitors: monitors,
      trims: trims,
      solos: solos,
      outputs: outputs,
      laneInputs: inputRoutes,
      laneOutputs: outputRoutes,
      laneCounts: counts,
      sourceTracks: sourceTracks,
    );
  }

  EngineResult _requestMix(_MixIntent next, {bool replay = false}) {
    if (!next.input.isValid || !next.output.isValid) {
      return _mixFailure(EngineResult.invalid);
    }
    _mixReplay = replay;
    final result = _mix.request(next);
    _mixReplay = false;
    if (!result.isOk) return _mixFailure(result);
    _reproject();
    return _mix.settled ? _mix.lastResult : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendMix(_MixIntent next) {
    final payload = _mixPayload(next, replay: _mixReplay);
    final result = _engine.setMix(payload);
    return (
      result: result,
      // The callback publishes the revision it applied; another revision
      // means the engine refused this one and kept the prior controls.
      check: () {
        if (!_engine.commandsSettled) return null;
        return _engine.snapshot().mixRevision == payload.revision
            ? (verdict: ReceiptVerdict.accepted, result: EngineResult.ok)
            : (verdict: ReceiptVerdict.refused, result: EngineResult.invalid);
      },
    );
  }

  /// Retires every pending settings receipt before replacing engine ownership.
  /// Published capture images are reconciled before their old lifetime ends.
  void _retireEngineLifetime() {
    // Session replacement also retires callers without reconfiguring native
    // storage. Keep their IDs until a later poll/admission consumes the result
    // (or INVALID after configure), rather than leaking native receipt slots.
    for (final entry in _pendingReceipts.entries) {
      entry.value?.complete(EngineResult.notReady);
      _pendingReceipts[entry.key] = null;
    }
    for (final receipt in <SettingsReceipt<Object>>[
      _clickMode,
      _clickVolume,
      _recordStart,
      _oneShot,
      _timing,
      _length,
      _mix,
    ]) {
      receipt.cancel();
    }
    _mixGeneration++;
    if (_pendingImages.isNotEmpty) _snapshotAndSettleImages();
    _pendingImages.clear();
    // A refused Record press belongs to the lifetime that refused it: never
    // start a take on a restarted engine or a loaded session for it.
    _recordRetry = null;
  }

  /// Waits for callback publication independently of UI polling. A timeout
  /// leaves the vector owed ([mixRecoveryRequired]) and audio running.
  Future<EngineResult> settleMixSettings({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _mix.settle(pollInterval: pollInterval, attempts: attempts);

  /// Whether every admitted structural recipe is callback-confirmed.
  /// Reading readiness never submits queued Clear/Undo work; explicit
  /// settlement and repository polling advance those operations.
  bool get fxRecipesSettled =>
      _historyFx.isEmpty &&
      _fxPending.entries.every((entry) {
        final key = entry.key;
        return _engine.fxRecipeRevision(
              owner: key.$1,
              channel: key.$2,
              lane: key.$3,
            ) ==
            entry.value;
      });

  void _requestHistoryFx(
    int channel,
    int lane, {
    required List<TrackEffect> effects,
    required bool enabled,
    required List<int> inheritedFrom,
    required bool restoring,
  }) {
    _historyFx[(channel, lane)] = (
      effects: List<TrackEffect>.of(effects),
      enabled: enabled,
      inheritedFrom: List<int>.of(inheritedFrom),
      restoring: restoring,
    );
    _drainHistoryFx();
  }

  /// The latest Clear/Undo intent for each lane wins after any older callback
  /// recipe. This uses the same target fence as an ordinary structural edit.
  void _drainHistoryFx() {
    for (final key in _historyFx.keys.toList()) {
      // A lane notification can synchronously drain another queued lane.
      final desired = _historyFx[key];
      if (desired == null || _fxTargetPending(FxOwner.lane, key.$1, key.$2)) {
        continue;
      }
      final result = setLaneEffects(
        channel: key.$1,
        lane: key.$2,
        effects: desired.effects,
        chainEnabled: desired.enabled,
        allowUnavailable: true,
      );
      if (!result.isOk) continue;
      _historyFx.remove(key);
      setLaneChainMeta(
        channel: key.$1,
        lane: key.$2,
        inheritedFrom: desired.inheritedFrom,
      );
      if (!desired.restoring) onLaneChainChanged?.call(key.$1, key.$2);
    }
  }

  void _stageClearUndoFx(int channel) {
    if (!_restoreFxStaged.add(channel)) return;
    final snapshot = _clearRestore[channel];
    if (snapshot == null) return;
    for (final entry in snapshot.entries) {
      _requestHistoryFx(
        channel,
        entry.key,
        effects: entry.value.effects,
        enabled: entry.value.chainEnabled,
        inheritedFrom: entry.value.inheritedFrom,
        restoring: true,
      );
    }
  }

  void _cancelStagedClearUndoFx(int channel) {
    if (!_restoreFxStaged.remove(channel)) return;
    final snapshot = _clearRestore[channel];
    if (snapshot == null) return;
    for (final lane in snapshot.keys) {
      _requestHistoryFx(
        channel,
        lane,
        effects: const [],
        enabled: true,
        inheritedFrom: const [],
        restoring: false,
      );
    }
  }

  /// A stopped callback cannot publish a queued history recipe. Keep the
  /// latest accepted Clear in the remembered rig before the next device opens.
  /// A staged Undo does not count: its audible restore was never admitted.
  Set<(int, int)> _foldHistoryFxAtQuiescence() {
    final keys = <(int, int)>{..._historyFx.keys};
    for (final channel in _restoreFxStaged) {
      for (final lane in _clearRestore[channel]?.keys ?? const <int>[]) {
        keys.add((channel, lane));
      }
    }
    keys.forEach(_foldHistoryFxKey);
    _historyFx.clear();
    _restoreFxStaged.clear();
    _pendingClearUndo.clear();
    _pendingClearAllUndo = const {};
    return keys;
  }

  /// The same fold, confined to [channels]: the tracks a partially retained
  /// reopen dropped (#1140). Their native history is gone, so their queued
  /// Clear/Undo recipes fold into the remembered rig and their pending
  /// Clear/Undo bookkeeping is forgotten; every other track keeps its queued
  /// recipes for [_drainHistoryFx] to republish after the replay.
  Set<(int, int)> _foldHistoryFxForChannels(Set<int> channels) {
    final keys = <(int, int)>{
      for (final key in _historyFx.keys)
        if (channels.contains(key.$1)) key,
    };
    for (final channel in channels) {
      if (!_restoreFxStaged.contains(channel)) continue;
      for (final lane in _clearRestore[channel]?.keys ?? const <int>[]) {
        keys.add((channel, lane));
      }
    }
    for (final key in keys) {
      _foldHistoryFxKey(key);
      _historyFx.remove(key);
    }
    for (final channel in channels) {
      _restoreFxStaged.remove(channel);
      _pendingClearUndo.remove(channel);
      if (_pendingClearAllUndo.contains(channel)) {
        _pendingClearAllUndo = const {};
      }
    }
    return keys;
  }

  /// Folds one lane's queued history recipe into the remembered rig: a staged
  /// restore drops the lane's chain outright (its audible restore was never
  /// admitted), an accepted Clear keeps its latest effects, flag and lineage.
  void _foldHistoryFxKey((int, int) key) {
    final desired = _historyFx[key];
    if (_restoreFxStaged.contains(key.$1) || desired?.restoring == true) {
      _laneEffects.remove(key);
      _laneChainEnabled.remove(key);
      _laneChainMeta.remove(key);
    } else if (desired != null) {
      if (desired.effects.isEmpty) {
        _laneEffects.remove(key);
      } else {
        _laneEffects[key] = desired.effects;
      }
      if (desired.enabled) {
        _laneChainEnabled.remove(key);
      } else {
        _laneChainEnabled[key] = false;
      }
      if (desired.inheritedFrom.isEmpty) {
        _laneChainMeta.remove(key);
      } else {
        _laneChainMeta[key] = desired.inheritedFrom;
      }
    }
  }

  bool _clearUndoFxReady(int channel) {
    _drainHistoryFx();
    final snapshot = _clearRestore[channel];
    if (snapshot == null) return true;
    for (final lane in snapshot.keys) {
      if (_historyFx.containsKey((channel, lane)) ||
          _fxTargetPending(FxOwner.lane, channel, lane)) {
        return false;
      }
    }
    return true;
  }

  bool _fxTargetPending(FxOwner owner, int channel, int lane) {
    final key = (owner, channel, lane);
    final revision = _fxPending[key];
    if (revision == null) return false;
    if (_engine.fxRecipeRevision(owner: owner, channel: channel, lane: lane) ==
        revision) {
      _fxPending.remove(key);
      return false;
    }
    return true;
  }

  /// Waits for exact recipe revisions before a boot or rig load is published.
  /// Editor persistence may opt to keep waiting past the bounded boot deadline:
  /// an accepted recipe can apply after a temporarily stalled callback. The
  /// same captured engine/session lifetime fences every poll, and [cancelled]
  /// lets a disposed editor release its waiter without publishing stale data.
  Future<EngineResult> settleFxRecipes({
    Duration pollInterval = const Duration(milliseconds: 8),
    int attempts = 64,
    bool waitForCallback = false,
    bool Function()? cancelled,
  }) async {
    if (!_intendRunning) {
      return _fxPending.isEmpty ? EngineResult.ok : EngineResult.notReady;
    }
    final generation = _mixGeneration;
    final sessionRevision = _sessionRevision;
    for (var i = 0; waitForCallback || i < attempts; i++) {
      if (generation != _mixGeneration ||
          sessionRevision != _sessionRevision ||
          !_intendRunning ||
          (cancelled?.call() ?? false)) {
        return EngineResult.notReady;
      }
      _drainHistoryFx();
      if (fxRecipesSettled) return EngineResult.ok;
      if (_engine.commandsSettled) return EngineResult.invalid;
      await Future<void>.delayed(pollInterval);
    }
    if (generation != _mixGeneration ||
        sessionRevision != _sessionRevision ||
        !_intendRunning) {
      return EngineResult.notReady;
    }
    _drainHistoryFx();
    if (fxRecipesSettled) return EngineResult.ok;
    return EngineResult.notReady;
  }

  /// Replaces saved track-pan and input-setup intent in one transaction.
  EngineResult setMixSettings({
    required Map<int, double> trackPans,
    required InputSetup inputSetup,
    OutputSetup? outputSetup,
    Map<(int, int), double> laneLevels = const {},
    Map<int, double> monitorLevels = const {},
    Map<int, double> trackLevels = const {},
  }) => applyMixSettings(
    mixSettingsSnapshot.copyWith(
      trackPans: trackPans,
      trackLevels: {..._trackVolume, ...trackLevels},
      inputSetup: inputSetup,
      outputSetup: outputSetup,
      laneLevels: {..._laneVolume, ...laneLevels},
      monitorLevels: {..._monitorVolume, ...monitorLevels},
    ),
  );

  EngineSnapshot _snapshotAndSettleImages() {
    // A settled fence may retire an absent image only from a later snapshot.
    // Reading it afterwards can mistake an in-flight join for a cancellation.
    final commandsSettled = _engine.commandsSettled;
    final snapshot = _engine.snapshot();
    for (final entry in _pendingImages.entries.toList()) {
      final ch = entry.key;
      if (ch >= snapshot.tracks.length) continue;
      final track = snapshot.tracks[ch];
      if (track.imageRevision == entry.value.revision) {
        final pending = entry.value;
        _laneBasePan.addAll(entry.value.images);
        _laneBalance.addAll(entry.value.balances);
        // A published take changes only source metadata. A concurrently
        // accepted fader edit still owns its independent live level/offset.
        _mix.pending?.images.addAll(entry.value.images);
        _mix.pending?.balances.addAll(entry.value.balances);
        if (pending.clearOnCommit) {
          if (_pendingClearUndo.remove(ch)) _clearRestore.remove(ch);
          if (_pendingClearAllUndo.contains(ch)) {
            _pendingClearAllUndo = const {};
          }
        }
        _forgetLaneMutes(ch);
        for (final inherited in pending.inherited.entries) {
          final lane = inherited.key;
          final effects = inherited.value;
          final key = (ch, lane);
          if (effects.isEmpty) {
            _laneEffects.remove(key);
            _laneChainMeta.remove(key);
          } else {
            _laneEffects[key] = effects;
            _laneChainMeta[key] = List<int>.unmodifiable([
              pending.inheritedInputs[lane],
            ]);
          }
          _laneChainEnabled.remove(key);
          _laneSlots.removeWhere((slot, _) => slot.$1 == ch && slot.$2 == lane);
          final handles = pending.inheritedHandles[lane] ?? const {};
          _fxSlots[(FxOwner.lane, ch, lane)] = handles;
          for (var index = 0; index < effects.length; index++) {
            final id = effects[index].slotId;
            final handle = id == null ? null : handles[id];
            if (handle != null) _laneSlots[(ch, lane, index)] = handle;
          }
          onLaneChainChanged?.call(ch, lane);
        }
        _pendingImages.remove(ch);
        _reproject();
      } else if (commandsSettled &&
          !track.pending &&
          track.pendingLaunch == null) {
        _pendingImages.remove(ch);
      }
    }
    return snapshot;
  }

  late final _timing = SettingsReceipt<_TimingIntent>(
    _TimingIntent(RecordTiming.immediately, GridDivision.off, const {}),
    send: _sendTiming,
    running: () => _intendRunning,
    publish: () => _reproject(forcePublication: true),
  );

  /// Which fields the next timing command edits; a full vector is `0x1ff`.
  int _timingEditMask = 0x1ff;

  /// Callback refusal or uncertainty from both explicit edits and reconnects.
  Stream<EngineResult> get recordTimingFailures => _timing.failures;

  /// No timing vector is awaiting its complete callback receipt.
  bool get recordTimingSettingsSettled => _timing.settled;

  /// An uncertain receipt owes its Released vector until Retry or restart.
  bool get recordTimingRecoveryRequired => _timing.recoveryRequired;

  /// Capture locks Record timing; see [captureLocked].
  bool get recordTimingCaptureLocked => captureLocked;

  /// Released restart intent, independent of a temporary live Held value.
  ({
    RecordTiming defaultTiming,
    GridDivision rememberedDivision,
    Map<int, RecordTiming> trackOverrides,
  })
  get recordTimingRestartIntent => (
    defaultTiming: _timing.restart.defaultTiming,
    rememberedDivision: _timing.restart.rememberedDivision,
    trackOverrides: _timing.restart.overrides,
  );

  EngineResult _requestTiming(
    _TimingIntent intent, {
    required int editMask,
    _TimingIntent? restart,
  }) {
    _timingEditMask = editMask;
    final result = _timing.request(intent, restart: restart);
    _timingEditMask = 0x1ff;
    _reproject();
    return result.isOk && _timing.settled ? _timing.lastResult : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendTiming(
    _TimingIntent intent,
  ) {
    if (captureLocked) return (result: EngineResult.invalid, check: null);
    final prior = _engine.snapshot();
    final result = _engine.setRecordTimingSettings(
      defaultTiming: intent.defaultTiming,
      rememberedDivision: intent.rememberedDivision,
      trackOverrides: intent.overrides,
      editMask: _timingEditMask,
    );
    final expected = (prior.recordTimingRevision + 2) & 0xffffffff;
    final before = _TimingIntent(
      RecordTiming.of(quantize: prior.quantize, division: prior.quantizeDiv),
      prior.quantizeDiv,
      {
        for (var c = 0; c < prior.tracks.length; c++)
          if (prior.tracks[c].quantizeOverride != null)
            c: RecordTiming.of(
              quantize: prior.tracks[c].quantizeOverride!,
              division: prior.tracks[c].quantizeDivOverride ?? GridDivision.off,
            ),
      },
    );
    return (
      result: result,
      // The revision fences the receipt; the vector must match exactly.
      check: () {
        if (!_engine.commandsSettled) return null;
        final snapshot = _engine.snapshot();
        if (snapshot.recordTimingRevision != expected) return null;
        final result = EngineResult.fromCode(snapshot.recordTimingResult);
        if (result.isOk && _timingMatches(snapshot, intent)) {
          return (verdict: ReceiptVerdict.accepted, result: result);
        }
        if (!result.isOk && _timingMatches(snapshot, before)) {
          return (verdict: ReceiptVerdict.refused, result: result);
        }
        return (
          verdict: ReceiptVerdict.uncertain,
          result: result.isOk ? EngineResult.invalid : result,
        );
      },
    );
  }

  bool _timingMatches(EngineSnapshot snapshot, _TimingIntent intent) {
    if (snapshot.tracks.length != 8 ||
        snapshot.quantize != intent.defaultTiming.quantize ||
        snapshot.quantizeDiv != intent.rememberedDivision) {
      return false;
    }
    for (var c = 0; c < 8; c++) {
      final track = snapshot.tracks[c];
      final value = intent.overrides[c];
      if (track.quantizeOverride != value?.quantize ||
          track.quantizeDivOverride != value?.division) {
        return false;
      }
    }
    return true;
  }

  /// Awaits the exact revision/result/vector, with a bounded callback deadline.
  Future<EngineResult> settleRecordTimingSettings({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _timing.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed vector while running and stages it stopped.
  /// Never stops audio.
  EngineResult recoverRecordTimingSettings() {
    final result = _timing.recover();
    _reproject();
    return result;
  }

  /// Stages or requests a complete timing vector, with an optional Released
  /// vector for restart. [editMask] names the fields an edit changes; a
  /// startup, Session or restore vector edits all of them.
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    ({
      RecordTiming defaultTiming,
      GridDivision rememberedDivision,
      Map<int, RecordTiming> trackOverrides,
    })?
    released,
    int editMask = 0x1ff,
  }) {
    bool invalid(
      RecordTiming timing,
      GridDivision remembered,
      Map<int, RecordTiming> overrides,
    ) =>
        overrides.keys.any((c) => c < 0 || c >= 8) ||
        (timing.quantize && timing.division != remembered);
    if (invalid(defaultTiming, rememberedDivision, trackOverrides) ||
        (released != null &&
            invalid(
              released.defaultTiming,
              released.rememberedDivision,
              released.trackOverrides,
            ))) {
      return EngineResult.invalid;
    }
    return _requestTiming(
      _TimingIntent(defaultTiming, rememberedDivision, trackOverrides),
      editMask: editMask,
      restart: released == null
          ? null
          : _TimingIntent(
              released.defaultTiming,
              released.rememberedDivision,
              released.trackOverrides,
            ),
    );
  }

  late final _length = SettingsReceipt<_LengthIntent>(
    _LengthIntent(0, const {}, LooperMode.multi),
    send: _sendLength,
    running: () => _intendRunning,
    publish: () => _reproject(forcePublication: true),
  );

  /// Whether the next length command also switches the looper mode.
  bool _lengthChangeMode = false;

  /// Refused length or mode receipts and autonomous restart uncertainty.
  Stream<EngineResult> get lengthSettingsFailures => _length.failures;

  /// No native request is outstanding; recovery is a separate admission gate.
  bool get lengthSettingsSettled => _length.settled;

  EngineResult _requestLengthSettings({
    required int defaultBars,
    required Map<int, int> overrides,
    required LooperMode mode,
    bool changeMode = false,
    _LengthIntent? restart,
  }) {
    _lengthChangeMode = changeMode;
    final result = _length.request(
      _LengthIntent(defaultBars, overrides, mode),
      restart: restart,
    );
    _lengthChangeMode = false;
    _reproject();
    return result.isOk && _length.settled ? _length.lastResult : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendLength(
    _LengthIntent intent,
  ) {
    if (captureLocked) return (result: EngineResult.invalid, check: null);
    final prior = _engine.snapshot();
    final bars = _lengthPresetsFor(
      intent.mode,
      defaultBars: intent.defaultBars,
      overrides: intent.overrides,
    );
    final result = _lengthChangeMode
        ? _engine.setLooperModeWithPresets(intent.mode, bars)
        : _engine.setTrackLengthPresets(bars);
    final priorBars = [
      for (final track in prior.tracks) track.lengthPresetBars,
    ];
    final priorMode = prior.looperMode;
    return (
      result: result,
      check: () {
        if (!_engine.commandsSettled) return null;
        final snapshot = _engine.snapshot();
        bool matches(List<int> expected, LooperMode mode) {
          if (snapshot.looperMode != mode ||
              snapshot.tracks.length != 8 ||
              expected.length != 8) {
            return false;
          }
          for (var c = 0; c < 8; c++) {
            if (snapshot.tracks[c].lengthPresetBars != expected[c]) {
              return false;
            }
          }
          return true;
        }

        // A capture that began after the vector landed does not undo it.
        // When the vector equals the prior one, a capture leaves it unknown
        // whether the callback applied it, so it reads as refused.
        final unchanged =
            intent.mode == priorMode &&
            [for (var c = 0; c < 8; c++) c].every(
              (c) => c < priorBars.length && bars[c] == priorBars[c],
            );
        final capturing = snapshot.tracks.any(
          (t) =>
              t.state == TrackState.recording ||
              t.state == TrackState.overdubbing,
        );
        if (matches(bars, intent.mode) && !(unchanged && capturing)) {
          return (verdict: ReceiptVerdict.accepted, result: EngineResult.ok);
        }
        // A guarded callback left the old vector whole.
        if (matches(priorBars, priorMode)) {
          return (
            verdict: ReceiptVerdict.refused,
            result: EngineResult.invalid,
          );
        }
        return (
          verdict: ReceiptVerdict.uncertain,
          result: EngineResult.invalid,
        );
      },
    );
  }

  /// Waits for raw vector/mode publication, with a lifetime-bound deadline.
  Future<EngineResult> settleLengthSettings({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _length.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed vector while running and stages it stopped.
  /// Never stops audio.
  EngineResult recoverLengthSettings() {
    _lengthChangeMode = true;
    final result = _length.recover();
    _lengthChangeMode = false;
    _reproject();
    return result;
  }

  /// Playback default and explicit track overrides, independent of audio.
  /// An absent override follows the default, including after reconnect.
  int _sessionRevision = 0;

  /// Changes when session recall takes ownership from startup preferences.
  int get sessionRevision => _sessionRevision;

  /// Future recording presets, including empty tracks.
  Map<int, int> get trackLengthPresetOverrides =>
      Map.unmodifiable(_trackLengthPreset);

  /// Musical settings for session capture and settings editors. Uses the
  /// latest published live tempo, while desired settings survive a stopped
  /// device and do not require another native snapshot per stream event.
  TransportState get sessionTransport {
    final live = _last?.transport;
    final useLiveTempo = _intendRunning && live != null && live.tempoBpm > 0;
    return TransportState(
      isRunning: _intendRunning,
      loopBars: live?.loopBars ?? 0,
      loopBeats: live?.loopBeats ?? 0,
      tempoBpm: useLiveTempo ? live.tempoBpm : _tempoBpm,
      tempoSource: useLiveTempo ? live.tempoSource : _tempoSource,
      tsNum: _tsNum,
      tsDen: _tsDen,
      syncTempo: _syncTempo,
      quantizeDiv: _quantizeDiv,
      clickMode: _clickMode.live,
      clickMask: _clickMask,
      clickVolume: _clickVolume.live,
      countInBars: _recordStart.live.countInBars,
      recDub: _recDub,
      autoRecord: _recordStart.live.soundStart,
      quantize: _quantize,
      recordTiming: defaultRecordTiming,
      overdubDecay: _overdubDecay,
      defaultOneShot: defaultOneShot,
      defaultLengthPresetBars: _defaultLengthPreset,
      defaultMultiple: _defaultMultiple,
      looperMode: _looperMode,
      primaryTrack: live?.primaryTrack ?? _pendingCrown ?? -1,
    );
  }

  /// Shared playback default: true plays each pass once, false loops.
  bool get defaultOneShot => _oneShot.live.defaultValue;

  /// Explicit playback overrides, including custom Loop values.
  Map<int, bool> get trackOneShotOverrides => _oneShot.live.overrides;

  /// Explicit record timing overrides, including values equal to the default.
  Map<int, RecordTiming> get trackRecordTimingOverrides =>
      Map.unmodifiable(_trackRecordTiming);

  /// Explicit overdub decay overrides, independent of recorded audio.
  Map<int, int> get trackOverdubDecayOverrides =>
      Map.unmodifiable(_trackOverdubDecay);

  /// Current desired recording timing, including while the device is stopped.
  RecordTiming get defaultRecordTiming =>
      RecordTiming.of(quantize: _quantize, division: _quantizeDiv);

  /// Current desired overdub decay, including while the device is stopped.
  int get defaultOverdubDecay => _overdubDecay;

  /// Per-track active lane count (absent => 1). Remembered and re-applied on
  /// every successful (re)start.
  final Map<int, int> _laneCount = {};

  /// Per-(channel, lane) recorded input channel (`-1` = none), output mask,
  /// volume, mute, and effect chain — each remembered and re-applied on every
  /// successful (re)start so they survive device changes / reconnects.
  final Map<(int, int), int> _laneInput = {};
  final Map<(int, int), int> _laneOutput = {};
  final Map<(int, int), double> _laneVolume = {};
  final Map<int, double> _trackVolume = {};

  /// Independent whole-track gain, downstream of its Pre representation.
  Map<int, double> get trackLevels => Map.unmodifiable(_trackVolume);
  final Map<(int, int), bool> _laneMute = {};

  /// The mix model (accepted design, slice 3). A lane's image is fixed at
  /// record time from its input's setup: [_laneBasePan] is where the input
  /// sat (`-1`/`1` for a pair member, its pan otherwise) and [_laneBalance]
  /// the gain the pair's balance gave its side. The engine is given the
  /// lane's EFFECTIVE pan (base plus the track's [_trackPan], clamped) and
  /// its effective volume (the level times the balance gain), so a track's
  /// fader and pan move every lane together without rewriting what the
  /// take recorded. Absent entries are centre and unity.
  final Map<(int, int), double> _laneBasePan = {};
  final Map<(int, int), double> _laneBalance = {};
  final Map<int, double> _trackPan = {};
  final Map<int, bool> _trackSolo = {};

  /// The per-input capture setup (trim, pan, pairs): remembered, pushed as
  /// the capture trim and the monitors' pan and gain, and seeded onto a
  /// lane when it records. See [InputSetup].
  InputSetup _inputSetup = const InputSetup.empty();

  /// The output setup (slice 3b): every destination off its defaults, held
  /// while stopped and replayed on every (re)start like the mix above.
  OutputSetup _outputSetup = const OutputSetup();
  final Map<(int, int), List<TrackEffect>> _laneEffects = {};

  /// Per-(channel, lane) chain-enabled flags (R15; absent => enabled). Only
  /// disabled entries are stored (default-on, self-cleaning, mirroring
  /// [_outputEnabled]), and they are re-applied on every successful (re)start
  /// — a fresh engine start resets every chain flag to enabled.
  final Map<(int, int), bool> _laneChainEnabled = {};

  /// Per-(channel, lane) inheritance provenance (R13/A8): the inputs whose
  /// monitor chains were snapshot-copied onto the lane at record time, in
  /// input order. Absent => never inherited. Repository-owned meta the engine
  /// never sees; rides the persisted chain envelope.
  final Map<(int, int), List<int>> _laneChainMeta = {};

  /// The Track-stage (per-track stereo bus) chains and the output destination
  /// chain (FX v3 part 1b), remembered and re-applied on every (re)start,
  /// mirroring [_laneEffects]. Owned by the bloc layer's `LooperBloc`.
  final Map<int, List<TrackEffect>> _trackEffects = {};
  final Map<int, List<TrackEffect>> _outputEffects = {};

  /// The All tracks recorded-mix chain (slice 3e), remembered and re-applied
  /// on every (re)start like the others. One chain for every destination: the
  /// engine runs it once per output bus over that bus's recorded mix.
  List<TrackEffect> _allTracksEffects = const [];
  bool _allTracksChainEnabled = true;

  /// Track/monitor/master chain-enabled flags (absent / `true` => enabled),
  /// stored like [_laneChainEnabled].
  final Map<int, bool> _trackChainEnabled = {};
  final Map<int, bool> _monitorChainEnabled = {};
  final Map<int, bool> _outputChainEnabled = {};

  /// What each cleared track's [undo] must put back that the engine cannot:
  /// `channel -> lane -> (chain, chain flag, provenance, mute)`. Written by
  /// [clear], consumed by [undo] only when the engine confirms the restore
  /// point survived.
  final Map<
    int,
    Map<
      int,
      ({
        List<TrackEffect> effects,
        bool chainEnabled,
        List<int> inheritedFrom,
        bool muted,
      })
    >
  >
  _clearRestore = {};

  /// Per-hardware-input live monitor mode (absent => [MonitorMode.off]). The
  /// input-level gate; per-lane routing / mix / effects live in the maps below.
  /// All re-applied on every successful (re)start so they survive device
  /// changes / reconnects.
  ///
  /// This holds **intent**. What the engine is told is [monitorResolved],
  /// which collapses [MonitorMode.auto] against the current record arm.
  final Map<int, MonitorMode> _monitorInputMode = {};

  /// The resolved gate last pushed to the engine, per input. Only inputs whose
  /// resolved value has actually moved are re-pushed on a poll, so a session
  /// sitting idle in [MonitorMode.auto] costs one map read per tick and no FFI
  /// call at all.
  final Map<int, bool> _monitorResolvedPushed = {};

  /// Per-input monitor output mask, volume, mute, and a single effect chain —
  /// each remembered and re-applied on every successful (re)start. An empty
  /// chain is the clean (dry) path; this chain is what gets snapshot-copied
  /// onto a track lane when recording into the input.
  final Map<int, int> _monitorOutput = {};
  final Map<int, double> _monitorVolume = {};
  final Map<int, bool> _monitorMute = {};
  final Map<int, List<TrackEffect>> _monitorEffects = {};

  /// Per-input conditioning-stage intent (the fixed HPF / hum-notch / expander
  /// utility stage), remembered and re-applied on every successful (re)start:
  /// the engine resets conditioning on every configure, so — like the monitor
  /// maps above — the intent lives here and is re-pushed after each device
  /// (re)open. [_condEnabled] is the stage on/off; [_condParams] holds each set
  /// parameter's real-unit value, keyed by input then [InputConditioningParam].
  final Map<int, bool> _condEnabled = {};
  final Map<int, Map<InputConditioningParam, double>> _condParams = {};

  /// Live plugin slot handles keyed by chain position — `(channel, lane,
  /// index)` for lane chains, `(input, index)` for monitor chains. Repopulated
  /// every time a chain is (re)applied to the running engine; an absent entry
  /// means the plugin is not currently loaded (engine stopped, or its load
  /// failed), so a parameter set has nowhere to go. Handles are opaque tokens
  /// the engine owns; the repository never frees them directly.
  final Map<(int, int, int), PluginSlotHandle> _laneSlots = {};
  final Map<(int, int), PluginSlotHandle> _monitorSlots = {};
  final Map<(FxOwner, int, int), Map<String, PluginSlotHandle>> _fxSlots = {};
  final Map<(FxOwner, int, int), int> _fxPending = {};
  bool _hasOpenedEngine = false;
  final Map<
    (int, int),
    ({
      List<TrackEffect> effects,
      bool enabled,
      List<int> inheritedFrom,
      bool restoring,
    })
  >
  _historyFx = {};
  final Set<int> _restoreFxStaged = {};
  var _fxRevision = 0;

  /// Structural output gate: outputs the user explicitly turned OFF (absent =>
  /// enabled). Only off entries are stored (default-on, self-cleaning), and
  /// they are re-applied on every successful (re)start so a gated output
  /// survives device changes / reconnects.
  final Map<int, bool> _outputEnabled = {};

  /// Reconnect supervision: while these are non-null a pinned device is absent
  /// and we are polling enumeration to reopen it. Their presence *is* the
  /// "awaiting reconnect" state, so there is no separate flag to keep in sync.
  StreamSubscription<void>? _reconnectSub;
  Timer? _reconnectTimer;

  /// Signature of the device list at the last restart attempt. A failed
  /// restart is not retried until the device list changes (e.g. a re-plug), so
  /// a present but unopenable device cannot thrash the engine.
  String? _lastAttemptSignature;

  bool get _isReconnecting => _reconnectSub != null || _reconnectTimer != null;

  /// The input of every monitor change, as it happens.
  ///
  /// Monitor state is the one part of the rig that is NOT in [looperState]:
  /// the projection carries tracks and buses, and a monitor lives only in
  /// these maps. So a writer that goes straight to the repository — a pedal
  /// binding resolving an `FxStage.input` target, a session apply — is
  /// invisible to anything holding its own copy, and `MonitorCubit` holds
  /// exactly that. Without this, a footswitch that bypasses an input chain
  /// leaves the console still drawing it as running.
  ///
  /// Carries the input, not the new state: a listener re-reads what it needs
  /// from the getters, which is what makes this correct for every writer
  /// rather than for the ones that remembered to describe their change.
  ///
  /// Every STRUCTURAL write announces — the chain, its power, an entry's
  /// power, the mode, mask, volume, mute, a relink, and a rebind that
  /// rewrote the chain. A parameter write does not: those arrive at
  /// controller rate from a mapped CC, and a listener that persists what it
  /// reads would write settings on every frame of a sweep. Param writes get
  /// their own throttled stream instead — [monitorParamChanges] (#605).
  Stream<int> get monitorChanges => _monitorChanges.stream;

  /// The parameter-announce cadence: the same ≤10 Hz ceiling as the editor
  /// sync poll (D-SYNC), which exists for exactly this class of problem.
  static const Duration monitorParamAnnounceInterval = Duration(
    milliseconds: 100,
  );

  /// Broadcasts the input whose monitor chain just took a parameter write —
  /// [setMonitorEffectParam], the one monitor write [monitorChanges] stays
  /// silent on — throttled to [monitorParamAnnounceInterval].
  ///
  /// A CC mapped to an input-stage param writes here at controller rate
  /// (`ControlValueResolver` routes an `FxStage.input` target straight to the
  /// repository), and without an announce the audio moves while the console
  /// knob does not — until the next structural announce makes a listener
  /// re-read the chain and the knob jumps (#605). This stream is what lets
  /// the knob follow.
  ///
  /// Deliberately DISTINCT from [monitorChanges] so a listener can treat the
  /// two differently: a structural announce is worth persisting, a swept
  /// value is not — the editor-sync poll does not persist either, and a
  /// persist-per-announce here would still write settings ten times a second
  /// for the length of a sweep.
  ///
  /// Throttle shape: the first write announces immediately (the knob starts
  /// moving on the first frame, not 100 ms late), writes inside the open
  /// window coalesce, and a dirty window closes with one trailing announce —
  /// so a burst produces its first and last values, never a stale rest.
  Stream<int> get monitorParamChanges => _monitorParamChanges.stream;

  /// Announces a change to monitor [input]. Every monitor setter ends here.
  void _monitorChanged(int input) {
    if (_monitorChanges.isClosed) return;
    _monitorChanges.add(input);
  }

  /// Announces a parameter write to monitor [input]'s chain, coalescing to at
  /// most one announce per [monitorParamAnnounceInterval] per input.
  void _monitorParamChanged(int input) {
    if (_monitorParamChanges.isClosed) return;
    if (_paramAnnounceWindows.containsKey(input)) {
      _paramAnnounceDirty.add(input);
      return;
    }
    _monitorParamChanges.add(input);
    _paramAnnounceWindows[input] = Timer(monitorParamAnnounceInterval, () {
      _paramAnnounceWindows.remove(input);
      // Trailing announce re-arms the window, so a sweep longer than one
      // window keeps announcing at the cadence rather than once per sweep.
      if (_paramAnnounceDirty.remove(input)) _monitorParamChanged(input);
    });
  }

  /// Fires once per completed [applySession]: the rig that was on the engine
  /// has been replaced wholesale by a loaded session's.
  ///
  /// This exists because the replacement is NOT reliably visible in
  /// [looperState]: the load's cleared window is a few milliseconds of mostly
  /// synchronous FFI import, so the poll-driven projection frequently never
  /// emits the empty rig in between — anything watching the stream for "the
  /// old rig is gone" (the stage's transport clock resetting its elapsed
  /// time, #678) sees the old session flow seamlessly into the new one.
  /// An explicit event is the honest seam; sampling a transient is not.
  ///
  /// Fires only on success. A failed apply leaves the rig destructively
  /// cleared, and an empty rig is a STABLE projection every stream listener
  /// does see.
  Stream<void> get rigReplaced => _rigReplaced.stream;

  final StreamController<void> _rigReplaced =
      StreamController<void>.broadcast();

  /// Refused history operations from every control surface.
  Stream<RecoveryRefusal> get recoveryRefusals => _recoveryRefusals.stream;

  final StreamController<RecoveryRefusal> _recoveryRefusals =
      StreamController<RecoveryRefusal>.broadcast();

  EngineResult _reportRecoveryResult(
    EngineResult result, {
    required bool redo,
  }) {
    if (result == EngineResult.modeMismatch ||
        result == EngineResult.notReady) {
      _recoveryRefusals.add(
        RecoveryRefusal(
          action: redo ? RecoveryAction.redo : RecoveryAction.undo,
          result: result,
        ),
      );
    }
    return result;
  }

  EngineResult _historyModeGate(Iterable<int> channels, {required bool redo}) {
    var mask = 0;
    for (final channel in channels) {
      // The FFI mask is uint32; native validates the configured track count.
      if (channel < 0 || channel >= 32) return EngineResult.invalid;
      mask |= 1 << channel;
    }
    return _reportRecoveryResult(
      _engine.historyModeGate(channels: mask, redo: redo),
      redo: redo,
    );
  }

  /// Distinct stream of looper states.
  ///
  /// A new subscriber immediately receives the most recent state before live
  /// updates, so a late listener — e.g. a bloc created after the audio-setup
  /// flow already drove the engine to a steady state — shows the current tracks
  /// instead of waiting for the next change.
  Stream<LooperState> get looperState async* {
    final last = _last;
    if (last != null) yield last;
    yield* _controller.stream;
  }

  /// The current state, read synchronously from the engine.
  ///
  /// **Every call is a fresh FFI walk**: one `snapshot()` plus a per-track and
  /// per-lane read (`1 + T + T*L` boundary crossings — ~31 on a default
  /// 8x3 rig), then two complete object graphs, including a native->Dart
  /// `String` for the device name. Correct when the caller must not miss a
  /// write it just made; wrong on a repeating timer, where it re-derives at
  /// the caller's cadence a projection [_poll] already keeps current. Timers
  /// want [lastState].
  LooperState get state => _project(_engine.snapshot());

  /// The most recently PROJECTED state — the same object [looperState] last
  /// emitted, with no engine walk.
  ///
  /// This is what a periodic reader should use. [_poll] refreshes the
  /// projection at the UI refresh rate ([pollInterval], 16 ms by default), so
  /// a 33 ms timer calling [state] pays a full engine walk to recompute a
  /// value that is at most one poll old and byte-identical to this one
  /// ([_project] is pure over the snapshot, and the poll's own `next == _last`
  /// dedupe is what proves it).
  ///
  /// Falls back to a real walk whenever the cache cannot be trusted to be
  /// current — before the first poll has landed, and equally whenever polling
  /// is not running (nobody is listening to [looperState], so nothing is
  /// refreshing [_last] and it may be arbitrarily old). A caller reading
  /// during construction, or on a repository with no subscribers, still sees
  /// the engine rather than a stale or invented rig.
  LooperState get lastState {
    final last = _last;
    return last != null && _isPolling ? last : state;
  }

  /// Whether the snapshot poll is currently running — either driven by the
  /// injected ticker or by this repository's own timer.
  bool get _isPolling => _tickerSub != null || _pollTimer != null;

  /// Reads the audio callback's self-measurement (native issue #722): how long
  /// the engine takes to service one hardware period against the period, the
  /// entry-to-entry starvation detector, and real backend dropouts — in a
  /// whole-session window and a since-the-last-arm window.
  ///
  /// **For diagnostics — a bench readout, a support screen — never for
  /// `build()`.** A method rather than a getter precisely so it does not read
  /// like cheap state: every call crosses the FFI boundary and allocates the
  /// histogram lists. More importantly, every counter it returns changes on
  /// every audio callback, so feeding it into a widget or into [state] would
  /// make each frame's value unequal to the last, defeat [looperState]'s dedupe
  /// and rebuild the whole UI continuously on an idle rig — CPU pressure
  /// invented by the instrument that exists to find CPU pressure. That is why
  /// it is not on [LooperState] at all.
  ///
  /// On healthy hardware every judged field reads zero; see
  /// [CallbackTelemetry].
  CallbackTelemetry readCallbackTelemetry() => _engine.callbackTelemetry();

  /// The most recent config passed to [startEngine], or `null` before the first
  /// successful start.
  EngineConfig? get lastEngineConfig => _lastEngineConfig;

  /// The engine + miniaudio version string.
  String get engineVersion => _engine.version;

  void _startPolling() {
    // Polling must survive subscribe/cancel cycles (hot restart, a bloc being
    // rebuilt). An injected ticker (tests) is a broadcast stream and can be
    // re-listened; the default uses a recreatable [Timer] because
    // `Stream.periodic` is single-subscription and cannot be re-listened after
    // [_stopPolling] cancels it.
    final ticker = _ticker;
    if (ticker != null) {
      _tickerSub = ticker.listen((_) => _poll());
    } else {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    }
    _poll();
  }

  void _stopPolling() {
    unawaited(_tickerSub?.cancel());
    _tickerSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// The current snapshot-poll cadence.
  Duration get pollInterval => _pollInterval;

  /// Updates the snapshot-poll cadence (UI refresh rate). When polling on the
  /// default timer, restarts it at the new [interval] so the change takes
  /// effect immediately; an injected ticker (tests) is unaffected.
  void setPollInterval(Duration interval) {
    if (interval == _pollInterval) return;
    _pollInterval = interval;
    if (_ticker == null && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    }
  }

  /// Whether each poll also reads every lane's wet-cache state into
  /// [Lane.cacheState] (R27 debug telemetry).
  ///
  /// Starts off, and stays off until a caller turns it on. While off, every
  /// lane reports a `null` cache state — honestly "not observed" rather than
  /// "live".
  ///
  /// The read itself is one batched engine sweep ([AudioEngine.laneCacheStates]
  /// — a single drain + scheduler pass for ALL lanes, #418), so the residual
  /// cost of leaving this on is one extra sweep per poll on top of the one
  /// `snapshot()` already runs. Still gated, because telemetry nobody renders
  /// should cost nothing: the app scopes it to "the Signal surface is showing
  /// AND the track-indicator preference is on" (`CacheTelemetryScope`), so
  /// the appliance — where the xrun budget is tight — never pays even that
  /// sweep outside the one screen that draws it.
  bool get cacheTelemetryEnabled => _cacheTelemetryEnabled;
  bool _cacheTelemetryEnabled = false;

  /// The last-refreshed per-lane cache states, keyed by `(channel, lane)`, or
  /// empty while telemetry is off.
  ///
  /// [_project] reads THIS rather than the engine, and only [_poll] (plus the
  /// toggle below) refreshes it. That split matters: `_project` also runs from
  /// [_reproject], which fires on every local edit — including each frame of a
  /// dragged FX knob — and re-reading telemetry there would put an engine
  /// drain inside the very gesture `_reproject` exists to keep responsive.
  /// A debug glyph can be one poll tick stale; a knob cannot be janky.
  final Map<(int, int), LaneCacheState> _laneCacheStates = {};

  /// Re-reads every lane's cache state in one batched engine sweep, or clears
  /// the map when telemetry is off. The only place the engine read happens.
  void _refreshCacheTelemetry() {
    _laneCacheStates.clear();
    if (!_cacheTelemetryEnabled) return;
    _laneCacheStates.addAll(_engine.laneCacheStates());
  }

  /// Turns per-lane wet-cache telemetry on or off (see [cacheTelemetryEnabled])
  /// and republishes immediately, so the glyph appears or clears on the toggle
  /// rather than at the next tick.
  ///
  /// **Single-owner:** this is a plain last-writer-wins switch, not a
  /// refcounted resource. Exactly one surface is expected to drive it — today
  /// the app's `CacheTelemetryScope`, which ANDs the track-indicator
  /// preference with "the Signal surface is showing" over its own lifecycle.
  /// A second independent caller would fight the first; give the switch an
  /// ownership model before adding one.
  void setCacheTelemetryEnabled({required bool enabled}) {
    if (enabled == _cacheTelemetryEnabled) return;
    _cacheTelemetryEnabled = enabled;
    // Populate (or drop) the states before republishing, so the toggle shows
    // the real thing immediately instead of a tick of empty glyphs.
    _refreshCacheTelemetry();
    // _reproject, not _poll: this is an out-of-band republish like every other
    // local edit, and it must not run the periodic poll's device supervision.
    _reproject();
  }

  // Null observations are expired callers with native claims still to drain.
  // Admission drains too because normal polling stops without UI subscribers.
  final Map<int, ReceiptObservation?> _pendingReceipts = {};
  bool _drainReceipt(int request) {
    if (!_pendingReceipts.containsKey(request)) return false;
    final result = _engine.readRequestResult(request);
    if (result == null) return false;
    _pendingReceipts.remove(request)?.complete(result);
    return true;
  }

  bool _drainReceipts() {
    var changed = false;
    for (final request in _pendingReceipts.keys.toList()) {
      if (_drainReceipt(request)) changed = true;
    }
    return changed;
  }

  Future<EngineResult> _requestReceipt(RequestAdmission Function() admit) {
    _drainReceipts();
    final admission = admit();
    if (!admission.result.isOk) return Future.value(admission.result);
    final observation = ReceiptObservation();
    _pendingReceipts[admission.request] = observation;
    _watchReceipt(
      observation,
      settle: () => _drainReceipt(admission.request),
      expire: () {
        _pendingReceipts[admission.request] = null;
        observation.complete(EngineResult.notReady);
      },
    );
    return observation.wait(
      pollInterval: const Duration(milliseconds: 10),
      attempts: 50,
    );
  }

  /// Completes with the exact callback outcome, never queue acceptance alone.
  Future<EngineResult> toggleFade({
    required int channel,
    required double seconds,
  }) => _requestReceipt(
    () => _engine.toggleFade(channel: channel, seconds: seconds),
  );

  /// Restores one coherent image to its observed native material lifetime.
  Future<EngineResult> installFade({
    required int channel,
    required FadeImage image,
  }) => _requestReceipt(
    () => _engine.installFade(channel: channel, image: image),
  );

  /// Flips the read direction of track [channel]'s recorded material at its
  /// current position (Reverse, #1162). Completes with the exact callback
  /// outcome: [EngineResult.invalid] for an empty or writing track,
  /// [EngineResult.notReady] while an arm or launch is pending on it. The
  /// projection's `Track.reversed` follows the published direction.
  Future<EngineResult> toggleReverse({required int channel}) =>
      _requestReceipt(() => _engine.toggleReverse(channel: channel));

  /// Doubles or halves track [channel] as one history entry (#1168).
  /// Completes with the exact callback outcome; refused before any change
  /// with [EngineResult.modeMismatch], [EngineResult.capacity],
  /// [EngineResult.invalid] or [EngineResult.notReady] (also while a
  /// Session is being applied). [undo] restores the other length; the
  /// projection's `Track.lengthFrames`, `multiple` and `syncDivisor` follow.
  Future<EngineResult> editLength({
    required int channel,
    required LengthEdit edit,
  }) {
    if (_sessionAudioReserved) return Future.value(EngineResult.notReady);
    return _requestReceipt(
      () => _engine.editLength(channel: channel, edit: edit),
    );
  }

  /// Installs an explicit direction (Session recall, before the commit).
  Future<EngineResult> installReverse({
    required int channel,
    required bool reversed,
  }) => _requestReceipt(
    () => _engine.installReverse(channel: channel, reversed: reversed),
  );

  void _watchReceipt(
    ReceiptObservation observation, {
    required bool Function() settle,
    required void Function() expire,
  }) {
    observation.start(
      settle: settle,
      expire: expire,
      publish: () => _reproject(forcePublication: true),
    );
  }

  bool _observeSettingsReceipts() {
    var changed = _drainReceipts();
    for (final observation in [
      _oneShot.observation,
      _clickVolume.observation,
      _clickMode.observation,
      _recordStart.observation,
      _timing.observation,
      _length.observation,
      _mix.observation,
    ]) {
      if (observation?.check() ?? false) changed = true;
    }
    return changed;
  }

  void _poll() {
    final receiptsSettled = _observeSettingsReceipts();
    _drainHistoryFx();
    final snapshot = _snapshotAndSettleImages();
    _retryRefusedRecord(snapshot);
    _refreshCacheTelemetry();
    _superviseDevice(devicePresent: snapshot.devicePresent);
    // A measurement auto-sets the engine's offset (it never flows through
    // setRecordOffset), so mirror it into the remembered value here — otherwise
    // a restart would re-apply a stale offset. Guard on > 0 so a transient zero
    // during a restart / in-flight measurement can't clobber a good value; an
    // explicit "no compensation" (0) still lands via setRecordOffset.
    if (snapshot.recordOffsetFrames > 0) {
      _recordOffset = snapshot.recordOffsetFrames;
    }
    _settlePendingClearUndos();
    // Remember retired restore points even when no Undo is waiting. A later
    // individual clear must not re-form an obsolete clear-all group.
    _intactClearAllGroup();
    final next = _project(snapshot);
    _rememberLooperMode(next, snapshot.looperMode);
    // Settlement also reaches persistence when the visible state is unchanged.
    if (next == _last && !receiptsSettled) {
      return;
    }
    _last = next;
    _forgetEmptyWaveforms(next);
    // Before listeners see it: `auto` monitors resolve against the arm state
    // this projection just moved, and the gate should open on the same frame
    // the track arms rather than one behind it.
    _reconcileAutoMonitors();
    _controller.add(next);
  }

  /// Re-projects and emits immediately (deduped), skipping the device
  /// supervision the periodic poll does. Used so a local edit — e.g. a lane FX
  /// param the UI drives — reflects on the next frame rather than waiting for
  /// the next poll tick (which would make a dragged knob feel a tick behind).
  void _reproject({bool forcePublication = false}) {
    final receiptsSettled = _observeSettingsReceipts();
    final snapshot = _snapshotAndSettleImages();
    final next = _project(snapshot);
    _rememberLooperMode(next, snapshot.looperMode);
    // Settlement also reaches persistence when the visible state is unchanged.
    if (!forcePublication && next == _last && !receiptsSettled) {
      return;
    }
    _last = next;
    _forgetEmptyWaveforms(next);
    _reconcileAutoMonitors();
    _controller.add(next);
  }

  /// Watches the pinned device's presence each poll. When a pinned device goes
  /// absent (and the user did not stop the engine), it begins polling
  /// enumeration on the reconnect ticker/timer; when it reappears it stops and
  /// restarts the engine on that device. System default ('' device ids) is
  /// never auto-restarted. Cheap on the hot path: only a bool is checked here;
  /// the expensive enumeration runs on the slower reconnect cadence.
  void _superviseDevice({required bool devicePresent}) {
    if (!_isPinned || !_intendRunning) return;
    if (!devicePresent && !_isReconnecting) {
      _startReconnectPolling();
    } else if (devicePresent && _isReconnecting) {
      _stopReconnectPolling();
    }
  }

  /// Whether the last successful start pinned a specific device (vs the system
  /// default, which is never auto-restarted on transient loss).
  bool get _isPinned {
    final config = _lastEngineConfig;
    return config != null &&
        (config.playbackDeviceId.isNotEmpty ||
            config.captureDeviceId.isNotEmpty);
  }

  void _startReconnectPolling() {
    _lastAttemptSignature = null; // a fresh loss may retry immediately
    // A new loss episode: whatever the previous reopen decided about the
    // loops is not what THIS return will mean. A return the backend produces
    // on its own (a reroute, an interruption ending) reopens nothing and must
    // read as a plain restore, not re-raise a stale "tracks dropped" or
    // "loops cleared" notice over an intact rig.
    _lastReopen = null;
    _reopenVerdictPending = false;
    final ticker = _reconnectTicker;
    if (ticker != null) {
      _reconnectSub = ticker.listen((_) => _attemptReconnect());
    } else {
      _reconnectTimer = Timer.periodic(
        _reconnectInterval,
        (_) => _attemptReconnect(),
      );
    }
  }

  void _stopReconnectPolling() {
    unawaited(_reconnectSub?.cancel());
    _reconnectSub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Reopens the pinned device once it reappears in enumeration. A reopen is
  /// attempted at most once per distinct device list: if it fails, we wait for
  /// the list to change (e.g. a re-plug) before retrying, so a present-but-
  /// unopenable device cannot thrash the engine. (Engine calls are synchronous,
  /// so no re-entrancy guard is needed.)
  ///
  /// A refused attempt is not an attempt: while the admission predicate holds
  /// the engine open (a Session apply, a boot fence, a settings recovery) the
  /// device list is NOT recorded as tried and the dead device is NOT released,
  /// so the next admissible tick reopens on the very same list. Recording the
  /// signature before the refusal used to suppress every later attempt until
  /// the hardware was re-plugged.
  void _attemptReconnect() {
    final config = _lastEngineConfig;
    if (config == null || !_isPinned) {
      _stopReconnectPolling();
      return;
    }
    if (_startRefused) return;
    final devices = _engine
        .enumerateDevices()
        .map(audioDeviceFromEngine)
        .toList();
    if (!_pinnedDevicesPresent(config, devices)) {
      return; // still absent — keep waiting
    }
    final signature = devices
        .map((d) => '${d.isInput ? 'i' : 'o'}:${d.id}')
        .join('|');
    if (signature == _lastAttemptSignature) return; // already tried this set
    // Release the dead device with a RAW stop (not stopEngine(), which would
    // clear _intendRunning and disarm this supervisor), then reopen through
    // the engine's material-preserving path (#1140): the recorded loops come
    // back stopped, and the remembered rig (lanes, monitors, mix, effects,
    // output gate, hosted plugins) is replayed onto them exactly as after a
    // start. The reopen discards queued commands, so its retire step cancels
    // their waiters before the confirmed settings replay, without disarming
    // reconnect supervision.
    _engine.stop();
    _lastAttemptSignature = signature;
    if (_reopenEngine(config).isOk) {
      _stopReconnectPolling();
    }
  }

  /// Whether every pinned device id in [config] is present in [devices]. An
  /// empty id (system default) is always considered present.
  bool _pinnedDevicesPresent(EngineConfig config, List<AudioDevice> devices) {
    bool present(String id, {required bool isInput}) =>
        id.isEmpty || devices.any((d) => d.isInput == isInput && d.id == id);
    return present(config.playbackDeviceId, isInput: false) &&
        present(config.captureDeviceId, isInput: true);
  }

  LooperState _project(EngineSnapshot s) => LooperState(
    mixGeneration: _mixGeneration,
    tuner: TunerReading(
      hz: s.tunerHz,
      confidence: s.tunerConfidence,
      input: s.tunerInput,
    ),
    transport: TransportState(
      isRunning: s.isRunning,
      masterLengthFrames: s.masterLengthFrames,
      masterPositionFrames: s.masterPositionFrames,
      tempoBpm: s.tempoBpm,
      tempoSource: s.tempoSource,
      tsNum: s.tsNum,
      tsDen: s.tsDen,
      syncTempo: s.syncTempo,
      quantizeDiv: s.quantizeDiv,
      loopBars: s.loopBars,
      loopBeats: s.loopBeats,
      currentBeat: s.currentBeat,
      // Raw mode may change before the callback publishes its command fence.
      // Every repository consumer observes the same receipt-confirmed choice.
      clickMode: _clickMode.live,
      clickMask: s.clickMask,
      clickVolume: s.clickVolume,
      // The repository's own re-apply cache, like the record start settings
      // below: the engine's mirror reads 0 while it is stopped (nothing is
      // pushed to a stopped engine) and lands a block late while it runs,
      // and the cubits that own the setting follow this value.
      countInBars: _recordStart.live.countInBars,
      countingIn: s.countingIn,
      countInBeatsLeft: s.countInBeatsLeft,
      looperMode: s.looperMode,
      // The crown every surface draws: the engine's designation when that
      // track holds a completed take, otherwise the lowest track that does
      // (the designation survives its own clear while a sibling plays, so
      // its re-record re-establishes it), and none for an empty session.
      primaryTrack: resolvedPrimaryTrack(s.primaryTrack, s.tracks),
      outputPeak: s.outputPeak,
      recDub: _recDub,
      // The record start and decay defaults are the repository's own
      // re-apply caches (what a stopped engine would be given on start);
      // the caches mirror the engine's count-in and Sound start exclusion
      // ([setRecordStartSettings]), so they read right while the
      // engine is stopped and in the mock flavour, which reports neither.
      quantize: _quantize,
      autoRecord: _recordStart.live.soundStart,
      overdubDecay: _overdubDecay,
      defaultOneShot: defaultOneShot,
      defaultLengthPresetBars: _defaultLengthPreset,
      defaultMultiple: _defaultMultiple,
      recordTiming: RecordTiming.of(
        quantize: _quantize,
        division: _quantizeDiv,
      ),
    ),
    tracks:
        _importTracks ??
        [
          for (var i = 0; i < s.tracks.length; i++)
            Track(
              channel: i,
              state: s.tracks[i].state,
              fade: s.tracks[i].fade,
              reversed: s.tracks[i].reversed,
              // An untouched live fader is unity. Native volume already
              // includes
              // source balance, which must never become a second saved level.
              volume: _trackVolume[i] ?? 1,
              muted: s.tracks[i].muted,
              pan: _trackPan[i] ?? 0,
              solo: s.tracks[i].solo,
              peakL: s.tracks[i].peakL,
              peakR: s.tracks[i].peakR,
              lengthFrames: s.tracks[i].lengthFrames,
              peak: s.tracks[i].peak,
              undoDepth: s.tracks[i].undoDepth,
              clearRestore: s.tracks[i].clearRestore,
              redoDepth: s.tracks[i].redoDepth,
              peelDepth: s.tracks[i].peelDepth,
              layerInFlight: s.tracks[i].layerInFlight,
              pending: s.tracks[i].pending,
              pendingLaunch: s.tracks[i].pendingLaunch,
              pendingTrigger: ArmTrigger.fromCode(s.tracks[i].pendingTrigger),
              positionFrames: s.tracks[i].positionFrames,
              lengthPresetBars: _effectiveLengthPreset(i),
              lengthPresetOverride: _trackLengthPreset[i],
              recordTimingOverride: _trackRecordTiming[i],
              overdubDecayOverride: _trackOverdubDecay[i],
              oneShot: _oneShot.live.effective(i),
              oneShotOverride: _oneShot.live.overrides[i],
              multiple: s.tracks[i].multiple,
              syncDivisor: s.tracks[i].syncDivisor,
              inputMask: s.tracks[i].inputMask,
              outputMask: s.tracks[i].outputMask,
              lanes: [
                for (var l = 0; l < s.tracks[i].lanes.length; l++)
                  Lane(
                    inputChannel: s.tracks[i].lanes[l].inputChannel,
                    outputMask: s.tracks[i].lanes[l].outputMask,
                    volume: _laneVolume[(i, l)] ?? 1,
                    pan: s.tracks[i].lanes[l].pan,
                    imagePan: _laneBasePan[(i, l)] ?? 0,
                    balance: _laneBalance[(i, l)] ?? 1,
                    muted: s.tracks[i].lanes[l].muted,
                    lengthFrames: s.tracks[i].lanes[l].lengthFrames,
                    effects: _laneEffects[(i, l)] ?? const [],
                    chainEnabled: laneChainEnabled(i, l),
                    inheritedFrom: _laneChainMeta[(i, l)] ?? const [],
                    inputChainDiverges: laneChainDivergesFromInput(i, l),
                    // From the last refresh, never a fresh engine read — see
                    // [_laneCacheStates] for why _project must stay cheap.
                    cacheState: _laneCacheStates[(i, l)],
                  ),
              ],
              effects: _trackEffects[i] ?? const [],
              chainEnabled: trackChainEnabled(i),
            ),
        ],
    outputChains: allOutputChains(),
    allTracksChain: allTracksChainEnvelope(),
    inputSetup: _inputSetup,
    outputSetup: _outputSetup,
    laneInputs: Map.unmodifiable(_laneInput),
    laneOutputs: Map.unmodifiable(_laneOutput),
    laneCounts: Map.unmodifiable(_laneCount),
    recordingInputLocks: Set.unmodifiable({
      ..._pendingImages.keys,
      for (var ch = 0; ch < s.tracks.length; ch++)
        if (s.tracks[ch].pending ||
            s.tracks[ch].state == TrackState.recording ||
            s.tracks[ch].state == TrackState.overdubbing)
          ch,
    }),
    outputBusCount: s.outputBusCount,
    tailResetRev: s.tailResetRev,
    // Sized by the engine to the channels the device has.
    inputPeaks: s.inputPeaks,
    monitorPeaks: s.monitorPeaks,
    outputPeaks: s.outputPeaks,
    status: EngineStatus(
      deviceName: _engine.deviceName,
      sampleRate: s.sampleRate,
      bufferFrames: s.bufferFrames,
      inputChannels: s.inputChannels,
      outputChannels: s.outputChannels,
      latencyState: latencyStateFromEngine(s.latencyState),
      measuredLatencyMs: s.measuredLatencyMs,
      xrunCount: s.xrunCount,
      isConnected: s.isRunning,
      devicePresent: s.devicePresent,
      excludedInputMask: s.excludedInputMask,
      inputClipMask: s.inputClipMask,
      inputCondMask: s.inputCondMask,
      recordOffsetFrames: s.recordOffsetFrames,
      fxAddedLatencyFrames: s.fxAddedLatencyFrames,
      activeBackend: audioBackendFromEngine(s.activeBackend),
      reopen: _lastReopen,
    ),
    // From the repository's own re-apply CACHE, not `s.outputEnabledMask`, on
    // the same reasoning as the quantize override above: the gate is re-applied
    // at every start, so while the engine is STOPPED its snapshot still reports
    // every output on. A session that loaded with outputs gated would then read
    // as audible until the device opened — and the Audio face's silence banner
    // is drawn straight off this mask.
    outputEnabledMask: _outputEnabledMask,
  );

  /// The gate as a mask: default-on, with a bit cleared per remembered off
  /// entry. Bits past the mask's own width stay set — a stored off-state for
  /// an output this rig has not got gates nothing.
  int get _outputEnabledMask {
    var mask = 0xFFFFFFFF;
    _outputEnabled.forEach((output, enabled) {
      if (!enabled && output >= 0 && output < 32) mask &= ~(1 << output);
    });
    return mask;
  }

  /// Enumerates the host's audio devices (playback + capture) for the picker.
  List<AudioDevice> devices() =>
      _engine.enumerateDevices().map(audioDeviceFromEngine).toList();

  /// Enumerates the installed ASIO drivers (one duplex [AudioDevice] each) for
  /// the backend selector's driver picker. Empty off Windows / the default
  /// build. Must not be called while running on the ASIO backend (the cubit
  /// enforces this — see the re-entrancy contract on
  /// [AudioEngine.enumerateAsioDrivers]).
  List<AudioDevice> asioDrivers() =>
      _engine.enumerateAsioDrivers().map(audioDeviceFromEngine).toList();

  /// Whether a device (re)open must be refused right now: a Session apply or
  /// boot fence is up, or a settings owner still owes its recovery. The one
  /// predicate [startEngine], [_reopenEngine] and the reconnect supervisor
  /// share, so a refused attempt is refused the same way everywhere.
  bool get _startRefused =>
      _applyingSessionRevision != null ||
      _sessionBootStartBlocked ||
      _mixRecoveryStartBlocked;

  /// Opens the audio device and starts processing.
  EngineResult startEngine(EngineConfig config) {
    if (_startRefused) return EngineResult.notReady;
    _retireEngineLifetime();
    final replayedPriorEngine = _hasOpenedEngine;
    final result = _engine.start(engineConfigToEngine(config));
    if (!result.isOk) return result;
    // A deliberate start, not a reconnect — unless the last reconnect's
    // replay rolled back before its verdict could be shown.
    if (!_reopenVerdictPending) _lastReopen = null;
    _reopenVerdictPending = false;
    if (_audioCleared(_engine.snapshot())) _importTracks = null;
    final foldedHistory = _foldHistoryFxAtQuiescence();
    return _replayRig(
      config,
      replayedPriorEngine: replayedPriorEngine,
      foldedHistory: foldedHistory,
    );
  }

  /// Reopens the pinned device after a loss WITHOUT discarding the recorded
  /// loops (#1140): the engine's own `reopen` keeps every lane's PCM, history,
  /// multiples and Fade envelopes at the same negotiated sample rate and loop
  /// cap, brings the content tracks back stopped at the loop head, drops only
  /// a take that was still capturing or a track whose Clear/Undo/Redo/cancel
  /// never applied (reported in [EngineReopened.droppedTracks]), and clears
  /// everything exactly as a start would only when the device came back at
  /// another rate or cap. The remembered rig is replayed as after any start.
  ///
  /// Dart-side history state follows the engine's verdict: on a full
  /// retention nothing is folded — the native history survived, so pending
  /// Clear/Undo recipes republish after the replay; on a partial retention
  /// only the dropped tracks' history is folded; on a clear the whole fold a
  /// start performs runs. Same admission predicate as [startEngine]; retired
  /// settings waiters complete `notReady` once; `mixGeneration` steps once;
  /// `sessionRevision` is untouched (only a Session load moves it);
  /// [fxReplayConfirmed] fires after the replayed recipes confirm.
  ///
  /// The verdict rides [EngineStatus.reopen] for the device return that
  /// follows. A replay refusal rolls the start back through [stopEngine], so
  /// no such return comes; the verdict is then carried through the next
  /// successful [startEngine] (see [_reopenVerdictPending]) and surfaced by
  /// the audio setup's re-apply instead.
  EngineResult _reopenEngine(EngineConfig config) {
    if (_startRefused) return EngineResult.notReady;
    // The stopped engine still reports the rate the loops were recorded at.
    final previousRate = _engine.snapshot().sampleRate;
    _retireEngineLifetime();
    final reopened = _engine.reopen(engineConfigToEngine(config));
    if (!reopened.result.isOk) return reopened.result;
    final snapshot = _engine.snapshot();
    final verdict = EngineReopened(
      outcome: reopened.outcome,
      droppedTracks: reopened.droppedTracks,
      previousSampleRate: previousRate,
      sampleRate: snapshot.sampleRate,
    );
    _lastReopen = verdict;
    final foldedHistory = switch (verdict.outcome) {
      ReopenOutcome.retained => const <(int, int)>{},
      ReopenOutcome.retainedPartial => _foldHistoryFxForChannels(
        verdict.droppedChannels.toSet(),
      ),
      ReopenOutcome.clearedRate ||
      ReopenOutcome.clearedCap => _foldHistoryFxAtQuiescence(),
    };
    // An import the engine dropped (its commit never applied) or a cleared
    // rig: the staged public vector no longer describes anything.
    if (!verdict.retainedAll || _audioCleared(snapshot)) _importTracks = null;
    final result = _replayRig(
      config,
      replayedPriorEngine: true,
      foldedHistory: foldedHistory,
    );
    // The surviving tracks' pending history recipes publish on top of the
    // replayed chains, now that no replay target is pending on them.
    if (result.isOk && verdict.keepsMaterial) _drainHistoryFx();
    // Rolled back: the device will not read present again until a deliberate
    // start, which must still tell the player what this reopen did.
    if (!result.isOk) _reopenVerdictPending = true;
    return result;
  }

  /// The post-open replay shared by [startEngine] and [_reopenEngine]: every
  /// remembered setting, route, chain, monitor and gate is pushed onto the
  /// freshly opened engine, and the start is rolled back ([stopEngine]) on
  /// the first refusal. [foldedHistory] names the lanes whose folded Clear the
  /// settings owner must be told about once their dry replay was admitted.
  EngineResult _replayRig(
    EngineConfig config, {
    required bool replayedPriorEngine,
    required Set<(int, int)> foldedHistory,
  }) {
    {
      _fxSlots.clear();
      _fxPending.clear();
      _laneSlots.clear();
      _monitorSlots.clear();
      _lastEngineConfig = config;
      _intendRunning = true;
      // Do not project this partial startup: remembered track lengths and
      // other rig settings are replayed below before the final projection.
      // An owed Click value replays here, so a reconnect resolves it.
      final clickResult = _clickVolume.replay();
      if (!clickResult.isOk) {
        stopEngine();
        return clickResult;
      }
      // A fresh start resets the engine's quantize flag and monitor masks;
      // re-apply the desired state so it survives device changes / reconnects.
      // An owed timing vector replays here, so a reconnect resolves it.
      final timingResult = _timing.replay();
      if (!timingResult.isOk) {
        stopEngine();
        return timingResult;
      }
      _engine
        ..setRecDub(enabled: _recDub)
        ..setDefaultMultiple(multiple: _defaultMultiple)
        ..setMasterGain(_masterGain)
        // Master peak limiter on by default: a fresh start resets it to off, so
        // re-assert the cached state here (like the rest) to guard the summed
        // output against driver clipping. No UI yet — the cache holds the
        // safety default.
        ..setLimiter(enabled: _limiterEnabled, ceiling: _limiterCeiling);
      // Re-apply the remembered record offset only when there IS compensation
      // to restore: a fresh start already defaults to 0, so pushing 0 is a
      // no-op that also clobbers the auto-measure boot path (which measures
      // instead of restoring). A device change / reconnect with a real offset
      // still gets it back.
      if (_recordOffset > 0) _engine.setRecordOffset(_recordOffset);
      // Re-arm the tuner only if it is armed RIGHT NOW — see [_tunerInput].
      // Without this a device reconnect under an open Tuner face leaves the
      // engine disarmed, and the face has no way to notice: it armed once, on
      // the way in, and will not do so again until it is closed and reopened.
      if (_tunerInput >= 0) _engine.setTunerInput(input: _tunerInput);
      // Re-apply the tempo grid + click/count-in state (A1/A2), plus the
      // looper mode (B2a): a fresh start resets all of it to the tempo-free/
      // Multi defaults, same as quantize/gain above. Only an explicitly-set
      // tempo is restored (see [_tempoBpm]'s doc) — pushing the unset `0`
      // would clamp up to 30 BPM and falsely leave the grid on; the mode has
      // no such sentinel (`multi` IS the default), so it is always pushed,
      // like sync/quantize/click above.
      if (_tempoBpm > 0) {
        _engine.restoreTempo(bpm: _tempoBpm, source: _tempoSource);
      }
      _engine
        ..setTimeSignature(_tsNum, _tsDen)
        ..setSyncTempo(on: _syncTempo)
        ..setClickOutput(_clickMask);
      final startResult = _recordStart.replay();
      if (!startResult.isOk) {
        stopEngine();
        return startResult;
      }
      final modeResult = _clickMode.replay();
      if (!modeResult.isOk) {
        stopEngine();
        return modeResult;
      }
      _lengthChangeMode = true;
      final lengthResult = _length.replay();
      _lengthChangeMode = false;
      if (!lengthResult.isOk) {
        stopEngine();
        return lengthResult;
      }
      // A crown requested while stopped lands now, once. The engine owns the
      // crown from here (see [_pendingCrown]).
      final pendingCrown = _pendingCrown;
      if (pendingCrown != null) {
        _pendingCrown = null;
        _engine.crownPrimary(channel: pendingCrown);
      }
      _trackMultiple.forEach(
        (channel, multiple) =>
            _engine.setTrackMultiple(channel: channel, multiple: multiple),
      );
      final onceResult = _oneShot.replay();
      if (!onceResult.isOk) {
        stopEngine();
        return onceResult;
      }
      var decayReplay = _engine.setOverdubFeedback(
        feedbackOfDecay(_restartOverdubDecay),
      );
      if (decayReplay.isOk) {
        // Replay all fixed slots, including inherited ones. An absent entry
        // explicitly clears a former override instead of assuming native reset.
        for (var channel = 0; channel < 8; channel++) {
          final percent = _restartTrackOverdubDecay[channel];
          decayReplay = _engine.setTrackOverdubFeedback(
            channel: channel,
            feedback: percent == null ? null : feedbackOfDecay(percent),
          );
          if (!decayReplay.isOk) break;
        }
      }
      if (!decayReplay.isOk) {
        stopEngine();
        return decayReplay;
      }
      _overdubDecay = _restartOverdubDecay;
      _trackOverdubDecay
        ..clear()
        ..addAll(_restartTrackOverdubDecay);
      // Replay routes, lane activation and live controls together.
      // An owed vector replays here, so a reconnect resolves it.
      if (!_mix.recoveryRequired) _mix.adopt(_mixIntent());
      _mixReplay = true;
      final mixResult = _mix.replay();
      _mixReplay = false;
      // As before: observe the replay at once, so an edit right after start
      // is not refused behind an already published receipt.
      if (mixResult.isOk) _reproject();
      if (!mixResult.isOk) {
        stopEngine();
        return mixResult;
      }
      for (final entry in _laneMute.entries) {
        final result = _engine.setLaneMute(
          muted: entry.value,
          channel: entry.key.$1,
          lane: entry.key.$2,
        );
        if (!result.isOk) {
          stopEngine();
          return result;
        }
      }
      for (final key in <(int, int)>{
        ..._laneEffects.keys,
        ..._laneChainEnabled.keys,
      }) {
        final fxResult = _applyLaneEffects(key.$1, key.$2);
        if (!fxResult.isOk) {
          stopEngine();
          return fxResult;
        }
      }
      // Admit remembered mutes before enabling any live monitor.
      for (final entry in _monitorMute.entries) {
        final muteResult = _engine.setMonitorInputMute(
          input: entry.key,
          muted: entry.value,
        );
        if (!muteResult.isOk) {
          stopEngine();
          return muteResult;
        }
      }
      _monitorInputMode.forEach((input, _) {
        final resolved = monitorResolved(input);
        _monitorResolvedPushed[input] = resolved;
        _engine.setMonitorInputEnabled(input: input, enabled: resolved);
      });
      _monitorOutput.forEach(
        (input, mask) =>
            _engine.setMonitorInputOutput(input: input, mask: mask),
      );

      for (final input in <int>{
        ..._monitorEffects.keys,
        ..._monitorChainEnabled.keys,
      }) {
        final fxResult = _applyMonitorEffects(input);
        if (!fxResult.isOk) {
          stopEngine();
          return fxResult;
        }
      }
      // Re-apply per-input conditioning (the engine resets it on configure):
      // stage each input's parameters first, then its enable flag, so the final
      // enable establishes the stage with its parameters already in place.
      _condParams.forEach((input, params) {
        params.forEach(
          (param, value) => _engine.setInputConditioningParam(
            input: input,
            param: param,
            value: value,
          ),
        );
      });
      _condEnabled.forEach(
        (input, enabled) =>
            _engine.setInputConditioningEnabled(input: input, enabled: enabled),
      );
      // Each target receives one complete recipe, including its power flag.
      for (final channel in <int>{
        ..._trackEffects.keys,
        ..._trackChainEnabled.keys,
      }) {
        final fxResult = _applyTrackEffects(channel);
        if (!fxResult.isOk) {
          stopEngine();
          return fxResult;
        }
      }
      for (final bus in <int>{
        ..._outputEffects.keys,
        ..._outputChainEnabled.keys,
      }) {
        final fxResult = _applyOutputEffects(bus);
        if (!fxResult.isOk) {
          stopEngine();
          return fxResult;
        }
      }
      if (_allTracksEffects.isNotEmpty || !_allTracksChainEnabled) {
        final fxResult = _applyAllTracksEffects();
        if (!fxResult.isOk) {
          stopEngine();
          return fxResult;
        }
      }
      // Re-apply the structural output gate. A fresh start enables every
      // output, so only the stored OFF entries need re-asserting (default-on).
      _outputEnabled.forEach(
        (output, enabled) =>
            _engine.setOutputEnabled(output: output, enabled: enabled),
      );
      // Restored plugins load by id through the native scan cache, which is
      // empty on a cold start — so the apply above leaves them unavailable.
      // Most chains are restored AFTER this call (by the cubits, through
      // setLaneEffects/setMonitorEffects), so the same recovery also fires from
      // there; this call covers a mid-session reconnect where the chains are
      // already present.
      _recoverUnavailablePlugins();
      // A raw reconnect did not pass through stopEngine's quiescent lane
      // notices. Register each folded Clear with the settings owner now,
      // after its dry replay was admitted under this new engine lifetime.
      for (final key in foldedHistory) {
        onLaneChainChanged?.call(key.$1, key.$2);
      }
      _hasOpenedEngine = true;
      if (replayedPriorEngine) {
        unawaited(_announceFxReplayAfterConfirmation());
      }
    }
    return EngineResult.ok;
  }

  Future<void> _announceFxReplayAfterConfirmation() async {
    final generation = _mixGeneration;
    final sessionRevision = _sessionRevision;
    final settled = await settleFxRecipes(
      waitForCallback: true,
      cancelled: () => _fxReplayConfirmed.isClosed,
    );
    if (!settled.isOk ||
        generation != _mixGeneration ||
        sessionRevision != _sessionRevision ||
        _fxReplayConfirmed.isClosed) {
      return;
    }
    _fxReplayConfirmed.add((
      mixGeneration: generation,
      sessionRevision: sessionRevision,
    ));
  }

  /// Whether [effects] holds a hosted plugin that failed to load (its id was
  /// not in the scan cache when the chain was applied).
  static bool _hasUnavailablePlugin(Iterable<TrackEffect> effects) =>
      effects.any((e) => e is PluginEffect && e.unavailable);

  /// Recovers plugins that failed to load because the engine's in-process scan
  /// cache was empty when their chain was applied.
  ///
  /// On a cold start nothing has scanned yet, and the saved chains are restored
  /// (by the cubits, through [setLaneEffects]/[setMonitorEffects]) *after*
  /// [startEngine] — so a one-shot scan at start would run before any chain
  /// exists and miss them, leaving the entries stuck as unavailable
  /// placeholders until the user relinks by hand. Instead, whenever an applied
  /// chain surfaces an unavailable plugin, kick a single catalog scan and
  /// re-apply the affected chains once it lands, so the plugins load (resolving
  /// their display names too) on their own.
  ///
  /// While that recovery scan is in flight the affected entries are flipped to
  /// the transient "loading…" state (F5), so the UI shows a spinner rather than
  /// a scary "unavailable + relink" during the brief auto-recovery window; the
  /// re-apply then resolves them, or restores genuine unavailability if the
  /// plugin is still missing. A no-op when nothing is unavailable.
  void _recoverUnavailablePlugins() {
    final laneKeys = [
      for (final e in _laneEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    final monitorKeys = [
      for (final e in _monitorEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    final trackKeys = [
      for (final e in _trackEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    final outputKeys = [
      for (final e in _outputEffects.entries)
        if (_hasUnavailablePlugin(e.value)) e.key,
    ];
    final allTracks = _hasUnavailablePlugin(_allTracksEffects);
    if (laneKeys.isEmpty &&
        monitorKeys.isEmpty &&
        trackKeys.isEmpty &&
        outputKeys.isEmpty &&
        !allTracks) {
      return;
    }
    // A completed scan is authoritative even when it found zero plugins.
    // Otherwise an unrelated bus edit re-enters this path and turns a settled
    // missing-plugin placeholder back into a permanent loading spinner.
    if (pluginCatalog.descriptors.isNotEmpty ||
        (_restoredPluginScan != null && !pluginCatalog.isScanning)) {
      return;
    }
    _markUnavailablePluginsLoading(laneKeys, monitorKeys);
    // Bus plugins are intentionally unsupported, even if the catalog later
    // finds them. Keep that visible placeholder while scanning their names;
    // only lane/monitor plugins may transition through a loading host state.
    final generation = _mixGeneration;
    final sessionRevision = _sessionRevision;
    final scan = _restoredPluginScan ??= pluginCatalog.scan();
    unawaited(
      scan.then((_) async {
        if (!_intendRunning ||
            generation != _mixGeneration ||
            sessionRevision != _sessionRevision) {
          return;
        }
        final settled = await settleFxRecipes(
          waitForCallback: true,
          cancelled: () =>
              !_intendRunning ||
              generation != _mixGeneration ||
              sessionRevision != _sessionRevision,
        );
        if (!settled.isOk ||
            !_intendRunning ||
            generation != _mixGeneration ||
            sessionRevision != _sessionRevision) {
          return;
        }
        for (final key in laneKeys) {
          _applyLaneEffects(key.$1, key.$2);
        }
        monitorKeys.forEach(_applyMonitorEffects);
        trackKeys.forEach(_applyTrackEffects);
        outputKeys.forEach(_applyOutputEffects);
        if (allTracks) _applyAllTracksEffects();
      }),
    );
  }

  /// Flips the unavailable plugin entries of the given lane / monitor chains to
  /// the transient loading state (F5) while [_recoverUnavailablePlugins]'s scan
  /// runs. Lane chains re-project so the UI updates; monitor chains update the
  /// cache (the MonitorCubit re-reads it), mirroring how the scan-landed
  /// re-apply reaches each.
  void _markUnavailablePluginsLoading(
    List<(int, int)> laneKeys,
    List<int> monitorKeys,
  ) {
    PluginEffect toLoading(PluginEffect fx) =>
        fx.copyWith(loading: true, unavailable: false, unsupported: false);
    for (final key in laneKeys) {
      final effects = _laneEffects[key];
      if (effects == null) continue;
      _laneEffects[key] = [
        for (final fx in effects)
          if (fx is PluginEffect && fx.unavailable) toLoading(fx) else fx,
      ];
    }
    for (final input in monitorKeys) {
      final effects = _monitorEffects[input];
      if (effects == null) continue;
      _monitorEffects[input] = [
        for (final fx in effects)
          if (fx is PluginEffect && fx.unavailable) toLoading(fx) else fx,
      ];
    }
    if (laneKeys.isNotEmpty) _reproject();
  }

  /// Closes the audio device. A deliberate stop also cancels any in-flight
  /// reconnect supervision so the engine is not reopened behind the user.
  EngineResult stopEngine() {
    // Quiesce the callback before reconciling the final published take image.
    final result = _engine.stop();
    _retireEngineLifetime();
    final folded = _foldHistoryFxAtQuiescence();
    if (_intendRunning) {
      final snapshot = _engine.snapshot();
      if (snapshot.tempoBpm > 0) {
        _tempoBpm = snapshot.tempoBpm;
        _tempoSource = snapshot.tempoSource;
      }
    }
    _intendRunning = false;
    _clickVolume.retireLive();
    _stopReconnectPolling();
    // The engine tears down all plugin slots on stop; drop our stale handles so
    // a later param set doesn't address a freed slot.
    _laneSlots.clear();
    _monitorSlots.clear();
    _fxSlots.clear();
    _fxPending.clear();
    for (final key in folded) {
      onLaneChainChanged?.call(key.$1, key.$2);
    }
    return result;
  }

  /// Detects a cable-free loopback capture path for auto-measuring latency.
  LoopbackInfo detectLoopback() =>
      loopbackInfoFromEngine(_engine.detectLoopback());

  /// Triggers a loopback round-trip latency measurement.
  EngineResult measureLatency() => _engine.measureLatency();

  /// Advances track [channel]: record / finalize loop / toggle overdub.
  ///
  /// When the track is leaving EMPTY (a fresh capture), the input's live
  /// monitor chain is snapshot-copied onto each recording lane and pushed to
  /// the engine, so the take's remembered FX matches what was monitored. The
  /// repository is the sole record-time snapshot authority: it computes the
  /// snapshot from the synchronously-correct `_monitorEffects` cache (never
  /// from ring-deferred engine state), so there is no drain-timing race. The
  /// copy is by value, so editing the input chain afterwards never alters the
  /// take (D3).
  ///
  /// A punch-in the engine refuses because the track plays reversed
  /// ([EngineResult.reversed]) is also reported on [overdubRefusals].
  EngineResult record({int channel = 0}) {
    final result = _record(channel);
    if (result == EngineResult.reversed && !_overdubRefusals.isClosed) {
      _overdubRefusals.add(channel);
    }
    return result;
  }

  EngineResult _record(int channel) {
    if (_sessionAudioReserved) {
      return EngineResult.notReady;
    }
    final snapshot = _engine.snapshot();
    final state = channel >= 0 && channel < snapshot.tracks.length
        ? snapshot.tracks[channel].state
        : null;
    if (channel < 0 || channel >= snapshot.tracks.length) {
      return EngineResult.invalid;
    }
    // The owed retry of a refused fresh capture must never become anything
    // else: a take that started since (the player's own second press) would
    // be finished by the plain record below, and a Count-in it started would
    // be cancelled by the branch after. Superseded, quietly.
    if (_retryingRecord &&
        (state != TrackState.empty ||
            snapshot.tracks[channel].pendingLaunch != null ||
            snapshot.tracks[channel].countInCancelGrace)) {
      _retrySuperseded = true;
      return EngineResult.invalid;
    }
    // The callback rechecks this cancellation-only intent, so an expired
    // grace window cannot turn the press into a new capture.
    if (snapshot.tracks[channel].pendingLaunch != null ||
        snapshot.tracks[channel].countInCancelGrace) {
      return _engine.cancelArm(channel: channel);
    }
    if (snapshot.tracks[channel].pending ||
        (state != TrackState.empty &&
            state != TrackState.playing &&
            state != TrackState.stopped)) {
      return _engine.record(channel: channel);
    }
    // Fresh acquisition must not capture or prepare plugin state while timing
    // admission is fenced. Owned cancellation and finishing remain available.
    if (!recordTimingSettingsSettled ||
        recordTimingRecoveryRequired ||
        !recordStartSettingsSettled ||
        recordStartRecoveryRequired) {
      return EngineResult.notReady;
    }
    // A take records through the mix's routes: wait for them, and refuse
    // while they are owed.
    if (!_mix.settled || _mix.recoveryRequired) {
      return _mixFailure(EngineResult.notReady);
    }
    if (_recordStart.live.soundStart && state == TrackState.empty) {
      if (!_engine.commandsSettled) return EngineResult.notReady;
      final applied = _engine.snapshot();
      final usable = applied.tracks[channel].lanes.any(
        (lane) =>
            lane.inputChannel >= 0 &&
            lane.inputChannel < applied.inputChannels &&
            (applied.excludedInputMask & (1 << lane.inputChannel)) == 0,
      );
      if (!usable) {
        _recordingInputRequired.add(channel);
        return EngineResult.invalid;
      }
    }
    if (_historyFx.keys.any((key) => key.$1 == channel) ||
        _restoreFxStaged.contains(channel)) {
      return EngineResult.notReady;
    }
    // A pending monitor recipe is safe: the remembered monitor chain is the
    // synchronous record snapshot. Only a lane recipe for this track competes
    // with the image that the arm will publish on that same native target.
    for (var lane = 0; lane < laneCount(channel); lane++) {
      final key = (FxOwner.lane, channel, lane);
      final pending = _fxPending[key];
      if (pending == null) continue;
      if (_engine.fxRecipeRevision(
            owner: FxOwner.lane,
            channel: channel,
            lane: lane,
          ) !=
          pending) {
        return EngineResult.notReady;
      }
      _fxPending.remove(key);
    }
    final images = <(int, int), double>{};
    final balances = <(int, int), double>{};
    final source = <int, StereoMix>{};
    for (var lane = 0; lane < laneCount(channel); lane++) {
      final key = (channel, lane);
      if (state != TrackState.empty && _laneBasePan.containsKey(key)) continue;
      final input = _laneInput[key] ?? lane;
      images[key] = _inputSetup.effectivePanOf(input);
      balances[key] = _inputSetup.balanceGainOf(input);
      source[lane] = (gain: balances[key]!, pan: images[key]!);
    }
    if (_pendingImages.containsKey(channel)) return EngineResult.notReady;
    final recipes = <int, FxRecipe>{};
    final inherited = <int, List<TrackEffect>>{};
    final inheritedInputs = <int, int>{};
    final inheritedHandles = <int, Map<String, PluginSlotHandle>>{};
    final detached = <PluginSlotHandle>[];
    EngineResult? preparationFailure;
    if (state == TrackState.empty) {
      try {
        for (var lane = 0; lane < laneCount(channel); lane++) {
          final chain = _inheritableChain(channel, lane);
          if (chain == null) continue;
          final input = _laneInput[(channel, lane)] ?? lane;
          final captured = <TrackEffect>[];
          for (var index = 0; index < chain.length; index++) {
            final fx = _capturePluginForLane(chain[index], input, index);
            if (fx != null) captured.add(fx);
          }
          final copied = withFreshSlotIds(captured);
          final slots = <FxRecipeSlot>[];
          final handles = <String, PluginSlotHandle>{};
          final loaded = <TrackEffect>[];
          for (final fx in copied) {
            if (fx is BuiltInEffect) {
              loaded.add(fx);
              slots.add(
                FxRecipeSlot(
                  type: trackEffectTypeToEngine(fx.type),
                  params: fx.params,
                  enabled: fx.enabled,
                  channels: fxChannelsToEngine(fx.channels),
                ),
              );
            } else {
              final plugin = fx as PluginEffect;
              if (plugin.unavailable || plugin.unsupported || plugin.loading) {
                // Recall may already know this input plugin is missing. Its
                // live path is dry; copy that explicit placeholder by value
                // so a valid take and the surrounding built-ins still land.
                loaded.add(
                  plugin.loading
                      ? plugin.copyWith(loading: false, unavailable: true)
                      : plugin,
                );
                slots.add(
                  FxRecipeSlot(
                    type: trackEffectTypeToEngine(TrackEffectType.none),
                  ),
                );
                continue;
              }
              final handle = _engine.preparePlugin(pluginId: plugin.ref.id);
              if (handle == null) {
                throw const _FxPreparationRefused(EngineResult.invalid);
              }
              detached.add(handle);
              final bound = _bindPluginSlot(handle, plugin, prepared: true);
              loaded.add(bound);
              handles[plugin.slotId!] = handle;
              slots.add(
                FxRecipeSlot(
                  type: trackEffectTypeToEngine(TrackEffectType.none),
                  plugin: handle,
                  enabled: plugin.enabled,
                  channels: fxChannelsToEngine(plugin.channels),
                ),
              );
            }
          }
          inherited[lane] = loaded;
          inheritedInputs[lane] = input;
          inheritedHandles[lane] = handles;
          recipes[lane] = FxRecipe(
            slots: slots,
            preCount: fxPreCount(loaded),
          );
        }
      } on _FxPreparationRefused catch (failure) {
        preparationFailure = failure.result;
      }
    }
    if (preparationFailure != null) {
      detached.forEach(_engine.discardPreparedPlugin);
      return preparationFailure;
    }
    _imageRevision = (_imageRevision + 1) & 0xffffffff;
    if (_imageRevision == 0) _imageRevision = 1;
    final result = _engine.recordWithImage(
      RecordImage(revision: _imageRevision, lanes: source, laneFx: recipes),
      channel: channel,
    );
    if (result.isOk) {
      _pendingImages[channel] = _PendingImage(
        _imageRevision,
        images,
        balances,
        {
          for (var lane = 0; lane < laneCount(channel); lane++)
            _laneInput[(channel, lane)] ?? lane,
        },
        inherited,
        inheritedInputs,
        inheritedHandles,
        clearOnCommit: state == TrackState.empty,
      );
      _reproject();
    } else {
      detached.forEach(_engine.discardPreparedPlugin);
      // The engine's own fresh-capture refusal (#1146): the callback may
      // still hold this track's buffers for one block. Owed one retry.
      if (result == EngineResult.notReady &&
          state == TrackState.empty &&
          !_retryingRecord) {
        _recordRetry = _RecordRetry(channel);
      }
    }
    return result;
  }

  /// Drops the remembered per-lane mutes for [channel] — used when the engine
  /// itself force-unmutes (clear, record-from-empty, redo-from-empty), so the
  /// restart replay can't resurrect a stale mute over an audible track.
  void _forgetLaneMutes(int channel, {bool notify = true}) {
    final mutedLanes = [
      for (final entry in _laneMute.entries)
        if (entry.key.$1 == channel && entry.value) entry.key.$2,
    ];
    _laneMute.removeWhere((key, _) => key.$1 == channel);
    if (notify) {
      for (final lane in mutedLanes) {
        onLaneChainChanged?.call(channel, lane);
      }
    }
  }

  /// Copies lane [lane] of track [channel]'s routed input chain onto the lane
  /// by value, with a fresh provenance stamp — the one inheritance mechanism,
  /// used by part 4's explicit re-sync ([resyncLaneChainFromInput]). Returns
  /// whether the lane's chain was replaced; both dry input shapes bail (see
  /// [laneCanInheritFromInput]) and leave the lane untouched.
  bool _inheritMonitorChainOntoLane(int channel, int lane) {
    final input = _laneInput[(channel, lane)] ?? lane;
    final chain = _inheritableChain(channel, lane);
    if (chain == null) return false;
    // D-P1: a plugin in the monitor chain can't be value-copied — capture
    // its live opaque state so the lane re-instantiates a frozen instance
    // from that exact state on playback. The recorded audio is dry either
    // way, so a capture failure just drops the entry (bypassed) without
    // affecting the take.
    final captured = <TrackEffect>[];
    for (var i = 0; i < chain.length; i++) {
      final fx = _capturePluginForLane(chain[i], input, i);
      if (fx != null) captured.add(fx);
    }
    // The take's entries are new identities (A9): fresh slot ids, never the
    // input chain's.
    final snapshot = withFreshSlotIds(captured);
    final result = setLaneEffects(
      channel: channel,
      lane: lane,
      effects: snapshot,
      chainEnabled: true,
    );
    if (!result.isOk) return false;
    setLaneChainMeta(
      channel: channel,
      lane: lane,
      inheritedFrom: snapshot.isEmpty ? const [] : [input],
    );
    // The take's chain just changed under the repository's own hand — notify
    // so the bloc persists it (F3: without this, a restart replays the
    // pre-take chain from settings).
    onLaneChainChanged?.call(channel, lane);
    return true;
  }

  /// Lane [lane] of track [channel]'s routed input chain when there is
  /// something to inherit, else null — the ONE place the "is there anything to
  /// copy" rule lives, so the predicate and the copy can never disagree.
  ///
  /// Null covers every non-inheritable shape: no such input, and the two dry
  /// ones the record-time snapshot bails on (an empty chain, and a
  /// chain-DISABLED one — D2/D-CHAINDIS, R18).
  List<TrackEffect>? _inheritableChain(int channel, int lane) {
    final input = _laneInput[(channel, lane)] ?? lane;
    if (input < 0 || input >= kMaxMonitoredInputs) return null;
    final chain = _monitorEffects[input];
    if (chain == null || chain.isEmpty) return null;
    return monitorChainEnabled(input) ? chain : null;
  }

  /// Whether lane [lane] of track [channel] has an inheritable routed input
  /// chain (see [_inheritableChain]). Gates part 4's re-sync action so it is
  /// never offered when it would do nothing.
  bool laneCanInheritFromInput(int channel, int lane) =>
      _inheritableChain(channel, lane) != null;

  /// Re-copies lane [lane] of track [channel]'s routed input chain onto the
  /// lane by value with a fresh provenance stamp (A6/R13) — part 4's explicit,
  /// user-initiated re-sync. Never automatic: an overdub never re-inherits
  /// (A7), and nothing here propagates to any other take. Returns whether the
  /// chain was replaced (`false` when there is nothing inheritable — see
  /// [laneCanInheritFromInput]).
  bool resyncLaneChainFromInput({required int channel, required int lane}) =>
      _inheritMonitorChainOntoLane(channel, lane);

  /// Snapshots one monitor chain entry onto a recording lane. Built-in effects
  /// copy by value; a plugin captures its live state blob from monitor slot
  /// `(input, index)`. Returns null when a plugin's capture fails (the entry is
  /// dropped → bypassed on playback; the dry take is unaffected).
  TrackEffect? _capturePluginForLane(TrackEffect fx, int input, int index) {
    if (fx is! PluginEffect) return fx;
    final handle = _monitorSlots[(input, index)];
    // Not loaded (engine settling): keep the entry + any prior persisted state.
    if (handle == null) return fx;
    final blob = _engine.pluginStateGet(handle);
    // Loaded but capture failed: drop the entry so the lane plays dry for it
    // (bypass). The recorded buffer is dry regardless, so the take is unharmed.
    if (blob.isEmpty) return null;
    return fx.copyWith(state: base64Encode(blob));
  }

  /// Halts track [channel]'s playback (retaining the buffer).
  EngineResult stopTrack({int channel = 0}) =>
      _engine.stopTrack(channel: channel);

  /// Resumes playback of track [channel].
  EngineResult play({int channel = 0}) {
    if (_sessionAudioReserved) return EngineResult.notReady;
    final tracks = _engine.snapshot().tracks;
    if (channel >= 0 &&
        channel < tracks.length &&
        (tracks[channel].pendingLaunch != null ||
            tracks[channel].countInCancelGrace)) {
      return _engine.cancelArm(channel: channel);
    }
    // Play waits for an admitted pair; an owed pair never blocks playback.
    return !recordStartSettingsSettled
        ? EngineResult.notReady
        : _engine.play(channel: channel);
  }

  /// Erases track [channel] (resets the master if all tracks empty), leaving a
  /// restore point: [undo] puts the take back, chains and mutes included.
  ///
  /// The take's FX chains are dropped (cache + engine): a cleared track is
  /// empty, so a subsequent record-from-empty through a *dry* monitor must land
  /// a dry take — not inherit the erased take's chain (the "leftover from a
  /// previous config" bug). They are snapshotted first, so undoing the
  /// clear can put them back. It does NOT touch routing (`_laneInput` /
  /// `_laneOutput` /
  /// `_laneVolume`), which is the track's config, not the take.
  ///
  /// This is the USER's clear. [applySession] uses [_clearDestructive]
  /// instead — loading a session must never be undoable.
  EngineResult clear({int channel = 0}) {
    if (_sessionAudioReserved) return EngineResult.notReady;
    final result = _clearTrack(channel);
    if (result.isOk) {
      // A refused native clear leaves the prior restore/group ownership.
      _clearAllGroup = const {};
      _clearAllPending = const {};
      _pendingClearAllUndo = const {};
    }
    return result;
  }

  EngineResult _clearTrack(int channel) {
    final result = _engine.clearUndoable(channel: channel);
    if (!result.isOk) return result;
    _pendingClearUndo.remove(channel);
    _restoreFxStaged.remove(channel);
    _snapshotForClearRestore(channel);
    _dropTakeState(channel);
    // A capture the clear froze comes back audible (a capturing track is
    // never observed muted, and the engine files its point with every lane
    // unmuted): remember it that way, or a restart would replay a mute the
    // engine never restored.
    if (result.isOk && _engine.clearRestorePending(channel: channel)) {
      final snapshot = _clearRestore[channel];
      if (snapshot != null) {
        _clearRestore[channel] = {
          for (final entry in snapshot.entries)
            entry.key: (
              effects: entry.value.effects,
              chainEnabled: entry.value.chainEnabled,
              inheritedFrom: entry.value.inheritedFrom,
              muted: false,
            ),
        };
      }
    }
    return result;
  }

  /// Clears every track in [channels] as ONE grouped edit (accepted design,
  /// slice 2): the next [undo] on any of them restores the whole group —
  /// each take's content, layers, length and previous playing or stopped
  /// state — and the next [redo] after that re-clears the group. A track
  /// caught capturing is frozen stopped at the clear and comes back stopped,
  /// never as a resumed capture; a cancelled arm stays idle.
  ///
  /// The group holds only while every member still offers its restore point:
  /// a fresh take on a member retires that member's point (the engine's
  /// rule), and the group with it — the per-track history then answers as
  /// usual, and nothing newer is overwritten.
  EngineResult clearAll(Iterable<int> channels) {
    if (_sessionAudioReserved) return EngineResult.notReady;
    _pendingClearAllUndo = const {};
    final group = <int>{};
    final pending = <int>{};
    var result = EngineResult.ok;
    for (final channel in channels) {
      final rc = _clearTrack(channel);
      if (!rc.isOk) {
        result = rc;
        continue;
      }
      // Members are the takes the clear can give back, by the engine's own
      // account: a restore point filed now (a playing or stopped take), or
      // one still to be filed (a capture the clear froze — confirmed once
      // its report lands, dropped if the capture had nothing). A redo-only
      // track is erased but has no restore point, so it is not what the
      // group's undo restores.
      if (_engine.undoRestoresClear(channel: channel)) {
        group.add(channel);
      } else if (_engine.clearRestorePending(channel: channel)) {
        pending.add(channel);
      }
    }
    _clearAllGroup = group;
    _clearAllPending = pending;
    _clearAllRedoGroup = const {};
    return result;
  }

  /// The channels the last [clearAll] erased with a restore point.
  Set<int> _clearAllGroup = const {};

  /// Frozen captures of the last [clearAll] whose restore point is still to
  /// be filed: promoted to [_clearAllGroup] when it lands, dropped when the
  /// capture turned out to hold nothing.
  Set<int> _clearAllPending = const {};

  /// The channels an undone [clearAll] restored.
  Set<int> _clearAllRedoGroup = const {};

  /// A grouped undo waits for every frozen point before changing any member.
  Set<int> _pendingClearAllUndo = const {};

  /// Tracks whose undo waits for the clear's frozen restore point to land:
  /// tapped at a frozen clear, restored on the first poll after the engine
  /// files the point, forgotten when the capture held nothing (or a fresh
  /// take retired the point first).
  final Set<int> _pendingClearUndo = {};

  /// Settles the deferred taps whose point has landed or never will: the
  /// take comes back (audio from the engine, chains from the snapshot), or
  /// nothing does and the snapshot is dropped so an empty track carries no
  /// leftover chain (the rule [_dropTakeState] enforces at the clear).
  void _settlePendingClearUndos() {
    _drainHistoryFx();
    if (_pendingClearAllUndo.isNotEmpty &&
        !_pendingClearAllUndo.any(
          (channel) => _engine.clearRestorePending(channel: channel),
        )) {
      final requested = _pendingClearAllUndo;
      _pendingClearAllUndo = const {};
      final group = _intactClearAllGroup();
      if (group.isNotEmpty && requested.containsAll(group)) {
        _undoClearGroup(group);
      }
    }
    if (_pendingClearUndo.isEmpty) return;
    for (final channel in _pendingClearUndo.toList()) {
      if (_engine.clearRestorePending(channel: channel)) continue;
      _pendingClearUndo.remove(channel);
      if (_engine.undoRestoresClear(channel: channel)) {
        _undoTrack(channel);
      } else {
        _clearRestore.remove(channel);
        _restoreFxStaged.remove(channel);
        // A void member has no re-clear to offer the restored group.
        _clearAllRedoGroup = _clearAllRedoGroup.difference({channel});
      }
    }
  }

  /// The clear-all group while every member still restores a cleared take;
  /// empty while one does not.
  ///
  /// A frozen member whose point is still to be filed counts as a member.
  /// The repository parks the whole group's Undo until every point lands,
  /// then asks the engine to check all recovered lengths before restoring.
  Set<int> _intactClearAllGroup() {
    // Frozen members first: a filed point makes a member; neither pending
    // nor filed means the capture held nothing to give back.
    if (_clearAllPending.isNotEmpty) {
      final group = {..._clearAllGroup};
      final pending = <int>{};
      for (final channel in _clearAllPending) {
        if (_engine.clearRestorePending(channel: channel)) {
          pending.add(channel);
        } else if (_engine.undoRestoresClear(channel: channel)) {
          group.add(channel);
        }
      }
      _clearAllGroup = group;
      _clearAllPending = pending;
    }
    for (final channel in _clearAllGroup) {
      if (_engine.undoRestoresClear(channel: channel)) continue;
      // The engine retired the point (a fresh take): the group is gone, and
      // a later single clear on that track must not re-form it.
      _clearAllGroup = const {};
      _clearAllPending = const {};
      return const {};
    }
    return {..._clearAllGroup, ..._clearAllPending};
  }

  /// Whole-rig recovery from a clear-all: the intact group comes back as one
  /// operation; otherwise every track that still holds a clear restore point
  /// is restored on its own (a group the engine partly retired).
  EngineResult undoClearAll() {
    if (_sessionAudioReserved) return EngineResult.notReady;
    _settlePendingClearUndos();
    final group = _intactClearAllGroup();
    if (group.isNotEmpty) return undo(channel: group.first);
    var result = EngineResult.ok;
    for (final track in lastState.tracks) {
      if (!track.clearRestore) continue;
      final rc = undo(channel: track.channel);
      if (!rc.isOk) result = rc;
    }
    return result;
  }

  /// The destructive clear: same erasure, no way back. Session load only.
  EngineResult _clearDestructive({int channel = 0}) {
    final result = _engine.clear(channel: channel);
    if (!result.isOk) return result;
    _pendingClearAllUndo = const {};
    _pendingClearUndo.remove(channel);
    _clearRestore.remove(channel);
    _restoreFxStaged.remove(channel);
    _historyFx.removeWhere((key, _) => key.$1 == channel);
    _forgetLaneMutes(channel, notify: false);
    // Session apply sends exactly one final recipe per target after this clear.
    _laneEffects.removeWhere((key, _) => key.$1 == channel);
    _laneChainEnabled.removeWhere((key, _) => key.$1 == channel);
    _laneChainMeta.removeWhere((key, _) => key.$1 == channel);
    return result;
  }

  /// The erasure both clears share: forget the remembered mutes (the engine
  /// force-unmutes every lane) and empty the take's chains in cache + engine,
  /// persisting each (F3 — without this, settings keeps the erased take's chain
  /// and a restart replays it onto the fresh take). The chain flag resets to
  /// the enabled default and the inheritance meta is dropped alongside — a
  /// cleared lane is dry with no history; [undo]'s restore puts both back from
  /// the [_clearRestore] snapshot.
  void _dropTakeState(int channel) {
    _forgetLaneMutes(channel);
    final clearedLanes = {
      for (final key in _laneEffects.keys)
        if (key.$1 == channel) key.$2,
      for (final key in _laneChainEnabled.keys)
        if (key.$1 == channel) key.$2,
      for (final key in _historyFx.keys)
        if (key.$1 == channel) key.$2,
    };
    for (final lane in clearedLanes) {
      _requestHistoryFx(
        channel,
        lane,
        effects: const [],
        enabled: true,
        inheritedFrom: const [],
        restoring: false,
      );
    }
  }

  /// Captures what a clear on [channel] is about to throw away and the engine
  /// cannot give back: the take's per-lane FX chains and mutes. Keyed by
  /// channel, replaced by the next clear on the same track.
  ///
  /// Deliberately NOT invalidated here when the engine retires its restore
  /// point (a fresh recording does, two different ways). Mirroring those rules
  /// in Dart would be a second copy of the engine's bookkeeping, drifting on
  /// its own; a
  /// stale entry is inert instead, because it is only ever applied when
  /// [AudioEngine.undoRestoresClear] says a restore actually happened.
  void _snapshotForClearRestore(int channel) {
    // Include mute-only lanes: an empty enabled chain still has remembered
    // mute intent that must round-trip through Clear and Undo.
    final lanes = {
      for (final key in _laneEffects.keys)
        if (key.$1 == channel) key.$2,
      for (final key in _laneChainEnabled.keys)
        if (key.$1 == channel) key.$2,
      for (final key in _laneMute.keys)
        if (key.$1 == channel) key.$2,
    };
    _clearRestore[channel] = {
      for (final lane in lanes)
        lane: (
          effects: List<TrackEffect>.of(
            _laneEffects[(channel, lane)] ?? const [],
          ),
          // R15: disable a chain → clear → restore must come back disabled,
          // so the chain flag (and the inheritance marker) ride the snapshot
          // beside the chain itself.
          chainEnabled: laneChainEnabled(channel, lane),
          inheritedFrom: _laneChainMeta[(channel, lane)] ?? const [],
          muted: _laneMute[(channel, lane)] ?? false,
        ),
    };
  }

  /// Removes the most recent overdub layer on track [channel] — or, on a track
  /// the user cleared, restores the take.
  ///
  /// The engine puts the audio, transport and mutes back; the chains are the
  /// repository's to restore, since the engine is a pure sink that holds only
  /// what this class pushes. Asked BEFORE the undo: the engine's answer
  /// describes the next tap, and the snapshot it derives from does not flip
  /// until the audio thread applies the restore.
  EngineResult undo({int channel = 0}) {
    if (_sessionAudioReserved) {
      return EngineResult.notReady;
    }
    _settlePendingClearUndos();
    // A grouped clear comes back as one operation, whichever member is asked.
    final group = _intactClearAllGroup();
    if (group.contains(channel)) return _undoClearGroup(group);
    return _undoTrack(channel);
  }

  EngineResult _undoClearGroup(Set<int> group) {
    if (group.any((channel) => _engine.clearRestorePending(channel: channel))) {
      _pendingClearAllUndo = group;
      return EngineResult.ok;
    }
    final ordered = group.toList()
      ..sort()
      ..forEach(_stageClearUndoFx);
    if (ordered.any((member) => !_clearUndoFxReady(member))) {
      _pendingClearAllUndo = group;
      return EngineResult.ok;
    }
    final gate = _historyModeGate(ordered, redo: false);
    if (!gate.isOk) {
      ordered.forEach(_cancelStagedClearUndoFx);
      return gate;
    }
    for (final member in ordered) {
      final result = _undoTrack(member);
      if (!result.isOk) return result;
    }
    _clearAllRedoGroup = group;
    _clearAllGroup = const {};
    _clearAllPending = const {};
    return EngineResult.ok;
  }

  /// One track's undo. A tap at a frozen clear (its point still to be filed)
  /// is held here rather than handed to the engine, and taken on the first
  /// poll after the point lands ([_settlePendingClearUndos]) so the chains
  /// come back with the take; a capture that held nothing is then forgotten
  /// instead of being restored onto an empty track.
  EngineResult _undoTrack(int channel) {
    if (_engine.clearRestorePending(channel: channel)) {
      _pendingClearUndo.add(channel);
      return EngineResult.ok;
    }
    final restoresClear = _engine.undoRestoresClear(channel: channel);
    if (restoresClear) {
      _stageClearUndoFx(channel);
      if (!_clearUndoFxReady(channel)) {
        _pendingClearUndo.add(channel);
        return EngineResult.ok;
      }
    }
    final gate = _historyModeGate([channel], redo: false);
    if (!gate.isOk) {
      if (restoresClear) _cancelStagedClearUndoFx(channel);
      return gate;
    }
    final result = _reportRecoveryResult(
      _engine.undo(channel: channel),
      redo: false,
    );
    if (restoresClear && result == EngineResult.ok) {
      _restoreClearedTake(channel);
    } else if (restoresClear) {
      _cancelStagedClearUndoFx(channel);
    }
    return result;
  }

  /// Puts a restored take's chains and mutes back (cache + engine), persisting
  /// each chain so a restart replays the restored take rather than the emptied
  /// one the clear wrote.
  void _restoreClearedTake(int channel) {
    final snapshot = _clearRestore.remove(channel);
    _restoreFxStaged.remove(channel);
    if (snapshot == null) return;
    for (final entry in snapshot.entries) {
      // The complete restored recipe, including its power flag and
      // provenance, was acknowledged before the audio Undo was admitted.
      onLaneChainChanged?.call(channel, entry.key);
      // The engine restored the lane mutes from its own record; remember them
      // to match, or the restart replay would resurrect the clear's
      // force-unmute.
      _laneMute[(channel, entry.key)] = entry.value.muted;
    }
  }

  /// Re-applies the most recently undone overdub layer on track [channel].
  /// A redo that resurrects an undone-to-empty track comes back unmuted
  /// engine-side; the remembered mutes are forgotten to match.
  EngineResult redo({int channel = 0}) {
    if (_sessionAudioReserved) {
      return EngineResult.notReady;
    }
    // Cancel a grouped undo before settling it: every member is still clear.
    if (_pendingClearAllUndo.contains(channel)) {
      _pendingClearAllUndo.forEach(_cancelStagedClearUndoFx);
      _pendingClearAllUndo = const {};
      return EngineResult.ok;
    }
    if (_pendingClearUndo.remove(channel)) {
      _cancelStagedClearUndoFx(channel);
      return EngineResult.ok;
    }
    _settlePendingClearUndos();
    if (_clearAllRedoGroup.contains(channel)) {
      final group = _clearAllRedoGroup;
      if (group.every((member) => _engine.redoReclears(channel: member))) {
        final ordered = group.toList()..sort();
        final gate = _historyModeGate(ordered, redo: true);
        if (!gate.isOk) return gate;
        for (final member in ordered) {
          final result = _redoTrack(member);
          if (!result.isOk) return result;
        }
        _clearAllRedoGroup = const {};
        _clearAllGroup = group;
        _clearAllPending = const {};
        return EngineResult.ok;
      }
      _clearAllRedoGroup = const {};
    }
    return _redoTrack(channel);
  }

  /// Changes cached take metadata only after the native history edit succeeds.
  EngineResult _redoTrack(int channel) {
    final gate = _historyModeGate([channel], redo: true);
    if (!gate.isOk) return gate;
    final reclears = _engine.redoReclears(channel: channel);
    final snapshot = _engine.snapshot();
    final wasEmpty =
        channel >= 0 &&
        channel < snapshot.tracks.length &&
        snapshot.tracks[channel].state == TrackState.empty;
    final result = _reportRecoveryResult(
      _engine.redo(channel: channel),
      redo: true,
    );
    if (!result.isOk) return result;
    if (reclears) {
      _snapshotForClearRestore(channel);
      _dropTakeState(channel);
    } else if (wasEmpty) {
      _forgetLaneMutes(channel);
    }
    return result;
  }

  /// Removes the newest overdub layer on track [channel] as one history
  /// entry (Peel): the pre-pass image plays, [undo] restores the layer, and
  /// the redo branch is dropped. The original take is never removed.
  ///
  /// The engine's answer is the result: a peel is a synchronous layer swap
  /// that changes no take metadata, so there is no cache work here (unlike a
  /// Clear restore). [EngineResult.notReady] while a Session is being
  /// applied, like [undo]. A member of a grouped Clear All that is peeled
  /// afterwards has a newer edit, which the group logic already excludes.
  EngineResult peel({int channel = 0}) {
    if (_sessionAudioReserved) return EngineResult.notReady;
    return _engine.peel(channel: channel);
  }

  /// Applies a loaded session [rig] to the engine THROUGH this repository —
  /// the ONE session-apply path (F2). Every write lands in the remembered
  /// caches as well as the engine, so a device restart / reconnect replays the
  /// LOADED session by construction, never a pre-load cache.
  ///
  /// **The caller owns writing settings back.** This method updates the engine
  /// and the caches only; it never touches the boot-restore keys. A session
  /// load is therefore not complete until whichever layer owns settings
  /// persistence re-writes them from the enumerations below ([allLaneChains] /
  /// [allTrackChains] / [allOutputChains] / [allMonitors]). Left silent,
  /// that asymmetry shipped twice — a cold boot restored the pre-load rig — so
  /// state it here rather than leaving the caller to discover it.
  ///
  /// Order: clear every track via [clear] (which forgets remembered lane
  /// mutes), await the engine settling to empty, reset every per-track
  /// SETTING that survives a clear by design (length preset, One Shot) plus
  /// the looper mode and crown (B5c) — all pushed from the rig's values or
  /// their defaults before any content is imported — import the stems,
  /// commit the master loop, re-apply mix through the cached setters, then
  /// apply the rig's chains — explicitly resetting every remembered chain of
  /// all FOUR FX stages (input monitor, loop lane, track bus, master insert)
  /// and every chain-enabled flag the rig does not define, so a previous
  /// session's leftovers can never sound (or apply) under the loaded one
  /// (R17). The crowned
  /// primary track is the one exception with an incomplete reset: no native
  /// "un-crown" call exists, so a channel crowned by a live/prior session can
  /// stay crowned on the ENGINE through a load that defines no crown of its
  /// own (the re-apply cache is still correctly reset — see the inline doc
  /// above `_primaryTrack = null`).
  ///
  /// Clears are applied asynchronously on the audio thread;
  /// [clearPollInterval] / [clearPollAttempts] bound how long the settle wait
  /// polls (tests can shrink them). Throws [StateError] when the engine fails
  /// to clear or an import/commit is rejected.
  Future<void> applySession(
    SessionRig rig, {
    Duration clearPollInterval = const Duration(milliseconds: 8),
    int clearPollAttempts = 64,
  }) async {
    if (rig.tracks.isNotEmpty) {
      final snapshot = _engine.snapshot();
      if (!snapshot.isRunning || !snapshot.devicePresent) {
        throw StateError('audio device must be running before session import');
      }
    }
    if (rig.outputChains.keys.any((bus) => bus < 0 || bus >= kMaxOutputBuses)) {
      throw StateError('session output chains cannot be restored');
    }
    final mix = MixSettingsSnapshot.fromRig(rig);
    if (!mix.isValid) throw StateError('session mix cannot be restored');
    if (rig.loopBars < 0 ||
        rig.loopBars > 0x7fffffff ~/ 15 ||
        rig.gridBeats < 0 ||
        rig.gridBeats > 0x7fffffff ~/ 15) {
      throw StateError('session grid cannot be restored');
    }
    if (!rig.tempoBpm.isFinite ||
        (rig.tempoSource == TempoSource.none
            ? rig.tempoBpm != 0
            : rig.tempoSource == TempoSource.external ||
                  rig.tempoBpm < 30 ||
                  rig.tempoBpm > 300)) {
      throw StateError('session tempo cannot be restored');
    }
    if (!rig.inputSetup.isValid ||
        rig.trackPans.entries.any(
          (e) =>
              e.key < 0 ||
              e.key >= 8 ||
              !e.value.isFinite ||
              e.value < -1 ||
              e.value > 1,
        ) ||
        rig.tracks.any(
          (t) =>
              t.channel < 0 ||
              t.channel >= 8 ||
              !t.fadeAmount.isFinite ||
              t.fadeAmount < 0 ||
              t.fadeAmount > 1 ||
              t.lanes.any(
                (l) =>
                    l.lane < 0 ||
                    l.lane >= kMaxLanes ||
                    !l.volume.isFinite ||
                    l.volume < 0 ||
                    l.volume > 2 ||
                    !l.pan.isFinite ||
                    l.pan < -1 ||
                    l.pan > 1 ||
                    !l.balance.isFinite ||
                    l.balance < 0 ||
                    l.balance > 1,
              ),
        ) ||
        rig.monitors.any(
          (m) =>
              m.input < 0 ||
              m.input >= kMaxChannels ||
              !m.volume.isFinite ||
              m.volume < 0 ||
              m.volume > 1,
        )) {
      throw StateError('session mix cannot be restored');
    }
    final restoredMix = _MixIntent(
      pans: rig.trackPans,
      trackLevels: rig.trackLevels,
      solos: const {},
      levels: const {},
      images: const {},
      balances: const {},
      monitorLevels: const {},
      input: rig.inputSetup,
      output: rig.outputSetup.detached(),
      inputs: mix.laneInputs,
      routes: mix.laneOutputs,
      counts: mix.laneCounts,
    );
    final revision = ++_sessionRevision;
    _applyingSessionRevision = revision;
    try {
      await _applySession(
        rig,
        restoredMix,
        revision: revision,
        clearPollInterval: clearPollInterval,
        clearPollAttempts: clearPollAttempts,
      );
    } finally {
      if (_applyingSessionRevision == revision) _applyingSessionRevision = null;
    }
  }

  Future<void> _applySession(
    SessionRig rig,
    _MixIntent restoredMix, {
    required int revision,
    required Duration clearPollInterval,
    required int clearPollAttempts,
  }) async {
    _retireEngineLifetime();
    final generation = _mixGeneration;
    void requireCurrent() {
      if (revision != _sessionRevision ||
          generation != _mixGeneration ||
          _controller.isClosed) {
        throw StateError('session replacement was superseded');
      }
    }

    _length.reset();
    _mix.reset();
    _timing.reset();
    _clickMode.reset();
    _clickVolume.reset();
    _recordStart.reset();
    _oneShot.reset();
    // Own the settings before the first await. Callers may reuse their maps.
    final recordTimingOverrides = Map.of(rig.trackRecordTimingOverrides);
    final overdubDecayOverrides = Map.of(rig.trackOverdubDecayOverrides);
    final oneShotOverrides = Map.of(rig.trackOneShotOverrides);
    final lengthPresetOverrides = Map.of(rig.trackLengthPresetOverrides);
    _requireSessionSetting(
      await settleFxRecipes(
        pollInterval: clearPollInterval,
        attempts: clearPollAttempts,
      ),
    );
    requireCurrent();
    final priorLaneKeys = <(int, int)>{
      ..._laneEffects.keys,
      ..._laneChainEnabled.keys,
    };
    final trackCount = _engine.snapshot().tracks.length;
    for (var channel = 0; channel < trackCount; channel++) {
      // Destructive on purpose: a session load replaces the rig wholesale, so
      // the tracks it wipes must not sit there offering an undo back to the
      // previous session's takes.
      if (!_clearDestructive(channel: channel).isOk) {
        throw StateError('engine refused session clear');
      }
    }
    // The session's per-lane config replaces the remembered one wholesale:
    // purge it all (not just the mutes [clear] forgot) so the restart replay
    // carries only the loaded values, then re-set from the rig below.
    _laneCount.clear();
    _laneInput.clear();
    _laneOutput.clear();
    _laneVolume.clear();
    _trackVolume.clear();
    // The loaded rig may land on the same steady facts as the one it
    // replaces; the shapes are not the same.
    _waveforms.clear();
    _laneMute.clear();
    // Chain-enabled flags + inheritance meta (R15/F2): every remembered lane
    // flag resets to the enabled default — pushed to the engine too (the
    // setter is a direct atomic publish), or a chain the loaded session
    // defines on a previously chain-disabled lane would land silently muted.
    // The rig's own flags are re-applied from its envelopes at the end of
    // this
    // method; the provenance markers drop with the takes they described (and
    // likewise come back from the rig).
    for (final key in _laneChainEnabled.keys.toList()) {
      setLaneChainEnabled(channel: key.$1, lane: key.$2, enabled: true);
    }
    _laneChainMeta.clear();
    // Length presets survive clear; the session replaces their complete
    // default/override choice together with mode before importing content.
    // Same reasoning for One Shot (B4/B5c): `clear` deliberately leaves
    // a_one_shot untouched (it is a per-track SETTING, not content — see
    // `le_engine_set_one_shot`'s doc), so a track this session does not mark
    // One Shot must be explicitly turned off below or a prior session/live
    // flag would bleed into the freshly loaded one.
    _oneShot.adopt(
      _OneShotIntent(const {}, defaultValue: _oneShot.live.defaultValue),
    );
    // Same for the record timing and decay overrides (slice 2b): per-track
    // settings that survive `clear`, reset below and re-armed from the rig.
    _trackOverdubDecay.clear();
    _restartTrackOverdubDecay.clear();
    // The crown dies with the last take: the clear awaited below empties
    // every track, and the engine uncrowns itself on that (its own rule, not
    // a call from here). A crown requested while stopped for a rig that is
    // now being replaced must not land on the new one either.
    _pendingCrown = null;
    if (!await _awaitCleared(clearPollInterval, clearPollAttempts)) {
      throw StateError('engine did not clear before applying the session');
    }
    requireCurrent();

    _importTracks = null;

    // Countermand the live engine's leftover lane count/routing. `clear`
    // above
    // resets a track's audio/state/mutes but NOT its lane_count or per-lane
    // input/output, and the cache purge only fixes the restart replay — so a
    // track this session leaves empty would still RECORD the prior session's
    // lane count/inputs (the record path reads the cache, but the engine
    // records
    // at its own stale lane_count). Reset every track to the fresh configure
    // defaults (lane_count 1; lane 0 records input 0 to the first output
    // pair,
    // matching le_lane_reset) so the engine agrees with the purged caches;
    // the
    // rig restore below re-grows and re-routes the tracks this session
    // defines.
    // Imports grow settled EMPTY tracks; the final canonical mix publishes
    // exact counts after import, without a queued reset racing that growth.
    if (_intendRunning) {
      for (var channel = 0; channel < trackCount; channel++) {
        _engine
          ..setLaneInput(channel: channel, lane: 0, inputChannel: 0)
          ..setLaneOutput(channel: channel, lane: 0, mask: 0x3)
          ..setLaneVolume(1, channel: channel)
          ..setLanePan(pan: 0, channel: channel)
          ..setTrackSolo(channel: channel, solo: false)
          // a_one_shot survives `clear` by design too (see above) — reset
          // every track to off here; the rig loop below re-arms it for any
          // track this session actually marks One Shot.
          ..setOneShot(channel: channel, oneShot: false)
          // The record timing and decay overrides survive `clear` the same
          // way: back to inherit here, re-armed from the rig below.
          ..setTrackOverdubFeedback(channel: channel, feedback: null);
        _requireSessionSetting(
          _engine.setLaneMute(muted: false, channel: channel),
        );
      }
    }

    // Musical settings belong to the session, not the connected interface.
    // Restore them before imported audio establishes the new shared clock.
    _requireSessionSetting(setTimeSignature(rig.tsNum, rig.tsDen));
    _tempoBpm = rig.tempoBpm;
    _tempoSource = rig.tempoSource;
    if (_intendRunning) {
      _requireSessionSetting(
        _engine.restoreTempo(bpm: rig.tempoBpm, source: rig.tempoSource),
      );
    }
    _requireSessionSetting(setSyncTempo(on: rig.syncTempo));
    _requireSessionSetting(
      setRecordTimingSettings(
        defaultTiming: rig.recordTiming,
        rememberedDivision: rig.quantizeDiv,
        trackOverrides: recordTimingOverrides,
      ),
    );
    _requireSessionSetting(await settleRecordTimingSettings());
    requireCurrent();
    _requireSessionSetting(setOverdubDecay(rig.overdubDecay));

    _requireSessionSetting(setDefaultMultiple(multiple: rig.defaultMultiple));
    _requireSessionSetting(setRecDub(enabled: rig.recDub));
    _requireSessionSetting(
      setRecordStartSettings(
        countInBars: rig.countInBars,
        soundStart: rig.autoRecord,
        editKind: RecordStartEditKind.restore,
      ),
    );
    _requireSessionSetting(await settleRecordStartSettings());
    requireCurrent();
    _requireSessionSetting(setClickMode(rig.clickMode));
    _requireSessionSetting(await settleClickMode());
    requireCurrent();
    _requireSessionSetting(setClickOutput(rig.clickMask));
    _requireSessionSetting(setClickVolume(rig.clickVolume));
    _requireSessionSetting(await settleClickVolume());
    requireCurrent();

    // Session-level mode + crown (B5c), applied here — before any content is
    // imported below — so the mode lands on an empty rig with nothing to
    // measure or stop (see [LooperModeControl]'s class doc for the content
    // rules a switch over takes would apply). The mode is always
    // pushed (like [setLooperMode]'s own "no unset sentinel" posture —
    // `multi`
    // IS the default), mirroring how the tempo grid's SETTINGS push
    // unconditionally elsewhere in this method. The crown is NOT gated by
    // content (D18) so its ordering here is only for symmetry; it is pushed
    // only when the rig actually defines one — a rig without a crown gets the
    // engine's own: its lowest recorded track, once the import commits.
    _requireSessionSetting(
      _requestLengthSettings(
        defaultBars: _clampPresetBars(rig.defaultLengthPresetBars),
        overrides: {
          for (final entry in lengthPresetOverrides.entries)
            if (entry.key >= 0 && entry.key < (_intendRunning ? trackCount : 8))
              entry.key: _clampPresetBars(entry.value),
        },
        mode: rig.looperMode,
        changeMode: true,
      ),
    );
    _requireSessionSetting(
      await settleLengthSettings(
        pollInterval: clearPollInterval,
        attempts: clearPollAttempts,
      ),
    );
    requireCurrent();
    // The session's own defaults (slice 2b), before the per-track overrides
    // land with the tracks below: a track whose override is null follows
    // these, so restoring the overrides without them would leave that track
    // on whatever the app was last set to.
    // Bounded to `trackCount` — same bound as the per-track settings below:
    // a manifest saved on a build with more physical tracks than this engine
    // must not push an out-of-range channel, nor hold one as a pending crown
    // this engine can never actually apply.
    if (rig.primaryTrack >= 0 && rig.primaryTrack < trackCount) {
      crownPrimary(channel: rig.primaryTrack);
    }

    await _importSessionAudio(
      rig,
      revision: revision,
      generation: generation,
      interval: clearPollInterval,
      attempts: clearPollAttempts,
    );
    requireCurrent();

    // Restore per-lane routing / mix through the cached setters so the caches
    // stay truthful (and a restart replays them). Lane count first — so an
    // added lane is activated — then per-lane input / output / volume / mute.
    for (final track in rig.tracks) {
      // Activate up to the highest imported lane index — not the lane *count*
      // —
      // so a non-contiguous set (a middle lane dropped on capture/decode)
      // does
      // not deactivate the top lane the imports just filled.
      final laneCount =
          track.lanes.map((l) => l.lane).reduce((a, b) => a > b ? a : b) + 1;
      restoredMix.counts.putIfAbsent(track.channel, () => laneCount);
      for (final lane in track.lanes) {
        // The lane's recorded image (slice 3): the balance gain before the
        // level push composes with it, the image before the track pan
        // below lands on top of it.
        restoredMix.balances[(track.channel, lane.lane)] = lane.balance;
        restoredMix.images[(track.channel, lane.lane)] = lane.pan;
        restoredMix.levels[(track.channel, lane.lane)] = lane.volume;
        _requireSessionSetting(
          setLaneMute(
            muted: lane.muted,
            channel: track.channel,
            lane: lane.lane,
          ),
        );
      }
    }

    _requireSessionSetting(
      setOneShotSnapshot(
        defaultOneShot: rig.defaultOneShot,
        trackOverrides: oneShotOverrides,
      ),
    );
    _requireSessionSetting(await settleOneShot());
    requireCurrent();

    // Settings have one content-independent owner. Empty tracks and custom
    // values equal to defaults restore through the same maps as recorded
    // ones.
    // Before device startup there is no native track array yet, but the eight
    // product tracks still own settings that must be replayed on first start.
    final settingsTrackCount = _intendRunning ? trackCount : 8;
    for (var channel = 0; channel < settingsTrackCount; channel++) {
      _requireSessionSetting(
        setTrackOverdubDecay(
          channel: channel,
          percent: overdubDecayOverrides[channel],
        ),
      );
    }

    // A loaded target receives exactly one final recipe. Clearing it first
    // would queue a second revision for the same target before the first one
    // reaches the callback, so the native owner would refuse the restore.
    for (final key in <(int, int)>{
      ...priorLaneKeys,
      ..._laneEffects.keys,
      ..._laneChainEnabled.keys,
      ...rig.laneChains.keys,
    }) {
      if (key.$1 < 0 || key.$1 >= settingsTrackCount) {
        _laneEffects.remove(key);
        _laneChainEnabled.remove(key);
        _laneChainMeta.remove(key);
        continue;
      }
      final chain = rig.laneChains[key];
      _requireSessionSetting(
        setLaneEffects(
          channel: key.$1,
          lane: key.$2,
          effects: chain?.entries ?? const [],
          chainEnabled: chain?.chainEnabled ?? true,
          allowUnavailable: true,
        ),
      );
      setLaneChainMeta(
        channel: key.$1,
        lane: key.$2,
        inheritedFrom: chain?.meta?.inheritedFrom ?? const [],
      );
    }
    for (final channel in <int>{
      ..._trackEffects.keys,
      ..._trackChainEnabled.keys,
      ...rig.trackChains.keys,
    }) {
      if (channel < 0 || channel >= settingsTrackCount) {
        _trackEffects.remove(channel);
        _trackChainEnabled.remove(channel);
        continue;
      }
      final chain = rig.trackChains[channel];
      _requireSessionSetting(
        setTrackEffects(
          channel: channel,
          effects: chain?.entries ?? const [],
          chainEnabled: chain?.chainEnabled ?? true,
          allowUnavailable: true,
        ),
      );
    }
    for (final bus in <int>{
      ..._outputEffects.keys,
      ..._outputChainEnabled.keys,
      ...rig.outputChains.keys,
    }) {
      final chain = rig.outputChains[bus] ?? const FxChainEnvelope();
      _requireSessionSetting(
        setOutputEffects(
          bus: bus,
          effects: chain.entries,
          chainEnabled: chain.chainEnabled,
          allowUnavailable: true,
        ),
      );
    }
    _requireSessionSetting(
      setAllTracksEffects(
        effects: rig.allTracksChain.entries,
        chainEnabled: rig.allTracksChain.chainEnabled,
        allowUnavailable: true,
      ),
    );
    // Monitors: fully reset every remembered monitor the rig does not define
    // —
    // not just its chain but its enable / routing / mix too, or an input
    // enabled under session A would keep monitoring under session B (the F2
    // leftover class). Reset to the disabled defaults, then apply the rig's.
    final definedMonitors = {for (final m in rig.monitors) m.input};
    // Snapshot the configured inputs before the reset loop mutates the maps.
    // Resetting a monitor already at the disabled default is a no-op, so the
    // default-omitting `allMonitors()` covers every input that needs
    // clearing.
    final rememberedMonitors = allMonitors().keys.toList();
    for (final input in rememberedMonitors) {
      if (definedMonitors.contains(input)) continue;
      setMonitorInputMode(input: input, mode: MonitorMode.off);
      setMonitorOutput(input: input, mask: _defaultMonitorOutputMask);
      restoredMix.monitorLevels[input] = 1;
      _requireSessionSetting(setMonitorMute(input: input, muted: false));
      _requireSessionSetting(
        setMonitorEffects(
          input: input,
          effects: const [],
          chainEnabled: true,
        ),
      );
    }
    for (final monitor in rig.monitors) {
      // Silence before enabling; unmute only after the destination is ready.
      if (monitor.muted) {
        _requireSessionSetting(
          setMonitorMute(input: monitor.input, muted: true),
        );
      }
      setMonitorInputMode(input: monitor.input, mode: monitor.mode);
      setMonitorOutput(input: monitor.input, mask: monitor.outputMask);
      if (!monitor.muted) {
        _requireSessionSetting(
          setMonitorMute(input: monitor.input, muted: false),
        );
      }
      restoredMix.monitorLevels[monitor.input] = monitor.volume;
      _requireSessionSetting(
        setMonitorEffects(
          input: monitor.input,
          effects: monitor.effects,
          chainEnabled: monitor.chainEnabled,
          allowUnavailable: true,
        ),
      );
    }
    // The input setup (slice 3): trims to the engine, pans and balances onto
    // the monitors. After the monitors above, so their gains compose with
    // the pairs' balance; before the tracks' lanes are seeded by a later
    // record, which reads it.
    _requireSessionSetting(_requestMix(restoredMix, replay: true));
    _requireSessionSetting(
      await settleMixSettings(
        pollInterval: clearPollInterval,
        attempts: clearPollAttempts,
      ),
    );
    requireCurrent();
    _requireSessionSetting(
      await settleFxRecipes(
        pollInterval: clearPollInterval,
        attempts: clearPollAttempts,
      ),
    );
    requireCurrent();

    // Last, after every import/commit that could throw: [rigReplaced]'s
    // contract is "a NEW rig is on the engine", not "a load was attempted".
    if (!_rigReplaced.isClosed) _rigReplaced.add(null);
  }

  Future<void> _importSessionAudio(
    SessionRig rig, {
    required int revision,
    required int generation,
    required Duration interval,
    required int attempts,
  }) async {
    if (rig.tracks.isEmpty) return;
    bool current() =>
        revision == _sessionRevision &&
        generation == _mixGeneration &&
        !_controller.isClosed;
    void requireCurrent() {
      if (!current()) throw StateError('session import was superseded');
    }

    requireCurrent();
    _importTracks = state.tracks;
    try {
      for (final track in rig.tracks) {
        requireCurrent();
        // A clear posted just above may not be acked yet — the engine rejects
        // an
        // import that races a pending state flip and expects a trivial retry.
        // The
        // ack lands within a buffer or two, so cap the retry low (NOT the full
        // clear budget, which — times track count — could stall a load for
        // seconds on a genuinely bad stem before surfacing the error). Only the
        // first (lane 0) import can race the clear ack; once it lands the track
        // stays EMPTY until commit, so sibling lanes import without retry.
        final importRetries = attempts < _maxImportAckRetries
            ? attempts
            : _maxImportAckRetries;
        // Stage every layer of every lane, then finalize to rebuild the shared
        // undo/redo stacks. Only the very first import into the track can race
        // the just-posted clear's ack, so retry that one; the rest follow while
        // the track stays EMPTY.
        var first = true;
        for (final lane in track.lanes) {
          for (var ordinal = 0; ordinal < lane.layers.length; ordinal++) {
            final pcm = lane.layers[ordinal];
            var result = _engine.importLayer(
              track.channel,
              lane.lane,
              ordinal,
              pcm,
            );
            if (first) {
              for (
                var attempt = 0;
                !result.isOk && attempt < importRetries;
                attempt++
              ) {
                await Future<void>.delayed(interval);
                requireCurrent();
                result = _engine.importLayer(
                  track.channel,
                  lane.lane,
                  ordinal,
                  pcm,
                );
              }
              first = false;
            }
            if (!result.isOk) {
              throw StateError(
                'failed to import track ${track.channel} lane ${lane.lane} '
                'layer $ordinal: ${result.name}',
              );
            }
          }
        }
        // The history is track-wide (shared across lanes) — take lane 0's.
        final primary = track.lanes.first;
        final finalized = _engine.finalizeHistory(
          track.channel,
          primary.history,
        );
        if (!finalized.isOk) {
          throw StateError(
            'failed to finalize track ${track.channel}: ${finalized.name}',
          );
        }
      }
      // Finalization queues a material reset. Its callback must publish the
      // new Fade generation before an image can target that imported material.
      var finalized = false;
      for (var attempt = 0; attempt < attempts; attempt++) {
        requireCurrent();
        if (_engine.commandsSettled) {
          finalized = true;
          break;
        }
        await Future<void>.delayed(interval);
      }
      if (!finalized) throw StateError('session material reset did not settle');
      requireCurrent();
      final imported = _engine.snapshot();
      for (final track in rig.tracks) {
        requireCurrent();
        if (track.channel >= imported.tracks.length) {
          throw StateError('session Fade track is unavailable');
        }
        final identity = imported.tracks[track.channel].fade;
        final result = await installFade(
          channel: track.channel,
          image: FadeImage(
            amount: track.fadeAmount,
            target: track.fadeAmount,
            lifetime: identity.lifetime,
            generation: identity.generation,
          ),
        );
        requireCurrent();
        if (!result.isOk) {
          throw StateError('failed to install Session Fade: ${result.name}');
        }
      }
      // An empty session establishes no master: the engine stays free to define
      // a fresh loop length.
      if (rig.tracks.isNotEmpty && rig.baseLengthFrames > 0) {
        final committed = _engine.commitSession(
          rig.baseLengthFrames,
          loopBeats: rig.gridBeats,
        );
        if (!committed.isOk) {
          throw StateError('failed to commit the session: ${committed.name}');
        }
      }

      for (var attempt = 0; attempt < attempts; attempt++) {
        requireCurrent();
        if (_engine.commandsSettled) {
          final snapshot = _engine.snapshot();
          final committed =
              snapshot.masterLengthFrames == rig.baseLengthFrames &&
              rig.tracks.every((track) {
                if (track.channel >= snapshot.tracks.length) return false;
                final actual = snapshot.tracks[track.channel];
                final primary = track.lanes.first;
                return actual.state == TrackState.stopped &&
                    actual.lengthFrames == primary.livePcm.length &&
                    actual.undoDepth == primary.undoCount &&
                    actual.redoDepth == primary.redoCount;
              });
          if (!committed) throw StateError('session import commit was refused');
          _importTracks = null;
          _reproject();
          return;
        }
        await Future<void>.delayed(interval);
      }
      throw StateError('session import commit did not settle');
    } catch (_) {
      if (current()) {
        var admitted = true;
        for (final track in rig.tracks) {
          if (!_clearDestructive(channel: track.channel).isOk) admitted = false;
        }
        final cleared = admitted && await _awaitCleared(interval, attempts);
        if (current()) {
          if (cleared) {
            _importTracks = null;
            _reproject();
          } else {
            // A queued commit must not apply after failure. Keep staged audio
            // private even if the native stop retains its final raw snapshot.
            stopEngine();
          }
        }
      }
      rethrow;
    }
  }

  static bool _audioCleared(EngineSnapshot snapshot) =>
      snapshot.masterLengthFrames == 0 &&
      snapshot.tracks.every(
        (track) =>
            track.state == TrackState.empty &&
            track.lengthFrames == 0 &&
            track.undoDepth == 0 &&
            track.redoDepth == 0 &&
            track.lanes.every((lane) => lane.lengthFrames == 0),
      );

  /// The default monitor output routing (the first stereo pair) an undefined
  /// monitor resets to on a session apply — matches [monitorOutput]'s default.
  static const int _defaultMonitorOutputMask = 0x3;

  /// The ceiling on how many times a session-import retries the posted-clear
  /// ack race (a few audio buffers). Bounds a genuinely-bad stem's failure so a
  /// load can't stall for seconds per track.
  static const int _maxImportAckRetries = 8;

  /// Polls until every track reports empty and the master is reset, returning
  /// whether the engine settled within [attempts].
  Future<bool> _awaitCleared(Duration interval, int attempts) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (_intendRunning && !_engine.commandsSettled) {
        await Future<void>.delayed(interval);
        continue;
      }
      final snapshot = _engine.snapshot();
      if (_audioCleared(snapshot)) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// Every remembered Loop-stage chain as the persisted [FxChainEnvelope],
  /// keyed by `(channel, lane)` — what a session save captures (the live rig
  /// is the truth being saved).
  ///
  /// The key set is the UNION of the chain, chain-flag and provenance maps, not
  /// just the chain map: a lane whose chain is empty but whose flag is
  /// disabled (or that carries an inheritance marker) has state worth saving.
  /// A lane at every default appears in none of the three, so it is omitted —
  /// and an omitted lane is RESET on the next apply, never inherited (F2).
  Map<(int, int), FxChainEnvelope> allLaneChains() {
    final keys = <(int, int)>{
      ..._laneEffects.keys,
      ..._laneChainEnabled.keys,
      ..._laneChainMeta.keys,
    };
    return {
      for (final key in keys)
        key: FxChainEnvelope(
          chainEnabled: laneChainEnabled(key.$1, key.$2),
          // Null — not an empty marker — when the chain was never inherited,
          // matching [FxChainEnvelope.meta]'s contract and `decodeFxChain`'s
          // own normalization, so an envelope read back here equals the one a
          // decode produces.
          meta: _metaOrNull(laneChainInheritedFrom(key.$1, key.$2)),
          entries: laneEffects(key.$1, key.$2),
        ),
    };
  }

  static FxChainMeta? _metaOrNull(List<int> inheritedFrom) =>
      inheritedFrom.isEmpty ? null : FxChainMeta(inheritedFrom: inheritedFrom);

  /// Every remembered Track-stage (stereo bus) chain as the persisted
  /// envelope, keyed by track channel — the bus twin of [allLaneChains] (bus
  /// chains carry no inheritance provenance, so their envelopes have no meta).
  Map<int, FxChainEnvelope> allTrackChains() {
    final channels = <int>{..._trackEffects.keys, ..._trackChainEnabled.keys};
    return {
      for (final channel in channels)
        channel: FxChainEnvelope(
          chainEnabled: trackChainEnabled(channel),
          entries: trackEffects(channel),
        ),
    };
  }

  /// The destination chain as a persisted envelope, empty and enabled
  /// when the destination has never been configured.
  FxChainEnvelope outputChainEnvelope(int bus) => FxChainEnvelope(
    chainEnabled: outputChainEnabled(bus),
    entries: outputEffects(bus),
  );

  /// Every configured output destination, including an empty disabled chain.
  Map<int, FxChainEnvelope> allOutputChains() => {
    for (final bus in {..._outputEffects.keys, ..._outputChainEnabled.keys})
      bus: outputChainEnvelope(bus),
  };

  /// Every **configured** live monitor, keyed by input — the union of all
  /// remembered monitor state (enable / routing / mix / effects), not just
  /// inputs that carry an FX chain. A monitor equal to the disabled default is
  /// omitted, so an absent input reads back as the disabled default on load.
  ///
  /// The single monitor-enumeration source of truth: a session save captures
  /// this (so a dry-but-enabled monitor round-trips), the MonitorCubit
  /// re-projects from it after a session load, and [applySession]'s reset walks
  /// its keys.
  Map<int, InputMonitor> allMonitors() {
    final inputs = <int>{
      ..._monitorInputMode.keys,
      ..._monitorOutput.keys,
      ..._monitorVolume.keys,
      ..._monitorMute.keys,
      ..._monitorEffects.keys,
      ..._monitorChainEnabled.keys,
    };
    final result = <int, InputMonitor>{};
    for (final input in inputs) {
      final monitor = InputMonitor(
        input: input,
        mode: monitorMode(input),
        outputMask: monitorOutput(input),
        volume: monitorVolume(input),
        pan: _inputSetup.effectivePanOf(input),
        muted: monitorMuted(input),
        effects: monitorEffects(input),
        chainEnabled: monitorChainEnabled(input),
      );
      // Skip inputs equal to the disabled default (no state worth persisting).
      if (monitor != InputMonitor(input: input)) result[input] = monitor;
    }
    return result;
  }

  /// What hardware [input]'s live monitor is asked to do (remembered intent).
  MonitorMode monitorMode(int input) =>
      _monitorInputMode[input] ?? MonitorMode.off;

  /// Whether hardware [input] is monitoring **right now** — intent resolved
  /// against the record arm. This is the boolean the engine is given.
  ///
  /// [MonitorMode.auto] is a **fan-in**, not a 1:1: there is no "the input's
  /// track". A lane records one [Lane.inputChannel], and one input can feed
  /// lanes on several tracks, so the rule is *any* of them being armed.
  bool monitorResolved(int input) => switch (monitorMode(input)) {
    MonitorMode.off => false,
    MonitorMode.on => true,
    MonitorMode.auto => _autoArms(input),
  };

  /// Whether any lane fed by [input] sits on a track that is armed or
  /// capturing. `pending` is the waiting quantized arm; `isCapturing` is
  /// recording or overdubbing.
  ///
  /// Walks the PROJECTED lanes rather than [_laneInput]. Two reasons: the
  /// projection has already applied the `?? lane` default, so a lane that was
  /// never explicitly routed still counts (over half of them, in a default
  /// rig); and arm state and routing then come off the same object instead of
  /// being joined across an intent map and a snapshot that could disagree.
  ///
  /// No projection yet means nothing can be armed, so `auto` reads closed —
  /// which is also the right answer while the engine is stopped.
  bool _autoArms(int input) {
    final state = _last;
    if (state == null) return false;
    for (final track in state.tracks) {
      if (!track.pending && !track.isCapturing) continue;
      for (final lane in track.lanes) {
        if (lane.inputChannel == input) return true;
      }
    }
    return false;
  }

  /// Immediate record/arm fence, including accepted requests not yet published.
  bool recordingInputsLocked(int channel) {
    if (_pendingImages.containsKey(channel)) return true;
    final tracks = _engine.snapshot().tracks;
    if (channel < 0 || channel >= 8) return true;
    if (channel >= tracks.length) return false;
    final track = tracks[channel];
    return track.pending ||
        track.state == TrackState.recording ||
        track.state == TrackState.overdubbing;
  }

  bool _sourceAvailable(int input) {
    final device = _engine.snapshot();
    return input >= 0 &&
        input < device.inputChannels &&
        (device.excludedInputMask & (1 << input)) == 0;
  }

  MixSettingsSnapshot? _assignSources(
    MixSettingsSnapshot snapshot,
    int channel,
    List<int> members,
    bool selected,
  ) {
    if (recordingInputsLocked(channel)) return null;
    if (selected && members.any((input) => !_sourceAvailable(input))) {
      return null;
    }
    var count = snapshot.laneCounts[channel] ?? 1;
    final inputs = Map<(int, int), int>.of(snapshot.laneInputs);
    final levels = Map<(int, int), double>.of(snapshot.laneLevels);
    for (final input in members) {
      final assigned = [
        for (var lane = 0; lane < count; lane++)
          if ((inputs[(channel, lane)] ?? lane) == input) lane,
      ];
      if (!selected) {
        for (final lane in assigned) {
          inputs[(channel, lane)] = -1;
        }
        continue;
      }
      if (assigned.isNotEmpty) continue;
      var free = -1;
      for (var lane = 0; lane < count; lane++) {
        if ((inputs[(channel, lane)] ?? lane) < 0) {
          free = lane;
          break;
        }
      }
      if (free < 0) {
        if (count >= kMaxLanes) return null;
        free = count++;
        levels.putIfAbsent((channel, free), () => 1);
      }
      inputs[(channel, free)] = input;
    }
    return snapshot.copyWith(
      laneInputs: inputs,
      laneLevels: levels,
      laneCounts: {...snapshot.laneCounts, channel: count},
    );
  }

  /// Builds one admitted source selection without changing live or saved state.
  /// Explicit stereo membership expands either selected member to both.
  MixSettingsSnapshot? prepareRecordingInputs(
    MixSettingsSnapshot snapshot, {
    required int channel,
    required int input,
    required bool selected,
  }) {
    if (!snapshot.isValid ||
        channel < 0 ||
        channel >= 8 ||
        input < 0 ||
        input >= kMaxChannels) {
      return null;
    }
    final lower = snapshot.inputSetup.pairOf(input);
    return _assignSources(
      snapshot,
      channel,
      lower == null ? [input] : [lower, lower + 1],
      selected,
    );
  }

  /// Links every affected track as one proposal, or refuses all of them.
  /// Unlinking retains both source selections and the recorded lane identities.
  MixSettingsSnapshot? prepareInputPair(
    MixSettingsSnapshot snapshot, {
    required int input,
    required bool paired,
  }) {
    if (!snapshot.isValid ||
        input < 0 ||
        input + 1 >= kMaxChannels ||
        input.isOdd ||
        _inputPairLocked(input) ||
        _inputPairLocked(input + 1)) {
      return null;
    }
    if (paired && (!_sourceAvailable(input) || !_sourceAvailable(input + 1))) {
      return null;
    }
    var next = snapshot.copyWith(
      inputSetup: snapshot.inputSetup.withPair(input, paired: paired),
    );
    if (!paired) return next;
    for (var channel = 0; channel < 8; channel++) {
      final count = next.laneCounts[channel] ?? 1;
      final affected = [
        for (var lane = 0; lane < count; lane++)
          next.laneInputs[(channel, lane)] ?? lane,
      ].any((value) => value == input || value == input + 1);
      if (!affected) continue;
      final expanded = _assignSources(next, channel, [input, input + 1], true);
      if (expanded == null) return null;
      next = expanded;
    }
    return next;
  }

  /// Routes all current and future lane slots in one detached track edit.
  /// Remembered absent destinations can be removed but never newly added.
  MixSettingsSnapshot? prepareTrackOutput(
    MixSettingsSnapshot snapshot, {
    required int channel,
    required int mask,
  }) {
    if (!snapshot.isValid ||
        channel < 0 ||
        channel >= 8 ||
        mask < 0 ||
        mask > 0xffffffff) {
      return null;
    }
    final channels = _engine.snapshot().outputChannels;
    final available = channels >= kMaxChannels
        ? 0xffffffff
        : (1 << channels) - 1;
    final routes = Map<(int, int), int>.of(snapshot.laneOutputs);
    for (var lane = 0; lane < kMaxLanes; lane++) {
      final old = routes[(channel, lane)] ?? 3;
      if ((mask & ~old & ~available) != 0) return null;
      routes[(channel, lane)] = mask;
    }
    return snapshot.copyWith(laneOutputs: routes);
  }

  bool _inputPairLocked(int input) {
    if (_pendingImages.values.any(
      (pending) => pending.inputs.contains(input),
    )) {
      return true;
    }
    // The callback may be ahead of the UI projection, including when an
    // accepted arm has just become a recording or overdub.
    final snapshot = _engine.snapshot();
    for (var channel = 0; channel < snapshot.tracks.length; channel++) {
      final track = snapshot.tracks[channel];
      if (!track.pending &&
          track.state != TrackState.recording &&
          track.state != TrackState.overdubbing) {
        continue;
      }
      for (var lane = 0; lane < laneCount(channel); lane++) {
        if ((_laneInput[(channel, lane)] ?? lane) == input) return true;
      }
    }
    return _autoArms(input);
  }

  /// Re-pushes the resolved gate for every [MonitorMode.auto] input whose
  /// answer has changed since the last push.
  ///
  /// Called where the repository already recomputes on a state change, so
  /// `auto` needs no subscription and no lifecycle of its own. Only `auto`
  /// inputs are walked: `off` and `on` do not depend on the arm state, and
  /// their pushes stay where every other monitor write already is.
  void _reconcileAutoMonitors() {
    if (!_intendRunning) return;
    for (final entry in _monitorInputMode.entries) {
      if (entry.value != MonitorMode.auto) continue;
      final resolved = monitorResolved(entry.key);
      if (_monitorResolvedPushed[entry.key] == resolved) continue;
      _monitorResolvedPushed[entry.key] = resolved;
      _engine.setMonitorInputEnabled(input: entry.key, enabled: resolved);
    }
  }

  /// Monitor [input]'s remembered output mask (the default stereo pair if
  /// never set).
  int monitorOutput(int input) =>
      _monitorOutput[input] ?? _defaultMonitorOutputMask;

  /// Monitor [input]'s remembered output gain (unity if never set).
  double monitorVolume(int input) => _monitorVolume[input] ?? 1;

  /// Whether monitor [input] is muted (remembered intent).
  bool monitorMuted(int input) => _monitorMute[input] ?? false;

  /// The fingerprint of lane [lane] of track [channel]'s CACHED chain, computed
  /// with the same folding as the engine's [AudioEngine.laneFxFingerprint] —
  /// chain flag + per-slot enabled bits included — so the two can be compared
  /// for cache-vs-engine divergence (F6). An absent chain yields the
  /// empty-chain basis, matching an empty engine lane.
  int laneChainFingerprint(int channel, int lane) => fxChainFingerprint(
    _laneEffects[(channel, lane)] ?? const [],
    chainEnabled: laneChainEnabled(channel, lane),
  );

  /// The fingerprint of monitor [input]'s CACHED chain (see
  /// [laneChainFingerprint]).
  int monitorChainFingerprint(int input) => fxChainFingerprint(
    _monitorEffects[input] ?? const [],
    chainEnabled: monitorChainEnabled(input),
  );

  /// The fingerprint of track [channel]'s CACHED Track-stage chain (see
  /// [laneChainFingerprint]; pure-Dart — the engine publishes no native twin
  /// for the bus stages yet).
  int trackFxChainFingerprint(int channel) => fxChainFingerprint(
    _trackEffects[channel] ?? const [],
    chainEnabled: trackChainEnabled(channel),
  );

  /// The fingerprint of the CACHED output destination chain (see
  /// [trackFxChainFingerprint]).
  int outputFxChainFingerprint(int bus) => fxChainFingerprint(
    outputEffects(bus),
    chainEnabled: outputChainEnabled(bus),
  );

  /// Whether lane [lane] of track [channel]'s chain currently SOUNDS
  /// different from its routed input's monitor chain (A7). The domain query
  /// behind part 4's overdub "input ≠ loop chain" hint: overdub never
  /// re-inherits, so the two drift apart the moment the input chain is edited
  /// after the take. A lane with no monitorable routed input never diverges
  /// (there is nothing to diverge from).
  ///
  /// Audible-shape comparison, consistent with D-CHAINDIS (R18): a chain that
  /// is EMPTY, chain-DISABLED, or has EVERY slot individually disabled (each
  /// renders bit-exact passthrough, R16) is dry on either side — two dry
  /// chains never diverge (even if their raw fingerprints differ), a dry
  /// chain always diverges from an audible one, and two audible chains
  /// compare by sound fingerprint.
  bool laneChainDivergesFromInput(int channel, int lane) {
    final input = _laneInput[(channel, lane)] ?? lane;
    if (input < 0 || input >= kMaxMonitoredInputs) return false;
    final laneDry = _chainAudiblyDry(
      _laneEffects[(channel, lane)] ?? const [],
      chainEnabled: laneChainEnabled(channel, lane),
    );
    final monitorDry = _chainAudiblyDry(
      _monitorEffects[input] ?? const [],
      chainEnabled: monitorChainEnabled(input),
    );
    if (laneDry || monitorDry) return laneDry != monitorDry;
    return laneChainFingerprint(channel, lane) !=
        monitorChainFingerprint(input);
  }

  /// Whether a chain renders bit-exact passthrough: empty, chain-disabled,
  /// or every slot individually disabled (all three dry shapes; an empty
  /// chain trivially satisfies the `every`).
  static bool _chainAudiblyDry(
    List<TrackEffect> chain, {
    required bool chainEnabled,
  }) => !chainEnabled || chain.every((fx) => !fx.enabled);

  /// Sets the track's independent playback gain after Pre and before Post.
  /// Part levels and the captured source image remain independent.
  EngineResult setVolume(double volume, {int channel = 0}) {
    if (channel < 0 || channel >= 8 || !volume.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    final next = _mixIntent();
    next.trackLevels[channel] = volume.clamp(0.0, 2.0);
    return _requestMix(next);
  }

  /// Whether track [channel] is muted per the repository's remembered
  /// intent — **every lane of it**, the same whole-track reading [setMute]
  /// writes.
  ///
  /// Synchronous intent, not the polled snapshot, for the reason
  /// [trackChainEnabled] exists: a toggle resolved from a ~16 ms-stale
  /// snapshot mirror can read the pre-toggle value twice inside the echo
  /// window and re-apply the first flip instead of undoing it.
  bool trackMuted(int channel) {
    for (var lane = 0; lane < laneCount(channel); lane++) {
      if (!(_laneMute[(channel, lane)] ?? false)) return false;
    }
    return true;
  }

  /// Mutes or unmutes track [channel] — **every lane of it**. A track-level
  /// mute is a whole-track control, so a multi-lane track silences (or
  /// restores) all its lanes, not just lane 0. Returns the last failing lane's
  /// result, or [EngineResult.ok] if all lanes succeed.
  EngineResult setMute({required bool muted, int channel = 0}) {
    var result = EngineResult.ok;
    for (var lane = 0; lane < laneCount(channel); lane++) {
      final r = setLaneMute(muted: muted, channel: channel, lane: lane);
      if (r != EngineResult.ok) result = r;
    }
    return result;
  }

  /// Routes track [channel]'s lane 0 record source to the input channels in
  /// [mask]. A lane records a single input, so the lowest set bit is used
  /// (`0` => record nothing); the full per-lane assignment UI lands in a later
  /// PR. Convenience for lane 0.
  EngineResult setInputMask({required int channel, required int mask}) =>
      setLaneInput(
        channel: channel,
        lane: 0,
        inputChannel: maskToInputChannel(mask),
      );

  /// Routes track [channel]'s lane 0 playback to the output channels in [mask].
  /// Convenience for lane 0.
  EngineResult setOutputMask({required int channel, required int mask}) =>
      setLaneOutput(channel: channel, lane: 0, mask: mask);

  /// Sets track [channel]'s active lane count (`>= 1`), lazily allocating the
  /// buffers for any newly added lanes. Remembered and re-applied on every
  /// (re)start; takes effect immediately only while running.
  EngineResult setLaneCount({required int channel, required int count}) {
    if (channel < 0 || channel >= 8 || count < 1 || count > kMaxLanes) {
      return EngineResult.invalid;
    }
    final levels = Map<(int, int), double>.of(_laneVolume);
    for (var lane = laneCount(channel); lane < count; lane++) {
      levels.putIfAbsent((channel, lane), () => 1);
    }
    return applyMixSettings(
      mixSettingsSnapshot.copyWith(
        laneCounts: {..._laneCount, channel: count},
        laneLevels: levels,
      ),
    );
  }

  /// Track [channel]'s remembered active lane count (`1` if unset).
  int laneCount(int channel) => _laneCount[channel] ?? 1;

  /// Lane [lane] of track [channel] records hardware input [inputChannel]
  /// (`-1` = none) into its own clean buffer. Remembered and re-applied on
  /// every (re)start.
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    return applyMixSettings(
      mixSettingsSnapshot.copyWith(
        laneInputs: {..._laneInput, (channel, lane): inputChannel},
      ),
    );
  }

  /// Routes lane [lane] of track [channel]'s playback to the output channels in
  /// [mask]. Remembered and re-applied on every (re)start.
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    return applyMixSettings(
      mixSettingsSnapshot.copyWith(
        laneOutputs: {..._laneOutput, (channel, lane): mask},
      ),
    );
  }

  /// Sets lane [lane] of track [channel]'s playback gain (`0..LE_MAX_GAIN`,
  /// 2.0, +6.02 dB headroom above unity). Remembered and re-applied on every
  /// (re)start.
  EngineResult setLaneVolume(
    double volume, {
    required int channel,
    required int lane,
  }) {
    if (channel < 0 ||
        channel >= 8 ||
        lane < 0 ||
        lane >= kMaxLanes ||
        !volume.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    final next = _mixIntent();
    next.levels[(channel, lane)] = volume.clamp(0.0, 2.0);
    return _requestMix(next);
  }

  /// Track [channel]'s pan, `-1` (left) .. `1` (right); the repository's
  /// remembered intent.
  double trackPan(int channel) => _trackPan[channel] ?? 0;

  /// Confirmed pans, including empty tracks.
  Map<int, double> get trackPans => Map.unmodifiable(_trackPan);

  /// Sets track [channel]'s pan (accepted design, Mixer): every lane's
  /// recorded image moves by it. Remembered and re-applied on every
  /// (re)start; re-projects, since the pan is projected from the cache.
  EngineResult setTrackPan(double pan, {int channel = 0}) {
    if (channel < 0 || channel >= 8 || !pan.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    final next = _mixIntent();
    next.pans[channel] = pan.clamp(-1.0, 1.0);
    return _requestMix(next);
  }

  /// Whether this track is soloed in the confirmed mix.
  bool trackSoloed(int channel) => _trackSolo[channel] ?? false;

  /// Changes only the track's solo flag, independently of mute.
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    if (channel < 0 || channel >= 8) return _mixFailure(EngineResult.invalid);
    final next = _mixIntent();
    next.solos[channel] = solo;
    return _requestMix(next);
  }

  /// Clears every solo as one accepted change.
  EngineResult clearSolo() => _requestMix(_mixIntent()..solos.clear());

  /// Resets all track levels and pan together, preserving image balance,
  /// mute, solo, FX and PCM.
  EngineResult resetMixer() {
    final next = _mixIntent()
      ..pans.clear()
      ..trackLevels.clear();
    return _requestMix(next);
  }

  /// Confirmed output setup.
  OutputSetup get outputSetup => _outputSetup;

  /// Sets one destination level, retaining mute and balance.
  EngineResult setOutputLevel({required int bus, required double level}) =>
      _applyOutputBus(bus, _outputSetup.of(bus).copyWith(level: level));

  /// Changes mute without losing the retained level.
  EngineResult setOutputMute({required int bus, required bool muted}) =>
      _applyOutputBus(bus, _outputSetup.of(bus).copyWith(muted: muted));

  /// Changes Stereo/Mono without losing the retained balance.
  EngineResult setOutputMono({required int bus, required bool mono}) =>
      _applyOutputBus(bus, _outputSetup.of(bus).copyWith(mono: mono));

  /// Changes the balance retained while Mono is enabled.
  EngineResult setOutputBalance({required int bus, required double balance}) =>
      _applyOutputBus(bus, _outputSetup.of(bus).copyWith(balance: balance));

  /// Replaces every destination atomically through the shared mix transaction.
  EngineResult setOutputSetup(OutputSetup setup) =>
      applyMixSettings(mixSettingsSnapshot.copyWith(outputSetup: setup));

  EngineResult _applyOutputBus(int bus, OutputBus value) {
    if (bus < 0 || bus >= kMaxOutputBuses) return EngineResult.invalid;
    return setOutputSetup(_outputSetup.withBus(bus, value));
  }

  /// Stops audible recorded sources and clears effect tails, keeping settings.
  EngineResult cutSound() =>
      _intendRunning ? _engine.cutSound() : EngineResult.ok;

  /// The per-input capture setup, the repository's remembered intent.
  InputSetup get inputSetup => _inputSetup;

  /// Capture gain only. The UI chooses half-decibel increments.
  EngineResult setInputTrimDb({required int input, required double db}) {
    if (input < 0 || input >= kMaxChannels || !db.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    return setInputSetup(
      _inputSetup.withTrim(input, db.clamp(kMinInputTrimDb, kMaxInputTrimDb)),
    );
  }

  /// Moves live monitoring and future recording images.
  EngineResult setInputPan({required int input, required double pan}) {
    if (input < 0 || input >= kMaxChannels || !pan.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    return setInputSetup(_inputSetup.withPan(input, pan.clamp(-1.0, 1.0)));
  }

  /// Pair membership cannot change while either source is armed/capturing.
  EngineResult setInputPair({required int input, required bool paired}) {
    final next = prepareInputPair(
      mixSettingsSnapshot,
      input: input,
      paired: paired,
    );
    return next == null
        ? _mixFailure(EngineResult.invalid)
        : applyMixSettings(next);
  }

  /// Changes both members' effective live mix atomically.
  EngineResult setPairBalance({required int input, required double balance}) {
    if (!_inputSetup.pairs.containsKey(input) || !balance.isFinite) {
      return _mixFailure(EngineResult.invalid);
    }
    return setInputSetup(
      _inputSetup.withBalance(input, balance.clamp(-1.0, 1.0)),
    );
  }

  /// Replaces the validated whole setup without changing confirmed intent on
  /// refusal. Call settleMixSettings before saving it.
  EngineResult setInputSetup(InputSetup setup) {
    if (!setup.isValid) return _mixFailure(EngineResult.invalid);
    var next = mixSettingsSnapshot.copyWith(inputSetup: setup);
    for (final lower in setup.pairs.keys) {
      if (_inputSetup.pairs.containsKey(lower)) continue;
      final expanded = prepareInputPair(next, input: lower, paired: true);
      if (expanded == null) return _mixFailure(EngineResult.invalid);
      next = expanded;
    }
    return applyMixSettings(next);
  }

  /// Last admitted mute intent, including writes not yet in a polled snapshot.
  bool laneMuted(int channel, int lane) => _laneMute[(channel, lane)] ?? false;

  /// Mutes or unmutes lane [lane] of track [channel]. Remembered and re-applied
  /// on every (re)start.
  EngineResult setLaneMute({
    required bool muted,
    required int channel,
    required int lane,
  }) {
    if (channel < 0 || channel >= 8 || lane < 0 || lane >= kMaxLanes) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setLaneMute(
        muted: muted,
        channel: channel,
        lane: lane,
      );
      if (!result.isOk) return result;
    }
    _laneMute[(channel, lane)] = muted;
    return EngineResult.ok;
  }

  /// Arms the chromatic tuner on hardware [input], or disarms it with `-1`.
  ///
  /// Remembered and re-applied on every (re)start, like the rest of this class
  /// — which does NOT mean a rig resumes analysing behind a closed face. The
  /// face disarms on its way out, so `-1` IS the remembered value whenever
  /// nobody is looking; the cache only carries an arm across a restart that
  /// happens WHILE the tuner is open (a reconnect, a device change), which is
  /// the one case where dropping it strands the face on a dead engine.
  EngineResult setTunerInput({required int input}) {
    _tunerInput = input;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setTunerInput(input: input);
  }

  /// Sets what hardware [input]'s live monitor is asked to do. The input-level
  /// gate; per-lane routing / mix / effects drive each lane. The monitored
  /// signal is never recorded. Remembered and re-applied on every (re)start;
  /// takes effect immediately only while running.
  EngineResult setMonitorInputMode({
    required int input,
    required MonitorMode mode,
  }) {
    _monitorInputMode[input] = mode;
    final resolved = monitorResolved(input);
    _monitorResolvedPushed[input] = resolved;
    _monitorChanged(input);
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputEnabled(input: input, enabled: resolved);
  }

  /// Routes monitor [input]'s chain to the output channels in [mask].
  /// Remembered and re-applied on every (re)start; takes effect immediately
  /// only while running.
  EngineResult setMonitorOutput({required int input, required int mask}) {
    _monitorOutput[input] = mask;
    _monitorChanged(input);
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMonitorInputOutput(input: input, mask: mask);
  }

  /// Sets monitor [input]'s output gain ([volume], silence to unity).
  /// Remembered and re-applied on every
  /// (re)start; takes effect immediately while running.
  EngineResult setMonitorVolume({required int input, required double volume}) {
    if (input < 0 ||
        input >= kMaxChannels ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1) {
      return _mixFailure(EngineResult.invalid);
    }
    final next = _mixIntent();
    next.monitorLevels[input] = volume;
    return _requestMix(next);
  }

  /// Mutes or unmutes monitor [input]. Remembered and re-applied on every
  /// (re)start; takes effect immediately only while running.
  EngineResult setMonitorMute({required int input, required bool muted}) {
    if (input < 0 || input >= kMaxMonitoredInputs) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setMonitorInputMute(input: input, muted: muted);
      if (!result.isOk) return result;
    }
    _monitorMute[input] = muted;
    _monitorChanged(input);
    return EngineResult.ok;
  }

  /// Enables or disables hardware [input]'s conditioning stage (the fixed HPF /
  /// hum-notch / expander utility stage). Remembered and re-applied on every
  /// successful (re)start — the engine resets conditioning on each configure —
  /// and takes effect immediately only while running. Returns
  /// [EngineResult.invalid] for an input outside `[0, kMaxMonitoredInputs)`.
  EngineResult setInputConditioningEnabled({
    required int input,
    required bool enabled,
  }) {
    if (input < 0 || input >= kMaxMonitoredInputs) {
      return EngineResult.invalid;
    }
    _condEnabled[input] = enabled;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setInputConditioningEnabled(input: input, enabled: enabled);
  }

  /// Sets conditioning parameter [param] of hardware [input] to [value] in its
  /// real unit (Hz / dB / ms / ratio — see [InputConditioningParam]).
  /// Remembered
  /// and re-applied on every (re)start; takes effect immediately only while
  /// running. Independent of the enable flag — a value set while the stage is
  /// off is applied and takes effect when it is next enabled. Returns
  /// [EngineResult.invalid] for an input outside `[0, kMaxMonitoredInputs)`.
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) {
    if (input < 0 || input >= kMaxMonitoredInputs) {
      return EngineResult.invalid;
    }
    (_condParams[input] ??= {})[param] = value;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setInputConditioningParam(
      input: input,
      param: param,
      value: value,
    );
  }

  /// Turns hardware [output] on/off as a routing target (the structural output
  /// gate). A disabled output is removed from the mix while its lane/monitor
  /// route masks are preserved — re-enabling restores them. Default-on: only
  /// off entries are remembered, and they are re-applied on every (re)start.
  ///
  /// Re-projects, for the reason [setTrackRecordTiming] does: the gate
  /// lives in the
  /// map below and a stopped engine's snapshot cannot report it, so nothing
  /// else would tell a surface it had changed. A session load writes these with
  /// no user gesture to hang a re-read off.
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    if (enabled) {
      _outputEnabled.remove(output); // absence == enabled (default-on)
    } else {
      _outputEnabled[output] = false;
    }
    _reproject();
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setOutputEnabled(output: output, enabled: enabled);
  }

  /// Whether hardware [output] is currently enabled (a routing target). Reads
  /// the remembered gate (absence == enabled).
  bool outputEnabled(int output) => _outputEnabled[output] ?? true;

  /// Reads the loop waveform (peaks indexed by loop position, `0..1`) of the
  /// mixed output for the visualizer.
  Float32List readWaveform() => _engine.readVisual();

  /// Reads track [channel]'s loop waveform for a per-track thumbnail.
  ///
  /// The engine's buffer is a lazily swept tap, not a stored shape: each
  /// bucket holds the peak of the most recent pass over its slice of the
  /// loop, written as the sweeping playhead leaves it. So right after a
  /// content change (a finalize, an undo, a stop-then-play) the buffer still
  /// shows the previous pass until one full sweep has rewritten it, and while
  /// a take or a pass is captured it changes every block. Reading it across
  /// the engine boundary on every poll for every visible track is the cost
  /// the stage and the second display used to pay for that; this keeps one
  /// copy per track and re-reads only while the shape can still be changing:
  ///
  /// - on every call while the track's steady facts just changed, until the
  ///   sweep has passed a full lap beyond the change (that call included);
  /// - on every call while the track is capturing;
  /// - once per track lap thereafter, at the wrap, while the track plays;
  /// - never while the track stands still (its last shape is kept).
  ///
  /// The native tap and playhead both span this track's entire loop, including
  /// multiples, divisions and independent Free/Song clocks.
  Float32List readTrackWaveform(int channel) {
    final rig = lastState;
    final track = channel >= 0 && channel < rig.tracks.length
        ? rig.tracks[channel]
        : null;
    if (track == null || !track.hasContent) {
      _waveforms.remove(channel);
      return Float32List(0);
    }
    final key = _WaveformKey.of(track);
    final progress = track.progress;
    final entry = _waveforms[channel];
    if (entry == null || entry.key != key) {
      final samples = _engine.readTrackVisual(channel);
      _waveforms[channel] = _WaveformRead(key, samples, sweepFrom: progress);
      return samples;
    }
    final wrapped = progress < entry.lastProgress;
    if (wrapped) entry.wraps++;
    entry.lastProgress = progress;
    final swept =
        entry.wraps >= 2 || (entry.wraps == 1 && progress >= entry.sweepFrom);
    // The call that completes the sweep reads too: the buckets between the
    // previous call and here were the last ones still holding the old pass.
    final justSwept = swept && !entry.swept;
    entry.swept = swept;
    final playing = track.state == TrackState.playing;
    if (track.isCapturing || (playing && (!swept || justSwept || wrapped))) {
      entry.samples = _engine.readTrackVisual(channel);
    }
    return entry.samples;
  }

  /// One copy of each track's waveform, see [readTrackWaveform].
  final _waveforms = <int, _WaveformRead>{};

  /// Drops the copies of tracks that lost their content, so a take recorded
  /// or restored later under the same steady facts starts its own sweep
  /// rather than inheriting a finished one. Called per projection; the
  /// readers only ask for tracks with content, so they never see the empty
  /// branch above themselves.
  void _forgetEmptyWaveforms(LooperState next) {
    if (_waveforms.isEmpty) return;
    // A stopped engine reports no tracks at all: those copies go too.
    _waveforms.removeWhere(
      (channel, _) =>
          channel >= next.tracks.length || !next.tracks[channel].hasContent,
    );
  }

  /// Sets the record-offset latency compensation in frames. Remembered and
  /// re-applied on every (re)start (device change / reconnect) so the
  /// compensation survives — a fresh engine start resets it to 0.
  EngineResult setRecordOffset(int frames) {
    _recordOffset = frames < 0 ? 0 : frames;
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setRecordOffset(_recordOffset);
  }

  /// Sets track [channel]'s record timing override (accepted design, Length
  /// & quantize): `null` follows the default ([setRecordTiming]), else the
  /// timing this track's own record and overdub requests wait for — the
  /// engine's per-track quantize gate and division, set together. Remembered
  /// and re-applied on every (re)start.
  ///
  /// Re-projects, because the override is projected from the cache below:
  /// nothing else would tell a surface that it had changed. That matters
  /// beyond the tap that sets it — a session load writes these with no user
  /// gesture to hang a re-read off, and the console's Tracks face would
  /// otherwise go on showing the outgoing session's overrides.
  EngineResult setTrackRecordTiming({
    required int channel,
    required RecordTiming? timing,
    RecordTiming? releasedTiming,
  }) {
    if (channel < 0 || channel >= 8) return EngineResult.invalid;
    final live = Map.of(_trackRecordTiming);
    final durable = Map.of(_timing.restart.overrides);
    if (timing == null) {
      live.remove(channel);
      durable.remove(channel);
    } else {
      live[channel] = timing;
      durable[channel] = releasedTiming ?? timing;
    }
    return _requestTiming(
      _TimingIntent(defaultRecordTiming, _quantizeDiv, live),
      editMask: 2 << channel,
      restart: _TimingIntent(
        _timing.restart.defaultTiming,
        _timing.restart.rememberedDivision,
        durable,
      ),
    );
  }

  /// Sets track [channel]'s overdub decay override in percent (`0..100`;
  /// accepted design, Playback & overdub): `null` follows the default
  /// ([setOverdubDecay]). Live: the engine ramps a change during a pass at
  /// the write head. Remembered and re-applied on every (re)start;
  /// re-projects for the reason [setTrackRecordTiming] does.
  EngineResult setTrackOverdubDecay({
    required int channel,
    required int? percent,
  }) {
    if (channel < 0 || channel >= 8) return EngineResult.invalid;
    final clamped = percent?.clamp(0, 100);
    if (_intendRunning) {
      final result = _engine.setTrackOverdubFeedback(
        channel: channel,
        feedback: clamped == null ? null : feedbackOfDecay(clamped),
      );
      if (!result.isOk) return result;
    }
    if (clamped == null) {
      _trackOverdubDecay.remove(channel);
      _restartTrackOverdubDecay.remove(channel);
    } else {
      _trackOverdubDecay[channel] = clamped;
      _restartTrackOverdubDecay[channel] = clamped;
    }
    _reproject();
    return EngineResult.ok;
  }

  /// The engine's feedback coefficient for a decay in percent: each overdub
  /// pass keeps `1 - percent / 100` of the existing layer.
  static double feedbackOfDecay(int percent) => 1 - percent.clamp(0, 100) / 100;

  /// Cancels track [channel]'s pending record arm, whatever armed it — the
  /// quantized loop-top arm, the signal-triggered one, or a Band section
  /// toggle. A no-op when the track is not armed, and nothing to remember
  /// across a restart (an arm does not survive one).
  ///
  /// The unconditional cancel, NOT [record]: a record press only retires an
  /// arm whose trigger it owns and only while the conditions that created the
  /// arm still hold — parked transport, or quantize since switched off, and
  /// the same press starts a capture instead. Callers that need "nothing may
  /// fire later" (the pedal's FX mode hands over a surface with no transport
  /// controls) must use this.
  EngineResult cancelArm({required int channel}) {
    if (!_intendRunning) return EngineResult.ok;
    return _engine.cancelArm(channel: channel);
  }

  /// Rec Stop retires Count-in, otherwise finishing only a live capture.
  /// The callback resolves the intent without a snapshot-to-toggle race.
  EngineResult stopRecordControl({required int channel}) {
    if (!_intendRunning) return EngineResult.ok;
    return _engine.stopRecordControl(channel: channel);
  }

  /// Retires only Count-in membership/grace, preserving ordinary live work.
  EngineResult cancelCountIn() {
    if (!_intendRunning) return EngineResult.ok;
    return _engine.cancelCountIn();
  }

  /// Finalizes track [channel]'s live non-defining recording take NOW —
  /// [cancelArm]'s counterpart for the LIVE take (#405): the cancel retires
  /// an arm that has not fired, this ends a take already capturing, exactly
  /// as a quantize-off record press would (rounded up to whole base loops,
  /// the tail staying silence — never off-grid) and without touching any
  /// arm machinery.
  ///
  /// The engine refuses for the DEFINING take (ending it would let a mode
  /// switch set the session's bar length mid-gesture) and while a pending
  /// arm is live on the channel; callers treat a refusal as "the capture
  /// survives". Pending Count-in uses [cancelArm]. No [record]-style snapshot
  /// side effects here: the
  /// take is already running, so its record-time lane FX snapshot was pushed
  /// when it started — and nothing to remember across a restart (a live take
  /// does not survive one).
  EngineResult finalizeTake({required int channel}) {
    if (!_intendRunning) return EngineResult.ok;
    return _engine.finalizeTake(channel: channel);
  }

  /// Fixes track [channel]'s loop length to [multiple] base loops (`0` = auto).
  /// Remembered and re-applied on every (re)start.
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    if (multiple <= 0) {
      _trackMultiple.remove(channel);
    } else {
      _trackMultiple[channel] = multiple;
    }
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setTrackMultiple(
      channel: channel,
      multiple: multiple <= 0 ? 0 : multiple,
    );
  }

  /// Replaces lane [lane] of track [channel]'s effect chain with [effects]
  /// (clamped to [kTrackEffectMax]). Remembered and re-applied on every
  /// (re)start. Use this for structural edits (add / remove / reorder / type);
  /// it resets the affected entries' DSP state. For a live parameter tweak use
  /// [setLaneEffectParam], which does not.
  EngineResult setLaneEffects({
    required int channel,
    required int lane,
    required List<TrackEffect> effects,
    bool? chainEnabled,
    bool allowUnavailable = false,
  }) {
    // The repository write boundary mints stable slot ids (A9): any entry
    // arriving without one — a fresh insert, a legacy decode — gets a unique
    // id exactly once; entries that carry one keep it.
    final clamped = _clampAndMint(effects);
    final submitted = _submitFxRecipe(
      owner: FxOwner.lane,
      channel: channel,
      lane: lane,
      effects: clamped,
      enabled: chainEnabled ?? _laneChainEnabled[(channel, lane)] ?? true,
      allowUnavailable: allowUnavailable,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (chainEnabled != null) {
      if (chainEnabled) {
        _laneChainEnabled.remove((channel, lane));
      } else {
        _laneChainEnabled[(channel, lane)] = false;
      }
    }
    if (submitted.effects.isEmpty) {
      _laneEffects.remove((channel, lane));
      // An empty chain is dry — no provenance to keep (the marker described
      // entries that no longer exist).
      _laneChainMeta.remove((channel, lane));
    } else {
      // Provenance follows the entries it describes (A9): when the incoming
      // chain keeps NONE of the previous entries' slot ids — a wholesale
      // replacement, not an edit/reorder (those carry ids through) — the
      // inheritance marker is as stale as on the empty branch and drops too.
      final previous = _laneEffects[(channel, lane)];
      if (previous != null && _laneChainMeta.containsKey((channel, lane))) {
        final kept = {for (final fx in previous) fx.slotId};
        if (!submitted.effects.any((fx) => kept.contains(fx.slotId))) {
          _laneChainMeta.remove((channel, lane));
        }
      }
      _laneEffects[(channel, lane)] = submitted.effects;
    }
    _laneSlots.removeWhere((key, _) => key.$1 == channel && key.$2 == lane);
    for (var i = 0; i < submitted.effects.length; i++) {
      final id = submitted.effects[i].slotId;
      final handle = id == null ? null : submitted.handles[id];
      if (handle != null) _laneSlots[(channel, lane, i)] = handle;
    }
    _reproject();
    // A restored chain whose plugin id wasn't in the (cold-start-empty) scan
    // cache lands here as unavailable — kick the one-shot recovery scan.
    if (_intendRunning) _recoverUnavailablePlugins();
    return submitted.result;
  }

  /// Sets parameter [param] of chain entry [index] on lane [lane] of track
  /// [channel] to [value] (`0..1`) without resetting DSP state. Remembered and
  /// re-applied on (re)start. No-op if [index] is out of range for the
  /// remembered chain.
  EngineResult setLaneEffectParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    final params = List<double>.of(fx.params)..[param] = value;
    if (_intendRunning) {
      final result = _engine.setLaneFxParam(
        channel: channel,
        lane: lane,
        index: index,
        param: param,
        value: value,
      );
      if (!result.isOk) return result;
    }
    // Replace the stored list with a fresh instance rather than mutating it in
    // place: `_project` puts this list into the emitted `LooperState` by
    // reference, so an in-place edit would also mutate the last-emitted state,
    // and the poll's `next == _last` check would then suppress the update.
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    _reproject();
    return EngineResult.ok;
  }

  /// Sets hosted-plugin parameter [paramId] of lane [lane]'s chain entry
  /// [index] to the plain [value], routing it to the loaded plugin through the
  /// RT param queue. The value is remembered on the [PluginEffect] so it
  /// persists and re-applies when the plugin reloads. Returns [EngineResult
  /// .invalid] if the entry is not a plugin, or the running plugin has no live
  /// slot (e.g. its load failed).
  EngineResult setLanePluginParam({
    required int channel,
    required int lane,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    if (_fxTargetPending(FxOwner.lane, channel, lane)) {
      return EngineResult.notReady;
    }
    if (_intendRunning) {
      final handle = _laneSlots[(channel, lane, index)];
      if (handle == null) return EngineResult.invalid;
      final result = _engine.pluginParamSet(handle, paramId, value);
      if (!result.isOk) return result;
    }
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    _reproject();
    return EngineResult.ok;
  }

  /// [fx] pointed at [ref], keeping what still belongs to it.
  ///
  /// Power, placement, channels and slot identity belong to the entry. State
  /// bytes and parameter ids belong to the plugin and cannot be replayed to a
  /// different id.
  static PluginEffect _relinked(PluginEffect fx, PluginRef ref) =>
      fx.ref.id == ref.id
      ? fx.copyWith(ref: ref, unavailable: false)
      : PluginEffect(
          ref: ref,
          enabled: fx.enabled,
          slotId: fx.slotId,
          placement: fx.placement,
          channels: fx.channels,
          rack: fx.rack,
          module: fx.module,
        );

  /// Relinks lane [lane]'s chain entry [index] to plugin [ref] (umbrella
  /// D-MISS), keeping what still belongs to it — see [_relinked] — and
  /// clearing the unavailable flag, then reloads it. Use to resolve a
  /// placeholder (uninstalled/moved) or accept a version change. Returns
  /// [EngineResult.invalid] when the entry is not a plugin.
  EngineResult relinkLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required PluginRef ref,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    final next = List<TrackEffect>.of(effects)..[index] = _relinked(fx, ref);
    return setLaneEffects(channel: channel, lane: lane, effects: next);
  }

  /// Relinks monitor [input]'s chain entry [index] to plugin [ref] (D-MISS),
  /// keeping its state + tweaks. Returns [EngineResult.invalid] when the entry
  /// is not a plugin.
  EngineResult relinkMonitorPlugin({
    required int input,
    required int index,
    required PluginRef ref,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    final next = List<TrackEffect>.of(effects)..[index] = _relinked(fx, ref);
    return setMonitorEffects(input: input, effects: next);
  }

  /// Opens the native editor window for lane [lane]'s plugin chain entry
  /// [index] (umbrella D-WIN). Returns [EngineResult.invalid] when no plugin is
  /// loaded there.
  EngineResult openLanePluginEditor({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginEditorOpen(handle);
  }

  /// Force-closes lane [lane] chain entry [index]'s editor window, then does a
  /// final read-back of its parameters so the editor's last state lands in the
  /// model (D-SYNC; the plugin is the source of truth on conflict).
  EngineResult closeLanePluginEditor({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return EngineResult.invalid;
    final result = _engine.pluginEditorClose(handle);
    refreshLanePluginParams(channel: channel, lane: lane, index: index);
    return result;
  }

  /// Whether lane [lane] chain entry [index]'s plugin editor window is still
  /// open natively — false once the user closes the OS window, so the bloc's
  /// sync poll can self-terminate.
  bool isLanePluginEditorOpen({
    required int channel,
    required int lane,
    required int index,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    return handle != null && _engine.pluginEditorIsOpen(handle);
  }

  /// Reads the live values of lane [lane] chain entry [index]'s user-visible
  /// plugin params back into the model (D-SYNC inbound mirror). Returns whether
  /// anything changed — the bloc's ≤10 Hz editor poll calls this and re-emits
  /// only on a change. A no-op when the entry is not a loaded plugin.
  bool refreshLanePluginParams({
    required int channel,
    required int lane,
    required int index,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) return false;
    final fx = effects[index];
    if (fx is! PluginEffect) return false;
    if (_fxTargetPending(FxOwner.lane, channel, lane)) return false;
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return false;
    final updated = _readBackParams(fx, handle);
    if (updated == null) return false;
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = updated;
    _reproject();
    return true;
  }

  /// Reads every param of [fx] the user can SEE from its loaded [handle];
  /// returns a copy with the changed values, or null if nothing moved. Shared
  /// by the lane and monitor read-back paths.
  ///
  /// Not `isUserVisible` — that is `isAutomatable && !isHidden`, and a
  /// parameter can be shown without being automatable: a mode selector, a
  /// gain-reduction meter. The console draws those (read-only), and a drawn
  /// value that is never read back is frozen at the plugin's default forever
  /// — a live-looking number guaranteed to be wrong, including right after
  /// the user has changed it in the plugin's own window.
  ///
  /// The plugin is the source of truth (D-SYNC), so a value the plugin reports
  /// overwrites the model. One known transient: an in-app knob set is RT-queued
  /// and applies on the next process block, so a poll that ticks in that window
  /// reads the pre-change value and briefly snaps the knob back. Editor and
  /// in-app knobs are rarely driven at once, so this is accepted for now.
  PluginEffect? _readBackParams(PluginEffect fx, PluginSlotHandle handle) {
    final values = Map<int, double>.of(fx.paramValues);
    var changed = false;
    for (final p in fx.params) {
      if (p.isHidden) continue;
      final live = _engine.pluginParamGet(handle, p.id);
      // See [_bindPluginSlot]: a non-finite reading cannot be persisted, and
      // taking one poisons every later write of this chain.
      if (!live.isFinite) continue;
      if (values[p.id] != live) {
        values[p.id] = live;
        changed = true;
      }
    }
    return changed ? fx.copyWith(paramValues: values) : null;
  }

  /// Lane [lane] of track [channel]'s remembered effect chain (empty if none),
  /// in processing order.
  List<TrackEffect> laneEffects(int channel, int lane) =>
      List<TrackEffect>.unmodifiable(_laneEffects[(channel, lane)] ?? const []);

  /// Pushes lane [lane] of track [channel]'s remembered chain to the engine:
  /// each entry's type (which seeds default params), then its parameter values,
  /// then the active count. Called on (re)start and after a structural edit.
  EngineResult _applyLaneEffects(int channel, int lane) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.lane,
      channel: channel,
      lane: lane,
      effects: _laneEffects[(channel, lane)] ?? const [],
      enabled: _laneChainEnabled[(channel, lane)] ?? true,
      allowUnavailable: true,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (submitted.effects.isEmpty) {
      _laneEffects.remove((channel, lane));
    } else {
      _laneEffects[(channel, lane)] = submitted.effects;
    }
    _laneSlots.removeWhere((key, _) => key.$1 == channel && key.$2 == lane);
    for (var i = 0; i < submitted.effects.length; i++) {
      final id = submitted.effects[i].slotId;
      final handle = id == null ? null : submitted.handles[id];
      if (handle != null) _laneSlots[(channel, lane, i)] = handle;
    }
    _reproject();
    return submitted.result;
  }

  /// Reconciles a freshly-loaded plugin [handle] with its chain entry [fx]:
  /// enumerates the plugin's live parameter surface into [PluginEffect.params]
  /// and replays each persisted value in [PluginEffect.paramValues] through the
  /// RT param queue. A `null` handle (load failed / engine stopped) clears the
  /// stale metadata so the card renders the unresolved state.
  PluginEffect _bindPluginSlot(
    PluginSlotHandle? handle,
    PluginEffect fx, {
    bool prepared = false,
  }) {
    if (handle == null) {
      // The plugin failed to load on the running engine — flag the D-MISS
      // placeholder, preserving ref + state for relink (never a silent `none`).
      // A failed load whose id IS in the scan catalog means the plugin is
      // installed but rejected (instrument / multi-bus — D-BUS), as opposed to
      // simply missing; the card shows the right message. On a cold start the
      // catalog is still empty, so this reads as a plain unavailable — which
      // [_recoverUnavailablePlugins] catches, flips to "loading…", and rebinds
      // once its scan lands (F5); clearing `loading` here keeps that transition
      // one-way per apply.
      final installed = _descriptorFor(fx.ref.id) != null;
      return fx.copyWith(
        params: const [],
        unavailable: true,
        unsupported: installed,
        loading: false,
      );
    }
    // Restore the captured opaque state first (D-P1 frozen instance) — a
    // corrupt blob is ignored, never fatal (D-MISS) — then replay the user's
    // param tweaks on top.
    if (fx.state.isNotEmpty) {
      try {
        final result = _engine.pluginStateSet(handle, base64Decode(fx.state));
        if (prepared && !result.isOk) throw _FxPreparationRefused(result);
      } on FormatException {
        // Corrupt blob: leave the plugin at its default state.
      }
    }
    final infos = _enrichParamLabels(
      handle,
      _engine.pluginParamInfos(handle).map(pluginParamInfoFromEngine).toList(),
    );
    // Everything except what the plugin SAYS the host may not set.
    // `paramValues` holds every parameter the console reads back, and
    // replaying one the host does not own writes a stale reading into the
    // plugin's own storage, or overrides with a captured value what the state
    // blob just restored.
    //
    // Stated as what to SKIP rather than what to keep: a plugin can enumerate
    // no parameters at all — a VST3 whose edit controller failed to
    // instantiate, a CLAP with no params extension — and a keep-list built
    // from that is empty, which would silently discard every saved value on
    // each engine start. No flags is no evidence, and no evidence is not a
    // refusal.
    final unwritable = {
      for (final info in infos)
        if (!info.isAutomatable || info.isReadOnly) info.id,
    };
    for (final entry in fx.paramValues.entries) {
      if (unwritable.contains(entry.key)) continue;
      final result = prepared
          ? _engine.preparePluginParam(handle, entry.key, entry.value)
          : _engine.pluginParamSet(handle, entry.key, entry.value);
      if (prepared && !result.isOk) throw _FxPreparationRefused(result);
    }
    // And read back the drawn parameters the replay did NOT write, so a value
    // the console shows is true as of load. The refresh polls run only while
    // the plugin's own window is open — on the appliance, never — so without
    // this a drawn setting is whatever was last persisted, which is not what
    // the plugin is at once its state blob has been restored on top.
    //
    // ONLY the ones not just written. A param set is RT-queued and drained at
    // the next process block, while this read is synchronous and immediate:
    // read one back here and it still answers with its pre-replay value,
    // which would then overwrite the user's saved setting with the plugin's
    // default — and permanently on VST3, whose controller is never told what
    // the host set.
    final values = Map<int, double>.of(fx.paramValues);
    for (final info in infos) {
      if (info.isHidden || !unwritable.contains(info.id)) continue;
      final live = _engine.pluginParamGet(handle, info.id);
      // Finite only. A dB meter reads `-inf` at silence, which is ordinary
      // plugin behaviour and which the hosts pass through unclamped — and
      // `jsonEncode` throws on it, so a chain carrying one could never be
      // persisted again. That throw escapes from inside the bloc's own push,
      // so the failure is not this value: it is every later edit of the chain
      // going unsaved.
      if (live.isFinite) values[info.id] = live;
    }
    final descriptor = _descriptorFor(fx.ref.id);
    // The installed version differs from what the take saved (same id, new
    // version) — the plugin still loaded, but note the drift (D-MISS). Drift is
    // only detectable once the catalog has the descriptor, so a false flag here
    // means "no drift OR not yet scanned", never a hard "versions match".
    final versionDrift =
        descriptor != null &&
        fx.ref.version != 0 &&
        descriptor.version != 0 &&
        descriptor.version != fx.ref.version;
    return fx.copyWith(
      params: infos,
      paramValues: values,
      name: descriptor?.name ?? fx.name,
      unavailable: false,
      unsupported: false,
      versionChanged: versionDrift,
      loading: false,
    );
  }

  /// The scanned descriptor for plugin [id], or null when the catalog hasn't
  /// seen it (not yet scanned, or uninstalled).
  PluginDescriptor? _descriptorFor(String id) {
    // A failed-to-scan descriptor carries an EMPTY id and the offending
    // FILE's name, so an entry whose id decoded to nothing would match one
    // and take a broken bundle's filename as its display name.
    if (id.isEmpty) return null;
    for (final d in pluginCatalog.descriptors) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// A discrete param with more steps than this stays a knob rather than
  /// becoming a dropdown — enumerating every step of, say, a 128-value param
  /// would be a wall of menu items, not a usable control.
  static const int _maxEnumSteps = 24;

  /// Enriches each small discrete param in [infos] with its per-step display
  /// labels (so the UI can render a switch / dropdown), by asking the plugin to
  /// format every step value. A param whose steps don't all resolve to text is
  /// left bare (it falls back to a knob). Continuous params are untouched.
  List<PluginParamInfo> _enrichParamLabels(
    PluginSlotHandle handle,
    List<PluginParamInfo> infos,
  ) => [
    for (final p in infos)
      if (p.stepCount >= 1 && p.stepCount <= _maxEnumSteps)
        _withStepLabels(handle, p)
      else
        p,
  ];

  PluginParamInfo _withStepLabels(PluginSlotHandle handle, PluginParamInfo p) {
    final labels = <String>[];
    for (var k = 0; k <= p.stepCount; k++) {
      final value = p.min + (p.max - p.min) * k / p.stepCount;
      final text = _engine.pluginParamValueText(handle, p.id, value);
      if (text == null || text.isEmpty) return p; // incomplete -> keep the knob
      labels.add(text);
    }
    return p.withValueTexts(labels);
  }

  /// The plugin's own display string for lane [lane] chain entry [index]'s
  /// parameter [paramId] at the plain [value] (e.g. `-6.0 dB`), or null when no
  /// plugin is loaded there or it offers no text. Drives live knob readouts.
  String? lanePluginParamText({
    required int channel,
    required int lane,
    required int index,
    required int paramId,
    required double value,
  }) {
    final handle = _laneSlots[(channel, lane, index)];
    if (handle == null) return null;
    return _engine.pluginParamValueText(handle, paramId, value);
  }

  /// Like [lanePluginParamText] for monitor [input]'s chain entry [index].
  String? monitorPluginParamText({
    required int input,
    required int index,
    required int paramId,
    required double value,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return null;
    return _engine.pluginParamValueText(handle, paramId, value);
  }

  // ---- Track-stage (stereo bus) and output destination chains ----
  //
  // Every stage now submits the same complete recipe; the engine prepares
  // hosted plugins at lane, track, monitor and output targets alike.

  /// Replaces track [channel]'s Track-stage (stereo bus) chain with [effects]
  /// (clamped to [kTrackEffectMax]). Empty == the engine's bit-identical
  /// per-lane routing path. Remembered and re-applied on every (re)start.
  EngineResult setTrackEffects({
    required int channel,
    required List<TrackEffect> effects,
    bool? chainEnabled,
    bool allowUnavailable = false,
  }) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.track,
      channel: channel,
      effects: _clampAndMint(effects),
      enabled: chainEnabled ?? _trackChainEnabled[channel] ?? true,
      allowUnavailable: allowUnavailable,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (chainEnabled != null) {
      if (chainEnabled) {
        _trackChainEnabled.remove(channel);
      } else {
        _trackChainEnabled[channel] = false;
      }
    }
    if (submitted.effects.isEmpty) {
      _trackEffects.remove(channel);
    } else {
      _trackEffects[channel] = submitted.effects;
    }
    _reproject();
    if (_intendRunning) _recoverUnavailablePlugins();
    return submitted.result;
  }

  /// Track [channel]'s remembered Track-stage chain (empty if none), in
  /// processing order.
  List<TrackEffect> trackEffects(int channel) =>
      List<TrackEffect>.unmodifiable(_trackEffects[channel] ?? const []);

  /// Replaces the output destination chain with [effects] (clamped to
  /// [kTrackEffectMax]). Empty == bit-identical output. Remembered and
  /// re-applied on every (re)start.
  EngineResult setOutputEffects({
    required int bus,
    required List<TrackEffect> effects,
    bool? chainEnabled,
    bool allowUnavailable = false,
  }) {
    if (bus < 0 || bus >= kMaxOutputBuses) return EngineResult.invalid;
    // An output chain's stage is fixed after its mix, so the accepted design
    // omits the Pre/Post control here and states that output chains always
    // resolve to Post. Forcing it at the write boundary makes that a stored
    // fact rather than a convention the surfaces have to remember: a chain
    // pasted or restored from a destination that DID carry Pre entries lands
    // wholly Post, and the engine is never told a Pre count it cannot honour.
    final submitted = _submitFxRecipe(
      owner: FxOwner.output,
      channel: bus,
      effects: _clampAndMint([
        for (final fx in effects) _placed(fx, FxPlacement.post),
      ]),
      enabled: chainEnabled ?? outputChainEnabled(bus),
      allowUnavailable: allowUnavailable,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (chainEnabled != null) {
      if (chainEnabled) {
        _outputChainEnabled.remove(bus);
      } else {
        _outputChainEnabled[bus] = false;
      }
    }
    if (submitted.effects.isEmpty) {
      _outputEffects.remove(bus);
    } else {
      _outputEffects[bus] = submitted.effects;
    }
    _reproject();
    if (_intendRunning) _recoverUnavailablePlugins();
    return submitted.result;
  }

  /// The destination chain (empty if none), in processing order.
  List<TrackEffect> outputEffects(int bus) =>
      List<TrackEffect>.unmodifiable(_outputEffects[bus] ?? const []);

  /// Pushes track [channel]'s remembered Track-stage chain to the engine —
  /// the bus twin of [_applyLaneEffects]: each entry's type + params, its
  /// per-slot enabled bit (every slot, every apply — R16), then the count.
  EngineResult _applyTrackEffects(int channel) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.track,
      channel: channel,
      effects: _trackEffects[channel] ?? const [],
      enabled: _trackChainEnabled[channel] ?? true,
      allowUnavailable: true,
    );
    if (submitted.result.isOk) {
      if (submitted.effects.isEmpty) {
        _trackEffects.remove(channel);
      } else {
        _trackEffects[channel] = submitted.effects;
      }
      _reproject();
    }
    return submitted.result;
  }

  /// Sets built-in parameter [param] of entry [index] of track [channel]'s
  /// Track-stage chain — the bus twin of [setLaneEffectParam].
  ///
  /// Granular ON PURPOSE: the whole-chain [setTrackEffects] path re-pushes
  /// every slot's TYPE, and `LE_CMD_SET_TRACK_FX` unconditionally resets that
  /// slot's DSP state on the audio thread. Routing a knob through it would
  /// clear every reverb tail and delay line on the bus at pointer-move rate.
  /// This writes the cached entry and pokes the one parameter, which is a
  /// direct atomic store with no ring command and no reset.
  EngineResult setTrackEffectParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _trackEffects[channel];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    final params = List<double>.of(fx.params)..[param] = value;
    if (_intendRunning) {
      final result = _engine.setTrackFxParam(
        channel: channel,
        index: index,
        param: param,
        value: value,
      );
      if (!result.isOk) return result;
    }
    // A fresh list instance, not an in-place edit — see [setLaneEffectParam].
    _trackEffects[channel] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    _reproject();
    return EngineResult.ok;
  }

  /// Sets hosted-plugin parameter [paramId] of entry [index] of track
  /// [channel]'s Track-stage chain to the plain [value] — the bus twin of
  /// [setLanePluginParam].
  ///
  /// Granular for the same reason as [setTrackEffectParam]: the whole-chain
  /// [setTrackEffects] path re-pushes every slot's TYPE, and
  /// `LE_CMD_SET_TRACK_FX` resets that slot's DSP on the audio thread — so a
  /// plugin knob routed through it would clear the reverb tails and delay
  /// lines of the BUILT-INS sharing the bus, at pointer-move rate.
  ///
  /// Sends the live parameter to the hosted Track-stage instance, then
  /// remembers it only if the engine accepts the value.
  EngineResult setTrackPluginParam({
    required int channel,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _trackEffects[channel];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    if (_intendRunning) {
      final id = fx.slotId;
      final handle = id == null
          ? null
          : _fxSlots[(FxOwner.track, channel, 0)]?[id];
      if (handle == null) return EngineResult.invalid;
      final result = _engine.pluginParamSet(handle, paramId, value);
      if (!result.isOk) return result;
    }
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    // A fresh list instance, not an in-place edit — see [setLaneEffectParam].
    _trackEffects[channel] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    _reproject();
    return EngineResult.ok;
  }

  /// Sets built-in parameter [param] of output destination entry [index] (see
  /// [setTrackEffectParam] for why this is granular).
  EngineResult setOutputEffectParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _outputEffects[bus];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    if (_intendRunning) {
      final result = _engine.setOutputFxParam(
        bus: bus,
        index: index,
        param: param,
        value: value,
      );
      if (!result.isOk) return result;
    }
    final params = List<double>.of(fx.params)..[param] = value;
    _outputEffects[bus] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    _reproject();
    return EngineResult.ok;
  }

  /// Sets hosted-plugin parameter [paramId] of output destination entry [index]
  /// (see [setTrackPluginParam] for why this is granular).
  EngineResult setOutputPluginParam({
    required int bus,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _outputEffects[bus];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    if (_intendRunning) {
      final id = fx.slotId;
      final handle = id == null
          ? null
          : _fxSlots[(FxOwner.output, bus, 0)]?[id];
      if (handle == null) return EngineResult.invalid;
      final result = _engine.pluginParamSet(handle, paramId, value);
      if (!result.isOk) return result;
    }
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    _outputEffects[bus] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    _reproject();
    return EngineResult.ok;
  }

  /// Pushes the remembered output destination chain to the engine (see
  /// [_applyTrackEffects]).
  EngineResult _applyOutputEffects(int bus) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.output,
      channel: bus,
      effects: outputEffects(bus),
      enabled: outputChainEnabled(bus),
      allowUnavailable: true,
    );
    if (submitted.result.isOk) {
      if (submitted.effects.isEmpty) {
        _outputEffects.remove(bus);
      } else {
        _outputEffects[bus] = submitted.effects;
      }
      _reproject();
    }
    return submitted.result;
  }

  /// Replaces the All tracks recorded-mix chain with [effects] (clamped to
  /// [kTrackEffectMax]). Empty == the tracks route straight to their outputs,
  /// bit-identically. Remembered and re-applied on every (re)start.
  ///
  /// Wholly Post, like an output chain: this stage processes a sum computed
  /// live from the tracks, so it has no dry original to print a Pre entry
  /// from.
  EngineResult setAllTracksEffects({
    required List<TrackEffect> effects,
    bool? chainEnabled,
    bool allowUnavailable = false,
  }) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.allTracks,
      effects: _clampAndMint([
        for (final fx in effects) _placed(fx, FxPlacement.post),
      ]),
      enabled: chainEnabled ?? _allTracksChainEnabled,
      allowUnavailable: allowUnavailable,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (chainEnabled != null) _allTracksChainEnabled = chainEnabled;
    _allTracksEffects = submitted.effects;
    if (_intendRunning) _recoverUnavailablePlugins();
    return submitted.result;
  }

  /// The remembered All tracks chain (empty if none), in processing order.
  List<TrackEffect> get allTracksEffects =>
      List<TrackEffect>.unmodifiable(_allTracksEffects);

  /// Whether the All tracks chain is engaged as a whole (R15).
  bool get allTracksChainEnabled => _allTracksChainEnabled;

  /// The All tracks chain as a persisted envelope.
  FxChainEnvelope allTracksChainEnvelope() => FxChainEnvelope(
    chainEnabled: _allTracksChainEnabled,
    entries: _allTracksEffects,
  );

  /// Sets parameter [param] of All tracks chain entry [index] to [value]
  /// (`0..1`) without resetting DSP state.
  EngineResult setAllTracksEffectParam({
    required int index,
    required int param,
    required double value,
  }) {
    if (index < 0 || index >= _allTracksEffects.length) {
      return EngineResult.invalid;
    }
    final fx = _allTracksEffects[index];
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    if (_intendRunning) {
      final result = _engine.setAllTracksFxParam(
        index: index,
        param: param,
        value: value,
      );
      if (!result.isOk) return result;
    }
    final next = List<TrackEffect>.of(_allTracksEffects)
      ..[index] = fx.copyWith(params: [...fx.params]..[param] = value);
    _allTracksEffects = next;
    return EngineResult.ok;
  }

  /// Enables/disables All tracks chain entry [index].
  EngineResult setAllTracksEffectEnabled({
    required int index,
    required bool enabled,
  }) {
    if (index < 0 || index >= _allTracksEffects.length) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setAllTracksFxEnabled(
        index: index,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    _allTracksEffects = List<TrackEffect>.of(_allTracksEffects)
      ..[index] = _withEnabled(_allTracksEffects[index], enabled);
    return EngineResult.ok;
  }

  /// Enables/disables the whole All tracks chain, leaving the per-entry flags
  /// intact.
  EngineResult setAllTracksChainEnabled({required bool enabled}) {
    if (_intendRunning) {
      final result = _engine.setAllTracksFxChainEnabled(enabled: enabled);
      if (!result.isOk) return result;
    }
    _allTracksChainEnabled = enabled;
    return EngineResult.ok;
  }

  /// The All tracks chain's fingerprint, for divergence detection.
  int allTracksFxChainFingerprint() => fxChainFingerprint(
    _allTracksEffects,
    chainEnabled: _allTracksChainEnabled,
  );

  /// Pushes the remembered All tracks chain to the engine — the master twin:
  /// each entry's type + params, the count, then every per-slot enabled bit
  /// (R16 ordering, see [_applyLaneEffects]).
  EngineResult _applyAllTracksEffects() {
    final submitted = _submitFxRecipe(
      owner: FxOwner.allTracks,
      effects: _allTracksEffects,
      enabled: _allTracksChainEnabled,
      allowUnavailable: true,
    );
    if (submitted.result.isOk) _allTracksEffects = submitted.effects;
    return submitted.result;
  }

  /// Sets the channel handling and level of the entry with [slotId] on lane
  /// [lane] of track [channel] (slice 3e).
  ///
  /// By identity, not index, for the same reason the placement setters are:
  /// these are per-instance settings, and an index is what a reorder or a
  /// placement move changes. Returns [EngineResult.invalid] when no entry on
  /// that chain carries [slotId].
  EngineResult setLaneEffectChannels({
    required int channel,
    required int lane,
    required String slotId,
    required FxChannels channels,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null) return EngineResult.invalid;
    final index = effects.indexWhere((fx) => fx.slotId == slotId);
    if (index < 0) return EngineResult.invalid;
    return setLaneEffects(
      channel: channel,
      lane: lane,
      effects: List<TrackEffect>.of(effects)
        ..[index] = _withChannels(effects[index], channels),
    );
  }

  /// Sets the channel handling and level of the entry with [slotId] on
  /// monitor [input]'s chain — see [setLaneEffectChannels].
  EngineResult setMonitorEffectChannels({
    required int input,
    required String slotId,
    required FxChannels channels,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null) return EngineResult.invalid;
    final index = effects.indexWhere((fx) => fx.slotId == slotId);
    if (index < 0) return EngineResult.invalid;
    return setMonitorEffects(
      input: input,
      effects: List<TrackEffect>.of(effects)
        ..[index] = _withChannels(effects[index], channels),
    );
  }

  // ---- per-slot + per-chain enable, all four stages (R15/R16) ----
  //
  // Every setter updates the cache and calls the engine's direct-atomic
  // enable bindings in the same call, so `cache == engine` always holds. The
  // bindings work while stopped (no ring command), so unlike the chain
  // setters these do NOT gate on the engine running — the flag lands
  // immediately and a later (re)start replays it.

  /// Enables/disables entry [index] of lane [lane] of track [channel]'s chain
  /// without losing its type or parameters (click-free ramp engine-side).
  EngineResult setLaneEffectEnabled({
    required int channel,
    required int lane,
    required int index,
    required bool enabled,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setLaneFxEnabled(
        channel: channel,
        lane: lane,
        index: index,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    _laneEffects[(channel, lane)] = List<TrackEffect>.of(effects)
      ..[index] = _withEnabled(effects[index], enabled);
    _reproject();
    return EngineResult.ok;
  }

  // ---- per-instance placement, the three switchable stages (slice 3e) ----
  //
  // Placement rides the ENTRY, not the [FxAddress], so a move preserves every
  // binding that names the instance — bindings persist the address plus the
  // slot id, and neither changes. Each setter names the instance by slot id
  // for the same reason: an index would be the one thing the move invalidates.
  //
  // A live input, a recorded part and a whole track have a switchable
  // placement. An output chain and the All-tracks recorded mix do not: they
  // process every source routed to them, which is not a fixed combination the
  // engine can render, so their stage is fixed after their own mix and their
  // write boundary forces Post.
  //
  // A whole track's Pre run is rendered over the COMBINATION of its parts —
  // each part's own printed material at its level, mute and pan, summed —
  // which the engine can build from originals. It renders only while every
  // part's chain is wholly Pre; a part carrying a Post entry keeps the
  // track's Pre run live, sounding the same, because a render would have to
  // bake that Post entry and a baked tail cannot drain past a Stop.

  /// Moves the entry with [slotId] on lane [lane] of track [channel] to
  /// [placement], to the end of that stage's run, keeping its identity,
  /// parameters, enable state and every binding that names it.
  ///
  /// Returns [EngineResult.invalid] when no entry on that chain carries
  /// [slotId]; a move to the placement the entry already has succeeds and
  /// changes nothing, including the stored order.
  EngineResult setLaneEffectPlacement({
    required int channel,
    required int lane,
    required String slotId,
    required FxPlacement placement,
  }) {
    final effects = _laneEffects[(channel, lane)];
    if (effects == null || !effects.any((fx) => fx.slotId == slotId)) {
      return EngineResult.invalid;
    }
    final moved = _withPlacement(effects, slotId, placement);
    if (identical(moved, effects)) return EngineResult.ok;
    return setLaneEffects(channel: channel, lane: lane, effects: moved);
  }

  /// Moves the entry with [slotId] on track [channel]'s Track-stage chain to
  /// [placement] — see [setLaneEffectPlacement].
  ///
  /// A whole track's Pre run processes the combination of its parts as one
  /// signal, which is what makes it different from putting the same effect on
  /// each part: a compressor or a distortion sounds different on a sum than
  /// on the parts separately.
  EngineResult setTrackEffectPlacement({
    required int channel,
    required String slotId,
    required FxPlacement placement,
  }) {
    final effects = _trackEffects[channel];
    if (effects == null || !effects.any((fx) => fx.slotId == slotId)) {
      return EngineResult.invalid;
    }
    final moved = _withPlacement(effects, slotId, placement);
    if (identical(moved, effects)) return EngineResult.ok;
    return setTrackEffects(channel: channel, effects: moved);
  }

  /// Moves the entry with [slotId] on monitor [input]'s chain to [placement]
  /// — see [setLaneEffectPlacement]. A live input's Pre entries are the ones a
  /// take records; its Post entries are copied onto the lane at record and run
  /// after that take's player.
  EngineResult setMonitorEffectPlacement({
    required int input,
    required String slotId,
    required FxPlacement placement,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || !effects.any((fx) => fx.slotId == slotId)) {
      return EngineResult.invalid;
    }
    final moved = _withPlacement(effects, slotId, placement);
    if (identical(moved, effects)) return EngineResult.ok;
    return setMonitorEffects(input: input, effects: moved);
  }

  /// Enables/disables entry [index] of monitor [input]'s chain. No
  /// `_reproject()`: monitor chains are not part of the projected
  /// [LooperState] (the MonitorCubit owns and emits them).
  EngineResult setMonitorEffectEnabled({
    required int input,
    required int index,
    required bool enabled,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setMonitorInputFxEnabled(
        input: input,
        index: index,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = _withEnabled(effects[index], enabled);
    _monitorChanged(input);
    return EngineResult.ok;
  }

  /// Enables/disables entry [index] of track [channel]'s Track-stage chain.
  EngineResult setTrackEffectEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) {
    final effects = _trackEffects[channel];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setTrackFxEnabled(
        channel: channel,
        index: index,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    _trackEffects[channel] = List<TrackEffect>.of(effects)
      ..[index] = _withEnabled(effects[index], enabled);
    _reproject();
    return EngineResult.ok;
  }

  /// Enables/disables entry [index] of the output destination chain.
  EngineResult setOutputEffectEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) {
    final effects = _outputEffects[bus];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    if (_intendRunning) {
      final result = _engine.setOutputFxEnabled(
        bus: bus,
        index: index,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    _outputEffects[bus] = List<TrackEffect>.of(effects)
      ..[index] = _withEnabled(effects[index], enabled);
    _reproject();
    return EngineResult.ok;
  }

  /// Enables/disables lane [lane] of track [channel]'s WHOLE chain in one
  /// atomic flip without touching the per-entry flags (R15).
  EngineResult setLaneChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) {
    if (_intendRunning) {
      final result = _engine.setLaneFxChainEnabled(
        channel: channel,
        lane: lane,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    if (enabled) {
      _laneChainEnabled.remove((channel, lane)); // absence == enabled
    } else {
      _laneChainEnabled[(channel, lane)] = false;
    }
    _reproject();
    return EngineResult.ok;
  }

  /// Whether lane [lane] of track [channel]'s chain is engaged (remembered
  /// intent; absence == enabled).
  bool laneChainEnabled(int channel, int lane) =>
      _laneChainEnabled[(channel, lane)] ?? true;

  /// Enables/disables monitor [input]'s WHOLE chain in one atomic flip. A
  /// chain-disabled monitor is treated as dry — it also stops being
  /// snapshot-copied onto recording lanes (D-CHAINDIS, R18).
  EngineResult setMonitorChainEnabled({
    required int input,
    required bool enabled,
  }) {
    if (_intendRunning) {
      final result = _engine.setMonitorInputFxChainEnabled(
        input: input,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    if (enabled) {
      _monitorChainEnabled.remove(input);
    } else {
      _monitorChainEnabled[input] = false;
    }
    _monitorChanged(input);
    return EngineResult.ok;
  }

  /// Whether monitor [input]'s chain is engaged (remembered intent).
  bool monitorChainEnabled(int input) => _monitorChainEnabled[input] ?? true;

  /// Enables/disables track [channel]'s WHOLE Track-stage chain. Disabling
  /// yields dry through the bus, NOT a return to per-lane routing (only
  /// emptying the chain does that).
  EngineResult setTrackChainEnabled({
    required int channel,
    required bool enabled,
  }) {
    if (_intendRunning) {
      final result = _engine.setTrackFxChainEnabled(
        channel: channel,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    if (enabled) {
      _trackChainEnabled.remove(channel);
    } else {
      _trackChainEnabled[channel] = false;
    }
    _reproject();
    return EngineResult.ok;
  }

  /// Whether track [channel]'s Track-stage chain is engaged.
  bool trackChainEnabled(int channel) => _trackChainEnabled[channel] ?? true;

  /// Enables/disables the WHOLE output destination chain.
  EngineResult setOutputChainEnabled({
    required int bus,
    required bool enabled,
  }) {
    if (bus < 0 || bus >= kMaxOutputBuses) return EngineResult.invalid;
    if (_intendRunning) {
      final result = _engine.setOutputFxChainEnabled(
        bus: bus,
        enabled: enabled,
      );
      if (!result.isOk) return result;
    }
    if (enabled) {
      _outputChainEnabled.remove(bus);
    } else {
      _outputChainEnabled[bus] = false;
    }
    _reproject();
    return EngineResult.ok;
  }

  /// Whether the output destination chain is engaged.
  bool outputChainEnabled(int bus) => _outputChainEnabled[bus] ?? true;

  /// Sets lane [lane] of track [channel]'s inheritance provenance (R13/A8) —
  /// the boot-restore counterpart of the record-time stamp in
  /// the record-time image, and part 4's detach path (an empty
  /// list clears the marker).
  void setLaneChainMeta({
    required int channel,
    required int lane,
    required List<int> inheritedFrom,
  }) {
    if (inheritedFrom.isEmpty) {
      _laneChainMeta.remove((channel, lane));
    } else {
      _laneChainMeta[(channel, lane)] = List<int>.unmodifiable(inheritedFrom);
    }
    _reproject();
  }

  /// Lane [lane] of track [channel]'s inheritance provenance: the inputs its
  /// chain was copied from at record time, in input order; empty when never
  /// inherited.
  List<int> laneChainInheritedFrom(int channel, int lane) =>
      _laneChainMeta[(channel, lane)] ?? const [];

  /// Flips one entry's enabled flag, dispatching over the sealed hierarchy
  /// (each subtype owns its `copyWith`).
  static TrackEffect _withEnabled(TrackEffect fx, bool enabled) => switch (fx) {
    BuiltInEffect() => fx.copyWith(enabled: enabled),
    PluginEffect() => fx.copyWith(enabled: enabled),
  };

  /// Sets one entry's channel handling, dispatching over the sealed hierarchy.
  static TrackEffect _withChannels(TrackEffect fx, FxChannels channels) =>
      switch (fx) {
        BuiltInEffect() => fx.copyWith(channels: channels),
        PluginEffect() => fx.copyWith(channels: channels),
      };

  /// Sets one entry's placement, dispatching over the sealed hierarchy.
  static TrackEffect _placed(TrackEffect fx, FxPlacement placement) =>
      switch (fx) {
        BuiltInEffect() => fx.copyWith(placement: placement),
        PluginEffect() => fx.copyWith(placement: placement),
      };

  /// The shared write-boundary step of all four chain setters: partitions
  /// [effects] Pre-first, clamps to [kTrackEffectMax] and mints stable slot
  /// ids for any id-less entry, exactly once (A9).
  ///
  /// Partition BEFORE clamp, so an over-long chain loses its trailing Post
  /// entries rather than whichever entries happened to sit last: the engine is
  /// told one boundary index, and a clamp that cut across the partition would
  /// name a Pre count larger than the chain it describes.
  static List<TrackEffect> _clampAndMint(List<TrackEffect> effects) {
    final ordered = partitionByPlacement(effects);
    return withMintedSlotIds(
      ordered.length > kTrackEffectMax
          ? ordered.sublist(0, kTrackEffectMax)
          : ordered,
    );
  }

  /// Prepares a complete chain off the audio thread, then submits one native
  /// command. Remembered state is changed by the caller only after admission.
  ({
    EngineResult result,
    List<TrackEffect> effects,
    Map<String, PluginSlotHandle> handles,
  })
  _submitFxRecipe({
    required FxOwner owner,
    required List<TrackEffect> effects,
    required bool enabled,
    bool allowUnavailable = false,
    int channel = 0,
    int lane = 0,
  }) {
    if (!_intendRunning) {
      return (result: EngineResult.ok, effects: effects, handles: {});
    }
    final key = (owner, channel, lane);
    final pending = _fxPending[key];
    if (pending != null) {
      if (_engine.fxRecipeRevision(
            owner: owner,
            channel: channel,
            lane: lane,
          ) !=
          pending) {
        return (result: EngineResult.notReady, effects: effects, handles: {});
      }
      _fxPending.remove(key);
    }
    final oldHandles = _fxSlots[key] ?? const <String, PluginSlotHandle>{};
    final oldEffects = switch (owner) {
      FxOwner.lane => _laneEffects[(channel, lane)] ?? const <TrackEffect>[],
      FxOwner.track => _trackEffects[channel] ?? const <TrackEffect>[],
      FxOwner.monitor => _monitorEffects[channel] ?? const <TrackEffect>[],
      FxOwner.allTracks => _allTracksEffects,
      FxOwner.output => _outputEffects[channel] ?? const <TrackEffect>[],
    };
    final reusable = {
      for (final fx in oldEffects)
        if (fx is PluginEffect && fx.slotId != null) fx.slotId!: fx,
    };
    final handles = <String, PluginSlotHandle>{};
    final prepared = <PluginSlotHandle>[];
    final loaded = <TrackEffect>[];
    final slots = <FxRecipeSlot>[];
    var refusal = EngineResult.invalid;
    try {
      for (final fx in effects) {
        if (fx is BuiltInEffect) {
          loaded.add(fx);
          slots.add(
            FxRecipeSlot(
              type: trackEffectTypeToEngine(fx.type),
              params: fx.params,
              enabled: fx.enabled,
              channels: fxChannelsToEngine(fx.channels),
            ),
          );
          continue;
        }
        final plugin = fx as PluginEffect;
        if (owner != FxOwner.lane && owner != FxOwner.monitor) {
          // Native hosts plugins only on parts and live inputs. Keep a bus
          // entry as an explicit unsupported placeholder and an inert native
          // slot, so recall never fails the rest of an otherwise valid chain.
          loaded.add(
            plugin.copyWith(
              name: _descriptorFor(plugin.ref.id)?.name ?? plugin.name,
              params: const [],
              unavailable: true,
              unsupported: true,
              loading: false,
            ),
          );
          slots.add(
            FxRecipeSlot(type: trackEffectTypeToEngine(TrackEffectType.none)),
          );
          continue;
        }
        final id = plugin.slotId;
        final previous = id == null ? null : reusable[id];
        final existing =
            previous != null &&
                previous.ref == plugin.ref &&
                previous.state == plugin.state &&
                previous.paramValues.length == plugin.paramValues.length &&
                previous.paramValues.entries.every(
                  (entry) => plugin.paramValues[entry.key] == entry.value,
                )
            ? oldHandles[id]
            : null;
        final handle =
            existing ?? _engine.preparePlugin(pluginId: plugin.ref.id);
        if (handle == null && !allowUnavailable) {
          throw const _FxPreparationRefused(EngineResult.invalid);
        }
        if (handle != null && existing == null) prepared.add(handle);
        final bound = existing != null
            ? plugin
            : _bindPluginSlot(handle, plugin, prepared: handle != null);
        loaded.add(bound);
        if (id != null && handle != null) handles[id] = handle;
        slots.add(
          FxRecipeSlot(
            type: trackEffectTypeToEngine(TrackEffectType.none),
            plugin: handle,
            enabled: plugin.enabled,
            channels: fxChannelsToEngine(plugin.channels),
          ),
        );
      }
      _fxRevision = (_fxRevision + 1) & 0xffffffff;
      if (_fxRevision == 0) _fxRevision = 1;
      refusal = _engine.setFxRecipe(
        owner: owner,
        channel: channel,
        lane: lane,
        recipe: FxRecipe(
          slots: slots,
          // The live monitor processes its whole chain before capture. Its
          // Pre/Post split is metadata for the inherited recording recipe.
          preCount: owner == FxOwner.monitor ? 0 : fxPreCount(effects),
          enabled: enabled,
        ),
        revision: _fxRevision,
      );
      if (refusal.isOk) {
        _fxPending[key] = _fxRevision;
        _fxSlots[key] = handles;
        return (result: refusal, effects: loaded, handles: handles);
      }
    } on _FxPreparationRefused catch (failure) {
      refusal = failure.result;
    } finally {
      if (!refusal.isOk) {
        prepared.forEach(_engine.discardPreparedPlugin);
      }
    }
    return (result: refusal, effects: effects, handles: {});
  }

  /// Returns [effects] with the entry whose [TrackEffect.slotId] is [slotId]
  /// moved to [placement], or [effects] unchanged when no entry carries that
  /// id or it is already there.
  ///
  /// The accepted design: an explicit placement change "moves that instance to
  /// the end of the destination stage and preserves its identity, parameters,
  /// channels, enable state and pedal assignment". Removing the entry and
  /// appending it is exactly that — [_clampAndMint]'s stable partition puts
  /// the re-placed entry last within its new stage, and the id rides the entry
  /// so every binding that names it still resolves.
  static List<TrackEffect> _withPlacement(
    List<TrackEffect> effects,
    String slotId,
    FxPlacement placement,
  ) {
    final index = effects.indexWhere((fx) => fx.slotId == slotId);
    if (index < 0 || effects[index].placement == placement) return effects;
    final fx = effects[index];
    final moved = switch (fx) {
      BuiltInEffect() => fx.copyWith(placement: placement),
      PluginEffect() => fx.copyWith(placement: placement),
    };
    return [
      for (var i = 0; i < effects.length; i++)
        if (i != index) effects[i],
      moved,
    ];
  }

  /// Replaces monitor [input]'s effect chain with [effects] (clamped to
  /// [kTrackEffectMax]). An empty chain is the clean (dry) path. Remembered and
  /// re-applied on every (re)start; this is the chain snapshot-copied onto a
  /// lane on record. A structural edit resets the affected entries' DSP state.
  /// For a live parameter tweak use [setMonitorEffectParam].
  EngineResult setMonitorEffects({
    required int input,
    required List<TrackEffect> effects,
    bool? chainEnabled,
    bool allowUnavailable = false,
  }) {
    // Repository write boundary: mint slot ids exactly once (A9), same as
    // [setLaneEffects].
    final clamped = _clampAndMint(effects);
    final submitted = _submitFxRecipe(
      owner: FxOwner.monitor,
      channel: input,
      effects: clamped,
      enabled: chainEnabled ?? _monitorChainEnabled[input] ?? true,
      allowUnavailable: allowUnavailable,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (chainEnabled != null) {
      if (chainEnabled) {
        _monitorChainEnabled.remove(input);
      } else {
        _monitorChainEnabled[input] = false;
      }
    }
    if (submitted.effects.isEmpty) {
      _monitorEffects.remove(input);
    } else {
      _monitorEffects[input] = submitted.effects;
    }
    _monitorSlots.removeWhere((key, _) => key.$1 == input);
    for (var i = 0; i < submitted.effects.length; i++) {
      final id = submitted.effects[i].slotId;
      final handle = id == null ? null : submitted.handles[id];
      if (handle != null) _monitorSlots[(input, i)] = handle;
    }
    _monitorChanged(input);
    // Same cold-start recovery as setLaneEffects: a restored monitor chain
    // whose plugin wasn't yet scanned lands unavailable — rescan and rebind.
    if (_intendRunning) _recoverUnavailablePlugins();
    return submitted.result;
  }

  /// Sets parameter [param] of monitor [input]'s chain entry [index] to [value]
  /// (`0..1`) without resetting DSP state. Remembered and re-applied on
  /// (re)start. No-op if [index] is out of range for the remembered chain.
  EngineResult setMonitorEffectParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return EngineResult.invalid;
    if (param < 0 || param >= fx.params.length) return EngineResult.invalid;
    if (_intendRunning) {
      final result = _engine.setMonitorInputFxParam(
        input: input,
        index: index,
        param: param,
        value: value,
      );
      if (!result.isOk) return result;
    }
    final params = List<double>.of(fx.params)..[param] = value;
    // Replace with a fresh list rather than mutating in place — the same
    // invariant as `setLaneEffectParam`. No `_reproject()` here: monitor
    // chains are not part of the projected `LooperState` (the MonitorCubit
    // owns them and emits optimistically), so there is nothing to re-emit.
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(params: params);
    // The throttled param announce, not [_monitorChanged]: this is the write
    // that arrives at controller rate, and the structural stream's listeners
    // persist what they read (#605).
    _monitorParamChanged(input);
    return EngineResult.ok;
  }

  /// Sets hosted-plugin parameter [paramId] of monitor [input]'s chain entry
  /// [index] to the plain [value], routing it through the RT param queue and
  /// remembering it on the [PluginEffect]. No `_reproject()`: monitor chains
  /// are not part of the projected `LooperState`. Returns
  /// [EngineResult.invalid] if the entry is not a plugin, or its slot is gone.
  EngineResult setMonitorPluginParam({
    required int input,
    required int index,
    required int paramId,
    required double value,
  }) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) {
      return EngineResult.invalid;
    }
    final fx = effects[index];
    if (fx is! PluginEffect) return EngineResult.invalid;
    if (_fxTargetPending(FxOwner.monitor, input, 0)) {
      return EngineResult.notReady;
    }
    if (_intendRunning) {
      final handle = _monitorSlots[(input, index)];
      if (handle == null) return EngineResult.invalid;
      final result = _engine.pluginParamSet(handle, paramId, value);
      if (!result.isOk) return result;
    }
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    _monitorEffects[input] = List<TrackEffect>.of(effects)
      ..[index] = fx.copyWith(paramValues: values);
    return EngineResult.ok;
  }

  /// Opens the native editor window for monitor [input]'s plugin chain entry
  /// [index] (D-WIN). Returns [EngineResult.invalid] when no plugin is loaded.
  EngineResult openMonitorPluginEditor({
    required int input,
    required int index,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return EngineResult.invalid;
    return _engine.pluginEditorOpen(handle);
  }

  /// Force-closes monitor [input] chain entry [index]'s editor, then reads back
  /// its params so the editor's final state lands in the model (D-SYNC).
  EngineResult closeMonitorPluginEditor({
    required int input,
    required int index,
  }) {
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return EngineResult.invalid;
    final result = _engine.pluginEditorClose(handle);
    refreshMonitorPluginParams(input: input, index: index);
    return result;
  }

  /// Whether monitor [input] chain entry [index]'s plugin editor window is
  /// still open natively (false once the user closes the OS window).
  bool isMonitorPluginEditorOpen({required int input, required int index}) {
    final handle = _monitorSlots[(input, index)];
    return handle != null && _engine.pluginEditorIsOpen(handle);
  }

  /// Reads monitor [input] chain entry [index]'s live plugin param values back
  /// into the model (D-SYNC). Returns whether anything changed. Monitor chains
  /// are not projected, so no `_reproject()` — the MonitorCubit re-reads
  /// [monitorEffects] to emit.
  bool refreshMonitorPluginParams({required int input, required int index}) {
    final effects = _monitorEffects[input];
    if (effects == null || index < 0 || index >= effects.length) return false;
    final fx = effects[index];
    if (fx is! PluginEffect) return false;
    if (_fxTargetPending(FxOwner.monitor, input, 0)) return false;
    final handle = _monitorSlots[(input, index)];
    if (handle == null) return false;
    final updated = _readBackParams(fx, handle);
    if (updated == null) return false;
    _monitorEffects[input] = List<TrackEffect>.of(effects)..[index] = updated;
    return true;
  }

  /// Monitor [input]'s remembered effect chain (empty if none), in processing
  /// order.
  List<TrackEffect> monitorEffects(int input) =>
      List<TrackEffect>.unmodifiable(_monitorEffects[input] ?? const []);

  /// Pushes monitor [input]'s remembered chain to the engine: each entry's type
  /// (which seeds default params), then its parameter values, then the active
  /// count. Called on (re)start and after a structural edit.
  EngineResult _applyMonitorEffects(int input) {
    final submitted = _submitFxRecipe(
      owner: FxOwner.monitor,
      channel: input,
      effects: _monitorEffects[input] ?? const [],
      enabled: _monitorChainEnabled[input] ?? true,
      allowUnavailable: true,
    );
    if (!submitted.result.isOk) return submitted.result;
    if (submitted.effects.isEmpty) {
      _monitorEffects.remove(input);
    } else {
      _monitorEffects[input] = submitted.effects;
    }
    _monitorSlots.removeWhere((key, _) => key.$1 == input);
    for (var i = 0; i < submitted.effects.length; i++) {
      final id = submitted.effects[i].slotId;
      final handle = id == null ? null : submitted.handles[id];
      if (handle != null) _monitorSlots[(input, i)] = handle;
    }
    _monitorChanged(input);
    return submitted.result;
  }

  /// Sets the global default loop length for inheriting tracks (`0` = auto).
  /// Remembered and re-applied on every (re)start.
  EngineResult setDefaultMultiple({required int multiple}) {
    if (_intendRunning) {
      final result = _engine.setDefaultMultiple(
        multiple: multiple < 0 ? 0 : multiple,
      );
      if (!result.isOk) return result;
    }
    _defaultMultiple = multiple < 0 ? 0 : multiple;
    _reproject();
    return EngineResult.ok;
  }

  /// Sets the global rec/dub second-press mode. Remembered and re-applied on
  /// every (re)start.
  EngineResult setRecDub({required bool enabled}) {
    if (_intendRunning) {
      final result = _engine.setRecDub(enabled: enabled);
      if (!result.isOk) return result;
    }
    _recDub = enabled;
    // Projected as `TransportState.recDub`: the queued take-end cue reads it,
    // so it lands on the next frame, not the next poll.
    _reproject();
    return EngineResult.ok;
  }

  /// The current desired master gain, retained across engine restarts.
  double get masterGain => _masterGain;

  /// Sets the global master output gain (`0..1`, clamped by the engine).
  /// Remembered and re-applied on every (re)start so it survives device changes
  /// and reconnects.
  EngineResult setMasterGain(double gain) {
    _masterGain = gain.clamp(0.0, 1.0);
    if (!_intendRunning) return EngineResult.ok;
    return _engine.setMasterGain(_masterGain);
  }

  /// Whether the master peak limiter is engaged.
  ///
  /// The engine's limiter surface is write-only (no snapshot read-back), so
  /// this cached copy of what the repository last pushed is the only truth a
  /// caller can read — a performance-capture arm records it into the arm
  /// snapshot, since the engine cannot report it. There is no setter yet:
  /// nothing writes the limiter, so this reads the safety default the engine
  /// is started with on every (re)start.
  bool get limiterEnabled => _limiterEnabled;

  /// The master peak limiter's ceiling (`0..1`), meaningful only while
  /// [limiterEnabled]. Cached for the same write-only reason.
  double get limiterCeiling => _limiterCeiling;

  /// Sets the default record timing (accepted design, Length & quantize):
  /// the engine's quantize gate and musical division, set together. Tracks
  /// follow it unless they carry an override ([setTrackRecordTiming]).
  /// Remembered and re-applied on every (re)start; re-projects so the
  /// published default moves with the call.
  EngineResult setRecordTiming(
    RecordTiming timing, {
    RecordTiming? releasedTiming,
  }) {
    final remembered = timing.quantize
        ? timing.division
        : _timing.restart.rememberedDivision;
    final durable = releasedTiming ?? timing;
    final durableDivision = durable.quantize
        ? durable.division
        : _timing.restart.rememberedDivision;
    return _requestTiming(
      _TimingIntent(timing, remembered, _trackRecordTiming),
      editMask: 1,
      restart: _TimingIntent(
        durable,
        durableDivision,
        _timing.restart.overrides,
      ),
    );
  }

  /// Sets the default overdub decay in percent (`0..100`; accepted design,
  /// Playback & overdub). Tracks follow it unless they carry an override
  /// ([setTrackOverdubDecay]). Remembered and re-applied on every (re)start;
  /// re-projects so the published default moves with the call.
  EngineResult setOverdubDecay(int percent) {
    if (_intendRunning) {
      final result = _engine.setOverdubFeedback(feedbackOfDecay(percent));
      if (!result.isOk) return result;
    }
    _overdubDecay = percent.clamp(0, 100);
    _restartOverdubDecay = _overdubDecay;
    _reproject();
    return EngineResult.ok;
  }

  // ---- tempo grid (A1) + click/count-in (A2) passthroughs ----
  //
  // Every setter below remembers its value (mirroring [setRecordTiming] /
  // [setMasterGain] above) so [startEngine] can re-apply it on every (re)start
  // — a fresh start resets the engine's tempo grid to the tempo-free defaults.
  // Takes effect immediately only while running, like every other remembered
  // setter in this file; while stopped the call still reports
  // [EngineResult.ok] and is applied on the next start.

  /// Sets the tempo in denominator-note beats per minute. Accepted edits are
  /// remembered for restart; the live engine owns any timing-lock decision.
  EngineResult setTempo(double bpm) {
    if (_intendRunning) {
      final result = _engine.setTempo(bpm);
      if (!result.isOk) return result;
    }
    _tempoBpm = bpm;
    _tempoSource = TempoSource.manual;
    _reproject();
    return EngineResult.ok;
  }

  /// Sets the time signature to [num]/[den] (only the 17 Sheeran-verified
  /// signatures are valid — the engine rejects anything else without
  /// applying). Remembered and re-applied on every (re)start. Ignored by the
  /// engine while the tempo is locked.
  EngineResult setTimeSignature(int num, int den) {
    if (_intendRunning) {
      final result = _engine.setTimeSignature(num, den);
      if (!result.isOk) return result;
    }
    _tsNum = num;
    _tsDen = den;
    _reproject();
    return EngineResult.ok;
  }

  /// Registers a tempo tap. The engine owns its resulting BPM and source;
  /// settled session capture and device stop retain those values.
  EngineResult tapTempo() => _engine.tapTempo();

  /// Enables/disables loop↔grid sync (default on). Remembered and re-applied
  /// on every (re)start.
  EngineResult setSyncTempo({required bool on}) {
    if (_intendRunning) {
      final result = _engine.setSyncTempo(on: on);
      if (!result.isOk) return result;
    }
    _syncTempo = on;
    _reproject();
    return EngineResult.ok;
  }

  /// Last accepted live pair, including temporary controller intent.
  ({int countInBars, bool soundStart}) get recordStartSettings =>
      _recordStart.live;

  /// Accepted Released pair for session capture and device restart.
  ({int countInBars, bool soundStart}) get recordStartRestartIntent =>
      _recordStart.restart;

  /// Whether a pair command is awaiting its callback receipt.
  bool get recordStartSettingsSettled => _recordStart.settled;

  /// An uncertain receipt owes its Released pair until Retry or restart.
  bool get recordStartRecoveryRequired => _recordStart.recoveryRequired;

  /// Actual capture locks future start settings; waiting arms remain editable.
  bool get recordStartCaptureLocked => captureLocked;

  /// Pair refusals and autonomous restart uncertainty.
  Stream<EngineResult> get recordStartSettingsFailures => _recordStart.failures;

  /// Empty Sound-start target needing a real selected recording input.
  Stream<int> get recordingInputRequired => _recordingInputRequired.stream;

  /// Fresh-capture Record presses the engine refused twice (the channel): the
  /// press is lost and the player should press again. Low stakes, so a toast.
  Stream<int> get recordRefusals => _recordRefusals.stream;

  /// Record presses on a reversed track (the channel): overdub is
  /// unavailable while a track plays reversed, from any surface.
  Stream<int> get overdubRefusals => _overdubRefusals.stream;

  /// Whether a Record press on [channel] the engine refused is still waiting
  /// for its one retry — the press counts as accepted until it resolves.
  bool recordRetryPending(int channel) => _recordRetry?.channel == channel;

  /// Runs the one retry a refused fresh-capture press is owed, once every
  /// command posted before it has published (`commandsSettled`: the emptying
  /// that caused the refusal was posted earlier, so settled implies its block
  /// completed — a frame advance alone can be one block short when the buffer
  /// period exceeds the poll), or after [_recordRetryPollLimit] polls without
  /// settlement. A track that is no longer a fresh target (a later press
  /// landed, a redo) supersedes the press silently; a second refusal is
  /// reported.
  void _retryRefusedRecord(EngineSnapshot snapshot) {
    final retry = _recordRetry;
    if (retry == null) return;
    if (!_engine.commandsSettled && ++retry.polls < _recordRetryPollLimit) {
      return;
    }
    _recordRetry = null;
    final track = retry.channel < snapshot.tracks.length
        ? snapshot.tracks[retry.channel]
        : null;
    if (track == null ||
        track.state != TrackState.empty ||
        track.pending ||
        track.pendingLaunch != null ||
        track.countInCancelGrace) {
      return;
    }
    _retryingRecord = true;
    _retrySuperseded = false;
    EngineResult result;
    try {
      result = record(channel: retry.channel);
    } finally {
      _retryingRecord = false;
    }
    if (!result.isOk && !_retrySuperseded && !_recordRefusals.isClosed) {
      _recordRefusals.add(retry.channel);
    }
  }

  static const _recordRetryPollLimit = 4;

  /// Stages a stopped pair or requests one callback-confirmed atomic edit.
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
    ({int countInBars, bool soundStart})? releasedSettings,
  }) {
    if (!const [0, 1, 2, 4].contains(countInBars) ||
        countInBars > 0 && soundStart ||
        releasedSettings != null &&
            (!const [0, 1, 2, 4].contains(releasedSettings.countInBars) ||
                releasedSettings.countInBars > 0 &&
                    releasedSettings.soundStart)) {
      return EngineResult.invalid;
    }
    _recordStartEdit = editKind;
    final result = _recordStart.request(
      (countInBars: countInBars, soundStart: soundStart),
      restart: releasedSettings,
    );
    _recordStartEdit = RecordStartEditKind.restore;
    _reproject();
    return result.isOk && _recordStart.settled
        ? _recordStart.lastResult
        : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendRecordStart(
    ({int countInBars, bool soundStart}) settings,
  ) {
    if (recordStartCaptureLocked) {
      return (result: EngineResult.invalid, check: null);
    }
    final prior = _engine.snapshot();
    final result = _engine.setRecordStartSettings(
      countInBars: settings.countInBars,
      soundStart: settings.soundStart,
      editKind: _recordStartEdit,
    );
    final expected = (prior.recordStartRevision + 1) & 0xffffffff;
    final before = (
      countInBars: prior.countInBars,
      soundStart: prior.autoRecord,
    );
    return (
      result: result,
      // Acquire the callback boundary before reading the scalar receipt.
      check: () {
        if (!_engine.commandsSettled) return null;
        final snapshot = _engine.snapshot();
        if (snapshot.recordStartRevision != expected) return null;
        final actual = (
          countInBars: snapshot.countInBars,
          soundStart: snapshot.autoRecord,
        );
        final result = EngineResult.fromCode(snapshot.recordStartResult);
        if (result.isOk && actual == settings) {
          return (verdict: ReceiptVerdict.accepted, result: result);
        }
        if (!result.isOk && actual == before) {
          return (verdict: ReceiptVerdict.refused, result: result);
        }
        return (verdict: ReceiptVerdict.uncertain, result: result);
      },
    );
  }

  /// Bounded exact receipt/readback settlement, also observed autonomously.
  Future<EngineResult> settleRecordStartSettings({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _recordStart.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed pair while running and stages it stopped.
  EngineResult recoverRecordStartSettings() {
    final result = _recordStart.recover();
    _reproject();
    return result;
  }

  /// Accepted Released choice used on a device restart.
  ClickMode get clickModeRestartIntent => _clickMode.restart;

  /// No Hear click request is awaiting its callback receipt.
  bool get clickModeSettled => _clickMode.settled;

  /// An uncertain receipt owes its Released choice until Retry or restart.
  bool get clickModeRecoveryRequired => _clickMode.recoveryRequired;

  /// Capture locks Hear click; see [captureLocked].
  bool get clickModeCaptureLocked => captureLocked;

  /// Refusals/uncertainty from explicit edits and autonomous replay.
  Stream<EngineResult> get clickModeFailures => _clickMode.failures;

  /// Stages or enqueues Hear click, with separate durable Released intent.
  EngineResult setClickMode(ClickMode mode, {ClickMode? releasedMode}) {
    final result = _clickMode.request(mode, restart: releasedMode);
    _reproject();
    return result.isOk && _clickMode.settled ? _clickMode.lastResult : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendClickMode(
    ClickMode mode,
  ) {
    if (clickModeCaptureLocked) {
      return (result: EngineResult.invalid, check: null);
    }
    final prior = _engine.snapshot();
    final result = _engine.setClickMode(mode);
    final expected = (prior.clickModeRevision + 1) & 0xffffffff;
    return (
      result: result,
      // Acquire BEFORE sampling: the revision fence names this exact command.
      check: () {
        if (!_engine.commandsSettled) return null;
        final snapshot = _engine.snapshot();
        if (snapshot.clickModeRevision != expected) return null;
        final result = EngineResult.fromCode(snapshot.clickModeResult);
        if (result.isOk && snapshot.clickMode == mode) {
          return (verdict: ReceiptVerdict.accepted, result: result);
        }
        if (!result.isOk && snapshot.clickMode == prior.clickMode) {
          return (verdict: ReceiptVerdict.refused, result: result);
        }
        return (verdict: ReceiptVerdict.uncertain, result: result);
      },
    );
  }

  /// Bounded exact revision/result/actual-mode confirmation.
  Future<EngineResult> settleClickMode({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _clickMode.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed choice while running and stages it stopped.
  EngineResult recoverClickMode() {
    final result = _clickMode.recover();
    _reproject();
    return result;
  }

  /// Routes the click to the output channels set in [mask]. Remembered and
  /// re-applied on every (re)start.
  EngineResult setClickOutput(int mask) {
    if (_intendRunning) {
      final result = _engine.setClickOutput(mask);
      if (!result.isOk) return result;
    }
    _clickMask = mask;
    _reproject();
    return EngineResult.ok;
  }

  /// Admits a Click gain edit. Running edits publish only after the callback;
  /// callers must await [settleClickVolume] before treating them as accepted.
  EngineResult setClickVolume(double volume, {double? releasedVolume}) {
    final restartVolume = releasedVolume ?? volume;
    if (!_validClickGain(volume) || !_validClickGain(restartVolume)) {
      return EngineResult.invalid;
    }
    final result = _clickVolume.request(volume, restart: releasedVolume);
    _reproject();
    return result.isOk && _clickVolume.settled
        ? _clickVolume.lastResult
        : result;
  }

  static bool _validClickGain(double gain) =>
      gain.isFinite && gain >= 0 && gain <= kMaxClickGain;

  ({EngineResult result, ReceiptCheck? check}) _sendClickVolume(
    double volume,
  ) => (
    result: _engine.setClickVolume(volume),
    // A drained queue publishing another gain did not accept this write.
    check: () {
      if (!_engine.commandsSettled) return null;
      final actual = _engine.snapshot().clickVolume;
      return actual.isFinite && (actual - volume).abs() <= 1e-6
          ? (verdict: ReceiptVerdict.accepted, result: EngineResult.ok)
          : (verdict: ReceiptVerdict.uncertain, result: EngineResult.invalid);
    },
  );

  /// Accepted Released gain used on a device restart.
  double get clickVolumeRestartIntent => _clickVolume.restart;

  /// No Click gain command is awaiting its callback receipt.
  bool get clickVolumeSettled => _clickVolume.settled;

  /// An uncertain receipt owes its Released gain until Retry or restart.
  bool get clickVolumeRecoveryRequired => _clickVolume.recoveryRequired;

  /// Refusals/uncertainty from explicit edits and autonomous replay.
  Stream<EngineResult> get clickVolumeFailures => _clickVolume.failures;

  /// Awaits command publication and actual gain readback, independently of UI
  /// polling.
  Future<EngineResult> settleClickVolume({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _clickVolume.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed gain while running and stages it stopped.
  EngineResult recoverClickVolume() {
    final result = _clickVolume.recover();
    _reproject();
    return result;
  }

  /// Sets one future-recording length override. Null inherits the default;
  /// zero is explicit Auto. Multi retains the override for independent modes.
  /// Existing audio is not resized. Refusal leaves the override unchanged.
  EngineResult setTrackLengthPreset({
    required int channel,
    required int? bars,
    int? releasedBars,
  }) {
    if (channel < 0 ||
        channel >= 8 ||
        (bars != null && (bars < 0 || bars > 64)) ||
        (releasedBars != null && (releasedBars < 0 || releasedBars > 64)) ||
        (_intendRunning && channel >= _engine.snapshot().tracks.length)) {
      return EngineResult.invalid;
    }
    final overrides = Map.of(_trackLengthPreset);
    final durable = Map.of(_length.restart.overrides);
    if (bars == null) {
      overrides.remove(channel);
      durable.remove(channel);
    } else {
      overrides[channel] = bars;
      durable[channel] = releasedBars ?? bars;
    }
    return _requestLengthSettings(
      defaultBars: _defaultLengthPreset,
      overrides: overrides,
      mode: _looperMode,
      restart: _LengthIntent(_length.restart.defaultBars, durable, _looperMode),
    );
  }

  /// A complete length vector; nullable membership was validated before
  /// admission and explicit Auto remains stored. A [mode] switches the looper
  /// mode in the same command. [released] is the durable vector when this one
  /// is temporary.
  EngineResult setLengthSettings({
    required int defaultBars,
    required Map<int, int> overrides,
    LooperMode? mode,
    ({int defaultBars, Map<int, int> trackOverrides, LooperMode mode})?
    released,
  }) {
    bool invalid(int bars, Map<int, int> custom) =>
        bars < 0 ||
        bars > 64 ||
        custom.entries.any(
          (e) => e.key < 0 || e.key >= 8 || e.value < 0 || e.value > 64,
        );
    if (invalid(defaultBars, overrides) ||
        (released != null &&
            invalid(released.defaultBars, released.trackOverrides))) {
      return EngineResult.invalid;
    }
    return _requestLengthSettings(
      defaultBars: defaultBars,
      overrides: overrides,
      mode: mode ?? _looperMode,
      changeMode: mode != null,
      restart: released == null
          ? null
          : _LengthIntent(
              released.defaultBars,
              released.trackOverrides,
              released.mode,
            ),
    );
  }

  /// Sets the default live preset and its optional durable Released value.
  EngineResult setDefaultLengthPreset(int bars, {int? releasedBars}) {
    if (bars < 0 ||
        bars > 64 ||
        (releasedBars != null && (releasedBars < 0 || releasedBars > 64))) {
      return EngineResult.invalid;
    }
    return _requestLengthSettings(
      defaultBars: bars,
      overrides: Map.of(_trackLengthPreset),
      mode: _looperMode,
      restart: _LengthIntent(
        releasedBars ?? bars,
        _length.restart.overrides,
        _looperMode,
      ),
    );
  }

  /// The confirmed mode, unavailable while a coupled vector is pending.
  LooperMode? get settledLooperMode =>
      !_intendRunning || _length.settled ? _looperMode : null;

  /// Mode and latent track retirement land in the same native transaction.
  EngineResult setLooperMode(
    LooperMode mode, {
    Map<int, int>? trackOverrides,
  }) {
    if (trackOverrides != null &&
        trackOverrides.entries.any(
          (entry) =>
              entry.key < 0 ||
              entry.key >= 8 ||
              entry.value < 0 ||
              entry.value > 64,
        )) {
      return EngineResult.invalid;
    }
    return _requestLengthSettings(
      defaultBars: _defaultLengthPreset,
      overrides: trackOverrides ?? Map.of(_trackLengthPreset),
      mode: mode,
      changeMode: true,
      restart: _LengthIntent(
        _length.restart.defaultBars,
        trackOverrides ?? _length.restart.overrides,
        mode,
      ),
    );
  }

  /// Outside a pending or owed transaction the published mode owns the live
  /// rig.
  void _rememberLooperMode(LooperState next, LooperMode reported) {
    if (!_intendRunning ||
        !next.status.isConnected ||
        !_length.settled ||
        _length.recoveryRequired ||
        (_length.live.mode == reported && _length.restart.mode == reported)) {
      return;
    }
    _length.adopt(
      _length.live.withMode(reported),
      restart: _length.restart.withMode(reported),
    );
  }

  /// What [setLooperMode] would do with [mode] right now (accepted design,
  /// slice 2): open, or the reason it is refused, or `playing` — the answer a
  /// "stop loops and switch" confirmation stands for. A stopped engine holds
  /// no takes to measure, so every change is open.
  LooperModeGate looperModeGate(LooperMode mode) =>
      _intendRunning ? _engine.looperModeGate(mode) : LooperModeGate.open;

  /// Crowns [channel] the primary track — the explicit timing handoff (D18).
  /// Held until the next start when the engine is not running (see
  /// [_pendingCrown]). There is no "un-crown" call: the engine crowns the
  /// first completed take by itself and clears the crown when the session
  /// empties, so moving it explicitly means crowning a different channel.
  EngineResult crownPrimary({required int channel}) {
    if (!_intendRunning) {
      _pendingCrown = channel;
      return EngineResult.ok;
    }
    _pendingCrown = null;
    return _engine.crownPrimary(channel: channel);
  }

  /// Stages a stopped vector or requests one callback-confirmed vector, with
  /// an optional Released vector for restart. Every request sends the whole
  /// vector and confirms all eight slots.
  EngineResult setOneShotSnapshot({
    required bool defaultOneShot,
    required Map<int, bool> trackOverrides,
    ({bool defaultOneShot, Map<int, bool> trackOverrides})? released,
  }) {
    if (trackOverrides.keys.any((c) => c < 0 || c >= 8) ||
        (released?.trackOverrides.keys.any((c) => c < 0 || c >= 8) ?? false)) {
      return EngineResult.invalid;
    }
    final result = _oneShot.request(
      _OneShotIntent(trackOverrides, defaultValue: defaultOneShot),
      restart: released == null
          ? null
          : _OneShotIntent(
              released.trackOverrides,
              defaultValue: released.defaultOneShot,
            ),
    );
    _reproject();
    return result.isOk && _oneShot.settled ? _oneShot.lastResult : result;
  }

  ({EngineResult result, ReceiptCheck? check}) _sendOneShot(
    _OneShotIntent intent,
  ) {
    var admitted = false;
    for (final choice in [false, true]) {
      var mask = 0;
      for (var c = 0; c < 8; c++) {
        if (intent.effective(c) == choice) mask |= 1 << c;
      }
      if (mask == 0) continue;
      final result = _engine.setOneShotMask(channels: mask, oneShot: choice);
      if (!result.isOk) {
        // A refusal after the first group was admitted leaves the vector
        // half-applied: the receipt owes it rather than reporting a refusal.
        return admitted
            ? (
                result: EngineResult.ok,
                check: () => (
                  verdict: ReceiptVerdict.uncertain,
                  result: result,
                ),
              )
            : (result: result, check: null);
      }
      admitted = true;
    }
    return (
      result: EngineResult.ok,
      // True only after actual callback bits match the whole vector.
      check: () {
        if (!_engine.commandsSettled) return null;
        final tracks = _engine.snapshot().tracks;
        for (var c = 0; c < 8; c++) {
          if (c >= tracks.length || tracks[c].oneShot != intent.effective(c)) {
            return (
              verdict: ReceiptVerdict.uncertain,
              result: EngineResult.invalid,
            );
          }
        }
        return (verdict: ReceiptVerdict.accepted, result: EngineResult.ok);
      },
    );
  }

  /// No playback vector is awaiting its callback receipt.
  bool get oneShotSettingsSettled => _oneShot.settled;

  /// Waits for a callback receipt, with a lifetime-bound timeout.
  Future<EngineResult> settleOneShot({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) => _oneShot.settle(pollInterval: pollInterval, attempts: attempts);

  /// Retry re-requests the owed vector while running and stages it stopped.
  EngineResult recoverOneShotSettings() {
    final result = _oneShot.recover();
    _reproject();
    return result;
  }

  void _requireSessionSetting(EngineResult result) {
    if (!result.isOk) {
      throw StateError('session setting could not be restored: ${result.name}');
    }
  }

  /// Releases the repository and the underlying engine.
  Future<void> dispose() async {
    _retireEngineLifetime();
    await _stopPollingAndClose();
    _engine.dispose();
  }

  Future<void> _stopPollingAndClose() async {
    _stopPolling();
    _stopReconnectPolling();
    for (final window in _paramAnnounceWindows.values) {
      window.cancel();
    }
    _paramAnnounceWindows.clear();
    _paramAnnounceDirty.clear();
    await _monitorChanges.close();
    await _monitorParamChanges.close();
    await _fxReplayConfirmed.close();
    await _rigReplaced.close();
    await _recoveryRefusals.close();
    await _timing.dispose();
    await _length.dispose();
    await _clickMode.dispose();
    await _clickVolume.dispose();
    await _recordStart.dispose();
    await _recordingInputRequired.close();
    await _recordRefusals.close();
    await _overdubRefusals.close();
    await _mixSettingsFailures.close();
    await _mix.dispose();
    await _controller.close();
  }
}

/// The crown the screens draw for an engine whose designation is
/// [designation] over [tracks]: the designated track when it holds a
/// completed take, else the lowest track that does, else `-1`.
///
/// The engine keeps the designation through the primary's own clear while a
/// sibling still holds audio (its re-record re-establishes it — D18), so the
/// raw field can name an empty track; a completed take is any state but
/// empty and recording — a take still being defined is not a recording yet.
int resolvedPrimaryTrack(int designation, List<TrackSnapshot> tracks) {
  bool completed(int channel) {
    if (channel < 0 || channel >= tracks.length) return false;
    final state = tracks[channel].state;
    return state != TrackState.empty && state != TrackState.recording;
  }

  if (completed(designation)) return designation;
  for (var channel = 0; channel < tracks.length; channel++) {
    if (completed(channel)) return channel;
  }
  return -1;
}

/// The steady facts a track's recorded shape is a function of — see
/// [LooperRepository.readTrackWaveform]. Equal keys mean nothing about the
/// content changed; a playhead tick, a level tick, a mute or a volume change
/// move none of these.
class _WaveformKey extends Equatable {
  const _WaveformKey({
    required this.state,
    required this.lengthFrames,
    required this.undoDepth,
    required this.redoDepth,
    required this.clearRestore,
  });

  factory _WaveformKey.of(Track track) => _WaveformKey(
    state: track.state,
    lengthFrames: track.lengthFrames,
    undoDepth: track.undoDepth,
    redoDepth: track.redoDepth,
    clearRestore: track.clearRestore,
  );

  final TrackState state;
  final int lengthFrames;
  final int undoDepth;
  final int redoDepth;
  final bool clearRestore;

  @override
  List<Object?> get props => [
    state,
    lengthFrames,
    undoDepth,
    redoDepth,
    clearRestore,
  ];
}

/// One cached waveform read with the sweep it is waiting on.
class _WaveformRead {
  _WaveformRead(this.key, this.samples, {required this.sweepFrom})
    : lastProgress = sweepFrom;

  final _WaveformKey key;
  Float32List samples;

  /// The playhead position the last key change was read at, and how many
  /// times the playhead has wrapped since: the buffer is fully rewritten
  /// once the head has passed [sweepFrom] again on a later lap.
  final double sweepFrom;
  int wraps = 0;
  double lastProgress;

  /// Whether the sweep has completed since the key change.
  bool swept = false;
}

class _MixIntent {
  _MixIntent({
    required Map<int, double> pans,
    required Map<int, double> trackLevels,
    required Map<int, bool> solos,
    required Map<(int, int), double> levels,
    required Map<(int, int), double> images,
    required Map<(int, int), double> balances,
    required Map<int, double> monitorLevels,
    required this.input,
    required this.output,
    required Map<(int, int), int> inputs,
    required Map<(int, int), int> routes,
    required Map<int, int> counts,
  }) : inputs = Map.of(inputs),
       routes = Map.of(routes),
       counts = Map.of(counts),
       pans = Map.of(pans),
       trackLevels = Map.of(trackLevels),
       solos = Map.of(solos),
       levels = Map.of(levels),
       images = Map.of(images),
       balances = Map.of(balances),
       monitorLevels = Map.of(monitorLevels);
  final Map<int, double> pans;
  final Map<int, double> trackLevels;
  final Map<int, bool> solos;
  final Map<(int, int), double> levels;
  final Map<(int, int), double> images;
  final Map<(int, int), double> balances;
  final Map<int, double> monitorLevels;
  final Map<(int, int), int> inputs;
  final Map<(int, int), int> routes;
  final Map<int, int> counts;
  InputSetup input;
  OutputSetup output;
  StereoMix laneMix((int, int) key) => (
    gain: levels[key] ?? 1,
    pan: pans[key.$1] ?? 0,
  );
  StereoMix laneImage((int, int) key) => (
    gain: balances[key] ?? 1,
    pan: images[key] ?? 0,
  );
  StereoMix monitorMix(int i) => (
    gain: (monitorLevels[i] ?? 1) * input.balanceGainOf(i),
    pan: input.effectivePanOf(i),
  );
}

class _PendingImage {
  _PendingImage(
    this.revision,
    this.images,
    this.balances,
    this.inputs,
    this.inherited,
    this.inheritedInputs,
    this.inheritedHandles, {
    required this.clearOnCommit,
  });
  final int revision;
  final Map<(int, int), double> images;
  final Map<(int, int), double> balances;
  final Set<int> inputs;
  final Map<int, List<TrackEffect>> inherited;
  final Map<int, int> inheritedInputs;
  final Map<int, Map<String, PluginSlotHandle>> inheritedHandles;
  final bool clearOnCommit;
}

/// One refused fresh-capture press waiting for its retry (#1146).
class _RecordRetry {
  _RecordRetry(this.channel);

  final int channel;

  /// Polls waited without the ring settling.
  int polls = 0;
}

class _FxPreparationRefused implements Exception {
  const _FxPreparationRefused(this.result);

  final EngineResult result;
}

final class _OneShotIntent {
  _OneShotIntent(Map<int, bool> overrides, {required this.defaultValue})
    : overrides = Map.unmodifiable(overrides);
  final bool defaultValue;
  final Map<int, bool> overrides;
  bool effective(int channel) => overrides[channel] ?? defaultValue;
}
