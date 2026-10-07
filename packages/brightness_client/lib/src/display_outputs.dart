import 'dart:io';

/// Which connector each app window is shown on, and whether a panel is
/// plugged into it. File reads only: no helper, no fork.
abstract class DisplayOutputs {
  /// The connector each pinned app-id is placed on (`app-id -> HDMI-A-1`).
  /// Empty when the compositor's pins cannot be read.
  Future<Map<String, String>> appIdConnectors();

  /// Whether a panel is attached to [connector]; `null` when that is not
  /// known (no such connector, or no DRM status to read).
  Future<bool?> isConnected(String connector);
}

/// No outputs known: a desktop, where the windows are placed by the OS.
class UnknownDisplayOutputs implements DisplayOutputs {
  /// Creates an [UnknownDisplayOutputs].
  const UnknownDisplayOutputs();

  @override
  Future<Map<String, String>> appIdConnectors() async => const {};

  @override
  Future<bool?> isConnected(String connector) async => null;
}

/// The appliance's outputs: the `[output]` `app-ids` pins in weston.ini, and
/// the DRM connector status under sysfs.
class SystemDisplayOutputs implements DisplayOutputs {
  /// Creates a [SystemDisplayOutputs]; the paths are overridable for tests.
  const SystemDisplayOutputs({
    this.westonIni = '/etc/xdg/weston/weston.ini',
    this.drmRoot = '/sys/class/drm',
  });

  /// The compositor configuration that pins each window to an output.
  final String westonIni;

  /// Where the DRM connectors (`card0-HDMI-A-1`) are listed.
  final String drmRoot;

  @override
  Future<Map<String, String>> appIdConnectors() async {
    try {
      return parseWestonAppIdConnectors(await File(westonIni).readAsString());
    } on FileSystemException {
      return const {};
    }
  }

  @override
  Future<bool?> isConnected(String connector) async {
    final root = Directory(drmRoot);
    try {
      await for (final entry in root.list(followLinks: false)) {
        final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (!name.startsWith('card') || !name.endsWith('-$connector')) {
          continue;
        }
        final status = await File('${entry.path}/status').readAsString();
        return switch (status.trim()) {
          'connected' => true,
          'disconnected' => false,
          _ => null,
        };
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}

/// Factory: the compositor's outputs on a Linux appliance that has the
/// weston configuration, else unknown.
DisplayOutputs createDisplayOutputs() {
  const system = SystemDisplayOutputs();
  if (!Platform.isLinux || !File(system.westonIni).existsSync()) {
    return const UnknownDisplayOutputs();
  }
  return system;
}

/// Reads weston.ini's `[output]` sections: each `name=` connector with the
/// app-ids its `app-ids=` list pins there (comma separated, exact tokens, as
/// kiosk-shell matches them).
Map<String, String> parseWestonAppIdConnectors(String ini) {
  final pins = <String, String>{};
  String? section;
  String? name;
  var appIds = <String>[];
  void flush() {
    // An output with no name pins nothing: an empty connector would reach
    // whichever display the helper finds first.
    if (section == 'output' && (name?.isNotEmpty ?? false)) {
      for (final id in appIds) {
        pins[id] = name!;
      }
    }
    name = null;
    appIds = <String>[];
  }

  for (final raw in ini.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      flush();
      section = line.substring(1, line.length - 1).trim();
      continue;
    }
    final eq = line.indexOf('=');
    if (eq < 0 || section != 'output') continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 1).trim();
    if (key == 'name') name = value;
    if (key == 'app-ids') {
      appIds = [
        for (final id in value.split(','))
          if (id.trim().isNotEmpty) id.trim(),
      ];
    }
  }
  flush();
  return pins;
}
