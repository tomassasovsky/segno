import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/view/playback_endpoint_choice.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

void main() {
  testWidgets('Loop/Once choice restores its opening draft on Escape', (
    tester,
  ) async {
    var endpoint = 0.0;
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
            builder: (context, setState) => PlaybackEndpointChoice(
              value: endpoint,
              width: 420,
              enabled: true,
              keyPrefix: 'choice',
              onChanged: (value) => setState(() => endpoint = value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(endpoint, 0);
    await tester.tap(find.byKey(const Key('choice_once')));
    await tester.pump();
    expect(endpoint, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(endpoint, 0);
    await tester.tap(find.byKey(const Key('choice_once')));
    await tester.pump();
    expect(endpoint, 1);
  });
}
