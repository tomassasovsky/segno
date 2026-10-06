import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show FxOwner, TrackSnapshot;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Sessions extends Mock implements SessionRepository {}

class _ReadGateStore extends FakeKeyValueStore {
  Completer<String?>? midiRead;
  final midiReadEntered = Completer<void>();
  Completer<void>? fxWrite;
  final fxWriteEntered = Completer<void>();
  Completer<void>? bootWrite;
  final bootWriteEntered = Completer<void>();
  bool refuseFx = false;
  bool refuseFade = false;
  Completer<void>? fadeWrite;
  final fadeWriteEntered = Completer<void>();
  bool refuseMute = false;
  int fxWrites = 0;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await super.setBool(key, value: value);
    if (key == 'lane_mute.0.0' && refuseMute) {
      throw StateError('mute storage wrote then refused');
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'looper.fade_durations') {
      if (!fadeWriteEntered.isCompleted) fadeWriteEntered.complete();
      await fadeWrite?.future;
      await super.setString(key, value);
      if (refuseFade) throw StateError('Fade write then refusal');
    }
    if (key == 'all_tracks_fx_chain' && bootWrite != null) {
      if (!bootWriteEntered.isCompleted) bootWriteEntered.complete();
      await bootWrite!.future;
    }
    if (key == 'track_fx_chain.0') {
      fxWrites++;
      if (!fxWriteEntered.isCompleted) fxWriteEntered.complete();
      await fxWrite?.future;
      if (refuseFx) throw StateError('FX storage refused');
    }
    await super.setString(key, value);
  }

  @override
  Future<String?> getString(String key) {
    if (key == 'midi.configuration' && midiRead != null) {
      midiReadEntered.complete();
      return midiRead!.future;
    }
    return super.getString(key);
  }
}

void main() {
  late AppRuntime runtime;
  late FakeAudioEngine engine;
  late FakePedalLink link;
  late _Sessions sessions;
  late _ReadGateStore store;
  late LooperRepository repository;
  late SettingsRepository settings;
  late PerformanceRepository performance;
  late String exportsDirectory;
  var closeFailureExpected = false;
  var halts = 0;

  setUp(() async {
    halts = 0;
    closeFailureExpected = false;
    engine = FakeAudioEngine();
    repository = LooperRepository(
      engine: engine,
      ticker: const Stream<void>.empty(),
    )..startEngine(const EngineConfig());
    store = _ReadGateStore();
    settings = SettingsRepository(store: store);
    final controllers = ControllerRepository(sources: const []);
    final midi = MidiDeviceRepository(source: null, settings: settings);
    link = FakePedalLink();
    final pedal = PedalRepository(link);
    link.hello();
    await pumpEventQueue();
    sessions = _Sessions();
    when(() => sessions.bundlePathOf(any())).thenAnswer((_) async => '/test');
    when(sessions.listSessions).thenAnswer((_) async => []);
    when(sessions.newSessionId).thenAnswer((_) async => 'new');
    when(
      () => sessions.releaseSessionId(any()),
    ).thenAnswer((_) async {});
    exportsDirectory = '.';
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => exportsDirectory,
    );
    addTearDown(performance.dispose);
    runtime = AppRuntime(
      guards: GuardRegistry(),
      repository: repository,
      settings: settings,
      mix: testMixSettings(repository, settings: settings),
      controllers: controllers,
      midiDevices: midi,
      pedal: pedal,
      performance: performance,
      sessions: sessions,
      powerOff: () async => halts++,
    );
    addTearDown(() async {
      if (closeFailureExpected) {
        await expectLater(runtime.close(), throwsStateError);
      } else {
        await runtime.close();
      }
      await pedal.dispose();
      await midi.dispose();
      await controllers.dispose();
      await repository.dispose();
    });
  });

  Future<(Future<void>, Completer<SessionBundle>)> holdSessionRead() async {
    final entered = Completer<void>();
    final read = Completer<SessionBundle>();
    when(
      () => sessions.open(any(), liveSettings: any(named: 'liveSettings')),
    ).thenAnswer(
      _opened((_) {
        entered.complete();
        return read.future;
      }),
    );
    final loading = runtime.session.open('Incoming');
    await entered.future;
    return (loading, read);
  }

  void finishRead(Completer<SessionBundle> read) => read.complete((
    session: const Session(
      sampleRate: 48000,
      channels: 1,
      baseLengthFrames: 0,
      tracks: [],
    ),
    laneStems: <(int, int), List<Float32List>>{},
  ));

  group('Fade duration Session composition', () {
    test(
      'retains incoming setup through boot write failure and explicit Retry',
      () async {
        await runtime.start();
        await runtime.fade.setDefault(6000);
        await runtime.fade.setOverride(0, 6000);
        engine.nextSnapshot = engine.nextSnapshot.copyWith(
          sampleRate: 48000,
          isRunning: true,
          devicePresent: true,
        );
        when(
          () => sessions.open(any(), liveSettings: any(named: 'liveSettings')),
        ).thenAnswer(
          _opened(
            (_) async => (
              session: const Session(
                sampleRate: 48000,
                channels: 1,
                baseLengthFrames: 128,
                tracks: [
                  SessionTrack(
                    channel: 0,
                    multiple: 1,
                    lengthFrames: 128,
                    fadeAmount: .25,
                    reversed: false,
                    lanes: [
                      SessionLane(
                        lane: 0,
                        volume: 1,
                        muted: false,
                        outputMask: 1,
                        inputChannel: 0,
                        layers: [SessionLayer(file: 'track0.wav')],
                        history: TrackHistory.none,
                      ),
                    ],
                  ),
                  SessionTrack(
                    channel: 1,
                    multiple: 1,
                    lengthFrames: 128,
                    fadeAmount: 0,
                    reversed: false,
                    lanes: [
                      SessionLane(
                        lane: 0,
                        volume: 1,
                        muted: false,
                        outputMask: 1,
                        inputChannel: 0,
                        layers: [SessionLayer(file: 'track1.wav')],
                        history: TrackHistory.none,
                      ),
                    ],
                  ),
                ],
                defaultFadeDurationMs: 12000,
              ),
              laneStems: {
                (0, 0): [Float32List(128)..fillRange(0, 128, .5)],
                (1, 0): [Float32List(128)..fillRange(0, 128, .5)],
              },
            ),
          ),
        );
        store.refuseFade = true;
        await runtime.session.open('Incoming');
        expect(runtime.session.state.bootRecoveryRequired, isTrue);
        expect(repository.sessionBootRecoveryRequired, isTrue);
        // This fake's snapshot is scripted independently of stop(). Publish the
        // stopped device observation while retaining the accepted material.
        engine.nextSnapshot = engine.nextSnapshot.copyWith(
          isRunning: false,
          devicePresent: false,
        );
        expect(repository.play(), EngineResult.notReady);
        expect(repository.state.tracks.take(2).map((t) => t.fade.amount), [
          .25,
          0,
        ]);
        expect(
          repository.state.tracks.take(2).map((t) => t.state),
          everyElement(TrackState.stopped),
        );
        await expectLater(runtime.fade.setDefault(2000), throwsStateError);
        expect(await runtime.fade.recover(), isFalse);
        await runtime.session.retryLoadedSession();
        expect(runtime.session.state.bootRecoveryRequired, isTrue);
        store.refuseFade = false;
        await runtime.session.retryLoadedSession();
        expect(runtime.session.state.outcome, SessionOutcome.loaded);
        expect(repository.sessionBootRecoveryRequired, isFalse);
        expect(runtime.fade.confirmed, FadeDurations(defaultMs: 12000));
        expect(await runtime.fade.recover(), isTrue);
        expect(runtime.fade.confirmed.overrides, isEmpty);
        expect(repository.state.tracks.take(2).map((t) => t.fade.amount), [
          .25,
          0,
        ]);
        expect(
          repository.state.tracks.take(2).map((t) => t.state),
          everyElement(TrackState.stopped),
        );
      },
    );

    test(
      'real Session save waits for an admitted duration edit and captures '
      'it',
      () async {
        await runtime.start();
        registerFallbackValue(const SessionChains());
        registerFallbackValue(const SessionSettings());
        SessionSettings? saved;
        when(
          () => sessions.save(
            any(),
            chains: any(named: 'chains'),
            settings: any(named: 'settings'),
            pedalBindings: any(named: 'pedalBindings'),
            name: any(named: 'name'),
            captureStillValid: any(named: 'captureStillValid'),
          ),
        ).thenAnswer((call) async {
          saved = call.namedArguments[#settings] as SessionSettings;
          return const Session(
            sampleRate: 48000,
            channels: 1,
            baseLengthFrames: 0,
            tracks: [],
          );
        });
        store.fadeWrite = Completer<void>();
        final edit = runtime.fade.setOverride(7, 4000);
        await store.fadeWriteEntered.future;
        final save = runtime.session.saveAs('durations');
        // Fade edits queue behind Session exclusion like every owned family;
        // the Mixer still refuses its own edits there.
        expect(
          (await runtime.mix.setTrackVolume(.3)).status,
          MixSettingsStatus.superseded,
        );
        expect(saved, isNull);
        store.fadeWrite!.complete();
        await edit;
        await save;
        expect(runtime.session.state.outcome, SessionOutcome.savedAs);
        expect(saved!.defaultFadeDurationMs, 4000);
        expect(saved!.trackFadeDurationOverrides, {7: 4000});
      },
    );

    for (final amount in [null, double.nan, -.1, 1.1]) {
      test(
        'invalid incoming vector ($amount) fails before disarm '
        'or stored setup changes',
        () async {
          await runtime.start();
          await runtime.fade.setDefault(6000);
          final oldRevision = repository.sessionRevision;
          final oldBytes = store.values['looper.fade_durations'];
          final directory = await Directory.systemTemp.createTemp(
            'fade-preflight-',
          );
          exportsDirectory = directory.path;
          addTearDown(() => directory.delete(recursive: true));
          engine.publishPerfCommands = true;
          expect(await performance.arm(), EngineResult.ok);
          final capture = performance.armedDirectory;
          expect(capture, isNotNull);
          expect(engine.snapshot().isPerfArmed, isTrue);
          final disarms = engine.perfDisarmCalls;
          when(
            () =>
                sessions.open(any(), liveSettings: any(named: 'liveSettings')),
          ).thenAnswer(
            _opened(
              (_) async => (
                session: Session(
                  sampleRate: 48000,
                  channels: 1,
                  baseLengthFrames: 0,
                  tracks: [
                    if (amount != null)
                      SessionTrack(
                        channel: 0,
                        multiple: 1,
                        lengthFrames: 128,
                        fadeAmount: amount,
                        reversed: false,
                        lanes: const [],
                      ),
                  ],
                  defaultFadeDurationMs: amount == null ? 501 : 4000,
                ),
                laneStems: <(int, int), List<Float32List>>{},
              ),
            ),
          );
          await runtime.session.open('invalid');
          expect(runtime.session.state.status, SessionStatus.failure);
          expect(repository.sessionRevision, oldRevision);
          expect(engine.perfDisarmCalls, disarms);
          expect(engine.snapshot().isPerfArmed, isTrue);
          expect(performance.armedDirectory, capture);
          expect(store.values['looper.fade_durations'], oldBytes);
          expect(runtime.fade.confirmed.defaultMs, 6000);
          expect(runtime.fxPersistence.sessionTransitionActive, isFalse);
        },
      );
    }
  });

  test('stopped Session stays reserved through the real boot write', () async {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      isRunning: true,
      devicePresent: true,
      sampleRate: 48000,
    );
    await runtime.start();
    store.bootWrite = Completer<void>();
    addTearDown(() {
      if (!store.bootWrite!.isCompleted) store.bootWrite!.complete();
    });
    when(
      () => sessions.open(any(), liveSettings: any(named: 'liveSettings')),
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
                    volume: .4,
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
            (0, 0): [Float32List(128)..fillRange(0, 128, .5)],
          },
        ),
      ),
    );
    final loading = runtime.session.open('Incoming');
    await store.bootWriteEntered.future;
    expect(repository.state.tracks[0].state, TrackState.stopped);
    final before = (
      engine.playCalls,
      engine.recordCalls,
      engine.undoCalls,
      engine.redoCalls,
    );
    runtime.looper
      ..add(const LooperPlayPressed(0))
      ..add(const LooperRecordPressed(0))
      ..add(const LooperUndoPressed(0))
      ..add(const LooperRedoPressed(0));
    expect(repository.play(), EngineResult.notReady);
    expect(repository.undo(), EngineResult.notReady);
    expect(repository.redo(), EngineResult.notReady);
    await pumpEventQueue();
    expect((
      engine.playCalls,
      engine.recordCalls,
      engine.undoCalls,
      engine.redoCalls,
    ), before);
    expect(repository.state.tracks[0].state, TrackState.stopped);
    store.bootWrite!.complete();
    await loading;
    expect(runtime.session.state.outcome, SessionOutcome.loaded);
    expect(repository.sessionBootRecoveryRequired, isFalse);
    expect(repository.state.tracks[0].state, TrackState.stopped);
    runtime.looper.add(const LooperPlayPressed(0));
    await pumpEventQueue();
    expect(engine.playCalls, before.$1 + 1);
  });

  test(
    'close drains session before its controls and cuts encoder ingress',
    () async {
      await runtime.start();
      final (loading, read) = await holdSessionRead();
      final gain = engine.lastMasterGain;
      var closed = false;
      final closing = runtime.close().then((_) => closed = true);
      final secondClose = runtime.close();
      link.turn(-16);
      await pumpEventQueue();
      final gainWhileDraining = engine.lastMasterGain;
      final closedWhileDraining = closed;
      final controlClosedWhileDraining = runtime.control.isClosed;
      finishRead(read);
      await loading;
      await closing;
      await secondClose;
      expect(gainWhileDraining, gain);
      expect(closedWhileDraining, isFalse);
      expect(controlClosedWhileDraining, isFalse);
      expect(runtime.session.state.outcome, SessionOutcome.loaded);
      expect(runtime.session.state.bootRecoveryRequired, isFalse);
      expect(runtime.control.isClosed, isTrue);
    },
  );

  test(
    'close cancels a pending halt before waiting for session storage',
    () async {
      await runtime.start();
      runtime.power.press(const PowerOffSnapshot());
      await pumpEventQueue();
      expect(runtime.power.state.phase, PowerOffPhase.goodbye);
      final (loading, read) = await holdSessionRead();
      final closing = runtime.close();
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      final haltsWhileDraining = halts;
      finishRead(read);
      await loading;
      await closing;
      expect(haltsWhileDraining, 0);
      expect(halts, 0);
    },
  );
  test(
    'session replacement blocks master encoder edits until applied',
    () async {
      await runtime.start();
      runtime.control.encoderTurned(0);
      final (loading, read) = await holdSessionRead();
      final gain = engine.lastMasterGain!;
      link.turn(-16);
      await pumpEventQueue();
      final gainWhileLoading = engine.lastMasterGain;
      finishRead(read);
      await loading;
      expect(gainWhileLoading, gain);
      link.turn(-16);
      await pumpEventQueue();
      expect(engine.lastMasterGain, lessThan(gain));
    },
  );

  Future<void> prepareTrackFx() async {
    await runtime.start();
    expect(
      repository.setTrackEffects(
        channel: 0,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.drive,
            slotId: 'drive',
            params: const [.2, .4, .5],
          ),
        ],
      ),
      EngineResult.ok,
    );
    expect(await repository.settleFxRecipes(), EngineResult.ok);
    await pumpEventQueue();
  }

  for (final stopEngine in [false, true]) {
    test('close saves a debounced FX drag after receipt settlement '
        '(engine stopped $stopEngine)', () async {
      await prepareTrackFx();
      engine
        ..publishFxRecipes = false
        ..commandsAreSettled = false;
      // An admitted structural edit is awaiting the audio callback. Subsequent
      // atomic knob/power edits must share its confirmation barrier.
      expect(
        repository.setTrackEffects(
          channel: 0,
          effects: repository.trackEffects(0),
        ),
        EngineResult.ok,
      );
      runtime.looper.add(
        const LooperBusEffectParamChanged(
          FxAddress(stage: FxStage.track),
          0,
          0,
          .7,
        ),
      );
      await pumpEventQueue();
      expect(engine.pendingFxRecipeRevisions, isNotEmpty);
      expect(store.fxWrites, 0);
      var closed = false;
      final closing = runtime.close().then((_) => closed = true);
      await pumpEventQueue();
      final closedBeforeReceipt = closed;
      final writesBeforeReceipt = store.fxWrites;
      if (stopEngine) {
        expect(repository.stopEngine(), EngineResult.ok);
      } else {
        engine.publishFxRecipe(owner: FxOwner.track);
      }
      await closing;
      // Also let any incorrectly detached work reveal itself before assertions.
      await pumpEventQueue();
      expect(closedBeforeReceipt, isFalse);
      expect(writesBeforeReceipt, 0);
      expect(store.fxWrites, 1);
      final saved = decodeFxChain(await settings.loadTrackFxChain(0));
      expect((saved.entries.single as BuiltInEffect).params.first, .7);
    });
  }

  test('close waits for an unawaited FX stomp and its delayed store', () async {
    await prepareTrackFx();
    store.fxWrite = Completer<void>();
    engine
      ..publishFxRecipes = false
      ..commandsAreSettled = false;
    // An admitted structural edit is awaiting the audio callback. Subsequent
    // atomic knob/power edits must share its confirmation barrier.
    expect(
      repository.setTrackEffects(
        channel: 0,
        effects: repository.trackEffects(0),
      ),
      EngineResult.ok,
    );
    runtime.control.toggleTrackChain(0);
    expect(engine.pendingFxRecipeRevisions, isNotEmpty);
    var closed = false;
    final closing = runtime.close().then((_) => closed = true);
    await pumpEventQueue();
    final closedBeforeReceipt = closed;
    final writesBeforeReceipt = store.fxWrites;
    engine.publishFxRecipe(owner: FxOwner.track);
    await store.fxWriteEntered.future;
    await pumpEventQueue();
    final closedBeforeStorage = closed;
    store.fxWrite!.complete();
    await closing;
    final writesAtClose = store.fxWrites;
    await pumpEventQueue();
    expect(closedBeforeReceipt, isFalse);
    expect(writesBeforeReceipt, 0);
    expect(closedBeforeStorage, isFalse);
    expect(writesAtClose, 1);
    expect(store.fxWrites, writesAtClose);
    final saved = decodeFxChain(await settings.loadTrackFxChain(0));
    expect(saved.chainEnabled, isFalse);
  });

  test(
    'shutdown refuses retained lane mute failure until explicit retry',
    () async {
      await runtime.start();
      store.refuseMute = true;
      runtime.looper.add(const LooperMuteToggled(0));
      await pumpEventQueue();
      expect(repository.laneMuted(0, 0), isTrue);
      expect(store.values['lane_mute.0.0'], isTrue);
      await expectLater(
        runtime.prepareShutdown(retry: false),
        throwsStateError,
      );
      store.refuseMute = false;
      await runtime.prepareShutdown(retry: true);
      expect(await settings.loadLaneMute(0, 0), isTrue);
    },
  );

  test('FX flush failure still closes every application owner', () async {
    await prepareTrackFx();
    store.refuseFx = true;
    runtime.fxPersistence.scheduleSave(
      const FxAddress(stage: FxStage.track),
      settings,
      debounce: const Duration(minutes: 1),
    );
    final disposed = <String>{};
    runtime.tempo.stream.listen((_) {}, onDone: () => disposed.add('tempo'));
    runtime.playback.stream.listen(
      (_) {},
      onDone: () => disposed.add('playback'),
    );
    runtime.record.stream.listen((_) {}, onDone: () => disposed.add('record'));
    runtime.timing.stream.listen((_) {}, onDone: () => disposed.add('timing'));
    runtime.mix.failures.listen((_) {}, onDone: () => disposed.add('mix'));
    closeFailureExpected = true;
    await expectLater(runtime.close(), throwsStateError);
    expect(disposed, {'tempo', 'playback', 'record', 'timing', 'mix'});
    expect(runtime.power.isClosed, isTrue);
    expect(runtime.session.isClosed, isTrue);
    expect(runtime.control.isClosed, isTrue);
    expect(runtime.looper.isClosed, isTrue);
    final writesAtClose = store.fxWrites;
    await pumpEventQueue();
    expect(store.fxWrites, writesAtClose);
  });

  group('Click settings owners', () {
    Future<void> settled(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue);
    }

    test('flush reports current state after a capture-locked refusal, a '
        'cancelled receipt while stopped and a superseded write', () async {
      await runtime.start();
      final click = runtime.tempo.clickVolumeOwner;
      final mode = runtime.tempo.clickModeOwner;
      final idle = engine.nextSnapshot;
      engine.nextSnapshot = idle.copyWith(
        tracks: [
          const TrackSnapshot(
            state: TrackState.recording,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          for (var i = 1; i < 8; i++) const TrackSnapshot.empty(),
        ],
      );
      expect((await mode.set(ClickMode.rec)).status, SettingStatus.rejected);
      engine
        ..nextSnapshot = idle
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      final cancelled = click.set(1.5);
      await settled(() => engine.lastClickVolume == 1.5);
      repository.stopEngine();
      expect((await cancelled).status, SettingStatus.superseded);
      engine
        ..publishClickCommands = true
        ..commandsAreSettled = true;

      final stale = await click.setController(
        .25,
        lifetime: (sessionRevision: -1, mixGeneration: -1),
      );
      expect(stale.status, SettingStatus.superseded);

      expect((await click.flush()).status, SettingStatus.applied);
      expect((await mode.flush()).status, SettingStatus.applied);
      await runtime.prepareShutdown(retry: false);
      expect(engine.stopCalls, 1);
    });

    test('an owed Click volume and an owed Mixer vector do not block '
        'power-off: storage holds both, and the halt fires', () async {
      await runtime.start();
      engine
        ..publishClickCommands = false
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      expect(
        (await runtime.tempo.clickVolumeOwner.set(1.5)).status,
        SettingStatus.recoveryRequired,
      );
      expect(
        (await runtime.mix.setTrackPan(.4)).status,
        MixSettingsStatus.recoveryRequired,
      );
      expect(repository.mixRecoveryRequired, isTrue);
      expect(runtime.tempo.clickVolumeOwner.ready, isFalse);
      runtime.power.press(const PowerOffSnapshot());
      for (var i = 0; i < 200 && halts == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(runtime.power.state.phase, PowerOffPhase.goodbye);
      expect(halts, 1);
      // The next start replays what storage holds.
      expect(store.values['tempo.click_volume'], 1.5);
      final device = repository.state.status.deviceName;
      expect((await settings.loadMixSettings(device)).trackPans[0], .4);
      expect(engine.stopCalls, 0);
    });

    test('a Retry that cannot land an owed setting still lets power-off go '
        'ahead', () async {
      await runtime.start();
      engine
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      expect(
        (await runtime.tempo.clickVolumeOwner.set(1.5)).status,
        SettingStatus.recoveryRequired,
      );
      await runtime.prepareShutdown(retry: true);
      expect(runtime.tempo.clickVolumeOwner.ready, isFalse);
      expect(store.values['tempo.click_volume'], 1.5);
      expect(engine.stopCalls, 0);
    });

    test('a Retry that cannot land an owed vector still lets power-off go '
        'ahead', () async {
      await runtime.start();
      engine
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      expect(
        (await runtime.mix.setTrackPan(.4)).status,
        MixSettingsStatus.recoveryRequired,
      );
      await runtime.prepareShutdown(retry: true);
      expect(repository.mixRecoveryRequired, isTrue);
      expect(engine.stopCalls, 0);
    });

    test('an unreadable Count-in pair keeps audio running and the registry '
        'Retry repairs it for shutdown', () async {
      store.values
        ..['tempo.count_in_bars'] = 2
        ..['looper.auto_record'] = true;
      await runtime.start();
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(runtime.tempo.recordStartOwner.ready, isFalse);
      await expectLater(
        runtime.prepareShutdown(retry: false),
        throwsStateError,
      );
      await runtime.prepareShutdown(retry: true);
      expect(store.values['tempo.count_in_bars'], 0);
      expect(store.values['looper.auto_record'], isFalse);
      expect(runtime.tempo.recordStartOwner.ready, isTrue);
      expect(engine.stopCalls, 0);
    });

    test('unreadable Hear click keeps audio running and Retry repairs it '
        'for shutdown', () async {
      store.values['tempo.click_mode'] = 9;
      await runtime.start();
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(engine.stopCalls, 0);
      expect(runtime.tempo.clickModeOwner.ready, isFalse);
      await expectLater(
        runtime.prepareShutdown(retry: false),
        throwsStateError,
      );
      await runtime.prepareShutdown(retry: true);
      expect(store.values['tempo.click_mode'], ClickMode.off.code);
      expect(runtime.tempo.clickModeOwner.value, ClickMode.off);
      expect(engine.stopCalls, 0);
    });
  });

  test('late controller startup cannot change a disposed rig', () async {
    store.values['looper.default_mode'] = 'mute';
    store.midiRead = Completer<String?>();
    final started = runtime.start();
    await store.midiReadEntered.future;
    await runtime.close();
    store.midiRead!.complete();
    await expectLater(started, completes);
  });
}

/// Answers a stubbed `open` with a bundle that needed no conversion.
Future<OpenedSession> Function(Invocation) _opened(
  FutureOr<SessionBundle> Function(Invocation) answer,
) =>
    (invocation) async => (bundle: await answer(invocation), conversion: null);
