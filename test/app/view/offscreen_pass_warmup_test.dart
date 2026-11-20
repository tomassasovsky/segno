import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/view/offscreen_pass_warmup.dart';

void main() {
  group(OffscreenPassWarmup, () {
    testWidgets('draws its offscreen pass for one frame after the first', (
      tester,
    ) async {
      const warmup = Key('offscreen_pass_warmup');
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: OffscreenPassWarmup(),
        ),
      );
      expect(find.byKey(warmup), findsNothing);
      await tester.pump();
      expect(find.byKey(warmup), findsOneWidget);
      expect(tester.widget<Opacity>(find.byKey(warmup)).opacity, 0.5);
      await tester.pump();
      expect(find.byKey(warmup), findsNothing);
      await tester.pump();
      expect(find.byKey(warmup), findsNothing);
    });
  });
}
