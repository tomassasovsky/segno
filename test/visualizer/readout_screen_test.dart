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
  });
}
