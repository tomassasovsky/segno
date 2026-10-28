@Tags(['screenshots'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';
import '../looper/view/fx/stomp/factory_pedals.dart';

/// Every catalogue pedal on one sheet, each as the first factory preset that
/// holds it loads it: the review sheet for the pedals drawn in code (#1501).
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
  });

  testWidgets('Every catalogue pedal', (tester) async {
    tester.view
      ..physicalSize = const Size(1680, 1440)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final presets = factoryPresets();
    final faces = [
      for (final module in kFxModules)
        fxStompFace(
          l10n,
          fxEntryArt(
            factoryPedal(
              module,
              presets.firstWhere((p) => fxPresetModules(p).contains(module)),
            ),
          )!,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: ColoredBox(
          color: SurfaceTheme.dark.background,
          child: Wrap(
            children: [
              for (final face in faces)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: SizedBox(
                    width: 220,
                    height: 340,
                    child: FxStompPedal(face: face),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(Wrap),
      matchesGoldenFile('goldens/fx_stomp_pedals.png'),
    );
  }, skip: !rendersScreenshots);
}
