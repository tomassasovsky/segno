import 'package:meta/meta.dart';

/// One reading of the machine's idle time and of the clock, both in
/// hundredths of a second.
///
/// The load comes from idle time against elapsed time, not from the busy
/// fields of `/proc/stat` (#1868). The kernel samples the busy fields at the
/// scheduler tick, which misses work done in short bursts between ticks: on
/// the console the audio callback (every 0.67 ms) and the USB interrupt
/// thread (about 4000 times a second) were mostly missing, and the interrupt
/// thread's time arrived in one lump every few seconds. Idle and I/O wait
/// are measured by the kernel as the core enters and leaves idle, so they
/// add up to the real figure.
@immutable
class CpuSample {
  /// Creates a [CpuSample].
  const new({required this.uptime, required this.idle});

  /// Time since boot, in hundredths of a second, from `/proc/uptime`.
  final int uptime;

  /// Idle plus I/O wait, summed over every core, in `/proc/stat` ticks. The
  /// tick (`USER_HZ`) is a hundredth of a second on Linux for arm64 and
  /// x86-64, so this is in the same unit as [uptime].
  final int idle;

  @override
  bool operator ==(Object other) =>
      other is CpuSample && other.uptime == uptime && other.idle == idle;

  @override
  int get hashCode => Object.hash(uptime, idle);

  @override
  String toString() => 'CpuSample(uptime: $uptime, idle: $idle)';
}

/// Reads a [CpuSample] from the text of `/proc/stat` and of `/proc/uptime`,
/// or null when either has nothing to read.
///
/// Idle is the fourth field of the aggregate `cpu` line and I/O wait the
/// fifth. I/O wait counts as idle, as in `top`: a core waiting on the disk
/// is free to run anything else. The idle figure in `/proc/uptime` is not
/// used because it leaves I/O wait out.
CpuSample? parseCpuSample({required String stat, required String uptime}) {
  final seconds = double.tryParse(uptime.trim().split(RegExp(r'\s+')).first);
  if (seconds == null) return null;
  for (final line in stat.split('\n')) {
    if (!line.startsWith('cpu ')) continue;
    final fields = line
        .substring(4)
        .trim()
        .split(RegExp(r'\s+'))
        .take(5)
        .map(int.tryParse)
        .toList();
    // Idle is the fourth field; a line without it is not one to trust.
    if (fields.length < 4 || fields.contains(null)) return null;
    final ticks = fields.cast<int>();
    return CpuSample(
      uptime: (seconds * 100).round(),
      idle: ticks[3] + (ticks.length > 4 ? ticks[4] : 0),
    );
  }
  return null;
}

/// The whole machine's load between two samples, as a whole percent (all
/// [cores] = 100): the share of the elapsed time on every core that was not
/// idle. Null when no time passed between them.
int? loadPercent(CpuSample earlier, CpuSample later, {required int cores}) {
  final total = (later.uptime - earlier.uptime) * cores;
  if (total <= 0) return null;
  final idle = (later.idle - earlier.idle).clamp(0, total);
  return (100 * (total - idle) / total).round();
}
