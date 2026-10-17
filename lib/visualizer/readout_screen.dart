import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:segno/settings/touch_calibration/view/calibration_target.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/screen_link.dart';
import 'package:segno/visualizer/waveform_window.dart';

/// Entrypoint for the readout, which ivi-homescreen runs as its own engine on
/// the 7"'s output.
///
/// It owns no audio engine and no repositories: it draws what the main screen
/// sends over the screen link, and reports a touch on it back as activity, or
/// as a calibration tap while the main screen is calibrating its touch.
Future<void> runReadoutScreen({
  PortDirectory directory = const IsolateNameServerDirectory(),
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final link = ReadoutScreenLink(directory: directory)..start();
  runApp(ReadoutScreen(link: link));
}

/// A touch calibration step on the readout: the `target` to tap, in the
/// readout's normalized coordinates, and the `label` saying which step it is.
typedef ReadoutCalibration = ({({double x, double y}) target, String label});

/// The readout's end of the screen link: the state the main screen pushes, and
/// the way back for a touch on the readout.
class ReadoutScreenLink {
  /// Creates a [ReadoutScreenLink]; nothing is published until [start].
  ReadoutScreenLink({
    PortDirectory directory = const IsolateNameServerDirectory(),
  }) : _directory = directory;

  final PortDirectory _directory;
  ReceivePort? _inbox;
  SendPort? _main;

  /// Whether the main screen wants the readout drawn. False until it says so,
  /// so a disabled readout preference never flashes the readout at boot.
  final visible = ValueNotifier<bool>(false);

  /// The latest waveform frame.
  final frame = ValueNotifier<WaveformFrame>((
    samples: Float32List(0),
    progress: 0,
    selectedTrack: '',
  ));

  /// The latest performance readout.
  final readout = ValueNotifier<PerformanceReadout>(
    const PerformanceReadout(),
  );

  /// The calibration step on screen, or `null` when the readout is not being
  /// calibrated.
  final calibration = ValueNotifier<ReadoutCalibration?>(null);

  /// Publishes this end's inbox and announces it to the main screen, if the
  /// main screen is already up. If it is not, its greeting prompts the
  /// announcement later.
  void start() {
    if (_inbox != null) return;
    final inbox = _inbox = ReceivePort('segno screen link (readout)')
      ..listen(_onMessage);
    _directory.publish(screenLinkReadoutPort, inbox.sendPort);
    _announce();
  }

  /// Tells the main screen a player touched the readout. Fire-and-forget: the
  /// next touch says the same thing.
  void sendActivity() {
    _mainPort()?.send({'op': ScreenLinkOp.activity});
  }

  /// Tells the main screen where a calibration tap landed, in the readout's
  /// normalized coordinates.
  void sendCalibrationTap(({double x, double y}) tap) {
    _mainPort()?.send({
      'op': ScreenLinkOp.calibrationTap,
      'x': tap.x,
      'y': tap.y,
    });
  }

  /// Closes the inbox and the notifiers.
  void dispose() {
    _inbox?.close();
    visible.dispose();
    frame.dispose();
    readout.dispose();
    calibration.dispose();
  }

  SendPort? _mainPort() => _main ??= _directory.lookup(screenLinkMainPort);

  void _announce() {
    // An announcement means "I hold nothing": the main screen drops its diffs
    // and resends everything, so whatever is on screen now is stale.
    _main = null;
    _mainPort()?.send({'op': ScreenLinkOp.ready, 'port': _inbox!.sendPort});
  }

  void _onMessage(Object? message) {
    if (message is! Map<Object?, Object?>) return;
    switch (message['op']) {
      case ScreenLinkOp.hello:
        _announce();
      case ScreenLinkOp.show:
        visible.value = true;
      case ScreenLinkOp.hide:
        visible.value = false;
        // Hidden means holding nothing: the next show starts blank and is
        // re-seeded, rather than flashing whatever the rig showed before it
        // was hidden.
        frame.value = (samples: Float32List(0), progress: 0, selectedTrack: '');
        readout.value = const PerformanceReadout();
      case ScreenLinkOp.waveform:
        final samples = unpackSamples(message['samples']);
        frame.value = waveformFrameFrom({
          'progress': message['progress'],
          'selectedTrack': message['selectedTrack'],
          'samples': ?samples,
        }, frame.value);
        _ack(message['seq']);
      case ScreenLinkOp.readout:
        final map = message['readout'];
        if (map is Map<Object?, Object?>) {
          readout.value = PerformanceReadout.fromMap(map);
        }
        _ack(message['seq']);
      case ScreenLinkOp.calibrate:
        final target = message['target'];
        final label = message['label'];
        calibration.value =
            target is List &&
                target.length == 2 &&
                target.every((v) => v is num)
            ? (
                target: (
                  x: (target[0] as num).toDouble(),
                  y: (target[1] as num).toDouble(),
                ),
                label: label is String ? label : '',
              )
            : null;
    }
  }

  void _ack(Object? seq) {
    if (seq is! int) return;
    _mainPort()?.send({'op': ScreenLinkOp.ack, 'seq': seq});
  }
}

/// The readout screen: a calibration step while the main screen is
/// calibrating the 7"'s touch; otherwise [WaveformWindowApp] while the main
/// screen wants it drawn, or the readout's own background with nothing on it.
class ReadoutScreen extends StatelessWidget {
  /// Creates a [ReadoutScreen] drawing [link]'s state.
  const ReadoutScreen({required this.link, super.key});

  /// The readout's end of the screen link.
  final ReadoutScreenLink link;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReadoutCalibration?>(
      valueListenable: link.calibration,
      builder: (context, calibration, _) {
        if (calibration != null) {
          return ReadoutCalibrationFace(
            calibration: calibration,
            onTap: link.sendCalibrationTap,
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: link.visible,
          builder: (context, visible, _) => visible
              ? WaveformWindowApp(
                  frame: link.frame,
                  readout: link.readout,
                  onActivity: link.sendActivity,
                )
              : ColoredBox(color: AppTheme.neon.scaffoldBackgroundColor),
        );
      },
    );
  }
}

/// The 7" while its touch is calibrated: the calibration area's ground, the
/// target to tap, and which step it is. Every tap goes back to the main
/// screen, which does the measuring, normalized to the whole panel because
/// that is the space the touch calibration matrix maps onto.
class ReadoutCalibrationFace extends StatelessWidget {
  /// Creates a [ReadoutCalibrationFace].
  const ReadoutCalibrationFace({
    required this.calibration,
    required this.onTap,
    super.key,
  });

  /// The step on screen.
  final ReadoutCalibration calibration;

  /// Called with each tap, normalized to the panel.
  final void Function(({double x, double y}) tap) onTap;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.neon,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            final surface = context.surface;
            return LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => onTap((
                    x: event.localPosition.dx / size.width,
                    y: event.localPosition.dy / size.height,
                  )),
                  child: ColoredBox(
                    color: surface.background,
                    child: Stack(
                      children: [
                        PositionedCalibrationTarget(
                          target: calibration.target,
                          area: size,
                        ),
                        Positioned(
                          top: 16,
                          right: 20,
                          child: Text(
                            calibration.label,
                            key: const Key('readout_calibration_label'),
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 15,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
