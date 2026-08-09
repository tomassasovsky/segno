import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Everything the scan found, searchable — the way to a plugin that is not on
/// the add dialog's short shelf.
///
/// A bottom sheet rather than a second dialog: it is a LIST of a hundred
/// things and the add dialog is a handful of choices, so this takes the width
/// of the surface and the dialog stays the size of its own question.
///
/// Resolves to the chosen descriptor, or null when dismissed.
Future<PluginDescriptor?> showSignalBrowsePlugins(
  BuildContext context, {
  required PluginCatalog catalog,
}) => showModalBottomSheet<PluginDescriptor>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: context.surface.scrim,
  builder: (_) => _BrowseSheet(catalog: catalog),
);

class _BrowseSheet extends StatefulWidget {
  const _BrowseSheet({required this.catalog});

  final PluginCatalog catalog;

  @override
  State<_BrowseSheet> createState() => _BrowseSheetState();
}

class _BrowseSheetState extends State<_BrowseSheet> {
  String _query = '';

  /// Matches on the plugin's own words — its name and its vendor.
  ///
  /// Not the path: a search that matched a directory would rank plugins by
  /// where someone happened to install them, which is not a fact about the
  /// plugin. Case-insensitive and substring rather than prefix, because the
  /// vendor is often the prefix and the name is what is being looked for.
  List<PluginDescriptor> get _results {
    final all = widget.catalog.descriptors;
    if (_query.isEmpty) return all;
    final needle = _query.toLowerCase();
    return [
      for (final plugin in all)
        if (plugin.name.toLowerCase().contains(needle) ||
            plugin.vendor.toLowerCase().contains(needle))
          plugin,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final all = widget.catalog.descriptors;
    final results = _results;

    return Container(
      key: const Key('signal_browse_plugins'),
      padding: const EdgeInsets.fromLTRB(19, 20, 19, 19),
      decoration: BoxDecoration(
        color: surface.card,
        border: Border(top: BorderSide(color: surface.borderStrong)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.fxBrowseTitle,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 18,
                    height: 1.17,
                    leadingDistribution: TextLeadingDistribution.even,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  l10n.fxBrowseInstalled(all.length),
                  style: TextStyle(
                    color: surface.textMuted,
                    fontSize: 14,
                    height: 1.21,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
                const Spacer(),
                ConsoleSmallButton(
                  key: const Key('signal_browse_cancel'),
                  label: l10n.cancel,
                  onPressed: Navigator.of(context).pop,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SearchField(
              hint: l10n.fxBrowseSearchHint,
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 14),
            if (all.isEmpty)
              ConsoleEmptyCard(
                key: const Key('signal_browse_empty'),
                message: l10n.fxBrowseNoPlugins,
              )
            else if (results.isEmpty)
              ConsoleEmptyCard(
                key: const Key('signal_browse_no_matches'),
                // A fact about the query, not about the rig — the scan found
                // plenty, this search did not.
                message: l10n.fxBrowseNoMatches,
              )
            else ...[
              Flexible(
                child: SingleChildScrollView(
                  child: ConsoleChipGrid<String>(
                    key: const Key('signal_browse_results'),
                    selected: const {},
                    onTap: (id) => Navigator.of(context).pop(
                      results.where((d) => d.id == id).firstOrNull,
                    ),
                    options: [
                      for (final plugin in results)
                        ConsoleSegment(
                          value: plugin.id,
                          label: plugin.name,
                          // The format as the machine fact under the name —
                          // the same treatment the recent shelf gives it.
                          sublabel: plugin.format.name.toUpperCase(),
                          optionKey: Key('signal_browse_${plugin.id}'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.fxBrowseMatches(results.length),
                style: TextStyle(
                  color: surface.textMuted,
                  fontSize: 13,
                  height: 1.23,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The sheet's search field — accented border and caret, as the mockups draw
/// it, because the field is where the sheet opens focused.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.accent),
      ),
      child: TextField(
        key: const Key('signal_browse_search'),
        autofocus: true,
        onChanged: onChanged,
        cursorColor: surface.accent,
        style: TextStyle(
          color: surface.textPrimary,
          fontSize: 18,
          height: 1.17,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          hintText: hint,
          hintStyle: TextStyle(
            color: surface.textMuted,
            fontSize: 18,
            height: 1.17,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }
}
