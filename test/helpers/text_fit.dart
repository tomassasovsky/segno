import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The font families the app bundles, from the font manifest the test build
/// writes from the pubspec, each with its asset paths.
Future<Map<String, List<String>>> bundledFontFiles() async {
  final manifest = jsonDecode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;
  return {
    for (final entry in manifest.cast<Map<String, dynamic>>())
      entry['family'] as String: [
        for (final font
            in (entry['fonts'] as List<dynamic>).cast<Map<String, dynamic>>())
          font['asset'] as String,
      ],
  };
}

/// Registers every family the app bundles under its own name, so a test
/// measures text in the faces the console draws it in rather than in the
/// test font's squares.
Future<void> loadBundledFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final MapEntry(key: family, value: assets)
      in (await bundledFontFiles()).entries) {
    final loader = FontLoader(family);
    assets.map(rootBundle.load).forEach(loader.addFont);
    await loader.load();
  }
}

/// Every text under [within] that does not show in full, described as
/// `"<text>": <why>`: an ellipsis or a cut line, a single line wider than its
/// box, or a box reaching past a clip above it.
///
/// Text inside a scale-down `FittedBox` is drawn smaller, not cut, so it
/// passes; the box it is measured in is the one before the scale.
List<String> clippedTexts(WidgetTester tester, {Finder? within}) {
  final found = <String>[];
  for (final (:paragraph, :text) in _paragraphs(tester, within)) {
    final why = _whyClipped(paragraph);
    if (why != null) found.add('"$text": $why');
  }
  return found;
}

/// Every text under [within] whose family the app does not bundle, as
/// `"<text>": <family>`. The appliance image carries no system fonts, so
/// such a text draws nothing at all on the console.
Future<List<String>> unbundledTexts(
  WidgetTester tester, {
  Finder? within,
}) async {
  final bundled = (await tester.runAsync(bundledFontFiles))!.keys.toSet();
  final found = <String>[];
  for (final (:paragraph, :text) in _paragraphs(tester, within)) {
    // A span without a family of its own draws in its parent's.
    final families = <String?>{};
    void collect(InlineSpan span, String? inherited) {
      final family = span.style?.fontFamily ?? inherited;
      if (span is! TextSpan) return;
      if (span.text?.isNotEmpty ?? false) families.add(family);
      for (final child in span.children ?? const <InlineSpan>[]) {
        collect(child, family);
      }
    }

    collect(paragraph.text, null);
    for (final family in families) {
      if (family == null || !bundled.contains(family)) {
        found.add('"$text": $family');
      }
    }
  }
  return found;
}

/// The laid-out paragraphs with text under [within], or on the whole screen.
Iterable<({RenderParagraph paragraph, String text})> _paragraphs(
  WidgetTester tester,
  Finder? within,
) sync* {
  final finder = within == null
      ? find.byType(RichText)
      : find.descendant(of: within, matching: find.byType(RichText));
  for (final paragraph in tester.renderObjectList<RenderParagraph>(finder)) {
    final text = paragraph.text.toPlainText().trim();
    if (text.isNotEmpty && paragraph.attached) {
      yield (paragraph: paragraph, text: text);
    }
  }
}

String? _whyClipped(RenderParagraph paragraph) {
  if (paragraph.didExceedMaxLines) return 'ellipsized or cut to its lines';
  final singleLine = paragraph.maxLines == 1 || !paragraph.softWrap;
  if (singleLine) {
    final natural = paragraph.getMaxIntrinsicWidth(double.infinity);
    if (natural > paragraph.size.width + 0.5) {
      return 'needs ${natural.toStringAsFixed(1)} px, has '
          '${paragraph.size.width.toStringAsFixed(1)}';
    }
  }
  final box = _globalRect(paragraph);
  var node = paragraph.parent;
  while (node != null) {
    if (node is RenderClipRect ||
        node is RenderClipRRect ||
        node is RenderClipPath ||
        (node is RenderFittedBox && node.clipBehavior != Clip.none)) {
      final clip = _globalRect(node as RenderBox);
      // A pixel of slack: the optical nudge moves caps and figures down by
      // one, inside the line box's own leading.
      if (box.left < clip.left - 1 ||
          box.right > clip.right + 1 ||
          box.top < clip.top - 1.5 ||
          box.bottom > clip.bottom + 1.5) {
        return 'reaches past the clip of ${node.runtimeType}';
      }
    }
    node = node.parent;
  }
  return null;
}

Rect _globalRect(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
