import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';

/// The console's way into Audio routing, and the click's level, on the Audio /
/// Device face.
///
/// **Why the routing row is here.** The accepted design reaches Audio routing
/// from Settings. On the console this tray IS Settings: the desktop settings
/// page is behind a right-click, a key and a menu bar, and a touch appliance
/// has none of the three. Without a row here every task the routing route
/// builds is unreachable on the hardware the design is for.
///
/// **Why the click's level is here.** Where the click goes is Audio routing's,
/// as the accepted design has it. How loud it is has nowhere else to live
/// until the Mixer holds it, and a fresh unit has to be able to make its click
/// audible, so its level stays on the tab that owns the rig's outputs.
class AudioRoutingCard extends StatelessWidget {
  /// Creates an [AudioRoutingCard].
  const AudioRoutingCard({super.key});

  /// What the volume bar is inset by inside the card.
  static const EdgeInsets _barInset = EdgeInsets.all(18);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<TempoCubit>();
    final volume = cubit.state.clickVolume.clamp(0.0, kMaxClickGain);

    return ConsoleCard(
      key: const Key('audio_routing_card'),
      children: [
        ConsoleRow(
          key: const Key('audio_routing_row'),
          title: l10n.routingTitle,
          subtitle: l10n.routingRowSubtitle,
          onTap: () => unawaited(openAudioRouting()),
        ),
        // The bar's `0..1` travel maps onto `0..`[kMaxClickGain] — the
        // engine's own ceiling. The readout stays percent-of-unity like the
        // rest of the app, which puts a normal click at half the bar and keeps
        // the headroom reachable. Double-tap snaps back to unity.
        Padding(
          padding: _barInset,
          child: ConsoleValueBar(
            key: const Key('audio_click_volume'),
            label: l10n.clickVolumeLabel,
            value: volume / kMaxClickGain,
            resetValue: 1 / kMaxClickGain,
            readout: l10n.loopClickVolumeReadout((volume * 100).round()),
            onChanged: (value) =>
                unawaited(cubit.setClickVolume(value * kMaxClickGain)),
          ),
        ),
      ],
    );
  }
}
