import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:backing_repository/backing_repository.dart'
    show BackingEnd, BackingTransport;
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/backing/application/session_backing.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/audio_tempo.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/backing_fixture.dart';
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

class _BootStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fail = false;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'all_tracks_fx_chain') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      if (fail) throw StateError('boot storage refused');
    }
    await super.setString(key, value);
  }
}

const _conversion = SessionConversion(
  fromVersion: 7,
  original: '{"version": 7}',
  manifest: {'version': 12},
  notes: ['monitors[0].volume: 1.5 lowered to the live-input ceiling of 1'],
  changes: {SessionConversionChange.monitorLevelLowered},
);

const _session = Session(
  sampleRate: 48000,
  channels: 1,
  baseLengthFrames: 0,
  tracks: [],
);

class _ClickVolumeOwner extends Fake implements SettingsOwner<double, double?> {
  @override
  double get durable => 1;
}

class _ClickModeOwner extends Fake implements SettingsOwner<ClickMode, int?> {
  @override
  ClickMode get durable => ClickMode.off;
}

class _RecordStartOwner extends Fake
    implements SettingsOwner<RecordStartSettings, StoredRecordStart> {
  @override
  RecordStartSettings get durable =>
      RecordStartSettings(countInBars: 0, soundStart: false);
}

/// The Record length owner's Session exclusion as the registry runs it:
/// it waits for a pending receipt, whatever the receipt's result.
class _LengthOwner extends Fake implements SettingsOwner<Object, Object?> {
  _LengthOwner(this.looper);
  final LooperRepository looper;

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    if (!looper.lengthSettingsSettled) await looper.settleLengthSettings();
    return operation();
  }
}

class _TempoOwner extends Fake implements TempoSettings {
  @override
  final clickVolumeOwner = _ClickVolumeOwner();

  @override
  final clickModeOwner = _ClickModeOwner();

  @override
  final recordStartOwner = _RecordStartOwner();
}

class _DecayOwner extends Fake implements SettingsOwner<DecaySnapshot, int?> {
  _DecayOwner(this.looper);
  final LooperRepository looper;

  @override
  DecaySnapshot get durable => DecaySnapshot(
    defaultPercent: looper.defaultOverdubDecay,
    trackOverrides: looper.trackOverdubDecayOverrides,
  );
}

class _OneShotOwner extends Fake
    implements SettingsOwner<OneShotSnapshot, bool?> {
  _OneShotOwner(this.looper);
  final LooperRepository looper;

  @override
  OneShotSnapshot get durable => OneShotSnapshot(
    defaultOneShot: looper.defaultOneShot,
    trackOverrides: looper.trackOneShotOverrides,
  );
}

class _InheritOwner<T extends Object> extends Fake
    implements SettingsOwner<InheritSnapshot<T>, bool?> {
  _InheritOwner(this.durable);

  @override
  final InheritSnapshot<T> durable;
}

class _PlaybackOwner extends Fake implements PlaybackSettings {
  _PlaybackOwner(LooperRepository looper)
    : decayOwner = _DecayOwner(looper),
      oneShotOwner = _OneShotOwner(looper);

  @override
  final SettingsOwner<DecaySnapshot, int?> decayOwner;

  @override
  final SettingsOwner<OneShotSnapshot, bool?> oneShotOwner;

  @override
  final SettingsOwner<InheritSnapshot<bool>, bool?> followTempoOwner =
      _InheritOwner(
        InheritSnapshot(defaultValue: true, trackOverrides: const {}),
      );

  @override
  final SettingsOwner<InheritSnapshot<PitchMode>, bool?> pitchModeOwner =
      _InheritOwner(
        InheritSnapshot(
          defaultValue: PitchMode.unchanged,
          trackOverrides: const {},
        ),
      );
}

class _RecordOwner extends Fake implements RecordSettings {
  _RecordOwner(this.looper);
  final LooperRepository looper;

  @override
  RecordLengthSnapshot get durableRecordLengthSnapshot => RecordLengthSnapshot(
    defaultBars: looper.sessionTransport.defaultLengthPresetBars,
    trackOverrides: looper.trackLengthPresetOverrides,
    mode: looper.sessionTransport.looperMode,
    captureLocked: false,
  );
}

class _TimingOwner extends Fake implements RecordTimingSettings {
  _TimingOwner(this.looper);
  final LooperRepository looper;

  @override
  RecordTimingSnapshot get durableRecordTimingSnapshot => RecordTimingSnapshot(
    defaultTiming: looper.defaultRecordTiming,
    rememberedDivision: looper.sessionTransport.quantizeDiv,
    trackOverrides: looper.trackRecordTimingOverrides,
    captureLocked: false,
  );
}

void main() {
  late SessionRepository repository;

  /// What the mocked repository's fingerprint of the live rig reads; a test
  /// changes it to stand for an edit.
  var liveFingerprint = 'fp';
  late LooperRepository looper;
  late PerformanceRepository performance;
  late MixSettingsCoordinator mixSettings;
  late FxChainPersistence fxPersistence;
  late SessionSettingsCoordinator captureSettings;
  late MixSettingsPersistence mixPersistence;
  late SettingsRepository settings;
  late FadeSettings fade;
  late StreamController<LooperState> looperStates;

  setUpAll(() {
    registerFallbackValue(const SessionRig());
    registerFallbackValue(const SessionChains());
    registerFallbackValue(const SessionSettings());
    registerFallbackValue(_conversion);
  });

  SessionSettingsCoordinator buildCapture() => SessionSettingsCoordinator(
    fade: fade,
    looper: looper,
    mix: mixSettings,
    fx: fxPersistence,
    owners: SettingsOwners([_LengthOwner(looper), ...fade.owners]),
    tempo: _TempoOwner(),
    playback: _PlaybackOwner(looper),
    record: _RecordOwner(looper),
    timing: _TimingOwner(looper),
  );

  setUp(() async {
    liveFingerprint = 'fp';
    repository = _MockSessionRepository();
    when(repository.newSessionId).thenAnswer((_) async => 'new');
    when(repository.listFolders).thenAnswer((_) async => const []);
    when(
      () => repository.fingerprint(
        settings: any(named: 'settings'),
        chains: any(named: 'chains'),
        pedalBindings: any(named: 'pedalBindings'),
      ),
    ).thenAnswer((_) => liveFingerprint);
    when(
      () => repository.releaseSessionId(any()),
    ).thenAnswer((_) async {});
    looper = _MockLooperRepository();
    performance = _MockPerformanceRepository();
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    addTearDown(looperStates.close);
    settings = SettingsRepository(store: FakeKeyValueStore());
    fade = FadeSettings(
      repository: looper,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    await fade.load();
    addTearDown(fade.close);
    mixPersistence = SettingsMixPersistence(settings);
    // Default chain getters so the save path's _captureChains() has something
    // to read; individual tests override as needed.
    when(looper.allLaneChains).thenReturn(const {});
    when(() => looper.laneMuted(any(), any())).thenReturn(false);
    when(looper.allTrackChains).thenReturn(const {});
    when(looper.allOutputChains).thenReturn(const {});
    when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
    when(looper.allMonitors).thenReturn(const {});
    when(() => looper.sessionTransport).thenReturn(const TransportState());
    when(() => looper.lengthSettingsSettled).thenReturn(true);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.mixRecoveryRequired).thenReturn(false);
    when(
      () => looper.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
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
    fxPersistence = FxChainPersistence(looper: looper);
    addTearDown(fxPersistence.close);
    captureSettings = buildCapture();
    // open's auto-disarm-before-load orchestration; a no-op success by
    // default since nothing is armed in these tests.
    when(
      performance.disarmAndFinalize,
    ).thenAnswer((_) async => EngineResult.ok);
  });

  SessionCubit build() => SessionCubit(
    guards: GuardRegistry(),
    captureSettings: captureSettings,
    fxPersistence: fxPersistence,
    settings: settings,
    repository: repository,
    looper: looper,
    performance: performance,
    mixSettings: mixSettings,
    mixPersistence: mixPersistence,
  );

  for (final accepted in [true, false]) {
    test(
      'Save waits for a pending length receipt, and writes the requested '
      'value even when it ends owed; accepted=$accepted',
      () async {
        final settled = Completer<EngineResult>();
        when(() => looper.lengthSettingsSettled).thenReturn(false);
        when(
          () => looper.settleLengthSettings(),
        ).thenAnswer((_) => settled.future);
        when(repository.listSessions).thenAnswer((_) async => []);
        when(
          () => repository.bundlePathOf('new'),
        ).thenAnswer((_) async => '/tmp/pending');
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),

            name: any(named: 'name'),
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

            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        );
        when(
          () => looper.sessionTransport,
        ).thenReturn(const TransportState(defaultLengthPresetBars: 8));
        settled.complete(accepted ? EngineResult.ok : EngineResult.invalid);
        await save;
        // An owed value is the durable one: Save never refuses it.
        expect(cubit.state.status, SessionStatus.success);
        final settings =
            verify(
                  () => repository.save(
                    '/tmp/pending',
                    chains: any(named: 'chains'),
                    settings: captureAny(named: 'settings'),
                    pedalBindings: any(named: 'pedalBindings'),

                    name: any(named: 'name'),
                    captureStillValid: any(named: 'captureStillValid'),
                  ),
                ).captured.single
                as SessionSettings;
        expect(settings.defaultLengthPresetBars, 8);
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
        () => repository.bundlePathOf('new'),
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

          name: any(named: 'name'),
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
        () => repository.bundlePathOf('new'),
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

          name: any(named: 'name'),
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

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      );
    },
  );

  test('Save As keeps the invocation rig through catalog lookup', () async {
    final catalog = Completer<List<SessionSummary>>();
    when(repository.listSessions).thenAnswer((_) => catalog.future);
    when(
      () => repository.bundlePathOf('new'),
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

        name: any(named: 'name'),
        captureStillValid: any(named: 'captureStillValid'),
      ),
    );
    // The id was reserved before the refusal; giving it back keeps an empty
    // directory from listing as a folder.
    verify(() => repository.releaseSessionId('new')).called(1);
  });

  group('load failure classification', () {
    void stubRead(Object error) {
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((_) async => '/root/x');
      when(
        () => repository.open(any(), liveSettings: any(named: 'liveSettings')),
      ).thenThrow(error);
    }

    blocTest<SessionCubit, SessionState>(
      'an Open that fails names the session it tried',
      setUp: () => stubRead(StateError('audio device must be running')),
      build: build,
      act: (cubit) => cubit.open('X'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.failedSessionId, 'failed', 'X'),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'open classifies a sample-rate mismatch',
      setUp: () => stubRead(
        const SessionSampleRateMismatch(sessionRate: 44100, deviceRate: 48000),
      ),
      build: build,
      act: (cubit) => cubit.open('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.sampleRateMismatch),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'open rejects a newer version without replacing the open rig',
      setUp: () => stubRead(
        const SessionUnsupportedVersion(version: 13, supported: 12),
      ),
      build: build,
      seed: () => const SessionState(
        currentSessionId: 'Current',
        currentSessionName: 'Current',
      ),
      act: (cubit) => cubit.open('X'),
      expect: () => [
        const SessionState(
          status: SessionStatus.working,
          currentSessionId: 'Current',
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
      'open refuses an unconvertible older session untouched',
      setUp: () => stubRead(
        const SessionUnconvertible(version: 0, reason: 'older than schema 1'),
      ),
      build: build,
      act: (cubit) => cubit.open('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.unconvertible),
      ],
      verify: (_) {
        verifyNever(() => looper.applySession(any()));
        verifyNever(() => repository.commitConversion(any(), any()));
      },
    );

    blocTest<SessionCubit, SessionState>(
      'open classifies a corrupt overdub-layer stack',
      setUp: () => stubRead(
        const SessionCorruptLayers(
          channel: 0,
          lane: 0,
          reason: 'layer count mismatch',
        ),
      ),
      build: build,
      act: (cubit) => cubit.open('X'),
      expect: () => [
        const SessionState(status: SessionStatus.working),
        isA<SessionState>()
            .having((s) => s.status, 'status', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.corruptLayers),
      ],
    );
  });

  group('named sessions', () {
    const summaries = [
      SessionSummary(id: 'A', name: 'A'),
      SessionSummary(id: 'B', name: 'B'),
    ];

    void stubCatalog({List<SessionSummary> list = summaries}) {
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((inv) async => '/root/${inv.positionalArguments.first}');
      when(repository.listSessions).thenAnswer((_) async => list);
      when(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).thenAnswer((_) async => _session);
    }

    blocTest<SessionCubit, SessionState>(
      'audio load without processing refuses before disarm or storage',
      setUp: () {
        stubCatalog();
        mixPersistence = _WriteThenThrowPersistence();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: const Session(
                sampleRate: 48000,
                channels: 1,
                baseLengthFrames: 128,
                tracks: [
                  SessionTrack(
                    fadeAmount: 1,
                    reversed: false,
                    channel: 0,
                    multiple: 1,
                    lengthFrames: 128,
                    lanes: [
                      SessionLane(
                        lane: 0,
                        volume: 1,
                        muted: false,
                        outputMask: 1,
                        inputChannel: 0,
                        layers: [SessionLayer(file: 'track0_lane0_L0.wav')],
                        history: TrackHistory.none,
                      ),
                    ],
                  ),
                ],
              ),
              laneStems: {
                (0, 0): [Float32List(128)],
              },
            ),
          ),
        );
      },
      build: build,
      act: (cubit) => cubit.open('A'),
      verify: (cubit) {
        expect(cubit.state.status, SessionStatus.failure);
        expect(
          cubit.state.errorMessage,
          contains('audio device must be running'),
        );
        expect(
          (mixPersistence as _WriteThenThrowPersistence).durable,
          'previous mix',
        );
        expect((mixPersistence as _WriteThenThrowPersistence).restores, 0);
        verifyNever(performance.disarmAndFinalize);
        verifyNever(() => looper.applySession(any()));
        verifyNever(looper.blockStartForSessionBoot);
        verifyNever(looper.stopEngine);
        expect(fxPersistence.sessionTransitionActive, isFalse);
      },
    );

    for (final failBoot in [false, true]) {
      late _BootStore boot;
      var blocked = false;
      blocTest<SessionCubit, SessionState>(
        'boot admission remains held through persistence and retry '
        'fail=$failBoot',
        setUp: () {
          stubCatalog();
          blocked = false;
          boot = _BootStore()..fail = failBoot;
          settings = SettingsRepository(store: boot);
          when(
            looper.blockStartForSessionBoot,
          ).thenAnswer((_) => blocked = true);
          when(
            looper.clearSessionBootStartBlock,
          ).thenAnswer((_) => blocked = false);
          when(
            () => repository.open(
              any(),
              liveSettings: any(named: 'liveSettings'),
            ),
          ).thenAnswer(
            _opened(
              (_) async => (
                session: _session,
                laneStems: <(int, int), List<Float32List>>{},
              ),
            ),
          );
          when(() => looper.applySession(any())).thenAnswer((_) async {
            expect(blocked, isTrue);
          });
        },
        build: build,
        act: (cubit) async {
          final load = cubit.open('A');
          await boot.entered.future;
          expect(blocked, isTrue);
          expect(cubit.state.status, SessionStatus.working);
          boot.release.complete();
          await load;
          expect(blocked, failBoot);
          if (failBoot) {
            expect(cubit.state.bootRecoveryRequired, isTrue);
            verify(looper.stopEngine).called(1);
            boot.fail = false;
            await cubit.retryLoadedSession();
          }
        },
        verify: (cubit) {
          expect(blocked, isFalse);
          expect(cubit.state.outcome, SessionOutcome.loaded);
          verify(() => looper.applySession(any())).called(1);
          expect(fxPersistence.sessionTransitionActive, isFalse);
        },
      );
    }

    blocTest<SessionCubit, SessionState>(
      'failed apply cancels its boot admission block',
      setUp: () {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenThrow(StateError('refused'));
      },
      build: build,
      act: (cubit) => cubit.open('A'),
      verify: (cubit) {
        expect(cubit.state.status, SessionStatus.failure);
        verifyInOrder([
          looper.blockStartForSessionBoot,
          () => looper.applySession(any()),
          looper.stopEngine,
          looper.clearSessionBootStartBlock,
        ]);
        expect(fxPersistence.sessionTransitionActive, isFalse);
      },
    );

    test('an open is refused at its commit while an audio change is in '
        'flight, before anything changes (#1198)', () async {
      stubCatalog();
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((_) async => '/root/A');
      when(
        () => repository.open(any(), liveSettings: any(named: 'liveSettings')),
      ).thenAnswer(
        (_) async => (
          bundle: (
            session: _session,
            laneStems: <(int, int), List<Float32List>>{},
          ),
          conversion: null,
        ),
      );
      final guards = GuardRegistry()
        ..enter(
          GuardKind.deviceChange,
          const GuardScope.internal(),
          purpose: 'audio apply',
        );
      final cubit = SessionCubit(
        captureSettings: captureSettings,
        fxPersistence: fxPersistence,
        settings: settings,
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
        guards: guards,
      );
      addTearDown(cubit.close);

      await cubit.open('A');
      expect(cubit.state.status, SessionStatus.failure);
      expect(cubit.state.error, SessionError.busy);
      expect(cubit.state.refusedBy, GuardKind.deviceChange);
      // Counted like every other failure, so the Library shows it once.
      expect(cubit.state.failureCount, 1);
      verifyNever(performance.disarmAndFinalize);
      verifyNever(() => looper.applySession(any()));
      expect(fxPersistence.sessionTransitionActive, isFalse);
      expect(guards.active.single.kind, GuardKind.deviceChange);
    });

    test('an open holds the apply guard from its commit to its end '
        '(#1198)', () async {
      stubCatalog();
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((_) async => '/root/A');
      when(
        () => repository.open(any(), liveSettings: any(named: 'liveSettings')),
      ).thenAnswer(
        (_) async => (
          bundle: (
            session: _session,
            laneStems: <(int, int), List<Float32List>>{},
          ),
          conversion: null,
        ),
      );
      final guards = GuardRegistry();
      final seenAtFinalize = <GuardKind>[];
      final seenAtApply = <GuardKind>[];
      when(performance.disarmAndFinalize).thenAnswer((_) async {
        seenAtFinalize.addAll(guards.active.map((o) => o.kind));
        return EngineResult.ok;
      });
      when(() => looper.applySession(any())).thenAnswer((_) async {
        seenAtApply.addAll(guards.active.map((o) => o.kind));
        // A take cannot start under an apply.
        expect(
          guards.blockers(GuardKind.capture, const GuardScope.internal()),
          isNotEmpty,
        );
      });
      final cubit = SessionCubit(
        captureSettings: captureSettings,
        fxPersistence: fxPersistence,
        settings: settings,
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
        guards: guards,
      );
      addTearDown(cubit.close);

      await cubit.open('A');
      expect(seenAtFinalize, [GuardKind.sessionApply]);
      expect(seenAtApply, [GuardKind.sessionApply]);
      expect(guards.active, isEmpty);
    });

    test('load closes control admission before the catalog read', () async {
      stubCatalog();
      final read = Completer<SessionBundle>();
      final entered = Completer<void>();
      when(
        () => repository.open(any(), liveSettings: any(named: 'liveSettings')),
      ).thenAnswer(
        _opened((_) {
          entered.complete();
          return read.future;
        }),
      );
      final cubit = build();
      addTearDown(cubit.close);

      final load = cubit.open('A');
      expect(fxPersistence.sessionTransitionActive, isTrue);
      await entered.future;
      read.completeError(StateError('bundle unavailable'));
      await load;
      expect(cubit.state.status, SessionStatus.failure);
      expect(fxPersistence.sessionTransitionActive, isFalse);
      verifyNever(() => looper.applySession(any()));
    });

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
                  '/root/new',
                  chains: any(named: 'chains'),
                  settings: captureAny(named: 'settings'),

                  name: any(named: 'name'),
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
                  '/root/new',
                  chains: any(named: 'chains'),
                  settings: captureAny(named: 'settings'),

                  name: any(named: 'name'),
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
          () => repository.bundlePathOf('new'),
        ).thenAnswer((_) async => '/root/new');
        when(
          () => repository.bundlePathOf('B'),
        ).thenAnswer((_) async => '/root/B');
        when(
          () => repository.save(
            '/root/new',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),

            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((_) {
          order.add('save A');
          saveEntered.complete();
          return finishSave.future;
        });
        when(
          () => repository.open(
            '/root/B',
            liveSettings: any(named: 'liveSettings'),
          ),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {
          order.add('apply B');
        });
        final cubit = build();
        addTearDown(cubit.close);

        final save = cubit.saveAs('A');
        await saveEntered.future;
        final load = cubit.open('B');
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
          captureSettings = buildCapture();
          when(
            () => repository.bundlePathOf('B'),
          ).thenAnswer((_) async => '/root/B');
          when(
            () => repository.open(
              '/root/B',
              liveSettings: any(named: 'liveSettings'),
            ),
          ).thenAnswer(
            _opened(
              (_) async => (
                session: _session,
                laneStems: <(int, int), List<Float32List>>{},
              ),
            ),
          );
          when(repository.listSessions).thenAnswer((_) async => const []);
          final cubit = build();
          addTearDown(cubit.close);
          addTearDown(mixSettings.close);

          await cubit.open('B');

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
            .having((s) => s.outcome, 'outcome', SessionOutcome.savedAs)
            .having((s) => s.currentSessionId, 'id', 'new')
            .having((s) => s.currentSessionName, 'current', 'New')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) => verify(
        () => repository.save(
          '/root/new',
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs rejects a duplicate slug with nameCollision, writing nothing',
      setUp: () => stubCatalog(
        list: const [SessionSummary(id: 'Taken', name: 'Taken')],
      ),
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

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ),
    );

    blocTest<SessionCubit, SessionState>(
      'saveAs accepts a name that differs from a saved one only by case, '
      'as the case-sensitive appliance always has',
      setUp: () => stubCatalog(
        list: const [SessionSummary(id: 'Song', name: 'Song')],
      ),
      build: build,
      act: (cubit) => cubit.saveAs('song'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.currentSessionName, 'current', 'song'),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'save writes back to the open session with no prompt',
      setUp: stubCatalog,
      seed: () => const SessionState(
        currentSessionId: 'Open',
        currentSessionName: 'Open',
      ),
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

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'save with no open session saves under the next automatic name and '
      'makes it current (D4)',
      setUp: () {
        stubCatalog();
        when(
          () => repository.nextAutomaticName(any()),
        ).thenAnswer((_) async => 'New loop 2');
      },
      build: build,
      act: (cubit) => cubit.save(),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.savedAs)
            .having((s) => s.currentSessionId, 'id', 'new')
            .having((s) => s.currentSessionName, 'name', 'New loop 2'),
      ],
      verify: (_) {
        verify(
          () => repository.nextAutomaticName(SessionCubit.automaticNamePrefix),
        ).called(1);
        verify(
          () => repository.save(
            '/root/new',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: 'New loop 2',
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).called(1);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'a failed write-back reports saveFailed and leaves the open session '
      'and catalog as they were (19/05)',
      setUp: () {
        stubCatalog();
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenThrow(const FileSystemException('disk full'));
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
      build: build,
      act: (cubit) => cubit.save(),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.saveFailed)
            .having((s) => s.currentSessionId, 'id', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'a failed Save as reports saveFailed, gives the id back and keeps the '
      'open session',
      setUp: () {
        stubCatalog();
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenThrow(const FileSystemException('disk full'));
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
      build: build,
      act: (cubit) => cubit.saveAs('Fresh'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.saveFailed)
            .having((s) => s.currentSessionId, 'id', 'A'),
      ],
      verify: (_) => verify(() => repository.releaseSessionId('new')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'open reads, applies through the looper, sets current, refreshes',
      setUp: () {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.open('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.working)
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.bootRecoveryRequired, 'boot debt', isTrue),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.loaded)
            .having((s) => s.currentSessionId, 'id', 'A')
            .having((s) => s.currentSessionName, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) {
        verify(
          () => repository.open(
            '/root/A',
            liveSettings: any(named: 'liveSettings'),
          ),
        ).called(1);
        verify(() => looper.applySession(any())).called(1);
        verify(performance.disarmAndFinalize).called(1);
        verifyNever(() => repository.commitConversion(any(), any()));
      },
    );

    group('an older session', () {
      void stubConvertedOpen() {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          (_) async => (
            bundle: (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
            conversion: _conversion,
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      }

      blocTest<SessionCubit, SessionState>(
        'is written back after it applies and the player is told what changed',
        setUp: () {
          stubConvertedOpen();
          when(
            () => repository.commitConversion(any(), any()),
          ).thenAnswer((_) async => true);
        },
        build: build,
        act: (cubit) => cubit.open('A'),
        skip: 2,
        expect: () => [
          isA<SessionState>()
              .having((s) => s.outcome, 'outcome', SessionOutcome.loaded)
              .having(
                (s) => s.conversion,
                'conversion',
                const SessionConversionNotice(
                  fromVersion: 7,
                  written: true,
                  changes: {SessionConversionChange.monitorLevelLowered},
                ),
              ),
        ],
        verify: (_) {
          verifyInOrder([
            () => looper.applySession(any()),
            () => repository.commitConversion('/root/A', _conversion),
          ]);
          // The settings the old session never carried come from the
          // player's live owners.
          final live =
              verify(
                    () => repository.open(
                      '/root/A',
                      liveSettings: captureAny(named: 'liveSettings'),
                    ),
                  ).captured.single
                  as SessionSettings Function();
          expect(live().recDub, captureSettings.current().recDub);
        },
      );

      blocTest<SessionCubit, SessionState>(
        'that cannot be written back still loads, and says the original is '
        'unchanged',
        setUp: () {
          stubConvertedOpen();
          when(
            () => repository.commitConversion(any(), any()),
          ).thenThrow(const FileSystemException('read-only'));
        },
        build: build,
        act: (cubit) => cubit.open('A'),
        skip: 2,
        expect: () => [
          isA<SessionState>()
              .having((s) => s.status, 'st', SessionStatus.success)
              .having((s) => s.outcome, 'outcome', SessionOutcome.loaded)
              .having((s) => s.conversion?.written, 'written', isFalse),
        ],
      );

      blocTest<SessionCubit, SessionState>(
        'whose manifest changed before the write-back says nothing was written',
        setUp: () {
          stubConvertedOpen();
          when(
            () => repository.commitConversion(any(), any()),
          ).thenAnswer((_) async => false);
        },
        build: build,
        act: (cubit) => cubit.open('A'),
        skip: 2,
        expect: () => [
          isA<SessionState>().having(
            (s) => s.conversion?.written,
            'written',
            isFalse,
          ),
        ],
      );

      blocTest<SessionCubit, SessionState>(
        'is not written back when it does not apply',
        setUp: () {
          stubConvertedOpen();
          when(
            () => looper.applySession(any()),
          ).thenThrow(StateError('refused'));
        },
        build: build,
        act: (cubit) => cubit.open('A'),
        verify: (_) =>
            verifyNever(() => repository.commitConversion(any(), any())),
      );
    });

    group('Open preserves the outgoing rig (D7)', () {
      void stubOpen() {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
        when(
          () => repository.nextAutomaticName(any()),
        ).thenAnswer((_) async => 'New loop 3');
      }

      VerificationResult verifySavedTo(String path, {String? name}) => verify(
        () => repository.save(
          path,
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),
          name: name ?? any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      );

      void verifyNoSave() => verifyNever(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),
          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      );

      test('the target is read first, then a changed named rig is saved to '
          'its identity, then the target applied', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();
        clearInteractions(repository);
        liveFingerprint = 'edited';

        await cubit.open('B');

        verifyInOrder([
          () => repository.open(
            '/root/B',
            liveSettings: any(named: 'liveSettings'),
          ),
          () => repository.save(
            '/root/A',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: 'A',
            captureStillValid: any(named: 'captureStillValid'),
          ),
          () => looper.applySession(any()),
        ]);
        expect(cubit.state.currentSessionId, 'B');
      });

      test('an unchanged named rig is not saved again', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();
        clearInteractions(repository);

        await cubit.open('B');

        verifyNoSave();
        verify(
          () => repository.open(
            '/root/B',
            liveSettings: any(named: 'liveSettings'),
          ),
        ).called(1);
      });

      test(
        'an unnamed rig with any edit is saved as the next New loop',
        () async {
          stubOpen();
          final cubit = build();
          addTearDown(cubit.close);
          await cubit.recordBaseline();
          liveFingerprint = 'an effect was added';

          await cubit.open('B');

          verify(
            () =>
                repository.nextAutomaticName(SessionCubit.automaticNamePrefix),
          ).called(1);
          verifySavedTo('/root/new', name: 'New loop 3').called(1);
          expect(cubit.state.currentSessionId, 'B');
        },
      );

      test('a fresh untouched rig writes nothing', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();

        await cubit.open('B');

        verifyNoSave();
        verifyNever(() => repository.nextAutomaticName(any()));
      });

      test('the opened session becomes the reference: opening another while '
          'it is unchanged saves nothing', () async {
        stubOpen();
        // Applying A makes the live rig A's, which differs from the baseline.
        when(() => looper.applySession(any())).thenAnswer((_) async {
          liveFingerprint = 'A as opened';
        });
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();
        await cubit.open('A');
        clearInteractions(repository);

        await cubit.open('B');

        verifyNoSave();
      });

      test(
        'a failed preservation applies nothing and says the save failed',
        () async {
          stubOpen();
          final cubit = build();
          addTearDown(cubit.close);
          cubit.emit(
            const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
          );
          await cubit.save();
          liveFingerprint = 'edited';
          when(
            () => repository.save(
              any(),
              chains: any(named: 'chains'),
              settings: any(named: 'settings'),
              pedalBindings: any(named: 'pedalBindings'),
              name: any(named: 'name'),
              captureStillValid: any(named: 'captureStillValid'),
            ),
          ).thenThrow(const FileSystemException('disk full'));

          await cubit.open('B');

          expect(cubit.state.status, SessionStatus.failure);
          expect(cubit.state.error, SessionError.saveFailed);
          expect(cubit.state.currentSessionId, 'A');
          verifyNever(() => looper.applySession(any()));
        },
      );

      test('a refused target saves nothing, keeps the current session, and '
          "keeps the player's arms (#1178 Part 4 lows review, 1)", () async {
        stubOpen();
        when(
          () => repository.open(
            '/root/B',
            liveSettings: any(named: 'liveSettings'),
          ),
        ).thenThrow(
          const SessionSampleRateMismatch(
            sessionRate: 44100,
            deviceRate: 48000,
          ),
        );
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();
        liveFingerprint = 'edited';

        when(() => looper.state).thenReturn(
          LooperState(
            tracks: [
              const Track(state: TrackState.stopped, lengthFrames: 48000),
              const Track(channel: 1, pending: true),
              for (var c = 2; c < 8; c++) Track(channel: c),
            ],
          ),
        );

        await cubit.open('B');

        expect(cubit.state.status, SessionStatus.failure);
        expect(cubit.state.error, SessionError.sampleRateMismatch);
        expect(cubit.state.currentSessionId, isNull);
        verifyNoSave();
        verifyNever(() => looper.cancelArm(channel: any(named: 'channel')));
        verifyNever(looper.cancelCountIn);
        verifyNever(() => looper.applySession(any()));
      });

      test('with no baseline a rig without audio is not saved', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.open('B');

        verifyNoSave();
      });

      test('with no baseline a rig holding audio is saved', () async {
        stubOpen();
        when(() => looper.state).thenReturn(
          LooperState(
            tracks: [
              const Track(state: TrackState.stopped, lengthFrames: 48000),
              for (var c = 1; c < 8; c++) Track(channel: c),
            ],
          ),
        );
        when(() => looper.laneCount(any())).thenReturn(1);
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.open('B');

        verifySavedTo('/root/new', name: 'New loop 3').called(1);
      });

      test('opening the current session does nothing', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        final before = cubit.state;

        await cubit.open('A');

        expect(cubit.state, before);
        verifyNever(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        );
        verifyNoSave();
      });

      test('the baseline is taken once', () async {
        stubOpen();
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();
        liveFingerprint = 'edited';
        await cubit.recordBaseline();

        await cubit.open('B');

        verifySavedTo('/root/new').called(1);
      });

      group('a take in progress (D8)', () {
        LooperState rig(TrackState track1) => LooperState(
          tracks: [
            const Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: track1, lengthFrames: 24000),
            for (var c = 2; c < 8; c++) Track(channel: c),
          ],
        );

        for (final capture in [TrackState.recording, TrackState.overdubbing]) {
          test('once the target is read, a ${capture.name} take is ended, '
              'then saved with the rig', () async {
            stubOpen();
            var live = rig(capture);
            when(() => looper.state).thenAnswer((_) => live);
            when(() => looper.laneCount(any())).thenReturn(1);
            when(
              () => looper.stopRecordControl(channel: any(named: 'channel')),
            ).thenAnswer((_) {
              live = rig(TrackState.playing);
              return EngineResult.ok;
            });
            final cubit = build();
            addTearDown(cubit.close);
            cubit.emit(
              const SessionState(
                currentSessionId: 'A',
                currentSessionName: 'A',
              ),
            );
            await cubit.save();
            clearInteractions(repository);
            liveFingerprint = 'the take';

            await cubit.open('B');

            verifyInOrder([
              () => repository.open(
                '/root/B',
                liveSettings: any(named: 'liveSettings'),
              ),
              () => looper.stopRecordControl(channel: 1),
              () => repository.save(
                '/root/A',
                chains: any(named: 'chains'),
                settings: any(named: 'settings'),
                pedalBindings: any(named: 'pedalBindings'),
                name: 'A',
                captureStillValid: any(named: 'captureStillValid'),
              ),
            ]);
            verifyNever(() => looper.stopRecordControl(channel: 0));
            expect(cubit.state.currentSessionId, 'B');
          });
        }

        test('an arm waiting for its boundary, and a Count-in, are withdrawn '
            'before the outgoing rig is saved (review D-1)', () async {
          stubOpen();
          var live = LooperState(
            tracks: [
              const Track(state: TrackState.playing, lengthFrames: 48000),
              const Track(channel: 1, pending: true),
              const Track(
                channel: 2,
                pendingLaunch: PendingLaunchAction.record,
              ),
              for (var c = 3; c < 8; c++) Track(channel: c),
            ],
          );
          when(() => looper.state).thenAnswer((_) => live);
          when(() => looper.laneCount(any())).thenReturn(1);
          when(
            () => looper.cancelArm(channel: any(named: 'channel')),
          ).thenReturn(EngineResult.ok);
          when(looper.cancelCountIn).thenAnswer((_) {
            // The engine has taken both withdrawals by its next block.
            live = LooperState(
              tracks: [
                const Track(state: TrackState.playing, lengthFrames: 48000),
                for (var c = 1; c < 8; c++) Track(channel: c),
              ],
            );
            return EngineResult.ok;
          });
          final cubit = build();
          addTearDown(cubit.close);
          cubit.emit(
            const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
          );
          await cubit.save();
          clearInteractions(repository);
          liveFingerprint = 'changed';

          await cubit.open('B');

          verifyInOrder([
            () => looper.cancelArm(channel: 1),
            looper.cancelCountIn,
            () => repository.save(
              '/root/A',
              chains: any(named: 'chains'),
              settings: any(named: 'settings'),
              pedalBindings: any(named: 'pedalBindings'),
              name: 'A',
              captureStillValid: any(named: 'captureStillValid'),
            ),
          ]);
          verifyNever(() => looper.cancelArm(channel: 0));
          verifyNever(
            () => looper.stopRecordControl(channel: any(named: 'channel')),
          );
          expect(cubit.state.currentSessionId, 'B');
        });

        test('an arm that is not withdrawn in time refuses the Open', () async {
          stubOpen();
          when(() => looper.state).thenReturn(
            LooperState(
              tracks: [
                const Track(pending: true),
                for (var c = 1; c < 8; c++) Track(channel: c),
              ],
            ),
          );
          when(
            () => looper.cancelArm(channel: any(named: 'channel')),
          ).thenReturn(EngineResult.ok);
          final cubit = SessionCubit(
            captureSettings: captureSettings,
            fxPersistence: fxPersistence,
            settings: settings,
            repository: repository,
            looper: looper,
            performance: performance,
            mixSettings: mixSettings,
            mixPersistence: mixPersistence,
            guards: GuardRegistry(),
            captureEndTimeout: const Duration(milliseconds: 20),
          );
          addTearDown(cubit.close);
          cubit.emit(
            const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
          );

          await cubit.open('B');

          expect(cubit.state.error, SessionError.captureInProgress);
          verifyNoSave();
        });

        test('a take that does not end in time refuses the Open and changes '
            'nothing', () async {
          stubOpen();
          when(() => looper.state).thenReturn(rig(TrackState.recording));
          when(
            () => looper.stopRecordControl(channel: any(named: 'channel')),
          ).thenReturn(EngineResult.ok);
          final cubit = SessionCubit(
            captureSettings: captureSettings,
            fxPersistence: fxPersistence,
            settings: settings,
            repository: repository,
            looper: looper,
            performance: performance,
            mixSettings: mixSettings,
            mixPersistence: mixPersistence,
            guards: GuardRegistry(),
            captureEndTimeout: const Duration(milliseconds: 20),
          );
          addTearDown(cubit.close);
          cubit.emit(
            const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
          );

          await cubit.open('B');

          expect(cubit.state.status, SessionStatus.failure);
          expect(cubit.state.error, SessionError.captureInProgress);
          expect(cubit.state.currentSessionId, 'A');
          verifyNoSave();
          verifyNever(() => looper.applySession(any()));
        });
      });
    });

    group('New loop (plan D9)', () {
      /// The order the seams below are reached in.
      late List<String> events;

      /// The rigs the looper was asked to apply.
      late List<SessionRig> applied;

      void stubNewLoop() {
        events = [];
        applied = [];
        stubCatalog();
        when(
          () => repository.liveSession(
            settings: any(named: 'settings'),
            chains: any(named: 'chains'),
            pedalBindings: any(named: 'pedalBindings'),
          ),
        ).thenAnswer((inv) {
          events.add('capture');
          return Session(
            name: 'A',
            sampleRate: 48000,
            channels: 1,
            baseLengthFrames: 96000,
            tracks: const [],
            tempoBpm: 96,
            tempoSource: TempoSource.manual,
            tsNum: 7,
            tsDen: 8,
            loopBars: 4,
            looperMode: LooperMode.sync,
            primaryTrack: 2,
            countInBars: 2,
            trackLevels: const {0: 0.5},
            pedalBindings: inv.namedArguments[#pedalBindings] as String,
          );
        });
        when(() => looper.applySession(any())).thenAnswer((inv) async {
          events.add('apply');
          applied.add(inv.positionalArguments.first as SessionRig);
        });
        when(
          () => repository.nextAutomaticName(any()),
        ).thenAnswer((_) async => 'New loop 3');
      }

      VerificationResult verifySavedTo(String path, {String? name}) => verify(
        () => repository.save(
          path,
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),
          name: name ?? any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      );

      void stubAudioInRig() {
        when(() => looper.state).thenReturn(
          LooperState(
            tracks: [
              const Track(state: TrackState.stopped, lengthFrames: 48000),
              for (var c = 1; c < 8; c++) Track(channel: c),
            ],
          ),
        );
        when(() => looper.laneCount(any())).thenReturn(1);
      }

      SessionCubit buildWithPedals({
        required void Function(String) onPedalBindings,
      }) => SessionCubit(
        guards: GuardRegistry(),
        captureSettings: captureSettings,
        fxPersistence: fxPersistence,
        settings: settings,
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
        currentPedalBindings: () => 'remap',
        onPedalBindings: onPedalBindings,
        releaseHeldBindings: () => events.add('release'),
      );

      test('applies the empty rig with the live settings, then saves it as '
          'the next New loop, which becomes current', () async {
        stubNewLoop();
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();

        await cubit.newLoop();

        final rig = applied.single;
        expect(rig.tracks, isEmpty);
        expect(rig.baseLengthFrames, 0);
        expect(rig.loopBars, 0);
        expect(rig.primaryTrack, -1);
        expect(rig.tempoBpm, 96);
        expect((rig.tsNum, rig.tsDen), (7, 8));
        expect(rig.looperMode, LooperMode.sync);
        expect(rig.countInBars, 2);
        expect(rig.trackLevels, {0: 0.5});
        verifyInOrder([
          () => looper.applySession(any()),
          () => repository.save(
            '/root/new',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: 'New loop 3',
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ]);
        expect(cubit.state.status, SessionStatus.success);
        expect(cubit.state.outcome, SessionOutcome.newLoop);
        expect(cubit.state.currentSessionId, 'new');
        expect(cubit.state.currentSessionName, 'New loop 3');
        expect(cubit.state.sessions, summaries);
      });

      test('a take in progress is ended and saved before the clear', () async {
        stubNewLoop();
        LooperState rig(TrackState track1) => LooperState(
          tracks: [
            const Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: track1, lengthFrames: 24000),
            for (var c = 2; c < 8; c++) Track(channel: c),
          ],
        );
        var live = rig(TrackState.recording);
        when(() => looper.state).thenAnswer((_) => live);
        when(() => looper.laneCount(any())).thenReturn(1);
        when(
          () => looper.stopRecordControl(channel: any(named: 'channel')),
        ).thenAnswer((_) {
          live = rig(TrackState.playing);
          return EngineResult.ok;
        });
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();
        clearInteractions(repository);
        liveFingerprint = 'the take';

        await cubit.newLoop();

        verifyInOrder([
          () => looper.stopRecordControl(channel: 1),
          () => repository.save(
            '/root/A',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: 'A',
            captureStillValid: any(named: 'captureStillValid'),
          ),
          () => looper.applySession(any()),
        ]);
      });

      test(
        'a changed outgoing session is saved to its identity first',
        () async {
          stubNewLoop();
          final cubit = build();
          addTearDown(cubit.close);
          cubit.emit(
            const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
          );
          await cubit.save();
          clearInteractions(repository);
          liveFingerprint = 'edited';

          await cubit.newLoop();

          verifyInOrder([
            () => repository.save(
              '/root/A',
              chains: any(named: 'chains'),
              settings: any(named: 'settings'),
              pedalBindings: any(named: 'pedalBindings'),
              name: 'A',
              captureStillValid: any(named: 'captureStillValid'),
            ),
            () => looper.applySession(any()),
            () => repository.save(
              '/root/new',
              chains: any(named: 'chains'),
              settings: any(named: 'settings'),
              pedalBindings: any(named: 'pedalBindings'),
              name: 'New loop 3',
              captureStillValid: any(named: 'captureStillValid'),
            ),
          ]);
        },
      );

      test('an unchanged outgoing session is not saved again', () async {
        stubNewLoop();
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();
        clearInteractions(repository);

        await cubit.newLoop();

        verifyNever(
          () => repository.save(
            '/root/A',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        );
        verifySavedTo('/root/new', name: 'New loop 3').called(1);
      });

      test('a failed preservation applies nothing and mints no id', () async {
        stubNewLoop();
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();
        clearInteractions(repository);
        liveFingerprint = 'edited';
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenThrow(const FileSystemException('disk full'));

        await cubit.newLoop();

        expect(cubit.state.status, SessionStatus.failure);
        expect(cubit.state.error, SessionError.saveFailed);
        expect(cubit.state.currentSessionId, 'A');
        verifyNever(() => looper.applySession(any()));
        verifyNever(repository.newSessionId);
      });

      test('a refusal before the apply gives the new id back and leaves the '
          'current session', () async {
        stubNewLoop();
        when(
          performance.disarmAndFinalize,
        ).thenAnswer((_) async => EngineResult.device);
        final cubit = build();
        addTearDown(cubit.close);
        cubit.emit(
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
        );
        await cubit.save();

        await cubit.newLoop();

        expect(cubit.state.status, SessionStatus.failure);
        expect(cubit.state.currentSessionId, 'A');
        verify(() => repository.releaseSessionId('new')).called(1);
        verifyNever(() => looper.applySession(any()));
      });

      test('an empty rig that cannot be written leaves the new loop started '
          'and current, and says something failed', () async {
        stubNewLoop();
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();
        when(
          () => repository.save(
            '/root/new',
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenThrow(const FileSystemException('disk full'));

        await cubit.newLoop();

        verify(() => looper.applySession(any())).called(1);
        expect(cubit.state.status, SessionStatus.failure);
        expect(cubit.state.error, SessionError.newLoopNotSaved);
        expect(cubit.state.currentSessionId, 'new');
        expect(cubit.state.currentSessionName, 'New loop 3');
        verifyNever(() => repository.releaseSessionId(any()));

        // The outgoing rig's reference no longer applies: with no reference,
        // a rig holding audio is saved on the next Open, to the new loop.
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        stubAudioInRig();
        clearInteractions(repository);
        await cubit.open('B');
        verifySavedTo('/root/new', name: 'New loop 3').called(1);
      });

      test('keeps the pedal remap, and releases a held momentary before the '
          'chains it keeps are captured', () async {
        stubNewLoop();
        final installed = <String>[];
        final cubit = buildWithPedals(onPedalBindings: installed.add);
        addTearDown(cubit.close);
        await cubit.recordBaseline();

        await cubit.newLoop();

        expect(installed, ['remap']);
        expect(events.indexOf('release'), lessThan(events.indexOf('capture')));
        expect(events.indexOf('capture'), lessThan(events.indexOf('apply')));
      });

      test('the new loop is the reference: opening another session while '
          'it is unchanged saves nothing more', () async {
        stubNewLoop();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {
          liveFingerprint = 'the empty rig';
        });
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.recordBaseline();
        await cubit.newLoop();
        clearInteractions(repository);
        // Audio in the rig: only the recorded reference keeps it from being
        // saved again.
        stubAudioInRig();

        await cubit.open('B');

        verifyNever(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        );
      });
    });

    blocTest<SessionCubit, SessionState>(
      'invalid effect placement refuses session before the live rig changes',
      setUp: () {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
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
          ),
        );
      },
      seed: () =>
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.open('B'),
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
      'invalid monitor gain preserves the current rig and ongoing capture',
      setUp: () {
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: const Session(
                sampleRate: 48000,
                channels: 1,
                baseLengthFrames: 0,
                tracks: [],
                monitors: [
                  SessionMonitor(
                    input: 0,
                    mode: 'on',
                    outputMask: 3,
                    volume: 1.5,
                    muted: false,
                    encoded: '[]',
                  ),
                ],
              ),
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
      },
      seed: () =>
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.open('B'),
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
        verifyNever(performance.disarmAndFinalize);
        verifyNever(() => looper.applySession(any()));
        verifyNever(looper.stopEngine);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'open validates the bundle before disarming and applying '
      '(D-ORCHESTRATE)',
      setUp: () {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.open('A'),
      verify: (_) {
        verifyInOrder([
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
          performance.disarmAndFinalize,
          () => looper.applySession(any()),
        ]);
      },
    );

    blocTest<SessionCubit, SessionState>(
      'open leaves the live rig alone when performance disarm refuses',
      setUp: () {
        stubCatalog();
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: _session,
              laneStems: <(int, int), List<Float32List>>{},
            ),
          ),
        );
        when(
          performance.disarmAndFinalize,
        ).thenAnswer((_) async => EngineResult.device);
      },
      seed: () =>
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
      build: build,
      act: (cubit) => cubit.open('B'),
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
        verify(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).called(1);
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
      seed: () =>
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
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
      seed: () =>
          const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
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
      'deleteSession deletes a saved session, keeps the open one and never '
      'touches the rig',
      setUp: () {
        stubCatalog(
          list: const [SessionSummary(id: 'A', name: 'A')],
        );
        when(() => repository.deleteSession(any())).thenAnswer((_) async {});
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
      build: build,
      act: (cubit) => cubit.deleteSession('B'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.deleted)
            .having((s) => s.currentSessionId, 'current', 'A')
            .having((s) => s.sessions, 'sessions', const [
              SessionSummary(id: 'A', name: 'A'),
            ]),
      ],
      verify: (_) {
        verify(() => repository.deleteSession('B')).called(1);
        verifyNever(() => looper.applySession(any()));
      },
    );

    blocTest<SessionCubit, SessionState>(
      'deleteSession refuses the open session and deletes nothing (D6)',
      setUp: () {
        stubCatalog();
        when(() => repository.deleteSession(any())).thenAnswer((_) async {});
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
      build: build,
      act: (cubit) => cubit.deleteSession('A'),
      expect: () => [
        isA<SessionState>().having(
          (s) => s.status,
          'st',
          SessionStatus.working,
        ),
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having(
              (s) => s.error,
              'error',
              SessionError.currentSessionProtected,
            )
            .having((s) => s.currentSessionId, 'current', 'A')
            .having((s) => s.sessions, 'sessions', summaries),
      ],
      verify: (_) => verifyNever(() => repository.deleteSession(any())),
    );

    blocTest<SessionCubit, SessionState>(
      'moveSession moves the bundle and re-lists sessions and folders',
      setUp: () {
        stubCatalog();
        when(
          () => repository.moveSession(any(), folder: any(named: 'folder')),
        ).thenAnswer((_) async {});
        when(repository.listFolders).thenAnswer((_) async => ['Gigs']);
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
      build: build,
      act: (cubit) => cubit.moveSession('A', folder: 'Gigs'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.success)
            .having((s) => s.outcome, 'outcome', SessionOutcome.moved)
            .having((s) => s.currentSessionId, 'current', 'A')
            .having((s) => s.folders, 'folders', ['Gigs']),
      ],
      verify: (_) =>
          verify(() => repository.moveSession('A', folder: 'Gigs')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'moveSession with no folder moves to Unfiled',
      setUp: () {
        stubCatalog();
        when(
          () => repository.moveSession(any(), folder: any(named: 'folder')),
        ).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.moveSession('B'),
      verify: (_) => verify(() => repository.moveSession('B')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'createFolder creates it and the folders re-list',
      setUp: () {
        stubCatalog();
        when(() => repository.createFolder(any())).thenAnswer((_) async {});
        when(repository.listFolders).thenAnswer((_) async => ['Gigs']);
      },
      build: build,
      act: (cubit) => cubit.createFolder('Gigs'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.outcome, 'outcome', SessionOutcome.folderCreated)
            .having((s) => s.folders, 'folders', ['Gigs']),
      ],
      verify: (_) => verify(() => repository.createFolder('Gigs')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'deleteFolder deletes an empty folder and re-lists',
      setUp: () {
        stubCatalog();
        when(() => repository.deleteFolder(any())).thenAnswer((_) async {});
      },
      build: build,
      act: (cubit) => cubit.deleteFolder('Spare'),
      skip: 1,
      expect: () => [
        isA<SessionState>().having(
          (s) => s.outcome,
          'outcome',
          SessionOutcome.folderDeleted,
        ),
      ],
      verify: (_) => verify(() => repository.deleteFolder('Spare')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'deleteFolder on a folder holding sessions fails with folderNotEmpty',
      setUp: () {
        stubCatalog();
        when(
          () => repository.deleteFolder(any()),
        ).thenThrow(const SessionFolderNotEmpty(folder: 'Gigs'));
      },
      build: build,
      act: (cubit) => cubit.deleteFolder('Gigs'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.folderNotEmpty),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'renameFolder renames it and re-lists',
      setUp: () {
        stubCatalog();
        when(
          () => repository.renameFolder(any(), any()),
        ).thenAnswer((_) async {});
        when(repository.listFolders).thenAnswer((_) async => ['Shows']);
      },
      build: build,
      act: (cubit) => cubit.renameFolder('Gigs', 'Shows'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.outcome, 'outcome', SessionOutcome.folderRenamed)
            .having((s) => s.folders, 'folders', ['Shows']),
      ],
      verify: (_) =>
          verify(() => repository.renameFolder('Gigs', 'Shows')).called(1),
    );

    blocTest<SessionCubit, SessionState>(
      'createFolder on a taken name fails with nameCollision',
      setUp: () {
        stubCatalog();
        when(
          () => repository.createFolder(any()),
        ).thenThrow(const SessionNameCollision(slug: 'Gigs'));
      },
      build: build,
      act: (cubit) => cubit.createFolder('Gigs'),
      skip: 1,
      expect: () => [
        isA<SessionState>()
            .having((s) => s.status, 'st', SessionStatus.failure)
            .having((s) => s.error, 'error', SessionError.nameCollision),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'an unreadable folder list keeps the folders already in state',
      setUp: () {
        stubCatalog();
        when(
          repository.listFolders,
        ).thenThrow(const FileSystemException('denied'));
      },
      seed: () => const SessionState(folders: ['Gigs']),
      build: build,
      act: (cubit) => cubit.refreshSessions(),
      expect: () => [
        isA<SessionState>()
            .having((s) => s.sessions, 'sessions', summaries)
            .having((s) => s.folders, 'folders', ['Gigs']),
      ],
    );

    blocTest<SessionCubit, SessionState>(
      'duplicateSession copies the bundle and refreshes the catalog',
      setUp: () {
        stubCatalog();
        when(
          () => repository.duplicateSession(any(), any()),
        ).thenAnswer((_) async => 'copy-id');
      },
      seed: () => const SessionState(
        currentSessionId: 'A',
        currentSessionName: 'A',
        sessions: summaries,
      ),
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
            .having((s) => s.outcome, 'outcome', SessionOutcome.duplicated)
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

          name: any(named: 'name'),
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

    test('every failure counts once, and a refresh keeps the last result '
        'as it was', () async {
      stubCatalog();
      final cubit = build();
      addTearDown(cubit.close);
      cubit.emit(
        const SessionState(currentSessionId: 'A', currentSessionName: 'A'),
      );

      await cubit.deleteSession('A');
      expect(cubit.state.failureCount, 1);
      await cubit.deleteSession('A');
      expect(cubit.state.failureCount, 2);

      await cubit.refreshSessions();
      expect(cubit.state.status, SessionStatus.failure);
      expect(cubit.state.error, SessionError.currentSessionProtected);
      expect(cubit.state.failureCount, 2);
      expect(cubit.state.sessions, summaries);
    });

    test('a refresh keeps who refused the last action and the last '
        'conversion notice', () async {
      stubCatalog();
      final cubit = build();
      addTearDown(cubit.close);
      const notice = SessionConversionNotice(fromVersion: 7, written: true);
      cubit.emit(
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.busy,
          refusedBy: GuardKind.transfer,
          conversion: notice,
          failureCount: 1,
        ),
      );

      await cubit.refreshSessions();

      expect(cubit.state.refusedBy, GuardKind.transfer);
      expect(cubit.state.conversion, notice);
      expect(cubit.state.sessions, summaries);
    });

    blocTest<SessionCubit, SessionState>(
      'a write-back preserves the open session + catalog across the '
      'transition (C1)',
      setUp: () {
        when(
          () => repository.bundlePathOf(any()),
        ).thenAnswer((_) async => '/root/Open');
        when(
          () => repository.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),

            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((_) async => _session);
        // A write-back re-lists so an open Sessions dialog's date column
        // shows the save it just made.
        when(repository.listSessions).thenAnswer((_) async => summaries);
      },
      seed: () => const SessionState(
        currentSessionId: 'Open',
        currentSessionName: 'Open',
        sessions: summaries,
      ),
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

  group('close drains admitted session work', () {
    // Shutdown closes Session before its engine and settings owners. A pending
    // repository operation must finish before its state stream closes, while
    // new actions are rejected as soon as close starts.
    test(
      'renameSession finishes before close completes (success path)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) => completer.future);
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = build();
        final future = cubit.renameSession('x', 'Renamed');

        final closing = cubit.close();
        expect(cubit.isClosed, isFalse);
        completer.complete();

        await expectLater(future, completes);
        await closing;
        expect(cubit.isClosed, isTrue);
      },
    );

    test(
      'renameSession error settles before close (SessionException)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) => completer.future);
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = build();
        final future = cubit.renameSession('x', 'Renamed');

        final closing = cubit.close();
        expect(cubit.isClosed, isFalse);
        completer.completeError(const SessionNameCollision(slug: 'x'));

        await expectLater(future, completes);
        await closing;
      },
    );

    test(
      'renameSession error settles before close (unknown error)',
      () async {
        final completer = Completer<void>();
        when(
          () => repository.renameSession(any(), any()),
        ).thenAnswer((_) => completer.future);
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = build();
        final future = cubit.renameSession('x', 'Renamed');

        final closing = cubit.close();
        expect(cubit.isClosed, isFalse);
        completer.completeError(Exception('disk full'));

        await expectLater(future, completes);
        await closing;
      },
    );

    test(
      'refreshSessions completes before close',
      () async {
        final completer = Completer<List<SessionSummary>>();
        when(repository.listSessions).thenAnswer((_) => completer.future);

        final cubit = build();
        final future = cubit.refreshSessions();

        final closing = cubit.close();
        expect(cubit.isClosed, isFalse);
        completer.complete(const []);

        await expectLater(future, completes);
        await closing;
      },
    );
  });

  group('SessionCubit backing (#1200)', () {
    late BackingFixture backing;
    setUp(() async {
      backing = BackingFixture();
      await backing.start();
      addTearDown(backing.dispose);
    });

    SessionSettingsCoordinator withBacking() => SessionSettingsCoordinator(
      fade: fade,
      looper: looper,
      mix: mixSettings,
      fx: fxPersistence,
      owners: SettingsOwners([
        _LengthOwner(looper),
        ...fade.owners,
        ...backing.settings.owners,
      ]),
      tempo: _TempoOwner(),
      playback: _PlaybackOwner(looper),
      record: _RecordOwner(looper),
      timing: _TimingOwner(looper),
      backing: SessionBackingPort(
        player: backing.player,
        settings: backing.settings,
      ),
    );

    test('Open stops the backing and installs the session setup, loaded '
        'again stopped at 0; capture reads it back', () async {
      final a = await backing.asset('a.wav');
      final b = await backing.asset('b.wav');
      await backing.player.addToPrepared(a);
      await backing.player.play();
      await backing.advance(50);
      final saved = SessionBacking(
        prepared: [SessionBackingItem(digest: b.digest, name: 'b.wav')],
        loaded: SessionBackingItem(digest: b.digest, name: 'b.wav'),
        endMode: BackingEnd.repeat,
        level: 0.4,
        pan: 0.25,
        outputMask: 0x3,
      );
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((_) async => '/b/X');
      when(
        () => repository.open(any(), liveSettings: any(named: 'liveSettings')),
      ).thenAnswer(
        _opened(
          (_) async => (
            session: Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: const [],
              backing: saved,
              clickPan: -0.5,
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        ),
      );
      when(() => looper.applySession(any())).thenAnswer((_) async {});
      when(repository.listSessions).thenAnswer((_) async => const []);
      final coordinator = withBacking();
      final cubit = SessionCubit(
        captureSettings: coordinator,
        fxPersistence: fxPersistence,
        settings: settings,
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
        guards: GuardRegistry(),
      );
      addTearDown(cubit.close);

      await cubit.open('X');

      expect(cubit.state.status, isNot(SessionStatus.failure));
      final state = backing.player.state;
      expect(state.prepared.map((i) => i.name), ['b.wav']);
      expect(state.loaded?.digest, b.digest);
      expect(backing.repository.state.loaded, b.digest);
      expect(backing.repository.state.transport, BackingTransport.stopped);
      expect(backing.repository.state.position, 0);
      expect(backing.settings.mix.level, 0.4);
      expect(backing.settings.clickPan, -0.5);
      expect(backing.engine.backingState().endMode, BackingEnd.repeat);
      final current = coordinator.current();
      expect(current.backing, saved);
      expect(current.clickPan, -0.5);
    });
  });

  group('SessionCubit pedal remap (part 6b)', () {
    test(
      'splits the seam across the apply: releases held momentaries BEFORE it '
      '(so the restore lands on the outgoing rig) and commits the new set '
      'only AFTER it',
      () async {
        final order = <String>[];
        when(
          () => repository.bundlePathOf(any()),
        ).thenAnswer((_) async => '/b/X');
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
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
          ),
        );
        when(() => looper.applySession(any())).thenAnswer((_) async {
          order.add('applySession');
        });
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = SessionCubit(
          guards: GuardRegistry(),
          captureSettings: captureSettings,
          fxPersistence: fxPersistence,
          settings: settings,
          repository: repository,
          looper: looper,
          performance: performance,
          mixSettings: mixSettings,
          mixPersistence: mixPersistence,
          onPedalBindings: (_) => order.add('onPedalBindings'),
          releaseHeldBindings: () => order.add('releaseHeldBindings'),
        );
        addTearDown(cubit.close);

        await cubit.open('X');

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
          () => repository.bundlePathOf(any()),
        ).thenAnswer((_) async => '/b/X');
        when(
          () =>
              repository.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
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
          ),
        );
        when(
          () => looper.applySession(any()),
        ).thenThrow(StateError('engine refused the rig'));
        when(repository.listSessions).thenAnswer((_) async => const []);

        final cubit = SessionCubit(
          guards: GuardRegistry(),
          captureSettings: captureSettings,
          fxPersistence: fxPersistence,
          settings: settings,
          repository: repository,
          looper: looper,
          performance: performance,
          mixSettings: mixSettings,
          mixPersistence: mixPersistence,
          onPedalBindings: (_) => committed = true,
        );
        addTearDown(cubit.close);

        await cubit.open('X');

        expect(cubit.state.status, SessionStatus.failure);
        expect(committed, isFalse);
        verify(looper.stopEngine).called(1);
      },
    );

    test('saves the remap IN FORCE, so a session can acquire one', () async {
      when(
        () => repository.bundlePathOf(any()),
      ).thenAnswer((_) async => '/b/X');
      when(repository.listSessions).thenAnswer((_) async => const []);
      when(
        () => repository.save(
          any(),
          chains: any(named: 'chains'),
          settings: any(named: 'settings'),
          pedalBindings: any(named: 'pedalBindings'),

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).thenAnswer((_) async => _session);

      final cubit = SessionCubit(
        guards: GuardRegistry(),
        captureSettings: captureSettings,
        fxPersistence: fxPersistence,
        settings: settings,
        repository: repository,
        looper: looper,
        performance: performance,
        mixSettings: mixSettings,
        mixPersistence: mixPersistence,
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

          name: any(named: 'name'),
          captureStillValid: any(named: 'captureStillValid'),
        ),
      ).called(1);
    });
  });
}

/// Answers a stubbed `open` with a bundle that needed no conversion.
Future<OpenedSession> Function(Invocation) _opened(
  FutureOr<SessionBundle> Function(Invocation) answer,
) =>
    (invocation) async => (bundle: await answer(invocation), conversion: null);
