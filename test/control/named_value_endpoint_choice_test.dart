import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/view/named_value_endpoint_choice.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

void main() {
  testWidgets('choice edit and Escape preserve the exact opening endpoint', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1800, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var value = 0.2;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NamedValueEndpointChoice(
              target: const ClickModeValueTarget(),
              value: value,
              width: 500,
              enabled: true,
              keyPrefix: 'click_choice',
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(value, 0.2);
    await tester.tap(find.byKey(const Key('click_choice_playRec')));
    await tester.pump();
    expect(value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(value, 0.2);

    await tester.tap(find.byKey(const Key('click_choice_rec')));
    await tester.pump();
    expect(value, 2 / 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Count-in choice and Escape preserve noncanonical opening', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1800, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var value = 0.2;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NamedValueEndpointChoice(
              target: const CountInValueTarget(),
              value: value,
              width: 500,
              enabled: true,
              keyPrefix: 'count_choice',
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('count_choice_4')));
    await tester.pump();
    expect(value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(value, 0.2);
    await tester.tap(find.byKey(const Key('count_choice_2')));
    await tester.pump();
    expect(value, 2 / 3);
    expect(tester.takeException(), isNull);
  });
}
