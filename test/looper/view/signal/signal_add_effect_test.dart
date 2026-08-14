import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal/signal_add_effect.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

const _a = PluginDescriptor(
  id: 'plug.a',
  name: 'Airwindows Console',
  vendor: 'Airwindows',
  path: '/a.vst3',
  format: PluginFormat.vst3,
  version: 1,
);
const _b = PluginDescriptor(
  id: 'plug.b',
  name: 'TDR Nova',
  vendor: 'Tokyo Dawn',
  path: '/b.clap',
  format: PluginFormat.clap,
  version: 1,
);

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('the recent shelf', () {
    test('remembers newest first, without duplicates', () async {
      await SignalRecentPlugins.remember(settings, 'plug.a');
      await SignalRecentPlugins.remember(settings, 'plug.b');
      await SignalRecentPlugins.remember(settings, 'plug.a');

      expect(await SignalRecentPlugins.load(settings), ['plug.a', 'plug.b']);
    });

    test('drops ids the catalog no longer reports', () {
      // The catalog decides what EXISTS; the list only remembers an order, so
      // a plugin that was uninstalled leaves rather than drawing a dead cell.
      final shelf = SignalRecentPlugins.resolve(
        ['plug.a', 'gone', 'plug.b'],
        const [_a, _b],
      );

      expect(shelf.map((d) => d.id), ['plug.a', 'plug.b']);
    });

    test('shows one row at most', () {
      final many = [
        for (var i = 0; i < 9; i++)
          PluginDescriptor(
            id: 'p$i',
            name: 'P$i',
            vendor: 'v',
            path: '/p$i',
            format: PluginFormat.vst3,
            version: 1,
          ),
      ];

      expect(
        SignalRecentPlugins.resolve(many.map((d) => d.id).toList(), many),
        hasLength(SignalRecentPlugins.shelf),
      );
    });
  });

  group('the built-in grid', () {
    Future<void> pumpGrid(
      WidgetTester tester, {
      required Set<TrackEffectType> present,
      required ValueChanged<TrackEffectType> onTap,
    }) async {
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
            builder: (context) {
              final l10n = context.l10n;
              return Scaffold(
                body: ConsoleChipGrid<TrackEffectType>(
                  selected: present,
                  onTap: onTap,
                  options: [
                    for (final type in TrackEffectType.values)
                      if (type != TrackEffectType.none)
                        ConsoleSegment(
                          value: type,
                          label: l10n.effectTypeLabel(type),
                        ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lights what is ALREADY on the chain, not a pick', (
      tester,
    ) async {
      TrackEffectType? tapped;
      await pumpGrid(
        tester,
        present: {TrackEffectType.drive, TrackEffectType.filter},
        onTap: (type) => tapped = type,
      );

      // The accent is a fact about the chain, so nothing is "selected" before
      // a tap and tapping a lit cell adds a SECOND one rather than toggling.
      expect(tapped, isNull);
      await tester.tap(find.text('Drive'));
      await tester.pumpAndSettle();
      expect(tapped, TrackEffectType.drive);
    });

    testWidgets('offers the seven, and not the absence of an effect', (
      tester,
    ) async {
      await pumpGrid(tester, present: const {}, onTap: (_) {});

      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Reverb'), findsOneWidget);
      // `none` is what an empty slot IS, not something anyone adds.
      expect(find.byType(ConsoleSegment<TrackEffectType>), findsNothing);
      final grid = tester.widget<ConsoleChipGrid<TrackEffectType>>(
        find.byType(ConsoleChipGrid<TrackEffectType>),
      );
      expect(grid.options, hasLength(7));
    });
  });
}
