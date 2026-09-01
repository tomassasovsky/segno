import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:daw_export/daw_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/performance/performance.dart';

import '../../helpers/helpers.dart';

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockPerformanceCompletionCubit
    extends MockCubit<PerformanceCompletionStatus>
    implements PerformanceCompletionCubit {}

class _MockPedalRepository extends Mock implements PedalRepository {}

/// Types [name] into the console rename sheet and confirms with Enter.
///
/// The sheet reads `KeyEvent.character`, so there is no field to `enterText`
/// into -- each character is sent as its own key event.
Future<void> typeSheetName(WidgetTester tester, String name) async {
  for (var i = 0; i < 60; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
  }
  for (final ch in name.split('')) {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
  }
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

void main() {
  late _MockPerformanceRecorderCubit cubit;
  late _MockPerformanceCompletionCubit completion;
  late _MockPedalRepository pedal;

  setUp(() {
    cubit = _MockPerformanceRecorderCubit();
    completion = _MockPerformanceCompletionCubit();
    pedal = _MockPedalRepository();
    when(
      () => pedal.events,
    ).thenAnswer((_) => const Stream<PedalEvent>.empty());
    whenListen(
      completion,
      const Stream<PerformanceCompletionStatus>.empty(),
      initialState: PerformanceCompletionStatus.active,
    );
  });

  Future<void> pump(WidgetTester tester, PerformanceRecorderState state) async {
    whenListen(
      cubit,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: state,
    );
    await tester.pumpApp(
      BlocProvider<PerformanceRecorderCubit>.value(
        value: cubit,
        child: BlocProvider<PerformanceCompletionCubit>.value(
          value: completion,
          child: const Scaffold(body: PerformanceCompletionSheet()),
        ),
      ),
    );
  }

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets('renders nothing when not Completed', (tester) async {
    await pump(tester, const PerformanceRecorderIdle());
    expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
  });

  testWidgets('renders nothing for a discarded-short completion (no result)', (
    tester,
  ) async {
    await pump(tester, const PerformanceRecorderCompleted.discardedShort());
    expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
  });

  testWidgets('a Done result shows no extra message, just the path', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);
    // The name rides inside the pen's subtitle sentence now, not on a bare
    // path line.
    expect(find.textContaining('perf-1'), findsOneWidget);
  });

  testWidgets('a Partial result shows the partial-failure message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordPartial('/exports/perf-2'),
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfPartial), findsOneWidget);
  });

  testWidgets('a StoppedEarly/diskFull result shows the disk-full message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordStoppedEarly(
          '/exports/perf-3',
          PerformanceStopReason.diskFull,
        ),
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfStoppedDiskFull), findsOneWidget);
  });

  testWidgets(
    'a StoppedEarly/deviceChanged result shows the device-change message',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordStoppedEarly(
            '/exports/perf-4',
            PerformanceStopReason.deviceChanged,
          ),
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfStoppedDeviceChange), findsOneWidget);
    },
  );

  testWidgets('the reveal button is present with a non-empty label', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    final reveal = tester.widget<ConsoleSmallButton>(
      find.byKey(const Key('perfCompletion_reveal')),
    );
    expect(find.byKey(const Key('perfCompletion_reveal')), findsOneWidget);
    expect(reveal.onPressed, isNotNull);
    // Portable across host platforms: assert SOME localized label renders
    // rather than pinning the exact macOS/Windows/other string.
    expect(reveal.label, isNotEmpty);
  });

  testWidgets('the rename button opens the rename dialog', (tester) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    await tester.tap(find.byKey(const Key('perfCompletion_rename')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
  });

  testWidgets(
    'submitting a valid name in the rename dialog calls '
    'renameCompletedCapture',
    (tester) async {
      when(
        () => cubit.renameCompletedCapture(any()),
      ).thenAnswer((_) async {});
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );

      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      await typeSheetName(tester, 'My Take');

      verify(() => cubit.renameCompletedCapture('My Take')).called(1);
    },
  );

  testWidgets(
    'renaming to the reserved "recovered" name shows the inline '
    'invalid-name error instead of a dead Save — the take would otherwise '
    "BECOME the boot salvage's recovered/ area (#679 r5)",
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      final strings = await l10n();

      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      await typeSheetName(tester, 'Recovered');

      // The console sheet has no inline-validator hook, so the guard runs
      // after it closes and reports through a SnackBar. What matters is that
      // the reserved name never reaches the cubit.
      expect(find.text(strings.perfRenameInvalid), findsOneWidget);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      verifyNever(() => cubit.renameCompletedCapture(any()));
    },
  );

  testWidgets(
    'a PerformanceNameCollision thrown by the cubit shows a SnackBar with '
    'the duplicate message',
    (tester) async {
      when(
        () => cubit.renameCompletedCapture(any()),
      ).thenThrow(const PerformanceNameCollision(slug: 'Taken'));
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      final strings = await l10n();

      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      await typeSheetName(tester, 'Taken');

      expect(find.text(strings.perfRenameDuplicate('Taken')), findsOneWidget);
    },
  );

  testWidgets(
    'no export summary is shown when the completed state has no tracks',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      expect(find.byKey(const Key('exportSummary')), findsNothing);
    },
  );

  testWidgets(
    'a live-plugin track shows its name and the live-plugins label',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [
            DawTrack(
              name: 'Track 0',
              deviceChain: [
                DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
              ],
            ),
          ],
        ),
      );
      final strings = await l10n();

      expect(find.byKey(const Key('exportSummary')), findsOneWidget);
      expect(find.text('Track 0'), findsOneWidget);
      expect(find.text(strings.perfExportTrackLive), findsOneWidget);
    },
  );

  testWidgets(
    'a bounced track with a fallback reason shows the bounced label and '
    'the specific reason',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [
            DawTrack(
              name: 'Track 1',
              deviceChainFallbackReason:
                  DeviceChainFallbackReason.mixedLaneChains,
            ),
          ],
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
      expect(find.text(strings.perfExportReasonMixedLanes), findsOneWidget);
    },
  );

  testWidgets(
    'a bounced track with no effects at all shows no fallback callout',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [DawTrack(name: 'Track 2', deviceChain: [])],
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
      expect(find.text(strings.perfExportReasonMixedLanes), findsNothing);
      expect(
        find.text(strings.perfExportReasonThirdPartyPlugin),
        findsNothing,
      );
      expect(
        find.text(strings.perfExportReasonUnrepresented),
        findsNothing,
      );
    },
  );

  testWidgets('the re-export button calls cubit.reExport when tapped', (
    tester,
  ) async {
    when(() => cubit.reExport()).thenAnswer((_) async {});
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    await tester.tap(find.byKey(const Key('perfCompletion_reExport')));
    await tester.pumpAndSettle();

    verify(() => cubit.reExport()).called(1);
  });

  testWidgets(
    'the re-export button is disabled while a re-export is in progress',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          isReExporting: true,
        ),
      );

      final button = tester.widget<ConsoleSmallButton>(
        find.byKey(const Key('perfCompletion_reExport')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('a failed re-export shows the failure message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
        reExportFailed: true,
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfExportReExportFailed), findsOneWidget);
  });

  testWidgets('a glitched Done capture shows the dropped-frames banner', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
        hadGlitch: true,
      ),
    );
    expect(find.text((await l10n()).perfCaptureGlitch), findsOneWidget);
  });

  testWidgets('a clean Done capture shows no banner', (tester) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );
    expect(find.byKey(const Key('perfCompletion_banner')), findsNothing);
  });

  testWidgets('the subtitle carries the track count and length', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
        tracks: [DawTrack(name: 'Track 0', deviceChain: [])],
        duration: Duration(minutes: 2, seconds: 14),
      ),
    );
    expect(
      find.text((await l10n()).perfSavedSubtitle('perf-1', 1, '2:14')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a trackless capture keeps its length, and a long one grows hours',
    (tester) async {
      // Finding: `tracks.isEmpty` used to throw the known duration away, and
      // a 75-minute set printed as `75:04`.
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-9'),
          duration: Duration(hours: 1, minutes: 15, seconds: 4),
        ),
      );
      expect(
        find.text((await l10n()).perfSavedSubtitleTimed('perf-9', '1:15:04')),
        findsOneWidget,
      );
    },
  );

  group('the dialog route', () {
    late StreamController<PerformanceRecorderState> states;

    setUp(() {
      states = StreamController<PerformanceRecorderState>.broadcast();
    });

    tearDown(() => states.close());

    // A host page whose context can open the dialog, with a cubit whose
    // state the test drives through [states].
    Future<BuildContext> host(
      WidgetTester tester,
      PerformanceRecorderState initial,
    ) async {
      whenListen(cubit, states.stream, initialState: initial);
      late BuildContext hostContext;
      await tester.pumpApp(
        RepositoryProvider<PedalRepository>.value(
          value: pedal,
          child: BlocProvider<PerformanceRecorderCubit>.value(
            value: cubit,
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  hostContext = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      return hostContext;
    }

    testWidgets('a render in progress draws the rendering face', (
      tester,
    ) async {
      final strings = await l10n();
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 62, name: 'perf-1'),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsOneWidget);
      expect(find.text(strings.perfRenderingTitle(62)), findsOneWidget);

      await tester.tap(find.byKey(const Key('perfRendering_hide')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
    });

    testWidgets('the rendering face morphs into the saved face in place', (
      tester,
    ) async {
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 10),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      states.add(
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
      expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);
    });

    testWidgets('a second open while the dialog is up is refused', (
      tester,
    ) async {
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 10),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsOneWidget);
    });

    testWidgets('the dialog can reopen while its exit animation runs', (
      tester,
    ) async {
      // Regression: the double-open flag must clear at pop INITIATION, not
      // after the exit transition — a Completed landing during Hide's
      // animation reopens the result, and nothing else ever would.
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 90),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('perfRendering_hide')));
      await tester.pump(const Duration(milliseconds: 20)); // mid-exit
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsOneWidget);
    });

    testWidgets('a foreign state pops the dialog instead of lingering', (
      tester,
    ) async {
      // Regression: the pedal can arm straight through the repository while
      // a render is up; a dialog that only stopped drawing would leave the
      // barrier dimming a dead stage.
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 40),
      );
      // The page route owns a barrier of its own; the dialog's is the extra.
      final barriers = find.byType(ModalBarrier).evaluate().length;
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();

      states.add(const PerformanceRecorderIdle());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
      expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
      expect(find.byType(ModalBarrier).evaluate().length, barriers);
    });

    testWidgets(
      'a foreign state after the dialog already left leaves the home '
      'route alone',
      (tester) async {
        // Regression (#712): the operator's Done/Hide races a pedal-side
        // state change — the listener still fires while the dialog route is
        // animating out, and an unconditional pop removed the HOME route
        // (black stage). Not-current means already leaving: correct no-op.
        final context = await host(
          tester,
          const PerformanceRecorderRendering(percent: 40),
        );
        unawaited(showPerformanceCompletionSheet(context));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('perfRendering_hide')));
        await tester.pump(const Duration(milliseconds: 20)); // mid-exit

        states.add(const PerformanceRecorderIdle());
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
        expect(
          find.byType(Scaffold),
          findsOneWidget,
          reason: 'the home route must survive the foreign state',
        );
      },
    );

    testWidgets(
      'two foreign states in quick succession pop once, not the home route',
      (tester) async {
        // Regression (#712): the first foreign state pops the dialog; the
        // second used to pop again during the exit transition (home route),
        // and on an emptied navigator threw `Bad state: No element`.
        final context = await host(
          tester,
          const PerformanceRecorderRendering(percent: 40),
        );
        final barriers = find.byType(ModalBarrier).evaluate().length;
        unawaited(showPerformanceCompletionSheet(context));
        await tester.pumpAndSettle();

        states
          ..add(const PerformanceRecorderIdle())
          ..add(const PerformanceRecorderCompleted.discardedShort());
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
        expect(
          find.byType(Scaffold),
          findsOneWidget,
          reason: 'only the dialog route may go',
        );
        expect(find.byType(ModalBarrier).evaluate().length, barriers);
      },
    );

    testWidgets('teardown without a pop still releases the double-open flag', (
      tester,
    ) async {
      // Regression: the future-side clear never runs when the tree dies
      // without a pop; dispose must release the flag or no capture dialog
      // ever opens again this process.
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 40),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink()); // die, no pop

      final again = await host(
        tester,
        const PerformanceRecorderRendering(percent: 41),
      );
      unawaited(showPerformanceCompletionSheet(again));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('perfRendering_dialog')), findsOneWidget);
    });

    testWidgets('the saved face shrinks instead of filling the screen', (
      tester,
    ) async {
      final context = await host(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();
      final size = tester.getSize(
        find.byKey(const Key('perfCompletion_sheet')),
      );
      final viewport = tester.getSize(find.byType(MaterialApp));
      expect(size.height, lessThan(viewport.height));
    });

    testWidgets('the rendering face shrinks instead of filling the screen', (
      tester,
    ) async {
      final context = await host(
        tester,
        const PerformanceRecorderRendering(percent: 40),
      );
      unawaited(showPerformanceCompletionSheet(context));
      await tester.pumpAndSettle();
      final size = tester.getSize(
        find.byKey(const Key('perfRendering_dialog')),
      );
      final viewport = tester.getSize(find.byType(MaterialApp));
      expect(size.height, lessThan(viewport.height));
    });
  });

  group('dismiss', () {
    StreamController<PerformanceCompletionStatus> statuses() {
      final controller =
          StreamController<PerformanceCompletionStatus>.broadcast();
      addTearDown(controller.close);
      return controller;
    }

    Future<void> openSheet(
      WidgetTester tester, {
      required PerformanceRecorderState state,
      Stream<PerformanceCompletionStatus>? statuses,
    }) async {
      whenListen(
        cubit,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: state,
      );
      whenListen(
        completion,
        statuses ?? const Stream<PerformanceCompletionStatus>.empty(),
        initialState: PerformanceCompletionStatus.active,
      );
      await tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MultiBlocProvider(
                  providers: [
                    BlocProvider<PerformanceRecorderCubit>.value(value: cubit),
                    BlocProvider<PerformanceCompletionCubit>.value(
                      value: completion,
                    ),
                  ],
                  child: const PerformanceCompletionSheet(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a footswitch request pops the saved face', (tester) async {
      final requested = statuses();
      await openSheet(
        tester,
        state: const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
        statuses: requested.stream,
      );

      requested.add(PerformanceCompletionStatus.dismissalRequested);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a footswitch request pops the rendering face', (tester) async {
      final requested = statuses();
      await openSheet(
        tester,
        state: const PerformanceRecorderRendering(percent: 40),
        statuses: requested.stream,
      );

      requested.add(PerformanceCompletionStatus.dismissalRequested);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('perfRendering_dialog')), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('pops a stacked rename sheet too', (tester) async {
      final requested = statuses();
      await openSheet(
        tester,
        state: const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
        statuses: requested.stream,
      );
      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);

      requested.add(PerformanceCompletionStatus.dismissalRequested);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a request racing a barrier dismissal preserves home', (
      tester,
    ) async {
      final requested = statuses();
      await openSheet(
        tester,
        state: const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
        statuses: requested.stream,
      );
      final route = ModalRoute.of(
        tester.element(find.byKey(const Key('perfCompletion_sheet'))),
      )!;

      await tester.tapAt(const Offset(1, 1));
      await tester.pump();
      expect(route.isCurrent, isFalse);
      requested.add(PerformanceCompletionStatus.dismissalRequested);
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);
    });
  });
}
