import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// Plymouth field behind the Saving face and the terminal faces, on both
/// screens.
const Color kPowerGoodbyeFill = Color(0xFF08080A);

/// What the Track display shows for [state] (pen 32). It keeps the track
/// display through Power options, Save As, a refusal and a fast save, and
/// takes over only once a save is slow or the goodbye comes (owner, #1553).
/// Restarting shows only while [installsUpdate]; a plain restart is the bare
/// Plymouth field on its way to the boot splash.
ReadoutGoodbye readoutGoodbyeOf(
  PowerState state, {
  required bool installsUpdate,
}) => switch (state.phase) {
  PowerPhase.saving => state.slow ? ReadoutGoodbye.saving : ReadoutGoodbye.none,
  PowerPhase.goodbye => switch (state.action) {
    PowerAction.restart when installsUpdate => ReadoutGoodbye.restarting,
    PowerAction.restart => ReadoutGoodbye.blank,
    PowerAction.shutDown || null => ReadoutGoodbye.safeToSwitchOff,
  },
  PowerPhase.idle ||
  PowerPhase.refuse ||
  PowerPhase.options ||
  PowerPhase.saveAs ||
  PowerPhase.saveFailed => ReadoutGoodbye.none,
};

/// The step's line, as the Saving face lists it: what it does while it runs
/// or is still ahead, what it did once [done].
String powerStepLabel(
  AppLocalizations l10n,
  PowerStep step, {
  bool done = false,
}) => switch (step) {
  PowerStep.stopPlayback =>
    done ? l10n.powerStepStopPlaybackDone : l10n.powerStepStopPlayback,
  PowerStep.saveSettings =>
    done ? l10n.powerStepSaveSettingsDone : l10n.powerStepSaveSettings,
  PowerStep.writeSession =>
    done ? l10n.powerStepWriteSessionDone : l10n.powerStepWriteSession,
  PowerStep.finishOnDisk =>
    done ? l10n.powerStepFinishOnDiskDone : l10n.powerStepFinishOnDisk,
};

/// The main screen's full-screen Saving, Safe to switch off and Restarting
/// faces (pen 32). Non-interactive; draws nothing in any other phase.
///
/// Saving shows only once the save is slow ([PowerState.slow], #1553); it
/// lists [PowerState.steps] and ticks them off as the save reaches them. The
/// terminal faces name the saved session and the console's local time of the
/// save. Restarting shows only when [stagedUpdate] installs during the
/// restart, and carries no icon (owner, #1543). A plain restart is the bare
/// Plymouth field, on its way to the boot splash. [unplugToApply] adds,
/// under Safe to switch off, that unplugging for five seconds lets the
/// console take the charger's full power (#1352).
class PowerGoodbye extends StatelessWidget {
  /// Creates a [PowerGoodbye] for [state].
  const PowerGoodbye({
    required this.state,
    this.stagedUpdate,
    this.unplugToApply = false,
    super.key,
  });

  /// The power flow.
  final PowerState state;

  /// The staged update's version, which installs during a restart; null
  /// when nothing is staged.
  final String? stagedUpdate;

  /// Whether a power cycle would raise the USB-C contract.
  final bool unplugToApply;

  @override
  Widget build(BuildContext context) {
    final Widget content;
    switch (state.phase) {
      case PowerPhase.saving:
        if (!state.slow) return const SizedBox.shrink();
        content = _SavingFace(state: state);
      case PowerPhase.goodbye:
        content = switch ((state.action, stagedUpdate)) {
          (PowerAction.restart, final version?) => _RestartingFace(
            state: state,
            version: version,
          ),
          (PowerAction.restart, null) => const SizedBox.shrink(),
          _ => _SafeToSwitchOffFace(
            state: state,
            unplugToApply: unplugToApply,
          ),
        };
      case PowerPhase.idle:
      case PowerPhase.refuse:
      case PowerPhase.options:
      case PowerPhase.saveAs:
      case PowerPhase.saveFailed:
        return const SizedBox.shrink();
    }
    return AbsorbPointer(
      child: ColoredBox(
        key: const Key('power_goodbye'),
        color: kPowerGoodbyeFill,
        child: Center(child: content),
      ),
    );
  }
}

/// "Saving `session`", the step list and the bar.
class _SavingFace extends StatelessWidget {
  const _SavingFace({required this.state});

  final PowerState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final steps = state.steps;
    final current = steps.indexOf(state.step!);
    final session = state.session;
    return Column(
      key: const Key('power_saving'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          session == null ? l10n.powerSaving : l10n.powerSavingSession(session),
          textAlign: TextAlign.center,
          style: _style(surface.textPrimary, 36, FontWeight.w600),
        ),
        const SizedBox(height: 40),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 20),
              _StepRow(
                label: powerStepLabel(l10n, steps[i], done: i < current),
                progress: i < current
                    ? _StepProgress.done
                    : i == current
                    ? _StepProgress.current
                    : _StepProgress.pending,
              ),
            ],
          ],
        ),
        const SizedBox(height: 40),
        _ProgressBar(value: state.progress, width: 440),
      ],
    );
  }
}

enum _StepProgress { done, current, pending }

/// One step: a green check once done, a spinner while current, a muted ring
/// before.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.progress});

  final String label;
  final _StepProgress progress;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final marker = switch (progress) {
      _StepProgress.done => Icon(
        Icons.check,
        key: const Key('power_step_done'),
        size: 28,
        color: Theme.of(
          context,
        ).extension<LooperTheme>()!.waveformColor(LooperMeterState.playing),
      ),
      _StepProgress.current => Padding(
        key: const Key('power_step_current'),
        padding: const EdgeInsets.all(3),
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: surface.accent,
          backgroundColor: surface.line,
        ),
      ),
      _StepProgress.pending => Container(
        key: const Key('power_step_pending'),
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: surface.line, width: 2.5),
        ),
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 28, child: marker),
        const SizedBox(width: 16),
        AppText(
          label,
          style: _style(switch (progress) {
            _StepProgress.done => surface.textSecondary,
            _StepProgress.current => surface.textPrimary,
            _StepProgress.pending => surface.textMuted,
          }, 24),
        ),
      ],
    );
  }
}

/// The ring, "Safe to switch off", the saved line and the unplug line.
class _SafeToSwitchOffFace extends StatelessWidget {
  const _SafeToSwitchOffFace({
    required this.state,
    required this.unplugToApply,
  });

  final PowerState state;
  final bool unplugToApply;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final saved = _savedLine(context, state);
    return Column(
      key: const Key('power_safe_to_switch_off'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const _CheckRing(diameter: 112),
        const SizedBox(height: 32),
        AppText(
          l10n.powerSafeToSwitchOff,
          textAlign: TextAlign.center,
          style: _style(surface.textPrimary, 48, FontWeight.w600),
        ),
        if (saved != null) ...[
          const SizedBox(height: 16),
          AppText(
            saved,
            key: const Key('power_saved_at'),
            textAlign: TextAlign.center,
            style: _style(surface.textSecondary, 24),
          ),
        ],
        if (unplugToApply) ...[
          const SizedBox(height: 12),
          AppText(
            l10n.powerUnplugToApply,
            key: const Key('power_unplug_to_apply'),
            textAlign: TextAlign.center,
            style: _style(surface.textSecondary, 24),
          ),
        ],
      ],
    );
  }
}

/// "Restarting", the saved line and the update it installs. No icon.
class _RestartingFace extends StatelessWidget {
  const _RestartingFace({required this.state, required this.version});

  final PowerState state;
  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final saved = _savedLine(context, state);
    final sub = _style(surface.textSecondary, 24);
    return Column(
      key: const Key('power_restarting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          l10n.powerRestarting,
          textAlign: TextAlign.center,
          style: _style(surface.textPrimary, 48, FontWeight.w600),
        ),
        if (saved != null) ...[
          const SizedBox(height: 16),
          AppText(
            saved,
            key: const Key('power_saved_at'),
            textAlign: TextAlign.center,
            style: sub,
          ),
        ],
        const SizedBox(height: 8),
        AppText(
          l10n.powerInstallingUpdate(version),
          key: const Key('power_installing_update'),
          textAlign: TextAlign.center,
          style: sub,
        ),
      ],
    );
  }
}

/// "`session` saved at HH:MM" in the console's local time; null when nothing
/// was saved.
String? _savedLine(BuildContext context, PowerState state) {
  final session = state.session;
  final at = state.savedAt;
  if (session == null || at == null) return null;
  final time = DateFormat.Hm(
    Localizations.localeOf(context).toString(),
  ).format(at.toLocal());
  return context.l10n.powerSavedAt(session, time);
}

/// The Track display's power faces (pen 32), mirrored from the main window
/// through [PerformanceReadout]: Saving with the current step when the save
/// is slow, then Safe to switch off, Restarting while an update installs, or
/// the bare field of a plain restart. No Segno logo (owner, #1543). Draws
/// nothing for [ReadoutGoodbye.none].
///
/// Proportional like `ConsoleReadoutView`: every figure is the 1024x600
/// design's, times the limiting-axis scale against it.
class ReadoutGoodbyeFace extends StatelessWidget {
  /// Creates a [ReadoutGoodbyeFace] for [readout].
  const ReadoutGoodbyeFace({required this.readout, super.key});

  /// What the main window pushed.
  final PerformanceReadout readout;

  /// The design's Track display.
  static const Size referenceSize = Size(1024, 600);

  @override
  Widget build(BuildContext context) {
    if (readout.goodbye == ReadoutGoodbye.none) return const SizedBox.shrink();
    return AbsorbPointer(
      child: ColoredBox(
        key: const Key('readout_goodbye'),
        color: kPowerGoodbyeFill,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : referenceSize.width;
            final height = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : referenceSize.height;
            final s =
                width / referenceSize.width < height / referenceSize.height
                ? width / referenceSize.width
                : height / referenceSize.height;
            return Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 48 * s),
                child: _ReadoutContent(readout: readout, s: s),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReadoutContent extends StatelessWidget {
  const _ReadoutContent({required this.readout, required this.s});

  final PerformanceReadout readout;
  final double s;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final headline = _style(surface.textPrimary, 44 * s, FontWeight.w600);
    switch (readout.goodbye) {
      case ReadoutGoodbye.none:
      case ReadoutGoodbye.blank:
        return const SizedBox.shrink();
      case ReadoutGoodbye.saving:
        final step = readout.savingStep;
        return Column(
          key: const Key('readout_goodbye_saving'),
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText(
              l10n.powerSaving,
              textAlign: TextAlign.center,
              style: headline,
            ),
            if (step != null) ...[
              SizedBox(height: 16 * s),
              AppText(
                powerStepLabel(l10n, step),
                textAlign: TextAlign.center,
                style: _style(surface.textSecondary, 28 * s),
              ),
            ],
            SizedBox(height: 36 * s),
            _ProgressBar(
              value: readout.savingProgress,
              width: 360 * s,
              height: 8 * s,
            ),
          ],
        );
      case ReadoutGoodbye.safeToSwitchOff:
        return Column(
          key: const Key('readout_goodbye_safe_to_switch_off'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _CheckRing(diameter: 96 * s),
            SizedBox(height: 28 * s),
            AppText(
              l10n.powerSafeToSwitchOff,
              textAlign: TextAlign.center,
              style: headline,
            ),
          ],
        );
      case ReadoutGoodbye.restarting:
        return Column(
          key: const Key('readout_goodbye_restarting'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restart_alt,
              size: 96 * s,
              color: surface.textSecondary,
            ),
            SizedBox(height: 28 * s),
            AppText(
              l10n.powerRestarting,
              textAlign: TextAlign.center,
              style: headline,
            ),
          ],
        );
    }
  }
}

/// A check in a green ring: the save landed and the console is off.
class _CheckRing extends StatelessWidget {
  const _CheckRing({required this.diameter});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    final green = Theme.of(
      context,
    ).extension<LooperTheme>()!.waveformColor(LooperMeterState.playing);
    return Container(
      key: const Key('power_check_ring'),
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: green.withValues(alpha: 0.12),
        border: Border.all(color: green, width: diameter / 28),
      ),
      child: Icon(Icons.check, size: diameter / 2, color: green),
    );
  }
}

/// The save's progress: [value] of the steps finished.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.value,
    required this.width,
    this.height = 8,
  });

  final double value;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      child: LinearProgressIndicator(
        key: const Key('power_progress'),
        value: value,
        minHeight: height,
        color: surface.accent,
        backgroundColor: surface.line,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

TextStyle _style(Color color, double size, [FontWeight? weight]) => TextStyle(
  color: color,
  fontSize: size,
  fontWeight: weight ?? FontWeight.w400,
  height: 1.2,
  leadingDistribution: TextLeadingDistribution.even,
);
