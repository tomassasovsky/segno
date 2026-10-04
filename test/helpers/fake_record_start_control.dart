import 'package:segno/looper/model/record_start.dart';

/// An unavailable recording-start owner for unrelated control fixtures.
/// Recording-start behavior tests use the real owner instead.
class FakeRecordStartControl implements RecordStartControl {
  @override
  RecordStartSnapshot? get recordStartSnapshot => null;

  @override
  RecordStartSettings? get confirmedRecordStart => null;

  @override
  RecordStartSettings get durableRecordStartSettings =>
      RecordStartSettings(countInBars: 0, soundStart: false);

  @override
  RecordStartLifetime get recordStartLifetime =>
      (sessionRevision: 0, mixGeneration: 0);

  @override
  int get recordStartRevision => 0;

  @override
  Stream<RecordStartSettings> get ordinaryRecordStartChanges =>
      const Stream.empty();

  @override
  Future<RecordStartOutcome> setCountInBars(int bars) async =>
      const RecordStartOutcome(RecordStartStatus.rejected);

  @override
  Future<RecordStartOutcome> setSoundStart({required bool enabled}) async =>
      const RecordStartOutcome(RecordStartStatus.rejected);

  @override
  Future<RecordStartOutcome> setControllerCountIn(
    int bars, {
    required RecordStartLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) async => const RecordStartOutcome(RecordStartStatus.rejected);
}
