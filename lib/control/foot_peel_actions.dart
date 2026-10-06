import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/model/foot_peel.dart';

/// Stateless Peel semantics over the engine's audio history.
/// Control owns contacts; this component caches nothing.
class FootPeelActions {
  /// Connects the shared repository without introducing a new lifetime.
  const FootPeelActions({required this.repository});

  /// Owner of the tracks and their history.
  final LooperRepository repository;

  /// Reads the same projection used by the screen, without retaining it.
  FootPeelProjection project({required int bank, LooperState? looper}) =>
      projectFootPeel(looper ?? repository.state, bank: bank);

  /// Removes the newest overdub layer of [channel]. Returns null when a
  /// layer was removed, or why not: a track that is empty, holds only its
  /// original, or is busy is refused without reaching the engine. Shared by
  /// the Peel surface and assigned Peel actions.
  FootPeelRefusal? peel(int channel) {
    if (channel < 0 || channel >= 8) return FootPeelRefusal.empty;
    final refusal = readFootPeelTrack(repository.state, channel).refusal;
    if (refusal != null) return refusal;
    return switch (repository.peel(channel: channel)) {
      EngineResult.ok => null,
      // The projection lags the engine by one drain: a refusal here names
      // the same causes the projection would have.
      EngineResult.invalid => FootPeelRefusal.originalOnly,
      EngineResult.notReady => FootPeelRefusal.busy,
      _ => FootPeelRefusal.failed,
    };
  }
}
