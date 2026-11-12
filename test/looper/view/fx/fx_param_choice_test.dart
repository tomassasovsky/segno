import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

import '../../../helpers/helpers.dart';
import '../../../helpers/text_fit.dart';

void main() {
  group('FxBuiltInParamControl', () {
    late List<double> written;
    late AppLocalizations l10n;

    setUpAll(() async {
      // The faces the console draws in, so a name measures its real width.
      await loadBundledFonts();
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    setUp(() => written = []);

    // The single effect page's width; a rack pedal's column is 250.
    Future<void> pump(
      WidgetTester tester,
      BuiltInEffect effect,
      int index, {
      double width = 493,
    }) => tester.pumpApp(
      Center(
        child: FxBuiltInParamControl(
          effect: effect,
          index: index,
          width: width,
          onChanged: written.add,
        ),
      ),
    );

    testWidgets('a two-way choice is a row of named buttons, not a slider', (
      tester,
    ) async {
      // The octaver's mode: Phase vocoder or PSOLA.
      await pump(tester, BuiltInEffect(type: TrackEffectType.octaver), 3);

      expect(find.byType(LoopSlider), findsNothing);
      expect(find.byType(LoopChoiceButton), findsNWidgets(2));
      expect(find.text(l10n.octaverModePhaseVocoder), findsOneWidget);

      await tester.tap(find.byKey(const Key('fx_choice_mode_1')));
      await tester.pump();
      expect(written, [1.0]);
    });

    testWidgets('a long choice is a list to pick from', (tester) async {
      // The Slicer's pattern: seventeen of them.
      await pump(tester, BuiltInEffect(type: TrackEffectType.slicer), 0);

      expect(find.byType(LoopSlider), findsNothing);
      expect(find.byType(LoopSelect<int>), findsOneWidget);
      expect(find.text('AABB'), findsOneWidget);

      await tester.tap(find.byKey(const Key('fx_choice_slicer_pattern')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fx_choice_slicer_pattern_4')));
      await tester.pumpAndSettle();
      expect(written, [4 / 16]);
    });

    testWidgets("a rack variant's choice writes its kind's setting", (
      tester,
    ) async {
      // The Studio Rack's Mod shows Chorus and Tremolo, the kind's first and
      // fourth modes.
      final module = kFxModules.firstWhere((m) => m.name == 'Modulation');
      final entry = fxModuleEntry(
        module,
        const FxPreset(
          family: 'Studio Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Mod': 1},
        ),
      );
      final index = fxEntryControls(entry).params.firstWhere(
        (i) => fxEntryParam(entry, i).unit == FxParamUnit.choice,
      );
      await pump(tester, entry, index);

      expect(find.byType(LoopChoiceButton), findsNWidgets(2));
      await tester.tap(find.text('Tremolo'));
      await tester.pump();
      expect(written, [fxEntryKindSetting(entry, index, 1)]);
      expect(
        TrackEffectType.mod.params[index].positionOf(written.single),
        3,
      );
    });

    testWidgets("a three-way choice is a list in a rack pedal's narrow "
        'column', (tester) async {
      // The Guitar Rack's Mod: Chorus, Phaser, Flanger.
      final module = kFxModules.firstWhere((m) => m.name == 'Modulation');
      final entry = fxModuleEntry(
        module,
        const FxPreset(
          family: 'Guitar Rack',
          name: 'p',
          id: 'p',
          type: 0,
          params: {'Mod': 1},
        ),
      );
      final index = fxEntryControls(entry).params.firstWhere(
        (i) => fxEntryParam(entry, i).unit == FxParamUnit.choice,
      );
      expect(fxEntryParam(entry, index).steps, 3);

      await pump(tester, entry, index, width: 250);
      expect(find.byType(LoopSelect<int>), findsOneWidget);
      expect(find.byType(LoopChoiceButton), findsNothing);

      await pump(tester, entry, index);
      expect(find.byType(LoopChoiceButton), findsNWidgets(3));
    });

    testWidgets('a continuous parameter stays a slider', (tester) async {
      await pump(tester, BuiltInEffect(type: TrackEffectType.octaver), 1);

      expect(find.byType(LoopSlider), findsOneWidget);
      expect(find.byType(LoopChoiceButton), findsNothing);
    });

    testWidgets('every choice parameter of every effect is offered by name, '
        'its current position picked', (tester) async {
      for (final type in TrackEffectType.values) {
        for (final (index, param) in type.params.indexed) {
          if (!fxParamIsChoice(param)) continue;
          final last = param.steps - 1;
          final effect = BuiltInEffect(
            type: type,
            params: List.of(type.defaultParams)..[index] = 1,
          );
          await pump(tester, effect, index);
          final reason = '${type.name} ${param.key}';
          expect(find.byType(LoopSlider), findsNothing, reason: reason);
          final name = l10n.fxParamValueText(param, 1);
          final row = find.byType(LoopChoiceButton).evaluate().isNotEmpty;
          // Five buttons never fit the page's 493 at a readable width.
          if (param.steps > 4) expect(row, isFalse, reason: reason);
          if (row) {
            final button = tester.widget<LoopChoiceButton>(
              find.byKey(Key('fx_choice_${param.key}_$last')),
            );
            expect(button.selected, isTrue, reason: reason);
            expect(button.label, name, reason: reason);
          } else {
            final select = tester.widget<LoopSelect<int>>(
              find.byType(LoopSelect<int>),
            );
            expect(select.value, last, reason: reason);
            expect(select.items.map((i) => i.label), [
              for (var k = 0; k <= last; k++)
                l10n.fxParamValueText(param, k / last),
            ], reason: reason);
          }
        }
      }
    });
  });
}
