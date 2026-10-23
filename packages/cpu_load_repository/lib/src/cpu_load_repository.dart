import 'dart:async';
import 'dart:io';

import 'package:cpu_load_repository/src/proc_stat.dart';

/// Reads the text of `/proc/stat`.
typedef ProcStatReader = Future<String> Function();

/// The console's CPU load as a share of the whole machine: every core
/// together is 100% (#1307).
///
/// Sampled from the aggregate `cpu` line of `/proc/stat`, the change in busy
/// over the change in total jiffies between two reads [interval] apart. A
/// build without `/proc/stat` (macOS desktop) is [isSupported] false and
/// reports nothing.
class CpuLoadRepository {
  /// Creates a [CpuLoadRepository] reading through [readStat].
  const CpuLoadRepository({
    required ProcStatReader readStat,
    this.interval = const Duration(seconds: 1),
  }) : _readStat = readStat,
       isSupported = true;

  /// A repository for a build that cannot measure the load.
  const CpuLoadRepository.unsupported()
    : _readStat = null,
      interval = const Duration(seconds: 1),
      isSupported = false;

  /// The repository for this machine: `/proc/stat` where the kernel has it,
  /// [CpuLoadRepository.unsupported] where it does not.
  factory CpuLoadRepository.system({String path = '/proc/stat'}) {
    final file = File(path);
    if (!file.existsSync()) return const CpuLoadRepository.unsupported();
    return CpuLoadRepository(readStat: file.readAsString);
  }

  final ProcStatReader? _readStat;

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
    final read = _readStat;
    if (read == null) return const Stream<int>.empty();
    late final StreamController<int> controller;
    Timer? timer;
    var cancelled = false;
    CpuTimes? previous;
    int? last;

    Future<void> sample() async {
      CpuTimes? times;
      try {
        times = parseProcStat(await read());
      } on Exception {
        times = null;
      }
      if (times == null || cancelled) return;
      final earlier = previous;
      previous = times;
      if (earlier == null) return;
      final load = loadPercent(earlier, times);
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
