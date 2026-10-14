import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/touch_calibration/cubit/touch_calibration_cubit.dart';
import 'package:segno/settings/touch_calibration/view/calibration_target.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

/// Settings > Displays > Touch calibration (pen 30): five targets to tap,
/// then three to try the result on before keeping it.
///
/// The main display is calibrated on this page. The Track display's targets
/// are drawn on the Track display itself, through the screen link, because
/// only a tap on that panel can measure it; this page mirrors where the
/// target is and carries the countdown and the buttons.
class TouchCalibrationPage extends StatelessWidget {
  /// Creates a [TouchCalibrationPage] for [screen].
  const TouchCalibrationPage({required this.screen, super.key});

  /// The panel being calibrated.
  final TouchScreen screen;

  /// The route that opens the page for [screen].
  static Route<void> route(TouchScreen screen) => MaterialPageRoute(
    builder: (_) => TouchCalibrationPage(screen: screen),
  );

  /// Where the capture targets sit, in the calibrated screen's normalized
  /// coordinates: the four corners pen 30 starts from, and the centre.
  static const List<TouchPoint> captureTargets = [
    (x: 0.12, y: 0.16),
    (x: 0.88, y: 0.16),
    (x: 0.88, y: 0.84),
    (x: 0.12, y: 0.84),
    (x: 0.5, y: 0.5),
  ];

  /// Where the test targets sit: away from the capture targets, so a hit
  /// shows the fit holds between them.
  static const List<TouchPoint> testTargets = [
    (x: 0.28, y: 0.3),
    (x: 0.72, y: 0.7),
    (x: 0.45, y: 0.78),
  ];

  @override
  Widget build(BuildContext context) {
    final readout = screen == TouchScreen.readout;
    return BlocProvider(
      create: (context) => TouchCalibrationCubit(
        client: context.read<TouchCalibrationClient>(),
        screen: screen,
        captureTargets: readout ? captureTargets : MainCalibrationArea.toScreen,
        testTargets: readout ? testTargets : MainCalibrationArea.testToScreen,
      )..start(),
      child: TouchCalibrationView(screen: screen),
    );
  }
}

/// The main display's calibration area in pen pixels, and how its targets
/// convert to the screen's normalized coordinates. The calibration matrix is
/// in whole-screen terms, so the area's targets and taps are converted before
/// they reach the cubit.
abstract final class MainCalibrationArea {
  /// The area in the 1920 x 1080 pen canvas: the workspace at (36, 124)
  /// under the 96 px top bar, and the area at (52, 56) in it.
  static const Rect rect = Rect.fromLTWH(88, 276, 1744, 660);

  /// [TouchCalibrationPage.captureTargets] as screen points.
  static final List<TouchPoint> toScreen = [
    for (final t in TouchCalibrationPage.captureTargets) areaToScreen(t),
  ];

  /// [TouchCalibrationPage.testTargets] as screen points.
  static final List<TouchPoint> testToScreen = [
    for (final t in TouchCalibrationPage.testTargets) areaToScreen(t),
  ];

  /// A point in the area's normalized coordinates, on the screen.
  static TouchPoint areaToScreen(TouchPoint p) => (
    x: (rect.left + p.x * rect.width) / kLoopPenSize.width,
    y: (rect.top + p.y * rect.height) / kLoopPenSize.height,
  );

  /// A screen point, in the area's normalized coordinates.
  static TouchPoint screenToArea(TouchPoint p) => (
    x: (p.x * kLoopPenSize.width - rect.left) / rect.width,
    y: (p.y * kLoopPenSize.height - rect.top) / rect.height,
  );
}

/// The calibration page's layout, under its [TouchCalibrationCubit].
class TouchCalibrationView extends StatefulWidget {
  /// Creates a [TouchCalibrationView].
  const TouchCalibrationView({required this.screen, super.key});

  /// The panel being calibrated.
  final TouchScreen screen;

  /// The Track display's mirror of its panel, 16:9 at the area's height.
  static const Size trackArea = Size(1186, 660);

  @override
  State<TouchCalibrationView> createState() => _TouchCalibrationViewState();
}

class _TouchCalibrationViewState extends State<TouchCalibrationView> {
  late final WaveformWindowService _link = context
      .read<WaveformWindowService>();

  bool get _readout => widget.screen == TouchScreen.readout;

  @override
  void initState() {
    super.initState();
    if (_readout) {
      _link.onCalibrationTap = context.read<TouchCalibrationCubit>().tap;
    }
  }

  @override
  void dispose() {
    if (_readout) {
      _link.onCalibrationTap = null;
      unawaited(_link.showCalibrationTarget(null));
    }
    super.dispose();
  }

  /// Mirrors the cubit's target onto the Track display. Unreachable means
  /// the panel went away: nothing can be measured, so the calibration ends.
  Future<void> _mirror(TouchCalibrationState state) async {
    final target = state.target;
    final shown = await _link.showCalibrationTarget(
      target,
      label: target == null ? '' : _stepLabel(context.l10n, state),
    );
    if (!shown && mounted) context.read<TouchCalibrationCubit>().cancel();
  }

  void _cancel() => context.read<TouchCalibrationCubit>().cancel();

  void _stage() => Navigator.popUntil(context, (route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final display = _readout
        ? l10n.displaysTrackDisplay
        : l10n.displaysMainDisplay;
    return BlocListener<TouchCalibrationCubit, TouchCalibrationState>(
      listener: (context, state) {
        switch (state.phase) {
          case .kept || .reverted:
            Navigator.maybePop(context);
          case .capture || .test:
            if (_readout) unawaited(_mirror(state));
          // The 7" keeps its last target while a calibration is applied,
          // stored or reverted, rather than blanking for a moment.
          case .loading || .applying || .saving || .reverting || .failed:
            return;
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: LoopSettingsFrame(
              crumb: l10n.settingsCrumb(l10n.settingsDisplaysTitle),
              title: l10n.touchCalibrationTitle(display),
              onBack: _cancel,
              onStage: _stage,
              actions: LoopOutlinedButton(
                key: const Key('touch_calibration_cancel'),
                width: 125,
                label: l10n.cancel,
                onTap: _cancel,
              ),
              children: [
                Positioned(
                  left: MainCalibrationArea.rect.left,
                  top: 124,
                  width: MainCalibrationArea.rect.width,
                  child: _Instruction(readout: _readout),
                ),
                Positioned(
                  left: _readout
                      ? MainCalibrationArea.rect.left +
                            (MainCalibrationArea.rect.width -
                                    TouchCalibrationView.trackArea.width) /
                                2
                      : MainCalibrationArea.rect.left,
                  top: MainCalibrationArea.rect.top - kLoopTopBarHeight,
                  child: _readout ? const _TrackMirror() : const _MainArea(),
                ),
                Positioned(
                  left: MainCalibrationArea.rect.left,
                  top: 124 + 740,
                  width: MainCalibrationArea.rect.width,
                  height: 76,
                  child: const _Footer(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _stepLabel(AppLocalizations l10n, TouchCalibrationState state) =>
    state.phase == .test
    ? l10n.touchCalibrationTestStep(state.step + 1, state.steps)
    : l10n.touchCalibrationStep(state.step + 1, state.steps);

class _Instruction extends StatelessWidget {
  const _Instruction({required this.readout});

  final bool readout;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<TouchCalibrationCubit>().state;
    final testing = state.phase == .test;
    final heading = switch (state.phase) {
      .failed => l10n.touchCalibrationFailed,
      .test when state.target == null => l10n.touchCalibrationTestDone,
      .test => l10n.touchCalibrationTestInstruction,
      _ when readout => l10n.touchCalibrationTrackInstruction,
      _ => l10n.touchCalibrationInstruction,
    };
    final showStep =
        state.target != null && (testing || state.phase == .capture);
    return Row(
      children: [
        Expanded(
          child: AppText(
            heading,
            key: const Key('touch_calibration_heading'),
            style: TextStyle(
              color: state.phase == .failed
                  ? surface.warning
                  : surface.frameText,
              fontSize: 28,
              height: 1.1,
            ),
          ),
        ),
        if (showStep)
          AppText(
            _stepLabel(l10n, state),
            key: const Key('touch_calibration_step'),
            style: TextStyle(
              color: surface.frameCrumb,
              fontSize: 24,
              height: 1.1,
            ),
          ),
      ],
    );
  }
}

/// The main display's area: the target, and the taps it measures.
class _MainArea extends StatelessWidget {
  const _MainArea();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TouchCalibrationCubit>();
    final target = context.select<TouchCalibrationCubit, TouchPoint?>(
      (cubit) => cubit.state.target,
    );
    final size = MainCalibrationArea.rect.size;
    return Listener(
      key: const Key('touch_calibration_area'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => cubit.tap(
        MainCalibrationArea.areaToScreen((
          x: event.localPosition.dx / size.width,
          y: event.localPosition.dy / size.height,
        )),
      ),
      child: _AreaBox(
        size: size,
        target: target == null
            ? null
            : MainCalibrationArea.screenToArea(target),
      ),
    );
  }
}

/// Where the Track display's target is, drawn small here: the taps land on
/// the Track display, not on this mirror.
class _TrackMirror extends StatelessWidget {
  const _TrackMirror();

  @override
  Widget build(BuildContext context) {
    final target = context.select<TouchCalibrationCubit, TouchPoint?>(
      (cubit) => cubit.state.target,
    );
    return ExcludeSemantics(
      child: _AreaBox(
        key: const Key('touch_calibration_track_mirror'),
        size: TouchCalibrationView.trackArea,
        target: target,
      ),
    );
  }
}

class _AreaBox extends StatelessWidget {
  const _AreaBox({required this.size, required this.target, super.key});

  final Size size;
  final TouchPoint? target;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final target = this.target;
    // A DecoratedBox, not a Container: a Container insets its child by the
    // border, which would draw the target a pixel off where taps are
    // measured from.
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.meterTrack,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: surface.frameControlLine),
        ),
        child: Stack(
          children: [
            if (target != null)
              PositionedCalibrationTarget(target: target, area: size),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<TouchCalibrationCubit>();
    final state = context.watch<TouchCalibrationCubit>().state;
    final testing = state.phase == .test;
    final note = TextStyle(
      color: surface.frameCrumb,
      fontSize: 22,
      height: 1.1,
    );
    return Row(
      children: [
        Expanded(child: AppText(l10n.touchCalibrationPrevious, style: note)),
        if (testing) ...[
          AppText(
            l10n.touchCalibrationCountdown(state.secondsLeft),
            key: const Key('touch_calibration_countdown'),
            style: note,
          ),
          const SizedBox(width: 24),
          LoopOutlinedButton(
            key: const Key('touch_calibration_restart'),
            width: 128,
            label: l10n.touchCalibrationRestart,
            onTap: cubit.restart,
          ),
          const SizedBox(width: 23),
          LoopOutlinedButton(
            key: const Key('touch_calibration_keep'),
            width: 237,
            tone: LoopButtonTone.accent,
            label: l10n.touchCalibrationKeep,
            onTap: cubit.keep,
          ),
        ],
      ],
    );
  }
}
