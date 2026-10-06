import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_reverse.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

/// The accepted ten-pedal Reverse surface, driven by the shared Control
/// owner. Each track pedal turns its track around on contact; the overview
/// shows all eight directions.
class FootReverseView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootReverseView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final bank = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    final projection = context.select<LooperBloc, FootReverseProjection>(
      (bloc) => projectFootReverse(bloc.state, bank: bank),
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
        key: const Key('foot_reverse_view'),
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
                  key: const Key('foot_reverse_exit'),
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
                  onPressed: () => context.read<SettingsTrayCubit>().open(),
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
                          l10n.actionModeReverse,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootReversePedal(
                          button: PedalButton.clear,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootReversePedal(
                          button: PedalButton.bank,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 940,
                        top: 150,
                        width: 820,
                        child: _ReverseOverview(projection: projection),
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
                                child: _FootReversePedal(
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
class _ReverseOverview extends StatelessWidget {
  const _ReverseOverview({required this.projection});

  final FootReverseProjection projection;

  @override
  Widget build(BuildContext context) {
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          l10n.footReversePlaybackDirection,
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
                    child: _ReverseOverviewCell(
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

/// One track in the overview: name, then its direction or Empty.
class _ReverseOverviewCell extends StatelessWidget {
  const _ReverseOverviewCell({required this.track, required this.name});

  final FootReverseTrack track;
  final String name;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final color = !track.recorded
        ? surface.textMuted
        : track.reversed
        ? surface.textPrimary
        : surface.textSecondary;
    final style = TextStyle(fontSize: 22, color: color);
    // A busy recorded track keeps its real direction, dimmed: it cannot
    // turn around until the pass or arm resolves.
    return Opacity(
      key: Key('foot_reverse_overview_${track.channel}'),
      opacity: track.busy ? surface.disabledOpacity : 1,
      child: _overviewColumn(l10n, style, color),
    );
  }

  Widget _overviewColumn(AppLocalizations l10n, TextStyle style, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            if (track.recorded) ...[
              Icon(
                _directionIcon(reversed: track.reversed),
                size: 26,
                color: color,
              ),
              const SizedBox(width: 9),
            ],
            AppText(_directionWord(l10n, track), style: style),
          ],
        ),
      ],
    );
  }
}

/// Reads one track's direction as a short state word.
String _directionWord(AppLocalizations l10n, FootReverseTrack track) =>
    !track.recorded
    ? l10n.readoutStateEmpty
    : track.reversed
    ? l10n.footReverseReversed
    : l10n.footReverseForward;

/// The chevron pointing the way the track plays.
IconData _directionIcon({required bool reversed}) =>
    reversed ? Icons.chevron_left : Icons.chevron_right;

class _FootReversePedal extends StatelessWidget {
  const _FootReversePedal({required this.button, required this.projection});

  final PedalButton button;
  final FootReverseProjection projection;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final cursor = context.select<ControlCubit, int>(
      (cubit) => cubit.state.cursor,
    );
    final l10n = context.l10n;
    final role = FootReverseProjection.pedalRoles[button]!;
    final track = role.slot == null ? null : projection.trackAt(role.slot!);
    final title = switch (role.press) {
      FootReverseAction.recordPlay => l10n.actionRecordPlay,
      FootReverseAction.stop => l10n.actionStop,
      FootReverseAction.exit => l10n.actionModeExit,
      FootReverseAction.nextBank => l10n.footFadeBank(
        projection.bank == 0 ? 'A' : 'B',
      ),
      FootReverseAction.toggleTrack => l10n.displayTrackName(
        tracks.nameOf(track!.channel),
        track.channel,
      ),
      FootReverseAction.none =>
        button == PedalButton.undo
            ? l10n.actionUndo
            : l10n.actionOperationClear,
    };
    final detail = track != null
        ? _directionWord(l10n, track)
        : switch (role.press) {
            FootReverseAction.recordPlay => l10n.displayTrackName(
              tracks.nameOf(cursor),
              cursor,
            ),
            FootReverseAction.stop => l10n.actionScopeAllTracks,
            FootReverseAction.nextBank => l10n.footReverseSwitchBank,
            _ => '',
          };
    final reversed = track != null && track.recorded && track.reversed;
    return PerformancePedal(
      keyPrefix: 'foot_reverse_pedal',
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
      detailIcon: track != null && track.recorded
          ? _directionIcon(reversed: track.reversed)
          : null,
      detailHighlighted: reversed && !track.busy,
      hint: '',
      // A busy recorded track still admits the stomp, which is refused with
      // a notice; an empty one has nothing to turn around.
      enabled:
          role.press != FootReverseAction.none && (track?.recorded ?? true),
      // The selection bar mirrors the physical LED: a reversed track, Bank
      // on bank B, and Exit, the way back to Tracks.
      selected:
          role.press == FootReverseAction.exit ||
          (role.press == FootReverseAction.nextBank && projection.bank == 1) ||
          reversed,
      onPressed: control.footReversePressed,
      onReleased: control.footReverseReleased,
      onCancelled: control.footReverseCancelled,
      onActivate: () => control.activateFootReversePedal(button),
    );
  }
}
