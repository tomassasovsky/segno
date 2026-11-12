import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/theme/theme.dart';

/// A bar [width] wide with a 300 wide leading group and a [trailing] wide
/// trailing one, both 60 high.
Widget _bar({required double width, required double trailing}) => MaterialApp(
  theme: ThemeData(extensions: const [SpacingTheme.standard]),
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      height: 96,
      child: TopBarLayout(
        leading: const SizedBox(key: Key('leading'), width: 300, height: 60),
        centre: const SizedBox.shrink(),
        trailing: SizedBox(
          key: const Key('trailing'),
          width: trailing,
          height: 60,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a trailing group that fits keeps its size at the edge', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(width: 800, trailing: 312));
    expect(
      tester.getRect(find.byKey(const Key('trailing'))),
      const Rect.fromLTWH(488, 18, 312, 60),
    );
  });

  testWidgets('a trailing group wider than the room left is scaled down to '
      'fit, at the edge, instead of overflowing', (tester) async {
    await tester.pumpWidget(_bar(width: 800, trailing: 1000));
    expect(tester.takeException(), isNull);
    // 800 less the leading 300 and the 24 gap leaves 476 for 1000: scaled
    // to 0.476, at the edge, centred on the bar's height.
    final trailing = tester.getRect(find.byKey(const Key('trailing')));
    expect(trailing.left, closeTo(324, 1e-9));
    expect(trailing.right, closeTo(800, 1e-9));
    expect(trailing.height, closeTo(60 * 0.476, 1e-9));
    expect(trailing.center.dy, closeTo(48, 1e-9));
    expect(
      tester.getRect(find.byKey(const Key('leading'))),
      const Rect.fromLTWH(0, 18, 300, 60),
    );
  });
}
