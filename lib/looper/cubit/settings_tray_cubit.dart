import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

part 'settings_tray_state.dart';

/// Drives the console's slide-down tray, which holds only the tuner.
///
/// The tray's other faces, its navigation rail and the brightness capsule
/// moved to Settings destinations and the FX page (#1199); the tray itself
/// goes once the tuner has its foot function. Its drag state is ephemeral.
class SettingsTrayCubit extends Cubit<SettingsTrayState> {
  /// Creates a [SettingsTrayCubit].
  SettingsTrayCubit() : super(const SettingsTrayState());

  /// Live drag progress, clamped to `0..1`. Called every
  /// `onVerticalDragUpdate` frame while the handle is being dragged.
  void dragTo(double progress) {
    emit(SettingsTrayState(dragProgress: progress.clamp(0.0, 1.0)));
  }

  /// Settles a released drag: past the 50% distance threshold snaps open,
  /// otherwise closed. Distance-only — no velocity/fling threshold.
  void settleFromDrag() {
    if (state.dragProgress > 0.5) {
      open();
    } else {
      closeTray();
    }
  }

  /// Opens the tray (tap-on-handle, or programmatic).
  void open() => emit(const SettingsTrayState(dragProgress: 1));

  /// Closes the tray. Named `closeTray` rather than `close` — the latter is
  /// `Cubit.close()`, which disposes the bloc's stream; overriding it here
  /// would be a hard invalid-override error, not a UI action.
  void closeTray() => emit(const SettingsTrayState());

  /// Toggles open/closed. Only ever called from a tap (never mid-drag), so
  /// `dragProgress` is always settled at exactly `0` or `1` here.
  void toggle() {
    if (state.dragProgress > 0) {
      closeTray();
    } else {
      open();
    }
  }
}
