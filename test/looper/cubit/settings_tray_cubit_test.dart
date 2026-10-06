import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
