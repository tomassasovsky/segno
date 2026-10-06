import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/library/application/audio_export.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:session_repository/session_repository.dart';

part 'library_state.dart';

/// Owns the Library page's browsing state: location, search, folder chip,
/// selection and the selected session's preview, the drives the port
/// reports, and the footswitch's return-to-Tracks request.
///
/// It also runs Listen (plan D10): one preview of the selected session
/// through the engine's audition voice, which it polls every 100 ms
/// (`listenPoll`) while it plays, and stops on a new selection, a
/// footswitch press and when the page closes. The page stops it before an
/// Open, a New loop and when a track starts recording; the engine itself
/// ends it on a performance arm and a device reopen, which the poll reads
/// as the preview no longer playing.
///
/// It runs Sessions > USB (pen section 34, plan Part 8): `Back up to USB`
/// copies the selected bundle to the drive as one directory through the
/// port ([AudioExporter]'s package protocol: every file under a write lease
/// into a hidden staging directory, then one rename, `Replace` keeping the
/// old backup until the new one is in place), under a `transfer` guard; the
/// USB location lists the drive's backups; `Restore to Library` adds one as
/// a new, independent session.
///
/// It never opens a session. `SessionCubit` owns the current session, the
/// catalog and its folders, and every other catalog mutation; the one
/// catalog write here is a restore, which adds a session and touches no
/// other, and the page refreshes the catalog when it lands
/// ([LibraryState.restoredId]). Selecting a row can never reach the engine.
class LibraryCubit extends Cubit<LibraryState> {
  /// Creates a [LibraryCubit] over [sessions], [volumes] and [pedal].
  LibraryCubit({
    required SessionRepository sessions,
    required RemovableVolumes volumes,
    required PedalRepository pedal,
    required GuardRegistry guards,
    Duration listenPoll = const Duration(milliseconds: 100),
  }) : _sessions = sessions,
       _volumes = volumes,
       _exporter = AudioExporter(volumes),
       _guards = guards,
       _listenPoll = listenPoll,
       super(LibraryState(volumes: volumes.current)) {
    _pedalSubscription = pedal.events.listen(_onPedalEvent);
    _volumesSubscription = volumes.volumes.listen(_onVolumes);
  }

  final SessionRepository _sessions;
  final RemovableVolumes _volumes;
  final AudioExporter _exporter;
  final GuardRegistry _guards;

  /// The policy the last backup ran under, which `Retry` repeats.
  ConflictPolicy _backupPolicy = ConflictPolicy.ask;
  bool _backupCancelRequested = false;

  /// How often a playing preview's progress is read.
  final Duration _listenPoll;

  Timer? _listenTimer;
  int _listenRequest = 0;

  /// Polls the engine has not yet reported the preview playing: the start
  /// lands at the next audio block, so an early poll can still read nothing.
  int _listenPollsBeforePlaying = 0;
  bool _listenSeenPlaying = false;
  late final StreamSubscription<PedalEvent> _pedalSubscription;
  late final StreamSubscription<List<RemovableVolume>> _volumesSubscription;
  int _previewRequest = 0;

  /// A footswitch press returns to Tracks before it acts (plan D14); encoder
  /// turns and releases do not.
  void _onPedalEvent(PedalEvent event) {
    if (event is! ButtonPressed) return;
    stopListening();
    if (state.dismissalRequested) return;
    emit(state.copyWith(dismissalRequested: true));
  }

  void _onVolumes(List<RemovableVolume> volumes) {
    emit(state.copyWith(volumes: volumes));
    if (state.location == LibraryLocation.usb) loadBackups();
  }

  /// Selects [id] and reads its preview. Selecting is not opening: nothing
  /// reaches the engine.
  Future<void> select(SessionId id) async {
    final request = ++_previewRequest;
    if (state.listen?.id != id) stopListening();
    emit(
      state.copyWith(
        selectedId: id,
        clearPreview: true,
        clearListenRefusal: true,
      ),
    );
    SessionPreview? preview;
    LibraryPreviewError? error;
    try {
      preview = await _sessions.readPreview(id);
    } on SessionUnsupportedVersion {
      error = LibraryPreviewError.unsupportedVersion;
    } on SessionUnconvertible {
      error = LibraryPreviewError.unconvertible;
    } on Object {
      error = LibraryPreviewError.unreadable;
    }
    // A later selection superseded this read; its own result lands instead.
    if (isClosed || request != _previewRequest) return;
    emit(state.copyWith(preview: preview, previewError: error));
    if (preview != null) await _readPeaks(request, id, preview);
  }

  /// Reads each track's lane peaks off the UI isolate; a track whose layer
  /// does not read is left out, and draws its length only.
  Future<void> _readPeaks(
    int request,
    SessionId id,
    SessionPreview preview,
  ) async {
    final peaks = <int, List<double>>{};
    for (final track in preview.tracks) {
      try {
        final read = await _sessions.readPeaks(
          id,
          track,
        );
        if (read != null) peaks[track.channel] = read;
      } on Object {
        // Length only for this track.
      }
      if (isClosed || request != _previewRequest) return;
    }
    emit(state.copyWith(peaks: peaks));
  }

  /// Plays the selected session's saved preview, or stops it when it plays
  /// or is still starting. A refusal is kept in
  /// [LibraryState.listenRefusal].
  ///
  /// Each press is one request: a start the player withdrew, or that a later
  /// selection superseded, while its file decoded is dropped before it
  /// reaches the voice (the `stillWanted` check), so it can never replace the
  /// preview that superseded it.
  Future<void> listen() async {
    final id = state.selectedId;
    if (id == null || state.preview == null) return;
    if (state.listen != null) {
      stopListening();
      return;
    }
    final request = ++_listenRequest;
    bool wanted() => !isClosed && request == _listenRequest;
    emit(
      state.copyWith(
        clearListenRefusal: true,
        listen: LibraryListen(id: id, frames: 0, starting: true),
      ),
    );
    final AuditionStart started;
    try {
      started = await _sessions.startAudition(id, stillWanted: wanted);
    } on Object {
      if (wanted()) {
        emit(
          state.copyWith(
            clearListen: true,
            listenRefusal: LibraryListenRefusal.unplayable,
          ),
        );
      }
      return;
    }
    if (!wanted()) {
      // Stopped, or another selection, after the voice took it: the engine
      // checks only up to the start itself.
      if (started.result == EngineResult.ok) _sessions.stopAudition();
      return;
    }
    if (started.result != EngineResult.ok) {
      emit(
        state.copyWith(
          clearListen: true,
          listenRefusal: _refusalOf(started.result),
        ),
      );
      return;
    }
    _listenSeenPlaying = false;
    _listenPollsBeforePlaying = 0;
    emit(
      state.copyWith(
        listen: LibraryListen(
          id: id,
          frames: started.frames,
          truncated: started.truncated,
          sampleRate: started.rate,
        ),
      ),
    );
    _listenTimer = Timer.periodic(_listenPoll, (_) => _pollListen());
  }

  static LibraryListenRefusal _refusalOf(EngineResult result) =>
      switch (result) {
        EngineResult.notRunning => LibraryListenRefusal.noDevice,
        EngineResult.alreadyRunning => LibraryListenRefusal.performanceArmed,
        EngineResult.notReady => LibraryListenRefusal.busy,
        _ => LibraryListenRefusal.unplayable,
      };

  void _pollListen() {
    final listen = state.listen;
    if (isClosed || listen == null) return;
    final now = _sessions.auditionState();
    if (now.playing) {
      _listenSeenPlaying = true;
      emit(state.copyWith(listen: _withPosition(listen, now.position)));
      return;
    }
    // Not playing: it ended, or the engine ended it (a performance arm, a
    // device reopen). Before it was ever seen playing, give the start a few
    // polls to land.
    if (!_listenSeenPlaying && ++_listenPollsBeforePlaying < 5) return;
    // A start that never reported playing may still sit in the engine's
    // queue: withdraw it, so it cannot sound later with no Stop on screen.
    if (!_listenSeenPlaying) _sessions.stopAudition();
    _endListen();
  }

  static LibraryListen _withPosition(LibraryListen listen, int position) =>
      LibraryListen(
        id: listen.id,
        frames: listen.frames,
        position: position,
        truncated: listen.truncated,
        sampleRate: listen.sampleRate,
      );

  /// Stops the preview, if one plays, and forgets it; a start still
  /// decoding is withdrawn before it reaches the voice.
  void stopListening() {
    _listenRequest++;
    final listen = state.listen;
    if (listen == null) return;
    if (!listen.starting) _sessions.stopAudition();
    _endListen();
  }

  void _endListen() {
    _listenTimer?.cancel();
    _listenTimer = null;
    if (!isClosed) emit(state.copyWith(clearListen: true));
  }

  /// Drops the selection and its preview: the selected session is gone and
  /// no session is open to fall back to. Listen ends with it: its control
  /// lives on the preview.
  void clearSelection() {
    _previewRequest++;
    stopListening();
    emit(
      LibraryState(
        section: state.section,
        location: state.location,
        query: state.query,
        folderFilter: state.folderFilter,
        volumes: state.volumes,
        dismissalRequested: state.dismissalRequested,
      ),
    );
  }

  /// Filters the list by [query], a case-insensitive substring of the name.
  void search(String query) => emit(state.copyWith(query: query));

  /// Puts the folder chip [filter] down.
  void filterFolder(LibraryFolderFilter filter) =>
      emit(state.copyWith(folderFilter: filter));

  /// Shows [section]. Leaving Sessions ends Listen: the Audio tab's
  /// `Preview` uses the same voice.
  void showSection(LibrarySection section) {
    if (section == state.section) return;
    stopListening();
    emit(state.copyWith(section: section));
  }

  /// Browses [location]; the USB location reads the drive's backups.
  void setLocation(LibraryLocation location) {
    emit(state.copyWith(location: location));
    if (location == LibraryLocation.usb) loadBackups();
  }

  /// The drive the Library reads, or null.
  RemovableVolume? get _readableDrive =>
      state.volumes.where((v) => v.readable).firstOrNull;

  /// Reads the backups on the readable drive (none without one). The
  /// selection stays while its backup is still there.
  void loadBackups() {
    final drive = _readableDrive;
    final backups = drive == null
        ? const <SessionSummary>[]
        : _sessions.listBackups(
            '${drive.mountPoint}/${AudioExportFolders.sessions}',
          );
    final keep = backups.any((b) => b.id == state.selectedBackup);
    emit(
      state.copyWith(
        backups: backups,
        clearSelectedBackup: !keep,
        clearRestoreError: true,
      ),
    );
  }

  /// Selects the backup [id] on the USB list.
  void selectBackup(String id) => emit(
    state.copyWith(selectedBackup: id, clearRestoreError: true),
  );

  /// `Restore to Library`: adds the selected backup as a new session, then
  /// shows it selected in Internal (pen 34 `Restored session selected`).
  Future<void> restore() async {
    final drive = _readableDrive;
    final backup = state.selectedBackup;
    if (drive == null || backup == null) return;
    emit(state.copyWith(clearRestoreError: true));
    final SessionId id;
    try {
      id = await _sessions.restoreFrom(
        '${drive.mountPoint}/${AudioExportFolders.sessions}/$backup',
      );
    } on GuardRefused {
      if (!isClosed) {
        emit(state.copyWith(restoreError: LibraryRestoreError.busy));
      }
      return;
    } on Object {
      if (!isClosed) {
        emit(state.copyWith(restoreError: LibraryRestoreError.failed));
      }
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(location: LibraryLocation.internal, restoredId: id));
    await select(id);
  }

  /// `Back up to USB` for the selected session [name]d so: asks before a
  /// backup already on the drive is touched, and reports a missing drive,
  /// an interruption or a refusal with nothing changed.
  Future<void> backUp({required String name, required String purpose}) async {
    final id = state.selectedId;
    if (id == null || state.backup is LibraryBackupRunning) return;
    _backupPurpose = purpose;
    await _runBackup(id, name, ConflictPolicy.ask);
  }

  String _backupPurpose = '';

  /// Answers `A backup has this name` with `Keep both` or `Replace`.
  Future<void> resolveBackupConflict(ConflictPolicy policy) async {
    final backup = state.backup;
    if (backup is! LibraryBackupConflict) return;
    await _runBackup(backup.id, backup.name, policy);
  }

  /// `Retry` on an interruption: the same backup under the same choice.
  Future<void> retryBackup() async {
    final backup = state.backup;
    if (backup is! LibraryBackupInterrupted) return;
    await _runBackup(backup.id, backup.name, _backupPolicy);
  }

  /// `Cancel`: stops a running backup after the file in flight (removing
  /// what it placed), or closes the question in front of the player.
  void cancelBackup() {
    if (state.backup is LibraryBackupRunning) {
      _backupCancelRequested = true;
      return;
    }
    emit(state.copyWith(clearBackup: true));
  }

  Future<void> _runBackup(
    SessionId id,
    String name,
    ConflictPolicy policy,
  ) async {
    _backupPolicy = policy;
    LibraryBackup interrupted(
      LibraryBackupProblem problem, [
      GuardKind? blockedBy,
    ]) => LibraryBackupInterrupted(
      id: id,
      name: name,
      problem: problem,
      blockedBy: blockedBy,
    );
    final drive = _volumes.current
        .where(
          (v) =>
              v.status == RemovableVolumeStatus.mounted && v.mountPoint != null,
        )
        .firstOrNull;
    if (drive == null) {
      final readOnly = _volumes.current.any(
        (v) => v.status == RemovableVolumeStatus.readOnly,
      );
      emit(
        state.copyWith(
          backup: interrupted(
            readOnly
                ? LibraryBackupProblem.readOnly
                : LibraryBackupProblem.noDrive,
          ),
        ),
      );
      return;
    }
    _backupCancelRequested = false;
    emit(
      state.copyWith(
        backup: LibraryBackupRunning(id: id, name: name),
      ),
    );
    OperationGuard? guard;
    OperationGuard? reading;
    try {
      final bundle = await _sessions.bundlePathOf(id);
      // On the drive: an eject or a take recorded to it waits for the copy.
      guard = _guards.enter(
        GuardKind.transfer,
        GuardScope.removable(
          drive.generation,
          item: '${AudioExportFolders.sessions}/$id',
        ),
        purpose: _backupPurpose,
      );
      // On the bundle it reads: a save, rename or delete of the session
      // waits too, so the backup never copies half of a write.
      reading = _guards.enter(
        GuardKind.transfer,
        GuardScope.internal(item: bundle),
        purpose: _backupPurpose,
      );
      final files = await _sessions.bundleFiles(id);
      await _exporter.run(
        AudioExportPlan(
          name: id,
          folder: AudioExportFolders.sessions,
          package: true,
          files: [for (final f in files) AudioExportFile('$bundle/$f', f)],
        ),
        generation: drive.generation,
        policy: policy,
        purpose: _backupPurpose,
        cancelled: () => _backupCancelRequested,
        onProgress: (fraction) {
          if (isClosed) return;
          emit(
            state.copyWith(
              backup: LibraryBackupRunning(
                id: id,
                name: name,
                fraction: fraction,
              ),
            ),
          );
        },
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          backup: LibraryBackupDone(id: id, name: name),
        ),
      );
      if (state.location == LibraryLocation.usb) loadBackups();
    } on NameConflict {
      if (!isClosed) {
        emit(
          state.copyWith(
            backup: LibraryBackupConflict(id: id, name: name),
          ),
        );
      }
    } on AudioExportCancelled {
      if (!isClosed) emit(state.copyWith(clearBackup: true));
    } on GuardRefused catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            backup: interrupted(
              LibraryBackupProblem.busy,
              e.blockers.first.kind,
            ),
          ),
        );
      }
    } on Object catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            backup: interrupted(switch (e) {
              StorageVolumeLost() ||
              StorageUnsupported() => LibraryBackupProblem.driveLost,
              StorageFull() => LibraryBackupProblem.full,
              StorageReadOnly() => LibraryBackupProblem.readOnly,
              _ => LibraryBackupProblem.failed,
            }),
          ),
        );
      }
    } finally {
      guard?.release();
      reading?.release();
    }
  }

  @override
  Future<void> close() async {
    // Leaving the Library ends Listen.
    stopListening();
    _listenTimer?.cancel();
    await _pedalSubscription.cancel();
    await _volumesSubscription.cancel();
    return super.close();
  }
}
