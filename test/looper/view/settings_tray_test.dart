import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/tray/tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/tuner/view/tuner_tray_panel.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsTrayCubit cubit;
  late LooperRepository looper;
  late TunerCubit tunerCubit;
  late InputsCubit inputsCubit;

  setUp(() {
    final settings = SettingsRepository(store: FakeKeyValueStore());
    cubit = SettingsTrayCubit();
    looper = LooperRepository(engine: FakeAudioEngine());
    tunerCubit = TunerCubit(repository: looper);
    inputsCubit = InputsCubit(settings: settings, repository: looper);
  });
  tearDown(() async {
    await cubit.close();
    await tunerCubit.close();
    await inputsCubit.close();
    unawaited(looper.dispose());
  });

  Future<void> pump(WidgetTester tester, {VoidCallback? onStageTap}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepositoryProvider<LooperRepository>.value(
            value: looper,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsTrayCubit>.value(value: cubit),
                BlocProvider<TunerCubit>.value(value: tunerCubit),
                BlocProvider<InputsCubit>.value(value: inputsCubit),
              ],
              // A Scaffold + Stack mirrors how TracksView actually mounts the
              // tray: as a Stack sibling over full-screen content, top edge
              // at (0, 0).
              child: Scaffold(
                body: Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onStageTap,
                      child: const SizedBox.expand(),
                    ),
                    const SettingsTray(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('renders the always-visible handle', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('settingsTray_handle')), findsOneWidget);
  });

  testWidgets('renders the scrim', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('settingsTray_scrim')), findsOneWidget);
  });

  testWidgets('tapping the handle opens a closed tray', (tester) async {
    await pump(tester);
    expect(cubit.state.dragProgress, 0);

    await tester.tap(find.byKey(const Key('settingsTray_handle')));
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 1);
  });

  testWidgets('tapping the handle closes an open tray', (tester) async {
    cubit.open();
    await pump(tester);
    await tester.pump();

    await tester.tap(find.byKey(const Key('settingsTray_handle')));
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 0);
  });

  testWidgets('dragging the handle down past the threshold opens the tray', (
    tester,
  ) async {
    await pump(tester);
    expect(cubit.state.dragProgress, 0);

    // Past 50% of the tray's reveal height — well past (the drag helper
    // delivers the offset over several synthetic pointer moves, and only the
    // net displacement needs to clear the threshold); the tray is
    // near-fullscreen (test surface height 600 - 24 = 576), so 500px clears
    // the 288px halfway point.
    await tester.drag(
      find.byKey(const Key('settingsTray_handle')),
      const Offset(0, 500),
    );
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 1);
  });

  testWidgets('dragging the handle down under the threshold settles closed', (
    tester,
  ) async {
    await pump(tester);

    await tester.drag(
      find.byKey(const Key('settingsTray_handle')),
      const Offset(0, 40),
    );
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 0);
  });

  testWidgets('dragging the handle up closes an open tray', (tester) async {
    cubit.open();
    await pump(tester);
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('settingsTray_handle')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(cubit.state.dragProgress, 0);
  });

  for (final progress in [0.5, 1.0]) {
    testWidgets('background taps keep a $progress revealed tray open', (
      tester,
    ) async {
      var stageTaps = 0;
      cubit.dragTo(progress);
      await pump(tester, onStageTap: () => stageTaps++);
      await tester.pumpAndSettle();

      final screen = tester.getRect(find.byType(Scaffold));
      // At half reveal these points hit the exposed scrim below the handle;
      // at full reveal they hit empty panel space above the handle. Neither
      // may dismiss the tray or activate the stage underneath it.
      for (final point in [
        Offset(screen.right - 5, screen.bottom - 50),
        Offset(screen.center.dx, screen.bottom - 50),
      ]) {
        expect(
          tester
              .getRect(find.byKey(const Key('settingsTray_handle')))
              .contains(point),
          isFalse,
        );
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(cubit.state.dragProgress, progress);
        expect(stageTaps, 0);
      }
    });
  }

  testWidgets('the handle exposes a labelled working close action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      cubit.open();
      await pump(tester);
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final handle = find.byKey(const Key('settingsTray_handle'));
      final node = tester.getSemantics(handle);
      expect(node.label, l10n.close);
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      // The inert backdrop is not announced as a second dismiss button.
      expect(find.bySemanticsLabel(l10n.dismiss), findsNothing);
      expect(find.bySemanticsLabel(l10n.close), findsOneWidget);

      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(cubit.state.dragProgress, 0);
      expect(tester.getSemantics(handle).label, l10n.a11yTrayHandle);
    } finally {
      semantics.dispose();
    }
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('the focused handle closes the tray with ${key.debugName}', (
      tester,
    ) async {
      cubit.open();
      await pump(tester);
      await tester.pumpAndSettle();

      final pill = find.descendant(
        of: find.byKey(const Key('settingsTray_handle')),
        matching: find.byType(AnimatedContainer),
      );
      Focus.of(tester.element(pill)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();

      expect(cubit.state.dragProgress, 0);
    });
  }

  testWidgets('the closed scrim lets taps reach the stage', (tester) async {
    var stageTaps = 0;
    await pump(tester, onStageTap: () => stageTaps++);

    await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
    await tester.pump();

    expect(cubit.state.dragProgress, 0);
    expect(stageTaps, 1);
    expect(tester.takeException(), isNull);
  });

  group('the sheet', () {
    /// The sheet's own [BoxDecoration] — the shadow is the only thing on this
    /// surface with no text or geometry to assert on, so it is read directly.
    BoxShadow shadowOf(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(TrayPanel),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (box.decoration as BoxDecoration).boxShadow!.single;
    }

    testWidgets('casts no shadow while closed — its bottom edge is parked on '
        'the top of the screen, and a shadow there is a dark band over the '
        'stage that never goes away', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();

      expect(cubit.state.dragProgress, 0);
      expect(shadowOf(tester).color.a, 0);
    });

    testWidgets('the shadow arrives WITH the slide, not at the end of it', (
      tester,
    ) async {
      await pump(tester);
      cubit.dragTo(0.5);
      await tester.pump();
      await tester.pumpAndSettle();

      final midway = shadowOf(tester).color.a;
      expect(midway, greaterThan(0));

      cubit.open();
      await tester.pumpAndSettle();
      expect(shadowOf(tester).color.a, greaterThan(midway));
    });

    testWidgets('the shadow TRACKS the slide on a tap, rather than snapping '
        'ahead of it — a tap moves dragProgress between 0 and 1 in one '
        'frame while the sheet takes 220ms to get there', (tester) async {
      await pump(tester);
      cubit.open();
      await tester.pumpAndSettle();
      final open = shadowOf(tester).color.a;
      expect(open, greaterThan(0));

      // Closing: the sheet is still fully on screen for the whole slide, so
      // the shadow under it has to still be there part-way through. Reading
      // `dragProgress` straight off the cubit drops it to zero on frame one.
      cubit.closeTray();
      // Three frames, and each earns its place: the first delivers the
      // cubit's emit, the second is the fade's own first frame, and only
      // then is there an animation to advance halfway.
      await tester.pump();
      await tester.pump();
      await tester.pump(kTrayMotion ~/ 2);

      final sliding = shadowOf(tester).color.a;
      expect(sliding, greaterThan(0));
      expect(sliding, lessThan(open));

      await tester.pumpAndSettle();
      expect(shadowOf(tester).color.a, 0);
    });

    testWidgets('is opaque: the stage never shows through the settings being '
        'read', (tester) async {
      await pump(tester);
      cubit.open();
      await tester.pumpAndSettle();

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(TrayPanel),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).color!.a, 1);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('the tuner', () {
    testWidgets('is the only face: the open sheet shows it directly', (
      tester,
    ) async {
      cubit.open();
      await pump(tester);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(TrayPanel),
          matching: find.byKey(const Key('tuner_tray_panel')),
        ),
        findsOneWidget,
      );
      expect(find.byType(TunerTrayPanel), findsOneWidget);
    });

    testWidgets('a closed tray neither builds nor arms it', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();

      expect(cubit.state.dragProgress, 0);
      expect(find.byType(TunerTrayPanel), findsNothing);
      expect(tunerCubit.state.isOpen, isFalse);
    });

    testWidgets('tapping the handle arms the tuner; closing disarms it at '
        'once and drops the face once the sheet is up', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('settingsTray_handle')));
      await tester.pumpAndSettle();
      expect(tunerCubit.state.isOpen, isTrue);

      await tester.tap(find.byKey(const Key('settingsTray_handle')));
      await tester.pump();
      await tester.pump(kTrayMotion ~/ 2);
      // Still on its way up: the face stays drawn, but no longer listens.
      expect(find.byType(TunerTrayPanel), findsOneWidget);
      expect(tunerCubit.state.isOpen, isFalse);

      await tester.pumpAndSettle();
      expect(find.byType(TunerTrayPanel), findsNothing);
    });

    testWidgets('a drag arms it from the first frame the sheet shows', (
      tester,
    ) async {
      await pump(tester);
      cubit.dragTo(0.2);
      await tester.pump();
      expect(tunerCubit.state.isOpen, isTrue);

      cubit.settleFromDrag();
      await tester.pumpAndSettle();
      expect(cubit.state.dragProgress, 0);
      expect(tunerCubit.state.isOpen, isFalse);
    });
  });

  testWidgets('every tap target is labeled (labeledTapTargetGuideline)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    cubit.open();
    await pump(tester);
    await tester.pump();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
