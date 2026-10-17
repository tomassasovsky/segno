import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// What each [RecordTiming] is called on the Loop settings pages. One table
/// for the choice buttons, the hub summary and the notes.
Map<RecordTiming, String> recordTimingLabels(AppLocalizations l10n) => {
  RecordTiming.immediately: l10n.loopTimingImmediately,
  RecordTiming.loopStart: l10n.loopTimingLoopStart,
  RecordTiming.bar: l10n.loopTimingBar,
  RecordTiming.half: l10n.loopTimingHalf,
  RecordTiming.quarter: l10n.loopTimingQuarter,
  RecordTiming.eighth: l10n.loopTimingEighth,
  RecordTiming.sixteenth: l10n.loopTimingSixteenth,
};

/// The one-sentence note under the record timing choices.
String recordTimingNote(AppLocalizations l10n, RecordTiming timing) =>
    switch (timing) {
      RecordTiming.immediately => l10n.loopTimingNoteImmediately,
      RecordTiming.loopStart => l10n.loopTimingNoteLoopStart,
      _ => l10n.loopTimingNoteGrid(recordTimingLabels(l10n)[timing]!),
    };

/// A length preset as the hub and the editor name it: Auto, or the bars.
String lengthPresetLabel(AppLocalizations l10n, int bars) =>
    bars <= 0 ? l10n.loopLengthAuto : l10n.lengthPresetBars(bars);

/// The note under the length choices.
String lengthPresetNote(AppLocalizations l10n, int bars) =>
    bars <= 0 ? l10n.loopLengthNoteAuto : l10n.loopLengthNoteBars(bars);

/// The note under the decay slider.
String overdubDecayNote(AppLocalizations l10n, int percent) =>
    switch (percent) {
      0 => l10n.loopDecayNoteOff,
      100 => l10n.loopDecayNoteReplace,
      _ => l10n.loopDecayNote(100 - percent),
    };

/// The decay readout: Off, or the percent.
String overdubDecayReadout(AppLocalizations l10n, int percent) =>
    percent <= 0 ? l10n.loopDecayOff : l10n.loopDecayPercent(percent);

/// A time signature as the pages write it.
String timeSignatureLabel(int num, int den) => '$num/$den';
