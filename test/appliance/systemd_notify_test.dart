import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/systemd_notify.dart';

/// Binds an AF_UNIX datagram socket at [address] (a path, or `@name` in the
/// abstract namespace) with python3, and returns its first datagram. Python
/// stands in for systemd's end; the app's side is what is under test.
Future<String> _receiveOne(
  String address,
  void Function() send,
) async {
  const script = r'''
import socket, sys
address = sys.argv[1]
if address.startswith("@"):
    address = "\0" + address[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind(address)
print("bound", flush=True)
s.settimeout(10)
sys.stdout.write(s.recv(4096).decode())
sys.stdout.flush()
''';
  final receiver = await Process.start('python3', ['-c', script, address]);
  final output = StringBuffer();
  var sent = false;
  await receiver.stdout.transform(utf8.decoder).forEach((chunk) {
    output.write(chunk);
    if (!sent && output.toString().startsWith('bound\n')) {
      sent = true;
      send();
    }
  });
  await receiver.exitCode.timeout(const Duration(seconds: 15));
  return output.toString().substring('bound\n'.length);
}

void main() {
  group('systemdNotifyFromEnvironment', () {
    test('nothing to notify without NOTIFY_SOCKET', () {
      expect(systemdNotifyFromEnvironment(const {}), isNull);
      expect(systemdNotifyFromEnvironment(const {'NOTIFY_SOCKET': ''}), isNull);
    });

    test(
      'nothing to notify off Linux, even with NOTIFY_SOCKET',
      () {
        expect(
          systemdNotifyFromEnvironment(const {'NOTIFY_SOCKET': '/run/x'}),
          isNull,
        );
      },
      skip: Platform.isLinux ? 'Linux notifies' : false,
    );
  });

  group(
    UnixDatagramNotifier,
    () {
      late Directory dir;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('notify-test');
        addTearDown(() => dir.deleteSync(recursive: true));
      });

      test('sends the state to a socket path', () async {
        final path = '${dir.path}/notify';
        late bool sent;
        final received = await _receiveOne(
          path,
          () => sent = UnixDatagramNotifier(path).notify(
            'READY=1\nSTATUS=alive 0 readout none audio ok',
          ),
        );
        expect(sent, isTrue);
        expect(received, 'READY=1\nSTATUS=alive 0 readout none audio ok');
      });

      test('sends to a socket in the abstract namespace', () async {
        final name = '@segno-notify-test-$pid';
        late bool sent;
        final received = await _receiveOne(
          name,
          () => sent = UnixDatagramNotifier(name).notify('STATUS=alive 1'),
        );
        expect(sent, isTrue);
        expect(received, 'STATUS=alive 1');
      });

      test('reports a socket nobody listens on as not sent', () {
        expect(
          UnixDatagramNotifier('${dir.path}/nobody').notify('READY=1'),
          isFalse,
        );
      });

      test('refuses a path longer than sockaddr_un holds', () {
        expect(
          UnixDatagramNotifier('/${'x' * 120}').notify('READY=1'),
          isFalse,
        );
      });

      test('the factory notifies through the socket it names', () async {
        final path = '${dir.path}/factory';
        final notify = systemdNotifyFromEnvironment({'NOTIFY_SOCKET': path})!;
        final received = await _receiveOne(
          path,
          () => notify('READY=1'),
        );
        expect(received, 'READY=1');
      });
    },
    skip: Platform.isLinux ? false : 'the notify socket is Linux only',
  );
}
