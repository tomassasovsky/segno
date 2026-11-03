import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';

import '../../helpers/helpers.dart';

/// A unit family over one stored int whose request, receipt or load can
/// throw, the way a repository call that returns an unexpected null does.
class _Family implements SettingsFamily<int, int?> {
  int? stored = 1;
  int value = 1;
  bool throwOnRequest = false;
  bool throwOnSettle = false;

  @override
  OwnedSetting get key => OwnedSetting.clickVolume;

  @override
  List<Object?> get addresses => const [null];

  @override
  bool validate(int value) => true;

  @override
  Future<int?> readCheckpoint(Object? address) async => stored;

  @override
  Future<void> writeCheckpoint(Object? address, int? checkpoint) async =>
      stored = checkpoint;

  @override
  int? checkpointOf(int durable, Object? address, int? stored) => durable;

  @override
  List<Object?> supersededBy(Object? address, int before, int after) =>
      const [];

  @override
  int durableAfter(int durable, int written, Object? address) => written;

  @override
  int restoreValue(Map<Object?, int?> checkpoints) => checkpoints[null] ?? 1;

  @override
  int repair(Object? address) => 1;

  @override
  int get live => value;

  @override
  int get durable => value;

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => false;

  @override
  Stream<EngineResult> get failures => const Stream.empty();

  @override
  EngineResult request(int live, int durable, Object? edit) {
    if (throwOnRequest) throw TypeError();
    value = live;
    return EngineResult.ok;
  }

  @override
  Future<EngineResult> settle() async {
    if (throwOnSettle) throw StateError('receipt failed');
    return EngineResult.ok;
  }

  @override
  EngineResult recover() => EngineResult.ok;

  @override
  void retireLive() {}
}

/// A write that throws inside the owner's queue (#1614) answers its caller
/// with a reported refusal instead of leaving it waiting, and the writes
/// after it still run.
void main() {
  late LooperRepository looper;
  late _Family family;
  late SettingsOwner<int, int?> owner;
  late List<SettingOutcome> reported;

  setUp(() async {
    looper = LooperRepository(engine: FakeAudioEngine());
    family = _Family();
    owner = SettingsOwner(repository: looper, family: family);
    reported = [];
    final subscription = owner.failures.listen(reported.add);
    addTearDown(() async {
      await subscription.cancel();
      await owner.close();
      await looper.dispose();
    });
  });

  Future<SettingOutcome> answer(Future<SettingOutcome> write) =>
      write.timeout(const Duration(seconds: 2));

  test(
    'a request that throws refuses, reports and rolls storage back',
    () async {
      await owner.load();
      family.throwOnRequest = true;

      final outcome = await answer(owner.set(5));

      expect(outcome.status, SettingStatus.rejected);
      expect(outcome.error, isA<TypeError>());
      expect(family.stored, 1);
      expect(reported.single.error, isA<TypeError>());

      family.throwOnRequest = false;
      expect((await answer(owner.set(6))).isOk, isTrue);
      expect(family.stored, 6);
    },
  );

  test('a receipt that throws before storage is touched refuses and '
      'reports', () async {
    await owner.load();
    family.throwOnSettle = true;

    final outcome = await answer(owner.set(5));

    expect(outcome.status, SettingStatus.rejected);
    expect(outcome.error, isA<StateError>());
    expect(family.stored, 1);
    expect(reported.single.status, SettingStatus.rejected);

    family.throwOnSettle = false;
    expect((await answer(owner.set(6))).isOk, isTrue);
    expect(family.stored, 6);
  });

  test('a load that throws answers the write waiting on it', () async {
    family.throwOnSettle = true;

    final outcome = await answer(owner.set(5));

    expect(outcome.status, SettingStatus.rejected);
    expect(outcome.error, isA<StateError>());
    expect(family.stored, 1);
    expect(reported.last.error, isA<StateError>());
  });
}
