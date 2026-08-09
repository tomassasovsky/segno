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

/// Whether a dialog is already on its way up.
///
/// Guards the window BEFORE the dialog exists, and only that: reading the
/// recent shelf is a real platform round-trip on the appliance, and a second
/// tap inside it would open a second dialog and add the effect twice. Once
/// the dialog is up its own modal barrier does the job — holding the flag
/// until it closes would strand it forever on a route that never pops.
bool _opening = false;

/// How long the shelf read is given before the dialog opens anyway.
///
/// A wedged platform channel must not make the add button a permanent no-op:
/// the shelf is a convenience, and a dialog with no shelf still adds effects.
const Duration _shelfTimeout = Duration(seconds: 2);

/// Offers what can go on the end of a chain: the seven built-ins, the plugins
/// you reached for last, and a way to the rest.
///
/// **The accent in the grid does not mean "picked".** It marks what is
/// ALREADY in this chain — the mockups draw `Drive` and `Filter` lit on a
/// chain that is Drive → Filter, with nothing selected at all. A grid used as
/// a pick-one gets that backwards, which is why its `selected` set is fed the
/// chain's own contents rather than a cursor. There is no confirm step: a tap
/// adds, and the dialog closes.
Future<void> showSignalAddEffect(
  BuildContext context, {
  required FxScope scope,
  required String chainName,
}) async {
  if (_opening) return;
  _opening = true;
  final PluginCatalog catalog;
  final SettingsRepository settings;
  List<String> recents;
  try {
    final repository = context.read<LooperRepository>();
    settings = context.read<SettingsRepository>();
    catalog = repository.pluginCatalog;
    // The shelf is a convenience. A store that hangs, or throws, must not
    // stop the dialog opening; without the catch the failure escapes through
    // the `unawaited` at the call site and no dialog appears at all.
    //
    // `on Object`, deliberately, and NOT `on Exception`: the prefs backends
    // throw `Error`s for exactly the cases this guards. The Foundation
    // implementation converts a platform argument failure into `ArgumentError`
    // on purpose, and every backend casts the platform reply (`… as String?`),
    // which raises `TypeError` on a value of the wrong type — a stored key
    // that got corrupted, say. Narrowing this to `Exception` looked tidier and
    // put the permanent no-op straight back.
    try {
      recents = await SignalRecentPlugins.load(
        settings,
      ).timeout(_shelfTimeout, onTimeout: () => const []);
    } on Object {
      recents = const [];
    }
  } finally {
    _opening = false;
  }
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _AddEffectDialog(
      scope: scope,
      chainName: chainName,
      catalog: catalog,
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
    // A newline would split one id into two phantoms on the way back out, and
    // an empty id is what a failed scan carries — neither is a plugin.
    if (id.isEmpty || id.contains('\n')) return;
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

class _AddEffectDialog extends StatefulWidget {
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

  /// The dialog's width.
  ///
  /// 746, not the 744 the mockups measure: the grid inside needs 694 for its
  /// four columns (4x166 + 3x10), and 744 less 25 of padding either side and
  /// the 1px border leaves 692 — two short, which drops the grid to TWO
  /// columns and makes the dialog tall enough to overflow a 1024x600 screen.
  /// The pen's own arithmetic is what is off by the border.
  static const double width = 746;

  @override
  State<_AddEffectDialog> createState() => _AddEffectDialogState();
}

class _AddEffectDialogState extends State<_AddEffectDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(_scanIfNeeded());
  }

  /// Fills the catalog, once, if nobody has looked yet.
  ///
  /// Gated on whether a scan has ever COMPLETED — `cache.appVersion` is only
  /// set by a finished harvest — rather than on whether it found anything.
  /// Gating on `descriptors` rescans the filesystem on every open of the
  /// default appliance, which has no plugins at all; gating on
  /// `availablePlugins` also rescans a machine where every candidate file
  /// fails to load.
  ///
  /// A scan already in flight is JOINED, not skipped, whether or not one has
  /// completed before: `PluginCatalog.scan()` hands back the running future.
  /// Returning early there leaves the dialog subscribed to nothing while its
  /// build already read `isScanning` and drew "Looking for plugins…" with the
  /// browse row disabled — stuck that way for good. That is reachable on the
  /// rescan path as easily as on the first scan, which is why the check is on
  /// BOTH conditions rather than either.
  ///
  /// AWAITED and redrawn: a fire-and-forget scan into a snapshot leaves the
  /// dialog reading "0 plugins" for as long as it is open.
  Future<void> _scanIfNeeded() async {
    final catalog = widget.catalog;
    if (catalog.cache.appVersion.isNotEmpty && !catalog.isScanning) return;
    await catalog.scan();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final scope = widget.scope;
    final catalog = widget.catalog;
    // `availablePlugins`, not `descriptors`: a file that failed to scan is
    // kept in the catalog with an EMPTY id, so offering it would insert a
    // `PluginRef` with no identity — an instant D-MISS placeholder — and two
    // such chips would resolve to the same entry.
    final descriptors = catalog.availablePlugins;
    final scanning = catalog.isScanning;
    final shelf = SignalRecentPlugins.resolve(widget.recents, descriptors);
    // The types already on this chain, which is what the accent marks.
    final present = {
      for (final effect in scope.effects)
        if (effect case BuiltInEffect(:final type)) type,
    };

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        key: const Key('signal_add_effect'),
        width: _AddEffectDialog.width,
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(
          color: surface.card,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: surface.borderStrong),
        ),
        // Scrollable, because the shelf appears only after a plugin has been
        // added once — so the dialog that fits today can stop fitting later,
        // on the shortest screen the console ships on.
        child: SingleChildScrollView(
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
                l10n.fxAddInto(widget.chainName),
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
                    // A count of zero mid-scan is not a fact about the
                    // machine, so the row says what it is doing instead.
                    title: scanning
                        ? l10n.fxAddScanning
                        : l10n.fxAddBrowseAll(descriptors.length),
                    // Nor tappable at zero: the sheet it opens would have
                    // nothing in it but the same sentence. "Available", not
                    // "installed" — a machine can have plugin files that all
                    // failed to load, and this row cannot tell the player
                    // there are none when there are.
                    onTap: scanning || descriptors.isEmpty
                        ? null
                        : () => unawaited(_browse(context)),
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
    widget.scope.insertPlugin(
      PluginRef(format: plugin.format, id: plugin.id, version: plugin.version),
    );
    unawaited(SignalRecentPlugins.remember(widget.settings, plugin.id));
    Navigator.of(context).pop();
  }

  Future<void> _browse(BuildContext context) async {
    final navigator = Navigator.of(context);
    final picked = await showSignalBrowsePlugins(
      context,
      catalog: widget.catalog,
    );
    if (picked == null) {
      return;
    }
    widget.scope.insertPlugin(
      PluginRef(format: picked.format, id: picked.id, version: picked.version),
    );
    unawaited(SignalRecentPlugins.remember(widget.settings, picked.id));
    navigator.pop();
  }
}
