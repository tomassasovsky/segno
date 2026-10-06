import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/model/foot_reverse.dart';

/// Stateless Reverse semantics over the callback-owned direction.
/// Control owns contacts; this component caches nothing.
class FootReverseActions {
  /// Connects the shared repository without introducing a new lifetime.
  const FootReverseActions({required this.repository});

  /// Callback-owned direction and its receipts.
  final LooperRepository repository;

  /// Reads the same projection used by the screen, without retaining it.
  FootReverseProjection project({required int bank, LooperState? looper}) =>
      projectFootReverse(looper ?? repository.state, bank: bank);

  /// Turns one recorded track around at its current position. Refuses a
  /// track that is empty, capturing or pending as [EngineResult.invalid]
  /// without posting. Shared by the Reverse surface and assigned Reverse
  /// actions.
  Future<EngineResult> toggle(int channel) {
    if (channel < 0 || channel >= 8) return Future.value(EngineResult.invalid);
    final track = project(bank: 0).tracks[channel];
    if (!track.available) return Future.value(EngineResult.invalid);
    return repository.toggleReverse(channel: channel);
  }
}
