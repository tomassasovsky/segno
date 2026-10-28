@Tags(['screenshots'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';
import '../looper/view/fx/stomp/factory_pedals.dart';

/// Every catalogue pedal, each as the first factory preset that holds it
/// loads it, grouped by face as the approved design sheet groups them: the
/// review sheet for the pedals drawn in code (#1501).
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadFxStompArt();
  });

  testWidgets('Every catalogue pedal', (tester) async {
    tester.view
      ..physicalSize = const Size(2000, 1900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final presets = factoryPresets();
    FxStompFace faceOf(FxModule module) => fxStompFace(
      l10n,
      fxEntryArt(
        factoryPedal(
          module,
          presets.firstWhere((p) => fxPresetModules(p).contains(module)),
        ),
        live: true,
      )!,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: ColoredBox(
          color: SurfaceTheme.dark.background,
          child: Column(
            key: const Key('stomp_sheet'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final kind in FxStompFaceKind.values)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      for (final module in kFxModules)
                        if (kFxStompSpecs[module.name]!.face == kind)
                          SizedBox(
                            width: 180,
                            height: 180 / kind.size.aspectRatio,
                            child: FxStompPedal(face: faceOf(module)),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const Key('stomp_sheet')),
      matchesGoldenFile('goldens/fx_stomp_pedals.png'),
    );
  }, skip: !rendersScreenshots);
}
