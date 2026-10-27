@Tags(['screenshots'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/view/storage_destination_picker.dart';
import 'package:segno/theme/theme.dart';
import 'package:storage_repository/storage_repository.dart';

import '../helpers/helpers.dart';

/// Pen 48's `Save to` (`cH9UX`, `FwjUV`) and pen `m5XyVv`'s Connect USB
/// sheet, for eyeballing against the pen. Renders only with
/// `--update-goldens`, like every suite here.
void main() {
  setUpAll(() async {
    if (!rendersScreenshots) return;
    await loadScreenshotFont('Roboto', [
      '$materialFontDir/Roboto-Regular.ttf',
      '$materialFontDir/Roboto-Medium.ttf',
      '$materialFontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
  });

  const usb = RemovableVolume(
    generation: 1,
    fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
    label: 'SEGNO USB',
    fsType: 'exfat',
    sizeBytes: 32000000000,
    status: RemovableVolumeStatus.mounted,
    mountPoint: '/run/media/segno/1-SEGNO_USB',
    writeBytesPerSecond: 16777216,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    EdgeInsets inset = const EdgeInsets.fromLTRB(1180, 300, 20, 20),
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          brightness: Brightness.dark,
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(
          backgroundColor: SurfaceTheme.dark.background,
          body: Padding(
            padding: inset,
            child: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );

  testWidgets('Choose Internal or USB', (tester) async {
    await pump(
      tester,
      StorageDestinationPicker(
        volumes: const [usb],
        value: const StorageDestination.internal(),
        onChanged: (_) {},
        onConnectUsb: () {},
      ),
    );
    await shoot(tester, 'save_to_choose');
  }, skip: !rendersScreenshots);

  testWidgets('Record directly to USB', (tester) async {
    await pump(
      tester,
      StorageDestinationPicker(
        volumes: const [usb],
        value: const StorageDestination.removable(1),
        enabled: false,
        onChanged: (_) {},
        onConnectUsb: () {},
      ),
    );
    await shoot(tester, 'save_to_recording');
  }, skip: !rendersScreenshots);

  testWidgets('Connect USB drive', (tester) async {
    await pump(
      tester,
      ConnectUsbSheet(onTryAgain: () {}, onCancel: () {}),
      inset: EdgeInsets.zero,
    );
    await shoot(tester, 'connect_usb_sheet');
  }, skip: !rendersScreenshots);
}
