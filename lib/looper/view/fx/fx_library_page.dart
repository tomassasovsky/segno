import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_saved_list.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// What the library was asked for: a whole rack preset, or a single effect.
sealed class FxLibraryChoice {
  const FxLibraryChoice();
}

/// One factory rack preset, to be instantiated as a run of chain entries.
final class FxRackChoice extends FxLibraryChoice {
  /// Creates an [FxRackChoice].
  const FxRackChoice(this.preset);

  /// The preset chosen.
  final FxPreset preset;
}

/// One standalone effect, alongside the rack families rather than inside one.
final class FxSingleChoice extends FxLibraryChoice {
  /// Creates an [FxSingleChoice].
  const FxSingleChoice(this.type);

  /// The built-in chosen.
  final TrackEffectType type;
}

/// One of the player's own saved sounds.
final class FxSavedChoice extends FxLibraryChoice {
  /// Creates an [FxSavedChoice].
  const FxSavedChoice(this.preset);

  /// The saved preset chosen.
  final FxUserPreset preset;
}

/// The effect library (accepted design, `03 Sound library & presets`): the
/// rack families and Single FX in one artwork grid, then the chosen family's
/// presets.
///
/// A route that RESOLVES to a choice rather than one that edits: what the
/// choice does to a chain belongs to the destination that opened this, so
/// Back here changes nothing and choosing returns.
class FxLibraryPage extends StatefulWidget {
  /// Creates an [FxLibraryPage] adding to [destinationLabel].
  const FxLibraryPage({
    required this.catalogue,
    required this.destinationLabel,
    this.freeSlots = kTrackEffectMax,
    super.key,
  });

  /// The catalogue to offer.
  final FxCatalogue catalogue;

  /// What the header says this is being added to — stated once, which is the
  /// accepted design's rule: no repeated source subtitle below it.
  final String destinationLabel;

  /// How many chain entries the destination can still take. A rack needing
  /// more than this is offered but explains itself rather than half-landing.
  final int freeSlots;

  @override
  State<FxLibraryPage> createState() => _FxLibraryPageState();
}

class _FxLibraryPageState extends State<FxLibraryPage> {
  /// The family being browsed, or null for the grid.
  ///
  /// Page state rather than a route, so Back from a family lands on the grid
  /// and Back from the grid leaves the library — which is what makes the
  /// accepted "one Back returns to the destination" possible once a choice is
  /// made.
  FxFamily? _family;

  /// Whether the standalone-effect list is showing.
  bool _single = false;

  /// Whether the player's saved sounds are showing.
  bool _saved = false;

  void _back() {
    if (_family != null || _single || _saved) {
      setState(() {
        _family = null;
        _single = false;
        _saved = false;
      });
      return;
    }
    Navigator.maybePop(context);
  }

  void _choose(FxLibraryChoice choice) => Navigator.maybePop(context, choice);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final family = _family;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.fxAddCrumb(widget.destinationLabel),
        title: switch ((family, _single, _saved)) {
          (final FxFamily f, _, _) => f.name,
          (_, true, _) => l10n.fxLibrarySingle,
          (_, _, true) => l10n.fxMyPresetsTitle,
          _ => l10n.fxAddTitle,
        },
        onBack: _back,
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          if (family != null)
            Positioned(
              left: 36,
              top: 86,
              child: AppText(
                l10n.fxPresetCount(family.presets.length),
                key: const Key('fx_library_subtitle'),
                style: TextStyle(
                  color: context.surface.textSecondary,
                  fontSize: 22,
                ),
              ),
            ),
          // Import and Export all are drawn where the pen draws them and do
          // nothing: moving presets on or off this console is the USB export
          // domain's job, and that domain is not built.
          if (_saved)
            Positioned(
              left: 36,
              top: 32,
              right: 36,
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  LoopOutlinedButton(
                    key: const Key('fx_presets_import'),
                    width: 204,
                    label: l10n.fxImportPresets,
                    onTap: null,
                  ),
                  const SizedBox(width: 14),
                  LoopOutlinedButton(
                    key: const Key('fx_presets_export_all'),
                    width: 151,
                    label: l10n.fxExportAllPresets,
                    onTap: null,
                  ),
                ],
              ),
            ),
          Positioned(
            left: 36,
            top: family != null || _single || _saved ? 138 : 124,
            right: 36,
            bottom: 24,
            child: switch ((family, _single, _saved)) {
              (final FxFamily f, _, _) => _PresetList(
                family: f,
                freeSlots: widget.freeSlots,
                onChoose: _choose,
              ),
              (_, true, _) => _SingleList(onChoose: _choose),
              (_, _, true) => FxSavedList(
                freeSlots: widget.freeSlots,
                onChoose: _choose,
              ),
              _ => _LibraryGrid(
                catalogue: widget.catalogue,
                onFamily: (f) => setState(() => _family = f),
                onSingle: () => setState(() => _single = true),
                onSaved: () => setState(() => _saved = true),
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// The artwork grid: My presets, the rack families and Single FX.
class _LibraryGrid extends StatelessWidget {
  const _LibraryGrid({
    required this.catalogue,
    required this.onFamily,
    required this.onSingle,
    required this.onSaved,
  });

  final FxCatalogue catalogue;
  final void Function(FxFamily) onFamily;
  final VoidCallback onSingle;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (catalogue.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: AppText(
          l10n.fxLibraryEmpty,
          key: const Key('fx_library_empty'),
          style: TextStyle(color: context.surface.textTertiary, fontSize: 24),
        ),
      );
    }
    // Ed's Rack takes the wide banner the accepted design gives it; every
    // other family takes the square card.
    final wide = catalogue.family("Ed's Rack");
    final rest = [
      for (final family in catalogue.families)
        if (family != wide) family,
    ];
    return SingleChildScrollView(
      child: Wrap(
        spacing: 40,
        runSpacing: 20,
        children: [
          _LibraryCard(
            key: const Key('fx_library_saved'),
            label: l10n.fxLibraryMyPresets,
            // The player's own saved sounds have no factory artwork, and the
            // accepted design gives My presets matching ORIGINAL artwork
            // rather than a borrowed rack banner. Until that art exists the
            // card carries its name and no picture.
            onTap: onSaved,
          ),
          if (wide != null)
            _LibraryCard(
              key: Key('fx_library_family_${wide.slug}'),
              label: wide.name,
              asset: wide.selectorAsset,
              width: 810,
              onTap: () => onFamily(wide),
            ),
          _LibraryCard(
            key: const Key('fx_library_single'),
            label: l10n.fxLibrarySingle,
            asset: kFxSingleSelectorAsset,
            onTap: onSingle,
          ),
          for (final family in rest)
            _LibraryCard(
              key: Key('fx_library_family_${family.slug}'),
              label: family.name,
              asset: family.selectorAsset,
              onTap: () => onFamily(family),
            ),
        ],
      ),
    );
  }
}

/// One catalogue entry: its artwork over its name.
class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.label,
    required this.onTap,
    this.asset,
    this.width = 385,
    super.key,
  });

  final String label;
  final String? asset;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: surface.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: 260,
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: asset == null
                        ? const SizedBox.shrink()
                        : Image.asset(
                            asset!,
                            package: FxCatalogueLoader.package,
                            fit: BoxFit.contain,
                          ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AppText(
                        label,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 26,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One family's presets, as the pen's plain rows.
class _PresetList extends StatelessWidget {
  const _PresetList({
    required this.family,
    required this.freeSlots,
    required this.onChoose,
  });

  final FxFamily family;
  final int freeSlots;
  final void Function(FxLibraryChoice) onChoose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return ListView.separated(
      itemCount: family.presets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final preset = family.presets[i];
        final needed = fxPresetModules(preset).length;
        // Offered whatever the room, and explained when there is not enough:
        // a rack that half-landed would be a sound nobody chose.
        final fits = needed <= freeSlots;
        return _PresetRow(
          key: Key('fx_preset_${preset.id}'),
          name: preset.name,
          note: fits
              ? null
              : l10n.fxRackTooLong(preset.name, needed, freeSlots),
          onTap: fits ? () => onChoose(FxRackChoice(preset)) : null,
          surface: surface,
        );
      },
    );
  }
}

/// The standalone effects this engine can build.
class _SingleList extends StatelessWidget {
  const _SingleList({required this.onChoose});

  final void Function(FxLibraryChoice) onChoose;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // The built-ins, which is what a standalone effect can be here. The
    // catalogue's own single-effect identities are rack modules, and most of
    // them have no DSP in this build — offering one as a standalone would be
    // offering a pedal that does nothing.
    final types = [
      for (final type in TrackEffectType.values)
        if (type != TrackEffectType.none) type,
    ];
    return ListView.separated(
      itemCount: types.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _PresetRow(
        key: Key('fx_single_${types[i].name}'),
        name: types[i].label,
        onTap: () => onChoose(FxSingleChoice(types[i])),
        surface: surface,
      ),
    );
  }
}

/// One row of the pen's preset list: a name, an optional note, a chevron.
class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.name,
    required this.onTap,
    required this.surface,
    this.note,
    super.key,
  });

  final String name;
  final String? note;
  final VoidCallback? onTap;
  final SurfaceTheme surface;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: note == null ? name : '$name, $note',
    child: Opacity(
      opacity: onTap == null ? surface.disabledOpacity : 1,
      child: Material(
        color: surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: surface.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 96,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          name,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 26,
                            height: 1,
                          ),
                        ),
                        if (note case final note?) ...[
                          const SizedBox(height: 6),
                          AppText(
                            note,
                            style: TextStyle(
                              color: surface.textTertiary,
                              fontSize: 18,
                              height: 1,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 28,
                    color: surface.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
