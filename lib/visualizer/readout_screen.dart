import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';
import 'package:segno/visualizer/screen_link.dart';
import 'package:segno/visualizer/waveform_window.dart';

/// Entrypoint for the readout when the embedder runs it as its own engine on
/// its own output (ivi-homescreen on the appliance).
///
/// It owns no audio engine and no repositories: it draws what the main screen
/// sends over the screen link and sends the volume overlay's commands back.
Future<void> runReadoutScreen({
  PortDirectory directory = const IsolateNameServerDirectory(),
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final link = ReadoutScreenLink(directory: directory)..start();
  runApp(ReadoutScreen(link: link));
}

/// The readout's end of the screen link: the state the main screen pushes, and
/// the way back for the volume overlay's commands.
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

  /// Sends a volume-overlay command to the main screen. Fire-and-forget, like
  /// on the GTK path: a dropped fader move is corrected by the next one.
  void sendControl(ReadoutControl control) {
    _mainPort()?.send({
      'op': ScreenLinkOp.control,
      'control': sendableCopy(control.toMap()),
    });
  }

  /// Closes the inbox and the notifiers.
  void dispose() {
    _inbox?.close();
    visible.dispose();
    frame.dispose();
    readout.dispose();
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
    }
  }

  void _ack(Object? seq) {
    if (seq is! int) return;
    _mainPort()?.send({'op': ScreenLinkOp.ack, 'seq': seq});
  }
}

/// The readout screen: [WaveformWindowApp] while the main screen wants it
/// drawn, otherwise the readout's own background with nothing on it.
class ReadoutScreen extends StatelessWidget {
  /// Creates a [ReadoutScreen] drawing [link]'s state.
  const ReadoutScreen({required this.link, super.key});

  /// The readout's end of the screen link.
  final ReadoutScreenLink link;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: link.visible,
      builder: (context, visible, _) => visible
          ? WaveformWindowApp(
              frame: link.frame,
              readout: link.readout,
              title: 'Segno — Output',
              onControl: link.sendControl,
            )
          : ColoredBox(color: AppTheme.neon.scaffoldBackgroundColor),
    );
  }
}
