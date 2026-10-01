import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/theme/theme.dart';

/// Reads the painter's output at measured points from the hardware study.
/// The source is rendered, so a path or paint-order error changes pixels even
/// if a copied path comment still matches the JavaScript study.
Future<Uint8List> _renderFace(
  WidgetTester tester, {
  required bool selected,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [SurfaceTheme.dark]),
      home: Center(
        child: RepaintBoundary(
          key: const Key('face-image'),
          child: SizedBox(
            width: 84,
            height: 114,
            child: PedalHardwareFace(label: '', selected: selected),
          ),
        ),
      ),
    ),
  );
  expect(tester.getSize(find.byType(PedalHardwareFace)), const Size(84, 114));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('face-image')),
  );
  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 4);
    try {
      final data = await image.toByteData();
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  return pixels!;
}

Color _at(Uint8List pixels, double x, double y) {
  const width = 84 * 4;
  final offset = ((y * 4).round() * width + (x * 4).round()) * 4;
  return Color.fromARGB(
    pixels[offset + 3],
    pixels[offset],
    pixels[offset + 1],
    pixels[offset + 2],
  );
}

void main() {
  testWidgets('measured hinges, rolled edges, pad and plate are painted', (
    tester,
  ) async {
    final pixels = await _renderFace(tester, selected: false);
    expect(_at(pixels, 1.5, 25), const Color(0xFF424A53)); // left hinge
    expect(_at(pixels, 82.5, 25), const Color(0xFF424A53)); // right hinge
    expect(_at(pixels, 6, 60), const Color(0xFF343B43)); // left roll
    expect(_at(pixels, 78, 60), const Color(0xFF242A31)); // right roll
    expect(_at(pixels, 15, 35), const Color(0xFF191D21)); // rubber pad
    expect(_at(pixels, 20, 17), const Color(0xFF20252B)); // nameplate
  });

  testWidgets('all thirty raised grips remain visible at the study pitch', (
    tester,
  ) async {
    final pixels = await _renderFace(tester, selected: false);
    for (var row = 0; row < 6; row++) {
      for (var column = 0; column < 5; column++) {
        final x = 42 + (column - 2) * 11.6373;
        final y = 39.47 + row * 12;
        expect(
          _at(pixels, x, y),
          isNot(const Color(0xFF191D21)),
          reason: 'grip at row $row column $column',
        );
        expect(
          _at(pixels, x, y),
          isNot(_at(pixels, x + 5, y)),
          reason: 'grip contrasts with pad at row $row column $column',
        );
      }
    }
  });

  testWidgets('selection changes alloy and plate while keeping side rolls', (
    tester,
  ) async {
    final normal = await _renderFace(tester, selected: false);
    final selected = await _renderFace(tester, selected: true);
    final normalMetal = _at(normal, 42, 3);
    final selectedMetal = _at(selected, 42, 3);
    expect(selectedMetal.r, greaterThan(normalMetal.r));
    expect(selectedMetal.g, greaterThan(normalMetal.g));
    expect(selectedMetal.b, greaterThan(normalMetal.b));
    expect(_at(selected, 20, 17), const Color(0xFF273449));
    expect(_at(selected, 6, 60), const Color(0xFF343B43));
    expect(_at(selected, 78, 60), const Color(0xFF242A31));
  });
}
