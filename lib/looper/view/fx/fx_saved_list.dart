import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/fx_presets_cubit.dart';
import 'package:segno/looper/view/fx/fx_chain_strip.dart';
import 'package:segno/looper/view/fx/fx_library_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The pen's `04 My presets`: the player's own saved sounds, each a card that
/// recalls it over a row that renames or deletes it.
///
/// Both jobs on one page, as the pen draws it. Recalling and managing are the
/// same list, and a second page to manage what this one lists would be a place
/// to keep a name in step with.
class FxSavedList extends StatelessWidget {
  /// Creates an [FxSavedList].
  const FxSavedList({
    required this.freeSlots,
    required this.onChoose,
    super.key,
  });

  /// How many chain entries the destination can still take.
  final int freeSlots;

  /// Reports the preset chosen.
  final ValueChanged<FxLibraryChoice> onChoose;

  /// The pen's card geometry.
  static const double _cardWidth = 442;
  static const double _cardGap = 24;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final presets = context.watch<FxPresetsCubit>().state;
    if (presets.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: AppText(
          l10n.fxNoSavedPresets,
          key: const Key('fx_saved_empty'),
          style: TextStyle(color: surface.textTertiary, fontSize: 24),
        ),
      );
    }
    return SingleChildScrollView(
      child: Wrap(
        spacing: _cardGap,
        runSpacing: _cardGap,
        children: [
          for (final preset in presets)
            SizedBox(
              width: _cardWidth,
              child: _SavedPreset(
                preset: preset,
                // A saved sound that would not fit is still listed and still
                // says why, rather than half-landing or quietly vanishing.
                fits: preset.entries.length <= freeSlots,
                freeSlots: freeSlots,
                onChoose: () => onChoose(FxSavedChoice(preset)),
              ),
            ),
        ],
      ),
    );
  }
}

/// One saved sound: the card that recalls it, and the row that manages it.
class _SavedPreset extends StatelessWidget {
  const _SavedPreset({
    required this.preset,
    required this.fits,
    required this.freeSlots,
    required this.onChoose,
  });

  final FxUserPreset preset;
  final bool fits;
  final int freeSlots;
  final VoidCallback onChoose;

  Future<void> _rename(BuildContext context) async {
    final l10n = context.l10n;
    final presets = context.read<FxPresetsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.fxPresetRename,
      subtitle: preset.name,
      current: preset.name,
      fieldLabel: l10n.fxPresetNameField,
    );
    if (name == null) return;
    await presets.rename(preset.id, name);
  }

  Future<void> _delete(BuildContext context) async {
    final l10n = context.l10n;
    final presets = context.read<FxPresetsCubit>();
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.fxPresetDeleteTitle(preset.name),
      // The accepted rule, said where it matters: a saved definition and the
      // instances made from it are separate things.
      body: l10n.fxPresetDeleteBody,
      confirmLabel: l10n.fxPresetDelete,
    );
    if (!confirmed) return;
    await presets.remove(preset.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: fits ? 1 : surface.disabledOpacity,
          child: Material(
            color: surface.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: surface.borderSubtle),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: Key('fx_saved_${preset.id}'),
              onTap: fits ? onChoose : null,
              child: SizedBox(
                height: 323,
                child: Padding(
                  padding: const EdgeInsets.all(25),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: FxRackArt(slug: preset.art, lit: true),
                      ),
                      const SizedBox(height: 16),
                      AppText(
                        preset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 24,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 16),
                      AppText(
                        fits
                            ? l10n.fxModuleCount(preset.entries.length)
                            : l10n.fxRackTooLong(
                                preset.name,
                                preset.entries.length,
                                freeSlots,
                              ),
                        maxLines: 2,
                        style: TextStyle(
                          color: surface.textTertiary,
                          fontSize: 20,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            LoopOutlinedButton(
              key: Key('fx_saved_rename_${preset.id}'),
              width: 140,
              height: 54,
              fontSize: 20,
              label: l10n.fxPresetRename,
              onTap: () => unawaited(_rename(context)),
            ),
            const SizedBox(width: 10),
            // Export is drawn where the pen draws it and does nothing: moving
            // a preset off this console is the USB export domain's job, and
            // that domain is not built. A control with nothing to do reads as
            // having nothing to do.
            LoopOutlinedButton(
              key: Key('fx_saved_export_${preset.id}'),
              width: 141,
              height: 54,
              fontSize: 20,
              label: l10n.fxPresetExport,
              onTap: null,
            ),
            const SizedBox(width: 10),
            LoopOutlinedButton(
              key: Key('fx_saved_delete_${preset.id}'),
              width: 141,
              height: 54,
              fontSize: 20,
              label: l10n.fxPresetDelete,
              onTap: () => unawaited(_delete(context)),
            ),
          ],
        ),
      ],
    );
  }
}
