import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:settings_repository/settings_repository.dart'
    as persisted
    show AudioBackend;
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockBackingRepository extends Mock implements BackingRepository {}

const _applied = AudioApplyResult(
  status: AudioApplyStatus.applied,
  result: EngineResult.ok,
);

void main() {
  setUpAll(() => registerFallbackValue(const EngineConfig()));

  late LooperRepository repository;
  late BackingRepository backing;
  late GuardRegistry guards;
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late StreamController<LooperState> stateController;

  setUp(() {
    repository = _MockLooperRepository();
    backing = _MockBackingRepository();
    when(() => backing.state).thenReturn(const BackingPlayerState());
    guards = GuardRegistry();
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lastEngineConfig).thenReturn(null);
    when(() => repository.applyAudioConfig(any())).thenReturn(_applied);
    when(() => repository.fxRoomAt(any(), any())).thenReturn(1 << 30);
    when(
      () => repository.stopTrack(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(() => repository.setRecordOffset(any())).thenReturn(EngineResult.ok);
    when(repository.devices).thenReturn(const []);
  });

  tearDown(() => stateController.close());

  AudioSetupCubit buildCubit({
    Duration deviceRefreshInterval = const Duration(seconds: 1),
  }) => AudioSetupCubit(
    repository: repository,
    settings: settings,
    guards: guards,
    backing: backing,
    deviceRefreshInterval: deviceRefreshInterval,
  );

  test('initial state has sensible defaults', () {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    expect(cubit.state.sampleRate, 48000);
    expect(cubit.state.bufferFrames, 128);
    expect(cubit.state.status, AudioSetupStatus.stopped);
  });

  test('hydrates from the repository when the engine is already running', () {
    when(() => repository.state).thenReturn(
      const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 96000,
          bufferFrames: 256,
          isConnected: true,
        ),
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 96000,
        bufferFrames: 256,
      ),
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);

    expect(cubit.state.status, AudioSetupStatus.running);
    expect(cubit.state.sampleRate, 96000);
    expect(cubit.state.bufferFrames, 256);
    expect(cubit.state.engineStatus.deviceName, 'Scarlett');
  });

  group('apply (#1270 Part 3a)', () {
    const running = EngineStatus(
      deviceName: 'Scarlett',
      sampleRate: 48000,
      bufferFrames: 128,
      isConnected: true,
      devicePresent: true,
    );
    const playing = Track(
      state: TrackState.playing,
      lengthFrames: 48000,
    );
    const recorded = Track(
      channel: 1,
      state: TrackState.stopped,
      lengthFrames: 48000,
    );

    void seed({List<Track> tracks = const [], bool countingIn = false}) {
      LooperState looper(int rate, int buffer) => LooperState(
        status: EngineStatus(
          deviceName: running.deviceName,
          sampleRate: rate,
          bufferFrames: buffer,
          isConnected: true,
          devicePresent: true,
        ),
        tracks: tracks,
        transport: TransportState(countingIn: countingIn),
      );
      when(() => repository.state).thenReturn(looper(48000, 128));
      // The device opens what it is asked for: the snapshot follows.
      when(() => repository.applyAudioConfig(any())).thenAnswer((invocation) {
        final config = invocation.positionalArguments.single as EngineConfig;
        when(
          () => repository.state,
        ).thenReturn(looper(config.sampleRate, config.bufferFrames));
        return _applied;
      });
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(sampleRate: 48000, bufferFrames: 128),
      );
    }

    test('a buffer change while stopped applies once and saves it', () async {
      seed();
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(256);

      final asked =
          verify(
                () => repository.applyAudioConfig(captureAny()),
              ).captured.single
              as EngineConfig;
      expect(asked.bufferFrames, 256);
      verifyNever(() => repository.startEngine(any()));
      verifyNever(repository.stopEngine);
      await pumpEventQueue();
      expect((await settings.loadAudioConfig())?.bufferFrames, 256);
    });

    test('a change while a track plays asks first and calls nothing', () {
      seed(tracks: const [playing]);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(256);

      expect(cubit.state.applyPhase, ApplyPhase.confirming);
      expect(cubit.state.bufferFrames, 128);
      verifyNever(() => repository.applyAudioConfig(any()));
      verifyNever(() => repository.stopTrack(channel: any(named: 'channel')));
    });

    test('Stop audio and apply stops the tracks and the backing, then '
        'applies', () {
      seed(tracks: const [playing]);
      when(() => backing.state).thenReturn(
        const BackingPlayerState(transport: BackingTransport.playing),
      );
      final cubit = buildCubit()..setBufferFrames(256);
      addTearDown(cubit.close);

      cubit.confirmApply();

      expect(cubit.state.applyPhase, ApplyPhase.idle);
      verifyInOrder([
        () => repository.stopTrack(),
        backing.stop,
        () => repository.applyAudioConfig(any()),
      ]);
    });

    test('Cancel leaves playback and the config as they were', () {
      seed(tracks: const [playing]);
      final cubit = buildCubit()..setBufferFrames(256);
      addTearDown(cubit.close);

      cubit.cancelApply();

      expect(cubit.state.applyPhase, ApplyPhase.idle);
      expect(cubit.state.bufferFrames, 128);
      verifyNever(() => repository.stopTrack(channel: any(named: 'channel')));
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    for (final (label, tracks, countingIn) in [
      ('recording', const [Track(state: TrackState.recording)], false),
      ('overdubbing', const [Track(state: TrackState.overdubbing)], false),
      ('waiting on a quantized start', const [Track(pending: true)], false),
      ('counting in', const <Track>[], true),
    ]) {
      test('every setter is refused while a track is $label', () {
        seed(tracks: tracks, countingIn: countingIn);
        final cubit = buildCubit();
        addTearDown(cubit.close);

        cubit
          ..setBufferFrames(256)
          ..setDevice(playbackDeviceId: 'a', captureDeviceId: 'a')
          ..setMaxLoopMinutes(5)
          ..setSampleRate(96000);

        expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
        verifyNever(() => repository.applyAudioConfig(any()));
      });
    }

    test('a performance capture refuses it through the guard table', () {
      seed();
      final capture = guards.enter(
        GuardKind.capture,
        const GuardScope.internal(),
        purpose: 'performance',
      );
      addTearDown(capture.release);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(256);

      expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a take that starts while the question is open refuses the '
        'confirm', () {
      seed(tracks: const [playing]);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      cubit.setBufferFrames(256);
      seed(tracks: const [Track(state: TrackState.recording)]);

      cubit.confirmApply();

      expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
      verifyNever(() => repository.stopTrack(channel: any(named: 'channel')));
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('the apply holds the device-change guard while it runs', () {
      seed();
      late List<ActiveOperation> during;
      when(() => repository.applyAudioConfig(any())).thenAnswer((_) {
        during = guards.active;
        return _applied;
      });
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(256);

      expect(during.single.kind, GuardKind.deviceChange);
      expect(guards.active, isEmpty);
    });

    test('with material the rate and the loop cap are locked; the buffer and '
        'the device are not', () {
      seed(tracks: const [recorded]);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.hasContent, isTrue);

      cubit
        ..setSampleRate(96000)
        ..setMaxLoopMinutes(5);
      verifyNever(() => repository.applyAudioConfig(any()));
      expect(cubit.state.sampleRate, 48000);
      expect(cubit.state.maxLoopMinutes, 0);
      expect(cubit.state.refusal, isNull);

      cubit.setBufferFrames(256);
      verify(() => repository.applyAudioConfig(any())).called(1);
    });

    test('with every track empty the rate and the loop cap apply', () {
      seed();
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..setSampleRate(44100)
        ..setMaxLoopMinutes(5);

      verify(() => repository.applyAudioConfig(any())).called(2);
    });

    test('a higher rate the effects do not fit is refused inline (D19)', () {
      seed();
      when(() => repository.fxRoomAt(96000, 128)).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setSampleRate(96000);

      expect(cubit.state.refusal, const ApplyRefusal.overBudgetRate(96000));
      expect(cubit.state.sampleRate, 48000);
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a change that only lowers the cost is never refused (D19)', () {
      seed();
      when(() => repository.fxRoomAt(any(), any())).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..setSampleRate(44100)
        ..setBufferFrames(512);

      verifyNever(() => repository.fxRoomAt(any(), any()));
      verify(() => repository.applyAudioConfig(any())).called(2);
    });

    test('a refused config saves nothing and names both configs', () async {
      seed();
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.device,
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setSampleRate(96000);

      expect(cubit.state.sampleRate, 48000);
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.phase, ConfigPhase.refused);
      expect(cubit.state.requestedRate, 96000);
      expect(cubit.state.actualRate, 48000);
      await pumpEventQueue();
      expect((await settings.loadAudioConfig())?.sampleRate, 48000);
    });

    test('a refused change clears a refusal shown before it', () {
      seed();
      when(() => repository.fxRoomAt(96000, 128)).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      cubit.setSampleRate(96000);
      expect(cubit.state.refusal, isNotNull);

      cubit.setBufferFrames(256);

      expect(cubit.state.refusal, isNull);
    });

    test('a repository that will not reopen at all refuses as busy', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.notReady,
        ),
      );
      final cubit = buildCubit()..setBufferFrames(256);
      addTearDown(cubit.close);

      expect(cubit.state.refusal, const ApplyRefusal.busy('other'));
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.phase, ConfigPhase.settled);
    });

    test('an interface that will not open is named, not its rates', () {
      seed();
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'b',
          name: 'Other Interface',
          isDefault: false,
          isInput: false,
        ),
      ]);
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.device,
        ),
      );
      final cubit = buildCubit()
        ..setDevice(playbackDeviceId: 'b', captureDeviceId: 'b');
      addTearDown(cubit.close);

      expect(
        cubit.state.refusal,
        const ApplyRefusal.deviceRefused('Other Interface'),
      );
      expect(cubit.state.phase, ConfigPhase.settled);
      expect(cubit.state.playbackDeviceId, isEmpty);
    });

    test('a refused apply that cleared the loops still says so', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.device,
          reopen: EngineReopened(
            outcome: ReopenOutcome.clearedRate,
            droppedTracks: 0,
            previousSampleRate: 48000,
            sampleRate: 44100,
          ),
        ),
      );
      final cubit = buildCubit()
        ..setDevice(playbackDeviceId: 'b', captureDeviceId: 'b');
      addTearDown(cubit.close);

      expect(
        cubit.state.deviceConnectivity,
        DeviceConnectivity.restoredCleared,
      );
    });

    test('after a failed open the same choice can be asked again', () {
      seed();
      var calls = 0;
      when(() => repository.applyAudioConfig(any())).thenAnswer((_) {
        calls++;
        return calls == 1
            ? const AudioApplyResult(
                status: AudioApplyStatus.failed,
                result: EngineResult.device,
              )
            : _applied;
      });
      final cubit = buildCubit()
        ..setDevice(playbackDeviceId: 'b', captureDeviceId: 'b');
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.error);

      // Nothing runs, so tapping what is shown is the retry.
      cubit.setBufferFrames(128);

      expect(calls, 2);
      expect(cubit.state.status, AudioSetupStatus.running);
    });

    test('a buffer change keeps the loop cap that is open, so the reopen '
        'keeps the loops', () {
      seed();
      // Open at a cap a minute count does not round-trip to.
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          maxLoopFrames: 14399999,
        ),
      );
      final cubit = buildCubit()..setBufferFrames(256);
      addTearDown(cubit.close);

      final asked =
          verify(
                () => repository.applyAudioConfig(captureAny()),
              ).captured.single
              as EngineConfig;
      expect(asked.maxLoopFrames, 14399999);
    });

    test('a reopen that cleared the loops says so (#1140)', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.applied,
          result: EngineResult.ok,
          reopen: EngineReopened(
            outcome: ReopenOutcome.clearedRate,
            droppedTracks: 0,
            previousSampleRate: 48000,
            sampleRate: 44100,
          ),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setDevice(playbackDeviceId: 'b', captureDeviceId: 'b');

      expect(
        cubit.state.deviceConnectivity,
        DeviceConnectivity.restoredCleared,
      );
    });

    test('a reopen that kept every loop raises no notice', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.applied,
          result: EngineResult.ok,
          reopen: EngineReopened(
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            previousSampleRate: 48000,
            sampleRate: 48000,
          ),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(256);

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
      expect(cubit.state.status, AudioSetupStatus.running);
    });

    test('a setting change uses the selected max loop length '
        '(minutes -> frames)', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setMaxLoopMinutes(5);

      // 5 min * 60 s * 48000 Hz = 14_400_000 frames.
      verify(
        () => repository.applyAudioConfig(
          const EngineConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            maxLoopFrames: 14400000,
          ),
        ),
      ).called(1);
      await pumpEventQueue();
      expect((await settings.loadAudioConfig())?.maxLoopMinutes, 5);
    });

    test('a failed open surfaces an error and keeps the selection', () {
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.failed,
          result: EngineResult.device,
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setBufferFrames(64);

      expect(cubit.state.status, AudioSetupStatus.error);
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.errorDetail, EngineResult.device.name);
      expect(cubit.state.bufferFrames, 128);
    });

    test('a later success clears the error', () {
      var calls = 0;
      when(() => repository.applyAudioConfig(any())).thenAnswer((_) {
        calls++;
        return calls == 1
            ? const AudioApplyResult(
                status: AudioApplyStatus.failed,
                result: EngineResult.device,
              )
            : _applied;
      });
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..setBufferFrames(64)
        ..setBufferFrames(256);

      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.error, isNull);
      expect(cubit.state.errorDetail, isNull);
    });
  });

  test('hydrates maxLoopMinutes from the last engine config (frames)', () {
    when(() => repository.state).thenReturn(
      const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
        ),
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        maxLoopFrames: 14400000, // 5 minutes at 48 kHz
      ),
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);

    expect(cubit.state.maxLoopMinutes, 5);
  });

  blocTest<AudioSetupCubit, AudioSetupState>(
    'repository stream updates the engine status',
    build: buildCubit,
    act: (_) => stateController.add(
      const LooperState(
        status: EngineStatus(deviceName: 'Scarlett', isConnected: true),
      ),
    ),
    expect: () => [
      isA<AudioSetupState>()
          .having((s) => s.engineStatus.deviceName, 'deviceName', 'Scarlett')
          .having((s) => s.status, 'status', AudioSetupStatus.running),
    ],
  );

  test('detects a loopback on construction and exposes it', () {
    const routable = LoopbackInfo(
      available: true,
      kind: LoopbackKind.virtualDevice,
      deviceName: 'BlackHole 2ch',
    );
    when(repository.detectLoopback).thenReturn(routable);
    final cubit = buildCubit();
    addTearDown(cubit.close);
    expect(cubit.state.loopback, routable);
  });

  group('latency persistence', () {
    const connected = LooperState(
      status: EngineStatus(
        deviceName: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        isConnected: true,
      ),
    );

    test('applies a saved offset when a device connects', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        frames: 512,
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(connected);
      await pumpEventQueue();

      verify(() => repository.setRecordOffset(512)).called(1);
    });

    test('an unmeasured profile sets the offset to 0 and saves nothing '
        '(#1270 Part 3a)', () async {
      // The offset replayed from another device, rate or buffer must not
      // compensate this one; and only a measurement saves an offset.
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 256,
            isConnected: true,
            recordOffsetFrames: 640,
          ),
        ),
      );
      await pumpEventQueue();

      verify(() => repository.setRecordOffset(0)).called(1);
      expect(
        await settings.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 256,
        ),
        isNull,
      );
    });

    test('a new profile after an apply gets its own saved offset', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 256,
        frames: 300,
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(connected);
      await pumpEventQueue();
      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 256,
            isConnected: true,
            recordOffsetFrames: 512,
          ),
        ),
      );
      await pumpEventQueue();

      verify(() => repository.setRecordOffset(300)).called(1);
    });
  });

  group('device selection', () {
    test('hydrates devices and selected ids from the repository', () {
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett',
          isDefault: true,
          isInput: false,
        ),
        AudioDevice(
          id: 'in-1',
          name: 'Built-in Mic',
          isDefault: true,
          isInput: true,
        ),
      ]);
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1', captureDeviceId: 'in-1'),
      );

      final cubit = buildCubit();
      addTearDown(cubit.close);

      expect(cubit.state.devices, hasLength(2));
      expect(cubit.state.playbackDevices, hasLength(1));
      expect(cubit.state.captureDevices, hasLength(1));
      expect(cubit.state.playbackDeviceId, 'out-1');
      expect(cubit.state.captureDeviceId, 'in-1');
    });

    const plugged = AudioDevice(
      id: 'in-9',
      name: 'Scarlett 4i4',
      isDefault: false,
      isInput: true,
    );

    test('refreshDevices re-enumerates and updates the picker', () {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.devices, isEmpty);

      // An interface is plugged in after launch.
      when(repository.devices).thenReturn(const [plugged]);
      cubit.refreshDevices();

      expect(cubit.state.devices, const [plugged]);
      expect(cubit.state.captureDevices, const [plugged]);
    });

    test(
      'periodically re-enumerates so a later-plugged device appears',
      () async {
        final cubit = buildCubit(
          deviceRefreshInterval: const Duration(milliseconds: 10),
        )..beginDeviceScan();
        addTearDown(cubit.close);

        when(repository.devices).thenReturn(const [plugged]);
        // Let the refresh timer fire (interval 10ms; ample margin).
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(cubit.state.devices, const [plugged]);
      },
    );

    group('the poll is gated on a picker (#649)', () {
      // The enumeration is a synchronous engine call on the UI isolate, and
      // its miniaudio fall-through — the path the appliance takes when an
      // interface is unplugged — measured 950 ms/tick. It must not run when
      // nothing is rendering the list.
      const interval = Duration(milliseconds: 10);

      test('never re-enumerates while no picker is mounted', () async {
        final cubit = buildCubit(deviceRefreshInterval: interval);
        addTearDown(cubit.close);
        // The one enumeration at construction hydrates the initial state.
        verify(repository.devices).called(1);

        await Future<void>.delayed(const Duration(milliseconds: 80));

        verifyNever(repository.devices);
      });

      test('beginDeviceScan enumerates at once, then keeps polling', () async {
        final cubit = buildCubit(deviceRefreshInterval: interval);
        addTearDown(cubit.close);
        verify(repository.devices).called(1);
        when(repository.devices).thenReturn(const [plugged]);

        cubit.beginDeviceScan();

        // Immediately, so opening a picker never shows a stale list.
        expect(cubit.state.devices, const [plugged]);
        verify(repository.devices).called(1);

        await Future<void>.delayed(const Duration(milliseconds: 80));

        verify(repository.devices).called(greaterThan(1));
      });

      test('endDeviceScan stops it again', () async {
        final cubit = buildCubit(deviceRefreshInterval: interval)
          ..beginDeviceScan()
          ..endDeviceScan();
        addTearDown(cubit.close);
        // Construction + the scope's own immediate refresh.
        verify(repository.devices).called(2);

        await Future<void>.delayed(const Duration(milliseconds: 80));

        verifyNever(repository.devices);
      });

      test(
        'two overlapping pickers keep the poll alive between them',
        () async {
          // A route transition mounts the incoming surface before the outgoing
          // one disposes; the poll must survive that handover.
          final cubit = buildCubit(deviceRefreshInterval: interval)
            ..beginDeviceScan()
            ..beginDeviceScan()
            ..endDeviceScan();
          addTearDown(cubit.close);

          when(repository.devices).thenReturn(const [plugged]);
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(cubit.state.devices, const [plugged]);
        },
      );

      test('an unbalanced endDeviceScan is inert', () {
        final cubit = buildCubit(deviceRefreshInterval: interval)
          ..endDeviceScan()
          ..beginDeviceScan();
        addTearDown(cubit.close);

        when(repository.devices).thenReturn(const [plugged]);
        cubit.refreshDevices();

        expect(cubit.state.devices, const [plugged]);
      });
    });

    test('setPlaybackDevice updates state and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setPlaybackDevice('out-1');
      expect(cubit.state.playbackDeviceId, 'out-1');
      await Future<void>.delayed(Duration.zero);
      expect((await settings.loadAudioConfig())?.playbackDeviceId, 'out-1');
    });

    test('setCaptureDevice updates state and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit.setCaptureDevice('in-1');
      expect(cubit.state.captureDeviceId, 'in-1');
      await Future<void>.delayed(Duration.zero);
      expect((await settings.loadAudioConfig())?.captureDeviceId, 'in-1');
    });

    test('selecting a device while running reopens the engine on it', () {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'X', isConnected: true),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.running);

      cubit.setPlaybackDevice('out-1');

      // Reopened through the material-keeping apply, never stop and start.
      verifyNever(repository.stopEngine);
      verifyNever(() => repository.startEngine(any()));
      final captured =
          verify(
                () => repository.applyAudioConfig(captureAny()),
              ).captured.single
              as EngineConfig;
      expect(captured.playbackDeviceId, 'out-1');
    });

    test('a failed reopen while running surfaces an error', () {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'X', isConnected: true),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.running);

      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.failed,
          result: EngineResult.device,
        ),
      );
      cubit.setPlaybackDevice('out-1');

      expect(cubit.state.status, AudioSetupStatus.error);
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.errorDetail, isNotNull);
    });
  });

  group('device connectivity', () {
    LooperState present({
      required bool devicePresent,
      String name = 'Scarlett',
      EngineReopened? reopen,
    }) => LooperState(
      status: EngineStatus(
        deviceName: name,
        isConnected: true,
        devicePresent: devicePresent,
        reopen: reopen,
      ),
    );

    const partial = EngineReopened(
      outcome: ReopenOutcome.retainedPartial,
      droppedTracks: 1 << 2,
      previousSampleRate: 48000,
      sampleRate: 48000,
    );
    const cleared = EngineReopened(
      outcome: ReopenOutcome.clearedRate,
      droppedTracks: 0,
      previousSampleRate: 48000,
      sampleRate: 44100,
    );

    test(
      'a return that kept every loop is the plain restored event, even with '
      'a retained verdict on the status (#1140)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);
        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        stateController.add(
          present(
            devicePresent: true,
            reopen: const EngineReopened(
              outcome: ReopenOutcome.retained,
              droppedTracks: 0,
              previousSampleRate: 48000,
              sampleRate: 48000,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.restored);
      },
    );

    test(
      'a return that dropped some tracks is the partial variant — one notice, '
      'not restored plus another (#1140)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);
        final seen = <DeviceConnectivity>[];
        final sub = cubit.stream.listen(
          (state) => seen.add(state.deviceConnectivity),
        );
        addTearDown(sub.cancel);
        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: true, reopen: partial));
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.deviceConnectivity,
          DeviceConnectivity.restoredPartial,
        );
        expect(cubit.state.engineStatus.reopen, partial);
        expect(seen, isNot(contains(DeviceConnectivity.restored)));
      },
    );

    test(
      'a return at another rate is the standing cleared notice, until the '
      'user acts on it (#1140)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);
        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: true, reopen: cleared));
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.deviceConnectivity,
          DeviceConnectivity.restoredCleared,
        );
        // Further present ticks are not transitions: the notice stands.
        stateController.add(present(devicePresent: true, reopen: cleared));
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.deviceConnectivity,
          DeviceConnectivity.restoredCleared,
        );
        cubit.dismissReopenNotice();
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
      },
    );

    test(
      'a later return without a verdict is the plain restored event, even '
      'after an earlier partial reconnect (#1167)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);
        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: true, reopen: partial));
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.deviceConnectivity,
          DeviceConnectivity.restoredPartial,
        );
        // The repository forgets the verdict at the next loss; the return the
        // backend handled on its own must not re-raise it.
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.restored);
      },
    );

    test(
      'a re-apply that opens the rig after a rolled-back reopen raises the '
      'carried verdict instead of nothing (#1167)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        when(() => repository.state).thenReturn(
          const LooperState(
            status: EngineStatus(
              deviceName: 'Scarlett',
              isConnected: true,
              devicePresent: true,
              sampleRate: 44100,
              bufferFrames: 128,
              reopen: cleared,
            ),
          ),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);
        // A different rate than the hydrated one, so this is a real re-apply.
        cubit.setSampleRate(96000);
        verify(() => repository.applyAudioConfig(any())).called(1);
        expect(cubit.state.status, AudioSetupStatus.running);
        expect(
          cubit.state.deviceConnectivity,
          DeviceConnectivity.restoredCleared,
        );
        expect(cubit.state.connectivityDeviceName, 'Scarlett');
      },
    );

    test('an ordinary re-apply raises no notice', () async {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1'),
      );
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            isConnected: true,
            devicePresent: true,
            sampleRate: 44100,
            bufferFrames: 128,
          ),
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      cubit.setSampleRate(96000);
      verify(() => repository.applyAudioConfig(any())).called(1);
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test('dismissing the notice touches nothing else', () async {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1'),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
      cubit.dismissReopenNotice();
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
    });

    test('raises lost then restored for a pinned device', () async {
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(playbackDeviceId: 'out-1'),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);

      // Device lost (name now empty, but the last-seen name is remembered).
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
      expect(cubit.state.connectivityDeviceName, 'Scarlett');

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.restored);
    });

    test('never raises an event for the system default', () async {
      final cubit = buildCubit(); // no pinned device
      addTearDown(cubit.close);

      stateController.add(present(devicePresent: true));
      await Future<void>.delayed(Duration.zero);
      stateController.add(present(devicePresent: false));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test(
      'resolving a lost device by picking the system default clears the '
      'standing condition for good (#453)',
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);

        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);

        // The banner's action ends it: un-pinning to the system default IS a
        // resolution — and after it the pinned guard would never clear the
        // enum again, so the apply itself must.
        cubit.setPlaybackDevice('');
        expect(cubit.state.playbackDeviceId, isEmpty);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);

        // Un-pinned ticks with the old interface still absent stay quiet.
        stateController.add(present(devicePresent: false, name: ''));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
      },
    );

    test(
      "the app's own reopen being refused does not read as an unplug (#453)",
      () async {
        when(() => repository.lastEngineConfig).thenReturn(
          const EngineConfig(playbackDeviceId: 'out-1'),
        );
        final cubit = buildCubit();
        addTearDown(cubit.close);

        stateController.add(present(devicePresent: true));
        await Future<void>.delayed(Duration.zero);

        // A settings change stops the engine and the restart is refused: the
        // engine now reports no device — with the hardware plugged in the
        // whole time.
        when(() => repository.applyAudioConfig(any())).thenReturn(
          const AudioApplyResult(
            status: AudioApplyStatus.failed,
            result: EngineResult.device,
          ),
        );
        cubit.setSampleRate(96000);
        expect(cubit.state.status, AudioSetupStatus.error);

        // The stopped engine's ticks (default status: not connected, device
        // not present) must not raise `lost` beside the real error: the stop
        // was the app's own.
        stateController.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        stateController.add(const LooperState());
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
        expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      },
    );
  });

  group('AudioBackend bridge (domain <-> settings)', () {
    test('round-trips every value in both directions', () {
      for (final backend in AudioBackend.values) {
        expect(engineBackendOf(settingsBackendOf(backend)), backend);
      }
      for (final backend in persisted.AudioBackend.values) {
        expect(settingsBackendOf(engineBackendOf(backend)), backend);
      }
    });
  });
}
