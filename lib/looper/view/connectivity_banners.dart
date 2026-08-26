import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The stage's standing loss conditions, drawn to the pen's
/// `STAGE / device-lost`: device-lost in the record red — the engine is
/// stopped, which is the loudest fact the console has — and MIDI-lost in the
/// warning amber, because the loops keep playing without it. Both at once
/// stack in severity order, device first, flush as the pen draws them.
///
/// A banner and never a toast or a dialog (`c/device-lost`): a toast is for
/// an *event*, these are *conditions* — each banner holds the screen exactly
/// as long as its condition holds and leaves on its own the moment the
/// hardware returns, and a dialog would steal the transport mid-song. The
/// lost-toasts this surface replaces were the D1 stopgap (#453).
///
/// Each banner carries the one action that ends it: **Choose device** opens
/// the tray's Audio domain on the Device tab, **Control** opens the Control
/// domain — navigation through [SettingsTrayCubit], no new routing. Mounted
/// by `TracksView` on console AND desktop builds: the condition is exactly as
/// true in a window as on the panel.
class ConnectivityBanners extends StatelessWidget {
  /// Creates a [ConnectivityBanners].
  const ConnectivityBanners({super.key});

  /// The gap under the stack: the pen's 10 on the console stage (the run's
  /// own rhythm), 14 on desktop where the surrounding chrome — the toolbar
  /// gap and the not-running banner's — steps by 14.
  static const double _gapBelow = kConsoleMode ? 10 : 14;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final deviceLost = context.select<AudioSetupCubit, bool>(
      (cubit) => cubit.state.deviceConnectivity == DeviceConnectivity.lost,
    );
    final midiLost = context.select<MidiSetupCubit, bool>(
      (cubit) => cubit.state.connection.connectivity == MidiConnectivity.lost,
    );
    if (!deviceLost && !midiLost) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (deviceLost)
          _LostBanner(
            key: const Key('connectivity_banner_device'),
            message: l10n.deviceLostBanner,
            actionLabel: l10n.deviceLostBannerAction,
            actionKey: const Key('connectivity_banner_device_action'),
            severity: _LostSeverity.device,
            onAction: context.read<SettingsTrayCubit>().openAudioDevice,
          ),
        if (midiLost)
          _LostBanner(
            key: const Key('connectivity_banner_midi'),
            message: l10n.midiLostBanner,
            actionLabel: l10n.midiLostBannerAction,
            actionKey: const Key('connectivity_banner_midi_action'),
            severity: _LostSeverity.midi,
            onAction: context.read<SettingsTrayCubit>().openControl,
          ),
        const SizedBox(height: _gapBelow),
      ],
    );
  }
}

/// Which loss a strip states — and with it the whole colour family.
enum _LostSeverity {
  /// The pinned audio interface is absent: record red, the engine is stopped.
  device,

  /// The pinned MIDI controller is absent: warning amber, loops keep playing.
  midi,
}

/// One strip of the stack: the pen's `Banner` component as `STAGE /
/// device-lost` instantiates it — tinted fill, 1px line border, radius 11,
/// the 8px dot, the sentence, and the single action button.
class _LostBanner extends StatelessWidget {
  const _LostBanner({
    required this.message,
    required this.actionLabel,
    required this.actionKey,
    required this.severity,
    required this.onAction,
    super.key,
  });

  final String message;
  final String actionLabel;
  final Key actionKey;
  final _LostSeverity severity;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final (dot, tint, line) = switch (severity) {
      _LostSeverity.device => (
        surface.rec,
        surface.recTint,
        surface.recLine,
      ),
      _LostSeverity.midi => (
        surface.warning,
        surface.warningTint,
        surface.warningLine,
      ),
    };
    return Container(
      // The pen's [11, 15] padding around a 38-tall action button.
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 15),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: line),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AppText(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 15,
                height: 1.2,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ConsoleSmallButton(
            key: actionKey,
            label: actionLabel,
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}
