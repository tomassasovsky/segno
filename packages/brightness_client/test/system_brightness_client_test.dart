@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';

void main() {
  test('default helperPath is the appliance segno-brightness-ctl', () {
    expect(
      const SystemBrightnessClient().helperPath,
      '/usr/bin/segno-brightness-ctl',
    );
  });

  group('names the display on every call', () {
    late Directory dir;
    late File args;
    late SystemBrightnessClient client;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('brightness-client');
      args = File('${dir.path}/args');
      final helper = File('${dir.path}/helper')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'echo "\$@" >> "${args.path}"\n'
          'echo \'{"supported":true}\'\n',
        );
      Process.runSync('chmod', ['+x', helper.path]);
      client = SystemBrightnessClient(helperPath: helper.path);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('supported', () async {
      expect(await client.isSupported('HDMI-A-2'), isTrue);
      expect(args.readAsStringSync().trim(), 'supported --connector HDMI-A-2');
    });

    test('set, as a whole percent', () async {
      await client.set('HDMI-A-1', 0.5);
      expect(args.readAsStringSync().trim(), 'set 50 --connector HDMI-A-1');
    });
  });
}
