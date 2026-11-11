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

    testWidgets('a long name does not shrink the pedal: pedals in one row '
        'come out the same size', (tester) async {
      await pump(tester, [
        BuiltInEffect(type: TrackEffectType.echo, slotId: 'short', module: 'X'),
        BuiltInEffect(
          type: TrackEffectType.echo,
          slotId: 'long',
          module: 'A pedal with a name long enough to wrap',
        ),
      ]);
      // The art's slot: the card's second Expanded, after the header's.
      Rect art(String id) => tester.getRect(
        find
            .descendant(
              of: find.byKey(Key('fx_card_$id')),
              matching: find.byType(Expanded),
            )
            .at(1),
      );
      expect(art('long').size, art('short').size);
      expect(art('long').top, art('short').top);
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

    testWidgets('a single card shows its placement, name, assignment and a '
        'power that flips its group', (tester) async {
      final toggles = await pump(tester, mixed);
      final card = find.byKey(const Key('fx_card_s1'));
      expect(
        find.descendant(of: card, matching: find.text('Pre')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Filter')),
        findsOneWidget,
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
