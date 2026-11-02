import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/logging/app_log.dart';
import 'package:settings_repository/settings_repository.dart';

part 'audio_setup_state.dart';

/// Manages the audio device options (device, sample rate, buffer size, maximum
/// loop length) and surfaces the live engine status.
///
/// Every change goes through one guarded apply (#1270 Part 3a): it is refused
/// while a take runs, ignored while the loops lock it (the sample rate and
/// the loop cap clear the engine), refused when the effects would not fit at
/// the new rate or buffer, confirmed first when music is playing, and applied
/// by reopening the device so the loops stay. The config is saved only once
/// the device has opened it.
///
/// It also owns the record offset (#1541): the one saved for the running
/// device, rate and buffer, or, when an open owes one that was never saved,
/// one measured through the interface's own loopback and saved.
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
    _followWarmUp(_repository.state.status);
    unawaited(_syncRecordOffset());
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

  /// The device profile whose record offset was last set, so it is set once
  /// per profile unless an open owes it again.
  String? _hydratedDeviceKey;

  /// Whether [_syncRecordOffset] runs, so a tick meanwhile only marks it
  /// [_offsetStale] and it settles again once done.
  bool _syncingOffset = false;
  bool _offsetStale = false;

  /// Whether the boot-time recovery still waits for the pinned interface
  /// ([setWaitingForDevice]), so a refused or failed apply in the meantime
  /// gives the strip back to the wait.
  bool _recoveryWaiting = false;

  /// The request waiting on the "Apply audio settings?" answer.
  AudioSetupState? _pending;

  /// The player's config while the device warms up (#1533), so the end of
  /// the warm-up can be told against what was asked.
  EngineConfig? _warmUpTarget;

  /// Previous pinned-device presence, to detect lost/restored transitions; and
  /// the last device name seen while present, so a disconnect banner can name
  /// the device even after the snapshot stops reporting it.
  bool? _lastDevicePresent;
  String _lastPresentDeviceName = '';

  // ------------------------------------------------------------- the draft

  /// Drafts [sampleRate] (pen 28/01). Ignored while the loops lock the rate
  /// (D2): its chips are drawn disabled with the reason.
  void editRate(int sampleRate) {
    if (state.hasContent) return;
    _setDraft(_draft.copyWith(sampleRate: sampleRate));
  }

  /// Drafts [bufferFrames].
  void editBuffer(int bufferFrames) =>
      _setDraft(_draft.copyWith(bufferFrames: bufferFrames));

  /// Drafts the maximum loop length in whole [minutes] (`0` = engine
  /// default). Ignored while the loops lock it (D2).
  void editMaxLoop(int minutes) {
    if (state.hasContent) return;
    _setDraft(_draft.copyWith(maxLoopMinutes: minutes));
  }

  /// Drafts one interface, both directions: the host lists its playback and
  /// capture halves separately, but it is one box.
  void editDevice({
    required String playbackDeviceId,
    required String captureDeviceId,
  }) => _setDraft(
    _draft.copyWith(
      playbackDeviceId: playbackDeviceId,
      captureDeviceId: captureDeviceId,
    ),
  );

  /// Cancel on the Apply row: the page shows what runs again.
  void discardDraft() {
    if (isClosed || state.draft == null) return;
    emit(state.copyWith(clearDraft: true));
  }

  /// Apply on the Apply row: the whole draft through one guarded apply
  /// (#1270 Part 3a): the take check, the lock, the effects budget, and the
  /// question first when music is playing.
  void applyDraft() {
    final draft = state.draft;
    if (draft == null) return;
    _requestApply(
      state.copyWith(
        sampleRate: draft.sampleRate,
        bufferFrames: draft.bufferFrames,
        maxLoopMinutes: draft.maxLoopMinutes,
        playbackDeviceId: draft.playbackDeviceId,
        captureDeviceId: draft.captureDeviceId,
      ),
    );
  }

  /// Keeps the draft honest as the rig moves under it: material that lands
  /// locks the rate and the loop cap (D2), so their drafted values go back to
  /// what runs; and a draft that now equals what runs (a retry the device
  /// answered on its own) is no draft.
  void _reconcileDraft() {
    final draft = state.draft;
    if (draft == null) return;
    if (state.hasContent &&
        (draft.sampleRate != state.sampleRate ||
            draft.maxLoopMinutes != state.maxLoopMinutes)) {
      _setDraft(
        draft.copyWith(
          sampleRate: state.sampleRate,
          maxLoopMinutes: state.maxLoopMinutes,
        ),
      );
      return;
    }
    if (draft == AudioDraft.of(state) && !_failed) {
      emit(state.copyWith(clearDraft: true));
    }
  }

  /// The draft being edited, or what runs when there is none.
  AudioDraft get _draft => state.draft ?? AudioDraft.of(state);

  /// Keeps [draft] while it differs from what runs. After a failed open
  /// nothing runs, so even the same settings are a draft: applying them is
  /// how to retry.
  void _setDraft(AudioDraft draft) {
    final same = draft == AudioDraft.of(state) && !_failed;
    emit(
      same ? state.copyWith(clearDraft: true) : state.copyWith(draft: draft),
    );
  }

  /// Whether the last open failed and nothing runs: then the selection on
  /// screen is not running either, and applying it again is how to retry.
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
    final asked = _pending;
    if (asked == null) return;
    _pending = null;
    // The draft as it stands now: material that landed while the question
    // was open has put its rate and loop cap back (_reconcileDraft).
    final draft = state.draft;
    final next = draft == null
        ? asked
        : state.copyWith(
            sampleRate: draft.sampleRate,
            bufferFrames: draft.bufferFrames,
            maxLoopMinutes: draft.maxLoopMinutes,
            playbackDeviceId: draft.playbackDeviceId,
            captureDeviceId: draft.captureDeviceId,
          );
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

  // ------------------------------------------------------- the cable test

  /// The calibration guard a running cable test holds.
  OperationGuard? _measureGuard;

  /// Opens the cable test (pen 28/03): refused while a take runs (D3), and
  /// unavailable while the interface is not there.
  void openCableTest() {
    if (!_canMeasure ||
        state.draft != null ||
        state.measurePhase == MeasurePhase.cable ||
        state.measurePhase == MeasurePhase.running ||
        state.measurePhase == MeasurePhase.noReturn) {
      return;
    }
    final busy = _busyKind(GuardKind.calibration);
    if (busy != null) {
      emit(state.copyWith(refusal: ApplyRefusal.busy(busy)));
      return;
    }
    emit(
      state.copyWith(
        measurePhase: MeasurePhase.cable,
        playbackRunning: _musicPlaying,
        clearRefusal: true,
        measureOutput: _clampJack(
          state.measureOutput,
          state.engineStatus.outputChannels,
        ),
        measureInput: _clampJack(
          state.measureInput,
          state.engineStatus.inputChannels,
        ),
      ),
    );
  }

  /// Measures the cable from [output] to [input] (1-based): checks the take
  /// again, stops the transport and the backing track (D4), and holds the
  /// calibration guard for the run, so an Apply, a device change or a take
  /// is refused meanwhile. Only a pulse that comes back moves the offset; it
  /// is saved under the device, rate and buffer it was measured on.
  void startCableTest(int output, int input) {
    if (state.measurePhase == MeasurePhase.running || !_canMeasure) return;
    final busy = _busyKind(GuardKind.calibration);
    if (busy != null) {
      emit(state.copyWith(refusal: ApplyRefusal.busy(busy)));
      return;
    }
    final OperationGuard guard;
    try {
      guard = _guards.enter(
        GuardKind.calibration,
        const GuardScope.internal(),
        purpose: 'latency measurement',
      );
    } on GuardRefused catch (refused) {
      emit(
        state.copyWith(
          refusal: ApplyRefusal.busy(refused.blockers.first.kind.name),
        ),
      );
      return;
    }
    _measureGuard = guard;
    for (final track in _repository.state.tracks) {
      _repository.stopTrack(channel: track.channel);
    }
    if (_backing.state.playing) _backing.stop();
    final status = state.engineStatus;
    emit(
      state.copyWith(
        measurePhase: MeasurePhase.running,
        measureOutput: output,
        measureInput: input,
        clearRefusal: true,
      ),
    );
    unawaited(_runCableTest(guard, status, output, input));
  }

  Future<void> _runCableTest(
    OperationGuard guard,
    EngineStatus status,
    int output,
    int input,
  ) async {
    final LatencyResult result;
    try {
      result = await _repository.measureLatency(
        output: output - 1,
        input: input - 1,
      );
    } finally {
      _releaseMeasureGuard(guard);
    }
    // Cancelled from here (or the cubit closed) while it ran: that answer
    // is already on screen.
    if (isClosed || state.measurePhase != MeasurePhase.running) return;
    switch (result.outcome) {
      case LatencyOutcome.done:
        emit(
          state.copyWith(
            measurePhase: MeasurePhase.done,
            loopbackMeasure: LoopbackMeasure.idle,
          ),
        );
        await _settings.saveLatencyOffsetFrames(
          device: status.deviceName,
          sampleRate: status.sampleRate,
          bufferFrames: status.bufferFrames,
          frames: result.offsetFrames,
        );
      case LatencyOutcome.noReturn || LatencyOutcome.timedOut:
        emit(state.copyWith(measurePhase: MeasurePhase.noReturn));
      case LatencyOutcome.cancelled || LatencyOutcome.refused:
        emit(state.copyWith(measurePhase: MeasurePhase.cancelled));
    }
  }

  /// Picks the cable's [output] and [input] jacks (1-based) while the
  /// dialog is open and nothing runs.
  void chooseCableJacks({int? output, int? input}) {
    if (state.measurePhase == MeasurePhase.idle ||
        state.measurePhase == MeasurePhase.running) {
      return;
    }
    emit(
      state.copyWith(
        measureOutput: output == null
            ? null
            : _clampJack(output, state.engineStatus.outputChannels),
        measureInput: input == null
            ? null
            : _clampJack(input, state.engineStatus.inputChannels),
      ),
    );
  }

  /// Closes the cable test, cancelling a run in flight: the offset stays as
  /// it was. Leaving the page does this too.
  void cancelMeasure() {
    if (isClosed || state.measurePhase == MeasurePhase.idle) return;
    if (state.measurePhase == MeasurePhase.running) {
      _repository.cancelLatency();
    }
    emit(state.copyWith(measurePhase: MeasurePhase.idle, clearRefusal: true));
  }

  /// Whether the interface is there to measure.
  bool get _canMeasure =>
      state.engineStatus.isConnected && state.engineStatus.devicePresent;

  void _releaseMeasureGuard(OperationGuard guard) {
    guard.release();
    if (identical(_measureGuard, guard)) _measureGuard = null;
  }

  /// [jack] within 1..[count], or 1 when the count is unknown.
  static int _clampJack(int jack, int count) =>
      count <= 0 ? 1 : jack.clamp(1, count);

  /// Whether music would be cut by an apply: a track plays, or the backing
  /// track does.
  bool get _musicPlaying =>
      _repository.state.isPlaying || _backing.state.playing;

  /// The checks every request passes before it may apply, in order (D3, D2,
  /// D19). A refusal is shown and nothing changes; a locked change is only
  /// ignored, because its control is already drawn disabled with the reason.
  bool _admit(AudioSetupState next) {
    final busy = _busyKind(GuardKind.deviceChange);
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
  /// (or anything else the table says [kind] must not overlap).
  String? _busyKind(GuardKind kind) {
    final looper = _repository.state;
    final takeRunning =
        looper.transport.countingIn ||
        looper.tracks.any(
          (t) => t.isCapturing || t.pending || t.pendingLaunch != null,
        );
    if (takeRunning) return GuardKind.capture.name;
    // The automatic loopback measurement (#1541): an Apply or the cable test
    // would cut it.
    if (state.loopbackMeasure == LoopbackMeasure.measuring) {
      return GuardKind.calibration.name;
    }
    final blockers = _guards.blockers(kind, const GuardScope.internal());
    return blockers.isEmpty ? null : blockers.first.kind.name;
  }

  /// The refusal for a change that would leave the effects no room (#887,
  /// owner's Q5 answer, D19), or `null`. Only a change that shrinks the room
  /// is refused: a higher rate, or a buffer below the 64-frame block the
  /// per-frame costs were measured at (32, #1529). A change that leaves the
  /// room as it is or frees some is never refused, as an effects removal
  /// never is. The room now is the running device's, which can differ from
  /// the selection when the device negotiated an off-list period. When both
  /// move, the rate is named only if it alone would not fit.
  ApplyRefusal? _overBudget(AudioSetupState next) {
    final live = state.engineStatus;
    final rate = live.sampleRate > 0 ? live.sampleRate : state.sampleRate;
    final buffer = live.bufferFrames > 0
        ? live.bufferFrames
        : state.bufferFrames;
    if (next.sampleRate == rate && next.bufferFrames == buffer) return null;
    final room = _repository.fxRoomAt(next.sampleRate, next.bufferFrames);
    if (room >= 0) return null;
    if (room >= _repository.fxRoomAt(rate, buffer)) return null;
    final rateAlone = next.sampleRate > rate
        ? _repository.fxRoomAt(next.sampleRate, buffer)
        : 0;
    return rateAlone < 0
        ? ApplyRefusal.overBudgetRate(next.sampleRate)
        : ApplyRefusal.overBudgetBuffer(next.bufferFrames);
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
    // The draft is being applied: whatever the device does with it, the page
    // shows what runs from here on, unless the repository touched nothing.
    final draft = state.draft;
    emit(state.copyWith(clearDraft: true));
    try {
      final outcome = _applyGuarded(next);
      if (draft != null &&
          outcome.status == AudioApplyStatus.refused &&
          outcome.result == EngineResult.notReady) {
        emit(state.copyWith(draft: draft));
      }
    } finally {
      guard.release();
    }
    if (_recoveryWaiting &&
        state.status != AudioSetupStatus.running &&
        state.deviceConnectivity == DeviceConnectivity.none) {
      emit(state.copyWith(deviceConnectivity: DeviceConnectivity.waiting));
    }
  }

  AudioApplyResult _applyGuarded(AudioSetupState next) {
    // An intentional (re)apply resets the standing connectivity condition
    // (#453): the lost banner must not outlive the user acting on it, and the
    // app's own stop and reopen below must not read as an unplug. The
    // repository's reconnect supervisor never passes through here, so a REAL
    // unplug's lost/restored pair is untouched.
    _lastDevicePresent = null;
    // The player's own apply ends a warm-up, and its outcome is told below;
    // a refused one puts the warm-up back, and the next tick follows it.
    _warmUpTarget = null;
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
          when outcome.result == EngineResult.wouldClear:
        // The interface would open at another rate, which would clear the
        // loops: the previous config runs again, and the banner names the
        // rate the new one would have run (#1270 Part 3b).
        emit(
          state.copyWith(
            status: AudioSetupStatus.running,
            clearError: true,
            clearRefusal: true,
            phase: ConfigPhase.refused,
            requestedRate: outcome.refusedRate,
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
    return outcome;
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
    // row saying 480 when the grid only offers 32/64/128/256/512 another, with
    // no chip lit and no way back. So an off-list figure stays out of the
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
    emit(
      _projectFromRepository(
        looper,
        current: state,
      ).copyWith(playbackRunning: _musicPlaying),
    );
    _reconcileDraft();
    _detectConnectivity(looper.status);
    _followWarmUp(looper.status);
    unawaited(_syncRecordOffset());
  }

  /// Follows a warm-up (#1533) to its end. The end opens the player's config
  /// (`AudioWarmUpCubit`); when the device runs something else after it,
  /// the page says so the way it says it after a refused Apply: the chips
  /// show what runs and the banner names what was asked. Nothing is saved,
  /// so the next start asks for the player's config again. A switch that
  /// lost loops is told like a reconnect that did.
  void _followWarmUp(EngineStatus status) {
    if (status.warmingUp) {
      _warmUpTarget = _repository.lastEngineConfig;
      return;
    }
    final asked = _warmUpTarget;
    _warmUpTarget = null;
    if (asked == null || !status.isConnected) return;
    final lost = _restoredConnectivity(status.reopen);
    if (lost != DeviceConnectivity.restored) {
      emit(
        state.copyWith(
          deviceConnectivity: lost,
          connectivityDeviceName: status.deviceName,
        ),
      );
    }
    // Refused: the warm-up buffer still runs. A period the device rounded
    // is not a refusal, as it was not before the warm-up.
    if (asked.bufferFrames == kWarmUpBufferFrames ||
        status.bufferFrames != kWarmUpBufferFrames) {
      return;
    }
    emit(
      state.copyWith(
        sampleRate: _offerable(
          status.sampleRate,
          AudioSetupState.sampleRates,
          state.sampleRate,
        ),
        bufferFrames: _offerable(
          status.bufferFrames,
          AudioSetupState.bufferSizes,
          state.bufferFrames,
        ),
        phase: ConfigPhase.refused,
        requestedRate: asked.sampleRate > 0
            ? asked.sampleRate
            : status.sampleRate,
        requestedBuffer: asked.bufferFrames > 0
            ? asked.bufferFrames
            : status.bufferFrames,
        actualRate: status.sampleRate,
        actualBuffer: status.bufferFrames,
      ),
    );
  }

  /// Whether the boot-time recovery waits for the pinned interface
  /// (`AudioRecoveryCubit`), so the stage says so on its one strip rather
  /// than a toast beside the engine-stopped banner (#860, #1270 Part 5).
  /// Any other condition already on the strip outranks it.
  void setWaitingForDevice({required bool waiting}) {
    _recoveryWaiting = waiting;
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

  /// Sets the record offset of the open device, rate and buffer, once per
  /// profile (#1270 Part 3a), so an offset measured on one profile never
  /// compensates another: the saved one, or 0 when it was never measured.
  ///
  /// When the open owes its offset ([EngineStatus.recordOffsetOwed], #1541:
  /// the warm-up switch, a start that needed no warm-up, an apply here) it is
  /// set however often, and the outputs stay silent with the transport closed
  /// until it is. With none saved and a loopback on the interface
  /// ([EngineStatus.excludedInputMask]) it is measured first, and saved
  /// under the profile as the cable test saves. A measurement that fails
  /// leaves 0, saves nothing, and says so on the latency row; the next owed
  /// offset of that profile tries again. A saved offset is never measured
  /// over, so a cable result is never replaced.
  ///
  /// Not during a warm-up (#1533): nothing records on its buffer, and the
  /// switch owes the player's.
  Future<void> _syncRecordOffset() async {
    if (_syncingOffset) {
      _offsetStale = true;
      return;
    }
    _syncingOffset = true;
    try {
      do {
        _offsetStale = false;
        await _settleRecordOffset(state.engineStatus);
      } while (_offsetStale && !isClosed);
    } finally {
      _syncingOffset = false;
    }
  }

  Future<void> _settleRecordOffset(EngineStatus status) async {
    if (!status.isConnected || status.warmingUp) return;
    // Owed by the last tick and still owed now: a tick published before the
    // offset was set must not settle it a second time.
    final owed =
        status.recordOffsetOwed && _repository.state.status.recordOffsetOwed;
    try {
      if (status.deviceName.isEmpty) {
        // No profile to look up or save under, but an owed offset is what
        // keeps the outputs silent: it is 0.
        if (owed) _repository.setRecordOffset(0);
        return;
      }
      final key = _profileKey(status);
      if (!owed && _hydratedDeviceKey == key) return;
      _hydratedDeviceKey = key;
      await _settleProfile(status, key, owed: owed);
    } on Object catch (error) {
      // Whatever went wrong, an owed offset must not leave the console
      // silent.
      AppLog.error('record offset: not settled: $error');
      if (owed && !isClosed) _repository.setRecordOffset(0);
    }
  }

  Future<void> _settleProfile(
    EngineStatus status,
    String key, {
    required bool owed,
  }) async {
    // A failure told on the row belongs to the profile that failed.
    emit(state.copyWith(loopbackMeasure: LoopbackMeasure.idle));
    final saved = await _savedOffset(status);
    if (isClosed) return;
    if (saved != null) {
      _setRecordOffset(key, saved, owed: owed);
      return;
    }
    if (!owed || status.excludedInputMask == 0) {
      _setRecordOffset(key, 0, owed: owed);
      return;
    }
    emit(state.copyWith(loopbackMeasure: LoopbackMeasure.measuring));
    final measured = await _measureThroughLoopback(status);
    if (isClosed) return;
    final live = _repository.state.status;
    if (measured.interrupted &&
            (!live.devicePresent || !live.isConnected || live.warmingUp) ||
        _profileKey(state.engineStatus) != key) {
      // The device left or reopened meanwhile: its own owed offset comes
      // next, and this profile is settled again when it runs.
      _hydratedDeviceKey = null;
      emit(state.copyWith(loopbackMeasure: LoopbackMeasure.idle));
      return;
    }
    final offset = measured.offset;
    if (offset == null) {
      emit(state.copyWith(loopbackMeasure: LoopbackMeasure.failed));
      _setRecordOffset(key, 0, owed: owed);
      return;
    }
    // Heard first, saved after: a slow write must not hold the outputs.
    emit(state.copyWith(loopbackMeasure: LoopbackMeasure.idle));
    _setRecordOffset(key, offset, owed: owed);
    try {
      await _settings.saveLatencyOffsetFrames(
        device: status.deviceName,
        sampleRate: status.sampleRate,
        bufferFrames: status.bufferFrames,
        frames: offset,
      );
    } on Object catch (error) {
      AppLog.error('record offset: measured offset not saved: $error');
    }
  }

  /// The offset saved for [status]'s device, rate and buffer, or `null` when
  /// none is (or it cannot be read).
  Future<int?> _savedOffset(EngineStatus status) async {
    try {
      final saved = await _settings.loadLatencyOffsetFrames(
        device: status.deviceName,
        sampleRate: status.sampleRate,
        bufferFrames: status.bufferFrames,
      );
      return saved != null && saved > 0 ? saved : null;
    } on Object catch (error) {
      AppLog.error('record offset: saved offset unreadable: $error');
      return null;
    }
  }

  /// Measures the round trip through the interface's loopback. While it
  /// runs an Apply and the cable test are refused ([_busyKind]). Twice, as it
  /// runs right after a reopen: a period the device dropped in the window
  /// would move the peak, and a saved offset is never measured again.
  /// The offset is the measured one when both agree within
  /// [_loopbackTolerance] frames, or `null` when they do not or one did not
  /// return; `interrupted` says a run was cancelled (the device left, or the
  /// engine reopened) rather than measured.
  Future<({int? offset, bool interrupted})> _measureThroughLoopback(
    EngineStatus status,
  ) async {
    final profile =
        '${status.deviceName} ${status.sampleRate} Hz / '
        '${status.bufferFrames}';
    final offsets = <int>[];
    for (var run = 0; run < 2; run++) {
      final result = await _repository.measureLoopbackLatency();
      if (isClosed) return (offset: null, interrupted: true);
      if (result.outcome != LatencyOutcome.done || result.offsetFrames <= 0) {
        AppLog.warn(
          'record offset: loopback measurement of $profile failed: '
          '${result.outcome.name} (${result.engineResult.name})',
        );
        return (
          offset: null,
          interrupted: result.outcome == LatencyOutcome.cancelled,
        );
      }
      offsets.add(result.offsetFrames);
    }
    if ((offsets[0] - offsets[1]).abs() > _loopbackTolerance) {
      AppLog.warn(
        'record offset: loopback measurements of $profile disagree: '
        '${offsets.join(' and ')} frames',
      );
      return (offset: null, interrupted: false);
    }
    AppLog.info(
      'record offset: $profile measured through the loopback: '
      '${offsets[1]} frames',
    );
    return (offset: offsets[1], interrupted: false);
  }

  /// How far apart two loopback measurements may land and still agree. The
  /// loopback is digital, so a sound path returns the same lag every run.
  static const _loopbackTolerance = 2;

  /// Sets [frames] while [key] is still the open profile (the last status
  /// the repository published): always when the open owes it, as that is
  /// what makes it heard, else only when it moves.
  void _setRecordOffset(String key, int frames, {required bool owed}) {
    final live = state.engineStatus;
    if (_profileKey(live) != key) return;
    if (owed || frames != live.recordOffsetFrames) {
      _repository.setRecordOffset(frames);
    }
  }

  static String _profileKey(EngineStatus status) =>
      '${status.deviceName}|${status.sampleRate}|${status.bufferFrames}';

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
              // A warm-up's buffer is not the player's (#1533).
              negotiated: engineStatus.warmingUp
                  ? 0
                  : engineStatus.bufferFrames,
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
    if (state.measurePhase == MeasurePhase.running ||
        state.loopbackMeasure == LoopbackMeasure.measuring) {
      _repository.cancelLatency();
    }
    final guard = _measureGuard;
    if (guard != null) _releaseMeasureGuard(guard);
    _deviceRefreshTimer?.cancel();
    unawaited(_subscription.cancel());
    return super.close();
  }
}
