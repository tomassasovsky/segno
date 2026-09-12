import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Where the switches and their indicators are is MEASURED, not drawn: the
/// design study holds the centres in the source raster's own coordinates and
/// the app places its hit targets from them. A hand copy is exactly the kind
/// of thing that drifts, and a marker a few pixels out is a performer
/// pointing at the wrong switch.
void main() {
  const study = 'docs/design/external-switch-study.js';

  /// The study's `artwork` object, as {name: {width, height, switches, leds}}.
  Map<String, Map<String, Object>> studyArtwork() {
    final js = File(study).readAsStringSync();
    final line = RegExp(r'const artwork=\{(.+?)\};').firstMatch(js);
    expect(line, isNotNull, reason: '$study no longer declares `artwork`');
    final body = line!.group(1)!;
    final entries = <String, Map<String, Object>>{};
    for (final match in RegExp(
      r'(\w+):\{width:(\d+),height:(\d+),'
      r'switches:\[(.*?)\],leds:\[(.*?)\]\}',
    ).allMatches(body)) {
      List<Offset> points(String raw) => [
        for (final pair in RegExp(r'\[([\d.]+),([\d.]+)\]').allMatches(raw))
          Offset(double.parse(pair.group(1)!), double.parse(pair.group(2)!)),
      ];
      entries[match.group(1)!] = {
        'size': Size(
          double.parse(match.group(2)!),
          double.parse(match.group(3)!),
        ),
        'switches': points(match.group(4)!),
        'leds': points(match.group(5)!),
      };
    }
    return entries;
  }

  test('the study and the app measure the same pedals', () {
    final measured = studyArtwork();
    expect(
      measured.keys.toSet(),
      {'single', 'dual'},
      reason: 'a pedal added to the study needs one here too',
    );
  });

  test('every switch and indicator sits where the study measured it', () {
    final measured = studyArtwork();
    const named = {
      'single': ExternalJackType.singleSwitch,
      'dual': ExternalJackType.dualSwitch,
    };
    for (final entry in named.entries) {
      final art = ExternalPedalArt.artwork[entry.value];
      expect(art, isNotNull, reason: entry.key);
      final source = measured[entry.key]!;
      expect(art!.size, source['size'], reason: '${entry.key} raster size');
      expect(
        art.switches,
        source['switches'],
        reason: '${entry.key} switch centres',
      );
      expect(
        art.indicators,
        source['leds'],
        reason: '${entry.key} indicator centres',
      );
    }
  });

  testWidgets('a marker lands on its switch whatever size the art is drawn', (
    tester,
  ) async {
    // The console's own size: the art's box is 722 tall, which the default
    // 800 x 600 test surface would squeeze and move every marker with it.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The two artworks have different aspects, so the placement has to work
    // off the rect the picture LANDED in rather than off the box it was
    // offered.
    for (final type in [
      ExternalJackType.singleSwitch,
      ExternalJackType.dualSwitch,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(extensions: const [SurfaceTheme.dark]),
          home: Center(
            child: ExternalPedalArt(
              type: type,
              selected: 0,
              onSelect: (_) {},
              contacts: const {},
            ),
          ),
        ),
      );
      final art = ExternalPedalArt.artwork[type]!;
      final box = tester.getRect(find.byType(ExternalPedalArt));
      final scale =
          (ExternalPedalArt.penSize.width / art.size.width) <
              (ExternalPedalArt.penSize.height / art.size.height)
          ? ExternalPedalArt.penSize.width / art.size.width
          : ExternalPedalArt.penSize.height / art.size.height;
      for (final (index, centre) in art.switches.indexed) {
        final target = tester.getRect(
          find.byKey(Key('external_switch_$index')),
        );
        final want = Offset(
          box.center.dx + (centre.dx - art.size.width / 2) * scale,
          box.center.dy + (centre.dy - art.size.height / 2) * scale,
        );
        expect(
          target.center.dx,
          closeTo(want.dx, 0.01),
          reason: '${type.name} switch $index x',
        );
        expect(
          target.center.dy,
          closeTo(want.dy, 0.01),
          reason: '${type.name} switch $index y',
        );
      }
    }
  });
}
