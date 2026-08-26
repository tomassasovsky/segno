import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

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
    tray = SettingsTrayCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    addTearDown(tray.close);
  });

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: audioSetup),
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

  testWidgets('Open setup opens the tray at Audio / Device', (tester) async {
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
}
