import 'dart:async';

import 'package:bloc/bloc.dart';

/// One value picked out of a live engine stream: the levels (#1301) or the
/// playheads (#1563).
///
/// Both move on every engine poll, so neither is part of `LooperState`. A
/// meter or a playhead creates one of these for itself (see `LiveValue`), so
/// the stream reaches only what is on screen and stops when it closes.
///
/// `select` picks this widget's value out of the stream and should quantise
/// it to what the widget can show (`meterPeak` in `meter_scale.dart`). Equal
/// values are not emitted, so a change that does not change the drawing
/// rebuilds nothing.
class LiveCubit<S, T extends Object> extends Cubit<T> {
  /// Creates a [LiveCubit] following [_values] through [select], starting
  /// from [latest].
  new({
    required this._values,
    required S Function() latest,
    required T Function(S value) select,
  }) : _latest = latest,
       _select = select,
       super(select(latest())) {
    _subscription = _listen();
  }

  final Stream<S> _values;
  final S Function() _latest;
  final T Function(S value) _select;
  StreamSubscription<S>? _subscription;

  StreamSubscription<S> _listen() => _values.listen(_show);

  void _show(S value) {
    final next = _select(value);
    // Compared here because Cubit lets its FIRST emit through even when it
    // equals the initial state, and that one rebuild per widget is exactly
    // what an idle console must not pay.
    if (next != state) emit(next);
  }

  /// Follows the stream while [visible], and stops while not: a route under
  /// another one is built but not drawn, and a value it follows would still
  /// rebuild it and make the screen draw a frame that shows nothing new.
  /// Coming back, it shows the latest value at once.
  void follow({required bool visible}) {
    if (isClosed || visible == (_subscription != null)) return;
    if (visible) {
      _show(_latest());
      _subscription = _listen();
    } else {
      unawaited(_subscription?.cancel());
      _subscription = null;
    }
  }

  @override
  Future<void> close() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    return super.close();
  }
}
