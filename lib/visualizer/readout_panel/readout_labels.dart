import 'package:looper_repository/looper_repository.dart' show RecordTiming;
import 'package:segno/l10n/l10n.dart';

/// What each [RecordTiming] is called on the readout (#1654): short enough
/// for a 72 px button and the footer strip. The note values are written as
/// fractions, which read the same in both languages.
String readoutTimingLabel(AppLocalizations l10n, RecordTiming timing) =>
    switch (timing) {
      RecordTiming.immediately => l10n.readoutTimingNow,
      RecordTiming.loopStart => l10n.readoutTimingLoopTop,
      RecordTiming.bar => l10n.loopTimingBar,
      RecordTiming.half => '1/2',
      RecordTiming.quarter => '1/4',
      RecordTiming.eighth => '1/8',
      RecordTiming.sixteenth => '1/16',
    };

/// A record timing on the Loop panel's Start buttons: as [readoutTimingLabel]
/// names it, shorter where a button has no room for the whole name (#1672).
String readoutTimingButtonLabel(AppLocalizations l10n, RecordTiming timing) =>
    timing == RecordTiming.loopStart
    ? l10n.readoutButtonLoopTop
    : readoutTimingLabel(l10n, timing);

/// A length as the readout names it: Auto, or the bars.
String readoutLengthLabel(AppLocalizations l10n, int bars) =>
    bars <= 0 ? l10n.loopLengthAuto : l10n.lengthPresetBars(bars);

/// The tempo with its hundredths, as the panel and the keypad show it, or
/// the dash for no tempo.
String readoutExactTempo({required bool hasTempo, required double bpm}) =>
    hasTempo ? bpm.toStringAsFixed(2) : '—';
