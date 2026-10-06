import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:session_repository/session_repository.dart';

part 'library_state.dart';

/// Owns the Library page's browsing state: location, search, folder chip,
/// selection and the selected session's preview, the drives the port
/// reports, and the footswitch's return-to-Tracks request.
///
/// It never opens a session and never changes the catalog: `SessionCubit`
/// owns the current session and every catalog mutation. This cubit only
/// reads facts about saved bundles (folders, previews), so selecting a row
/// can never reach the engine.
class LibraryCubit extends Cubit<LibraryState> {
  /// Creates a [LibraryCubit] over [sessions], [volumes] and [pedal].
  LibraryCubit({
    required SessionRepository sessions,
    required RemovableVolumes volumes,
    required PedalRepository pedal,
  }) : _sessions = sessions,
       super(LibraryState(volumes: volumes.current)) {
    _pedalSubscription = pedal.events.listen(_onPedalEvent);
    _volumesSubscription = volumes.volumes.listen(_onVolumes);
  }

  final SessionRepository _sessions;
  late final StreamSubscription<PedalEvent> _pedalSubscription;
  late final StreamSubscription<List<RemovableVolume>> _volumesSubscription;
  int _previewRequest = 0;

  /// A footswitch press returns to Tracks before it acts (plan D14); encoder
  /// turns and releases do not.
  void _onPedalEvent(PedalEvent event) {
    if (state.dismissalRequested || event is! ButtonPressed) return;
    emit(state.copyWith(dismissalRequested: true));
  }

  void _onVolumes(List<RemovableVolume> volumes) {
    emit(state.copyWith(volumes: volumes));
  }

  /// Reads the folder chips and selects [selected] (the current session),
  /// when there is one.
  Future<void> start({SessionId? selected}) async {
    await _readFolders();
    if (selected != null) await select(selected);
  }

  Future<void> _readFolders() async {
    final List<String> folders;
    try {
      folders = await _sessions.listFolders();
    } on Object {
      // Unreadable folders leave the chips at All and Unfiled; the rows
      // still list, so the Library stays usable.
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(folders: folders));
  }

  /// Selects [id] and reads its preview. Selecting is not opening: nothing
  /// reaches the engine.
  Future<void> select(SessionId id) async {
    final request = ++_previewRequest;
    emit(state.copyWith(selectedId: id, clearPreview: true));
    SessionPreview? preview;
    LibraryPreviewError? error;
    try {
      preview = await _sessions.readPreview(id);
    } on SessionUnsupportedVersion {
      error = LibraryPreviewError.unsupportedVersion;
    } on Object {
      error = LibraryPreviewError.unreadable;
    }
    // A later selection superseded this read; its own result lands instead.
    if (isClosed || request != _previewRequest) return;
    emit(state.copyWith(preview: preview, previewError: error));
  }

  /// Filters the list by [query], a case-insensitive substring of the name.
  void search(String query) => emit(state.copyWith(query: query));

  /// Puts the folder chip [filter] down.
  void filterFolder(LibraryFolderFilter filter) =>
      emit(state.copyWith(folderFilter: filter));

  /// Browses [location].
  void setLocation(LibraryLocation location) =>
      emit(state.copyWith(location: location));

  @override
  Future<void> close() async {
    await _pedalSubscription.cancel();
    await _volumesSubscription.cancel();
    return super.close();
  }
}
