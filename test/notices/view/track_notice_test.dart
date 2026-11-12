import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/helpers.dart';
import '../../helpers/text_fit.dart';

Notice _refused() => Notice(
  id: 'rec',
  tone: NoticeTone.warning,
  overline: (_) => 'Rec refused',
  title: (_) => 'Recording did not start',
  body: (_) => 'Press Record again',
);

/// A card's free area: a box with a tap target under the message.
class _Area extends StatelessWidget {
  const _Area({
    required this.channel,
    required this.size,
    required this.onTap,
  });

  final int channel;
  final Size size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => DecoratedBox(
      key: Key('card_$channel'),
      decoration: BoxDecoration(
        border: Border.all(
          color: trackNoticeRing(context, channel) ?? context.surface.card,
          width: 2,
        ),
      ),
      child: SizedBox.fromSize(
        key: Key('area_$channel'),
        size: size,
        child: GestureDetector(
          key: Key('control_$channel'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: TrackNotice(
            channel: channel,
            child: const ColoredBox(
              key: Key('content'),
              color: Colors.transparent,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late NoticesCubit notices;

  setUpAll(loadBundledFonts);

  setUp(() => notices = NoticesCubit());
  tearDown(() => notices.close());

  Future<void> pumpCards(WidgetTester tester, {VoidCallback? onTap}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A Track view column's meter and a Wave view row's waveform.
            _Area(
              channel: 0,
              size: const Size(366, 640),
              onTap: onTap ?? () {},
            ),
            _Area(
              channel: 1,
              size: const Size(1100, 150),
              onTap: onTap ?? () {},
            ),
          ],
        ),
      ),
      notices: notices,
    );
  }

  double fontSizeOf(WidgetTester tester, String key) => tester
      .renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(RichText),
        ),
      )
      .text
      .style!
      .fontSize!;

  testWidgets('nothing over the card while its track has no message', (
    tester,
  ) async {
    await pumpCards(tester);
    expect(find.byKey(const Key('track_notice_0')), findsNothing);
    final ring = tester.widget<DecoratedBox>(
      find.byKey(const Key('card_0')),
    );
    expect(
      (ring.decoration as BoxDecoration).border!.top.color,
      SurfaceTheme.dark.card,
    );
  });

  testWidgets("the message is on its own track's card only, ringed in its "
      'tone, and goes by itself', (tester) async {
    await pumpCards(tester);
    notices.showOnTrack(0, _refused());
    await tester.pump();
    expect(find.byKey(const Key('track_notice_0')), findsOneWidget);
    expect(find.byKey(const Key('track_notice_1')), findsNothing);
    expect(find.text('REC REFUSED'), findsOneWidget);
    expect(find.text('Recording did not start'), findsOneWidget);
    expect(find.text('Press Record again'), findsOneWidget);
    final ring = tester.widget<DecoratedBox>(find.byKey(const Key('card_0')));
    expect(
      (ring.decoration as BoxDecoration).border!.top.color,
      SurfaceTheme.dark.warning,
    );

    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const Key('track_notice_0')), findsNothing);
  });

  testWidgets("the message is centred in the card's free area", (
    tester,
  ) async {
    await pumpCards(tester);
    notices.showOnTrack(0, _refused());
    await tester.pump();
    final area = tester.getRect(find.byKey(const Key('area_0')));
    final top = tester.getRect(
      find.byKey(const Key('track_notice_overline_0')),
    );
    final bottom = tester.getRect(find.byKey(const Key('track_notice_body_0')));
    final block = Rect.fromLTRB(area.left, top.top, area.right, bottom.bottom);
    expect(block.center.dy, moreOrLessEquals(area.center.dy, epsilon: 0.5));
    for (final key in const [
      'track_notice_overline_0',
      'track_notice_title_0',
      'track_notice_body_0',
    ]) {
      expect(
        tester.getRect(find.byKey(Key(key))).center.dx,
        moreOrLessEquals(area.center.dx, epsilon: 0.5),
        reason: key,
      );
    }
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('every card uses the same type ramp, whatever its size', (
    tester,
  ) async {
    await pumpCards(tester);
    notices
      ..showOnTrack(0, _refused())
      ..showOnTrack(1, _refused());
    await tester.pump();
    for (final part in const ['overline', 'title', 'body']) {
      expect(
        fontSizeOf(tester, 'track_notice_${part}_0'),
        fontSizeOf(tester, 'track_notice_${part}_1'),
        reason: part,
      );
    }
    expect(
      fontSizeOf(tester, 'track_notice_title_0'),
      NoticeTheme.standard.trackTitle.fontSize,
    );
    // The short Wave row still shows all of it.
    expect(
      clippedTexts(tester, within: find.byKey(const Key('area_1'))),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets("the message takes the content's place and gives it back", (
    tester,
  ) async {
    await pumpCards(tester);
    expect(find.byKey(const Key('content')).hitTestable(), findsNWidgets(2));
    notices.showOnTrack(0, _refused());
    await tester.pump();
    expect(find.byKey(const Key('content')).hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const Key('content')).hitTestable(), findsNWidgets(2));
  });

  testWidgets('a tap on the card still reaches it', (tester) async {
    var taps = 0;
    await pumpCards(tester, onTap: () => taps++);
    notices.showOnTrack(0, _refused());
    await tester.pump();
    await tester.tap(find.byKey(const Key('area_0')));
    expect(taps, 1);
    await tester.pump(const Duration(seconds: 6));
  });
}
