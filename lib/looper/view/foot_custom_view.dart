import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_custom.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/theme/theme.dart';

/// The notice for a refused assigned [action]. An action this build cannot
/// run is named by its saved key, so the notice does not say "unavailable"
/// twice.
String assignedActionRefusedText(
  AppLocalizations l10n,
  List<String> trackNames,
  ControlAction action,
) => l10n.assignedActionRefused(switch (action) {
  UnavailableAction(:final key) => key,
  _ => controlActionLabel(l10n, trackNames, action),
});

/// The Custom performance surface: each switch names what the performer
/// assigned to it for the bank in view, and lights exactly what the switch
/// LEDs light. Driven by the shared Control owner.
class FootCustomView extends StatelessWidget {
  /// Creates the surface within the real Tracks hierarchy.
  const FootCustomView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final projection = context.select<ControlCubit, FootCustomProjection>(
      (cubit) => projectFootCustom(cubit.state),
    );
    final l10n = context.l10n;
    final surface = context.surface;

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
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_custom_view'),
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
                  key: const Key('foot_custom_exit'),
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
                const _RecordingPill(),
                const SizedBox(width: 24),
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
                  onPressed: () => unawaited(openSegnoSettings()),
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
                          l10n.actionModeCustom,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootCustomPedal(
                          pedal: projection[PedalButton.clear],
                          bank: projection.bank,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootCustomPedal(
                          pedal: projection[PedalButton.bank],
                          bank: projection.bank,
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
                              SizedBox(
                                width: 180,
                                child: _FootCustomPedal(
                                  pedal: projection[button],
                                  bank: projection.bank,
                                ),
                              ),
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

/// The elapsed time of a running performance recording, as the stage top
/// bar shows it; nothing while none runs.
class _RecordingPill extends StatelessWidget {
  const _RecordingPill();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PerformanceRecorderCubit>().state;
    if (state is! PerformanceRecorderArmed) return const SizedBox.shrink();
    final surface = context.surface;
    final minutes = state.elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (state.elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final elapsed = '$minutes:$seconds';
    return Semantics(
      label: context.l10n.perfArmedElapsed(elapsed),
      child: ExcludeSemantics(
        child: Container(
          key: const Key('foot_custom_recording'),
          height: 48,
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: surface.cardHigh,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 12, height: 12, color: surface.rec),
              const SizedBox(width: 12),
              AppText(
                elapsed,
                style: const TextStyle(
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FootCustomPedal extends StatelessWidget {
  const _FootCustomPedal({required this.pedal, required this.bank});

  final FootCustomPedal pedal;
  final int bank;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final names = context.select<TracksCubit, List<String>>(
      (cubit) => cubit.state.names,
    );
    final armed = context.select<PerformanceRecorderCubit, bool>(
      (cubit) => cubit.state is PerformanceRecorderArmed,
    );
    final l10n = context.l10n;
    final button = pedal.button;
    // A switch assigned Record performance offers to stop the recording it
    // started (pen 20/03).
    String label(ControlAction action) =>
        armed && action == const CommandAction(ControlCommand.recordPerformance)
        ? l10n.footCustomStopRecording
        : controlActionLabel(l10n, names, action);
    final slot = switch (button) {
      PedalButton.track1 => 0,
      PedalButton.track2 => 1,
      PedalButton.track3 => 2,
      PedalButton.track4 => 3,
      _ => null,
    };
    final press = pedal.press;
    final hold = pedal.hold;
    final title = switch (pedal.role) {
      FootCustomRole.exit => l10n.actionModeExit,
      FootCustomRole.nextBank => l10n.footFadeBank(bank == 0 ? 'A' : 'B'),
      FootCustomRole.assignment when press != null => label(press),
      // No Press: the switch reads its hardware name.
      FootCustomRole.assignment => switch (button) {
        PedalButton.recPlay => l10n.actionRecordPlay,
        PedalButton.stop => l10n.actionStop,
        PedalButton.undo => l10n.actionUndo,
        PedalButton.clear => l10n.actionOperationClear,
        _ => l10n.controlTrackSwitchName(bank * 4 + slot! + 1),
      },
    };
    final hint = switch (pedal.role) {
      FootCustomRole.nextBank => l10n.footPeelSwitchBank,
      FootCustomRole.assignment when hold != null => l10n.footCustomHold(
        label(hold),
      ),
      _ => '',
    };
    return PerformancePedal(
      keyPrefix: 'foot_custom_pedal',
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${slot! + 1}',
      },
      title: title,
      detail: '',
      hint: hint,
      titleMuted: pedal.unavailable,
      titleMaxLines: 2,
      enabled: pedal.enabled,
      selected: pedal.lit,
      onPressed: control.footCustomPressed,
      onReleased: control.footCustomReleased,
      onCancelled: control.footCustomCancelled,
      onActivate: () => control.activateFootCustomPedal(button),
      onHold: hold == null
          ? null
          : () => control.activateFootCustomPedal(button, hold: true),
    );
  }
}
