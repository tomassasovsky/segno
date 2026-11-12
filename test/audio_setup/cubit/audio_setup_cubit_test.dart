import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository;

class _MockBackingRepository extends Mock implements BackingRepository;

/// Counts the integer writes, so a test can tell an offset saved once.
class _CountingStore extends FakeKeyValueStore {
  int intWrites = 0;

  @override
  Future<void> setInt(String key, int value) {
    intWrites++;
    return super.setInt(key, value);
  }
}

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
    when(() => repository.looperState)
        .thenAnswer((_) => stateController.stream);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lastEngineConfig).thenReturn(null);
    when(() => repository.applyAudioConfig(any())).thenReturn(_applied);
    when(() => repository.fxRoomAt(any(), any())).thenReturn(1 << 30);
    when(() => repository.stopTrack(channel: any(named: 'channel')))
        .thenReturn(EngineResult.ok);
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
    // 48 kHz / 32 frames, the console's measured default (#1529).
    expect(cubit.state.sampleRate, 48000);
    expect(cubit.state.bufferFrames, 32);
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
    when(() => repository.lastEngineConfig)
        .thenReturn(const EngineConfig(sampleRate: 96000, bufferFrames: 256));

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
    const playing = Track(state: TrackState.playing, lengthFrames: 48000);
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
        when(() => repository.state)
            .thenReturn(looper(config.sampleRate, config.bufferFrames));
        return _applied;
      });
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(sampleRate: 48000, bufferFrames: 128));
    }

    test('a buffer change while stopped applies once and saves it', () async {
      seed();
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editBuffer(256)
        ..applyDraft();

      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      expect(asked.bufferFrames, 256);
      verifyNever(() => repository.startEngine(any()));
      verifyNever(repository.stopEngine);
      await pumpEventQueue();
      expect((await settings.loadAudioConfig())?.bufferFrames, 256);
    });

    test('32 frames is on the list: it applies, stays selected and is '
        'saved (#1529)', () async {
      seed();
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editBuffer(32)
        ..applyDraft();

      expect(cubit.state.phase, ConfigPhase.settled);
      expect(cubit.state.bufferFrames, 32);
      expect(cubit.state.actualBuffer, 32);
      await pumpEventQueue();
      expect((await settings.loadAudioConfig())?.bufferFrames, 32);
    });

    test('a change while a track plays asks first and calls nothing', () {
      seed(tracks: const [playing]);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editBuffer(256)
        ..applyDraft();

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
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
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
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
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
          ..editBuffer(256)
          ..applyDraft()
          ..editDevice(playbackDeviceId: 'a', captureDeviceId: 'a')
          ..applyDraft()
          ..editMaxLoop(5)
          ..applyDraft()
          ..editRate(96000)
          ..applyDraft();

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

      cubit
        ..editBuffer(256)
        ..applyDraft();

      expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a take that starts while the question is open refuses the '
        'confirm', () {
      seed(tracks: const [playing]);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      cubit
        ..editBuffer(256)
        ..applyDraft();
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

      cubit
        ..editBuffer(256)
        ..applyDraft();

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
        ..editRate(96000)
        ..applyDraft()
        ..editMaxLoop(5)
        ..applyDraft();
      verifyNever(() => repository.applyAudioConfig(any()));
      expect(cubit.state.sampleRate, 48000);
      expect(cubit.state.maxLoopMinutes, 0);
      expect(cubit.state.refusal, isNull);

      cubit
        ..editBuffer(256)
        ..applyDraft();
      verify(() => repository.applyAudioConfig(any())).called(1);
    });

    test('with every track empty the rate and the loop cap apply', () {
      seed();
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editRate(44100)
        ..applyDraft()
        ..editMaxLoop(5)
        ..applyDraft();

      verify(() => repository.applyAudioConfig(any())).called(2);
    });

    test('a higher rate the effects do not fit is refused inline (D19)', () {
      seed();
      when(() => repository.fxRoomAt(96000, 128)).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editRate(96000)
        ..applyDraft();

      expect(cubit.state.refusal, const ApplyRefusal.overBudgetRate(96000));
      expect(cubit.state.sampleRate, 48000);
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a 32-frame buffer the effects do not fit is refused inline '
        '(D19, #1529)', () {
      seed();
      when(() => repository.fxRoomAt(48000, 32)).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editBuffer(32)
        ..applyDraft();

      expect(cubit.state.refusal, const ApplyRefusal.overBudgetBuffer(32));
      expect(cubit.state.bufferFrames, 128);
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a higher rate that fits with a buffer that does not names the '
        'buffer (D19, #1529)', () {
      seed();
      when(() => repository.fxRoomAt(96000, 32)).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editRate(96000)
        ..editBuffer(32)
        ..applyDraft();

      expect(cubit.state.refusal, const ApplyRefusal.overBudgetBuffer(32));
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    test('a change that does not lower the room is never refused (D19)', () {
      seed();
      // Already over budget at 48 kHz / 128 (an effects removal is never
      // refused either): a lower rate and a bigger buffer leave as much room
      // or more, so neither is refused.
      when(() => repository.fxRoomAt(any(), any())).thenReturn(-1);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editRate(44100)
        ..applyDraft()
        ..editBuffer(512)
        ..applyDraft();

      expect(cubit.state.refusal, isNull);
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

      cubit
        ..editRate(96000)
        ..applyDraft();

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
      cubit
        ..editRate(96000)
        ..applyDraft();
      expect(cubit.state.refusal, isNotNull);

      cubit
        ..editBuffer(256)
        ..applyDraft();

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
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
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
        ..editDevice(playbackDeviceId: 'b', captureDeviceId: 'b')
        ..applyDraft();
      addTearDown(cubit.close);

      expect(
        cubit.state.refusal,
        const ApplyRefusal.deviceRefused('Other Interface'),
      );
      expect(cubit.state.phase, ConfigPhase.settled);
      expect(cubit.state.playbackDeviceId, isEmpty);
    });

    test('a refused loop cap says the settings were refused, not the '
        'interface', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.device,
        ),
      );
      final cubit = buildCubit()
        ..editMaxLoop(5)
        ..applyDraft();
      addTearDown(cubit.close);

      expect(cubit.state.refusal, const ApplyRefusal.settingsRefused());
      expect(cubit.state.maxLoopMinutes, 0);
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
        ..editDevice(playbackDeviceId: 'b', captureDeviceId: 'b')
        ..applyDraft();
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
        ..editDevice(playbackDeviceId: 'b', captureDeviceId: 'b')
        ..applyDraft();
      addTearDown(cubit.close);
      expect(cubit.state.status, AudioSetupStatus.error);

      // Nothing runs, so tapping what is shown is the retry.
      cubit
        ..editBuffer(128)
        ..applyDraft();

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
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
      addTearDown(cubit.close);

      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      expect(asked.maxLoopFrames, 14399999);
    });

    test('a rate change with the tracks empty recomputes the loop cap', () {
      seed();
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          maxLoopFrames: 14400000,
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);
      expect(cubit.state.maxLoopMinutes, 5);

      cubit
        ..editRate(96000)
        ..applyDraft();

      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      // Five minutes at 96 kHz, not the 48 kHz frame count.
      expect(asked.maxLoopFrames, 5 * 60 * 96000);
    });

    test('the open loop cap is kept even when the device runs another rate '
        'than was asked', () {
      seed();
      // Asked 96 kHz, running 48: the cap was opened at 96 kHz frames.
      when(() => repository.lastEngineConfig).thenReturn(
        const EngineConfig(
          sampleRate: 96000,
          bufferFrames: 128,
          maxLoopFrames: 28800000,
        ),
      );
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
      addTearDown(cubit.close);

      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      expect(asked.maxLoopFrames, 28800000);
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

      cubit
        ..editDevice(playbackDeviceId: 'b', captureDeviceId: 'b')
        ..applyDraft();

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

      cubit
        ..editBuffer(256)
        ..applyDraft();

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
      expect(cubit.state.status, AudioSetupStatus.running);
    });

    test('a setting change uses the selected max loop length '
        '(minutes -> frames)', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editMaxLoop(5)
        ..applyDraft();

      // 5 min * 60 s * 48000 Hz = 14_400_000 frames.
      verify(
        () => repository.applyAudioConfig(
          const EngineConfig(
            sampleRate: 48000,
            bufferFrames: 32,
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

      cubit
        ..editBuffer(64)
        ..applyDraft();

      expect(cubit.state.status, AudioSetupStatus.error);
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.errorDetail, EngineResult.device.name);
      expect(cubit.state.bufferFrames, 32);
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
        ..editBuffer(64)
        ..applyDraft()
        ..editBuffer(256)
        ..applyDraft();

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

  group('the owed record offset (#1541)', () {
    late _CountingStore counting;
    late LooperState live;
    late Completer<LatencyResult> measurement;

    LooperState scarlett({
      int buffer = 32,
      bool owed = true,
      int loopback = 1 << 4,
      int offset = 0,
    }) => LooperState(
      status: EngineStatus(
        deviceName: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: buffer,
        isConnected: true,
        devicePresent: true,
        excludedInputMask: loopback,
        recordOffsetFrames: offset,
        recordOffsetOwed: owed,
      ),
    );

    setUp(() {
      counting = _CountingStore();
      settings = SettingsRepository(store: counting);
      live = const LooperState();
      measurement = Completer<LatencyResult>();
      when(() => repository.state).thenAnswer((_) => live);
      // Setting the offset settles the owed one, as the repository does.
      when(() => repository.setRecordOffset(any())).thenAnswer((invocation) {
        final frames = invocation.positionalArguments.single as int;
        live = LooperState(
          status: EngineStatus(
            deviceName: live.status.deviceName,
            sampleRate: live.status.sampleRate,
            bufferFrames: live.status.bufferFrames,
            isConnected: true,
            devicePresent: true,
            excludedInputMask: live.status.excludedInputMask,
            recordOffsetFrames: frames,
          ),
        );
        stateController.add(live);
        return EngineResult.ok;
      });
      when(() => repository.measureLoopbackLatency())
          .thenAnswer((_) => measurement.future);
    });

    Future<AudioSetupCubit> owe(LooperState next) async {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      live = next;
      stateController.add(next);
      await pumpEventQueue();
      return cubit;
    }

    Future<int?> saved({int buffer = 32}) => settings.loadLatencyOffsetFrames(
      device: 'Scarlett 4i4',
      sampleRate: 48000,
      bufferFrames: buffer,
    );

    test('a saved offset is set, and nothing is measured', () async {
      // A cable result, say: it is never measured over.
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 32,
        frames: 320,
      );
      counting.intWrites = 0;

      await owe(scarlett());

      verify(() => repository.setRecordOffset(320)).called(1);
      verifyNever(() => repository.measureLoopbackLatency());
      expect(counting.intWrites, 0);
    });

    test(
      'none saved, with a loopback: measured twice, saved, then set',
      () async {
        final cubit = await owe(scarlett());

        verify(() => repository.measureLoopbackLatency()).called(1);
        expect(cubit.state.loopbackMeasure, LoopbackMeasure.measuring);
        // Silent and closed until the offset is set.
        verifyNever(() => repository.setRecordOffset(any()));
        // The cable test waits for it.
        cubit.openCableTest();
        expect(cubit.state.measurePhase, MeasurePhase.idle);
        expect(cubit.state.refusal, const ApplyRefusal.busy('calibration'));

        measurement.complete(
          const LatencyResult.done(offsetFrames: 292, latencyMs: 6.08),
        );
        await pumpEventQueue();

        // The second run, which agrees.
        verify(() => repository.measureLoopbackLatency()).called(1);
        expect(await saved(), 292);
        verify(() => repository.setRecordOffset(292)).called(1);
        expect(cubit.state.loopbackMeasure, LoopbackMeasure.idle);
      },
    );

    test(
      'a profile measured once is not measured again, nor saved twice',
      () async {
        await owe(scarlett());
        measurement.complete(
          const LatencyResult.done(offsetFrames: 292, latencyMs: 6.08),
        );
        await pumpEventQueue();
        expect(counting.intWrites, 1);

        // The next start owes the same profile again.
        live = scarlett();
        stateController.add(live);
        await pumpEventQueue();

        verify(() => repository.measureLoopbackLatency()).called(2);
        verify(() => repository.setRecordOffset(292)).called(2);
        expect(counting.intWrites, 1);
      },
    );

    for (final outcome in [
      const LatencyResult(LatencyOutcome.noReturn),
      const LatencyResult(LatencyOutcome.timedOut),
      const LatencyResult(LatencyOutcome.cancelled),
      const LatencyResult.refused(EngineResult.invalid),
    ]) {
      test('a measurement that ends ${outcome.outcome.name} leaves 0, saves '
          'nothing and says so', () async {
        final cubit = await owe(scarlett());

        measurement.complete(outcome);
        await pumpEventQueue();

        verify(() => repository.setRecordOffset(0)).called(1);
        expect(await saved(), isNull);
        expect(counting.intWrites, 0);
        expect(cubit.state.loopbackMeasure, LoopbackMeasure.failed);
        // A tick from before the offset was set does not measure again.
        stateController.add(scarlett());
        await pumpEventQueue();
        verify(() => repository.measureLoopbackLatency()).called(1);
      });
    }

    test('two runs that disagree save nothing and say so', () async {
      final runs = [
        const LatencyResult.done(offsetFrames: 292, latencyMs: 6.08),
        const LatencyResult.done(offsetFrames: 324, latencyMs: 6.75),
      ];
      when(() => repository.measureLoopbackLatency())
          .thenAnswer((_) async => runs.removeAt(0));

      final cubit = await owe(scarlett());

      expect(await saved(), isNull);
      verify(() => repository.setRecordOffset(0)).called(1);
      expect(cubit.state.loopbackMeasure, LoopbackMeasure.failed);
    });

    test('an owed offset with no device name to key it is 0', () async {
      await owe(
        const LooperState(
          status: EngineStatus(
            sampleRate: 48000,
            bufferFrames: 32,
            isConnected: true,
            devicePresent: true,
            excludedInputMask: 1 << 4,
            recordOffsetOwed: true,
          ),
        ),
      );

      verifyNever(() => repository.measureLoopbackLatency());
      verify(() => repository.setRecordOffset(0)).called(1);
    });

    test(
      'an open owed again while a settle runs is settled after it',
      () async {
        // A plain open of an unmeasured profile is settling (its saved offset
        // is being read) when an apply owes the same profile: that tick is
        // skipped, so the end of the settle picks it up from the repository.
        final cubit = buildCubit();
        addTearDown(cubit.close);
        live = scarlett(owed: false);
        stateController.add(live);
        live = scarlett();
        stateController.add(live);
        await pumpEventQueue();
        measurement.complete(
          const LatencyResult.done(offsetFrames: 292, latencyMs: 6.08),
        );
        await pumpEventQueue();

        expect(await saved(), 292);
        expect(live.status.recordOffsetOwed, isFalse);
        expect(live.status.recordOffsetFrames, 292);
      },
    );

    test('the device leaving mid-measurement is no failure: the next owed '
        'offset measures again', () async {
      final cubit = await owe(scarlett());

      live = const LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett 4i4',
          sampleRate: 48000,
          bufferFrames: 32,
          isConnected: true,
          excludedInputMask: 1 << 4,
          recordOffsetOwed: true,
        ),
      );
      measurement.complete(const LatencyResult(LatencyOutcome.cancelled));
      await pumpEventQueue();

      verifyNever(() => repository.setRecordOffset(any()));
      expect(cubit.state.loopbackMeasure, LoopbackMeasure.idle);

      // It came back and owes the same profile again.
      measurement = Completer<LatencyResult>();
      live = scarlett();
      stateController.add(live);
      await pumpEventQueue();
      measurement.complete(
        const LatencyResult.done(offsetFrames: 292, latencyMs: 6.08),
      );
      await pumpEventQueue();

      expect(await saved(), 292);
      verify(() => repository.setRecordOffset(292)).called(1);
    });

    test('a guard someone else holds does not stop it', () async {
      final held = guards.enter(
        GuardKind.sessionApply,
        const GuardScope.internal(),
        purpose: 'boot session',
      );
      addTearDown(held.release);

      await owe(scarlett());

      verify(() => repository.measureLoopbackLatency()).called(1);
    });

    test('an interface with no loopback is set to 0, unmeasured', () async {
      final cubit = await owe(scarlett(loopback: 0));

      verifyNever(() => repository.measureLoopbackLatency());
      verify(() => repository.setRecordOffset(0)).called(1);
      expect(cubit.state.loopbackMeasure, LoopbackMeasure.idle);
    });

    test('a profile that nothing owes is never measured', () async {
      await owe(scarlett(owed: false, offset: 50));

      verifyNever(() => repository.measureLoopbackLatency());
      verify(() => repository.setRecordOffset(0)).called(1);
    });

    test('a device that reopened at another buffer while measuring: nothing '
        'saved, and the new profile is settled', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 64,
        frames: 330,
      );
      final cubit = await owe(scarlett());

      live = scarlett(buffer: 64);
      stateController.add(live);
      await pumpEventQueue();
      measurement.complete(const LatencyResult(LatencyOutcome.cancelled));
      await pumpEventQueue();

      expect(await saved(), isNull);
      verifyNever(() => repository.setRecordOffset(0));
      verify(() => repository.setRecordOffset(330)).called(1);
      expect(cubit.state.loopbackMeasure, LoopbackMeasure.idle);
    });

    test('a cable result clears the failure', () async {
      final cubit = await owe(scarlett());
      measurement.complete(const LatencyResult(LatencyOutcome.noReturn));
      await pumpEventQueue();
      expect(cubit.state.loopbackMeasure, LoopbackMeasure.failed);
      when(
        () => repository.measureLatency(
          output: any(named: 'output'),
          input: any(named: 'input'),
        ),
      ).thenAnswer(
        (_) async =>
            const LatencyResult.done(offsetFrames: 320, latencyMs: 6.67),
      );

      cubit
        ..openCableTest()
        ..startCableTest(1, 1);
      await pumpEventQueue();

      expect(cubit.state.loopbackMeasure, LoopbackMeasure.idle);
      expect(await saved(), 320);
    });

    test('closing mid-measurement cancels it', () async {
      when(() => repository.cancelLatency()).thenReturn(null);
      final cubit = await owe(scarlett());

      await cubit.close();

      verify(() => repository.cancelLatency()).called(1);
    });
  });

  group('the audio warm-up (#1533)', () {
    const target = EngineConfig(
      sampleRate: 48000,
      bufferFrames: 32,
      playbackDeviceId: 'scarlett',
    );

    LooperState looper({required bool warmingUp, int? buffer}) => LooperState(
      status: EngineStatus(
        deviceName: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: buffer ?? (warmingUp ? kWarmUpBufferFrames : 32),
        isConnected: true,
        devicePresent: true,
        warmingUp: warmingUp,
      ),
    );

    setUp(() {
      when(() => repository.lastEngineConfig).thenReturn(target);
      when(() => repository.state).thenReturn(looper(warmingUp: true));
    });

    test("hydrates the player's buffer, not the warm-up's", () {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      expect(cubit.state.sampleRate, 48000);
      expect(cubit.state.bufferFrames, 32);
      expect(cubit.state.playbackDeviceId, 'scarlett');
    });

    test('sets no record offset while warming up', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
        frames: 900,
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(looper(warmingUp: true));
      await pumpEventQueue();

      verifyNever(() => repository.setRecordOffset(any()));
    });

    test("an end that opened the player's config shows no banner", () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(looper(warmingUp: false));
      await pumpEventQueue();

      expect(cubit.state.phase, ConfigPhase.settled);
    });

    test('an end that left the warm-up config running says what was asked '
        'and what runs', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      when(() => repository.lastEngineConfig).thenReturn(target.warmUp);
      stateController.add(
        looper(warmingUp: false, buffer: kWarmUpBufferFrames),
      );
      await pumpEventQueue();

      expect(cubit.state.phase, ConfigPhase.refused);
      expect(cubit.state.requestedRate, 48000);
      expect(cubit.state.requestedBuffer, 32);
      expect(cubit.state.actualRate, 48000);
      expect(cubit.state.actualBuffer, kWarmUpBufferFrames);
      // The chips show what runs, so choosing 32 again is an Apply that
      // retries it; nothing is saved.
      expect(cubit.state.bufferFrames, kWarmUpBufferFrames);
      expect(await settings.loadAudioConfig(), isNull);
    });

    test('a period the device rounded is not a refusal', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(looper(warmingUp: false, buffer: 48));
      await pumpEventQueue();

      expect(cubit.state.phase, ConfigPhase.settled);
    });

    test('a switch that dropped a track is told', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 32,
            isConnected: true,
            devicePresent: true,
            reopen: EngineReopened(
              outcome: ReopenOutcome.retainedPartial,
              droppedTracks: 1 << 2,
              previousSampleRate: 48000,
              sampleRate: 48000,
            ),
          ),
        ),
      );
      await pumpEventQueue();

      expect(
        cubit.state.deviceConnectivity,
        DeviceConnectivity.restoredPartial,
      );
      expect(cubit.state.phase, ConfigPhase.settled);
    });

    test("the player's own apply ends the warm-up without a refusal "
        'banner', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      when(() => repository.applyAudioConfig(any())).thenAnswer((_) {
        when(() => repository.state)
            .thenReturn(looper(warmingUp: false, buffer: 64));
        return _applied;
      });

      cubit
        ..editBuffer(64)
        ..applyDraft();
      await pumpEventQueue();
      stateController.add(looper(warmingUp: false, buffer: 64));
      await pumpEventQueue();

      expect(cubit.state.phase, ConfigPhase.settled);
      expect(cubit.state.bufferFrames, 64);
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

    test('a drafted playback device applies and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editDevice(
          playbackDeviceId: 'out-1',
          captureDeviceId: cubit.state.captureDeviceId,
        )
        ..applyDraft();
      expect(cubit.state.playbackDeviceId, 'out-1');
      await Future<void>.delayed(Duration.zero);
      expect((await settings.loadAudioConfig())?.playbackDeviceId, 'out-1');
    });

    test('a drafted capture device applies and persists', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editDevice(
          playbackDeviceId: cubit.state.playbackDeviceId,
          captureDeviceId: 'in-1',
        )
        ..applyDraft();
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

      cubit
        ..editDevice(
          playbackDeviceId: 'out-1',
          captureDeviceId: cubit.state.captureDeviceId,
        )
        ..applyDraft();

      // Reopened through the material-keeping apply, never stop and start.
      verifyNever(repository.stopEngine);
      verifyNever(() => repository.startEngine(any()));
      final captured =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
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
      cubit
        ..editDevice(
          playbackDeviceId: 'out-1',
          captureDeviceId: cubit.state.captureDeviceId,
        )
        ..applyDraft();

      expect(cubit.state.status, AudioSetupStatus.error);
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.errorDetail, isNotNull);
    });
  });

  group('waiting for the interface at boot (#1270 Part 5)', () {
    test('the wait takes the strip only while nothing else holds it', () {
      final cubit = buildCubit()..setWaitingForDevice(waiting: true);
      addTearDown(cubit.close);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.waiting);

      cubit.setWaitingForDevice(waiting: false);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test('a failed apply during the wait gives the strip back to it', () {
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.failed,
          result: EngineResult.device,
        ),
      );
      final cubit = buildCubit()..setWaitingForDevice(waiting: true);
      addTearDown(cubit.close);

      cubit
        ..editBuffer(256)
        ..applyDraft();

      expect(cubit.state.error, AudioSetupError.openDeviceFailed);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.waiting);
    });

    test('the awaited interface coming up ends the wait without a '
        'reconnected notice', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
      final cubit = buildCubit()..setWaitingForDevice(waiting: true);
      addTearDown(cubit.close);

      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            isConnected: true,
            devicePresent: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test('neither config opening leaves the previous one supervised: the '
        'stage says lost, and the return clears it (D17)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
      final cubit = buildCubit();
      addTearDown(cubit.close);
      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            isConnected: true,
            devicePresent: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.waiting,
          result: EngineResult.device,
        ),
      );

      cubit
        ..editDevice(playbackDeviceId: 'b', captureDeviceId: 'b')
        ..applyDraft();

      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
      expect(cubit.state.connectivityDeviceName, 'Scarlett');
      expect(cubit.state.error, AudioSetupError.openDeviceFailed);

      // The supervisor reopens the previous config when it answers.
      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            isConnected: true,
            devicePresent: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.restored);
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

    test('a return that kept every loop is the plain restored event, even with '
        'a retained verdict on the status (#1140)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
    });

    test('a lost interface is named as the host lists it, not by the '
        "engine's generic ALSA name (#1562)", () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett 4i4 USB',
          isDefault: false,
          isInput: false,
        ),
      ]);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      stateController.add(
        present(devicePresent: true, name: 'Playback Device'),
      );
      await Future<void>.delayed(Duration.zero);
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.lost);
      expect(cubit.state.connectivityDeviceName, 'Scarlett 4i4 USB');
    });

    test('a switch to another interface is named after the new one '
        '(#1562)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
      when(repository.devices).thenReturn(const [
        AudioDevice(id: 'out-1', name: 'A', isDefault: false, isInput: false),
        AudioDevice(id: 'out-2', name: 'B', isDefault: false, isInput: false),
      ]);
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Playback Device',
            isConnected: true,
            devicePresent: true,
            reopen: partial,
          ),
        ),
      );
      when(() => repository.applyAudioConfig(any())).thenReturn(_applied);
      final cubit = buildCubit();
      addTearDown(cubit.close);
      cubit
        ..editDevice(playbackDeviceId: 'out-2', captureDeviceId: '')
        ..applyDraft();
      expect(cubit.state.connectivityDeviceName, 'B');
    });

    test('an interface plugged in after boot is named from a fresh catalog '
        '(#1562)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
      final cubit = buildCubit();
      addTearDown(cubit.close);
      // Booted without it: the catalog the cubit holds has no entry.
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      when(repository.devices).thenReturn(const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett 4i4 USB',
          isDefault: false,
          isInput: false,
        ),
      ]);
      stateController.add(
        present(devicePresent: true, name: 'Playback Device'),
      );
      await Future<void>.delayed(Duration.zero);
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.connectivityDeviceName, 'Scarlett 4i4 USB');
    });

    test(
      'a return that dropped some tracks is the partial variant — one notice, '
      'not restored plus another (#1140)',
      () async {
        when(() => repository.lastEngineConfig)
            .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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

    test('a return at another rate is the standing cleared notice, until the '
        'user acts on it (#1140)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
    });

    test('a later return without a verdict is the plain restored event, even '
        'after an earlier partial reconnect (#1167)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
    });

    test('a re-apply that opens the rig after a rolled-back reopen raises the '
        'carried verdict instead of nothing (#1167)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
      cubit
        ..editRate(96000)
        ..applyDraft();
      verify(() => repository.applyAudioConfig(any())).called(1);
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(
        cubit.state.deviceConnectivity,
        DeviceConnectivity.restoredCleared,
      );
      expect(cubit.state.connectivityDeviceName, 'Scarlett');
    });

    test('an ordinary re-apply raises no notice', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
      cubit
        ..editRate(96000)
        ..applyDraft();
      verify(() => repository.applyAudioConfig(any())).called(1);
      expect(cubit.state.status, AudioSetupStatus.running);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test('dismissing the notice touches nothing else', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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

    test('resolving a lost device by picking the system default clears the '
        'standing condition for good (#453)', () async {
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
      cubit
        ..editDevice(
          playbackDeviceId: '',
          captureDeviceId: cubit.state.captureDeviceId,
        )
        ..applyDraft();
      expect(cubit.state.playbackDeviceId, isEmpty);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);

      // Un-pinned ticks with the old interface still absent stay quiet.
      stateController.add(present(devicePresent: false, name: ''));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.deviceConnectivity, DeviceConnectivity.none);
    });

    test(
      "the app's own reopen being refused does not read as an unplug (#453)",
      () async {
        when(() => repository.lastEngineConfig)
            .thenReturn(const EngineConfig(playbackDeviceId: 'out-1'));
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
        cubit
          ..editRate(96000)
          ..applyDraft();
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

  group('cable test (#1270 Part 3b)', () {
    const playing = Track(state: TrackState.playing, lengthFrames: 48000);

    void seed({
      List<Track> tracks = const [],
      bool countingIn = false,
      bool present = true,
    }) {
      when(() => repository.state).thenReturn(
        LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 128,
            inputChannels: 4,
            outputChannels: 4,
            isConnected: present,
            devicePresent: present,
          ),
          tracks: tracks,
          transport: TransportState(countingIn: countingIn),
        ),
      );
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(sampleRate: 48000, bufferFrames: 128));
    }

    Completer<LatencyResult> measuring() {
      final result = Completer<LatencyResult>();
      when(
        () => repository.measureLatency(
          output: any(named: 'output'),
          input: any(named: 'input'),
        ),
      ).thenAnswer((_) => result.future);
      when(repository.cancelLatency).thenReturn(null);
      return result;
    }

    test('Measure opens the dialog on the jacks the interface has', () {
      seed();
      final cubit = buildCubit()..openCableTest();
      addTearDown(cubit.close);
      expect(cubit.state.measurePhase, MeasurePhase.cable);
      cubit.chooseCableJacks(output: 9, input: 3);
      expect(cubit.state.measureOutput, 4);
      expect(cubit.state.measureInput, 3);
    });

    test('nothing opens while the interface is not there', () {
      seed(present: false);
      final cubit = buildCubit()..openCableTest();
      addTearDown(cubit.close);
      expect(cubit.state.measurePhase, MeasurePhase.idle);
    });

    for (final (name, tracks, countingIn) in [
      ('recording', const [Track(state: TrackState.recording)], false),
      (
        'overdubbing',
        const [Track(state: TrackState.overdubbing, lengthFrames: 48000)],
        false,
      ),
      ('counting in', const <Track>[], true),
    ]) {
      test('a take $name refuses the test and measures nothing', () {
        seed(tracks: tracks, countingIn: countingIn);
        measuring();
        final cubit = buildCubit()..openCableTest();
        addTearDown(cubit.close);
        expect(cubit.state.measurePhase, MeasurePhase.idle);
        expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
        cubit.startCableTest(3, 2);
        expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
        verifyNever(
          () => repository.measureLatency(
            output: any(named: 'output'),
            input: any(named: 'input'),
          ),
        );
      });
    }

    test('Start test measures the chosen jacks, and its DONE saves the offset '
        'under the device, rate and buffer', () async {
      seed();
      final result = measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(3, 2);
      addTearDown(cubit.close);

      verify(() => repository.measureLatency(output: 2, input: 1)).called(1);
      expect(cubit.state.measurePhase, MeasurePhase.running);
      result.complete(
        const LatencyResult.done(offsetFrames: 240, latencyMs: 5),
      );
      await pumpEventQueue();

      expect(cubit.state.measurePhase, MeasurePhase.done);
      expect(
        await settings.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
        ),
        240,
      );
      expect(guards.active, isEmpty);
    });

    test('Start test stops the tracks and the backing before it measures', () {
      seed(tracks: const [playing]);
      when(() => backing.state).thenReturn(
        const BackingPlayerState(transport: BackingTransport.playing),
      );
      measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1);
      addTearDown(cubit.close);

      verifyInOrder([
        () => repository.stopTrack(),
        backing.stop,
        () => repository.measureLatency(output: 0, input: 0),
      ]);
    });

    test('an Apply during the run is refused for the calibration, and the '
        'guard goes with the run', () async {
      seed();
      final result = measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1)
        ..editBuffer(256)
        ..applyDraft();
      addTearDown(cubit.close);

      expect(cubit.state.refusal, const ApplyRefusal.busy('calibration'));
      verifyNever(() => repository.applyAudioConfig(any()));
      result.complete(const LatencyResult(LatencyOutcome.noReturn));
      await pumpEventQueue();
      expect(guards.active, isEmpty);
      cubit
        ..editBuffer(256)
        ..applyDraft();
      verify(() => repository.applyAudioConfig(any())).called(1);
    });

    test('no return keeps the dialog and the saved offset', () async {
      seed();
      final result = measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1);
      addTearDown(cubit.close);
      result.complete(const LatencyResult(LatencyOutcome.timedOut));
      await pumpEventQueue();
      expect(cubit.state.measurePhase, MeasurePhase.noReturn);
      expect(
        await settings.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
        ),
        isNull,
      );
    });

    test('Cancel posts the cancel and keeps the saved offset; a late answer '
        'changes nothing', () async {
      seed();
      final result = measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1)
        ..cancelMeasure();
      addTearDown(cubit.close);
      verify(repository.cancelLatency).called(1);
      expect(cubit.state.measurePhase, MeasurePhase.idle);
      result.complete(const LatencyResult(LatencyOutcome.cancelled));
      await pumpEventQueue();
      expect(cubit.state.measurePhase, MeasurePhase.idle);
      expect(guards.active, isEmpty);
    });

    test('Measure during a run changes nothing', () {
      seed();
      measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1)
        ..openCableTest();
      addTearDown(cubit.close);
      expect(cubit.state.measurePhase, MeasurePhase.running);
    });

    test('closing the dialog takes a refusal shown in it along', () {
      seed();
      measuring();
      final cubit = buildCubit()..openCableTest();
      addTearDown(cubit.close);
      guards.enter(
        GuardKind.deviceChange,
        const GuardScope.internal(),
        purpose: 'test',
      );
      cubit.startCableTest(1, 1);
      expect(cubit.state.refusal, const ApplyRefusal.busy('deviceChange'));
      cubit.cancelMeasure();
      expect(cubit.state.refusal, isNull);
    });

    test('closing the cubit mid-run cancels the measurement', () async {
      seed();
      measuring();
      final cubit = buildCubit()
        ..openCableTest()
        ..startCableTest(1, 1);
      await cubit.close();
      verify(repository.cancelLatency).called(1);
      expect(guards.active, isEmpty);
    });

    test('a device change that would clear the loops names the rate it '
        'would have run, and saves nothing', () async {
      seed(tracks: const [playing]);
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.wouldClear,
          refusedRate: 44100,
        ),
      );
      final cubit = buildCubit();
      addTearDown(cubit.close);

      cubit
        ..editDevice(playbackDeviceId: 'other', captureDeviceId: 'other')
        ..applyDraft()
        ..confirmApply();

      expect(cubit.state.phase, ConfigPhase.refused);
      expect(cubit.state.requestedRate, 44100);
      expect(cubit.state.actualRate, 48000);
      expect(cubit.state.playbackDeviceId, isNot('other'));
      await pumpEventQueue();
      expect(await settings.loadAudioConfig(), isNull);
    });
  });

  group('the draft (#1270 Part 4)', () {
    void seed({List<Track> tracks = const []}) {
      when(() => repository.state).thenReturn(
        LooperState(
          status: const EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 128,
            isConnected: true,
            devicePresent: true,
          ),
          tracks: tracks,
        ),
      );
      when(() => repository.lastEngineConfig)
          .thenReturn(const EngineConfig(sampleRate: 48000, bufferFrames: 128));
    }

    test('editing calls nothing, and Cancel shows what runs again', () {
      seed();
      final cubit = buildCubit()..editBuffer(256);
      addTearDown(cubit.close);
      expect(cubit.state.shown.bufferFrames, 256);
      expect(cubit.state.bufferFrames, 128);
      verifyNever(() => repository.applyAudioConfig(any()));
      cubit.discardDraft();
      expect(cubit.state.draft, isNull);
      expect(cubit.state.shown.bufferFrames, 128);
    });

    test('editing back to what runs leaves no draft', () {
      seed();
      final cubit = buildCubit()
        ..editBuffer(256)
        ..editBuffer(128);
      addTearDown(cubit.close);
      expect(cubit.state.draft, isNull);
    });

    test('rate and buffer drafted together apply once with both', () {
      seed();
      final cubit = buildCubit()
        ..editRate(96000)
        ..editBuffer(256)
        ..editMaxLoop(5)
        ..applyDraft();
      addTearDown(cubit.close);
      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      expect(asked.sampleRate, 96000);
      expect(asked.bufferFrames, 256);
      expect(asked.maxLoopFrames, 5 * 60 * 96000);
      expect(cubit.state.draft, isNull);
    });

    test('the rate and the loop cap are not drafted while loops hold '
        'material', () {
      seed(
        tracks: const [Track(state: TrackState.stopped, lengthFrames: 48000)],
      );
      final cubit = buildCubit()
        ..editRate(96000)
        ..editMaxLoop(5);
      addTearDown(cubit.close);
      expect(cubit.state.draft, isNull);
    });

    test('Measure does not open while a draft is pending', () {
      seed();
      final cubit = buildCubit()
        ..editBuffer(256)
        ..openCableTest();
      addTearDown(cubit.close);
      expect(cubit.state.measurePhase, MeasurePhase.idle);
    });

    test('material landing under a rate draft puts the rate back', () async {
      seed();
      final cubit = buildCubit()
        ..editRate(96000)
        ..editBuffer(256);
      addTearDown(cubit.close);
      const recorded = Track(state: TrackState.stopped, lengthFrames: 48000);
      stateController.add(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 128,
            isConnected: true,
            devicePresent: true,
          ),
          tracks: [recorded],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.draft?.sampleRate, 48000);
      expect(cubit.state.draft?.bufferFrames, 256);
    });

    test('a take landing while the question is open is answered with the '
        'draft as it stands', () async {
      const playing = Track(state: TrackState.playing, lengthFrames: 48000);
      seed(tracks: const [playing]);
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 128,
            isConnected: true,
            devicePresent: true,
          ),
        ),
      );
      final cubit = buildCubit()
        ..editRate(96000)
        ..editBuffer(256);
      addTearDown(cubit.close);
      when(() => backing.state).thenReturn(
        const BackingPlayerState(transport: BackingTransport.playing),
      );
      cubit.applyDraft();
      expect(cubit.state.applyPhase, ApplyPhase.confirming);
      const recorded = LooperState(
        status: EngineStatus(
          deviceName: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
          devicePresent: true,
        ),
        tracks: [playing],
      );
      when(() => repository.state).thenReturn(recorded);
      stateController.add(recorded);
      await Future<void>.delayed(Duration.zero);
      cubit.confirmApply();
      final asked =
          verify(() => repository.applyAudioConfig(captureAny()))
                  .captured
                  .single
              as EngineConfig;
      expect(asked.sampleRate, 48000);
      expect(asked.bufferFrames, 256);
    });

    test('a repository that touches nothing keeps the draft', () {
      seed();
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.refused,
          result: EngineResult.notReady,
        ),
      );
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
      addTearDown(cubit.close);
      expect(cubit.state.refusal, const ApplyRefusal.busy('other'));
      expect(cubit.state.draft?.bufferFrames, 256);
    });

    test('a refused admission keeps the draft to retry', () {
      seed(tracks: const [Track(state: TrackState.recording)]);
      final cubit = buildCubit()
        ..editBuffer(256)
        ..applyDraft();
      addTearDown(cubit.close);
      expect(cubit.state.refusal, const ApplyRefusal.busy('capture'));
      expect(cubit.state.draft?.bufferFrames, 256);
    });
  });
}
