import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/theme/theme.dart';

/// Which FX-overlay treatment is drawn over the stage.
///
/// FX mode is an OVERLAY, not the in-place tile transform #867 shipped (owner
/// pivot 2026-08-27): the four track columns render EXACTLY as normal under a
/// dim scrim, and per-pedal ON/OFF controls float above them. These four
/// candidates are being compared before one is chosen — the pen frames
/// `fx-opt-A`…`fx-opt-D` (#692):
///
/// - [a] a big power glyph centered in each column;
/// - [b] a single dock bar along the bottom, one cell per column;
/// - [c] a slim footer strip at the foot of each column;
/// - [d] a ribbon across the top of each column.
enum FxOverlayStyle {
  /// `fx-opt-A`: a big power glyph per column.
  a,

  /// `fx-opt-B`: a bottom dock bar.
  b,

  /// `fx-opt-C`: a slim per-column footer strip (the default candidate).
  c,

  /// `fx-opt-D`: a top FX ribbon.
  d;

  /// The next style in the a→b→c→d→a cycle (the comparison cycler).
  FxOverlayStyle get next =>
      FxOverlayStyle.values[(index + 1) % FxOverlayStyle.values.length];

  /// The short caption the cycler chip shows (`STYLE C`).
  String get caption => 'STYLE ${name.toUpperCase()}';
}

/// The FX-mode overlay: a dim scrim over the (unmodified) track run, plus the
/// per-pedal ON/OFF controls for the chosen [style] (#692, owner pivot).
///
/// It is mounted only in [InteractionMode.fx] and painted ABOVE the track
/// content, so the columns beneath read exactly as they do in every other mode.
/// Each control resolves the FX binding on its footswitch — the chain a stomp
/// on that pedal would flip — from [ControlCubit], names it CHAIN-FIRST
/// (`TARGET · CHAIN`), and reflects/toggles that chain's `enabled` state. This
/// is also the fix for #884: the bound chain is now visible on the stage.
///
/// [channels] is the ordered list of the active bank's present track channels
/// — the SAME list the track run lays out — so the overlay's four cells align
/// with the four columns (one [Expanded] each, at the run's own [spacing]).
class FxOverlay extends StatelessWidget {
  /// Creates an [FxOverlay].
  const FxOverlay({
    required this.style,
    required this.channels,
    required this.spacing,
    super.key,
  });

  /// The treatment to draw (one of the four #692 candidates).
  final FxOverlayStyle style;

  /// The active bank's present track channels, in column order.
  final List<int> channels;

  /// The horizontal gap the track run uses between columns (kept in step so the
  /// overlay cells sit over the columns).
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    // Bindings + the visible bank come from ControlCubit; watched, since a
    // remap (or a bank change) must reach every cell.
    final control = context.watch<ControlCubit>().state;
    // Input names are only consulted for a named-input identity; read, not
    // watched — a rename is not worth rebuilding the overlay live.
    final inputNames = context.read<InputsCubit>().state.names;
    final looper = context.read<LooperRepository>();

    // The reactive chain slice: recomputed only when the engine state actually
    // changes a drawn FX fact, never on a meter tick (#646). Each cell is an
    // Equatable value, so a poll that moves only a level rebuilds nothing here.
    final cells = context.select<LooperBloc, List<_FxCellData>>(
      (_) => [
        for (final channel in channels)
          _resolveCell(
            l10n: l10n,
            control: control,
            looper: looper,
            inputNames: inputNames,
            channel: channel,
          ),
      ],
    );

    // The scrim is the DS overlay scrim (the pen's ~55% black over the run) —
    // it dims the columns and, with an opaque no-op tap, swallows every gesture
    // meant for the tiles beneath: FX controls are ON/OFF only, so the tiles
    // take no selection or transport tap while the overlay is up.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('fx_overlay_scrim'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: ColoredBox(color: surface.scrim),
          ),
        ),
        Positioned.fill(
          child: _FxControlsLayer(style: style, cells: cells, spacing: spacing),
        ),
      ],
    );
  }
}

/// The per-pedal control layer — one cell per column, laid out per [style].
class _FxControlsLayer extends StatelessWidget {
  const _FxControlsLayer({
    required this.style,
    required this.cells,
    required this.spacing,
  });

  final FxOverlayStyle style;
  final List<_FxCellData> cells;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    // Bottom dock (B) is the one style whose control is NOT inside the column
    // band: the cells ride a bar pinned to the run's bottom edge.
    if (style == FxOverlayStyle.b) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: kConsoleMode ? 12 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: spacing,
            children: [
              for (final cell in cells)
                Expanded(
                  child: _FxCell(style: style, data: cell),
                ),
            ],
          ),
        ),
      );
    }
    // A / C / D place their control inside each column's own band.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: spacing,
      children: [
        for (final cell in cells)
          Expanded(
            child: _FxCell(style: style, data: cell),
          ),
      ],
    );
  }
}

/// One pedal's control, drawn in the [style]'s idiom.
class _FxCell extends StatelessWidget {
  const _FxCell({required this.style, required this.data});

  final FxOverlayStyle style;
  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case FxOverlayStyle.a:
        return _FxGlyphCell(data: data);
      case FxOverlayStyle.b:
        return _FxDockCell(data: data);
      case FxOverlayStyle.c:
        return _FxFooterCell(data: data);
      case FxOverlayStyle.d:
        return _FxRibbonCell(data: data);
    }
  }
}

// ---------------------------------------------------------------------------
// Style A — a big power glyph centered in each column.
// ---------------------------------------------------------------------------

class _FxGlyphCell extends StatelessWidget {
  const _FxGlyphCell({required this.data});

  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    // Centred at ~40% of the card height, matching the pen frame.
    return Align(
      alignment: const Alignment(0, -0.2),
      child: _FxTapTarget(
        data: data,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FxPowerGlyph(data: data),
            const SizedBox(height: kConsoleMode ? 14 : 9),
            _FxIdentity(data: data, align: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// The big power ring — purple + power icon when engaged, a muted ghost when
/// off, and a `+` invitation when the pedal is unbound.
class _FxPowerGlyph extends StatelessWidget {
  const _FxPowerGlyph({required this.data});

  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    const size = kConsoleMode ? 92.0 : 60.0;
    final unbound = !data.bound || !data.hasChain;
    final on = data.enabled ?? false;
    final ring = unbound
        ? surface.borderStrong
        : (on ? surface.fx : surface.textMuted);
    final glyph = unbound ? Icons.add : Icons.power_settings_new;
    return Container(
      key: Key('fx_overlay_power_${data.channel}'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? surface.fxSurface : Colors.transparent,
        border: Border.all(color: ring, width: on ? 3 : 2),
      ),
      child: Icon(
        glyph,
        size: kConsoleMode ? 44 : 28,
        color: unbound ? surface.textMuted : ring,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Style B — a bottom dock bar, one cell per column.
// ---------------------------------------------------------------------------

class _FxDockCell extends StatelessWidget {
  const _FxDockCell({required this.data});

  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return _FxTapTarget(
      data: data,
      borderRadius: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kConsoleMode ? 16 : 10,
          vertical: kConsoleMode ? 12 : 8,
        ),
        decoration: BoxDecoration(
          color: surface.cardHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: surface.line),
        ),
        child: Row(
          children: [
            Expanded(child: _FxIdentity(data: data)),
            const SizedBox(width: 10),
            _FxToggleVisual(data: data),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Style C — a slim footer strip at the foot of each column (default).
// ---------------------------------------------------------------------------

class _FxFooterCell extends StatelessWidget {
  const _FxFooterCell({required this.data});

  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: kConsoleMode ? 16 : 10),
        child: _FxTapTarget(
          data: data,
          borderRadius: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: kConsoleMode ? 12 : 8,
              vertical: kConsoleMode ? 8 : 6,
            ),
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: surface.borderSubtle),
            ),
            child: Row(
              children: [
                Expanded(child: _FxIdentity(data: data, dense: true)),
                const SizedBox(width: 8),
                _FxToggleVisual(data: data, small: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Style D — a ribbon across the top of each column.
// ---------------------------------------------------------------------------

class _FxRibbonCell extends StatelessWidget {
  const _FxRibbonCell({required this.data});

  final _FxCellData data;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: kConsoleMode ? 6 : 4),
        child: _FxTapTarget(
          data: data,
          borderRadius: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: kConsoleMode ? 12 : 8,
              vertical: kConsoleMode ? 8 : 6,
            ),
            decoration: BoxDecoration(
              // A hair of fx wash so the ribbon reads as the mode's own band,
              // over the flat FX surface the mode already carries.
              color: data.enabled ?? false
                  ? surface.fxSurface
                  : surface.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: data.enabled ?? false
                    ? surface.fx
                    : surface.borderSubtle,
              ),
            ),
            child: Row(
              children: [
                Expanded(child: _FxIdentity(data: data, dense: true)),
                const SizedBox(width: 8),
                _FxToggleVisual(data: data, small: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared leaves.
// ---------------------------------------------------------------------------

/// The cell's tap surface + accessible name. Tapping toggles the bound chain;
/// an unbound or unresolved pedal is inert. The composed semantic names the
/// chain-first identity and its on/off, so the announcement matches the pen's
/// visible control (and pins #884: the bound chain is what the stage states).
class _FxTapTarget extends StatelessWidget {
  const _FxTapTarget({
    required this.data,
    required this.child,
    this.borderRadius = 8,
  });

  final _FxCellData data;
  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final enabled = data.enabled;
    final canToggle = data.bound && data.hasChain && enabled != null;
    final identity = data.identitySub == null
        ? data.identityPrimary
        : '${data.identityPrimary} ${data.identitySub}';
    final onOff = (enabled ?? false)
        ? l10n.a11yTrackFxChainOn
        : l10n.a11yTrackFxChainOff;
    final semantic = !data.bound
        ? l10n.controlUnassigned
        : !data.hasChain
        ? '$identity, ${l10n.stageFxNoChain}'
        : '$identity, $onOff';
    return FocusableTapTarget(
      key: Key('fx_overlay_cell_${data.channel}'),
      selected: enabled,
      borderRadius: borderRadius,
      semanticLabel: semantic,
      onTap: canToggle
          ? () {
              // The chain-level flip the pen's control performs — even a
              // per-slot binding toggles its whole chain here (the stage
              // control is the chain's power). #884: the on/off lands on the
              // BOUND chain, whatever stage it sits on.
              final address = data.address!;
              final currentlyOn = data.enabled ?? false;
              looper.setBindingEnabled(
                FxChainTarget(address),
                enabled: !currentlyOn,
              );
            }
          : null,
      child: child,
    );
  }
}

/// The chain-first identity — `TARGET · CHAIN`, a bare stage, a named input's
/// two-tier name, or a quiet `unbound` when the pedal carries no binding.
class _FxIdentity extends StatelessWidget {
  const _FxIdentity({
    required this.data,
    this.align = TextAlign.start,
    this.dense = false,
  });

  final _FxCellData data;
  final TextAlign align;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final on = data.enabled ?? false;
    final crossAxis = align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    if (!data.bound) {
      // The quiet unbound state (the pen's dim `unbound`): nothing bound to
      // this pedal, so there is no chain to name or power.
      return AppText(
        l10n.controlUnassigned.toUpperCase(),
        key: Key('fx_overlay_unbound_${data.channel}'),
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: SurfaceTheme.displayFont,
          color: surface.textMuted,
          fontSize: dense ? (kConsoleMode ? 18 : 12) : (kConsoleMode ? 24 : 15),
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
          height: 1,
        ),
      );
    }

    final primarySize = dense
        ? (kConsoleMode ? 20.0 : 13.0)
        : (kConsoleMode ? 28.0 : 18.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxis,
      children: [
        AppText(
          data.hasChain ? data.identityPrimary : l10n.stageFxNoChain,
          key: Key('fx_overlay_label_${data.channel}'),
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: !data.hasChain
                ? surface.textMuted
                : (on ? surface.textPrimary : surface.textSecondary),
            fontSize: primarySize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            height: 1,
          ),
        ),
        if (data.identitySub != null) ...[
          const SizedBox(height: kConsoleMode ? 4 : 3),
          AppText(
            data.identitySub!,
            key: Key('fx_overlay_sub_${data.channel}'),
            textAlign: align,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textMuted,
              fontSize: dense
                  ? (kConsoleMode ? 14 : 10)
                  : (kConsoleMode ? 16 : 11),
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              height: 1,
            ),
          ),
        ],
      ],
    );
  }
}

/// A non-interactive toggle in the pen's `Toggle` idiom — fx-purple track with
/// the knob to the right when engaged, a muted ghost with the knob left when
/// off. The tap is owned by the enclosing [_FxTapTarget], so this draws state
/// only (no nested gesture that could double-fire).
class _FxToggleVisual extends StatelessWidget {
  const _FxToggleVisual({required this.data, this.small = false});

  final _FxCellData data;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // An empty / unresolved chain has nothing to power: no toggle is drawn.
    if (!data.bound || !data.hasChain || data.enabled == null) {
      return const SizedBox.shrink();
    }
    final on = data.enabled!;
    final scale = small ? 0.72 : (kConsoleMode ? 1.15 : 1.0);
    final width = 52.0 * scale;
    final height = 30.0 * scale;
    final knob = height - 8;
    return Container(
      key: Key('fx_overlay_power_${data.channel}'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: on ? surface.fx : surface.control,
        borderRadius: BorderRadius.circular(height),
        border: Border.all(color: on ? surface.fx : surface.line),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox.square(
            dimension: knob,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: on ? surface.onAccent : surface.textSecondary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The style cycler — a TEMPORARY comparison affordance.
// ---------------------------------------------------------------------------

/// A small chip, visible only in FX mode, that advances the overlay style
/// a→b→c→d→a on tap.
///
/// TEMPORARY: this exists only to compare the four #692 candidates on the real
/// stage. Once the owner picks a style, delete this widget, the
/// [FxOverlayStyle] cycling, and the ephemeral style state in
/// `tracks_view.dart` — the overlay keeps only the chosen treatment.
class FxStyleCycler extends StatelessWidget {
  /// Creates an [FxStyleCycler].
  const FxStyleCycler({required this.style, required this.onCycle, super.key});

  /// The style currently shown.
  final FxOverlayStyle style;

  /// Advances to the next style.
  final VoidCallback onCycle;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      key: const Key('fx_style_cycler'),
      semanticLabel: style.caption,
      borderRadius: 8,
      onTap: onCycle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: surface.fxSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: surface.fx),
        ),
        child: AppText(
          style.caption,
          style: TextStyle(
            fontFamily: SurfaceTheme.monoFont,
            color: surface.fx,
            fontSize: kConsoleMode ? 14 : 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            height: 1,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Resolution.
// ---------------------------------------------------------------------------

/// The immutable per-cell slice the overlay draws — Equatable, so the reactive
/// `context.select` read rebuilds only when a drawn FX fact changes.
class _FxCellData extends Equatable {
  const _FxCellData({
    required this.channel,
    required this.bound,
    required this.hasChain,
    required this.address,
    required this.identityPrimary,
    required this.identitySub,
    required this.enabled,
  });

  /// A pedal with no binding: the quiet `unbound` cell.
  const _FxCellData.unbound(this.channel)
    : bound = false,
      hasChain = false,
      address = null,
      identityPrimary = '',
      identitySub = null,
      enabled = null;

  final int channel;

  /// Whether the footswitch carries a (resolvable) binding.
  final bool bound;

  /// Whether the bound chain exists in the live rig (may be empty).
  final bool hasChain;

  /// The bound chain's address — what a toggle flips. Null when unbound/stale.
  final FxAddress? address;

  /// The dominant identity line — `TARGET · CHAIN`, a bare stage, or a named
  /// input's own name.
  final String identityPrimary;

  /// The smaller second tier (`INPUT n` under a named input), or null.
  final String? identitySub;

  /// The chain's `enabled` state, or null when there is nothing to power (an
  /// empty or unresolved chain).
  final bool? enabled;

  @override
  List<Object?> get props => [
    channel,
    bound,
    hasChain,
    address,
    identityPrimary,
    identitySub,
    enabled,
  ];
}

/// Resolves the FX binding on [channel]'s footswitch to its drawn slice.
_FxCellData _resolveCell({
  required AppLocalizations l10n,
  required ControlState control,
  required LooperRepository looper,
  required Map<int, String> inputNames,
  required int channel,
}) {
  final position = channel - control.bankBaseChannel;
  if (position < 0 || position >= kTrackSwitches.length) {
    return _FxCellData.unbound(channel);
  }
  final key = PedalBindingKey(
    button: kTrackSwitches[position],
    bank: control.activeBank,
  );
  final binding = control.bindings.bindings
      .where((b) => b.key == key)
      .firstOrNull;
  final target = binding?.decodeTarget();
  if (target == null) return _FxCellData.unbound(channel);

  final address = target.address;
  final entries = looper.chainEntriesAt(address);
  final enabled = looper.bindingEnabled(FxChainTarget(address));
  if (entries == null || enabled == null) {
    // A stale binding — the chain it named is gone. Read as unbound on the
    // stage, the same silence its unlit pedal LED gives (R25).
    return _FxCellData.unbound(channel);
  }

  final stageLabel = _stageLabel(l10n, address);
  final chainName = entries.isEmpty
      ? null
      : fxBlockName(l10n, entries.first).toUpperCase();
  // A named input is the one two-tier identity: the socket's own name over a
  // smaller `INPUT n`. Every other stage — and an unnamed input — is a single
  // `TARGET · CHAIN` line, or the bare stage when the chain is empty.
  final inputName = address.stage == FxStage.input
      ? (inputNames[address.index] ?? '')
      : '';
  final String primary;
  final String? sub;
  if (inputName.isNotEmpty) {
    primary = inputName.toUpperCase();
    sub = stageLabel;
  } else if (address.stage == FxStage.input || chainName == null) {
    primary = stageLabel;
    sub = null;
  } else {
    primary = l10n.stageFxCellLabel(stageLabel, chainName);
    sub = null;
  }

  return _FxCellData(
    channel: channel,
    bound: true,
    hasChain: entries.isNotEmpty,
    address: address,
    identityPrimary: primary,
    identitySub: sub,
    // Nothing to power on an empty chain.
    enabled: entries.isEmpty ? null : enabled,
  );
}

/// The generic FX stage label — `INPUT n` / `TRACK n` / `LANE n` / `MASTER`,
/// 1-based, track-name-free (#692). A named input layers its own name over
/// this in [_resolveCell].
String _stageLabel(AppLocalizations l10n, FxAddress address) =>
    switch (address.stage) {
      FxStage.input => l10n.stageFxTargetInput(address.index + 1),
      FxStage.loop => l10n.stageFxTargetLane(address.lane ?? 0),
      FxStage.track => l10n.stageFxTargetTrack(address.index + 1),
      FxStage.master => l10n.stageFxTargetMaster,
    };
