import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/live_value.dart';

/// Builds a playhead from the engine's live playheads (#1563).
///
/// A [LiveValue] over `LooperRepository.playheads`, the way `LiveMeter` is
/// one over the levels: only a change in the value [select] picks rebuilds
/// [builder], and only while the playhead is drawn. A caller whose selection
/// depends on something that can change (the channel it shows) gives this
/// widget a key built from it.
class LivePlayhead<T extends Object> extends StatelessWidget {
  /// Creates a [LivePlayhead].
  const LivePlayhead({required this.select, required this.builder, super.key});

  /// Picks this widget's value out of the playheads.
  final T Function(Playhead playhead) select;

  /// Draws the widget for a value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<LooperRepository>();
    return LiveValue<Playhead, T>(
      values: repository.playheads,
      latest: () => repository.playhead,
      select: select,
      builder: builder,
    );
  }
}
