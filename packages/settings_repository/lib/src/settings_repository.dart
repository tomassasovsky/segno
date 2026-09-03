import 'package:flutter/foundation.dart';
import 'package:local_storage_client/local_storage_client.dart';
import 'package:pub_semver/pub_semver.dart';

/// The persisted device-backend intent. A settings-layer domain enum (mirroring
/// the engine's backend) kept here so this repository holds no data-layer
/// dependency; the presentation layer maps it to/from the engine backend.
enum AudioBackend {
  /// The platform's default miniaudio backend.
  miniaudio,

  /// Windows ASIO.
  asio,
}

/// A persisted audio device configuration, used to auto-start the engine on
/// launch with the user's last-used options.
@immutable
class StoredAudioConfig {
  /// Creates a [StoredAudioConfig].
  const StoredAudioConfig({
    required this.sampleRate,
    required this.bufferFrames,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopMinutes = 0,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.backend = AudioBackend.miniaudio,
    this.asioDriver = '',
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Requested hardware capture channel count (`0` => device default).
  final int inputChannels;

  /// Requested hardware playback channel count (`0` => device default).
  final int outputChannels;

  /// Maximum loop length the engine allocates per track, in whole minutes.
  /// `0` defers to the engine default. Stored as minutes (not frames) so the
  /// user's intent survives a later sample-rate change.
  final int maxLoopMinutes;

  /// Pinned playback device id (empty => system default).
  final String playbackDeviceId;

  /// Pinned capture device id (empty => system default).
  final String captureDeviceId;

  /// The persisted device-backend intent. Defaults to [AudioBackend.miniaudio].
  /// ASIO availability is a presentation-layer decision (Windows + an installed
  /// driver), so the repository stays platform-agnostic and holds only intent.
  final AudioBackend backend;

  /// The selected ASIO driver name (used only when [backend] is
  /// [AudioBackend.asio]). Empty on the default path.
  final String asioDriver;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredAudioConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          maxLoopMinutes == other.maxLoopMinutes &&
          playbackDeviceId == other.playbackDeviceId &&
          captureDeviceId == other.captureDeviceId &&
          backend == other.backend &&
          asioDriver == other.asioDriver;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopMinutes,
    playbackDeviceId,
    captureDeviceId,
    backend,
    asioDriver,
  );
}

/// Persists user/device settings via a [KeyValueStore].
///
/// Stores the per-device record-offset latency calibration, the last-used audio
/// device configuration (so the engine can auto-start on launch), per-track
/// display names, and big-picture view preferences.
class SettingsRepository {
  /// Creates a [SettingsRepository] backed by [store].
  ///
  /// [alsaPeriods] is the effective ALSA period count the engine runs with,
  /// or `null` where that knob is not engaged (any non-Linux platform, or
  /// Linux without `SEGNO_ALSA_PERIODS` set). Derive it with
  /// [alsaPeriodsFromEnvironment]; the composition root passes it in.
  const SettingsRepository({required KeyValueStore store, int? alsaPeriods})
    : _store = store,
      _alsaPeriods = alsaPeriods;

  final KeyValueStore _store;

  /// The effective ALSA period count, part of the latency-calibration key.
  ///
  /// The period count changes the ALSA playback start threshold (#809), which
  /// changes real output latency — so a record-offset calibration measured
  /// under one period count is stale under another, for the same device /
  /// sample-rate / buffer triple. Folding it into the key separates those
  /// offsets. A pre-#809 calibration under the legacy (period-less) key is
  /// not discarded but **migrated** on first read — see
  /// [loadLatencyOffsetFrames] — because nothing on the appliance would ever
  /// re-measure it: both auto-measure triggers in the bootstrap are
  /// structurally false on Linux (the console pins its capture device, and
  /// `le_platform_excluded_input_mask` always returns 0 there), so a
  /// discarded offset would simply mean *no* compensation, an error of the
  /// full hardware round trip.
  ///
  /// `null` means "knob not engaged" and keeps the legacy key shape, so every
  /// desktop calibration (and Linux with the variable unset, where #809 is a
  /// no-op) stays valid.
  final int? _alsaPeriods;

  /// Derives the effective ALSA period count from the raw
  /// `SEGNO_ALSA_PERIODS` environment value, mirroring the engine's own
  /// parser (`le_alsa_periods_from_env` in engine_miniaudio.c) so the key
  /// records what the engine actually runs with, not what was typed.
  ///
  /// Returns `null` for unset/empty (the engine keeps its default — the knob
  /// is not engaged). Otherwise parses the leading integer the way `strtol`
  /// does (no digits => 0, overflow saturates) and clamps into `[2, 8]`.
  static int? alsaPeriodsFromEnvironment(String? value) {
    if (value == null || value.isEmpty) return null;
    final digits = RegExp('^[+-]?[0-9]+').firstMatch(value.trimLeft());
    if (digits == null) return 2;
    // A run of digits too long for a Dart int can only be far out of [2, 8]:
    // saturate to the bound on its sign, as the engine's strtol + clamp does.
    final parsed =
        int.tryParse(digits[0]!) ?? (digits[0]!.startsWith('-') ? 0 : 8);
    return parsed.clamp(2, 8);
  }

  String _legacyLatencyKey(String device, int sampleRate, int bufferFrames) =>
      'latency_offset.$device.$sampleRate.$bufferFrames';

  String _latencyKey(String device, int sampleRate, int bufferFrames) {
    final base = _legacyLatencyKey(device, sampleRate, bufferFrames);
    // Appended only when the ALSA periods knob is engaged, so desktop keys
    // keep their historical shape and stay valid (see [_alsaPeriods]).
    return _alsaPeriods == null ? base : '$base.p$_alsaPeriods';
  }

  /// How many frames #809 added to real output latency versus the legacy
  /// (pre-#809, period-less) configuration, for this period count and buffer.
  ///
  /// The patched ALSA start threshold (miniaudio.h, SEGNO PATCH #809) is
  /// `max(2 * period, (period * periods) ~/ 2)`; stock was `2 * period`. The
  /// steady-state output latency moves by exactly the threshold delta —
  /// that is the PR's own premise ("the steady-state cost is exactly the
  /// added frames in output latency") — so:
  ///
  ///   delta = max(0, (bufferFrames * periods) ~/ 2 - 2 * bufferFrames)
  ///
  /// which is 0 for periods <= 4 and, e.g., `2 * bufferFrames` at the
  /// appliance's shipped 8. `period` here is [bufferFrames]: the engine
  /// requests `periodSizeInFrames = buffer_frames` (engine_miniaudio.c) and
  /// the key stores that same requested value. Caveat, accepted: the
  /// threshold itself uses the NEGOTIATED internalPeriodSize/internalPeriods,
  /// while this uses the requested buffer and the clamped requested period
  /// count — they match on the appliance's Scarlett (per the launcher's
  /// hw_params note), which is the only place the knob ships engaged.
  int _startThresholdDeltaFrames(int bufferFrames) {
    final halfRing = bufferFrames * _alsaPeriods! ~/ 2;
    final legacyThreshold = 2 * bufferFrames;
    return halfRing > legacyThreshold ? halfRing - legacyThreshold : 0;
  }

  /// Loads the saved record-offset (frames) for the given device profile, or
  /// `null` if none has been stored.
  ///
  /// When the ALSA periods knob is engaged and the period-qualified key is
  /// empty, a calibration stored under the legacy key is migrated: returned
  /// shifted by [_startThresholdDeltaFrames] and persisted under the
  /// qualified key. Discarding it instead would leave the appliance with NO
  /// offset forever — no auto re-measure exists on Linux (see
  /// [_alsaPeriods]) — and the shift is exact because #809 changes output
  /// latency by precisely the threshold delta. This is a one-time value
  /// migration for calibrations on shipped hardware, not a compatibility
  /// code path (AGENTS.md): the legacy key is never read again once the
  /// qualified key exists. It runs even at delta 0 (periods <= 4, where #809
  /// is a no-op): the qualified key still materialises so the legacy entry
  /// stays a pristine pre-#809 baseline — subsequent saves land on the
  /// qualified key, never overwrite the legacy one, and a later period-count
  /// change migrates from the baseline again with its own delta. The legacy
  /// entry is left in place for exactly that reason, and so a downgrade to a
  /// pre-#809 build still finds its own correct value.
  Future<int?> loadLatencyOffsetFrames({
    required String device,
    required int sampleRate,
    required int bufferFrames,
  }) async {
    final key = _latencyKey(device, sampleRate, bufferFrames);
    final stored = await _store.getInt(key);
    if (stored != null || _alsaPeriods == null) return stored;
    final legacy = await _store.getInt(
      _legacyLatencyKey(device, sampleRate, bufferFrames),
    );
    if (legacy == null) return null;
    final migrated = legacy + _startThresholdDeltaFrames(bufferFrames);
    await _store.setInt(key, migrated);
    return migrated;
  }

  /// Saves the record-offset (frames) for the given device profile.
  Future<void> saveLatencyOffsetFrames({
    required String device,
    required int sampleRate,
    required int bufferFrames,
    required int frames,
  }) => _store.setInt(_latencyKey(device, sampleRate, bufferFrames), frames);

  static const String _audioSampleRateKey = 'audio.sample_rate';
  static const String _audioBufferFramesKey = 'audio.buffer_frames';
  // Legacy global input-monitor flag. No longer part of [StoredAudioConfig]:
  // monitoring is now the per-input routing graph (the `monitor_input.N` keys).
  // Read only by the one-time monitor migration via [loadLegacyMonitorInput].
  static const String _audioMonitorKey = 'audio.monitor_input';
  static const String _audioInputChannelsKey = 'audio.input_channels';
  static const String _audioOutputChannelsKey = 'audio.output_channels';
  static const String _audioMaxLoopMinutesKey = 'audio.max_loop_minutes';
  static const String _audioPlaybackDeviceIdKey = 'audio.playback_device_id';
  static const String _audioCaptureDeviceIdKey = 'audio.capture_device_id';
  static const String _audioBackendKey = 'audio.backend';
  static const String _audioAsioDriverKey = 'audio.asioDriver';

  /// Loads the last-used audio configuration, or `null` if none has been saved
  /// yet (a first run, so the setup flow should be shown).
  Future<StoredAudioConfig?> loadAudioConfig() async {
    final sampleRate = await _store.getInt(_audioSampleRateKey);
    final bufferFrames = await _store.getInt(_audioBufferFramesKey);
    if (sampleRate == null || bufferFrames == null) return null;
    return StoredAudioConfig(
      sampleRate: sampleRate,
      bufferFrames: bufferFrames,
      inputChannels: await _store.getInt(_audioInputChannelsKey) ?? 0,
      outputChannels: await _store.getInt(_audioOutputChannelsKey) ?? 0,
      maxLoopMinutes: await _store.getInt(_audioMaxLoopMinutesKey) ?? 0,
      playbackDeviceId: await _store.getString(_audioPlaybackDeviceIdKey) ?? '',
      captureDeviceId: await _store.getString(_audioCaptureDeviceIdKey) ?? '',
      backend: _backendFromName(await _store.getString(_audioBackendKey)),
      asioDriver: await _store.getString(_audioAsioDriverKey) ?? '',
    );
  }

  /// Resolves a stored backend name to an [AudioBackend], forward-compatibly:
  /// an unknown name (e.g. a value written by a newer build) resolves to
  /// [AudioBackend.miniaudio] rather than throwing (a defensive read).
  AudioBackend _backendFromName(String? name) =>
      AudioBackend.values.asNameMap()[name] ?? AudioBackend.miniaudio;

  /// Loads the legacy global input-monitor flag, or `null` if it was never set.
  /// Only the one-time monitor migration reads this — the live app no longer
  /// persists it (monitoring is the per-input routing graph). Nullable so the
  /// migration can tell "never configured" apart from an explicit choice.
  Future<bool?> loadLegacyMonitorInput() => _store.getBool(_audioMonitorKey);

  static const String _monitorMigratedV1Key = 'monitor.migrated_v1';

  /// Whether the one-time legacy-monitor migration has already run. Defaults to
  /// `false` so a fresh install runs (and no-ops) it once.
  Future<bool> loadMonitorMigratedV1() async =>
      await _store.getBool(_monitorMigratedV1Key) ?? false;

  /// Marks the one-time legacy-monitor migration done so it never re-runs.
  Future<void> saveMonitorMigratedV1() =>
      _store.setBool(_monitorMigratedV1Key, value: true);

  static const String _monitorMigratedV2Key = 'monitor.migrated_v2';

  /// Whether the one-time single-route → multi-lane monitor migration (v2) has
  /// already run. Defaults to `false` so a fresh install runs (and no-ops) it
  /// once. Runs after v1 (the global → per-input step) so a cold upgrade folds
  /// both in order.
  Future<bool> loadMonitorMigratedV2() async =>
      await _store.getBool(_monitorMigratedV2Key) ?? false;

  /// Marks the v2 monitor-lane migration done so it never re-runs.
  Future<void> saveMonitorMigratedV2() =>
      _store.setBool(_monitorMigratedV2Key, value: true);

  static const String _monitorMigratedV3Key = 'monitor.migrated_v3';

  /// Whether the one-time multi-lane → single-chain monitor fold (v3) has
  /// already run. Defaults to `false` so a fresh install runs (and no-ops) it
  /// once. Runs after v2 so a cold v1→v2→v3 upgrade folds in order.
  Future<bool> loadMonitorMigratedV3() async =>
      await _store.getBool(_monitorMigratedV3Key) ?? false;

  /// Marks the v3 single-chain monitor fold done so it never re-runs.
  Future<void> saveMonitorMigratedV3() =>
      _store.setBool(_monitorMigratedV3Key, value: true);

  /// Saves the audio [config] so the engine can auto-start with it next launch.
  Future<void> saveAudioConfig(StoredAudioConfig config) async {
    await _store.setInt(_audioSampleRateKey, config.sampleRate);
    await _store.setInt(_audioBufferFramesKey, config.bufferFrames);
    await _store.setInt(_audioInputChannelsKey, config.inputChannels);
    await _store.setInt(_audioOutputChannelsKey, config.outputChannels);
    await _store.setInt(_audioMaxLoopMinutesKey, config.maxLoopMinutes);
    await _store.setString(
      _audioPlaybackDeviceIdKey,
      config.playbackDeviceId,
    );
    await _store.setString(_audioCaptureDeviceIdKey, config.captureDeviceId);
    await _store.setString(_audioBackendKey, config.backend.name);
    await _store.setString(_audioAsioDriverKey, config.asioDriver);
  }

  static const String _midiInputDeviceIdKey = 'midi.input_device_id';
  static const String _midiInputDeviceNameKey = 'midi.input_device_name';

  /// Loads the pinned MIDI input device as `(id, name)`, or `null` when none
  /// has been selected (a fresh install, or after picking "None"). The `id` is
  /// the per-OS stable token used to re-open the device on launch; `name` is
  /// the human-readable label kept so a "last device not found" status can name
  /// it even while the device is absent. Additive flat keys, like `audio.*`.
  Future<({String id, String name})?> loadMidiDevice() async {
    final id = await _store.getString(_midiInputDeviceIdKey);
    if (id == null || id.isEmpty) return null;
    final name = await _store.getString(_midiInputDeviceNameKey) ?? '';
    return (id: id, name: name);
  }

  /// Pins the MIDI input device [id]/[name] so it auto-reconnects next launch.
  Future<void> saveMidiDevice({
    required String id,
    required String name,
  }) async {
    await _store.setString(_midiInputDeviceIdKey, id);
    await _store.setString(_midiInputDeviceNameKey, name);
  }

  /// Clears the pinned MIDI input device (the "None" selection), so the looper
  /// relaunches with no MIDI device attached.
  Future<void> clearMidiDevice() async {
    await _store.remove(_midiInputDeviceIdKey);
    await _store.remove(_midiInputDeviceNameKey);
  }

  static const String _pedalLongPressMsKey = 'pedal.long_press_ms';

  /// Loads the pedal long-press threshold in milliseconds (Undo long-press =
  /// redo). Defaults to `500` when unset.
  Future<int> loadPedalLongPressMs() async =>
      await _store.getInt(_pedalLongPressMsKey) ?? 500;

  /// Saves the pedal long-press threshold in milliseconds.
  Future<void> savePedalLongPressMs(int ms) =>
      _store.setInt(_pedalLongPressMsKey, ms);

  static const String _modeSwitchStyleKey = 'pedal.mode_switch_style';

  /// Loads the persisted MODE-footswitch style token (an opaque token, e.g.
  /// `'cycleThree'` / `'holdFx'`), or `null` if unset. The presentation layer
  /// maps the token to its style enum; unset (and unknown) tokens resolve to
  /// the original three-mode tap cycle, so existing rigs see no change.
  Future<String?> loadModeSwitchStyle() =>
      _store.getString(_modeSwitchStyleKey);

  /// Saves the MODE-footswitch [style] token.
  Future<void> saveModeSwitchStyle(String style) =>
      _store.setString(_modeSwitchStyleKey, style);

  static const String _pedalClearFadeMsKey = 'pedal.clear_fade_ms';

  /// Loads the pedal clear-all fade/guard window in milliseconds (`0` disables
  /// the guard — Clear erases immediately). Defaults to `1000` when unset.
  Future<int> loadPedalClearFadeMs() async =>
      await _store.getInt(_pedalClearFadeMsKey) ?? 1000;

  /// Saves the pedal clear-all fade/guard window in milliseconds.
  Future<void> savePedalClearFadeMs(int ms) =>
      _store.setInt(_pedalClearFadeMsKey, ms);

  static const String _showWaveformWindowKey = 'ui.waveform_window';

  /// Whether the secondary output-waveform window should open. Defaults to
  /// `true` when unset.
  Future<bool> loadShowWaveformWindow() async =>
      await _store.getBool(_showWaveformWindowKey) ?? true;

  /// Saves whether the secondary output-waveform window should open.
  Future<void> saveShowWaveformWindow({required bool value}) =>
      _store.setBool(_showWaveformWindowKey, value: value);

  static const String _highContrastKey = 'ui.high_contrast';

  /// Whether the manual high-contrast theme override is on. Defaults to
  /// `false`. Desktop platforms (macOS / Windows / Linux) do not deliver the OS
  /// high-contrast flag to Flutter, so this toggle is the only way to enable
  /// the high-contrast palette there.
  Future<bool> loadHighContrast() async =>
      await _store.getBool(_highContrastKey) ?? false;

  /// Saves the high-contrast override.
  Future<void> saveHighContrast({required bool value}) =>
      _store.setBool(_highContrastKey, value: value);

  static const String _brightnessKey = 'ui.brightness';

  /// Console display brightness (`0..1`). Defaults to `1.0` when unset —
  /// the same number as the app's `kDefaultDisplayBrightness`, which this
  /// package cannot import (it must not depend on the app).
  Future<double> loadBrightness() async =>
      (await _store.getDouble(_brightnessKey) ?? 1.0).clamp(0.0, 1.0);

  /// Saves console display brightness (`0..1`).
  Future<void> saveBrightness(double value) =>
      _store.setDouble(_brightnessKey, value.clamp(0.0, 1.0));

  static const String _showTrackIndicatorsKey = 'tracks.indicators';

  /// Whether per-track status indicators show on the Tracks-view tiles.
  /// Defaults to `true` when unset.
  Future<bool> loadShowTrackIndicators({bool defaultValue = true}) async =>
      await _store.getBool(_showTrackIndicatorsKey) ?? defaultValue;

  /// Saves whether per-track status indicators show on the Tracks-view tiles.
  Future<void> saveShowTrackIndicators({required bool value}) =>
      _store.setBool(_showTrackIndicatorsKey, value: value);

  static const String _defaultInteractionModeKey = 'looper.default_mode';

  /// Loads the persisted default interaction mode (an opaque token, e.g.
  /// `'record'` / `'mute'` — or the legacy `'play'` that older builds wrote
  /// for the mute mode), or `null` if unset. The presentation layer maps the
  /// token to its mode enum, including the legacy-token shim.
  Future<String?> loadDefaultInteractionMode() =>
      _store.getString(_defaultInteractionModeKey);

  /// Saves the default interaction [mode] token.
  Future<void> saveDefaultInteractionMode(String mode) =>
      _store.setString(_defaultInteractionModeKey, mode);

  static const String _pedalBindingsKey = 'pedal.bindings';

  /// Loads the GLOBAL pedal remap as its opaque encoded string, or `null` when
  /// none was ever saved (every footswitch keeps its contextual default).
  ///
  /// Opaque here on purpose: the binding model lives app-side next to
  /// `ControlCubit`, so this package persists the string without knowing its
  /// shape — the same treatment the FX chain envelopes get. A session may
  /// carry its own set, which overrides this one wholesale (A12); that copy
  /// rides the session bundle, not this key.
  Future<String?> loadPedalBindings() => _store.getString(_pedalBindingsKey);

  /// Saves the global pedal remap as its [encoded] string.
  Future<void> savePedalBindings(String encoded) =>
      _store.setString(_pedalBindingsKey, encoded);

  /// The key the recent-plugin order lives under.
  ///
  /// Visible so a test can fail THIS read specifically without copying the
  /// string — a copy stops matching the day the key is renamed, and the test
  /// then passes because nothing threw at all. The only key here that is not
  /// private, and annotated so production code does not start depending on
  /// one storage detail out of fifty.
  @visibleForTesting
  static const String recentPluginsKey = 'fx.recent_plugins';

  /// The plugin ids most recently added to a chain, newest first.
  ///
  /// A convenience, not a source of truth: the add dialog offers a short
  /// shelf so the four plugins someone actually uses are one tap away rather
  /// than behind a search of a hundred. An id that no longer scans is simply
  /// not drawn — the catalog decides what exists, this only remembers an
  /// order.
  Future<String?> loadRecentPlugins() => _store.getString(recentPluginsKey);

  /// Saves the recent-plugin ids as a newline-separated list.
  Future<void> saveRecentPlugins(String encoded) =>
      _store.setString(recentPluginsKey, encoded);

  static const String _controllerMappingsKey = 'controller.mappings';

  /// Loads the external-MIDI mapping set as its opaque encoded string, or
  /// `null` when none was ever saved (external control drives nothing).
  ///
  /// Opaque here for the same reason the pedal remap is: the binding model
  /// lives in `controller_repository` and its TARGETS are canonical-JSON
  /// strings only the app can decode, so this package persists the blob
  /// without knowing its shape.
  ///
  /// GLOBAL-ONLY in v1 (R19), unlike the pedal remap: expression hardware is
  /// per-rig, not per-song, so no session carries a copy of this key and a
  /// session stays portable across machines with different controllers.
  Future<String?> loadControllerMappings() =>
      _store.getString(_controllerMappingsKey);

  /// Saves the external-MIDI mapping set as its [encoded] string.
  Future<void> saveControllerMappings(String encoded) =>
      _store.setString(_controllerMappingsKey, encoded);

  static const String _refreshHzKey = 'ui.refresh_hz';

  /// Loads the UI snapshot-poll rate in Hz. Defaults to `60` when unset.
  Future<int> loadRefreshHz() async => await _store.getInt(_refreshHzKey) ?? 60;

  /// Saves the UI snapshot-poll rate in [hz].
  Future<void> saveRefreshHz(int hz) => _store.setInt(_refreshHzKey, hz);

  static const String _quantizeKey = 'looper.quantize';

  /// Whether recording is quantized to the loop grid. Defaults to `false`
  /// (the free-running behaviour) when unset.
  Future<bool> loadQuantize() async =>
      await _store.getBool(_quantizeKey) ?? false;

  /// Saves whether recording is quantized to the loop grid.
  Future<void> saveQuantize({required bool value}) =>
      _store.setBool(_quantizeKey, value: value);

  static const String _recDubKey = 'looper.rec_dub';

  /// Whether a record press finalizing a recording continues into overdub
  /// (rec/dub) instead of playback. Defaults to `false`.
  Future<bool> loadRecDub() async => await _store.getBool(_recDubKey) ?? false;

  /// Saves the rec/dub second-press mode.
  Future<void> saveRecDub({required bool value}) =>
      _store.setBool(_recDubKey, value: value);

  static const String _defaultMultipleKey = 'looper.default_multiple';

  /// Loads the global default loop length (`0` = auto), or `0` if unset.
  Future<int> loadDefaultMultiple() async =>
      await _store.getInt(_defaultMultipleKey) ?? 0;

  /// Saves the global default loop length (`0` = auto).
  Future<void> saveDefaultMultiple(int multiple) =>
      _store.setInt(_defaultMultipleKey, multiple);

  static const String _autoRecordKey = 'looper.auto_record';

  /// Whether recording is sound-activated (starts on input). Defaults to
  /// `false`.
  Future<bool> loadAutoRecord() async =>
      await _store.getBool(_autoRecordKey) ?? false;

  /// Saves the sound-activated recording preference.
  Future<void> saveAutoRecord({required bool value}) =>
      _store.setBool(_autoRecordKey, value: value);

  String _trackMultipleKey(int channel) => 'track_multiple.$channel';

  /// Loads track [channel]'s forced loop multiple (`0` = auto; `0` if unset).
  Future<int> loadTrackMultiple(int channel) async =>
      await _store.getInt(_trackMultipleKey(channel)) ?? 0;

  /// Saves track [channel]'s forced loop multiple (`0` = auto).
  Future<void> saveTrackMultiple(int channel, int multiple) =>
      _store.setInt(_trackMultipleKey(channel), multiple);

  // ---- tempo grid (A1) + click/count-in (A2) ----
  //
  // Every key here defaults to the tempo-free/grid-off value, so an unset
  // install (or one that predates this plan) loads exactly the tempo-free
  // behaviour — mirroring [loadQuantize]'s off-by-default contract.

  static const String _tempoBpmKey = 'tempo.bpm';

  /// Loads the saved tempo in beats per minute. Defaults to `0` (never set)
  /// when unset.
  Future<double> loadTempoBpm() async =>
      await _store.getDouble(_tempoBpmKey) ?? 0;

  /// Saves the tempo in beats per minute.
  Future<void> saveTempoBpm(double bpm) => _store.setDouble(_tempoBpmKey, bpm);

  static const String _timeSignatureNumKey = 'tempo.ts_num';
  static const String _timeSignatureDenKey = 'tempo.ts_den';

  /// Loads the saved time signature as `(num, den)`. Defaults to `(4, 4)`
  /// when unset.
  Future<(int num, int den)> loadTimeSignature() async => (
    await _store.getInt(_timeSignatureNumKey) ?? 4,
    await _store.getInt(_timeSignatureDenKey) ?? 4,
  );

  /// Saves the time signature.
  Future<void> saveTimeSignature(int num, int den) async {
    await _store.setInt(_timeSignatureNumKey, num);
    await _store.setInt(_timeSignatureDenKey, den);
  }

  static const String _syncTempoKey = 'tempo.sync';

  /// Whether loop↔grid sync is on. Defaults to `true` when unset.
  Future<bool> loadSyncTempo() async =>
      await _store.getBool(_syncTempoKey) ?? true;

  /// Saves whether loop↔grid sync is on.
  Future<void> saveSyncTempo({required bool value}) =>
      _store.setBool(_syncTempoKey, value: value);

  static const String _quantizeDivKey = 'tempo.quantize_div';

  /// Loads the musical quantization granularity as the native `le_grid_div`
  /// enum code (see `GridDivision.code` / `GridDivision.fromCode`). Defaults
  /// to `0` (`GridDivision.off`) when unset.
  Future<int> loadQuantizeDiv() async =>
      await _store.getInt(_quantizeDivKey) ?? 0;

  /// Saves the musical quantization granularity as its enum [code].
  Future<void> saveQuantizeDiv(int code) =>
      _store.setInt(_quantizeDivKey, code);

  static const String _clickModeKey = 'tempo.click_mode';

  /// Loads the click audibility mode as the native `le_click_mode` enum code
  /// (see `ClickMode.code` / `ClickMode.fromCode`). Defaults to `0`
  /// (`ClickMode.off`) when unset.
  Future<int> loadClickMode() async => await _store.getInt(_clickModeKey) ?? 0;

  /// Saves the click audibility mode as its enum [code].
  Future<void> saveClickMode(int code) => _store.setInt(_clickModeKey, code);

  static const String _clickOutputMaskKey = 'tempo.click_output_mask';

  /// Loads the click output routing bitmask. Defaults to `0` (no outputs)
  /// when unset.
  Future<int> loadClickOutputMask() async =>
      await _store.getInt(_clickOutputMaskKey) ?? 0;

  /// Saves the click output routing bitmask.
  Future<void> saveClickOutputMask(int mask) =>
      _store.setInt(_clickOutputMaskKey, mask);

  static const String _clickVolumeKey = 'tempo.click_volume';

  /// Loads the click volume (`0..LE_MAX_GAIN`). Defaults to `1.0` when unset.
  Future<double> loadClickVolume() async =>
      await _store.getDouble(_clickVolumeKey) ?? 1.0;

  /// Saves the click volume.
  Future<void> saveClickVolume(double volume) =>
      _store.setDouble(_clickVolumeKey, volume);

  static const String _countInBarsKey = 'tempo.count_in_bars';

  /// Loads the count-in length in measures (`0` = off). Defaults to `0`
  /// (off) when unset — the wire default per A2, not the UI-suggested
  /// starting point of one bar.
  Future<int> loadCountInBars() async =>
      await _store.getInt(_countInBarsKey) ?? 0;

  /// Saves the count-in length in measures (`0` = off).
  Future<void> saveCountInBars(int bars) =>
      _store.setInt(_countInBarsKey, bars);

  // ---- looper mode (B2a, D4) ----

  static const String _looperModeKey = 'looper.mode';

  /// Loads the five-mode axis as the native `le_looper_mode` enum code (see
  /// `LooperMode.code` / `LooperMode.fromCode`). Defaults to `0`
  /// (`LooperMode.multi`) when unset — the int-code convention matches this
  /// enum's siblings ([loadQuantizeDiv] / [loadClickMode]), unlike
  /// `loadDefaultInteractionMode`'s opaque-string-token scheme: that key
  /// predates this plan and preserves pre-rename legacy tokens (D10), a
  /// concern this newly-introduced enum has no analog of.
  Future<int> loadLooperMode() async =>
      await _store.getInt(_looperModeKey) ?? 0;

  /// Saves the looper mode as its enum [code].
  Future<void> saveLooperMode(int code) => _store.setInt(_looperModeKey, code);

  // ---- track length presets (A6, D17) ----

  String _trackLengthPresetKey(int channel) => 'tempo.length_preset.$channel';

  /// Loads track [channel]'s length preset (`0` = AUTO; `0` if unset).
  Future<int> loadTrackLengthPreset(int channel) async =>
      await _store.getInt(_trackLengthPresetKey(channel)) ?? 0;

  /// Saves track [channel]'s length preset (`0` = AUTO, `1..64` = fixed bars).
  Future<void> saveTrackLengthPreset(int channel, int bars) =>
      _store.setInt(_trackLengthPresetKey(channel), bars);

  // Legacy single-route monitor keys (one route per input). No longer written
  // by the live app; read once by the v2 lane migration and then cleared. The
  // v1 courtesy migration still writes monitor_input.N (global flag →
  // per-input) before v2 converts it to lanes.
  String _monitorInputKey(int input) => 'monitor_input.$input';
  String _monitorInputDryKey(int input) => 'monitor_input_dry.$input';
  String _monitorInputVolKey(int input) => 'monitor_input_vol.$input';
  String _monitorInputFxKey(int input) => 'monitor_input_fx.$input';

  // Per-input single-chain monitor keys (the model the live app uses after the
  // v3 fold). The enable flag is shared with the prior model.
  String _monitorInputModeKey(int input) => 'monitor_input_mode.$input';
  String _monitorOutKey(int input) => 'monitor_out.$input';
  String _monitorVolKey(int input) => 'monitor_vol.$input';
  String _monitorMuteKey(int input) => 'monitor_mute.$input';
  String _monitorFxKey(int input) => 'monitor_fx.$input';

  // Per-(input, lane) monitor keys — the prior multi-lane model. No longer
  // written by the live app; read once by the v3 single-chain fold and then
  // cleared.
  String _monitorLaneCountKey(int input) => 'monitor_lane_count.$input';
  String _monitorLaneOutKey(int input, int lane) =>
      'monitor_lane_out.$input.$lane';
  String _monitorLaneVolKey(int input, int lane) =>
      'monitor_lane_vol.$input.$lane';
  String _monitorLaneMuteKey(int input, int lane) =>
      'monitor_lane_mute.$input.$lane';
  String _monitorLaneFxKey(int input, int lane) =>
      'monitor_lane_fx.$input.$lane';

  // Structural output gate. Keyed per DEVICE and socket, like [_inputNameKey]
  // and [_latencyKey]: the flag is a fact about a physical socket, and sockets
  // belong to devices — Out 3/4 disabled as one interface's phones pair must
  // not silence another interface whose Out 3/4 feed the PA. Absence of a key
  // means ENABLED (default-on); only explicitly-disabled outputs are written,
  // so no fixed bound is needed and the set is self-cleaning when devices
  // change.
  String _outputEnabledKey(String device, int output) =>
      'output_enabled.$device.$output';

  // The pre-device-keyed shape (#569). Never written any more; read once by
  // [loadOutputEnabled]'s adoption migration and then removed.
  String _legacyOutputEnabledKey(int output) => 'output_enabled.$output';

  /// Loads hardware [input]'s LEGACY single-route monitor routing as
  /// `(enabled, outputMask)`, or `null` if it was never saved. Read only by the
  /// v1 courtesy migration and the v2 lane migration; the live app reads the
  /// per-(input, lane) keys.
  ///
  /// Packed into one int: a negative value means disabled; a non-negative value
  /// is the output bitmask of an enabled monitor.
  Future<(bool enabled, int outputMask)?> loadMonitorInput(int input) async {
    final value = await _store.getInt(_monitorInputKey(input));
    if (value == null) return null;
    return value < 0 ? (false, 0x3) : (true, value);
  }

  /// Saves hardware [input]'s legacy single-route monitor routing. Written only
  /// by the v1 courtesy migration (global flag → per-input); the v2 migration
  /// then converts it to lanes.
  Future<void> saveMonitorInput(
    int input, {
    required bool enabled,
    required int outputMask,
  }) => _store.setInt(_monitorInputKey(input), enabled ? outputMask : -1);

  /// Loads hardware [input]'s legacy monitor dry-send output bitmask
  /// (`0` = off). Read only by the v2 lane migration.
  Future<int> loadMonitorInputDry(int input) async =>
      await _store.getInt(_monitorInputDryKey(input)) ?? 0;

  /// Loads hardware [input]'s legacy monitor output gain (`0..LE_MAX_GAIN`,
  /// 2.0, +6.02 dB headroom above unity), or `null` if it was never saved.
  /// Read only by the v2 lane migration.
  Future<double?> loadMonitorInputVolume(int input) =>
      _store.getDouble(_monitorInputVolKey(input));

  /// Loads hardware [input]'s legacy monitor effect chain as an opaque encoded
  /// string (see `encodeTrackEffects`), or `null`. Read only by the v2 lane
  /// migration.
  Future<String?> loadMonitorInputEffects(int input) =>
      _store.getString(_monitorInputFxKey(input));

  /// Clears hardware [input]'s legacy single-route monitor keys once the v2
  /// lane migration has converted them to lane keys.
  Future<void> clearLegacyMonitorInput(int input) async {
    await _store.remove(_monitorInputKey(input));
    await _store.remove(_monitorInputDryKey(input));
    await _store.remove(_monitorInputVolKey(input));
    await _store.remove(_monitorInputFxKey(input));
  }

  /// Loads hardware [input]'s monitor mode name, or `null` if never saved.
  ///
  /// Stored as the enum's name rather than an index so the on-disk value stays
  /// readable and survives any reordering of the enum. The caller maps an
  /// absent or unrecognised value to `off`, which is the model's default
  /// anyway — the same answer the old boolean key gave when it was missing.
  Future<String?> loadMonitorInputMode(int input) =>
      _store.getString(_monitorInputModeKey(input));

  /// Saves hardware [input]'s monitor mode (the input-level gate).
  Future<void> saveMonitorInputMode(int input, {required String mode}) =>
      _store.setString(_monitorInputModeKey(input), mode);

  // ---- single-chain monitor (the live model after the v3 fold) ----

  /// Loads hardware [input]'s monitor output bitmask, or `null` if never saved
  /// (the caller defaults to full stereo `0x3`).
  Future<int?> loadMonitorOutput(int input) =>
      _store.getInt(_monitorOutKey(input));

  /// Saves hardware [input]'s monitor output bitmask.
  Future<void> saveMonitorOutput(int input, int mask) =>
      _store.setInt(_monitorOutKey(input), mask);

  /// Loads hardware [input]'s monitor output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity), or `null` if never saved (the caller
  /// defaults to unity `1.0`).
  Future<double?> loadMonitorVolume(int input) =>
      _store.getDouble(_monitorVolKey(input));

  /// Saves hardware [input]'s monitor output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity).
  Future<void> saveMonitorVolume(int input, double volume) =>
      _store.setDouble(_monitorVolKey(input), volume);

  /// Loads hardware [input]'s monitor mute flag, or `null` if never saved.
  Future<bool?> loadMonitorMute(int input) =>
      _store.getBool(_monitorMuteKey(input));

  /// Saves hardware [input]'s monitor mute flag.
  Future<void> saveMonitorMute(int input, {required bool muted}) =>
      _store.setBool(_monitorMuteKey(input), value: muted);

  /// Loads hardware [input]'s monitor effect chain as an opaque encoded string
  /// (see `encodeTrackEffects`), or `null` if none is saved.
  Future<String?> loadMonitorEffects(int input) =>
      _store.getString(_monitorFxKey(input));

  /// Saves hardware [input]'s [encoded] monitor effect chain.
  Future<void> saveMonitorEffects(int input, String encoded) =>
      _store.setString(_monitorFxKey(input), encoded);

  // ---- per-input conditioning + loop-close restoration (#697) ----
  //
  // Input-scoped, like the `monitor_*.N` family — a fact about the instrument
  // plugged into a socket, not about the interface (unlike `latency_offset.*`).
  // Every load returns `null` when its key was never written, so the caller
  // owns the default (see `InputConditioningCubit` — the plan's default table:
  // stage off, HPF 40 Hz, hum 50 Hz × 4 harmonics, expander -55 dB / 2.0 /
  // 150 ms, restore flags 0). The conditioning params are stored in their real
  // units (Hz / dB / ms / ratio), matching the engine's `le_cond_param` surface.

  String _inputCondEnabledKey(int input) => 'input_cond.$input';
  String _inputCondHpfKey(int input) => 'input_cond_hpf.$input';
  String _inputCondHumKey(int input) => 'input_cond_hum.$input';
  String _inputCondHumHarmonicsKey(int input) =>
      'input_cond_hum_harmonics.$input';
  String _inputCondExpThreshKey(int input) => 'input_cond_exp_thresh.$input';
  String _inputCondExpRatioKey(int input) => 'input_cond_exp_ratio.$input';
  String _inputCondExpReleaseKey(int input) => 'input_cond_exp_release.$input';
  String _inputRestoreKey(int input) => 'input_restore.$input';

  /// Loads hardware [input]'s conditioning-stage on/off flag, or `null` if it
  /// was never saved (the caller defaults to off).
  Future<bool?> loadInputConditioningEnabled(int input) =>
      _store.getBool(_inputCondEnabledKey(input));

  /// Saves hardware [input]'s conditioning-stage on/off flag.
  Future<void> saveInputConditioningEnabled(
    int input, {
    required bool enabled,
  }) => _store.setBool(_inputCondEnabledKey(input), value: enabled);

  /// Loads hardware [input]'s conditioning high-pass cutoff in Hz (`0` = HPF
  /// section off), or `null` if never saved (the caller defaults to `40`).
  Future<double?> loadInputConditioningHpfHz(int input) =>
      _store.getDouble(_inputCondHpfKey(input));

  /// Saves hardware [input]'s conditioning high-pass cutoff in Hz.
  Future<void> saveInputConditioningHpfHz(int input, double hz) =>
      _store.setDouble(_inputCondHpfKey(input), hz);

  /// Loads hardware [input]'s conditioning mains-hum base frequency in Hz
  /// (`0` = hum section off), or `null` if never saved (the caller defaults to
  /// `50`).
  Future<int?> loadInputConditioningHumHz(int input) =>
      _store.getInt(_inputCondHumKey(input));

  /// Saves hardware [input]'s conditioning mains-hum base frequency in Hz.
  Future<void> saveInputConditioningHumHz(int input, int hz) =>
      _store.setInt(_inputCondHumKey(input), hz);

  /// Loads hardware [input]'s conditioning hum-notch count (base included,
  /// `1..8`), or `null` if never saved (the caller defaults to `4`).
  Future<int?> loadInputConditioningHumHarmonics(int input) =>
      _store.getInt(_inputCondHumHarmonicsKey(input));

  /// Saves hardware [input]'s conditioning hum-notch count.
  Future<void> saveInputConditioningHumHarmonics(int input, int count) =>
      _store.setInt(_inputCondHumHarmonicsKey(input), count);

  /// Loads hardware [input]'s conditioning expander threshold in dB, or `null`
  /// if never saved (the caller defaults to `-55`).
  Future<double?> loadInputConditioningExpThresholdDb(int input) =>
      _store.getDouble(_inputCondExpThreshKey(input));

  /// Saves hardware [input]'s conditioning expander threshold in dB.
  Future<void> saveInputConditioningExpThresholdDb(int input, double db) =>
      _store.setDouble(_inputCondExpThreshKey(input), db);

  /// Loads hardware [input]'s conditioning expander ratio (`1:N`), or `null`
  /// if never saved (the caller defaults to `2.0`).
  Future<double?> loadInputConditioningExpRatio(int input) =>
      _store.getDouble(_inputCondExpRatioKey(input));

  /// Saves hardware [input]'s conditioning expander ratio.
  Future<void> saveInputConditioningExpRatio(int input, double ratio) =>
      _store.setDouble(_inputCondExpRatioKey(input), ratio);

  /// Loads hardware [input]'s conditioning expander release in ms, or `null`
  /// if never saved (the caller defaults to `150`).
  Future<double?> loadInputConditioningExpReleaseMs(int input) =>
      _store.getDouble(_inputCondExpReleaseKey(input));

  /// Saves hardware [input]'s conditioning expander release in ms.
  Future<void> saveInputConditioningExpReleaseMs(int input, double ms) =>
      _store.setDouble(_inputCondExpReleaseKey(input), ms);

  /// Loads hardware [input]'s loop-close restoration opt-in as a flag bitmask
  /// (`1` = denoise, `2` = declip), or `null` if never saved (the caller
  /// defaults to `0` — no restoration). The offline restoration worker itself
  /// is engine-side; this is the per-input opt-in the Dart trigger policy
  /// reads.
  Future<int?> loadInputRestore(int input) =>
      _store.getInt(_inputRestoreKey(input));

  /// Saves hardware [input]'s loop-close restoration opt-in [flags] bitmask
  /// (`1` = denoise, `2` = declip).
  Future<void> saveInputRestore(int input, int flags) =>
      _store.setInt(_inputRestoreKey(input), flags);

  // ---- structural output gate ----

  /// Loads hardware [output]'s gate flag on [device]. `null` means the key was
  /// never written, which (default-on) the caller reads as ENABLED; `false` is
  /// the only value ever stored (an explicitly-disabled output).
  ///
  /// A value stored under the legacy global key (`output_enabled.N`, pre
  /// device keying) is adopted by the first device that reads it: written
  /// under that device's key and removed. One-way and once — the global flag
  /// described whichever rig was patched when it was written, and the device
  /// in front of the player when the migration runs is the best owner it has.
  /// Any other interface starts default-on, which is the per-device point.
  Future<bool?> loadOutputEnabled({
    required String device,
    required int output,
  }) async {
    final stored = await _store.getBool(_outputEnabledKey(device, output));
    if (stored != null) return stored;
    final legacy = await _store.getBool(_legacyOutputEnabledKey(output));
    if (legacy == null) return null;
    await _store.setBool(_outputEnabledKey(device, output), value: legacy);
    await _store.remove(_legacyOutputEnabledKey(output));
    return legacy;
  }

  /// Persists hardware [output]'s gate on [device]. Default-on: an enabled
  /// output REMOVES the key (so absence == enabled and the set self-cleans);
  /// a disabled output writes `false`.
  Future<void> saveOutputEnabled({
    required String device,
    required int output,
    required bool enabled,
  }) async {
    if (enabled) {
      await _store.remove(_outputEnabledKey(device, output));
    } else {
      await _store.setBool(_outputEnabledKey(device, output), value: false);
    }
  }

  // ---- prior multi-lane monitor keys ----
  //
  // Written only by the v2 single-route → lanes migration (a cold-upgrade
  // stepping stone) and read once by the v3 single-chain fold, which then
  // clears them. The live app never touches these.

  /// Loads hardware [input]'s prior active monitor lane count, or `null`.
  Future<int?> loadMonitorLaneCount(int input) =>
      _store.getInt(_monitorLaneCountKey(input));

  /// Saves hardware [input]'s prior active monitor lane count (v2 migration).
  Future<void> saveMonitorLaneCount(int input, int count) =>
      _store.setInt(_monitorLaneCountKey(input), count);

  /// Loads monitor [input]'s prior lane [lane] output bitmask, or `null`.
  Future<int?> loadMonitorLaneOutput(int input, int lane) =>
      _store.getInt(_monitorLaneOutKey(input, lane));

  /// Saves monitor [input]'s prior lane [lane] output bitmask (v2 migration).
  Future<void> saveMonitorLaneOutput(int input, int lane, int mask) =>
      _store.setInt(_monitorLaneOutKey(input, lane), mask);

  /// Loads monitor [input]'s prior lane [lane] output gain, or `null`.
  Future<double?> loadMonitorLaneVolume(int input, int lane) =>
      _store.getDouble(_monitorLaneVolKey(input, lane));

  /// Saves monitor [input]'s prior lane [lane] output gain (v2 migration).
  Future<void> saveMonitorLaneVolume(int input, int lane, double volume) =>
      _store.setDouble(_monitorLaneVolKey(input, lane), volume);

  /// Loads monitor [input]'s prior lane [lane] mute flag, or `null`.
  Future<bool?> loadMonitorLaneMute(int input, int lane) =>
      _store.getBool(_monitorLaneMuteKey(input, lane));

  /// Loads monitor [input]'s prior lane [lane] effect chain (encoded), or
  /// `null`.
  Future<String?> loadMonitorLaneEffects(int input, int lane) =>
      _store.getString(_monitorLaneFxKey(input, lane));

  /// Saves monitor [input]'s lane [lane] [encoded] effect chain (v2 migration).
  Future<void> saveMonitorLaneEffects(int input, int lane, String encoded) =>
      _store.setString(_monitorLaneFxKey(input, lane), encoded);

  /// Clears hardware [input]'s prior multi-lane monitor keys for lanes
  /// `[0, laneCount)` (count + per-lane out/vol/mute/fx) once the v3 fold has
  /// converted them, so a later restore cannot resurrect multi-lane state.
  Future<void> clearMonitorLaneKeys(int input, int laneCount) async {
    await _store.remove(_monitorLaneCountKey(input));
    for (var lane = 0; lane < laneCount; lane++) {
      await _store.remove(_monitorLaneOutKey(input, lane));
      await _store.remove(_monitorLaneVolKey(input, lane));
      await _store.remove(_monitorLaneMuteKey(input, lane));
      await _store.remove(_monitorLaneFxKey(input, lane));
    }
  }

  /// Keyed per SERIAL, the same shape [saveInputName] and
  /// [saveLatencyOffsetFrames] use. The name is a name for *this box*, and a
  /// profile carried to a second console would otherwise arrive claiming to
  /// be the first one.
  String _consoleNameKey(String serial) => 'console_name.$serial';

  /// Loads the name given to the console with [serial], or `null` when it
  /// still answers to the name the appliance shipped with.
  Future<String?> loadConsoleName(String serial) =>
      _store.getString(_consoleNameKey(serial));

  /// Saves the given [name] for the console with [serial].
  Future<void> saveConsoleName(String serial, String name) =>
      _store.setString(_consoleNameKey(serial), name);

  /// Forgets the given name, handing the box back the one it shipped with.
  Future<void> clearConsoleName(String serial) =>
      _store.remove(_consoleNameKey(serial));

  String _trackNameKey(int channel) => 'track_name.$channel';

  /// Loads the custom display name for track [channel], or `null` if unset.
  Future<String?> loadTrackName(int channel) =>
      _store.getString(_trackNameKey(channel));

  /// Saves the custom display [name] for track [channel].
  Future<void> saveTrackName(int channel, String name) =>
      _store.setString(_trackNameKey(channel), name);

  /// Keyed per DEVICE and socket, the same shape [saveLatencyOffsetFrames]
  /// uses. Input 1 on a Scarlett and input 1 on the built-in pair are different
  /// jacks with different things plugged into them; one name for both would
  /// describe whichever rig was patched last.
  String _inputNameKey(String device, int input) => 'input_name.$device.$input';

  /// Loads the given name for [input] on [device], or `null` if it has none.
  Future<String?> loadInputName({
    required String device,
    required int input,
  }) => _store.getString(_inputNameKey(device, input));

  /// Saves the given [name] for [input] on [device].
  Future<void> saveInputName({
    required String device,
    required int input,
    required String name,
  }) => _store.setString(_inputNameKey(device, input), name);

  /// Forgets [input]'s given name on [device], handing the socket back its
  /// ordinal.
  ///
  /// Removed rather than stored as an empty string: an input's fallback is not
  /// a name it was given, and a stored `''` would be a name the next reader has
  /// to know to ignore. A track has no equivalent — its fallback IS a name.
  Future<void> clearInputName({
    required String device,
    required int input,
  }) => _store.remove(_inputNameKey(device, input));

  String _trackQuantizeKey(int channel) => 'track_quantize.$channel';

  /// Loads track [channel]'s quantize override: `null` (inherit the global
  /// default), `false` (force off), or `true` (force on).
  Future<bool?> loadTrackQuantize(int channel) async {
    final value = await _store.getInt(_trackQuantizeKey(channel));
    if (value == null || value < 0) return null;
    return value > 0;
  }

  /// Saves track [channel]'s quantize override (`null` => inherit).
  Future<void> saveTrackQuantize(int channel, {required bool? enabled}) =>
      _store.setInt(
        _trackQuantizeKey(channel),
        enabled == null ? -1 : (enabled ? 1 : 0),
      );

  String _laneCountKey(int channel) => 'lane_count.$channel';
  String _laneInputKey(int channel, int lane) => 'lane_input.$channel.$lane';
  String _laneOutputKey(int channel, int lane) => 'lane_output.$channel.$lane';
  String _laneVolKey(int channel, int lane) => 'lane_vol.$channel.$lane';
  String _laneMuteKey(int channel, int lane) => 'lane_mute.$channel.$lane';
  String _laneEffectsKey(int channel, int lane) =>
      'lane_effects.$channel.$lane';

  /// Loads track [channel]'s saved active lane count, or `1` if unset.
  Future<int> loadLaneCount(int channel) async =>
      await _store.getInt(_laneCountKey(channel)) ?? 1;

  /// Saves track [channel]'s active lane [count].
  Future<void> saveLaneCount(int channel, int count) =>
      _store.setInt(_laneCountKey(channel), count);

  /// Loads lane [lane] of track [channel]'s recorded input channel (`-1` =
  /// none), or `null` if unset.
  Future<int?> loadLaneInput(int channel, int lane) =>
      _store.getInt(_laneInputKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s recorded [inputChannel].
  Future<void> saveLaneInput(int channel, int lane, int inputChannel) =>
      _store.setInt(_laneInputKey(channel, lane), inputChannel);

  /// Loads lane [lane] of track [channel]'s output bitmask, or `null` if unset.
  Future<int?> loadLaneOutput(int channel, int lane) =>
      _store.getInt(_laneOutputKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s output [mask].
  Future<void> saveLaneOutput(int channel, int lane, int mask) =>
      _store.setInt(_laneOutputKey(channel, lane), mask);

  /// Loads lane [lane] of track [channel]'s playback volume, or `null` if
  /// unset.
  Future<double?> loadLaneVolume(int channel, int lane) =>
      _store.getDouble(_laneVolKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s playback [volume].
  Future<void> saveLaneVolume(int channel, int lane, double volume) =>
      _store.setDouble(_laneVolKey(channel, lane), volume);

  /// Loads lane [lane] of track [channel]'s mute state, or `null` if unset.
  Future<bool?> loadLaneMute(int channel, int lane) =>
      _store.getBool(_laneMuteKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s [muted] state.
  Future<void> saveLaneMute(int channel, int lane, {required bool muted}) =>
      _store.setBool(_laneMuteKey(channel, lane), value: muted);

  /// Loads lane [lane] of track [channel]'s persisted effect chain as an opaque
  /// encoded string (see `encodeTrackEffects`), or `null` if none is saved.
  Future<String?> loadLaneEffects(int channel, int lane) =>
      _store.getString(_laneEffectsKey(channel, lane));

  /// Saves lane [lane] of track [channel]'s [encoded] effect chain.
  Future<void> saveLaneEffects(int channel, int lane, String encoded) =>
      _store.setString(_laneEffectsKey(channel, lane), encoded);

  /// Clears lane [lane] of track [channel]'s persisted chain, so the boot
  /// restore reads it back as "no chain" rather than as the last value written.
  ///
  /// For a session load that leaves a lane with no chain: there is no envelope
  /// to overwrite the key with, and the old string would otherwise be restored
  /// on the next launch. Deletes rather than writing an empty envelope (which
  /// the boot restore reads identically) so the key set self-cleans — the same
  /// posture as [saveOutputEnabled]'s default-on removal.
  Future<void> clearLaneEffects(int channel, int lane) =>
      _store.remove(_laneEffectsKey(channel, lane));

  String _trackFxChainKey(int channel) => 'track_fx_chain.$channel';
  static const String _masterFxChainKey = 'master_fx_chain';

  /// Loads track [channel]'s persisted Track-stage (stereo bus) chain as an
  /// opaque encoded envelope string (see `encodeFxChain`), or `null` if none
  /// is saved. The chain-enabled flag rides inside the envelope — no separate
  /// per-flag key exists (R15).
  Future<String?> loadTrackFxChain(int channel) =>
      _store.getString(_trackFxChainKey(channel));

  /// Saves track [channel]'s [encoded] Track-stage chain envelope.
  Future<void> saveTrackFxChain(int channel, String encoded) =>
      _store.setString(_trackFxChainKey(channel), encoded);

  /// Clears track [channel]'s persisted Track-stage chain envelope — the bus
  /// twin of [clearLaneEffects], for a session load that drops a chain the
  /// live rig carried.
  ///
  /// There is no Master equivalent: the Master envelope always has a value
  /// (the empty enabled chain when none is configured), so a load overwrites
  /// it rather than needing it cleared.
  Future<void> clearTrackFxChain(int channel) =>
      _store.remove(_trackFxChainKey(channel));

  /// Loads the persisted Master insert chain as an opaque encoded envelope
  /// string (see `encodeFxChain`), or `null` if none is saved.
  Future<String?> loadMasterFxChain() => _store.getString(_masterFxChainKey);

  /// Saves the [encoded] Master insert chain envelope.
  Future<void> saveMasterFxChain(String encoded) =>
      _store.setString(_masterFxChainKey, encoded);

  static const String _updateAutoCheckKey = 'updates.auto_check';
  static const String _updateChannelKey = 'updates.channel';
  static const String _updateDismissedKey = 'updates.dismissed';

  /// Whether the app runs the passive, read-only update check automatically.
  /// Defaults to `true` (checking is read-only; applying stays opt-in).
  Future<bool> loadUpdateAutoCheck() async =>
      await _store.getBool(_updateAutoCheckKey) ?? true;

  /// Persists whether the passive update check runs automatically.
  Future<void> saveUpdateAutoCheck({required bool value}) =>
      _store.setBool(_updateAutoCheckKey, value: value);

  /// Loads the user-selected update channel (`experimental` / `production`),
  /// or `null` when the user has never set one (fall back to the device's
  /// baked `/etc/segno/update-channel` marker).
  Future<String?> loadUpdateChannel() async {
    final raw = await _store.getString(_updateChannelKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  /// Persists the user-selected update channel.
  Future<void> saveUpdateChannel(String channel) =>
      _store.setString(_updateChannelKey, channel);

  /// Loads the set of update semantic versions whose notification the user
  /// dismissed. Stored as a comma-separated list of semver strings (the same
  /// encoded-scalar idiom as [loadLaneEffects]); bad entries are ignored.
  Future<Set<Version>> loadDismissedUpdateVersions() async {
    final raw = await _store.getString(_updateDismissedKey);
    if (raw == null || raw.isEmpty) return const {};
    return raw
        .split(',')
        .map((s) {
          try {
            return Version.parse(s.trim());
          } on FormatException {
            return null;
          }
        })
        .whereType<Version>()
        .toSet();
  }

  /// Saves the set of dismissed update semantic versions (sorted,
  /// comma-separated).
  Future<void> saveDismissedUpdateVersions(Set<Version> versions) =>
      _store.setString(
        _updateDismissedKey,
        (versions.toList()..sort()).join(','),
      );

  /// Clears all settings.
  Future<void> clear() => _store.clear();
}
