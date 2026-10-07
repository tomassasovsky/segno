import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../../helpers/helpers.dart';

void main() {
  group(PowerGoodbye, () {
    testWidgets('Saving face has no spinner and uses the Plymouth field', (
      tester,
    ) async {
      await tester.pumpApp(
        const PowerGoodbye(face: ReadoutGoodbye.saving),
      );

      expect(find.byKey(const Key('power_saving')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('power_mark')), findsNothing);
      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('power_goodbye')),
      );
      expect(box.color, kPowerGoodbyeFill);
    });

    testWidgets('mark uses the bundled lockup on #08080A', (tester) async {
      await tester.pumpApp(const PowerGoodbye(face: ReadoutGoodbye.mark));

      expect(find.byKey(const Key('power_mark')), findsOneWidget);
      final image = tester.widget<Image>(
        find.byKey(const Key('power_mark')),
      );
      expect(
        image.image,
        isA<AssetImage>().having(
          (asset) => asset.assetName,
          'assetName',
          kPowerLockupAsset,
        ),
      );
      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('power_goodbye')),
      );
      expect(box.color, const Color(0xFF08080A));
    });

    testWidgets('none draws nothing', (tester) async {
      await tester.pumpApp(const PowerGoodbye(face: ReadoutGoodbye.none));
      expect(find.byKey(const Key('power_goodbye')), findsNothing);
    });
  });

  group('terminal faces', () {
    testWidgets('Shut down draws Safe to switch off, centered, no lockup', (
      tester,
    ) async {
      await tester.pumpApp(
        const PowerGoodbye(
          face: ReadoutGoodbye.mark,
          action: PowerAction.shutDown,
        ),
      );
      expect(find.byKey(const Key('power_safe_to_switch_off')), findsOneWidget);
      expect(find.text('Safe to switch off'), findsOneWidget);
      expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
      expect(find.byKey(const Key('power_mark')), findsNothing);
    });

    testWidgets('Restart draws Restarting without an ellipsis', (
      tester,
    ) async {
      await tester.pumpApp(
        const PowerGoodbye(
          face: ReadoutGoodbye.mark,
          action: PowerAction.restart,
        ),
      );
      expect(find.byKey(const Key('power_restarting')), findsOneWidget);
      expect(find.text('Restarting'), findsOneWidget);
      expect(find.textContaining('…'), findsNothing);
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);
    });
  });

  group('readoutGoodbyeOf', () {
    test('saving and goodbye map to the 7" overlay faces', () {
      expect(readoutGoodbyeOf(PowerPhase.saving), ReadoutGoodbye.saving);
      expect(readoutGoodbyeOf(PowerPhase.goodbye), ReadoutGoodbye.mark);
      for (final phase in [
        PowerPhase.idle,
        PowerPhase.refuse,
        PowerPhase.options,
        PowerPhase.saveAs,
        PowerPhase.saveFailed,
      ]) {
        expect(readoutGoodbyeOf(phase), ReadoutGoodbye.none);
      }
    });
  });
}
