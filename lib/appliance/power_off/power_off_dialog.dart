import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Opens the power-off confirm on the root navigator. Scrim tap returns
/// false (Keep playing). Committed phases must not call this.
Future<bool?> showPowerOffDialog(
  BuildContext context, {
  required PowerOffSnapshot Function() snapshot,
  Future<void> Function()? onSave,
}) {
  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierColor: context.surface.scrim,
    builder: (dialogContext) => BlocProvider<PowerOffCubit>.value(
      value: context.read<PowerOffCubit>(),
      child: PowerOffDialog(
        snapshot: snapshot,
        onSave: onSave,
      ),
    ),
  );
}

/// Refuse / three-choice / save-failed surface in the console dialog language.
class PowerOffDialog extends StatelessWidget {
  /// Creates a [PowerOffDialog].
  const PowerOffDialog({
    required this.snapshot,
    this.onSave,
    super.key,
  });

  /// Fresh gate input at every commit.
  final PowerOffSnapshot Function() snapshot;

  /// Writes the open named session. Null when the cubit should emit Save As.
  final Future<void> Function()? onSave;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PowerOffCubit, PowerOffState>(
      builder: (context, state) {
        final refuse =
            state.phase == PowerOffPhase.refuse ||
            (state.phase == PowerOffPhase.saveFailed &&
                snapshot().takeInFlight);
        return Center(
          child: ConsoleDialogShell(
            key: const Key('power_off_dialog'),
            child: refuse
                ? _RefuseBody(onKeepPlaying: () => _keepPlaying(context))
                : _ConfirmBody(
                    failed: state.phase == PowerOffPhase.saveFailed,
                    onKeepPlaying: () => _keepPlaying(context),
                    onSave: () => context.read<PowerOffCubit>().saveAndPowerOff(
                      snapshot(),
                      save: onSave,
                    ),
                    onDiscard: () => context
                        .read<PowerOffCubit>()
                        .powerOffWithoutSaving(snapshot()),
                  ),
          ),
        );
      },
    );
  }

  void _keepPlaying(BuildContext context) {
    context.read<PowerOffCubit>().keepPlaying();
  }
}

class _RefuseBody extends StatelessWidget {
  const _RefuseBody({required this.onKeepPlaying});

  final VoidCallback onKeepPlaying;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          l10n.powerOffRefuseTitle,
          style: TextStyle(
            color: surface.warning,
            fontSize: 19,
            height: 1.15,
            fontWeight: FontWeight.w600,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 10),
        AppText(
          l10n.powerOffRefuseBody,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 16,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 19),
        Align(
          alignment: Alignment.centerRight,
          child: ConsoleDialogButton(
            key: const Key('power_off_keep_playing'),
            label: l10n.powerOffKeepPlaying,
            tone: ConsoleDialogTone.warning,
            onPressed: onKeepPlaying,
          ),
        ),
      ],
    );
  }
}

class _ConfirmBody extends StatelessWidget {
  const _ConfirmBody({
    required this.failed,
    required this.onKeepPlaying,
    required this.onSave,
    required this.onDiscard,
  });

  final bool failed;
  final VoidCallback onKeepPlaying;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          failed ? l10n.powerOffSaveFailedTitle : l10n.powerOffConfirmTitle,
          style: TextStyle(
            color: surface.textPrimary,
            fontSize: 19,
            height: 1.15,
            fontWeight: FontWeight.w600,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 10),
        AppText(
          failed ? l10n.powerOffSaveFailedBody : l10n.powerOffConfirmBody,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 16,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 19),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 10,
          children: [
            ConsoleDialogButton(
              key: const Key('power_off_keep_playing'),
              label: l10n.powerOffKeepPlaying,
              onPressed: onKeepPlaying,
            ),
            ConsoleDialogButton(
              key: const Key('power_off_save'),
              label: l10n.powerOffSaveAndPowerOff,
              tone: ConsoleDialogTone.accent,
              onPressed: onSave,
            ),
            ConsoleDialogButton(
              key: const Key('power_off_discard'),
              label: l10n.powerOffWithoutSaving,
              tone: ConsoleDialogTone.destructive,
              onPressed: onDiscard,
            ),
          ],
        ),
      ],
    );
  }
}
