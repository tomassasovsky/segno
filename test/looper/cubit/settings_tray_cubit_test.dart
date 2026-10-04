import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/network/network_tab.dart';

void main() {
  SettingsTrayCubit buildCubit() => SettingsTrayCubit();

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
  });
}
