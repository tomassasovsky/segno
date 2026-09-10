@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-in, four-out rig with two tracks recording, as the pen's examples
/// draw: track 0 takes inputs 1 and 2, track 1 takes input 3.
const _rig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
    ),
    Track(channel: 1, lanes: [Lane(inputChannel: 2, outputMask: 0xC)]),
  ],
  status: EngineStatus(
    isConnected: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  inputPeaks: [0.5, 0.12, 0, 0],
  outputPeaks: [0.35, 0.28, 0, 0],
  outputBusCount: 2,
);

void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Author-machine goldens, like the other screenshot suites here.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
    if (!hasScreenshotFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    monitorChanges = StreamController<int>.broadcast();
    monitorParams = StreamController<int>.broadcast();
    addTearDown(monitorChanges.close);
    addTearDown(monitorParams.close);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(_rig);
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => monitorChanges.stream);
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => monitorParams.stream);
    when(() => repository.allMonitors()).thenReturn(const {});
  });

  Future<void> pump(
    WidgetTester tester, {
    required AudioRoutingTab tab,
    LooperState state = _rig,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: state,
    );
    final inputs = InputsCubit(repository: repository, settings: settings);
    final outputs = OutputsCubit(repository: repository, settings: settings);
    final monitors = MonitorCubit(repository: repository, settings: settings);
    final tempo = TempoCubit(repository: repository, settings: settings);
    final tracks = TracksCubit(settings: settings);
    for (final cubit in <BlocBase<Object?>>[
      inputs,
      outputs,
      monitors,
      tempo,
      tracks,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await inputs.rename(0, 'Acoustic guitar');
    await inputs.rename(1, 'Lead vocal microphone');
    await inputs.rename(2, 'Keyboard left');
    await outputs.rename(0, 'Main output');
    await outputs.rename(1, 'Monitor output');
    await tracks.rename(0, 'drums');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
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
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: outputs),
              BlocProvider.value(value: monitors),
              BlocProvider.value(value: tempo),
              BlocProvider.value(value: tracks),
            ],
            child: AudioRoutingPage(initial: tab),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Input setup', (tester) async {
    await pump(tester, tab: AudioRoutingTab.setup);
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_input_setup.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Recording inputs', (tester) async {
    await pump(tester, tab: AudioRoutingTab.record);
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_recording_inputs.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Output routing', (tester) async {
    await pump(tester, tab: AudioRoutingTab.outputs);
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_output_routing.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Output setup', (tester) async {
    await pump(tester, tab: AudioRoutingTab.outputSetup);
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_output_setup.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Input names', (tester) async {
    await pump(tester, tab: AudioRoutingTab.setup);
    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_input_names.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Output names', (tester) async {
    await pump(tester, tab: AudioRoutingTab.outputSetup);
    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AudioRoutingPage),
      matchesGoldenFile('goldens/audio_routing_output_names.png'),
    );
  }, skip: !hasScreenshotFonts);
}
