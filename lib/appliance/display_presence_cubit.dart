import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:segno/appliance/display_role.dart';

/// The panels known to be unplugged, read while the Displays page is open.
///
/// A panel whose presence cannot be read (a desktop, a window the compositor
/// does not pin) is not reported unplugged: "Not connected" is a fact the
/// console read, never a guess.
class DisplayPresenceCubit extends Cubit<Set<DisplayRole>> {
  /// Creates a [DisplayPresenceCubit] that re-reads every [interval].
  DisplayPresenceCubit({
    required DisplayOutputs outputs,
    this.interval = const Duration(seconds: 2),
  }) : _outputs = outputs,
       super(const {});

  final DisplayOutputs _outputs;

  /// How often presence is re-read while watching.
  final Duration interval;

  Timer? _timer;

  /// Reads presence now and keeps reading it until closed.
  void watch() {
    _timer?.cancel();
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Reads which panels are unplugged.
  Future<void> refresh() async {
    final connectors = displayConnectors(await _outputs.appIdConnectors());
    final unplugged = <DisplayRole>{};
    for (final MapEntry(key: role, value: connector) in connectors.entries) {
      if (await _outputs.isConnected(connector) == false) unplugged.add(role);
    }
    if (isClosed) return;
    if (unplugged.length != state.length || !unplugged.containsAll(state)) {
      emit(unplugged);
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
