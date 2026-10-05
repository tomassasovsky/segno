import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show FxOwner;
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
    when(() => sessions.bundlePath(any())).thenAnswer((_) async => '/test');
    when(sessions.listSessions).thenAnswer((_) async => []);
    exportsDirectory = '.';
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => exportsDirectory,
    );
    addTearDown(performance.dispose);
    runtime = AppRuntime(
      repository: repository,
      settings: settings,
      mix: testMixSettings(repository, settings: settings),
      controllers: controllers,
      midiDevices: midi,
      pedal: pedal,
      performance: performance,
      sessions: sessions,
      exportDirectory: () async => '.',
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
    when(() => sessions.read(any())).thenAnswer((_) {
      entered.complete();
      return read.future;
    });
    final loading = runtime.session.loadNamed('Incoming');
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
        when(() => sessions.read(any())).thenAnswer(
          (_) async => (
            session: const Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: [],
              defaultFadeDurationMs: 12000,
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        );
        store.refuseFade = true;
        await runtime.session.loadNamed('Incoming');
        expect(runtime.session.state.bootRecoveryRequired, isTrue);
        expect(repository.sessionBootRecoveryRequired, isTrue);
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
      },
    );

    test(
      'real Session save waits for duration and refuses later edits',
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
        await expectLater(runtime.fade.setDefault(8000), throwsStateError);
        expect(
          (await runtime.mix.setTrackVolume(.3)).status,
          MixSettingsStatus.superseded,
        );
        expect(saved, isNull);
        store.fadeWrite!.complete();
        await edit;
        await save;
        expect(runtime.session.state.outcome, SessionOutcome.saved);
        expect(saved!.defaultFadeDurationMs, 4000);
        expect(saved!.trackFadeDurationOverrides, {7: 4000});
      },
    );

    test(
      'invalid incoming vector fails before disarm or stored setup changes',
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
        when(() => sessions.read(any())).thenAnswer(
          (_) async => (
            session: const Session(
              sampleRate: 48000,
              channels: 1,
              baseLengthFrames: 0,
              tracks: [],
              defaultFadeDurationMs: 501,
            ),
            laneStems: <(int, int), List<Float32List>>{},
          ),
        );
        await runtime.session.loadNamed('invalid');
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
    when(() => sessions.read(any())).thenAnswer(
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
              lanes: [
                SessionLane(
                  lane: 0,
                  volume: .4,
                  muted: false,
                  outputMask: 1,
                  inputChannel: 0,
                  layers: [SessionLayer(file: 'track0_lane0_L0.wav')],
                ),
              ],
            ),
          ],
        ),
        laneStems: {
          (0, 0): [Float32List(128)..fillRange(0, 128, .5)],
        },
      ),
    );
    final loading = runtime.session.loadNamed('Incoming');
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
