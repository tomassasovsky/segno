import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno_engine/segno_engine.dart' as le;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

le.EngineSnapshot _stopped(LooperMode mode) => le.EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 2,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  looperMode: mode,
);

void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;
  late LooperRepository repository;
  late SettingsRepository settings;
  late LooperBloc bloc;

  Future<void> poll([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      ticker.add(null);
      await pumpEventQueue();
    }
  }

  setUp(() {
    engine = FakeAudioEngine()..nextSnapshot = _stopped(LooperMode.multi);
    ticker = StreamController<void>.broadcast();
    repository = LooperRepository(engine: engine, ticker: ticker.stream);
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = LooperBloc(repository: repository, settings: settings);
  });

  tearDown(() async {
    await bloc.close();
    await repository.dispose();
    await ticker.close();
  });

  test(
    'save confirmed modes, never requests rejected by stationary reports',
    () async {
      repository.startEngine(const EngineConfig());
      await poll();
      bloc.add(const LooperModeChanged(LooperMode.free));
      await pumpEventQueue();
      expect(repository.settledLooperMode, isNull);
      expect(await settings.loadLooperMode(), LooperMode.multi.code);

      engine.nextSnapshot = _stopped(LooperMode.free);
      await poll();
      expect(await settings.loadLooperMode(), LooperMode.free.code);

      bloc.add(const LooperModeChanged(LooperMode.band));
      await pumpEventQueue();
      expect(await settings.loadLooperMode(), LooperMode.free.code);
      await poll(14); // No position, meter, or visible state changes.
      expect(repository.settledLooperMode, LooperMode.free);
      expect(bloc.state.transport.looperMode, LooperMode.free);
      expect(await settings.loadLooperMode(), LooperMode.free.code);
      repository
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastLooperMode, LooperMode.free);
    },
  );

  test(
    'offline choices persist but a rejected boot replay is reconciled',
    () async {
      engine.nextSnapshot = const le.EngineSnapshot.initial();
      bloc.add(const LooperModeChanged(LooperMode.band));
      await pumpEventQueue();
      expect(await settings.loadLooperMode(), LooperMode.band.code);
      repository.startEngine(const EngineConfig());
      engine.nextSnapshot = _stopped(LooperMode.multi);
      expect(engine.lastLooperMode, LooperMode.band);
      await poll();
      expect(await settings.loadLooperMode(), LooperMode.band.code);
      await poll(13);
      expect(repository.settledLooperMode, LooperMode.multi);
      expect(await settings.loadLooperMode(), LooperMode.multi.code);
    },
  );
}
