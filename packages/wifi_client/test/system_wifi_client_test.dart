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

    /// A helper that records its argv and stdin, and answers [stdout] and
    /// [stderr]. `KEY` in [stderr] is replaced by what came on stdin, so a
    /// test can stand in for a helper that echoes the key back.
    void helper({
      String stdout = '{}',
      int exitCode = 0,
      String stderr = 'segno-wifi-ctl: refused',
    }) {
      final script = File('${dir.path}/segno-wifi-ctl')
        ..writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$*" >> "${argsLog.path}"
cat > "${dir.path}/last-stdin"
cat "${dir.path}/last-stdin" >> "${stdinLog.path}"
key=\$(cat "${dir.path}/last-stdin")
printf '%s' '$stdout'
printf '%s\\n' '$stderr' | sed "s/KEY/\$key/" >&2
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
          isA<WifiHelperException>()
              .having((e) => e.message, 'message', 'segno-wifi-ctl: refused')
              .having((e) => e.restored, 'restored', isNull),
        ),
      );
    });

    test('connect hands the key over stdin, never argv', () async {
      helper();
      await client.connect('The Studio', psk: 'n3w-s3cret');

      expect(argsLog.readAsStringSync(), 'connect The Studio\n');
      expect(stdinLog.readAsStringSync(), 'n3w-s3cret\n');
    });

    test('an open network sends no key at all', () async {
      helper();
      await client.connect('Cafe Free');

      expect(argsLog.readAsStringSync(), 'connect Cafe Free\n');
      expect(stdinLog.readAsStringSync(), isEmpty);
    });

    test('a failed join says which network the helper brought back', () async {
      helper(stdout: '{"restored":"The Studio"}', exitCode: 1);
      await expectLater(
        client.connect('Rehearsal', psk: 'wrongpass'),
        throwsA(
          isA<WifiHelperException>().having(
            (e) => e.restored,
            'restored',
            'The Studio',
          ),
        ),
      );
    });

    test('a failed join that restored nothing says so', () async {
      helper(stdout: '', exitCode: 1);
      await expectLater(
        client.connect('Rehearsal', psk: 'wrongpass'),
        throwsA(
          isA<WifiHelperException>().having(
            (e) => e.restored,
            'restored',
            isNull,
          ),
        ),
      );
    });

    test('no error text ever carries the key or the arguments', () async {
      helper(exitCode: 1, stderr: 'segno-wifi-ctl: nmcli said KEY');
      Object? error;
      try {
        await client.connect('Rehearsal', psk: 'n3w-s3cret');
      } on Object catch (e) {
        error = e;
      }
      expect('$error', 'segno-wifi-ctl: nmcli said ***');

      error = null;
      try {
        await client.changePassword('Rehearsal', 'n3w-s3cret');
      } on Object catch (e) {
        error = e;
      }
      expect('$error', isNot(contains('n3w-s3cret')));
      expect('$error', isNot(contains('set-password')));
    });
  });
}
