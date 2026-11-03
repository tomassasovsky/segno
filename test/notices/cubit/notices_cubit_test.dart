import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';

Notice _notice(
  String id, {
  NoticeTone tone = NoticeTone.neutral,
  NoticeAction? action,
  bool explains = false,
}) => Notice(
  id: id,
  title: (_) => id,
  tone: tone,
  action: action,
  explains: explains,
);

void main() {
  group(NoticesCubit, () {
    test('starts with nothing on screen', () async {
      final cubit = NoticesCubit();
      expect(cubit.state, const NoticesState());
      expect(cubit.state.banner, isNull);
      expect(cubit.state.latestTrackMessage, isNull);
      await cubit.close();
    });

    group('durations', () {
      test('four seconds for a neutral or success message', () {
        expect(_notice('a').duration, const Duration(seconds: 4));
        expect(
          _notice('a', tone: NoticeTone.success).duration,
          const Duration(seconds: 4),
        );
      });

      test('six for a warning, eight with an action, ten to explain', () {
        expect(
          _notice('a', tone: NoticeTone.warning).duration,
          const Duration(seconds: 6),
        );
        expect(
          _notice(
            'a',
            tone: NoticeTone.warning,
            action: NoticeAction(label: (_) => 'Undo', onPressed: () {}),
          ).duration,
          const Duration(seconds: 8),
        );
        expect(
          _notice('a', explains: true).duration,
          const Duration(seconds: 10),
        );
      });
    });

    group('show', () {
      test('a message goes by itself after its duration', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..show(_notice('saved', tone: NoticeTone.success));
          expect(cubit.state.message?.notice.id, 'saved');
          async.elapse(const Duration(milliseconds: 3999));
          expect(cubit.state.message, isNotNull);
          async.elapse(const Duration(milliseconds: 1));
          expect(cubit.state.message, isNull);
          unawaited(cubit.close());
        });
      });

      test('the newest message replaces the last, with no queue', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..show(_notice('first'))
            ..show(_notice('second', tone: NoticeTone.warning));
          expect(cubit.state.message?.notice.id, 'second');
          async.elapse(const Duration(seconds: 6));
          // The first never comes back.
          expect(cubit.state.message, isNull);
          unawaited(cubit.close());
        });
      });

      test('the same id again restarts its time', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()..show(_notice('saved'));
          final first = cubit.state.message!;
          async.elapse(const Duration(seconds: 3));
          cubit.show(_notice('saved'));
          final second = cubit.state.message!;
          expect(second.serial, greaterThan(first.serial));
          expect(second.notice.id, first.notice.id);
          async.elapse(const Duration(seconds: 3));
          expect(cubit.state.message, isNotNull);
          async.elapse(const Duration(seconds: 1));
          expect(cubit.state.message, isNull);
          unawaited(cubit.close());
        });
      });

      test('one-time explanations wait for each other, so none is lost', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..show(_notice('bluetooth', explains: true))
            ..show(_notice('boot mode', explains: true))
            ..show(_notice('tuner', explains: true));
          expect(cubit.state.message?.notice.id, 'bluetooth');
          async.elapse(const Duration(seconds: 10));
          expect(cubit.state.message?.notice.id, 'boot mode');
          async.elapse(const Duration(seconds: 10));
          expect(cubit.state.message?.notice.id, 'tuner');
          async.elapse(const Duration(seconds: 10));
          expect(cubit.state.message, isNull);
          unawaited(cubit.close());
        });
      });

      test('a press replaces an explanation, and the waiting ones still '
          'come after it', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..show(_notice('bluetooth', explains: true))
            ..show(_notice('tuner', explains: true))
            ..show(_notice('refused', tone: NoticeTone.warning));
          expect(cubit.state.message?.notice.id, 'refused');
          async.elapse(const Duration(seconds: 6));
          expect(cubit.state.message?.notice.id, 'tuner');
          unawaited(cubit.close());
        });
      });

      test('a message with the id of a must-act message is dropped', () {
        final cubit = NoticesCubit()
          ..raise(_notice('mix', tone: NoticeTone.critical))
          ..show(_notice('mix', tone: NoticeTone.warning));
        expect(cubit.state.message, isNull);
        expect(cubit.state.banner?.notice.id, 'mix');
        addTearDown(cubit.close);
      });
    });

    group('showOnTrack', () {
      test('routes the message to its track and leaves the bar alone', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..showOnTrack(1, _notice('rec', tone: NoticeTone.warning));
          expect(cubit.state.message, isNull);
          expect(cubit.state.trackMessage(1)?.notice.id, 'rec');
          expect(cubit.state.trackMessage(0), isNull);
          async.elapse(const Duration(seconds: 6));
          expect(cubit.state.trackMessage(1), isNull);
          unawaited(cubit.close());
        });
      });

      test('each track keeps its own message and its own time', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..showOnTrack(0, _notice('a', tone: NoticeTone.warning));
          async.elapse(const Duration(seconds: 3));
          cubit.showOnTrack(2, _notice('b', tone: NoticeTone.warning));
          expect(cubit.state.latestTrackMessage?.channel, 2);
          async.elapse(const Duration(seconds: 3));
          expect(cubit.state.trackMessage(0), isNull);
          expect(cubit.state.trackMessage(2)?.notice.id, 'b');
          async.elapse(const Duration(seconds: 3));
          expect(cubit.state.trackMessage(2), isNull);
          unawaited(cubit.close());
        });
      });

      test('a newer message on the same track replaces the older', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..showOnTrack(0, _notice('a', tone: NoticeTone.warning));
          async.elapse(const Duration(seconds: 5));
          cubit.showOnTrack(0, _notice('b', tone: NoticeTone.warning));
          async.elapse(const Duration(seconds: 2));
          // The first's timer must not end the second.
          expect(cubit.state.trackMessage(0)?.notice.id, 'b');
          async.elapse(const Duration(seconds: 4));
          expect(cubit.state.trackMessage(0), isNull);
          unawaited(cubit.close());
        });
      });
    });

    group('raise and clear', () {
      test('a must-act message stays until it is cleared', () {
        fakeAsync((async) {
          final cubit = NoticesCubit()
            ..raise(_notice('lost', tone: NoticeTone.critical));
          async.elapse(const Duration(minutes: 5));
          expect(cubit.state.banner?.notice.id, 'lost');
          cubit.clear('lost');
          expect(cubit.state.banner, isNull);
          unawaited(cubit.close());
        });
      });

      test('critical outranks warning, then the newest wins', () {
        final cubit = NoticesCubit()
          ..raise(_notice('fx', tone: NoticeTone.warning))
          ..raise(_notice('lost', tone: NoticeTone.critical))
          ..raise(_notice('monitor', tone: NoticeTone.warning));
        expect(cubit.state.banner?.notice.id, 'lost');
        cubit.clear('lost');
        expect(cubit.state.banner?.notice.id, 'monitor');
        cubit.clear('monitor');
        expect(cubit.state.banner?.notice.id, 'fx');
        addTearDown(cubit.close);
      });

      test('raising ends the passing message with its id', () {
        final cubit = NoticesCubit()
          ..show(_notice('mix', tone: NoticeTone.warning))
          ..showOnTrack(1, _notice('mix', tone: NoticeTone.warning))
          ..raise(_notice('mix', tone: NoticeTone.critical));
        expect(cubit.state.message, isNull);
        expect(cubit.state.trackMessage(1), isNull);
        addTearDown(cubit.close);
      });

      test('raising again replaces the standing one', () {
        final cubit = NoticesCubit()
          ..raise(_notice('lost', tone: NoticeTone.critical))
          ..raise(
            Notice(
              id: 'lost',
              title: (_) => 'again',
              tone: NoticeTone.critical,
            ),
          );
        expect(cubit.state.banners, hasLength(1));
        expect(
          cubit.state.banner?.notice.title(
            lookupAppLocalizations(const Locale('en')),
          ),
          'again',
        );
        addTearDown(cubit.close);
      });

      test('clear ends a passing message too, and emits nothing when '
          'nothing has the id', () async {
        final cubit = NoticesCubit()..show(_notice('saved'));
        final emitted = <NoticesState>[];
        final sub = cubit.stream.listen(emitted.add);
        cubit
          ..clear('other')
          ..clear('saved');
        await Future<void>.delayed(Duration.zero);
        expect(emitted, hasLength(1));
        expect(cubit.state.message, isNull);
        await sub.cancel();
        await cubit.close();
      });
    });

    group('setHeld', () {
      test('drops passing messages and keeps must-act ones behind it', () {
        final cubit = NoticesCubit()
          ..show(_notice('saved'))
          ..showOnTrack(0, _notice('rec', tone: NoticeTone.warning))
          ..raise(_notice('lost', tone: NoticeTone.critical))
          ..setHeld(held: true);
        expect(cubit.state.message, isNull);
        expect(cubit.state.trackMessage(0), isNull);
        expect(cubit.state.banner, isNull);
        cubit
          ..show(_notice('later'))
          ..showOnTrack(1, _notice('later', tone: NoticeTone.warning));
        expect(cubit.state.message, isNull);
        expect(cubit.state.tracks, isEmpty);
        cubit.setHeld(held: false);
        expect(cubit.state.banner?.notice.id, 'lost');
        expect(cubit.state.message, isNull);
        addTearDown(cubit.close);
      });
    });
  });
}
