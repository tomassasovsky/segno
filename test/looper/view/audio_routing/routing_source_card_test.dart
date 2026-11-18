import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';

import '../../../helpers/helpers.dart';

void main() {
  group(RoutingSourceCard, () {
    Future<double Function(String)> pumpRow(
      WidgetTester tester, {
      required bool ordinalLine,
      required bool tagLine,
      List<String> tags = const [],
    }) async {
      await tester.pumpApp(
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RoutingSourceCard(
                ordinal: 'Input 1',
                name: 'Guitar',
                selected: false,
                ordinalLine: ordinalLine,
                tagLine: tagLine,
                tags: tags,
                onTap: () {},
              ),
              RoutingSourceCard(
                ordinal: 'Input 2',
                name: 'Input 2',
                selected: false,
                ordinalLine: ordinalLine,
                tagLine: tagLine,
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      double top(String text) => tester.getRect(find.text(text)).top;
      return top;
    }

    testWidgets('a row that keeps the ordinal line puts every name on one '
        'line (#1672)', (tester) async {
      final top = await pumpRow(tester, ordinalLine: true, tagLine: false);
      expect(top('Input 2'), top('Guitar'));
      // The unnamed card's ordinal is not drawn twice.
      expect(find.text('Input 2'), findsOneWidget);
    });

    testWidgets('a row that keeps the tag line puts every name on one line '
        '(#1672)', (tester) async {
      final top = await pumpRow(
        tester,
        ordinalLine: true,
        tagLine: true,
        tags: const ['Inst'],
      );
      expect(top('Input 2'), top('Guitar'));
    });
  });
}
