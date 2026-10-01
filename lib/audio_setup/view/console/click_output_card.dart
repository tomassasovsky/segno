import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/view/click_output_section.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Where the click sounds and how loud, as one card of the console's Audio /
/// Device face.
///
/// The console counterpart of [ClickOutputSection], and on the Device tab for
/// the same reason: that tab is where the rig's outputs live, and the click's
/// routing is a fact about them rather than about when it plays.
///
/// The output row is **the one chooser here that is not pick-one**: the click
/// sounds on a bitmask of hardware outputs, so several chips are lit at once
/// and a tap toggles one bit rather than replacing the answer. It stays open
/// across taps for the same reason — there is no single pick that ends the
/// question.
class ClickOutputCard extends StatefulWidget {
  /// Creates a [ClickOutputCard].
  const ClickOutputCard({super.key});

  @override
  State<ClickOutputCard> createState() => _ClickOutputCardState();
}

class _ClickOutputCardState extends State<ClickOutputCard> {
  bool _open = false;

  /// What the volume bar is inset by inside the card.
  static const EdgeInsets _barInset = EdgeInsets.all(18);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.watch<TempoCubit>();
    final settings = cubit.state;
    final outputs = clickOutputCount(context.watch<AudioSetupCubit>().state);
    final mask = settings.clickOutputMask;
    final volume = settings.clickVolume.clamp(0.0, kMaxClickGain);

    return ConsoleCard(
      key: const Key('audio_click_card'),
      children: [
        ConsoleRow(
          key: const Key('audio_click_output_row'),
          title: l10n.clickOutputLabel,
          state: clickOutputSummary(l10n, mask: mask, outputs: outputs),
          expanded: _open,
          fill: _open ? surface.control : null,
          onTap: () => setState(() => _open = !_open),
        ),
        ConsoleChooser.grid(
          key: const Key('audio_click_output_chooser'),
          open: _open,
          grid: ConsoleChipGrid<int>(
            // A set, not a single value: this is the bitmask case the grid
            // exists to serve, and several cells are lit at once.
            selected: {
              for (var i = 0; i < outputs; i++)
                if (mask & (1 << i) != 0) i,
            },
            options: [
              for (var i = 0; i < outputs; i++)
                ConsoleSegment(
                  value: i,
                  label: l10n.outputChannelLabel(i + 1),
                  optionKey: Key('audio_click_output_$i'),
                ),
            ],
            // Toggles one bit and leaves the grid open: no single tap answers
            // this question, so nothing here closes it.
            onTap: (i) => unawaited(cubit.setClickOutput(mask ^ (1 << i))),
          ),
        ),
        // The bar's `0..1` travel maps onto `0..`[kMaxClickGain] — the
        // engine's own ceiling, and the range the desktop slider has. The
        // readout stays percent-of-unity like the rest of the app, which puts
        // a normal click at half the bar and keeps the headroom reachable.
        // Double-tap snaps back to unity.
        Padding(
          padding: _barInset,
          child: ConsoleValueBar(
            key: const Key('audio_click_volume'),
            label: l10n.loopClickVolumeLabel,
            value: volume / kMaxClickGain,
            resetValue: 1 / kMaxClickGain,
            readout: l10n.loopClickVolumeReadout((volume * 100).round()),
            semanticLabel: l10n.a11yLoopClickVolume,
            onChanged: (value) =>
                unawaited(cubit.setClickVolume(value * kMaxClickGain)),
          ),
        ),
      ],
    );
  }
}
