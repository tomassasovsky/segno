part of 'interface_inputs_cubit.dart';

/// A switch on the interface the player can change.
enum InterfaceSwitch {
  /// An input's Inst or Line.
  level,

  /// An input's pad.
  pad,

  /// An input's Air.
  air,

  /// A 48 V switch.
  phantom,

  /// A Focusrite unit's setup mode.
  setupMode,
}

/// What the interface's input switches hold, for the device the engine has
/// open (#1646).
class InterfaceInputsState extends Equatable {
  /// Creates an [InterfaceInputsState].
  const new({
    this.inputs = InterfaceInputs.none,
    this.loaded = false,
    this.failures = 0,
    this.lastFailure,
  });

  /// What the interface reports; [InterfaceInputs.none] until [loaded].
  final InterfaceInputs inputs;

  /// Whether the open device has been read at least once.
  final bool loaded;

  /// How many changes the interface refused while this device has been open:
  /// a listener says so when it grows.
  final int failures;

  /// The switch the last refused change was for.
  final InterfaceSwitch? lastFailure;

  /// This state after a refused change of [refused].
  InterfaceInputsState refusing(InterfaceSwitch refused) =>
      InterfaceInputsState(
        inputs: inputs,
        loaded: loaded,
        failures: failures + 1,
        lastFailure: refused,
      );

  /// This state with [read] as what the interface reports.
  InterfaceInputsState reading(InterfaceInputs read) => InterfaceInputsState(
    inputs: read,
    loaded: true,
    failures: failures,
    lastFailure: lastFailure,
  );

  @override
  List<Object?> get props => [inputs, loaded, failures, lastFailure];
}
