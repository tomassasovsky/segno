import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/signal_browse_plugins.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

/// What can go on the end of a chain: the seven built-ins, the plugins you
/// reached for last, and a way to the rest.
///
/// **The accent here does not mean "picked".** It marks what is ALREADY in
/// this chain — the mockups draw `Drive` and `Filter` lit on a chain that is
/// Drive → Filter, with nothing selected at all. A grid used as a pick-one
/// gets that backwards, which is why the grid's `selected` set is fed the
/// chain's own contents rather than a cursor. There is no confirm step: a tap
/// adds, and the dialog closes.
Future<void> showSignalAddEffect(
  BuildContext context, {
  required FxScope scope,
  required String chainName,
}) async {
  final repository = context.read<LooperRepository>();
  final settings = context.read<SettingsRepository>();
  final recents = await SignalRecentPlugins.load(settings);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _AddEffectDialog(
      scope: scope,
      chainName: chainName,
      catalog: repository.pluginCatalog,
      recents: recents,
      settings: settings,
    ),
  );
}

/// The plugin ids most recently added, newest first.
///
/// Persisted as a plain newline-separated list rather than as JSON: it is an
/// ORDER over ids the catalog already owns, so anything more would be a second
/// place for a plugin's identity to live and drift.
class SignalRecentPlugins {
  /// How many the shelf shows — one row of the add dialog's grid.
  static const int shelf = 4;

  /// Reads the remembered order.
  static Future<List<String>> load(SettingsRepository settings) async {
    final raw = await settings.loadRecentPlugins();
    if (raw == null || raw.isEmpty) return const [];
    return raw.split('\n').where((id) => id.isNotEmpty).toList();
  }

  /// Moves [id] to the front and writes the list back.
  static Future<void> remember(
    SettingsRepository settings,
    String id,
  ) async {
    final current = await load(settings);
    final next = [id, ...current.where((existing) => existing != id)];
    await settings.saveRecentPlugins(next.take(shelf * 2).join('\n'));
  }

  /// The shelf: remembered ids that still scan, newest first, resolved
  /// against [catalog].
  ///
  /// An id the catalog no longer reports is dropped rather than drawn as a
  /// dead cell — the catalog decides what exists; the list only remembers an
  /// order.
  static List<PluginDescriptor> resolve(
    List<String> ids,
    List<PluginDescriptor> catalog,
  ) => [
    for (final id in ids) ...catalog.where((d) => d.id == id).take(1),
  ].take(shelf).toList();
}

class _AddEffectDialog extends StatelessWidget {
  const _AddEffectDialog({
    required this.scope,
    required this.chainName,
    required this.catalog,
    required this.recents,
    required this.settings,
  });

  final FxScope scope;
  final String chainName;
  final PluginCatalog catalog;
  final List<String> recents;
  final SettingsRepository settings;

  /// The dialog's width, as the mockups draw it — the same 744 the pick-one
  /// settled on, so two dialogs on one surface are not two widths.
  static const double width = 744;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final descriptors = catalog.descriptors;
    final shelf = SignalRecentPlugins.resolve(recents, descriptors);
    // The types already on this chain, which is what the accent marks.
    final present = {
      for (final effect in scope.effects)
        if (effect case BuiltInEffect(:final type)) type,
    };

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        key: const Key('signal_add_effect'),
        width: width,
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(
          color: surface.card,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: surface.borderStrong),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.fxAddTitle,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 19,
                height: 1.16,
                leadingDistribution: TextLeadingDistribution.even,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.fxAddInto(chainName),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 16,
                height: 1.55,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            const SizedBox(height: 19),
            ConsoleGroupLabel(l10n.fxAddBuiltIn),
            const SizedBox(height: 10),
            ConsoleChipGrid<TrackEffectType>(
              key: const Key('signal_add_builtin'),
              selected: present,
              onTap: (type) {
                scope.addEffectOfType(type);
                Navigator.of(context).pop();
              },
              options: [
                // `none` is the absence of an effect, not one of the seven.
                for (final type in TrackEffectType.values)
                  if (type != TrackEffectType.none)
                    ConsoleSegment(
                      value: type,
                      label: l10n.effectTypeLabel(type),
                      optionKey: Key('signal_add_builtin_${type.name}'),
                    ),
              ],
            ),
            if (shelf.isNotEmpty) ...[
              const SizedBox(height: 19),
              ConsoleGroupLabel(l10n.fxAddRecentPlugins),
              const SizedBox(height: 10),
              ConsoleChipGrid<String>(
                key: const Key('signal_add_recent'),
                selected: const {},
                onTap: (id) => _addPlugin(context, shelf, id),
                options: [
                  for (final plugin in shelf)
                    ConsoleSegment(
                      value: plugin.id,
                      label: plugin.name,
                      // The format is a real fact in the wrong place on a
                      // chain chip; here it is exactly what a sublabel is for
                      // (D4/D7) — and it makes the cell the vocabulary's own
                      // two-line height instead of a size nothing else has.
                      sublabel: plugin.format.name.toUpperCase(),
                      optionKey: Key('signal_add_recent_${plugin.id}'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 19),
            ConsoleCard(
              key: const Key('signal_add_browse'),
              children: [
                ConsoleRow(
                  title: l10n.fxAddBrowseAll(descriptors.length),
                  onTap: () => unawaited(_browse(context)),
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: 19),
            Align(
              alignment: Alignment.centerRight,
              child: ConsoleSmallButton(
                key: const Key('signal_add_cancel'),
                label: l10n.cancel,
                onPressed: Navigator.of(context).pop,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addPlugin(
    BuildContext context,
    List<PluginDescriptor> shelf,
    String id,
  ) {
    final plugin = shelf.where((d) => d.id == id).firstOrNull;
    if (plugin == null) return;
    scope.insertPlugin(
      PluginRef(format: plugin.format, id: plugin.id, version: plugin.version),
    );
    unawaited(SignalRecentPlugins.remember(settings, plugin.id));
    Navigator.of(context).pop();
  }

  Future<void> _browse(BuildContext context) async {
    final navigator = Navigator.of(context);
    final picked = await showSignalBrowsePlugins(context, catalog: catalog);
    if (picked == null) {
      return;
    }
    scope.insertPlugin(
      PluginRef(format: picked.format, id: picked.id, version: picked.version),
    );
    unawaited(SignalRecentPlugins.remember(settings, picked.id));
    navigator.pop();
  }
}
