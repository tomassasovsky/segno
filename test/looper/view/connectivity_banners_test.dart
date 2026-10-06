import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show EngineReopened, EngineStatus, LooperState, ReopenOutcome;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockSessionRepository extends Mock implements SessionRepository {}

/// The device-lost coverage (#453), written against the persistent surface
/// that replaces the D1 lost-toast. Only the AUDIO interface has a standing
/// banner: a lost MIDI controller is a transient toast (loops keep playing),
/// tested in `app_test`, and never a bar here.
void main() {
  const deviceKey = Key('connectivity_banner_device');

  const deviceLostState = AudioSetupState(
    deviceConnectivity: DeviceConnectivity.lost,
    connectivityDeviceName: 'Scarlett 2i2',
  );

  late AppLocalizations l10n;
  late _MockAudioSetupCubit audioSetup;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    audioSetup = _MockAudioSetupCubit();
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: const AudioSetupState(),
    );
  });

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: audioSetup),
      ],
      child: const Scaffold(body: ConnectivityBanners()),
    ),
  );

  SurfaceTheme surface(WidgetTester tester) => Theme.of(
    tester.element(find.byType(ConnectivityBanners)),
  ).extension<SurfaceTheme>()!;

  BoxDecoration decorationOf(WidgetTester tester, Key key) {
    final container = tester.widget<Container>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Container))
          .first,
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('renders nothing while nothing is lost', (tester) async {
    await pump(tester);

    expect(find.byKey(deviceKey), findsNothing);
  });

  group('material cleared on reconnect (#1140)', () {
    const materialKey = Key('connectivity_banner_material');
    const clearedState = AudioSetupState(
      deviceConnectivity: DeviceConnectivity.restoredCleared,
      connectivityDeviceName: 'Scarlett 2i2',
      engineStatus: EngineStatus(
        reopen: EngineReopened(
          outcome: ReopenOutcome.clearedRate,
          droppedTracks: 0,
          previousSampleRate: 48000,
          sampleRate: 44100,
        ),
      ),
    );

    testWidgets(
      'holds a standing banner naming both rates with the Library action',
      (tester) async {
        whenListen(
          audioSetup,
          const Stream<AudioSetupState>.empty(),
          initialState: clearedState,
        );
        await pump(tester);

        expect(find.byKey(materialKey), findsOneWidget);
        expect(find.byKey(deviceKey), findsNothing);
        expect(
          find.text(l10n.deviceRestoredClearedBanner(44100, 48000)),
          findsOneWidget,
        );
        expect(find.text(l10n.stageLibrary), findsOneWidget);
        await tester.pump(const Duration(seconds: 30));
        expect(find.byKey(materialKey), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        final s = surface(tester);
        expect(decorationOf(tester, materialKey).color, s.recTint);
      },
    );

    testWidgets('a cap mismatch names the limit, not rates', (tester) async {
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.restoredCleared,
          engineStatus: EngineStatus(
            reopen: EngineReopened(
              outcome: ReopenOutcome.clearedCap,
              droppedTracks: 0,
              previousSampleRate: 48000,
              sampleRate: 48000,
            ),
          ),
        ),
      );
      await pump(tester);
      expect(find.text(l10n.deviceRestoredClearedCapBanner), findsOneWidget);
    });

    testWidgets(
      'its action ends the notice and opens the Library',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1920, 1080)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(resetSegnoNavigatorForTest);
        whenListen(
          audioSetup,
          const Stream<AudioSetupState>.empty(),
          initialState: clearedState,
        );
        when(audioSetup.dismissReopenNotice).thenReturn(null);
        final session = _MockSessionCubit();
        final looper = _MockLooperBloc();
        whenListen(
          looper,
          const Stream<LooperState>.empty(),
          initialState: const LooperState(),
        );
        whenListen(
          session,
          const Stream<SessionState>.empty(),
          initialState: const SessionState(),
        );
        when(session.refreshSessions).thenAnswer((_) async {});
        final pedal = _MockPedalRepository();
        when(
          () => pedal.events,
        ).thenAnswer((_) => const Stream<PedalEvent>.empty());
        final sessions = _MockSessionRepository();
        when(sessions.listFolders).thenAnswer((_) async => const []);
        // The Library is a root-navigator route, so the providers sit above
        // the app, as they do in `App`.
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              RepositoryProvider<PedalRepository>.value(value: pedal),
              RepositoryProvider<SessionRepository>.value(value: sessions),
              RepositoryProvider<RemovableVolumes>.value(
                value: const InternalOnlyVolumes(),
              ),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<AudioSetupCubit>.value(value: audioSetup),
                BlocProvider<SessionCubit>.value(value: session),
                // The app provides the looper above every route, the
                // Library's included.
                BlocProvider<LooperBloc>.value(value: looper),
              ],
              child: MaterialApp(
                navigatorKey: segnoNavigatorKey,
                theme: AppTheme.neon,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const Scaffold(body: ConnectivityBanners()),
              ),
            ),
          ),
        );

        await tester.tap(
          find.byKey(const Key('connectivity_banner_material_action')),
        );
        await tester.pumpAndSettle();

        verify(audioSetup.dismissReopenNotice).called(1);
        verify(session.refreshSessions).called(1);
        expect(find.byType(LibraryPage), findsOneWidget);
      },
    );

    testWidgets('a partial retention is never a bar', (tester) async {
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.restoredPartial,
          engineStatus: EngineStatus(
            reopen: EngineReopened(
              outcome: ReopenOutcome.retainedPartial,
              droppedTracks: 2,
              previousSampleRate: 48000,
              sampleRate: 48000,
            ),
          ),
        ),
      );
      await pump(tester);
      expect(find.byKey(materialKey), findsNothing);
      expect(find.byKey(deviceKey), findsNothing);
    });
  });

  testWidgets(
    'device-lost holds a red banner that outlives any toast timeout — '
    'and is never a dialog',
    (tester) async {
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: deviceLostState,
      );
      await pump(tester);

      expect(find.byKey(deviceKey), findsOneWidget);
      expect(find.text(l10n.deviceLostBanner), findsOneWidget);
      expect(find.text(l10n.deviceLostBannerAction), findsOneWidget);

      // A standing condition, not an event: no auto-hide, ever. 30 seconds
      // outlives every toast duration the app has.
      await tester.pump(const Duration(seconds: 30));
      expect(find.byKey(deviceKey), findsOneWidget);

      // The pen's rule: a lost interface mid-song must not steal the
      // transport — the condition never surfaces as a dialog.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      // Record red, from the tokens (never a hardcoded hue).
      final s = surface(tester);
      final decoration = decorationOf(tester, deviceKey);
      expect(decoration.color, s.recTint);
      expect(decoration.border, Border.all(color: s.recLine));
    },
  );

  testWidgets(
    'the action hugs the message rather than floating to the far edge',
    (tester) async {
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: deviceLostState,
      );
      await pump(tester);

      // The button sits right after the sentence — no wall of dead space
      // between them (`c/device-lost`). The message sizes to content, so the
      // gap from its right edge to the button is the layout's fixed 10px
      // spacer, not the banner's whole free width.
      final messageRight = tester
          .getBottomRight(find.text(l10n.deviceLostBanner))
          .dx;
      const actionKey = Key('connectivity_banner_device_action');
      final actionLeft = tester.getTopLeft(find.byKey(actionKey)).dx;
      expect(actionLeft - messageRight, lessThan(24));

      // And the pair sits at the start of the banner, leaving the dead space
      // trailing: the action is nowhere near the right edge. If it were
      // floated there (the rejected `Expanded` layout) only the 15px content
      // padding would separate it from the edge; the real trailing gap is
      // several times that.
      final bannerRight = tester.getTopRight(find.byKey(deviceKey)).dx;
      final actionRight = tester.getTopRight(find.byKey(actionKey)).dx;
      expect(bannerRight - actionRight, greaterThan(40));
    },
  );

  testWidgets('leaves on its own the moment the device returns', (
    tester,
  ) async {
    final states = StreamController<AudioSetupState>();
    addTearDown(() => unawaited(states.close()));
    whenListen(audioSetup, states.stream, initialState: deviceLostState);
    await pump(tester);
    expect(find.byKey(deviceKey), findsOneWidget);

    states.add(
      const AudioSetupState(
        deviceConnectivity: DeviceConnectivity.restored,
        connectivityDeviceName: 'Scarlett 2i2',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(deviceKey), findsNothing);
  });
}
