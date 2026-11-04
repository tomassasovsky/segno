import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/theme/theme.dart';

void main() {
  /// The routing meter's amplitude for [db] dBFS.
  const minus12 = 0.2511886;
  const minus3 = 0.7079458;

  Future<void> pump(WidgetTester tester, RoutingInputMeter meter) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [SurfaceTheme.dark]),
          home: Scaffold(body: Center(child: meter)),
        ),
      );

  Color cellColor(WidgetTester tester, int index) {
    final cells = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(RoutingInputMeter),
            matching: find.byType(Container),
          ),
        )
        .toList();
    return cells[index].color!;
  }

  group('RoutingInputMeter target band', () {
    test('covers -18 to -6 dBFS on the scale the level lights', () {
      expect(kInputGainTargetDb, (low: -18.0, high: -6.0));
      const meter = RoutingInputMeter(
        level: 0,
        clipping: false,
        width: 659,
        semanticLabel: 'Signal',
        target: kInputGainTargetDb,
      );
      // -18 dBFS is halfway along (between the -24 and -12 ticks), -6 five
      // sixths of the way: cells 21 to 33 of 41.
      expect(meter.targetCells, (first: 21, last: 34));
    });

    test('a meter without a target has no band', () {
      const meter = RoutingInputMeter(
        level: 0,
        clipping: false,
        width: 659,
        semanticLabel: 'Signal',
      );
      expect(meter.targetCells, isNull);
    });

    testWidgets('shades the band the level has not reached and marks it '
        'underneath', (tester) async {
      await pump(
        tester,
        const RoutingInputMeter(
          level: minus12,
          clipping: false,
          width: 659,
          semanticLabel: 'Signal',
          target: kInputGainTargetDb,
        ),
      );
      const surface = SurfaceTheme.dark;
      expect(
        find.byKey(const Key('routing_meter_target_cell')),
        findsNWidgets(13),
      );
      // -12 dBFS lights cells 0..26; the band's rest is shaded.
      expect(cellColor(tester, 26), surface.accent);
      expect(cellColor(tester, 27), surface.accentSurface);
      expect(cellColor(tester, 33), surface.accentSurface);
      expect(cellColor(tester, 34), surface.card);

      const step = 659 / 41;
      final marker = tester.getRect(
        find.byKey(const Key('routing_meter_target')),
      );
      final meter = tester.getRect(find.byType(RoutingInputMeter));
      expect(marker.left - meter.left, closeTo(21 * step, 0.01));
      expect(marker.top - meter.top, 28 + RoutingInputMeter.markerGap);
    });

    testWidgets('a level past the band lights over it', (tester) async {
      await pump(
        tester,
        const RoutingInputMeter(
          level: minus3,
          clipping: false,
          width: 659,
          semanticLabel: 'Signal',
          target: kInputGainTargetDb,
        ),
      );
      expect(cellColor(tester, 21), SurfaceTheme.dark.accent);
      expect(cellColor(tester, 33), SurfaceTheme.dark.accent);
      expect(find.byKey(const Key('routing_meter_target')), findsOneWidget);
    });
  });
}
