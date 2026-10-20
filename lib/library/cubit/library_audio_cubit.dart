import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/library/application/audio_export.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/performance/application/daw_project_export.dart';
import 'package:session_repository/session_repository.dart';

part 'library_audio_state.dart';

/// Writes a recording's DAW project into its bundle ([writeDawProject]).
typedef DawProjectWriter = Future<Object?> Function(String dir);

/// Owns Library > Audio (#1178 Part 7): the `Performances` folder (finished
/// recordings, the recovered ones kept and marked) and the `Sessions` folder
/// (each saved session's mixdown), the selection's waveform and `Preview`,
/// `Export to USB` through the [RemovableVolumes] port, `DAW project` and a
/// recording's Delete.
///
/// Every export is all or nothing on the drive and only reads internal
/// storage ([AudioExporter]). It asks before a name already on the drive is
/// touched: the conflict is held until the player picks `Keep both` or
/// `Replace` ([resolveConflict]) or cancels.
///
/// A recording's export holds a `transfer` guard on the take for the whole
/// copy, so its Delete (a `sessionWrite` on the same item) is refused until
/// the copy ends, even from a Library opened later; the card shows the
/// export's purpose on Delete while it runs (`deleteBlockedBy`).
/// The DAW project and the DAW package wait for the take's render: its stems
/// are written in place while it runs.
///
/// `Preview` uses the engine's one audition voice, as the Sessions tab's
/// Listen does; the page stops the one when it shows the other, and this
/// cubit stops its own on a new selection, a folder change and its close.
class LibraryAudioCubit extends Cubit<LibraryAudioState> {
  /// Creates a [LibraryAudioCubit].
  LibraryAudioCubit({
    required PerformanceRepository performance,
    required SessionRepository sessions,
    required RemovableVolumes volumes,
    required GuardRegistry guards,
    DawProjectWriter dawProject = writeDawProject,
    Duration previewPoll = const Duration(milliseconds: 100),
  }) : _performance = performance,
       _sessions = sessions,
       _volumes = volumes,
       _guards = guards,
       _exporter = AudioExporter(volumes),
       _dawProject = dawProject,
       _previewPoll = previewPoll,
       super(const LibraryAudioState());

  final PerformanceRepository _performance;
  final SessionRepository _sessions;
  final RemovableVolumes _volumes;
  final GuardRegistry _guards;
  final AudioExporter _exporter;
  final DawProjectWriter _dawProject;
  final Duration _previewPoll;

  int _selectRequest = 0;
  int _previewRequest = 0;
  Timer? _previewTimer;
  bool _previewSeenPlaying = false;
  int _previewPollsBeforePlaying = 0;

  /// The export waiting on a conflict answer or a drive.
  ({LibraryAudioItem item, LibraryAudioExportKind kind, String purpose})?
  _pending;
  bool _cancelRequested = false;

  /// Reads both folders. The selection stays when its item is still there.
  Future<void> load() async {
    final List<CaptureSummary> captures;
    final List<SessionSummary> sessions;
    try {
      captures = await _performance.listCaptures();
      sessions = await _sessions.listSessions();
    } on Object {
      if (!isClosed) emit(state.copyWith(loaded: true));
      return;
    }
    final mixdowns = <LibraryMixdown>[];
    for (final session in sessions) {
      if (session.unreadable) continue;
      final mixdown = await _sessions.mixdownOf(session.id);
      if (mixdown != null) mixdowns.add(LibraryMixdown(session, mixdown));
    }
    if (isClosed) return;
    final recordings = [for (final c in captures) LibraryRecording(c)];
    final keys = {
      for (final i in recordings) i.key,
      for (final i in mixdowns) i.key,
    };
    final keep = keys.contains(state.selectedKey);
    if (!keep) stopPreview();
    emit(
      state.copyWith(
        loaded: true,
        recordings: recordings,
        mixdowns: mixdowns,
        clearSelection: !keep,
      ),
    );
  }

  /// Opens [folder].
  void openFolder(LibraryAudioFolder folder) {
    stopPreview();
    emit(
      state.copyWith(
        folder: folder,
        query: '',
        clearSelection: true,
        clearError: true,
        dawProjectWritten: false,
      ),
    );
  }

  /// Back to the top, where the two folders are.
  void closeFolder() {
    stopPreview();
    emit(
      state.copyWith(
        atTop: true,
        query: '',
        clearSelection: true,
        clearError: true,
        dawProjectWritten: false,
      ),
    );
  }

  /// Filters the open folder by [query], a case-insensitive substring.
  void search(String query) => emit(state.copyWith(query: query));

  /// Selects [item] and reads its waveform.
  Future<void> select(LibraryAudioItem item) async {
    final request = ++_selectRequest;
    if (state.preview?.key != item.key) stopPreview();
    emit(
      state.copyWith(
        selectedKey: item.key,
        clearPeaks: true,
        clearRefusal: true,
        clearError: true,
        dawProjectWritten: false,
        deleteBlockedBy: _deleteBlocker(item),
        clearDeleteBlockedBy: _deleteBlocker(item) == null,
      ),
    );
    List<double>? peaks;
    try {
      peaks = switch (item) {
        LibraryRecording(:final capture) => await _performance.readPeaks(
          capture,
        ),
        LibraryMixdown(:final session) => await _sessions.readMixdownPeaks(
          session.id,
        ),
      };
    } on Object {
      peaks = null;
    }
    if (isClosed || request != _selectRequest || peaks == null) return;
    emit(state.copyWith(peaks: peaks));
  }

  /// The purpose of the operation that would refuse [item]'s Delete now (an
  /// export of it, from this Library or one opened before), or null.
  String? _deleteBlocker(LibraryAudioItem item) {
    if (item is! LibraryRecording) return null;
    final blockers = _guards.blockers(
      GuardKind.sessionWrite,
      GuardScope.internal(item: item.capture.path),
    );
    return blockers.isEmpty ? null : blockers.first.purpose;
  }

  /// Plays the selected item through the audition voice, or stops it when
  /// it plays or is still starting. A refusal is kept in
  /// [LibraryAudioState.previewRefusal]. A start withdrawn or superseded
  /// while its file decoded never reaches the voice (`stillWanted`).
  Future<void> preview() async {
    final item = state.selected;
    if (item == null) return;
    if (state.preview != null) {
      stopPreview();
      return;
    }
    final request = ++_previewRequest;
    bool wanted() => !isClosed && request == _previewRequest;
    emit(
      state.copyWith(
        clearRefusal: true,
        preview: LibraryAudioPreview(
          key: item.key,
          frames: 0,
          sampleRate: 0,
          starting: true,
        ),
      ),
    );
    AuditionStart started;
    try {
      started = switch (item) {
        LibraryRecording(:final capture) => await _performance.startAudition(
          capture,
          stillWanted: wanted,
        ),
        LibraryMixdown(:final session) => await _sessions.startAudition(
          session.id,
          stillWanted: wanted,
        ),
      };
    } on Object {
      started = const AuditionStart(result: EngineResult.invalid);
    }
    if (!wanted()) {
      if (started.result == EngineResult.ok) _sessions.stopAudition();
      return;
    }
    if (started.result != EngineResult.ok) {
      emit(
        state.copyWith(
          clearPreview: true,
          previewRefusal: _refusalOf(started.result),
        ),
      );
      return;
    }
    _previewSeenPlaying = false;
    _previewPollsBeforePlaying = 0;
    emit(
      state.copyWith(
        preview: LibraryAudioPreview(
          key: item.key,
          frames: started.frames,
          sampleRate: started.rate,
          truncated: started.truncated,
        ),
      ),
    );
    _previewTimer = Timer.periodic(_previewPoll, (_) => _pollPreview());
  }

  static LibraryListenRefusal _refusalOf(EngineResult result) =>
      switch (result) {
        EngineResult.notRunning => LibraryListenRefusal.noDevice,
        EngineResult.alreadyRunning => LibraryListenRefusal.performanceArmed,
        EngineResult.notReady => LibraryListenRefusal.busy,
        _ => LibraryListenRefusal.unplayable,
      };

  void _pollPreview() {
    final preview = state.preview;
    if (isClosed || preview == null) return;
    final now = _sessions.auditionState();
    if (now.playing) {
      _previewSeenPlaying = true;
      emit(state.copyWith(preview: preview.at(now.position)));
      return;
    }
    // Ended, or the engine ended it; a start gets a few polls to land.
    if (!_previewSeenPlaying && ++_previewPollsBeforePlaying < 5) return;
    // Never seen playing: withdraw it, so it cannot sound later unseen.
    if (!_previewSeenPlaying) _sessions.stopAudition();
    _endPreview();
  }

  /// Stops `Preview`, if it plays; a start still decoding stops itself when
  /// it lands.
  void stopPreview() {
    _previewRequest++;
    final preview = state.preview;
    if (preview == null) return;
    if (!preview.starting) _sessions.stopAudition();
    _endPreview();
  }

  void _endPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (!isClosed) emit(state.copyWith(clearPreview: true));
  }

  /// Exports the selected item to the drive as [kind]: asks first when the
  /// name is taken (pen 20/09), asks for a drive when there is none (20/10),
  /// reports a full or read-only drive on the card's line (20/11), and
  /// shows the result (20/12). [purpose] is what the Storage page shows on
  /// the disabled Eject while it runs.
  Future<void> export(
    LibraryAudioExportKind kind, {
    required String purpose,
  }) async {
    final item = state.selected;
    if (item == null || state.export is LibraryExportRunning) return;
    _pending = (item: item, kind: kind, purpose: purpose);
    await _run(ConflictPolicy.ask);
  }

  /// Answers 20/09 with [policy] (`Keep both` or `Replace`).
  Future<void> resolveConflict(ConflictPolicy policy) async {
    if (state.export is! LibraryExportConflict || _pending == null) return;
    await _run(policy);
  }

  /// `Try again` on 20/10.
  Future<void> retryExport() async {
    if (state.export is! LibraryExportNeedsDrive || _pending == null) return;
    // The dialog closed on the answer: still no drive asks again.
    emit(state.copyWith(clearExport: true));
    await _run(ConflictPolicy.ask);
  }

  /// `Cancel`: stops a running export after the file in flight (removing
  /// what it placed), or closes 20/09 or 20/10.
  void cancelExport() {
    if (state.export is LibraryExportRunning) {
      _cancelRequested = true;
      return;
    }
    _pending = null;
    emit(state.copyWith(clearExport: true));
  }

  /// `Done` on 20/12.
  void dismissExport() {
    _pending = null;
    emit(state.copyWith(clearExport: true));
  }

  Future<void> _run(ConflictPolicy policy) async {
    final pending = _pending;
    if (pending == null) return;
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
        readOnly
            ? state.copyWith(
                error: LibraryAudioError.readOnly,
                clearExport: true,
              )
            : state.copyWith(
                export: const LibraryExportNeedsDrive(),
                clearError: true,
              ),
      );
      if (readOnly) _pending = null;
      return;
    }
    stopPreview();
    final folder = _folderOf(pending.item);
    if (_needsRender(pending.kind) && _performance.rendering) {
      _pending = null;
      emit(
        state.copyWith(
          error: LibraryAudioError.stillRendering,
          clearExport: true,
        ),
      );
      return;
    }
    _cancelRequested = false;
    emit(
      state.copyWith(
        export: LibraryExportRunning(name: pending.item.name, folder: folder),
        clearError: true,
        dawProjectWritten: false,
      ),
    );
    final scratch = pending.item is LibraryMixdown
        ? Directory.systemTemp.createTempSync('segno_export')
        : null;
    OperationGuard? reading;
    try {
      // Held for the whole copy: the take's Delete waits for it.
      if (pending.item case LibraryRecording(:final capture)) {
        reading = _guards.enter(
          GuardKind.transfer,
          GuardScope.internal(item: capture.path),
          purpose: pending.purpose,
        );
      }
      final plan = await _planFor(pending.item, pending.kind, scratch);
      final at = await _exporter.run(
        plan,
        generation: drive.generation,
        policy: policy,
        purpose: pending.purpose,
        cancelled: () => _cancelRequested,
        onProgress: (fraction) {
          if (isClosed) return;
          emit(
            state.copyWith(
              export: LibraryExportRunning(
                name: pending.item.name,
                folder: folder,
                fraction: fraction,
              ),
            ),
          );
        },
      );
      _pending = null;
      if (isClosed) return;
      emit(
        state.copyWith(
          export: LibraryExportDone(name: _lastSegment(at), folder: folder),
        ),
      );
    } on NameConflict {
      if (!isClosed) {
        emit(state.copyWith(export: LibraryExportConflict(pending.item.name)));
      }
    } on StorageVolumeLost {
      if (!isClosed) {
        emit(state.copyWith(export: const LibraryExportNeedsDrive()));
      }
    } on StorageUnsupported {
      if (!isClosed) {
        emit(state.copyWith(export: const LibraryExportNeedsDrive()));
      }
    } on AudioExportCancelled {
      _pending = null;
      if (!isClosed) emit(state.copyWith(clearExport: true));
    } on Object catch (e) {
      _pending = null;
      if (!isClosed) {
        emit(
          state.copyWith(
            clearExport: true,
            error: switch (e) {
              StorageFull() => LibraryAudioError.notEnoughSpace,
              StorageReadOnly() => LibraryAudioError.readOnly,
              GuardRefused() => LibraryAudioError.exportBusy,
              _ => LibraryAudioError.exportFailed,
            },
          ),
        );
      }
    } finally {
      reading?.release();
      if (scratch != null && scratch.existsSync()) {
        scratch.deleteSync(recursive: true);
      }
      final selected = isClosed ? null : state.selected;
      if (selected != null) {
        final blocker = _deleteBlocker(selected);
        emit(
          state.copyWith(
            deleteBlockedBy: blocker,
            clearDeleteBlockedBy: blocker == null,
          ),
        );
      }
    }
  }

  /// Whether [kind] reads the take's rendered stems or writes its project.
  static bool _needsRender(LibraryAudioExportKind kind) =>
      kind == LibraryAudioExportKind.dawPackage;

  static LibraryAudioFolder _folderOf(LibraryAudioItem item) => switch (item) {
    LibraryRecording() => LibraryAudioFolder.performances,
    LibraryMixdown() => LibraryAudioFolder.sessions,
  };

  /// The files [kind] of [item] writes. A session export stages them in
  /// [scratch], which the caller creates and always deletes.
  Future<AudioExportPlan> _planFor(
    LibraryAudioItem item,
    LibraryAudioExportKind kind,
    Directory? scratch,
  ) async {
    switch (item) {
      case LibraryRecording(:final capture):
        final name = driveSafeName(capture.name);
        if (kind == LibraryAudioExportKind.dawPackage) {
          final als = File('${capture.path}/project.als');
          if (!als.existsSync()) await _dawProject(capture.path);
          return AudioExportPlan(
            name: name,
            folder: AudioExportFolders.performances,
            package: true,
            files: [
              for (final f in _performance.dawPackageFiles(capture))
                AudioExportFile('${capture.path}/$f', f),
            ],
          );
        }
        final parts = capture.masterParts;
        return AudioExportPlan(
          name: name,
          folder: AudioExportFolders.performances,
          files: [
            for (final p in parts)
              AudioExportFile(
                '${capture.path}/${p.file}',
                parts.length == 1
                    ? '{name}.wav'
                    : '{name} · Part ${p.index.toString().padLeft(3, '0')}'
                          '.wav',
              ),
          ],
          // Replace takes away every file of an earlier export of this
          // name, so no part of another take stays beside the new ones.
          earlier: RegExp(
            '^${RegExp.escape(name)}( · Part \\d{3})?\\.wav\$',
          ),
        );
      case LibraryMixdown(:final session):
        final name = driveSafeName(session.name);
        final dir = scratch!;
        if (kind == LibraryAudioExportKind.stems) {
          await _sessions.exportStems(session.id, dir.path);
          final stems = [
            for (final e in dir.listSync())
              if (e is File) _lastSegment(e.path),
          ]..sort();
          return AudioExportPlan(
            name: '$name stems',
            folder: AudioExportFolders.sessions,
            package: true,
            files: [
              for (final f in stems) AudioExportFile('${dir.path}/$f', f),
            ],
          );
        }
        final mixdown = '${dir.path}/mixdown.wav';
        await _sessions.exportMixdown(session.id, mixdown);
        return AudioExportPlan(
          name: name,
          folder: AudioExportFolders.sessions,
          files: [AudioExportFile(mixdown, '{name}.wav')],
        );
    }
  }

  static String _lastSegment(String path) =>
      path.split('/').where((s) => s.isNotEmpty).last;

  /// `DAW project`: writes `project.als` and `fx-chains.txt` into the
  /// selected recording's bundle.
  Future<void> writeProject() async {
    final item = state.selected;
    if (item is! LibraryRecording) return;
    if (_performance.rendering) {
      emit(
        state.copyWith(
          error: LibraryAudioError.stillRendering,
          dawProjectWritten: false,
        ),
      );
      return;
    }
    emit(state.copyWith(clearError: true, dawProjectWritten: false));
    try {
      await _dawProject(item.capture.path);
    } on Object {
      if (!isClosed) {
        emit(state.copyWith(error: LibraryAudioError.dawProjectFailed));
      }
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(dawProjectWritten: true));
    await load();
  }

  /// Deletes the selected recording from internal storage, after the page
  /// confirmed it.
  Future<void> deleteRecording() async {
    final item = state.selected;
    if (item is! LibraryRecording) return;
    stopPreview();
    emit(state.copyWith(clearError: true, dawProjectWritten: false));
    try {
      await _performance.deleteCapture(item.capture);
    } on Object catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            error: e is PerformanceCaptureBusy || e is GuardRefused
                ? LibraryAudioError.deleteBusy
                : LibraryAudioError.deleteFailed,
          ),
        );
      }
      return;
    }
    await load();
  }

  @override
  Future<void> close() {
    stopPreview();
    _previewTimer?.cancel();
    return super.close();
  }
}
