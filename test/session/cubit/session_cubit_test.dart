import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockPerformanceRepository extends Mock
    implements PerformanceRepository {}

class _WriteThenThrowPersistence implements MixSettingsPersistence {
  String? durable = 'previous mix';
  bool refuseRestore = false;
  int restores = 0;

  @override
  Future<String?> read(String device) async => durable;

  @override
  Future<void> write(String device, MixSettingsSnapshot candidate) async {
    durable = 'incoming mix';
    throw StateError('write reported failure after reaching disk');
  }

  @override
  Future<void> restore(String device, String? checkpoint) async {
    restores++;
    if (refuseRestore) throw StateError('restore failed');
    durable = checkpoint;
  }
}

const _session = Session(
  sampleRate: 48000,
  channels: 1,
  baseLengthFrames: 0,
  tracks: [],
);

Future<T> _readyClick<T>(Future<T> Function() operation) => operation();

void main() {
  late SessionRepository repository;
  late LooperRepository looper;
  late PerformanceRepository performance;
  late MixSettingsCoordinator mixSettings;
  late MixSettingsPersistence mixPersistence;
  late StreamController<LooperState> looperStates;

  setUpAll(() {
    registerFallbackValue(const SessionRig());
    registerFallbackValue(const SessionChains());
    registerFallbackValue(const SessionSettings());
  });

  setUp(() {
    repository = _MockSessionRepository();
    looper = _MockLooperRepository();
    performance = _MockPerformanceRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    addTearDown(looperStates.close);
    mixPersistence = SettingsMixPersistence(
      SettingsRepository(store: FakeKeyValueStore()),
    );
    // Default chain getters so the save path's _captureChains() has something
    // to read; individual tests override as needed.
    when(looper.allLaneChains).thenReturn(const {});
    when(looper.allTrackChains).thenReturn(const {});
    when(looper.allOutputChains).thenReturn(const {});
    when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
    when(looper.allMonitors).thenReturn(const {});
    when(() => looper.sessionTransport).thenReturn(const TransportState());
    when(() => looper.lengthSettingsSettled).thenReturn(true);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(looper.stopEngine).thenReturn(EngineResult.ok);
    when(() => looper.defaultRecordTiming).thenReturn(RecordTiming.immediately);
    when(() => looper.defaultOverdubDecay).thenReturn(0);
    when(() => looper.defaultOneShot).thenReturn(false);
    when(() => looper.trackRecordTimingOverrides).thenReturn(const {});
    when(() => looper.trackOverdubDecayOverrides).thenReturn(const {});
    when(() => looper.trackOneShotOverrides).thenReturn(const {});
    when(() => looper.trackLengthPresetOverrides).thenReturn(const {});
    when(() => looper.state).thenReturn(const LooperState());
    mixSettings = MixSettingsCoordinator(
      repository: looper,
      persistence: mixPersistence,
      device: () => looper.state.status.deviceName,
    );
    // loadNamed's auto-disarm-before-load orchestration; a no-op success by
    // default since nothing is armed in these tests.
    when(
      performance.disarmAndFinalize,
    ).thenAnswer((_) async => EngineResult.ok);
  });

  SessionCubit build() => SessionCubit(
    runClickVolumeExclusive: _readyClick,
    currentDurableClickVolume: () => 1,
    fxPersistence: FxChainPersistence(looper: looper),
    repository: repository,
    looper: looper,
    performance: performance,
    mixSettings: mixSettings,
    mixPersistence: mixPersistence,
    exportDirectory: () async => '/tmp/x',
  );

  for (final accepted in [true, false]) {
    test(
      'session save waits for length confirmation accepted=$accepted',
      () async {
        final settled = Completer<EngineResult>();
        when(() => looper.lengthSettingsSettled).thenReturn(false);
        when(
          () => looper.settleLengthSettings(),
        ).thenAnswer((_) => settled.future);
        when(repository.listSessions).thenAnswer((_) async => []);
        when(
          () => repository.bundlePath('pending'),
        ).thenAnswer((_) async => '/tmp/pending');
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),

            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((_) async => _session);
        final cubit = build();
        addTearDown(cubit.close);
        final save = cubit.saveAs('pending');
        await Future<void>.delayed(Duration.zero);
        verifyNever(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),

            captureStillValid: any(named: 'captureStillValid'),
          ),
        );
        when(
          () => looper.sessionTransport,
        ).thenReturn(const TransportState(defaultLengthPresetBars: 8));
        settled.complete(accepted ? EngineResult.ok : EngineResult.invalid);
        await save;
        expect(
          cubit.state.status,
          accepted ? SessionStatus.success : SessionStatus.failure,
        );
        if (accepted) {
          final settings =
              verify(
                    () => repository.save(
                      '/tmp/pending',
                      chains: any(named: 'chains'),
                      settings: captureAny(named: 'settings'),
                      pedalBindings: any(named: 'pedalBindings'),

                      captureStillValid: any(named: 'captureStillValid'),
                    ),
                  ).captured.single
                  as SessionSettings;
          expect(settings.defaultLengthPresetBars, 8);
        } else {
          verifyNever(
            () => repository.save(
              any(),
              chains: any(named: 'chains'),
              settings: any(named: 'settings'),
              pedalBindings: any(named: 'pedalBindings'),

              captureStillValid: any(named: 'captureStillValid'),
            ),
          );
        }
      },
    );
  }

  test(
    'session replacement supersedes pending save after successful settlement',
    () async {
      final settled = Completer<EngineResult>();
      when(() => looper.lengthSettingsSettled).thenReturn(false);
      when(
        () => looper.settleLengthSettings(),
      ).thenAnswer((_) => settled.future);
      when(repository.listSessions).thenAnswer((_) async => []);
      when(
        () => repository.bundlePath('pending'),
      ).thenAnswer((_) async => '/tmp/pending');
      final cubit = build();
      addTearDown(cubit.close);
      final save = cubit.saveAs('pending');
      await Future<void>.delayed(Duration.zero);
      verify(() => looper.settleLengthSettings()).called(1);
      when(() => looper.sessionRevision).thenReturn(1);
      settled.complete(EngineResult.ok);
      await save;
      expect(cubit.state.status, SessionStatus.failure);
      verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      );
    },
  );

  test(
    'session save waits for confirmed mix and refuses a replaced rig',
    () async {
      final settled = Completer<EngineResult>();
      when(() => looper.mixSettingsSettled).thenReturn(false);
      when(() => looper.settleMixSettings()).thenAnswer((_) => settled.future);
      when(repository.listSessions).thenAnswer((_) async => []);
      when(
        () => repository.bundlePath('mix'),
      ).thenAnswer((_) async => '/tmp/mix');
      final cubit = build();
      addTearDown(cubit.close);

      final save = cubit.saveAs('mix');
      await Future<void>.delayed(Duration.zero);
      verify(() => looper.settleMixSettings()).called(1);
      verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      );
      when(() => looper.sessionRevision).thenReturn(1);
      settled.complete(EngineResult.ok);
      await save;
      expect(cubit.state.status, SessionStatus.failure);
      verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      );
    },
  );

  test('Save As keeps the invocation rig through catalog lookup', () async {
    final catalog = Completer<List<SessionSummary>>();
    when(repository.listSessions).thenAnswer((_) => catalog.future);
    when(
      () => repository.bundlePath('new'),
    ).thenAnswer((_) async => '/tmp/new');
    final cubit = build();
    addTearDown(cubit.close);

    final save = cubit.saveAs('new');
    await Future<void>.delayed(Duration.zero);
    when(() => looper.sessionRevision).thenReturn(1);
    catalog.complete([]);
    await save;
    expect(cubit.state.status, SessionStatus.failure);
    verifyNever(
      () => repository.save(
        any(),
        chains: any(named: 'chains'),
        settings: any(named: 'settings'),
        pedalBindings: any(named: 'pedalBindings'),

        captureStillValid: any(named: 'captureStillValid'),
      ),
    );
  });

  group('SessionCubit exports', () {
    blocTest<SessionCubit, SessionState>(
      'exportMixdown writes mixdown.wav under the directory',
      setUp: () => when(
        () => repository.exportMixdown(any()),
      ).thenAnswer((_) async {}),
      build: build,
      act: (cubit) => cubit.exportMixdown(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.mixdownExported,
        ),
      ],
      verify: (_) => verify(
        () => repository.exportMixdown('/tmp/x/mixdown.wav'),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'exportStems writes stems under a stems folder',
      setUp: () => when(
        () => repository.exportStems(any()),
      ).thenAnswer((_) async {}),
      build: build,
      act: (cubit) => cubit.exportStems(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.stemsExported,
        ),
      ],
      verify: (_) =>
          verify(() => repository.exportStems('/tmp/x/stems')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'exportMixdown emits an unknown-classified failure when the repo throws',
      setUp: () => when(
        () => repository.exportMixdown(any()),
      ).thenThrow(Exception('disk full')),
      build: build,
      act: (cubit) => cubit.exportMixdown(),
      expect: () => const [
        SessionState(status: SessionStatus.working),
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: 'Exception: disk full',
        ),
      ],
    );
  });

  group('load failure classification', () {
    void stubRead(Object error) {
      when(
        () => repository.bundlePath(any()),
      ).thenAnswer((_) async => '/root/x');
      when(() => repository.read(any())).thenThrow(error);
    }

    blocTest<SessionCubit, SessionState>(
      'loadNamed classifies a sample-rate mismatch',
      setUp: () => stubRead(
        const SessionSampleRateMismatch(sessionRate: 44100, deviceRate: 48000),
      ),
      build: build,
      act: (cubit) => cubit.loadNamed('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.sampleRateMismatch),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed rejects an older version without replacing the open rig',
      setUp: () => stubRead(
        const SessionUnsupportedVersion(version: 7, supported: 8),
      ),
      build: build,
      seed: () => const SessionState(currentSessionName: 'Current'),
      act: (cubit) => cubit.loadNamed('X'),
      expect: () => [
        const SessionState(
          status: SessionStatus.working,
          currentSessionName: 'Current',
        ),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unsupportedVersion)
            .having((s) => s.currentSessionName, 'current', 'Current'),
      ],
      verify: (_) => verifyNever(() => looper.applySession(any())),
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed classifies a corrupt overdub-layer stack',
      setUp: () => stubRead(
        const SessionCorruptLayers(
          channel: 0,
          lane: 0,
          reason: 'layer count mismatch',
        ),
      ),
      build: build,
      act: (cubit) => cubit.loadNamed('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.corruptLayers),
      ],
    );
  });

  group('named sessions', () {
    const summaries = [SessionSummary(name: 'A'), SessionSummary(name: 'B')];

    void stubCatalog({List<SessionSummary> list = summaries}) {
      when(
        () => repository.bundlePath(any()),
      ).thenAnswer((inv) async => '/root/${inv.positionalArguments.first}');
      when(repository.listSessions).thenAnswer((_) async => list);
      when(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).thenAnswer((_) async => _session);
    }

    test('Save As and Save capture the current desired settings', () async {
      stubCatalog();
      when(() => looper.sessionTransport).thenReturn(
        const TransportState(
          tempoBpm: 109,
          tempoSource: TempoSource.manual,
          tsNum: 3,
          tsDen: 8,
        ),
      );
      when(() => looper.defaultOneShot).thenReturn(true);
      when(() => looper.trackOneShotOverrides).thenReturn(const {2: false});
      when(
        () => looper.trackRecordTimingOverrides,
      ).thenReturn(const {2: RecordTiming.bar});
      when(() => looper.trackOverdubDecayOverrides).thenReturn(const {2: 35});
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.saveAs('New');
      final first =
          verify(
                () => repository.save(
                  '/root/New',
                  chains: any(named: 'chains'),
                  settings: captureAny(named: 'settings'),

                  captureStillValid: any(named: 'captureStillValid'),
                ),
              ).captured.single
              as SessionSettings;
      expect(first.tempoBpm, 109);
      expect(first.tempoSource, TempoSource.manual);
      expect(first.tsNum, 3);
      expect(first.tsDen, 8);
      expect(first.defaultOneShot, isTrue);
      expect(first.trackOneShotOverrides, {2: false});
      expect(first.trackRecordTimingOverrides, {2: RecordTiming.bar});
      expect(first.trackOverdubDecayOverrides, {2: 35});

      when(() => looper.trackOneShotOverrides).thenReturn(const {});
      when(() => looper.trackRecordTimingOverrides).thenReturn(const {});
      when(() => looper.trackOverdubDecayOverrides).thenReturn(const {});
      await cubit.save();
      final second =
          verify(
                () => repository.save(
                  '/root/New',
                  chains: any(named: 'chains'),
                  settings: captureAny(named: 'settings'),

                  captureStillValid: any(named: 'captureStillValid'),
                ),
              ).captured.single
              as SessionSettings;
      expect(second.defaultOneShot, isTrue);
      expect(second.trackOneShotOverrides, isEmpty);
      expect(second.trackRecordTimingOverrides, isEmpty);
      expect(second.trackOverdubDecayOverrides, isEmpty);
    });

    test(
      'session load waits until an in-flight save has captured its rig',
      () async {
        final saveEntered = Completer<void>();
        final finishSave = Completer<Session>();
        final order = <String>[];
        when(repository.listSessions).thenAnswer((_) async => []);
        when(
          () => repository.bundlePath('A'),
        ).thenAnswer((_) async => '/root/A');
        when(
          () => repository.bundlePath('B'),
        ).thenAnswer((_) async => '/root/B');
        when(
          () => repository.save(
            '/root/A',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),

            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((_) {
          order.add('save A');
          saveEntered.complete();
          return finishSave.future;
        });
        when(() => repository.read('/root/B')).thenAnswer(
          (_) async =>
              (session: _session, laneStems: <(int, int), List<Float32List>>{}),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {
          order.add('apply B');
        });
        final cubit = build();
        addTearDown(cubit.close);

        final save = cubit.saveAs('A');
        await saveEntered.future;
        final load = cubit.loadNamed('B');
        await Future<void>.delayed(Duration.zero);
        expect(order, ['save A']);
        verifyNever(() => looper.applySession(any()));

        finishSave.complete(_session);
        await save;
        await load;
        expect(order, ['save A', 'apply B']);
        expect(cubit.state.currentSessionName, 'B');
      },
    );

    for (final refuseRestore in [false, true]) {
      test(
        'session write-then-throw restores or requires recovery '
        'refuseRestore=$refuseRestore',
        () async {
          final failing = _WriteThenThrowPersistence()
            ..refuseRestore = refuseRestore;
          mixPersistence = failing;
          mixSettings = MixSettingsCoordinator(
            repository: looper,
            persistence: failing,
            device: () => looper.state.status.deviceName,
          );
          when(
            () => repository.bundlePath('B'),
          ).thenAnswer((_) async => '/root/B');
          when(() => repository.read('/root/B')).thenAnswer(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          );
          final cubit = build();
          addTearDown(cubit.close);
          addTearDown(mixSettings.close);

          await cubit.loadNamed('B');

          expect(cubit.state.status, SessionStatus.failure);
          expect(cubit.state.currentSessionName, isNull);
          verifyNever(() => looper.applySession(any()));
          expect(failing.restores, 1);
          if (refuseRestore) {
            expect(failing.durable, 'incoming mix');
            expect(
              cubit.state.errorMessage,
              contains('Mix settings recovery required'),
            );
            failing.refuseRestore = false;
            expect((await mixSettings.recover()).isOk, isTrue);
          }
          expect(failing.durable, 'previous mix');
        },
      );
    }

    blocTest<SessionCubit, SessionState>(
      'saveAs writes a new named session, sets it current, and refreshes',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.saveAs('New'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'New')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) => verify(
        () => repository.save(
          '/root/New',
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs rejects a duplicate slug with nameCollision, writing nothing',
      setUp: () => stubCatalog(list: const [SessionSummary(name: 'Taken')]),
      build: build,
      act: (cubit) => cubit.saveAs('Taken!'), // folds to the existing "Taken"
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.nameCollision),
      ],
      verify: (_) => verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'save writes back to the open session with no prompt',
      setUp: stubCatalog,
      seed: () => const SessionState(currentSessionName: 'Open'),
      build: build,
      act: (cubit) => cubit.save(),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.working)
            .having((s) => s.currentSessionName, 'current', 'Open'),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'Open'),
      ],
      verify: (_) => verify(
        () => repository.save(
          '/root/Open',
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'save with no open session signals saveAsRequested and does not save',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.save(),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.outcome, 'outcome', SessionOutcome.saveAsRequested)
            .having((s) => s.currentSessionName, 'current', isNull),
      ],
      verify: (_) => verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed reads, applies through the looper, sets current, refreshes',
      setUp: () {
        stubCatalog();
        when(() => repository.read(any())).thenAnswer(
          (_) async =>
              (session: _session, laneStems: <(int, int), List<Float32List>>{}),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.loadNamed('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.loaded)
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) {
        verify(() => repository.read('/root/A')).called(1);
        verify(() => looper.applySession(any())).called(1);
        verify(performance.disarmAndFinalize).called(1);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'invalid effect placement refuses session before the live rig changes',
      setUp: () {
        stubCatalog();
        when(() => repository.read(any())).thenAnswer(
          (_) async => (
            session: const Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: [],
              allTracksChain:
                  '{"chainEnabled":true,"entries":['
                  '{"type":1,"placement":"sideways"}]}',
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        );
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.loadNamed('B'),
      expect: () => [
        isA<SessionState>().having(
          (state) => state.status,
          'status',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((state) => state.status, 'status', SessionStatus.failure)
            .having((state) => state.currentSessionName, 'current', 'A'),
      ],
      verify: (_) => verifyNever(() => looper.applySession(any())),
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed auto-disarms and finalizes before reading the bundle '
      '(D-ORCHESTRATE)',
      setUp: () {
        stubCatalog();
        when(() => repository.read(any())).thenAnswer(
          (_) async =>
              (session: _session, laneStems: <(int, int), List<Float32List>>{}),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.loadNamed('A'),
      verify: (_) {
        verifyInOrder([
          performance.disarmAndFinalize,
          () => repository.read(any()),
          () => looper.applySession(any()),
        ]);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'loadNamed leaves the live rig alone when performance disarm refuses',
      setUp: () {
        when(
          performance.disarmAndFinalize,
        ).thenAnswer((_) async => EngineResult.device);
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.loadNamed('B'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'status',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.currentSessionName, 'current', 'A'),
      ],
      verify: (_) {
        verify(performance.disarmAndFinalize).called(1);
        verifyNever(() => repository.read(any()));
        verifyNever(() => looper.applySession(any()));
      },
    );

    blocTest<SessionCubit, SessionState>(
      'renameSession makes the current pointer follow a rename of the open one',
      setUp: () {
        stubCatalog();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.renameSession('A', 'A2'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.renamed)
            .having((s) => s.currentSessionName, 'current', 'A2'),
      ],
      verify: (_) =>
          verify(() => repository.renameSession('A', 'A2')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'renameSession leaves the current pointer alone for a non-open session',
      setUp: () {
        stubCatalog();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () => const SessionState(currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.renameSession('B', 'B2'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.currentSessionName, 'current', 'A'),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'deleteSession clears the current pointer and never touches the rig',
      setUp: () {
        stubCatalog(list: const [SessionSummary(name: 'B')]);
        when(() => repository.deleteSession(any())).thenAnswer((_) async {});
      },
      seed: () =>
          const SessionState(currentSessionName: 'A', sessions: summaries),
      build: build,
      act: (cubit) => cubit.deleteSession('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.deleted)
            .having((s) => s.currentSessionName, 'current', isNull)
            .having((s) => s.sessions, 'sessions', const [
              SessionSummary(name: 'B'),
            ]),
      ],
      verify: (_) {
        verify(() => repository.deleteSession('A')).called(1);
        verifyNever(() => looper.applySession(any()));
      },
    );

    blocTest<SessionCubit, SessionState>(
      'duplicateSession copies the bundle and refreshes the catalog',
      setUp: () {
        stubCatalog();
        when(
          () => repository.duplicateSession(any(), any()),
        ).thenAnswer((_) async {});
      },
      seed: () =>
          const SessionState(currentSessionName: 'A', sessions: summaries),
      build: build,
      act: (cubit) => cubit.duplicateSession('A', 'A copy'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            // The open session is unchanged — a duplicate is a disk copy.
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) =>
          verify(() => repository.duplicateSession('A', 'A copy')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs with an unsanitizable name fails (invalid), writing nothing',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.saveAs('   '),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unknown),
      ],
      verify: (_) => verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'refreshSessions loads the catalog into state',
      setUp: stubCatalog,
      build: build,
      act: (cubit) => cubit.refreshSessions(),
      expect: () => [
        isA<SessionState>().having((s) => s.sessions, 'sessions', summaries),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'a write-back preserves the open session + catalog across the '
      'transition (C1)',
      setUp: () {
        when(
          () => repository.bundlePath(any()),
        ).thenAnswer((_) async => '/root/Open');
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),

            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((_) async => _session);
        // A write-back re-lists so an open Sessions dialog's date column
        // shows the save it just made.
        when(repository.listSessions).thenAnswer((_) async => summaries);
      },
      seed: () =>
          const SessionState(currentSessionName: 'Open', sessions: summaries),
      build: build,
      act: (cubit) => cubit.save(), // write-back to the open session
      verify: (_) => verify(repository.listSessions).called(1),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.working)
            .having((s) => s.currentSessionName, 'current', 'Open')
            .having((s) => s.sessions, 'sessions', summaries),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.saved)
            .having((s) => s.currentSessionName, 'current', 'Open')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
    );
  });

  group('isClosed guard', () {
    // These exercise `_run`'s three branches (success, `on SessionException`,
    // `on Object`) and `refreshSessions` all closing mid-flight: the mocked
    // repository call is left pending on a Completer, the cubit is closed
    // while that await is outstanding, and only then is the Completer
    // resolved — resuming the suspended action after `isClosed` is already
    // true. Without a guard, the post-await `emit` throws `StateError`, and
    // (for the success path) `_run`'s `on Object catch` branch re-emits
    // unguarded too, so the error propagates out of the returned Future.
    // Plain `test()` is used instead of `blocTest()` here because the
    // assertion is "the returned Future completes without throwing", not a
    // state-sequence `blocTest`'s `expect` is shaped for.
    test(
      'exportMixdown does not throw when the cubit closes while the '
      'repository call is still pending (success path)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.exportMixdown(any()),
        ).thenAnswer((_) => completer.future);

        final cubit = build();
        final future = cubit.exportMixdown();

        await cubit.close();
        completer.complete();

        await expectLater(future, completes);
      },
    );

    test(
      'exportMixdown does not throw when the cubit closes while the '
      'repository call is still pending (on SessionException catch)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.exportMixdown(any()),
        ).thenAnswer((_) => completer.future);

        final cubit = build();
        final future = cubit.exportMixdown();

        await cubit.close();
        completer.completeError(const SessionNameCollision(slug: 'x'));

        await expectLater(future, completes);
      },
    );

    test(
      'exportMixdown does not throw when the cubit closes while the '
      'repository call is still pending (on Object catch)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.exportMixdown(any()),
        ).thenAnswer((_) => completer.future);

        final cubit = build();
        final future = cubit.exportMixdown();

        await cubit.close();
        completer.completeError(Exception('disk full'));

        await expectLater(future, completes);
      },
    );

    test(
      'refreshSessions does not throw when the cubit closes while the '
      'repository call is still pending',
      () async {
        final completer = Completer<List<SessionSummary>>();
        when(repository.listSessions).thenAnswer((_) => completer.future);

        final cubit = build();
        final future = cubit.refreshSessions();

        await cubit.close();
        completer.complete(const []);

        await expectLater(future, completes);
      },
    );
  });

  group('SessionCubit pedal remap (part 6b)', () {
    test(
      'splits the seam across the apply: releases held momentaries BEFORE it '
      '(so the restore lands on the outgoing rig) and commits the new set '
      'only AFTER it',
      () async {
        final order = <String>[];
        when(
          () => repository.bundlePath(any()),
        ).thenAnswer((_) async => '/b/X');
        when(() => repository.read(any())).thenAnswer(
          (_) async => (
            session: const Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: [],
              pedalBindings: '[{"button":"stop","target":"t"}]',
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {
          order.add('applySession');
        });
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = SessionCubit(
          runClickVolumeExclusive: _readyClick,
          currentDurableClickVolume: () => 1,
          fxPersistence: FxChainPersistence(looper: looper),
          repository: repository,
          looper: looper,
          performance: performance,
          mixSettings: mixSettings,
          mixPersistence: mixPersistence,
          exportDirectory: () async => '/tmp/x',
          onPedalBindings: (_) => order.add('onPedalBindings'),
          releaseHeldBindings: () => order.add('releaseHeldBindings'),
        );
        addTearDown(cubit.close);

        await cubit.loadNamed('X');

        expect(order, [
          'releaseHeldBindings',
          'applySession',
          'onPedalBindings',
        ]);
      },
    );

    test(
      'a FAILED apply never commits the remap — the pedal must not end up '
      'dispatching a session that never loaded against the rig still live',
      () async {
        var committed = false;
        when(
          () => repository.bundlePath(any()),
        ).thenAnswer((_) async => '/b/X');
        when(() => repository.read(any())).thenAnswer(
          (_) async => (
            session: const Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: [],
              pedalBindings: '[{"button":"stop","target":"t"}]',
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        );
        when(
          () => looper.applySession(any()),
        ).thenThrow(StateError('engine refused the rig'));
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = SessionCubit(
          runClickVolumeExclusive: _readyClick,
          currentDurableClickVolume: () => 1,
          fxPersistence: FxChainPersistence(looper: looper),
          repository: repository,
          looper: looper,
          performance: performance,
          mixSettings: mixSettings,
          mixPersistence: mixPersistence,
          exportDirectory: () async => '/tmp/x',
          onPedalBindings: (_) => committed = true,
        );
        addTearDown(cubit.close);

        await cubit.loadNamed('X');

        expect(cubit.state.status, SessionStatus.failure);
        expect(committed, isFalse);
        verify(looper.stopEngine).called(1);
      },
    );

    test('saves the remap IN FORCE, so a session can acquire one', () async {
      when(() => repository.bundlePath(any())).thenAnswer((_) async => '/b/X');
      when(repository.listSessions).thenAnswer((_) async => const []);
      when(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).thenAnswer((_) async => _session);

      final cubit = SessionCubit(
        runClickVolumeExclusive: _readyClick,
        currentDurableClickVolume: () => 1,
        fxPersistence: FxChainPersistence(looper: looper),
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
        exportDirectory: () async => '/tmp/x',
        currentPedalBindings: () => 'the-remap-in-force',
      );
      addTearDown(cubit.close);

      await cubit.saveAs('X');

      verify(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: 'the-remap-in-force',

          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1);
    });
  });
}
