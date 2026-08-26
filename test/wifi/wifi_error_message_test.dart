import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:segno/wifi/wifi_join_failure.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('maps authentication failures to the password hint', () {
    expect(
      wifiErrorMessage(
        l10n,
        'segno-wifi-ctl: authentication failed for network 0 (wrong password?)',
      ),
      l10n.wifiConnectFailedPassword,
    );
  });

  test('maps association timeouts', () {
    expect(
      wifiErrorMessage(
        l10n,
        'segno-wifi-ctl: timed out waiting for association (state=ASSOCIATED)',
      ),
      l10n.wifiConnectFailedTimeout,
    );
  });

  test('maps generic helper process failures', () {
    expect(
      wifiErrorMessage(
        l10n,
        'ProcessException: segno-wifi-ctl failed',
      ),
      l10n.wifiConnectFailedGeneric,
    );
  });

  // NM's `no-secrets` is what the #824 boot race ends as — on an agent-less
  // console it is not evidence about the password, so without the join
  // context the mapper must NOT suggest re-typing it (#829).
  test('no longer maps bare NetworkManager secrets errors to the password '
      'hint', () {
    expect(
      wifiErrorMessage(
        l10n,
        'Error: Connection activation failed: (7) Secrets were required, '
        'but not provided.',
      ),
      l10n.wifiConnectFailedBackend,
    );
  });

  test('a classified kind decides the copy over the raw text', () {
    const raw = 'Secrets were required, but not provided.';
    expect(
      wifiErrorMessage(l10n, raw, kind: WifiJoinErrorKind.credentials),
      l10n.wifiConnectFailedPassword,
    );
    expect(
      wifiErrorMessage(l10n, raw, kind: WifiJoinErrorKind.transient),
      l10n.wifiConnectFailedBackend,
    );
    expect(
      wifiErrorMessage(l10n, raw, kind: WifiJoinErrorKind.timeout),
      l10n.wifiConnectFailedTimeout,
    );
    expect(
      wifiErrorMessage(l10n, raw, kind: WifiJoinErrorKind.unknown),
      l10n.wifiConnectFailedGeneric,
    );
  });

  test('the backend copy never mentions the password as the fix', () {
    expect(
      l10n.wifiConnectFailedBackend.toLowerCase(),
      isNot(contains('check the password')),
    );
  });
}
