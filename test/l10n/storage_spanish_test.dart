import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The USB storage strings (#1177) are complete in Spanish: the owner runs
/// the console in Spanish, and a Storage page or a Save to that falls back
/// to English mid-screen reads as unfinished.
void main() {
  const prefixes = [
    'storage',
    'saveTo',
    'connectUsb',
    'powerOffTransfer',
    'perfStoppedVolumeLost',
    'perfArmDriveUnavailable',
  ];

  Map<String, dynamic> arb(String locale) =>
      jsonDecode(File('lib/l10n/arb/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;

  test('every Storage and Save to string has a Spanish translation', () {
    final english = arb('en');
    final spanish = arb('es');
    final missing = [
      for (final key in english.keys)
        if (!key.startsWith('@') &&
            prefixes.any(key.startsWith) &&
            !spanish.containsKey(key))
          key,
    ];
    expect(missing, isEmpty);
  });
}
