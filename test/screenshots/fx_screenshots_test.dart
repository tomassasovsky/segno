@Tags(['screenshots'])
library;

import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/fx_presets_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx/fx_effect_editor.dart';
import 'package:segno/looper/view/fx/fx_library_page.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/looper/view/fx/fx_rack_editor.dart';
import 'package:segno/looper/view/fx/fx_reorder_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../looper/view/fx/stomp/factory_pedals.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc;

class _MockLooperRepository extends Mock implements LooperRepository;

BuiltInEffect _fx(
  String slot,
  TrackEffectType type, {
  bool enabled = true,
  FxPlacement placement = FxPlacement.post,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  placement: placement,
);

/// A four-in, four-out rig with two tracks recording, as the pen's examples
/// draw: track 0 takes inputs 1 and 2, track 1 takes input 3. Track 0 carries
/// a chain that straddles both stages, so the strip has a break to draw.
/// One module of the rack [rackId].
BuiltInEffect _module(
  String slot,
  TrackEffectType type, {
  required String rackId,
  required String module,
  String rackName = 'Funk Wah',
  bool enabled = true,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  module: module,
  rack: FxRack(id: rackId, name: rackName, art: 'guitar'),
);

/// A rig whose track 0 carries a rack of three pedals between two standalone
/// effects, so the strip draws both kinds of card.
final _rackRig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: const [Lane(inputChannel: 0, lengthFrames: 48000)],
      effects: [
        _fx('p1', TrackEffectType.filter, placement: FxPlacement.pre),
        _module(
          'r1a',
          TrackEffectType.modeDelay,
          rackId: 'R1',
          module: 'Delay',
        ),
        _module(
          'r1b',
          TrackEffectType.none,
          rackId: 'R1',
          module: 'Pumper',
          enabled: false,
        ),
        _module(
          'r1c',
          TrackEffectType.reverb,
          rackId: 'R1',
          module: 'Reverb',
        ),
        _fx('s1', TrackEffectType.echo),
      ],
    ),
  ],
  status: const EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

/// A rack whose pedals the catalogue names in words Spanish translates: the
/// Lo-Fi Rack's Distortion (on the Overdrive), its low-pass filter and vinyl,
/// and the Studio Rack's Pitch shift (on the octaver) (#1752).
final _loFiRig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: const [Lane(inputChannel: 0, lengthFrames: 48000)],
      effects: [
        _module(
          'g1',
          TrackEffectType.lpf,
          rackId: 'G',
          module: 'Low-pass filter',
          rackName: 'Grubby',
        ),
        _module(
          'g2',
          TrackEffectType.vinyl,
          rackId: 'G',
          module: 'Vinyl',
          rackName: 'Grubby',
        ),
        _module(
          'g3',
          TrackEffectType.overdrive,
          rackId: 'G',
          module: 'Distortion',
          rackName: 'Grubby',
        ),
        _module(
          'g4',
          TrackEffectType.octaver,
          rackId: 'G',
          module: 'Pitch shift',
          rackName: 'Grubby',
        ),
      ],
    ),
  ],
  status: const EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

final _rig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: [
        Lane(
          inputChannel: 0,
          lengthFrames: 48000,
          effects: [_fx('l1', TrackEffectType.drive)],
        ),
        const Lane(inputChannel: 1, lengthFrames: 48000),
      ],
      effects: [
        _fx('t1', TrackEffectType.filter, placement: FxPlacement.pre),
        _fx(
          't2',
          TrackEffectType.drive,
          placement: FxPlacement.pre,
          enabled: false,
        ),
        _fx('t3', TrackEffectType.reverb),
      ],
    ),
    const Track(channel: 1, lanes: [Lane(inputChannel: 2, outputMask: 0xC)]),
  ],
  laneCounts: const {0: 2},
  laneInputs: const {(0, 0): 0, (0, 1): 1, (1, 0): 2},
  outputChains: {
    0: FxChainEnvelope(entries: [_fx('o1', TrackEffectType.reverb)]),
  },
  allTracksChain: FxChainEnvelope(
    entries: [
      _fx('a1', TrackEffectType.echo),
      _fx('a2', TrackEffectType.filter, enabled: false),
    ],
  ),
  status: const EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

/// One recording track whose chain is [effects], and nothing else.
LooperState _chainRig(List<TrackEffect> effects) => LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: const [Lane(inputChannel: 0, lengthFrames: 48000)],
      effects: effects,
    ),
  ],
  status: const EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

/// A stand-in catalogue: the wide family, two ordinary ones, real slugs.
const _library = FxCatalogue(
  families: [
    FxFamily(name: "Ed's Rack", slug: 'edsguitar', presets: []),
    FxFamily(name: 'Guitar Rack', slug: 'guitar', presets: []),
    FxFamily(name: 'Vocal Rack', slug: 'vocal', presets: []),
  ],
);

class _MockControlCubit extends MockCubit<ControlState>
    implements ControlCubit;

/// The console's second track switch on the reverb, and CTRL 1 on it too:
/// the Recorded track card names both (#1757).
final _assigned = ControlState(
  globalBindings: PedalBindingSet([
    PedalBinding(
      key: const PedalBindingKey(button: PedalButton.track2, bank: 0),
      target: const FxSlotTarget(
        address: FxAddress(stage: FxStage.track),
        slotId: 't3',
      ).canonicalString(),
    ),
  ]),
  pedalSetup: PedalSetup(
    external: ExternalPedalSetup(
      jacks: {
        PedalCtrlJack.ctrl1: ExternalJackSetup(
          single: ExternalSwitchSetup(
            controls: ExternalControls(
              activations: const [
                ExternalActivation(
                  target: FxSlotTarget(
                    address: FxAddress(stage: FxStage.track),
                    slotId: 't3',
                  ),
                ),
              ],
            ),
          ),
        ),
      },
    ),
  ),
);

/// CTRL 1 switching the Funk Wah rack: its card names it (#1760).
final _rackAssigned = ControlState(
  pedalSetup: PedalSetup(
    external: ExternalPedalSetup(
      jacks: {
        PedalCtrlJack.ctrl1: ExternalJackSetup(
          single: ExternalSwitchSetup(
            controls: ExternalControls(
              activations: const [
                ExternalActivation(
                  target: FxRackTarget(
                    address: FxAddress(stage: FxStage.track),
                    rackId: 'R1',
                  ),
                ),
              ],
            ),
          ),
        ),
      },
    ),
  ),
);

void main() {
  setUpAll(() async {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(const FxAddress(stage: FxStage.track));
    registerFallbackValue(<FxAddress, List<TrackEffect>>{});
    if (!rendersScreenshots) return;
    // The rack editor and the reorder strip draw catalogue pedals.
    await loadFxStompArt();
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    settings = SettingsRepository(store: FakeKeyValueStore());
    monitorChanges = StreamController<int>.broadcast();
    monitorParams = StreamController<int>.broadcast();
    addTearDown(monitorChanges.close);
    addTearDown(monitorParams.close);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.state).thenReturn(_rig);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.fxRoomNs).thenReturn(1 << 40);
    when(() => repository.fxChainHeld(any())).thenReturn(false);
    when(() => repository.fxHeldChainFits(any())).thenReturn(true);
    registerFallbackValue(<FxAddress, bool>{});
    when(
      () => repository.fxGrowthNs(
        any(),
        chainSwitches: any(named: 'chainSwitches'),
      ),
    ).thenAnswer(
      (call) => fxChainCostNs(
        (call.positionalArguments[0] as Map<FxAddress, List<TrackEffect>>)
            .values
            .expand((chain) => chain),
      ),
    );
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.laneCount(any())).thenAnswer((call) {
      final channel = call.positionalArguments.first as int;
      return repository.state.tracks
              .where((track) => track.channel == channel)
              .firstOrNull
              ?.lanes
              .length ??
          0;
    });
    when(() => repository.monitorEffects(any())).thenReturn([
      _fx('m1', TrackEffectType.delay, placement: FxPlacement.pre),
      _fx('m2', TrackEffectType.reverb),
    ]);
    when(() => repository.monitorChainEnabled(any())).thenReturn(true);
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => monitorChanges.stream);
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => monitorParams.stream);
    when(() => repository.allMonitors()).thenReturn({
      0: InputMonitor(
        input: 0,
        effects: [
          _fx('m1', TrackEffectType.delay, placement: FxPlacement.pre),
          _fx('m2', TrackEffectType.reverb),
        ],
      ),
    });
  });

  /// Lets the bundled artwork actually load.
  ///
  /// Waits for the displayed images themselves, rather than assuming a fixed
  /// delay is enough for decoding. Missing assets fail instead of silently
  /// becoming blank reference images.
  Future<void> settleArtwork(WidgetTester tester) async {
    final errors = <Object>[];
    await tester.runAsync(() async {
      await Future.wait([
        for (final element in find.byType(Image).evaluate())
          precacheImage(
            (element.widget as Image).image,
            element,
            onError: (error, _) => errors.add(error),
          ),
      ]);
    });
    expect(errors, isEmpty, reason: 'Every displayed artwork asset must load.');
    await tester.pumpAndSettle();
  }

  late FxPresetsCubit presets;

  Future<void> pump(
    WidgetTester tester, {
    required FxDestination destination,
    LooperState? state,
    FxCatalogue catalogue = FxCatalogue.empty,
    Locale? locale,
    ControlState control = const ControlState(),
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = state ?? _rig;
    when(() => bloc.state).thenReturn(rig);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: rig,
    );
    final inputs = InputsCubit(repository: repository, settings: settings);
    final outputs = OutputsCubit(repository: repository, settings: settings);
    final fxPersistence = FxChainPersistence(looper: repository);
    final monitors = MonitorCubit(
      fxPersistence: fxPersistence,
      repository: repository,
      settings: settings,
      mixSettings: testMixSettings(repository, settings: settings),
    )..projectFromRepository();
    final tracks = TracksCubit(settings: settings);
    presets = FxPresetsCubit(settings: settings);
    await presets.load();
    for (final cubit in <BlocBase<Object?>>[
      inputs,
      outputs,
      monitors,
      tracks,
      presets,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await inputs.rename(0, 'Acoustic guitar');
    await inputs.rename(1, 'Lead vocal microphone');
    await inputs.rename(2, 'Keyboard left');
    await outputs.rename(0, 'Main output');
    await outputs.rename(1, 'Monitor output');
    await tracks.rename(0, 'drums');
    final controlCubit = _MockControlCubit();
    when(() => controlCubit.state).thenReturn(control);

    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
            SpacingTheme.standard,
            NoticeTheme.standard,
          ],
        ),
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<SettingsRepository>.value(value: settings),
            RepositoryProvider<FxChainPersistence>.value(
              value: fxPersistence,
            ),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: outputs),
              BlocProvider.value(value: monitors),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: presets),
              BlocProvider<ControlCubit>.value(value: controlCubit),
            ],
            child: FxPage(initial: destination, catalogue: catalogue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await settleArtwork(tester);
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(FxPage),
      matchesGoldenFile('goldens/fx_$name.png'),
    );
  }

  testWidgets('Live inputs', (tester) async {
    await pump(tester, destination: const FxDestination.liveInput(0));
    await shoot(tester, 'live_inputs');
  }, skip: !rendersScreenshots);

  testWidgets('Recorded track, whole track', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      control: _assigned,
    );
    await shoot(tester, 'recorded_track');
  }, skip: !rendersScreenshots);

  // Spanish: a single effect's card has no title, and its pedal prints the
  // effect's English name in every locale (#1754).
  testWidgets('Recorded track, in Spanish', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
      locale: const Locale('es'),
    );
    await shoot(tester, 'recorded_track_es');
  }, skip: !rendersScreenshots);

  testWidgets('Recorded track, the part picker', (tester) async {
    await pump(tester, destination: const FxDestination.recordedTrack(0));
    await tester.tap(find.byKey(const Key('fx_part_picker')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/fx_recorded_track_parts.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('All tracks', (tester) async {
    await pump(tester, destination: const FxDestination.allTracks());
    await shoot(tester, 'all_tracks');
  }, skip: !rendersScreenshots);

  testWidgets('Outputs', (tester) async {
    await pump(tester, destination: const FxDestination.output(0));
    await shoot(tester, 'outputs');
  }, skip: !rendersScreenshots);

  testWidgets('The effect editor', (tester) async {
    await pump(tester, destination: const FxDestination.recordedTrack(0));
    await tester.tap(find.byKey(const Key('fx_card_t1')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(FxEffectEditor),
      matchesGoldenFile('goldens/fx_effect_editor.png'),
    );
  }, skip: !rendersScreenshots);

  // Every standalone effect's own page: the seven built-ins the singles
  // library offers, each alone on the track (#1730).
  for (final type in TrackEffectType.values) {
    if (type == TrackEffectType.none || type.isRackKind) continue;
    testWidgets('The ${type.name} effect page', (tester) async {
      await pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: _chainRig([_fx('s1', type)]),
      );
      await tester.tap(find.byKey(const Key('fx_card_s1')));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(FxEffectEditor),
        matchesGoldenFile('goldens/fx_effect_${type.name}.png'),
      );
    }, skip: !rendersScreenshots);
  }

  // A factory rack's pedals that carry a choice parameter, one rack per
  // family that has them, as its preset loads them (#1730).
  for (final (family, name) in const [
    ("Ed's Rack", 'Acoustic Rhythm 1'),
    ('Rhythmic Rack', 'Funk Wah'),
    ('Guitar Rack', 'Clean Rhythm'),
    ('Studio Rack', 'AC Guitar Chorus'),
    ('Vocal Tuner Rack', 'Auto Harm Hi Dry'),
    ('Drum Rack', 'Ballad'),
  ]) {
    testWidgets('The rack editor, $family choices', (tester) async {
      final preset = factoryPresets().firstWhere(
        (p) => p.family == family && p.name == name,
      );
      final entries = [
        for (final entry in fxFactoryRack(
          preset,
          placement: FxPlacement.post,
          into: FxRack(
            id: 'R1',
            name: preset.name,
            art: kFxFamilySlugs[family],
          ),
        ))
          if (fxEntryControls(entry).params.any(
            (i) => fxEntryParam(entry, i).unit == FxParamUnit.choice,
          ))
            entry,
      ];
      await pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: _chainRig([
          for (final (i, entry) in entries.indexed)
            entry.copyWith(slotId: 'r$i'),
        ]),
      );
      await tester.tap(find.byKey(const Key('fx_card_R1')));
      await tester.pumpAndSettle();
      await settleArtwork(tester);

      await expectLater(
        find.byType(FxRackEditor),
        matchesGoldenFile(
          'goldens/fx_rack_choices_${kFxFamilySlugs[family]}.png',
        ),
      );
    }, skip: !rendersScreenshots);
  }

  testWidgets('A chain of racks', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
      control: _rackAssigned,
    );

    await shoot(tester, 'racks');
  }, skip: !rendersScreenshots);

  testWidgets('The rack editor', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
    );
    await tester.tap(find.byKey(const Key('fx_card_R1')));
    await tester.pumpAndSettle();
    await settleArtwork(tester);

    await expectLater(
      find.byType(FxRackEditor),
      matchesGoldenFile('goldens/fx_rack_editor.png'),
    );
  }, skip: !rendersScreenshots);

  // Spanish: a rack's pedals by their translated module names, and the
  // single effects by their translated kinds (#1752).
  testWidgets('The rack editor, in Spanish', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _loFiRig,
      locale: const Locale('es'),
    );
    await tester.tap(find.byKey(const Key('fx_card_G')));
    await tester.pumpAndSettle();
    await settleArtwork(tester);

    await expectLater(
      find.byType(FxRackEditor),
      matchesGoldenFile('goldens/fx_rack_editor_es.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('Single effects, in Spanish', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _loFiRig,
      catalogue: _library,
      locale: const Locale('es'),
    );
    await tester.tap(find.byKey(const Key('fx_add_effects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_library_single')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(FxLibraryPage),
      matchesGoldenFile('goldens/fx_single_es.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('Reorder', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
    );
    await tester.tap(find.byKey(const Key('fx_reorder')));
    await tester.pumpAndSettle();
    await settleArtwork(tester);

    await expectLater(
      find.byType(FxReorderPage),
      matchesGoldenFile('goldens/fx_reorder.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('Rack options', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
    );
    await tester.tap(find.byKey(const Key('fx_card_R1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_rack_options')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const Key('fx_options_sheet')),
      matchesGoldenFile('goldens/fx_rack_options.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('My presets', (tester) async {
    await pump(
      tester,
      destination: const FxDestination.recordedTrack(0),
      state: _rackRig,
      catalogue: _library,
    );
    await presets.save(
      name: 'Warm rhythmic guitar',
      entries: [
        _module(
          'a',
          TrackEffectType.modeDelay,
          rackId: 'X',
          module: 'Delay',
        ),
        _module('b', TrackEffectType.reverb, rackId: 'X', module: 'Reverb'),
      ],
      art: 'guitar',
    );
    await presets.save(
      name: 'Clean verse',
      entries: [_fx('c', TrackEffectType.echo)],
      art: 'rhythmic',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_add_effects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_library_saved')));
    await tester.pumpAndSettle();
    await settleArtwork(tester);

    await expectLater(
      find.byType(FxLibraryPage),
      matchesGoldenFile('goldens/fx_my_presets.png'),
    );
  }, skip: !rendersScreenshots);

  testWidgets('Add effects, the library grid', (tester) async {
    // A stand-in catalogue of the real shape rather than the bundled one, so
    // this golden is pinned to a fixed set of families and presets rather
    // than to whatever the catalogue import last shipped. The artwork it
    // names is the real artwork.
    await pump(
      tester,
      destination: const FxDestination.liveInput(0),
      catalogue: _library,
    );
    await tester.tap(find.byKey(const Key('fx_add_effects')));
    await tester.pumpAndSettle();

    await settleArtwork(tester);
    await expectLater(
      find.byType(FxLibraryPage),
      matchesGoldenFile('goldens/fx_library.png'),
    );
  }, skip: !rendersScreenshots);
}
