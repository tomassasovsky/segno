import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/backing/cubit/backing_cubit.dart';
import 'package:segno/backing/cubit/backing_mix_cubit.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/control/view/control_value_readout.dart'
    show clickModeReadout;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart'
    show routingPlacementLabel;
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// Opens the Mixer's `Backing & click` dialog (the pen's 25 `bZDIR`): the
/// backing's and the click's volume and pan, side by side.
Future<void> showBackingClickDialog(BuildContext context) {
  final surface = context.surface;
  final backing = context.read<BackingCubit>();
  final mix = context.read<BackingMixCubit>();
  final tempo = context.read<TempoCubit>();
  return showDialog<void>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: backing),
        BlocProvider.value(value: mix),
        BlocProvider.value(value: tempo),
      ],
      child: const BackingClickDialog(),
    ),
  );
}

/// The pen's 1260 x 549 `Backing & click` panel.
class BackingClickDialog extends StatelessWidget {
  /// Creates a [BackingClickDialog].
  const BackingClickDialog({super.key});

  static const double _width = 1260;
  static const double _pad = 41;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final loaded = context.select<BackingCubit, String?>(
      (cubit) => cubit.state.backing.loaded?.name,
    );
    final mix = context.watch<BackingMixCubit>().state;
    final tempo = context.watch<TempoCubit>().state;
    final mixCubit = context.read<BackingMixCubit>();
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Semantics(
              container: true,
              label: l10n.mixerBackingClick,
              child: Material(
                key: const Key('backing_click_dialog'),
                color: surface.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: surface.borderStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: _width,
                  child: Padding(
                    padding: const EdgeInsets.all(_pad),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppText(
                          l10n.mixerBackingClick,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 32,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _AuxChannel(
                          key: const Key('backing_click_backing'),
                          name: l10n.mixerBackingChannel,
                          subtitle: loaded ?? l10n.mixerBackingNothingLoaded,
                          level: mix.mix.level,
                          pan: mix.mix.pan,
                          enabled: mix.mixReady,
                          volumeLabel: l10n.mixerBackingVolume,
                          panLabel: l10n.mixerBackingPan,
                          onLevel: mixCubit.setLevel,
                          onPan: mixCubit.setPan,
                        ),
                        const SizedBox(height: 24),
                        _AuxChannel(
                          key: const Key('backing_click_click'),
                          name: l10n.routingSourceClick,
                          subtitle: clickModeReadout(l10n, tempo.clickMode),
                          level: tempo.clickVolume,
                          pan: mix.clickPan,
                          enabled: tempo.clickReady,
                          panEnabled: mix.clickPanReady,
                          volumeLabel: l10n.clickVolumeLabel,
                          panLabel: l10n.mixerClickPan,
                          onLevel: (gain) => unawaited(
                            context.read<TempoCubit>().setClickVolume(gain),
                          ),
                          onPan: mixCubit.setClickPan,
                        ),
                        const SizedBox(height: 24),
                        Align(
                          alignment: Alignment.centerRight,
                          child: LoopOutlinedButton(
                            key: const Key('backing_click_done'),
                            width: 110,
                            tone: LoopButtonTone.accent,
                            label: l10n.done,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One `stage-aux-channel` row: the name and what it plays, then Volume on
/// the Mixer's gain axis and Pan. A double tap restores unity or centre.
class _AuxChannel extends StatefulWidget {
  const _AuxChannel({
    required this.name,
    required this.subtitle,
    required this.level,
    required this.pan,
    required this.enabled,
    required this.volumeLabel,
    required this.panLabel,
    required this.onLevel,
    required this.onPan,
    this.panEnabled,
    super.key,
  });

  final String name;
  final String subtitle;
  final double level;
  final double pan;
  final bool enabled;
  final bool? panEnabled;

  /// The accessible names; the visible ones are `Volume` and `Pan`.
  final String volumeLabel;
  final String panLabel;
  final void Function(double gain) onLevel;
  final void Function(double pan) onPan;

  @override
  State<_AuxChannel> createState() => _AuxChannelState();
}

class _AuxChannelState extends State<_AuxChannel> {
  /// A drag or keyboard draft not yet committed, as slider travel.
  double? _levelDraft;
  double? _panDraft;

  static const double _labelWidth = 280;
  static const double _controlLeft = 320;
  static const double _controlWidth = 409;
  static const double _controlGap = 40;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final level = _levelDraft == null
        ? widget.level
        : mixerGainAt(_levelDraft!);
    final pan = _panDraft == null ? widget.pan : _panDraft! * 2 - 1;
    final panEnabled = widget.panEnabled ?? widget.enabled;
    return SizedBox(
      height: 147,
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  widget.name,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 16),
                AppText(
                  widget.subtitle,
                  key: const Key('backing_click_subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 21,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _controlLeft - _labelWidth),
          _control(
            key: const Key('backing_click_volume'),
            label: l10n.expressionControlVolume,
            semanticLabel: widget.volumeLabel,
            readout: signalGainReadout(level),
            value: mixerTravelFor(level),
            enabled: widget.enabled,
            onChanged: (v) => setState(() => _levelDraft = v),
            onCommit: (v) {
              setState(() => _levelDraft = null);
              widget.onLevel(mixerGainAt(v));
            },
            onCancel: () => setState(() => _levelDraft = null),
            onReset: () => widget.onLevel(1),
          ),
          const SizedBox(width: _controlGap),
          _control(
            key: const Key('backing_click_pan'),
            label: l10n.routingPan,
            semanticLabel: widget.panLabel,
            readout: routingPlacementLabel(l10n, pan),
            value: (pan + 1) / 2,
            enabled: panEnabled,
            onChanged: (v) => setState(() => _panDraft = v),
            onCommit: (v) {
              setState(() => _panDraft = null);
              widget.onPan(v * 2 - 1);
            },
            onCancel: () => setState(() => _panDraft = null),
            onReset: () => widget.onPan(0),
          ),
        ],
      ),
    );
  }

  Widget _control({
    required Key key,
    required String label,
    required String semanticLabel,
    required String readout,
    required double value,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
    required VoidCallback onCancel,
    required VoidCallback onReset,
  }) => SizedBox(
    key: key,
    width: _controlWidth,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RoutingInlineLabel(
          label: label,
          value: readout,
          width: _controlWidth,
        ),
        const SizedBox(height: 7),
        LoopSlider(
          value: value,
          width: _controlWidth,
          semanticLabel: semanticLabel,
          semanticValueBuilder: (_) => readout,
          enabled: enabled,
          keyboardStep: 0.02,
          onChanged: onChanged,
          onChangeEnd: onCommit,
          onEditCancel: (_) => onCancel(),
          onDoubleTap: onReset,
        ),
      ],
    ),
  );
}
