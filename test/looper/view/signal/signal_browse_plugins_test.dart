import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal/signal_browse_plugins.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import '../../../helpers/helpers.dart';

engine.PluginDescriptor _good(
  String id,
  String name, {
  String vendor = 'Acme',
}) => engine.PluginDescriptor(
  id: id,
  name: name,
  vendor: vendor,
  path: '/$id.vst3',
  format: engine.PluginFormat.vst3,
  version: 1,
);

/// What a file that failed to scan looks like: kept, but with no identity.
const _broken = engine.PluginDescriptor(
  id: '',
  name: 'BrokenOne.vst3',
  vendor: '',
  path: '/BrokenOne.vst3',
  format: engine.PluginFormat.vst3,
  version: 0,
);

void main() {
  late PluginCatalog catalog;
  late FakeAudioEngine fake;

  Future<PluginDescriptor?> open(
    WidgetTester tester,
    List<engine.PluginDescriptor> entries, {
    Size size = const Size(1920, 1080),
    bool holdScan = false,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    fake = FakeAudioEngine()..pluginScanResults = entries;
    catalog = PluginCatalog(
      engine: fake,
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    addTearDown(catalog.dispose);
    if (!holdScan) {
      // Real async: the scan polls on a timer, which `testWidgets`' fake
      // clock never advances on its own.
      await tester.runAsync(catalog.scan);
    }
    PluginDescriptor? picked;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => picked = await showSignalBrowsePlugins(
                  context,
                  catalog: catalog,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets("takes the width of the surface, not Material's 640 cap", (
    tester,
  ) async {
    await open(tester, [_good('a', 'Alpha')]);

    // A list across a 1920 surface, not a phone dialog: capped, the results
    // grid loses columns for no reason the player can see.
    final width = tester
        .getSize(find.byKey(const Key('signal_browse_plugins')))
        .width;
    expect(width, greaterThan(640));
  });

  testWidgets('offers only what actually loaded', (tester) async {
    await open(tester, [_good('a', 'Alpha'), _broken]);

    // A failed entry has an EMPTY id, so a chip for it would insert a
    // `PluginRef` with no identity — and two of them would collide.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('BrokenOne.vst3'), findsNothing);
  });

  testWidgets('search trims what the keyboard added', (tester) async {
    await open(tester, [_good('a', 'Alpha'), _good('b', 'Beta')]);

    await tester.enterText(
      find.byKey(const Key('signal_browse_search')),
      'alpha ',
    );
    await tester.pumpAndSettle();

    // A trailing space is not part of what someone typed.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('a whitespace query is not a query', (tester) async {
    await open(tester, [_good('a', 'Alpha'), _good('b', 'Beta')]);

    await tester.enterText(find.byKey(const Key('signal_browse_search')), '  ');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('matches the vendor as well as the name', (tester) async {
    await open(tester, [
      _good('a', 'Alpha', vendor: 'Tokyo Dawn'),
      _good('b', 'Beta'),
    ]);

    await tester.enterText(
      find.byKey(const Key('signal_browse_search')),
      'tokyo',
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('a sheet opened cold looks for plugins itself', (tester) async {
    // Nothing has scanned. The relink action opens this sheet DIRECTLY, with
    // no add dialog ahead of it to have filled the catalog — and a sheet that
    // only listed what was already there told the player, on a fresh boot,
    // that they had no plugins at all.
    await open(tester, [_good('a', 'Alpha')], holdScan: true);
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('a scan that lands while the sheet is open reaches it', (
    tester,
  ) async {
    // Already scanned once and found nothing, so the sheet's own look is a
    // no-op: what lands here is somebody ELSE's scan, underneath it.
    await open(tester, []);
    expect(find.text('Alpha'), findsNothing);

    fake.pluginScanResults = [_good('a', 'Alpha')];
    await tester.runAsync(catalog.scan);
    await tester.pump();
    await tester.pump();

    // The catalog is not a Listenable. Without following its progress the
    // sheet keeps showing whatever was there when it opened, and the only
    // thing that refreshed it was typing a character into the search box.
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('a plugin installed later can be found by asking again', (
    tester,
  ) async {
    await open(tester, []);
    expect(find.byKey(const Key('signal_browse_empty')), findsOneWidget);

    // The cold-start scan is gated on one having COMPLETED, so a plugin
    // installed after the first boot can never appear on its own — the
    // catalog stays whatever the rig had the first time it looked.
    fake.pluginScanResults = [_good('a', 'Alpha')];
    await tester.tap(find.byKey(const Key('signal_browse_rescan')));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('a scan in flight says so, and can be stopped', (tester) async {
    await open(tester, [_good('a', 'Alpha')], holdScan: true);
    fake.pluginScanPending = true;
    unawaited(catalog.scan(rescan: true));
    // The poll runs on a timer, so the sheet only hears about the scan on the
    // first tick.
    await tester.pump(const Duration(milliseconds: 5));

    expect(find.byKey(const Key('signal_browse_scanning')), findsOneWidget);
    expect(find.byKey(const Key('signal_browse_rescan')), findsNothing);

    await tester.tap(find.byKey(const Key('signal_browse_stop_scan')));
    await tester.pumpAndSettle();

    // A scan of a big plugin folder is minutes long; with no way to stop one
    // the sheet was hostage to it.
    expect(catalog.isScanning, isFalse);
  });

  testWidgets('an empty catalog and an empty result are different facts', (
    tester,
  ) async {
    await open(tester, []);
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('signal_browse_plugins'))),
    );

    expect(find.text(l10n.fxBrowseNoPlugins), findsOneWidget);
    expect(find.text(l10n.fxBrowseNoMatches), findsNothing);
  });

  testWidgets('a query that matches nothing says so about the query', (
    tester,
  ) async {
    await open(tester, [_good('a', 'Alpha')]);
    await tester.enterText(
      find.byKey(const Key('signal_browse_search')),
      'zzz',
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('signal_browse_plugins'))),
    );

    expect(find.text(l10n.fxBrowseNoMatches), findsOneWidget);
    expect(find.text(l10n.fxBrowseNoPlugins), findsNothing);
  });
}
