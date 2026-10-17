import 'dart:async';

import 'package:controller_repository/src/controller_binding_event.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/controller_source.dart';

/// Owns controller sources and forwards exact console events to ControlCubit.
/// Musical MIDI mappings use the selected-device raw stream; there are no
/// implicit transport CCs or a second assignment dispatcher here.
class ControllerRepository {
  /// Subscribes once and takes ownership of every supplied source.
  ControllerRepository({required List<ControllerSource> sources})
    : _sources = List.unmodifiable(sources) {
    for (final source in _sources) {
      _subscriptions.add(source.inputs.listen(_onInput));
    }
  }

  final List<ControllerSource> _sources;
  final _subscriptions = <StreamSubscription<ControllerSourceEvent>>[];
  final _events = StreamController<ControllerDispatchEvent>.broadcast();
  bool _disposed = false;

  /// Qualified console samples and unavailable boundaries, without remapping.
  Stream<ControllerDispatchEvent> get bindingEvents => _events.stream;

  void _onInput(ControllerSourceEvent event) {
    final kind = switch (event) {
      RawControllerInput() => event.kind,
      ControllerSourceUnavailable() => event.trigger.kind,
    };
    if (!_disposed && kind.isConsoleCtrl) {
      _events.add(ControllerConsoleEvent(event));
    }
  }

  /// Releases subscriptions before their sources and closes the fan-in stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final source in _sources) {
      await source.dispose();
    }
    await _events.close();
  }
}
