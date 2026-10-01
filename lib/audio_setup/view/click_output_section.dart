import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// How many hardware outputs the click can be routed to.
///
/// The pinned playback device's own count first: it is known from enumeration
/// even while the engine is closed, which the engine's report is not. Then
/// what the engine has open. A stopped engine reports no outputs and the
/// picker still needs a plausible width, so stereo — the floor every rig has —
/// is the last answer.
int clickOutputCount(AudioSetupState state) {
  for (final device in state.playbackDevices) {
    if (device.id == state.playbackDeviceId && device.outputChannels > 0) {
      return device.outputChannels;
    }
  }
  final reported = state.engineStatus.outputChannels;
  return reported > 0 ? reported : 2;
}

/// How many outputs [clickOutputSummary] names before it starts counting
/// them.
const int _summaryLimit = 3;

/// The click's routing in one phrase: `nowhere`, `all outputs`, the chosen
/// outputs by name up to [_summaryLimit], and a count past that.
///
/// Named up to the limit, counted past it: an 18-out interface with nine
/// boxes ticked would otherwise put a sentence in a row's readout column.
String clickOutputSummary(
  AppLocalizations l10n, {
  required int mask,
  required int outputs,
}) {
  final all = (1 << outputs) - 1;
  final chosen = [
    for (var i = 0; i < outputs; i++)
      if (mask & (1 << i) != 0) i,
  ];
  return switch (chosen.length) {
    0 => l10n.loopClickOutputNone,
    _ when mask & all == all => l10n.loopClickOutputAll,
    > _summaryLimit => l10n.loopClickOutputCount(chosen.length),
    _ => chosen.map((i) => l10n.outputChannelLabel(i + 1)).join(' · '),
  };
}

/// Where the click sounds and how loud, on the desktop Audio settings page.
///
/// WHEN the click sounds is a Loop setting; where it goes and at what level
/// are properties of the rig's outputs, so they sit beside the output device
/// that owns them (`docs/design/2026-09-06-loop-setup-ux.md`). The Mixer that
/// will eventually hold click gain is slice 3; until it lands this is the one
/// place a fresh unit — whose saved mask is `0`, which the engine reads as
/// "no output" — can make its click audible at all.
///
/// Reads [TempoCubit]'s own state rather than the live transport: the pedal
/// path that bypasses the cubit moves the click MODE only, never its routing
/// or level, so there is no second cache to fall out of step here.
class ClickOutputSection extends StatelessWidget {
  /// Creates a [ClickOutputSection].
  const ClickOutputSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<TempoCubit>();
    final settings = cubit.state;
    final outputs = clickOutputCount(context.watch<AudioSetupCubit>().state);

    return Column(
      key: const Key('audioSettings_clickOutput_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(l10n.clickOutputLabel, style: context.setupBody),
        const SizedBox(height: 12),
        SetupChannelChips(
          channelCount: outputs,
          mask: settings.clickOutputMask,
          keyPrefix: 'audioSettings_clickOutput',
          onChanged: (mask) => unawaited(cubit.setClickOutput(mask)),
        ),
        const SizedBox(height: 16),
        _ClickVolumeSlider(
          volume: settings.clickVolume,
          onChanged: (volume) => unawaited(cubit.setClickVolume(volume)),
        ),
      ],
    );
  }
}

/// The click's own volume slider over the whole gain stage
/// (`0..`[kMaxClickGain]), with a percent-of-unity readout.
class _ClickVolumeSlider extends StatelessWidget {
  const _ClickVolumeSlider({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final clamped = volume.clamp(0.0, kMaxClickGain);
    return Row(
      children: [
        Expanded(
          // Merged, so the slider announces as "Click volume" rather than as
          // an unnamed control next to a caption.
          child: MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  l10n.clickVolumeLabel,
                  style: TextStyle(color: surface.textPrimary, fontSize: 13),
                ),
                SliderTheme(
                  data: context.setupSliderTheme,
                  child: Slider(
                    key: const Key('audioSettings_clickVolume_slider'),
                    value: clamped,
                    max: kMaxClickGain,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 48,
          child: AppText(
            l10n.loopClickVolumeReadout((clamped * 100).round()),
            key: const Key('audioSettings_clickVolume_readout'),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
