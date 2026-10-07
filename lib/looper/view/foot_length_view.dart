import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
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

/// The accepted ten-pedal Multiply and Divide surfaces (#1168, pen section
/// 16), driven by the shared Control owner. The track pedals select a
/// recorded track and Rec/Play, Stop keep their Tracks meaning. Multiply
/// doubles on Clear and keeps Undo; Divide keeps the first half on Undo
/// (hold for Undo) and the last half on Clear. The panel reads the selected
/// track's length and the outcome of the latest edit.
class FootLengthView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootLengthView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final (mode, bank, cursor, outcome) = context
        .select<ControlCubit, (InteractionMode, int, int, FootLengthOutcome)>(
          (cubit) => (
            cubit.state.mode,
            cubit.state.activeBank,
            cubit.state.cursor,
            cubit.state.footLengthOutcome,
          ),
        );
    final projection = context.select<LooperBloc, FootLengthProjection>(
      (bloc) => projectFootLength(bloc.state, bank: bank, cursor: cursor),
    );
    final sampleRate = context.select<LooperBloc, int>(
      (bloc) => bloc.state.status.sampleRate,
    );
    final l10n = context.l10n;
    final surface = context.surface;
    final divide = mode == InteractionMode.divide;

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
      mode: mode,
      projection: projection,
      outcome: outcome,
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
                          divide
                              ? l10n.actionModeDivide
                              : l10n.actionModeMultiply,
                          key: const Key('foot_length_title'),
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
                        top: 112,
                        width: 820,
                        child: _LengthPanel(
                          divide: divide,
                          projection: projection,
                          outcome: outcome,
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

/// The selected track's length (pen 16 "Selected track length"): its name
/// and length, one cell per bar (Divide: the two halves), and an outcome
/// line. With no recorded track selected it reads "Loop length" and says
/// what to do.
class _LengthPanel extends StatelessWidget {
  const _LengthPanel({
    required this.divide,
    required this.projection,
    required this.outcome,
    required this.sampleRate,
  });

  final bool divide;
  final FootLengthProjection projection;
  final FootLengthOutcome outcome;
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    final track = projection.selected;
    final secondary = TextStyle(fontSize: 26, color: surface.textSecondary);
    if (!track.hasContent) {
      return Column(
        key: const Key('foot_length_panel_empty'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(l10n.footLengthOverview, style: secondary),
          const SizedBox(height: 14),
          AppText(
            projection.bankHasContent
                ? l10n.footLengthSelectTrack
                : l10n.footLengthBankEmpty,
            key: const Key('foot_length_panel_note'),
            style: TextStyle(fontSize: 22, color: surface.textSecondary),
          ),
        ],
      );
    }
    final cells = _cells(l10n, track, divide: divide);
    return Column(
      key: const Key('foot_length_panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: AppText(
                l10n.displayTrackName(
                  tracks.nameOf(track.channel),
                  track.channel,
                ),
                key: const Key('foot_length_panel_track'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: secondary,
              ),
            ),
            AppText(
              _lengthWord(l10n, track, sampleRate),
              key: const Key('foot_length_panel_length'),
              style: TextStyle(fontSize: 46, color: surface.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 92,
          child: Row(
            children: [
              for (var i = 0; i < cells.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: _LengthCell(
                    key: Key('foot_length_cell_$i'),
                    cell: cells[i],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 26),
        AppText(
          _outcomeWord(l10n, track, outcome, sampleRate),
          key: const Key('foot_length_panel_note'),
          style: TextStyle(fontSize: 22, color: surface.textSecondary),
        ),
      ],
    );
  }
}

/// One cell of the length panel: its label and one tick per beat.
typedef _Cell = ({String label, int ticks});

/// The panel's cells: Divide's two halves, else one per bar (or beat), at
/// most 16; a length with neither reads as one unlabelled cell.
List<_Cell> _cells(
  AppLocalizations l10n,
  FootLengthTrack track, {
  required bool divide,
}) {
  final bars = track.bars;
  final beats = track.totalBeats;
  final perBar = bars != null && bars > 0 && beats != null ? beats ~/ bars : 1;
  final halves = track.halves;
  if (divide && !track.busy && halves != null) {
    final ticks = halves.inBars ? halves.half * perBar : halves.half;
    return [
      (label: l10n.footLengthFirstHalf, ticks: ticks),
      (label: l10n.footLengthLastHalf, ticks: ticks),
    ];
  }
  final units = bars ?? beats;
  if (units == null || units <= 0) return [(label: '', ticks: 0)];
  final count = units.clamp(1, 16);
  return [
    for (var i = 0; i < count; i++)
      (label: '${i + 1}', ticks: bars != null ? perBar : 1),
  ];
}

class _LengthCell extends StatelessWidget {
  const _LengthCell({required this.cell, super.key});

  final _Cell cell;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(7, 6, 7, 8),
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            cell.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(fontSize: 17, color: surface.textSecondary),
          ),
          const Spacer(),
          // One tick per beat, rising through each bar, as the pen draws
          // the recorded beat order. Ticks that would not fit are left out.
          LayoutBuilder(
            builder: (context, constraints) {
              final fit = ((constraints.maxWidth + 4) / 16).floor();
              final ticks = cell.ticks.clamp(0, fit < 0 ? 0 : fit);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < ticks; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    Container(
                      width: 12,
                      height: 14.0 + 8 * (i % 4),
                      decoration: BoxDecoration(
                        color: surface.textTertiary,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ],
              );
            },
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
/// whole beats (a halved sole loop), else seconds, or Empty.
String _lengthWord(
  AppLocalizations l10n,
  FootLengthTrack track,
  int sampleRate,
) {
  if (!track.hasContent) return l10n.readoutStateEmpty;
  final bars = track.bars;
  if (bars != null) return l10n.stageBarsFigure(bars);
  final beats = track.beats;
  if (beats != null) return l10n.stageBeatsFigure(beats);
  if (sampleRate <= 0) return l10n.stageNoBarsFigure;
  return l10n.footLengthSeconds(track.lengthFrames / sampleRate);
}

/// What Double length would make of [track]: twice its bars, beats or
/// seconds.
String _doubledWord(
  AppLocalizations l10n,
  FootLengthTrack track,
  int sampleRate,
) {
  final bars = track.bars;
  if (bars != null) return l10n.stageBarsFigure(bars * 2);
  final beats = track.beats;
  if (beats != null) return l10n.stageBeatsFigure(beats * 2);
  if (sampleRate <= 0) return l10n.stageNoBarsFigure;
  return l10n.footLengthSeconds(2 * track.lengthFrames / sampleRate);
}

/// The bars or beats one half of [track] covers: "Bar 1", "Beats 3–4".
/// Empty when the halves are not whole beats.
String _halfWord(
  AppLocalizations l10n,
  FootLengthTrack track, {
  required bool first,
}) {
  final halves = track.halves;
  if (halves == null) return '';
  final from = first ? 1 : halves.half + 1;
  final to = first ? halves.half : 2 * halves.half;
  if (halves.inBars) {
    return from == to
        ? l10n.footLengthBar(from)
        : l10n.footLengthBars(from, to);
  }
  return from == to
      ? l10n.footLengthBeat(from)
      : l10n.footLengthBeats(from, to);
}

/// The panel's outcome line: what the latest edit on the selected track did
/// while it still describes it, else that speed and pitch are unchanged.
String _outcomeWord(
  AppLocalizations l10n,
  FootLengthTrack track,
  FootLengthOutcome outcome,
  int sampleRate,
) {
  if (track.busy) return l10n.footLengthFinishRecordingNote;
  if (!outcome.describes(track)) return l10n.footLengthUnchanged;
  final length = _lengthWord(l10n, track, sampleRate);
  return switch (outcome.edit) {
    LengthEdit.doubled => l10n.footLengthRepeated(length),
    LengthEdit.firstHalf => l10n.footLengthFirstKept(length),
    LengthEdit.lastHalf => l10n.footLengthLastKept(length),
  };
}

class _FootLengthPedal extends StatelessWidget {
  const _FootLengthPedal({
    required this.button,
    required this.mode,
    required this.projection,
    required this.outcome,
    required this.sampleRate,
  });

  final PedalButton button;
  final InteractionMode mode;
  final FootLengthProjection projection;
  final FootLengthOutcome outcome;
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final l10n = context.l10n;
    final role = FootLengthProjection.rolesFor(mode)[button]!;
    final track = role.slot == null ? null : projection.trackAt(role.slot!);
    final selected = projection.selected;
    final edits = FootLengthProjection.editOf(role.press) != null;
    String selectedName() => l10n.displayTrackName(
      tracks.nameOf(selected.channel),
      selected.channel,
    );
    final title = switch (role.press) {
      FootLengthAction.recordPlay => l10n.actionRecordPlay,
      FootLengthAction.undo => l10n.actionUndo,
      FootLengthAction.redo => l10n.actionRedo,
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
      FootLengthAction.recordPlay => selectedName(),
      FootLengthAction.undo =>
        !selected.canUndo
            ? l10n.footLengthNothingToUndo
            : outcome.describes(selected)
            ? l10n.footLengthUndoEdit
            : l10n.footLengthUndoLast,
      // The edit pedals say what they would do, or why they cannot.
      _ when edits && !selected.hasContent => l10n.footLengthSelectTrack,
      _ when edits && selected.busy => l10n.footLengthFinishRecording,
      FootLengthAction.doubleTrack => l10n.footLengthRepeatTo(
        _doubledWord(l10n, selected, sampleRate),
      ),
      FootLengthAction.firstHalf => _halfWord(l10n, selected, first: true),
      FootLengthAction.lastHalf => _halfWord(l10n, selected, first: false),
      FootLengthAction.stop => l10n.actionScopeAllTracks,
      FootLengthAction.nextBank => l10n.footMixerTracksPage(
        projection.bank * 4 + 1,
        projection.bank * 4 + 4,
      ),
      FootLengthAction.exit || FootLengthAction.redo => '',
    };
    final hold = role.hold;
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
      // Divide's First half gives way to Undo on a hold, while there is
      // something to undo.
      hint: hold == FootLengthAction.undo && selected.canUndo
          ? l10n.footLengthHoldUndo
          : '',
      // An empty track is dimmed and silent: its pedal cannot be selected,
      // and the edit pedals rest while no recorded track is selected. A busy
      // recorded track still admits the stomp, which is refused with a
      // notice. Undo rests while there is nothing to undo.
      enabled: track != null
          ? track.hasContent
          : role.press == FootLengthAction.undo
          ? selected.canUndo || selected.canRedo
          : !edits || selected.hasContent || (hold != null && selected.canUndo),
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
      onHold: hold == null ? null : () => control.holdFootLengthPedal(button),
    );
  }
}
