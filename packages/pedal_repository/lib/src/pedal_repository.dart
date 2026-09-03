import 'dart:async';

import 'package:pedal_repository/src/pedal_event.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// Whether the console board is on the other end of the link.
///
/// Decided by traffic, not by opening a port: the board says hello every
/// [PedalLinkCodec.helloIntervalMs], and the link counts as [connected] from
/// the first hello until none has arrived for `PedalRepository.helloTimeout`.
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

/// Owns the pedal link: turns inbound board messages into [PedalEvent]s,
/// tracks whether the board is alive, and pushes [PedalStateFrame]s out.
/// Hardware-free: everything native is behind the [PedalLink].
///
/// Liveness is one mechanism, driven by the board: every hello is answered
/// with the last pushed frame, so a board that just (re)connected — or that
/// missed a frame — is current within a second, and its own frame watchdog
/// sees traffic while segno runs. A frame identical to the last one is not
/// sent again, so callers push freely.
///
/// [status] and [firmwareVersion] are read off the last hello heard: there is
/// no separate status to keep in step with it.
class PedalRepository {
  /// Creates a [PedalRepository] over [link].
  ///
  /// [clock] stamps button events for the cubit's tap / long-press timing; it
  /// defaults to a monotonic stopwatch. [helloTimeout] is how long the board
  /// may stay silent before the link reads as disconnected: three hellos, so
  /// one lost on the wire does not flap the status. [log] receives one line
  /// per link status change — the app hands it its persistent log, so a dark
  /// panel has a breadcrumb.
  PedalRepository(
    PedalLink link, {
    Duration Function()? clock,
    this.helloTimeout = const Duration(
      milliseconds: 3 * PedalLinkCodec.helloIntervalMs,
    ),
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

  /// The last hello heard, or `null` while the board is quiet.
  HelloMessage? _hello;
  PedalStateFrame? _lastFrame;
  Timer? _helloWatchdog;
  bool _goodbye = false;
  bool _disposed = false;

  /// Decoded pedal inputs (button presses/releases, encoder detents).
  Stream<PedalEvent> get events => _events.stream;

  /// Link status transitions. Also fires, with the same status, when a
  /// talking board announces a different firmware version — the board was
  /// reflashed under a running app.
  Stream<PedalLinkStatus> get statusChanges => _statusChanges.stream;

  /// The current link status.
  PedalLinkStatus get status => switch (_hello) {
    null => PedalLinkStatus.disconnected,
    HelloMessage(protocolVersion: PedalLinkCodec.protocolVersion) =>
      PedalLinkStatus.connected,
    HelloMessage() => PedalLinkStatus.incompatible,
  };

  /// The firmware version the board announced (`major.minor`) while it is
  /// talking, or `null` while it is not.
  String? get firmwareVersion => _hello?.firmwareVersion;

  /// Whether the board is talking a link protocol this build does not speak,
  /// in which case its button table cannot be trusted: a reordered one could
  /// map a stomp onto Clear.
  bool get _incompatible => _disposed || status == PedalLinkStatus.incompatible;

  /// Sends [frame] to the board unless it is the frame already showing, and
  /// remembers it as the frame every later hello is answered with. Recorded
  /// but not sent while the board is [PedalLinkStatus.incompatible]; dropped
  /// after [goodbye].
  void pushState(PedalStateFrame frame) {
    if (_disposed || _goodbye || frame == _lastFrame) return;
    _lastFrame = frame;
    if (!_incompatible) _link.send(StateMessage(frame));
  }

  /// Darkens the console for a shutdown and holds the mark: from here on
  /// every frame is dropped, so nothing — a last looper poll, a stomp made
  /// out of habit — re-lights a panel whose host is halting. Hellos are
  /// still answered, with the goodbye frame, so a board that missed it goes
  /// dark on the next one.
  ///
  /// Inbound stomps are deliberately NOT swallowed. Blocking them as well
  /// makes a goodbye that turns out to be wrong — a halt that never
  /// happens — indistinguishable from a broken link: no frames, no events,
  /// no log line, and no way back short of a restart. Dropping the frames is
  /// what holds the mark; the events can do no harm on a console that is
  /// going down, and they leave a trace if it is not.
  void goodbye() {
    if (_disposed || _goodbye) return;
    pushState(PedalStateFrame.blank(goodbye: true));
    _goodbye = true;
    _log?.call('pedal link: goodbye mark held; frames stop here');
  }

  void _onMessage(PedalLinkMessage message) {
    switch (message) {
      case ButtonMessage(:final button, :final pressed):
        if (_incompatible) return;
        _emit(
          pressed
              ? ButtonPressed(button, timestamp: _clock())
              : ButtonReleased(button, timestamp: _clock()),
        );
      case EncoderMessage(:final delta):
        if (_incompatible) return;
        _emit(EncoderDelta(delta));
      case CtrlMessage(:final jack, :final kind, :final value):
        if (_incompatible) return;
        _emit(CtrlChanged(jack: jack, kind: kind, value: value));
      case HelloMessage():
        _onHello(message);
      case StateMessage():
        break; // outbound; a board never sends one
    }
  }

  void _onHello(HelloMessage hello) {
    _helloWatchdog?.cancel();
    _helloWatchdog = Timer(helloTimeout, _onHelloTimeout);
    _setHello(
      hello,
      () => hello.protocolVersion == PedalLinkCodec.protocolVersion
          ? 'firmware ${hello.firmwareVersion}'
          : 'firmware ${hello.firmwareVersion} speaks link protocol '
                '${hello.protocolVersion}, this build speaks '
                '${PedalLinkCodec.protocolVersion}',
    );
    // Answer every hello with the current frame: the reconnect re-push and
    // the keep-alive in one place, paced by the board.
    final frame = _lastFrame;
    if (status == PedalLinkStatus.connected && frame != null) {
      _link.send(StateMessage(frame));
    }
  }

  void _onHelloTimeout() {
    _setHello(null, () => 'no hello for ${helloTimeout.inMilliseconds} ms');
  }

  /// Records the latest hello (or, with `null`, its absence) and announces
  /// the status when the hello differs from the last one — a new status, or
  /// the same status from a board that now names another firmware version.
  /// [why] is the log line's detail, built only when a line is written.
  void _setHello(HelloMessage? hello, String Function() why) {
    if (hello == _hello) return;
    _hello = hello;
    _log?.call('pedal link: ${status.name} (${why()})');
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  void _emit(PedalEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Cancels the inbound subscription, releases the link, and closes the
  /// streams. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _helloWatchdog?.cancel();
    _setHello(null, () => 'link released');
    await _inboundSub.cancel();
    await _link.dispose();
    await _events.close();
    await _statusChanges.close();
  }
}
