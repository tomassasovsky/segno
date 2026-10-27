import 'dart:async';

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
  List<Stream<Object?>> changes = const [],
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
        changes: changes,
      ),
    ),
  );
}

/// Power options (pen 32), the take, update and transfer refusals and
/// "Segno is staying on", in the console dialog language.
class PowerDialog extends StatelessWidget {
  /// Creates a [PowerDialog].
  const PowerDialog({
    required this.snapshot,
    required this.save,
    this.stagedUpdate,
    this.changes = const [],
    super.key,
  });

  /// Fresh gate input at every commit.
  final PowerSnapshot Function() snapshot;

  /// Writes the open named session.
  final Future<void> Function() save;

  /// The staged update's version, which installs during a restart; null
  /// when nothing is staged.
  final String? stagedUpdate;

  /// Changes to what [snapshot] reads (the looper, the backing). Each event
  /// rebuilds the dialog so its lines follow the rig while it is open: the
  /// empty-session line must not outlive a take that just finished.
  final List<Stream<Object?>> changes;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return _RebuildOn(
      changes: changes,
      builder: (context) => BlocBuilder<PowerCubit, PowerState>(
        builder: (context, state) {
          final cubit = context.read<PowerCubit>();
          final Widget body;
          switch (state.phase) {
            case PowerPhase.refuse:
              final (title, line) = switch (state.refusal) {
                PowerRefusal.update => (
                  l10n.powerUpdateTitle,
                  l10n.powerUpdateBody,
                ),
                PowerRefusal.transfer => (
                  l10n.powerTransferTitle,
                  l10n.powerTransferBody,
                ),
                PowerRefusal.take || null => (
                  l10n.powerRefuseTitle,
                  l10n.powerRefuseBody,
                ),
              };
              body = _PowerBody(
                title: title,
                titleColor: surface.warning,
                lines: [line],
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
                    onPressed: () => cubit.retry(snapshot(), save: save),
                  ),
                ],
              );
            case PowerPhase.idle:
            case PowerPhase.options:
            case PowerPhase.saveAs:
            case PowerPhase.saving:
            case PowerPhase.goodbye:
              final reading = snapshot();
              final name = reading.currentSessionName;
              // An unnamed session with nothing in it is not saved, so the
              // save promise and the naming line would both be untrue.
              final empty = name == null && !reading.sessionHasContent;
              body = _PowerBody(
                title: l10n.powerOptionsTitle,
                lines: [
                  if (empty)
                    l10n.powerOptionsBodyEmpty
                  else ...[
                    l10n.powerOptionsBody,
                    name ?? l10n.powerSessionUnnamed,
                  ],
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
      ),
    );
  }
}

/// Calls [builder] again on every event of [changes].
class _RebuildOn extends StatefulWidget {
  const _RebuildOn({required this.changes, required this.builder});

  final List<Stream<Object?>> changes;
  final WidgetBuilder builder;

  @override
  State<_RebuildOn> createState() => _RebuildOnState();
}

class _RebuildOnState extends State<_RebuildOn> {
  final _subscriptions = <StreamSubscription<Object?>>[];

  @override
  void initState() {
    super.initState();
    for (final stream in widget.changes) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
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
