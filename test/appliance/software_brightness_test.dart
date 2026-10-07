import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/software_brightness.dart';

void main() {
  group('SoftwareBrightness', () {
    testWidgets('skips ColorFiltered at full brightness', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SoftwareBrightness(
            brightness: 1,
            child: Text('hi'),
          ),
        ),
      );
      expect(find.byType(ColorFiltered), findsNothing);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('wraps with ColorFiltered when dimmed', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SoftwareBrightness(
            brightness: 0.5,
            child: Text('hi'),
          ),
        ),
      );
      expect(find.byType(ColorFiltered), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
    });
  });

  testWidgets('the dimmed subtree keeps its state as the filter comes and '
      'goes', (tester) async {
    Widget at(double brightness) => Directionality(
      textDirection: TextDirection.ltr,
      child: SoftwareBrightness(
        brightness: brightness,
        child: const _Counter(),
      ),
    );
    await tester.pumpWidget(at(1));
    await tester.tap(find.byType(_Counter));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    await tester.pumpWidget(at(0.3));
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.pumpWidget(at(1));
    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });

  group('softwareBrightnessFilter', () {
    test('scales RGB by brightness', () {
      final filter = softwareBrightnessFilter(0.5);
      expect(filter, isA<ColorFilter>());
    });
  });

  group('clampDisplayBrightness', () {
    test('keeps a setting in the 20-100% range', () {
      expect(kMinDisplayBrightness, 0.2);
      expect(clampDisplayBrightness(0), kMinDisplayBrightness);
      expect(clampDisplayBrightness(0.1), kMinDisplayBrightness);
      expect(clampDisplayBrightness(0.5), 0.5);
      expect(clampDisplayBrightness(1.2), 1.0);
    });
  });

  group('shownBrightness', () {
    test('awake shows the setting', () {
      expect(shownBrightness(0.8, dimmed: false), 0.8);
    });

    test('dimmed shows 30% of it, never below 10%', () {
      expect(shownBrightness(1, dimmed: true), closeTo(0.3, 1e-9));
      expect(shownBrightness(0.5, dimmed: true), closeTo(0.15, 1e-9));
      expect(shownBrightness(0.2, dimmed: true), kMinShownBrightness);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _taps++),
    child: Text('$_taps'),
  );
}
