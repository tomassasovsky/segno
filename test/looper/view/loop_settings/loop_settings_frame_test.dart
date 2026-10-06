import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/theme/theme.dart';

import '../../../helpers/helpers.dart';

void main() {
  group(LoopSettingsFrame, () {
    Future<SurfaceTheme> pump(WidgetTester tester, {Widget? actions}) async {
      tester.view
        ..physicalSize = kLoopPenSize
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        LoopSettingsFrame(
          crumb: 'SETTINGS',
          title: 'Settings',
          titleLeft: 100,
          onBack: () {},
          onStage: () {},
          actions: actions,
          children: const [],
        ),
      );
      return tester.element(find.byType(LoopSettingsFrame)).surface;
    }

    ShapeBorder shapeOf(WidgetTester tester, String key) => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byKey(Key(key)),
                matching: find.byType(Material),
              )
              .first,
        )
        .shape!;

    testWidgets('draws the page, rule, Back and Stage from the frame tokens', (
      tester,
    ) async {
      final surface = await pump(tester);

      final canvas = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(LoopPenCanvas),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(canvas.color, surface.frameBackground);

      final bar = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(LoopSettingsFrame),
              matching: find.byType(Container),
            )
            .first,
      );
      final border = (bar.decoration! as BoxDecoration).border! as Border;
      expect(border.bottom.color, surface.frameRule);

      final back = find.byKey(const Key('loop_settings_back'));
      final chevron = tester.widget<Icon>(
        find.descendant(of: back, matching: find.byType(Icon)),
      );
      expect(chevron.icon, LucideIcons.chevronLeft);
      expect(chevron.color, surface.frameIcon);
      final backMaterial = tester.widget<Material>(
        find.descendant(of: back, matching: find.byType(Material)).first,
      );
      expect(backMaterial.color, Colors.transparent);
      expect(
        (shapeOf(tester, 'loop_settings_back') as RoundedRectangleBorder)
            .side
            .color,
        surface.frameControlLine,
      );

      final stage = find.byKey(const Key('loop_settings_stage'));
      final stageMaterial = tester.widget<Material>(
        find.descendant(of: stage, matching: find.byType(Material)).first,
      );
      expect(stageMaterial.color, surface.frameControlFill);
      expect(
        (shapeOf(tester, 'loop_settings_stage') as RoundedRectangleBorder)
            .side
            .color,
        surface.frameControlLine,
      );
    });

    testWidgets('sets the crumb, Stage and title in the frame typeface and '
        'colours', (tester) async {
      final surface = await pump(tester);

      TextStyle styleOf(String text) =>
          tester.widget<Text>(find.text(text)).style!;
      expect(styleOf('SETTINGS').fontFamily, SurfaceTheme.frameFont);
      expect(styleOf('SETTINGS').color, surface.frameCrumb);
      expect(styleOf('Stage').fontFamily, SurfaceTheme.frameFont);
      expect(styleOf('Stage').color, surface.frameText);
      expect(styleOf('Settings').fontFamily, SurfaceTheme.frameFont);
      expect(styleOf('Settings').color, surface.frameText);
    });

    testWidgets('centres the title in a 72 high row, or a 64 high row when '
        'the title carries actions', (tester) async {
      await pump(tester);
      final alone = tester.getCenter(
        find.byKey(const Key('loop_settings_title')),
      );
      expect(alone.dy, kLoopTopBarHeight + 28 + 72 / 2);

      await pump(tester, actions: const SizedBox(width: 64, height: 64));
      final withActions = tester.getCenter(
        find.byKey(const Key('loop_settings_title')),
      );
      expect(withActions.dy, kLoopTopBarHeight + 30 + 64 / 2);
    });
  });
}
