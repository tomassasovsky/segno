import 'dart:math' show ln10, log;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';
import 'package:segno/looper/view/track_column.dart' show ShrinkToWidth;
import 'package:segno/looper/view/track_meters.dart' show kClipPeak;
import 'package:segno/theme/theme.dart';

/// The session strip under the track run (the accepted stage): tempo and time
/// signature, the elapsed transport time, the output level with its clip
/// warning, and the loop mode. Readouts only, each subscribed to its own
/// slice so a level tick redraws one figure and a beat nothing at all.
class StageFooter extends StatelessWidget {
  /// Creates a [StageFooter].
  const StageFooter({super.key});

  /// The strip's inset from the screen edges — the pen's 54.
  static const double sideInset = 54;

  @override
  Widget build(BuildContext context) => Padding(
    // The pen's 22 above the readouts; the run's own inset holds the strip
    // off the columns.
    padding: const EdgeInsets.fromLTRB(sideInset, 22, sideInset, 0),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      // Spread at the pen's width; scaled down as one strip in a narrower
      // desktop window.
      child: const ShrinkToWidth(
        child: Row(
          key: Key('stage_footer'),
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _TempoBlock(),
            _ElapsedClock(),
            _OutputLevel(),
            _LoopModePill(),
          ],
        ),
      ),
    ),
  );
}

/// The tempo slice the strip renders. A record, so `context.select` compares
/// it structurally and a per-poll engine tick rebuilds nothing until a drawn
/// fact changes.
typedef _TempoFacts = ({
  double bpm,
  bool hasTempo,
  int tsNum,
  int tsDen,
  int countInBeatsLeft,
});

/// `84.0 BPM  4/4`, or `84.0 BPM  Count-in · 3` while a count-in runs. The
/// bpm figure reads `—` on the tempo-free path (`TempoSource.none`): drawing
/// `0.0` over a grid that does not exist would state a wrong fact.
class _TempoBlock extends StatelessWidget {
  const _TempoBlock();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tempo = context.select<LooperBloc, _TempoFacts>((bloc) {
      final transport = bloc.state.transport;
      return (
        bpm: transport.tempoBpm,
        hasTempo: transport.tempoSource != TempoSource.none,
        tsNum: transport.tsNum,
        tsDen: transport.tsDen,
        countInBeatsLeft: transport.countingIn ? transport.countInBeatsLeft : 0,
      );
    });
    final bpm = tempo.hasTempo ? tempo.bpm.toStringAsFixed(1) : '—';
    // A count-in replaces the signature for its beats: the one moment the
    // footer's tempo block says something the performer must act on.
    final signature = tempo.countInBeatsLeft > 0
        ? l10n.stageCountIn(tempo.countInBeatsLeft)
        : '${tempo.tsNum}/${tempo.tsDen}';
    final secondary = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textSecondary,
      fontSize: 24,
      height: 1,
    );
    return Semantics(
      label: l10n.a11yStageTempo(bpm, signature),
      child: ExcludeSemantics(
        child: Row(
          key: const Key('stage_footer_tempo'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            AppText(
              bpm,
              key: const Key('stage_footer_bpm'),
              style: TextStyle(
                fontFamily: SurfaceTheme.displayFont,
                color: surface.textPrimary,
                fontSize: 32,
                height: 1,
              ),
            ),
            const SizedBox(width: 6),
            AppText(l10n.stageBpmUnit, style: secondary),
            const SizedBox(width: 22),
            AppText(
              signature,
              key: const Key('stage_footer_signature'),
              style: secondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// `00:01:23` — [TransportClockCubit]'s elapsed transport time: wall time
/// while anything records or plays, holding across a stop and resetting only
/// when the rig empties (#678). Whole seconds in the state, so the select
/// slice fires once per displayed second.
class _ElapsedClock extends StatelessWidget {
  const _ElapsedClock();

  static String format(int totalSeconds) {
    final hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final elapsed = context.select<TransportClockCubit, int>(
      (cubit) => cubit.state.elapsed.inSeconds,
    );
    final time = format(elapsed);
    return Semantics(
      label: context.l10n.a11yStageElapsed(time),
      child: ExcludeSemantics(
        child: AppText(
          time,
          key: const Key('stage_footer_clock'),
          style: TextStyle(
            fontFamily: SurfaceTheme.monoFont,
            color: surface.textPrimary,
            fontSize: 28,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The output reading the strip renders: the master-bus peak in tenths of a
/// dB, or `null` for silence — quantised so a level tick that does not move
/// the displayed figure rebuilds nothing.
typedef _OutputReading = ({int? tenths, bool clip});

/// `OUT -3.8 dBFS`, or `OUT CLIP` in red — the master bus after summing,
/// because a sum can clip when no single track does.
class _OutputLevel extends StatelessWidget {
  const _OutputLevel();

  static _OutputReading readingOf(double peak) {
    if (peak <= 0) return (tenths: null, clip: false);
    if (peak >= kClipPeak) return (tenths: 0, clip: true);
    final db = 20 * log(peak) / ln10;
    return (tenths: (db * 10).round(), clip: false);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final reading = context.select<LooperBloc, _OutputReading>(
      (bloc) => readingOf(bloc.state.transport.outputPeak),
    );
    final tenths = reading.tenths;
    final db = tenths == null ? '−∞' : (tenths / 10).toStringAsFixed(1);
    return Semantics(
      label: reading.clip
          ? l10n.a11yStageOutputClip
          : l10n.a11yStageOutputLevel(db),
      child: ExcludeSemantics(
        child: AppText(
          reading.clip ? l10n.stageOutputClip : l10n.stageOutputLevel(db),
          key: const Key('stage_footer_output'),
          style: TextStyle(
            fontFamily: SurfaceTheme.monoFont,
            color: reading.clip ? surface.rec : surface.textSecondary,
            fontSize: 20,
            fontWeight: reading.clip ? FontWeight.w700 : FontWeight.w400,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The loop mode in its bordered pill: `MULTI`, `SYNC`, `BAND`, `SONG`,
/// `FREE`.
class _LoopModePill extends StatelessWidget {
  const _LoopModePill();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final mode = context.select<LooperBloc, LooperMode>(
      (bloc) => bloc.state.transport.looperMode,
    );
    final label = switch (mode) {
      LooperMode.multi => l10n.looperModeMultiLabel,
      LooperMode.sync => l10n.looperModeSyncLabel,
      LooperMode.song => l10n.looperModeSongLabel,
      LooperMode.band => l10n.looperModeBandLabel,
      LooperMode.free => l10n.looperModeFreeLabel,
    };
    return Semantics(
      label: l10n.a11yStageLoopMode(label),
      child: ExcludeSemantics(
        child: Container(
          key: const Key('stage_footer_mode'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: surface.line),
          ),
          child: AppText(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textSecondary,
              fontSize: 22,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
