import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/helpers.dart';

/// The Pending Hold cue on one performance pedal (#1229 Part 1, pen `PRSrG`).
void main() {
  const barKey = Key('p_undo_hold');

  Widget pedal({required bool pending}) => Center(
    child: PerformancePedal(
      keyPrefix: 'p',
      button: PedalButton.undo,
      label: 'UNDO',
      title: 'Level −',
      detail: '',
      hint: 'Hold · Unity',
      enabled: true,
      selected: false,
      onPressed: (_, _) {},
      onReleased: (_, _) {},
      onCancelled: (_, _) {},
      onActivate: () {},
      holdPending: pending,
    ),
  );

  double barOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.descendant(of: find.byKey(barKey), matching: find.byType(Opacity)),
      )
      .opacity;

  double fill(WidgetTester tester) => tester
      .widget<FractionallySizedBox>(
        find.descendant(
          of: find.byKey(barKey),
          matching: find.byType(FractionallySizedBox),
        ),
      )
      .widthFactor!;

  Color hintColor(WidgetTester tester) =>
      tester.widget<Text>(find.text('Hold · Unity')).style!.color!;

  testWidgets('idle, the bar is laid out but invisible', (tester) async {
    await tester.pumpApp(pedal(pending: false));
    expect(find.byKey(barKey), findsOneWidget);
    expect(tester.getSize(find.byKey(barKey)), const Size(156, 3));
    // The pen's blue-grey track under a pale-blue fill (`IBL3g`).
    final boxes = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byKey(barKey),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(boxes.map((box) => box.color), [
      SurfaceTheme.dark.holdTrack,
      SurfaceTheme.dark.holdProgress,
    ]);
    expect(SurfaceTheme.dark.holdTrack, const Color(0xFF303B4B));
    expect(barOpacity(tester), 0);
    expect(hintColor(tester), SurfaceTheme.dark.textSecondary);
  });

  testWidgets('the bar fills over the threshold from its own ticker', (
    tester,
  ) async {
    await tester.pumpApp(pedal(pending: false));
    await tester.pumpApp(pedal(pending: true));
    expect(barOpacity(tester), 1);
    expect(fill(tester), 0);
    expect(hintColor(tester), SurfaceTheme.dark.holdPendingText);

    await tester.pump(const Duration(milliseconds: 400));
    expect(fill(tester), closeTo(0.5, 1e-9));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fill(tester), 1);

    await tester.pumpApp(pedal(pending: false));
    expect(barOpacity(tester), 0);
    expect(fill(tester), 0);
    expect(hintColor(tester), SurfaceTheme.dark.textSecondary);
  });

  testWidgets('a hold pending from the first frame starts at once', (
    tester,
  ) async {
    await tester.pumpApp(pedal(pending: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fill(tester), closeTo(0.25, 1e-9));
  });

  testWidgets('a new hold restarts the bar from empty', (tester) async {
    await tester.pumpApp(pedal(pending: true));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpApp(pedal(pending: false));
    await tester.pumpApp(pedal(pending: true));
    expect(fill(tester), 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(fill(tester), closeTo(0.5, 1e-9));
  });

  testWidgets('the cue never changes the pedal layout', (tester) async {
    await tester.pumpApp(pedal(pending: false));
    final idle = tester.getSize(find.byType(PerformancePedal));
    final title = tester.getTopLeft(find.text('Level −'));
    await tester.pumpApp(pedal(pending: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(find.byType(PerformancePedal)), idle);
    expect(tester.getTopLeft(find.text('Level −')), title);
  });
}
