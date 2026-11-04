import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/settings/view/settings_fact_panel.dart';
import 'package:segno/theme/theme.dart';

/// The fact rows' geometry (#1590 UPD-1, UPD-2): labels on one line, values
/// and chevrons at the panel's right content edge.
void main() {
  const width = 848.0;

  Future<void> pump(WidgetTester tester, List<Widget> rows) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SettingsFactPanel(
              key: const Key('panel'),
              title: 'Panel',
              width: width,
              rows: rows,
            ),
          ),
        ),
      ),
    );
  }

  /// The panel's right content edge: its width less the border and inset.
  double contentRight(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('panel'))).right -
      1 -
      SettingsFactPanel.inset;

  testWidgets('a long label stays on one line beside a caption and a '
      'control', (tester) async {
    await pump(tester, [
      // The test font draws every glyph a full em wide, so these labels
      // need 168 and 312: more than the third of the free space the label
      // used to get (138 and 252 here, #1590 UPD-1).
      const SettingsFactRow(
        label: 'Channel',
        caption: 'Never downloads or installs on its own.',
        trailing: SizedBox(width: 320, height: 56),
      ),
      const SettingsFactRow(label: 'Segno version', value: '1.0.0'),
    ]);
    for (final label in ['Channel', 'Segno version']) {
      final text = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      expect(
        text
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            )
            .map((box) => box.top)
            .toSet(),
        hasLength(1),
        reason: '$label wraps',
      );
    }
  });

  testWidgets('a label beside a control and no value takes the free width; '
      'beside a caption it leaves the caption a third', (tester) async {
    // The row's content is 782 wide (848 less border and inset); a 320
    // control and the xl gap leave 438 for the label and its value.
    await pump(tester, [
      const SettingsFactRow(
        label: 'Update channel',
        trailing: SizedBox(width: 320, height: 56),
      ),
      const SettingsFactRow(
        label: 'Check automatically',
        caption: 'Never downloads or installs on its own.',
        trailing: SizedBox(width: 320, height: 56),
      ),
    ]);
    // 336 wide in the test font: past the two-thirds cap, but with no
    // value there is nothing to leave room for.
    final channel = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('Update channel'),
        matching: find.byType(RichText),
      ),
    );
    expect(
      channel
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 14),
          )
          .map((box) => box.top)
          .toSet(),
      hasLength(1),
    );
    // 456 wide: capped, so the caption keeps a third of what the gap leaves.
    final gap = SpacingTheme.standard.xl;
    expect(
      tester.getSize(find.text('Check automatically')).width,
      lessThanOrEqualTo((438 - gap) * 2 / 3),
    );
  });

  testWidgets('values share the right content edge, with or without a '
      'caption', (tester) async {
    await pump(tester, [
      const SettingsFactRow(label: 'Segno version', value: '1.0.0'),
      const SettingsFactRow(label: 'Serial', value: '10000000abcd1234'),
      const SettingsFactRow(
        label: 'Audio interface',
        value: 'Scarlett 4i4 4th Gen',
        caption: '48 kHz · 32 frames',
      ),
    ]);
    final right = contentRight(tester);
    for (final text in [
      '1.0.0',
      '10000000abcd1234',
      'Scarlett 4i4 4th Gen',
      '48 kHz · 32 frames',
    ]) {
      expect(
        tester.getRect(find.text(text)).right,
        moreOrLessEquals(right),
        reason: text,
      );
    }
  });

  testWidgets('a row that leads somewhere ends with its chevron at the '
      'content edge', (tester) async {
    await pump(tester, [
      SettingsFactRow(label: 'About Segno', onTap: () {}),
      SettingsFactRow(
        label: 'Open-source notices',
        value: '212 components',
        onTap: () {},
      ),
    ]);
    final right = contentRight(tester);
    final chevrons = find.byType(Icon);
    expect(chevrons, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(
        tester.getRect(chevrons.at(i)).right,
        moreOrLessEquals(right),
      );
    }
    // The value sits just before its chevron, not mid-card.
    final chevronLeft = tester.getRect(chevrons.last).left;
    expect(
      chevronLeft - tester.getRect(find.text('212 components')).right,
      SpacingTheme.standard.lg,
    );
  });
}
