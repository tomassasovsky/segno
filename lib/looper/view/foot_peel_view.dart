import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

/// The notice for a Peel press that removed nothing.
String footPeelRefusalText(AppLocalizations l10n, FootPeelRefusal refusal) =>
    switch (refusal) {
      FootPeelRefusal.empty => l10n.footPeelRefusedEmpty,
      FootPeelRefusal.originalOnly => l10n.footPeelRefusedOriginalOnly,
      FootPeelRefusal.busy => l10n.footPeelRefusedBusy,
      FootPeelRefusal.failed => l10n.footPeelFailure,
    };

/// The accepted ten-pedal Peel surface, driven by the shared Control owner.
/// Each track pedal removes its track's newest overdub layer on contact; the
/// overview shows all eight tracks' layers.
class FootPeelView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootPeelView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final bank = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    final projection = context.select<LooperBloc, FootPeelProjection>(
      (bloc) => projectFootPeel(bloc.state, bank: bank),
    );
    final l10n = context.l10n;
    final surface = context.surface;

    const front = [
      PedalButton.recPlay,
      PedalButton.stop,
      PedalButton.undo,
      PedalButton.mode,
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ];
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_peel_view'),
        children: [
          Container(
            height: 96,
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 36),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: Row(
              children: [
                IconButton.outlined(
                  key: const Key('foot_peel_exit'),
                  tooltip: l10n.actionModeExit,
                  onPressed: () => control.setMode(InteractionMode.record),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(64, 64),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                const Spacer(),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(136, 64),
                    textStyle: const TextStyle(
                      fontFamily: SurfaceTheme.displayFont,
                      fontSize: 24,
                      fontWeight: FontWeight.w400,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => unawaited(openSegnoSettings()),
                  child: AppText(l10n.stageSettings),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(60, 24, 60, 24),
              child: FittedBox(
                child: SizedBox(
                  width: 1800,
                  height: 880,
                  child: Stack(
                    children: [
                      PositionedDirectional(
                        start: 40,
                        top: 16,
                        child: AppText(
                          l10n.actionModePeel,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootPeelPedal(
                          button: PedalButton.clear,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootPeelPedal(
                          button: PedalButton.bank,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 940,
                        top: 150,
                        width: 820,
                        child: _PeelOverview(projection: projection),
                      ),
                      PositionedDirectional(
                        start: 40,
                        end: 40,
                        top: 472,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            for (final button in front)
                              SizedBox(
                                width: 180,
                                child: _FootPeelPedal(
                                  button: button,
                                  projection: projection,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The all-eight overview: a heading over two rows of four tracks.
class _PeelOverview extends StatelessWidget {
  const _PeelOverview({required this.projection});

  final FootPeelProjection projection;

  @override
  Widget build(BuildContext context) {
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          l10n.footPeelLayers,
          style: TextStyle(fontSize: 26, color: surface.textSecondary),
        ),
        const SizedBox(height: 22),
        for (final row in [0, 4])
          Padding(
            padding: const EdgeInsetsDirectional.only(bottom: 24),
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 18),
                  Expanded(
                    child: _PeelOverviewCell(
                      track: projection.tracks[row + i],
                      name: l10n.displayTrackName(
                        tracks.nameOf(row + i),
                        row + i,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One track in the overview: its name, then its layers.
class _PeelOverviewCell extends StatelessWidget {
  const _PeelOverviewCell({required this.track, required this.name});

  final FootPeelTrack track;
  final String name;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 22, color: _layersColor(context, track));
    return Column(
      key: Key('foot_peel_overview_${track.channel}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
        const SizedBox(height: 10),
        AppText(_layersWord(context.l10n, track), style: style),
      ],
    );
  }
}

/// Reads one track's layers as a short state word. A recorded track always
/// reads its real count, even while it is busy and cannot be peeled.
String _layersWord(AppLocalizations l10n, FootPeelTrack track) =>
    !track.hasContent
    ? l10n.readoutStateEmpty
    : track.layers <= 1
    ? l10n.footPeelOriginalOnly
    : l10n.stageLayersFigure(track.layers);

/// Bright while a press would peel, secondary for a recorded track that
/// cannot be peeled now, muted for an empty one.
Color _layersColor(BuildContext context, FootPeelTrack track) {
  final surface = context.surface;
  return track.available
      ? surface.textPrimary
      : track.hasContent
      ? surface.textSecondary
      : surface.textMuted;
}

class _FootPeelPedal extends StatelessWidget {
  const _FootPeelPedal({required this.button, required this.projection});

  final PedalButton button;
  final FootPeelProjection projection;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final cursor = context.select<ControlCubit, int>(
      (cubit) => cubit.state.cursor,
    );
    final l10n = context.l10n;
    final role = FootPeelProjection.pedalRoles[button]!;
    final track = role.slot == null ? null : projection.trackAt(role.slot!);
    final title = switch (role.press) {
      FootPeelAction.recordPlay => l10n.actionRecordPlay,
      FootPeelAction.stop => l10n.actionStop,
      FootPeelAction.exit => l10n.actionModeExit,
      FootPeelAction.nextBank => l10n.footFadeBank(
        projection.bank == 0 ? 'A' : 'B',
      ),
      FootPeelAction.peelTrack => l10n.displayTrackName(
        tracks.nameOf(track!.channel),
        track.channel,
      ),
      FootPeelAction.none =>
        button == PedalButton.undo
            ? l10n.actionUndo
            : l10n.actionOperationClear,
    };
    final detail = track != null
        ? _layersWord(l10n, track)
        : switch (role.press) {
            FootPeelAction.recordPlay => l10n.displayTrackName(
              tracks.nameOf(cursor),
              cursor,
            ),
            FootPeelAction.stop => l10n.actionScopeAllTracks,
            FootPeelAction.nextBank => l10n.footPeelSwitchBank,
            _ => '',
          };
    return PerformancePedal(
      keyPrefix: 'foot_peel_pedal',
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${role.slot! + 1}',
      },
      title: title,
      detail: detail,
      hint: '',
      // A recorded track's pedal takes a press even when it cannot peel
      // now, so the refusal can say why. An empty track's pedal is dimmed,
      // as on Fade and Reverse.
      enabled: role.press != FootPeelAction.none && (track?.hasContent ?? true),
      // The selection bar mirrors the physical LED: a track a press would
      // peel, Bank on bank B, and Exit, the way back to Tracks.
      selected:
          role.press == FootPeelAction.exit ||
          (role.press == FootPeelAction.nextBank && projection.bank == 1) ||
          (track?.available ?? false),
      onPressed: control.footPeelPressed,
      onReleased: control.footPeelReleased,
      onCancelled: control.footPeelCancelled,
      onActivate: () => control.activateFootPeelPedal(button),
    );
  }
}
