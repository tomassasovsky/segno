@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:wifi_client/wifi_client.dart';

void main() {
  test('default helperPath is the appliance segno-wifi-ctl', () {
    expect(const SystemWifiClient().helperPath, '/usr/bin/segno-wifi-ctl');
  });

  group('against a stand-in helper', () {
    late Directory dir;
    late File argsLog;
    late File stdinLog;
    late SystemWifiClient client;

    /// A helper that records its argv and stdin, and answers [stdout].
    void helper({String stdout = '{}', int exitCode = 0}) {
      final script = File('${dir.path}/segno-wifi-ctl')
        ..writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$*" >> "${argsLog.path}"
cat >> "${stdinLog.path}"
printf '%s' '$stdout'
echo 'segno-wifi-ctl: refused' >&2
exit $exitCode
''');
      Process.runSync('chmod', ['+x', script.path]);
      client = SystemWifiClient(helperPath: script.path);
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('wifi-client-test');
      argsLog = File('${dir.path}/args')..writeAsStringSync('');
      stdinLog = File('${dir.path}/stdin')..writeAsStringSync('');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('changePassword hands the key over stdin, never argv', () async {
      helper();
      await client.changePassword('The Studio', 'n3w-s3cret');

      expect(argsLog.readAsStringSync(), 'set-password The Studio\n');
      expect(stdinLog.readAsStringSync(), 'n3w-s3cret\n');
    });

    test('setAutoConnect maps to autoconnect <ssid> on|off', () async {
      helper();
      await client.setAutoConnect('The Studio', enabled: false);
      await client.setAutoConnect('The Studio', enabled: true);

      expect(
        argsLog.readAsStringSync(),
        'autoconnect The Studio off\nautoconnect The Studio on\n',
      );
    });

    test('checkConnectivity reads the internet flag', () async {
      helper(stdout: '{"internet":false}');
      expect(await client.checkConnectivity(), isFalse);
      helper(stdout: '{"internet":true}');
      expect(await client.checkConnectivity(), isTrue);
      expect(argsLog.readAsStringSync(), 'connectivity\nconnectivity\n');
    });

    test('a refusal throws with the helper stderr', () async {
      helper(exitCode: 1);
      await expectLater(
        client.setAutoConnect('Nowhere', enabled: true),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            'segno-wifi-ctl: refused',
          ),
        ),
      );
    });
  });
}
