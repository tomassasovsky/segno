import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
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
/// "Segno is staying on", in the power panel: a 760 px panel anchored
/// bottom-centre over the dimmed screen, which replaced the centred dialog
/// (owner, #1543).
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
                warning: true,
                body: line,
                actions: [
                  const Spacer(),
                  Expanded(
                    child: PowerPanelButton(
                      key: const Key('power_keep_playing'),
                      label: l10n.powerKeepPlaying,
                      tone: PowerPanelTone.warning,
                      onPressed: cubit.dismiss,
                    ),
                  ),
                ],
              );
            case PowerPhase.saveFailed:
              body = _PowerBody(
                title: l10n.powerSaveFailedTitle,
                warning: true,
                body: l10n.powerSaveFailedBody,
                actions: [
                  Expanded(
                    child: PowerPanelButton(
                      key: const Key('power_stay_on'),
                      label: l10n.powerStayOn,
                      onPressed: cubit.dismiss,
                    ),
                  ),
                  Expanded(
                    child: PowerPanelButton(
                      key: const Key('power_retry'),
                      label: l10n.powerRetry,
                      tone: PowerPanelTone.accent,
                      onPressed: () => cubit.retry(snapshot(), save: save),
                    ),
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
              body = _PowerBody(
                title: l10n.powerOptionsTitle,
                body: name != null
                    ? l10n.powerOptionsBodyNamed(name)
                    // An unnamed session with nothing in it is not saved, so
                    // the save promise and the naming line would be untrue.
                    : reading.sessionHasContent
                    ? l10n.powerOptionsBodyUnnamed
                    : l10n.powerOptionsBodyEmpty,
                note: stagedUpdate == null
                    ? null
                    : l10n.powerStagedUpdate(stagedUpdate!),
                actions: [
                  Expanded(
                    flex: 196,
                    child: PowerPanelButton(
                      key: const Key('power_cancel'),
                      label: l10n.powerCancel,
                      onPressed: cubit.dismiss,
                    ),
                  ),
                  Expanded(
                    flex: 216,
                    child: PowerPanelButton(
                      key: const Key('power_restart'),
                      label: l10n.powerRestart,
                      icon: Icons.restart_alt,
                      onPressed: () => cubit.restart(snapshot(), save: save),
                    ),
                  ),
                  Expanded(
                    flex: 248,
                    child: PowerPanelButton(
                      key: const Key('power_shut_down'),
                      label: l10n.powerShutDown,
                      icon: Icons.power_settings_new,
                      tone: PowerPanelTone.accent,
                      onPressed: () => cubit.shutDown(snapshot(), save: save),
                    ),
                  ),
                ],
              );
          }
          return IgnorePointer(
            ignoring: !state.isDismissible,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _PowerPanel(child: body),
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

/// The panel: 760 wide, 48 above the bottom edge, on the surface tone with
/// a line border.
class _PowerPanel extends StatelessWidget {
  const _PowerPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            key: const Key('power_dialog'),
            padding: const EdgeInsets.fromLTRB(36, 32, 36, 32),
            decoration: BoxDecoration(
              color: surface.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: surface.line),
            ),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
  }
}

/// Title, body, an optional small note and the button row. A [warning]
/// title wears the warning colour and an alert icon.
class _PowerBody extends StatelessWidget {
  const _PowerBody({
    required this.title,
    required this.body,
    required this.actions,
    this.note,
    this.warning = false,
  });

  final String title;
  final String body;
  final String? note;
  final bool warning;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final titleColor = warning ? surface.warning : surface.textPrimary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (warning) ...[
              Icon(Icons.error_outline, size: 32, color: titleColor),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: AppText(
                title,
                style: TextStyle(
                  color: titleColor,
                  fontSize: 32,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AppText(
          body,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 21,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        if (note case final note?) ...[
          const SizedBox(height: 8),
          AppText(
            note,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 18,
              height: 1.4,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ],
        const SizedBox(height: 28),
        Row(spacing: context.spacing.lg, children: actions),
      ],
    );
  }
}

/// What a [PowerPanelButton] is for.
enum PowerPanelTone {
  /// The way out: Cancel, Restart, Stay on. Card-toned, quietly outlined.
  neutral,

  /// The action the panel is for: Shut down, Retry. Outlined and lettered in
  /// the accent over its own surface.
  accent,

  /// The only way out of a refusal: Keep playing. Solid in the warning amber.
  warning,
}

/// An 84 px button in the power panel, large enough to hit with the console
/// on the floor.
class PowerPanelButton extends StatelessWidget {
  /// Creates a [PowerPanelButton].
  const PowerPanelButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.tone = PowerPanelTone.neutral,
    super.key,
  });

  /// Visible caption, and the announced label.
  final String label;

  /// Tap action.
  final VoidCallback onPressed;

  /// Glyph before [label].
  final IconData? icon;

  /// What this button is for.
  final PowerPanelTone tone;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final (background, edge, ink) = switch (tone) {
      PowerPanelTone.neutral => (
        surface.cardHigh,
        surface.borderStrong,
        surface.textPrimary,
      ),
      PowerPanelTone.accent => (
        surface.accentSurface,
        surface.accent,
        surface.accent,
      ),
      // Ink is the surface's own background: dark over the amber fill in
      // both themes, as ConsoleDialogTone.warning has it.
      PowerPanelTone.warning => (
        surface.warning,
        surface.warning,
        surface.background,
      ),
    };
    final radius = BorderRadius.circular(14);
    return FocusableTapTarget(
      onTap: onPressed,
      semanticLabel: label,
      borderRadius: 14,
      child: InkWell(
        onTap: onPressed,
        // The tap target is the one focus stop.
        canRequestFocus: false,
        borderRadius: radius,
        child: Container(
          height: 84,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: background,
            borderRadius: radius,
            border: Border.all(color: edge),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon case final icon?) ...[
                Icon(icon, size: 28, color: ink),
                const SizedBox(width: 12),
              ],
              Flexible(
                child: AppText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
