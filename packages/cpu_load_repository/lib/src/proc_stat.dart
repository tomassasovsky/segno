import 'package:meta/meta.dart';

/// The machine's cumulative CPU time, in jiffies, from the aggregate `cpu`
/// line of `/proc/stat`: every core together.
@immutable
class CpuTimes {
  /// Creates a [CpuTimes].
  const CpuTimes({required this.busy, required this.total});

  /// Jiffies spent doing work: everything but idle and I/O wait.
  final int busy;

  /// All jiffies counted.
  final int total;

  @override
  bool operator ==(Object other) =>
      other is CpuTimes && other.busy == busy && other.total == total;

  @override
  int get hashCode => Object.hash(busy, total);

  @override
  String toString() => 'CpuTimes(busy: $busy, total: $total)';
}

/// Reads the aggregate `cpu` line out of [contents] (the text of
/// `/proc/stat`), or null when there is none.
///
/// The line's fields are user, nice, system, idle, iowait, irq, softirq and
/// steal, then guest and guest_nice. The guest fields are already counted in
/// user and nice, so only the first eight are summed. Idle and iowait are
/// the machine waiting; the rest is work. This is how `top` and `vmstat`
/// read the line.
CpuTimes? parseProcStat(String contents) {
  for (final line in contents.split('\n')) {
    if (!line.startsWith('cpu ')) continue;
    final fields = line
        .substring(4)
        .trim()
        .split(RegExp(r'\s+'))
        .take(8)
        .map(int.tryParse)
        .toList();
    // Idle is the fourth field; a line without it is not one to trust.
    if (fields.length < 4 || fields.contains(null)) return null;
    final jiffies = fields.cast<int>();
    final total = jiffies.fold(0, (sum, value) => sum + value);
    final idle = jiffies[3] + (jiffies.length > 4 ? jiffies[4] : 0);
    return CpuTimes(busy: total - idle, total: total);
  }
  return null;
}

/// The whole machine's load between two samples, as a whole percent
/// (all cores = 100), or null when no time passed between them.
int? loadPercent(CpuTimes earlier, CpuTimes later) {
  final total = later.total - earlier.total;
  if (total <= 0) return null;
  final busy = (later.busy - earlier.busy).clamp(0, total);
  return (100 * busy / total).round();
}
