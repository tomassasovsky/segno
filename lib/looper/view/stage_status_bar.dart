import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

/// The console's status bar, drawn to `STAGE / stage`: the strip above the
/// track run carrying the session name, the mode pill, the bank pair, the
/// performance-record light, and the tempo + clock readout.
///
/// **Readouts, not controls.** The feet drive transport, so every element
/// here is a state light — the REC pill and the bank halves take no taps. The
/// one exception is the session-name block, which opens the Sessions dialog:
/// that is navigation, not transport, and the console has no other way to
/// reach it from the stage.
///
/// Self-contained (the `SessionMenu` / `PerfRecordButton` pattern): each
/// element subscribes to its own cubit slice, so a beat tick rebuilds the
/// clock and nothing else — the same rebuild discipline the track run holds
/// (#646). The widget itself is not gated on `kConsoleMode`; the host mounts
/// it console-only, which keeps it testable in a normal test run.
class StageStatusBar extends StatelessWidget {
  /// Creates a [StageStatusBar].
  const StageStatusBar({super.key});

  /// The strip's height — the pen's 40, which the session block fills and the
  /// pills centre inside.
  static const double height = 40;

  /// The gap between elements. The pen places every block 12 after the last
  /// (the FX pill is narrower than REC and its neighbours shift left with it,
  /// so the strip is a flow, not a set of columns).
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: height,
    child: Row(
      key: Key('stage_status_bar'),
      children: [
        // The pen insets the session block 2 into the strip.
        SizedBox(width: 2),
        // Flexible so a long session name gives way (ellipsized) instead of
        // pushing the readouts off the fixed panel.
        Flexible(child: _SessionBlock()),
        SizedBox(width: _gap),
        _ModePill(),
        SizedBox(width: _gap),
        _BankPair(),
        SizedBox(width: _gap),
        _RecordLight(),
        Spacer(),
        _TempoClock(),
      ],
    ),
  );
}

/// The session block: the amber session mark, the open session's name, and
/// the kebab — one tap target that opens the Sessions dialog.
///
/// The dot is the pen's session emblem (`warning` amber on every STAGE
/// screen), not a state light: the pen draws it identically across all six
/// stage states, so no fact is attached to it here.
class _SessionBlock extends StatelessWidget {
  const _SessionBlock();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return BlocBuilder<SessionCubit, SessionState>(
      buildWhen: (a, b) => a.currentSessionName != b.currentSessionName,
      builder: (context, state) {
        final name = state.currentSessionName;
        return FocusableTapTarget(
          key: const Key('stage_session_block'),
          semanticLabel: l10n.a11ySessionMenu,
          borderRadius: 10,
          onTap: () => unawaited(showSessionsManager(context)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => unawaited(showSessionsManager(context)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: surface.warning,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 6),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: AppText(
                    name ?? l10n.sessionUnsaved,
                    key: const Key('stage_session_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      // The italic is the desktop toolbar's own "no session
                      // open" mark; the pen only draws the named state.
                      fontStyle: name == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // The kebab is drawn as part of the block rather than being
                // its own button: the whole block is the tap target, and two
                // nested targets doing the same thing would announce twice.
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: surface.line),
                  ),
                  child: Icon(
                    Icons.more_vert,
                    size: 19,
                    color: surface.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The mode pill: `REC` red, `MUTE` green, `FX` blue — a readout of
/// [ControlState.mode], sharing the desktop `ModeIndicator`'s colour mapping
/// (owner call 2026-08-20: rec=red, mute=green is the product mapping; the
/// pedal plate's firmware LEDs flip to match via the #714/#693 line -- until
/// that lands the physical plate still shows the legacy rec=green/mute=amber).
/// Not tappable: the MODE
/// footswitch owns the cycle.
///
/// The pen draws the record state (`rec` outline over `recSurface`) and the
/// FX state (`accent` over the flat `accentSurface`); mute is `success` over
/// the matching `successSurface` (#693 — the owner's call from the bench),
/// since no STAGE screen draws it. Every arm reads a fill TOKEN, so the
/// high-contrast flavor lifts them together — an inline alpha here would pin
/// mute at the dark fill while REC brightened around it (#737).
class _ModePill extends StatelessWidget {
  const _ModePill();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final mode = context.select<ControlCubit, InteractionMode>(
      (cubit) => cubit.state.mode,
    );
    final (color, fill, label) = switch (mode) {
      InteractionMode.record => (
        surface.rec,
        surface.recSurface,
        l10n.interactionModeRec,
      ),
      InteractionMode.mute => (
        surface.success,
        surface.successSurface,
        l10n.interactionModeMute,
      ),
      InteractionMode.fx => (
        surface.accent,
        surface.accentSurface,
        l10n.interactionModeFx,
      ),
    };
    return Container(
      key: const Key('stage_mode_pill'),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: const SizedBox.square(dimension: 11),
          ),
          const SizedBox(width: 7),
          AppText(
            label,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.12,
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ],
      ),
    );
  }
}

/// The bank pair: a bordered A | B capsule whose active half is filled — a
/// readout of [ControlState.activeBank]. Not tappable: the BANK footswitch is
/// what changes banks, and this light exists exactly so the foot can see
/// which bank it is on.
class _BankPair extends StatelessWidget {
  const _BankPair();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final active = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    return Semantics(
      label: context.l10n.a11yStageBank(String.fromCharCode(0x41 + active)),
      child: ExcludeSemantics(
        child: Container(
          key: const Key('stage_bank_pair'),
          height: 33,
          padding: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: surface.line),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Row(
              children: [
                for (var bank = 0; bank < ControlState.bankCount; bank++)
                  Container(
                    key: Key('stage_bank_$bank'),
                    width: 38,
                    alignment: Alignment.center,
                    color: bank == active ? surface.control : null,
                    child: AppText(
                      String.fromCharCode(0x41 + bank),
                      style: TextStyle(
                        color: bank == active
                            ? surface.textPrimary
                            : surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The performance-record light: a circle holding a red dot at rest, and —
/// per `c/stage-armed` — a red stop square with the elapsed readout beside it
/// while a capture runs. A state light, not the desktop's arm button: the
/// MODE footswitch long-press owns arm/disarm on the console.
class _RecordLight extends StatelessWidget {
  const _RecordLight();

  static String _format(Duration elapsed) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<PerformanceRecorderCubit>().state;
    final armed = state is PerformanceRecorderArmed ? state : null;
    final elapsed = armed == null ? null : _format(armed.elapsed);
    return Semantics(
      label: elapsed == null
          ? l10n.a11yStageRecordIdle
          : l10n.perfArmedElapsed(elapsed),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const Key('stage_record_light'),
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: armed != null ? surface.recSurface : null,
                border: Border.all(
                  color: armed != null ? surface.rec : surface.borderStrong,
                ),
              ),
              child: armed != null
                  ? Container(width: 12, height: 12, color: surface.rec)
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.rec,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 14),
                    ),
            ),
            if (elapsed != null) ...[
              const SizedBox(width: 12),
              AppText(
                elapsed,
                key: const Key('stage_record_elapsed'),
                style: TextStyle(
                  color: surface.rec,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 14,
                  height: 1.15,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The narrow tempo slice the readout renders. A record, so
/// `context.select` compares it structurally and a per-poll engine tick
/// rebuilds nothing until a drawn fact actually changes.
typedef _TempoState = ({
  double bpm,
  bool hasTempo,
  int tsNum,
  int currentBeat,
  bool countingIn,
});

/// The strip's trailing readout: the count-in word when one is running, the
/// beat dots, the tempo, and the transport clock — the pen's
/// `count-in  ····  120.0 bpm  0:00:11` group, in the mono face.
///
/// The tempo and the dots vanish on the tempo-free path
/// (`TempoSource.none`), exactly as the desktop readout does: the pen always
/// draws a tempo, but drawing `0.0 bpm` over a grid that does not exist would
/// state a wrong fact.
///
/// The clock is [TransportClockCubit]'s **elapsed transport time** — wall
/// time while anything records or plays, holding across a stop and resetting
/// only when the rig empties (#678). Whole seconds in the state, so the
/// select slice fires once per displayed second.
class _TempoClock extends StatelessWidget {
  const _TempoClock();

  static String _format(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final clock = context.select<LooperBloc, _TempoState>((bloc) {
      final transport = bloc.state.transport;
      return (
        bpm: transport.tempoBpm,
        hasTempo: transport.tempoSource != TempoSource.none,
        tsNum: transport.tsNum,
        currentBeat: transport.currentBeat,
        countingIn: transport.countingIn,
      );
    });
    final elapsedSeconds = context.select<TransportClockCubit, int>(
      (cubit) => cubit.state.elapsed.inSeconds,
    );
    // The pen's unlit beat dot is white at 18% — between the theme's border
    // tiers, with no token of its own — so it is derived from the lit dot's
    // colour rather than hardcoded.
    final unlitDot = surface.textPrimary.withValues(alpha: 0.18);
    final mono = TextStyle(
      color: surface.textSecondary,
      fontFamily: SurfaceTheme.monoFont,
      fontSize: 16,
      height: 1.2,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Row(
      key: const Key('stage_tempo_clock'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (clock.hasTempo) ...[
          if (clock.countingIn) ...[
            AppText(
              l10n.stageCountIn,
              key: const Key('stage_count_in'),
              style: mono,
            ),
            const SizedBox(width: 10),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 5,
            children: [
              for (var beat = 0; beat < clock.tsNum; beat++)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: beat == clock.currentBeat
                        ? surface.textPrimary
                        : unlitDot,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 7),
                ),
            ],
          ),
          const SizedBox(width: 10),
          AppText(
            l10n.stageTempoBpm(clock.bpm.toStringAsFixed(1)),
            key: const Key('stage_tempo_bpm'),
            style: mono,
          ),
          const SizedBox(width: 10),
        ],
        AppText(
          _format(elapsedSeconds),
          key: const Key('stage_clock'),
          style: mono,
        ),
      ],
    );
  }
}
