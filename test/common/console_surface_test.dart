import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

  group('a value bar that only reads', () {
    /// Pumps a bar whose value never moves, so what is drawn is either the
    /// widget's value or a fraction the bar is holding on its own.
    Future<void> pumpBar(WidgetTester tester, {required bool live}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(extensions: const [SurfaceTheme.dark]),
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

  group('ConsoleCaption', () {
    Future<void> pumpCaption(
      WidgetTester tester, {
      String? explain,
      String explainLabel = 'What "in the mix" does',
    }) => pumpRows(tester, [
      ConsoleCaption(
        'in the mix',
        explain: explain,
        // Together or not at all — the widget asserts it, since an
        // explanation with no label is an unnamed button.
        explainLabel: explain == null ? null : explainLabel,
      ),
    ]);

    testWidgets('a caption with nothing to explain has no question', (
      tester,
    ) async {
      await pumpCaption(tester);

      // Not every caption needs one: `chain` over a strip of named effects is
      // its own answer, and a `?` beside it is noise on a dense face.
      expect(find.byKey(const Key('console_caption_explain')), findsNothing);
    });

    testWidgets('opening the answer moves nothing on the face', (
      tester,
    ) async {
      await pumpCaption(tester, explain: 'Whether you hear it.');
      final shut = tester.getRect(find.byType(ConsoleCaption));

      await tester.tap(find.byKey(const Key('console_caption_explain')));
      await tester.pumpAndSettle();

      // The whole point of the overlay. As inline prose this grew the caption
      // by the paragraph's own height and pushed every control under it down
      // — on a four-caption face, most of a small console's screen, and it
      // moved under the finger that had just tapped.
      expect(
        find.byKey(const Key('console_caption_explanation')),
        findsOneWidget,
      );
      expect(tester.getRect(find.byType(ConsoleCaption)), shut);
    });

    testWidgets('an answer with no room around it still lands on screen', (
      tester,
    ) async {
      // The worst corner and the longest answer: a caption at the bottom
      // right has no room under it, none to its right, and this paragraph is
      // taller than the screen it has to fit on.
      final long = List.filled(60, 'Whether you hear it.').join(' ');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: ConsoleCaption(
                'in the mix',
                explain: long,
                explainLabel: 'What "in the mix" does',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('console_caption_explain')));
      await tester.pumpAndSettle();

      const screen = Rect.fromLTWH(0, 0, 800, 600);
      final answer = tester.getRect(
        find.byKey(const Key('console_caption_explanation')),
      );
      expect(
        screen.contains(answer.topLeft) && screen.contains(answer.bottomRight),
        isTrue,
        reason: '$answer is not inside $screen',
      );

      // And what will not fit is reachable rather than gone. Clipping the
      // overflow would take the end of the paragraph, which is where these
      // answers put the consequence.
      final before = tester.getRect(find.text(long)).top;
      await tester.drag(find.text(long), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text(long)).top, lessThan(before));
    });

    testWidgets('the answer carries its own way out, on the console OS', (
      tester,
    ) async {
      // Linux is what the appliance runs. `ModalBarrier` offers its dismiss
      // action only where the platform has a back gesture — Android, iOS and
      // macOS — and excludes itself from semantics everywhere else, while
      // still blocking the face behind. That left a reader on this console
      // holding one paragraph with no action on it and nothing else in tree.
      //
      // `finally`, not a tear-down: the framework asserts every foundation
      // debug variable is back before the test RETURNS, so a tear-down is too
      // late and trips its own check. Restoring only on the happy path is
      // worse than either — one failure here then fails every test after it
      // in this file, which buries the one that actually broke.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final handle = tester.ensureSemantics();
      const explain = 'Whether you hear it.';
      try {
        await pumpCaption(tester, explain: explain);
        await tester.tap(find.byKey(const Key('console_caption_explain')));
        await tester.pumpAndSettle();

        final answer = tester.getSemantics(
          find.byKey(const Key('console_caption_explanation')),
        );
        final data = answer.getSemanticsData();
        expect(data.hasAction(SemanticsAction.dismiss), isTrue);

        // On the same node as the words. Split apart, the node that answers
        // the question cannot be closed and the node that closes it announces
        // nothing.
        expect(data.label, explain);
        expect(find.bySemanticsLabel(explain), findsOneWidget);

        // And it is not decoration: performing it closes.
        answer.owner!.performAction(answer.id, SemanticsAction.dismiss);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('console_caption_explanation')),
          findsNothing,
        );
      } finally {
        handle.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the answer follows a caption the face moves', (tester) async {
      // The barrier stops a finger, not the face: this panel grows a notice on
      // its own, and a window resizes. A rect measured once and never again
      // left the paragraph hanging off whatever moved into its place.
      // Grown from outside the tree, the way the real triggers are: a notice
      // arriving from a bloc, a window resizing. A button would not do — the
      // barrier is over it, and the tap would close the answer first.
      final notice = ValueNotifier<double>(0);
      addTearDown(notice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: Scaffold(
            body: Column(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: notice,
                  builder: (context, height, child) => SizedBox(height: height),
                ),
                const ConsoleCaption(
                  'in the mix',
                  explain: 'Whether you hear it.',
                  explainLabel: 'What "in the mix" does',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('console_caption_explain')));
      await tester.pumpAndSettle();
      final gap =
          tester
              .getRect(find.byKey(const Key('console_caption_explanation')))
              .top -
          tester.getRect(find.byKey(const Key('console_caption_explain'))).top;

      notice.value = 200;
      await tester.pumpAndSettle();

      // Same distance from the caption, wherever the caption ended up.
      expect(
        tester
                .getRect(find.byKey(const Key('console_caption_explanation')))
                .top -
            tester
                .getRect(find.byKey(const Key('console_caption_explain')))
                .top,
        closeTo(gap, 0.5),
      );
    });

    testWidgets('a tap anywhere else puts the answer away', (tester) async {
      await pumpCaption(tester, explain: 'Whether you hear it.');
      await tester.tap(find.byKey(const Key('console_caption_explain')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('console_caption_scrim')));
      await tester.pumpAndSettle();

      // An answer that stays up while you go and use the control it explains
      // is a panel, not an answer.
      expect(
        find.byKey(const Key('console_caption_explanation')),
        findsNothing,
      );
    });

    testWidgets('a tap 15px off centre still opens it', (tester) async {
      await pumpCaption(tester, explain: 'Whether you hear it.');
      final target = find.byKey(const Key('console_caption_explain'));

      // The gap this replaces: an `OverflowBox` grew what was PAINTED to 44
      // and left the hit test at the 18px the ancestors were sized to, so a
      // finger that landed inside the drawn circle did nothing. Layout size
      // proved nothing about it — the old test measured 44 and passed while
      // this tap did not work.
      await tester.tapAt(tester.getCenter(target) + const Offset(0, -15));
      await tester.pump();
      expect(
        find.byKey(const Key('console_caption_explanation')),
        findsOneWidget,
      );
    });

    testWidgets('the words open it too', (tester) async {
      await pumpCaption(tester, explain: 'Whether you hear it.');

      // A question mark that answers only when struck dead centre teaches
      // people it is broken. The caption beside it asks the same question.
      await tester.tap(find.text('in the mix'));
      await tester.pump();
      expect(
        find.byKey(const Key('console_caption_explanation')),
        findsOneWidget,
      );
    });

    testWidgets('it meets the platform tap target guideline', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCaption(tester, explain: 'Whether you hear it.');

      // The floor unit is aimed at with a finger by someone standing over it.
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the reader hears the name, not the glyph', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCaption(
        tester,
        explain: 'Whether you hear it.',
      );

      // Without excluding the subtree the node reads "What "in the mix" does
      // \n in the mix \n ?" — the reader announces the question mark.
      expect(
        tester.getSemantics(
          find.byKey(const Key('console_caption_explain')),
        ),
        matchesSemantics(
          label: 'What "in the mix" does',
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasExpandedState: true,
          isFocusable: true,
        ),
      );
      handle.dispose();
    });
  });
}
