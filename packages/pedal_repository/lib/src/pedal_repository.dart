import 'dart:async';

import 'package:pedal_repository/src/pedal_event.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// Whether the console board is on the other end of the link.
///
/// Decided by traffic, not by opening a port: the board says hello once a
/// second, and the link counts as [connected] from the first hello until
/// none has arrived for `PedalRepository.helloTimeout`.
enum PedalLinkStatus {
  /// No board has been heard from (yet, or for a while).
  disconnected,

  /// The board is talking.
  connected,
}

/// Owns the pedal link: turns inbound board messages into [PedalEvent]s, tracks
/// whether the board is alive, and pushes [PedalStateFrame]s and the loop-top
/// pulse out. Hardware-free: everything native is behind the [PedalLink].
class PedalRepository {
  /// Creates a [PedalRepository] over [link].
  ///
  /// [clock] stamps button events for the cubit's tap / long-press timing; it
  /// defaults to a monotonic stopwatch. [helloTimeout] is how long the board
  /// may stay silent before the link reads as disconnected.
  PedalRepository(
    PedalLink link, {
    Duration Function()? clock,
    this.helloTimeout = const Duration(seconds: 3),
  }) : _link = link {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? (() => stopwatch.elapsed);
    _inboundSub = _link.inbound.listen(_onMessage);
  }

  final PedalLink _link;
  late final Duration Function() _clock;
  late final StreamSubscription<PedalLinkMessage> _inboundSub;

  /// How long without a hello before the board counts as gone.
  final Duration helloTimeout;

  final StreamController<PedalEvent> _events =
      StreamController<PedalEvent>.broadcast();
  final StreamController<PedalLinkStatus> _statusChanges =
      StreamController<PedalLinkStatus>.broadcast();

  PedalLinkStatus _status = PedalLinkStatus.disconnected;
  String? _firmwareVersion;
  Timer? _helloWatchdog;
  bool _disposed = false;

  /// Decoded pedal inputs (button presses/releases, encoder detents).
  Stream<PedalEvent> get events => _events.stream;

  /// Link status transitions.
  Stream<PedalLinkStatus> get statusChanges => _statusChanges.stream;

  /// The current link status.
  PedalLinkStatus get status => _status;

  /// The firmware version the board last announced (`major.minor`), or
  /// `null` before the first hello.
  String? get firmwareVersion => _firmwareVersion;

  /// Sends [frame] to the board.
  void pushState(PedalStateFrame frame) {
    if (_disposed) return;
    _link.send(StateMessage(frame));
  }

  /// Sends the loop-top pulse.
  void sendLoopTop() {
    if (_disposed) return;
    _link.send(const LoopTopMessage());
  }

  void _onMessage(PedalLinkMessage message) {
    switch (message) {
      case ButtonMessage(:final button, :final pressed):
        _emit(
          pressed
              ? ButtonPressed(button, timestamp: _clock())
              : ButtonReleased(button, timestamp: _clock()),
        );
      case EncoderMessage(:final delta):
        _emit(EncoderDelta(delta));
      case HelloMessage():
        _firmwareVersion = message.firmwareVersion;
        _helloWatchdog?.cancel();
        _helloWatchdog = Timer(
          helloTimeout,
          () => _setStatus(PedalLinkStatus.disconnected),
        );
        _setStatus(PedalLinkStatus.connected);
      case StateMessage() || LoopTopMessage():
        break; // outbound types; a board never sends them
    }
  }

  void _emit(PedalEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _setStatus(PedalLinkStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  /// Cancels the inbound subscription, releases the link, and closes the
  /// streams. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _helloWatchdog?.cancel();
    await _inboundSub.cancel();
    await _link.dispose();
    await _events.close();
    await _statusChanges.close();
  }
}
