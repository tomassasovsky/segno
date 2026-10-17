import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/meter_cubit.dart';

/// Builds a meter from one live value of the engine's levels (#1301).
///
/// Owns a [MeterCubit] for as long as it is in the tree, so a meter follows
/// the levels only while it is on screen, and only a change in the value
/// [select] picks rebuilds [builder].
///
/// [select] is read once, when the cubit is created. A caller whose
/// selection depends on something that can change (the channel it shows)
/// gives this widget a key built from it, so a new selection gets a new
/// cubit.
class LiveMeter<T extends Object> extends StatelessWidget {
  /// Creates a [LiveMeter].
  const LiveMeter({required this.select, required this.builder, super.key});

  /// Picks this meter's value out of the levels, quantised to what it shows.
  final T Function(MeterLevels levels) select;

  /// Draws the meter for a value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => MeterCubit<T>(
        repository: context.read<LooperRepository>(),
        select: select,
      ),
      child: BlocBuilder<MeterCubit<T>, T>(builder: builder),
    );
  }
}
