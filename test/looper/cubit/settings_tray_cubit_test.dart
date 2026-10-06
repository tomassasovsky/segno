import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';

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
        ..showDestination(SettingsTrayDestination.control)
        ..showControlTab(ControlTab.controllers)
        ..closeTray(),
      expect: () => [
        const SettingsTrayState(dragProgress: 1),
        const SettingsTrayState(
          dragProgress: 1,
          controlTab: ControlTab.controllers,
        ),
        // Closing puts the destination back to the landing face and leaves
        // the tab where it was: reopening Control lands on Controllers.
        const SettingsTrayState(controlTab: ControlTab.controllers),
      ],
    );

    blocTest<SettingsTrayCubit, SettingsTrayState>(
      'showDestination switches face without touching dragProgress — the '
      'rail must never become a second say in whether the tray is open',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit
        ..showDestination(SettingsTrayDestination.network)
        ..showDestination(SettingsTrayDestination.system),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          destination: SettingsTrayDestination.network,
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
      'showControlTab moves the tab and does NOT touch the destination — the '
      'strip is only reachable while Control is already showing',
      build: buildCubit,
      seed: () => const SettingsTrayState(dragProgress: 1),
      act: (cubit) => cubit.showControlTab(ControlTab.controllers),
      expect: () => [
        const SettingsTrayState(
          dragProgress: 1,
          controlTab: ControlTab.controllers,
        ),
      ],
    );
  });
}
