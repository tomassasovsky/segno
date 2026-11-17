import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:wifi_repository/wifi_repository.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('a failed join', () {
    test('names the network for every reason', () {
      for (final reason in WifiJoinError.values) {
        expect(
          wifiJoinErrorMessage(l10n, reason, 'MyHouseWTF_es'),
          contains('MyHouseWTF_es'),
          reason: '$reason',
        );
      }
    });

    test('speaks of the password only when the key was refused', () {
      for (final reason in WifiJoinError.values) {
        final message = wifiJoinErrorMessage(l10n, reason, 'Studio');
        expect(
          message.toLowerCase().contains('password'),
          reason == WifiJoinError.wrongPassword,
          reason: '$reason: $message',
        );
      }
    });

    test('each reason has its own words', () {
      final messages = {
        for (final reason in WifiJoinError.values)
          wifiJoinErrorMessage(l10n, reason, 'Studio'),
      };
      expect(messages, hasLength(WifiJoinError.values.length));
    });

    test('the 2026-11-17 failure reads as a failed connection', () {
      expect(
        wifiJoinErrorMessage(l10n, WifiJoinError.noConnection, 'Studio'),
        'Couldn’t connect to Studio.',
      );
    });
  });

  group('any other failed action', () {
    test('is one plain line, never the helper text', () {
      expect(
        wifiErrorMessage(l10n, 'segno-wifi-ctl: no saved network named X'),
        l10n.networkActionFailed,
      );
    });

    test('nothing for no error', () {
      expect(wifiErrorMessage(l10n, null), isEmpty);
      expect(wifiErrorMessage(l10n, ''), isEmpty);
    });
  });
}
