import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'interface_inputs_state.dart';

/// The interface's own input switches (#1646): Inst or Line, Pad, Air and
/// 48 V phantom power, for the device the engine has open.
///
/// Segno stores none of them. The interface keeps its own settings and its
/// front-panel buttons change the same values, so this cubit only mirrors
/// what the interface reports: it reads at every device open, after every
/// change, and twice a second while a page that shows them is open
/// ([startWatching] / [stopWatching]), which is how a front-panel press shows
/// up. A change the interface refuses keeps the value it reports and counts
/// a failure for the page to say.
///
/// Nothing here turns 48 V on by itself: [setPhantomPower] runs only when the
/// player asks, after the page's confirmation.
class InterfaceInputsCubit extends Cubit<InterfaceInputsState> {
  /// Creates an [InterfaceInputsCubit] that follows [repository]'s open
  /// device.
  InterfaceInputsCubit({
    required LooperRepository repository,
    Duration watchInterval = const Duration(milliseconds: 500),
  }) : _repository = repository,
       _watchInterval = watchInterval,
       super(const InterfaceInputsState()) {
    _subscription = _repository.looperState.listen(_followDevice);
    _followDevice(_repository.state);
  }

  final LooperRepository _repository;
  final Duration _watchInterval;
  late final StreamSubscription<LooperState> _subscription;
  Timer? _watch;

  /// The open device's key, or null with none open; a read for another key
  /// is dropped.
  (String, int)? _device;

  /// Reads are numbered as they start; one that lands after a later one
  /// (a watch read overtaken by a change's read-back) is dropped.
  int _readsStarted = 0;
  int _readShown = 0;
  bool _watchReading = false;

  void _followDevice(LooperState looper) {
    final status = looper.status;
    final device = status.isConnected && status.devicePresent
        ? (status.deviceName, _repository.mixGeneration)
        : null;
    if (device == _device) return;
    _device = device;
    emit(const InterfaceInputsState());
    if (device != null) unawaited(_read());
  }

  /// Reads the interface and shows what it reports.
  Future<void> _read() async {
    final device = _device;
    if (device == null) return;
    final number = ++_readsStarted;
    final read = await _repository.readInterfaceInputs();
    if (isClosed || device != _device || number < _readShown) return;
    _readShown = number;
    emit(state.reading(read));
  }

  /// A watch read, unless the last one is still on its way.
  Future<void> _watchRead() async {
    if (_watchReading) return;
    _watchReading = true;
    try {
      await _read();
    } finally {
      _watchReading = false;
    }
  }

  /// Reads the interface twice a second until [stopWatching], so a change
  /// made on the interface itself shows.
  void startWatching() {
    _watch?.cancel();
    _watch = Timer.periodic(_watchInterval, (_) => unawaited(_watchRead()));
    unawaited(_watchRead());
  }

  /// Stops [startWatching]'s reads.
  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  /// Sets [input]'s level.
  void setLevel(int input, InputLevel level) => unawaited(
    _change(
      InterfaceSwitch.level,
      () => _repository.setInterfaceInputLevel(input, level),
    ),
  );

  /// Sets [input]'s pad.
  void setPad(int input, {required bool on}) => unawaited(
    _change(
      InterfaceSwitch.pad,
      () => _repository.setInterfaceInputPad(input, on: on),
    ),
  );

  /// Sets [input]'s Air.
  void setAir(int input, InputAir air) => unawaited(
    _change(
      InterfaceSwitch.air,
      () => _repository.setInterfaceInputAir(input, air),
    ),
  );

  /// Turns 48 V switch [phantomSwitch] on or off. Turning it on is the
  /// player's confirmed request; nothing calls this on its own.
  void setPhantomPower(int phantomSwitch, {required bool on}) => unawaited(
    _change(
      InterfaceSwitch.phantom,
      () => _repository.setInterfacePhantomPower(phantomSwitch, on: on),
    ),
  );

  /// Turns the unit's setup mode off; it shows its controls after a power
  /// cycle.
  void turnOffSetupMode() => unawaited(
    _change(InterfaceSwitch.setupMode, _repository.turnOffInterfaceSetupMode),
  );

  Future<void> _change(
    InterfaceSwitch which,
    Future<EngineResult> Function() write,
  ) async {
    final device = _device;
    if (device == null) return;
    final result = await write();
    if (isClosed || device != _device) return;
    if (!result.isOk) emit(state.refusing(which));
    // What the interface holds now, refused or not.
    await _read();
  }

  @override
  Future<void> close() async {
    stopWatching();
    await _subscription.cancel();
    return super.close();
  }
}
