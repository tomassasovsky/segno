import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:session_repository/session_repository.dart';

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
    required MixSettingsPersistence mixPersistence,
    required Future<T> Function<T>(Future<T> Function() operation)
    runClickVolumeExclusive,
    required double Function() currentDurableClickVolume,
    required Future<T> Function<T>(Future<T> Function() operation)
    runDecayExclusive,
    required DecaySnapshot Function() currentDurableDecay,
    required Future<String> Function() exportDirectory,
    String Function() currentPedalBindings = _noBindings,
    void Function(String encoded) onPedalBindings = _ignoreBindings,
    void Function() releaseHeldBindings = _noRelease,
  }) : _repository = repository,
       _looper = looper,
       _performance = performance,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _mixPersistence = mixPersistence,
       _runClickVolumeExclusive = runClickVolumeExclusive,
       _currentDurableClickVolume = currentDurableClickVolume,
       _runDecayExclusive = runDecayExclusive,
       _currentDurableDecay = currentDurableDecay,
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
  final MixSettingsPersistence _mixPersistence;
  final Future<T> Function<T>(Future<T> Function() operation)
  _runClickVolumeExclusive;
  final double Function() _currentDurableClickVolume;
  final Future<T> Function<T>(Future<T> Function() operation)
  _runDecayExclusive;
  final DecaySnapshot Function() _currentDurableDecay;
  final Future<String> Function() _exportDirectory;
  final String Function() _currentPedalBindings;
  final void Function(String encoded) _onPedalBindings;
  final void Function() _releaseHeldBindings;

  // One lock order for every session boundary: Mixer, then Click, then Decay.
  Future<T> _runSettingsExclusive<T>(Future<T> Function() operation) =>
      _mixSettings.runExclusive(
        () => _runClickVolumeExclusive(() => _runDecayExclusive(operation)),
      );

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
    final sessions = await _repository.listSessions();
    if (isClosed) return;
    emit(state.copyWith(sessions: sessions));
  }

  /// Saves the live rig as a NEW named session and makes it current. Rejects a
  /// duplicate slug with [SessionError.nameCollision] and writes nothing.
  Future<void> saveAs(String name) {
    final revision = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final device = _looper.state.status.deviceName;
    return _run(
      () => _runSettingsExclusive(() async {
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
      () => _runSettingsExclusive(() async {
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
    if (!_looper.lengthSettingsSettled) {
      final result = await _looper.settleLengthSettings();
      if (!result.isOk || !stillOwned()) {
        throw StateError('length settings did not settle before session save');
      }
    }
    if (!_looper.mixSettingsSettled) {
      final result = await _looper.settleMixSettings();
      if (!result.isOk || !stillOwned()) {
        throw StateError('mix settings did not settle before session save');
      }
    }
    final mixOutcome = await _mixSettings.flush();
    if (!mixOutcome.isOk || !stillOwned()) {
      throw StateError('mix edit did not settle before session save');
    }
    await _fxPersistence.settlePending();
    if (!stillOwned()) throw StateError('session changed before snapshot');
    await _repository.save(
      directory,
      chains: chainsFromLooper(
        _looper,
        projection: _fxPersistence,
        mix: _mixSettings.durableSnapshot,
      ),
      settings: settingsFromLooper(
        _looper,
        mix: _mixSettings.durableSnapshot,
        clickVolume: _currentDurableClickVolume(),
        decay: _currentDurableDecay(),
      ),
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
    () => _runSettingsExclusive(() async {
      final disarmed = await _performance.disarmAndFinalize();
      if (!disarmed.isOk) {
        throw StateError(
          'performance capture did not stop before session load',
        );
      }
      final bundle = await _repository.read(await _repository.bundlePath(name));
      final rig = rigFromBundle(bundle);
      final candidate = MixSettingsSnapshot.fromRig(rig);
      if (!candidate.isValid) throw StateError('session mix is invalid');
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
      // The remap is control-surface configuration outside the rig the engine
      // applies, so it leaves through its own seam rather than
      // `SessionRig`. Its two halves belong on opposite sides of the apply.
      //
      // Release first: a held momentary's captured state has to be written back
      // onto the OUTGOING rig. Run after the apply it would instead stamp the
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
      try {
        await _looper.applySession(rig);
      } on Object {
        _looper.stopEngine();
        final rollback = await _mixSettings.rollbackExclusive(
          device: device,
          checkpoint: checkpoint,
        );
        if (rollback.status == MixSettingsStatus.recoveryRequired) {
          throw MixSettingsRecoveryException(rollback);
        }
        rethrow;
      }
      // Commit last: only once the rig actually landed. `applySession` can
      // throw, and `_run` catches everything — committing before it would leave
      // the pedal dispatching a failed session's bindings against the rig that
      // is still loaded, a mapping the user never activated.
      _onPedalBindings(bundle.session.pedalBindings);
      return _ActionResult(
        SessionOutcome.loaded,
        currentName: _slugOf(name),
        sessions: await _repository.listSessions(),
      );
    }),
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
  Future<void> _run(Future<_ActionResult> Function() action) async {
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

  static SessionError _classify(SessionException error) => switch (error) {
    SessionSampleRateMismatch() => SessionError.sampleRateMismatch,
    SessionUnsupportedVersion() => SessionError.unsupportedVersion,
    SessionNameCollision() => SessionError.nameCollision,
    SessionCorruptLayers() => SessionError.corruptLayers,
  };
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
