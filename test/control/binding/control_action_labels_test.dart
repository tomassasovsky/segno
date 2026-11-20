import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/l10n/l10n.dart';

void main() {
  group('the session commands', () {
    Future<List<String>> labels(String locale) async {
      final l10n = await AppLocalizations.delegate.load(Locale(locale));
      return [
        for (final action in controlActionsIn(ControlActionGroup.sessions))
          controlActionLabel(l10n, const [], action),
      ];
    }

    test('are named as the accepted catalogue names them', () async {
      expect(await labels('en'), ['New loop', 'Save session']);
    });

    test('are named in Spanish', () async {
      expect(await labels('es'), ['Nuevo loop', 'Guardar sesión']);
    });

    test('sit under the Sessions heading', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        controlActionGroupLabel(l10n, ControlActionGroup.sessions),
        'Sessions',
      );
    });
  });
}
