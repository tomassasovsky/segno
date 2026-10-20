import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every string the app has in English it also has in Spanish. The owner
/// runs the console in Spanish, and a screen that falls back to English
/// midway reads as unfinished; gen-l10n only warns about it.
void main() {
  Map<String, dynamic> arb(String locale) =>
      jsonDecode(File('lib/l10n/arb/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;

  test('app_es.arb has every key app_en.arb has', () {
    final spanish = arb('es');
    final missing = [
      for (final key in arb('en').keys)
        if (!key.startsWith('@') && !spanish.containsKey(key)) key,
    ];
    expect(missing, isEmpty, reason: 'untranslated: ${missing.join(', ')}');
  });
}
