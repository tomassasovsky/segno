import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/record_timing.dart';

/// Unavailable timing owner for tests of unrelated controls.
class FakeRecordTimingControl implements RecordTimingControl {
  @override
  RecordTimingSnapshot? get recordTimingSnapshot => null;

  @override
  RecordTimingSnapshot get durableRecordTimingSnapshot => RecordTimingSnapshot(
    defaultTiming: RecordTiming.immediately,
    rememberedDivision: GridDivision.off,
    trackOverrides: const {},
    captureLocked: false,
  );

  @override
  RecordTimingLifetime get recordTimingLifetime =>
      (sessionRevision: 0, mixGeneration: 0);

  @override
  int recordTimingRevision(RecordTimingAddress address) => 0;

  @override
  Stream<({RecordTimingAddress address, RecordTiming? timing})>
  get ordinaryRecordTimingChanges => const Stream.empty();

  @override
  Future<RecordTimingOutcome> setControllerTiming(
    RecordTimingAddress address,
    RecordTiming timing, {
    required RecordTimingLifetime lifetime,
    required int revision,
    RecordTiming? releasedTiming,
  }) async => const RecordTimingOutcome(RecordTimingStatus.rejected);

  @override
  Future<RecordTimingOutcome> setTrackTiming({
    required int channel,
    required RecordTiming? timing,
  }) async => const RecordTimingOutcome(RecordTimingStatus.rejected);
}
