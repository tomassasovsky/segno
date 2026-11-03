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

  /// Every receipt throws, the load's and a write's first one included.
  bool throwOnSettle = false;

  /// Only the receipt right after a request throws.
  bool throwOnReceipt = false;
  bool _requested = false;
  final requests = <int>[];

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
    requests.add(live);
    if (throwOnRequest) throw TypeError();
    value = live;
    _requested = true;
    return EngineResult.ok;
  }

  @override
  Future<EngineResult> settle() async {
    final requested = _requested;
    _requested = false;
    if (throwOnSettle || (throwOnReceipt && requested)) {
      throw StateError('receipt failed');
    }
    return EngineResult.ok;
  }

  @override
  EngineResult recover() => EngineResult.ok;

  @override
  void retireLive() {}
}

/// A write or load that throws inside the owner's queue (#1614) answers its
/// caller and reports, instead of leaving it waiting; the writes after it
/// still run, and Retry recovers what the throw left uncertain.
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

  test('a request that throws owes its value: storage keeps it, Retry '
      'requests it again', () async {
    await owner.load();
    family.throwOnRequest = true;

    final outcome = await answer(owner.set(5));

    expect(outcome.status, SettingStatus.recoveryRequired);
    expect(outcome.error, isA<TypeError>());
    expect(family.stored, 5);
    expect(reported.single.error, isA<TypeError>());
    expect(owner.ready, isFalse);
    expect(
      (await answer(owner.set(6))).status,
      SettingStatus.recoveryRequired,
    );
    expect(family.stored, 5);

    family.throwOnRequest = false;
    expect((await answer(owner.recover())).isOk, isTrue);
    expect(family.requests.last, 5);
    expect(family.value, 5);
    expect(owner.ready, isTrue);
    expect((await answer(owner.set(6))).isOk, isTrue);
    expect(family.stored, 6);
  });

  test('a receipt that throws after the request owes the value too', () async {
    await owner.load();
    family.throwOnReceipt = true;

    final outcome = await answer(owner.set(5));

    expect(outcome.status, SettingStatus.recoveryRequired);
    expect(outcome.error, isA<StateError>());
    expect(family.stored, 5);
    expect(owner.ready, isFalse);

    family.throwOnReceipt = false;
    expect((await answer(owner.recover())).isOk, isTrue);
    expect(owner.ready, isTrue);
    expect((await answer(owner.set(6))).isOk, isTrue);
  });

  test('a receipt that throws before storage is touched refuses and '
      'reports, and the next write runs', () async {
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

  test('a load that throws answers the write waiting on it, and Retry '
      'loads again', () async {
    family.throwOnSettle = true;

    final outcome = await answer(owner.set(5));

    expect(outcome.status, SettingStatus.recoveryRequired);
    expect(family.stored, 1);
    expect(reported.first.error, isA<StateError>());
    expect(owner.initialized, isFalse);

    family.throwOnSettle = false;
    expect((await answer(owner.recover())).isOk, isTrue);
    expect(owner.initialized, isTrue);
    expect(owner.ready, isTrue);
    expect((await answer(owner.set(6))).isOk, isTrue);
    expect(family.stored, 6);
  });
}
