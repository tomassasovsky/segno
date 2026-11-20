import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:session_repository/session_repository.dart';

part 'session_preview_state.dart';

/// Reads one saved session's setup for a surface that shows it without
/// opening it (#1921): what its manifest says, and its effects by name.
///
/// The Sessions face asks it for the session under the player's foot.
/// Nothing here reaches the engine, and nothing is opened.
class SessionPreviewCubit extends Cubit<SessionPreviewState> {
  /// Creates a [SessionPreviewCubit] over [_sessions].
  new(this._sessions) : super(const SessionPreviewState());

  final SessionRepository _sessions;

  /// Counts the requests, so a read that a later one superseded is dropped.
  int _request = 0;

  /// Shows [id]'s preview, or none for null.
  Future<void> show(SessionId? id) async {
    // The face asks for none as it leaves the tree, which can be after it
    // has closed this cubit.
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
        // In signal order: the inputs, the tracks, All tracks, the outputs.
        effects: [
          for (final encoded in [
            ...preview.inputChains,
            ...preview.trackChains,
            preview.allTracksChain,
            ...preview.outputChains,
          ])
            ..._entriesOf(encoded),
        ],
      ),
    );
  }

  /// The entries of one stored chain. A chain that is switched off keeps
  /// its entries: it is still part of the setup. One that does not decode
  /// names nothing.
  static List<TrackEffect> _entriesOf(String encoded) {
    try {
      return decodeFxChain(encoded).entries;
    } on Object {
      return const [];
    }
  }
}
