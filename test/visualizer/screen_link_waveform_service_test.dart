import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_screen.dart';
import 'package:segno/visualizer/screen_link.dart';
import 'package:segno/visualizer/screen_link_waveform_service.dart';

/// An in-memory [PortDirectory]: both ends run in the test isolate, so the
/// link is exercised over real ports without the VM-wide registry.
class _Directory implements PortDirectory {
  final ports = <String, SendPort>{};

  @override
  SendPort? lookup(String name) => ports[name];

  @override
  void publish(String name, SendPort port) => ports[name] = port;
}

/// Lets queued port messages (and their replies) be delivered.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Directory directory;
  late ScreenLinkWaveformService service;

  ReadoutScreenLink startReadout() {
    final link = ReadoutScreenLink(directory: directory)..start();
    addTearDown(link.dispose);
    return link;
  }

  setUp(() {
    directory = _Directory();
    service = ScreenLinkWaveformService(
      directory: directory,
      readyTimeout: const Duration(milliseconds: 200),
      ackTimeout: const Duration(milliseconds: 200),
    );
  });

  group('open', () {
    test('waits for a readout that starts after the main screen', () async {
      final opening = service.open();
      await settle();
      final readout = startReadout();

      expect(await opening, isTrue);
      await settle();
      expect(service.isOpen, isTrue);
      expect(readout.visible.value, isTrue);
    });

    test('finds a readout that started first, through the greeting', () async {
      final readout = startReadout();
      await settle();

      expect(await service.open(), isTrue);
      await settle();
      expect(readout.visible.value, isTrue);
    });

    test('reports failure when no readout ever announces itself', () async {
      expect(await service.open(), isFalse);
      expect(service.isOpen, isFalse);
    });

    test('a readout stays blank until the main screen opens it', () async {
      final readout = startReadout();
      await settle();
      expect(readout.visible.value, isFalse);
    });
  });

  test('a close while open is waiting keeps the readout blank', () async {
    final opening = service.open();
    await settle();
    await service.close();
    final readout = startReadout();

    expect(await opening, isTrue, reason: 'the readout is reachable');
    await settle();
    expect(service.isOpen, isFalse);
    expect(readout.visible.value, isFalse);
  });

  test('a newer open survives an older one timing out', () async {
    final first = service.open();
    await service.close();
    // The second open starts halfway through the first one's wait.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final second = service.open();
    expect(await first, isFalse);

    final readout = startReadout();
    expect(await second, isTrue);
    await settle();
    expect(service.isOpen, isTrue);
    expect(readout.visible.value, isTrue);
  });

  test('a readout announcing to a closed link is told to stay blank', () async {
    final readout = startReadout();
    readout.visible.value = true; // left showing by an earlier main screen

    await service.close();
    await settle();

    expect(readout.visible.value, isFalse);
  });

  test('the re-seed pushed on the first announcement lands', () async {
    final peaks = Float32List.fromList([0.2, 0.4]);
    final seeded = Completer<void>();
    // What App does: re-seed the readout the moment it announces itself.
    service.onWindowReady = () =>
        seeded.complete(service.pushWaveform(peaks, 0.5, 'Seed'));
    final opening = service.open();
    await settle();
    final readout = startReadout();

    expect(await opening, isTrue);
    await seeded.future;
    expect(readout.frame.value.samples, peaks);
    expect(readout.frame.value.selectedTrack, 'Seed');
  });

  test('hiding drops what the readout held', () async {
    final readout = startReadout();
    await service.open();
    await service.pushWaveform(Float32List.fromList([1]), 0.5, 'T');

    await service.close();
    await settle();
    expect(readout.frame.value.samples, isEmpty);
    expect(readout.frame.value.selectedTrack, isEmpty);

    // Reopened, the next frame carries the peaks again.
    await service.open();
    await service.pushWaveform(Float32List.fromList([1]), 0.6, 'T');
    expect(readout.frame.value.samples, [1.0]);
  });

  test('close blanks the readout and stops pushes', () async {
    final readout = startReadout();
    await service.open();
    await settle();

    await service.close();
    await settle();
    expect(readout.visible.value, isFalse);
    expect(service.isOpen, isFalse);

    await service.pushWaveform(Float32List.fromList([1]), 0.5, 'T1');
    await settle();
    expect(readout.frame.value.samples, isEmpty);
  });

  group('pushWaveform', () {
    test('delivers peaks once and holds them under later frames', () async {
      final readout = startReadout();
      await service.open();
      final peaks = Float32List.fromList([0.1, 0.5, 0.9]);

      await service.pushWaveform(peaks, 0.25, 'Track 1');
      expect(readout.frame.value.samples, peaks);
      expect(readout.frame.value.progress, 0.25);
      expect(readout.frame.value.selectedTrack, 'Track 1');

      // Same peaks: a progress-only frame, which must not blank the waveform.
      await service.pushWaveform(peaks, 0.75, 'Track 1');
      expect(readout.frame.value.samples, peaks);
      expect(readout.frame.value.progress, 0.75);
    });

    test('fails when the readout never acknowledges', () async {
      // A readout that announces itself and then ignores everything.
      final mute = ReceivePort();
      addTearDown(mute.close);
      directory.publish(screenLinkReadoutPort, mute.sendPort);
      final opening = service.open();
      await settle();
      directory.ports[screenLinkMainPort]!.send({
        'op': ScreenLinkOp.ready,
        'port': mute.sendPort,
      });
      expect(await opening, isTrue);

      await expectLater(
        service.pushWaveform(Float32List(1), 0, ''),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a readout that re-announces itself is re-seeded', () async {
      final readout = startReadout();
      var announcements = 0;
      service.onWindowReady = () => announcements++;
      await service.open();
      await settle();
      final peaks = Float32List.fromList([0.3, 0.6]);
      await service.pushWaveform(peaks, 0.1, 'T');

      // The readout restarts: a fresh link, holding nothing, publishes over the
      // old one and announces itself again.
      expect(readout.frame.value.samples, peaks);
      final restarted = startReadout();
      await settle();
      expect(announcements, 2);
      expect(restarted.visible.value, isTrue);

      // The same peaks are sent again, because the new readout has none.
      await service.pushWaveform(peaks, 0.2, 'T');
      expect(restarted.frame.value.samples, peaks);
    });
  });

  group('pushReadout', () {
    const readout = PerformanceReadout(
      selected: ReadoutTrack(channel: 1, name: 'Loop', state: 'playing'),
      tempoBpm: 96,
    );

    test('delivers a readout and skips an identical one', () async {
      final link = startReadout();
      await service.open();

      await service.pushReadout(readout);
      expect(link.readout.value, readout);

      link.readout.value = const PerformanceReadout();
      await service.pushReadout(readout);
      await settle();
      expect(link.readout.value, const PerformanceReadout());
    });
  });

  test('a touch on the readout reaches the main screen', () async {
    final link = startReadout();
    var touches = 0;
    service.onWindowActivity = () => touches++;
    await service.open();
    await settle();

    link.sendActivity();
    await settle();

    expect(touches, 1);
  });

  group('touch calibration', () {
    test('draws a target on the readout and brings its taps back', () async {
      final link = startReadout();
      final taps = <({double x, double y})>[];
      service.onCalibrationTap = taps.add;
      await service.open();
      await settle();

      expect(
        await service.showCalibrationTarget((
          x: 0.12,
          y: 0.16,
        ), label: '1 of 5'),
        isTrue,
      );
      await settle();
      expect(link.calibration.value, (
        target: (x: 0.12, y: 0.16),
        label: '1 of 5',
      ));

      link.sendCalibrationTap((x: 0.13, y: 0.15));
      await settle();
      expect(taps, [(x: 0.13, y: 0.15)]);

      expect(await service.showCalibrationTarget(null), isTrue);
      await settle();
      expect(link.calibration.value, isNull);
    });

    test('reports an unreachable readout', () async {
      expect(await service.showCalibrationTarget((x: 0.5, y: 0.5)), isFalse);
    });
  });

  group('overlapping pushes', () {
    late _ScriptedReadout readout;

    setUp(() async {
      readout = _ScriptedReadout(directory);
      addTearDown(readout.close);
      expect(await service.open(), isTrue);
      await settle();
    });

    for (final waveform in [true, false]) {
      group(waveform ? 'waveform samples' : 'readout', () {
        Future<void> push(int value) => waveform
            ? service.pushWaveform(
                Float32List.fromList([value.toDouble()]),
                0.5,
                'Track',
              )
            : service.pushReadout(PerformanceReadout(tsNum: value));

        bool carriesData(Map<Object?, Object?> delivery) => waveform
            ? delivery.containsKey('samples')
            : delivery.containsKey('readout');

        /// [value] is what the readout holds: pushing it again sends no data.
        Future<void> expectAcknowledged(int value) async {
          final count = readout.deliveries.length;
          final sent = push(value);
          await settle();
          if (waveform) {
            expect(readout.deliveries, hasLength(count + 1));
            expect(carriesData(readout.deliveries.last), isFalse);
            readout.ack(readout.deliveries.last);
          } else {
            expect(readout.deliveries, hasLength(count));
          }
          await sent;
        }

        test(
          'an equal follower carries data until delivery is acknowledged',
          () async {
            final first = push(1);
            final rejected = expectLater(first, throwsA(isA<Exception>()));
            await settle();
            final second = push(1);
            await settle();
            expect(readout.deliveries, hasLength(2));
            expect(readout.deliveries.every(carriesData), isTrue);

            readout.ack(readout.deliveries[1]);
            await second;
            await rejected;
            await expectAcknowledged(1);
          },
        );

        test(
          'a revert carries data and ignores an old acknowledgement',
          () async {
            final seed = push(1);
            await settle();
            readout.ack(readout.deliveries.single);
            await seed;

            final replacement = push(2);
            await settle();
            final revert = push(1);
            await settle();
            expect(readout.deliveries, hasLength(3));
            expect(carriesData(readout.deliveries.last), isTrue);
            readout.ack(readout.deliveries[2]);
            await revert;
            readout.ack(readout.deliveries[1]);
            await replacement;
            await expectAcknowledged(1);
          },
        );

        test('a failed latest send is retried with its payload', () async {
          await expectLater(push(1), throwsA(isA<Exception>()));
          final retry = push(1);
          await settle();
          expect(carriesData(readout.deliveries.last), isTrue);
          readout.ack(readout.deliveries.last);
          await retry;
        });

        for (final reopen in [false, true]) {
          test('a late reply cannot seed a '
              '${reopen ? 'reopened' : 'reannounced'} readout', () async {
            final old = push(1);
            final dropped = expectLater(old, throwsA(isA<StateError>()));
            await settle();
            final stale = readout.deliveries.single;
            if (reopen) {
              await service.close();
              expect(await service.open(), isTrue);
            } else {
              readout.announce();
            }
            await settle();
            readout.ack(stale);
            await dropped;
            final fresh = push(1);
            await settle();
            expect(readout.deliveries, hasLength(2));
            expect(carriesData(readout.deliveries.last), isTrue);
            readout.ack(readout.deliveries.last);
            await fresh;
          });
        }
      });
    }
  });
}

/// A readout whose acknowledgements the test sends, so pushes can overlap.
class _ScriptedReadout {
  _ScriptedReadout(this._directory) {
    _inbox.listen(_onMessage);
    _directory.publish(screenLinkReadoutPort, _inbox.sendPort);
  }

  final _Directory _directory;
  final _inbox = ReceivePort('scripted readout');

  /// Every waveform frame and readout received, unacknowledged until [ack].
  final deliveries = <Map<Object?, Object?>>[];

  void _onMessage(Object? message) {
    if (message is! Map<Object?, Object?>) return;
    switch (message['op']) {
      case ScreenLinkOp.hello:
        announce();
      case ScreenLinkOp.waveform || ScreenLinkOp.readout:
        deliveries.add(message);
    }
  }

  /// Says "I am up and hold nothing", as a restarted readout does.
  void announce() => _directory.lookup(screenLinkMainPort)?.send({
    'op': ScreenLinkOp.ready,
    'port': _inbox.sendPort,
  });

  /// Acknowledges [delivery].
  void ack(Map<Object?, Object?> delivery) => _directory
      .lookup(screenLinkMainPort)!
      .send({'op': ScreenLinkOp.ack, 'seq': delivery['seq']});

  void close() => _inbox.close();
}
