import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/tracks_tab.dart';
import 'package:segno/network/network_tab.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _FakeBrightnessClient implements BrightnessClient {
  bool supported = true;
  double current = 0.8;
  final sets = <double>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<double> get() async => current;

  @override
  Future<void> set(double value) async {
    sets.add(value);
    current = value;
  }
}

void main() {
  late SettingsRepository settings;
  late _FakeBrightnessClient brightness;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    brightness = _FakeBrightnessClient();
  });

  SettingsTrayCubit buildCubit() => SettingsTrayCubit(
    settings: settings,
    brightnessClient: brightness,
  );

  group('SettingsTrayCubit', () {
    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'open / closeTray / toggle',
      build: buildCubit,
      act: (cubit) => cubit
        ..open()
        ..closeTray()
        ..toggle()
        ..toggle(),
      expect: () => [
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(),
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'openAudioDevice opens at Audio on the Device tab — the device-lost '
      'banner action (#453)',
      build: buildCubit,
      // Park Audio on a different tab first: the banner's whole point is the
      // picker, so the action must move the tab, not land on a leftover.
      act: (cubit) => cubit
        ..showAudioTab(AudioTab.recording)
        ..openAudioDevice(),
      expect: () => [
        const SettingsTrayState(audioTab: AudioTab.recording),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.audio,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'dragTo clamps and settleFromDrag snaps',
      build: buildCubit,
      act: (cubit) => cubit
        ..dragTo(0.6)
        ..settleFromDrag()
        ..dragTo(0.4)
        ..settleFromDrag(),
      expect: () => [
        const SettingsTrayState(dragProgress: 0.6),
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(dragProgress: 0.4),
        const SettingsTrayState(),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'load restores brightness and applies when supported',
      build: buildCubit,
      setUp: () async {
        await settings.saveBrightness(0.55);
      },
      act: (cubit) => cubit.load(),
      expect: () => [const SettingsTrayState(brightness: 0.55)],
      verify: (_) {
        expect(brightness.sets, [0.55]);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'setBrightness persists and applies when supported',
      build: buildCubit,
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.3);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.3),
      ],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.3);
        expect(brightness.sets.last, 0.3);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'setBrightness skips apply when unsupported',
      build: buildCubit,
      setUp: () {
        brightness.supported = false;
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.4);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.4),
      ],
      verify: (_) {
        expect(brightness.sets, isEmpty);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'delegates brightness to DisplayBrightnessCubit when provided',
      build: () => SettingsTrayCubit(
        settings: settings,
        brightnessClient: brightness,
        displayBrightness: DisplayBrightnessCubit(
          settings: settings,
          client: brightness,
        ),
      ),
      setUp: () {
        brightness.supported = false;
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.setBrightness(0.35);
      },
      expect: () => [
        const SettingsTrayState(),
        const SettingsTrayState(brightness: 0.35),
      ],
      verify: (_) async {
        expect(await settings.loadBrightness(), 0.35);
        // DDC unsupported — DisplayBrightnessCubit still owns persistence;
        // software dim is applied by App via the cubit state.
        expect(brightness.sets, isEmpty);
      },
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'a domain opened at a tab survives closeTray, which resets only where',
      build: buildCubit,
      act: (cubit) => cubit
        ..open()
        ..showDestination(SettingsTrayDestination.network)
        ..showNetworkTab(NetworkTab.bluetooth)
        ..closeTray(),
      expect: () => [
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
        ),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
          networkTab: NetworkTab.bluetooth,
        ),
        // Closing puts the destination back to the landing face and leaves
        // the tab where it was: reopening Network lands on Bluetooth.
        const SettingsTrayState(networkTab: NetworkTab.bluetooth),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showDestination switches face without touching dragProgress — the '
      'rail must never become a second say in whether the tray is open',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit
        ..showDestination(SettingsTrayDestination.tuner)
        ..showDestination(SettingsTrayDestination.system),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.tuner,
        ),
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.system,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showDestination on a closed tray leaves it closed',
      build: buildCubit,
      act: (cubit) => cubit.showDestination(SettingsTrayDestination.network),
      expect: () => [
        const SettingsTrayState(
          destination: SettingsTrayDestination.network,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showNetworkTab moves the tab and does NOT touch the destination — the '
      'strip is only reachable while Network is already showing',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.showNetworkTab(NetworkTab.bluetooth),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          networkTab: NetworkTab.bluetooth,
        ),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showTracksTab moves the tab and leaves the destination alone, so the '
      'domain lands where it was left',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.showTracksTab(TracksTab.routing),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          tracksTab: TracksTab.routing,
        ),
      ],
    );
  });

  group('the Signal card selection', () {
    test('selecting opens, re-selecting the same card closes', () {
      final cubit = SettingsTrayCubit(settings: settings);
      addTearDown(cubit.close);
      const card = FxAddress(stage: FxStage.loop, index: 2, lane: 1);

      cubit.selectSignalCard(card);
      expect(cubit.state.signalSelection, card);

      // A disclosure that cannot be shut leaves no way back to the plain run.
      cubit.selectSignalCard(card);
      expect(cubit.state.signalSelection, isNull);
    });

    test('a different card replaces rather than closes', () {
      final cubit = SettingsTrayCubit(settings: settings);
      addTearDown(cubit.close);
      cubit
        ..selectSignalCard(const FxAddress(stage: FxStage.input))
        ..selectSignalCard(const FxAddress(stage: FxStage.input, index: 1));

      expect(
        cubit.state.signalSelection,
        const FxAddress(stage: FxStage.input, index: 1),
      );
    });

    test('changing stage clears it', () {
      final cubit = SettingsTrayCubit(settings: settings);
      addTearDown(cubit.close);
      cubit
        ..selectSignalCard(const FxAddress(stage: FxStage.input))
        ..showSignalTab(FxStage.master);

      expect(cubit.state.signalSelection, isNull);
      expect(cubit.state.signalTab, FxStage.master);
    });

    test('copyWith cannot clear it by accident, only by flag', () {
      const open = SettingsTrayState(
        signalSelection: FxAddress(stage: FxStage.master),
      );
      // `?? this` can never clear — the flag is what makes null reachable.
      expect(open.copyWith().signalSelection, isNotNull);
      expect(open.copyWith(brightness: 0.2).signalSelection, isNotNull);
      expect(open.copyWith(clearSignalSelection: true).signalSelection, isNull);
    });
  });
}
