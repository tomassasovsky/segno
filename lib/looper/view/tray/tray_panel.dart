import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray_metrics.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/view/tuner_tray_panel.dart';

/// The tray's contents once open: an opaque sheet holding the tuner.
///
/// The tuner is the one face left (#1199): every other face moved to a
/// Settings destination or the FX page, and the rail that chose between them
/// went with them.
///
/// The shell never unmounts this panel; it slides it off screen. The tuner is
/// built only while some of the sheet is showing (from the first frame of an
/// opening drag until a close has finished sliding), so a stage that never
/// opens the tray never builds it, and it listens only while the tray is open.
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
  /// Whether the sheet is anywhere on screen: set as soon as it starts to
  /// open, cleared once a close has finished sliding, so the tuner does not
  /// vanish from a sheet that is still on its way up.
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final state = context.watch<SettingsTrayCubit>().state;
    final open = state.dragProgress > 0;
    if (open) _showing = true;

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
        onEnd: () {
          if (!open && _showing) setState(() => _showing = false);
        },
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
            // Inside the hairline, so the face stops at the seam instead of
            // crossing it.
            padding: const EdgeInsets.only(bottom: 1),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
                child: SizedBox.expand(
                  child: _showing
                      ? TunerTrayPanel(active: open)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
