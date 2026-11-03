import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';
import '../../helpers/text_fit.dart';

/// Inter's cap height, as a share of the font size.
const double _interCapHeight = 1490 / 2048;

/// A top bar built the way the stage's is: two side groups and the centre.
class _Bar extends StatelessWidget {
  const _Bar({this.trackCards});

  final bool Function(int channel)? trackCards;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        key: const Key('bar'),
        height: 96,
        child: NoticeBar(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 60),
            child: TopBarLayout(
              leading: const SizedBox(
                key: Key('leading'),
                width: 300,
                height: 60,
              ),
              centre: NoticeBarMessage(
                trackCards: trackCards,
                fallback: AppText(
                  'Night set',
                  key: const Key('session'),
                  style: context.noticeTheme.barTitle.copyWith(
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              trailing: const SizedBox(
                key: Key('trailing'),
                width: 312,
                height: 60,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Notice _saved() => Notice(
  id: 'saved',
  tone: NoticeTone.success,
  title: (_) => 'Saved as Night set',
);

Notice _lost({VoidCallback? onFix}) => Notice(
  id: 'lost',
  tone: NoticeTone.critical,
  title: (_) => 'Scarlett 4i4 disconnected. Nothing is heard.',
  action: NoticeAction(
    key: const Key('fix'),
    label: (_) => 'Open setup',
    onPressed: onFix ?? () {},
  ),
);

/// The y of [finder]'s first line's alphabetic baseline, in global pixels.
double _baseline(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)).first,
  );
  final distance = paragraph.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  return paragraph.localToGlobal(Offset(0, distance)).dy;
}

/// Lets a message fade in without running out its time, which a settle
/// would: the time-left line animates for the message's whole duration.
Future<void> _fadeIn(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  late NoticesCubit notices;

  // The console's faces, so the geometry below is Inter's and Lucide's and
  // not the test font's squares.
  setUpAll(loadBundledFonts);

  setUp(() {
    notices = NoticesCubit(stopwatch: () => clock.stopwatch());
  });

  tearDown(() => notices.close());

  Future<void> pumpBar(
    WidgetTester tester, {
    bool Function(int channel)? trackCards,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      BlocProvider(
        create: (_) => TracksCubit(
          settings: SettingsRepository(store: FakeKeyValueStore()),
        ),
        child: _Bar(trackCards: trackCards),
      ),
      notices: notices,
    );
  }

  group(NoticeBarMessage, () {
    testWidgets('shows the session name while nothing is said', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(find.byKey(const Key('session')), findsOneWidget);
      expect(find.byKey(const Key('notice_bar_time_left')), findsNothing);
    });

    testWidgets("a message takes the name's place, then gives it back", (
      tester,
    ) async {
      await pumpBar(tester);
      notices.show(_saved());
      await _fadeIn(tester);
      expect(find.text('Saved as Night set', findRichText: true), findsOne);
      expect(find.byKey(const Key('session')), findsNothing);
      expect(find.byKey(const Key('notice_bar_icon')), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session')), findsOneWidget);
      expect(find.text('Saved as Night set', findRichText: true), findsNothing);
    });

    testWidgets('the newest message replaces the one on screen', (
      tester,
    ) async {
      await pumpBar(tester);
      notices.show(_saved());
      await _fadeIn(tester);
      notices.show(
        Notice(
          id: 'midi',
          tone: NoticeTone.warning,
          title: (_) => 'MIDI controller disconnected',
          body: (_) => 'Loops keep playing',
        ),
      );
      await _fadeIn(tester);
      expect(find.text('Saved as Night set', findRichText: true), findsNothing);
      expect(
        find.textContaining('MIDI controller disconnected', findRichText: true),
        findsOne,
      );
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets("the message sits on the session name's baseline at its "
        'size', (tester) async {
      await pumpBar(tester);
      final nameBaseline = _baseline(tester, find.byKey(const Key('session')));
      final nameStyle = tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(const Key('session')),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!;

      notices.show(
        Notice(
          id: 'midi',
          tone: NoticeTone.warning,
          title: (_) => 'MIDI controller disconnected',
          body: (_) => 'Loops keep playing',
        ),
      );
      await _fadeIn(tester);
      final text = find.byKey(const Key('notice_bar_text'));
      expect(_baseline(tester, text), moreOrLessEquals(nameBaseline));
      final title = tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(const Key('notice_sentence_title')),
              matching: find.byType(RichText),
            ),
          )
          .text;
      expect(title.toPlainText(), 'MIDI controller disconnected');
      expect(title.style?.fontSize, nameStyle.fontSize);
      // The body is on the same baseline.
      expect(
        _baseline(tester, find.byKey(const Key('notice_sentence_body'))),
        moreOrLessEquals(nameBaseline),
      );
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets("the icon is centred on the title's capitals and sized to "
        'its line', (tester) async {
      await pumpBar(tester);
      notices.show(_saved());
      await _fadeIn(tester);
      final title = find.byKey(const Key('notice_bar_text'));
      final size = NoticeTheme.standard.barTitle.fontSize!;
      final capCentre = _baseline(tester, title) - size * _interCapHeight / 2;
      final icon = tester.getRect(find.byKey(const Key('notice_bar_icon')));
      expect(icon.height, size);
      expect(icon.center.dy, moreOrLessEquals(capCentre, epsilon: 0.5));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('the time-left line is exactly as wide as the message and '
        'shrinks to its centre', (tester) async {
      await pumpBar(tester);
      notices.show(_saved());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final row = tester.getRect(find.byKey(const Key('notice_bar_saved')));
      final bar = tester.getRect(find.byKey(const Key('bar')));
      var line = tester.getRect(find.byKey(const Key('notice_bar_time_left')));
      // 200 ms of 4 s gone: 95% left.
      expect(line.width, moreOrLessEquals(row.width * 0.95, epsilon: 0.5));
      expect(line.center.dx, moreOrLessEquals(row.center.dx));
      expect(line.bottom, bar.bottom);
      expect(line.height, NoticeTheme.standard.timeLineThickness);

      await tester.pump(const Duration(seconds: 1, milliseconds: 800));
      line = tester.getRect(find.byKey(const Key('notice_bar_time_left')));
      expect(line.width, moreOrLessEquals(row.width / 2, epsilon: 0.5));
      expect(line.center.dx, moreOrLessEquals(row.center.dx));
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('a bar built while a message goes by picks its line up '
        'where it is', (tester) async {
      await pumpBar(tester);
      notices.show(_saved());
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      // Another screen's bar: a fresh one, half the time gone.
      await tester.pumpWidget(const SizedBox());
      await pumpBar(tester);
      await tester.pump();
      final row = tester.getRect(find.byKey(const Key('notice_bar_saved')));
      final line = tester.getRect(
        find.byKey(const Key('notice_bar_time_left')),
      );
      expect(line.width, moreOrLessEquals(row.width / 2, epsilon: 0.5));
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('the same id again restarts the time in place', (tester) async {
      await pumpBar(tester);
      notices.show(_saved());
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final row = tester.getRect(find.byKey(const Key('notice_bar_saved')));
      notices.show(_saved());
      await tester.pump();
      final line = tester.getRect(
        find.byKey(const Key('notice_bar_time_left')),
      );
      expect(line.width, moreOrLessEquals(row.width));
      // Not cross-faded: one message on screen, never two.
      expect(find.byKey(const Key('notice_bar_saved')), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('the bar keeps its height and its side controls do not move '
        'in any state', (tester) async {
      await pumpBar(tester);
      Rect bar() => tester.getRect(find.byKey(const Key('bar')));
      Rect leading() => tester.getRect(find.byKey(const Key('leading')));
      Rect trailing() => tester.getRect(find.byKey(const Key('trailing')));
      final resting = (bar(), leading(), trailing());

      notices.show(
        Notice(
          id: 'undo',
          title: (_) => 'Cleared all tracks',
          action: NoticeAction(label: (_) => 'Undo', onPressed: () {}),
        ),
      );
      await _fadeIn(tester);
      expect((bar(), leading(), trailing()), resting);

      notices.raise(_lost());
      await tester.pumpAndSettle(const Duration(seconds: 9));
      expect(find.byKey(const Key('notice_bar_dot')), findsOneWidget);
      expect((bar(), leading(), trailing()), resting);
      expect(bar().height, 96);
    });

    testWidgets('a long message is cut short before it reaches a side group', (
      tester,
    ) async {
      await pumpBar(tester);
      notices.show(
        Notice(
          id: 'long',
          title: (_) => 'A message far too long for the room the bar has ' * 4,
          body: (_) => 'and its body',
        ),
      );
      await _fadeIn(tester);
      final row = tester.getRect(find.byKey(const Key('notice_bar_long')));
      final leading = tester.getRect(find.byKey(const Key('leading')));
      final trailing = tester.getRect(find.byKey(const Key('trailing')));
      expect(row.left, greaterThanOrEqualTo(leading.right + 24));
      expect(row.right, lessThanOrEqualTo(trailing.left - 24));
      expect(row.center.dx, moreOrLessEquals(960));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets("a passing message's action runs and stays a shortcut", (
      tester,
    ) async {
      var undone = 0;
      await pumpBar(tester);
      notices.show(
        Notice(
          id: 'undo',
          title: (_) => 'Cleared all tracks',
          action: NoticeAction(
            key: const Key('undo'),
            label: (_) => 'Undo',
            onPressed: () => undone++,
          ),
        ),
      );
      await _fadeIn(tester);
      final button = tester.getRect(find.byKey(const Key('undo')));
      expect(button.height, NoticeTheme.standard.barActionHeight);
      expect(
        button.center.dy,
        moreOrLessEquals(
          tester.getRect(find.byKey(const Key('bar'))).center.dy,
        ),
      );
      await tester.tap(find.byKey(const Key('undo')));
      expect(undone, 1);
      await tester.pumpAndSettle(const Duration(seconds: 9));
    });
  });

  testWidgets('a bar with no notice centre above it draws at rest', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A page pumped on its own, as the screenshot suites do.
    await tester.pumpApp(const _Bar());
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('session')), findsOneWidget);
  });

  group(NoticeBar, () {
    testWidgets('a must-act message tints the whole bar and rules it in its '
        'tone until it is cleared', (tester) async {
      var fixed = 0;
      await pumpBar(tester);
      const surface = SurfaceTheme.dark;
      Color rule() => tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(const Key('notice_bar_rule')),
              matching: find.byType(ColoredBox),
            ),
          )
          .color;
      expect(rule(), surface.line);

      notices.raise(_lost(onFix: () => fixed++));
      await tester.pumpAndSettle();
      final tint = tester.widget<AnimatedContainer>(
        find.byKey(const Key('notice_bar_tint')),
      );
      expect((tint.decoration as BoxDecoration?)?.color, surface.recTint);
      expect(rule(), surface.rec);
      expect(
        tester.getRect(find.byKey(const Key('notice_bar_rule'))).height,
        NoticeTheme.standard.ruleThickness,
      );
      expect(
        find.textContaining('Nothing is heard.', findRichText: true),
        findsOne,
      );
      await tester.tap(find.byKey(const Key('fix')));
      expect(fixed, 1);

      // Still standing a minute later.
      await tester.pump(const Duration(minutes: 1));
      expect(find.byKey(const Key('notice_bar_dot')), findsOneWidget);

      notices.clear('lost');
      await tester.pumpAndSettle();
      expect(rule(), surface.line);
      expect(find.byKey(const Key('session')), findsOneWidget);
    });

    testWidgets('a passing message takes the centre for its time, then the '
        'must-act message comes back', (tester) async {
      await pumpBar(tester);
      notices
        ..raise(_lost())
        ..show(_saved());
      await _fadeIn(tester);
      expect(find.text('Saved as Night set', findRichText: true), findsOne);
      expect(find.byKey(const Key('notice_bar_dot')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notice_bar_dot')), findsOneWidget);
    });

    testWidgets('nothing shows while the Power screen holds the notices', (
      tester,
    ) async {
      await pumpBar(tester);
      notices
        ..raise(_lost())
        ..setHeld(held: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session')), findsOneWidget);
      notices.setHeld(held: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notice_bar_dot')), findsOneWidget);
    });
  });

  group('track messages on a bar', () {
    Notice refused() => Notice(
      id: 'rec',
      tone: NoticeTone.warning,
      overline: (_) => 'Rec refused',
      title: (_) => 'Recording did not start',
      body: (_) => 'Press Record again',
    );

    testWidgets('a bar whose screen has no track cards says them after the '
        "track's name", (tester) async {
      await pumpBar(tester);
      notices.showOnTrack(1, refused());
      await _fadeIn(tester);
      expect(
        find.textContaining('TRACK 2', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Recording did not start', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 7));
    });

    testWidgets('the stage bar leaves them to the cards on screen', (
      tester,
    ) async {
      await pumpBar(tester, trackCards: (channel) => channel < 4);
      notices.showOnTrack(1, refused());
      await _fadeIn(tester);
      expect(find.byKey(const Key('session')), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets("and says the other bank's, whose cards are not", (
      tester,
    ) async {
      await pumpBar(tester, trackCards: (channel) => channel < 4);
      notices.showOnTrack(5, refused());
      await _fadeIn(tester);
      expect(
        find.textContaining('TRACK 6', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 7));
    });
  });
}
