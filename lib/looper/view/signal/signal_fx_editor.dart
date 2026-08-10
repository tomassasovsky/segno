import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/fx_editor/fx_plugin_state.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/fx_param_edit_sheet.dart';
import 'package:segno/looper/view/signal/fx_param_tile.dart';
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
/// Parameters are the grid `DS / 06` resolves: one 78px tile per parameter,
/// wrapping, with the kind of parameter choosing the cell. A tile opens the
/// editor sheet and writes nothing itself.
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
    final rows = _cellsFor(l10n, effect);

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
                      onTap: () => unawaited(_relink(context, effect.slotId)),
                    ),
                ],
              ),
            ),
          if (rows.isNotEmpty)
            // The grid, not a column of faders: every parameter kind wears the
            // same 78px skeleton, so a two-knob built-in and a 24-parameter
            // compressor read as the same surface. It wraps and never scrolls
            // sideways, so no parameter hides off the edge.
            Wrap(
              key: const Key('signal_fx_param_grid'),
              spacing: FxParamTileMetrics.gutter,
              runSpacing: FxParamTileMetrics.gutter,
              children: [
                for (final (param, row) in rows.indexed)
                  KeyedSubtree(
                    key: Key('signal_fx_param_$param'),
                    child: row.build(context, this),
                  ),
              ],
            ),
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
          _Footer(scope: scope, index: index, effect: effect, onClose: onClose),
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
  /// [slot] is the identity of the entry this placeholder was DRAWN for, and
  /// the entry is re-found by it after the sheet closes. A modal sheet is
  /// open for as long as someone takes to choose, and the chain can be
  /// rewritten underneath it — a record pass snapshots the monitor chain onto
  /// the lane, another surface removes an entry. A position would then name
  /// whatever had slid into it, and the relink would swap an unrelated
  /// plugin's `ref` while replaying the saved state of the one that is gone
  /// into it. Read at BUILD time rather than on the tap for the same reason:
  /// a tap dispatched in the frame the chain changed reads the new chain.
  Future<void> _relink(BuildContext context, String? slot) async {
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

  /// One cell per parameter, each already in the units its own side speaks.
  ///
  /// A built-in's parameters are normalized `0..1` end to end; a hosted
  /// plugin's are PLAIN values in its own units with its own `min`/`max`.
  /// Nothing converts between them, because nothing has to: the cells and the
  /// sheet work in the parameter's own range, which `_builtInSpec` states for
  /// a built-in as the `0..1` it actually is. The fader this replaced spoke
  /// only `0..1` and had to convert both ends.
  List<_ParamCell> _cellsFor(AppLocalizations l10n, TrackEffect effect) =>
      switch (effect) {
        BuiltInEffect(:final type, :final params) => [
          for (final (param, spec) in type.params.indexed)
            _ParamCell(
              spec: _builtInSpec(l10n, type, param, spec),
              plain: param < params.length ? params[param] : 0,
              slot: effect.slotId,
              semanticLabel: l10n.a11yFxParam(
                l10n.effectParamLabel(spec.label),
                fxBlockName(l10n, effect),
              ),
              readout: fxParamReadout(
                l10n,
                spec,
                param < params.length ? params[param] : 0,
              ),
              formatValue: (value) => fxParamReadout(l10n, spec, value),
              onChanged: _bySlot(
                effect.slotId,
                (at) => (value) {
                  scope.setParam(at, param, value);
                },
              ),
            ),
        ],
        PluginEffect(:final params, :final paramValues) => [
          // Everything the plugin means a person to SETTLE. A plugin's own
          // bypass is not a fader — the footer's pill is THE power control
          // (D-POWER), and a second one beside it is the ambiguity that rule
          // exists to prevent — and a hidden parameter is not a control at
          // all.
          //
          // A non-automatable one IS drawn, read-only: `isAutomatable` is
          // optional per parameter, so a plugin that marks its mode selector
          // non-automatable rendered nothing at all and was told it exposes
          // no controls, which was untrue of it.
          //
          // So is a READ-ONLY one, and `DS / 06` says where it lands: a
          // borderless, untappable tile, muted, with the accent off its
          // indicator. A gain-reduction meter is only true for the instant it
          // was read — which is the argument for drawing it as something that
          // is plainly not a control, not for hiding a value the plugin
          // publishes about itself.
          for (final info in params)
            if (!info.isHidden && !info.isBypass)
              _pluginCell(l10n, effect, info, paramValues[info.id] ?? info.def),
        ],
      };

  _ParamCell _pluginCell(
    AppLocalizations l10n,
    TrackEffect effect,
    PluginParamInfo info,
    double plain,
  ) {
    // A meter: the plugin either will not be automated on this parameter or
    // reports it read-only. It draws, borderless and untappable, rather than
    // being dropped — a value the plugin publishes is part of what the plugin
    // IS, and a strip missing its gain-reduction readout is a strip that
    // silently disagrees with the plugin's own window.
    final live = info.isAutomatable && !info.isReadOnly;
    return _ParamCell(
      spec: info,
      plain: plain,
      slot: effect.slotId,
      semanticLabel: l10n.a11yFxParam(info.name, fxBlockName(l10n, effect)),
      // The live instance's own string first — it is the only thing that
      // knows what its numbers MEAN.
      readout:
          scope.formatPluginValue(index, info.id, plain) ??
          _plainReadout(info, plain),
      // Through the SAME entry the writes go to, and with the same fallback
      // the tile uses. Asking by position would format the value through a
      // different plugin the moment the chain moved under the open sheet, and
      // no fallback at all left a bus stage — which never has a live instance
      // to ask — showing `2` in the sheet under a tile reading `Highpass`.
      formatValue: (value) =>
          _atSlot(effect.slotId, (at) {
            return scope.formatPluginValue(at, info.id, value);
          }) ??
          _plainReadout(info, value),
      // Plain values, both ways: the sheet and the cells speak the
      // parameter's own units, so nothing here converts. The old fader spoke
      // `0..1` and had to.
      onChanged: !live
          ? null
          : _bySlot(
              scope.effects[index].slotId,
              (at) => (value) {
                scope.setPluginParam(at, info.id, value);
              },
            ),
    );
  }

  /// A write aimed at the entry identified by [slot], wherever it has moved
  /// to by the time it lands.
  ///
  /// The sheet is modal and stays open for as long as someone takes to settle
  /// a value, and the chain can be rewritten underneath it — a record pass
  /// snapshots the monitor chain onto the lane, another surface removes an
  /// entry. A captured POSITION would then name whatever slid into it, and
  /// the drag would move a parameter of an unrelated effect. The same
  /// argument [_relink] already makes, for the same reason.
  ///
  /// A slot that is GONE takes no writes at all: an edit with nothing to edit
  /// is not an edit to apply somewhere else. [_relink] refuses the same way,
  /// though it parts company on the no-id case — see [_slotIndex].
  ValueChanged<double> _bySlot(
    String? slot,
    ValueChanged<double> Function(int at) write,
  ) => (value) {
    final at = _slotIndex(slot);
    if (at < 0) return;
    write(at)(value);
  };

  /// Where the entry identified by [slot] is NOW, or -1 when it is gone.
  ///
  /// An entry with no slot id keeps the position it was drawn at: there is
  /// nothing to re-find it by, which is what the whole surface did before
  /// this. The repository mints ids at its write boundary, so a live chain has
  /// them and that path does not happen.
  int _slotIndex(String? slot) {
    final chain = scope.effects;
    final at = slot == null
        ? index
        : chain.indexWhere((effect) => effect.slotId == slot);
    return at >= 0 && at < chain.length ? at : -1;
  }

  /// Reads something about the entry identified by [slot], or null when it is
  /// gone — the read half of [_bySlot], so what the sheet SHOWS and what it
  /// writes cannot end up describing two different effects.
  T? _atSlot<T>(String? slot, T? Function(int at) read) {
    final at = _slotIndex(slot);
    return at < 0 ? null : read(at);
  }

  /// The breadcrumb under the parameter's name in the sheet — which effect,
  /// on which chain.
  ///
  /// The sheet is raised over a dimmed console, so the one thing it cannot
  /// rely on is the surface behind it still answering "what am I editing".
  String _sourceLine(BuildContext context, String? slot) {
    final l10n = context.l10n;
    final name =
        _atSlot(slot, (at) => fxBlockName(l10n, scope.effects[at])) ?? '';
    return '$name · ${scope.label(l10n)}';
  }

  /// A built-in parameter's range, in the type the sheet and the taxonomy
  /// speak.
  ///
  /// Not a pretend plugin: [PluginParamInfo] describes a parameter's RANGE,
  /// and a built-in's range is continuous over `0..1` with a name, a default
  /// and — where it has steps — a name for each of them, all of which the
  /// effect already declares. Writing that down is what lets one grid draw
  /// both kinds; the alternative is a second taxonomy that decides the same
  /// things again for built-ins.
  PluginParamInfo _builtInSpec(
    AppLocalizations l10n,
    TrackEffectType type,
    int param,
    TrackEffectParam spec,
  ) {
    // A built-in's divisions are its steps, and a continuous one has none.
    final steps = spec.divisions ?? 0;
    final defaults = type.defaultParams;
    return PluginParamInfo(
      id: param,
      name: l10n.effectParamLabel(spec.label),
      unit: '',
      min: 0,
      max: 1,
      // The effect's OWN default, not zero. The sheet's Reset writes this,
      // and zero is silence for most of them — a reset that switches the
      // effect off is not a reset.
      def: param < defaults.length ? defaults[param] : 0,
      stepCount: steps,
      flags: 0x01,
      // What each step is CALLED, in the effect's own words — the octaver's
      // mode is the built-in that has names, and without these it reads as a
      // bare index or as nothing at all.
      //
      // Only where they are NAMES, and only where a menu could show them.
      //
      // A percentage is not a step name: a future built-in with four plain
      // divisions must not become a dropdown of `0% 25% 50% 75% 100%`. That
      // half is protection — no built-in is shaped that way today, so no test
      // can reach it, and the first one added would find the trap sprung.
      //
      // The step ceiling changes nothing observable, since the routing gate
      // already excludes anything past 24. It stops the octaver's 48-step
      // Shift building a 49-element list through the localiser on every
      // rebuild of a panel that never reads it.
      valueTexts: steps == 0 || steps > 24 || spec.readout == ParamReadout.none
          ? const []
          : [
              for (var step = 0; step <= steps; step++)
                fxParamReadout(l10n, spec, step / steps),
            ],
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
            glyph: _Glyph.earlier,
            semanticLabel: l10n.fxMoveEarlier,
            // Processing order IS signal order, so earlier means earlier in
            // the sound. Nothing to do at the head of the chain.
            onTap: index <= 0 ? null : () => _move(index - 1),
          ),
          const SizedBox(width: 10),
          _Glyph(
            glyphKey: const Key('signal_fx_move_down'),
            glyph: _Glyph.later,
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
              border: Border.all(color: active ? surface.accent : surface.line),
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

  /// Which way the triangle points, or null for a text button.
  ///
  /// PAINTED, not typed. `◀` and `▶` are emoji-presentation by default, so
  /// macOS renders them out of Apple Color Emoji — a fat coloured lozenge
  /// sitting off the text baseline, next to a `Remove` in Inter. A path is
  /// the same shape on every platform the console runs on.
  final String? glyph;

  /// The two directions [glyph] can name.
  static const String earlier = 'earlier';
  static const String later = 'later';
  final String? label;
  final String semanticLabel;
  final VoidCallback? onTap;

  /// The triangle, keyed by the way it points.
  ///
  /// One value drives both the key and the path, so a direction that gets
  /// flipped is a direction a test can see — nothing about a painted
  /// triangle reaches the widget tree otherwise.
  static Widget _triangle({required bool pointsLeft, required Color color}) =>
      CustomPaint(
        key: Key(
          pointsLeft ? 'signal_fx_points_left' : 'signal_fx_points_right',
        ),
        size: const Size(11, 13),
        painter: _TrianglePainter(pointsLeft: pointsLeft, color: color),
      );
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
            // A disabled end of the chain recedes rather than disappears: the
            // button is still where it was a moment ago.
            child: glyph == null
                ? Text(
                    label!,
                    style: TextStyle(
                      color: enabled ? surface.textPrimary : surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  )
                : _triangle(
                    pointsLeft: glyph == _Glyph.earlier,
                    color: enabled ? surface.textPrimary : surface.textMuted,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The solid triangle the move buttons carry.
class _TrianglePainter extends CustomPainter {
  const _TrianglePainter({required this.pointsLeft, required this.color});

  final bool pointsLeft;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointsLeft) {
      path
        ..moveTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height / 2);
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(0, size.height)
        ..lineTo(size.width, size.height / 2);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      old.pointsLeft != pointsLeft || old.color != color;
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

/// One parameter's place in the grid: what the tile reads, and what the sheet
/// edits when it is tapped.
///
/// A single type for both kinds. A built-in's parameters are a fixed list of
/// normalized knobs and a plugin's are a described range, but the design puts
/// them in one grid, so what differs is confined to how a cell is BUILT.
class _ParamCell {
  const _ParamCell({
    required this.spec,
    required this.plain,
    required this.slot,
    required this.readout,
    required this.semanticLabel,
    required this.onChanged,
    this.formatValue,
  });

  /// The parameter's range, as the sheet needs it. For a built-in this is
  /// written here rather than reported by a plugin — a built-in parameter IS
  /// continuous over `0..1`, and saying so in the type the sheet already
  /// speaks beats a second sheet that says the same thing differently.
  final PluginParamInfo spec;

  /// The current value in [spec]'s own units.
  final double plain;

  /// The identity of the chain entry this parameter belongs to. Everything
  /// the sheet reads and everything it writes goes through it, so a chain
  /// rewritten under an open sheet cannot leave the two describing different
  /// effects.
  final String? slot;

  /// The value as it should read, unit included.
  final String readout;

  /// Null when the parameter only reports — a meter, or a plugin that says the
  /// value is read-only.
  final ValueChanged<double>? onChanged;

  /// The plugin's own rendering of an arbitrary value, for the sheet's live
  /// readout. Null for a built-in, which formats through its own spec.
  final String? Function(double value)? formatValue;

  /// What the tile says out loud: the parameter AND the effect it belongs to.
  final String semanticLabel;

  /// The cell the taxonomy calls for. First match wins, so a read-only
  /// parameter never reaches the step-count branches.
  Widget build(BuildContext context, SignalFxEditor editor) {
    final set = onChanged;
    // Read-only first, then the step count: a meter reports a value it will
    // not take, so it is never a switch and never a menu however many steps
    // it claims.
    if (set == null) {
      return FxParamTile(
        spec: spec,
        value: plain,
        valueText: readout,
        semanticLabel: semanticLabel,
        onTap: null,
      );
    }
    // Named steps go to the menu, whatever their count — including two of
    // them. A switch has no room for a caption (36px, by the DS), so a
    // two-state parameter whose states have names would show neither.
    final named =
        spec.valueTexts.length == spec.stepCount + 1 && spec.stepCount >= 1;
    if (spec.stepCount == 1 && !named) {
      return FxParamSwitchCell(
        spec: spec,
        value: plain,
        semanticLabel: semanticLabel,
        onChanged: set,
      );
    }
    // Labelled, not merely small: steps AND a name for each one. A three-step
    // parameter with no names would draw a menu of `0 1 2 3`, which says less
    // than the value it replaced.
    if (named && spec.stepCount <= 24) {
      return FxParamEnumCell(
        spec: spec,
        value: plain,
        semanticLabel: semanticLabel,
        onChanged: set,
      );
    }
    return FxParamTile(
      spec: spec,
      value: plain,
      valueText: readout,
      semanticLabel: semanticLabel,
      onTap: () => unawaited(
        FxParamEditSheet.show(
          context,
          spec: spec,
          value: plain,
          source: editor._sourceLine(context, slot),
          onChanged: set,
          formatValue: formatValue,
          // The entry can go while its sheet is open. Every write would then
          // land nowhere and every drag would move a value that no longer
          // exists, under a panel that has already collapsed behind the
          // scrim. Closing says so; swallowing the drags does not.
          isGone: () => editor._slotIndex(slot) < 0,
        ),
      ),
    );
  }
}
