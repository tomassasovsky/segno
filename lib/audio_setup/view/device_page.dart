import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart'
    show EngineStatus, LatencyState;
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/view/audio_device_scan_scope.dart';
import 'package:segno/audio_setup/view/audio_interfaces.dart';
import 'package:segno/audio_setup/view/console/audio_routing_card.dart';
import 'package:segno/audio_setup/view/console/cable_test_dialog.dart';
import 'package:segno/audio_setup/view/console/max_loop_length_card.dart';
import 'package:segno/audio_setup/view/device_dialog.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Settings > Device (#1270 Part 4, pen 28/01): the interface, its rate and
/// buffer, and what the round trip measures.
///
/// Every setting is drafted (`AudioDraft`): editing changes only the page,
/// and Apply opens the device once with all of it, through the guarded apply
/// (#1270 Part 3a). Leaving the page drops the draft and cancels a cable test
/// in flight.
class DevicePage extends StatefulWidget {
  /// Creates a [DevicePage].
  const DevicePage({super.key});

  /// The workspace's inset in the frame's main area (pen 28/01: the
  /// workspace at 36, 124 and its content 52 in from it).
  static const EdgeInsets inset = EdgeInsets.fromLTRB(88, 148, 88, 0);

  /// The Apply row's top in the main area.
  static const double applyRowTop = 852;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late final AudioSetupCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<AudioSetupCubit>();
  }

  @override
  void dispose() {
    // A draft is the page's: leaving it means not applying it. A pulse must
    // not keep playing behind a page that is gone.
    _cubit
      ..cancelMeasure()
      ..discardDraft();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AudioSetupCubit>().state;
    return MultiBlocListener(
      listeners: [
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.applyPhase != current.applyPhase &&
              current.applyPhase == ApplyPhase.confirming,
          listener: (context, _) => unawaited(_confirmApply(context)),
        ),
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.measurePhase != current.measurePhase &&
              current.measurePhase == MeasurePhase.cable,
          listener: (context, _) => unawaited(showCableTestDialog(context)),
        ),
      ],
      child: AudioDeviceScanScope(
        child: Scaffold(
          body: LoopSettingsFrame(
            key: const Key('device_page'),
            crumb: l10n.settingsCrumb(l10n.settingsDeviceTitle),
            title: l10n.devicePageTitle,
            onBack: () => Navigator.maybePop(context),
            onStage: () => Navigator.popUntil(context, (r) => r.isFirst),
            children: [
              Positioned(
                left: DevicePage.inset.left,
                top: DevicePage.inset.top,
                right: DevicePage.inset.right,
                bottom: state.draft == null
                    ? 40
                    : 1080 - kLoopTopBarHeight - DevicePage.applyRowTop,
                child: const SingleChildScrollView(child: _Workspace()),
              ),
              if (state.draft != null)
                Positioned(
                  left: DevicePage.inset.left,
                  right: DevicePage.inset.right,
                  top: DevicePage.applyRowTop,
                  height: 72,
                  child: const _ApplyRow(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Apply audio settings?" (pen 28/04), asked when the apply would stop
  /// the music. Focus starts on the dismissive answer.
  Future<void> _confirmApply(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDeviceConfirmDialog(
      context,
      title: l10n.audioApplyTitle,
      body: l10n.audioApplyBody,
      confirmLabel: l10n.audioApplyConfirm,
    );
    if (confirmed) {
      _cubit.confirmApply();
    } else {
      _cubit.cancelApply();
    }
  }
}

/// Everything above the Apply row.
class _Workspace extends StatelessWidget {
  const _Workspace();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AudioSetupCubit>().state;
    // Read from the looper's own gate over the outputs the rig HAS: the raw
    // mask is default-on across all 32 bits.
    final silent = context.select<LooperBloc, bool>((bloc) {
      final looper = bloc.state;
      final outputs = looper.status.outputChannels;
      return outputs > 0 &&
          List.generate(outputs, looper.isOutputEnabled).every((on) => !on);
    });
    final banner = _banner(l10n, state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (banner != null) ...[banner, const SizedBox(height: 16)],
        if (silent) ...[
          ConsoleBanner(
            key: const Key('audio_no_outputs_banner'),
            message: l10n.audioNoOutputsBanner,
            tone: ConsoleBannerTone.failure,
          ),
          const SizedBox(height: 16),
        ],
        const _Header(),
        const SizedBox(height: 40),
        // As tall as the taller column, so the rule between them runs the
        // whole way (pen 28/01: 441).
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EngineColumn(),
              SizedBox(width: 64),
              Expanded(child: _LatencyColumn()),
            ],
          ),
        ),
        const SizedBox(height: 40),
        // Not in pen 28/01; written back (§5): how long a loop may grow is
        // memory reserved when the device opens, and Audio routing is the
        // rig's jacks.
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 831, child: MaxLoopLengthCard()),
            SizedBox(width: 121),
            Expanded(child: AudioRoutingCard()),
          ],
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  /// What the last request turned out to be, or null when the page simply
  /// shows what runs.
  Widget? _banner(AppLocalizations l10n, AudioSetupState state) {
    final refusal = state.refusal;
    if (refusal != null) {
      return ConsoleBanner(
        key: const Key('audio_apply_refused_banner'),
        message: _refusalMessage(l10n, refusal),
        tone: ConsoleBannerTone.failure,
      );
    }
    final error = state.error;
    if (error != null) {
      return ConsoleBanner(
        key: const Key('audio_open_failed_banner'),
        message: switch (error) {
          AudioSetupError.openDeviceFailed => l10n.failedToOpenDevice(
            state.errorDetail ?? '',
          ),
        },
        tone: ConsoleBannerTone.failure,
      );
    }
    if (state.phase == ConfigPhase.settled) return null;
    return ConsoleBanner(
      key: const Key('audio_refused_banner'),
      message: l10n.audioRefusedConfig(
        l10n.audioRateBufferValue(
          l10n.sampleRateKhzLabel(state.requestedRate),
          state.requestedBuffer,
        ),
        l10n.audioRateBufferValue(
          l10n.sampleRateKhzLabel(state.actualRate),
          state.actualBuffer,
        ),
      ),
      tone: ConsoleBannerTone.failure,
    );
  }

  static String _refusalMessage(AppLocalizations l10n, ApplyRefusal refusal) {
    final rate = refusal.overBudgetRate;
    if (rate != null) {
      return l10n.audioEffectsOverBudgetRate(l10n.sampleRateKhzLabel(rate));
    }
    final device = refusal.refusedDevice;
    if (device != null) return l10n.audioDeviceRefused(device);
    if (refusal.settingsRefused) return l10n.audioSettingsRefused;
    return l10n.operationBusy(refusal.busyKind ?? 'other');
  }
}

/// The interface: its name and channel counts, whether it is there, and
/// Change interface.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<AudioSetupCubit>().state;
    final shown = state.shown;
    final devices = audioInterfacesOf(
      state,
      playbackId: shown.playbackDeviceId,
      captureId: shown.captureDeviceId,
    );
    final current = pinnedAudioInterface(
      devices,
      playbackId: shown.playbackDeviceId,
      captureId: shown.captureDeviceId,
    );
    final status = state.engineStatus;
    // The pill speaks for the interface the header names: the running one,
    // or a drafted one, which is there when the host lists it.
    final drafted =
        shown.playbackDeviceId != state.playbackDeviceId ||
        shown.captureDeviceId != state.captureDeviceId;
    final present = drafted
        ? current != null && !current.absent
        : status.isConnected && status.devicePresent;
    final name =
        current?.name ??
        (status.deviceName.isNotEmpty ? status.deviceName : l10n.systemDefault);
    final inputs = current?.inputChannels ?? status.inputChannels;
    final outputs = current?.outputChannels ?? status.outputChannels;
    return Container(
      height: 104,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.borderStrong)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  name,
                  key: const Key('device_name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 34,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 10),
                if (inputs > 0 && outputs > 0)
                  AppText(
                    l10n.deviceInputsOutputs(inputs, outputs),
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 22,
                      height: 1.1,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 25),
            child: _StatusPill(present: present),
          ),
          const SizedBox(width: 31),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LoopOutlinedButton(
              key: const Key('device_change_interface'),
              width: 233,
              label: l10n.deviceChangeInterface,
              onTap: () => unawaited(_chooseInterface(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// The interface list as a dialog: a choice is drafted, not applied.
  /// The interface list as a dialog that follows the host's list while it is
  /// open: a choice is drafted, not applied.
  Future<void> _chooseInterface(BuildContext context) async {
    final cubit = context.read<AudioSetupCubit>();
    final chosen = await showDialog<AudioInterface>(
      context: context,
      barrierColor: context.surface.scrim,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _InterfaceDialog()),
    );
    if (chosen == null) return;
    cubit.editDevice(
      playbackDeviceId: chosen.playbackId,
      captureDeviceId: chosen.captureId,
    );
  }
}

class _InterfaceDialog extends StatelessWidget {
  const _InterfaceDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AudioSetupCubit>().state;
    final shown = state.shown;
    final devices = audioInterfacesOf(
      state,
      playbackId: shown.playbackDeviceId,
      captureId: shown.captureDeviceId,
    );
    final current = pinnedAudioInterface(
      devices,
      playbackId: shown.playbackDeviceId,
      captureId: shown.captureDeviceId,
    );
    return DeviceDialog(
      key: const Key('device_interface_dialog'),
      title: l10n.deviceChangeInterface,
      content: [
        const SizedBox(height: 24),
        for (final (index, device) in devices.indexed)
          ConsolePickRow(
            key: Key('audio_device_option_$index'),
            title: device.name,
            state: device.absent
                ? l10n.audioDeviceUnplugged
                : audioChannelCounts(l10n, device),
            dimmed: device.absent,
            selected: device == current,
            showDivider: index < devices.length - 1,
            onTap: () => Navigator.of(context).pop(device),
          ),
      ],
      actions: [
        LoopOutlinedButton(
          key: const Key('device_interface_cancel'),
          width: 125,
          label: l10n.cancel,
          autofocus: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.present});

  final bool present;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final color = present ? surface.textSecondary : surface.rec;
    return Row(
      key: const Key('device_status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        AppText(
          present ? l10n.deviceConnected : l10n.deviceDisconnected,
          style: TextStyle(
            color: present ? surface.textPrimary : surface.rec,
            fontSize: 22,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// Sample rate, buffer and the period they make.
class _EngineColumn extends StatelessWidget {
  const _EngineColumn();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<AudioSetupCubit>();
    final state = context.watch<AudioSetupCubit>().state;
    final shown = state.shown;
    final locked = state.hasContent;
    final period = shown.sampleRate <= 0
        ? 0.0
        : shown.bufferFrames * 1000 / shown.sampleRate;
    final secondary = TextStyle(
      color: surface.textSecondary,
      fontSize: 22,
      height: 1,
    );
    return Container(
      width: 888,
      // 888 with its 1 px rule: the pen's 831 of content.
      padding: const EdgeInsets.only(right: 56),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: surface.borderStrong)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoopSectionLabel(l10n.deviceSampleRate),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final rate in AudioSetupState.sampleRates)
                LoopChoiceButton(
                  key: Key('device_rate_$rate'),
                  label: l10n.sampleRateKhzLabel(rate),
                  selected: shown.sampleRate == rate,
                  enabled: !locked,
                  hint: l10n.audioRateLocked,
                  width: 268,
                  height: 84,
                  fontSize: 28,
                  onTap: () => cubit.editRate(rate),
                ),
            ],
          ),
          SizedBox(
            height: 40,
            child: locked
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      l10n.audioRateLocked,
                      key: const Key('device_rate_locked'),
                      style: secondary,
                    ),
                  )
                : null,
          ),
          Row(
            children: [
              LoopSectionLabel(l10n.deviceBufferSize),
              const Spacer(),
              AppText(l10n.deviceSamples, style: secondary),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final frames in AudioSetupState.bufferSizes)
                LoopChoiceButton(
                  key: Key('device_buffer_$frames'),
                  label: '$frames',
                  selected: shown.bufferFrames == frames,
                  width: 198,
                  height: 84,
                  fontSize: 28,
                  onTap: () => cubit.editBuffer(frames),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              AppText(
                l10n.deviceLowerLatency,
                style: secondary.copyWith(fontSize: 20),
              ),
              const Spacer(),
              AppText(
                l10n.deviceMoreHeadroom,
                style: secondary.copyWith(fontSize: 20),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Row(
            key: const Key('device_period'),
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              AppText(
                period.toStringAsFixed(2),
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 42,
                  height: 1,
                ),
              ),
              const SizedBox(width: 11),
              AppText(
                l10n.deviceMs,
                style: TextStyle(color: surface.textPrimary, fontSize: 24),
              ),
              const SizedBox(width: 18),
              AppText(l10n.devicePerBuffer, style: secondary),
            ],
          ),
        ],
      ),
    );
  }
}

/// The round trip: what it measures, Measure, and the engine's health.
class _LatencyColumn extends StatelessWidget {
  const _LatencyColumn();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<AudioSetupCubit>();
    final state = context.watch<AudioSetupCubit>().state;
    final status = state.engineStatus;
    final present = status.isConnected && status.devicePresent;
    final running = state.measurePhase == MeasurePhase.running;
    final measured =
        status.latencyState == LatencyState.done &&
        status.recordOffsetFrames > 0;
    final note = !present
        ? l10n.audioMeasureUnavailable
        : state.draft != null
        ? l10n.deviceApplyBeforeMeasuring
        : measured
        ? l10n.audioRecordOffsetSub(status.recordOffsetFrames)
        : l10n.deviceMeasureNote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            LoopSectionLabel(l10n.roundTripLatencyLabel),
            const Spacer(),
            if (running)
              LoopOutlinedButton(
                key: const Key('audio_measure_cancel'),
                width: 144,
                label: l10n.cancel,
                onTap: cubit.cancelMeasure,
              )
            else
              Opacity(
                opacity: present && state.draft == null
                    ? 1
                    : surface.disabledOpacity,
                child: LoopOutlinedButton(
                  key: const Key('audio_measure'),
                  width: 144,
                  label: l10n.audioMeasure,
                  onTap: present && state.draft == null
                      ? cubit.openCableTest
                      : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 26),
        AppText(
          running
              ? l10n.measuringEllipsis
              : measured
              ? l10n.latencyMs(status.measuredLatencyMs.toStringAsFixed(2))
              : l10n.notMeasured,
          key: const Key('device_latency_value'),
          style: TextStyle(color: surface.textPrimary, fontSize: 42, height: 1),
        ),
        const SizedBox(height: 46),
        AppText(
          note,
          key: const Key('device_latency_note'),
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 22,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 32),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: surface.borderStrong)),
          ),
          padding: const EdgeInsets.only(top: 25),
          child: Column(
            children: [
              _HealthRow(
                key: const Key('device_dropouts'),
                label: l10n.deviceDropouts,
                value: '${status.xrunCount}',
              ),
              const SizedBox(height: 24),
              _HealthRow(
                key: const Key('device_engine'),
                label: l10n.deviceEngine,
                value: _engine(l10n, state, status),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Running, Stopped, or Offline: running for an interface that is gone.
  static String _engine(
    AppLocalizations l10n,
    AudioSetupState state,
    EngineStatus status,
  ) {
    if (status.isConnected && status.devicePresent) {
      return l10n.deviceEngineRunning;
    }
    if (status.isConnected ||
        state.deviceConnectivity == DeviceConnectivity.lost ||
        state.deviceConnectivity == DeviceConnectivity.waiting) {
      return l10n.deviceEngineOffline;
    }
    return l10n.deviceEngineStopped;
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      children: [
        AppText(
          label,
          style: TextStyle(color: surface.textSecondary, fontSize: 24),
        ),
        const Spacer(),
        AppText(
          value,
          style: TextStyle(color: surface.textPrimary, fontSize: 24),
        ),
      ],
    );
  }
}

/// Shown only while a draft differs from what runs (pen 28/01).
class _ApplyRow extends StatelessWidget {
  const _ApplyRow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<AudioSetupCubit>();
    return Row(
      key: const Key('device_apply_row'),
      children: [
        Expanded(
          child: AppText(
            l10n.deviceApplyNote,
            style: TextStyle(color: surface.warning, fontSize: 22, height: 1),
          ),
        ),
        LoopOutlinedButton(
          key: const Key('device_apply_cancel'),
          width: 125,
          label: l10n.cancel,
          onTap: cubit.discardDraft,
        ),
        const SizedBox(width: 18),
        LoopOutlinedButton(
          key: const Key('device_apply'),
          width: 117,
          label: l10n.deviceApply,
          tone: LoopButtonTone.accent,
          onTap: cubit.applyDraft,
        ),
      ],
    );
  }
}
