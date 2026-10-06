import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/theme/theme.dart';
import 'package:storage_repository/storage_repository.dart';

import 'destination_harness.dart';

class _MockPowerOffCubit extends MockCubit<PowerOffState>
    implements PowerOffCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockStorageRepository extends Mock implements StorageRepository {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

/// Takes every route off the navigator the moment it is pushed, before its
/// page builds, and keeps its name: the test is about WHICH page a tile
/// opens, and the five musical pages need a whole rig to build.
class _DroppingObserver extends NavigatorObserver {
  final pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = route.settings.name;
    // Only the destinations: the page under test is the home route.
    if (name == null || !name.startsWith('segno/')) return;
    pushed.add(name);
    scheduleMicrotask(() => navigator?.removeRoute(route));
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      powerOffSnapshotOf(
        looper: const LooperState(),
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(),
      ),
    );
  });

  setUp(resetSegnoNavigatorForTest);

  tearDown(() => setSegnoFxCatalogueForTest(null));

  Future<void> pumpHome(
    WidgetTester tester, {
    List<NavigatorObserver> observers = const [],
    bool powerAvailable = false,
    Widget Function(Widget app)? wrap,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = MaterialApp(
      navigatorKey: segnoNavigatorKey,
      navigatorObservers: observers,
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsHomePage(powerAvailable: powerAvailable),
    );
    await tester.pumpWidget(wrap?.call(app) ?? app);
    await tester.pumpAndSettle();
  }

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(SettingsHomePage)));

  Finder tile(SettingsDestination destination) =>
      find.byKey(Key('settings_tile_${destination.key}'));

  group('the ten tiles', () {
    testWidgets('are drawn in the pen order, on two rows of five', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.byType(SettingsTile), findsNWidgets(10));

      // The frame lays the pen out 1:1 at 1920 x 1080, with a 96 px top bar
      // over the main area the tile positions are measured in.
      expect(
        tester.getRect(tile(SettingsDestination.effects)),
        const Rect.fromLTWH(100, 368, 325, 244),
      );
      expect(
        tester.getRect(tile(SettingsDestination.updates)),
        const Rect.fromLTWH(1495, 636, 325, 244),
      );
      final order = [
        for (final destination in SettingsDestination.values)
          tester.getTopLeft(tile(destination)),
      ];
      for (var i = 1; i < order.length; i++) {
        final previous = order[i - 1];
        final current = order[i];
        if (i % 5 == 0) {
          expect(current.dy, greaterThan(previous.dy));
        } else {
          expect(current.dy, previous.dy);
          expect(current.dx, greaterThan(previous.dx));
        }
      }
    });

    testWidgets('each shows its own picture at the pen size and offset', (
      tester,
    ) async {
      await pumpHome(tester);
      for (final destination in SettingsDestination.values) {
        final art = find.byKey(Key('settings_tile_art_${destination.key}'));
        final image = tester.widget<Image>(art);
        // Decoded at the drawn size, so the provider is a resize of the asset.
        final provider = image.image as ResizeImage;
        expect(provider.width, 128);
        expect(
          (provider.imageProvider as AssetImage).assetName,
          'assets/settings/${destination.key}.png',
        );
        expect(tester.getSize(art), const Size(128, 128));
        expect(
          tester.getTopLeft(art) - tester.getTopLeft(tile(destination)),
          const Offset(98, 32),
        );
      }
    });

    testWidgets('are named as the pen names them', (tester) async {
      await pumpHome(tester);
      final strings = l10n(tester);
      for (final name in [
        'Effects',
        'Loop settings',
        'Pedals',
        'MIDI',
        'Audio routing',
        'Device',
        'Network',
        'Displays',
        'Storage',
        'Updates',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text(strings.stageSettings), findsOneWidget);
    });

    testWidgets('each opens its own destination', (tester) async {
      // Set inside the test body: a future completed outside the test's fake
      // async zone never resumes an `await` inside it.
      setSegnoFxCatalogueForTest(FxCatalogue.empty);
      final observer = _DroppingObserver();
      await pumpHome(tester, observers: [observer]);

      for (final destination in SettingsDestination.values) {
        await tester.tap(tile(destination));
        await tester.pumpAndSettle();
      }
      expect(observer.pushed, [
        segnoFxRouteName,
        segnoLoopSettingsRouteName,
        segnoPedalSetupRouteName,
        segnoMidiControlsRouteName,
        segnoAudioRoutingRouteName,
        segnoDeviceSettingsRouteName,
        segnoNetworkSettingsRouteName,
        segnoDisplaySettingsRouteName,
        segnoStorageSettingsRouteName,
        segnoUpdateSettingsRouteName,
      ]);
    });

    testWidgets('each is a button named for its destination', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpHome(tester);
      for (final destination in SettingsDestination.values) {
        expect(
          tester.getSemantics(tile(destination)),
          isSemantics(
            label: destination.label(l10n(tester)),
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
            isFocused: destination == SettingsDestination.effects,
          ),
        );
      }
      semantics.dispose();
    });
  });

  group('focus', () {
    testWidgets('starts on Effects and moves through the tiles in order', (
      tester,
    ) async {
      await pumpHome(tester);
      bool focused(SettingsDestination destination) => Focus.of(
        tester.element(
          find.descendant(
            of: tile(destination),
            matching: find.byType(Container),
          ),
        ),
      ).hasFocus;

      expect(focused(SettingsDestination.effects), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(focused(SettingsDestination.loop), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focused(SettingsDestination.network), isTrue);
    });

    testWidgets('the focused tile draws the encoder amber inside its edge', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await pumpHome(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final image = (await tester.runAsync(
        () => captureImage(tester.element(find.byType(SettingsHomePage))),
      ))!;
      final bytes = (await tester.runAsync(image.toByteData))!;
      Color pixel(Offset at) {
        final i = (at.dy.round() * image.width + at.dx.round()) * 4;
        return Color.fromARGB(
          bytes.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      // A column inside the left edge of a tile, halfway down: the tile's
      // own 1 px line is the first column, the 3 px ring covers three.
      Offset edge(SettingsDestination destination, double inset) {
        final rect = tester.getRect(tile(destination));
        return Offset(rect.left + inset, rect.center.dy);
      }

      const surface = SurfaceTheme.dark;
      expect(pixel(edge(SettingsDestination.loop, 0)), surface.encoderFocus);
      expect(pixel(edge(SettingsDestination.loop, 2)), surface.encoderFocus);
      expect(
        pixel(edge(SettingsDestination.effects, 0)),
        surface.menuArtLine,
      );
      expect(
        pixel(edge(SettingsDestination.effects, 2)),
        surface.menuArtGround,
      );
      image.dispose();
    });

    testWidgets('Back from a destination returns focus to its tile', (
      tester,
    ) async {
      final harness = DestinationHarness();
      await harness.pump(tester);
      unawaited(openSegnoSettings());
      await tester.pumpAndSettle();
      bool focused(SettingsDestination destination) => Focus.of(
        tester.element(
          find.descendant(
            of: tile(destination),
            matching: find.byType(Container),
          ),
        ),
      ).hasFocus;

      // Arrow to Displays (second row, third tile), open it with Enter.
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }
      expect(focused(SettingsDestination.displays), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(DisplaysSettingsPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byType(DisplaysSettingsPage), findsNothing);
      expect(focused(SettingsDestination.displays), isTrue);
    });
  });

  group('chrome', () {
    testWidgets('opens once, Back and Stage leave it', (tester) async {
      final harness = DestinationHarness();
      await harness.pump(tester);
      unawaited(openSegnoSettings());
      unawaited(openSegnoSettings());
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomePage), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomePage), findsNothing);

      unawaited(openSegnoSettings());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tile_storage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_settings_stage')));
      await tester.pumpAndSettle();
      expect(find.byType(StorageSettingsPage), findsNothing);
      expect(find.byType(SettingsHomePage), findsNothing);
    });

    testWidgets('Power is not shown where nothing can be powered off', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.byKey(const Key('settings_power')), findsNothing);
    });

    Future<_MockPowerOffCubit> pumpWithPower(
      WidgetTester tester, {
      StorageRepository? storage,
    }) async {
      final power = _MockPowerOffCubit();
      whenListen(
        power,
        const Stream<PowerOffState>.empty(),
        initialState: const PowerOffState(),
      );
      final looper = MockLooperBloc();
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(),
      );
      final session = _MockSessionCubit();
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(currentSessionName: 'Evening loop'),
      );
      final recorder = _MockPerformanceRecorderCubit();
      whenListen(
        recorder,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: const PerformanceRecorderIdle(),
      );
      await pumpHome(
        tester,
        powerAvailable: true,
        wrap: (app) {
          final blocs = MultiBlocProvider(
            providers: [
              BlocProvider<PowerOffCubit>.value(value: power),
              BlocProvider<LooperBloc>.value(value: looper),
              BlocProvider<SessionCubit>.value(value: session),
              BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
            ],
            child: app,
          );
          return storage == null
              ? blocs
              : RepositoryProvider<StorageRepository>.value(
                  value: storage,
                  child: blocs,
                );
        },
      );
      return power;
    }

    testWidgets('Power asks as the rear button does', (tester) async {
      final power = await pumpWithPower(tester);

      final button = find.byKey(const Key('settings_power'));
      expect(button, findsOneWidget);
      // At the title's right edge, as the pen's title bar has it.
      expect(tester.getTopRight(button).dx, 1920 - 100);
      await tester.tap(button);
      await tester.pump();

      final expected = powerOffSnapshotOf(
        looper: const LooperState(),
        recorder: const PerformanceRecorderIdle(),
        session: const SessionState(currentSessionName: 'Evening loop'),
      );
      verify(() => power.press(expected)).called(1);
    });

    testWidgets('Power during a USB transfer is refused, as the rear button '
        'is', (tester) async {
      final storage = _MockStorageRepository();
      when(() => storage.transferInFlight).thenReturn(true);
      final power = await pumpWithPower(tester, storage: storage);

      await tester.tap(find.byKey(const Key('settings_power')));
      await tester.pump();

      final pressed =
          verify(() => power.press(captureAny())).captured.single
              as PowerOffSnapshot;
      expect(pressed.transferInFlight, isTrue);
      expect(powerOffGate(pressed), PowerOffDisposition.refuse);
    });
  });
}
