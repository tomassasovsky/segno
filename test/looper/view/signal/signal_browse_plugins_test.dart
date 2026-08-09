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

  Future<PluginDescriptor?> open(
    WidgetTester tester,
    List<engine.PluginDescriptor> entries, {
    Size size = const Size(1920, 1080),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeAudioEngine()..pluginScanResults = entries;
    catalog = PluginCatalog(
      engine: fake,
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    // Real async: the scan polls on a timer, which `testWidgets`' fake clock
    // never advances on its own.
    await tester.runAsync(catalog.scan);
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
