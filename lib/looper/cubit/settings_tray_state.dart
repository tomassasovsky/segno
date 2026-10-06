part of 'settings_tray_cubit.dart';

/// Ephemeral tray drag state.
class SettingsTrayState extends Equatable {
  /// Creates a [SettingsTrayState].
  const SettingsTrayState({this.dragProgress = 0});

  /// Live drag/settle progress in `0..1` — `0` fully closed, `1` fully open.
  /// Driven every frame during a drag; jumps to its final value on settle
  /// (the view animates the visual transition to that value itself). The
  /// view drives all tray rendering from this one field — there is no
  /// separate "is it open" bit to keep in sync, since between drags this is
  /// always settled at exactly `0` or `1`.
  final double dragProgress;

  @override
  List<Object?> get props => [dragProgress];
}
