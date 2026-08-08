import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
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
    required this.onMoved,
    super.key,
  });

  /// The chain being edited.
  final FxScope scope;

  /// Which entry of it.
  final int index;

  /// Called when the entry goes, so the face can stop showing an editor for
  /// something that is no longer in the chain.
  final VoidCallback onClose;

  /// Called with the entry's new slot after a move.
  ///
  /// The editor is opened on an INDEX, so moving the entry without this
  /// leaves the editor on the position — one press would silently swap it
  /// onto a neighbour, and a second press would swap it back.
  final ValueChanged<int> onMoved;

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
    final params = _paramsOf(effect);

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
          if (params.isEmpty)
            Padding(
              key: const Key('signal_fx_no_params'),
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                l10n.fxNoParameters,
                style: TextStyle(
                  color: surface.textMuted,
                  fontSize: 14,
                  height: 1.21,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          for (final (param, spec) in params.indexed) ...[
            if (param > 0) const SizedBox(height: rowGap),
            ConsoleValueBar(
              key: Key('signal_fx_param_$param'),
              label: l10n.effectParamLabel(spec.label).toUpperCase(),
              // Named for the reader, which the display label cannot do —
              // it is an upper-cased fragment with no idea whose it is.
              semanticLabel: l10n.a11yFxParam(
                spec.label,
                fxBlockName(l10n, effect),
              ),
              value: _valueOf(effect, param),
              readout: fxParamReadout(l10n, spec, _valueOf(effect, param)),
              onChanged: (value) => switch (effect) {
                PluginEffect(:final params) => scope.setPluginParam(
                  index,
                  params[param].id,
                  value,
                ),
                BuiltInEffect() => scope.setParam(index, param, value),
              },
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
            onMoved: onMoved,
          ),
        ],
      ),
    );
  }

  /// The parameter descriptors for [effect] — a built-in's own, or the live
  /// list the host enumerated from the loaded plugin.
  static List<TrackEffectParam> _paramsOf(TrackEffect effect) =>
      switch (effect) {
        BuiltInEffect(:final type) => type.params,
        // A plugin's parameters are enumerated metadata rather than a fixed
        // set: it reports them by name, and they arrive with the loaded
        // plugin. Empty means the host has not enumerated any — which the
        // block says out loud rather than drawing a footer with no subject.
        PluginEffect(:final params) => [
          for (final p in params) TrackEffectParam(p.name),
        ],
      };

  static double _valueOf(TrackEffect effect, int param) => switch (effect) {
    BuiltInEffect(:final params) => param < params.length ? params[param] : 0.0,
    PluginEffect(:final params, :final paramValues) =>
      param < params.length ? paramValues[params[param].id] ?? 0.0 : 0.0,
  };
}

/// The block's footer: what this entry does, and where it sits.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.scope,
    required this.index,
    required this.effect,
    required this.onClose,
    required this.onMoved,
  });

  final FxScope scope;
  final int index;
  final TrackEffect effect;
  final VoidCallback onClose;
  final ValueChanged<int> onMoved;

  void _move(int to) {
    scope.moveEffect(index, to);
    // Follow the entry to its new slot, or the editor is left describing
    // whatever moved into the old one.
    onMoved(to);
  }

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
