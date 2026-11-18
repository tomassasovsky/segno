@Tags(['screenshots'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';
import '../looper/view/fx/stomp/factory_pedals.dart';

/// Every catalogue pedal, each as the first factory preset that holds it
/// loads it, then the standalone built-ins' own looks (#1730), grouped by
/// face as the approved design sheet groups them: the review sheet for the
/// pedals drawn in code (#1501).
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadFxStompArt();
  });

  testWidgets('Every catalogue pedal', (tester) async {
    tester.view
      ..physicalSize = const Size(2000, 2200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final presets = factoryPresets();
    FxStompFace faceOf(TrackEffect entry) =>
        fxStompFace(l10n, fxEntryArt(entry, live: true)!)!;
    final faces = [
      for (final module in kFxModules)
        faceOf(
          factoryPedal(
            module,
            presets.firstWhere((p) => fxPresetModules(p).contains(module)),
          ),
        ),
      for (final MapEntry(key: type, value: look) in kFxBuiltInLooks.entries)
        if (fxModuleNamed(look) == null) faceOf(BuiltInEffect(type: type)),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const [
            SurfaceTheme.dark,
            SpacingTheme.standard,
            NoticeTheme.standard,
          ],
        ),
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
                      for (final face in faces)
                        if (face.spec.face == kind)
                          SizedBox(
                            width: 180,
                            height: 180 / kind.size.aspectRatio,
                            child: FxStompPedal(face: face),
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
