import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

part 'outputs_state.dart';

/// What the player calls each destination of the open interface.
///
/// The output-side twin of [InputsCubit], and keyed the same way: names belong
/// to the DEVICE, because outputs 3 and 4 on a Scarlett and on the built-in
/// pair drive different things.
///
/// The one difference is the unit. An input is a jack; a destination is a
/// PAIR of jacks (bus `k` = outputs `2k` and `2k+1`), which is what the player
/// patches, names and sends a track to. Naming the jacks separately would ask
/// for two names for one cable pair and leave every routing surface to guess
/// which of them to show.
class OutputsCubit extends Cubit<OutputsState> {
  /// Creates an [OutputsCubit] that follows [repository]'s open device.
  OutputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : _settings = settings,
       _repository = repository,
       super(const OutputsState()) {
    _subscription = _repository.looperState.listen(
      (looper) => unawaited(_followDevice(looper.status.deviceName)),
    );
    unawaited(_followDevice(_repository.state.status.deviceName));
  }

  final SettingsRepository _settings;
  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

  /// Destinations renamed while a load was in flight, so the restore lands
  /// MERGED rather than overwriting a name the user just gave.
  final Set<int> _renamedDuringLoad = {};

  /// Whether a load is currently walking the destinations.
  bool _loading = false;

  /// The device a rename belongs to right now — moved when a walk STARTS, not
  /// when it finishes, so a rename arriving mid-walk is not saved against the
  /// device on its way out.
  String _device = '';

  /// Re-reads the names when the open device changes.
  ///
  /// Nothing to do while the engine reports no device: clearing the list would
  /// blank every destination for the length of a reopen.
  Future<void> _followDevice(String device) async {
    if (device.isEmpty || device == _device) return;
    await _restore(device);
  }

  Future<void> _restore(String device) async {
    _device = device;
    _loading = true;
    _renamedDuringLoad.clear();
    final names = <int, String>{};
    for (var bus = 0; bus < OutputsState.probeCeiling; bus++) {
      final saved = await _settings.loadOutputName(device: device, bus: bus);
      if (saved != null && saved.isNotEmpty) names[bus] = saved;
    }
    _loading = false;
    if (isClosed) return;
    for (final bus in _renamedDuringLoad) {
      final live = state.names[bus];
      if (live == null || live.isEmpty) {
        names.remove(bus);
      } else {
        names[bus] = live;
      }
    }
    _renamedDuringLoad.clear();
    emit(OutputsState(device: device, names: names));
  }

  /// Names destination [bus] on the open device, or hands it back its jack
  /// numbers when [name] trims to nothing.
  Future<void> rename(int bus, String name) async {
    final device = _device;
    // Nothing to key the name to; storing it against an empty device would be
    // a name that reappears on whatever opens next.
    if (device.isEmpty || bus < 0) return;
    final trimmed = name.trim();
    if (trimmed == (state.names[bus] ?? '')) return;
    if (_loading) _renamedDuringLoad.add(bus);
    final names = {...state.names};
    if (trimmed.isEmpty) {
      names.remove(bus);
    } else {
      names[bus] = trimmed;
    }
    emit(state.copyWith(names: names));
    if (trimmed.isEmpty) {
      await _settings.clearOutputName(device: device, bus: bus);
      return;
    }
    await _settings.saveOutputName(device: device, bus: bus, name: trimmed);
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
