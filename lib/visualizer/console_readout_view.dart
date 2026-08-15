import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// The console's 7" second screen, drawn to the pen's `STAGE / readout`:
/// glance facts in stage-sized type — tempo dominant, bars, the transport
/// clock, the beat dots, the mode word, the record light — over the
/// whole-loop output waveform with its moving playhead.
///
/// **Owner-directed revision of the drawn screen (#695):** the pen's readout
/// draws a per-track grid (name + state word per column); at two metres those
/// words are noise the main screen already carries, so this view renders NO
/// track-level content and reflows the freed area into the waveform strip.
/// The pen still governs everything else: the type scale, the weights, the
/// letter-spacing, the colours, and the header's arrangement are the drawn
/// ones.
///
/// **Proportional, not absolute.** The pen draws the screen at 1920×1080, but
/// the device window's logical size depends on the compositor scale (640×360
/// today at scale=3). Every dimension here is the pen's figure times the
/// limiting-axis scale against that reference, so the layout is the pen's at
/// any logical size — the pen's proportions are the contract, not its pixels.
class ConsoleReadoutView extends StatelessWidget {
  /// Creates a [ConsoleReadoutView].
  const ConsoleReadoutView({
    required this.readout,
    required this.waveform,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// The whole-loop waveform region, injected so this widget stays pure
  /// presentation (the window wires the frame stream into it).
  final Widget waveform;

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
        final surface = context.surface;
        return Padding(
          // The pen insets the whole screen 29 and separates header from
          // body by 22.
          padding: EdgeInsets.all(29 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The pen's 96-tall header, sized by its own type (14-over-77
              // plus the caption gap) rather than a fixed box: real font
              // metrics run fractions of a pixel past the drawn figure, and
              // a clipped descender is a worse fidelity loss than one.
              _ReadoutHeader(readout, s),
              SizedBox(height: 22 * s),
              // The area the pen's track grid occupied, reflowed wholesale
              // into the loop strip: full width, the pen's cell border.
              Expanded(
                child: DecoratedBox(
                  key: const Key('console_readout_waveform'),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14 * s),
                    border: Border.all(color: surface.line),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14 * s),
                    child: Padding(
                      padding: EdgeInsets.all(18 * s),
                      child: waveform,
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

/// The header row: TEMPO, BARS, TIME, the beat dots (with the count-in word
/// while one sounds), then the mode word and the record light on the right —
/// the pen's header with the stage bar's two right-side facts drawn in the
/// pen's REC-block idiom.
class _ReadoutHeader extends StatelessWidget {
  const _ReadoutHeader(this.readout, this.s);

  final PerformanceReadout readout;
  final double s;

  static String _clock(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tempo = readout.tempoBpm > 0
        ? readout.tempoBpm.toStringAsFixed(readout.tempoBpm % 1 == 0 ? 0 : 1)
        : '--';
    return Row(
      children: [
        // The figures-and-dots cluster takes whatever the pills leave and
        // scales DOWN only when it does not fit: in the pen's nominal case
        // the FittedBox is a no-op and every dimension stays the drawn one,
        // but a worst case the pen never draws (a long localized count-in
        // word, a high-numerator signature's fifteen dots, an hour-plus
        // clock, all at once) shrinks the cluster gracefully instead of
        // clipping the mode word and the record light off the panel.
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BigStat(
                  key: const Key('console_readout_tempo'),
                  label: l10n.readoutTempoLabel,
                  value: tempo,
                  s: s,
                ),
                SizedBox(width: 48 * s),
                if (readout.loopBars > 0) ...[
                  _BigStat(
                    key: const Key('console_readout_bars'),
                    label: l10n.readoutBarsLabel,
                    value: '${readout.loopBars}',
                    s: s,
                  ),
                  SizedBox(width: 48 * s),
                ],
                _BigStat(
                  key: const Key('console_readout_clock'),
                  label: l10n.readoutClockLabel,
                  value: _clock(readout.elapsedSeconds),
                  s: s,
                ),
                if (readout.hasTempo) ...[
                  SizedBox(width: 48 * s),
                  _BeatDots(readout: readout, s: s),
                ],
              ],
            ),
          ),
        ),
        SizedBox(width: 48 * s),
        _ModeWord(mode: readout.mode, s: s),
        SizedBox(width: 22 * s),
        _RecordLight(readout: readout, s: s),
      ],
    );
  }
}

/// One labelled stage-sized figure: the pen's 14-over-77 caption/value pair
/// in the mono face.
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
        AppText(
          label,
          style: TextStyle(
            color: surface.textMuted,
            fontSize: 14 * s,
            letterSpacing: 1.68 * s,
            height: 1.2,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        SizedBox(height: 5 * s),
        AppText(
          value,
          style: TextStyle(
            color: surface.textPrimary,
            fontFamily: SurfaceTheme.monoFont,
            fontSize: 77 * s,
            letterSpacing: -1.54 * s,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ],
    );
  }
}

/// The bar-position dots — one per beat, the current one lit — with the
/// count-in word before them while the click is counting a bar in.
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
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 29 * s,
              height: 1,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          SizedBox(width: 22 * s),
        ],
        Row(
          key: const Key('console_readout_beats'),
          mainAxisSize: MainAxisSize.min,
          spacing: 12 * s,
          children: [
            for (var beat = 0; beat < readout.tsNum; beat++)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: beat == readout.currentBeat
                      ? surface.textPrimary
                      : unlit,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(dimension: 19 * s),
              ),
          ],
        ),
      ],
    );
  }
}

/// The mode word — what a footswitch press does right now — in the pen's
/// REC-block idiom (bordered, stage-sized) with the stage status bar's
/// colour mapping, so the plate and both screens never disagree.
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
    final (color, fill, label) = switch (mode) {
      'record' => (surface.rec, surface.recSurface, l10n.readoutModeRecord),
      'mute' => (
        Theme.of(context).colorScheme.primary,
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
        l10n.readoutModeMute,
      ),
      'fx' => (surface.accent, surface.accentSurface, l10n.readoutModeFx),
      _ => (surface.textSecondary, null, mode.toUpperCase()),
    };
    return _HeaderPill(
      key: const Key('console_readout_mode'),
      color: color,
      fill: fill,
      s: s,
      child: _HeaderPill.word(label, color, s),
    );
  }
}

/// The record light: the pen's outlined REC block, lit red with the armed
/// elapsed beside the word while a capture runs, dimmed to an idle outline
/// otherwise — the stage status bar's record light at readout scale.
class _RecordLight extends StatelessWidget {
  const _RecordLight({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  static String _format(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final armed = readout.recordArmed;
    final color = armed ? surface.rec : surface.borderStrong;
    return _HeaderPill(
      key: const Key('console_readout_record'),
      color: color,
      fill: armed ? surface.recSurface : null,
      s: s,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeaderPill.word(
            context.l10n.readoutRecordLabel,
            armed ? surface.rec : surface.textMuted,
            s,
          ),
          if (armed) ...[
            SizedBox(width: 18 * s),
            AppText(
              _format(readout.recordSeconds),
              key: const Key('console_readout_record_elapsed'),
              style: TextStyle(
                color: surface.rec,
                fontFamily: SurfaceTheme.monoFont,
                fontSize: 29 * s,
                height: 1,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The pen's REC-block shell: a 62-tall outline, radius 12, stroke 2,
/// holding one stage-sized word — shared by the mode word and the record
/// light so the header's right side reads as one family.
class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.color,
    required this.fill,
    required this.s,
    required this.child,
    super.key,
  });

  final Color color;
  final Color? fill;
  final double s;
  final Widget child;

  /// The pill's word in the pen's face: Inter-weight 29 at +10% tracking.
  static Widget word(String label, Color color, double s) => AppText(
    label,
    style: TextStyle(
      color: color,
      fontSize: 29 * s,
      fontWeight: FontWeight.w700,
      letterSpacing: 2.9 * s,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62 * s,
      padding: EdgeInsets.symmetric(horizontal: 26 * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12 * s),
        border: Border.all(color: color, width: 2 * s),
      ),
      child: child,
    );
  }
}
