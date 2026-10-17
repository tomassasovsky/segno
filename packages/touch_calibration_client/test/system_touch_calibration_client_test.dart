@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

void main() {
  test('default helperPath is the appliance segno-touch-ctl', () {
    expect(
      const SystemTouchCalibrationClient().helperPath,
      '/usr/bin/segno-touch-ctl',
    );
  });

  group('names the screen on every call', () {
    late Directory dir;
    late File args;
    late File reply;
    late SystemTouchCalibrationClient client;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('touch-client');
      args = File('${dir.path}/args');
      reply = File('${dir.path}/reply')
        ..writeAsStringSync(
          '{"calibrated":true,"matrix":"1.1 0 -0.05 0 0.9 0.02"}',
        );
      final helper = File('${dir.path}/helper')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'echo "\$@" >> "${args.path}"\n'
          'cat "${reply.path}"\n',
        );
      Process.runSync('chmod', ['+x', helper.path]);
      client = SystemTouchCalibrationClient(helperPath: helper.path);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('supported when the helper is there', () async {
      expect(await client.isSupported(), isTrue);
      expect(
        await const SystemTouchCalibrationClient(
          helperPath: '/nonexistent/segno-touch-ctl',
        ).isSupported(),
        isFalse,
      );
    });

    test('read', () async {
      expect(
        await client.read(TouchScreen.readout),
        const TouchMatrix(1.1, 0, -0.05, 0, 0.9, 0.02),
      );
      expect(args.readAsStringSync().trim(), 'get readout');
    });

    test('read with no calibration is null', () async {
      reply.writeAsStringSync('{"calibrated":false,"matrix":""}');
      expect(await client.read(TouchScreen.main), isNull);
    });

    test('write', () async {
      await client.write(
        TouchScreen.main,
        const TouchMatrix(1, 0, 0.01, 0, 1, -0.02),
      );
      expect(
        args.readAsStringSync().trim(),
        'set main 1.000000 0.000000 0.010000 0.000000 1.000000 -0.020000',
      );
    });

    test('apply, without storing', () async {
      await client.apply(
        TouchScreen.readout,
        const TouchMatrix(1, 0, 0.01, 0, 1, -0.02),
      );
      expect(
        args.readAsStringSync().trim(),
        'try readout 1.000000 0.000000 0.010000 0.000000 1.000000 -0.020000',
      );
    });

    test('restore', () async {
      await client.restore(TouchScreen.readout);
      expect(args.readAsStringSync().trim(), 'restore readout');
    });
  });

  test('a failing helper surfaces its error', () async {
    final dir = Directory.systemTemp.createTempSync('touch-client-fail');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = File('${dir.path}/helper')
      ..writeAsStringSync('#!/bin/sh\necho "need 6 values" >&2\nexit 2\n');
    Process.runSync('chmod', ['+x', helper.path]);
    await expectLater(
      SystemTouchCalibrationClient(
        helperPath: helper.path,
      ).restore(TouchScreen.main),
      throwsA(
        isA<ProcessException>()
            .having((e) => e.message, 'message', 'need 6 values')
            .having((e) => e.errorCode, 'errorCode', 2),
      ),
    );
  });

  test('the unsupported client does nothing', () async {
    const client = UnsupportedTouchCalibrationClient();
    expect(await client.isSupported(), isFalse);
    expect(await client.read(TouchScreen.main), isNull);
    await client.write(TouchScreen.main, TouchMatrix.identity);
    await client.apply(TouchScreen.readout, TouchMatrix.identity);
    await client.restore(TouchScreen.readout);
  });

  test('off the appliance there is nothing to calibrate', () {
    // Neither this machine nor CI has the appliance helper installed.
    expect(
      createTouchCalibrationClient(),
      isA<UnsupportedTouchCalibrationClient>(),
    );
  });
}
