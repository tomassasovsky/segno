import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/performance/performance.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

void main() {
  group('PerformanceAutoStopNotice (#1767)', () {
    late _MockPerformanceRecorderCubit recorder;
    late IdleDimCubit idle;
    late NoticesCubit notices;
    late StreamController<PerformanceRecorderState> states;
    late NoticeLog said;

    setUp(() {
      recorder = _MockPerformanceRecorderCubit();
      states = StreamController<PerformanceRecorderState>.broadcast();
      whenListen(
        recorder,
        states.stream,
        initialState: const PerformanceRecorderIdle(),
      );
      idle = IdleDimCubit(
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
      notices = NoticesCubit();
      said = NoticeLog(notices);
    });

    tearDown(() async {
      await said.close();
      await states.close();
      await idle.close();
      await notices.close();
    });

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
          BlocProvider.value(value: idle),
        ],
        child: const PerformanceAutoStopNotice(child: SizedBox.shrink()),
      ),
      notices: notices,
    );

    PerformanceRecorderCompleted stopped(PerformanceStopReason reason) =>
        PerformanceRecorderCompleted(
          PerformanceRecordStoppedEarly('/exports/perf-1', reason),
        );

    for (final (reason, title) in const [
      (
        PerformanceStopReason.idle,
        'Capture stopped after 20 idle minutes.',
      ),
      (
        PerformanceStopReason.lengthLimit,
        'Capture reached its longest length.',
      ),
    ]) {
      testWidgets('a take that stopped on its own ($reason) is said when the '
          'player comes back, not before', (tester) async {
        await pump(tester);
        states.add(stopped(reason));
        await tester.pump();
        expect(said.shown, isEmpty, reason: 'nobody is there yet');

        idle.activity();
        await tester.pump();

        expect(said.titles, [title]);
        final notice = said.shown.single;
        expect(notice.id, AppNoticeId.performance);
        expect(notice.tone, NoticeTone.warning);
        final en = lookupAppLocalizations(const Locale('en'));
        expect(notice.body!(en), 'Everything recorded is kept.');

        idle.activity();
        await tester.pump();
        expect(said.shown, hasLength(1), reason: 'said once');
        await tester.pump(const Duration(seconds: 10));
      });
    }

    testWidgets('a take stopped for any other reason waits for nobody', (
      tester,
    ) async {
      await pump(tester);
      states.add(stopped(PerformanceStopReason.reserveReached));
      await tester.pump();
      idle.activity();
      await tester.pump();
      expect(said.shown, isEmpty);
    });

    testWidgets('a new capture before the player comes back forgets it', (
      tester,
    ) async {
      await pump(tester);
      states.add(stopped(PerformanceStopReason.idle));
      await tester.pump();
      states.add(
        const PerformanceRecorderArmed(elapsed: Duration.zero, overrun: false),
      );
      await tester.pump();
      idle.activity();
      await tester.pump();
      expect(said.shown, isEmpty);
    });
  });
}
