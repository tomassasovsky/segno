import 'dart:async';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// Counts the string writes the debounce is meant to collapse.
class _CountingStore extends FakeKeyValueStore {
  int stringWrites = 0;

  @override
  Future<void> setString(String key, String value) {
    stringWrites++;
    return super.setString(key, value);
  }
}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late PluginCatalog catalog;

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(MonitorMode.off);
  });

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
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
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorOutput(
        input: any(named: 'input'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorVolume(
        input: any(named: 'input'),
        volume: any(named: 'volume'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorMute(
        input: any(named: 'input'),
        muted: any(named: 'muted'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorChainEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorEffectParam(
        input: any(named: 'input'),
        index: any(named: 'index'),
        param: any(named: 'param'),
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
    when(() => repository.monitorEffects(any())).thenReturn(const []);
  });

  /// Writes through with no debounce, so a test's assertion does not have to
  /// outlive a pending write. The debounce itself is covered in its own group.
  MonitorCubit build() => MonitorCubit(
    repository: repository,
    settings: settings,
    fxPersistDebounce: Duration.zero,
  );

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
        verify(
          () => repository.setMonitorVolume(input: 0, volume: 0.5),
        ).called(1);
        expect(await settings.loadMonitorVolume(0), 0.5);
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
          () => repository.setMonitorChainEnabled(input: 0, enabled: false),
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
          () => repository.setMonitorChainEnabled(input: 0, enabled: false),
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
          () => repository.setMonitorVolume(input: 0, volume: 0.4),
        ).called(1);
        verify(
          () => repository.setMonitorMute(input: 0, muted: true),
        ).called(1);
        verify(
          () => repository.setMonitorEffects(
            input: 0,
            effects: any(named: 'effects'),
          ),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    group('syncFromRepository', () {
      blocTest<MonitorCubit, MonitorState>(
        're-projects the repository monitors into state and persists them',
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
        act: (cubit) => cubit.syncFromRepository(),
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
          // All five fields are persisted, so the next boot restores THIS set.
          expect(await settings.loadMonitorInputMode(2), 'on');
          expect(await settings.loadMonitorOutput(2), 0x2);
          expect(await settings.loadMonitorVolume(2), 0.4);
          expect(await settings.loadMonitorMute(2), isTrue);
          expect(await settings.loadMonitorEffects(2), isNotNull);
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
        'resets ALL persisted fields for inputs dropped since the last state',
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
          // The freshly loaded session defines no monitors.
          when(repository.allMonitors).thenReturn(const {});
        },
        build: build,
        // Seed input 5 into state so it counts as "previously present".
        act: (cubit) async {
          await cubit.setMode(5, MonitorMode.on);
          await cubit.syncFromRepository();
        },
        verify: (cubit) async {
          expect(cubit.state.inputs, isEmpty);
          // Every field is reset to the disabled default — no lingering
          // outputMask / volume / mute to resurrect the monitor on next boot.
          expect(await settings.loadMonitorInputMode(5), 'off');
          expect(await settings.loadMonitorOutput(5), 0x3);
          expect(await settings.loadMonitorVolume(5), 1.0);
          expect(await settings.loadMonitorMute(5), isFalse);
          expect(
            await settings.loadMonitorEffects(5),
            encodeFxChain(const FxChainEnvelope()),
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
      repository: repository,
      settings: settings,
      fxPersistDebounce: debounce,
    );

    test('a drag writes the engine per move and the store once', () async {
      final cubit = buildDebounced()..addEffect(0);
      addTearDown(cubit.close);
      // The structural add persists straight through; only the knob is
      // coalesced, so count from here.
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
      final writesBeforeDrag = store.stringWrites;
      cubit.setEffectParam(0, 0, 0, 0.42);
      expect(store.stringWrites, writesBeforeDrag);

      await cubit.close();
      await pumpEventQueue();

      final persisted = decodeFxChain(await settings.loadMonitorEffects(0));
      expect((persisted.entries.single as BuiltInEffect).params.first, 0.42);
    });
  });
}
