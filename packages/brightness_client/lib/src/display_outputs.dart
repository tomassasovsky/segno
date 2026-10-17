import 'dart:io';

import 'package:toml/toml.dart';

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
    } on TomlParserException {
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
/// Dart arguments name (`--segno-screen=<role>`) and its
/// `output.drm_connector`.
///
/// A view without both pins nothing: an empty connector would reach whichever
/// display the helper finds first. Throws [TomlParserException] when [toml]
/// is not TOML.
Map<String, String> parseHomescreenScreenConnectors(String toml) {
  final views = TomlDocument.parse(toml).toMap()['view'];
  if (views is! List) return const {};
  final connectors = <String, String>{};
  for (final view in views.whereType<Map<String, dynamic>>()) {
    final args = view['args'];
    final dart = args is Map ? args['dart'] : null;
    final output = view['output'];
    final connector = output is Map ? output['drm_connector'] : null;
    if (dart is! List || connector is! String || connector.isEmpty) continue;
    for (final arg in dart.whereType<String>()) {
      if (arg.startsWith(_screenArg)) {
        connectors[arg.substring(_screenArg.length)] = connector;
      }
    }
  }
  return connectors;
}

const _screenArg = '--segno-screen=';
