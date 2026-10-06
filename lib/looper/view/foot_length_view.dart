import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_length.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

/// The accepted ten-pedal Multiply / Divide surface (#1168), driven by the
/// shared Control owner. The track pedals select a recorded track; Rec/Play
/// doubles it, Undo keeps its first half and Clear its last half. The
/// overview shows all eight lengths.
class FootLengthView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootLengthView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final (bank, cursor) = context.select<ControlCubit, (int, int)>(
      (cubit) => (cubit.state.activeBank, cubit.state.cursor),
    );
    final projection = context.select<LooperBloc, FootLengthProjection>(
      (bloc) => projectFootLength(bloc.state, bank: bank, cursor: cursor),
    );
    final sampleRate = context.select<LooperBloc, int>(
      (bloc) => bloc.state.status.sampleRate,
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
    Widget pedal(PedalButton button) => _FootLengthPedal(
      button: button,
      projection: projection,
      sampleRate: sampleRate,
    );
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_length_view'),
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
                  key: const Key('foot_length_exit'),
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
                          l10n.actionModeLength,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: pedal(PedalButton.clear),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: pedal(PedalButton.bank),
                      ),
                      PositionedDirectional(
                        start: 940,
                        top: 150,
                        width: 820,
                        child: _LengthOverview(
                          projection: projection,
                          sampleRate: sampleRate,
                        ),
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
                              SizedBox(width: 180, child: pedal(button)),
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
class _LengthOverview extends StatelessWidget {
  const _LengthOverview({required this.projection, required this.sampleRate});

  final FootLengthProjection projection;
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          l10n.footLengthOverview,
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
                    child: _LengthOverviewCell(
                      track: projection.tracks[row + i],
                      selected:
                          projection.cursor == row + i &&
                          projection.tracks[row + i].hasContent,
                      sampleRate: sampleRate,
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

/// One track in the overview: its name, its length, and how it relates to
/// the base loop. The selected track carries the selection bar.
class _LengthOverviewCell extends StatelessWidget {
  const _LengthOverviewCell({
    required this.track,
    required this.selected,
    required this.sampleRate,
    required this.name,
  });

  final FootLengthTrack track;
  final bool selected;
  final int sampleRate;
  final String name;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final color = !track.hasContent
        ? surface.textMuted
        : selected
        ? surface.textPrimary
        : surface.textSecondary;
    final style = TextStyle(fontSize: 22, color: color);
    final ratio = _ratioWord(l10n, track);
    // A busy recorded track keeps its real length, dimmed: it cannot change
    // until the pass or arm resolves.
    return Opacity(
      key: Key('foot_length_overview_${track.channel}'),
      opacity: track.busy ? surface.disabledOpacity : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: Key('foot_length_overview_bar_${track.channel}'),
            height: 4,
            width: 56,
            color: selected ? surface.accent : Colors.transparent,
          ),
          const SizedBox(height: 8),
          AppText(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
          const SizedBox(height: 10),
          AppText(
            [
              _lengthWord(l10n, track, sampleRate),
              ?ratio,
            ].join(' · '),
            style: style,
          ),
        ],
      ),
    );
  }
}

/// The notice for a Multiply / Divide that changed nothing.
String footLengthRefusalText(
  AppLocalizations l10n,
  FootLengthRefusal refusal,
) => switch (refusal) {
  FootLengthRefusal.empty => l10n.footLengthEmpty,
  FootLengthRefusal.busy => l10n.footLengthBusy,
  FootLengthRefusal.incompatible => l10n.footLengthIncompatible,
  FootLengthRefusal.capacity => l10n.footLengthCapacity,
  FootLengthRefusal.failed => l10n.footLengthFailure,
};

/// Reads one track's length: whole bars when the grid counts them, else
/// seconds, or Empty.
String _lengthWord(
  AppLocalizations l10n,
  FootLengthTrack track,
  int sampleRate,
) {
  if (!track.hasContent) return l10n.readoutStateEmpty;
  final bars = track.bars;
  if (bars != null) return l10n.stageBarsFigure(bars);
  if (sampleRate <= 0) return l10n.stageNoBarsFigure;
  return l10n.footLengthSeconds(track.lengthFrames / sampleRate);
}

/// How the track relates to the base loop: `×2`, `×4`, `1/2`, `1/4`, or
/// null for one base loop or an empty track.
String? _ratioWord(AppLocalizations l10n, FootLengthTrack track) {
  if (!track.hasContent) return null;
  if (track.syncDivisor > 1) return l10n.footLengthDivision(track.syncDivisor);
  if (track.multiple > 1) return l10n.loopMultipleLabel(track.multiple);
  return null;
}

class _FootLengthPedal extends StatelessWidget {
  const _FootLengthPedal({
    required this.button,
    required this.projection,
    required this.sampleRate,
  });

  final PedalButton button;
  final FootLengthProjection projection;
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final role = FootLengthProjection.pedalRoles[button]!;
    final track = role.slot == null ? null : projection.trackAt(role.slot!);
    final selectedTrack = projection.selected;
    final edits = FootLengthProjection.editOf(role.press) != null;
    final title = switch (role.press) {
      FootLengthAction.doubleTrack => l10n.footLengthDouble,
      FootLengthAction.firstHalf => l10n.footLengthFirstHalf,
      FootLengthAction.lastHalf => l10n.footLengthLastHalf,
      FootLengthAction.stop => l10n.actionStop,
      FootLengthAction.exit => l10n.actionModeExit,
      FootLengthAction.nextBank => l10n.footFadeBank(
        projection.bank == 0 ? 'A' : 'B',
      ),
      FootLengthAction.selectTrack => l10n.displayTrackName(
        tracks.nameOf(track!.channel),
        track.channel,
      ),
    };
    final detail = switch (role.press) {
      FootLengthAction.selectTrack => _lengthWord(l10n, track!, sampleRate),
      // The edit pedals name the track they act on.
      _ when edits =>
        selectedTrack.hasContent
            ? l10n.displayTrackName(
                tracks.nameOf(selectedTrack.channel),
                selectedTrack.channel,
              )
            : l10n.readoutStateEmpty,
      FootLengthAction.stop => l10n.actionScopeAllTracks,
      FootLengthAction.nextBank => l10n.footReverseSwitchBank,
      _ => '',
    };
    final selectedSlot =
        track != null && track.hasContent && track.channel == projection.cursor;
    return PerformancePedal(
      keyPrefix: 'foot_length_pedal',
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
      detailHighlighted: selectedSlot,
      hint: '',
      // An empty track is dimmed and silent: its pedal cannot be selected,
      // and the edit pedals rest while the selected track is empty. A busy
      // recorded track still admits the stomp, which is refused with a
      // notice.
      enabled: track != null
          ? track.hasContent
          : !edits || selectedTrack.hasContent,
      // The selection bar mirrors the physical LED: the selected recorded
      // track, Bank on bank B, and Exit, the way back to Tracks.
      selected:
          role.press == FootLengthAction.exit ||
          (role.press == FootLengthAction.nextBank && projection.bank == 1) ||
          selectedSlot,
      onPressed: control.footLengthPressed,
      onReleased: control.footLengthReleased,
      onCancelled: control.footLengthCancelled,
      onActivate: () => control.activateFootLengthPedal(button),
    );
  }
}
