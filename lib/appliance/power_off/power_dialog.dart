import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Navigator name for the Power options / refuse / save-failed dialog. The
/// host pops by name so a sheet sitting on top can be dismissed in the same
/// turn.
const String powerDialogRoute = 'power_dialog';

/// Navigator name for the Save As sheet opened by a restart or shutdown.
const String powerSaveAsRoute = 'power_save_as';

/// Opens the power dialog on the root navigator. Scrim tap returns false
/// (Cancel). Committed phases must not call this.
Future<bool?> showPowerDialog(
  BuildContext context, {
  required PowerSnapshot Function() snapshot,
  required Future<void> Function() save,
  String? stagedUpdate,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: context.surface.scrim,
    routeSettings: const RouteSettings(name: powerDialogRoute),
    builder: (dialogContext) => BlocProvider<PowerCubit>.value(
      value: context.read<PowerCubit>(),
      child: PowerDialog(
        snapshot: snapshot,
        save: save,
        stagedUpdate: stagedUpdate,
      ),
    ),
  );
}

/// Power options (pen 32), the take refusal and "Segno is staying on", in
/// the console dialog language.
class PowerDialog extends StatelessWidget {
  /// Creates a [PowerDialog].
  const PowerDialog({
    required this.snapshot,
    required this.save,
    this.stagedUpdate,
    super.key,
  });

  /// Fresh gate input at every commit.
  final PowerSnapshot Function() snapshot;

  /// Writes the open named session.
  final Future<void> Function() save;

  /// The staged update's version, which installs during a restart; null
  /// when nothing is staged.
  final String? stagedUpdate;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return BlocBuilder<PowerCubit, PowerState>(
      builder: (context, state) {
        final cubit = context.read<PowerCubit>();
        final Widget body;
        switch (state.phase) {
          case PowerPhase.refuse:
            body = _PowerBody(
              title: l10n.powerRefuseTitle,
              titleColor: surface.warning,
              lines: [l10n.powerRefuseBody],
              actions: [
                ConsoleDialogButton(
                  key: const Key('power_keep_playing'),
                  label: l10n.powerKeepPlaying,
                  tone: ConsoleDialogTone.warning,
                  onPressed: cubit.dismiss,
                ),
              ],
            );
          case PowerPhase.saveFailed:
            body = _PowerBody(
              title: l10n.powerSaveFailedTitle,
              lines: [l10n.powerSaveFailedBody],
              actions: [
                ConsoleDialogButton(
                  key: const Key('power_stay_on'),
                  label: l10n.powerStayOn,
                  onPressed: cubit.dismiss,
                ),
                ConsoleDialogButton(
                  key: const Key('power_retry'),
                  label: l10n.powerRetry,
                  tone: ConsoleDialogTone.accent,
                  onPressed: () => cubit.retry(snapshot()),
                ),
              ],
            );
          case PowerPhase.idle:
          case PowerPhase.options:
          case PowerPhase.saveAs:
          case PowerPhase.saving:
          case PowerPhase.goodbye:
            final name = snapshot().currentSessionName;
            body = _PowerBody(
              title: l10n.powerOptionsTitle,
              lines: [
                l10n.powerOptionsBody,
                name ?? l10n.powerSessionUnnamed,
                if (stagedUpdate case final version?)
                  l10n.powerStagedUpdate(version),
              ],
              actions: [
                ConsoleDialogButton(
                  key: const Key('power_cancel'),
                  label: l10n.powerCancel,
                  onPressed: cubit.dismiss,
                ),
                ConsoleDialogButton(
                  key: const Key('power_restart'),
                  label: l10n.powerRestart,
                  onPressed: () => cubit.restart(snapshot(), save: save),
                ),
                ConsoleDialogButton(
                  key: const Key('power_shut_down'),
                  label: l10n.powerShutDown,
                  tone: ConsoleDialogTone.accent,
                  onPressed: () => cubit.shutDown(snapshot(), save: save),
                ),
              ],
            );
        }
        return IgnorePointer(
          ignoring: !state.isDismissible,
          child: Center(
            child: ConsoleDialogShell(
              key: const Key('power_dialog'),
              child: body,
            ),
          ),
        );
      },
    );
  }
}

/// Title, prose lines and a right-aligned button row.
class _PowerBody extends StatelessWidget {
  const _PowerBody({
    required this.title,
    required this.lines,
    required this.actions,
    this.titleColor,
  });

  final String title;
  final Color? titleColor;
  final List<String> lines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          title,
          style: TextStyle(
            color: titleColor ?? surface.textPrimary,
            fontSize: 19,
            height: 1.15,
            fontWeight: FontWeight.w600,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        for (final line in lines) ...[
          const SizedBox(height: 10),
          AppText(
            line,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 16,
              height: 1.4,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ],
        const SizedBox(height: 19),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 10,
          children: actions,
        ),
      ],
    );
  }
}
