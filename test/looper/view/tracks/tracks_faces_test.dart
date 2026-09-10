import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/looper/view/tray/tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-track rig, routed the way `TRACKS / tracks-routing` draws it: two
/// lanes on the first track, one each on the next two, and a fourth that
/// records nothing and reaches nothing.
///
/// A bare `Lane()` already records NOTHING (`inputChannel: -1`) out of the
/// first pair of outputs (`outputMask: 0x3`), so only the departures from that
/// are spelled out below.
const _rig = LooperState(
  tracks: [
    Track(
      lengthPresetBars: 8,
      lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
    ),
    Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
    Track(channel: 2, lanes: [Lane(inputChannel: 0, outputMask: 0x7)]),
    Track(channel: 3, lanes: [Lane(outputMask: 0)]),
  ],
  status: EngineStatus(inputChannels: 4, outputChannels: 4),
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late TracksCubit tracks;
  late InputsCubit inputs;
  late RecordTimingCubit quantize;
  late SettingsTrayCubit tray;

  /// The live state stream, when a test needs the face to REACT rather than
  /// only to render. Null by default: most tests seed one state and assert on
  /// it, and a live controller there would only add a teardown.
  StreamController<LooperState>? states;

  setUpAll(() {
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    states = null;
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecordTiming(any()),
    ).thenReturn(EngineResult.ok);
    // The input names follow the OPEN DEVICE, so the cubit reads the
    // repository's stream the moment it is built.
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(const LooperState());
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      states?.stream ?? const Stream<LooperState>.empty(),
      initialState: state,
    );
  }

  /// Mounts the Tracks face with the providers the real tray inherits.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view pushes the lower rows below the fold where a
  /// tap lands on nothing.
  Future<void> pump(
    WidgetTester tester, {
    LooperState state = _rig,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    seed(state);
    settings = SettingsRepository(store: FakeKeyValueStore());
    tracks = TracksCubit(settings: settings);
    inputs = InputsCubit(settings: settings, repository: repository);
    quantize = RecordTimingCubit(repository: repository, settings: settings);
    tray = SettingsTrayCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(quantize.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: quantize),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: TracksTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(TracksTrayPanel)));

  // ------------------------------------------------------------------ names

  group('Tracks — Names', () {
    testWidgets('the domain names itself once, and has no strip', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(find.byType(ConsoleDomainPanel<int>), findsOneWidget);
      expect(find.text(l10n.trayTracksLabel), findsOneWidget);
      expect(find.byKey(const Key('tracks_tabs')), findsNothing);
    });

    testWidgets('one row per track the ENGINE reports, not a fixed count', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byKey(const Key('tracks_names_row_3')), findsOneWidget);
      // The names list holds eight, the rig reports four.
      expect(find.byKey(const Key('tracks_names_row_4')), findsNothing);
    });

    testWidgets('a row reads the name, with the ordinal beside it', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tracks.rename(0, 'drums');
      await tester.pump();

      expect(find.text('drums'), findsOneWidget);
      expect(find.text(l10n.tracksOrdinal(1)), findsOneWidget);
    });

    testWidgets('tapping a row opens the console rename sheet, not a dialog', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      // The keys are IN the sheet — the console has no other keyboard.
      expect(find.text('q'), findsOneWidget);
    });

    testWidgets('typing and saving renames the track', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();
      // Clear the seeded name, then type a new one.
      for (var i = 0; i < 'TRACK 2'.length; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
      }
      await tester.pump();
      for (final key in ['b', 'a', 's', 's']) {
        await tester.tap(find.text(key));
      }
      await tester.pump();
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(tracks.state.names[1], 'bass');
    });

    testWidgets('Cancel leaves the name alone', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();
      for (final key in ['x', 'y']) {
        await tester.tap(find.text(key));
      }
      await tester.pump();
      await tester.tap(find.byKey(const Key('console_rename_cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(tracks.state.names[1], 'TRACK 2');
    });

    testWidgets('a physical keyboard drives the sheet too', (tester) async {
      // The on-screen keys are the console's only GUARANTEED input, not its
      // only possible one: desktop builds and a console with a USB keyboard
      // attached both type into this sheet directly.
      await pump(tester);
      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();

      for (var i = 0; i < 'TRACK 2'.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      }
      await tester.pump();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('console_rename_field')))
            .data,
        isEmpty,
      );
      // Backspace on an empty field is a no-op rather than an error.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(tracks.state.names[1], 'di');
    });

    testWidgets('Escape closes the sheet without renaming', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(tracks.state.names[1], 'TRACK 2');
    });

    testWidgets('an empty name does not close the sheet, and renames nothing', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_names_row_1')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 'TRACK 2'.length; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
      }
      await tester.pump();
      await tester.tap(find.text(l10nOf(tester).save));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      expect(tracks.state.names[1], 'TRACK 2');
    });
  });

  // ------------------------------------------------------------- empty rig

  group('Tracks — a stopped engine', () {
    testWidgets('says so instead of drawing a sliver', (tester) async {
      await pump(tester, state: const LooperState());
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('tracks_empty_card')), findsOneWidget);
      expect(find.text(l10n.tracksEmpty), findsOneWidget);
      // The footnote still applies — it is about the setting, not the rows.
      expect(find.byType(ConsoleProse), findsWidgets);
    });
  });

  group('the rail', () {
    testWidgets('reaches the Tracks face', (tester) async {
      await pump(tester);
      tray.showDestination(SettingsTrayDestination.tracks);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            extensions: [
              SurfaceTheme.dark,
              routingGraphThemeFromSurface(SurfaceTheme.dark),
            ],
          ),
          home: RepositoryProvider<LooperRepository>.value(
            value: repository,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<LooperBloc>.value(value: bloc),
                BlocProvider.value(value: tracks),
                BlocProvider.value(value: inputs),
                BlocProvider.value(value: quantize),
                BlocProvider.value(value: tray),
              ],
              child: const Scaffold(body: TrayPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tracks_tray_panel')), findsOneWidget);
    });

    testWidgets('has no strip: the domain has one task left', (tester) async {
      // Routing left this panel for Settings > Audio routing (slice 3c), and
      // a lone pill over a single body chooses nothing.
      await pump(tester);
      expect(find.byKey(const Key('tracks_tabs')), findsNothing);
      expect(find.byKey(const Key('tracks_names_tab')), findsOneWidget);
    });
  });
}
