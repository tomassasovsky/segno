import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/helpers.dart';
import '../../helpers/text_fit.dart';

void main() {
  setUpAll(loadBundledFonts);

  Future<void> pump(
    WidgetTester tester, {
    NoticeTone tone = NoticeTone.warning,
    String message = 'Effects are off on this track',
    Widget? action,
    int? maxLines,
    double height = 68,
  }) => tester.pumpApp(
    Center(
      child: SizedBox(
        width: 600,
        height: height,
        child: InlineNotice(
          message: message,
          tone: tone,
          action: action,
          maxLines: maxLines,
        ),
      ),
    ),
  );

  BoxDecoration decoration(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.descendant(
                  of: find.byType(InlineNotice),
                  matching: find.byType(Container),
                ),
              )
              .decoration!
          as BoxDecoration;

  for (final tone in [NoticeTone.neutral, NoticeTone.warning]) {
    testWidgets("draws the ${tone.name} tone's tint and edge", (tester) async {
      await pump(tester, tone: tone);
      final context = tester.element(find.byType(InlineNotice));
      final colors = NoticePalette.of(context.surface, tone);
      final box = decoration(tester);
      expect(box.color, colors.tint);
      final edge = (box.border! as Border).left;
      expect(edge.color, colors.line);
      expect(edge.width, context.noticeTheme.edgeThickness);
    });
  }

  testWidgets('holds the page action beside the sentence', (tester) async {
    await pump(
      tester,
      action: const SizedBox(key: Key('turn_on'), width: 200, height: 52),
    );
    final text = tester.getRect(find.text('Effects are off on this track'));
    final action = tester.getRect(find.byKey(const Key('turn_on')));
    expect(action.left, greaterThan(text.right));
  });

  testWidgets('two lines and the page action fit a 68 high band whole', (
    tester,
  ) async {
    await pump(
      tester,
      message: 'Effects are off on this track. ' * 3,
      maxLines: 2,
      action: const SizedBox(key: Key('turn_on'), width: 260, height: 52),
    );
    expect(tester.takeException(), isNull);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(InlineNotice),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraph.didExceedMaxLines, isTrue);
    // Laid out at its full two lines' height, not clipped to the band.
    expect(paragraph.textSize.height, lessThanOrEqualTo(paragraph.size.height));
  });

  testWidgets('with no line limit the sentence wraps whole, unclipped', (
    tester,
  ) async {
    const message = 'The console went back to 0.1.0-experimental.213. ';
    await pump(tester, message: message * 3, height: 400);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(InlineNotice),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraph.textSize.height, lessThanOrEqualTo(paragraph.size.height));
    expect(paragraph.size.height, greaterThan(2 * 24));
  });
}
