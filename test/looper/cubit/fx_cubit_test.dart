import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/cubit/fx_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/model/fx_library_choice.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Repository extends Mock implements LooperRepository {}

class _Settings extends Mock implements SettingsRepository {}

class _Persistence extends Mock implements FxChainPersistence {}

BuiltInEffect _effect(String id, {bool enabled = true}) => BuiltInEffect(
  type: TrackEffectType.filter,
  slotId: id,
  enabled: enabled,
);

void main() {
  late _Repository repository;
  late _Settings settings;
  late _Persistence persistence;
  late FxCubit cubit;
  late List<TrackEffect> chain;
  var generation = 4;
  var session = 9;
  var room = 1 << 40;

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(const FxAddress(stage: FxStage.track));
  });

  setUp(() {
    generation = 4;
    session = 9;
    room = 1 << 40;
    repository = _Repository();
    settings = _Settings();
    persistence = _Persistence();
    chain = [_effect('first'), _effect('second')];
    when(() => repository.mixGeneration).thenAnswer((_) => generation);
    when(() => repository.sessionRevision).thenAnswer((_) => session);
    when(() => repository.fxRoomNs).thenAnswer((_) => room);
    when(() => repository.fxCostOf(any())).thenAnswer(
      (call) => fxChainCostNs(call.positionalArguments[0] as List<TrackEffect>),
    );
    when(() => repository.state).thenReturn(
      const LooperState(
        tracks: [Track(), Track(channel: 1)],
        status: EngineStatus(inputChannels: 4),
        outputBusCount: 2,
      ),
    );
    when(() => repository.allTrackChains()).thenAnswer(
      (_) => {0: FxChainEnvelope(entries: chain)},
    );
    when(() => repository.trackEffects(0)).thenAnswer((_) => chain);
    when(
      () => repository.setTrackEffects(
        channel: 0,
        effects: any(named: 'effects'),
      ),
    ).thenAnswer((call) {
      chain = call.namedArguments[#effects]! as List<TrackEffect>;
      return EngineResult.ok;
    });
    when(
      () => repository.setTrackEffectEnabled(
        channel: 0,
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenAnswer((call) {
      final index = call.namedArguments[#index]! as int;
      final enabled = call.namedArguments[#enabled]! as bool;
      chain = List<TrackEffect>.of(chain)
        ..[index] = (chain[index] as BuiltInEffect).copyWith(enabled: enabled);
      return EngineResult.ok;
    });
    when(
      () => repository.setTrackEffectParam(
        channel: 0,
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => persistence.beginPending()).thenAnswer((_) => Object());
    when(() => persistence.finishPending(any())).thenReturn(null);
    when(
      () => persistence.retainConfirmed(any(), settings),
    ).thenReturn(null);
    when(
      () => persistence.saveConfirmed(any(), settings),
    ).thenAnswer((_) async {});
    when(() => persistence.scheduleSave(any(), settings)).thenReturn(null);
    when(
      () => persistence.ordinarySlotAt(
        any(),
        any(),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(null);
    when(
      () => persistence.ordinaryParameterAt(
        any(),
        any(),
        any(),
        any(),
      ),
    ).thenReturn(null);
    cubit = FxCubit(
      repository: repository,
      settings: settings,
      persistence: persistence,
      initial: const FxDestination.recordedTrack(0),
    );
    addTearDown(cubit.close);
  });

  test(
    'an added single effect is on, saved only after its native receipt',
    () async {
      final result = await cubit.appendChoice(
        const FxDestination.recordedTrack(0),
        const FxSingleChoice(TrackEffectType.reverb),
      );

      expect(result.status, FxEditStatus.applied);
      expect(chain, hasLength(3));
      expect(chain.last.enabled, isTrue);
      verifyInOrder([
        () => repository.setTrackEffects(
          channel: 0,
          effects: any(named: 'effects'),
        ),
        () => repository.settleFxRecipes(
          waitForCallback: true,
          cancelled: any(named: 'cancelled'),
        ),
        () => persistence.saveConfirmed(
          const FxAddress(stage: FxStage.track),
          settings,
        ),
      ]);
    },
  );

  for (final failed in [false, true]) {
    test('a live input edit ${failed ? 'is refused' : 'reaches the engine'} '
        'when its restore ${failed ? 'has failed' : 'succeeded'}', () async {
      when(() => persistence.inputRestoreFailed).thenReturn(failed);
      when(() => repository.monitorEffects(0)).thenReturn(const []);
      when(() => repository.monitorChainEnabled(0)).thenReturn(true);
      when(
        () => repository.setMonitorEffects(
          input: 0,
          effects: any(named: 'effects'),
          chainEnabled: any(named: 'chainEnabled'),
          allowUnavailable: any(named: 'allowUnavailable'),
        ),
      ).thenReturn(EngineResult.ok);
      final input = FxCubit(
        repository: repository,
        settings: settings,
        persistence: persistence,
        initial: const FxDestination.liveInput(0),
      );
      addTearDown(input.close);
      final result = await input.appendChoice(
        const FxDestination.liveInput(0),
        const FxSingleChoice(TrackEffectType.reverb),
      );
      void write() => repository.setMonitorEffects(
        input: 0,
        effects: any(named: 'effects'),
        chainEnabled: any(named: 'chainEnabled'),
        allowUnavailable: any(named: 'allowUnavailable'),
      );
      if (failed) {
        expect(result.status, FxEditStatus.refused);
        verifyNever(write);
      } else {
        expect(result.status, isNot(FxEditStatus.refused));
        expect(result.status, isNot(FxEditStatus.stale));
        verify(write).called(greaterThan(0));
      }
    });
  }

  test('native refusal leaves the change unsaved', () async {
    when(
      () => repository.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => EngineResult.invalid);

    final result = await cubit.removeEffect(
      const FxAddress(stage: FxStage.track),
      'first',
    );

    expect(result.status, FxEditStatus.refused);
    verifyNever(() => persistence.saveConfirmed(any(), settings));
  });

  test(
    'selection change does not cancel an admitted recipe or its save',
    () async {
      final nativeReceipt = Completer<void>();
      var persisted = '';
      when(() => repository.fxReplayConfirmed).thenAnswer(
        (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
      );
      when(() => repository.fxRecipesSettled).thenReturn(true);
      when(() => repository.trackChainEnabled(0)).thenReturn(true);
      when(
        () => repository.settleFxRecipes(
          waitForCallback: true,
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((call) async {
        await nativeReceipt.future;
        final cancelled = call.namedArguments[#cancelled]! as bool Function();
        return cancelled() ? EngineResult.notReady : EngineResult.ok;
      });
      when(() => settings.saveTrackFxChain(0, any())).thenAnswer((call) async {
        persisted = call.positionalArguments[1] as String;
      });
      final shared = FxChainPersistence(looper: repository);
      final owner = FxCubit(
        repository: repository,
        settings: settings,
        persistence: shared,
        initial: const FxDestination.recordedTrack(0),
      );
      addTearDown(owner.close);
      addTearDown(shared.close);

      final edit = owner.appendChoice(
        const FxDestination.recordedTrack(0),
        const FxSingleChoice(TrackEffectType.reverb),
      );
      owner.show(const FxDestination.recordedTrack(1));
      nativeReceipt.complete();

      expect((await edit).status, FxEditStatus.stale);
      await shared.flush();
      expect(decodeFxChain(persisted).entries, hasLength(3));
    },
  );

  test('a valid empty track accepts its first effect', () async {
    chain = [];
    when(() => repository.allTrackChains()).thenReturn(const {});

    final result = await cubit.appendChoice(
      const FxDestination.recordedTrack(0),
      const FxSingleChoice(TrackEffectType.reverb),
    );

    expect(result.status, FxEditStatus.applied);
    expect(chain, hasLength(1));
    verify(
      () => repository.setTrackEffects(
        channel: 0,
        effects: any(named: 'effects'),
      ),
    ).called(1);
  });

  test(
    'real repository exposes a valid empty default track for editing',
    () async {
      final realLooper = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      final realSettings = SettingsRepository(store: FakeKeyValueStore());
      final shared = FxChainPersistence(looper: realLooper);
      final owner = FxCubit(
        repository: realLooper,
        settings: realSettings,
        persistence: shared,
        initial: const FxDestination.recordedTrack(0),
      );
      addTearDown(realLooper.dispose);
      addTearDown(shared.close);
      addTearDown(owner.close);

      expect(realLooper.allTrackChains(), isEmpty);
      expect(
        realLooper.chainEntriesAt(const FxAddress(stage: FxStage.track)),
        isNull,
      );
      final result = await owner.appendChoice(
        const FxDestination.recordedTrack(0),
        const FxSingleChoice(TrackEffectType.reverb),
      );

      expect(result.status, FxEditStatus.applied);
      expect(realLooper.trackEffects(0), hasLength(1));
      expect(await realSettings.loadTrackFxChain(0), isNotNull);

      final missingDestination = FxDestination.recordedTrack(
        0,
        part: FxTrackPart.part(2),
      );
      owner.show(missingDestination);
      final missingPart = await owner.appendChoice(
        missingDestination,
        const FxSingleChoice(TrackEffectType.delay),
      );
      expect(missingPart.status, FxEditStatus.refused);
      expect(await realSettings.loadLaneEffects(0, 2), isNull);
    },
  );

  test('storage refusal reports live but unsaved state', () async {
    when(
      () => persistence.saveConfirmed(any(), settings),
    ).thenThrow(StateError('disk unavailable'));

    final result = await cubit.removeEffect(
      const FxAddress(stage: FxStage.track),
      'first',
    );

    expect(result.status, FxEditStatus.unsaved);
    expect(chain.map((effect) => effect.slotId), ['second']);
    verify(
      () => persistence.saveConfirmed(
        const FxAddress(stage: FxStage.track),
        settings,
      ),
    ).called(1);
  });

  test(
    'native callback error is refused without an unhandled UI future',
    () async {
      when(
        () => repository.settleFxRecipes(
          waitForCallback: true,
          cancelled: any(named: 'cancelled'),
        ),
      ).thenThrow(StateError('native callback interrupted'));

      final result = await cubit.removeEffect(
        const FxAddress(stage: FxStage.track),
        'first',
      );

      expect(result.status, FxEditStatus.refused);
      verifyNever(() => persistence.saveConfirmed(any(), settings));
    },
  );

  test('a later reorder edits the named effect, never its old index', () {
    chain = [chain.last, chain.first];

    final result = cubit.setEffectEnabled(
      const FxAddress(stage: FxStage.track),
      'first',
      enabled: false,
    );

    expect(result.status, FxEditStatus.applied);
    verify(
      () => repository.setTrackEffectEnabled(
        channel: 0,
        index: 1,
        enabled: false,
      ),
    ).called(1);
    verify(
      () => persistence.ordinarySlotAt(
        const FxAddress(stage: FxStage.track),
        1,
        enabled: false,
      ),
    ).called(1);
  });

  test('parameter movement uses one granular setter and coalesced save', () {
    final result = cubit.setParameter(
      const FxAddress(stage: FxStage.track),
      'second',
      0,
      0.42,
    );

    expect(result.status, FxEditStatus.applied);
    verify(
      () => repository.setTrackEffectParam(
        channel: 0,
        index: 1,
        param: 0,
        value: 0.42,
      ),
    ).called(1);
    verifyNever(
      () => repository.setTrackEffects(
        channel: 0,
        effects: any(named: 'effects'),
      ),
    );
    verify(
      () => persistence.scheduleSave(
        const FxAddress(stage: FxStage.track),
        settings,
      ),
    ).called(1);
  });

  group('the effects budget', () {
    const track = FxDestination.recordedTrack(0);
    const address = FxAddress(stage: FxStage.track);

    test('an add that needs more than is left is refused and changes '
        'nothing', () async {
      room = fxEntryCostNs(BuiltInEffect(type: TrackEffectType.octaver)) - 1;
      final before = chain;

      final result = await cubit.appendChoice(
        track,
        const FxSingleChoice(TrackEffectType.octaver),
      );

      expect(result.status, FxEditStatus.overBudget);
      expect(chain, same(before));
    });

    test('an add that fits lands', () async {
      room = kFxKindCostNs[TrackEffectType.delay]!;

      final result = await cubit.appendChoice(
        track,
        const FxSingleChoice(TrackEffectType.delay),
      );

      expect(result.status, FxEditStatus.applied);
    });

    test('switching an octaver to PSOLA is refused when its extra cost '
        'does not fit', () async {
      final octaver = BuiltInEffect(
        type: TrackEffectType.octaver,
        slotId: 'oct',
      );
      chain = [octaver];
      room = 0;

      final result = cubit.setParameter(address, 'oct', 3, 1);

      expect(result.status, FxEditStatus.overBudget);
    });

    test('a removal always lands, even over budget', () async {
      room = -1000;

      final result = await cubit.removeEffect(address, 'first');

      expect(result.status, FxEditStatus.applied);
      expect(chain.map((fx) => fx.slotId), ['second']);
    });
  });

  group('a factory rack', () {
    const track = FxDestination.recordedTrack(0);
    const address = FxAddress(stage: FxStage.track);
    const preset = FxPreset(
      family: "Ed's Rack",
      name: 'Acoustic Rhythm 1',
      id: 'ed53e7b8',
      type: 0,
      params: {
        'Compressor': 1,
        'Delay': 0,
        'Del Time': 0.42,
        'Reverb': 1,
        'Master Vol': 0.4,
      },
    );

    FxChainGroup rackOf(String id) =>
        fxChainGroups(chain).firstWhere((group) => group.rack?.id == id);

    test('takes its rack level from Master Vol', () async {
      final result = await cubit.appendChoice(
        track,
        const FxRackChoice(preset),
      );

      expect(result.status, FxEditStatus.applied);
      final rack = rackOf(result.groupId!);
      // Ed's Rack's measured order: Reverb runs before Delay.
      expect(rack.entries.map((fx) => fx.module), [
        'Compressor',
        'Reverb',
        'Delay',
      ]);
      expect(fxRackLevelDb(rack.channels.level), -2.4);
      // Every pedal as the preset sets it: the compressor and reverb on, the
      // delay off.
      expect(rack.entries.map((fx) => fx.enabled), [true, true, false]);
    });

    test('appended into an existing rack keeps that rack its own '
        'level', () async {
      final added = await cubit.appendChoice(
        track,
        const FxRackChoice(preset),
      );
      final rackId = added.groupId!;
      await cubit.setGroupChannels(
        address,
        rackId,
        const FxChannels(level: 0.8),
      );

      final result = await cubit.appendToRack(
        address,
        rackId,
        const FxRackChoice(
          FxPreset(
            family: 'Guitar Rack',
            name: 'Spring',
            id: 'guitar-1',
            type: 1,
            params: {'Spring': 1, 'Spring Mix': 0.3, 'Master Vol': 0.2},
          ),
        ),
      );

      expect(result.status, FxEditStatus.applied);
      final rack = rackOf(rackId);
      expect(rack.length, 4);
      expect(rack.entries.last.module, 'Spring reverb');
      expect(rack.channels.level, 0.8);
    });

    test(
      'a Dub Rack appended into a Dub Rack keeps the paths one run',
      () async {
        const dub = FxPreset(
          family: 'Dub Rack',
          name: 'Dub',
          id: 'dub-1',
          type: 4,
          params: {
            'Doubler': 1,
            'Doubler Mix': 1,
            'Doubler Sep': 1,
            'Dub Delay': 1,
            'Del Time': 0.3,
            'Del Feedback': 0.4,
            'Del Damp': 0.5,
            'Del L/R Ratio': 0.5,
            'Del Res-Freq': 0.5,
            'Del Reso': 0.5,
            'Dub-Verb': 1,
            'Dub-Verb Dec': 0.5,
            'Dub-Verb Vol': 0.2,
            'Amb-Verb': 1,
            'Amb-Verb Dec': 0.2,
            'Amb-verb Vol': 0.4,
            'Amb-Dub Mix': 0.4,
          },
        );
        final added = await cubit.appendChoice(track, const FxRackChoice(dub));
        final rackId = added.groupId!;
        final before = rackOf(rackId).entries.length;

        final result = await cubit.appendToRack(
          address,
          rackId,
          const FxRackChoice(dub),
        );

        expect(result.status, FxEditStatus.applied);
        final rack = rackOf(rackId).entries;
        expect(rack, hasLength(2 * before));
        final paths = fxEntryPaths(rack);
        final first = paths.indexWhere((p) => p != null);
        final last = paths.lastIndexWhere((p) => p != null);
        expect(paths.sublist(first, last + 1), everyElement(isNotNull));
        expect(paths.where((p) => p == FxModulePath.amb), hasLength(2));
      },
    );

    test('added again replaces the rack built from it, in its place, with '
        'new identities', () async {
      final first = await cubit.appendChoice(track, const FxRackChoice(preset));
      final oldIds = rackOf(first.groupId!).entries.map((fx) => fx.slotId);
      final trailing = await cubit.appendChoice(
        track,
        const FxSingleChoice(TrackEffectType.drive),
      );

      final result = await cubit.replaceRack(
        track,
        first.groupId!,
        const FxRackChoice(preset),
      );

      expect(result.status, FxEditStatus.applied);
      expect(result.groupId, isNot(first.groupId));
      expect(fxChainGroups(chain), hasLength(4));
      final rack = fxChainGroups(chain)[2];
      expect(rack.rack!.id, result.groupId);
      expect(
        rack.entries.map((fx) => fx.slotId),
        isNot(contains(oldIds.first)),
      );
      expect(fxRackLevelDb(rackOf(result.groupId!).channels.level), -2.4);
      // The single effect added after it is still after it.
      expect(chain.last.slotId, trailing.groupId);
    });

    test('a replacement saved while the player moves to another destination '
        'is stale for the page and still committed', () async {
      final first = await cubit.appendChoice(track, const FxRackChoice(preset));
      when(() => persistence.saveConfirmed(any(), settings)).thenAnswer((
        _,
      ) async {
        cubit.show(const FxDestination.recordedTrack(1));
      });

      final result = await cubit.replaceRack(
        track,
        first.groupId!,
        const FxRackChoice(preset),
      );

      expect(result.status, FxEditStatus.stale);
      expect(result.committed, isTrue);
      expect(fxChainGroups(chain).last.rack!.id, result.groupId);
    });

    test('a rack that is gone is not replaced', () async {
      final result = await cubit.replaceRack(
        track,
        'missing',
        const FxRackChoice(preset),
      );

      expect(result.status, FxEditStatus.refused);
      expect(chain, hasLength(2));
    });
  });

  group('setChainEnabled', () {
    // One chain per stage, all on, each written through its own repository
    // setter.
    late Map<FxAddress, bool> power;
    late EngineResult outcome;

    setUp(() {
      outcome = EngineResult.ok;
      power = {};
      bool on(FxAddress a) => power[a] ?? true;
      EngineResult write(FxAddress a, {required bool enabled}) {
        if (!outcome.isOk) return outcome;
        power[a] = enabled;
        return EngineResult.ok;
      }

      when(() => persistence.inputRestoreFailed).thenReturn(false);
      when(() => repository.monitorEffects(0)).thenReturn([_effect('m')]);
      when(() => repository.laneCount(0)).thenReturn(1);
      when(() => repository.laneEffects(0, 0)).thenReturn([_effect('l')]);
      when(() => repository.allTracksEffects).thenReturn([_effect('a')]);
      when(() => repository.outputEffects(0)).thenReturn([_effect('o')]);
      // The rig holds settings for every one of them.
      when(
        () => repository.allMonitors(),
      ).thenReturn(const {0: InputMonitor(input: 0)});
      when(
        () => repository.allLaneChains(),
      ).thenReturn(const {(0, 0): FxChainEnvelope()});
      when(
        () => persistence.ordinaryChain(any(), enabled: any(named: 'enabled')),
      ).thenReturn(null);
      const input = FxAddress(stage: FxStage.input);
      const lane = FxAddress(stage: FxStage.loop, lane: 0);
      const track = FxAddress(stage: FxStage.track);
      const all = FxAddress(stage: FxStage.allTracks);
      const output = FxAddress(stage: FxStage.output);
      when(
        () => repository.monitorChainEnabled(0),
      ).thenAnswer((_) => on(input));
      when(() => repository.laneChainEnabled(0, 0)).thenAnswer((_) => on(lane));
      when(() => repository.trackChainEnabled(0)).thenAnswer((_) => on(track));
      when(() => repository.allTracksChainEnabled).thenAnswer((_) => on(all));
      when(
        () => repository.outputChainEnabled(0),
      ).thenAnswer((_) => on(output));
      when(
        () => repository.setMonitorChainEnabled(
          input: 0,
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer(
        (call) => write(input, enabled: call.namedArguments[#enabled]! as bool),
      );
      when(
        () => repository.setLaneChainEnabled(
          channel: 0,
          lane: 0,
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer(
        (call) => write(lane, enabled: call.namedArguments[#enabled]! as bool),
      );
      when(
        () => repository.setTrackChainEnabled(
          channel: 0,
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer(
        (call) => write(track, enabled: call.namedArguments[#enabled]! as bool),
      );
      when(
        () => repository.setAllTracksChainEnabled(
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer(
        (call) => write(all, enabled: call.namedArguments[#enabled]! as bool),
      );
      when(
        () => repository.setOutputChainEnabled(
          bus: 0,
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer(
        (call) =>
            write(output, enabled: call.namedArguments[#enabled]! as bool),
      );
    });

    for (final address in const [
      FxAddress(stage: FxStage.input),
      FxAddress(stage: FxStage.loop, lane: 0),
      FxAddress(stage: FxStage.track),
      FxAddress(stage: FxStage.allTracks),
      FxAddress(stage: FxStage.output),
    ]) {
      test('switches the ${address.stage.name} chain through its own writer, '
          'as an ordinary write that is saved', () {
        final result = cubit.setChainEnabled(address, enabled: false);

        expect(result.status, FxEditStatus.applied);
        expect(power[address], isFalse);
        verify(
          () => persistence.ordinaryChain(address, enabled: false),
        ).called(1);
        verify(() => persistence.scheduleSave(address, settings)).called(1);
      });

      test('leaves the ${address.stage.name} chain alone when it is already '
          'so', () {
        final result = cubit.setChainEnabled(address, enabled: true);

        expect(result.status, FxEditStatus.unchanged);
        verifyNever(
          () =>
              persistence.ordinaryChain(any(), enabled: any(named: 'enabled')),
        );
      });

      test('reports a refused ${address.stage.name} write and saves '
          'nothing', () {
        outcome = EngineResult.invalid;

        final result = cubit.setChainEnabled(address, enabled: false);

        expect(result.status, FxEditStatus.refused);
        verifyNever(() => persistence.scheduleSave(any(), settings));
      });
    }

    test('switching off an input with no effects changes nothing, so no '
        'monitor the player never set up is saved', () {
      when(() => repository.monitorEffects(0)).thenReturn(const []);
      when(() => repository.allMonitors()).thenReturn(const {});

      final result = cubit.setChainEnabled(
        const FxAddress(stage: FxStage.input),
        enabled: false,
      );

      expect(result.status, FxEditStatus.unchanged);
      verifyNever(
        () => repository.setMonitorChainEnabled(
          input: any(named: 'input'),
          enabled: any(named: 'enabled'),
        ),
      );
      verifyNever(() => persistence.scheduleSave(any(), settings));
    });

    test('refuses a chain that does not exist', () {
      final result = cubit.setChainEnabled(
        const FxAddress(stage: FxStage.output, index: 5),
        enabled: false,
      );

      expect(result.status, FxEditStatus.refused);
    });
  });

  group('an addition keeps its source pedal states', () {
    // Mixed power keys, so a state the source sets cannot pass for one the
    // adding surface forced, on or off.
    const rack = FxPreset(
      family: "Ed's Rack",
      name: 'Acoustic Rhythm 1',
      id: 'ed53e7b8',
      type: 0,
      params: {'Compressor': 1, 'Delay': 0, 'Reverb': 1},
    );
    final saved = FxUserPreset(
      id: 'u1',
      name: 'verse',
      isRack: true,
      entries: [
        BuiltInEffect(type: TrackEffectType.echo, slotId: 's1'),
        BuiltInEffect(
          type: TrackEffectType.reverb,
          slotId: 's2',
          enabled: false,
        ),
      ],
    );
    final choices = <(String, FxLibraryChoice, List<bool>)>[
      // Rack order: Compressor, Reverb, Delay.
      ('a factory rack', const FxRackChoice(rack), [true, true, false]),
      ('a saved sound', FxSavedChoice(saved), [true, false]),
      (
        'a single effect',
        const FxSingleChoice(TrackEffectType.reverb),
        [true],
      ),
    ];

    /// Points the destination's chain at [staged], which every replacement
    /// writes back.
    void stage(
      FxAddress address,
      List<TrackEffect> Function() read,
      void Function(List<TrackEffect>) write,
    ) {
      switch (address.stage) {
        case FxStage.input:
          when(() => persistence.inputRestoreFailed).thenReturn(false);
          when(() => repository.monitorEffects(0)).thenAnswer((_) => read());
          when(
            () => repository.setMonitorEffects(
              input: 0,
              effects: any(named: 'effects'),
              chainEnabled: any(named: 'chainEnabled'),
              allowUnavailable: any(named: 'allowUnavailable'),
            ),
          ).thenAnswer((call) {
            write(call.namedArguments[#effects]! as List<TrackEffect>);
            return EngineResult.ok;
          });
        case FxStage.output:
          when(() => repository.outputEffects(0)).thenAnswer((_) => read());
          when(
            () => repository.setOutputEffects(
              bus: 0,
              effects: any(named: 'effects'),
              chainEnabled: any(named: 'chainEnabled'),
              allowUnavailable: any(named: 'allowUnavailable'),
            ),
          ).thenAnswer((call) {
            write(call.namedArguments[#effects]! as List<TrackEffect>);
            return EngineResult.ok;
          });
        case FxStage.allTracks:
          when(() => repository.allTracksEffects).thenAnswer((_) => read());
          when(
            () => repository.setAllTracksEffects(
              effects: any(named: 'effects'),
              chainEnabled: any(named: 'chainEnabled'),
              allowUnavailable: any(named: 'allowUnavailable'),
            ),
          ).thenAnswer((call) {
            write(call.namedArguments[#effects]! as List<TrackEffect>);
            return EngineResult.ok;
          });
        case FxStage.track:
        case FxStage.loop:
          // The group's own setUp already stages track 0 on `chain`.
          break;
      }
    }

    const destinations = <FxDestination>[
      FxDestination.liveInput(0),
      FxDestination.output(0),
      FxDestination.allTracks(),
      FxDestination.recordedTrack(0),
    ];

    for (final destination in destinations) {
      final address = destination.address!;
      for (final (label, choice, states) in choices) {
        test(
          '$label added to ${address.stage.name} keeps its states',
          () async {
            var staged = <TrackEffect>[];
            stage(address, () => staged, (next) => staged = next);
            List<TrackEffect> current() =>
                address.stage == FxStage.track ? chain : staged;
            final before = current().length;
            cubit.show(destination);

            final result = await cubit.appendChoice(destination, choice);

            expect(result.status, FxEditStatus.applied);
            expect(
              current().skip(before).map((fx) => fx.enabled),
              states,
            );
          },
        );
      }
    }

    for (final (label, choice, states) in choices) {
      test('$label added into an existing rack keeps its states', () async {
        const track = FxDestination.recordedTrack(0);
        final host = await cubit.appendChoice(track, const FxRackChoice(rack));
        final rackId = host.groupId!;
        final hostSize = fxChainGroups(
          chain,
        ).firstWhere((group) => group.rack?.id == rackId).length;

        final result = await cubit.appendToRack(
          const FxAddress(stage: FxStage.track),
          rackId,
          choice,
        );

        expect(result.status, FxEditStatus.applied);
        final grown = fxChainGroups(
          chain,
        ).firstWhere((group) => group.rack?.id == rackId);
        expect(grown.entries.skip(hostSize).map((fx) => fx.enabled), states);
      });
    }
  });
}
