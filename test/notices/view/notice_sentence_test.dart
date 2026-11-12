import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/notices/notices.dart';

import '../../helpers/helpers.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required String source}) =>
      tester.pumpApp(
        Center(
          child: SizedBox(
            width: 600,
            child: NoticeSentence(
              source: source,
              title: 'Recording did not start',
              titleStyle: const TextStyle(fontSize: 24),
              body: 'Press Record again',
              sourceStyle: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      );

  testWidgets('a long track name is cut at a third of the line and the '
      'message keeps its room', (tester) async {
    await pump(tester, source: 'An extremely long track name ' * 6);
    expect(tester.takeException(), isNull);
    final source = tester.getRect(
      find.byKey(const Key('notice_sentence_source')),
    );
    expect(source.width, lessThanOrEqualTo(200));
    expect(find.byKey(const Key('notice_sentence_title')), findsOneWidget);
  });

  testWidgets('a short track name is drawn whole', (tester) async {
    await pump(tester, source: 'VOX');
    expect(tester.takeException(), isNull);
    expect(find.text('VOX'), findsOneWidget);
  });
}
