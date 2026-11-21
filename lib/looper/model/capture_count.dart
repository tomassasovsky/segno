import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

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

/// [count] as the stage writes it (#1936): the figure and its small unit,
/// `2 / 4` bars, `3` bars or `0:07` with no unit.
({String figure, String unit}) captureCountWords(
  AppLocalizations l10n,
  CaptureCount count,
) {
  if (count.ofBars > 0) {
    return (
      figure: '${count.bar} / ${count.ofBars}',
      unit: l10n.stageBarsUnit(count.ofBars),
    );
  }
  if (count.bar > 0) {
    return (figure: '${count.bar}', unit: l10n.stageBarsUnit(count.bar));
  }
  return (figure: elapsedFigure(count.seconds), unit: '');
}

/// [seconds] as the stage's elapsed time: `0:07`, `1:32`.
String elapsedFigure(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// [count] in one piece, as the readout writes it: `2 / 4 bars`, `0:07`.
String captureCountText(AppLocalizations l10n, CaptureCount count) {
  final words = captureCountWords(l10n, count);
  return words.unit.isEmpty ? words.figure : '${words.figure} ${words.unit}';
}
