import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/theme/theme.dart';

void main() {
  Future<void> pumpRows(WidgetTester tester, List<Widget> rows) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: Scaffold(body: ConsoleCard(children: rows)),
        ),
      );

  group('ConsoleRow semantics', () {
    // A row announces itself as one composed label, so its visible words are
    // hidden from semantics or they would be read twice. What must NOT be
    // hidden with them is a control the row is holding: a row with no tap of
    // its own is exactly the row whose only control is its `leading` or
    // `trailing`, and silencing that takes the control away entirely rather
    // than removing an echo.
    testWidgets('a readout-only row keeps its trailing control', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var toggled = false;
      await pumpRows(tester, [
        ConsoleRow(
          key: const Key('row'),
          title: 'Sync tempo',
          subtitle: 'Take the tempo from the host',
          showDivider: false,
          trailing: ConsoleSwitch(
            key: const Key('row_switch'),
            value: false,
            semanticLabel: 'Sync tempo',
            onChanged: (_) => toggled = true,
          ),
        ),
      ]);

      // The toggle is still a thing assistive tech can see and name. Asserted
      // through the finder rather than the flag bits, which Flutter has been
      // reshaping: this is the guarantee that matters, and it reads 0 the
      // moment the row silences the control along with its own text.
      expect(find.bySemanticsLabel('Sync tempo'), findsOneWidget);

      // ...and still operable.
      await tester.tap(find.byKey(const Key('row_switch')));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);

      handle.dispose();
    });

    testWidgets('a readout-only row does not announce its text twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpRows(tester, const [
        ConsoleRow(
          key: Key('row'),
          title: 'Buffer',
          state: '128',
          showDisclosure: false,
        ),
      ]);

      expect(
        tester.getSemantics(find.byKey(const Key('row'))).label,
        'Buffer, 128',
      );

      handle.dispose();
    });
  });

  group('ConsoleSegmented', () {
    Widget host({required bool stretch}) => MaterialApp(
      theme: ThemeData(extensions: const [SurfaceTheme.dark]),
      home: Scaffold(
        body: SizedBox(
          width: 600,
          // Align, not a bare SizedBox parent: a tight constraint would force
          // 600 on the shrink-wrapped variant too and the test would prove
          // nothing.
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConsoleSegmented<int>(
              key: const Key('strip'),
              stretch: stretch,
              selected: 0,
              onChanged: (_) {},
              segments: const [
                ConsoleSegment(value: 0, label: 'one'),
                ConsoleSegment(value: 1, label: 'two'),
              ],
            ),
          ),
        ),
      ),
    );

    testWidgets('shrink-wraps by default, so it can sit beside a caption', (
      tester,
    ) async {
      await tester.pumpWidget(host(stretch: false));
      expect(
        tester.getSize(find.byKey(const Key('strip'))).width,
        lessThan(600),
      );
    });

    testWidgets('stretched, it divides the width it is given', (tester) async {
      await tester.pumpWidget(host(stretch: true));
      // The Signal panel stacks these as rows under captions; rows that ended
      // at different x would read as a ragged edge.
      expect(tester.getSize(find.byKey(const Key('strip'))).width, 600);
    });

    testWidgets('re-tapping the chosen segment does not fire', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [SurfaceTheme.dark]),
          home: Scaffold(
            body: ConsoleSegmented<int>(
              selected: 0,
              onChanged: (_) => fired++,
              segments: const [
                ConsoleSegment(value: 0, label: 'one'),
                ConsoleSegment(value: 1, label: 'two'),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      // A caller whose handler TOGGLES would otherwise invert the rig from the
      // segment that already says what the rig is doing.
      expect(fired, 0);

      await tester.tap(find.text('two'));
      await tester.pumpAndSettle();
      expect(fired, 1);
    });
  });
}
