import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/screen_capture.dart';
import 'package:segno/visualizer/screen_link.dart';

/// The width and height a PNG's IHDR chunk declares.
({int width, int height}) _pngSize(Uint8List png) {
  final header = ByteData.sublistView(png, 16, 24);
  return (width: header.getUint32(0), height: header.getUint32(4));
}

List<String> _names(Directory dir) =>
    dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('screen-capture-'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('screenCaptureRequests', () {
    test('off the console it never asks', () async {
      expect(await screenCaptureRequests(appliance: false).isEmpty, isTrue);
    });

    test('on the console a SIGUSR1 to the process asks', () async {
      final asked = Completer<void>();
      final sub = screenCaptureRequests(appliance: true)
          .listen((_) => asked.complete());
      addTearDown(sub.cancel);
      // The listen above installed the handler, so this cannot end the
      // test process.
      Process.killPid(pid, ProcessSignal.sigusr1);
      await asked.future.timeout(const Duration(seconds: 5));
    }, skip: Platform.isWindows ? 'no SIGUSR1 on Windows' : null);
  });

  test('screenCaptureName is the screen and the UTC time', () {
    expect(
      screenCaptureName(
        SegnoScreen.readout,
        DateTime.utc(2026, 11, 3, 4, 5, 6, 7),
      ),
      'readout-20261103T040506.007Z.png',
    );
  });

  group('saveScreenCapture', () {
    test('creates the directory and writes the PNG', () async {
      final target = '${dir.path}/capture';
      final path = await saveScreenCapture(
        directory: target,
        screen: SegnoScreen.main,
        at: DateTime.utc(2026, 11, 3),
        png: [1, 2, 3],
      );
      expect(path, '$target/main-20261103T000000.000Z.png');
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
      expect(_names(Directory(target)), ['main-20261103T000000.000Z.png']);
    });

    test("keeps that screen's newest captures and no other's", () async {
      File('${dir.path}/readout-20261101T000000.000Z.png')
          .writeAsBytesSync([0]);
      for (var minute = 0; minute < 4; minute++) {
        await saveScreenCapture(
          directory: dir.path,
          screen: SegnoScreen.main,
          at: DateTime.utc(2026, 11, 3, 12, minute),
          png: [minute],
          kept: 2,
        );
      }
      expect(_names(dir), [
        'main-20261103T120200.000Z.png',
        'main-20261103T120300.000Z.png',
        'readout-20261101T000000.000Z.png',
      ]);
    });

    test('keeps the new capture when the clock went back', () async {
      for (final day in [10, 11]) {
        File('${dir.path}/main-202611${day}T000000.000Z.png')
            .writeAsBytesSync([day]);
      }
      final path = await saveScreenCapture(
        directory: dir.path,
        screen: SegnoScreen.main,
        at: DateTime.utc(2026, 11, 3),
        png: [1],
        kept: 2,
      );
      expect(File(path).existsSync(), isTrue);
      expect(_names(dir), [
        'main-20261103T000000.000Z.png',
        'main-20261111T000000.000Z.png',
      ]);
    });

    test("deletes that screen's leftover partial writes", () async {
      File('${dir.path}/main-20261101T000000.000Z.png.part').createSync();
      File('${dir.path}/readout-20261101T000000.000Z.png.part').createSync();
      await saveScreenCapture(
        directory: dir.path,
        screen: SegnoScreen.main,
        at: DateTime.utc(2026, 11, 3),
        png: [1],
      );
      expect(_names(dir), [
        'main-20261103T000000.000Z.png',
        'readout-20261101T000000.000Z.png.part',
      ]);
    });
  });

  group('ScreenCapture', () {
    testWidgets('a request writes what the screen draws as a PNG', (
      tester,
    ) async {
      final requests = StreamController<void>.broadcast();
      addTearDown(requests.close);
      await tester.pumpWidget(
        ScreenCapture(
          screen: SegnoScreen.readout,
          requests: requests.stream,
          directory: dir.path,
          child: const ColoredBox(color: Color(0xFF00FF00)),
        ),
      );

      requests.add(null);
      // The capture's continuations run in the test's fake zone and its
      // rendering and file writes in real time, so alternate the two until
      // the PNG lands.
      List<File> pngs() => dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      for (var i = 0; i < 500 && pngs().isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }

      final written = pngs();
      expect(written, hasLength(1));
      final file = written.single;
      expect(file.uri.pathSegments.last, startsWith('readout-'));
      final png = file.readAsBytesSync();
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final physical = tester.view.physicalSize;
      expect(_pngSize(png), (
        width: physical.width.round(),
        height: physical.height.round(),
      ));
    });

    testWidgets('stops listening when it leaves the tree', (tester) async {
      final requests = StreamController<void>.broadcast();
      addTearDown(requests.close);
      await tester.pumpWidget(
        ScreenCapture(
          screen: SegnoScreen.main,
          requests: requests.stream,
          directory: dir.path,
          child: const SizedBox(),
        ),
      );
      expect(requests.hasListener, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(requests.hasListener, isFalse);
    });
  });
}
