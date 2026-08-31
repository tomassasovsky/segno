import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_goodbye.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../../helpers/helpers.dart';

void main() {
  group(PowerOffGoodbye, () {
    testWidgets('Saving face has no spinner and uses the Plymouth field', (
      tester,
    ) async {
      await tester.pumpApp(
        const PowerOffGoodbye(face: ReadoutGoodbye.saving),
      );

      expect(find.byKey(const Key('power_off_saving')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('power_off_mark')), findsNothing);
      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('power_off_goodbye')),
      );
      expect(box.color, kPowerOffGoodbyeFill);
    });

    testWidgets('mark uses the bundled lockup on #08080A', (tester) async {
      await tester.pumpApp(const PowerOffGoodbye(face: ReadoutGoodbye.mark));

      expect(find.byKey(const Key('power_off_mark')), findsOneWidget);
      final image = tester.widget<Image>(
        find.byKey(const Key('power_off_mark')),
      );
      expect(
        image.image,
        isA<AssetImage>().having(
          (asset) => asset.assetName,
          'assetName',
          kPowerOffLockupAsset,
        ),
      );
      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('power_off_goodbye')),
      );
      expect(box.color, const Color(0xFF08080A));
    });

    testWidgets('none draws nothing', (tester) async {
      await tester.pumpApp(const PowerOffGoodbye(face: ReadoutGoodbye.none));
      expect(find.byKey(const Key('power_off_goodbye')), findsNothing);
    });
  });

  group('readoutGoodbyeOf', () {
    test('saving and mark map to the 7" overlay faces', () {
      expect(readoutGoodbyeOf(PowerOffPhase.saving), ReadoutGoodbye.saving);
      expect(readoutGoodbyeOf(PowerOffPhase.goodbye), ReadoutGoodbye.mark);
      expect(readoutGoodbyeOf(PowerOffPhase.idle), ReadoutGoodbye.none);
      expect(readoutGoodbyeOf(PowerOffPhase.refuse), ReadoutGoodbye.none);
      expect(readoutGoodbyeOf(PowerOffPhase.confirm), ReadoutGoodbye.none);
      expect(readoutGoodbyeOf(PowerOffPhase.saveAs), ReadoutGoodbye.none);
      expect(readoutGoodbyeOf(PowerOffPhase.saveFailed), ReadoutGoodbye.none);
    });
  });
}
