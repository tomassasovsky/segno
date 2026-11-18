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

    test('a failed join says why, beside what it restored', () async {
      helper(
        stdout: '{"error":"wrong-password"}\n{"restored":"The Studio"}',
        exitCode: 1,
      );
      await expectLater(
        client.connect('Rehearsal', psk: 'wrongpass'),
        throwsA(
          isA<WifiHelperException>()
              .having((e) => e.join, 'join', WifiJoinError.wrongPassword)
              .having((e) => e.restored, 'restored', 'The Studio'),
        ),
      );
    });

    test('each code the helper prints is read', () async {
      for (final (code, join) in [
        ('not-found', WifiJoinError.notFound),
        ('no-address', WifiJoinError.noAddress),
        ('no-connection', WifiJoinError.noConnection),
        ('something-new', WifiJoinError.noConnection),
      ]) {
        helper(stdout: '{"error":"$code"}', exitCode: 1);
        await expectLater(
          client.connect('Rehearsal'),
          throwsA(isA<WifiHelperException>().having((e) => e.join, code, join)),
        );
      }
    });

    // The helper's code is the verdict, whatever NetworkManager said (#1843):
    // here the access point timed out the authentication (status 16) and NM
    // ended the join as no-secrets, as it does on a console with no agent.
    test(
      'NetworkManager saying secrets were missing is no wrong password',
      () async {
        helper(
          stdout: '{"error":"no-connection"}',
          exitCode: 1,
          stderr:
              'segno-wifi-ctl: join failed: no-connection (wlan0: '
              'CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16; '
              'nmcli: Error: Connection activation failed: Secrets were '
              'required, but not provided)',
        );
        await expectLater(
          client.connect('MyHouseWTF_es_2.4G'),
          throwsA(
            isA<WifiHelperException>()
                .having((e) => e.join, 'join', WifiJoinError.noConnection)
                .having(
                  (e) => e.message,
                  'message',
                  contains('status_code=16'),
                ),
          ),
        );
      },
    );

    test('a failed join with no code is a failed connection', () async {
      helper(stdout: '', exitCode: 1);
      await expectLater(
        client.connect('Rehearsal'),
        throwsA(
          isA<WifiHelperException>().having(
            (e) => e.join,
            'join',
            WifiJoinError.noConnection,
          ),
        ),
      );
    });

    test('only a join carries a join failure', () async {
      helper(stdout: '{"error":"not-found"}', exitCode: 1);
      await expectLater(
        client.forget('Rehearsal'),
        throwsA(isA<WifiHelperException>().having((e) => e.join, 'join', null)),
      );
    });

    group('changes', () {
      /// A monitor that prints [events], then waits 30 s, or exits at once
      /// when [exitAfter] is set.
      void monitor(List<String> events, {bool exitAfter = false}) {
        final lines = [for (final e in events) "printf '%s\\n' '$e'"];
        final script = File('${dir.path}/segno-wifi-ctl')
          ..writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$*" >> "${argsLog.path}"
echo \$\$ > "${dir.path}/pid"
${lines.join('\n')}
${exitAfter ? 'exit 0' : 'exec sleep 30'}
''');
        Process.runSync('chmod', ['+x', script.path]);
        client = SystemWifiClient(helperPath: script.path);
      }

      test('one event per line from segno-wifi-ctl monitor', () async {
        monitor([
          '{"event":"wlan0: connecting (prepare)"}',
          '{"event":"wlan0: connected"}',
        ]);
        expect(await client.changes().take(2).length, 2);
        expect(argsLog.readAsStringSync(), 'monitor\n');
      });

      test('cancelling stops the helper', () async {
        monitor(['{"event":"wlan0: connected"}']);
        await client.changes().first;
        // The helper would sleep 30 s; cancelling the stream kills it.
        final helperPid = File('${dir.path}/pid').readAsStringSync().trim();
        bool alive() =>
            Process.runSync('kill', ['-0', helperPid]).exitCode == 0;
        for (var i = 0; i < 50 && alive(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(alive(), isFalse);
      });

      test('the stream ends when the helper does', () async {
        monitor(['{"event":"wlan0: disconnected"}'], exitAfter: true);
        expect(await client.changes().length, 1);
      });
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

    group('holdReconnects', () {
      late File hold;

      setUp(() {
        helper();
        hold = File('${dir.path}/wifi-hold');
        client = SystemWifiClient(
          helperPath: client.helperPath,
          holdPath: hold.path,
        );
      });

      test("holding writes this process's PID to the hold file", () async {
        await client.holdReconnects(hold: true);
        expect(hold.readAsStringSync(), '$pid\n');
        expect(
          dir.listSync().map((e) => e.path),
          isNot(contains('${hold.path}.$pid')),
          reason: 'staged through a sibling, then renamed into place',
        );
      });

      test('releasing removes it, and releasing twice is fine', () async {
        await client.holdReconnects(hold: true);
        await client.holdReconnects(hold: false);
        expect(hold.existsSync(), isFalse);
        await client.holdReconnects(hold: false);
        expect(hold.existsSync(), isFalse);
      });

      test('the helper never runs for it', () async {
        await client.holdReconnects(hold: true);
        await client.holdReconnects(hold: false);
        expect(argsLog.readAsStringSync(), isEmpty);
      });
    });
  });

  test('holdReconnects does nothing off the appliance', () async {
    final dir = Directory.systemTemp.createTempSync('wifi-client-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final hold = File('${dir.path}/wifi-hold');
    final client = SystemWifiClient(
      helperPath: '${dir.path}/absent',
      holdPath: hold.path,
    );
    await client.holdReconnects(hold: true);
    expect(hold.existsSync(), isFalse);
  });
}
