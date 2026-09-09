import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/looper_mode_change.dart';
import 'package:segno/theme/theme.dart';

/// The Loop mode page: the five mode cards with their diagrams (the pen's
/// `mode-choices`, 1744 x 420 at (88, 332) under the title). A card that the
/// engine refuses right now shows its reason in place of its description;
/// choosing a mode over playing loops asks "Stop loops and switch" in the
/// pen's own dialog (accepted design, Loop mode transitions).
class LoopModePage extends StatelessWidget {
  /// Creates a [LoopModePage].
  const LoopModePage({super.key});

  @override
  Widget build(BuildContext context) {
    final current = context.select<LooperBloc, LooperMode>(
      (bloc) => bloc.state.transport.looperMode,
    );
    // The reasons move with the rig (a take starting, a queue landing), so
    // they are read on every projection rather than once.
    context.select<LooperBloc, int>((bloc) => bloc.state.tracks.length);
    final repository = context.read<LooperRepository>();
    final l10n = context.l10n;
    final primary = context.select<LooperBloc, int>(
      (bloc) => bloc.state.transport.primaryTrack,
    );
    return Positioned(
      left: 88,
      top: 332,
      child: Row(
        children: [
          for (final (i, mode) in LooperMode.values.indexed) ...[
            if (i > 0) const SizedBox(width: 24),
            _ModeCard(
              key: Key('loop_mode_${mode.name}'),
              mode: mode,
              selected: mode == current,
              reason: _reason(
                l10n,
                mode,
                mode == current
                    ? LooperModeGate.open
                    : repository.looperModeGate(mode),
                primary,
              ),
              onTap: () => unawaited(
                requestLooperModeChange(
                  context,
                  current: current,
                  next: mode,
                  confirm: () => _confirmStop(context, mode),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The card's line under its diagram: its description, or why it cannot
  /// be chosen right now.
  static String _reason(
    AppLocalizations l10n,
    LooperMode mode,
    LooperModeGate gate,
    int primary,
  ) => switch (gate) {
    LooperModeGate.open || LooperModeGate.playing => switch (mode) {
      LooperMode.multi => l10n.loopModeMultiDesc,
      LooperMode.sync => l10n.loopModeSyncDesc,
      LooperMode.song => l10n.loopModeSongDesc,
      LooperMode.band => l10n.loopModeBandDesc,
      LooperMode.free => l10n.loopModeFreeDesc,
    },
    LooperModeGate.capturing => l10n.loopModeReasonCapturing,
    LooperModeGate.queued => l10n.loopModeReasonQueued,
    LooperModeGate.spans => switch (mode) {
      LooperMode.multi => l10n.loopModeReasonEqualLengths,
      _ => l10n.loopModeReasonFollowPrimary(primary < 0 ? 1 : primary + 1),
    },
  };

  /// The pen's "Switch to …?" dialog: 960 x 267, Cancel and the filled
  /// "Stop loops and switch".
  static Future<bool> _confirmStop(
    BuildContext context,
    LooperMode next,
  ) async {
    final l10n = context.l10n;
    final surface = context.surface;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: surface.scrim,
      builder: (dialogContext) => Center(
        child: Material(
          color: Colors.transparent,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              key: const Key('loop_mode_confirm'),
              width: 960,
              height: 267,
              padding: const EdgeInsets.all(41),
              decoration: BoxDecoration(
                color: surface.cardHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: surface.borderStrong),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    l10n.modeChangeStopTitle(
                      looperModeLabels(l10n)[next]!.label,
                    ),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 32,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 29),
                  AppText(
                    l10n.modeChangeStopBody,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 24,
                      height: 1,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _DialogButton(
                        key: const Key('loop_mode_confirm_cancel'),
                        label: l10n.consoleKeepIt,
                        width: 125,
                        onTap: () => Navigator.of(dialogContext).pop(false),
                      ),
                      const SizedBox(width: 15),
                      _DialogButton(
                        key: const Key('loop_mode_confirm_switch'),
                        label: l10n.modeChangeStopConfirm,
                        width: 305,
                        filled: true,
                        onTap: () => Navigator.of(dialogContext).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return confirmed ?? false;
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.width,
    required this.onTap,
    this.filled = false,
    super.key,
  });

  final String label;
  final double width;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: filled ? surface.accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
        side: BorderSide(color: filled ? surface.accent : surface.borderStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: 64,
          child: Center(
            child: AppText(
              label,
              style: TextStyle(
                color: filled ? surface.onAccent : surface.textPrimary,
                fontSize: 24,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One mode card: 330 x 420, the name and a check when selected, the
/// three-track diagram, and the description or reason.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.reason,
    required this.onTap,
    super.key,
  });

  final LooperMode mode;
  final bool selected;
  final String reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = looperModeLabels(l10n)[mode]!.label;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      value: reason,
      child: Material(
        color: selected ? surface.accentSurface : surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? surface.accent : surface.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 330,
            height: 420,
            child: Stack(
              children: [
                Positioned(
                  left: 29,
                  top: 29,
                  child: AppText(
                    name,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 36,
                      height: 1,
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    left: 273,
                    top: 37,
                    child: Icon(
                      LucideIcons.check,
                      size: 28,
                      color: surface.textPrimary,
                    ),
                  ),
                Positioned(
                  left: 29,
                  top: 100,
                  child: _ModeDiagram(mode: mode, selected: selected),
                ),
                Positioned(
                  left: 29,
                  top: 268,
                  width: 272,
                  child: AppText(
                    reason,
                    key: Key('loop_mode_${mode.name}_reason'),
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 24,
                      height: 34 / 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pen's three-track diagram for a mode: each track is a 272 x 32 row of
/// loop blocks, drawn from the pen's own block positions.
class _ModeDiagram extends StatelessWidget {
  const _ModeDiagram({required this.mode, required this.selected});

  final LooperMode mode;
  final bool selected;

  /// Each track's blocks as (left, width) in the 272-wide row.
  static const Map<LooperMode, List<List<(double, double)>>> _blocks = {
    LooperMode.multi: [
      [(0, 272)],
      [(0, 272)],
      [(0, 272)],
    ],
    LooperMode.sync: [
      [(0, 60), (71, 60), (141, 60), (212, 60)],
      [(0, 131), (141, 131)],
      [(0, 272)],
    ],
    LooperMode.song: [
      [(0, 82)],
      [(95, 82)],
      [(190, 82)],
    ],
    LooperMode.band: [
      [(0, 272)],
      [(0, 131)],
      [(141, 131)],
    ],
    LooperMode.free: [
      [(0, 101), (114, 101)],
      [(41, 166)],
      [(8, 66), (90, 66), (171, 66)],
    ],
  };

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fill = selected ? surface.accentAlt : surface.controlStrong;
    final edge = selected ? surface.textPrimary : surface.borderStrong;
    return SizedBox(
      width: 272,
      height: 140,
      child: Stack(
        children: [
          for (final (row, blocks) in _blocks[mode]!.indexed)
            for (final (left, width) in blocks)
              Positioned(
                left: left,
                top: 6 + 48.0 * row,
                child: Container(
                  width: width,
                  height: 32,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: edge),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
