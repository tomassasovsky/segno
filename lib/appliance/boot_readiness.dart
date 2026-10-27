import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/console_audio_devices.dart';
import 'package:segno/appliance/systemd_notify.dart';
import 'package:segno/logging/app_log.dart';

/// The audio side of the boot health heartbeat, as `segno-mark-good` reads it.
enum BootAudio {
  /// The engine is running.
  ok,

  /// The interface is not there: the pinned one is unplugged, or nothing is
  /// pinned and there is no interface to pin. Not the build's fault.
  absent,

  /// An interface is there and the engine is not running on it, or whether
  /// one is there could not be read.
  refused,
}

/// The [BootAudio] for an engine that is [running] or not, with [config] the
/// config it last started with (or tried to, at boot) and [devices] the
/// enumeration, read only when the engine is not running.
BootAudio bootAudioOf({
  required bool running,
  required EngineConfig? config,
  required List<AudioDevice> Function() devices,
}) {
  if (running) return BootAudio.ok;
  final bool present;
  try {
    final list = devices();
    present = config != null && pinsDevice(config)
        ? pinnedDevicesPresent(config, list)
        : pickConsoleAudioDevices(list) != null;
  } on Object catch (error) {
    AppLog.warn('boot health: device enumeration failed: $error');
    return BootAudio.refused;
  }
  return present ? BootAudio.refused : BootAudio.absent;
}

/// Tells systemd the app is up, and keeps telling `segno-mark-good` how it is
/// (#976, docs/plan/2026-10-06-feat-device-pages-plan.md, Part 1).
///
/// `READY=1` first goes out when the main screen has rasterized its first
/// frame: `segno.service` is `Type=notify`, so until then the unit is not
/// active and the gate does not commit. Readiness waits for nothing else, so a
/// working app on a committed slot is never killed for want of a readout or an
/// interface. Those ride the heartbeat instead, which every [interval] sends
///
///     STATUS=alive <n> readout <m|none> audio <ok|absent|refused>
///
/// `n` counts this timer, so a hung UI isolate stops it. `m` counts the
/// readout's answers to a ping, which it gives only once it draws; it is
/// `none` while the readout's connector does not read connected. `audio` is
/// [BootAudio]. The gate commits only when `n` advanced, `m` advanced whenever
/// both its samples counted it, and `audio` was not `refused` in both.
class BootReadiness {
  /// Creates a [BootReadiness]; nothing is sent until [start].
  BootReadiness({
    required SystemdNotify notify,
    required Future<void> firstFrame,
    required BootAudio Function() audio,
    required Future<bool> Function() readoutConnected,
    required Future<bool> Function() pingReadout,
    this.interval = const Duration(seconds: 5),
  }) : _notify = notify,
       _firstFrame = firstFrame,
       _audio = audio,
       _readoutConnected = readoutConnected,
       _pingReadout = pingReadout;

  final SystemdNotify _notify;
  final Future<void> _firstFrame;
  final BootAudio Function() _audio;
  final Future<bool> Function() _readoutConnected;
  final Future<bool> Function() _pingReadout;

  /// How often the heartbeat goes out.
  final Duration interval;

  var _started = false;
  var _beating = false;
  var _alive = 0;
  var _readoutAnswers = 0;
  var _sendFailed = false;

  /// Waits for the first frame, says `READY=1` with the first status, then
  /// sends the heartbeat every [interval] for the life of the process.
  /// Idempotent.
  ///
  /// `READY=1` goes with every status: a lost datagram would otherwise leave
  /// the unit activating until systemd kills a working app at
  /// `TimeoutStartSec`, and a `sendto` that succeeds does not prove systemd
  /// took it. systemd ignores a repeated `READY=1`.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _firstFrame;
    final status = await _status(ping: false);
    _send(status);
    AppLog.info('boot health: first frame drawn ($status)');
    Timer.periodic(interval, (_) => unawaited(_beat()));
  }

  Future<void> _beat() async {
    // A ping that is still waiting for its answer holds the next beat back
    // rather than stacking up behind it.
    if (_beating) return;
    _beating = true;
    try {
      _alive++;
      _send(await _status(ping: true));
    } finally {
      _beating = false;
    }
  }

  /// The status line. Nothing in it can throw: a part that cannot be read
  /// reads as the unhealthy answer, so a beat is never lost to an error.
  Future<String> _status({required bool ping}) async {
    var connected = false;
    try {
      connected = await _readoutConnected();
    } on Object catch (error) {
      AppLog.warn('boot health: readout connector unreadable: $error');
    }
    if (connected && ping) {
      try {
        if (await _pingReadout()) _readoutAnswers++;
      } on Object catch (error) {
        AppLog.warn('boot health: readout ping failed: $error');
      }
    }
    var audio = BootAudio.refused;
    try {
      audio = _audio();
    } on Object catch (error) {
      AppLog.warn('boot health: audio state unreadable: $error');
    }
    final readout = connected ? '$_readoutAnswers' : 'none';
    return 'alive $_alive readout $readout audio ${audio.name}';
  }

  void _send(String status) {
    final state = 'READY=1\nSTATUS=$status';
    final sent = _notify(state);
    // Once per change, not every beat: a socket that stays unreachable would
    // otherwise fill the log.
    if (sent == !_sendFailed) return;
    _sendFailed = !sent;
    if (sent) {
      AppLog.info('boot health: systemd notifications sent again');
    } else {
      AppLog.warn('boot health: systemd notification not sent: $state');
    }
  }
}
