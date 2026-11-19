import 'dart:async';
import 'dart:io';

import 'package:cpu_load_repository/src/cpu_sample.dart';

/// Reads the text of a file under `/proc`, by its name there (`stat`,
/// `uptime`).
typedef ProcReader = Future<String> Function(String name);

/// The console's CPU load as a share of the whole machine: every core
/// together is 100% (#1307).
///
/// Each sample reads the idle time of every core from `/proc/stat` and the
/// clock from `/proc/uptime`; the load is the share of the elapsed time,
/// over [cores] cores, that was not idle between two reads [interval] apart
/// (#1868, see [CpuSample]). A build without `/proc` (macOS desktop) is
/// [isSupported] false and reports nothing.
class CpuLoadRepository {
  /// Creates a [CpuLoadRepository] reading through [_read] on a machine
  /// with [cores] cores.
  const new({
    required ProcReader this._read,
    required this.cores,
    this.interval = const Duration(seconds: 1),
  }) : isSupported = true;

  /// A repository for a build that cannot measure the load.
  const new unsupported()
    : _read = null,
      cores = 0,
      interval = const Duration(seconds: 1),
      isSupported = false;

  /// The repository for this machine: `/proc/stat` and `/proc/uptime` under
  /// [proc] where the kernel has them, [CpuLoadRepository.unsupported] where
  /// it does not.
  ///
  /// [cores] is the cores online, which are the ones whose idle time the
  /// kernel advances.
  factory system({String proc = '/proc'}) {
    if (!File('$proc/stat').existsSync() ||
        !File('$proc/uptime').existsSync()) {
      return const CpuLoadRepository.unsupported();
    }
    return CpuLoadRepository(
      read: (name) => File('$proc/$name').readAsString(),
      cores: Platform.numberOfProcessors,
    );
  }

  final ProcReader? _read;

  /// How many cores the load is shared over.
  final int cores;

  /// How far apart the samples are.
  final Duration interval;

  /// Whether this build can measure the load at all.
  final bool isSupported;

  /// The load in whole percent, sampled every [interval] while listened to.
  ///
  /// The first figure arrives one [interval] after listening (a load needs
  /// two samples). A figure equal to the last one is not repeated, so a
  /// listener only hears about a change it would show. Sampling stops when
  /// the subscription is cancelled. Empty when not [isSupported].
  Stream<int> watch() {
    final read = _read;
    if (read == null) return const Stream<int>.empty();
    late final StreamController<int> controller;
    Timer? timer;
    var cancelled = false;
    CpuSample? previous;
    int? last;

    Future<void> sample() async {
      CpuSample? now;
      try {
        // Both at once, so the idle time and the clock are read as close
        // together as they can be.
        final [stat, uptime] = await Future.wait([
          read('stat'),
          read('uptime'),
        ]);
        now = parseCpuSample(stat: stat, uptime: uptime);
      } on Exception {
        now = null;
      }
      if (now == null || cancelled) return;
      final earlier = previous;
      previous = now;
      if (earlier == null) return;
      // A gap of more than ten intervals is a suspend: /proc/uptime runs
      // through it and idle time does not, so it would read as full load.
      // A few failed reads in a row leave a shorter gap, which still counts.
      if (now.uptime - earlier.uptime > interval.inMilliseconds) return;
      final load = loadPercent(earlier, now, cores: cores);
      if (load == null || load == last) return;
      last = load;
      controller.add(load);
    }

    controller = StreamController<int>(
      onListen: () {
        unawaited(sample());
        timer = Timer.periodic(interval, (_) => unawaited(sample()));
      },
      onCancel: () {
        cancelled = true;
        timer?.cancel();
      },
    );
    return controller.stream;
  }
}
