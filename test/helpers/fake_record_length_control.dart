import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/record_length.dart';

/// An unavailable record-length owner for tests of unrelated controls.
class FakeRecordLengthControl implements RecordLengthControl {
  @override
  RecordLengthSnapshot? get recordLengthSnapshot => null;

  @override
  RecordLengthSnapshot get durableRecordLengthSnapshot => RecordLengthSnapshot(
    defaultBars: 0,
    trackOverrides: const {},
    mode: LooperMode.multi,
    captureLocked: false,
  );

  @override
  RecordLengthLifetime get recordLengthLifetime =>
      (sessionRevision: 0, mixGeneration: 0);

  @override
  int recordLengthRevision(RecordLengthAddress address) => 0;

  @override
  Stream<({RecordLengthAddress address, int? bars})>
  get ordinaryRecordLengthChanges => const Stream.empty();

  @override
  Future<RecordLengthOutcome> setControllerRecordLength(
    RecordLengthAddress address,
    int bars, {
    required RecordLengthLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) async => const RecordLengthOutcome(RecordLengthStatus.rejected);

  @override
  Future<RecordLengthOutcome> setTrackRecordLength({
    required int channel,
    required int? bars,
  }) async => const RecordLengthOutcome(RecordLengthStatus.rejected);

  @override
  Future<RecordLengthOutcome> setLooperMode(LooperMode mode) async =>
      const RecordLengthOutcome(RecordLengthStatus.rejected);
}
