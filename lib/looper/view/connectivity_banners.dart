import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The stage's one standing loss condition: the pinned audio interface is
/// gone, so the engine is stopped and nothing is heard — the loudest fact the
/// console has. Drawn to the pen's `STAGE / device-lost` in the record red.
///
/// A banner and never a toast or a dialog (`c/device-lost`): a toast is for
/// an *event*, this is a *condition* — the banner holds the screen exactly as
/// long as the interface is absent and leaves on its own the moment it
/// returns, and a dialog would steal the transport mid-song.
///
/// **It stands in for the engine-stopped banner, never beside it.** When the
/// engine is stopped *because* the device is gone, this is the only banner on
/// the stage: `TracksView` suppresses the generic `AudioNotRunningBanner`
/// while the loss condition holds, so the two never say "engine stopped"
/// twice (#453). A stopped engine with a device still present keeps the
/// generic banner as before.
///
/// The MIDI controller is deliberately NOT here: losing it is low-stakes —
/// the loops keep playing — so it surfaces as a transient toast, not a
/// standing bar (see `_showMidiConnectivityToast` in `app.dart`).
///
/// The banner carries the one action that ends it: **Open setup** opens the
/// tray's Audio domain on the Device tab — navigation through
/// [SettingsTrayCubit], no new routing. The action hugs the message rather
/// than floating to the far edge, so the sentence and the button read as one
/// unit. Mounted by `TracksView` on console AND desktop builds: the condition
/// is exactly as true in a window as on the panel.
class ConnectivityBanners extends StatelessWidget {
  /// Creates a [ConnectivityBanners].
  const ConnectivityBanners({super.key});

  /// The gap under the banner: the pen's 10 on the console stage (the run's
  /// own rhythm), 14 on desktop where the surrounding chrome — the toolbar
  /// gap and the not-running banner's — steps by 14.
  static const double _gapBelow = 10;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final deviceLost = context.select<AudioSetupCubit, bool>(
      (cubit) => cubit.state.deviceConnectivity == DeviceConnectivity.lost,
    );
    if (!deviceLost) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LostBanner(
          key: const Key('connectivity_banner_device'),
          message: l10n.deviceLostBanner,
          actionLabel: l10n.deviceLostBannerAction,
          actionKey: const Key('connectivity_banner_device_action'),
          onAction: context.read<SettingsTrayCubit>().openAudioDevice,
        ),
        const SizedBox(height: _gapBelow),
      ],
    );
  }
}

/// The device-lost strip: the pen's `Banner` component as `STAGE /
/// device-lost` instantiates it — record-red tinted fill, 1px rec line
/// border, radius 11, the 8px dot, the sentence, and the single action button
/// hugging it.
class _LostBanner extends StatelessWidget {
  const _LostBanner({
    required this.message,
    required this.actionLabel,
    required this.actionKey,
    required this.onAction,
    super.key,
  });

  final String message;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      // The pen's [11, 15] padding around a 38-tall action button.
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 15),
      decoration: BoxDecoration(
        color: surface.recTint,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: surface.recLine),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: surface.rec,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          // Loose, not `Expanded`: the sentence sizes to its own content so
          // the button sits right after it rather than being flung to the
          // far edge with a wall of dead space between (`c/device-lost`). It
          // still shrinks and ellipsises before it would overflow a narrow
          // stage.
          Flexible(
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
