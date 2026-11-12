import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../helpers/text_fit.dart';

/// Every text on the selected-track readout shows in full on the console's
/// second screen, in the faces the app bundles (#1524).
void main() {
  setUpAll(loadBundledFonts);

  Future<void> pump(
    WidgetTester tester,
    Locale locale,
    PerformanceReadout readout,
  ) async {
    // The readout screen: 1920 x 1080 at a device pixel ratio of 1.6.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.neon,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppTextDefaults(child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: ConsoleReadoutView(
            readout: readout,
            waveform: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  for (final locale in AppLocalizations.supportedLocales) {
    final language = locale.languageCode;
    for (final state in ['recording', 'overdubbing', 'playing', 'stopped']) {
      testWidgets('a $state track shows every text in full ($language)', (
        tester,
      ) async {
        await pump(
          tester,
          locale,
          PerformanceReadout(
            selected: ReadoutTrack(
              channel: 15,
              name: 'Bass',
              state: state,
              primary: true,
              bars: 128,
            ),
            tempoBpm: 188.5,
            hasTempo: true,
            tsNum: 12,
            tsDen: 8,
            // Custom is the longest function name in both languages.
            mode: 'custom',
            activeBank: 3,
            // The longest must-act line the band carries.
            notice: ReadoutNotice(
              title: lookupAppLocalizations(locale)
                  .deviceLostNamedBanner('Scarlett 18i20 4th Gen'),
              tone: NoticeTone.critical,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(clippedTexts(tester), isEmpty);
        expect(await unbundledTexts(tester), isEmpty);
      });
    }
  }
}
