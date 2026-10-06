import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/application/record_settings.dart';
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
  tracks: List.generate(8, (_) => const le.TrackSnapshot.empty()),
);

void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;
  late LooperRepository repository;
  late SettingsRepository settings;
  late LooperBloc bloc;
  late RecordSettings record;

  Future<void> poll([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      ticker.add(null);
      await pumpEventQueue();
    }
  }

  setUp(() async {
    engine = FakeAudioEngine()..nextSnapshot = _stopped(LooperMode.multi);
    ticker = StreamController<void>.broadcast();
    repository = LooperRepository(engine: engine, ticker: ticker.stream);
    settings = SettingsRepository(store: FakeKeyValueStore());
    record = RecordSettings(repository: repository, settings: settings);
    await record.load();
    bloc = LooperBloc(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository),
      repository: repository,
      settings: settings,
    );
  });

  tearDown(() async {
    await bloc.close();
    await record.close();
    await repository.dispose();
    await ticker.close();
  });

  for (final mode in [LooperMode.multi, LooperMode.song]) {
    test(
      'startup restores ${mode.name} with the complete length image',
      () async {
        final bootEngine = FakeAudioEngine();
        final bootRepository = LooperRepository(engine: bootEngine);
        final bootSettings = SettingsRepository(store: FakeKeyValueStore());
        if (mode != LooperMode.multi) {
          await bootSettings.saveLooperMode(mode.code);
        }
        await bootSettings.saveDefaultLengthPreset(4);
        await bootSettings.saveTrackLengthPreset(7, 0);
        final bootOwner = RecordSettings(
          repository: bootRepository,
          settings: bootSettings,
        );
        addTearDown(bootRepository.dispose);
        addTearDown(bootOwner.close);
        await bootOwner.load();
        expect(bootOwner.state.recordLengthReady, isTrue);
        expect(bootRepository.sessionTransport.looperMode, mode);
        expect(bootRepository.sessionTransport.defaultLengthPresetBars, 4);
        expect(bootRepository.trackLengthPresetOverrides, {7: 0});
      },
    );
  }

  test(
    'publish durable modes after callback acknowledgement and retain refusals',
    () async {
      repository.startEngine(const EngineConfig());
      await poll();
      engine
        ..commandsAreSettled = false
        ..publishModeCommands = false;
      unawaited(record.setLooperMode(LooperMode.free));
      await pumpEventQueue();
      expect(repository.settledLooperMode, isNull);
      // Storage stages the candidate before enqueue. Save and shutdown wait
      // on the owner queue; its durable image stays at the confirmed mode.
      expect(record.durableRecordLengthSnapshot.mode, LooperMode.multi);

      await poll(2);
      expect(repository.settledLooperMode, isNull);
      expect(record.durableRecordLengthSnapshot.mode, LooperMode.multi);
      engine
        ..nextSnapshot = _stopped(LooperMode.free)
        ..commandsAreSettled = true;
      await poll();
      await record.owner.flush();
      expect(await settings.loadLooperMode(), LooperMode.free.code);
      expect(record.durableRecordLengthSnapshot.mode, LooperMode.free);

      engine.commandsAreSettled = false;
      unawaited(record.setLooperMode(LooperMode.band));
      await pumpEventQueue();
      expect(repository.settledLooperMode, isNull);
      expect(record.durableRecordLengthSnapshot.mode, LooperMode.free);
      await poll(2);
      expect(repository.settledLooperMode, isNull);
      // The callback consumed the request but kept the already-confirmed mode.
      engine.commandsAreSettled = true;
      await poll();
      await record.owner.flush();
      expect(repository.settledLooperMode, LooperMode.free);
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(bloc.state.transport.looperMode, LooperMode.free);
      expect(await settings.loadLooperMode(), LooperMode.free.code);
      repository
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastLooperMode, LooperMode.free);
    },
  );

  test(
    'an unconfirmed startup mode is owed without a stop, keeps the saved '
    'choice, and Retry lands it',
    () async {
      engine.nextSnapshot = const le.EngineSnapshot.initial();
      unawaited(record.setLooperMode(LooperMode.band));
      await pumpEventQueue();
      expect(await settings.loadLooperMode(), LooperMode.band.code);
      engine
        ..nextSnapshot = _stopped(LooperMode.multi)
        ..commandsAreSettled = false
        ..publishModeCommands = false;
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(engine.lastLooperMode, LooperMode.band);
      await poll(2);
      expect(repository.settledLooperMode, isNull);
      expect(await settings.loadLooperMode(), LooperMode.band.code);

      final failure = repository.lengthSettingsFailures.first;
      engine.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      expect(await failure, EngineResult.invalid);
      await poll();
      // The replay owes the mode; audio keeps running.
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(repository.lengthRecoveryRequired, isTrue);
      expect(repository.lengthRestartIntent.mode, LooperMode.band);
      expect(await settings.loadLooperMode(), LooperMode.band.code);

      engine.publishModeCommands = true;
      expect((await record.owner.recover()).isOk, isTrue);
      expect(repository.lengthRecoveryRequired, isFalse);
      await poll();
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(engine.lastLooperMode, LooperMode.band);
      expect(bloc.state.transport.looperMode, LooperMode.band);
      expect(await settings.loadLooperMode(), LooperMode.band.code);
    },
  );
}
