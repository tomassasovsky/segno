import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

class _Engine extends FakeAudioEngine {
  bool corrupt = false;
  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) {
    final result = super.setRecordTimingSettings(
      defaultTiming: defaultTiming,
      rememberedDivision: rememberedDivision,
      trackOverrides: trackOverrides,
      editMask: editMask,
    );
    if (corrupt) lastQuantizeDiv = GridDivision.sixteenth;
    return result;
  }
}

void main() {
  late _Engine engine;
  late LooperRepository repository;
  setUp(() {
    engine = _Engine();
    repository = LooperRepository(engine: engine, ticker: const Stream.empty());
  });
  tearDown(() => repository.dispose());
  Future<void> start() async {
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
  }

  test(
    'pending timing refuses before monitor plugin capture or preparation',
    () async {
      await start();
      engine.nextState = Uint8List.fromList([1, 2, 3]);
      expect(
        repository.setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        ),
        EngineResult.ok,
      );
      engine.commandsAreSettled = false;
      expect(repository.setRecordTiming(RecordTiming.quarter), EngineResult.ok);
      engine.calls.clear();
      final refused = repository.record();
      expect(engine.calls, isNot(contains('pluginStateGet')));
      expect(engine.calls, isNot(contains('preparePlugin')));
      expect(engine.calls, isNot(contains('record')));
      expect(engine.lastRecordImage, isNull);
      expect(refused, EngineResult.notReady);
      engine.commandsAreSettled = true;
      expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
      engine.calls.clear();
      expect(repository.record(), EngineResult.ok);
      expect(engine.calls, contains('pluginStateGet'));
      expect(engine.calls, contains('preparePlugin'));
      expect(engine.calls, contains('record'));
      expect(engine.lastRecordImage, isNotNull);
    },
  );
  test(
    'same-value explicit Immediately waits for new callback receipt',
    () async {
      await start();
      engine.commandsAreSettled = false;
      expect(
        repository.setTrackRecordTiming(
          channel: 7,
          timing: RecordTiming.immediately,
        ),
        EngineResult.ok,
      );
      expect(repository.trackRecordTimingOverrides, isEmpty);
      expect(repository.recordTimingSettingsSettled, isFalse);
      engine.commandsAreSettled = true;
      expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
      expect(repository.trackRecordTimingOverrides, {
        7: RecordTiming.immediately,
      });
    },
  );
  test(
    'explicit refused receipt with exact prior vector never stops',
    () async {
      await start();
      engine.publishTimingCommands = false;
      repository.setRecordTiming(RecordTiming.quarter);
      expect(
        await repository.settleRecordTimingSettings(),
        EngineResult.invalid,
      );
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(repository.recordTimingRecoveryRequired, isFalse);
      expect(engine.calls.where((c) => c == 'stop'), isEmpty);
    },
  );
  test(
    'successful receipt with wrong vector is owed, not accepted, and Retry '
    'lands it without a stop',
    () async {
      await start();
      engine.corrupt = true;
      repository.setRecordTiming(RecordTiming.quarter);
      expect(
        await repository.settleRecordTimingSettings(),
        EngineResult.invalid,
      );
      expect(repository.recordTimingRecoveryRequired, isTrue);
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(
        repository.recordTimingRestartIntent.defaultTiming,
        RecordTiming.quarter,
      );
      expect(engine.calls.where((c) => c == 'stop'), isEmpty);
      engine.corrupt = false;
      expect(repository.recoverRecordTimingSettings(), EngineResult.ok);
      expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
      expect(repository.recordTimingRecoveryRequired, isFalse);
      expect(repository.defaultRecordTiming, RecordTiming.quarter);
    },
  );
  test('an owed timing vector does not refuse a Mixer edit', () async {
    await start();
    engine.corrupt = true;
    repository.setRecordTiming(RecordTiming.quarter);
    expect(
      await repository.settleRecordTimingSettings(),
      EngineResult.invalid,
    );
    expect(repository.recordTimingRecoveryRequired, isTrue);
    expect(repository.setVolume(.5, channel: 1), EngineResult.ok);
    expect(await repository.settleMixSettings(), EngineResult.ok);
  });
  test('autonomous startup receipt deadline owes the vector without blocking '
      'a restart', () async {
    repository.setRecordTimingSettings(
      defaultTiming: RecordTiming.quarter,
      rememberedDivision: GridDivision.quarter,
      trackOverrides: {7: RecordTiming.immediately},
    );
    engine.commandsAreSettled = false;
    final failure = repository.recordTimingFailures.first;
    repository.startEngine(const EngineConfig());
    expect(
      await failure.timeout(const Duration(seconds: 2)),
      EngineResult.notReady,
    );
    expect(repository.recordTimingRecoveryRequired, isTrue);
    expect(engine.calls.where((c) => c == 'stop'), isEmpty);
    // A restart replays the owed vector instead of being refused.
    engine.commandsAreSettled = true;
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
    expect(repository.defaultRecordTiming, RecordTiming.quarter);
    expect(repository.trackRecordTimingOverrides, {
      7: RecordTiming.immediately,
    });
  });
  test(
    'restart applies Released plus original Immediately memory in all slots',
    () async {
      await start();
      repository.setRecordTiming(RecordTiming.quarter);
      await repository.settleRecordTimingSettings();
      repository.setRecordTiming(RecordTiming.immediately);
      await repository.settleRecordTimingSettings();
      repository.setRecordTiming(
        RecordTiming.sixteenth,
        releasedTiming: RecordTiming.immediately,
      );
      await repository.settleRecordTimingSettings();
      repository.setTrackRecordTiming(
        channel: 7,
        timing: RecordTiming.bar,
        releasedTiming: RecordTiming.immediately,
      );
      await repository.settleRecordTimingSettings();
      repository
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(repository.sessionTransport.quantizeDiv, GridDivision.quarter);
      expect(engine.trackQuantize, {
        for (var c = 0; c < 7; c++) c: null,
        7: false,
      });
      expect(engine.trackQuantizeDiv[7], GridDivision.off);
    },
  );
}
