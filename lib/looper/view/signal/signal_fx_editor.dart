import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/fx_editor/fx_plugin_state.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/signal_browse_plugins.dart';
import 'package:segno/theme/theme.dart';

/// One link of a chain, opened in place: its parameters, and the four things
/// you can do to it.
///
/// **Inside the panel, not beside it.** The editor takes the place of `level`
/// and `in the mix` — you are looking at one effect now, and the questions
/// about the whole chain's loudness belong to the chain. The monitor segment
/// stays, because whether you hear the input at all is still true while you
/// are editing what it sounds like.
///
/// Parameters are [ConsoleValueBar] with no adjustment: the mockups' own
/// measure — 106 label + 14 + 1400 track + 14 + 94 readout — is 1628, which is
/// what that widget already draws.
class SignalFxEditor extends StatelessWidget {
  /// Creates a [SignalFxEditor] for entry [index] of [scope]'s chain.
  const SignalFxEditor({
    required this.scope,
    required this.index,
    required this.onClose,
    super.key,
  });

  /// The chain being edited.
  final FxScope scope;

  /// Which entry of it.
  final int index;

  /// Called when the entry goes, so the face can stop showing an editor for
  /// something that is no longer in the chain.
  final VoidCallback onClose;

  /// Inside padding of the block.
  static const double padding = 18;

  /// Gap between two parameter rows.
  static const double rowGap = 10;

  /// Gap between the last parameter and the footer's divider.
  static const double footerGap = 15;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final chain = scope.effects;
    // The entry can go while its editor is open — another surface removing it,
    // a record-time snapshot rewriting the chain. Nothing to draw beats a
    // block of someone else's parameters.
    if (index < 0 || index >= chain.length) return const SizedBox.shrink();
    final effect = chain[index];
    final rows = _rowsFor(l10n, effect);

    return Container(
      key: const Key('signal_fx_editor'),
      padding: const EdgeInsets.all(padding - 1),
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rows.isEmpty)
            Padding(
              key: const Key('signal_fx_no_params'),
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _emptyReason(l10n, effect),
                      style: TextStyle(
                        color: surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
                  // Only where it can help: a plugin the rig cannot FIND is
                  // what relinking is for. One this stage cannot host is not
                  // missing, and one still being looked for may yet arrive.
                  // Without this the entry can only be removed and added
                  // again, which throws away the state `PluginEffect.state`
                  // exists to keep.
                  if (_canRelink(effect))
                    _Glyph(
                      glyphKey: const Key('signal_fx_relink'),
                      label: l10n.fxRelink,
                      semanticLabel: l10n.signalPluginRelinkTooltip,
                      onTap: () => unawaited(_relink(context)),
                    ),
                ],
              ),
            ),
          for (final (param, row) in rows.indexed) ...[
            if (param > 0) const SizedBox(height: rowGap),
            ConsoleValueBar(
              key: Key('signal_fx_param_$param'),
              label: row.label.toUpperCase(),
              // Named for the reader, which the display label cannot do — it
              // is an upper-cased fragment with no idea whose it is.
              semanticLabel: l10n.a11yFxParam(
                row.label,
                fxBlockName(l10n, effect),
              ),
              value: row.normalized,
              readout: row.readout,
              onChanged: row.onChanged,
            ),
          ],
          if (!scope.chainEnabled) ...[
            const SizedBox(height: rowGap),
            Text(
              key: const Key('signal_fx_chain_off'),
              l10n.fxChainOffHere,
              style: TextStyle(
                color: surface.textMuted,
                fontSize: 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ],
          const SizedBox(height: footerGap),
          _Footer(
            scope: scope,
            index: index,
            effect: effect,
            onClose: onClose,
          ),
        ],
      ),
    );
  }

  /// Whether relinking [effect] is the thing that would help.
  static bool _canRelink(TrackEffect effect) => switch (effect) {
    PluginEffect(:final unavailable, :final unsupported, :final loading) =>
      unavailable && !unsupported && !loading,
    _ => false,
  };

  /// Points the entry at an installed plugin, keeping what it had.
  ///
  /// The entry is named by IDENTITY across the sheet, and re-found after it
  /// closes. A modal sheet is open for as long as someone takes to choose,
  /// and the chain can be rewritten underneath it — a record pass snapshots
  /// the monitor chain onto the lane, another surface removes an entry. The
  /// captured position would then name whatever had slid into it, and the
  /// relink would swap an unrelated plugin's `ref` while replaying the saved
  /// state of the one that is gone into it.
  Future<void> _relink(BuildContext context) async {
    final slot = scope.effects[index].slotId;
    final picked = await showSignalBrowsePlugins(
      context,
      catalog: context.read<LooperRepository>().pluginCatalog,
    );
    if (picked == null) return;
    final at = slot == null
        ? -1
        : scope.effects.indexWhere((effect) => effect.slotId == slot);
    if (at < 0) return;
    scope.relinkPlugin(
      at,
      PluginRef(
        format: picked.format,
        id: picked.id,
        version: picked.version,
      ),
    );
  }

  /// One row per parameter, already in the units each side expects.
  ///
  /// A built-in's parameters are normalized `0..1` end to end, which is what
  /// [ConsoleValueBar] speaks. **A hosted plugin's are not**: it reports and
  /// takes PLAIN values in its own units, with its own `min`/`max`. Feeding
  /// one straight to the bar pins anything above 1 to full, and writing the
  /// bar's fraction straight back sets a 20 kHz filter to 0.06 Hz. Both ends
  /// are converted here, the same way `fx_param_tile.dart` did it.
  List<_ParamRow> _rowsFor(AppLocalizations l10n, TrackEffect effect) =>
      switch (effect) {
        BuiltInEffect(:final type, :final params) => [
          for (final (param, spec) in type.params.indexed)
            _ParamRow(
              label: l10n.effectParamLabel(spec.label),
              normalized: param < params.length ? params[param] : 0,
              readout: fxParamReadout(
                l10n,
                spec,
                param < params.length ? params[param] : 0,
              ),
              onChanged: (value) => scope.setParam(index, param, value),
            ),
        ],
        PluginEffect(:final params, :final paramValues) => [
          // Everything the plugin means a person to see. A plugin's own
          // bypass is not a fader — the footer's pill is THE power control
          // (D-POWER), and a second one beside it is the ambiguity that rule
          // exists to prevent — and a hidden parameter is not a control at
          // all. Everything else is drawn, and what cannot be WRITTEN is
          // drawn as a meter rather than dropped: `isAutomatable` is optional
          // per parameter, so a plugin that marks its mode selector
          // non-automatable rendered nothing at all and was told it exposes
          // no controls, which was untrue of it.
          for (final info in params)
            if (!info.isHidden && !info.isBypass)
              _pluginRow(info, paramValues[info.id] ?? info.def),
        ],
      };

  _ParamRow _pluginRow(PluginParamInfo info, double plain) {
    final span = info.max - info.min;
    // A meter: the plugin either will not be automated on this parameter or
    // reports it read-only. The bar reads and does not write.
    final live = info.isAutomatable && !info.isReadOnly;
    // A degenerate range would divide by zero; the bar then reads empty and
    // the write clamps to the single value the plugin accepts.
    final normalized = span == 0
        ? 0.0
        : ((plain - info.min) / span).clamp(0.0, 1.0);
    return _ParamRow(
      label: info.name,
      normalized: normalized,
      // The live instance's own string first — it is the only thing that
      // knows what its numbers MEAN. A percentage of a plain value would be
      // meaningless even after the conversion above.
      readout:
          scope.formatPluginValue(index, info.id, plain) ??
          _plainReadout(info, plain),
      onChanged: !live
          ? null
          : (value) => scope.setPluginParam(
              index,
              info.id,
              // A stepped parameter has to LAND on a step: the readout
              // names one, and a value parked between two would leave the
              // plugin holding something the label says it is not.
              info.min +
                  (info.stepCount > 0
                          ? (value * info.stepCount).round() / info.stepCount
                          : value) *
                      span,
            ),
    );
  }

  /// What a plugin parameter reads as when the host cannot say — the two bus
  /// stages never can, since they hold no live instance to ask.
  static String _plainReadout(PluginParamInfo info, double plain) {
    final text = info.valueTexts.isNotEmpty && info.stepCount > 0
        ? _stepText(info, plain)
        : null;
    if (text != null) return text;
    final rounded = plain.abs() >= 100
        ? plain.round().toString()
        : plain.toStringAsFixed(2);
    return info.unit.isEmpty ? rounded : '$rounded ${info.unit}';
  }

  static String? _stepText(PluginParamInfo info, double plain) {
    final span = info.max - info.min;
    if (span == 0) return info.valueTexts.first;
    final step = ((plain - info.min) / span * info.stepCount).round();
    return step >= 0 && step < info.valueTexts.length
        ? info.valueTexts[step]
        : null;
  }

  /// Why a chain entry is showing no controls — which is several different
  /// facts, and only one of them is "it has none".
  ///
  /// Delegates to [fxPluginPlaceholderReason], which the placeholder card and
  /// the summary chip already share, so the three cannot disagree.
  ///
  /// The guard admits two different postures. `unsupported` is set
  /// **alongside** `unavailable` — so testing `unavailable` first would tell a
  /// bus-stage plugin it failed to load rather than that the stage cannot host
  /// it. `loading` is the opposite: the repository sets it with `unavailable`
  /// FALSE while a scan is in flight, so it needs its own way in or a plugin
  /// still being looked for reads as one that was not found.
  static String _emptyReason(AppLocalizations l10n, TrackEffect effect) =>
      switch (effect) {
        PluginEffect(:final unavailable, :final unsupported, :final loading)
            when unavailable || loading =>
          fxPluginPlaceholderReason(
            l10n,
            loading: loading,
            unsupported: unsupported,
          ),
        _ => l10n.fxNoParameters,
      };
}

/// The block's footer: what this entry does, and where it sits.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.scope,
    required this.index,
    required this.effect,
    required this.onClose,
  });

  final FxScope scope;
  final int index;
  final TrackEffect effect;
  final VoidCallback onClose;

  // The editor follows its entry by IDENTITY now, so a move needs no
  // follow-up: the selection names the entry, not the slot it was in.
  void _move(int to) => scope.moveEffect(index, to);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final last = scope.effects.length - 1;

    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Row(
        children: [
          _Pill(
            pillKey: const Key('signal_fx_bypass'),
            label: l10n.fxBypass,
            // The chain's per-slot power (D-POWER), which is what `bypass`
            // means here: the entry stays in the chain and stops sounding.
            active: !effect.enabled,
            onTap: () =>
                scope.setEffectEnabled(index, enabled: !effect.enabled),
          ),
          const SizedBox(width: 10),
          _Glyph(
            glyphKey: const Key('signal_fx_move_up'),
            glyph: '◀',
            semanticLabel: l10n.fxMoveEarlier,
            // Processing order IS signal order, so earlier means earlier in
            // the sound. Nothing to do at the head of the chain.
            onTap: index <= 0 ? null : () => _move(index - 1),
          ),
          const SizedBox(width: 10),
          _Glyph(
            glyphKey: const Key('signal_fx_move_down'),
            glyph: '▶',
            semanticLabel: l10n.fxMoveLater,
            onTap: index >= last ? null : () => _move(index + 1),
          ),
          // Only for a plugin that is actually LOADED: there is no window to
          // open for a built-in, and none for one that failed to resolve.
          // The console edits parameters generically, but a plugin's own UI
          // is the only place some of them exist at all.
          if (effect case PluginEffect(
            :final unavailable,
            :final loading,
          ) when !unavailable && !loading) ...[
            const SizedBox(width: 10),
            _Glyph(
              glyphKey: const Key('signal_fx_open_window'),
              label: l10n.fxOpenWindow,
              semanticLabel: l10n.signalPluginOpenEditorTooltip,
              onTap: () => scope.openPluginEditor(index),
            ),
          ],
          const Spacer(),
          _Glyph(
            glyphKey: const Key('signal_fx_remove'),
            label: l10n.fxRemove,
            semanticLabel: l10n.fxRemove,
            onTap: () {
              scope.removeEffect(index);
              // The editor cannot outlive what it edits.
              onClose();
            },
          ),
        ],
      ),
    );
  }
}

/// The `bypass` pill — outlined, and tinted while the entry is bypassed.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.pillKey,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final Key pillKey;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: InkWell(
        key: pillKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(119),
        child: ExcludeSemantics(
          child: Container(
            height: 33,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? surface.accentSurface : null,
              borderRadius: BorderRadius.circular(119),
              border: Border.all(
                color: active ? surface.accent : surface.line,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: active ? surface.accent : surface.textSecondary,
                fontSize: 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A footer button: a glyph, or a word where a glyph would be a guess.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.glyphKey,
    required this.semanticLabel,
    required this.onTap,
    this.glyph,
    this.label,
  });

  final Key glyphKey;
  final String? glyph;
  final String? label;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: InkWell(
        key: glyphKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ExcludeSemantics(
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: surface.borderStrong),
            ),
            child: Text(
              glyph ?? label!,
              style: TextStyle(
                // A disabled end of the chain recedes rather than disappears:
                // the button is still where it was a moment ago.
                color: enabled ? surface.textPrimary : surface.textMuted,
                fontSize: glyph != null ? 15 : 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A parameter's value in its own units.
///
/// Lifted out of `signal_fx_rack.dart` (which #533's demolition deletes) so
/// the one mapping from a normalized `0..1` to a human number outlives the
/// surface it was written for.
String fxParamReadout(
  AppLocalizations l10n,
  TrackEffectParam spec,
  double value,
) {
  final v = value.clamp(0.0, 1.0);
  return switch (spec.readout) {
    ParamReadout.none => '${(v * 100).round()}%',
    ParamReadout.pitchShift => l10n.formatLocalizedPitchShift(v),
    ParamReadout.octaverMode => l10n.octaverModeLabel(v),
  };
}

/// One parameter of one chain entry, in the units the bar speaks.
class _ParamRow {
  const _ParamRow({
    required this.label,
    required this.normalized,
    required this.readout,
    required this.onChanged,
  });

  final String label;
  final double normalized;
  final String readout;

  /// Null when the parameter only reads — see [ConsoleValueBar.onChanged].
  final ValueChanged<double>? onChanged;
}
