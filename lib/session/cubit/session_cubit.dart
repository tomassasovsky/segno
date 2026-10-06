import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'session_state.dart';

/// Drives session persistence (save / open) and the session catalog (list /
/// save-as / rename / duplicate / delete), tracking the open session by its
/// bundle id so a plain [save] writes back without re-prompting (the document
/// model).
///
/// Composes three repositories at the bloc level (repositories never import
/// repositories): the session repository does the file I/O + owns the catalog
/// layout, the looper repository — the single owner of looper state — applies a
/// loaded session to the engine and supplies the live chains a save captures,
/// and the performance repository is disarmed+finalized before a load applies
/// (a session load while armed would otherwise pull the rug out from under an
/// in-progress capture).
class SessionCubit extends Cubit<SessionState> {
  /// Creates a [SessionCubit] backed by [repository], [looper], and
  /// [performance].
  ///
  /// [currentPedalBindings] / [onPedalBindings] are the session's pedal remap
  /// (part 6b) crossing this cubit as an opaque string — read fresh at each
  /// save, handed back on each load. [releaseHeldBindings] restores any held
  /// momentary and runs BEFORE a load applies its rig (see [open] for why
  /// the two halves sit on opposite sides of the apply). All three are narrow
  /// injected functions rather than a `ControlCubit` dependency for the usual
  /// reason: a cubit never calls a cubit, and the binding model belongs to the
  /// control layer. Each defaults to a no-op, which is exactly the pre-6b
  /// behavior.
  SessionCubit({
    required SessionRepository repository,
    required LooperRepository looper,
    required PerformanceRepository performance,
    required MixSettingsCoordinator mixSettings,
    required FxChainPersistence fxPersistence,
    required SettingsRepository settings,
    required MixSettingsPersistence mixPersistence,
    required SessionSettingsCoordinator captureSettings,
    required GuardRegistry guards,
    String Function() currentPedalBindings = _noBindings,
    void Function(String encoded) onPedalBindings = _ignoreBindings,
    void Function() releaseHeldBindings = _noRelease,
    Duration captureEndTimeout = const Duration(seconds: 20),
  }) : _captureEndTimeout = captureEndTimeout,
       _repository = repository,
       _guards = guards,
       _looper = looper,
       _performance = performance,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _settings = settings,
       _mixPersistence = mixPersistence,
       _captureSettings = captureSettings,
       _currentPedalBindings = currentPedalBindings,
       _onPedalBindings = onPedalBindings,
       _releaseHeldBindings = releaseHeldBindings,
       super(const SessionState());

  /// The default `currentPedalBindings`: no session remap, so the global set
  /// applies (A12).
  static String _noBindings() => '';

  /// The default `onPedalBindings`: a call site that does not own a control
  /// surface simply drops the loaded blob.
  static void _ignoreBindings(String _) {}

  /// The default `releaseHeldBindings`: nothing to release without a control
  /// surface.
  static void _noRelease() {}

  final SessionRepository _repository;
  final LooperRepository _looper;
  final PerformanceRepository _performance;
  final MixSettingsCoordinator _mixSettings;
  final FxChainPersistence _fxPersistence;
  final SettingsRepository _settings;
  final MixSettingsPersistence _mixPersistence;
  final SessionSettingsCoordinator _captureSettings;
  final String Function() _currentPedalBindings;
  final void Function(String encoded) _onPedalBindings;
  final void Function() _releaseHeldBindings;

  /// The app's one guard table (accepted behaviour 6.12). Applying a session
  /// holds a `sessionApply` guard from its commit to the end of its boot, so
  /// a take, a device change or a calibration cannot start under it, and it
  /// is refused while one of those (or a shutdown) is in flight.
  final GuardRegistry _guards;

  /// What a refusal names a session apply by.
  static const String applyPurpose = 'opening a session';

  /// How long an Open or New loop waits for a take it ended to finish: the
  /// take ends at its Record timing, which can be the next bar or loop top.
  final Duration _captureEndTimeout;
  String? _pendingLoadedBindings;
  SessionId? _pendingLoadedId;
  String? _pendingLoadedName;
  List<SessionSummary>? _pendingLoadedSessions;
  FadeDurations? _pendingLoadedFade;
  SessionConversionNotice? _pendingConversion;
  final _activeOperations = <Future<void>>{};
  Future<void>? _closingFuture;
  bool _closing = false;

  // ---- the session catalog (the document model) ----

  /// Reloads the saved-session catalog and its folders into state (for the
  /// Library). A quiet update — no working/success cycle.
  Future<void> refreshSessions() async {
    if (_closing || isClosed) return;
    final operation = _refreshSessions();
    _track(operation);
    await operation;
  }

  Future<void> _refreshSessions() async {
    final sessions = await _repository.listSessions();
    final folders = await _listFolders();
    if (_closing || isClosed) return;
    emit(state.copyWith(sessions: sessions, folders: folders));
  }

  /// The catalog's folders, or the ones already in state when they cannot be
  /// read: an unreadable folder list must not fail the action that re-lists.
  Future<List<String>> _listFolders() async {
    try {
      return await _repository.listFolders();
    } on Object {
      return state.folders;
    }
  }

  /// The name a save with no identity takes: `New loop N`, the smallest N no
  /// catalog name carries (plan D4). A name is the session's data, not UI
  /// copy, so it is the same in every language.
  static const String automaticNamePrefix = 'New loop';

  /// Saves the live rig as a NEW session under a fresh id, named [name], and
  /// makes it current. Rejects a name another session carries exactly
  /// (case-sensitively, as the appliance always has) with
  /// [SessionError.nameCollision] and writes nothing.
  Future<void> saveAs(String name) => _saveNew(name);

  /// Writes the live rig back to the open session with no prompt. With no
  /// open session it saves under the next automatic name ([automaticNamePrefix]
  /// `N`) and makes that current; naming stays optional (plan D4).
  Future<void> save() {
    if (_closing || isClosed) return Future<void>.value();
    final id = state.currentSessionId;
    final name = state.currentSessionName;
    if (id == null) return _saveNew(null);
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    return _run(
      () => _captureSettings.runExclusive(() async {
        _savedFingerprint = await _asSaveFailure(
          () async => _saveCurrentRig(
            await _repository.bundlePathOf(id),
            name,
            revision,
            generation,
            device,
          ),
        );
        // Re-list, like every other mutation: the Library stays open, and its
        // date column reads the catalog — without this a just-saved session
        // goes on saying "yesterday".
        return _ActionResult(
          SessionOutcome.saved,
          sessions: await _repository.listSessions(),
        );
      }),
    );
  }

  /// Saves the live rig under a fresh id, named [name] or, when null, the
  /// next automatic name, and makes it current.
  Future<void> _saveNew(String? name) {
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    return _run(
      () => _captureSettings.runExclusive(() async {
        final (:id, :slug) = await _writeNew(
          name,
          revision: revision,
          generation: generation,
          device: device,
        );
        return _ActionResult(
          SessionOutcome.savedAs,
          currentId: id,
          currentName: slug,
          sessions: await _repository.listSessions(),
        );
      }),
    );
  }

  /// Writes the live rig under a fresh id, named [name] or the next
  /// automatic name, and records its fingerprint. Runs inside
  /// `runExclusive`.
  Future<({SessionId id, String slug})> _writeNew(
    String? name, {
    required int revision,
    required int generation,
    required String device,
  }) async {
    final String slug;
    if (name == null) {
      slug = await _repository.nextAutomaticName(automaticNamePrefix);
    } else {
      slug = _slugOf(name);
      if ((await _repository.listSessions()).any((s) => s.name == slug)) {
        throw SessionNameCollision(slug: slug);
      }
    }
    final id = await _repository.newSessionId();
    try {
      _savedFingerprint = await _asSaveFailure(
        () async => _saveCurrentRig(
          await _repository.bundlePathOf(id),
          slug,
          revision,
          generation,
          device,
        ),
      );
    } on Object {
      // A save refused before it wrote anything leaves the reserved
      // directory empty; give it back so it never lists as a folder.
      await _repository.releaseSessionId(id);
      rethrow;
    }
    return (id: id, slug: slug);
  }

  /// The fingerprint ([SessionRepository.fingerprint]) of the rig as of its
  /// last save, open or boot baseline, or null when it is unknown. Equal to
  /// the live rig's means there is nothing to preserve (plan D7).
  String? _savedFingerprint;

  /// Records the rig's fingerprint as the boot baseline, so an Open of
  /// another session does not save a rig nobody has touched. Quiet: no
  /// working/success cycle. Does nothing once a fingerprint is known. A
  /// capture that fails leaves none; Open then preserves the rig only when it
  /// holds recorded audio.
  Future<void> recordBaseline() async {
    if (_closing || isClosed) return;
    if (_savedFingerprint != null) return;
    final operation = _captureSettings.runExclusive(() async {
      if (_savedFingerprint != null) return;
      _savedFingerprint = await _liveFingerprint();
    });
    _track(operation);
    try {
      await operation;
    } on Object {
      // No baseline: the next Open preserves the rig.
    }
  }

  /// The live rig's fingerprint, from the same capture a save runs first.
  /// Runs inside `runExclusive`.
  Future<String> _liveFingerprint() async {
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    bool stillOwned() =>
        !isClosed &&
        revision == _looper.sessionRevision &&
        generation == _looper.mixGeneration &&
        device == _looper.state.status.deviceName;
    final captured = await _captureSettings.capture(stillOwned: stillOwned);
    return _repository.fingerprint(
      settings: captured.settings,
      chains: captured.chains,
      pedalBindings: _currentPedalBindings(),
    );
  }

  /// Saves the outgoing rig before an Open replaces it, when it has changed
  /// since its last save, open or the boot baseline (plan D7): to its
  /// identity, or under the next automatic name, which then becomes current
  /// so a refused target leaves the saved rig named. Any failure is a
  /// [SessionError.saveFailed] and stops the Open before anything else
  /// changes. Runs inside `runExclusive`.
  ///
  /// When the two cannot be compared (no baseline was taken, or the live
  /// rig's capture cannot run, as while a setting awaits recovery), the rig
  /// is saved when it holds recorded audio, the part nothing else can bring
  /// back, and is otherwise left as it is: an Open that resolves a recovery
  /// notice stays possible, and an untouched rig is not saved.
  Future<void> _preserveOutgoing() async {
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    String? now;
    try {
      now = await _liveFingerprint();
    } on Object {
      // A capture that cannot run now (a setting still awaiting recovery)
      // cannot be compared; the rule below decides.
      now = null;
    }
    final known = _savedFingerprint;
    if (now == null || known == null) {
      if (!_looper.state.tracks.any((t) => t.hasContent)) return;
    } else if (now == known) {
      return;
    }
    final id = state.currentSessionId;
    if (id != null) {
      _savedFingerprint = await _asSaveFailure(
        () async => _saveCurrentRig(
          await _repository.bundlePathOf(id),
          state.currentSessionName,
          revision,
          generation,
          device,
        ),
      );
      return;
    }
    final saved = await _asSaveFailure(
      () => _writeNew(
        null,
        revision: revision,
        generation: generation,
        device: device,
      ),
    );
    if (isClosed) return;
    emit(
      state.copyWith(
        status: SessionStatus.working,
        currentSessionId: saved.id,
        currentSessionName: saved.slug,
        sessions: await _repository.listSessions(),
      ),
    );
  }

  /// Ends every take in progress before an Open or New loop saves the
  /// outgoing rig, as the record control's Stop would (plan D8: the dialog
  /// promises the loop stays), and waits until none is capturing, so the
  /// take is saved with the rest. A take still capturing after
  /// the capture-end timeout refuses the action with
  /// [SessionError.captureInProgress] before anything else changes. Runs
  /// inside `runExclusive`.
  Future<void> _endCaptures() async {
    bool capturing() => _looper.state.tracks.any((t) => t.isCapturing);
    if (!capturing()) return;
    for (final track in _looper.state.tracks) {
      if (track.isCapturing) _looper.stopRecordControl(channel: track.channel);
    }
    final deadline = DateTime.now().add(_captureEndTimeout);
    while (capturing()) {
      if (DateTime.now().isAfter(deadline)) {
        throw const _SessionRefusal(SessionError.captureInProgress);
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  /// Records the just-opened rig's fingerprint; when it cannot be taken it
  /// is unknown, and the next Open preserves (the safe side).
  Future<void> _recordOpenedFingerprint() async {
    try {
      _savedFingerprint = await _liveFingerprint();
    } on Object {
      _savedFingerprint = null;
    }
  }

  /// Runs a save's write and reports any failure that is not a typed
  /// session refusal as [SessionError.saveFailed], the 19/05 banner's
  /// "Could not save your current loop. Nothing was changed."
  static Future<T> _asSaveFailure<T>(Future<T> Function() write) async {
    try {
      return await write();
    } on SessionException {
      rethrow;
    } on _SessionRefusal {
      rethrow;
    } on Object catch (error) {
      throw _SessionRefusal(SessionError.saveFailed, error);
    }
  }

  /// Captures and writes the live rig to [directory], returning the
  /// fingerprint of what it captured. The fingerprint is taken before the
  /// write's own capture, so an edit landing between the two makes it older,
  /// never newer: the next Open then saves once more rather than skipping an
  /// edit.
  Future<String> _saveCurrentRig(
    String directory,
    String? name,
    int revision,
    int generation,
    String device,
  ) async {
    bool stillOwned() =>
        !isClosed &&
        revision == _looper.sessionRevision &&
        generation == _looper.mixGeneration &&
        device == _looper.state.status.deviceName;
    if (!stillOwned()) {
      throw StateError('session changed before save');
    }
    final captured = await _captureSettings.capture(stillOwned: stillOwned);
    final pedalBindings = _currentPedalBindings();
    final fingerprint = _repository.fingerprint(
      settings: captured.settings,
      chains: captured.chains,
      pedalBindings: pedalBindings,
    );
    await _repository.save(
      directory,
      chains: captured.chains,
      settings: captured.settings,
      pedalBindings: pedalBindings,
      name: name,
      captureStillValid: stillOwned,
    );
    return fingerprint;
  }

  /// Opens the session [id] into the engine through the looper repository
  /// (the one apply path), makes it current, and refreshes the catalog.
  ///
  /// A session saved by an older schema is converted on open, keeping the
  /// settings it never carried at the player's current values. Once the rig
  /// is applied, the conversion is written back with the original manifest
  /// kept beside it, and the outcome carries [SessionState.conversion] so
  /// the player is told. A refused open leaves the bundle untouched.
  ///
  /// Auto-disarms and finalizes an in-progress performance-recording capture
  /// first — applying a loaded session mid-capture would otherwise pull the
  /// rug out from under it. The finalize + render run through the same path a
  /// manual disarm does; `PerformanceRecorderCubit` observes the repository's
  /// status stream, so it reflects this disarm too even though it was never
  /// the one to call it.
  ///
  /// The outgoing rig is saved first when it has changed (plan D7); opening
  /// the session that is already current does nothing.
  Future<void> open(SessionId id) {
    if (id == state.currentSessionId) return Future<void>.value();
    return _open(id);
  }

  Future<void> _open(SessionId id) => _run(
    subject: id,
    () async {
      try {
        return await _captureSettings.runExclusive(() async {
          await _endCaptures();
          await _preserveOutgoing();
          final path = await _repository.bundlePathOf(id);
          final (:bundle, :conversion) = await _repository.open(
            path,
            liveSettings: _captureSettings.current,
          );
          // The header shows the manifest's name; a bundle saved before names
          // were metadata shows its directory name, as the catalog does.
          final loadedName = bundle.session.name ?? id;
          final (:sessions, :notice) = await _applyRig(
            id: id,
            name: loadedName,
            rig: rigFromBundle(bundle),
            fade: FadeDurations(
              defaultMs: bundle.session.defaultFadeDurationMs,
              overrides: bundle.session.trackFadeDurationOverrides,
            ),
            pedalBindings: bundle.session.pedalBindings,
            path: path,
            conversion: conversion,
          );
          await _recordOpenedFingerprint();
          return _ActionResult(
            SessionOutcome.loaded,
            currentId: id,
            currentName: loadedName,
            sessions: sessions,
            conversion: notice,
          );
        });
      } on _SessionBootException {
        rethrow;
      } on Object {
        _fxPersistence.cancelSessionLoad();
        rethrow;
      }
    },
    reserveSessionLoad: true,
  );

  /// Starts a new loop (plan D9): saves the outgoing rig first when it has
  /// changed (plan D7), clears every track and its history, keeps the
  /// sound, tempo and pedal setup, and saves the empty rig at once under
  /// the next automatic name, which becomes current.
  ///
  /// The empty rig is [rigForNewLoop] of the live settings and chains,
  /// applied through the one apply path an Open uses; the transforms reset
  /// with the clear inside it. A failed preservation applies nothing. When
  /// the empty rig cannot be written after it is applied, the new loop is
  /// started and current under its new name, the failure is
  /// [SessionError.newLoopNotSaved], and the first Save writes it. A take in
  /// progress is ended first and saved with the outgoing rig, as for Open.
  Future<void> newLoop() => _run(
    () async {
      SessionId? reserved;
      var applied = false;
      try {
        return await _captureSettings.runExclusive(() async {
          await _endCaptures();
          await _preserveOutgoing();
          // A held momentary belongs to the outgoing rig, not to the chains
          // the new loop keeps.
          _releaseHeldBindings();
          final revision = _looper.sessionRevision;
          final generation = _looper.mixGeneration;
          final device = _looper.state.status.deviceName;
          final captured = await _captureSettings.capture(
            stillOwned: () =>
                !isClosed &&
                revision == _looper.sessionRevision &&
                generation == _looper.mixGeneration &&
                device == _looper.state.status.deviceName,
          );
          final live = _repository.liveSession(
            settings: captured.settings,
            chains: captured.chains,
            pedalBindings: _currentPedalBindings(),
          );
          final name = await _repository.nextAutomaticName(
            automaticNamePrefix,
          );
          final id = reserved = await _repository.newSessionId();
          await _applyRig(
            id: id,
            name: name,
            rig: rigForNewLoop(live),
            fade: FadeDurations(
              defaultMs: live.defaultFadeDurationMs,
              overrides: live.trackFadeDurationOverrides,
            ),
            pedalBindings: live.pedalBindings,
          );
          applied = true;
          // The outgoing rig's fingerprint no longer describes anything.
          _savedFingerprint = null;
          try {
            _savedFingerprint = await _saveCurrentRig(
              await _repository.bundlePathOf(id),
              name,
              _looper.sessionRevision,
              _looper.mixGeneration,
              _looper.state.status.deviceName,
            );
          } on Object catch (error) {
            // Not a failed save of the outgoing loop, which is safe: the new
            // loop is started and named, and only its empty bundle is
            // missing. The first Save writes it.
            throw _SessionRefusal(SessionError.newLoopNotSaved, error);
          }
          return _ActionResult(
            SessionOutcome.newLoop,
            currentId: id,
            currentName: name,
            sessions: await _repository.listSessions(),
          );
        });
      } on _SessionBootException {
        rethrow;
      } on Object {
        if (!applied) {
          _fxPersistence.cancelSessionLoad();
          final id = reserved;
          if (id != null) await _repository.releaseSessionId(id);
        }
        rethrow;
      }
    },
    reserveSessionLoad: true,
  );

  /// Applies [rig] as the session [id] named [name] through the looper
  /// repository, the one apply path Open and New loop share, and makes it
  /// current. Once the rig is applied, an Open's [conversion] is written
  /// back to the bundle at [path] (#1211). Returns the catalog read before
  /// the apply and the conversion notice. Runs inside `runExclusive`.
  ///
  /// A failure before the rig is applied changes nothing and rethrows; one
  /// after it stops the engine and throws [_SessionBootException], keeping
  /// the boot image for [retryLoadedSession].
  Future<({List<SessionSummary> sessions, SessionConversionNotice? notice})>
  _applyRig({
    required SessionId id,
    required String name,
    required SessionRig rig,
    required FadeDurations fade,
    required String pedalBindings,
    String? path,
    SessionConversion? conversion,
  }) async {
    var applied = false;
    // Held from the commit point to the end of the boot (#1198 P11).
    OperationGuard? applying;
    try {
      if (rig.tracks.isNotEmpty) {
        final live = _looper.state;
        if (!live.transport.isRunning || !live.status.devicePresent) {
          throw StateError(
            'audio device must be running before session load',
          );
        }
      }
      final candidate = MixSettingsSnapshot.fromRig(rig);
      if (!candidate.isValid) throw StateError('session mix is invalid');
      // The commit point: nothing has changed yet, and from here the rig
      // is being replaced. A running take is finished first, as before,
      // which the guard table allows.
      applying = _guards.enter(
        GuardKind.sessionApply,
        const GuardScope.internal(),
        purpose: applyPurpose,
      );
      final disarmed = await _performance.disarmAndFinalize();
      if (!disarmed.isOk) {
        throw StateError(
          'performance capture did not stop before session load',
        );
      }
      final sessions = await _repository.listSessions();
      final generation = _looper.mixGeneration;
      final device = _looper.state.status.deviceName;
      if (device.isEmpty &&
          (candidate.inputSetup != const InputSetup.empty() ||
              candidate.outputSetup != const OutputSetup())) {
        throw StateError('audio device is required for this mix setup');
      }
      final checkpoint = await _mixPersistence.read(device);
      if (generation != _looper.mixGeneration ||
          device != _looper.state.status.deviceName) {
        throw StateError('audio device changed before session load');
      }
      await _fxPersistence.beginSessionLoad();
      try {
        try {
          await _mixPersistence.write(device, candidate);
        } on Object {
          final rollback = await _mixSettings.rollbackExclusive(
            device: device,
            checkpoint: checkpoint,
          );
          if (rollback.status == MixSettingsStatus.recoveryRequired) {
            throw MixSettingsRecoveryException(rollback);
          }
          rethrow;
        }
        if (generation != _looper.mixGeneration ||
            device != _looper.state.status.deviceName) {
          final rollback = await _mixSettings.rollbackExclusive(
            device: device,
            checkpoint: checkpoint,
          );
          if (rollback.status == MixSettingsStatus.recoveryRequired) {
            throw MixSettingsRecoveryException(rollback);
          }
          throw StateError('audio device changed before session load');
        }
        // The remap is control-surface configuration outside the rig.
        // applies, so it leaves through its own seam rather than
        // `SessionRig`. Its halves sit on opposite sides of the apply.
        //
        // Release first: a held momentary's state belongs on the outgoing
        // rig. After apply it would instead stamp the old values onto
        // old session's values onto the chains the new one just installed,
        // bringing a freshly loaded session up bypassed.
        try {
          _releaseHeldBindings();
        } on Object {
          final rollback = await _mixSettings.rollbackExclusive(
            device: device,
            checkpoint: checkpoint,
          );
          if (rollback.status == MixSettingsStatus.recoveryRequired) {
            throw MixSettingsRecoveryException(rollback);
          }
          rethrow;
        }
        // Keep transport admission closed across apply and boot storage.
        // The callback continues processing the imported, stopped tracks.
        _looper.blockStartForSessionBoot();
        try {
          await _looper.applySession(rig);
        } on Object {
          _looper
            ..stopEngine()
            ..clearSessionBootStartBlock();
          final rollback = await _mixSettings.rollbackExclusive(
            device: device,
            checkpoint: checkpoint,
          );
          if (rollback.status == MixSettingsStatus.recoveryRequired) {
            throw MixSettingsRecoveryException(rollback);
          }
          rethrow;
        }
        applied = true;
        final notice = conversion == null || path == null
            ? null
            : await _commitConversion(path, conversion);
        _pendingLoadedId = id;
        _pendingLoadedName = name;
        _pendingLoadedBindings = pedalBindings;
        _pendingLoadedSessions = sessions;
        _pendingLoadedFade = fade;
        _pendingConversion = notice;
        // The live rig is the new session, even if boot keys fail later.
        // Do not publish loaded or enable its bindings until persistence
        // and readback of the full image have finished.
        if (!isClosed) {
          emit(
            state.copyWith(
              status: SessionStatus.working,
              currentSessionId: id,
              currentSessionName: name,
              bootRecoveryRequired: true,
            ),
          );
        }
        await _fxPersistence.persistLoadedSession(_settings);
        await _captureSettings.installFade(fade);
        _onPedalBindings(pedalBindings);
        _fxPersistence.completeSessionBoot();
        _looper.clearSessionBootStartBlock();
        _pendingLoadedId = null;
        _pendingLoadedName = null;
        _pendingLoadedBindings = null;
        _pendingLoadedSessions = null;
        _pendingLoadedFade = null;
        _pendingConversion = null;
        return (sessions: sessions, notice: notice);
      } on Object catch (error) {
        if (!applied) {
          _fxPersistence.cancelSessionLoad();
          rethrow;
        }
        _looper.stopEngine();
        _fxPersistence.markSessionBootFailed();
        throw _SessionBootException(error);
      }
    } finally {
      applying?.release();
    }
  }

  /// Writes an applied [conversion] back to the bundle at [path] and returns
  /// what the player is told. A failure is not raised: the converted rig is
  /// already live and the original manifest is still on disk, untouched; the
  /// notice then says so instead of claiming a backup, and the next save
  /// keeps the original as the backup.
  Future<SessionConversionNotice> _commitConversion(
    String path,
    SessionConversion conversion,
  ) async {
    var written = false;
    try {
      written = await _repository.commitConversion(path, conversion);
      AppLog.info(
        'session converted from schema ${conversion.fromVersion}: $path; '
        '${conversion.notes.join('; ')}',
      );
    } on Object catch (error) {
      AppLog.warn('session conversion not written back: $path: $error');
    }
    return SessionConversionNotice(
      fromVersion: conversion.fromVersion,
      written: written,
      changes: conversion.changes,
    );
  }

  /// Retries the stopped loaded rig's exact retained boot image and bindings.
  ///
  /// Takes no `sessionApply` guard: it re-persists settings for a rig that is
  /// already applied and stopped, and never re-applies audio to the engine.
  Future<void> retryLoadedSession() => _run(
    () => _captureSettings.runExclusive(() async {
      final id = _pendingLoadedId;
      final name = _pendingLoadedName;
      final bindings = _pendingLoadedBindings;
      final sessions = _pendingLoadedSessions;
      final fade = _pendingLoadedFade;
      final conversion = _pendingConversion;
      if (id == null ||
          name == null ||
          bindings == null ||
          sessions == null ||
          fade == null ||
          !_fxPersistence.sessionBootRecoveryRequired) {
        throw StateError('no loaded session needs boot recovery');
      }
      try {
        await _fxPersistence.retrySessionBoot();
        await _captureSettings.installFade(fade);
        _onPedalBindings(bindings);
        _fxPersistence.completeSessionBoot();
        _looper.clearSessionBootStartBlock();
        _pendingLoadedId = null;
        _pendingLoadedName = null;
        _pendingLoadedBindings = null;
        _pendingLoadedSessions = null;
        _pendingLoadedFade = null;
        _pendingConversion = null;
        await _recordOpenedFingerprint();
        return _ActionResult(
          SessionOutcome.loaded,
          currentId: id,
          currentName: name,
          sessions: sessions,
          conversion: conversion,
        );
      } on Object catch (error) {
        throw _SessionBootException(error);
      }
    }),
    allowBootRecovery: true,
  );

  /// Renames session [id] to [name] (metadata only; the bundle and its audio
  /// stay where they are). If [id] is the open session, the header name
  /// follows. A name collision surfaces as [SessionError.nameCollision] (the
  /// repository is the authority).
  Future<void> renameSession(SessionId id, String name) => _run(() async {
    await _repository.renameSession(id, name);
    return _ActionResult(
      SessionOutcome.renamed,
      currentName: state.currentSessionId == id ? _slugOf(name) : null,
      sessions: await _repository.listSessions(),
    );
  });

  /// Deletes the saved session [id]. The open session is protected: deleting
  /// it is refused with [SessionError.currentSessionProtected] and nothing is
  /// removed (plan D6; the cubit is the authority, the Manage sheet's
  /// disabled row is fast feedback).
  Future<void> deleteSession(SessionId id) => _run(() async {
    if (state.currentSessionId == id) {
      throw const _SessionRefusal(SessionError.currentSessionProtected);
    }
    await _repository.deleteSession(id);
    return _ActionResult(
      SessionOutcome.deleted,
      sessions: await _repository.listSessions(),
    );
  });

  /// Duplicates the saved session [id] to a NEW session named [name] (a copy
  /// on disk under a fresh id; the open session is unchanged). A name
  /// collision surfaces as [SessionError.nameCollision] (the repository is
  /// the authority).
  Future<void> duplicateSession(SessionId id, String name) => _run(() async {
    await _repository.duplicateSession(id, name);
    return _ActionResult(
      SessionOutcome.duplicated,
      sessions: await _repository.listSessions(),
    );
  });

  /// Moves the saved session [id] into [folder], or to the root (Unfiled)
  /// when [folder] is null. Its id, name and audio stay as they are, so the
  /// open session can move too.
  Future<void> moveSession(SessionId id, {String? folder}) => _run(() async {
    await _repository.moveSession(id, folder: folder);
    return _ActionResult(
      SessionOutcome.moved,
      sessions: await _repository.listSessions(),
    );
  });

  /// Deletes the folder [name]. One that still holds a session, or an
  /// interrupted save, is refused with [SessionError.folderNotEmpty] and
  /// nothing is removed: the catalog never deletes audio as a side effect.
  Future<void> deleteFolder(String name) => _run(() async {
    await _repository.deleteFolder(name);
    return _ActionResult(
      SessionOutcome.folderDeleted,
      sessions: await _repository.listSessions(),
    );
  });

  /// Renames the folder [name] to [to]; its sessions move with it and keep
  /// their ids, so the open session stays open. A taken name surfaces as
  /// [SessionError.nameCollision].
  Future<void> renameFolder(String name, String to) => _run(() async {
    await _repository.renameFolder(name, to);
    return _ActionResult(
      SessionOutcome.folderRenamed,
      sessions: await _repository.listSessions(),
    );
  });

  /// Creates the folder [name]. A name a folder or session directory already
  /// has surfaces as [SessionError.nameCollision].
  Future<void> createFolder(String name) => _run(() async {
    await _repository.createFolder(name);
    return _ActionResult(
      SessionOutcome.folderCreated,
      sessions: await _repository.listSessions(),
    );
  });

  /// The display name [name] resolves to, or throws [ArgumentError] when it
  /// sanitizes to nothing (the same rule the repository enforces).
  String _slugOf(String name) {
    final slug = sessionSlug(name);
    if (slug == null) {
      throw ArgumentError.value(name, 'name', 'not a valid session name');
    }
    return slug;
  }

  /// Runs [action] with the standard working → success/failure envelope,
  /// folding its durable-catalog changes into the next state and preserving the
  /// open session + list across the transition.
  ///
  /// [subject] is the session the action addresses; a failure carries it as
  /// [SessionState.failedSessionId], so the Library can show an Open's
  /// refusal on the session that refused and nowhere else.
  Future<void> _run(
    Future<_ActionResult> Function() action, {
    bool allowBootRecovery = false,
    bool reserveSessionLoad = false,
    SessionId? subject,
  }) {
    if (_closing || isClosed) return Future<void>.value();
    final operation = _performRun(
      action,
      subject: subject,
      allowBootRecovery: allowBootRecovery,
      reserveSessionLoad: reserveSessionLoad,
    );
    _track(operation);
    return operation;
  }

  void _track(Future<void> operation) {
    late final Future<void> settled;
    settled = operation.then<void>(
      (_) => _activeOperations.remove(settled),
      onError: (Object error, StackTrace stack) =>
          _activeOperations.remove(settled),
    );
    _activeOperations.add(settled);
  }

  Future<void> _performRun(
    Future<_ActionResult> Function() action, {
    required SessionId? subject,
    required bool allowBootRecovery,
    required bool reserveSessionLoad,
  }) async {
    if (!allowBootRecovery && _fxPersistence.sessionBootRecoveryRequired) {
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          failedSessionId: subject,
          error: SessionError.bootPersistence,
          errorMessage: 'session boot settings still need recovery',
          bootRecoveryRequired: true,
        ),
      );
      return;
    }
    if (!allowBootRecovery &&
        !reserveSessionLoad &&
        _fxPersistence.sessionTransitionActive) {
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          failedSessionId: subject,
          error: SessionError.unknown,
          errorMessage: 'session load is still in progress',
        ),
      );
      return;
    }
    if (reserveSessionLoad) {
      if (_fxPersistence.sessionTransitionActive) {
        emit(
          state.copyWith(
            status: SessionStatus.failure,
            failedSessionId: subject,
            error: SessionError.unknown,
            errorMessage: 'a session load is already active',
          ),
        );
        return;
      }
      _fxPersistence.reserveSessionLoad();
    }
    emit(state.copyWith(status: SessionStatus.working));
    try {
      final result = await action();
      // Every action that re-lists the sessions re-lists the folders too.
      final folders = result.sessions == null ? null : await _listFolders();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.success,
          outcome: result.outcome,
          currentSessionId: result.currentId,
          currentSessionName: result.currentName,
          sessions: result.sessions,
          folders: folders,
          bootRecoveryRequired: false,
          conversion: result.conversion,
        ),
      );
    } on _SessionRefusal catch (refusal) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          error: refusal.error,
          errorMessage: '${refusal.cause ?? refusal.error.name}',
        ),
      );
    } on _SessionBootException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          failedSessionId: subject,
          error: SessionError.bootPersistence,
          errorMessage: '${error.cause}',
          bootRecoveryRequired: true,
        ),
      );
    } on GuardRefused catch (error) {
      // Refused at its commit by an operation in flight (#1198): nothing
      // changed, and the player is told what to wait for.
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          error: SessionError.busy,
          errorMessage: '$error',
          refusedBy: error.blockers.first.kind,
        ),
      );
    } on SessionException catch (error) {
      // Recoverable, user-facing refusals: classify so the UI can localize.
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          failedSessionId: subject,
          error: _classify(error),
          errorMessage: '$error',
        ),
      );
    } on Object catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
          failedSessionId: subject,
          error: SessionError.unknown,
          errorMessage: '$error',
        ),
      );
    }
  }

  @override
  Future<void> close() {
    final closing = _closingFuture;
    if (closing != null) return closing;
    _closing = true;
    return _closingFuture = () async {
      await Future.wait(_activeOperations.toList());
      await super.close();
    }();
  }

  static SessionError _classify(SessionException error) => switch (error) {
    SessionSampleRateMismatch() => SessionError.sampleRateMismatch,
    SessionUnsupportedVersion() => SessionError.unsupportedVersion,
    SessionUnconvertible() => SessionError.unconvertible,
    SessionNameCollision() => SessionError.nameCollision,
    SessionCorruptLayers() => SessionError.corruptLayers,
    SessionFolderNotEmpty() => SessionError.folderNotEmpty,
  };
}

/// A refusal the cubit itself decides ([SessionError.currentSessionProtected])
/// or classifies ([SessionError.saveFailed], with the write's own [cause]).
class _SessionRefusal implements Exception {
  const _SessionRefusal(this.error, [this.cause]);

  final SessionError error;
  final Object? cause;
}

class _SessionBootException implements Exception {
  const _SessionBootException(this.cause);

  final Object cause;
}

/// What a session action changed: its success [outcome] plus any durable
/// catalog updates to fold into the next state.
class _ActionResult {
  const _ActionResult(
    this.outcome, {
    this.currentId,
    this.currentName,
    this.sessions,
    this.conversion,
  });

  final SessionOutcome outcome;
  final SessionId? currentId;
  final String? currentName;
  final List<SessionSummary>? sessions;
  final SessionConversionNotice? conversion;
}
