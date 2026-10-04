import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _RestoreEngine extends FakeAudioEngine {
  bool refuseMute = false;
  int muteRequests = 0;

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    muteRequests++;
    if (refuseMute) return EngineResult.invalid;
    return super.setMonitorInputMute(input: input, muted: muted);
  }
}

class _RestoreStore extends FakeKeyValueStore {
  bool refuseRead = false;
  Completer<void>? readGate;
  final readEntered = Completer<void>();
  Completer<void>? writeGate;
  final writeEntered = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'monitor_fx.0' && writeGate != null) {
      if (!writeEntered.isCompleted) writeEntered.complete();
      await writeGate!.future;
    }
    await super.setString(key, value);
  }

  @override
  Future<String?> getString(String key) async {
    if (key == 'monitor_input_mode.0' && readGate != null) {
      if (!readEntered.isCompleted) readEntered.complete();
      await readGate!.future;
    }
    if (refuseRead && key == 'monitor_input_mode.0') {
      throw StateError('saved monitor unavailable');
    }
    return super.getString(key);
  }
}

/// Gates the existing transaction stages without changing their effects.
class _RestoreRepository extends LooperRepository {
  _RestoreRepository(FakeAudioEngine engine)
    : super(engine: engine, ticker: const Stream<void>.empty());

  int fxCalls = 0;
  int? gatedFxCall;
  bool gateMix = false;
  final entered = Completer<void>();
  final release = Completer<EngineResult>();

  @override
  Future<EngineResult> settleFxRecipes({
    Duration pollInterval = const Duration(milliseconds: 8),
    int attempts = 64,
    bool waitForCallback = false,
    bool Function()? cancelled,
  }) {
    if (++fxCalls == gatedFxCall) {
      entered.complete();
      return release.future;
    }
    return super.settleFxRecipes(
      pollInterval: pollInterval,
      attempts: attempts,
      waitForCallback: waitForCallback,
      cancelled: cancelled,
    );
  }

  @override
  Future<EngineResult> settleMixSettings({
    Duration pollInterval = const Duration(milliseconds: 10),
    int attempts = 50,
  }) {
    if (gateMix) {
      gateMix = false;
      entered.complete();
      return release.future;
    }
    return super.settleMixSettings(
      pollInterval: pollInterval,
      attempts: attempts,
    );
  }
}

void main() {
  late _RestoreEngine engine;
  late _RestoreStore store;
  late _RestoreRepository repository;
  late SettingsRepository settings;
  late MixSettingsCoordinator mix;
  late FxChainPersistence fx;

  setUp(() async {
    engine = _RestoreEngine();
    store = _RestoreStore();
    repository = _RestoreRepository(engine)..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(repository, settings: settings);
    fx = FxChainPersistence(looper: repository);
    await settings.saveMonitorInputMode(0, mode: 'on');
    await settings.saveMonitorOutput(0, 8);
    await settings.saveMonitorVolume(0, .35);
  });

  tearDown(() async {
    await fx.close();
    await mix.close();
    await repository.dispose();
  });

  MonitorCubit build() => MonitorCubit(
    repository: repository,
    settings: settings,
    mixSettings: mix,
    fxPersistence: fx,
  );

  for (final (muted, initiallyMuted) in [
    (true, false),
    (false, true),
    (false, false),
  ]) {
    blocTest<MonitorCubit, MonitorState>(
      'retry restores saved mute $muted from $initiallyMuted after refusal',
      build: build,
      act: (cubit) async {
        await settings.saveMonitorMute(0, muted: muted);
        final encoded = encodeFxChain(
          FxChainEnvelope(
            entries: [
              BuiltInEffect(type: TrackEffectType.drive, slotId: 'saved'),
            ],
            chainEnabled: false,
          ),
        );
        await settings.saveMonitorEffects(0, encoded);
        if (initiallyMuted) repository.setMonitorMute(input: 0, muted: true);
        final saved = Map<String, Object>.of(store.values);
        engine.refuseMute = true;
        await cubit.load();
        expect(cubit.state.inputs, isEmpty);
        expect(cubit.state.restoreFailed, isTrue);
        expect(engine.monitorMute[0] ?? false, initiallyMuted);
        expect(repository.monitorMuted(0), initiallyMuted);
        engine.refuseMute = false;
        await cubit.load();
        expect(cubit.state.forInput(0).mode, MonitorMode.on);
        expect(cubit.state.forInput(0).outputMask, 8);
        expect(cubit.state.forInput(0).volume, .35);
        expect(cubit.state.forInput(0).muted, muted);
        expect(engine.monitorMute[0], muted);
        expect(cubit.state.restoreFailed, isFalse);
        expect(cubit.state.forInput(0).chainEnabled, isFalse);
        expect(cubit.state.forInput(0).effects.single.slotId, 'saved');
        expect(store.values, saved);
        final requests = engine.muteRequests;
        await cubit.load();
        expect(engine.muteRequests, requests);
        repository.setMonitorMute(input: 0, muted: !muted);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.forInput(0).muted, !muted);
      },
      errors: () => [isA<StateError>()],
    );
  }

  blocTest<MonitorCubit, MonitorState>(
    'explicit retry rereads saved settings after read failure',
    build: build,
    act: (cubit) async {
      store.refuseRead = true;
      await cubit.load();
      expect(cubit.state.inputs, isEmpty);
      store.refuseRead = false;
      await cubit.load();
      expect(cubit.state.forInput(0).mode, MonitorMode.on);
      expect(cubit.state.forInput(0).outputMask, 8);
    },
    errors: () => [isA<StateError>()],
  );
  blocTest<MonitorCubit, MonitorState>(
    'repeated failed retries remain explicit and in-flight loads deduplicate',
    build: build,
    act: (cubit) async {
      engine.refuseMute = true;
      await cubit.load();
      await cubit.load();
      expect(cubit.state.restoreFailed, isTrue);
      engine.refuseMute = false;
      store.readGate = Completer<void>();
      final first = cubit.load();
      await store.readEntered.future;
      final second = cubit.load();
      expect(identical(first, second), isTrue);
      expect(cubit.state.restoreFailed, isTrue);
      final requests = engine.muteRequests;
      store.readGate!.complete();
      await Future.wait([first, second]);
      expect(engine.muteRequests, requests + 1);
      expect(cubit.state.restoreFailed, isFalse);
    },
    errors: () => [isA<StateError>(), isA<StateError>()],
  );

  blocTest<MonitorCubit, MonitorState>(
    'ordinary state copy retains incomplete restore',
    seed: () => const MonitorState(restoreFailed: true),
    build: build,
    act: (cubit) async {
      await cubit.setMode(1, MonitorMode.off);
      expect(cubit.state.restoreFailed, isTrue);
    },
  );

  for (final stage in ['prior FX', 'mix', 'final FX']) {
    blocTest<MonitorCubit, MonitorState>(
      'Session reservation during $stage retires startup into explicit Retry',
      build: build,
      act: (cubit) async {
        if (stage == 'mix') {
          repository.gateMix = true;
        } else {
          repository.gatedFxCall = stage == 'prior FX' ? 1 : 2;
        }
        final pending = cubit.load();
        await repository.entered.future;
        fx.reserveSessionLoad();
        final requests = engine.muteRequests;
        repository.release.complete(EngineResult.invalid);
        await pending;
        expect(engine.muteRequests, requests);
        expect(cubit.state.inputs, isEmpty);
        expect(cubit.state.restoreFailed, isTrue);
        await cubit.load(); // The reservation itself never waits on Session.
        expect(engine.muteRequests, requests);
        fx.cancelSessionLoad();
        await cubit.load();
        expect(cubit.state.restoreFailed, isFalse);
        expect(cubit.state.forInput(0).outputMask, 8);
      },
    );
  }

  for (final close in [false, true]) {
    blocTest<MonitorCubit, MonitorState>(
      '${close ? 'close' : 'Session projection'} wins during '
      'prior FX settlement',
      build: build,
      act: (cubit) async {
        repository.gatedFxCall = 1;
        final pending = cubit.load();
        await repository.entered.future;
        if (close) {
          await cubit.close();
        } else {
          repository.setMonitorOutput(input: 0, mask: 16);
          cubit.projectFromRepository();
        }
        final requests = engine.muteRequests;
        repository.release.complete(EngineResult.invalid);
        await pending;
        expect(engine.muteRequests, requests);
        expect(cubit.state.restoreFailed, isFalse);
        if (!close) expect(cubit.state.forInput(0).outputMask, 16);
      },
    );
  }

  blocTest<MonitorCubit, MonitorState>(
    'close while reading admits no later monitor command',
    build: build,
    act: (cubit) async {
      store.readGate = Completer<void>();
      final pending = cubit.load();
      await store.readEntered.future;
      await cubit.close();
      final requests = engine.muteRequests;
      store.readGate!.complete();
      await pending;
      expect(engine.muteRequests, requests);
    },
  );
  blocTest<MonitorCubit, MonitorState>(
    'Session projection during minted-ID persistence prevents stale following',
    build: build,
    act: (cubit) async {
      await settings.saveMonitorEffects(
        0,
        encodeTrackEffects([BuiltInEffect(type: TrackEffectType.drive)]),
      );
      store.writeGate = Completer<void>();
      final pending = cubit.load();
      await store.writeEntered.future;
      repository.setMonitorOutput(input: 0, mask: 16);
      cubit.projectFromRepository();
      store.writeGate!.complete();
      await pending;
      expect(cubit.state.forInput(0).outputMask, 16);
      expect(cubit.state.restoreFailed, isFalse);
    },
  );

  for (final stage in ['FX', 'mix']) {
    blocTest<MonitorCubit, MonitorState>(
      '$stage refusal remains nonauthoritative and retryable',
      build: build,
      act: (cubit) async {
        if (stage == 'FX') {
          repository.gatedFxCall = 2;
        } else {
          repository.gateMix = true;
        }
        final pending = cubit.load();
        await repository.entered.future;
        repository.release.complete(EngineResult.invalid);
        await pending;
        expect(cubit.state.restoreFailed, isTrue);
        expect(cubit.state.inputs, isEmpty);
        await cubit.load();
        expect(cubit.state.restoreFailed, isFalse);
        expect(cubit.state.forInput(0).outputMask, 8);
      },
      errors: () => [isA<StateError>()],
    );
  }

  blocTest<MonitorCubit, MonitorState>(
    'reservation before first load exposes Retry after cancellation',
    build: build,
    act: (cubit) async {
      fx.reserveSessionLoad();
      final requests = engine.muteRequests;
      await cubit.load();
      expect(engine.muteRequests, requests);
      expect(cubit.state.restoreFailed, isTrue);
      fx.cancelSessionLoad();
      await cubit.load();
      expect(cubit.state.restoreFailed, isFalse);
      expect(cubit.state.forInput(0).outputMask, 8);
    },
  );
  blocTest<MonitorCubit, MonitorState>(
    'queued old load cannot overwrite an accepted replacement Session',
    build: build,
    act: (cubit) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final replacement = mix.runExclusive(() async {
        entered.complete();
        await release.future;
        await repository.applySession(
          const SessionRig(
            monitors: [
              SessionRigMonitor(
                input: 0,
                mode: MonitorMode.auto,
                outputMask: 16,
                volume: .65,
                muted: true,
                effects: [],
              ),
            ],
          ),
        );
      });
      await entered.future;
      final pending = cubit.load();
      release.complete();
      await replacement;
      final requests = engine.muteRequests;
      await pending;
      expect(engine.muteRequests, requests);
      expect(repository.allMonitors()[0]!.outputMask, 16);
      cubit.projectFromRepository();
      await cubit.load();
      expect(cubit.state.restoreFailed, isFalse);
      expect(cubit.state.forInput(0).volume, .65);
      expect(cubit.state.forInput(0).outputMask, 16);
    },
  );
}
