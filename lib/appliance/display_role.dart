import 'package:settings_repository/settings_repository.dart';

export 'package:settings_repository/settings_repository.dart' show DisplayRole;

/// The window each panel shows, by the app-id the compositor pins it with
/// (`linux/runner/my_application.cc`).
extension DisplayRoleWindow on DisplayRole {
  /// The xdg app-id of the window this panel shows.
  String get appId => switch (this) {
    DisplayRole.main => 'dev.aquiles.segno',
    DisplayRole.track => 'dev.aquiles.segno.waveform',
  };
}

/// Each role's connector from the compositor's [pins] (`app-id ->
/// connector`); a role whose window is not pinned is left out.
Map<DisplayRole, String> displayConnectors(Map<String, String> pins) => {
  for (final role in DisplayRole.values) role: ?pins[role.appId],
};
