import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The accepted ten-pedal performance Mixer, driven by the shared
/// Control owner.
/// Bars show gain settings; they never pretend to meter live audio.
class FootMixerView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootMixerView({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.read<LooperRepository>();
    return StreamBuilder<int>(
      stream: repository.monitorChanges,
      builder: (context, _) => _FootMixerContent(
        monitors: repository.allMonitors(),
      ),
    );
  }
}

class _FootMixerContent extends StatelessWidget {
  const _FootMixerContent({required this.monitors});

  final Map<int, InputMonitor> monitors;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final selection = context.select<ControlCubit, FootMixerSelection>(
      (cubit) => cubit.state.footMixer,
    );
    final projection = context.select<LooperBloc, FootMixerProjection>(
      (bloc) => projectFootMixer(bloc.state, selection, monitors: monitors),
    );
    final tracks = context.watch<TracksCubit>().state;
    final inputs = context.watch<InputsCubit>().state;
    final l10n = context.l10n;
    final surface = context.surface;
    final isInput = projection.selection.domain == FootMixerDomain.inputs;
    final selected = projection.selected;
    String name(FootMixerChannel channel) => isInput
        ? l10n.inputName(inputs.names, channel.channel)
        : l10n.displayTrackName(
            tracks.nameOf(channel.channel),
            channel.channel,
          );
    String status(FootMixerChannel channel) {
      if (channel.muted) return l10n.readoutStateMuted;
      if (channel.monitorMode == MonitorMode.off) return l10n.footMixerHearOff;
      if (channel.monitorMode == MonitorMode.auto && !channel.live) {
        return l10n.footMixerAutoOff;
      }
      return '';
    }

    final front = [
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
        key: const Key('foot_mixer_view'),
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
                  key: const Key('foot_mixer_exit'),
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
                  onPressed: () => context.read<SettingsTrayCubit>().open(),
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
                          l10n.footMixerTitle,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootMixerPedal(
                          button: PedalButton.clear,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootMixerPedal(
                          button: PedalButton.bank,
                          projection: projection,
                        ),
                      ),
                      PositionedDirectional(
                        start: 940,
                        top: 140,
                        width: 540,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                for (final domain in FootMixerDomain.values)
                                  LoopChoiceButton(
                                    label: domain == FootMixerDomain.tracks
                                        ? l10n.signalSectionTracks
                                        : l10n.signalSectionInputs,
                                    selected:
                                        projection.selection.domain == domain,
                                    onTap: () =>
                                        control.selectFootMixerDomain(domain),
                                    width: 156,
                                    height: 72,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            AppText(
                              selected == null
                                  ? isInput
                                        ? l10n.footMixerEmptyInputs
                                        : l10n.footMixerEmptyTracks
                                  : name(selected),
                              style: const TextStyle(fontSize: 30),
                            ),
                            if (selected != null) ...[
                              const SizedBox(height: 12),
                              AppText(
                                isInput
                                    ? l10n.footMixerLiveVolume
                                    : l10n.footMixerPlaybackVolume,
                                style: TextStyle(
                                  fontSize: 20,
                                  color: surface.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 18),
                              Row(
                                children: [
                                  AppText(
                                    l10n.footMixerPercent(
                                      (selected.gain * 100).round(),
                                    ),
                                    key: const Key('foot_mixer_selected_gain'),
                                    style: const TextStyle(
                                      fontSize: 48,
                                      fontFamily: SurfaceTheme.monoFont,
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  Expanded(
                                    child: AppText(
                                      status(selected),
                                      style: TextStyle(
                                        fontSize: 20,
                                        color: surface.warning,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              LinearProgressIndicator(
                                key: const Key('foot_mixer_gain_bar'),
                                value: (selected.gain / projection.maximumGain)
                                    .clamp(0, 1),
                                minHeight: 10,
                                color: selected.muted
                                    ? surface.textMuted
                                    : surface.textPrimary,
                                backgroundColor: surface.controlStrong,
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  AppText(l10n.footMixerPercent(0)),
                                  AppText(
                                    l10n.footMixerPercent(
                                      (projection.maximumGain * 100).round(),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
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
                                child: _FootMixerPedal(
                                  button: button,
                                  projection: projection,
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

class _FootMixerPedal extends StatelessWidget {
  const _FootMixerPedal({required this.button, required this.projection});

  final PedalButton button;
  final FootMixerProjection projection;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final tracks = context.watch<TracksCubit>().state;
    final inputs = context.watch<InputsCubit>().state;
    final cursor = context.select<ControlCubit, int>(
      (cubit) => cubit.state.cursor,
    );
    final l10n = context.l10n;
    final isInput = projection.selection.domain == FootMixerDomain.inputs;
    final selected = projection.selected;
    String name(FootMixerChannel channel) => isInput
        ? l10n.inputName(inputs.names, channel.channel)
        : l10n.displayTrackName(
            tracks.nameOf(channel.channel),
            channel.channel,
          );
    final first = projection.selection.page * 4 + 1;
    final last = (first + 3).clamp(0, projection.channelCount);
    final pageLabel = projection.channelCount == 0
        ? l10n.footMixerEmptyInputs
        : isInput
        ? l10n.footMixerInputsPage(first, last)
        : l10n.footMixerTracksPage(first, last);
    final role = FootMixerProjection.pedalRoles[button]!;
    final channel = role.slot == null ? null : projection.channels[role.slot!];
    final title = switch (role.press) {
      FootMixerAction.recordPlay => l10n.actionRecordPlay,
      FootMixerAction.stop => l10n.actionStop,
      FootMixerAction.exit => l10n.actionModeExit,
      FootMixerAction.decrease => l10n.footMixerVolumeDown,
      FootMixerAction.increase => l10n.footMixerVolumeUp,
      FootMixerAction.nextPage => pageLabel,
      FootMixerAction.selectChannel =>
        channel!.channel < projection.channelCount ? name(channel) : '—',
      FootMixerAction.toggleMute ||
      FootMixerAction.reset ||
      FootMixerAction.switchDomain => '',
    };
    final hint = switch (role.hold) {
      FootMixerAction.reset =>
        selected != null &&
                (role.press == FootMixerAction.increase
                    ? !projection.canIncrease
                    : !projection.canDecrease)
            ? l10n.footMixerLimitReset
            : l10n.footMixerHoldReset,
      FootMixerAction.switchDomain =>
        isInput ? l10n.footMixerHoldTracks : l10n.footMixerHoldInputs,
      FootMixerAction.toggleMute when channel!.available =>
        channel.muted ? l10n.footMixerHoldUnmute : l10n.footMixerHoldMute,
      _ => '',
    };
    final detail = channel != null
        ? channel.available
              ? channel.muted
                    ? l10n.footMixerMutedLevel((channel.gain * 100).round())
                    : l10n.footMixerPercent((channel.gain * 100).round())
              : channel.channel < projection.channelCount
              ? l10n.readoutStateEmpty
              : ''
        : switch (role.press) {
            FootMixerAction.recordPlay => l10n.displayTrackName(
              tracks.nameOf(cursor),
              cursor,
            ),
            FootMixerAction.stop => l10n.actionScopeAllTracks,
            _ => '',
          };
    return _MixerPedal(
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${role.slot! + 1}',
      },
      title: title,
      detail: detail,
      hint: hint,
      enabled:
          channel?.available ??
          (role.hold != FootMixerAction.reset || selected != null),
      selected:
          role.press == FootMixerAction.exit ||
          (channel != null && selected?.channel == channel.channel),
      onActivate: () => control.activateFootMixerPedal(button),
      onHold: role.hold == null
          ? null
          : () => control.activateFootMixerPedal(button, hold: true),
    );
  }
}

class _MixerPedal extends StatefulWidget {
  const _MixerPedal({
    required this.button,
    required this.label,
    required this.title,
    required this.detail,
    required this.hint,
    required this.enabled,
    required this.selected,
    required this.onActivate,
    this.onHold,
  });

  final PedalButton button;
  final String label;
  final String title;
  final String detail;
  final String hint;
  final bool enabled;
  final bool selected;
  final VoidCallback onActivate;
  final VoidCallback? onHold;

  @override
  State<_MixerPedal> createState() => _MixerPedalState();
}

class _MixerPedalState extends State<_MixerPedal> {
  late ControlCubit _control;
  ({Object source, Object token})? _contact;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _control = context.read<ControlCubit>();
  }

  void _press(Object source) {
    if (_contact != null || !widget.enabled) return;
    final token = Object();
    _contact = (source: source, token: token);
    _control.footMixerPressed(widget.button, token);
  }

  void _release(Object source) {
    final contact = _contact;
    if (contact == null || contact.source != source) return;
    _contact = null;
    _control.footMixerReleased(widget.button, contact.token);
  }

  void _cancel([Object? source]) {
    final contact = _contact;
    if (contact == null || (source != null && contact.source != source)) return;
    _contact = null;
    _control.footMixerCancelled(widget.button, contact.token);
  }

  @override
  void didUpdateWidget(_MixerPedal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.title,
      value: widget.detail,
      hint: widget.hint,
      onTap: widget.enabled ? widget.onActivate : null,
      onLongPress: widget.enabled ? widget.onHold : null,
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (focused) {
          if (!focused) _cancel();
        },
        onKeyEvent: (_, event) {
          if (!widget.enabled ||
              (event.logicalKey != LogicalKeyboardKey.enter &&
                  event.logicalKey != LogicalKeyboardKey.space)) {
            return KeyEventResult.ignored;
          }
          if (event is KeyDownEvent) _press(event.logicalKey);
          if (event is KeyUpEvent) _release(event.logicalKey);
          return KeyEventResult.handled;
        },
        child: Builder(
          builder: (context) => Listener(
            key: Key('foot_mixer_pedal_${widget.button.name}'),
            onPointerDown: widget.enabled
                ? (event) {
                    if (event.buttons == kPrimaryButton) {
                      _press(event.pointer);
                    }
                  }
                : null,
            onPointerUp: widget.enabled
                ? (event) => _release(event.pointer)
                : null,
            onPointerCancel: (event) => _cancel(event.pointer),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  width: 3,
                  color: Focus.of(context).hasFocus
                      ? surface.warning
                      : Colors.transparent,
                ),
              ),
              child: Opacity(
                opacity: widget.enabled ? 1 : surface.disabledOpacity,
                child: Column(
                  children: [
                    Container(
                      width: 112,
                      height: 12,
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? surface.textPrimary
                            : surface.controlStrong,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 156,
                      child: PedalHardwareFace(
                        label: widget.label,
                        selected: false,
                      ),
                    ),
                    const SizedBox(height: 16),
                    AppText(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 24),
                    ),
                    if (widget.detail.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 32,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AppText(
                            widget.detail,
                            style: TextStyle(
                              fontSize: 24,
                              color: surface.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (widget.hint.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 56,
                        child: AppText(
                          widget.hint,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            color: surface.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
