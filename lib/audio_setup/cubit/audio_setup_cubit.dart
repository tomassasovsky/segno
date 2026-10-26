import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
// Settings owns its own AudioBackend, mapped to/from the looper domain backend
// at the persistence boundary; prefixed only for that enum so the unprefixed
// AudioBackend stays the domain one.
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;
import 'package:settings_repository/settings_repository.dart'
    as persisted
    show AudioBackend;

part 'audio_setup_state.dart';

/// Maps the looper domain backend to the settings layer's own backend enum.
/// An exhaustive switch so adding a backend is a compile error here rather than
/// a runtime failure from a name lookup.
persisted.AudioBackend settingsBackendOf(AudioBackend backend) =>
    switch (backend) {
      AudioBackend.miniaudio => persisted.AudioBackend.miniaudio,
      AudioBackend.asio => persisted.AudioBackend.asio,
    };

/// Maps the settings layer's persisted backend to the looper domain backend.
AudioBackend engineBackendOf(persisted.AudioBackend backend) =>
    switch (backend) {
      persisted.AudioBackend.miniaudio => AudioBackend.miniaudio,
      persisted.AudioBackend.asio => AudioBackend.asio,
    };

/// Manages the audio device options (device, sample rate, buffer size, maximum
/// loop length) and surfaces the live engine status.
///
/// Every change goes through one guarded apply (#1270 Part 3a): it is refused
/// while a take runs, ignored while the loops lock it (the sample rate and
/// the loop cap clear the engine), refused when the effects would not fit at
/// the new rate or buffer, confirmed first when music is playing, and applied
/// by reopening the device so the loops stay. The config is saved only once
/// the device has opened it.
class AudioSetupCubit extends Cubit<AudioSetupState> {
  /// Creates an [AudioSetupCubit] backed by [repository], persisting the
  /// config through [settings]. [guards] is the app's operation table, and
  /// [backing] the backing player an apply stops along with the tracks.
  AudioSetupCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    required GuardRegistry guards,
    required BackingRepository backing,
    Duration deviceRefreshInterval = const Duration(seconds: 1),
  }) : _repository = repository,
       _settings = settings,
       _guards = guards,
       _backing = backing,
       _deviceRefreshInterval = deviceRefreshInterval,
       super(const AudioSetupState()) {
    _subscription = _repository.looperState.listen(_onLooperState);

    // Hydrate from the repository immediately — [looperState] is a broadcast
    // stream that does not replay, so a new cubit would otherwise show defaults
    // until the next engine tick even when the device is already open.
    emit(
      _projectFromRepository(
        _repository.state,
        current: state.copyWith(
          loopback: _repository.detectLoopback(),
          devices: _repository.devices(),
        ),
        hydrateConfig: true,
      ),
    );
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  final GuardRegistry _guards;
  final BackingRepository _backing;
  late final StreamSubscription<LooperState> _subscription;

  /// Cadence of the gated re-enumeration poll (see [beginDeviceScan]).
  ///
  /// A non-positive interval means DO NOT re-enumerate periodically at all.
  /// That is for a harness whose device list never changes: a widget test
  /// verifies its invariants before any tearDown runs, so a periodic timer
  /// left live for the length of the test body fails it however promptly the
  /// cubit is closed afterwards.
  final Duration _deviceRefreshInterval;

  Timer? _deviceRefreshTimer;

  /// How many device pickers are mounted. A count rather than a flag: a route
  /// transition can have the incoming surface mount before the outgoing one
  /// disposes, and the poll must not stop underneath the new one.
  int _deviceScanners = 0;

  /// The device profile whose saved offset was last applied, so it is
  /// applied once per profile.
  String? _hydratedDeviceKey;

  /// The request waiting on the "Apply audio settings?" answer.
  AudioSetupState? _pending;

  /// Previous pinned-device presence, to detect lost/restored transitions; and
  /// the last device name seen while present, so a disconnect banner can name
  /// the device even after the snapshot stops reporting it.
  bool? _lastDevicePresent;
  String _lastPresentDeviceName = '';

  /// Selects the requested sample rate and applies it (see [AudioSetupCubit]).
  void setSampleRate(int sampleRate) {
    if (sampleRate == state.sampleRate && !_failed) return;
    _requestApply(state.copyWith(sampleRate: sampleRate));
  }

  /// Selects the requested buffer size and applies it.
  void setBufferFrames(int bufferFrames) {
    if (bufferFrames == state.bufferFrames && !_failed) return;
    _requestApply(state.copyWith(bufferFrames: bufferFrames));
  }

  /// Sets the maximum per-track loop length in whole [minutes] (`0` = engine
  /// default) and applies it: the engine reserves the loop memory when the
  /// device opens.
  void setMaxLoopMinutes(int minutes) {
    if (minutes == state.maxLoopMinutes && !_failed) return;
    _requestApply(state.copyWith(maxLoopMinutes: minutes));
  }

  /// Selects the playback device to open (empty id = system default).
  void setPlaybackDevice(String deviceId) =>
      _selectDevice(playbackDeviceId: deviceId);

  /// Selects the capture device to open (empty id = system default).
  void setCaptureDevice(String deviceId) =>
      _selectDevice(captureDeviceId: deviceId);

  /// Pins both directions of one interface at once.
  ///
  /// The console shows ONE Device row, because an interface is one box even
  /// though the host lists its playback and capture halves separately. Setting
  /// them through [setPlaybackDevice] and [setCaptureDevice] in turn would
  /// apply twice for a single tap.
  void setDevice({
    required String playbackDeviceId,
    required String captureDeviceId,
  }) {
    if (playbackDeviceId == state.playbackDeviceId &&
        captureDeviceId == state.captureDeviceId &&
        !_failed) {
      return;
    }
    _requestApply(
      state.copyWith(
        playbackDeviceId: playbackDeviceId,
        captureDeviceId: captureDeviceId,
      ),
    );
  }

  void _selectDevice({String? playbackDeviceId, String? captureDeviceId}) {
    assert(
      (playbackDeviceId != null) ^ (captureDeviceId != null),
      'Either playbackDeviceId or captureDeviceId must be provided, '
      'but not both',
    );

    if (playbackDeviceId == state.playbackDeviceId ||
        captureDeviceId == state.captureDeviceId) {
      return;
    }
    _requestApply(
      state.copyWith(
        playbackDeviceId: playbackDeviceId,
        captureDeviceId: captureDeviceId,
      ),
    );
  }

  /// Whether the last open failed and nothing runs: then the selection on
  /// screen is not running either, and tapping it again is how to retry.
  bool get _failed => state.status == AudioSetupStatus.error;

  /// Applies [next] now, or asks first when music is playing (pen 28/04).
  void _requestApply(AudioSetupState next) {
    if (!_admit(next)) return;
    if (_musicPlaying) {
      _pending = next;
      emit(
        state.copyWith(applyPhase: ApplyPhase.confirming, clearRefusal: true),
      );
      return;
    }
    _apply(next);
  }

  /// "Stop audio and apply": checks the waiting request again (a take may
  /// have started while the question was open), stops the tracks and the
  /// backing track, and applies it.
  void confirmApply() {
    final next = _pending;
    if (next == null) return;
    _pending = null;
    emit(state.copyWith(applyPhase: ApplyPhase.idle));
    if (!_admit(next)) return;
    for (final track in _repository.state.tracks) {
      _repository.stopTrack(channel: track.channel);
    }
    if (_backing.state.playing) _backing.stop();
    _apply(next);
  }

  /// Cancel on "Apply audio settings?": nothing changes.
  void cancelApply() {
    if (_pending == null) return;
    _pending = null;
    emit(state.copyWith(applyPhase: ApplyPhase.idle));
  }

  /// Whether music would be cut by an apply: a track plays, or the backing
  /// track does.
  bool get _musicPlaying =>
      _repository.state.isPlaying || _backing.state.playing;

  /// The checks every request passes before it may apply, in order (D3, D2,
  /// D19). A refusal is shown and nothing changes; a locked change is only
  /// ignored, because its control is already drawn disabled with the reason.
  bool _admit(AudioSetupState next) {
    final busy = _busyKind();
    if (busy != null) {
      emit(state.copyWith(refusal: ApplyRefusal.busy(busy)));
      return false;
    }
    final looper = _repository.state;
    if (looper.hasContent &&
        (next.sampleRate != state.sampleRate ||
            next.maxLoopMinutes != state.maxLoopMinutes)) {
      return false;
    }
    final overBudget = _overBudget(next);
    if (overBudget != null) {
      emit(state.copyWith(refusal: overBudget));
      return false;
    }
    return true;
  }

  /// What a take in flight is called in the guard table's terms, or `null`
  /// when nothing would be cut: a track recording, overdubbing, waiting on a
  /// quantized or signal start or on the Count-in, or a performance capture
  /// (or anything else the table says a device change must not overlap).
  String? _busyKind() {
    final looper = _repository.state;
    final takeRunning =
        looper.transport.countingIn ||
        looper.tracks.any(
          (t) => t.isCapturing || t.pending || t.pendingLaunch != null,
        );
    if (takeRunning) return GuardKind.capture.name;
    final blockers = _guards.blockers(
      GuardKind.deviceChange,
      const GuardScope.internal(),
    );
    return blockers.isEmpty ? null : blockers.first.kind.name;
  }

  /// The refusal for a change that would leave the effects no room (#887,
  /// owner's Q5 answer, D19), or `null`. Only a change that shrinks the room
  /// is checked, and with buffers of 64 frames and up only a higher rate does
  /// (the per-frame costs only grow below the 64-frame block they were
  /// measured at). A lower rate or another buffer is never refused, as an
  /// effects removal never is.
  ApplyRefusal? _overBudget(AudioSetupState next) {
    if (next.sampleRate <= state.sampleRate) return null;
    if (_repository.fxRoomAt(next.sampleRate, next.bufferFrames) >= 0) {
      return null;
    }
    return ApplyRefusal.overBudgetRate(next.sampleRate);
  }

  /// Opens the device at [next] under the device-change guard, keeping the
  /// loops ([LooperRepository.applyAudioConfig]), and saves [next] only once
  /// it is open (D1). A refused config leaves the previous one running, on
  /// screen and on disk.
  void _apply(AudioSetupState next) {
    final OperationGuard guard;
    try {
      guard = _guards.enter(
        GuardKind.deviceChange,
        const GuardScope.internal(),
        purpose: 'audio settings',
      );
    } on GuardRefused catch (refused) {
      emit(
        state.copyWith(
          refusal: ApplyRefusal.busy(refused.blockers.first.kind.name),
        ),
      );
      return;
    }
    try {
      _applyGuarded(next);
    } finally {
      guard.release();
    }
  }

  void _applyGuarded(AudioSetupState next) {
    // An intentional (re)apply resets the standing connectivity condition
    // (#453): the lost banner must not outlive the user acting on it, and the
    // app's own stop and reopen below must not read as an unplug. The
    // repository's reconnect supervisor never passes through here, so a REAL
    // unplug's lost/restored pair is untouched.
    _lastDevicePresent = null;
    final askedRate = next.sampleRate;
    final askedBuffer = next.bufferFrames;
    final outcome = _repository.applyAudioConfig(_engineConfig(next));
    final live = _repository.state.status;
    // What the attempt did with the loops is told whatever else happened
    // (rule 3: no silent changes).
    final lost = _restoredConnectivity(outcome.reopen);
    final notice = lost == DeviceConnectivity.restored
        ? DeviceConnectivity.none
        : lost;
    switch (outcome.status) {
      case AudioApplyStatus.waiting:
        // Neither config would open, and the previous one stays pinned and
        // supervised (D17): the stage shows the loss, and audio comes back on
        // its own when the interface answers, as after an unplug.
        _lastDevicePresent = false;
        emit(
          state.copyWith(
            status: AudioSetupStatus.error,
            phase: ConfigPhase.settled,
            error: AudioSetupError.openDeviceFailed,
            errorDetail: outcome.result.name,
            deviceConnectivity: DeviceConnectivity.lost,
            connectivityDeviceName: _lastPresentDeviceName,
            clearRefusal: true,
          ),
        );
      case AudioApplyStatus.failed:
        // Nothing runs: the selection stays what it was, nothing is saved,
        // and the failure is the fact to surface.
        emit(
          state.copyWith(
            status: AudioSetupStatus.error,
            phase: ConfigPhase.settled,
            error: AudioSetupError.openDeviceFailed,
            errorDetail: outcome.result.name,
            deviceConnectivity: notice,
            clearRefusal: true,
          ),
        );
      case AudioApplyStatus.refused
          when outcome.result == EngineResult.notReady:
        // The repository would not reopen at all (a Session apply, a boot
        // fence, a settings recovery): nothing was touched.
        emit(state.copyWith(refusal: const ApplyRefusal.busy('other')));
      case AudioApplyStatus.refused
          when askedRate == state.sampleRate &&
              askedBuffer == state.bufferFrames:
        // Naming rates that did not move would say nothing. A device the
        // interface would not open is named; anything else (a loop cap, a
        // retry) says the settings were refused. The previous config runs.
        final deviceMoved =
            next.playbackDeviceId != state.playbackDeviceId ||
            next.captureDeviceId != state.captureDeviceId;
        emit(
          state.copyWith(
            status: AudioSetupStatus.running,
            clearError: true,
            refusal: deviceMoved
                ? ApplyRefusal.deviceRefused(_deviceName(next))
                : const ApplyRefusal.settingsRefused(),
            phase: ConfigPhase.settled,
            deviceConnectivity: notice,
          ),
        );
      case AudioApplyStatus.refused:
        // The previous config is open again. The chips keep showing it, and
        // the banner names what was asked and what is running.
        emit(
          state.copyWith(
            status: AudioSetupStatus.running,
            clearError: true,
            clearRefusal: true,
            phase: ConfigPhase.refused,
            requestedRate: askedRate,
            requestedBuffer: askedBuffer,
            actualRate: live.sampleRate > 0
                ? live.sampleRate
                : state.sampleRate,
            actualBuffer: live.bufferFrames > 0
                ? live.bufferFrames
                : state.bufferFrames,
            deviceConnectivity: notice,
          ),
        );
      case AudioApplyStatus.applied:
        _settle(next, live: live, reopen: outcome.reopen);
    }
  }

  /// The name the host gives the interface [config] pins, or its id.
  String _deviceName(AudioSetupState config) {
    final id = config.playbackDeviceId.isNotEmpty
        ? config.playbackDeviceId
        : config.captureDeviceId;
    for (final device in state.devices) {
      if (device.id == id) return device.name;
    }
    return id.isNotEmpty ? id : _lastPresentDeviceName;
  }

  /// The opened config: the selection follows what the device negotiated,
  /// as far as the chooser can show it, and that is what is saved.
  void _settle(
    AudioSetupState next, {
    required EngineStatus live,
    required EngineReopened? reopen,
  }) {
    final askedRate = next.sampleRate;
    final askedBuffer = next.bufferFrames;
    // `applyAudioConfig` is synchronous, so the snapshot already describes the
    // open device; waiting for the stream would never settle, because the
    // repository drops a tick whose projection is unchanged.
    final known = live.sampleRate > 0 && live.bufferFrames > 0;
    final actualRate = known ? live.sampleRate : askedRate;
    final actualBuffer = known ? live.bufferFrames : askedBuffer;
    final gave = actualRate == askedRate && actualBuffer == askedBuffer;
    // A row that says 96 kHz while the engine runs 48 would be a lie, and a
    // row saying 480 when the grid only offers 64/128/256/512 another, with no
    // chip lit and no way back. So an off-list figure stays out of the
    // selection and the banner names it.
    final rate = _offerable(actualRate, AudioSetupState.sampleRates, askedRate);
    final buffer = _offerable(
      actualBuffer,
      AudioSetupState.bufferSizes,
      askedBuffer,
    );
    // What the reopen did with the loops is reported here (rule 3: no silent
    // changes): a cold start carries a reconnect verdict its rollback left
    // pending (#1140), and a reopen its own.
    final carried = _restoredConnectivity(reopen ?? live.reopen);
    final settled = state.copyWith(
      maxLoopMinutes: next.maxLoopMinutes,
      playbackDeviceId: next.playbackDeviceId,
      captureDeviceId: next.captureDeviceId,
      status: AudioSetupStatus.running,
      clearError: true,
      clearRefusal: true,
      sampleRate: rate,
      bufferFrames: buffer,
      phase: gave ? ConfigPhase.settled : ConfigPhase.refused,
      requestedRate: askedRate,
      requestedBuffer: askedBuffer,
      actualRate: actualRate,
      actualBuffer: actualBuffer,
      engineStatus: live,
      deviceConnectivity: carried == DeviceConnectivity.restored
          ? DeviceConnectivity.none
          : carried,
      connectivityDeviceName: live.deviceName.isNotEmpty
          ? live.deviceName
          : _lastPresentDeviceName,
    );
    emit(settled);
    unawaited(_settings.saveAudioConfig(_storedConfig(settled)));
  }

  /// [negotiated] when the chooser can show it, otherwise [asked].
  ///
  /// The selection may only ever hold a value from its own option list: it is
  /// what the chip grids check against and what gets persisted, so a device
  /// period outside [AudioSetupState.bufferSizes] — an ALSA quantum — would
  /// leave the grid with nothing selected and stay off-list across restarts.
  /// [AudioSetupState.actualBuffer] carries the real figure for the banner.
  int _offerable(int negotiated, List<int> options, int asked) =>
      negotiated > 0 && options.contains(negotiated) ? negotiated : asked;

  /// The engine configuration for [config]'s options and device selection.
  EngineConfig _engineConfig(AudioSetupState config) => EngineConfig(
    sampleRate: config.sampleRate,
    bufferFrames: config.bufferFrames,
    // Channel counts left at 0 (device default): a multichannel interface
    // opens with all its channels; the negotiated counts are reported back.
    maxLoopFrames: _loopCapFrames(config),
    // An explicitly chosen input device always wins: only auto-route capture to
    // a detected loopback when the user has not pinned a capture device.
    // Otherwise, on hosts where every output exposes a "monitor" capture source
    // (e.g. PipeWire), the loopback auto-route would silently commandeer the
    // capture path and ignore the selected interface.
    useLoopbackCapture:
        config.loopback.isAutoRoutable && config.captureDeviceId.isEmpty,
    playbackDeviceId: config.playbackDeviceId,
    captureDeviceId: config.captureDeviceId,
    backend: config.backend,
    asioDriver: config.asioDriver,
  );

  /// The loop cap to open [config] with, in frames: the cap open now while
  /// neither the cap nor the rate on screen moves, because one recomputed
  /// from a rounded minute count, or from a rate that was asked for and not
  /// run (the selection follows the running rate), would differ from it and
  /// make the reopen clear the loops (`LE_REOPEN_CLEARED_CAP`) on a change
  /// that must keep them. A real rate change recomputes it: the minutes
  /// mean more frames at a higher rate, and with material the rate is
  /// locked anyway.
  int _loopCapFrames(AudioSetupState config) {
    final open = _repository.lastEngineConfig;
    if (open != null &&
        config.maxLoopMinutes == state.maxLoopMinutes &&
        config.sampleRate == state.sampleRate) {
      return open.maxLoopFrames;
    }
    return _maxLoopFrames(config.maxLoopMinutes, config.sampleRate);
  }

  /// The persisted form of [config].
  StoredAudioConfig _storedConfig(AudioSetupState config) => StoredAudioConfig(
    sampleRate: config.sampleRate,
    bufferFrames: config.bufferFrames,
    maxLoopMinutes: config.maxLoopMinutes,
    playbackDeviceId: config.playbackDeviceId,
    captureDeviceId: config.captureDeviceId,
    // Map the domain backend to the settings layer's own enum.
    backend: settingsBackendOf(config.backend),
    asioDriver: config.asioDriver,
  );

  /// Converts a minute cap to engine frames at [sampleRate]; `0` (engine
  /// default) stays `0`. Inverse of [_maxLoopMinutes].
  static int _maxLoopFrames(int minutes, int sampleRate) =>
      minutes <= 0 || sampleRate <= 0 ? 0 : minutes * 60 * sampleRate;

  /// Converts an engine frame cap back to whole minutes at [sampleRate]; `0`
  /// stays `0`. Inverse of [_maxLoopFrames].
  static int _maxLoopMinutes(int? frames, int sampleRate) =>
      frames == null || frames <= 0 || sampleRate <= 0
      ? 0
      : (frames / (60 * sampleRate)).round();

  /// Starts (or joins) the device re-enumeration poll, and re-enumerates once
  /// straight away so an interface plugged in while nothing was watching shows
  /// up on the frame the picker opens rather than a tick later.
  ///
  /// **Gated, because enumeration is not free.** It runs synchronously on the
  /// UI isolate, and #649 measured 0.146 ms/tick on the appliance's
  /// `/proc/asound/cards` path but 950 ms/tick on the miniaudio fall-through —
  /// which is the path the appliance takes whenever an interface is unplugged
  /// (`engine_devices.c`), i.e. exactly when the user is trying to get audio
  /// back. Polling it once a second from boot, on every screen, for a list
  /// only a picker renders, was paying that forever.
  ///
  /// Nothing else needs the list: the connectivity banner rides
  /// `looperState.status.devicePresent` (see [_detectConnectivity]) and
  /// `AudioRecoveryCubit` enumerates through the repository itself. Owned by
  /// `AudioDeviceScanScope`, the way `CacheTelemetryScope` owns cache
  /// telemetry (#418) — call [endDeviceScan] once per call to this.
  void beginDeviceScan() {
    _deviceScanners++;
    if (_deviceScanners > 1) return;
    refreshDevices();
    if (_deviceRefreshInterval <= Duration.zero) return;
    _deviceRefreshTimer = Timer.periodic(
      _deviceRefreshInterval,
      (_) => refreshDevices(),
    );
  }

  /// Drops one [beginDeviceScan] claim; the poll stops when the last one goes.
  void endDeviceScan() {
    if (_deviceScanners == 0) return;
    _deviceScanners--;
    if (_deviceScanners > 0) return;
    _deviceRefreshTimer?.cancel();
    _deviceRefreshTimer = null;
  }

  /// Re-enumerates the host's audio devices and updates the picker when the
  /// set changed (an unchanged list is deduped by the state's value equality,
  /// so this is a no-op when nothing was plugged in or removed). Driven by the
  /// gated refresh timer; also safe to call directly.
  void refreshDevices() {
    if (isClosed) return;
    emit(state.copyWith(devices: _repository.devices()));
  }

  void _onLooperState(LooperState looper) {
    emit(_projectFromRepository(looper, current: state));
    _detectConnectivity(looper.status);
    unawaited(_syncLatencyPersistence(looper.status));
  }

  /// Whether the boot-time recovery waits for the pinned interface
  /// (`AudioRecoveryCubit`), so the stage says so on its one strip rather
  /// than a toast beside the engine-stopped banner (#860, #1270 Part 5).
  /// Any other condition already on the strip outranks it.
  void setWaitingForDevice({required bool waiting}) {
    final current = state.deviceConnectivity;
    if (waiting && current == DeviceConnectivity.none) {
      emit(state.copyWith(deviceConnectivity: DeviceConnectivity.waiting));
    } else if (!waiting && current == DeviceConnectivity.waiting) {
      emit(state.copyWith(deviceConnectivity: DeviceConnectivity.none));
    }
  }

  /// Ends the standing material notice ([DeviceConnectivity.restoredCleared])
  /// once the user has acted on it — opened the Library from its
  /// action — the way a deliberate re-apply ends every connectivity condition.
  void dismissReopenNotice() {
    if (state.deviceConnectivity != DeviceConnectivity.restoredCleared) return;
    emit(state.copyWith(deviceConnectivity: DeviceConnectivity.none));
  }

  /// Diffs `devicePresent` against the previous tick and raises a transient
  /// lost/restored banner trigger for a pinned device. The system default is
  /// not flagged (it is never auto-restarted, so a banner would be noise).
  ///
  /// A return carries the reconnect's verdict on the loops
  /// ([EngineStatus.reopen], #1140): one notice per return — the plain
  /// restored snack when everything survived, a transient toast naming the
  /// dropped tracks on a partial retention, the standing cleared banner with
  /// the Sessions action when the device came back at another rate. Never
  /// two notices for one cause (#860).
  void _detectConnectivity(EngineStatus status) {
    final pinned =
        state.playbackDeviceId.isNotEmpty || state.captureDeviceId.isNotEmpty;
    final present = status.devicePresent;
    final previous = _lastDevicePresent;
    _lastDevicePresent = present;
    if (present && status.deviceName.isNotEmpty) {
      _lastPresentDeviceName = status.deviceName;
    }
    if (present && state.deviceConnectivity == DeviceConnectivity.waiting) {
      // The awaited interface is here and running: the strip has nothing
      // left to say, and a "reconnected" toast for a first start would be a
      // notice with no loss behind it.
      emit(state.copyWith(deviceConnectivity: DeviceConnectivity.none));
      return;
    }
    if (!pinned || previous == null || previous == present) return;
    emit(
      state.copyWith(
        deviceConnectivity: present
            ? _restoredConnectivity(status.reopen)
            : DeviceConnectivity.lost,
        connectivityDeviceName: _lastPresentDeviceName,
      ),
    );
  }

  static DeviceConnectivity _restoredConnectivity(EngineReopened? reopen) {
    if (reopen == null || reopen.retainedAll) {
      return DeviceConnectivity.restored;
    }
    return reopen.keepsMaterial
        ? DeviceConnectivity.restoredPartial
        : DeviceConnectivity.restoredCleared;
  }

  /// Sets the record offset saved for the open device, rate and buffer, or 0
  /// when they were never measured, once per profile (#1270 Part 3a). A
  /// device change, a new rate or buffer, or a reconnect each lands here, so
  /// an offset measured on one profile never compensates another. Nothing is
  /// saved here: only a measurement saves an offset.
  Future<void> _syncLatencyPersistence(EngineStatus status) async {
    if (!status.isConnected || status.deviceName.isEmpty) return;
    final deviceKey =
        '${status.deviceName}|${status.sampleRate}|${status.bufferFrames}';
    if (_hydratedDeviceKey == deviceKey) return;
    _hydratedDeviceKey = deviceKey;
    final saved = await _settings.loadLatencyOffsetFrames(
      device: status.deviceName,
      sampleRate: status.sampleRate,
      bufferFrames: status.bufferFrames,
    );
    if (isClosed || _hydratedDeviceKey != deviceKey) return;
    final offset = saved != null && saved > 0 ? saved : 0;
    if (offset != status.recordOffsetFrames) {
      _repository.setRecordOffset(offset);
    }
  }

  AudioSetupState _projectFromRepository(
    LooperState looper, {
    required AudioSetupState current,
    bool hydrateConfig = false,
  }) {
    final engineStatus = looper.status;
    final lastConfig = _repository.lastEngineConfig;

    // The sample-rate / buffer selectors reflect the user's *requested* values,
    // not what the engine negotiated. On hydrate we resolve from the saved
    // config; on every other tick we keep the current selection. (Pulling the
    // engine-reported value back into the selection drifts it from what was
    // picked — and, since changes persist, poisons the saved config. The
    // STATUS table shows the engine's actual values separately.)
    final resolvedSampleRate = hydrateConfig
        ? _resolvedOption(
            negotiated: engineStatus.sampleRate,
            requested: lastConfig?.sampleRate,
            fallback: current.sampleRate,
          )
        : current.sampleRate;

    return current.copyWith(
      sampleRate: resolvedSampleRate,
      bufferFrames: hydrateConfig
          ? _resolvedOption(
              negotiated: engineStatus.bufferFrames,
              requested: lastConfig?.bufferFrames,
              fallback: current.bufferFrames,
            )
          : current.bufferFrames,
      maxLoopMinutes: hydrateConfig
          ? _maxLoopMinutes(lastConfig?.maxLoopFrames, resolvedSampleRate)
          : current.maxLoopMinutes,
      playbackDeviceId: hydrateConfig
          ? lastConfig?.playbackDeviceId ?? current.playbackDeviceId
          : current.playbackDeviceId,
      captureDeviceId: hydrateConfig
          ? lastConfig?.captureDeviceId ?? current.captureDeviceId
          : current.captureDeviceId,
      // Carried through to the engine and the saved config until those
      // fields go (#1270 Part 2).
      backend: hydrateConfig
          ? lastConfig?.backend ?? AudioBackend.miniaudio
          : current.backend,
      asioDriver: hydrateConfig
          ? lastConfig?.asioDriver ?? current.asioDriver
          : current.asioDriver,
      hasContent: looper.hasContent,
      engineStatus: engineStatus,
      status: engineStatus.isConnected
          ? AudioSetupStatus.running
          : current.status == AudioSetupStatus.error
          ? AudioSetupStatus.error
          : AudioSetupStatus.stopped,
    );
  }

  int _resolvedOption({
    required int negotiated,
    required int? requested,
    required int fallback,
  }) {
    if (negotiated > 0) return negotiated;
    if (requested != null && requested > 0) return requested;
    return fallback;
  }

  @override
  Future<void> close() {
    _deviceRefreshTimer?.cancel();
    unawaited(_subscription.cancel());
    return super.close();
  }
}
