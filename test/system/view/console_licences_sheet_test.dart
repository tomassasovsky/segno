import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/system/view/console_licences_sheet.dart';
import 'package:segno/theme/theme.dart';

void main() {
  setUp(
    // The registry is a global and licences ADD to it, so without this each
    // test inherits every package the ones before it registered.
    LicenseRegistry.reset,
  );

  /// Opens the sheet on a 1920x1080 screen, the surface it is drawn for.
  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
            SpacingTheme.standard,
          ],
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open_licences'),
              onPressed: () => showConsoleLicences(
                context,
                packages: readConsoleLicencePackages(),
              ),
              child: const Text('Licences'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_licences')));
    await tester.pumpAndSettle();
  }

  group('showConsoleLicences', () {
    testWidgets("is the console's own panel, never Material's "
        'master-detail route, and Close shuts it', (tester) async {
      await open(tester);

      expect(find.byKey(const Key('console_licences_sheet')), findsOneWidget);
      // The console has no back chevron and no app bar; a second navigation
      // surface is the thing this panel exists to avoid.
      expect(find.byType(LicensePage), findsNothing);
      expect(find.byType(AppBar), findsNothing);

      await tester.tap(find.byKey(const Key('console_licences_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_licences_sheet')), findsNothing);
    });

    testWidgets('a package opens IN PLACE, one at a time, and its text is '
        "the registry's own", (tester) async {
      LicenseRegistry.addLicense(
        () => Stream.fromIterable([
          const LicenseEntryWithLineBreaks(['alpha_pkg'], 'ALPHA TERMS'),
          const LicenseEntryWithLineBreaks(['beta_pkg'], 'BETA TERMS'),
        ]),
      );
      await open(tester);

      // Shut: the drawer mounts nothing, so there is nothing to read.
      expect(find.text('ALPHA TERMS'), findsNothing);

      await tester.tap(find.byKey(const Key('console_licence_alpha_pkg')));
      await tester.pumpAndSettle();
      expect(find.text('ALPHA TERMS'), findsOneWidget);

      // One at a time — opening the next shuts the last.
      await tester.tap(find.byKey(const Key('console_licence_beta_pkg')));
      await tester.pumpAndSettle();
      expect(find.text('BETA TERMS'), findsOneWidget);
      expect(find.text('ALPHA TERMS'), findsNothing);
    });

    testWidgets('a registry too tall for the panel SCROLLS rather than '
        'overflowing it', (tester) async {
      // 150 packages is roughly what a real build registers, and comfortably
      // past the panel's own height. A `shrinkWrap` list handed unbounded
      // height sizes to all of it, paints past the card, and has no viewport
      // left to scroll — which is an overflow the framework reports as a test
      // failure, and a list that silently cannot be reached past its fold.
      LicenseRegistry.addLicense(
        () => Stream.fromIterable([
          for (var i = 0; i < 150; i++)
            LicenseEntryWithLineBreaks([
              'pkg_${i.toString().padLeft(3, '0')}',
            ], 'TERMS $i'),
        ]),
      );
      await open(tester);

      final list = tester.widget<ListView>(
        find.byKey(const Key('console_licences_list')),
      );
      expect(list.shrinkWrap, isTrue);

      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const Key('console_licences_list')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      // There is somewhere to scroll TO, which is the claim the shrinkWrap
      // comment makes and the thing an unbounded list cannot do.
      expect(position.maxScrollExtent, greaterThan(0));

      // And the panel is still inside the screen it was drawn for.
      final panel = tester.getRect(
        find.byKey(const Key('console_licences_sheet')),
      );
      expect(panel.height, lessThanOrEqualTo(1080));

      // The last package is reachable.
      await tester.drag(
        find.byKey(const Key('console_licences_list')),
        const Offset(0, -20000),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_licence_pkg_149')), findsOneWidget);
    });

    testWidgets('a registry that fits shrinks the card to it, rather than '
        'filling the panel with nothing', (tester) async {
      LicenseRegistry.addLicense(
        () => Stream.fromIterable([
          const LicenseEntryWithLineBreaks(['solo_pkg'], 'SOLO TERMS'),
        ]),
      );
      await open(tester);

      final panel = tester.getRect(
        find.byKey(const Key('console_licences_sheet')),
      );
      // Title + count + one 70px row + Close, nowhere near the 960 a filled
      // panel would take.
      expect(panel.height, lessThan(400));
    });

    testWidgets('the panel opens mid-animation, not between two frames', (
      tester,
    ) async {
      LicenseRegistry.addLicense(
        () => Stream.fromIterable([
          const LicenseEntryWithLineBreaks(['gamma_pkg'], 'GAMMA TERMS'),
        ]),
      );
      await open(tester);

      await tester.tap(find.byKey(const Key('console_licence_gamma_pkg')));
      await tester.pump();
      await tester.pump(kConsoleMotion ~/ 2);

      // The DRAWER's box, not the text's: the text is laid out at full size
      // from the first frame and the drawer clips it, so measuring the text
      // reports a settled size all the way through.
      const drawer = Key('console_licence_drawer_gamma_pkg');
      final opening = tester.getRect(find.byKey(drawer));
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byKey(drawer));

      // Grown out from under the row rather than appearing at full height.
      expect(opening.height, lessThan(settled.height));
      expect(opening.height, greaterThan(0));
    });
  });
}
