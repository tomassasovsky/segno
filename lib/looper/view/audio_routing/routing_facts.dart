import 'package:looper_repository/looper_repository.dart';

/// Whether any track that records [input] is armed or capturing.
///
/// The accepted lock behind "finish recording to change this", derived from
/// the projection because the repository keeps its own predicate private. One
/// definition, because two surfaces disagreeing about whether a jack is busy
/// would grey out one control and not the other.
bool inputBusy(LooperState state, int input) {
  for (final track in state.tracks) {
    if (!track.pending && !track.isCapturing) continue;
    for (final lane in track.lanes) {
      if (lane.inputChannel == input) return true;
    }
  }
  return false;
}
