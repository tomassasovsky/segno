import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
              SpacingTheme.standard,
              NoticeTheme.standard,
            ],
          ),
          home: Scaffold(body: ConsoleCard(children: rows)),
        ),
      );

  group('ConsoleRow layout', () {
    testWidgets('the title takes twice the share of the value, and a long '
        'subtitle keeps all its words (#1590 DEV-1)', (tester) async {
      // The console's own width: the test font's square glyphs make the
      // sentence far wider than it is on the console.
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const subtitle =
          'A higher cap reserves more memory per track. Change it with no '
          'tracks recorded.';
      await pumpRows(tester, [
        const ConsoleRow(
          key: Key('row'),
          title: 'Maximum loop length',
          subtitle: subtitle,
          value: '5 min',
          expanded: false,
          showDivider: false,
        ),
      ]);
      final row = tester.getRect(find.byKey(const Key('row')));
      final sub = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(subtitle),
          matching: find.byType(RichText),
        ),
      );
      // The title column takes more than half the row, and the value stays
      // at the row's right edge.
      expect(sub.size.width, greaterThan(row.width / 2));
      expect(
        tester.getTopRight(find.text('5 min')).dx,
        greaterThan(row.right - row.width / 4),
      );
      expect(sub.didExceedMaxLines, isFalse);
    });
  });

  testWidgets(
    'a row is drawn at the scale of the full-size pages (#1590 DEV-2)',
    (tester) async {
      await pumpRows(tester, [
        ConsoleRow(
          key: const Key('row'),
          title: 'Delete old captures',
          subtitle: 'Captures older than 30 days',
          value: '6.2 GB',
          expanded: false,
          showDivider: false,
          onTap: () {},
        ),
        ConsolePickRow(
          key: const Key('pick'),
          title: 'Scarlett 18i20',
          state: '18 in · 20 out',
          selected: true,
          onTap: () {},
        ),
      ]);
      double size(String text) => tester
          .widget<AppText>(find.widgetWithText(AppText, text))
          .style!
          .fontSize!;
      expect(tester.getSize(find.byKey(const Key('row'))).height, 84);
      expect(size('Delete old captures'), 24);
      expect(size('Captures older than 30 days'), 20);
      expect(size('6.2 GB'), 24);
      expect(size('Scarlett 18i20'), 24);
      expect(size('18 in · 20 out'), 20);
      // The pages' 28 px chevron and check, not text glyphs.
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('row')),
                matching: find.byType(Icon),
              ),
            )
            .size,
        28,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('pick')),
                matching: find.byType(Icon),
              ),
            )
            .size,
        28,
      );
    },
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
          trailing: Semantics(
            container: true,
            label: 'Sync tempo',
            child: Switch(
              key: const Key('row_switch'),
              value: false,
              onChanged: (_) => toggled = true,
            ),
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

  group('a value bar that only reads', () {
    /// Pumps a bar whose value never moves, so what is drawn is either the
    /// widget's value or a fraction the bar is holding on its own.
    Future<void> pumpBar(WidgetTester tester, {required bool live}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              extensions: const [
                SurfaceTheme.dark,
                SpacingTheme.standard,
                NoticeTheme.standard,
              ],
            ),
            home: Scaffold(
              body: ConsoleValueBar(
                label: 'GAIN',
                value: 0,
                readout: '0',
                onChanged: live ? (_) {} : null,
              ),
            ),
          ),
        );

    double fillWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(ConsoleValueBar.fillKey)).width;

    testWidgets('takes no gesture at all', (tester) async {
      await pumpBar(tester, live: false);

      await tester.drag(find.byType(ConsoleValueBar), const Offset(200, 0));
      await tester.pumpAndSettle();
      // Nothing to write to, so nothing to show for it either — a bar that
      // moved under the finger and snapped back is a control that lied.
      expect(fillWidth(tester), 0);
    });

    testWidgets('going read-only under a finger lets the fraction go', (
      tester,
    ) async {
      await pumpBar(tester, live: true);
      final bar = find.byType(ConsoleValueBar);
      final gesture = await tester.startGesture(tester.getCenter(bar));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(fillWidth(tester), greaterThan(0));

      // These bars are keyed by POSITION, so the same state is reused when the
      // editor switches to another effect — and row N there may be a meter.
      // Only the release handlers clear the held fraction and they are wired
      // only while the bar is live, so it stayed pinned where the finger left
      // it and stopped reading the value it is supposed to show, for good.
      await pumpBar(tester, live: false);
      await tester.pumpAndSettle();
      expect(fillWidth(tester), 0);

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

}
