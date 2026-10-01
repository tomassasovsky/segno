import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/control/view/pedal_setup/pedal_color_dialog.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The colour editor holds HSV and commits RGB, so the conversion has to be
/// exact in both directions: opening Edit on a colour and pressing Save
/// without touching a slider must give back the colour it opened on.
void main() {
  PedalColor roundTrip(PedalColor color) =>
      pedalColorFromHsv(HSVColor.fromColor(color.display));

  test('every built-in colour survives the editor untouched', () {
    for (final entry in PedalPaletteColor.values.map((item) => item.color)) {
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
  testWidgets(
    'slider endpoints produce explicit RGB, cancel discards the edit',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PedalColor? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: const [SurfaceTheme.dark]),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showPedalColorDialog(
                  context,
                  initial: const PedalColor(255, 0, 0),
                  editing: false,
                ).then((value) => result = value),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      void setSlider(String id, double value) {
        tester
            .widget<LoopSlider>(find.byKey(Key('pedal_color_slider_$id')))
            .onChanged(value);
      }

      setSlider('hue', 1 / 3);
      await tester.pumpAndSettle();
      expect(find.text('#00FF00'), findsOneWidget);
      setSlider('saturation', 0);
      await tester.pumpAndSettle();
      expect(find.text('#FFFFFF'), findsOneWidget);
      setSlider('brightness', 0);
      await tester.pumpAndSettle();
      expect(find.text('#000000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pedal_color_cancel')));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('#FF0000'), findsOneWidget);
      final slider = find.byKey(const Key('pedal_color_slider_hue'));
      final focus = find
          .descendant(of: slider, matching: find.byType(Builder))
          .first;
      Focus.of(tester.element(focus)).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('#FF0F00'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('#FF0000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pedal_color_done')));
      await tester.pumpAndSettle();
      expect(result, const PedalColor(255, 0, 0));
      expect(tester.takeException(), isNull);
    },
  );
}
