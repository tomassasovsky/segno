import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/view/pedal_setup/control_row_list.dart';

import '../../../helpers/helpers.dart';

void main() {
  /// The tile's content right edge: its box less the 25px horizontal padding.
  double contentRight(WidgetTester tester) =>
      tester.getRect(find.byType(ControlRowTile)).right - 25;

  Future<void> pumpTile(
    WidgetTester tester, {
    required String value,
    double width = 900,
    bool taken = false,
  }) => tester.pumpApp(
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: ControlRowTile(
          destination: 'Track 1',
          name: 'Overdub',
          value: value,
          valueKey: const Key('value'),
          taken: taken,
          onTap: () {},
        ),
      ),
    ),
  );

  group('ControlRowTile value', () {
    for (final value in ['On', 'Held', '−17.1 dB']) {
      testWidgets('sits at the right edge of the card ($value)', (
        tester,
      ) async {
        await pumpTile(tester, value: value);

        expect(
          tester.getRect(find.byKey(const Key('value'))).right,
          closeTo(contentRight(tester), 0.01),
        );
      });
    }

    testWidgets('ellipsizes a long value inside the card, at the right edge', (
      tester,
    ) async {
      await pumpTile(tester, value: 'A value far too long to fit ' * 6);

      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byKey(const Key('value')));
      expect(rect.right, closeTo(contentRight(tester), 0.01));
      expect(
        rect.left,
        greaterThan(tester.getRect(find.byType(ControlRowTile)).left),
      );
    });
  });
}
