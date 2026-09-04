import 'dart:async';

import 'package:pedal_repository/src/pedal_ctrl.dart';
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

  /// Calibrations the app set explicitly, by jack. Absent: learn the ends.
  final Map<PedalCtrlJack, PedalCtrlCalibration> _calibration = {};

  /// Ends learned from what each pedal has done this session, by jack.
  final Map<PedalCtrlJack, PedalCtrlCalibration> _learned = {};

  /// The last raw expression reading per jack, and the timer that decides it
  /// has settled there.
  final Map<PedalCtrlJack, int> _lastRaw = {};
  final Map<PedalCtrlJack, Timer> _settle = {};

  /// How long an expression pedal has to hold a reading before the ends are
  /// learned from it. A plug sliding into the jack brushes the tip past the
  /// other contacts for a few milliseconds and reads 0 or 255 on the way in;
  /// learning from those would put the real heel at 9% forever. A foot
  /// holds still for far longer than this.
  static const settleTime = Duration(milliseconds: 100);
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

  /// The calibration the app set for [jack], or `null` while its ends are
  /// being learned from the pedal instead.
  PedalCtrlCalibration? ctrlCalibration(PedalCtrlJack jack) =>
      _calibration[jack];

  /// Uses [calibration] for every expression reading on [jack] from now on,
  /// or with `null` goes back to learning the ends from the pedal. Re-reports
  /// the pedal's current position under the new ends, so a level bound to
  /// it and a readout watching it both move to where the pedal now is.
  void setCtrlCalibration(
    PedalCtrlJack jack,
    PedalCtrlCalibration? calibration,
  ) {
    if (_disposed) return;
    if (calibration == null) {
      _calibration.remove(jack);
    } else {
      _calibration[jack] = calibration;
    }
    _reportUnderNewEnds(jack);
  }

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
      case CtrlMessage(:final jack, :final contact, :final kind, :final value):
        if (_incompatible) return;
        _onCtrl(jack, contact, kind, value);
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
    // The board is gone, or rebooting: whatever was plugged in may not be
    // what comes back. The learned ends go with it; a set calibration stays.
    _forgetLearned();
  }

  void _onCtrl(
    PedalCtrlJack jack,
    PedalCtrlContact contact,
    PedalCtrlKind kind,
    int raw,
  ) {
    if (kind == PedalCtrlKind.none) {
      // The plug is gone, and whatever comes next may be another pedal: the
      // learned ends go with it. A calibration the user set stays — it is
      // the property of the pedal they calibrated, which they will plug back.
      _settle.remove(jack)?.cancel();
      _learned.remove(jack);
      _lastRaw.remove(jack);
      _emit(CtrlChanged(jack: jack, contact: contact, kind: kind, value: 0));
      return;
    }
    if (kind != PedalCtrlKind.expression) {
      _emit(CtrlChanged(jack: jack, contact: contact, kind: kind, value: raw));
      return;
    }
    _lastRaw[jack] = raw;
    _emit(
      CtrlChanged(
        jack: jack,
        contact: contact,
        kind: kind,
        value: _travel(jack, raw),
        raw: raw,
      ),
    );
    // Learn the ends only from readings the pedal holds, never from a plug
    // on its way in (see [settleTime]) — and only while nothing explicit is
    // set, so a calibration the user made is not quietly widened by noise.
    _settle[jack]?.cancel();
    if (_calibration.containsKey(jack)) return;
    _settle[jack] = Timer(settleTime, () => _learn(jack, raw));
  }

  /// [raw] mapped onto the ends known for [jack]: the calibration set for it,
  /// else the ends learned so far once they are far enough apart to trust,
  /// else the raw reading itself.
  int _travel(PedalCtrlJack jack, int raw) {
    final ends = _calibration[jack] ?? _learned[jack];
    if (ends == null || !ends.isUsable) return raw;
    return ends.apply(raw);
  }

  void _learn(PedalCtrlJack jack, int raw) {
    if (_disposed) return;
    final before = _learned[jack];
    final after =
        before?.including(raw) ?? PedalCtrlCalibration(min: raw, max: raw);
    if (after == before) return;
    final was = _travel(jack, raw);
    _learned[jack] = after;
    // The ends just moved, so the reading that moved them may map somewhere
    // new: a pedal held at heel goes from "nearly down" to a hard zero.
    _reportUnderNewEnds(jack, unless: was);
  }

  /// Re-reports [jack]'s last raw reading under the ends now known for it —
  /// unless that maps to [unless], the value already reported, in which case
  /// nothing has changed for anyone listening.
  void _reportUnderNewEnds(PedalCtrlJack jack, {int? unless}) {
    final raw = _lastRaw[jack];
    if (raw == null) return;
    final value = _travel(jack, raw);
    if (value == unless) return;
    _emit(
      CtrlChanged(
        jack: jack,
        kind: PedalCtrlKind.expression,
        value: value,
        raw: raw,
      ),
    );
  }

  void _forgetLearned() {
    for (final timer in _settle.values) {
      timer.cancel();
    }
    _settle.clear();
    _learned.clear();
    _lastRaw.clear();
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
    _forgetLearned();
    _setHello(null, () => 'link released');
    await _inboundSub.cancel();
    await _link.dispose();
    await _events.close();
    await _statusChanges.close();
  }
}
