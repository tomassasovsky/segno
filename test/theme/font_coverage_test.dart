import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/pitch.dart';

/// The font files of every family `pubspec.yaml` bundles, by family.
Map<String, List<String>> _bundledFamilies() {
  final families = <String, List<String>>{};
  List<String>? current;
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    final family = RegExp(r'^    - family: (.+)$').firstMatch(line);
    if (family != null) {
      current = families[family.group(1)!.trim()] = [];
      continue;
    }
    final asset = RegExp(r'^        - asset: (.+)$').firstMatch(line);
    if (asset != null) current?.add(asset.group(1)!.trim());
  }
  return families;
}

/// The code points a TrueType font maps to a glyph, read from the Unicode
/// subtables of its `cmap` table (formats 4 and 12, the two the bundled
/// faces use).
Set<int> _codePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int? cmap;
  for (var i = 0; i < data.getUint16(4); i++) {
    final record = 12 + 16 * i;
    if (String.fromCharCodes(bytes, record, record + 4) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  if (cmap == null) throw const FormatException('no cmap table');
  final points = <int>{};
  for (var i = 0; i < data.getUint16(cmap + 2); i++) {
    final record = cmap + 4 + 8 * i;
    final platform = data.getUint16(record);
    final encoding = data.getUint16(record + 2);
    // Unicode, or Windows Unicode BMP (1) and full repertoire (10).
    if (platform != 0 &&
        !(platform == 3 && (encoding == 1 || encoding == 10))) {
      continue;
    }
    final table = cmap + data.getUint32(record + 4);
    switch (data.getUint16(table)) {
      case 4:
        final segments = data.getUint16(table + 6) ~/ 2;
        final ends = table + 14;
        final starts = ends + 2 * segments + 2;
        final deltas = starts + 2 * segments;
        final offsets = deltas + 2 * segments;
        for (var s = 0; s < segments; s++) {
          final start = data.getUint16(starts + 2 * s);
          final end = data.getUint16(ends + 2 * s);
          final delta = data.getUint16(deltas + 2 * s);
          final offset = data.getUint16(offsets + 2 * s);
          for (var c = start; c <= end; c++) {
            if (c == 0xFFFF) continue;
            var glyph = offset == 0
                ? c
                : data.getUint16(offsets + 2 * s + offset + 2 * (c - start));
            if (offset != 0 && glyph == 0) continue;
            glyph = (glyph + delta) & 0xFFFF;
            if (glyph != 0) points.add(c);
          }
        }
      case 12:
        for (var g = 0; g < data.getUint32(table + 12); g++) {
          final group = table + 16 + 12 * g;
          final start = data.getUint32(group);
          final end = data.getUint32(group + 4);
          final first = data.getUint32(group + 8);
          for (var c = start; c <= end; c++) {
            if (first + c - start != 0) points.add(c);
          }
        }
    }
  }
  return points;
}

/// The code points every face of [family] maps.
Set<int> _familyCodePoints(Map<String, List<String>> bundled, String family) {
  final files = bundled[family];
  if (files == null || files.isEmpty) {
    throw StateError('$family is not bundled in pubspec.yaml');
  }
  return [
    for (final file in files) _codePoints(File(file).readAsBytesSync()),
  ].reduce((a, b) => a.intersection(b));
}

/// Every string literal in the Dart files under [roots], with where each
/// was found, generated localizations aside (the ARBs are read instead).
Map<String, String> _dartStrings(List<String> roots) {
  final strings = <String, String>{};
  for (final root in roots) {
    final files = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.contains('/l10n/gen/'));
    for (final file in files) {
      final unit = parseString(
        content: file.readAsStringSync(),
        path: file.absolute.path,
        throwIfDiagnostics: false,
      ).unit;
      unit.accept(_StringCollector(file.path, unit.lineInfo, strings));
    }
  }
  return strings;
}

class _StringCollector extends RecursiveAstVisitor<void> {
  new(this.path, this.lines, this.strings);

  final String path;
  final LineInfo lines;
  final Map<String, String> strings;

  void _add(String value, AstNode node) {
    final line = lines.getLocation(node.offset).lineNumber;
    strings.putIfAbsent(value, () => '$path:$line');
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _add(node.value, node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    _add(node.value, node);
    super.visitInterpolationString(node);
  }
}

/// Every ARB value under `lib/l10n/arb`, with its file and key.
Map<String, String> _arbStrings() => {
  for (final file
      in Directory('lib/l10n/arb').listSync().whereType<File>().where(
        (f) => f.path.endsWith('.arb'),
      ))
    for (final MapEntry(:key, :value) in (jsonDecode(
      file.readAsStringSync(),
    ) as Map<String, dynamic>).entries)
      if (!key.startsWith('@') && value is String) value: '${file.path} $key',
};

String _codePoint(int c) =>
    'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')} '
    '(${String.fromCharCode(c)})';

void main() {
  final bundled = _bundledFamilies();
  final chain = [SurfaceTheme.displayFont, ...SurfaceTheme.fontFallback];
  final covered = {
    for (final family in chain) ..._familyCodePoints(bundled, family),
  };

  test('every app theme sets the bundled fallback on its text', () {
    for (final theme in [
      AppTheme.neon,
      AppTheme.readout,
      AppTheme.highContrast,
    ]) {
      final style = theme.textTheme.bodyMedium!;
      expect(style.fontFamily, SurfaceTheme.displayFont);
      expect(style.fontFamilyFallback, SurfaceTheme.fontFallback);
      expect(
        theme.primaryTextTheme.bodyMedium!.fontFamilyFallback,
        SurfaceTheme.fontFallback,
      );
    }
  });

  test('the fallback is what draws the musical sharp and flat', () {
    // Read off the files, so a font update that changes this shows here.
    const sharp = 0x266F;
    const flat = 0x266D;
    final inter = _familyCodePoints(bundled, SurfaceTheme.displayFont);
    expect(inter, isNot(contains(sharp)));
    expect(inter, isNot(contains(flat)));
    expect(_familyCodePoints(bundled, 'Arimo'), contains(sharp));
    expect(_familyCodePoints(bundled, 'JetBrains Mono'), contains(flat));
  });

  test("the Tuner's note names draw in the app's faces", () {
    final names = {
      for (var n = 0; n < 12; n++)
        pitchFromHz(440 * math.pow(2, n / 12).toDouble())!.note,
    };
    expect(names, hasLength(12));
    expect(names, contains('C♯'));
    for (final name in names) {
      expect(
        name.runes.where((c) => !covered.contains(c)).map(_codePoint),
        isEmpty,
        reason: name,
      );
    }
  });

  // What the theme's text can draw: Inter and the fallback. Text a painter
  // lays out with its own TextStyle (a pedal's printed name and knob
  // labels) does not take the theme's fallback, and draws only fixed ASCII.
  test("every character of every app string draws in the theme's faces", () {
    final strings = {
      ..._arbStrings(),
      ..._dartStrings([
        'lib',
        ...Directory('packages')
            .listSync()
            .whereType<Directory>()
            .map((d) => '${d.path}/lib')
            .where((p) => Directory(p).existsSync()),
      ]),
    };
    final missing = <String>[];
    for (final MapEntry(key: text, value: where) in strings.entries) {
      for (final c in text.runes.toSet()) {
        // Control characters (a newline, a tab) draw nothing in any face.
        if (c < 0x20 || covered.contains(c)) continue;
        missing.add('${_codePoint(c)} in $where');
      }
    }
    expect(
      missing,
      isEmpty,
      reason:
          'No face of ${chain.join(', ')} has these characters, so the '
          'appliance, which has no system fonts, draws nothing for them.',
    );
  });
}
