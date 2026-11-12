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
  /// Creates an [InterfaceInputsCubit] that follows [_repository]'s open
  /// device.
  InterfaceInputsCubit({
    required this._repository,
    this._watchInterval = const Duration(milliseconds: 500),
  }) : super(const InterfaceInputsState()) {
    _subscription = _repository.looperState.listen(_followDevice);
    _followDevice(_repository.state);
  }

  final LooperRepository _repository;
  final Duration _watchInterval;
  late final StreamSubscription<LooperState> _subscription;
  Timer? _watch;

  /// The open device's name, or null with none open; a result for another
  /// device is dropped.
  String? _device;

  /// The open device's engine lifetime: a reopen of the same device reads it
  /// again without dropping what is shown.
  int _generation = -1;

  /// Every read and write runs after the last one finished, so the interface
  /// takes changes in the order the player made them and a read never
  /// reports a value from before a change that already landed.
  Future<void> _queue = Future<void>.value();
  int _queued = 0;

  void _followDevice(LooperState looper) {
    final status = looper.status;
    final device = status.isConnected && status.devicePresent
        ? status.deviceName
        : null;
    final generation = looper.mixGeneration;
    if (device == _device) {
      if (device != null && generation != _generation) {
        _generation = generation;
        _enqueue(_read);
      }
      return;
    }
    _device = device;
    _generation = generation;
    emit(const InterfaceInputsState());
    if (device != null) _enqueue(_read);
  }

  /// Runs [operation] after everything queued before it.
  void _enqueue(Future<void> Function() operation) {
    _queued++;
    _queue = _queue.then((_) async {
      try {
        if (!isClosed) await operation();
      } on Object catch (error, stackTrace) {
        if (!isClosed) addError(error, stackTrace);
      } finally {
        _queued--;
      }
    });
  }

  /// Reads the interface and shows what it reports.
  Future<void> _read() async {
    final device = _device;
    if (device == null) return;
    final read = await _repository.readInterfaceInputs();
    if (isClosed || device != _device) return;
    emit(state.reading(read));
  }

  /// Reads the interface twice a second until [stopWatching], so a change
  /// made on the interface itself shows. A tick with anything still queued
  /// is skipped.
  void startWatching() {
    if (isClosed) return;
    _watch?.cancel();
    void tick() {
      if (_queued == 0) _enqueue(_read);
    }

    _watch = Timer.periodic(_watchInterval, (_) => tick());
    tick();
  }

  /// Stops [startWatching]'s reads.
  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  /// Sets [input]'s level.
  void setLevel(int input, InputLevel level) => _change(
    InterfaceSwitch.level,
    () => _repository.setInterfaceInputLevel(input, level),
  );

  /// Sets [input]'s pad.
  void setPad(int input, {required bool on}) => _change(
    InterfaceSwitch.pad,
    () => _repository.setInterfaceInputPad(input, on: on),
  );

  /// Sets [input]'s Air.
  void setAir(int input, InputAir air) => _change(
    InterfaceSwitch.air,
    () => _repository.setInterfaceInputAir(input, air),
  );

  /// Turns 48 V switch [phantomSwitch] on or off. Turning it on is the
  /// player's confirmed request; nothing calls this on its own.
  void setPhantomPower(int phantomSwitch, {required bool on}) => _change(
    InterfaceSwitch.phantom,
    () => _repository.setInterfacePhantomPower(phantomSwitch, on: on),
  );

  /// Turns the unit's setup mode off; it shows its controls after a power
  /// cycle.
  void turnOffSetupMode() =>
      _change(InterfaceSwitch.setupMode, _repository.turnOffInterfaceSetupMode);

  /// Queues [write], counts a refusal, then reads what the interface holds,
  /// refused or not. A write that finds the engine stopped is not the
  /// interface refusing.
  void _change(
    InterfaceSwitch which,
    Future<EngineResult> Function() write,
  ) {
    final device = _device;
    if (device == null) return;
    _enqueue(() async {
      if (device != _device) return;
      EngineResult result;
      try {
        result = await write();
      } on Object catch (error, stackTrace) {
        addError(error, stackTrace);
        result = EngineResult.device;
      }
      if (isClosed || device != _device) return;
      if (!result.isOk && result != EngineResult.notRunning) {
        emit(state.refusing(which));
      }
    });
    _enqueue(_read);
  }

  @override
  Future<void> close() async {
    stopWatching();
    await _subscription.cancel();
    return await super.close();
  }
}
