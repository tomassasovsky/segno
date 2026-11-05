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
    this.refusals = const Stream.empty(),
    super.key,
  });

  /// How long the panel stays open without a touch.
  static const Duration idleClose = Duration(seconds: 10);

  /// How long the panel says why a command was refused: as long as the main
  /// screen shows a warning notice.
  static const Duration refusalFor = Duration(seconds: 6);

  /// What the main screen last pushed.
  final PerformanceReadout readout;

  /// The selected track's waveform and playhead, for the panel's small one.
  final ValueListenable<WaveformFrame> frame;

  /// The readout's waveform region.
  final Widget waveform;

  /// Sends a change to the main screen.
  final ValueChanged<ReadoutCommand> onCommand;

  /// Each command the main screen refused.
  final Stream<ReadoutRefusal> refusals;

  @override
  State<ReadoutControls> createState() => _ReadoutControlsState();
}

class _ReadoutControlsState extends State<ReadoutControls> {
  bool _open = false;
  Timer? _closeTimer;
  StreamSubscription<ReadoutRefusal>? _refusalSub;
  ReadoutRefusal? _refusal;
  Timer? _refusalTimer;

  @override
  void initState() {
    super.initState();
    _refusalSub = widget.refusals.listen(_onRefused);
  }

  @override
  void didUpdateWidget(ReadoutControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refusals != oldWidget.refusals) {
      unawaited(_refusalSub?.cancel());
      _refusalSub = widget.refusals.listen(_onRefused);
    }
  }

  /// Says why [refusal]'s command was refused, while the panel that sent it
  /// is open.
  void _onRefused(ReadoutRefusal refusal) {
    if (!mounted || !_open) return;
    setState(() => _refusal = refusal);
    _refusalTimer?.cancel();
    _refusalTimer = Timer(ReadoutControls.refusalFor, _clearRefusal);
  }

  void _clearRefusal() {
    _refusalTimer?.cancel();
    _refusalTimer = null;
    if (mounted && _refusal != null) setState(() => _refusal = null);
  }

  void _openPanel() {
    setState(() => _open = true);
    _keepOpen();
  }

  void _close() {
    _closeTimer?.cancel();
    _closeTimer = null;
    _clearRefusal();
    if (mounted && _open) setState(() => _open = false);
  }

  void _keepOpen() {
    _closeTimer?.cancel();
    _closeTimer = Timer(ReadoutControls.idleClose, _close);
  }

  void _send(ReadoutCommand command) {
    // A held step sends without new touches; it is a touch all the same.
    _keepOpen();
    // A new change replaces what the last refusal said.
    _clearRefusal();
    widget.onCommand(command);
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _refusalTimer?.cancel();
    unawaited(_refusalSub?.cancel());
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
              refusal: _refusal,
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
