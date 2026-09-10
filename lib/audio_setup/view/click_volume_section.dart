import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// How loud the click is, on the desktop Audio settings page.
///
/// WHERE the click goes is no longer here: Audio routing's Output routing task
/// owns it, as the accepted design has it, alongside every other source's
/// destinations (slice 3c). WHEN it sounds is a Loop setting. Its LEVEL has
/// nowhere else to live until the Mixer holds it, and a fresh unit has to be
/// able to make its click audible, so it stays beside the output device.
///
/// Reads [TempoCubit]'s own state rather than the live transport: the pedal
/// path that bypasses the cubit moves the click MODE only, never its level,
/// so there is no second cache to fall out of step here.
class ClickVolumeSection extends StatelessWidget {
  /// Creates a [ClickVolumeSection].
  const ClickVolumeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<TempoCubit>();
    return Column(
      key: const Key('audioSettings_clickVolume_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ClickVolumeSlider(
          volume: cubit.state.clickVolume,
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
