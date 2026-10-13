import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';
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
      tracks: [ReadoutTrack(name: 'Loop', state: 'playing', selected: true)],
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

  test('overlay commands reach the main screen', () async {
    final link = startReadout();
    final received = <ReadoutControl>[];
    service.onControl = received.add;
    await service.open();
    await settle();

    const control = ReadoutControl(
      action: ReadoutControl.trackVolume,
      index: 2,
      value: 0.4,
    );
    link.sendControl(control);
    await settle();

    expect(received, [control]);
  });
}
