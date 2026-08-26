import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

/// The D1-deferred replacement tests (#453): the device-lost / MIDI-lost
/// coverage deleted with the toast rewrite, finally written against the
/// persistent surface it was waiting for.
void main() {
  const deviceKey = Key('connectivity_banner_device');
  const midiKey = Key('connectivity_banner_midi');

  const deviceLostState = AudioSetupState(
    deviceConnectivity: DeviceConnectivity.lost,
    connectivityDeviceName: 'Scarlett 2i2',
  );
  const midiLostState = MidiSetupState(
    connection: MidiConnection(
      selectedId: 'fcb1010',
      selectedName: 'FCB1010',
      connectivity: MidiConnectivity.lost,
      connectivityDeviceName: 'FCB1010',
    ),
  );

  late AppLocalizations l10n;
  late _MockAudioSetupCubit audioSetup;
  late _MockMidiSetupCubit midiSetup;
  late SettingsTrayCubit tray;

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
    midiSetup = _MockMidiSetupCubit();
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: const MidiSetupState(),
    );
    tray = SettingsTrayCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    addTearDown(tray.close);
  });

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: audioSetup),
        BlocProvider<MidiSetupCubit>.value(value: midiSetup),
        BlocProvider<SettingsTrayCubit>.value(value: tray),
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
    expect(find.byKey(midiKey), findsNothing);
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

  testWidgets('MIDI-lost holds the amber banner', (tester) async {
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: midiLostState,
    );
    await pump(tester);

    expect(find.byKey(deviceKey), findsNothing);
    expect(find.byKey(midiKey), findsOneWidget);
    expect(find.text(l10n.midiLostBanner), findsOneWidget);
    expect(find.text(l10n.midiLostBannerAction), findsOneWidget);

    final s = surface(tester);
    final decoration = decorationOf(tester, midiKey);
    expect(decoration.color, s.warningTint);
    expect(decoration.border, Border.all(color: s.warningLine));
  });

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

  testWidgets('both lost stack in severity order — device first, flush', (
    tester,
  ) async {
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: deviceLostState,
    );
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: midiLostState,
    );
    await pump(tester);

    expect(find.byKey(deviceKey), findsOneWidget);
    expect(find.byKey(midiKey), findsOneWidget);
    // Device above MIDI, flush as the pen stacks them.
    final deviceBottom = tester.getBottomLeft(find.byKey(deviceKey));
    final midiTop = tester.getTopLeft(find.byKey(midiKey));
    expect(deviceBottom.dy, midiTop.dy);
    expect(
      tester.getTopLeft(find.byKey(deviceKey)).dy,
      lessThan(midiTop.dy),
    );
  });

  testWidgets('Choose device opens the tray at Audio / Device', (
    tester,
  ) async {
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: deviceLostState,
    );
    await pump(tester);

    await tester.tap(
      find.byKey(const Key('connectivity_banner_device_action')),
    );
    await tester.pump();

    expect(tray.state.dragProgress, 1);
    expect(tray.state.destination, SettingsTrayDestination.audio);
    expect(tray.state.audioTab, AudioTab.device);
  });

  testWidgets('Control opens the tray at the Control domain', (tester) async {
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: midiLostState,
    );
    await pump(tester);

    await tester.tap(find.byKey(const Key('connectivity_banner_midi_action')));
    await tester.pump();

    expect(tray.state.dragProgress, 1);
    expect(tray.state.destination, SettingsTrayDestination.control);
  });
}
