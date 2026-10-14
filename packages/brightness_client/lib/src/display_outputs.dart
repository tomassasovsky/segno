import 'dart:io';

/// Which connector each screen is drawn on, and whether a panel is plugged
/// into it. File reads only: no helper, no fork.
abstract class DisplayOutputs {
  /// The connector each screen is drawn on (`main -> HDMI-A-1`), by the role
  /// name the embedder gives it (`--segno-screen=`). Empty when the embedder's
  /// configuration cannot be read.
  Future<Map<String, String>> screenConnectors();

  /// Whether a panel is attached to [connector]; `null` when that is not
  /// known (no such connector, or no DRM status to read).
  Future<bool?> isConnected(String connector);
}

/// No outputs known: the macOS dev host.
class UnknownDisplayOutputs implements DisplayOutputs {
  /// Creates an [UnknownDisplayOutputs].
  const UnknownDisplayOutputs();

  @override
  Future<Map<String, String>> screenConnectors() async => const {};

  @override
  Future<bool?> isConnected(String connector) async => null;
}

/// The appliance's outputs: each view's `drm_connector` in ivi-homescreen's
/// configuration, and the DRM connector status under sysfs.
class SystemDisplayOutputs implements DisplayOutputs {
  /// Creates a [SystemDisplayOutputs]; the paths are overridable for tests.
  const SystemDisplayOutputs({
    this.homescreenConfig = '/etc/segno/homescreen.toml',
    this.drmRoot = '/sys/class/drm',
  });

  /// The embedder configuration that puts each screen on an output.
  final String homescreenConfig;

  /// Where the DRM connectors (`card0-HDMI-A-1`) are listed.
  final String drmRoot;

  @override
  Future<Map<String, String>> screenConnectors() async {
    try {
      return parseHomescreenScreenConnectors(
        await File(homescreenConfig).readAsString(),
      );
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

/// Factory: the embedder's outputs on a Linux appliance that has its
/// configuration, else unknown.
DisplayOutputs createDisplayOutputs() {
  const system = SystemDisplayOutputs();
  if (!Platform.isLinux || !File(system.homescreenConfig).existsSync()) {
    return const UnknownDisplayOutputs();
  }
  return system;
}

/// Reads ivi-homescreen's configuration: for each `[[view]]`, the screen its
/// Dart arguments name (`--segno-screen=<role>`) and its `drm_connector`.
///
/// Only the two keys this needs are read, line by line: a view's keys sit in
/// its own table or its `[view.*]` sub-tables, until the next `[[view]]` or
/// another top-level table. A view without both pins nothing: an empty
/// connector would reach whichever display the helper finds first.
Map<String, String> parseHomescreenScreenConnectors(String toml) {
  final connectors = <String, String>{};
  var inView = false;
  String? screen;
  String? connector;
  void flush() {
    if (inView && screen != null && (connector?.isNotEmpty ?? false)) {
      connectors[screen!] = connector!;
    }
    screen = null;
    connector = null;
  }

  final screenArg = RegExp("""['"]--segno-screen=([^'"]+)['"]""");
  final quoted = RegExp(r"""^\s*['"]([^'"]*)['"]""");
  for (final raw in toml.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[[')) {
      flush();
      inView = line == '[[view]]';
      continue;
    }
    if (line.startsWith('[')) {
      // `[view.args]` and the like stay inside the current view.
      if (!line.startsWith('[view.')) {
        flush();
        inView = false;
      }
      continue;
    }
    if (!inView) continue;
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 1);
    if (key == 'dart') screen = screenArg.firstMatch(value)?.group(1) ?? screen;
    if (key == 'drm_connector') {
      connector = quoted.firstMatch(value)?.group(1) ?? connector;
    }
  }
  flush();
  return connectors;
}
