import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
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
    String Function() currentPedalBindings = _noBindings,
    void Function(String encoded) onPedalBindings = _ignoreBindings,
    void Function() releaseHeldBindings = _noRelease,
  }) : _repository = repository,
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
        await _asSaveFailure(
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
          await _asSaveFailure(
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
        return _ActionResult(
          SessionOutcome.savedAs,
          currentId: id,
          currentName: slug,
          sessions: await _repository.listSessions(),
        );
      }),
    );
  }

  /// Runs a save's write and reports any failure that is not a typed
  /// session refusal as [SessionError.saveFailed], the 19/05 banner's
  /// "Could not save your current loop. Nothing was changed."
  static Future<void> _asSaveFailure(Future<void> Function() write) async {
    try {
      await write();
    } on SessionException {
      rethrow;
    } on Object catch (error) {
      throw _SessionRefusal(SessionError.saveFailed, error);
    }
  }

  Future<void> _saveCurrentRig(
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
    await _repository.save(
      directory,
      chains: captured.chains,
      settings: captured.settings,
      pedalBindings: _currentPedalBindings(),
      name: name,
      captureStillValid: stillOwned,
    );
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
  Future<void> open(SessionId id) => _run(
    subject: id,
    () async {
      var applied = false;
      try {
        return await _captureSettings.runExclusive(() async {
          final path = await _repository.bundlePathOf(id);
          final (:bundle, :conversion) = await _repository.open(
            path,
            liveSettings: _captureSettings.current,
          );
          final fade = FadeDurations(
            defaultMs: bundle.session.defaultFadeDurationMs,
            overrides: bundle.session.trackFadeDurationOverrides,
          );
          final rig = rigFromBundle(bundle);
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
          final disarmed = await _performance.disarmAndFinalize();
          if (!disarmed.isOk) {
            throw StateError(
              'performance capture did not stop before session load',
            );
          }
          // The header shows the manifest's name; a bundle saved before names
          // were metadata shows its directory name, as the catalog does.
          final loadedName = bundle.session.name ?? id;
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
            final notice = conversion == null
                ? null
                : await _commitConversion(path, conversion);
            _pendingLoadedId = id;
            _pendingLoadedName = loadedName;
            _pendingLoadedBindings = bundle.session.pedalBindings;
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
                  currentSessionName: loadedName,
                  bootRecoveryRequired: true,
                ),
              );
            }
            await _fxPersistence.persistLoadedSession(_settings);
            await _captureSettings.installFade(fade);
            _onPedalBindings(bundle.session.pedalBindings);
            _fxPersistence.completeSessionBoot();
            _looper.clearSessionBootStartBlock();
            _pendingLoadedId = null;
            _pendingLoadedName = null;
            _pendingLoadedBindings = null;
            _pendingLoadedSessions = null;
            _pendingLoadedFade = null;
            _pendingConversion = null;
            return _ActionResult(
              SessionOutcome.loaded,
              currentId: id,
              currentName: loadedName,
              sessions: sessions,
              conversion: notice,
            );
          } on Object catch (error) {
            if (!applied) {
              _fxPersistence.cancelSessionLoad();
              rethrow;
            }
            _looper.stopEngine();
            _fxPersistence.markSessionBootFailed();
            throw _SessionBootException(error);
          }
        });
      } on Object {
        if (!applied) _fxPersistence.cancelSessionLoad();
        rethrow;
      }
    },
    reserveSessionLoad: true,
  );

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
