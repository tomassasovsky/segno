import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/looper/cubit/live_cubit.dart';

/// Builds a widget from one value of a live engine stream (#1301, #1563).
///
/// Owns a [LiveCubit] for as long as it is in the tree, so it follows the
/// stream only while it is on screen, and only a change in the value
/// [select] picks rebuilds [builder]. It follows only while its route is
/// drawn ([TickerMode]): a page pushed over the stage would otherwise keep
/// the stage's meters and progress bars rebuilding under it.
///
/// What it builds paints in a layer of its own ([RepaintBoundary]): the value
/// changes at the engine's poll rate, and its repaint must not repaint the
/// page around it.
///
/// [select] is read once, when the cubit is created. A caller whose
/// selection depends on something that can change (the channel it shows)
/// gives this widget a key built from it, so a new selection gets a new
/// cubit.
class LiveValue<S, T extends Object> extends StatelessWidget {
  /// Creates a [LiveValue].
  const LiveValue({
    required this.values,
    required this.latest,
    required this.select,
    required this.builder,
    super.key,
  });

  /// The live stream.
  final Stream<S> values;

  /// Its most recent value, shown before the stream's next one.
  final S Function() latest;

  /// Picks this widget's value out of the stream, quantised to what it shows.
  final T Function(S value) select;

  /// Draws the widget for a value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          LiveCubit<S, T>(values: values, latest: latest, select: select),
      child: RepaintBoundary(
        child: _FollowWhileVisible<S, T>(
          child: BlocBuilder<LiveCubit<S, T>, T>(builder: builder),
        ),
      ),
    );
  }
}

/// Tells the [LiveCubit] above whether its route is drawn.
class _FollowWhileVisible<S, T extends Object> extends StatefulWidget {
  const _FollowWhileVisible({required this.child, super.key});

  final Widget child;

  @override
  State<_FollowWhileVisible<S, T>> createState() =>
      _FollowWhileVisibleState<S, T>();
}

class _FollowWhileVisibleState<S, T extends Object>
    extends State<_FollowWhileVisible<S, T>> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<LiveCubit<S, T>>().follow(
      visible: TickerMode.valuesOf(context).enabled,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
