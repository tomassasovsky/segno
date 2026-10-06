import 'dart:async';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/monitor_mute.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno_engine/segno_engine.dart' show FxOwner;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// Counts the monitor FX envelope writes the debounce is meant to collapse.
class _CountingStore extends FakeKeyValueStore {
  int stringWrites = 0;

  @override
  Future<void> setString(String key, String value) {
    if (key == 'monitor_fx.0') stringWrites++;
    return super.setString(key, value);
  }
}

class _DeferredMonitorFxStore extends FakeKeyValueStore {
  final firstWrite = Completer<void>();
  final firstWriteStarted = Completer<void>();
  int fxWrites = 0;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'monitor_fx.0') {
      fxWrites++;
      if (fxWrites == 1) {
        firstWriteStarted.complete();
        await firstWrite.future;
      }
    }
    await super.setString(key, value);
  }
}

class _BlockedMonitorModeStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'monitor_input_mode.0' && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.setString(key, value);
  }
}

class _RefusingMuteEngine extends FakeAudioEngine {
  bool refuseMute = false;
  final monitorSteps = <({bool enabled, bool muted, int output})>[];

  EngineResult _sampleMonitor(int input, EngineResult result) {
    if (result.isOk) {
      monitorSteps.add((
        enabled: monitorInputEnabled[input] ?? false,
        muted: monitorMute[input] ?? false,
        output: monitorOutput[input] ?? 3,
      ));
    }
    return result;
  }

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    if (refuseMute) return EngineResult.invalid;
    return _sampleMonitor(
      input,
      super.setMonitorInputMute(input: input, muted: muted),
    );
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) => _sampleMonitor(
    input,
    super.setMonitorInputEnabled(input: input, enabled: enabled),
  );

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) =>
      _sampleMonitor(
        input,
        super.setMonitorInputOutput(input: input, mask: mask),
      );
}

class _FailingMuteStore extends FakeKeyValueStore {
  bool failMute = false;
  String? blockedKey;
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> _waitForRelease(String key) async {
    if (key != blockedKey || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<void> setString(String key, String value) async {
    await _waitForRelease(key);
    await super.setString(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await _waitForRelease(key);
    if (failMute && key == 'monitor_mute.0') {
      throw StateError('mute storage failed');
    }
    await super.setBool(key, value: value);
  }
}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late PluginCatalog catalog;
  late StreamController<LooperState> looperStates;

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(const InputSetup.empty());
    registerFallbackValue(MixSettingsSnapshot());
  });

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
    addTearDown(looperStates.close);
    final monitorVolumes = <int, double>{};
    final monitorModes = <int, MonitorMode>{};
    final monitorOutputs = <int, int>{};
    final monitorMutes = <int, bool>{};
    when(() => repository.monitorMuted(any())).thenAnswer(
      (call) => monitorMutes[call.positionalArguments.first] ?? false,
    );
    final monitorChains = <int, List<TrackEffect>>{};
    final monitorChainFlags = <int, bool>{};
    when(repository.allMonitors).thenAnswer(
      (_) => {
        for (final input in {
          ...monitorChains.keys,
          ...monitorChainFlags.keys,
          ...monitorModes.keys,
          ...monitorOutputs.keys,
          ...monitorMutes.keys,
        })
          input: InputMonitor(
            input: input,
            mode: monitorModes[input] ?? MonitorMode.off,
            outputMask: monitorOutputs[input] ?? 3,
            muted: monitorMutes[input] ?? false,
            effects: monitorChains[input] ?? const [],
            chainEnabled: monitorChainFlags[input] ?? true,
          ),
      },
    );
    when(() => repository.monitorEffects(any())).thenAnswer((call) {
      final input = call.positionalArguments.first as int;
      return monitorChains[input] ??
          repository.allMonitors()[input]?.effects ??
          const [];
    });
    when(() => repository.monitorChainEnabled(any())).thenAnswer((call) {
      final input = call.positionalArguments.first as int;
      return monitorChainFlags[input] ??
          repository.allMonitors()[input]?.chainEnabled ??
          true;
    });
    var currentMix = MixSettingsSnapshot();
    MixSettingsSnapshot? pendingMix;
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => repository.fxRecipesSettled).thenReturn(true);
    when(
      () => repository.settleFxRecipes(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.mixSettingsSettled).thenReturn(true);
    when(() => repository.mixRecoveryRequired).thenReturn(false);
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.mixSettingsSnapshot).thenAnswer((_) => currentMix);
    when(
      () => repository.validateMixSettings(any()),
    ).thenReturn(EngineResult.ok);
    when(() => repository.applyMixSettings(any())).thenAnswer((call) {
      pendingMix = call.positionalArguments.first as MixSettingsSnapshot;
      return EngineResult.ok;
    });
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.trackPans).thenReturn(const {});
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.monitorVolume(any())).thenAnswer(
      (call) => monitorVolumes[call.positionalArguments.first] ?? 1,
    );
    when(
      () => repository.setMixSettings(
        trackPans: any(named: 'trackPans'),
        inputSetup: any(named: 'inputSetup'),
        monitorLevels: any(named: 'monitorLevels'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.settleMixSettings(),
    ).thenAnswer((_) async {
      if (pendingMix case final accepted?) {
        currentMix = accepted;
        monitorVolumes.addAll(accepted.monitorLevels);
        pendingMix = null;
      }
      return EngineResult.ok;
    });
    // The cubit follows the scan: the repository's answer about whether a
    // plugin loaded changes when one lands.
    catalog = PluginCatalog(
      engine: FakeAudioEngine(),
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    addTearDown(catalog.dispose);
    when(() => repository.pluginCatalog).thenReturn(catalog);
    // And it follows the repository's own monitor writes, so a change that
    // did not come through this cubit still reaches the console.
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    when(
      () => repository.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((call) {
      monitorModes[call.namedArguments[#input] as int] =
          call.namedArguments[#mode] as MonitorMode;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorOutput(
        input: any(named: 'input'),
        mask: any(named: 'mask'),
      ),
    ).thenAnswer((call) {
      monitorOutputs[call.namedArguments[#input] as int] =
          call.namedArguments[#mask] as int;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorVolume(
        input: any(named: 'input'),
        volume: any(named: 'volume'),
      ),
    ).thenAnswer((call) {
      monitorVolumes[call.namedArguments[#input] as int] =
          call.namedArguments[#volume] as double;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorMute(
        input: any(named: 'input'),
        muted: any(named: 'muted'),
      ),
    ).thenAnswer((call) {
      monitorMutes[call.namedArguments[#input] as int] =
          call.namedArguments[#muted] as bool;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
      ),
    ).thenAnswer((call) {
      monitorChains[call.namedArguments[#input] as int] = List.of(
        call.namedArguments[#effects] as List<TrackEffect>,
      );
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
        chainEnabled: any(named: 'chainEnabled'),
        allowUnavailable: true,
      ),
    ).thenAnswer((call) {
      final input = call.namedArguments[#input] as int;
      monitorChains[input] = List.of(
        call.namedArguments[#effects] as List<TrackEffect>,
      );
      monitorChainFlags[input] = call.namedArguments[#chainEnabled] as bool;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorChainEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenAnswer((call) {
      monitorChainFlags[call.namedArguments[#input] as int] =
          call.namedArguments[#enabled] as bool;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorEffectParam(
        input: any(named: 'input'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((call) {
      final input = call.namedArguments[#input] as int;
      final index = call.namedArguments[#index] as int;
      final parameter = call.namedArguments[#param] as int;
      final chain = List.of(repository.monitorEffects(input));
      final effect = chain[index] as BuiltInEffect;
      final params = List.of(effect.params);
      params[parameter] = call.namedArguments[#value] as double;
      chain[index] = effect.copyWith(params: params);
      monitorChains[input] = chain;
      return EngineResult.ok;
    });
    when(
      () => repository.setMonitorPluginParam(
        input: any(named: 'input'),
        index: any(named: 'index'),
        paramId: any(named: 'paramId'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.openMonitorPluginEditor(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.closeMonitorPluginEditor(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.refreshMonitorPluginParams(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(false);
    when(
      () => repository.isMonitorPluginEditorOpen(
        input: any(named: 'input'),
        index: any(named: 'index'),
      ),
    ).thenReturn(true);
  });

  group('real monitor mute admission', () {
    late _RefusingMuteEngine engine;
    late _FailingMuteStore store;
    late LooperRepository live;
    late SettingsRepository saved;
    late MixSettingsCoordinator mix;
    late FxChainPersistence fx;

    setUp(() {
      engine = _RefusingMuteEngine();
      store = _FailingMuteStore();
      live = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      saved = SettingsRepository(store: store);
      mix = testMixSettings(live, settings: saved);
      fx = FxChainPersistence(looper: live);
    });

    tearDown(() async {
      store.failMute = false;
      await fx.close();
      await mix.close();
      await live.dispose();
    });

    MonitorCubit buildLive() => MonitorCubit(
      repository: live,
      settings: saved,
      mixSettings: mix,
      fxPersistence: fx,
    );

    for (final shared in [false, true]) {
      final encoded = encodeFxChain(
        FxChainEnvelope(
          entries: [
            BuiltInEffect(
              type: TrackEffectType.drive,
              slotId: 'saved-monitor',
              params: const [.7, .4, .5, 0],
            ),
          ],
          chainEnabled: false,
        ),
      );
      blocTest<MonitorCubit, MonitorState>(
        'mute after failed restore preserves unrelated monitor settings '
        '(shared: $shared)',
        setUp: () async {
          await saved.saveMonitorInputMode(0, mode: 'on');
          await saved.saveMonitorOutput(0, 1);
          await saved.saveMonitorMute(0, muted: true);
          await saved.saveMonitorEffects(0, encoded);
          engine.refuseMute = true;
        },
        build: buildLive,
        act: (cubit) async {
          await cubit.load();
          expect(cubit.state.inputs, isEmpty);
          expect(cubit.state.restoreFailed, isTrue);
          expect(live.monitorMode(0), MonitorMode.off);
          expect(live.monitorOutput(0), 3);
          expect(live.monitorEffects(0), isEmpty);
          engine.refuseMute = false;
          Future<void> mute({required bool muted}) => shared
              ? applyMonitorMute(
                  repository: live,
                  settings: saved,
                  persistence: fx,
                  input: 0,
                  muted: muted,
                )
              : cubit.setMute(0, muted: muted);
          await mute(muted: true);
          await fx.flush();
          expect(engine.monitorMute[0], isTrue);
          expect(await saved.loadMonitorMute(0), isTrue);
          expect(
            (
              await saved.loadMonitorInputMode(0),
              await saved.loadMonitorOutput(0),
              await saved.loadMonitorEffects(0),
            ),
            ('on', 1, encoded),
          );
          store.failMute = true;
          await expectLater(mute(muted: false), throwsStateError);
          expect(live.monitorMuted(0), isFalse);
          expect(await saved.loadMonitorMute(0), isTrue);
          await expectLater(fx.flush(), throwsStateError);
          store.failMute = false;
          await fx.flush();
          expect(await saved.loadMonitorMute(0), isFalse);
          expect(
            (
              await saved.loadMonitorInputMode(0),
              await saved.loadMonitorOutput(0),
              await saved.loadMonitorEffects(0),
            ),
            ('on', 1, encoded),
          );
          if (shared) {
            // Explicit Retry must reread the now-confirmed false mute, not the
            // original true value from the failed startup attempt.
            expect(cubit.state.restoreFailed, isTrue);
            await cubit.load();
            expect(cubit.state.restoreFailed, isFalse);
            final restored = cubit.state.forInput(0);
            expect(restored, live.allMonitors()[0]);
            expect(restored.mode, MonitorMode.on);
            expect(restored.outputMask, 1);
            expect(restored.muted, isFalse);
            expect(restored.chainEnabled, isFalse);
            expect(restored.effects.single.slotId, 'saved-monitor');
            expect(engine.monitorInputEnabled[0], isTrue);
            expect(engine.monitorOutput[0], 1);
            expect(engine.monitorMute[0], isFalse);
            final recipe = engine.fxRecipes[(FxOwner.monitor, 0, 0)]!;
            expect(recipe.enabled, isFalse);
            expect(recipe.slots.single.type.name, 'drive');
            expect(recipe.slots.single.params, [.7, .4, .5, 0]);
            expect(await saved.loadMonitorMute(0), isFalse);
            expect(
              (
                await saved.loadMonitorInputMode(0),
                await saved.loadMonitorOutput(0),
                await saved.loadMonitorEffects(0),
              ),
              ('on', 1, encoded),
            );
          }
        },
        errors: () => allOf(isNotEmpty, everyElement(isA<StateError>())),
      );
    }

    test('monitor mute retains an earlier failed full-envelope save', () async {
      final effect = BuiltInEffect(
        type: TrackEffectType.drive,
        slotId: 'retry-monitor',
        params: const [.6, .4, .5, 0],
      );
      live
        ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
        ..setMonitorOutput(input: 0, mask: 2)
        ..setMonitorEffects(input: 0, effects: [effect], chainEnabled: false);
      store.failMute = true;
      await expectLater(
        saveFxOwner(
          settings: saved,
          projection: fx,
          address: const FxAddress(stage: FxStage.input),
        ),
        throwsStateError,
      );
      expect(await saved.loadMonitorEffects(0), isNull);
      store.failMute = false;
      await applyMonitorMute(
        repository: live,
        settings: saved,
        persistence: fx,
        input: 0,
        muted: true,
      );
      await fx.flush();
      expect(await saved.loadMonitorMute(0), isTrue);
      expect(await saved.loadMonitorInputMode(0), 'on');
      expect(await saved.loadMonitorOutput(0), 2);
      final chain = decodeFxChain(await saved.loadMonitorEffects(0));
      expect(chain.entries, [effect]);
      expect(chain.chainEnabled, isFalse);
    });

    for (final fxFirst in [true, false]) {
      test('monitor FX and mute overlap without loss during close '
          '(FX first: $fxFirst)', () async {
        final effect = BuiltInEffect(
          type: TrackEffectType.drive,
          slotId: 'live-monitor',
          params: const [.8, .4, .5, 0],
        );
        live
          ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
          ..setMonitorOutput(input: 0, mask: 2)
          ..setMonitorEffects(input: 0, effects: [effect], chainEnabled: false);
        store.blockedKey = fxFirst ? 'monitor_fx.0' : 'monitor_mute.0';
        Future<void> saveFx() => saveFxOwner(
          settings: saved,
          projection: fx,
          address: const FxAddress(stage: FxStage.input),
        );
        Future<void> mute() => applyMonitorMute(
          repository: live,
          settings: saved,
          persistence: fx,
          input: 0,
          muted: true,
        );
        final first = fxFirst ? saveFx() : mute();
        await store.entered.future;
        final second = fxFirst ? mute() : saveFx();
        final closing = fx.close();
        store.release.complete();
        await Future.wait([first, second, closing]);
        expect(await saved.loadMonitorMute(0), isTrue);
        expect(await saved.loadMonitorInputMode(0), 'on');
        expect(await saved.loadMonitorOutput(0), 2);
        final chain = decodeFxChain(await saved.loadMonitorEffects(0));
        expect(chain.entries, [effect]);
        expect(chain.chainEnabled, isFalse);
      });
    }

    blocTest<MonitorCubit, MonitorState>(
      'refused mute stays absent from view and unrelated saves; retry persists',
      build: buildLive,
      act: (cubit) async {
        await cubit.load();
        await cubit.setMode(0, MonitorMode.on);
        await cubit.setMute(0, muted: false);
        await fx.flush();
        final announcements = <int>[];
        final watch = live.monitorChanges.listen(announcements.add);
        engine.refuseMute = true;
        await expectLater(cubit.setMute(0, muted: true), throwsStateError);
        await pumpEventQueue();
        expect(announcements, isEmpty);
        expect(engine.monitorMute[0], isFalse);
        expect(live.monitorMuted(0), isFalse);
        expect(cubit.state.forInput(0).muted, isFalse);
        expect(await saved.loadMonitorMute(0), isFalse);
        await cubit.setOutputMask(0, 1);
        await fx.flush();
        expect(await saved.loadMonitorMute(0), isFalse);
        await watch.cancel();
        engine.refuseMute = false;
        await cubit.setMute(0, muted: true);
        await fx.flush();
        expect(engine.monitorMute[0], isTrue);
        expect(live.monitorMuted(0), isTrue);
        expect(cubit.state.forInput(0).muted, isTrue);
        expect(await saved.loadMonitorMute(0), isTrue);
        live.stopEngine();
        engine.monitorMute.clear();
        expect(live.startEngine(const EngineConfig()), EngineResult.ok);
        expect(engine.monitorMute[0], isTrue);
      },
      errors: () => [isA<StateError>()],
    );

    blocTest<MonitorCubit, MonitorState>(
      'accepted mute control persists while stopped and replays at start',
      build: buildLive,
      act: (cubit) async {
        await cubit.load();
        live.stopEngine();
        await cubit.setMute(0, muted: true);
        await fx.flush();
        expect(engine.monitorMute[0], isNull);
        expect(live.monitorMuted(0), isTrue);
        expect(cubit.state.forInput(0).muted, isTrue);
        expect(await saved.loadMonitorMute(0), isTrue);
        expect(live.startEngine(const EngineConfig()), EngineResult.ok);
        expect(engine.monitorMute[0], isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'accepted mute survives storage refusal and explicit flush retries',
      build: buildLive,
      act: (cubit) async {
        await cubit.load();
        await cubit.setMute(0, muted: false);
        await fx.flush();
        store.failMute = true;
        await expectLater(cubit.setMute(0, muted: true), throwsStateError);
        await pumpEventQueue();
        expect(engine.monitorMute[0], isTrue);
        expect(live.monitorMuted(0), isTrue);
        expect(cubit.state.forInput(0).muted, isTrue);
        expect(await saved.loadMonitorMute(0), isFalse);
        await expectLater(fx.flush(), throwsStateError);
        store.failMute = false;
        await fx.flush();
        expect(await saved.loadMonitorMute(0), isTrue);
      },
      errors: () => allOf(isNotEmpty, everyElement(isA<StateError>())),
    );

    blocTest<MonitorCubit, MonitorState>(
      'restore refuses mute before enabling, routing or applying saved effects',
      setUp: () async {
        await saved.saveMonitorInputMode(0, mode: 'on');
        await saved.saveMonitorOutput(0, 1);
        await saved.saveMonitorMute(0, muted: true);
        await saved.saveMonitorEffects(
          0,
          encodeFxChain(
            FxChainEnvelope(
              entries: [
                BuiltInEffect(type: TrackEffectType.drive),
              ],
            ),
          ),
        );
        engine.refuseMute = true;
      },
      build: buildLive,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(engine.monitorInputEnabled, isEmpty);
        expect(engine.monitorOutput, isEmpty);
        expect(live.monitorMode(0), MonitorMode.off);
        expect(live.monitorOutput(0), 3);
        expect(cubit.state.inputs, isEmpty);
        expect(live.monitorMuted(0), isFalse);
        expect(live.monitorEffects(0), isEmpty);
      },
      errors: () => [isA<StateError>()],
    );

    for (final mode in [MonitorMode.off, MonitorMode.on]) {
      blocTest<MonitorCubit, MonitorState>(
        'restore ${mode.name} unmutes only after mode and replacement route',
        setUp: () async {
          live
            ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
            ..setMonitorOutput(input: 0, mask: 1)
            ..setMonitorMute(input: 0, muted: true);
          await saved.saveMonitorInputMode(0, mode: mode.name);
          await saved.saveMonitorOutput(0, 2);
          await saved.saveMonitorMute(0, muted: false);
          engine.monitorSteps.clear();
        },
        build: buildLive,
        act: (cubit) => cubit.load(),
        verify: (cubit) {
          expect(engine.monitorSteps, isNotEmpty);
          for (final step in engine.monitorSteps) {
            if (step.enabled && !step.muted) {
              expect(mode, MonitorMode.on);
              expect(step.output, 2);
            }
          }
          expect(engine.monitorSteps.last, (
            enabled: mode == MonitorMode.on,
            muted: false,
            output: 2,
          ));
          expect(cubit.state.forInput(0).muted, isFalse);
        },
      );
    }

    blocTest<MonitorCubit, MonitorState>(
      'closed monitor cannot submit a new mute',
      build: buildLive,
      act: (cubit) async {
        await cubit.close();
        await cubit.setMute(0, muted: true);
        expect(live.monitorMuted(0), isFalse);
        expect(engine.monitorMute, isEmpty);
        expect(await saved.loadMonitorMute(0), isNull);
      },
    );
  });

  /// Writes through with no debounce, so a test's assertion does not have to
  /// outlive a pending write. The debounce itself is covered in its own group.
  MonitorCubit build() => MonitorCubit(
    fxPersistence: FxChainPersistence(looper: repository),
    mixSettings: testMixSettings(repository, settings: settings),
    repository: repository,
    settings: settings,
    fxPersistDebounce: Duration.zero,
  );

  blocTest<MonitorCubit, MonitorState>(
    'invalid saved gain reports load error before any monitor mutation',
    setUp: () {
      final store = FakeKeyValueStore();
      store.values.addAll({
        'mix_settings': '{"monitorLevels":{"0":0.5,"1":1.5}}',
        'monitor_input_mode.0': 'on',
        'monitor_output.0': 3,
      });
      settings = SettingsRepository(store: store);
    },
    build: build,
    act: (cubit) => cubit.load(),
    expect: () => [const MonitorState(restoreFailed: true)],
    errors: () => [isA<FormatException>()],
    verify: (_) {
      verifyNever(
        () => repository.setMonitorInputMode(
          input: any(named: 'input'),
          mode: any(named: 'mode'),
        ),
      );
      verifyNever(
        () => repository.setMonitorOutput(
          input: any(named: 'input'),
          mask: any(named: 'mask'),
        ),
      );
      verifyNever(
        () => repository.setMonitorMute(
          input: any(named: 'input'),
          muted: any(named: 'muted'),
        ),
      );
      verifyNever(
        () => repository.setMonitorEffects(
          input: any(named: 'input'),
          effects: any(named: 'effects'),
          chainEnabled: any(named: 'chainEnabled'),
          allowUnavailable: any(named: 'allowUnavailable'),
        ),
      );
    },
  );

  test('an input route edit outlives an earlier blocked FX save', () async {
    final store = _BlockedMonitorModeStore();
    settings = SettingsRepository(store: store);
    final cubit = build();
    addTearDown(cubit.close);
    cubit.addEffect(0);
    await store.entered.future;
    final route = cubit.setOutputMask(0, 4);
    store.release.complete();
    await route;
    await cubit.flushPersistence();
    expect(await settings.loadMonitorOutput(0), 4);
    expect(
      decodeFxChain(await settings.loadMonitorEffects(0)).entries,
      hasLength(1),
    );
  });

  group('following the repository', () {
    late StreamController<int> changes;

    setUp(() {
      changes = StreamController<int>.broadcast();
      addTearDown(changes.close);
      when(() => repository.monitorChanges).thenAnswer((_) => changes.stream);
      // Answers that REMEMBER what was written to them, the way the real
      // repository does — the cubit's restore pushes the saved monitors in,
      // and a follow that read a fixture frozen at the defaults would report
      // a clobbering that only the fixture was doing. Everything starts where
      // the cubit's own defaults are, so a test only sees what it changes.
      final modes = <int, MonitorMode>{};
      final volumes = <int, double>{};
      final masks = <int, int>{};
      final mutes = <int, bool>{};
      when(() => repository.monitorMode(any())).thenAnswer(
        (call) => modes[call.positionalArguments.first] ?? MonitorMode.off,
      );
      when(() => repository.monitorOutput(any())).thenAnswer(
        (call) => masks[call.positionalArguments.first] ?? 0x3,
      );
      when(() => repository.monitorVolume(any())).thenAnswer(
        (call) => volumes[call.positionalArguments.first] ?? 1.0,
      );
      when(
        () => repository.setMixSettings(
          trackPans: any(named: 'trackPans'),
          inputSetup: any(named: 'inputSetup'),
          monitorLevels: any(named: 'monitorLevels'),
        ),
      ).thenAnswer((call) {
        volumes.addAll(
          call.namedArguments[#monitorLevels] as Map<int, double>,
        );
        return EngineResult.ok;
      });
      when(() => repository.monitorMuted(any())).thenAnswer(
        (call) => mutes[call.positionalArguments.first] ?? false,
      );
      when(() => repository.monitorChainEnabled(any())).thenReturn(true);
      when(
        () => repository.setMonitorInputMode(
          input: any(named: 'input'),
          mode: any(named: 'mode'),
        ),
      ).thenAnswer((call) {
        modes[call.namedArguments[#input] as int] =
            call.namedArguments[#mode] as MonitorMode;
        return EngineResult.ok;
      });
      when(
        () => repository.setMonitorVolume(
          input: any(named: 'input'),
          volume: any(named: 'volume'),
        ),
      ).thenAnswer((call) {
        volumes[call.namedArguments[#input] as int] =
            call.namedArguments[#volume] as double;
        return EngineResult.ok;
      });
      when(
        () => repository.setMonitorOutput(
          input: any(named: 'input'),
          mask: any(named: 'mask'),
        ),
      ).thenAnswer((call) {
        masks[call.namedArguments[#input] as int] =
            call.namedArguments[#mask] as int;
        return EngineResult.ok;
      });
      when(
        () => repository.setMonitorMute(
          input: any(named: 'input'),
          muted: any(named: 'muted'),
        ),
      ).thenAnswer((call) {
        mutes[call.namedArguments[#input] as int] =
            call.namedArguments[#muted] as bool;
        return EngineResult.ok;
      });
    });

    test(
      'an announce before the restore does not save over saved state',
      () async {
        // What the player set, last session.
        await settings.saveMonitorInputMode(1, mode: MonitorMode.on.name);
        await settings.saveMonitorVolume(1, 0.5);
        final cubit = build();
        addTearDown(cubit.close);

        // Announced while the restore is still in flight: the repository does
        // not hold the saved monitors yet — this cubit is what puts them there
        // — so reading it now would take its defaults as truth and SAVE them
        // over the settings that have not been read yet. Silent, permanent, and
        // only visible on the next boot.
        // A session applied in the first frames: the repository now differs
        // from this cubit's defaults, which is what makes the read do
        // anything at all.
        when(() => repository.monitorChainEnabled(1)).thenReturn(false);
        changes.add(1);
        // Long enough for the read's own five-key save to land: what it
        // WRITES is the damage, and a restore racing ahead of that would read
        // the good settings by luck rather than by design.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await cubit.load();

        expect(cubit.state.forInput(1).mode, MonitorMode.on);
        expect(cubit.state.forInput(1).volume, 0.5);
        expect(await settings.loadMonitorInputMode(1), MonitorMode.on.name);
        expect(await settings.loadMonitorVolume(1), 0.5);
      },
    );

    test(
      'an input announced during the restore is read once it lands',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        when(() => repository.monitorChainEnabled(2)).thenReturn(false);

        // Held, not dropped: a session applied in the first frames is a real
        // change, and the console has to end up showing it.
        changes.add(2);
        await Future<void>.delayed(Duration.zero);
        await cubit.load();
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.forInput(2).chainEnabled, isFalse);
      },
    );

    test('a closed cubit stops listening', () async {
      final cubit = build();
      await cubit.load();
      await cubit.close();

      changes.add(0);
      await Future<void>.delayed(Duration.zero);

      // Not just silent — off the stream. A closed cubit that is still a
      // listener keeps its whole object graph alive for as long as the
      // repository lives, and this cubit outlives nothing.
      expect(changes.hasListener, isFalse);
    });

    test(
      'a mode announce cannot persist an earlier pending FX recipe',
      () async {
        final oldFx = BuiltInEffect(type: TrackEffectType.drive);
        final newFx = BuiltInEffect(type: TrackEffectType.reverb);
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(FxChainEnvelope(entries: [oldFx])),
        );
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        final applied = Completer<EngineResult>();
        var settled = false;
        when(() => repository.fxRecipesSettled).thenAnswer((_) => settled);
        when(
          () => repository.settleFxRecipes(
            waitForCallback: true,
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) => applied.future);
        when(() => repository.monitorEffects(0)).thenReturn([newFx]);

        changes.add(0); // admitted structural recipe
        await Future<void>.delayed(Duration.zero);
        when(() => repository.monitorMode(0)).thenReturn(MonitorMode.on);
        changes.add(0); // unrelated mode change while FX remains pending
        await Future<void>.delayed(Duration.zero);
        expect(
          decodeFxChain(await settings.loadMonitorEffects(0)).entries,
          [oldFx],
        );

        settled = true;
        applied.complete(EngineResult.ok);
        await pumpEventQueue();
        expect(
          decodeFxChain(await settings.loadMonitorEffects(0)).entries,
          [newFx],
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a chain switched off elsewhere reaches the console',
      build: build,
      // The state `load` emits on the way in; every test here is about what
      // comes AFTER it.
      skip: 1,
      act: (cubit) async {
        await cubit.load();
        // What a footswitch bound to an `FxStage.input` chain does: it writes
        // straight to the repository, past this cubit, and a monitor is not
        // in the projection that corrects every other stage.
        when(() => repository.monitorChainEnabled(0)).thenReturn(false);
        changes.add(0);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.forInput(0).chainEnabled,
          'chainEnabled',
          isFalse,
        ),
      ],
    );

    blocTest<MonitorCubit, MonitorState>(
      'every monitor fact is re-read, not just the chain',
      build: build,
      skip: 1,
      act: (cubit) async {
        await cubit.load();
        when(() => repository.monitorMuted(1)).thenReturn(true);
        when(() => repository.monitorVolume(1)).thenReturn(0.25);
        when(() => repository.monitorOutput(1)).thenReturn(0x2);
        when(() => repository.monitorMode(1)).thenReturn(MonitorMode.auto);
        when(
          () => repository.monitorEffects(1),
        ).thenReturn([BuiltInEffect(type: TrackEffectType.drive)]);
        changes.add(1);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        isA<MonitorState>()
            .having((s) => s.forInput(1).muted, 'muted', isTrue)
            .having((s) => s.forInput(1).volume, 'volume', 0.25)
            .having((s) => s.forInput(1).outputMask, 'outputMask', 0x2)
            .having((s) => s.forInput(1).mode, 'mode', MonitorMode.auto)
            .having((s) => s.forInput(1).effects, 'effects', hasLength(1)),
      ],
    );

    blocTest<MonitorCubit, MonitorState>(
      'a change that changes nothing does not rebuild the console',
      build: build,
      skip: 1,
      act: (cubit) async {
        await cubit.load();
        // Every write from this cubit comes back through the same stream, so
        // an unconditional emit would double every edit the surface makes.
        changes
          ..add(0)
          ..add(0);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => <MonitorState>[],
    );

    blocTest<MonitorCubit, MonitorState>(
      'what it reads is saved, and never pushed back',
      build: build,
      act: (cubit) async {
        await cubit.load();
        when(() => repository.monitorChainEnabled(0)).thenReturn(false);
        changes.add(0);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) async {
        // Never back to the engine: the repository is where this came from,
        // and pushing it back is this cubit re-applying the state the
        // engine's owner just set.
        verifyNever(
          () => repository.setMonitorChainEnabled(
            input: any(named: 'input'),
            enabled: any(named: 'enabled'),
          ),
        );
        // But saved — because the persisted envelope is built from this
        // state. Read and NOT saved, the flag would still ride into settings
        // on the next unrelated edit of that chain, so a footswitch bypass
        // would survive a restart if and only if the player happened to touch
        // the chain afterwards.
        final saved = decodeFxChain(await settings.loadMonitorEffects(0));
        expect(saved.chainEnabled, isFalse);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a chain that changed shape drops the editor polls keyed to the old one',
      build: build,
      act: (cubit) async {
        await cubit.load();
        when(() => repository.monitorEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
            slotId: 'a',
          ),
        ]);
        changes.add(0);
        await Future<void>.delayed(Duration.zero);
        cubit.openPluginEditor(0, 0);
        // A different entry in the same slot index: a poll still keyed to it
        // would start syncing a plugin the player never opened.
        when(() => repository.monitorEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'q'),
            slotId: 'b',
          ),
        ]);
        changes.add(0);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      },
      verify: (_) async {
        verifyNever(
          () => repository.refreshMonitorPluginParams(
            input: any(named: 'input'),
            index: any(named: 'index'),
          ),
        );
      },
    );
  });

  group('following the param stream', () {
    late StreamController<int> params;

    setUp(() {
      params = StreamController<int>.broadcast();
      addTearDown(params.close);
      when(
        () => repository.monitorParamChanges,
      ).thenAnswer((_) => params.stream);
      when(() => repository.monitorMode(any())).thenReturn(MonitorMode.off);
      when(() => repository.monitorOutput(any())).thenReturn(0x3);
      when(() => repository.monitorVolume(any())).thenReturn(1);
      when(() => repository.monitorMuted(any())).thenReturn(false);
      when(() => repository.monitorChainEnabled(any())).thenReturn(true);
    });

    blocTest<MonitorCubit, MonitorState>(
      'a swept param reaches the knob without a structural change',
      build: build,
      skip: 1,
      act: (cubit) async {
        await cubit.load();
        // What a CC bound to an `FxStage.input` param does: it writes
        // straight to the repository at controller rate, and the repository
        // announces on the throttled param stream — never the structural one.
        when(() => repository.monitorEffects(0)).thenReturn([
          BuiltInEffect(
            type: TrackEffectType.drive,
            params: const [0.7, 0.5],
          ),
        ]);
        params.add(0);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        isA<MonitorState>().having(
          (s) => (s.forInput(0).effects.single as BuiltInEffect).params.first,
          'swept param',
          0.7,
        ),
      ],
    );

    blocTest<MonitorCubit, MonitorState>(
      'a param-only announce persists nothing and writes nothing back',
      build: build,
      act: (cubit) async {
        await cubit.load();
        when(() => repository.monitorEffects(0)).thenReturn([
          BuiltInEffect(
            type: TrackEffectType.drive,
            params: const [0.7, 0.5],
          ),
        ]);
        params.add(0);
        // Long enough for a persist to have landed, were one issued.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (_) async {
        // The deliberate half of #605: a swept value arrives at up to 10 Hz
        // for the length of the sweep, and the editor-sync poll (the other
        // follower of live param motion) does not persist either. The value
        // still reaches settings with the next structural announce or edit.
        expect(await settings.loadMonitorEffects(0), isNull);
        // And never back to the engine — the repository is where it came
        // from.
        verifyNever(
          () => repository.setMonitorEffectParam(
            input: any(named: 'input'),
            index: any(named: 'index'),
            param: any(named: 'param'),
            value: any(named: 'value'),
          ),
        );
        verifyNever(
          () => repository.setMonitorEffects(
            input: any(named: 'input'),
            effects: any(named: 'effects'),
          ),
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'an announce with nothing applied does not wipe the console chain',
      build: build,
      skip: 1,
      act: (cubit) async {
        await cubit.load();
        cubit.addEffect(0);
        // The repository reports no chain (engine not running / a fake): a
        // param announce must not read that emptiness as a clear.
        when(() => repository.monitorEffects(0)).thenReturn(const []);
        params.add(0);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.forInput(0).effects,
          'effects',
          hasLength(1),
        ),
      ],
    );

    test('an announce before the restore is dropped, not read', () async {
      final cubit = build();
      addTearDown(cubit.close);
      when(() => repository.monitorEffects(0)).thenReturn([
        BuiltInEffect(type: TrackEffectType.drive, params: const [0.7, 0.5]),
      ]);

      // The restore has not marked the repository authoritative yet — and by
      // the time it does, it has pushed the SAVED chain over this one, so
      // there is nothing a held read could recover.
      params.add(0);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.inputs, isEmpty);
    });

    test('a closed cubit stops listening', () async {
      final cubit = build();
      await cubit.load();
      await cubit.close();

      params.add(0);
      await Future<void>.delayed(Duration.zero);

      expect(params.hasListener, isFalse);
    });
  });

  group('MonitorCubit', () {
    test('defaults to no configured inputs (disabled, clean chain)', () {
      final cubit = build();
      expect(cubit.state.inputs, isEmpty);
      expect(cubit.state.forInput(0).mode, MonitorMode.off);
      expect(cubit.state.forInput(0).outputMask, 0x3);
      expect(cubit.state.forInput(0).volume, 1.0);
      expect(cubit.state.forInput(0).effects, isEmpty);
    });

    blocTest<MonitorCubit, MonitorState>(
      'setMode opens an input, applies it, and persists',
      build: build,
      act: (cubit) => cubit.setMode(0, MonitorMode.on),
      expect: () => [
        isA<MonitorState>().having(
          (s) => s.forInput(0).mode,
          'mode',
          MonitorMode.on,
        ),
      ],
      verify: (_) async {
        verify(
          () => repository.setMonitorInputMode(input: 0, mode: MonitorMode.on),
        ).called(1);
        expect(await settings.loadMonitorInputMode(0), 'on');
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setOutputMask updates, applies, and persists the chain output mask',
      build: build,
      act: (cubit) async {
        await cubit.setMode(1, MonitorMode.on);
        await cubit.setOutputMask(1, 0x2);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(1).outputMask, 0x2);
        verify(
          () => repository.setMonitorOutput(input: 1, mask: 0x2),
        ).called(1);
        expect(await settings.loadMonitorOutput(1), 0x2);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setVolume updates, applies, and persists the gain',
      build: build,
      act: (cubit) async {
        await cubit.setMode(0, MonitorMode.on);
        await cubit.setVolume(0, 0.5);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).volume, 0.5);
        verify(() => repository.applyMixSettings(any())).called(1);
        expect(await settings.loadMonitorVolume(0), 0.5);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a refused monitor volume leaves state and storage at the prior gain',
      setUp: () {
        when(
          () => repository.applyMixSettings(any()),
        ).thenReturn(EngineResult.notReady);
      },
      build: build,
      act: (cubit) async {
        await settings.saveMonitorVolume(0, 0.75);
        await cubit.setVolume(0, 0.5);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).volume, 1);
        expect(await settings.loadMonitorVolume(0), 0.75);
        verifyNever(() => repository.settleMixSettings());
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a failed monitor publication leaves state and storage unchanged',
      setUp: () {
        when(
          () => repository.settleMixSettings(),
        ).thenAnswer((_) async => EngineResult.invalid);
      },
      build: build,
      act: (cubit) async {
        await settings.saveMonitorVolume(0, 0.75);
        await cubit.setVolume(0, 0.5);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).volume, 1);
        expect(await settings.loadMonitorVolume(0), 0.75);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'setMute mutes the input chain',
      build: build,
      act: (cubit) async {
        await cubit.setMode(0, MonitorMode.on);
        await cubit.setMute(0, muted: true);
      },
      verify: (cubit) async {
        expect(cubit.state.forInput(0).muted, isTrue);
        verify(
          () => repository.setMonitorMute(input: 0, muted: true),
        ).called(1);
        expect(await settings.loadMonitorMute(0), isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'inputs are independent of one another',
      build: build,
      act: (cubit) async {
        await cubit.setMode(0, MonitorMode.on);
        await cubit.setMode(1, MonitorMode.on);
        await cubit.setMode(0, MonitorMode.off);
      },
      verify: (cubit) {
        expect(cubit.state.forInput(0).mode, MonitorMode.off);
        expect(cubit.state.forInput(1).mode, MonitorMode.on);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load restores a chain-DISABLED envelope and pushes the flag '
      '(R15/D-CHAINDIS)',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            FxChainEnvelope(
              chainEnabled: false,
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          ),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.chainEnabled, isFalse);
        expect(monitor.effects, hasLength(1));
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
            chainEnabled: false,
            allowUnavailable: true,
          ),
        ).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a chain-DISABLED envelope with EMPTY entries still counts as saved '
      'state — the flag survives the restart (R15)',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(const FxChainEnvelope(chainEnabled: false)),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.inputs, contains(0));
        expect(cubit.state.forInput(0).chainEnabled, isFalse);
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
            chainEnabled: false,
            allowUnavailable: true,
          ),
        ).called(1);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a persisted chain re-encodes as the envelope carrying the chain flag',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            FxChainEnvelope(
              chainEnabled: false,
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          ),
        );
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        // A param tweak re-persists the chain; the disabled flag must ride.
        cubit.setEffectParam(0, 0, 0, 0.9);
      },
      verify: (cubit) async {
        final decoded = decodeFxChain(await settings.loadMonitorEffects(0));
        expect(decoded.chainEnabled, isFalse);
        expect(
          ((decoded.entries.single) as BuiltInEffect).params.first,
          0.9,
        );
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load restores single-chain state from the keys, applying it',
      setUp: () async {
        await settings.saveMonitorInputMode(0, mode: 'on');
        await settings.saveMonitorOutput(0, 0x2);
        await settings.saveMonitorVolume(0, 0.4);
        await settings.saveMonitorMute(0, muted: true);
        await settings.saveMonitorEffects(
          0,
          encodeTrackEffects([BuiltInEffect(type: TrackEffectType.delay)]),
        );
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        final monitor = cubit.state.forInput(0);
        expect(monitor.mode, MonitorMode.on);
        expect(monitor.outputMask, 0x2);
        expect(monitor.volume, 0.4);
        expect(monitor.muted, isTrue);
        expect(
          (monitor.effects.single as BuiltInEffect).type,
          TrackEffectType.delay,
        );
        verify(
          () => repository.setMonitorInputMode(input: 0, mode: MonitorMode.on),
        ).called(1);
        verify(
          () => repository.setMonitorOutput(input: 0, mask: 0x2),
        ).called(1);
        verify(
          () => repository.setMixSettings(
            trackPans: const {},
            inputSetup: const InputSetup.empty(),
            monitorLevels: const {0: 0.4},
          ),
        ).called(1);
        verify(
          () => repository.setMonitorMute(input: 0, muted: true),
        ).called(1);
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
            chainEnabled: true,
            allowUnavailable: true,
          ),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'load restores multiple monitor levels in one confirmed mix request',
      setUp: () async {
        await settings.saveMonitorVolume(0, 0.4);
        await settings.saveMonitorVolume(1, 0.6);
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.forInput(0).volume, 0.4);
        expect(cubit.state.forInput(1).volume, 0.6);
        verify(
          () => repository.setMixSettings(
            trackPans: const {},
            inputSetup: const InputSetup.empty(),
            monitorLevels: const {0: 0.4, 1: 0.6},
          ),
        ).called(1);
        verifyNever(
          () => repository.setMonitorVolume(
            input: any(named: 'input'),
            volume: any(named: 'volume'),
          ),
        );
      },
    );

    group('projectFromRepository', () {
      blocTest<MonitorCubit, MonitorState>(
        're-projects repository monitors without persisting them',
        setUp: () {
          when(repository.allMonitors).thenReturn({
            2: InputMonitor(
              input: 2,
              mode: MonitorMode.on,
              outputMask: 0x2,
              volume: 0.4,
              muted: true,
              effects: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          });
        },
        build: build,
        act: (cubit) => cubit.projectFromRepository(),
        verify: (cubit) async {
          final monitor = cubit.state.forInput(2);
          expect(monitor.mode, MonitorMode.on);
          expect(monitor.outputMask, 0x2);
          expect(monitor.volume, 0.4);
          expect(monitor.muted, isTrue);
          expect(
            (monitor.effects.single as BuiltInEffect).type,
            TrackEffectType.delay,
          );
          // The new session's boot image is a separate application write.
          expect(await settings.loadMonitorInputMode(2), isNull);
          expect(await settings.loadMonitorOutput(2), isNull);
          expect(await settings.loadMonitorVolume(2), isNull);
          expect(await settings.loadMonitorMute(2), isNull);
          expect(await settings.loadMonitorEffects(2), isNull);
          // The load already applied to the engine; the re-sync only READS the
          // repository — it must never push back, or it could desync the two.
          verifyNever(
            () => repository.setMonitorInputMode(
              input: any(named: 'input'),
              mode: any(named: 'mode'),
            ),
          );
          verifyNever(
            () => repository.setMonitorOutput(
              input: any(named: 'input'),
              mask: any(named: 'mask'),
            ),
          );
          verifyNever(
            () => repository.setMonitorVolume(
              input: any(named: 'input'),
              volume: any(named: 'volume'),
            ),
          );
          verifyNever(
            () => repository.setMonitorMute(
              input: any(named: 'input'),
              muted: any(named: 'muted'),
            ),
          );
          verifyNever(
            () => repository.setMonitorEffects(
              input: any(named: 'input'),
              effects: any(named: 'effects'),
            ),
          );
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'drops absent inputs from presentation without changing stored keys',
        setUp: () async {
          // A prior session left input 5 configured (enabled + non-default
          // routing / volume / mute) in settings AND cubit state.
          await settings.saveMonitorInputMode(5, mode: 'on');
          await settings.saveMonitorOutput(5, 0x2);
          await settings.saveMonitorVolume(5, 0.3);
          await settings.saveMonitorMute(5, muted: true);
          await settings.saveMonitorEffects(
            5,
            encodeTrackEffects([BuiltInEffect(type: TrackEffectType.reverb)]),
          );
        },
        build: build,
        // Seed input 5 into state so it counts as "previously present".
        act: (cubit) {
          when(repository.allMonitors).thenReturn(const {
            5: InputMonitor(input: 5, mode: MonitorMode.on),
          });
          cubit.projectFromRepository();
          // The freshly loaded session defines no monitors.
          when(repository.allMonitors).thenReturn(const {});
          cubit.projectFromRepository();
        },
        verify: (cubit) async {
          expect(cubit.state.inputs, isEmpty);
          // A projection cannot clear boot storage; the load owner does that.
          expect(await settings.loadMonitorInputMode(5), 'on');
          expect(await settings.loadMonitorOutput(5), 0x2);
          expect(await settings.loadMonitorVolume(5), 0.3);
          expect(await settings.loadMonitorMute(5), isTrue);
          expect(
            await settings.loadMonitorEffects(5),
            encodeTrackEffects([BuiltInEffect(type: TrackEffectType.reverb)]),
          );
        },
      );
    });

    blocTest<MonitorCubit, MonitorState>(
      "a restored chain takes the repository's answer, not the saved one",
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            const FxChainEnvelope(
              entries: [
                PluginEffect(
                  ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
                  slotId: 'slot-gone',
                ),
              ],
            ),
          ),
        );
        // What the repository made of it while applying: the plugin is not
        // installed any more.
        when(() => repository.monitorEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
            slotId: 'slot-gone',
            unavailable: true,
          ),
        ]);
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        // Decoded settings say nothing about whether a plugin LOADED. Left at
        // the saved answer, the console offers to open the window of a plugin
        // that is not there and never offers to relink the one that is
        // missing — on the one stage where hosting actually happens.
        final entry = cubit.state.forInput(0).effects.single as PluginEffect;
        expect(entry.unavailable, isTrue);
      },
    );

    blocTest<MonitorCubit, MonitorState>(
      'a chain still loading at boot picks up what the scan resolves',
      setUp: () async {
        await settings.saveMonitorEffects(
          0,
          encodeFxChain(
            const FxChainEnvelope(
              entries: [
                PluginEffect(
                  ref: PluginRef(format: PluginFormat.vst3, id: 'late'),
                  slotId: 'slot-late',
                ),
              ],
            ),
          ),
        );
        // The engine starts before the app with a cold plugin cache, so at
        // restore time every hosted entry has just failed to load and is
        // waiting on the repository's own recovery scan.
        when(() => repository.monitorEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'late'),
            slotId: 'slot-late',
            loading: true,
          ),
        ]);
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        expect(
          (cubit.state.forInput(0).effects.single as PluginEffect).loading,
          isTrue,
        );
        // The repository re-applies the chains from the SCAN FUTURE, and the
        // catalog publishes its last progress event before completing that
        // future — so a read hung straight off the event runs a microtask too
        // early and sees the chain still loading, with no later event coming.
        // Modelled here the way the repository does it: a `then` registered
        // before the cubit's own join.
        unawaited(
          catalog.scan().then((_) {
            when(() => repository.monitorEffects(0)).thenReturn(const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.vst3, id: 'late'),
                slotId: 'slot-late',
                name: 'Late',
              ),
            ]);
          }),
        );
        await catalog.scan();
        await pumpEventQueue();
      },
      verify: (cubit) {
        // Nothing tells this cubit that on its own, so a plugin that resolves
        // perfectly well sat in the console reading "loading…" — no
        // parameters, no window, no relink — until somebody edited the chain.
        final entry = cubit.state.forInput(0).effects.single as PluginEffect;
        expect(entry.loading, isFalse);
        expect(entry.name, 'Late');
      },
    );

    group('monitor power controls (D-POWER)', () {
      blocTest<MonitorCubit, MonitorState>(
        'setEffectEnabled flips one slot, pushes it, and re-persists',
        setUp: () {
          // Model the repository: it owns the flag flip across the sealed
          // entry hierarchy, and the cubit re-reads what actually landed.
          var chain = <TrackEffect>[];
          when(() => repository.monitorEffects(0)).thenAnswer((_) => chain);
          when(
            () => repository.setMonitorEffects(
              input: any(named: 'input'),
              effects: any(named: 'effects'),
            ),
          ).thenAnswer((invocation) {
            chain = invocation.namedArguments[#effects] as List<TrackEffect>;
            return EngineResult.ok;
          });
          when(
            () => repository.setMonitorEffectEnabled(
              input: any(named: 'input'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          ).thenAnswer((invocation) {
            final index = invocation.namedArguments[#index] as int;
            final enabled = invocation.namedArguments[#enabled] as bool;
            final fx = chain[index] as BuiltInEffect;
            chain = [...chain]..[index] = fx.copyWith(enabled: enabled);
            return EngineResult.ok;
          });
        },
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectEnabled(0, 0, enabled: false);
        },
        verify: (_) async {
          verify(
            () => repository.setMonitorEffectEnabled(
              input: 0,
              index: 0,
              enabled: false,
            ),
          ).called(1);
          // The flag rides the persisted envelope, not just "something wrote".
          final encoded = await settings.loadMonitorEffects(0);
          expect(decodeFxChain(encoded).entries.single.enabled, isFalse);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setChainEnabled ignores an input with no configured monitor',
        build: build,
        act: (cubit) => cubit.setChainEnabled(3, enabled: false),
        expect: () => <MonitorState>[],
        verify: (_) async {
          // Never materialize (or persist) a monitor the user never created —
          // the restore path would resurrect it on every subsequent boot.
          verifyNever(
            () => repository.setMonitorChainEnabled(
              input: any(named: 'input'),
              enabled: any(named: 'enabled'),
            ),
          );
          expect(await settings.loadMonitorEffects(3), isNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectEnabled ignores an out-of-range slot',
        build: build,
        act: (cubit) => cubit.setEffectEnabled(0, 3, enabled: false),
        expect: () => <MonitorState>[],
        verify: (_) {
          verifyNever(
            () => repository.setMonitorEffectEnabled(
              input: any(named: 'input'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          );
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setChainEnabled flips the whole chain and persists the envelope',
        build: build,
        act: (cubit) => cubit
          // Configure the input first: the flip only applies to a monitor the
          // user actually has (see the phantom-monitor guard).
          ..addEffect(0)
          ..setChainEnabled(0, enabled: false),
        expect: () => [
          isA<MonitorState>(),
          isA<MonitorState>().having(
            (s) => s.forInput(0).chainEnabled,
            'chainEnabled',
            isFalse,
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorChainEnabled(input: 0, enabled: false),
          ).called(1);
          // R15: the flag rides the one monitor-fx key beside the entries.
          final encoded = await settings.loadMonitorEffects(0);
          expect(decodeFxChain(encoded).chainEnabled, isFalse);
        },
      );
    });

    group('monitor effects', () {
      test('new session monitor edit follows a deferred prior save', () async {
        final store = _DeferredMonitorFxStore();
        settings = SettingsRepository(store: store);
        var sessionRevision = 0;
        when(
          () => repository.sessionRevision,
        ).thenAnswer((_) => sessionRevision);
        final cubit = build();
        addTearDown(cubit.close);
        cubit.addEffect(0);
        await store.firstWriteStarted.future;
        sessionRevision = 1;
        cubit.addEffect(0);
        await pumpEventQueue();
        expect(store.fxWrites, 1);
        store.firstWrite.complete();
        await pumpEventQueue();
        expect(store.fxWrites, 2);
        expect(
          decodeFxChain(await settings.loadMonitorEffects(0)).entries,
          hasLength(2),
        );
      });

      blocTest<MonitorCubit, MonitorState>(
        'addEffect appends a default drive, applies, and persists',
        build: build,
        act: (cubit) => cubit.addEffect(0),
        expect: () => [
          isA<MonitorState>().having(
            (s) => (s.forInput(0).effects.single as BuiltInEffect).type,
            'type',
            TrackEffectType.drive,
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
            ),
          ).called(1);
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        "a live input's new instances are Pre",
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, type: TrackEffectType.filter)
            ..insertPlugin(
              0,
              const PluginRef(format: PluginFormat.vst3, id: 'p'),
            );
        },
        verify: (cubit) {
          // An input's Pre entries are what a take records; its Post entries
          // are copied onto the lane and run after that take's player. The
          // accepted design makes Pre the default here, and the model's own
          // default is Post — so a surface that forgets to say leaves an
          // input's effects out of every take it records.
          final chain = cubit.state.forInput(0).effects;
          expect(chain.map((e) => e.placement), [
            FxPlacement.pre,
            FxPlacement.pre,
          ]);
          expect((chain[0] as BuiltInEffect).type, TrackEffectType.filter);
          expect(chain[1], isA<PluginEffect>());
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'a reorder across the Pre/Post boundary is refused',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, type: TrackEffectType.drive)
            ..addEffect(0, type: TrackEffectType.delay)
            // Send the delay to Post, then try to drag the drive past it.
            ..setEffectPlacement(0, 1, FxPlacement.post)
            ..moveEffect(0, 0, 1);
        },
        verify: (cubit) => expect(
          cubit.state.forInput(0).effects.map((e) => (e as BuiltInEffect).type),
          [TrackEffectType.drive, TrackEffectType.delay],
        ),
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectPlacement moves an instance to the end of its new stage',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0, type: TrackEffectType.drive)
            ..addEffect(0, type: TrackEffectType.delay)
            ..addEffect(0, type: TrackEffectType.reverb)
            // The first of three Pre entries goes Post; the two behind it
            // close up, and it lands last.
            ..setEffectPlacement(0, 0, FxPlacement.post);
        },
        verify: (cubit) {
          final chain = cubit.state.forInput(0).effects;
          expect(chain.map((e) => (e as BuiltInEffect).type), [
            TrackEffectType.delay,
            TrackEffectType.reverb,
            TrackEffectType.drive,
          ]);
          expect(chain.map((e) => e.placement), [
            FxPlacement.pre,
            FxPlacement.pre,
            FxPlacement.post,
          ]);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'a retype preserves the input slot identity, power, and channels',
        build: build,
        seed: () => MonitorState(
          inputs: {
            0: InputMonitor(
              input: 0,
              effects: [
                BuiltInEffect(
                  type: TrackEffectType.drive,
                  enabled: false,
                  slotId: 'monitor-slot',
                  placement: FxPlacement.pre,
                  channels: const FxChannels(
                    input: FxChannelInput.left,
                    output: FxChannelOutput.mono,
                    placement: .25,
                    level: .6,
                  ),
                ),
              ],
            ),
          },
        ),
        act: (cubit) => cubit.setEffectType(0, 0, TrackEffectType.reverb),
        verify: (cubit) {
          final fx = cubit.state.forInput(0).effects.single;
          expect((fx as BuiltInEffect).type, TrackEffectType.reverb);
          expect(fx.placement, FxPlacement.pre);
          expect(fx.slotId, 'monitor-slot');
          expect(fx.enabled, isFalse);
          expect(
            fx.channels,
            const FxChannels(
              input: FxChannelInput.left,
              output: FxChannelOutput.mono,
              placement: .25,
              level: .6,
            ),
          );
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setEffectParam tweaks an entry without a structural reset',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectParam(0, 0, 0, 0.9);
        },
        verify: (cubit) {
          expect(
            (cubit.state.forInput(0).effects.single as BuiltInEffect).params[0],
            0.9,
          );
          verify(
            () => repository.setMonitorEffectParam(
              input: 0,
              index: 0,
              param: 0,
              value: 0.9,
            ),
          ).called(1);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'setPluginParam routes a plain value by plugin param id and persists',
        setUp: () async {
          when(
            () => repository.setMonitorPluginParam(
              input: any(named: 'input'),
              index: any(named: 'index'),
              paramId: any(named: 'paramId'),
              value: any(named: 'value'),
            ),
          ).thenReturn(EngineResult.ok);
          // Seed a monitor chain with a single plugin entry, then restore it.
          await settings.saveMonitorEffects(
            0,
            encodeTrackEffects(const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              ),
            ]),
          );
        },
        build: build,
        act: (cubit) async {
          await cubit.load();
          cubit.setPluginParam(0, 0, 100, 0.7);
        },
        verify: (cubit) async {
          final fx = cubit.state.forInput(0).effects.single as PluginEffect;
          expect(fx.paramValues[100], 0.7);
          verify(
            () => repository.setMonitorPluginParam(
              input: 0,
              index: 0,
              paramId: 100,
              value: 0.7,
            ),
          ).called(1);
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'insertPlugin appends a PluginEffect, applies, and persists',
        build: build,
        act: (cubit) => cubit.insertPlugin(
          0,
          const PluginRef(format: PluginFormat.vst3, id: 'TUID-HEX'),
        ),
        expect: () => [
          isA<MonitorState>().having(
            (s) => s.forInput(0).effects.single,
            'inserted effect',
            isA<PluginEffect>().having((e) => e.ref.id, 'ref.id', 'TUID-HEX'),
          ),
        ],
        verify: (_) async {
          verify(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
            ),
          ).called(1);
          expect(await settings.loadMonitorEffects(0), isNotNull);
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'openPluginEditor opens the editor and starts the sync poll',
        build: build,
        act: (cubit) => cubit.openPluginEditor(0, 0),
        wait: const Duration(milliseconds: 250),
        verify: (_) {
          verify(
            () => repository.openMonitorPluginEditor(input: 0, index: 0),
          ).called(1);
          verify(
            () => repository.refreshMonitorPluginParams(input: 0, index: 0),
          ).called(greaterThanOrEqualTo(1));
        },
      );

      test('closePluginEditor closes the editor and stops the poll', () async {
        var refreshCount = 0;
        when(
          () => repository.refreshMonitorPluginParams(
            input: any(named: 'input'),
            index: any(named: 'index'),
          ),
        ).thenAnswer((_) {
          refreshCount++;
          return false;
        });
        final cubit = build()..openPluginEditor(0, 0);
        addTearDown(cubit.close);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(refreshCount, greaterThanOrEqualTo(1));
        cubit.closePluginEditor(0, 0);
        verify(
          () => repository.closeMonitorPluginEditor(input: 0, index: 0),
        ).called(1);
        // The poll stops climbing once the editor closes.
        final after = refreshCount;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(refreshCount, after);
      });

      blocTest<MonitorCubit, MonitorState>(
        'removeEffect drops an entry (back to the clean path)',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..removeEffect(0, 0);
        },
        verify: (cubit) => expect(cubit.state.forInput(0).effects, isEmpty),
      );

      blocTest<MonitorCubit, MonitorState>(
        'moveEffect reorders the chain and persists it',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..setEffectType(0, 0, TrackEffectType.drive)
            ..addEffect(0)
            ..setEffectType(0, 1, TrackEffectType.delay)
            ..moveEffect(0, 0, 1); // drive moves after delay
        },
        verify: (cubit) async {
          expect(
            cubit.state
                .forInput(0)
                .effects
                .map((e) => (e as BuiltInEffect).type),
            [TrackEffectType.delay, TrackEffectType.drive],
          );
          verify(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
            ),
          ).called(greaterThanOrEqualTo(1));
        },
      );

      blocTest<MonitorCubit, MonitorState>(
        'moveEffect ignores out-of-range and no-op moves',
        build: build,
        act: (cubit) {
          cubit
            ..addEffect(0)
            ..moveEffect(0, 5, 0) // from out of range
            ..moveEffect(0, 0, 0); // no-op
        },
        verify: (cubit) =>
            expect(cubit.state.forInput(0).effects, hasLength(1)),
      );
    });
  });

  group('knob-drag persistence is debounced', () {
    const debounce = Duration(milliseconds: 30);
    late _CountingStore store;

    setUp(() {
      store = _CountingStore();
      settings = SettingsRepository(store: store);
    });

    MonitorCubit buildDebounced() => MonitorCubit(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository, settings: settings),
      repository: repository,
      settings: settings,
      fxPersistDebounce: debounce,
    );

    test('a drag writes the engine per move and the store once', () async {
      final cubit = buildDebounced()..addEffect(0);
      addTearDown(cubit.close);
      // The structural add persists straight through; only the knob is
      // coalesced, so count from here.
      await pumpEventQueue();
      final writesBeforeDrag = store.stringWrites;

      for (var i = 0; i < 8; i++) {
        cubit.setEffectParam(0, 0, 0, i / 10);
      }

      // Every move reached the engine on the move that made it.
      verify(
        () => repository.setMonitorEffectParam(
          input: 0,
          index: 0,
          param: 0,
          value: any(named: 'value'),
        ),
      ).called(8);
      expect(store.stringWrites, writesBeforeDrag);

      await Future<void>.delayed(debounce * 3);

      expect(store.stringWrites, writesBeforeDrag + 1);
      final persisted = decodeFxChain(await settings.loadMonitorEffects(0));
      // The value the user let go on, not the one that scheduled the write.
      expect((persisted.entries.single as BuiltInEffect).params.first, 0.7);
    });

    test('closing flushes a drag that ended inside the window', () async {
      final cubit = buildDebounced()..addEffect(0);
      await pumpEventQueue();
      final writesBeforeDrag = store.stringWrites;
      cubit.setEffectParam(0, 0, 0, 0.42);
      expect(store.stringWrites, writesBeforeDrag);

      await cubit.close();
      await pumpEventQueue();

      final persisted = decodeFxChain(await settings.loadMonitorEffects(0));
      expect((persisted.entries.single as BuiltInEffect).params.first, 0.42);
    });

    test(
      'flushPersistence commits a drag that ended inside the window',
      () async {
        final cubit = buildDebounced()..addEffect(0);
        addTearDown(cubit.close);
        await pumpEventQueue();
        final writesBeforeDrag = store.stringWrites;
        cubit.setEffectParam(0, 0, 0, 0.42);
        expect(store.stringWrites, writesBeforeDrag);

        await cubit.flushPersistence();
        await pumpEventQueue();

        final persisted = decodeFxChain(await settings.loadMonitorEffects(0));
        expect((persisted.entries.single as BuiltInEffect).params.first, 0.42);
      },
    );
  });
}
