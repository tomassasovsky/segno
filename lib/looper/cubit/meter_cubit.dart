import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';

/// One meter's value, followed from the engine's live levels (#1301).
///
/// Levels are not part of `LooperState`: they change on every engine poll
/// while any signal flows, including an input's noise floor while the
/// console sits idle, and every surface following the state rebuilt with
/// them. A meter instead creates one of these for itself (see `LiveMeter`),
/// so levels reach only the meters on screen and stop when they close.
///
/// `select` picks this meter's value out of the levels and should quantise
/// it to what the meter can show (`meterPeak` in `meter_scale.dart`). Equal
/// values are not emitted, so a level that does not change the drawing
/// rebuilds nothing.
class MeterCubit<T extends Object> extends Cubit<T> {
  /// Creates a [MeterCubit] following [repository]'s levels through [select].
  MeterCubit({
    required LooperRepository repository,
    required T Function(MeterLevels levels) select,
  }) : super(select(repository.meters)) {
    _subscription = repository.meterLevels.listen((levels) {
      final next = select(levels);
      // Compared here because Cubit lets its FIRST emit through even when it
      // equals the initial state, and that one rebuild per meter is exactly
      // what an idle console must not pay.
      if (next != state) emit(next);
    });
  }

  late final StreamSubscription<MeterLevels> _subscription;

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
