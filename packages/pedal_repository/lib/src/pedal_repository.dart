import 'dart:async';

import 'package:pedal_repository/src/pedal_event.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
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

  /// The board is talking and speaks this build's link protocol.
  connected,

  /// The board is talking, but its hello names a link protocol this build
  /// does not speak: its firmware and this app were built against different
  /// revisions of `pedal_link.h`. The repository then drops its footswitch
  /// and encoder messages (a reordered button table could map a stomp onto
  /// Clear) and sends it no frames, until one side is updated.
  incompatible,
}

/// Owns the pedal link: turns inbound board messages into [PedalEvent]s, tracks
/// whether the board is alive, and pushes [PedalStateFrame]s and the loop-top
/// pulse out. Hardware-free: everything native is behind the [PedalLink].
///
/// Liveness is one mechanism, driven by the board: every hello is answered
/// with the last pushed frame, so a board that just (re)connected — or that
/// missed a frame — is current within a second, and its own frame watchdog
/// sees traffic while segno runs. Callers push only on change.
class PedalRepository {
  /// Creates a [PedalRepository] over [link].
  ///
  /// [clock] stamps button events for the cubit's tap / long-press timing; it
  /// defaults to a monotonic stopwatch. [helloTimeout] is how long the board
  /// may stay silent before the link reads as disconnected. [log] receives
  /// one line per link status change — the app hands it its persistent log,
  /// so a dark panel has a breadcrumb.
  PedalRepository(
    PedalLink link, {
    Duration Function()? clock,
    this.helloTimeout = const Duration(seconds: 3),
    void Function(String message)? log,
  }) : _link = link,
       _log = log {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? (() => stopwatch.elapsed);
    _inboundSub = _link.inbound.listen(_onMessage);
  }

  final PedalLink _link;
  final void Function(String message)? _log;
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
  PedalStateFrame? _lastFrame;
  Timer? _helloWatchdog;
  bool _disposed = false;

  /// Decoded pedal inputs (button presses/releases, encoder detents).
  Stream<PedalEvent> get events => _events.stream;

  /// Link status transitions. Also fires, with the same status, when a
  /// talking board announces a different firmware version — the board was
  /// reflashed under a running app.
  Stream<PedalLinkStatus> get statusChanges => _statusChanges.stream;

  /// The current link status.
  PedalLinkStatus get status => _status;

  /// The firmware version the board announced (`major.minor`) while it is
  /// talking, or `null` while it is not.
  String? get firmwareVersion => _firmwareVersion;

  /// Sends [frame] to the board and remembers it as the frame every later
  /// hello is answered with. Dropped while the board is
  /// [PedalLinkStatus.incompatible].
  void pushState(PedalStateFrame frame) {
    if (_disposed) return;
    _lastFrame = frame;
    if (_status == PedalLinkStatus.incompatible) return;
    _link.send(StateMessage(frame));
  }

  /// Sends the loop-top pulse. Dropped while the board is incompatible.
  void sendLoopTop() {
    if (_disposed || _status == PedalLinkStatus.incompatible) return;
    _link.send(const LoopTopMessage());
  }

  void _onMessage(PedalLinkMessage message) {
    switch (message) {
      case ButtonMessage(:final button, :final pressed):
        if (_status == PedalLinkStatus.incompatible) return;
        _emit(
          pressed
              ? ButtonPressed(button, timestamp: _clock())
              : ButtonReleased(button, timestamp: _clock()),
        );
      case EncoderMessage(:final delta):
        if (_status == PedalLinkStatus.incompatible) return;
        _emit(EncoderDelta(delta));
      case HelloMessage():
        _onHello(message);
      case StateMessage() || LoopTopMessage():
        break; // outbound types; a board never sends them
    }
  }

  void _onHello(HelloMessage hello) {
    final versionChanged = _firmwareVersion != hello.firmwareVersion;
    _firmwareVersion = hello.firmwareVersion;
    _helloWatchdog?.cancel();
    _helloWatchdog = Timer(helloTimeout, _onHelloTimeout);
    if (hello.protocolVersion == PedalLinkCodec.protocolVersion) {
      _setStatus(
        PedalLinkStatus.connected,
        force: versionChanged,
        detail: () => 'firmware ${hello.firmwareVersion}',
      );
      // Answer every hello with the current frame: the reconnect re-push
      // and the keep-alive in one place, paced by the board.
      final frame = _lastFrame;
      if (frame != null) _link.send(StateMessage(frame));
    } else {
      _setStatus(
        PedalLinkStatus.incompatible,
        force: versionChanged,
        detail: () =>
            'firmware ${hello.firmwareVersion} speaks link protocol '
            '${hello.protocolVersion}, this build speaks '
            '${PedalLinkCodec.protocolVersion}',
      );
    }
  }

  void _onHelloTimeout() {
    _firmwareVersion = null;
    _setStatus(
      PedalLinkStatus.disconnected,
      detail: () => 'no hello for ${helloTimeout.inSeconds} s',
    );
  }

  void _emit(PedalEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _setStatus(
    PedalLinkStatus status, {
    required String Function() detail,
    bool force = false,
  }) {
    if (_status == status && !force) return;
    _status = status;
    _log?.call('pedal link: ${status.name} (${detail()})');
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  /// Cancels the inbound subscription, releases the link, and closes the
  /// streams. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _helloWatchdog?.cancel();
    _firmwareVersion = null;
    _setStatus(PedalLinkStatus.disconnected, detail: () => 'link released');
    await _inboundSub.cancel();
    await _link.dispose();
    await _events.close();
    await _statusChanges.close();
  }
}
