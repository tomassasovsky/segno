import 'package:cpu_load_repository/cpu_load_repository.dart';

/// A [CpuLoadRepository] that reports [load] once, at once: the stage's CPU
/// readout with a known figure and no sampling timer.
class FixedCpuLoadRepository extends CpuLoadRepository {
  /// Creates a [FixedCpuLoadRepository] reporting [load].
  const new(this.load) : super(read: _unread, cores: 1);

  /// The load reported.
  final int load;

  @override
  Stream<int> watch() => Stream.value(load);
}

Future<String> _unread(String _) => throw UnimplementedError('never sampled');
