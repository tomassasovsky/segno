import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/fx_presets_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/fx/fx_effect_editor.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/looper/view/fx/fx_rack_editor.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _fx(
  String slot,
  TrackEffectType type, {
  bool enabled = true,
  FxPlacement placement = FxPlacement.post,
  FxChannels channels = FxChannels.defaults,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  placement: placement,
  channels: channels,
);

/// One module of the rack [rackId].
BuiltInEffect _module(
  String slot,
  TrackEffectType type, {
  required String rackId,
  String rackName = 'Funk Wah',
  String? module,
  bool enabled = true,
  FxPlacement placement = FxPlacement.post,
  FxChannels channels = FxChannels.defaults,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  placement: placement,
  channels: channels,
  module: module,
  rack: FxRack(id: rackId, name: rackName, art: 'guitar'),
);

/// A rig whose track 0 carries a rack of three pedals followed by one
/// standalone effect, both Post, plus a Pre standalone ahead of them.
final _rackRig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: const [Lane(inputChannel: 0, lengthFrames: 48000)],
      effects: [
        _fx('p1', TrackEffectType.filter, placement: FxPlacement.pre),
        _module('r1a', TrackEffectType.delay, rackId: 'R1', module: 'Delay'),
        // A pedal this build has no effect for: it keeps its catalogue name
        // and becomes a passthrough entry.
        _module('r1b', TrackEffectType.none, rackId: 'R1', module: 'Pumper'),
        _module('r1c', TrackEffectType.reverb, rackId: 'R1', module: 'Reverb'),
        _fx('s1', TrackEffectType.echo),
      ],
    ),
  ],
  status: const EngineStatus(
    isConnected: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

/// A four-in, four-out rig with two tracks recording, as the pen's examples
/// draw: track 0 takes inputs 1 and 2, track 1 takes input 3. Track 0 carries
/// a chain that straddles both stages, so the strip has a break to draw.
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
        _fx(
          't1',
          TrackEffectType.filter,
          placement: FxPlacement.pre,
          // Off its defaults, so a write that replaces the whole value
          // instead of copying it loses something a test can see.
          channels: const FxChannels(
            input: FxChannelInput.monoSum,
            placement: -0.5,
            level: 0.8,
          ),
        ),
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
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  inputPeaks: const [0.5, 0.12, 0, 0],
  outputPeaks: const [0.35, 0.28, 0, 0],
  outputBusCount: 2,
);

/// A small catalogue of the real shape: a family whose preset names three
/// modules, and one whose preset names one.
const _catalogue = FxCatalogue(
  families: [
    FxFamily(
      name: "Ed's Rack",
      slug: 'edsguitar',
      presets: [
        FxPreset(
          family: "Ed's Rack",
          name: 'Acoustic Rhythm 1',
          id: 'ed53e7b8',
          type: 0,
          params: {
            'Compressor': 1,
            'Comp Ratio': 0.75,
            'Delay': 0,
            'Del Time': 0.42,
            'Del Feedback': 0.35,
            'Del Mix': 0.25,
            'Reverb': 1,
            'Rev Length': 0.36,
            'Rev Mix': 0.05,
          },
        ),
      ],
    ),
    FxFamily(
      name: 'Rhythmic Rack',
      slug: 'rhythmic',
      presets: [
        FxPreset(
          family: 'Rhythmic Rack',
          name: 'Quarter Pump',
          id: 'rh-1',
          type: 6,
          params: {'Pumper': 1, 'Pumper Depth': 0.8},
        ),
      ],
    ),
  ],
);

void main() {
  setUpAll(() {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;
  late PluginCatalog catalog;
  late FxPresetsCubit presets;

  setUp(() {
    catalog = PluginCatalog(
      engine: FakeAudioEngine(),
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    addTearDown(catalog.dispose);
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
    when(() => repository.monitorEffects(any())).thenReturn([
      _fx('m1', TrackEffectType.delay, placement: FxPlacement.pre),
      _fx('m2', TrackEffectType.reverb),
    ]);
    when(() => repository.monitorChainEnabled(any())).thenReturn(true);
    when(
      () => repository.setMonitorEffects(
        input: any(named: 'input'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => monitorChanges.stream);
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => monitorParams.stream);
    when(() => repository.pluginCatalog).thenReturn(catalog);
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.monitorMode(any())).thenReturn(MonitorMode.off);
    when(() => repository.monitorOutput(any())).thenReturn(0x3);
    when(() => repository.monitorVolume(any())).thenReturn(1);
    when(() => repository.monitorMuted(any())).thenReturn(false);
    when(
      () => repository.setMonitorEffectEnabled(
        input: any(named: 'input'),
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  Future<void> pump(
    WidgetTester tester, {
    required FxDestination destination,
    LooperState? state,
    FxCatalogue? catalogue,
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
    final monitors = MonitorCubit(repository: repository, settings: settings);
    await monitors.load();
    final tempo = TempoCubit(repository: repository, settings: settings);
    final tracks = TracksCubit(settings: settings);
    presets = FxPresetsCubit(settings: settings);
    await presets.load();
    for (final cubit in <BlocBase<Object?>>[
      inputs,
      outputs,
      monitors,
      tempo,
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

    await tester.pumpWidget(
      // Saving a preset confirms with a toast, which needs the app's own
      // overlay wrapper to land in.
      ToastificationWrapper(
        child: MaterialApp(
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
                BlocProvider.value(value: presets),
              ],
              child: FxPage(
                initial: destination,
                catalogue: catalogue ?? _catalogue,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The real seeding path for a monitor chain: the repository announces the
    // input changed and the cubit re-reads it, which is how a chain reaches
    // the console when it did not come from this cubit's own write.
    monitorChanges.add(0);
    await tester.pumpAndSettle();
  }

  // Any Localizations context, because the library route covers the page and
  // half these checks read strings while it is up.
  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Navigator).first));

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  group('the Sound type row', () {
    testWidgets('picks which strip is showing', (tester) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      expect(find.byKey(const Key('fx_input_strip')), findsOneWidget);
      expect(find.byKey(const Key('fx_track_strip')), findsNothing);

      await tapKey(tester, 'fx_kind_recordedTrack');

      expect(find.byKey(const Key('fx_track_strip')), findsOneWidget);
      expect(find.byKey(const Key('fx_input_strip')), findsNothing);

      await tapKey(tester, 'fx_kind_output');

      expect(find.byKey(const Key('fx_output_strip')), findsOneWidget);
    });

    testWidgets('each strip keeps its own place across a switch', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      await tapKey(tester, 'fx_input_card_2');
      await tapKey(tester, 'fx_kind_output');
      await tapKey(tester, 'fx_kind_liveInput');

      // Not back to the first input: a context switch restores the strip,
      // it does not reset it.
      expect(
        tester
            .widget<RoutingSourceCard>(find.byKey(const Key('fx_input_card_2')))
            .selected,
        isTrue,
      );
    });
  });

  group('the Recorded tracks strip', () {
    testWidgets('lists the tracks and puts All tracks beside the last one', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));

      expect(find.byKey(const Key('fx_track_card_0')), findsOneWidget);
      expect(find.byKey(const Key('fx_track_card_1')), findsOneWidget);
      expect(find.byKey(const Key('fx_all_tracks')), findsOneWidget);
      // In the SAME strip, not a fourth Sound type of its own.
      expect(find.byKey(const Key('fx_track_strip')), findsOneWidget);
    });

    testWidgets('All tracks has no part picker and no placement tag — its '
        'stage is fixed after the recorded mix', (tester) async {
      await pump(tester, destination: const FxDestination.allTracks());

      expect(find.byKey(const Key('fx_part_picker')), findsNothing);
      expect(find.text(l10nOf(tester).fxPlacementPre), findsNothing);
      expect(find.text(l10nOf(tester).fxPlacementPost), findsNothing);
      // And it is the All tracks chain that is showing, not a track's.
      expect(find.text(l10nOf(tester).effectEcho), findsOneWidget);
    });

    testWidgets('switching tracks returns the part picker to Whole track', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_part_picker');
      await tester.tap(find.text('Acoustic guitar').last);
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).fxWholeTrack), findsNothing);

      await tapKey(tester, 'fx_track_card_1');

      // A part index names a lane of the track it was chosen on, so carrying
      // it across would open a stranger's part.
      expect(find.text(l10nOf(tester).fxWholeTrack), findsOneWidget);
    });
  });

  group('the chain', () {
    testWidgets('draws a cable between consecutive effects and a break where '
        'the Pre run ends', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));

      // Three entries: Pre, Pre, Post. One cable between the two Pre cards,
      // and NO cable across the stage break — the loop player is in there.
      expect(find.byKey(const Key('fx_cable_1')), findsOneWidget);
      expect(find.byKey(const Key('fx_cable_2')), findsNothing);
    });

    testWidgets('an output chain carries no placement tag, and a track chain '
        'does', (tester) async {
      await pump(tester, destination: const FxDestination.output(0));
      expect(find.text(l10nOf(tester).fxPlacementPost), findsNothing);

      await tapKey(tester, 'fx_kind_recordedTrack');
      expect(find.text(l10nOf(tester).fxPlacementPost), findsOneWidget);
      expect(find.text(l10nOf(tester).fxPlacementPre), findsNWidgets(2));
    });

    testWidgets('says so when the destination carries nothing', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(1));

      expect(find.byKey(const Key('fx_chain_empty')), findsOneWidget);
    });
  });

  group('power', () {
    testWidgets("writes to the stage's own owner, not one shared setter", (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_power_t3');
      verify(
        () => bloc.add(
          const LooperTrackEffectEnabledToggled(0, 2, enabled: false),
        ),
      ).called(1);

      await tapKey(tester, 'fx_all_tracks');
      await tapKey(tester, 'fx_power_a1');
      verify(
        () => bloc.add(
          const LooperAllTracksEffectEnabledToggled(0, enabled: false),
        ),
      ).called(1);

      await tapKey(tester, 'fx_kind_output');
      await tapKey(tester, 'fx_power_o1');
      verify(
        () => bloc.add(
          const LooperOutputEffectEnabledToggled(0, 0, enabled: false),
        ),
      ).called(1);
    });

    testWidgets("a live input's chain is the monitor cubit's, both to read "
        'and to write', (tester) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      // Read: the two entries the monitor cubit carries, not the projection's.
      expect(find.text(l10nOf(tester).effectDelay), findsOneWidget);

      await tapKey(tester, 'fx_power_m1');

      // Write: through the repository the cubit owns, with no bloc event for
      // a stage the bloc does not own.
      verify(
        () => repository.setMonitorEffectEnabled(
          input: 0,
          index: 0,
          enabled: false,
        ),
      ).called(1);
    });
  });

  group('Add effects', () {
    testWidgets('opens the library on the destination, and one Back from a '
        'completed addition lands on the destination', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_add_effects');

      // The destination is stated once, in the header.
      expect(find.text(l10nOf(tester).fxAddTitle), findsOneWidget);
      expect(
        find.byKey(const Key('fx_library_family_edsguitar')),
        findsOneWidget,
      );

      await tapKey(tester, 'fx_library_family_edsguitar');
      await tapKey(tester, 'fx_preset_ed53e7b8');

      // Back on the page, not on the family it was chosen from: Add, family
      // and preset are not in the completed addition's history.
      expect(find.byKey(const Key('fx_track_strip')), findsOneWidget);
    });

    testWidgets('Back from the library changes nothing', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'loop_settings_back');

      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectsAppended>())));
    });

    testWidgets('a rack becomes one entry per module, in one write', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'fx_library_family_edsguitar');
      await tapKey(tester, 'fx_preset_ed53e7b8');

      final appended =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusEffectsAppended>())),
              ).captured.single
              as LooperBusEffectsAppended;

      // One write, not one per pedal: a half-built rack must not be heard on
      // the way in.
      expect(appended.entries, hasLength(3));
      expect(
        appended.entries.map((e) => (e as BuiltInEffect).type),
        [
          // The table's order, which is not a processing order.
          TrackEffectType.none, // Compressor, which this engine cannot build
          TrackEffectType.delay,
          TrackEffectType.reverb,
        ],
      );
      // The preset's own values reach the parameters they feed.
      final delay = appended.entries[1] as BuiltInEffect;
      expect(delay.params[0], closeTo(0.42, 1e-9));
    });

    testWidgets('every pedal of one rack carries the SAME rack, which is what '
        'makes them one card and one thing to move', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'fx_library_family_edsguitar');
      await tapKey(tester, 'fx_preset_ed53e7b8');

      final appended =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusEffectsAppended>())),
              ).captured.single
              as LooperBusEffectsAppended;

      final racks = appended.entries.map((e) => e.rack).toSet();
      expect(racks, hasLength(1));
      expect(racks.single!.name, 'Acoustic Rhythm 1');
      // The family's own artwork slug, not a slug derived from its folder
      // name — the source does not name those the same way.
      expect(racks.single!.art, 'edsguitar');
      // And the catalogue's own name for each pedal, kept whatever this
      // engine could build for it.
      expect(
        appended.entries.map((e) => e.module),
        ['Compressor', 'Delay', 'Reverb'],
      );
    });

    testWidgets(
      'a single effect belongs to no rack, so it stays its own card',
      (tester) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_single');
        await tapKey(tester, 'fx_single_reverb');

        final appended =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsAppended>()),
                  ),
                ).captured.single
                as LooperBusEffectsAppended;

        expect(appended.entries.single.rack, isNull);
      },
    );

    testWidgets(
      'every added entry arrives bypassed, whatever the preset says',
      (tester) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_family_edsguitar');
        await tapKey(tester, 'fx_preset_ed53e7b8');

        final appended =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsAppended>()),
                  ),
                ).captured.single
                as LooperBusEffectsAppended;

        // The preset engages its compressor and reverb. Adding a rack mid-set
        // must not change the sound until the player says so.
        expect(appended.entries.every((e) => !e.enabled), isTrue);
      },
    );

    testWidgets("an added entry takes the destination's default placement", (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'fx_library_family_rhythmic');
      await tapKey(tester, 'fx_preset_rh-1');

      final appended =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusEffectsAppended>())),
              ).captured.single
              as LooperBusEffectsAppended;

      // A recorded destination defaults Post.
      expect(appended.entries.single.placement, FxPlacement.post);
    });

    testWidgets("a live input's addition goes through the monitor cubit, not "
        'the bloc', (tester) async {
      await pump(tester, destination: const FxDestination.liveInput(0));
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'fx_library_family_rhythmic');
      await tapKey(tester, 'fx_preset_rh-1');

      final pushed =
          verify(
                () => repository.setMonitorEffects(
                  input: 0,
                  effects: captureAny(named: 'effects'),
                ),
              ).captured.last
              as List<TrackEffect>;

      // Appended to the two the input already carries, and Pre — the live
      // input's default. Found by TYPE rather than by position: the chain is
      // stored Pre-first, so an added Pre entry lands before the input's
      // existing Post one.
      expect(pushed, hasLength(3));
      final added = pushed.firstWhere(
        (e) => e is BuiltInEffect && e.type == TrackEffectType.none,
      );
      expect(added.placement, FxPlacement.pre);
      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectsAppended>())));
    });

    testWidgets('a rack that will not fit is offered and explains itself '
        'rather than half-landing', (tester) async {
      // A track chain with one slot free.
      final full = [
        for (var i = 0; i < kTrackEffectMax - 1; i++)
          _fx('f$i', TrackEffectType.drive),
      ];
      await pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: LooperState(
          tracks: [
            Track(effects: full),
            const Track(channel: 1),
          ],
          status: _rig.status,
          outputBusCount: 2,
        ),
      );
      await tapKey(tester, 'fx_add_effects');
      await tapKey(tester, 'fx_library_family_edsguitar');

      // Three modules into one free slot: shown, with the reason.
      expect(
        find.text(
          l10nOf(tester).fxRackTooLong('Acoustic Rhythm 1', 3, 1),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'fx_preset_ed53e7b8');
      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectsAppended>())));
    });

    testWidgets('a build with no catalogue says so instead of drawing an '
        'empty grid', (tester) async {
      await pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        catalogue: FxCatalogue.empty,
      );
      await tapKey(tester, 'fx_add_effects');

      expect(find.byKey(const Key('fx_library_empty')), findsOneWidget);
    });
  });

  group('the effect editor', () {
    testWidgets('opens on the card and shows the effect by name', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_card_t1');

      expect(find.byType(FxEffectEditor), findsOneWidget);
      // Its own controls, directly: the accepted design removed the generic
      // parameter dialog the earlier study opened from a grid.
      expect(find.byKey(const Key('fx_param_0')), findsOneWidget);
      expect(find.byKey(const Key('fx_param_1')), findsOneWidget);
    });

    testWidgets('draws one control per parameter the effect actually has', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      // Filter has two parameters; reverb has three.
      await tapKey(tester, 'fx_card_t1');
      expect(find.byKey(const Key('fx_param_2')), findsNothing);
      await tapKey(tester, 'loop_settings_back');

      await tapKey(tester, 'fx_card_t3');
      expect(find.byKey(const Key('fx_param_2')), findsOneWidget);
    });

    testWidgets("says a control's scale was never recovered rather than "
        'printing a unit nobody verified', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_card_t1');

      expect(
        find.text(l10nOf(tester).fxScaleUnverified),
        findsNWidgets(2),
      );
    });

    group('the Pre/Post switch', () {
      testWidgets('is offered on a recorded track, with the consequence line '
          'that goes with it', (tester) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_card_t1');

        expect(find.byKey(const Key('fx_placement_pre')), findsOneWidget);
        // t1 is Pre, so the line says what Pre means.
        expect(
          find.text(l10nOf(tester).fxPlacementPreHint),
          findsOneWidget,
        );
      });

      testWidgets('moves the instance to the END of the other stage, through '
          "that stage's own owner", (tester) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_card_t1');
        await tapKey(tester, 'fx_placement_post');

        // A whole-chain write, because the switch moves an INSTANCE and an
        // instance can be a rack of six pedals. And to the end of the Post
        // run, not to where it stood: reorder is the separate, cancellable
        // surface that arranges a stage.
        final written =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsChanged>()),
                  ),
                ).captured.single
                as LooperBusEffectsChanged;

        expect(written.address.stage, FxStage.track);
        expect(written.effects.last.slotId, 't1');
        expect(written.effects.last.placement, FxPlacement.post);
        expect(fxPreCount(written.effects), 1);
      });

      testWidgets('is NOT offered on an output, whose stage is fixed after '
          'its own mix', (tester) async {
        await pump(tester, destination: const FxDestination.output(0));
        await tapKey(tester, 'fx_card_o1');

        expect(find.byType(FxEffectEditor), findsOneWidget);
        expect(find.byKey(const Key('fx_placement_pre')), findsNothing);
        expect(find.byKey(const Key('fx_placement_hint')), findsNothing);
      });

      testWidgets('is NOT offered on All tracks either', (tester) async {
        await pump(tester, destination: const FxDestination.allTracks());
        await tapKey(tester, 'fx_card_a1');

        expect(find.byType(FxEffectEditor), findsOneWidget);
        expect(find.byKey(const Key('fx_placement_pre')), findsNothing);
      });
    });

    group('channel handling', () {
      testWidgets('the output choice renames the placement control, because '
          'the same control is doing a different job', (tester) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_card_t1');

        // Stereo out places the two sides against each other.
        expect(find.text(l10nOf(tester).fxBalance), findsOneWidget);
        expect(find.text(l10nOf(tester).fxPan), findsNothing);
      });

      testWidgets('writes input, output and placement as ONE change', (
        tester,
      ) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        await tapKey(tester, 'fx_card_t1');
        await tapKey(tester, 'fx_output_mono');

        final written =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectChannelsChanged>()),
                  ),
                ).captured.single
                as LooperBusEffectChannelsChanged;

        // The one field the control touched changed, and the other three
        // came through untouched: the four are one control, and writing the
        // output alone would silently reset the rest.
        expect(written.channels.output, FxChannelOutput.mono);
        expect(written.channels.input, FxChannelInput.monoSum);
        expect(written.channels.placement, -0.5);
        expect(written.channels.level, 0.8);
        expect(written.index, 0);
      });

      testWidgets('the balance reads Centre at rest rather than a number', (
        tester,
      ) async {
        await pump(tester, destination: const FxDestination.recordedTrack(0));
        // t3 is at its defaults; t1 is deliberately not.
        await tapKey(tester, 'fx_card_t3');

        expect(find.text(l10nOf(tester).fxCentre), findsOneWidget);
      });
    });

    group('the rack', () {
      Future<void> pumpRack(WidgetTester tester) => pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: _rackRig,
      );

      /// The chain the last structural write pushed.
      List<TrackEffect> lastChain() =>
          (verify(
                    () => bloc.add(
                      captureAny(that: isA<LooperBusEffectsChanged>()),
                    ),
                  ).captured.last
                  as LooperBusEffectsChanged)
              .effects;

      testWidgets('is ONE card on the chain, named by the rack and saying how '
          'many pedals it holds', (tester) async {
        await pumpRack(tester);

        // Three modules, one card — and the standalones on either side are
        // still their own.
        expect(find.byKey(const Key('fx_card_R1')), findsOneWidget);
        expect(find.byKey(const Key('fx_card_r1a')), findsNothing);
        expect(find.text('Funk Wah'), findsOneWidget);
        expect(find.text(l10nOf(tester).fxModuleCount(3)), findsOneWidget);
      });

      testWidgets("the card's power writes every pedal, because a rack is one "
          'thing to the player', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_power_R1');

        final written = verify(
          () => bloc.add(
            captureAny(that: isA<LooperTrackEffectEnabledToggled>()),
          ),
        ).captured.cast<LooperTrackEffectEnabledToggled>();

        expect(written.map((e) => e.index), [1, 2, 3]);
        expect(written.every((e) => !e.enabled), isTrue);
      });

      testWidgets('opens into one column per pedal, each with its own power '
          'and controls', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');

        expect(find.byType(FxRackEditor), findsOneWidget);
        expect(find.byKey(const Key('fx_pedal_r1a')), findsOneWidget);
        expect(find.byKey(const Key('fx_pedal_r1b')), findsOneWidget);
        expect(find.byKey(const Key('fx_pedal_r1c')), findsOneWidget);
        // Two cables for three pedals.
        expect(find.byKey(const Key('fx_pedal_cable_1')), findsOneWidget);
        expect(find.byKey(const Key('fx_pedal_cable_2')), findsOneWidget);
      });

      testWidgets("a pedal this build cannot process keeps the catalogue's "
          'name and says so, rather than offering controls that reach '
          'nothing', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');

        expect(find.text('Pumper'), findsOneWidget);
        expect(
          find.text(l10nOf(tester).fxModuleUnavailable),
          findsOneWidget,
        );
      });

      testWidgets("a pedal's own power is its own, not the rack's", (
        tester,
      ) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_pedal_power_r1a');

        final written = verify(
          () => bloc.add(
            captureAny(that: isA<LooperTrackEffectEnabledToggled>()),
          ),
        ).captured.cast<LooperTrackEffectEnabledToggled>();

        expect(written.single.index, 1);
      });

      testWidgets('the footer writes the input to the first pedal and the '
          'level to the last', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tester.drag(
          find.byKey(const Key('fx_rack_level')),
          const Offset(-60, 0),
        );
        await tester.pumpAndSettle();

        final written = verify(
          () => bloc.add(
            captureAny(that: isA<LooperBusEffectChannelsChanged>()),
          ),
        ).captured.cast<LooperBusEffectChannelsChanged>();

        // The last pedal, because that is where the engine applies a level —
        // after the rack's effects, which is what the control says it does.
        expect(written.last.index, 3);
        expect(written.last.channels.level, lessThan(1));
      });

      testWidgets('rename writes every pedal and leaves the rack id alone', (
        tester,
      ) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_options');
        await tapKey(tester, 'fx_option_rename');
        // The console's one keyboard takes physical keys too, which is how a
        // test types into it.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        final chain = lastChain();
        final rack = chain.where((fx) => fx.rack?.id == 'R1').toList();
        expect(rack, hasLength(3));
        expect(rack.every((fx) => fx.rack!.name == 'Funk Wahv'), isTrue);
        // The rack's identity survives its name changing, and the standalone
        // effects on either side are untouched.
        expect(chain.map((fx) => fx.slotId), [
          'p1',
          'r1a',
          'r1b',
          'r1c',
          's1',
        ]);
      });

      testWidgets('Remove rack asks first, saying what it leaves alone, then '
          'takes every pedal and leaves its neighbours', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_options');
        await tapKey(tester, 'fx_option_remove');

        // The accepted rule, said where it matters: removing a rack from a
        // chain leaves the sounds saved from it in My presets.
        expect(find.text(l10nOf(tester).fxRemoveRackBody), findsOneWidget);
        await tester.tap(find.text(l10nOf(tester).fxRemoveRack));
        await tester.pumpAndSettle();

        expect(
          lastChain().map((fx) => fx.slotId),
          ['p1', 's1'],
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      });

      testWidgets('Remove an effect takes one pedal and keeps the rack', (
        tester,
      ) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_options');
        await tapKey(tester, 'fx_option_remove-one');
        await tapKey(tester, 'fx_option_r1b');

        final chain = lastChain();
        expect(chain.map((fx) => fx.slotId), ['p1', 'r1a', 'r1c', 's1']);
        expect(fxChainGroups(chain).map(fxGroupId), ['p1', 'R1', 's1']);
      });

      testWidgets('Reorder effects arranges the pedals inside the rack and '
          'nothing else', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_options');
        await tapKey(tester, 'fx_option_reorder');
        // The first pedal is picked by default; move it right once.
        await tapKey(tester, 'fx_move_right');
        await tapKey(tester, 'fx_reorder_done');

        expect(
          lastChain().map((fx) => fx.slotId),
          ['p1', 'r1b', 'r1a', 'r1c', 's1'],
        );
      });

      testWidgets('Reorder is cancellable: Cancel after several moves writes '
          'nothing at all', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_options');
        await tapKey(tester, 'fx_option_reorder');
        await tapKey(tester, 'fx_move_right');
        await tapKey(tester, 'fx_move_right');
        await tapKey(tester, 'fx_reorder_cancel');

        verifyNever(
          () => bloc.add(any(that: isA<LooperBusEffectsChanged>())),
        );
      });
    });

    group('saved sounds', () {
      Future<void> pumpRack(WidgetTester tester) => pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: _rackRig,
      );

      /// Lets a confirmation toast close, rather than leave its timer
      /// pending past the end of the test.
      Future<void> settleToast(WidgetTester tester) async {
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      }

      /// Types [text] into the console's one keyboard and commits it.
      Future<void> typeName(WidgetTester tester, String text) async {
        for (final unit in text.codeUnits) {
          await tester.sendKeyEvent(
            LogicalKeyboardKey(unit),
            character: String.fromCharCode(unit),
          );
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await settleToast(tester);
      }

      /// Empties the name field, so a test can type its own from scratch.
      Future<void> clearName(WidgetTester tester, int length) async {
        for (var i = 0; i < length; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        }
        await tester.pumpAndSettle();
      }

      testWidgets('Save preset copies the rack under the name the player '
          'gives it, and does NOT rename the rack itself', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_save');
        await clearName(tester, 'Funk Wah'.length);
        await typeName(tester, 'verse');

        final saved = presets.state.single;
        expect(saved.name, 'verse');
        expect(saved.entries, hasLength(3));
        // The instance on the chain is untouched: no write went out at all.
        verifyNever(
          () => bloc.add(any(that: isA<LooperBusEffectsChanged>())),
        );
        expect(find.text('Funk Wah'), findsWidgets);
      });

      testWidgets('a name already taken asks, and Replace rewrites that '
          'definition rather than adding a second row', (tester) async {
        await pumpRack(tester);
        await presets.save(
          name: 'verse',
          entries: [_fx('old', TrackEffectType.echo)],
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_save');
        await clearName(tester, 'Funk Wah'.length);
        await typeName(tester, 'verse');

        expect(find.text(l10nOf(tester).fxPresetExists), findsOneWidget);
        await tapKey(tester, 'fx_option_replace');
        await settleToast(tester);

        expect(presets.state, hasLength(1));
        expect(presets.state.single.entries, hasLength(3));
      });

      testWidgets('cancelling the question keeps the previous preset', (
        tester,
      ) async {
        await pumpRack(tester);
        await presets.save(
          name: 'verse',
          entries: [_fx('old', TrackEffectType.echo)],
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_card_R1');
        await tapKey(tester, 'fx_rack_save');
        await clearName(tester, 'Funk Wah'.length);
        await typeName(tester, 'verse');
        await tapKey(tester, 'fx_options_cancel');

        expect(presets.state.single.entries, hasLength(1));
      });

      testWidgets('My presets lists the saved sounds, and recalling one adds '
          'a NEW instance rather than a reference', (tester) async {
        await pumpRack(tester);
        await presets.save(
          name: 'verse',
          entries: [
            _fx('old1', TrackEffectType.echo),
            _fx('old2', TrackEffectType.reverb),
          ],
          art: 'guitar',
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_saved');

        expect(find.text('verse'), findsOneWidget);
        await tapKey(tester, 'fx_saved_${presets.state.single.id}');

        final appended =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsAppended>()),
                  ),
                ).captured.single
                as LooperBusEffectsAppended;

        // Its own rack, so it is its own thing on the chain; bypassed, like
        // every other addition; and the destination's placement, because
        // placement belongs to where a sound is used, not to the sound.
        final racks = appended.entries.map((e) => e.rack).toSet();
        expect(racks, hasLength(1));
        expect(racks.single!.name, 'verse');
        expect(racks.single!.id, isNot('R1'));
        expect(appended.entries.every((e) => !e.enabled), isTrue);
        expect(
          appended.entries.every((e) => e.placement == FxPlacement.post),
          isTrue,
        );
      });

      testWidgets('a saved single effect recalls as a single effect, not a '
          'rack of one', (tester) async {
        await pumpRack(tester);
        await presets.save(
          name: 'just echo',
          entries: [_fx('old', TrackEffectType.echo)],
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_saved');
        await tapKey(tester, 'fx_saved_${presets.state.single.id}');

        final appended =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsAppended>()),
                  ),
                ).captured.single
                as LooperBusEffectsAppended;

        expect(appended.entries.single.rack, isNull);
      });

      testWidgets('My presets says so when nothing has been saved', (
        tester,
      ) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_saved');

        expect(find.byKey(const Key('fx_saved_empty')), findsOneWidget);
      });

      testWidgets('Delete asks first and says what it does not affect', (
        tester,
      ) async {
        await pumpRack(tester);
        await presets.save(
          name: 'verse',
          entries: [_fx('old', TrackEffectType.echo)],
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_saved');
        await tapKey(tester, 'fx_saved_delete_${presets.state.single.id}');

        expect(
          find.text(l10nOf(tester).fxPresetDeleteBody),
          findsOneWidget,
        );
        await tester.tap(find.text(l10nOf(tester).fxPresetDelete).last);
        await tester.pumpAndSettle();

        expect(presets.state, isEmpty);
      });

      testWidgets('moving a preset off this console is drawn and inert, '
          'because that domain is not built', (tester) async {
        await pumpRack(tester);
        await presets.save(
          name: 'verse',
          entries: [_fx('old', TrackEffectType.echo)],
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_add_effects');
        await tapKey(tester, 'fx_library_saved');

        for (final key in [
          'fx_presets_import',
          'fx_presets_export_all',
          'fx_saved_export_${presets.state.single.id}',
        ]) {
          expect(
            tester.widget<LoopOutlinedButton>(find.byKey(Key(key))).onTap,
            isNull,
            reason: key,
          );
        }
      });
    });

    group('reordering the destination chain', () {
      Future<void> pumpRack(WidgetTester tester) => pump(
        tester,
        destination: const FxDestination.recordedTrack(0),
        state: _rackRig,
      );

      testWidgets('arranges whole racks, not their pedals', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_reorder');

        // Three cards for five entries: the Pre standalone, the rack, and the
        // Post standalone.
        expect(find.byKey(const Key('fx_reorder_p1')), findsOneWidget);
        expect(find.byKey(const Key('fx_reorder_R1')), findsOneWidget);
        expect(find.byKey(const Key('fx_reorder_s1')), findsOneWidget);
        expect(find.byKey(const Key('fx_reorder_r1a')), findsNothing);
      });

      testWidgets('will not carry a card across the Pre/Post break', (
        tester,
      ) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_reorder');

        // p1 is the only Pre card, so it has nowhere to go: moving it right
        // would put it in the Post run, which only the explicit switch does.
        final right = tester.widget<LoopOutlinedButton>(
          find.byKey(const Key('fx_move_right')),
        );
        expect(right.onTap, isNull);
        // And no cable is drawn across the break.
        expect(find.byKey(const Key('fx_reorder_cable_1')), findsNothing);
      });

      testWidgets('commits the new order on Done', (tester) async {
        await pumpRack(tester);
        await tapKey(tester, 'fx_reorder');
        await tester.tap(find.byKey(const Key('fx_reorder_R1')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'fx_move_right');
        await tapKey(tester, 'fx_reorder_done');

        final written =
            verify(
                  () => bloc.add(
                    captureAny(that: isA<LooperBusEffectsChanged>()),
                  ),
                ).captured.single
                as LooperBusEffectsChanged;

        expect(
          written.effects.map((fx) => fx.slotId),
          ['p1', 's1', 'r1a', 'r1b', 'r1c'],
        );
      });
    });

    testWidgets("a live input's edits go through the monitor cubit", (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.liveInput(0));
      await tapKey(tester, 'fx_card_m1');
      await tapKey(tester, 'fx_placement_post');

      final pushed =
          verify(
                () => repository.setMonitorEffects(
                  input: 0,
                  effects: captureAny(named: 'effects'),
                ),
              ).captured.last
              as List<TrackEffect>;

      // Through the cubit that owns the Input stage, and re-placed at the end
      // of its destination stage rather than edited where it stood.
      final moved = pushed.firstWhere((e) => e.slotId == 'm1');
      expect(moved.placement, FxPlacement.post);
      expect(pushed.last.slotId, 'm1');
      verifyNever(
        () => bloc.add(any(that: isA<LooperBusEffectChannelsChanged>())),
      );
    });
  });
}
