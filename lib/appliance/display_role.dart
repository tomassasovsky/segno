import 'package:segno/visualizer/screen_link.dart';
import 'package:settings_repository/settings_repository.dart';

export 'package:settings_repository/settings_repository.dart' show DisplayRole;

/// The screen each panel shows, by the role name the embedder gives it
/// (`--segno-screen=`, homescreen.toml).
extension DisplayRoleScreen on DisplayRole {
  /// The [SegnoScreen] this panel shows.
  SegnoScreen get screen => switch (this) {
    DisplayRole.main => SegnoScreen.main,
    DisplayRole.track => SegnoScreen.readout,
  };
}

/// Each role's connector from the embedder's [connectors] (`screen ->
/// connector`); a role whose screen has no connector is left out.
Map<DisplayRole, String> displayConnectors(Map<String, String> connectors) => {
  for (final role in DisplayRole.values) role: ?connectors[role.screen.name],
};
