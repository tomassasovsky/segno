import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(const FxAddress(stage: FxStage.track));
  });

  setUp(() {
    generation = 4;
    session = 9;
    repository = _Repository();
    settings = _Settings();
    persistence = _Persistence();
    chain = [_effect('first'), _effect('second')];
    when(() => repository.mixGeneration).thenAnswer((_) => generation);
    when(() => repository.sessionRevision).thenAnswer((_) => session);
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
    'an added effect is bypassed, saved only after its native receipt',
    () async {
      final result = await cubit.appendChoice(
        const FxDestination.recordedTrack(0),
        const FxSingleChoice(TrackEffectType.reverb),
      );

      expect(result.status, FxEditStatus.applied);
      expect(chain, hasLength(3));
      expect(chain.last.enabled, isFalse);
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
}
