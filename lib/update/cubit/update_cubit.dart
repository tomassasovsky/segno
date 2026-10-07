import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

part 'update_state.dart';

/// Drives the opt-in update UX: a passive read-only availability check that
/// powers the startup notification, plus the user-triggered download/stage and
/// apply. Nothing downloads or installs without an explicit call to
/// [startDownload]; only [check] runs automatically (and only when
/// [UpdateState.autoCheck] is on). Install and restart is the power flow's
/// restart (`PowerCubit.restart`), which saves the session first; the
/// helper's reboot boots a staged slot whenever one is staged.
///
/// It also reports what the last run left behind instead of hiding it: an
/// install cut off by a crash or a power loss ([UpdatePhase.interrupted]) and
/// a staged build that did not start ([UpdateState.rollback]).
class UpdateCubit extends Cubit<UpdateState> {
  /// Creates an [UpdateCubit]. Off until [load] restores preferences and (when
  /// auto-check is on) runs the first check.
  UpdateCubit({
    required UpdateRepository updates,
    required SettingsRepository settings,
  }) : _updates = updates,
       _settings = settings,
       super(const UpdateState());

  final UpdateRepository _updates;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// The download in flight, so [cancelDownload] can stop it.
  StreamSubscription<double>? _download;

  /// Completes [startDownload]'s future however the download ends.
  Completer<void>? _downloadDone;

  /// Restores persisted preferences, reads what the last run left behind
  /// and, if auto-check is enabled and the platform is supported, runs the
  /// first read-only check. Idempotent.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final autoCheck = await _settings.loadUpdateAutoCheck();
    final dismissed = await _settings.loadDismissedUpdateVersions();
    final savedChannel = await _settings.loadUpdateChannel();
    if (savedChannel != null) {
      await _updates.setChannel(savedChannel);
    }
    final current = await _updates.currentVersion();
    final recovery = await _updates.recover();
    var rollback = await _settings.loadUpdateRollback();
    final rolledBack = recovery.rolledBack;
    if (rolledBack != null) {
      // Reported once by the helper, so kept until the notice is dismissed.
      rollback = (attempted: rolledBack, restored: current);
      await _settings.saveUpdateRollback(
        attempted: rolledBack,
        restored: current,
      );
    }
    var interrupted = recovery.interrupted;
    if (interrupted != null && await _updates.stagedVersion() > current) {
      // Something else staged a build since; the cut-off attempt is moot.
      await _updates.clearInterrupted();
      interrupted = null;
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        supported: _updates.isSupported,
        channel: _updates.channel,
        currentVersion: current,
        autoCheck: autoCheck,
        dismissed: dismissed,
        rollback: rollback,
        interrupted: interrupted,
        phase: interrupted == null ? null : UpdatePhase.interrupted,
      ),
    );
    // An interrupted install waits for the player's Retry or Cancel; a check
    // now would paper over it with a fresh offer.
    if (autoCheck && _updates.isSupported && interrupted == null) {
      await check();
    }
  }

  /// Runs a read-only availability check (no download, no install). No-op on an
  /// unsupported platform.
  Future<void> check() async {
    if (!_updates.isSupported) return;
    emit(state.copyWith(phase: UpdatePhase.checking, clearError: true));
    try {
      final manifest = await _updates.checkForUpdate();
      if (isClosed) return;
      if (manifest != null) {
        emit(
          state.copyWith(phase: UpdatePhase.available, available: manifest),
        );
        return;
      }
      // Nothing newer to download — but a prior stage may still be waiting for
      // "Restart to apply" (staged > current after reconcile clears rollbacks).
      final current = await _updates.currentVersion();
      final staged = await _updates.stagedVersion();
      if (isClosed) return;
      if (staged > current) {
        emit(
          state.copyWith(
            phase: UpdatePhase.staged,
            available: UpdateManifest(
              version: staged,
              bundle: '',
              channel: _updates.channel,
            ),
            currentVersion: current,
          ),
        );
        return;
      }
      emit(
        state.copyWith(
          phase: UpdatePhase.upToDate,
          clearAvailable: true,
          currentVersion: current,
        ),
      );
    } on Object catch (error) {
      if (!isClosed) {
        emit(
          state.copyWith(
            phase: UpdatePhase.error,
            errorMessage: '$error',
            failure: UpdateFailure.check,
          ),
        );
      }
    }
  }

  /// Downloads and stages the available bundle to the inactive slot, tracking
  /// progress. Opt-in — call only from an explicit user action. No-op when no
  /// update is available or one is already downloading. Completes when the
  /// download is staged, fails, or is cancelled.
  Future<void> startDownload() {
    final manifest = state.available;
    if (manifest == null || _download != null) return Future.value();
    emit(
      state.copyWith(
        phase: UpdatePhase.downloading,
        progress: 0,
        clearError: true,
      ),
    );
    final done = _downloadDone = Completer<void>();
    _download = _updates
        .downloadAndStage(manifest)
        .listen(
          (progress) {
            if (!isClosed) {
              emit(state.copyWith(progress: progress.clamp(0.0, 1.0)));
            }
          },
          onError: (Object error) {
            _endDownload();
            if (!isClosed) {
              emit(
                state.copyWith(
                  phase: UpdatePhase.error,
                  errorMessage: '$error',
                  failure: UpdateFailure.download,
                ),
              );
            }
          },
          onDone: () {
            _endDownload();
            if (!isClosed) {
              emit(state.copyWith(phase: UpdatePhase.staged, progress: 1));
            }
          },
          cancelOnError: true,
        );
    return done.future;
  }

  /// Stops the download in flight and returns to the offer with nothing
  /// staged. The helper is killed rather than asked, and a kill leaves its
  /// attempt record behind for the next start to find; a cancel the player
  /// chose is not an interruption, so that record is cleared here.
  Future<void> cancelDownload() async {
    if (_download == null) return;
    await _download?.cancel();
    _endDownload();
    await _updates.clearInterrupted();
    if (isClosed) return;
    emit(state.copyWith(phase: UpdatePhase.available, progress: 0));
  }

  void _endDownload() {
    _download = null;
    final done = _downloadDone;
    _downloadDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Retries an install that was cut off: forgets the cut-off attempt, looks
  /// again, and downloads what the check offers. The check may find the
  /// build gone or superseded; it then shows what it found instead.
  Future<void> retryInterrupted() async {
    if (state.phase != UpdatePhase.interrupted) return;
    await _updates.clearInterrupted();
    if (isClosed) return;
    emit(state.copyWith(clearInterrupted: true));
    await check();
    if (state.phase == UpdatePhase.available) await startDownload();
  }

  /// Drops an install that was cut off. Nothing was changed by it; the panel
  /// goes back to plain Software updates.
  Future<void> discardInterrupted() async {
    if (state.phase != UpdatePhase.interrupted) return;
    await _updates.clearInterrupted();
    if (isClosed) return;
    emit(state.copyWith(phase: UpdatePhase.idle, clearInterrupted: true));
  }

  /// Dismisses the rolled-back notice for good.
  Future<void> dismissRollback() async {
    if (state.rollback == null) return;
    emit(state.copyWith(clearRollback: true));
    await _settings.clearUpdateRollback();
  }

  /// Records that the user dismissed the notification for [version], so it will
  /// not be shown again until a newer version appears.
  Future<void> dismiss(Version version) async {
    if (state.dismissed.contains(version)) return;
    final next = {...state.dismissed, version};
    emit(state.copyWith(dismissed: next));
    await _settings.saveDismissedUpdateVersions(next);
  }

  /// Sets and persists whether the passive check runs automatically.
  Future<void> setAutoCheck({required bool value}) async {
    if (value != state.autoCheck) emit(state.copyWith(autoCheck: value));
    await _settings.saveUpdateAutoCheck(value: value);
  }

  /// Switches between the experimental and production update channels.
  /// Persists the choice, writes the appliance override the OTA helper reads,
  /// clears any in-flight offer from the previous channel, and re-checks.
  /// No-op while a download is in progress.
  Future<void> setExperimentalChannel({required bool value}) async {
    if (state.phase == UpdatePhase.downloading) return;
    final channel = value ? 'experimental' : 'production';
    if (channel == state.channel) return;
    await _updates.setChannel(channel);
    await _settings.saveUpdateChannel(channel);
    if (isClosed) return;
    emit(
      state.copyWith(
        channel: channel,
        phase: UpdatePhase.idle,
        clearAvailable: true,
        clearError: true,
      ),
    );
    if (_updates.isSupported) await check();
  }

  @override
  Future<void> close() async {
    // Closing kills a download in flight rather than leaving the helper
    // running for a cubit that can no longer report it.
    await _download?.cancel();
    _endDownload();
    return super.close();
  }
}
