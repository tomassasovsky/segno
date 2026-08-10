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

    test('the glyph is centred and inside the safe zone', () {
      final xml = File(
        'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
      ).readAsStringSync();

      // The two nested groups: the outer places the 1024 artboard on the
      // adaptive canvas, the inner is the glyph's own transform.
      final groups = RegExp(
        r'<group\s+android:scaleX="(-?[\d.]+)"\s+'
        r'android:scaleY="(-?[\d.]+)"\s+'
        r'android:translateX="(-?[\d.]+)"\s+'
        r'android:translateY="(-?[\d.]+)"',
      ).allMatches(xml).toList();
      expect(groups, hasLength(2));

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
      final mid = Offset(
        (xs.reduce(math.min) + xs.reduce(math.max)) / 2,
        (ys.reduce(math.min) + ys.reduce(math.max)) / 2,
      );
      expect(mid.dx, closeTo(centre, 0.05));
      expect(mid.dy, closeTo(centre, 0.05));

      // Measured on the flattened OUTLINE, not the control points: a bezier's
      // hull overshoots the curve, and the difference here is 4dp — enough to
      // fail a check that is actually satisfied, or pass one that is not.
      final reach = points
          .map((p) => (p - const Offset(centre, centre)).distance)
          .reduce(math.max);
      expect(
        reach,
        lessThanOrEqualTo(safeRadius),
        reason:
            'ink reaches ${reach.toStringAsFixed(2)}dp; a circular mask clips '
            'anything past $safeRadius',
      );
      // And not so small it reads as a stamp on a plate rather than an icon.
      expect(reach, greaterThan(safeRadius * 0.9));
    });
  });
}

/// The path's outline as points, sampling each cubic rather than trusting its
/// control points.
List<Offset> _flatten(String data) {
  final tokens = RegExp(
    '[MLCVHZmlcvhz]|-?[0-9]+[.]?[0-9]*',
  ).allMatches(data).map((m) => m.group(0)!).toList();
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
