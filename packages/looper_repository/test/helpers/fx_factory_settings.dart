import 'dart:io';
import 'dart:typed_data';

import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';

/// Where the effects matrix (#1547) reads the factory presets' settings
/// from, relative to this package.
const String kFxFactorySettingsPath =
    '../segno_engine/src/test/bench/fx_factory_settings.inc';

/// Every distinct built-in entry the factory racks build, as C initializers
/// of `bench_fx_matrix.c`'s `mx_setting`: the rack, preset and module that
/// first build it, the native type code and the entry's parameters as the
/// engine receives them (`setLaneFxParam` sends each one as is).
///
/// Read from the catalogue's own files in [presetsDir] through
/// [fxRackEntries], so it is what the Effects library loads. Entries the
/// engine cannot build (no type) are left out, and so are repeats of a type
/// and settings already listed.
String fxFactorySettingsInc({
  String presetsDir = '../fx_catalogue/assets/presets',
}) {
  final out = StringBuffer()
    ..writeln(
      '/* GENERATED from packages/fx_catalogue/assets/presets by',
    )
    ..writeln(
      ' * packages/looper_repository/tool/generate_fx_factory_settings.dart.',
    )
    ..writeln(
      ' * Do not edit; fx_factory_settings_test.dart checks it is current.',
    )
    ..writeln(' * Included by bench_fx_matrix.c (#1547). */');
  final seen = <String>{};
  final families =
      Directory(presetsDir).listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final dir in families) {
    final family = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.fxpreset'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final preset = FxPreset.tryParse(family, file.readAsStringSync());
      if (preset == null) continue;
      for (final entry in fxRackEntries(preset)) {
        if (entry.type == TrackEffectType.none) continue;
        final width = entry.type.params.length;
        // As the engine holds them: the FFI passes each value as a float.
        final params = Float32List.fromList(entry.params.sublist(0, width));
        final values = [for (final v in params) '${_literal(v)}f'];
        final key = '${entry.type.code} ${values.join(' ')}';
        if (!seen.add(key)) continue;
        final name = '$family / ${preset.name} / ${entry.module}'
            .replaceAll(r'\', r'\\')
            .replaceAll('"', r'\"');
        out.writeln(
          '{"$name", ${entry.type.code}, {${values.join(', ')}}},',
        );
      }
    }
  }
  return out.toString();
}

/// [v] as a C literal that reads back as the same float: its shortest
/// double form, which C rounds to the nearest float, [v] itself.
String _literal(double v) {
  final s = v.toString();
  return s.contains('.') || s.contains('e') ? s : '$s.0';
}
