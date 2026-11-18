import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/live_value.dart';

/// Builds a meter from one live value of the engine's levels (#1301).
///
/// A [LiveValue] over `LooperRepository.meterLevels`: only a change in the
/// value [select] picks rebuilds [builder], and only while the meter is
/// drawn. A caller whose selection depends on something that can change
/// (the channel it shows) gives this widget a key built from it.
class LiveMeter<T extends Object> extends StatelessWidget {
  /// Creates a [LiveMeter].
  const new({required this.select, required this.builder, super.key});

  /// Picks this meter's value out of the levels, quantised to what it shows.
  final T Function(MeterLevels levels) select;

  /// Draws the meter for a value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<LooperRepository>();
    return LiveValue<MeterLevels, T>(
      values: repository.meterLevels,
      latest: () => repository.meters,
      select: select,
      builder: builder,
    );
  }
}
