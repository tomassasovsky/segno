import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// The adaptive icon is the one piece of branding CI cannot look at: it is
/// resources, not code, and nothing renders it on the way to green. These
/// checks stand in for the eye — they read the checked-in XML and re-derive the
/// geometry a launcher will apply to it.
void main() {
  const flavours = ['main', 'development', 'staging'];
  const canvas = 108.0;
  const centre = canvas / 2;
  // Android masks the 108dp canvas to a 72dp visible area, and guarantees only
  // the inner 66dp circle survives every launcher's mask shape.
  const safeRadius = 33.0;

  group('the Android adaptive icon', () {
    test('every flavour declares one, both shapes', () {
      for (final flavour in flavours) {
        for (final shape in ['ic_launcher', 'ic_launcher_round']) {
          final file = File(
            'android/app/src/$flavour/res/mipmap-anydpi-v26/$shape.xml',
          );
          expect(
            file.existsSync(),
            isTrue,
            reason:
                '$flavour/$shape.xml is missing, so Android 8+ falls back to '
                'the legacy full-bleed PNG and the launcher plates it',
          );
          final xml = file.readAsStringSync();
          expect(xml, contains('@color/ic_launcher_background'));
          expect(xml, contains('@drawable/ic_launcher_foreground'));
        }
        expect(
          File(
            'android/app/src/$flavour/res/values/ic_launcher_background.xml',
          ).existsSync(),
          isTrue,
          reason: 'the background colour the adaptive icon references',
        );
      }
    });

    test('the round icon is declared, not just shipped', () {
      // The round mipmaps have been in the tree since the scaffold with nothing
      // pointing at them: launchers that ask for a round icon never did. Either
      // they are declared or they are dead weight, and declaring costs a line.
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      );
    });

    test('every flavour keeps its glyph inside the safe zone', () {
      for (final flavour in flavours) {
        final xml = File(
          'android/app/src/$flavour/res/drawable/ic_launcher_foreground.xml',
        ).readAsStringSync();
        final glyph = _placedGlyph(xml);

        expect(glyph.centre.dx, closeTo(centre, 0.05), reason: flavour);
        // Measured on the flattened OUTLINE, not the control points: a bezier's
        // hull overshoots the curve, and the difference here is 4dp — enough to
        // fail a check that is actually satisfied, or pass one that is not.
        expect(
          glyph.reach,
          lessThanOrEqualTo(safeRadius),
          reason:
              '$flavour ink reaches ${glyph.reach.toStringAsFixed(2)}dp; a '
              'circular mask clips anything past $safeRadius',
        );
        // And not so small it reads as a stamp on a plate rather than an icon.
        expect(glyph.reach, greaterThan(safeRadius * 0.9), reason: flavour);
      }
    });

    test('the glyph is the brand glyph, not a re-traced one', () {
      final svg = File(
        'tool/brand_assets/segno-glyph-white.svg',
      ).readAsStringSync();
      final d = RegExp(r'\sd="([^"]+)"').firstMatch(svg)!.group(1);
      for (final flavour in flavours) {
        final xml = File(
          'android/app/src/$flavour/res/drawable/ic_launcher_foreground.xml',
        ).readAsStringSync();
        // The whole argument for the placement maths is that this is the same
        // curve every other platform draws. A regeneration through a tool that
        // re-emits the path would keep the geometry checks green while quietly
        // shipping a different shape.
        expect(xml, contains('android:pathData="$d"'), reason: flavour);
      }
    });

    test('a flavour band does not sit under the glyph', () {
      // The band lives at the canvas edge, where a mask crops it. What it must
      // not do is run into the glyph — the pre-rebrand icon kept its logo above
      // it, and this keeps the same clearance.
      for (final flavour in ['development', 'staging']) {
        final xml = File(
          'android/app/src/$flavour/res/drawable/ic_launcher_foreground.xml',
        ).readAsStringSync();
        expect(xml, contains('#13B9FD'), reason: '$flavour lost its band');
        final band = RegExp(
          r'<group\s+android:scaleX="([\d.]+)"[^>]*?'
          r'android:translateY="([\d.]+)"[^>]*>\s*<path\s+'
          r'android:fillColor="#13B9FD"\s+'
          r'android:pathData="M0,(\d+)h',
        ).firstMatch(xml);
        expect(band, isNotNull, reason: '$flavour band moved or was rewritten');
        final top =
            double.parse(band!.group(1)!) * double.parse(band.group(3)!) +
            double.parse(band.group(2)!);
        expect(_placedGlyph(xml).bottom, lessThan(top), reason: flavour);
      }
    });
  });
}

/// A glyph after both of a foreground's group transforms: where it sits on the
/// 108dp canvas, and how far its ink reaches from the mask's centre.
({Offset centre, double reach, double bottom}) _placedGlyph(String xml) {
  final groups = RegExp(
    r'<group\s+android:scaleX="(-?[\d.]+)"\s+'
    r'android:scaleY="(-?[\d.]+)"\s+'
    r'android:translateX="(-?[\d.]+)"\s+'
    r'android:translateY="(-?[\d.]+)"',
  ).allMatches(xml).toList();
  // The glyph is the first two: the artboard placement, then the glyph's own
  // transform. A flavour's band group follows and is not part of this.
  expect(groups.length, greaterThanOrEqualTo(2));
  double n(RegExpMatch m, int i) => double.parse(m.group(i)!);
  final (outer, inner) = (groups[0], groups[1]);

  final points =
      _flatten(
        RegExp('android:pathData="([^"]+)"').firstMatch(xml)!.group(1)!,
      ).map((p) {
        final ax = n(inner, 1) * p.dx + n(inner, 3);
        final ay = n(inner, 2) * p.dy + n(inner, 4);
        return Offset(
          n(outer, 1) * ax + n(outer, 3),
          n(outer, 2) * ay + n(outer, 4),
        );
      }).toList();

  final xs = points.map((p) => p.dx);
  final ys = points.map((p) => p.dy);
  return (
    centre: Offset(
      (xs.reduce(math.min) + xs.reduce(math.max)) / 2,
      (ys.reduce(math.min) + ys.reduce(math.max)) / 2,
    ),
    reach: points
        .map((p) => (p - const Offset(54, 54)).distance)
        .reduce(math.max),
    bottom: ys.reduce(math.max),
  );
}

/// The path's outline as points, sampling each cubic rather than trusting its
/// control points.
List<Offset> _flatten(String data) {
  final tokens = RegExp(
    '[MLCVHZmlcvhz]|-?[0-9]+[.]?[0-9]*',
  ).allMatches(data).map((m) => m.group(0)!).toList();
  // Anything outside this set would be dropped by the tokenizer and its
  // coordinates eaten by the previous command — a silently wrong measurement,
  // which is worse than no measurement. Most SVG optimizers emit `S` and
  // relative commands, so a regeneration through one is the live risk.
  final letters = RegExp('[A-Za-z]').allMatches(data).map((m) => m.group(0)!);
  expect(
    letters.toSet().difference({'M', 'L', 'C', 'V', 'H', 'Z'}),
    isEmpty,
    reason: 'the path uses a command this check cannot follow',
  );

  final out = <Offset>[];
  var cursor = Offset.zero;
  Offset? start;
  String? command;
  var i = 0;
  double next() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    final token = tokens[i];
    if (RegExp('[A-Za-z]').hasMatch(token)) {
      command = token;
      i++;
      continue;
    }
    switch (command) {
      case 'M' || 'L':
        cursor = Offset(next(), next());
        start ??= cursor;
        if (command == 'M') start = cursor;
        out.add(cursor);
      case 'C':
        final c1 = Offset(next(), next());
        final c2 = Offset(next(), next());
        final end = Offset(next(), next());
        for (var k = 1; k <= 64; k++) {
          final u = k / 64;
          final v = 1 - u;
          out.add(
            Offset(
              v * v * v * cursor.dx +
                  3 * v * v * u * c1.dx +
                  3 * v * u * u * c2.dx +
                  u * u * u * end.dx,
              v * v * v * cursor.dy +
                  3 * v * v * u * c1.dy +
                  3 * v * u * u * c2.dy +
                  u * u * u * end.dy,
            ),
          );
        }
        cursor = end;
      case 'V':
        cursor = Offset(cursor.dx, next());
        out.add(cursor);
      case 'H':
        cursor = Offset(next(), cursor.dy);
        out.add(cursor);
      case 'Z' || 'z':
        if (start != null) {
          cursor = start;
          out.add(cursor);
        }
        i++;
      default:
        i++;
    }
  }
  return out;
}
