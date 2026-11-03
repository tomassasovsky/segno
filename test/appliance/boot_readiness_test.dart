import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/boot_readiness.dart';
import 'package:segno/logging/app_log.dart';

const _scarlett = [
  AudioDevice(
    id: 'scarlett',
    name: 'Scarlett 4i4',
    isDefault: false,
    isInput: false,
  ),
  AudioDevice(
    id: 'scarlett',
    name: 'Scarlett 4i4',
    isDefault: false,
    isInput: true,
  ),
];

const _hdmiOnly = [
  AudioDevice(id: 'hdmi', name: 'HDMI', isDefault: true, isInput: false),
];

const _pinned = EngineConfig(
  playbackDeviceId: 'scarlett',
  captureDeviceId: 'scarlett',
);

void main() {
  group('bootAudioOf', () {
    test('a running engine is ok, without enumerating', () {
      expect(
        bootAudioOf(
          running: true,
          config: _pinned,
          devices: () => fail('enumerated a running engine'),
        ),
        BootAudio.ok,
      );
    });

    test('the pinned interface unplugged is absent', () {
      expect(
        bootAudioOf(running: false, config: _pinned, devices: () => _hdmiOnly),
        BootAudio.absent,
      );
    });

    test('the pinned interface present and not running is refused', () {
      expect(
        bootAudioOf(running: false, config: _pinned, devices: () => _scarlett),
        BootAudio.refused,
      );
    });

    test('nothing pinned and no interface to pin is absent (first run)', () {
      for (final config in [null, const EngineConfig()]) {
        expect(
          bootAudioOf(
            running: false,
            config: config,
            devices: () => _hdmiOnly,
          ),
          BootAudio.absent,
        );
      }
    });

    test('nothing pinned and an interface there is refused', () {
      expect(
        bootAudioOf(running: false, config: null, devices: () => _scarlett),
        BootAudio.refused,
      );
    });

    test('an enumeration that fails is refused, never absent', () {
      expect(
        bootAudioOf(
          running: false,
          config: _pinned,
          devices: () => throw StateError('ffi'),
        ),
        BootAudio.refused,
      );
    });
  });

  group(BootReadiness, () {
    late List<String> sent;
    late Completer<void> firstFrame;
    late BootAudio audio;
    late int frames;
    late bool callbackRuns;
    late bool readoutConnected;
    late bool readoutAnswers;
    late int pings;
    late bool notifyWorks;

    // Built inside each test's fakeAsync zone: a future made outside it would
    // complete on the real microtask queue, which flushMicrotasks never runs.
    BootReadiness readiness() => BootReadiness(
      notify: (state) {
        sent.add(state);
        return notifyWorks;
      },
      firstFrame: (firstFrame = Completer<void>()).future,
      audio: () => audio,
      audioFrames: () => callbackRuns ? frames += 240000 : frames,
      readoutConnected: () async => readoutConnected,
      pingReadout: () async {
        pings++;
        return readoutAnswers;
      },
    );

    setUp(() {
      sent = [];
      audio = BootAudio.ok;
      frames = 0;
      callbackRuns = true;
      readoutConnected = true;
      readoutAnswers = true;
      pings = 0;
      notifyWorks = true;
    });

    test('says nothing before the main screen has drawn', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        async.elapse(const Duration(seconds: 30));
        expect(sent, isEmpty);
      });
    });

    test('READY=1 with the first status, at the first raster', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.flushMicrotasks();
        expect(sent, ['READY=1\nSTATUS=alive 0 readout 0 audio ok']);
        // Readiness pings nothing: the readout gets a beat to link first.
        expect(pings, 0);

        // Every later status carries READY=1 too: systemd ignores the
        // repeat, and a lost first datagram must not get the app killed.
        async.elapse(const Duration(seconds: 15));
        expect(sent, hasLength(4));
        expect(sent.every((s) => s.startsWith('READY=1\nSTATUS=')), isTrue);
      });
    });

    test('a second start sends nothing more', () {
      fakeAsync((async) {
        final r = readiness();
        unawaited(r.start());
        unawaited(r.start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        expect(sent, [
          'READY=1\nSTATUS=alive 0 readout 0 audio ok',
          'READY=1\nSTATUS=alive 1 readout 1 audio ok',
        ]);
      });
    });

    test('the heartbeat advances alive and counts readout answers', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 15));
        expect(sent.skip(1), [
          'READY=1\nSTATUS=alive 1 readout 1 audio ok',
          'READY=1\nSTATUS=alive 2 readout 2 audio ok',
          'READY=1\nSTATUS=alive 3 readout 3 audio ok',
        ]);
      });
    });

    test('a readout that does not answer stops its counter', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        readoutAnswers = false;
        async.elapse(const Duration(seconds: 10));
        expect(sent.last, 'READY=1\nSTATUS=alive 3 readout 1 audio ok');
      });
    });

    test('a disconnected readout reads none and is not pinged', () {
      fakeAsync((async) {
        readoutConnected = false;
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 10));
        expect(sent.last, 'READY=1\nSTATUS=alive 2 readout none audio ok');
        expect(pings, 0);
      });
    });

    test('a readout connector that cannot be read reads none', () {
      fakeAsync((async) {
        final r = BootReadiness(
          notify: (state) {
            sent.add(state);
            return true;
          },
          firstFrame: (firstFrame = Completer<void>()).future,
          audio: () => audio,
          audioFrames: () => frames++,
          readoutConnected: () async => throw StateError('sysfs'),
          pingReadout: () async => true,
        );
        unawaited(r.start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 1 readout none audio ok');
      });
    });

    test('the audio state is read on every beat', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        audio = BootAudio.refused;
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 1 readout 1 audio refused');
        audio = BootAudio.absent;
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 2 readout 2 audio absent');
      });
    });

    test('a callback that stops reads stalled within one beat', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        callbackRuns = false;
        async.elapse(const Duration(seconds: 5));
        expect(sent.skip(1), [
          'READY=1\nSTATUS=alive 1 readout 1 audio ok',
          'READY=1\nSTATUS=alive 2 readout 2 audio stalled',
        ]);
        // It stays stalled while the count stands, and is ok once it moves.
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 3 readout 3 audio stalled');
        callbackRuns = true;
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 4 readout 4 audio ok');
      });
    });

    test('a change of the audio state reaches the log', () async {
      final dir = await Directory.systemTemp.createTemp('segno-boot-log-');
      AppLog.close();
      await AppLog.init(directory: dir);
      addTearDown(() async {
        AppLog.close();
        await dir.delete(recursive: true);
      });
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        callbackRuns = false;
        async.elapse(const Duration(seconds: 10));
        callbackRuns = true;
        async.elapse(const Duration(seconds: 5));
      });
      final lines = File(
        '${dir.path}/${AppLog.fileName}',
      ).readAsLinesSync().where((l) => l.contains('boot health: audio'));
      // Once per change, not once per beat.
      expect(lines, hasLength(2));
      expect(lines.first, endsWith(' W boot health: audio ok -> stalled'));
      expect(lines.last, endsWith(' I boot health: audio stalled -> ok'));
    });

    test('a count that starts again after a restart is not a stall', () {
      fakeAsync((async) {
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        // Stopped and started again between two beats: the count is lower.
        frames = 1000;
        async.elapse(const Duration(seconds: 5));
        expect(sent.last, 'READY=1\nSTATUS=alive 2 readout 2 audio ok');
      });
    });

    test('a stopped engine resets the count the next start compares to', () {
      fakeAsync((async) {
        callbackRuns = false;
        unawaited(readiness().start());
        firstFrame.complete();
        audio = BootAudio.refused;
        async.elapse(const Duration(seconds: 5));
        audio = BootAudio.ok;
        async.elapse(const Duration(seconds: 10));
        expect(sent.skip(1), [
          'READY=1\nSTATUS=alive 1 readout 1 audio refused',
          // The first running status after a stop has nothing to compare to.
          'READY=1\nSTATUS=alive 2 readout 2 audio ok',
          'READY=1\nSTATUS=alive 3 readout 3 audio stalled',
        ]);
      });
    });

    test('a frame count that cannot be read reads refused', () {
      fakeAsync((async) {
        final r = BootReadiness(
          notify: (state) {
            sent.add(state);
            return true;
          },
          firstFrame: (firstFrame = Completer<void>()).future,
          audio: () => audio,
          audioFrames: () => throw StateError('ffi'),
          readoutConnected: () async => true,
          pingReadout: () async => true,
        );
        unawaited(r.start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 5));
        expect(sent, [
          'READY=1\nSTATUS=alive 0 readout 0 audio refused',
          'READY=1\nSTATUS=alive 1 readout 1 audio refused',
        ]);
      });
    });

    test('a failed send keeps the heartbeat going', () {
      fakeAsync((async) {
        notifyWorks = false;
        unawaited(readiness().start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 10));
        notifyWorks = true;
        async.elapse(const Duration(seconds: 5));
        expect(sent, hasLength(4));
        expect(sent.last, 'READY=1\nSTATUS=alive 3 readout 3 audio ok');
      });
    });

    test('a ping slower than the beat holds the next beat back', () {
      fakeAsync((async) {
        final r = BootReadiness(
          notify: (state) {
            sent.add(state);
            return true;
          },
          firstFrame: (firstFrame = Completer<void>()).future,
          audio: () => audio,
          audioFrames: () => frames++,
          readoutConnected: () async => true,
          pingReadout: () async {
            pings++;
            await Future<void>.delayed(const Duration(seconds: 7));
            return true;
          },
        );
        unawaited(r.start());
        firstFrame.complete();
        async.elapse(const Duration(seconds: 15));
        // Beats at 5 s (answered at 12 s) and 15 s; the one at 10 s found
        // the 5 s ping still out and sent nothing.
        expect(pings, 2);
        expect(sent.skip(1), ['READY=1\nSTATUS=alive 1 readout 1 audio ok']);
      });
    });

    test(
      'a status part that throws reads as unhealthy, not as a lost beat',
      () {
        fakeAsync((async) {
          final r = BootReadiness(
            notify: (state) {
              sent.add(state);
              return true;
            },
            firstFrame: (firstFrame = Completer<void>()).future,
            audio: () => throw StateError('ffi'),
            audioFrames: () => fail('read frames of an unreadable engine'),
            readoutConnected: () async => true,
            pingReadout: () async => throw StateError('link'),
          );
          unawaited(r.start());
          firstFrame.complete();
          async.elapse(const Duration(seconds: 5));
          expect(sent, [
            'READY=1\nSTATUS=alive 0 readout 0 audio refused',
            'READY=1\nSTATUS=alive 1 readout 0 audio refused',
          ]);
        });
      },
    );
  });
}
