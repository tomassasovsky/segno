import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_command.dart';
import 'package:segno/visualizer/readout_panel/readout_loop_panel.dart';
import 'package:segno/visualizer/waveform_window.dart';

/// The readout with its Loop panel (#1654, layout B): the readout as it has
/// always been until its footer strip is touched, then the panel until Done
/// or [idleClose] without a touch. Whether the panel is open is the
/// readout's own state; only the commands cross the screen link.
///
/// While the console is idle-dimmed a barrier covers both, so the touch
/// that wakes the console presses nothing, as on the main screen.
class ReadoutControls extends StatefulWidget {
  /// Creates a [ReadoutControls].
  const ReadoutControls({
    required this.readout,
    required this.frame,
    required this.waveform,
    required this.onCommand,
    super.key,
  });

  /// How long the panel stays open without a touch.
  static const Duration idleClose = Duration(seconds: 10);

  /// What the main screen last pushed.
  final PerformanceReadout readout;

  /// The selected track's waveform and playhead, for the panel's small one.
  final ValueListenable<WaveformFrame> frame;

  /// The readout's waveform region.
  final Widget waveform;

  /// Sends a change to the main screen.
  final ValueChanged<ReadoutCommand> onCommand;

  @override
  State<ReadoutControls> createState() => _ReadoutControlsState();
}

class _ReadoutControlsState extends State<ReadoutControls> {
  bool _open = false;
  Timer? _closeTimer;

  void _openPanel() {
    setState(() => _open = true);
    _keepOpen();
  }

  void _close() {
    _closeTimer?.cancel();
    _closeTimer = null;
    if (mounted && _open) setState(() => _open = false);
  }

  void _keepOpen() {
    _closeTimer?.cancel();
    _closeTimer = Timer(ReadoutControls.idleClose, _close);
  }

  void _send(ReadoutCommand command) {
    // A held step sends without new touches; it is a touch all the same.
    _keepOpen();
    widget.onCommand(command);
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final face = _open
        ? Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _keepOpen(),
            child: ReadoutLoopPanel(
              readout: widget.readout,
              frame: widget.frame,
              onCommand: _send,
              onDone: _close,
            ),
          )
        : ConsoleReadoutView(
            readout: widget.readout,
            waveform: widget.waveform,
            onOpenControls: _openPanel,
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        face,
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !widget.readout.dimmed,
            child: const ExcludeSemantics(
              child: Listener(
                key: Key('readout_dim_wake'),
                behavior: HitTestBehavior.opaque,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
