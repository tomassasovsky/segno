import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

/// What the console can do with the interface's input switches (#1646).
enum InterfaceInputsStatus {
  /// The interface exposes none: its own switches set them.
  noControls,

  /// [InterfaceInputs.inputs] lists what can be set.
  controls,

  /// A Focusrite unit in its setup (MSD) mode, which hides its controls
  /// until setup mode is turned off and the unit is power-cycled.
  setupMode,

  /// Setup mode is off; the unit shows its controls after a power cycle.
  setupModeRestart,
}

/// An input's level: what the input expects to have plugged in.
enum InputLevel {
  /// A line-level source (keyboard, mixer, a mic through the preamp).
  line,

  /// An instrument (Hi-Z): a guitar or a bass straight in.
  inst,
}

/// An input's Air: a switch (off, [presence]) on most units, three-way on a
/// Scarlett 4th Gen.
enum InputAir {
  /// Off.
  off,

  /// On (a switch), or Presence (three-way).
  presence,

  /// Presence + Drive (three-way only).
  presenceDrive,
}

/// One input's switches; null where the interface has none.
class InterfaceInput extends Equatable {
  /// Creates an [InterfaceInput].
  const new({
    this.level,
    this.pad,
    this.air,
    this.airThreeWay = false,
    this.phantomSwitch,
  });

  /// An input with nothing to set.
  static const none = InterfaceInput();

  /// The level, or null.
  final InputLevel? level;

  /// Whether the pad is on, or null.
  final bool? pad;

  /// The Air setting, or null.
  final InputAir? air;

  /// Whether [air] has three choices (Off, Presence, Presence + Drive)
  /// rather than being a switch.
  final bool airThreeWay;

  /// The index into [InterfaceInputs.phantomSwitches] of the 48 V switch that
  /// powers this input, or null.
  final int? phantomSwitch;

  /// Whether this input has any switch to set.
  bool get hasSwitches =>
      level != null || pad != null || air != null || phantomSwitch != null;

  @override
  List<Object?> get props => [level, pad, air, airThreeWay, phantomSwitch];
}

/// One 48 V switch and the inputs it powers (0-based, inclusive). A switch
/// that powers two inputs is one control: turning it on powers both.
class PhantomSwitch extends Equatable {
  /// Creates a [PhantomSwitch].
  const new({
    required this.firstInput,
    required this.lastInput,
    required this.on,
  });

  /// The first input it powers.
  final int firstInput;

  /// The last input it powers.
  final int lastInput;

  /// Whether it is on.
  final bool on;

  /// Whether it powers [input].
  bool powers(int input) => input >= firstInput && input <= lastInput;

  @override
  List<Object?> get props => [firstInput, lastInput, on];
}

/// What the interface's input switches hold, as the interface reports them.
/// Nothing here is stored by Segno: the interface keeps its own settings, and
/// its front-panel buttons change the same values.
class InterfaceInputs extends Equatable {
  /// Creates an [InterfaceInputs].
  const new({
    required this.status,
    this.inputs = const [],
    this.phantomSwitches = const [],
  });

  /// An interface with nothing to set from the console.
  static const none = InterfaceInputs(status: InterfaceInputsStatus.noControls);

  /// What the console can do.
  final InterfaceInputsStatus status;

  /// The switches of Segno's inputs `0..inputs.length`.
  final List<InterfaceInput> inputs;

  /// The interface's 48 V switches.
  final List<PhantomSwitch> phantomSwitches;

  /// The switches of Segno's input [input]; [InterfaceInput.none] past the
  /// last one described.
  InterfaceInput inputAt(int input) =>
      input >= 0 && input < inputs.length ? inputs[input] : InterfaceInput.none;

  /// The 48 V switch that powers [input], or null.
  PhantomSwitch? phantomFor(int input) {
    final index = inputAt(input).phantomSwitch;
    return index == null || index >= phantomSwitches.length
        ? null
        : phantomSwitches[index];
  }

  @override
  List<Object?> get props => [status, inputs, phantomSwitches];
}

// --- Boundary mapper (package-internal; not exported from the barrel). ---

/// Maps the engine's reading to the domain model.
InterfaceInputs interfaceInputsFromEngine(
  engine.InterfaceInputsInfo info,
) => InterfaceInputs(
  status: switch (info.state) {
    engine.InterfaceInputsState.noControls => InterfaceInputsStatus.noControls,
    engine.InterfaceInputsState.controls => InterfaceInputsStatus.controls,
    engine.InterfaceInputsState.setupMode => InterfaceInputsStatus.setupMode,
    engine.InterfaceInputsState.setupModeRestart =>
      InterfaceInputsStatus.setupModeRestart,
  },
  inputs: [
    for (final input in info.inputs)
      InterfaceInput(
        level: switch (input.level) {
          null => null,
          0 => InputLevel.line,
          _ => InputLevel.inst,
        },
        pad: input.pad == null ? null : input.pad != 0,
        air: switch (input.air) {
          null => null,
          0 => InputAir.off,
          1 => InputAir.presence,
          _ => InputAir.presenceDrive,
        },
        airThreeWay: input.airChoices == 3,
        phantomSwitch: input.phantomGroup,
      ),
  ],
  phantomSwitches: [
    for (final p in info.phantom)
      PhantomSwitch(firstInput: p.first, lastInput: p.last, on: p.on),
  ],
);
