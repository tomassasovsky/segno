import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/view/console/audio_tray_panel.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/loop/loop_tray_panel.dart';
import 'package:segno/looper/view/signal/signal_tray_panel.dart';
import 'package:segno/looper/view/tracks/tracks_tray_panel.dart';
import 'package:segno/looper/view/tray/tray_brightness_popover.dart';
import 'package:segno/looper/view/tray/tray_metrics.dart';
import 'package:segno/looper/view/tray/tray_navigation_rail.dart';
import 'package:segno/network/network_tray_panel.dart';
import 'package:segno/system/view/system_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/view/tuner_tray_panel.dart';

/// The tray's contents once open — near-fullscreen frosted sheet, split into
/// a persistent [TrayNavigationRail] and the face it selects.
///
/// The face swap is a plain switch inside the sheet, never a full-screen
/// route: config is an overlay you drop out of with one gesture, so it never
/// routes the performer away from the stage view. The `KeyedSubtree` on the
/// destination is what makes the swap discard the outgoing face's state
/// rather than let Flutter reuse its element for the incoming one.
class TrayPanel extends StatefulWidget {
  /// Creates a [TrayPanel].
  const TrayPanel({this.motion = kTrayMotion, super.key});

  /// How long the sheet's shadow takes to reach a new strength.
  ///
  /// Handed down from the shell so it is the *same* duration the sheet slides
  /// on — including the [Duration.zero] the shell uses mid-drag and under
  /// reduced motion. A shadow that read `dragProgress` directly would snap,
  /// because a tap moves that value between 0 and 1 in a single frame while
  /// the sheet takes [kTrayMotion] to get there.
  final Duration motion;

  @override
  State<TrayPanel> createState() => _TrayPanelState();
}

class _TrayPanelState extends State<TrayPanel> {
  /// Whether the brightness popover is up. Local, not tray state: it is a
  /// drawer on one button, not a place the console can be in — nothing else
  /// reads it, and it must not survive a close-and-reopen.
  bool _brightness = false;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final state = context.watch<SettingsTrayCubit>().state;
    // `TrayPanel` is never unmounted — the shell translates it off-screen —
    // so a popover left open stays open, and `closeTray` resets the
    // destination under it. Reopening would then float it over a face it was
    // never opened from. Cleared here rather than in a listener because this
    // already rebuilds on every drag frame.
    if (state.dragProgress == 0 && _brightness) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _brightness = false);
      });
    }

    return Material(
      color: Colors.transparent,
      // The shadow FADES IN with the sheet, and that is not decoration. A
      // closed tray is parked with its bottom edge exactly on the top of the
      // screen, so a shadow at full strength there would cast its 19px offset
      // and 48px blur straight down over the stage — a dark band under the
      // pull tab that never goes away.
      //
      // Animated rather than read straight off `dragProgress`, because that
      // value only moves continuously while a finger is on the handle. A TAP
      // snaps it between 0 and 1 in one frame while the sheet takes [motion]
      // to slide, so a shadow driven by it directly would pop off a sheet
      // still on screen (closing) and paint the band it exists to prevent
      // (opening). [motion] is the shell's own — zero mid-drag, so the drag
      // still tracks the finger exactly.
      child: TweenAnimationBuilder<double>(
        duration: widget.motion,
        curve: kTrayMotionCurve,
        tween: Tween<double>(end: state.dragProgress.clamp(0.0, 1.0)),
        builder: (context, lift, child) => DecoratedBox(
          // Opaque, and the CARD tone rather than the page's — measured off
          // the mockups' tray layer. It was a frosted 78% page fill behind a
          // 24px blur, which was not only the wrong colour: a translucent
          // sheet let the stage's waveforms move behind the settings being
          // read.
          //
          // The shadow lifts the sheet off the tracks grid, and the hairline
          // along the bottom edge is the seam the drag handle rides on.
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(kTraySheetRadius),
            ),
            border: Border(bottom: BorderSide(color: surface.borderStrong)),
            boxShadow: [
              BoxShadow(
                color: surface.dropShadow.withValues(
                  alpha: surface.dropShadow.a * lift,
                ),
                offset: const Offset(0, 19),
                blurRadius: 48,
              ),
            ],
          ),
          child: child,
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(kTraySheetRadius),
          ),
          child: Padding(
            // Inside the hairline, so the rail's own right-hand rule stops at
            // the seam instead of crossing it.
            padding: const EdgeInsets.only(bottom: 1),
            child: Stack(
              children: [
                SafeArea(
                  top: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TrayNavigationRail(
                        onBrightness: () =>
                            setState(() => _brightness = !_brightness),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
                          // The config faces keep a fixed
                          // [_TrayFaceFrame] footprint and are centred
                          // individually, since a WiFi list stretched across
                          // a 1080p sheet reads worse than a centred panel.
                          child: KeyedSubtree(
                            key: ValueKey(state.destination),
                            child: switch (state.destination) {
                              SettingsTrayDestination.signal =>
                                const _TrayFaceFrame(child: SignalTrayPanel()),
                              SettingsTrayDestination.control =>
                                const _TrayFaceFrame(child: ControlTrayPanel()),
                              SettingsTrayDestination.loop =>
                                const _TrayFaceFrame(child: LoopTrayPanel()),
                              SettingsTrayDestination.tracks =>
                                const _TrayFaceFrame(child: TracksTrayPanel()),
                              SettingsTrayDestination.audio =>
                                const _TrayFaceFrame(child: AudioTrayPanel()),
                              SettingsTrayDestination.tuner =>
                                const _TrayFaceFrame(child: TunerTrayPanel()),
                              SettingsTrayDestination.network =>
                                const _TrayFaceFrame(child: NetworkTrayPanel()),
                              SettingsTrayDestination.system =>
                                const _TrayFaceFrame(child: SystemTrayPanel()),
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Over the rail and the face both, since it hangs off the
                // rail's edge into the pane. Last in the Stack so its scrim
                // takes the taps before the panel's own dismiss detector,
                // which would otherwise close the whole tray.
                if (_brightness)
                  Positioned.fill(
                    child: TrayBrightnessPopover(
                      onDismiss: () => setState(() => _brightness = false),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Footprint for the in-tray config faces — sizing only; no extra card
/// chrome. Lists scroll inside the panel.
///
/// One variant now. The fixed 980x700 landscape box went with the pedal plate
/// it existed for: the Control face is a list, and a list has no aspect ratio
/// to preserve.
class _TrayFaceFrame extends StatelessWidget {
  /// A face that fills the sheet beside the rail.
  ///
  /// The default, because that is what the rail is for: the destination you
  /// picked is the panel, so it should be the panel. These faces used to be
  /// pinned to a fixed 520x680 box and centred, which left a list floating in
  /// the middle of a mostly empty sheet no matter how much room was beside the
  /// rail (#493).
  const _TrayFaceFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}
