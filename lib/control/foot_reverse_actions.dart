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

  /// Turns one recorded track around at its current position. Refuses an
  /// empty track as [EngineResult.invalid] and a busy one (writing, or with
  /// an arm or launch pending) as [EngineResult.notReady], without posting
  /// either. Shared by the Reverse surface and assigned Reverse actions.
  Future<EngineResult> toggle(int channel) {
    if (channel < 0 || channel >= 8) return Future.value(EngineResult.invalid);
    final track = project(bank: 0).tracks[channel];
    if (!track.recorded) return Future.value(EngineResult.invalid);
    if (track.busy) return Future.value(EngineResult.notReady);
    return repository.toggleReverse(channel: channel);
  }
}
