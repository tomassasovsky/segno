@Tags(['screenshots'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// The notice system (#1562) on the surfaces the stage suite does not draw:
/// a settings page's top bar and the readout's band. Rendered with
///
///   flutter test --tags screenshots --update-goldens \
///     test/screenshots/notices_screenshots_test.dart
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFonts();
  });

  late NoticesCubit notices;

  setUp(() => notices = NoticesCubit());
  tearDown(() => notices.close());

  Future<void> canvas(WidgetTester tester, Size size) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpFrame(WidgetTester tester) async {
    await canvas(tester, const Size(1920, 1080));
    final tracks = TracksCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    addTearDown(tracks.close);
    await tracks.rename(1, 'BOOM');
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: notices),
            BlocProvider.value(value: tracks),
          ],
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: LoopSettingsFrame(
            title: 'Displays',
            crumb: 'Settings / Displays',
            onBack: () {},
            onStage: () {},
            children: const [],
          ),
        ),
      ),
    );
  }

  Future<void> shoot(WidgetTester tester, Finder finder, String name) async {
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(finder, matchesGoldenFile('goldens/notice_$name.png'));
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('a settings page: a passing message', (tester) async {
    await pumpFrame(tester);
    notices.show(
      Notice(
        id: 'brightness',
        tone: NoticeTone.warning,
        title: (_) => "Couldn't save",
        body: (_) => 'The brightness applies until a restart',
      ),
    );
    await shoot(tester, find.byType(LoopSettingsFrame), 'settings_message');
  }, skip: !rendersScreenshots);

  testWidgets("a settings page: a track's message names the track", (
    tester,
  ) async {
    await pumpFrame(tester);
    notices.showOnTrack(
      1,
      Notice(
        id: 'rec',
        tone: NoticeTone.warning,
        overline: (_) => 'Rec refused',
        title: (_) => 'Recording did not start',
        body: (_) => 'Press Record again',
      ),
    );
    await shoot(tester, find.byType(LoopSettingsFrame), 'settings_track');
  }, skip: !rendersScreenshots);

  testWidgets('a settings page: a must-act message', (tester) async {
    await pumpFrame(tester);
    notices.raise(
      Notice(
        id: 'lost',
        tone: NoticeTone.critical,
        title: (_) => 'Scarlett 4i4 disconnected. Nothing is heard.',
        action: NoticeAction(label: (_) => 'Open setup', onPressed: () {}),
      ),
    );
    await shoot(tester, find.byType(LoopSettingsFrame), 'settings_must_act');
  }, skip: !rendersScreenshots);

  for (final (name, size) in const [
    ('1080', Size(1920, 1080)),
    ('7in', Size(1024, 600)),
  ]) {
    for (final (kind, notice) in const [
      (
        'critical',
        ReadoutNotice(
          title: 'Scarlett 4i4 disconnected. Nothing is heard.',
          tone: NoticeTone.critical,
        ),
      ),
      (
        'track',
        ReadoutNotice(
          title: 'Recording did not start',
          body: 'Press Record again',
          tone: NoticeTone.warning,
          track: 'BOOM',
        ),
      ),
    ]) {
      testWidgets('the readout band, $kind, $name', (tester) async {
        await canvas(tester, size);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ConsoleReadoutView(
                readout: PerformanceReadout(
                  selected: const ReadoutTrack(
                    channel: 0,
                    name: 'GUITAR',
                    state: 'empty',
                  ),
                  tempoBpm: 84,
                  hasTempo: true,
                  notice: notice,
                ),
                waveform: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(ConsoleReadoutView),
          matchesGoldenFile('goldens/notice_readout_${kind}_$name.png'),
        );
      }, skip: !rendersScreenshots);
    }
  }
}
