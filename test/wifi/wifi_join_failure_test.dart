import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_join_failure.dart';

void main() {
  group('classifyWifiJoinFailure', () {
    // The recovered #824 boot-race specimen: NM ends the failed activation
    // as `no-secrets` while the saved profile holds a provably correct key.
    const noSecrets =
        'Error: Connection activation failed: (7) Secrets were required, '
        'but not provided.';

    test(
      'no-secrets on an autonomous saved-network join is backend/transient — '
      'the #824 race, never a password problem',
      () {
        expect(
          classifyWifiJoinFailure(raw: noSecrets, interactive: false),
          WifiJoinErrorKind.transient,
        );
        expect(
          classifyWifiJoinFailure(
            raw: "state change: config -> failed (reason 'no-secrets')",
            interactive: false,
          ),
          WifiJoinErrorKind.transient,
        );
      },
    );

    test(
      'no-secrets immediately after the user submitted a password is a '
      'credentials rejection — iwd reports interactive wrong-password this way',
      () {
        expect(
          classifyWifiJoinFailure(raw: noSecrets, interactive: true),
          WifiJoinErrorKind.credentials,
        );
      },
    );

    test('iwd Failed / Aborted are transient in any context', () {
      const failed =
          'Activation: (wifi) Network.Connect failed: '
          'GDBus.Error:net.connman.iwd.Failed';
      const aborted = 'GDBus.Error:net.connman.iwd.Aborted: Aborted';
      for (final interactive in [true, false]) {
        expect(
          classifyWifiJoinFailure(raw: failed, interactive: interactive),
          WifiJoinErrorKind.transient,
        );
        expect(
          classifyWifiJoinFailure(raw: aborted, interactive: interactive),
          WifiJoinErrorKind.transient,
        );
      }
    });

    test(
      'iwd teardown debris (Invalid exchange, connect-failed) is transient',
      () {
        expect(
          classifyWifiJoinFailure(
            raw:
                'Received error during CMD_TRIGGER_SCAN: Invalid exchange (52)',
            interactive: false,
          ),
          WifiJoinErrorKind.transient,
        );
        expect(
          classifyWifiJoinFailure(
            raw: 'event: connect-failed, status: 16',
            interactive: false,
          ),
          WifiJoinErrorKind.transient,
        );
      },
    );

    test(
      'hard handshake evidence is credentials even on an autonomous join — '
      'the key was tested and failed',
      () {
        const handshake = 'segno-wifi-ctl: 4-way handshake failed';
        expect(
          classifyWifiJoinFailure(raw: handshake, interactive: false),
          WifiJoinErrorKind.credentials,
        );
        expect(
          classifyWifiJoinFailure(
            raw: 'WPA: pre-shared key may be incorrect',
            interactive: false,
          ),
          WifiJoinErrorKind.credentials,
        );
      },
    );

    test('the helper wording for auth failure maps to credentials', () {
      expect(
        classifyWifiJoinFailure(
          raw: 'segno-wifi-ctl: authentication failed (wrong password?)',
          interactive: true,
        ),
        WifiJoinErrorKind.credentials,
      );
    });

    test('association timeouts are their own retryable kind', () {
      expect(
        classifyWifiJoinFailure(
          raw: 'segno-wifi-ctl: timed out waiting for association',
          interactive: true,
        ),
        WifiJoinErrorKind.timeout,
      );
      expect(
        classifyWifiJoinFailure(
          raw: 'association took too long',
          interactive: false,
        ),
        WifiJoinErrorKind.timeout,
      );
    });

    test('unrecognized text stays unknown', () {
      expect(
        classifyWifiJoinFailure(
          raw: 'something else entirely',
          interactive: true,
        ),
        WifiJoinErrorKind.unknown,
      );
    });
  });
}
