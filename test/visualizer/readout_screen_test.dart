import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/readout_screen.dart';
import 'package:segno/visualizer/waveform_window.dart';

void main() {
  group(ReadoutScreen, () {
    testWidgets('is blank until the main screen shows it', (tester) async {
      final link = ReadoutScreenLink();
      addTearDown(link.dispose);

      await tester.pumpWidget(ReadoutScreen(link: link));
      expect(find.byType(WaveformWindowApp), findsNothing);

      link.visible.value = true;
      await tester.pump();
      expect(find.byType(WaveformWindowApp), findsOneWidget);

      link.visible.value = false;
      await tester.pump();
      expect(find.byType(WaveformWindowApp), findsNothing);
      // Unmount before the harness checks timers: the chrome shell arms
      // cursor/chrome idle timers its dispose cancels.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows a calibration target over the readout and reports '
        'taps normalized to the panel', (tester) async {
      tester.view
        ..physicalSize = const Size(1024, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final link = ReadoutScreenLink();
      addTearDown(link.dispose);
      link.visible.value = true;

      await tester.pumpWidget(ReadoutScreen(link: link));
      expect(find.byType(WaveformWindowApp), findsOneWidget);

      link.calibration.value = (target: (x: 0.25, y: 0.5), label: '2 of 5');
      await tester.pump();
      expect(find.byType(WaveformWindowApp), findsNothing);
      expect(find.text('2 of 5'), findsOneWidget);
      final target = find.byKey(const Key('touch_calibration_target'));
      expect(tester.getCenter(target), const Offset(256, 300));

      final taps = <({double x, double y})>[];
      await tester.pumpWidget(
        ReadoutCalibrationFace(
          calibration: link.calibration.value!,
          onTap: taps.add,
        ),
      );
      await tester.tapAt(const Offset(512, 150));
      expect(taps, [(x: 0.5, y: 0.25)]);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
