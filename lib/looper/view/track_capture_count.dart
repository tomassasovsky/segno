import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/capture_count.dart';
import 'package:segno/looper/view/live_playhead.dart';
import 'package:segno/looper/view/track_column.dart' show SlotFigure;

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
    final tsNum = context.select<LooperBloc, int>(
      (bloc) => bloc.state.transport.tsNum,
    );
    final (framesPerBar, sampleRate) = context
        .select<LooperBloc, (double?, int)>((bloc) {
          final sampleRate = bloc.state.status.sampleRate;
          return (bloc.state.transport.framesPerBar(sampleRate), sampleRate);
        });
    return LivePlayhead<CaptureCount>(
      // The grid is part of the key: the selection reads it.
      key: ValueKey((channel, framesPerBar, sampleRate, tsNum)),
      select: (playhead) => captureCountOf(
        playhead.capture(channel),
        framesPerBar: framesPerBar,
        sampleRate: sampleRate,
        // The beat analysis's estimate, while a free first take records.
        estimateFramesPerBar: estimateFramesPerBar(
          playhead.tempoEstimateOf(channel),
          tsNum,
          sampleRate,
        ),
      ),
      builder: (context, count) {
        final words = captureCountWords(l10n, count);
        return SlotFigure(
          key: Key('tracks_capture_$channel'),
          figure: words.figure,
          unit: words.unit,
          figureStyle: figureStyle,
          unitStyle: unitStyle,
        );
      },
    );
  }
}
