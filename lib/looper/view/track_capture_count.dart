import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/live_playhead.dart';
import 'package:segno/looper/view/track_column.dart' show SlotFigure;

/// What a recording take's count shows (#1936), quantised to what changes on
/// screen: the bar being recorded and the bars the take will have, or the
/// whole seconds a take with no bar grid has run.
typedef CaptureCount = ({int bar, int ofBars, int seconds});

/// [capture]'s count. With a bar length ([framesPerBar]) it counts bars: the
/// bar being recorded, from 1, and the bars of the target when the take has
/// one. Without, it counts the seconds captured at [sampleRate].
CaptureCount captureCountOf(
  TakeCapture capture, {
  required double? framesPerBar,
  required int sampleRate,
}) {
  if (framesPerBar != null && framesPerBar > 0) {
    final ofBars = capture.targetFrames > 0
        ? (capture.targetFrames / framesPerBar).round()
        : 0;
    final bar = capture.frames ~/ framesPerBar + 1;
    // The seam's crossfade captures a few frames past the target.
    return (
      bar: ofBars > 0 && bar > ofBars ? ofBars : bar,
      ofBars: ofBars,
      seconds: 0,
    );
  }
  return (
    bar: 0,
    ofBars: 0,
    seconds: sampleRate > 0 ? capture.frames ~/ sampleRate : 0,
  );
}

/// [seconds] as the stage's elapsed time: `0:07`, `1:32`.
String elapsedFigure(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// The bars slot of a recording track (#1936): `2 / 4` bars toward a target,
/// `3` bars on a take only a press ends, or `0:07` on a take with no bar
/// grid (a first take with no tempo).
///
/// A leaf on the live playheads, like `TrackProgressBar`: the take's frames
/// move on every poll, so this follows them itself and rebuilds only when the
/// bar or the second it shows changes.
class TrackCaptureCount extends StatelessWidget {
  /// Creates a [TrackCaptureCount].
  const new({
    required this.channel,
    required this.figureStyle,
    required this.unitStyle,
    super.key,
  });

  /// The recording track's channel.
  final int channel;

  /// The figure's style, the bars slot's own.
  final TextStyle figureStyle;

  /// The unit's style, the bars slot's own.
  final TextStyle unitStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (framesPerBar, sampleRate) = context
        .select<LooperBloc, (double?, int)>((bloc) {
          final state = bloc.state;
          final sampleRate = state.status.sampleRate;
          final perBeat = state.transport.framesPerBeat(sampleRate);
          final tsNum = state.transport.tsNum;
          return (
            perBeat == null || tsNum <= 0 ? null : perBeat * tsNum,
            sampleRate,
          );
        });
    return LivePlayhead<CaptureCount>(
      // The grid is part of the key: the selection reads it.
      key: ValueKey((channel, framesPerBar, sampleRate)),
      select: (playhead) => captureCountOf(
        playhead.capture(channel),
        framesPerBar: framesPerBar,
        sampleRate: sampleRate,
      ),
      builder: (context, count) => SlotFigure(
        key: Key('tracks_capture_$channel'),
        figure: count.ofBars > 0
            ? '${count.bar} / ${count.ofBars}'
            : count.bar > 0
            ? '${count.bar}'
            : elapsedFigure(count.seconds),
        unit: count.ofBars > 0
            ? l10n.stageBarsUnit(count.ofBars)
            : count.bar > 0
            ? l10n.stageBarsUnit(count.bar)
            : '',
        figureStyle: figureStyle,
        unitStyle: unitStyle,
      ),
    );
  }
}
