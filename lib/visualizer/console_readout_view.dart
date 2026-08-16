import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// The console's 7" second screen, drawn to the pen's revised
/// `STAGE / readout` (the `c/readout` contract, #701): glance facts in
/// two-metre type over the whole-loop output waveform.
///
/// The header is a single row whose height is set by the figure pairs —
/// TEMPO, TIME, then BARS with its beat dots stacked beneath the figure —
/// and a flat right column: the mode word with the A/B bank pair and the
/// armed-capture pill side by side beneath it. Everything else (track
/// names, rows, per-track state words) lives on the main screen; the strip
/// takes all remaining height.
///
/// **Proportional, not absolute.** The pen draws the screen at 1920×1080,
/// but the device window's logical size depends on the compositor scale
/// (640×360 today at scale=3). Every dimension here is the pen's figure
/// times the limiting-axis scale against that reference, so the layout is
/// the pen's at any logical size — the pen's proportions are the contract,
/// not its pixels.
class ConsoleReadoutView extends StatelessWidget {
  /// Creates a [ConsoleReadoutView].
  const ConsoleReadoutView({
    required this.readout,
    required this.waveform,
    this.onMix,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// The whole-loop waveform region, injected so this widget stays pure
  /// presentation (the window wires the frame stream into it).
  final Widget waveform;

  /// Opens the volume overlay — wired to the MIX pill, the readout's ONLY
  /// touch affordance (`c/readout`, #707): the old tap-anywhere gesture is
  /// dead, and every other element stays inert so its surface remains
  /// available for future interactivity.
  final VoidCallback? onMix;

  /// The pen frame's size — the reference every dimension is drawn against.
  static const Size _penSize = Size(1920, 1080);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _penSize.width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : _penSize.height;
        // The limiting axis sets the scale: the 7" panel is a touch narrower
        // than the pen's 16:9 (1024x600 is 1.71:1), so a height-only scale
        // would run the header off the right edge. The freed height on such
        // a panel goes to the loop strip, which is elastic by design.
        final s = (width / _penSize.width < height / _penSize.height)
            ? width / _penSize.width
            : height / _penSize.height;
        return Padding(
          // The pen insets the whole screen 32 and separates the header from
          // the strip by 28.
          padding: EdgeInsets.all(32 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The pen's 220-tall header, sized by its own type (36-over-180
              // plus the caption gap) rather than a fixed box: real font
              // metrics run fractions of a pixel past the drawn figure, and
              // a clipped descender is a worse fidelity loss than one.
              _ReadoutHeader(readout, s),
              SizedBox(height: 28 * s),
              // The strip takes all remaining height — the pen's 766, 71% of
              // the frame — on the waveform's own dark, the pen's radius.
              // The MIX pill rides absolutely over the bars in the strip's
              // bottom-right corner, per the pen.
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14 * s),
                  child: ColoredBox(
                    key: const Key('console_readout_waveform'),
                    color: Theme.of(
                      context,
                    ).extension<LooperTheme>()!.waveformBackground,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: 24 * s,
                            horizontal: 16 * s,
                          ),
                          child: waveform,
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: _MixPill(s: s, onTap: onMix),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The MIX pill (`c/readout`, #707): the BACK-chip idiom drawn inside the
/// strip's bottom-right corner — 180×72 inset 24 from the strip's edges, on
/// the stage background because a near-full-height bar can run behind the
/// label. The ONLY affordance that opens the volume overlay.
///
/// The tap target is generous but bounded: the pill plus its 24-inset
/// margin on every side (out to the strip's corner) — a finger pad, NOT the
/// whole strip, which would resurrect tap-anywhere by the back door.
class _MixPill extends StatelessWidget {
  const _MixPill({required this.s, required this.onTap});

  final double s;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return GestureDetector(
      key: const Key('console_readout_mix'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(24 * s),
        child: Container(
          width: 180 * s,
          height: 72 * s,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: surface.background,
            borderRadius: BorderRadius.circular(24 * s),
            border: Border.all(color: surface.borderStrong, width: 2 * s),
          ),
          child: AppText(
            context.l10n.readoutMix,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 36 * s,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.52 * s,
              height: 1,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}

/// The single header row: the TEMPO / TIME / BARS figure pairs (beat dots
/// stacked beneath the BARS figure), then the right column — the mode word
/// over the bank pair and the record pill side by side.
class _ReadoutHeader extends StatelessWidget {
  const _ReadoutHeader(this.readout, this.s);

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tempo = readout.tempoBpm > 0 ? readoutTempo(readout.tempoBpm) : '--';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The figures-and-dots cluster takes whatever the right column
        // leaves and scales DOWN only when it does not fit: in the pen's
        // nominal case the FittedBox is a no-op and every dimension stays
        // the drawn one (the pen proves the h:mm:ss worst case with ~110 px
        // of slack), but a worst case the pen never draws (a long localized
        // count-in word, a high-numerator signature's fifteen dots, an
        // hour-plus clock, all at once) shrinks the cluster gracefully
        // instead of clipping the mode word and the lights off the panel.
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BigStat(
                  key: const Key('console_readout_tempo'),
                  label: l10n.readoutTempoLabel,
                  value: tempo,
                  s: s,
                ),
                SizedBox(width: 96 * s),
                _BigStat(
                  key: const Key('console_readout_clock'),
                  label: l10n.readoutClockLabel,
                  value: readoutClock(readout.elapsedSeconds),
                  s: s,
                ),
                if (readout.loopBars > 0 || readout.hasTempo)
                  SizedBox(width: 96 * s),
                _BarsAndBeats(readout: readout, s: s),
              ],
            ),
          ),
        ),
        SizedBox(width: 64 * s),
        _ModeColumn(readout: readout, s: s),
      ],
    );
  }
}

/// The tempo rule (`c/readout`): the decimal appears only when the tempo
/// actually carries one. The check is on the RENDERED string, not the
/// double: 119.98 rounds to "120.0", and a value-level `% 1` test would
/// keep that phantom ".0" on screen. Format first, then strip. Shared with
/// the 16" readout so the two faces can never disagree on a tempo.
String readoutTempo(double tempoBpm) {
  final rendered = tempoBpm.toStringAsFixed(1);
  return rendered.endsWith('.0')
      ? rendered.substring(0, rendered.length - 2)
      : rendered;
}

/// The clock rule (`c/readout`): `m:ss` below ten minutes, `mm:ss` below an
/// hour, and hours appear only at ≥ 1 h (`h:mm:ss`) — never a phantom
/// leading `0:`.
@visibleForTesting
String readoutClock(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    final paddedMinutes = minutes.toString().padLeft(2, '0');
    return '$hours:$paddedMinutes:$seconds';
  }
  return '$minutes:$seconds';
}

/// The figure face: Inter — the owner rejected the mono face's dotted
/// zeros — with tabular numerals so the ticking clock doesn't jitter.
TextStyle _figureStyle(Color color, double fontSize, double s) => TextStyle(
  color: color,
  fontSize: fontSize * s,
  // The pen's −1% tracking on the figures.
  letterSpacing: -0.01 * fontSize * s,
  height: 1,
  leadingDistribution: TextLeadingDistribution.even,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// One labelled stage-sized figure: the pen's 36-over-180 caption/value pair.
class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.label,
    required this.value,
    required this.s,
    super.key,
  });

  final String label;
  final String value;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Caption(label, s: s),
        SizedBox(height: 4 * s),
        AppText(value, style: _figureStyle(surface.textPrimary, 180, s)),
      ],
    );
  }
}

/// A figure pair's caption: the pen's 36 at the SectionCaption tracking
/// ratio (0.07 em).
class _Caption extends StatelessWidget {
  const _Caption(this.label, {required this.s});

  final String label;
  final double s;

  @override
  Widget build(BuildContext context) {
    return AppText(
      label,
      style: TextStyle(
        color: context.surface.textMuted,
        fontSize: 36 * s,
        letterSpacing: 2.52 * s,
        height: 1,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// The BARS pair with the beat dots stacked directly beneath the figure —
/// the dots read as the subdivision of the bar. Either half stands alone:
/// no loop yet keeps the dots, no tempo grid keeps the bar count.
class _BarsAndBeats extends StatelessWidget {
  const _BarsAndBeats({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (readout.loopBars > 0)
          Column(
            key: const Key('console_readout_bars'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Caption(context.l10n.readoutBarsLabel, s: s),
              SizedBox(height: 4 * s),
              AppText(
                '${readout.loopBars}',
                style: _figureStyle(surface.textPrimary, 120, s),
              ),
            ],
          ),
        if (readout.hasTempo) ...[
          if (readout.loopBars > 0) SizedBox(height: 8 * s),
          _BeatDots(readout: readout, s: s),
        ],
      ],
    );
  }
}

/// The bar-position dots — one per beat, 44⌀, the current one lit — with
/// the count-in word before them while the click is counting a bar in.
class _BeatDots extends StatelessWidget {
  const _BeatDots({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // The pen's unlit dot is white at 18% — between the theme's border
    // tiers, with no token of its own — so it derives from the lit colour
    // (the same derivation the stage status bar uses).
    final unlit = surface.textPrimary.withValues(alpha: 0.18);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (readout.countingIn) ...[
          AppText(
            context.l10n.readoutCountIn,
            key: const Key('console_readout_count_in'),
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 36 * s,
              height: 1,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          SizedBox(width: 28 * s),
        ],
        Row(
          key: const Key('console_readout_beats'),
          mainAxisSize: MainAxisSize.min,
          spacing: 28 * s,
          children: [
            for (var beat = 0; beat < readout.tsNum; beat++)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: beat == readout.currentBeat
                      ? surface.textPrimary
                      : unlit,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(dimension: 44 * s),
              ),
          ],
        ),
      ],
    );
  }
}

/// The header's flat right column: the mode word, then the bank pair and
/// the record pill side by side beneath it — the whole cluster tucked
/// under the figures' height.
class _ModeColumn extends StatelessWidget {
  const _ModeColumn({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The FittedBox guard on the left cluster does not cover this
        // column, and the unknown-mode fallback renders a raw token from a
        // possibly-newer main window at full stage size — the exact
        // version-skew path the fallback exists to survive. Cap the word at
        // the pen's right-column width (553) and scale it down past that,
        // so a long token shrinks instead of RenderFlex-overflowing; every
        // known word sits far under the cap and renders at the drawn size.
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 553 * s),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: _ModeWord(mode: readout.mode, s: s),
          ),
        ),
        SizedBox(height: 18 * s),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BankPair(activeBank: readout.activeBank, s: s),
            SizedBox(width: 18 * s),
            _RecordPill(readout: readout, s: s),
          ],
        ),
      ],
    );
  }
}

/// The mode word — what a footswitch press does right now — bare and
/// stage-sized per the pen: red only while a press records, the primary
/// text colour otherwise.
class _ModeWord extends StatelessWidget {
  const _ModeWord({required this.mode, required this.s});

  final String mode;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    // An unknown token renders verbatim rather than guessing: a newer main
    // window paired with an older sub-window degrades to showing the raw
    // mode instead of lying about it.
    final label = switch (mode) {
      'record' => l10n.readoutModeRecord,
      'mute' => l10n.readoutModeMute,
      'fx' => l10n.readoutModeFx,
      _ => mode.toUpperCase(),
    };
    return AppText(
      label,
      key: const Key('console_readout_mode'),
      style: TextStyle(
        color: mode == 'record' ? surface.rec : surface.textPrimary,
        fontSize: 84 * s,
        // The pen draws weight 750; the bundled Inter tops out at the 700
        // cut, which is the nearest face.
        fontWeight: FontWeight.w700,
        letterSpacing: 8.4 * s,
        height: 1.21,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// The A/B bank pair: the stage status bar's bordered capsule idiom scaled
/// to the pen's 224×93, active half filled — which bank the foot is on,
/// readable from the floor.
class _BankPair extends StatelessWidget {
  const _BankPair({required this.activeBank, required this.s});

  final int activeBank;
  final double s;

  /// Two halves, like the plate's BANK light: the wire carries an index so
  /// the pair keeps rendering even if the main window grows more banks.
  static const int _banks = 2;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('console_readout_bank'),
      height: 93 * s,
      padding: EdgeInsets.all(2 * s),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24 * s),
        border: Border.all(color: surface.line, width: 2 * s),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var bank = 0; bank < _banks; bank++)
            Container(
              key: Key('console_readout_bank_$bank'),
              width: 110 * s,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bank == activeBank ? surface.control : null,
                borderRadius: BorderRadius.circular(22 * s),
              ),
              child: AppText(
                String.fromCharCode(0x41 + bank),
                style: TextStyle(
                  color: bank == activeBank
                      ? surface.textPrimary
                      : surface.textMuted,
                  fontSize: 44 * s,
                  height: 1.21,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The record light: the pen's RecPill scaled ~2.8× — dot, REC, and the
/// capture elapsed in the red outline while a capture runs; dimmed to an
/// idle outline otherwise.
class _RecordPill extends StatelessWidget {
  const _RecordPill({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final armed = readout.recordArmed;
    final color = armed ? surface.rec : surface.borderStrong;
    return Container(
      key: const Key('console_readout_record'),
      height: 88 * s,
      padding: EdgeInsets.symmetric(horizontal: 40 * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: armed ? surface.recSurface : null,
        borderRadius: BorderRadius.circular(24 * s),
        border: Border.all(color: color, width: 2 * s),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: SizedBox.square(dimension: 30 * s),
          ),
          SizedBox(width: 18 * s),
          AppText(
            context.l10n.readoutRecordLabel,
            style: TextStyle(
              color: armed ? surface.rec : surface.textMuted,
              fontSize: 40 * s,
              fontWeight: FontWeight.w700,
              letterSpacing: 3.2 * s,
              height: 1.21,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          if (armed) ...[
            SizedBox(width: 18 * s),
            AppText(
              readoutClock(readout.recordSeconds),
              key: const Key('console_readout_record_elapsed'),
              // The pen draws the elapsed untracked; tabular numerals keep
              // the ticking seconds from wobbling the pill's width.
              style: TextStyle(
                color: surface.rec,
                fontSize: 40 * s,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
