import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'session_state.dart';

/// Drives session persistence (save / load / export) and the named-session
/// catalog (list / save-as / rename / delete), tracking the open session so a
/// plain [save] writes back without re-prompting (the document model).
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
  /// [exportDirectory] resolves the directory a mixdown / stems are written to;
  /// the named-session methods go through [repository]'s catalog instead.
  /// Injecting it keeps the cubit testable.
  ///
  /// [currentPedalBindings] / [onPedalBindings] are the session's pedal remap
  /// (part 6b) crossing this cubit as an opaque string — read fresh at each
  /// save, handed back on each load. [releaseHeldBindings] restores any held
  /// momentary and runs BEFORE a load applies its rig (see [loadNamed] for why
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
    required Future<String> Function() exportDirectory,
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
       _exportDirectory = exportDirectory,
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
  final Future<String> Function() _exportDirectory;
  final String Function() _currentPedalBindings;
  final void Function(String encoded) _onPedalBindings;
  final void Function() _releaseHeldBindings;
  String? _pendingLoadedBindings;
  String? _pendingLoadedName;
  List<SessionSummary>? _pendingLoadedSessions;
  FadeDurations? _pendingLoadedFade;
  final _activeOperations = <Future<void>>{};
  Future<void>? _closingFuture;
  bool _closing = false;

  // ---- exports (a separate action from the session catalog) ----

  /// Exports a mixed-down WAV of the live rig into the export directory.
  Future<void> exportMixdown() => _run(() async {
    await _repository.exportMixdown(
      '${await _exportDirectory()}/${SessionRepository.mixdownName}',
    );
    return const _ActionResult(SessionOutcome.mixdownExported);
  });

  /// Exports each track as a separate stem WAV under a `stems` folder.
  Future<void> exportStems() => _run(() async {
    await _repository.exportStems('${await _exportDirectory()}/stems');
    return const _ActionResult(SessionOutcome.stemsExported);
  });

  // ---- named-session catalog (the document model) ----

  /// Reloads the saved-session catalog into state (for the picker). A quiet
  /// update — no working/success cycle.
  Future<void> refreshSessions() async {
    if (_closing || isClosed) return;
    final operation = _refreshSessions();
    _track(operation);
    await operation;
  }

  Future<void> _refreshSessions() async {
    final sessions = await _repository.listSessions();
    if (_closing || isClosed) return;
    emit(state.copyWith(sessions: sessions));
  }

  /// Saves the live rig as a NEW named session and makes it current. Rejects a
  /// duplicate slug with [SessionError.nameCollision] and writes nothing.
  Future<void> saveAs(String name) {
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    return _run(
      () => _captureSettings.runExclusive(() async {
        final slug = _slugOf(name);
        if ((await _repository.listSessions()).any((s) => s.name == slug)) {
          throw SessionNameCollision(slug: slug);
        }
        await _saveCurrentRig(
          await _repository.bundlePath(name),
          revision,
          generation,
          device,
        );
        return _ActionResult(
          SessionOutcome.saved,
          currentName: slug,
          sessions: await _repository.listSessions(),
        );
      }),
    );
  }

  /// Writes the live rig back to the open session with no prompt. With no open
  /// session, signals the UI to open Save-As ([SessionOutcome.saveAsRequested])
  /// rather than silently picking a name.
  Future<void> save() {
    if (_closing || isClosed) return Future<void>.value();
    final name = state.currentSessionName;
    if (name == null) {
      emit(
        state.copyWith(
          status: SessionStatus.idle,
          outcome: SessionOutcome.saveAsRequested,
        ),
      );
      return Future<void>.value();
    }
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    return _run(
      () => _captureSettings.runExclusive(() async {
        await _saveCurrentRig(
          await _repository.bundlePath(name),
          revision,
          generation,
          device,
        );
        // Re-list, like every other mutation: the sessions dialog stays open by
        // design, and its date column reads the catalog — without this a
        // just-saved session goes on saying "yesterday".
        return _ActionResult(
          SessionOutcome.saved,
          sessions: await _repository.listSessions(),
        );
      }),
    );
  }

  Future<void> _saveCurrentRig(
    String directory,
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
      captureStillValid: stillOwned,
    );
  }

  /// Loads named session [name] into the engine through the looper repository
  /// (the one apply path), makes it current, and refreshes the catalog.
  ///
  /// Auto-disarms and finalizes an in-progress performance-recording capture
  /// first — applying a loaded session mid-capture would otherwise pull the
  /// rug out from under it. The finalize + render run through the same path a
  /// manual disarm does; `PerformanceRecorderCubit` observes the repository's
  /// status stream, so it reflects this disarm too even though it was never
  /// the one to call it.
  Future<void> loadNamed(String name) => _run(
    () async {
      var applied = false;
      try {
        return await _captureSettings.runExclusive(() async {
          final bundle = await _repository.read(
            await _repository.bundlePath(name),
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
          final loadedName = _slugOf(name);
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
            _pendingLoadedName = loadedName;
            _pendingLoadedBindings = bundle.session.pedalBindings;
            _pendingLoadedSessions = sessions;
            _pendingLoadedFade = fade;
            // The live rig is the new session, even if boot keys fail later.
            // Do not publish loaded or enable its bindings until persistence
            // and readback of the full image have finished.
            if (!isClosed) {
              emit(
                state.copyWith(
                  status: SessionStatus.working,
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
            _pendingLoadedName = null;
            _pendingLoadedBindings = null;
            _pendingLoadedSessions = null;
            _pendingLoadedFade = null;
            return _ActionResult(
              SessionOutcome.loaded,
              currentName: loadedName,
              sessions: sessions,
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

  /// Retries the stopped loaded rig's exact retained boot image and bindings.
  Future<void> retryLoadedSession() => _run(
    () => _captureSettings.runExclusive(() async {
      final name = _pendingLoadedName;
      final bindings = _pendingLoadedBindings;
      final sessions = _pendingLoadedSessions;
      final fade = _pendingLoadedFade;
      if (name == null ||
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
        _pendingLoadedName = null;
        _pendingLoadedBindings = null;
        _pendingLoadedSessions = null;
        _pendingLoadedFade = null;
        return _ActionResult(
          SessionOutcome.loaded,
          currentName: name,
          sessions: sessions,
        );
      } on Object catch (error) {
        throw _SessionBootException(error);
      }
    }),
    allowBootRecovery: true,
  );

  /// Renames session [from] to [to]. If [from] is the open session, the current
  /// pointer follows the rename. A slug collision surfaces as
  /// [SessionError.nameCollision] (the repository is the authority).
  Future<void> renameSession(String from, String to) => _run(() async {
    await _repository.renameSession(from, to);
    final open = state.currentSessionName;
    return _ActionResult(
      SessionOutcome.renamed,
      currentName: open == from ? _slugOf(to) : open,
      sessions: await _repository.listSessions(),
    );
  });

  /// Deletes session [name]. If it is the open session, the current pointer is
  /// cleared — the live rig keeps playing (the engine is never touched here).
  Future<void> deleteSession(String name) => _run(() async {
    await _repository.deleteSession(name);
    final wasOpen = state.currentSessionName == _slugOf(name);
    return _ActionResult(
      SessionOutcome.deleted,
      clearCurrent: wasOpen,
      sessions: await _repository.listSessions(),
    );
  });

  /// Duplicates saved session [from] to a NEW named session [to] (a copy on
  /// disk; the open session is unchanged). A slug collision surfaces as
  /// [SessionError.nameCollision] (the repository is the authority).
  Future<void> duplicateSession(String from, String to) => _run(() async {
    await _repository.duplicateSession(from, to);
    return _ActionResult(
      SessionOutcome.saved,
      sessions: await _repository.listSessions(),
    );
  });

  /// The slug [name] resolves to, or throws [ArgumentError] when it sanitizes
  /// to nothing (the same rule the repository's `bundlePath` enforces).
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
  Future<void> _run(
    Future<_ActionResult> Function() action, {
    bool allowBootRecovery = false,
    bool reserveSessionLoad = false,
  }) {
    if (_closing || isClosed) return Future<void>.value();
    final operation = _performRun(
      action,
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
    required bool allowBootRecovery,
    required bool reserveSessionLoad,
  }) async {
    if (!allowBootRecovery && _fxPersistence.sessionBootRecoveryRequired) {
      emit(
        state.copyWith(
          status: SessionStatus.failure,
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
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.success,
          outcome: result.outcome,
          currentSessionName: result.currentName,
          clearCurrentSession: result.clearCurrent,
          sessions: result.sessions,
          bootRecoveryRequired: false,
        ),
      );
    } on _SessionBootException catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
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
          error: _classify(error),
          errorMessage: '$error',
        ),
      );
    } on Object catch (error) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SessionStatus.failure,
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
    SessionNameCollision() => SessionError.nameCollision,
    SessionCorruptLayers() => SessionError.corruptLayers,
  };
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
    this.currentName,
    this.clearCurrent = false,
    this.sessions,
  });

  final SessionOutcome outcome;
  final String? currentName;
  final bool clearCurrent;
  final List<SessionSummary>? sessions;
}
