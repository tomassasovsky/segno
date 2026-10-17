import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:cpu_load_repository/cpu_load_repository.dart';

/// The console's CPU load for the stage top bar, in whole percent of the
/// whole machine (all cores = 100), or null before the first reading
/// (#1307).
///
/// Created by the readout itself, so the repository samples `/proc/stat`
/// only while the bar is on screen. Emits only when the displayed figure
/// changes, the way `MeterCubit` does for the meters (#1304): a steady load
/// rebuilds nothing.
class CpuLoadCubit extends Cubit<int?> {
  /// Creates a [CpuLoadCubit] following [repository].
  CpuLoadCubit({required CpuLoadRepository repository}) : super(null) {
    _subscription = repository.watch().listen((load) {
      if (load != state) emit(load);
    });
  }

  late final StreamSubscription<int> _subscription;

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
