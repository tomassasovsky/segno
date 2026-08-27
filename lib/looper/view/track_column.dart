import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/console_mode.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/rename_track_dialog.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/theme/theme.dart';

/// One tall track column in the Tracks view: a header (channel number,
/// loop-multiple badge, and undo/redo on the selected column), a tappable level
/// meter (record/overdub in record mode, mute/unmute in mute mode; long-press
/// stops), an editable name, and an optional readiness indicator strip.
class TrackColumn extends StatelessWidget {
  /// Creates a [TrackColumn].
  const TrackColumn({
    required this.track,
    required this.name,
    required this.selected,
    required this.mode,
    required this.onUndo,
    required this.onRedo,
    this.looperMode = LooperMode.multi,
    this.isPrimary = false,
    this.onCrownPrimary,
    this.fxTarget,
    this.inputNames = const {},
    super.key,
  });

  /// The track this column renders.
  final Track track;

  /// The FX stage the footswitch bound to this cell attaches to, in FX mode.
  ///
  /// FX mode identifies a cell CHAIN-FIRST — by the FX stage its bound chain
  /// targets, never by the column's track (#692): a footswitch may toggle a
  /// chain on any stage (an input monitor, a lane, another track's bus, the
  /// Master insert), so the cell names the chain it drives, not the track it
  /// happens to sit above.
  ///
  /// Null defaults to this column's own Track-stage chain — what the on-screen
  /// stage's per-column tap currently toggles ([LooperTrackChainToggled]) — so
  /// the identity still reads `TRACK n · …`, chain-first, exactly like any
  /// other target. The chain's entries and power state are always taken from
  /// [track] (the polled snapshot the stage renders); [fxTarget] renames the
  /// cell, it does not re-source the chain.
  final FxAddress? fxTarget;

  /// The player's own names for hardware inputs, keyed by socket index (the
  /// input-rename feature; `InputsState.names`).
  ///
  /// Only consulted when [fxTarget] is an Input-stage chain: a named socket
  /// makes the cell read `GUITAR 1 · …` instead of `INPUT 1 · …` (owner's
  /// call). Empty — the default — always yields the generic `INPUT n`.
  final Map<int, String> inputNames;

  /// The track's resolved display name.
  final String name;

  /// Whether this column is the selected one (a heavier white border).
  final bool selected;

  /// The active system mode (Record vs Mute).
  final InteractionMode mode;

  /// Dispatches an undo for the given channel (shares the keyboard path's
  /// dispatch+announce, wired in the host view).
  final void Function(int channel) onUndo;

  /// Dispatches a redo for the given channel.
  final void Function(int channel) onRedo;

  /// The five-mode axis (B5c): governs whether the crown badge shows at all
  /// — visible in Sync/Band, absent in Multi/Song/Free (Wave-view style, per
  /// the brainstorm).
  final LooperMode looperMode;

  /// Whether [track] is the crowned primary track (D18).
  final bool isPrimary;

  /// Dispatches a crown-primary press for the given channel. Required
  /// whenever [looperMode] is Sync/Band (the badge is interactive then).
  final void Function(int channel)? onCrownPrimary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final surface = context.surface;
    final bloc = context.read<LooperBloc>();

    // The border is always white; selection only changes its weight. The meter
    // bar color is one table lookup on the track's meter state (muted included;
    // see LooperTheme.meterColors).
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final isFx = mode == InteractionMode.fx;
    // FX mode recedes the meter to 40% alpha so the chain dressing reads on top
    // of it (#692). The meter stays TRUTHFUL — it is taken pre-chain, so it is
    // the same fill and hue the other modes show — it just steps back to let
    // the chain identity own the tile. The other modes paint it at full weight.
    final barColor = isFx
        ? looper.meterColor(meterState, mode: mode).withValues(alpha: 0.4)
        : looper.meterColor(meterState, mode: mode);
    // The FX-mode cell identity, chain-first (#692): the FX stage the bound
    // chain sits on, then the chain's own name — the track name is deliberately
    // absent, since the cell drives an FX control that need not belong to this
    // column's track. The stage defaults to this column's own Track chain (what
    // the per-column tap toggles), so a track chain still reads `TRACK n · …`,
    // named like every other target rather than borrowing the track's name. The
    // chain name is the head of the entries the polled snapshot carries.
    final fxAddress =
        fxTarget ?? FxAddress(stage: FxStage.track, index: track.channel);
    final fxStageLabel = _stageFxTargetLabel(l10n, fxAddress);
    final fxChainName = track.effects.isEmpty
        ? null
        : fxBlockName(l10n, track.effects.first);
    // A NAMED input is the ONE two-tier identity (owner's call): the socket's
    // own name on top, a smaller `INPUT n` sub-label under it, and the chain in
    // the entry-run chips below (not jammed into the identity line). Every
    // other stage — and an UNNAMED input — is a single `TARGET · CHAIN` line,
    // or the bare stage when the chain is empty.
    final fxInputName = fxAddress.stage == FxStage.input
        ? (inputNames[fxAddress.index] ?? '')
        : '';
    final String fxIdentityPrimary;
    final String? fxIdentitySub;
    if (fxInputName.isNotEmpty) {
      fxIdentityPrimary = fxInputName.toUpperCase();
      fxIdentitySub = fxStageLabel;
    } else if (fxAddress.stage == FxStage.input || fxChainName == null) {
      // Unnamed input, or an empty chain on any stage: the bare stage label.
      fxIdentityPrimary = fxStageLabel;
      fxIdentitySub = null;
    } else {
      fxIdentityPrimary = l10n.stageFxCellLabel(
        fxStageLabel,
        fxChainName.toUpperCase(),
      );
      fxIdentitySub = null;
    }
    // The screen-reader identity flattens the two tiers into one phrase.
    final fxCellLabel = fxIdentitySub == null
        ? fxIdentityPrimary
        : '$fxIdentityPrimary $fxIdentitySub';
    // Crown badge (D18, B5c): visible only in Sync/Band (Wave-view style,
    // per the brainstorm) — an inert, empty slot in every other mode so the
    // column layout never shifts when the mode changes.
    final crownVisible =
        looperMode == LooperMode.sync || looperMode == LooperMode.band;
    // Built once and placed in whichever branch below applies (console
    // Stack vs standard Row) — a single construction site means the two
    // layouts can never diverge on the badge's key/callback wiring (a
    // console-only regression the per-layout-flavor split would otherwise
    // let slip past a plain `flutter test` run, since `kConsoleMode` is a
    // compile-time constant no normal test toggles).
    final crownBadge = crownVisible
        ? _CrownBadge(
            key: Key('tracks_crown_${track.channel}'),
            isPrimary: isPrimary,
            color: theme.colorScheme.primary,
            onCrown: onCrownPrimary == null
                ? null
                : () => onCrownPrimary!(track.channel),
          )
        : null;

    // The track name label. On the console it renders at a uniform, larger
    // size (consistent height across columns; the longest name reaches ~60% of
    // the column width); desktop keeps the fixed text size.
    final nameStyle = theme.textTheme.titleMedium?.copyWith(
      color: surface.textPrimary,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.5,
    );
    final nameText = AppText(
      name,
      textAlign: TextAlign.center,
      style: nameStyle,
    );
    // Undo/Redo shortcut hints adapt to the host platform — Segno targets
    // Windows/Linux too, so this must not hardcode the macOS modifier.
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final undoShortcut = isMac ? '⌘Z' : 'Ctrl+Z';
    final redoShortcut = isMac ? '⌘⇧Z' : 'Ctrl+Y';
    // The meter conveys state through colour only (WCAG 1.4.1); name the state
    // in words so it reaches the tile's accessible label.
    final stateWord = switch (meterState) {
      LooperMeterState.empty => l10n.trackStateEmpty,
      LooperMeterState.recording => l10n.trackStateRecording,
      LooperMeterState.overdubbing => l10n.trackStateOverdubbing,
      LooperMeterState.playing => l10n.trackStatePlaying,
      LooperMeterState.stopped => l10n.trackStateStopped,
      LooperMeterState.muted => l10n.trackStateMuted,
    };

    return Container(
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(17),
        // Selected: a 4px white ring (onAccent == pure white). Unselected: a
        // 1px near-black hairline (the pen's card stroke #17171b, the `card`
        // token's near-black) — not borderless.
        border: Border.all(
          color: selected ? surface.onAccent : surface.card,
          width: selected ? 4 : 1,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (kConsoleMode)
            // Console mode: the foot pedals own undo/redo, so the on-screen
            // buttons are hidden entirely and the channel number is centred.
            // The loop-multiple badge still rides the right edge; a pending
            // arm badge (A5) rides the left.
            Stack(
              alignment: Alignment.center,
              children: [
                AppText(
                  '${track.channel + 1}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    // The pen's cell number: UI sans, muted grey.
                    fontFamily: SurfaceTheme.displayFont,
                    color: surface.textTertiary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (track.isMultiple)
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppText(
                      l10n.loopMultipleLabel(track.multiple),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                if (track.pending)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _PendingArmBadge(color: looper.recordColor),
                  ),
                if (crownBadge != null)
                  Align(alignment: Alignment.topCenter, child: crownBadge),
              ],
            )
          else
            Row(
              children: [
                if (crownBadge != null) ...[
                  crownBadge,
                  const SizedBox(width: 6),
                ],
                AppText(
                  '${track.channel + 1}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: surface.textSecondary,
                  ),
                ),
                if (track.pending) ...[
                  const SizedBox(width: 6),
                  _PendingArmBadge(color: looper.recordColor),
                ],
                const Spacer(),
                if (track.isMultiple)
                  AppText(
                    l10n.loopMultipleLabel(track.multiple),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                // Undo/Redo surface only on the selected column; the keyboard
                // shortcut hint in each tooltip adapts to the host platform.
                if (selected) ...[
                  IconButton(
                    key: Key('tracks_undo_${track.channel}'),
                    tooltip: l10n.undoTooltip(undoShortcut),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: looper.toolbarIconColor,
                    icon: const Icon(Icons.undo),
                    // Mirrors the `U` key: enabled whenever there is a layer to
                    // peel — stacked overdub passes, or the base recording
                    // itself (undoing it empties the track, redo-ably) — but
                    // not mid-capture, when the engine rejects undo.
                    onPressed:
                        (track.hasContent || track.canUndo) &&
                            !track.isCapturing
                        ? () => onUndo(track.channel)
                        : null,
                  ),
                  IconButton(
                    key: Key('tracks_redo_${track.channel}'),
                    tooltip: l10n.redoTooltip(redoShortcut),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: looper.toolbarIconColor,
                    icon: const Icon(Icons.redo),
                    onPressed: track.canRedo && !track.isCapturing
                        ? () => onRedo(track.channel)
                        : null,
                  ),
                ],
              ],
            ),
          Expanded(
            child: FocusableTapTarget(
              key: Key('tracks_tile_${track.channel}'),
              // The tap action follows the mode (mirroring the 1–8 number
              // keys): record/overdub in record mode, mute/unmute in mute
              // mode, FX-chain on/off in FX mode — one interaction mode for
              // every surface, touch included.
              // FX mode names the cell chain-first — its bound chain's target
              // identity (#692), not the track — and adds the CHAIN state,
              // which the meter and indicator (transport only) never report,
              // while KEEPING the transport word the other modes carry, which
              // the meter otherwise conveys by colour alone (WCAG 1.4.1).
              semanticLabel: switch (mode) {
                InteractionMode.record => l10n.a11yTrackTile(name, stateWord),
                InteractionMode.mute => l10n.a11yTrackTileMute(name, stateWord),
                InteractionMode.fx =>
                  track.chainEnabled
                      ? l10n.a11yTrackTileFxOn(fxCellLabel, stateWord)
                      : l10n.a11yTrackTileFxOff(fxCellLabel, stateWord),
              },
              selected: selected,
              borderRadius: 8,
              onTap: () {
                context.read<ControlCubit>().selectTrack(track.channel);
                switch (mode) {
                  case InteractionMode.record:
                    bloc.add(LooperRecordPressed(track.channel));
                  case InteractionMode.mute:
                    bloc.add(LooperMuteToggled(track.channel));
                  case InteractionMode.fx:
                    // Toggle event, not a computed set: `track` here is the
                    // polled snapshot, a poll behind any flip another surface
                    // just made. The announcement shares the keyboard path's
                    // helper so the two cannot drift.
                    TracksCommands(context).announceFxChainToggle(
                      track.channel,
                    );
                    bloc.add(LooperTrackChainToggled(track.channel));
                }
              },
              child: GestureDetector(
                key: Key('tracks_tileStop_${track.channel}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: PeakMeterBar(
                        peak: track.peak,
                        color: barColor,
                        hasContent: track.hasContent,
                        // A stopped track reports no live peak; hold the last
                        // fill so a loaded-but-paused loop keeps a visible bar
                        // after a stop.
                        frozen: track.state == TrackState.stopped,
                      ),
                    ),
                    // FX mode re-dresses the tile in place (#692): over the
                    // receded meter, one centered vertical group in the
                    // cell's upper-middle — the chain-first `TARGET · CHAIN`
                    // identity as the dominant focal text, the chain's entries
                    // in signal order below it, then a large ON/OFF power pill
                    // (or a centered NO CHAIN when the chain is empty). This is
                    // the on-screen twin of the tile's semantic label and of
                    // the pedal's chain LED; the meter alone shows nothing
                    // about the chain, since it is taken pre-chain.
                    if (isFx)
                      Positioned.fill(
                        child: _FxChainDressing(
                          identityPrimary: fxIdentityPrimary,
                          identitySub: fxIdentitySub,
                          effects: track.effects,
                          chainEnabled: track.chainEnabled,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          _TrackHistoryDots(
            // The base loop is not an engine undo layer (undo_depth counts
            // retired overdub passes only), but it is undoable — undoing it
            // clears the track — so count it as the first history entry.
            undoDepth: track.undoDepth + (track.hasContent ? 1 : 0),
            redoDepth: track.redoDepth,
          ),
          // The track name identifies the column in every mode BUT FX. In FX
          // mode the cell is not the track — it drives a bound FX chain, named
          // chain-first by the `TARGET · CHAIN` identity inside the tile above
          // (#692) — so the track name is removed from the cell entirely rather
          // than re-asserting the track-as-FX-control conflation here.
          if (!isFx) ...[
            const SizedBox(height: kConsoleMode ? 2 : 10),
            FocusableTapTarget(
              key: Key('tracks_name_${track.channel}'),
              semanticLabel: l10n.a11yRenameTrack(name),
              onTap: () => showRenameTrackDialog(
                context: context,
                cubit: context.read<TracksCubit>(),
                channel: track.channel,
                current: name,
              ),
              child: kConsoleMode
                  // Fixed console name size: uniform height across columns,
                  // tuned so a 6-char name (e.g. GUITAR) reaches ~60% of the
                  // column width on the 16" panel. Hard-coded (not
                  // width-relative).
                  ? AppText(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle?.copyWith(fontSize: 47.3, height: 1),
                    )
                  : nameText,
            ),
          ],
          // A discrete arm/readiness strip, shown only when the view preference
          // is on. When off the widget is absent and the tile reflows.
          if (context.select<TracksCubit, bool>(
            (c) => c.state.showIndicators,
          )) ...[
            const SizedBox(height: 6),
            _TrackIndicator(
              key: Key('tracks_indicator_${track.channel}'),
              status: TrackIndicator.of(
                track.state,
                muted: track.muted,
                hasContent: track.hasContent,
                selected: selected,
                mode: mode,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single-line, paged undo/redo history for a track.
///
/// History entries are laid out over pages of exactly [_slotsPerPage] dots.
/// The page-turn chevrons live in fixed gutters outside the dot row (invisible
/// when there is no adjacent page), so they never take a slot and the dots
/// never shift sideways. Only the page holding the current position is shown:
/// bright dots are undoable layers, grey dots are redoable ones, and faint
/// dots are unused slots — so the white/grey boundary marks where you are.
class _TrackHistoryDots extends StatelessWidget {
  const _TrackHistoryDots({
    required this.undoDepth,
    required this.redoDepth,
  });

  final int undoDepth;

  final int redoDepth;

  static const _slotsPerPage = 10;

  @override
  Widget build(BuildContext context) {
    final total = undoDepth + redoDepth;
    if (total == 0) return const SizedBox.shrink();

    final surface = context.surface;
    final looper = Theme.of(context).extension<LooperTheme>()!;

    final pageCount = (total + _slotsPerPage - 1) ~/ _slotsPerPage;
    // Show the page holding the newest undoable layer (0-based item index),
    // or the first page when there is nothing left to undo.
    final current = undoDepth == 0 ? 0 : undoDepth - 1;
    final page = current ~/ _slotsPerPage;
    final start = page * _slotsPerPage;

    // Three tiers of history slot: a layer you can peel, one you could redo
    // back to, and an unused slot. The last is `borderSubtle` rather than a
    // text tone — an empty slot is a container hairline, not a label.
    Color slotColor(int item) {
      if (item < undoDepth) return surface.textPrimary;
      if (item < total) return surface.textTertiary;
      return surface.borderSubtle;
    }

    // The console's are the pen's: `STAGE / stage` draws ten 10px dots 5 apart
    // in a 14-tall strip. They had been scaled up to 18 on the argument that
    // they should match the larger track name — but they are a history
    // READOUT, not a control, and at 18 with an 8 gap the row was half again
    // as wide as the column the pen gives it. Desktop keeps its compact sizes.
    const dotSize = kConsoleMode ? 10.0 : 8.0;
    const rowHeight = kConsoleMode ? 14.0 : 12.0;
    const gutterSize = kConsoleMode ? 14.0 : 12.0;
    const gapSize = kConsoleMode ? 5.0 : 4.0;

    Widget gutter(IconData icon, {required bool visible}) => Visibility(
      visible: visible,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: Icon(icon, size: gutterSize, color: looper.toolbarIconColor),
    );

    return SizedBox(
      height: rowHeight,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: gapSize,
          children: [
            gutter(Icons.chevron_left, visible: page > 0),
            for (var i = 0; i < _slotsPerPage; i++)
              SizedBox.square(
                dimension: dotSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: slotColor(start + i),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            gutter(Icons.chevron_right, visible: page < pageCount - 1),
          ],
        ),
      ),
    );
  }
}

/// A static, full-width status strip below a track name. Its colour is the
/// track's [TrackIndicator] state. Carries no semantics of its own
/// ([ExcludeSemantics]): the tile already names its state for screen readers,
/// so a second label here would double-announce. Static colour ⇒ no motion.
class _TrackIndicator extends StatelessWidget {
  const _TrackIndicator({required this.status, super.key});

  final TrackIndicator status;

  @override
  Widget build(BuildContext context) {
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: looper.indicatorColor(status),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const SizedBox(height: 5, width: double.infinity),
      ),
    );
  }
}

/// The crown badge marking (and setting) the Sync/Band primary track (D18),
/// Wave-view style per the brainstorm: a filled, inert badge on the
/// currently-crowned track; a dim, tappable one on every other track (tap to
/// crown IT instead — there is no separate "un-crown" gesture, matching the
/// engine's `crownPrimary`-only API).
class _CrownBadge extends StatelessWidget {
  const _CrownBadge({
    required this.isPrimary,
    required this.color,
    required this.onCrown,
    super.key,
  });

  /// Whether this track is the currently-crowned primary.
  final bool isPrimary;

  /// The badge's active tint when [isPrimary] (dimmed otherwise).
  final Color color;

  /// Crowns this track. `null` renders the badge fully inert (no callback
  /// wired) — the caller decides whether crowning is available at all.
  final VoidCallback? onCrown;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FocusableTapTarget(
      // Tapping the already-primary track's own badge would be a no-op (no
      // un-crown gesture exists), so it is presented as inert, matching
      // FocusableTapTarget's disabled-semantics convention.
      onTap: isPrimary ? null : onCrown,
      semanticLabel: isPrimary ? l10n.a11yTrackPrimary : l10n.a11yCrownTrack,
      selected: isPrimary,
      borderRadius: 4,
      child: Icon(
        Icons.workspace_premium,
        size: 14,
        color: isPrimary ? color : color.withValues(alpha: 0.35),
      ),
    );
  }
}

/// A small badge marking a track with a pending quantized/signal-triggered
/// record arm ([Track.pending], A3) — armed and waiting for its boundary,
/// cancellable by a second press on the tile or the pedal/controller's
/// global cancel-arm action (A5).
class _PendingArmBadge extends StatelessWidget {
  const _PendingArmBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.a11yTrackArmed,
      child: Icon(Icons.schedule_outlined, size: 14, color: color),
    );
  }
}

/// The generic FX stage label of an FX-mode cell — the stage the bound chain
/// sits on: `INPUT n` / `TRACK n` / `LANE n` / `MASTER` (#692).
///
/// Indices are 1-based, matching every other jack name the rig gives. This is
/// name-free by design: TRACK never borrows the column's track name (the
/// conflation fix), and LANE / MASTER carry no name. A NAMED input's own name
/// is layered on TOP of this in [TrackColumn] as a two-tier identity (the name
/// over this `INPUT n` sub-label); this helper always returns the generic form.
String _stageFxTargetLabel(AppLocalizations l10n, FxAddress address) =>
    switch (address.stage) {
      FxStage.input => l10n.stageFxTargetInput(address.index + 1),
      FxStage.loop => l10n.stageFxTargetLane(address.lane ?? 0),
      FxStage.track => l10n.stageFxTargetTrack(address.index + 1),
      FxStage.master => l10n.stageFxTargetMaster,
    };

/// The FX-mode re-dressing drawn over a track's (receded) meter (#692).
///
/// Candidate A of the #692 spike: FX mode does not swap the stage, it
/// re-dresses each tile IN PLACE — geometry, the 1–8 key parity and the
/// footswitch map all stay frozen, so the performer's spatial map is untouched.
///
/// The dressing is ONE centered vertical group sitting in the cell's
/// upper-middle, over the waveform (the approved Pencil `stage-fx` frame), NOT
/// scattered to the corners:
///
/// 1. the chain-first `TARGET · CHAIN` identity — the dominant focal text,
///    white when engaged;
/// 2. the chain's entries as small chips joined by `→`, in signal order;
/// 3. a large ON/OFF power pill — purple-filled `ON`, ghost-outlined `OFF`.
///
/// A bypassed chain dims the whole group together. An empty chain replaces the
/// group with a centered NO CHAIN and its hint — there is nothing to power.
///
/// It carries no semantics ([ExcludeSemantics]) and no hit target
/// ([IgnorePointer]): [TrackColumn]'s tile already names the chain state for a
/// screen reader, and the FX-mode tap that toggles the chain has to fall
/// through to the tile beneath this overlay.
class _FxChainDressing extends StatelessWidget {
  const _FxChainDressing({
    required this.identityPrimary,
    required this.identitySub,
    required this.effects,
    required this.chainEnabled,
  });

  /// The cell's primary identity line — `TARGET · CHAIN` (e.g.
  /// `MASTER · REVERB`), the bare stage `TARGET`, or a NAMED input's own name.
  final String identityPrimary;

  /// The smaller, dimmer second identity tier, or null for a single-line
  /// identity. Only a named input carries one: its `INPUT n` under the name.
  final String? identitySub;

  /// The bound chain's entries, in processing order.
  final List<TrackEffect> effects;

  /// Whether the whole chain is engaged (drives the power pill and the group's
  /// engaged/dimmed reading).
  final bool chainEnabled;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: effects.isEmpty
              // Nothing loaded: no power pill (there is nothing to power), just
              // a centered NO CHAIN and the invitation to build one.
              ? const Align(
                  // Upper-middle: the NO CHAIN group centres at ~40% of the
                  // card, matching the pen.
                  alignment: Alignment(0, -0.33),
                  child: _FxNoChain(),
                )
              // The centered group, anchored so its centre sits at ~42.7% of
              // the card (the pen). A bypassed chain reads as dimmed — but
              // through OPAQUE muted colours, not a translucent group: dimming
              // white over the green fill tinted the identity green and the
              // pill blue (the pen's dimmed values are flat neutral greys).
              : Align(
                  alignment: const Alignment(0, -0.26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A FIXED two-line slot for the identity, top-anchored: a
                      // one-line identity leaves the lower line empty. This
                      // keeps the chip row and the ON/OFF pill at the SAME y in
                      // every cell — a named input's second tier no longer
                      // pushes the indicators down out of line with its
                      // one-line neighbours across the row.
                      SizedBox(
                        height: kConsoleMode
                            ? _kFxIdentitySlot
                            : _kFxIdentitySlotDesktop,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: _FxCellIdentity(
                            primary: identityPrimary,
                            sub: identitySub,
                            enabled: chainEnabled,
                          ),
                        ),
                      ),
                      // Inter-element gaps opened to the pen's proportions:
                      // identity→chips ~3.8% of the card, chips→pill ~3.2%.
                      const SizedBox(height: kConsoleMode ? 20 : 12),
                      _FxEntryRun(effects: effects, chainEnabled: chainEnabled),
                      const SizedBox(height: kConsoleMode ? 30 : 18),
                      _FxPowerPill(enabled: chainEnabled),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// The centered "no effects loaded" state: a large NO CHAIN over a small,
/// dimmed hint pointing at the Signal tab where a chain is assembled. Both in
/// the UI sans, in the pen's flat muted grey.
class _FxNoChain extends StatelessWidget {
  const _FxNoChain();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          l10n.stageFxNoChain,
          key: const Key('tracks_tileFxNoChain'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textMuted,
            fontSize: kConsoleMode ? 28 : 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            height: 1.1,
          ),
        ),
        const SizedBox(height: kConsoleMode ? 8 : 5),
        AppText(
          l10n.stageFxNoChainHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textMuted,
            fontSize: kConsoleMode ? 18 : 12,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

/// The fixed height of the FX-cell identity slot — sized for the TWO-line
/// named input (primary 30 + 6 gap + `INPUT n` sub 18, plus the faces' line
/// overhead), so a one-line identity leaves the lower line empty and every
/// cell's chips + pill start at the same y.
const double _kFxIdentitySlot = 66;

/// The desktop twin (primary 19 + 4 gap + sub 12, plus overhead).
const double _kFxIdentitySlotDesktop = 44;

/// The cell identity — the dominant focal text of an FX-mode cell, in the UI
/// sans, at the top of the centered group.
///
/// Usually a single [primary] line: `TARGET · CHAIN` (e.g. `MASTER · REVERB`),
/// a bare stage `TARGET`, or — for a NAMED input — the socket's own name, with
/// a smaller, dimmer [sub] tier (`INPUT n`) directly beneath it. Names the FX
/// control the cell drives, NOT the track in the column (#692). The [primary]
/// line is near-white ([SurfaceTheme.textPrimary]) when engaged and a flat,
/// OPAQUE muted grey ([SurfaceTheme.textSecondary]) when bypassed — never a
/// translucent white, which over the green meter tints green; the [sub] line is
/// always the muted grey. Carries no semantics of its own: the tile's FX label
/// already announces this same identity.
class _FxCellIdentity extends StatelessWidget {
  const _FxCellIdentity({
    required this.primary,
    required this.sub,
    required this.enabled,
  });

  final String primary;

  final String? sub;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final subLabel = sub;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          primary,
          key: const Key('tracks_tileFxTarget'),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: enabled ? surface.textPrimary : surface.textSecondary,
            fontSize: kConsoleMode ? 30 : 19,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            height: 1,
          ),
        ),
        if (subLabel != null) ...[
          const SizedBox(height: kConsoleMode ? 6 : 4),
          AppText(
            subLabel,
            key: const Key('tracks_tileFxTargetSub'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textMuted,
              fontSize: kConsoleMode ? 18 : 12,
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

/// The large ON/OFF power pill — the prominent fully-round stadium below the
/// chips that states the whole chain's on/off at stage distance.
///
/// `ON` is purple-filled ([SurfaceTheme.fx]) with a WHITE label — a mode fill,
/// never an inline wash of `fx` (the high-contrast flavor could not reach that;
/// #737). `OFF` is the ghost of the same pill: transparent with a flat muted
/// grey ([SurfaceTheme.textMuted]) outline and label (the run's [Opacity] dims
/// it further when bypassed). The label is the UI sans, sized to the pen.
class _FxPowerPill extends StatelessWidget {
  const _FxPowerPill({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Container(
      key: const Key('tracks_tileFxPower'),
      padding: const EdgeInsets.symmetric(
        horizontal: kConsoleMode ? 46 : 28,
        vertical: kConsoleMode ? 16 : 10,
      ),
      decoration: BoxDecoration(
        color: enabled ? surface.fx : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        // OFF ring is the pen's flat muted grey, not the fx purple (which over
        // the green meter read bluish).
        border: enabled ? null : Border.all(color: surface.textMuted, width: 2),
      ),
      child: AppText(
        enabled ? l10n.stageFxChainOn : l10n.stageFxChainOff,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: SurfaceTheme.displayFont,
          // White label (onAccent) on the purple ON fill; flat muted grey on
          // the ghost.
          color: enabled ? surface.onAccent : surface.textMuted,
          fontSize: kConsoleMode ? 40 : 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          height: 1,
        ),
      ),
    );
  }
}

/// The chain's entries as small neutral chips joined by a sans `→`, in signal
/// order — the surface where #601's per-entry dim/strikethrough idiom will mark
/// bypassed entries. Sits directly below the identity, centered.
///
/// The whole run dims with the group when the chain is bypassed (the [Opacity]
/// here); the per-ENTRY seam is deliberate: [_FxEntryChip] already takes a
/// `bypassed` flag (always `false` until #601 wires per-entry state), so that
/// slice changes one argument here and nothing else.
class _FxEntryRun extends StatelessWidget {
  const _FxEntryRun({required this.effects, required this.chainEnabled});

  final List<TrackEffect> effects;

  final bool chainEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // Interleave entry chips with arrow separators, in processing order.
    final children = <Widget>[];
    for (var i = 0; i < effects.length; i++) {
      if (i > 0) {
        // The literal '→' (U+2192) in the UI SANS — Inter has the glyph, so it
        // renders cleanly; the console's mono face does not, which is what drew
        // the .notdef tofu when the run inherited it.
        children.add(
          AppText(
            '→',
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textMuted,
              fontSize: kConsoleMode ? 16 : 12,
              height: 1,
            ),
          ),
        );
      }
      children.add(
        // #601 seam: `bypassed` is passed explicitly false today; that slice
        // computes it per entry and this is the one line it edits.
        _FxEntryChip(label: fxBlockName(l10n, effects[i]), bypassed: false),
      );
    }
    return Opacity(
      // A bypassed run reads dimmer, together with the rest of the group.
      opacity: chainEnabled ? 1 : surface.disabledOpacity,
      child: Container(
        key: const Key('tracks_tileFxEntryRun'),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: kConsoleMode ? 8 : 6,
          runSpacing: 4,
          children: children,
        ),
      ),
    );
  }
}

/// One entry in the stage-tile chain run — the entry's name in a small neutral
/// pill chip (UI sans), a dark-grey fill with a hairline white border.
///
/// [bypassed] is the #601 seam: when that slice lands it will dim/strike a
/// single bypassed entry here without touching the whole-chain path above.
class _FxEntryChip extends StatelessWidget {
  const _FxEntryChip({required this.label, required this.bypassed});

  final String label;

  final bool bypassed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: bypassed ? surface.disabledOpacity : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kConsoleMode ? 14 : 9,
          vertical: kConsoleMode ? 8 : 5,
        ),
        decoration: BoxDecoration(
          // Neutral pills over the waveform (the pen): a dark-grey fill with a
          // hairline white border and a near-white label — NOT the FX purple,
          // which belongs to the power pill alone.
          color: surface.control,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: surface.borderSubtle),
        ),
        child: AppText(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textPrimary,
            fontSize: kConsoleMode ? 18 : 13,
            fontWeight: FontWeight.w600,
            decoration: bypassed ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }
}
