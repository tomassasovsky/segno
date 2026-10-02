import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

class _Engine extends FakeAudioEngine {
  final choices = <({int mask, bool once})>[];
  bool refuseTrue = false;
  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    choices.add((mask: channels, once: oneShot));
    if (refuseTrue && oneShot) return EngineResult.invalid;
    return super.setOneShotMask(channels: channels, oneShot: oneShot);
  }
}

void main() {
  group('Once callback receipt', () {
    late _Engine engine;
    late LooperRepository repository;
    setUp(() {
      engine = _Engine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
    });
    tearDown(() => repository.dispose());
    test('matching bits still wait for the command boundary', () async {
      repository.startEngine(const EngineConfig());
      await repository.settleOneShot();
      engine.commandsAreSettled = false;
      expect(repository.setOneShot(channel: 0, oneShot: false).isOk, isTrue);
      expect(repository.oneShotSettingsSettled, isFalse);
      expect(repository.trackOneShotOverrides, isEmpty);
      engine.commandsAreSettled = true;
      expect((await repository.settleOneShot()).isOk, isTrue);
      expect(repository.trackOneShotOverrides, {0: false});
    });
    test(
      'default excludes Custom false and all Custom needs no callback',
      () async {
        repository
          ..setOneShotSnapshot(
            defaultOneShot: false,
            trackOverrides: {0: false},
          )
          ..startEngine(const EngineConfig());
        await repository.settleOneShot();
        engine.choices.clear();
        repository.setDefaultOneShot(oneShot: true);
        await repository.settleOneShot();
        expect(engine.choices, [(mask: 254, once: true)]);
        expect(engine.trackOneShot[0], isFalse);
        repository
          ..stopEngine()
          ..setOneShotSnapshot(
            defaultOneShot: true,
            trackOverrides: {for (var c = 0; c < 8; c++) c: false},
          )
          ..startEngine(const EngineConfig());
        await repository.settleOneShot();
        engine.choices.clear();
        engine.commandsAreSettled = false;
        expect(repository.setDefaultOneShot(oneShot: false).isOk, isTrue);
        expect(repository.oneShotSettingsSettled, isTrue);
        expect(engine.choices, isEmpty);
      },
    );
    test(
      'partial enqueue stops uncertainty and recovers desired vector',
      () async {
        repository.startEngine(const EngineConfig());
        await repository.settleOneShot();
        engine.refuseTrue = true;
        expect(
          repository
              .setOneShotSnapshot(
                defaultOneShot: true,
                trackOverrides: {0: false},
              )
              .isOk,
          isFalse,
        );
        expect(repository.state.status.isConnected, isFalse);
        expect(repository.oneShotRecoveryRequired, isTrue);
        expect(repository.startEngine(const EngineConfig()).isOk, isFalse);
        engine.refuseTrue = false;
        expect(repository.recoverOneShotSettings().isOk, isTrue);
        repository.startEngine(const EngineConfig());
        expect((await repository.settleOneShot()).isOk, isTrue);
        expect(engine.trackOneShot, {
          0: false,
          for (var c = 1; c < 8; c++) c: true,
        });
      },
    );
    test('receipt commits Released before an immediate restart', () async {
      repository.startEngine(const EngineConfig());
      await repository.settleOneShot();
      repository.setOneShot(channel: 7, oneShot: true, releasedOneShot: false);
      expect(repository.oneShotSettingsSettled, isTrue);
      expect(repository.trackOneShotOverrides, {7: true});
      expect(repository.oneShotRestartIntent.trackOverrides, {7: false});
      repository
        ..stopEngine()
        ..startEngine(const EngineConfig());
      await repository.settleOneShot();
      expect(engine.trackOneShot[7], isFalse);
    });
    test('cancelled deadline cannot stop a replacement rig', () async {
      repository.startEngine(const EngineConfig());
      await repository.settleOneShot();
      engine.commandsAreSettled = false;
      repository.setDefaultOneShot(oneShot: true);
      final oldReceipt = repository.settleOneShot();
      repository.stopEngine();
      engine.commandsAreSettled = true;
      repository
        ..setOneShotSnapshot(
          defaultOneShot: true,
          trackOverrides: {0: false},
        )
        ..startEngine(const EngineConfig());
      expect((await repository.settleOneShot()).isOk, isTrue);
      expect((await oldReceipt).isOk, isFalse);
      final stops = engine.calls.where((call) => call == 'stop').length;
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(engine.calls.where((call) => call == 'stop').length, stops);
      expect(repository.oneShotRecoveryRequired, isFalse);
      expect(repository.defaultOneShot, isTrue);
    });
  });
}
