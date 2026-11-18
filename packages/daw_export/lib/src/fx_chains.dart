import 'dart:convert';
import 'dart:io';

import 'package:daw_export/src/effect_text.dart';
import 'package:daw_export/src/manifest_json.dart';

/// Writes `fx-chains.txt`: the effect chains a capture's arm snapshot
/// recorded for each looper track, input and the captured output, under the
/// names the Live set gives those tracks (see [EffectText]).
abstract final class FxChainsWriter {
  /// The summary for the capture in [captureDir], or `null` when its
  /// `performance.json` is missing or does not read.
  static String? render(String captureDir) {
    final file = File('$captureDir/performance.json');
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final manifest = decoded;

    final sections = <(String, String)>[];
    final channels = {
      for (final t in tracksOf(manifest['armSnapshot']))
        if (t['channel'] case final num c) c.toInt(),
    }.toList()..sort();
    for (final channel in channels) {
      final text = EffectText.track(manifest, channel, details: true);
      if (text != null) sections.add((trackNameOf(manifest, channel), text));
    }
    for (final input in capturedInputsOf(manifest)) {
      final text = EffectText.input(manifest, input, details: true);
      if (text != null) sections.add((inputNameOf(manifest, input), text));
    }
    final output = EffectText.output(manifest, details: true);
    if (output != null) sections.add((kMasterTrackName, output));

    final buffer = StringBuffer()
      ..writeln('Effects when the take started. Changes made during the')
      ..writeln('take are in events.log.')
      ..writeln();
    if (sections.isEmpty) buffer.writeln('No effects were recorded.');
    for (final (name, text) in sections) {
      buffer.writeln('$name:');
      for (final line in text.split('\n')) {
        buffer.writeln('  $line');
      }
    }
    return buffer.toString();
  }
}
