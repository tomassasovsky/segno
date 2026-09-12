import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/control/view/pedal_setup/pedal_color_dialog.dart';

/// The colour editor holds HSV and commits RGB, so the conversion has to be
/// exact in both directions: opening Edit on a colour and pressing Save
/// without touching a slider must give back the colour it opened on.
void main() {
  PedalColor roundTrip(PedalColor color) =>
      pedalColorFromHsv(HSVColor.fromColor(color.display));

  test('every built-in colour survives the editor untouched', () {
    for (final entry in [
      PedalColor.white,
      PedalColor.amber,
      PedalColor.red,
      PedalColor.orange,
      PedalColor.green,
      PedalColor.cyan,
      PedalColor.blue,
      PedalColor.violet,
    ]) {
      expect(roundTrip(entry), entry, reason: entry.toString());
    }
  });

  test('so does every corner of the cube, including the greys', () {
    for (final r in [0, 1, 0x7F, 0x80, 0xFE, 0xFF]) {
      for (final g in [0, 1, 0x7F, 0x80, 0xFE, 0xFF]) {
        for (final b in [0, 1, 0x7F, 0x80, 0xFE, 0xFF]) {
          final color = PedalColor(r, g, b);
          expect(roundTrip(color), color, reason: color.toString());
        }
      }
    }
  });

  test('the sliders name a colour the wire can carry', () {
    // Every channel lands inside a byte whatever the three doubles say.
    for (final hue in [0.0, 59.9, 180.0, 359.9, 360.0]) {
      for (final saturation in [0.0, 0.5, 1.0]) {
        for (final value in [0.0, 0.5, 1.0]) {
          final color = pedalColorFromHsv(
            HSVColor.fromAHSV(1, hue, saturation, value),
          );
          expect(color.rgb, inInclusiveRange(0, 0xFFFFFF));
        }
      }
    }
  });
}
