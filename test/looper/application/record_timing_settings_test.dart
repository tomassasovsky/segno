import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _FaultStore extends FakeKeyValueStore {
  String? failKey;
  bool failOnce = true;
  Completer<void>? blockedRead;
  @override
  Future<int?> getInt(String key) async {
    if (key == 'track_record_timing.7' && blockedRead != null) {
      await blockedRead!.future;
    }
    return super.getInt(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    await super.setInt(key, value);
    if (key == failKey) {
      if (failOnce) failKey = null;
      throw StateError('scalar write failed after mutation');
    }
  }
}

class _RefusingEngine extends FakeAudioEngine {
  bool refuse = false;
  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) => refuse
      ? EngineResult.invalid
      : super.setRecordTimingSettings(
          defaultTiming: defaultTiming,
          rememberedDivision: rememberedDivision,
          trackOverrides: trackOverrides,
          editMask: editMask,
        );
}

void main() {
  late _FaultStore store;
  late SettingsRepository settings;
  late _RefusingEngine engine;
  late LooperRepository repository;
  late RecordTimingSettings owner;
  setUp(() {
    store = _FaultStore();
    settings = SettingsRepository(store: store);
    engine = _RefusingEngine();
    repository = LooperRepository(engine: engine);
    owner = RecordTimingSettings(repository: repository, settings: settings);
  });
  tearDown(() async {
    await owner.close();
    await repository.dispose();
  });

  test(
    'default is unavailable until independent initialization completes',
    () async {
      expect(owner.recordTimingSnapshot, isNull);
      final states = <RecordTimingState>[];
      final subscription = owner.stream.listen(states.add);
      await owner.load();
      await Future<void>.delayed(Duration.zero);
      expect(
        owner.recordTimingSnapshot!.defaultTiming,
        RecordTiming.immediately,
      );
      expect(states.any((s) => s.recordTimingReady), isTrue);
      await subscription.cancel();
    },
  );
  test(
    'load stages all eight slots and retains explicit Immediately',
    () async {
      store.values.addAll({
        'looper.quantize': true,
        'tempo.quantize_div': 3,
        'track_record_timing.0': 0,
        'track_record_timing.7': 6,
      });
      await owner.load();
      expect(owner.state.defaultTiming, RecordTiming.quarter);
      expect(owner.state.trackOverrides, {
        0: RecordTiming.immediately,
        7: RecordTiming.sixteenth,
      });
      expect(owner.state.recordTimingReady, isTrue);
    },
  );
  test(
    'malformed final slot preserves storage and never partially applies',
    () async {
      store.values.addAll({
        'looper.quantize': true,
        'tempo.quantize_div': 3,
        'track_record_timing.7': 7,
      });
      await owner.load();
      expect(owner.recordTimingSnapshot, isNull);
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(
        (await owner.recoverRecordTiming()).status,
        RecordTimingStatus.recoveryRequired,
      );
      expect(store.values['track_record_timing.7'], 7);
    },
  );
  test('gate off and on keeps remembered musical division', () async {
    await owner.load();
    expect((await owner.setTiming(RecordTiming.quarter)).isOk, isTrue);
    await owner.setEnabled(value: false);
    expect(owner.state.defaultTiming, RecordTiming.immediately);
    expect(owner.state.rememberedDivision, GridDivision.quarter);
    await owner.setEnabled(value: true);
    expect(owner.state.defaultTiming, RecordTiming.quarter);
    expect((await settings.readRecordTimingCheckpoint()).division, 3);
  });
  test('first enable waits for saved remembered division', () async {
    store.values.addAll({'looper.quantize': false, 'tempo.quantize_div': 4});
    await owner.setEnabled(value: true);
    expect(owner.state.defaultTiming, RecordTiming.eighth);
  });
  test(
    'held musical timing projects Released with prior durable memory',
    () async {
      await owner.load();
      await owner.setTiming(RecordTiming.quarter);
      await owner.setEnabled(value: false);
      final result = await owner.setControllerTiming(
        const RecordTimingAddress.defaults(),
        RecordTiming.sixteenth,
        lifetime: owner.recordTimingLifetime,
        revision: 2,
        releasedTiming: RecordTiming.immediately,
      );
      expect(result.isOk, isTrue);
      expect(owner.state.defaultTiming, RecordTiming.sixteenth);
      expect(owner.state.rememberedDivision, GridDivision.sixteenth);
      expect(
        owner.durableRecordTimingSnapshot.defaultTiming,
        RecordTiming.immediately,
      );
      expect(
        owner.durableRecordTimingSnapshot.rememberedDivision,
        GridDivision.quarter,
      );
      expect((await settings.readRecordTimingCheckpoint()).quantize, isFalse);
      expect((await settings.readRecordTimingCheckpoint()).division, 3);
      final released = await owner.setControllerTiming(
        const RecordTimingAddress.defaults(),
        RecordTiming.immediately,
        lifetime: owner.recordTimingLifetime,
        revision: 2,
      );
      expect(released.isOk, isTrue);
      expect(owner.state.rememberedDivision, GridDivision.quarter);
      await owner.setEnabled(value: true);
      expect(owner.state.defaultTiming, RecordTiming.quarter);
    },
  );
  test(
    'ordinary reset removes explicit zero and fences only that address',
    () async {
      await owner.load();
      await owner.setTrackTiming(channel: 0, timing: RecordTiming.immediately);
      await owner.setTrackTiming(channel: 7, timing: RecordTiming.eighth);
      final origin = owner.recordTimingLifetime;
      await owner.setTrackTiming(channel: 0, timing: null);
      final stale = await owner.setControllerTiming(
        const RecordTimingAddress.track(0),
        RecordTiming.bar,
        lifetime: origin,
        revision: 1,
      );
      expect(stale.status, RecordTimingStatus.superseded);
      expect(owner.state.trackOverrides, {7: RecordTiming.eighth});
      expect(store.values.containsKey('track_record_timing.0'), isFalse);
      expect(owner.recordTimingRevision(const RecordTimingAddress.track(7)), 1);
    },
  );
  for (final key in ['tempo.quantize_div', 'track_record_timing.7']) {
    test('mutating failure compensates exact scalar absence: $key', () async {
      await owner.load();
      store.failKey = key;
      final result = key == 'tempo.quantize_div'
          ? await owner.setTiming(RecordTiming.quarter)
          : await owner.setTrackTiming(channel: 7, timing: RecordTiming.bar);
      expect(result.status, RecordTimingStatus.rejected);
      expect(store.values, isEmpty);
      expect(owner.state.defaultTiming, RecordTiming.immediately);
      expect(owner.state.trackOverrides, isEmpty);
      expect((await owner.recoverRecordTiming()).isOk, isTrue);
      expect((await owner.flushRecordTiming()).isOk, isTrue);
    });
  }
  test(
    'known engine refusal keeps accepted state and exact saved tuple',
    () async {
      await owner.load();
      await owner.setTiming(RecordTiming.quarter);
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      await repository.settleRecordTimingSettings();
      engine.refuse = true;
      final result = await owner.setTiming(RecordTiming.eighth);
      expect(result.status, RecordTimingStatus.rejected);
      expect(owner.state.defaultTiming, RecordTiming.quarter);
      expect((await settings.readRecordTimingCheckpoint()).division, 3);
    },
  );
  test('compensated native refusal leaves healthy flush applied', () async {
    await owner.load();
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    await repository.settleRecordTimingSettings();
    final failures = <RecordTimingOutcome>[];
    final subscription = owner.recordTimingFailures.listen(failures.add);
    engine.refuse = true;
    final result = await owner.setTiming(RecordTiming.quarter);
    expect(result.status, RecordTimingStatus.rejected);
    expect(store.values, isEmpty);
    expect(owner.state.defaultTiming, RecordTiming.immediately);
    expect(owner.state.recordTimingReady, isTrue);
    expect(repository.recordTimingRecoveryRequired, isFalse);
    expect(
      (await owner.flushRecordTiming()).status,
      RecordTimingStatus.applied,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      failures.map((outcome) => outcome.status),
      contains(RecordTimingStatus.rejected),
    );
    await subscription.cancel();
  });
  test('flush preserves malformed startup recovery blocker', () async {
    store.values['track_record_timing.7'] = 7;
    await owner.load();
    expect(
      (await owner.flushRecordTiming()).status,
      RecordTimingStatus.recoveryRequired,
    );
    expect(owner.recordTimingSnapshot, isNull);
    expect(store.values['track_record_timing.7'], 7);
  });
  test('flush does not acknowledge an unsettled callback deadline', () async {
    await owner.load();
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    await repository.settleRecordTimingSettings();
    engine.commandsAreSettled = false;
    expect(repository.setRecordTiming(RecordTiming.quarter), EngineResult.ok);
    final outcome = await owner.flushRecordTiming();
    expect(outcome.status, RecordTimingStatus.recoveryRequired);
    expect(repository.recordTimingRecoveryRequired, isTrue);
    expect(owner.recordTimingSnapshot, isNull);
  });
  test(
    'startup blocked at last read never publishes provisional readiness',
    () async {
      store.blockedRead = Completer<void>();
      final load = owner.load();
      await Future<void>.delayed(Duration.zero);
      repository.setMasterGain(.8);
      await Future<void>.delayed(Duration.zero);
      expect(owner.recordTimingSnapshot, isNull);
      store.blockedRead!.complete();
      await load;
      expect(owner.state.recordTimingReady, isTrue);
    },
  );
  test(
    'new session wins delayed startup without writing global settings',
    () async {
      store.values.addAll({'looper.quantize': true, 'tempo.quantize_div': 3});
      store.blockedRead = Completer<void>();
      final load = owner.load();
      await Future<void>.delayed(Duration.zero);
      await repository.applySession(
        const SessionRig(
          recordTiming: RecordTiming.eighth,
          quantizeDiv: GridDivision.eighth,
        ),
      );
      store.blockedRead!.complete();
      await load;
      expect(owner.state.defaultTiming, RecordTiming.eighth);
      expect((await settings.readRecordTimingCheckpoint()).division, 3);
    },
  );
  test(
    'close awaits initialization and prevents late ready emission',
    () async {
      store.blockedRead = Completer<void>();
      final load = owner.load();
      var closed = false;
      final closing = owner.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      store.blockedRead!.complete();
      await load;
      await closing;
      await expectLater(owner.stream, emitsDone);
      expect(owner.state.recordTimingReady, isFalse);
    },
  );
}
