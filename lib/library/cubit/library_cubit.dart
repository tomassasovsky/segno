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
/// It also runs Listen (plan D10): one preview of the selected session
/// through the engine's audition voice, which it polls every 100 ms
/// (`listenPoll`) while it plays, and stops on a new selection, a
/// footswitch press and when the page closes. The page stops it before an
/// Open, a New loop and when a track starts recording; the engine itself
/// ends it on a performance arm and a device reopen, which the poll reads
/// as the preview no longer playing.
///
/// It never opens a session and never changes the catalog: `SessionCubit`
/// owns the current session, the catalog and its folders, and every catalog
/// mutation. This cubit only reads previews of saved bundles, so selecting a
/// row can never reach the engine.
class LibraryCubit extends Cubit<LibraryState> {
  /// Creates a [LibraryCubit] over [sessions], [volumes] and [pedal].
  LibraryCubit({
    required SessionRepository sessions,
    required RemovableVolumes volumes,
    required PedalRepository pedal,
    Duration listenPoll = const Duration(milliseconds: 100),
  }) : _sessions = sessions,
       _listenPoll = listenPoll,
       super(LibraryState(volumes: volumes.current)) {
    _pedalSubscription = pedal.events.listen(_onPedalEvent);
    _volumesSubscription = volumes.volumes.listen(_onVolumes);
  }

  final SessionRepository _sessions;

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

  /// Plays the selected session's saved preview, or stops it when it plays.
  /// A refusal is kept in [LibraryState.listenRefusal].
  Future<void> listen() async {
    final id = state.selectedId;
    if (id == null || state.preview == null) return;
    if (state.listen != null) {
      stopListening();
      return;
    }
    final request = ++_listenRequest;
    emit(state.copyWith(clearListenRefusal: true));
    final AuditionStart started;
    try {
      started = await _sessions.startAudition(id);
    } on Object {
      if (!isClosed && request == _listenRequest) {
        emit(state.copyWith(listenRefusal: LibraryListenRefusal.unplayable));
      }
      return;
    }
    if (isClosed || request != _listenRequest) {
      // Stopped, or another selection, while it decoded.
      if (started.result == EngineResult.ok) _sessions.stopAudition();
      return;
    }
    if (started.result != EngineResult.ok) {
      emit(state.copyWith(listenRefusal: _refusalOf(started.result)));
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
          sampleRate: state.preview?.sampleRate ?? 0,
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
  /// decoding stops itself when it lands.
  void stopListening() {
    _listenRequest++;
    if (state.listen == null) return;
    _sessions.stopAudition();
    _endListen();
  }

  void _endListen() {
    _listenTimer?.cancel();
    _listenTimer = null;
    if (!isClosed) emit(state.copyWith(clearListen: true));
  }

  /// Drops the selection and its preview: the selected session is gone and
  /// no session is open to fall back to.
  void clearSelection() {
    _previewRequest++;
    emit(
      LibraryState(
        location: state.location,
        query: state.query,
        folderFilter: state.folderFilter,
        volumes: state.volumes,
        dismissalRequested: state.dismissalRequested,
        listen: state.listen,
      ),
    );
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
    // Leaving the Library ends Listen.
    stopListening();
    _listenTimer?.cancel();
    await _pedalSubscription.cancel();
    await _volumesSubscription.cancel();
    return super.close();
  }
}
