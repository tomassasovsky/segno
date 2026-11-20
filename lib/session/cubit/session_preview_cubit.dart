import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:session_repository/session_repository.dart';

part 'session_preview_state.dart';

/// Reads one saved session's preview for a surface that shows it without
/// opening it (#1921): the setup, the effects by place and the recordings,
/// then each recording's waveform.
///
/// The Sessions face asks it for the session a tap previews. Nothing here
/// reaches the engine, and nothing is opened.
class SessionPreviewCubit extends Cubit<SessionPreviewState> {
  /// Creates a [SessionPreviewCubit] over [_sessions].
  new(this._sessions) : super(const SessionPreviewState());

  final SessionRepository _sessions;

  /// Counts the requests, so a read that a later one superseded is dropped.
  int _request = 0;

  /// Shows [id]'s preview, or none for null. The setup and the list of
  /// recordings land first and the waveforms after, since they are read
  /// from the audio.
  Future<void> show(SessionId? id) async {
    // The panel asks for none as it leaves the tree, which can be after the
    // face that owns this cubit has closed it.
    if (isClosed || id == state.id) return;
    final request = ++_request;
    if (id == null) {
      emit(const SessionPreviewState());
      return;
    }
    emit(SessionPreviewState(id: id, status: SessionPreviewStatus.loading));
    final SessionPreview preview;
    try {
      preview = await _sessions.readPreview(id);
    } on Object {
      // Why it does not read is the Library's to say; here the session
      // stays on its switch and an Open gives the reason.
      if (isClosed || request != _request) return;
      emit(
        SessionPreviewState(id: id, status: SessionPreviewStatus.unreadable),
      );
      return;
    }
    if (isClosed || request != _request) return;
    emit(
      SessionPreviewState(
        id: id,
        status: SessionPreviewStatus.ready,
        preview: preview,
        effects: SessionPreviewEffects(
          inputs: _effectsOf(preview.inputChains),
          tracks: _effectsOf(preview.trackChains),
          allTracks: _effectsOf([preview.allTracksChain]),
          outputs: _effectsOf(preview.outputChains),
        ),
      ),
    );
    final peaks = <int, List<double>>{};
    for (final track in preview.tracks) {
      try {
        final read = await _sessions.readPeaks(id, track);
        if (read != null) peaks[track.channel] = read;
      } on Object {
        // This track draws its length only.
      }
      if (isClosed || request != _request) return;
    }
    if (peaks.isNotEmpty) emit(state.copyWith(peaks: peaks));
  }

  /// The entries of [chains], in order. A chain that is switched off keeps
  /// its entries: it is still part of the setup. One that does not decode
  /// names nothing.
  static List<TrackEffect> _effectsOf(List<String> chains) => [
    for (final encoded in chains) ..._entriesOf(encoded),
  ];

  static List<TrackEffect> _entriesOf(String encoded) {
    try {
      return decodeFxChain(encoded).entries;
    } on Object {
      return const [];
    }
  }
}
