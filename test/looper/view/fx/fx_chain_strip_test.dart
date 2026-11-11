import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/fx/fx_chain_strip.dart';

import '../../../helpers/helpers.dart';

void main() {
  const rack = FxRack(id: 'R', name: 'Funk Wah');

  Future<List<(int, bool)>> pump(
    WidgetTester tester,
    List<TrackEffect> entries, {
    bool showPlacement = true,
    Map<String, List<String>> assignments = const {},
  }) async {
    final toggles = <(int, bool)>[];
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 1856,
            height: 400,
            child: FxChainStrip(
              entries: entries,
              showPlacement: showPlacement,
              assignments: assignments,
              onTogglePower: (group, {required enabled}) =>
                  toggles.add((group, enabled)),
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    return toggles;
  }

  // What a screen reader announces for the card itself (its InkWell's node).
  String cardLabel(WidgetTester tester, Finder card) => tester
      .getSemantics(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      )
      .label;

  final mixed = [
    BuiltInEffect(
      type: TrackEffectType.filter,
      slotId: 's1',
      placement: FxPlacement.pre,
    ),
    BuiltInEffect(type: TrackEffectType.drive, slotId: 'r1', rack: rack),
    BuiltInEffect(type: TrackEffectType.reverb, slotId: 'r2', rack: rack),
    BuiltInEffect(type: TrackEffectType.echo, slotId: 's2'),
  ];

  group('FxChainStrip (#1754)', () {
    testWidgets('a single effect gets a card half a rack column wide, as tall '
        'as a rack card', (tester) async {
      await pump(tester, mixed);
      final single = tester.getRect(find.byKey(const Key('fx_card_s1')));
      final rackCard = tester.getRect(find.byKey(const Key('fx_card_R')));
      expect(single.width, kFxSingleCardWidth);
      expect(rackCard.width, kFxCardWidth);
      expect(single.height, rackCard.height);
      expect(single.top, rackCard.top);
      // The single card's header and assignment lines sit level with the
      // rack card's placement and status lines.
      Rect text(String card, String label) => tester.getRect(
        find.descendant(
          of: find.byKey(Key('fx_card_$card')),
          matching: find.text(label),
        ),
      );
      expect(text('s1', 'Pre').center.dy, text('R', 'Post').center.dy);
      expect(
        text('s1', 'Unassigned').center.dy,
        text('R', '2 effects').center.dy,
      );
    });

    testWidgets('after the Pre/Post break the Post run keeps the grid: two '
        'singles span a rack card', (tester) async {
      await pump(tester, [
        BuiltInEffect(
          type: TrackEffectType.filter,
          slotId: 'p',
          placement: FxPlacement.pre,
        ),
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'a'),
        BuiltInEffect(type: TrackEffectType.echo, slotId: 'b'),
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'c', rack: rack),
      ]);
      final p = tester.getRect(find.byKey(const Key('fx_card_p')));
      final a = tester.getRect(find.byKey(const Key('fx_card_a')));
      final b = tester.getRect(find.byKey(const Key('fx_card_b')));
      final r = tester.getRect(find.byKey(const Key('fx_card_R')));
      expect(a.left - p.right, kFxStageBreak);
      expect(b.right - a.left, kFxCardWidth);
      expect(r.left - b.right, kFxCardGap);
    });

    testWidgets('a plugin, which has no pedal, prints its name under the '
        "app's mark, once for a screen reader", (tester) async {
      await pump(tester, [
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'mystery'),
          name: 'Mystery box',
          slotId: 'x',
        ),
      ]);
      final card = find.byKey(const Key('fx_card_x'));
      expect(
        find.descendant(of: card, matching: find.text('Mystery box')),
        findsOneWidget,
      );
      expect(
        RegExp('Mystery box').allMatches(cardLabel(tester, card)),
        hasLength(1),
      );
    });

    testWidgets('the assignment line names what the effect is assigned to: '
        'one control, or the first and how many more (#1757)', (tester) async {
      await pump(
        tester,
        [
          BuiltInEffect(type: TrackEffectType.filter, slotId: 'one'),
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'many'),
          BuiltInEffect(type: TrackEffectType.echo, slotId: 'none'),
        ],
        assignments: {
          'one': ['Track 3'],
          'many': ['Track 1 · Hold', 'CTRL 2', 'CC 20 · Ch 1'],
        },
      );
      Finder line(String card, String text) => find.descendant(
        of: find.byKey(Key('fx_card_$card')),
        matching: find.text(text),
      );
      expect(line('one', 'Track 3'), findsOneWidget);
      expect(line('many', 'Track 1 · Hold +2'), findsOneWidget);
      expect(line('none', 'Unassigned'), findsOneWidget);
      // A screen reader hears every one.
      expect(
        cardLabel(tester, find.byKey(const Key('fx_card_many'))),
        contains('Track 1 · Hold, CTRL 2, CC 20 · Ch 1'),
      );
    });

    testWidgets('consecutive singles sit a gap apart, on the rack column '
        'grid', (tester) async {
      await pump(tester, [
        BuiltInEffect(type: TrackEffectType.filter, slotId: 'a'),
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'b'),
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'c', rack: rack),
      ]);
      final a = tester.getRect(find.byKey(const Key('fx_card_a')));
      final b = tester.getRect(find.byKey(const Key('fx_card_b')));
      final r = tester.getRect(find.byKey(const Key('fx_card_R')));
      expect(b.left - a.right, kFxCardGap);
      // The rack after two singles starts where a second rack would.
      expect(r.left - a.left, kFxCardWidth + kFxCardGap);
    });

    testWidgets('a single card shows its placement, assignment and a '
        'power that flips its group', (tester) async {
      final toggles = await pump(tester, mixed);
      final card = find.byKey(const Key('fx_card_s1'));
      expect(
        find.descendant(of: card, matching: find.text('Pre')),
        findsOneWidget,
      );
      // No title: the pedal prints the name, and the card carries it for a
      // screen reader.
      expect(
        find.descendant(of: card, matching: find.text('Filter')),
        findsNothing,
      );
      expect(
        cardLabel(tester, card),
        allOf(startsWith('Filter'), contains('Unassigned')),
      );
      // The power is its own node, so neither card's label carries it.
      expect(cardLabel(tester, card), isNot(contains('power')));
      expect(
        tester.getSemantics(find.text('Funk Wah')).label,
        allOf(contains('Funk Wah'), isNot(contains('power'))),
      );
      expect(
        find.descendant(of: card, matching: find.text('Unassigned')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('fx_power_s1')));
      expect(toggles, [(0, false)]);
    });

    testWidgets('without placement a single card has no Pre/Post tag', (
      tester,
    ) async {
      await pump(tester, [
        BuiltInEffect(type: TrackEffectType.echo, slotId: 's2'),
      ], showPlacement: false);
      final card = find.byKey(const Key('fx_card_s2'));
      expect(
        find.descendant(of: card, matching: find.text('Post')),
        findsNothing,
      );
      expect(find.byKey(const Key('fx_power_s2')), findsOneWidget);
    });
  });
}
