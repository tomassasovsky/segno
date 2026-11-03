import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/notices/notices.dart';

Notice _recovery() => Notice(
  id: AppNoticeId.mixSettings,
  tone: NoticeTone.critical,
  title: (_) => 'Mix settings need a retry',
);

void main() {
  group('retryNoticeAction', () {
    late NoticesCubit notices;

    setUp(() {
      notices = NoticesCubit();
      addTearDown(notices.close);
    });

    test('ends the message when the retry worked', () async {
      notices.raise(_recovery());
      final retry = retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () async => true,
      );
      retry.onPressed();
      await pumpEventQueue();
      expect(notices.state.banners, isEmpty);
    });

    test('keeps it when the retry failed', () async {
      notices.raise(_recovery());
      retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () async => false,
      ).onPressed();
      await pumpEventQueue();
      expect(notices.state.banners, hasLength(1));
    });

    test('keeps a newer failure raised while the retry ran', () async {
      notices.raise(_recovery());
      final done = Completer<bool>();
      retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () => done.future,
      ).onPressed();
      notices.raise(_recovery());
      done.complete(true);
      await pumpEventQueue();
      expect(notices.state.banners, hasLength(1));
    });
  });
}
