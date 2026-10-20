import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

class _Engine extends FakeAudioEngine {
  bool corrupt = false;
  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    final result = super.setTrackLengthPresets(bars);
    if (corrupt) publishedLengths[0] = 63;
    return result;
  }
}

void main() {
  group('Length callback receipt', () {
    late _Engine engine;
    late LooperRepository repository;
    setUp(() {
      engine = _Engine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
    });
    tearDown(() => repository.dispose());
    Future<void> start() async {
      repository.setLengthSettings(
        defaultBars: 0,
        overrides: {},
        mode: LooperMode.free,
      );
      expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
      expect((await repository.settleLengthSettings()).isOk, isTrue);
    }

    test(
      'same numeric vector waits for callback before explicit Auto membership',
      () async {
        await start();
        engine.commandsAreSettled = false;
        expect(
          repository.setTrackLengthPreset(channel: 0, bars: 0).isOk,
          isTrue,
        );
        expect(repository.lengthSettingsSettled, isFalse);
        expect(repository.trackLengthPresetOverrides, isEmpty);
        engine.commandsAreSettled = true;
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(repository.trackLengthPresetOverrides, {0: 0});
      },
    );
    test('exact previous vector means refusal without stopping', () async {
      await start();
      engine.publishLengthCommands = false;
      repository.setTrackLengthPreset(channel: 0, bars: 8);
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      expect(repository.lengthRecoveryRequired, isFalse);
      expect(engine.calls.where((c) => c == 'stop'), isEmpty);
      expect(repository.trackLengthPresetOverrides, isEmpty);
    });
    test(
      'a partial vector is owed without a stop, and Retry lands it',
      () async {
        await start();
        engine.corrupt = true;
        repository.setTrackLengthPreset(channel: 0, bars: 8);
        expect(await repository.settleLengthSettings(), EngineResult.invalid);
        expect(repository.lengthRecoveryRequired, isTrue);
        expect(repository.lengthRestartIntent.trackOverrides, {0: 8});
        expect(engine.calls.where((c) => c == 'stop'), isEmpty);
        engine.corrupt = false;
        expect(repository.recoverLengthSettings().isOk, isTrue);
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(repository.lengthRecoveryRequired, isFalse);
        expect(repository.trackLengthPresetOverrides, {0: 8});
        expect(engine.publishedLengths[0], 8);
      },
    );
    test(
      'a globally withheld startup owes each replay and keeps audio running',
      () async {
        repository.setLengthSettings(
          defaultBars: 4,
          overrides: {7: 0},
          mode: LooperMode.free,
        );
        engine.commandsAreSettled = false;
        // The global callback fence is withheld for every family. Each
        // replay's deadline owes its own vector; none stops the device.
        final timing = repository.recordTimingFailures.first;
        final length = repository.lengthSettingsFailures.first;
        expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
        expect(
          await timing.timeout(const Duration(seconds: 2)),
          EngineResult.notReady,
        );
        expect(
          await length.timeout(const Duration(seconds: 2)),
          EngineResult.notReady,
        );
        expect(repository.recordTimingRecoveryRequired, isTrue);
        expect(repository.lengthRecoveryRequired, isTrue);
        expect(engine.calls.where((c) => c == 'stop'), isEmpty);
        engine.commandsAreSettled = true;
        expect(repository.recoverRecordTimingSettings().isOk, isTrue);
        expect(repository.recoverLengthSettings().isOk, isTrue);
        expect((await repository.settleRecordTimingSettings()).isOk, isTrue);
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(engine.publishedLengths, {
          for (var c = 0; c < 7; c++) c: 4,
          7: 0,
        });
      },
    );
    test(
      'autonomous Length deadline fires without a later owner call',
      () async {
        await start();
        engine.commandsAreSettled = false;
        final failure = repository.lengthSettingsFailures.first;
        expect(repository.setDefaultLengthPreset(4), EngineResult.ok);
        expect(
          await failure.timeout(const Duration(seconds: 2)),
          EngineResult.notReady,
        );
        expect(repository.lengthRecoveryRequired, isTrue);
        expect(engine.calls.where((c) => c == 'stop'), isEmpty);
        // A restart is not refused; it replays the owed vector.
        engine.commandsAreSettled = true;
        expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(repository.lengthRecoveryRequired, isFalse);
        expect(engine.publishedLengths, {for (var c = 0; c < 8; c++) c: 4});
      },
    );
    test(
      'short raw vector never confirms the fixed eight-slot owner',
      () async {
        await start();
        engine.nextSnapshot = engine.nextSnapshot.copyWith(
          tracks: [const TrackSnapshot.empty()],
        );
        repository.setDefaultLengthPreset(8);
        expect((await repository.settleLengthSettings()).isOk, isFalse);
        expect(repository.lengthRecoveryRequired, isTrue);
      },
    );
    TrackSnapshot recording() => const TrackSnapshot(
      state: TrackState.recording,
      volume: 1,
      muted: false,
      lengthFrames: 0,
      undoDepth: 0,
      rms: 0,
      peak: 0,
    );

    test(
      'a take that starts after the vector lands is accepted with no stop',
      () async {
        await start();
        engine.commandsAreSettled = false;
        expect(
          repository.setTrackLengthPreset(channel: 0, bars: 8).isOk,
          isTrue,
        );
        // The vector has landed; a take begins before the receipt is read.
        engine.nextSnapshot = engine.nextSnapshot.copyWith(
          looperMode: LooperMode.free,
          tracks: [recording(), ...engine.nextSnapshot.tracks.skip(1)],
        );
        engine.commandsAreSettled = true;
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(repository.lengthRecoveryRequired, isFalse);
        expect(repository.trackLengthPresetOverrides, {0: 8});
        expect(engine.calls.where((c) => c == 'stop'), isEmpty);
      },
    );

    test('one capture lock, and a stopped engine never holds it', () async {
      await start();
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: [recording(), ...engine.nextSnapshot.tracks.skip(1)],
      );
      expect(repository.captureLocked, isTrue);
      expect(repository.recordLengthCaptureLocked, isTrue);
      expect(repository.recordTimingCaptureLocked, isTrue);
      expect(repository.clickModeCaptureLocked, isTrue);
      expect(repository.recordStartCaptureLocked, isTrue);
      repository.stopEngine();
      // The last snapshot still shows the take; the engine is stopped.
      expect(engine.snapshot().tracks.first.state, TrackState.recording);
      expect(repository.captureLocked, isFalse);
      expect(repository.recordLengthCaptureLocked, isFalse);
      expect(repository.recordTimingCaptureLocked, isFalse);
      expect(repository.setDefaultLengthPreset(8), EngineResult.ok);
    });

    test(
      'receipt installs durable Released before immediate restart',
      () async {
        await start();
        repository.setTrackLengthPreset(channel: 0, bars: 16, releasedBars: 0);
        expect((await repository.settleLengthSettings()).isOk, isTrue);
        expect(repository.trackLengthPresetOverrides, {0: 16});
        expect(repository.lengthRestartIntent.trackOverrides, {0: 0});
        repository
          ..stopEngine()
          ..startEngine(const EngineConfig());
        await repository.settleLengthSettings();
        expect(repository.trackLengthPresetOverrides, {0: 0});
        expect(engine.publishedLengths[0], 0);
      },
    );
  });
}
