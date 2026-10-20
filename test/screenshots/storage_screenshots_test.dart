@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:segno/storage/view/storage_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../helpers/helpers.dart';
import '../storage/helpers/storage_rig.dart';

/// The six tiles of pen 31 `Storage & safe eject`, at the pen's own numbers,
/// for eyeballing against the pen. Author-only, like every golden here: the
/// Material fonts come from the local Flutter SDK
/// (`SEGNO_SCREENSHOT_FONT_DIR`), and elsewhere these skip.
void main() {
  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  final hasFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  late StorageRig rig;

  /// Mounts the page on the tray sheet's own tone, inset as the System face
  /// insets its groups.
  Future<void> pump(
    WidgetTester tester, {
    List<RemovableVolumeRecord> volumes = const [],
    int internalFree = internalFree,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    rig = StorageRig(volumes: volumes)..internal(free: internalFree);
    for (final record in volumes) {
      rig.spaces[mountPoint(record.generation)] = const VolumeSpace(
        totalBytes: usbTotal,
        freeBytes: usbFree,
      );
    }
    final cubit = StorageCubit(
      repository: rig.repository,
      sampleRate: () => 48000,
    );
    addTearDown(() => unawaited(cubit.close()));
    addTearDown(() => unawaited(rig.dispose()));
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
        home: BlocProvider.value(
          value: cubit,
          child: Scaffold(
            backgroundColor: SurfaceTheme.dark.card,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(200, 120, 20, 20),
              child: StoragePage(onOpenLibrary: () {}),
            ),
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

  testWidgets('Storage overview', (tester) async {
    await pump(tester, volumes: [usbRecord(1)]);
    await shoot(tester, 'storage_overview');
  }, skip: !hasFonts);

  testWidgets('Ejecting USB', (tester) async {
    await pump(tester, volumes: [usbRecord(1)]);
    await tester.tap(find.byKey(const Key('storage_eject')));
    await tester.pumpAndSettle();
    await shoot(tester, 'storage_ejecting');
    rig.client.settleEject('req-1', ok: true);
    await tester.pumpAndSettle();
  }, skip: !hasFonts);

  testWidgets('Safe to remove', (tester) async {
    await pump(tester, volumes: [usbRecord(1)]);
    await tester.tap(find.byKey(const Key('storage_eject')));
    await tester.pumpAndSettle();
    rig.client.settleEject('req-1', ok: true);
    await tester.pumpAndSettle();
    await shoot(tester, 'storage_safe_to_remove');
  }, skip: !hasFonts);

  testWidgets('No USB drive', (tester) async {
    await pump(tester);
    await shoot(tester, 'storage_no_usb');
  }, skip: !hasFonts);

  testWidgets('Eject failed', (tester) async {
    await pump(tester, volumes: [usbRecord(1)]);
    await tester.tap(find.byKey(const Key('storage_eject')));
    await tester.pumpAndSettle();
    rig.client.settleEject('req-1', ok: false, reason: 'busy');
    await tester.pumpAndSettle();
    await shoot(tester, 'storage_eject_failed');
  }, skip: !hasFonts);

  testWidgets('Low internal space', (tester) async {
    await pump(tester, volumes: [usbRecord(1)], internalFree: 200000000);
    await shoot(tester, 'storage_low_internal');
  }, skip: !hasFonts);
}
