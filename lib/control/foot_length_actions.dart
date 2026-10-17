import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/model/foot_length.dart';

/// Stateless Multiply / Divide semantics over the engine's length edits
/// (#1168). Control owns contacts; this component caches nothing.
class FootLengthActions {
  /// Connects the shared repository without introducing a new lifetime.
  const FootLengthActions({required this.repository});

  /// Owner of the tracks and their length edits.
  final LooperRepository repository;

  /// Reads the same projection used by the screen, without retaining it.
  FootLengthProjection project({
    required int bank,
    required int cursor,
    LooperState? looper,
  }) => projectFootLength(
    looper ?? repository.state,
    bank: bank,
    cursor: cursor,
  );

  /// Doubles or halves [channel]. Completes with null when the edit landed,
  /// or why it did not: an empty or busy track is refused without reaching
  /// the engine; the engine's verdict names the rest. Shared by the Multiply
  /// / Divide surface and every assigned Multiply or Divide.
  Future<FootLengthRefusal?> edit(int channel, LengthEdit edit) async {
    if (channel < 0 || channel >= 8) return FootLengthRefusal.empty;
    final refusal = readFootLengthTrack(repository.state, channel).refusal;
    if (refusal != null) return refusal;
    final result = await repository.editLength(channel: channel, edit: edit);
    return footLengthRefusalOf(result);
  }
}

/// The refusal an engine verdict names, or null for an accepted edit.
FootLengthRefusal? footLengthRefusalOf(EngineResult result) => switch (result) {
  EngineResult.ok => null,
  EngineResult.notReady => FootLengthRefusal.busy,
  EngineResult.modeMismatch => FootLengthRefusal.incompatible,
  EngineResult.capacity => FootLengthRefusal.capacity,
  _ => FootLengthRefusal.failed,
};
