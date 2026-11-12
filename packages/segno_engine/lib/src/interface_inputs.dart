import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:segno_engine/src/ffi_strings.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// What the interface Segno records from lets the console set on its inputs
/// (#1646). Mirrors the native `le_interface_state`.
enum InterfaceInputsState {
  /// Nothing to set from the console: the interface's own switches do it.
  noControls,

  /// [InterfaceInputsInfo.inputs] lists what can be set.
  controls,

  /// A Focusrite unit in its setup (MSD) mode, which hides its controls.
  setupMode,

  /// Setup mode is off; the unit shows its controls after a power cycle.
  setupModeRestart;

  /// Maps a native `le_interface_state` value; an unknown one is
  /// [noControls].
  static InterfaceInputsState fromCode(int code) => switch (code) {
    1 => controls,
    2 => setupMode,
    3 => setupModeRestart,
    _ => noControls,
  };
}

/// What `InterfaceInputControl.setInterfaceInput` changes. Mirrors the native
/// `le_interface_control`.
enum InterfaceControl {
  /// An input's level: `0` Line, `1` Inst.
  level(0),

  /// An input's pad: `0` off, `1` on.
  pad(1),

  /// An input's Air: `0` off, `1` on (or Presence), `2` Presence + Drive.
  air(2),

  /// A 48 V switch, by its index in [InterfaceInputsInfo.phantom]: `0` off,
  /// `1` on.
  phantom(3),

  /// Turns a unit's setup mode off; index and value are unused.
  setupModeOff(4);

  InterfaceControl(this.code);

  /// The native `le_interface_control` value.
  final int code;
}

/// One input's switches, as the engine reads them; null where the interface
/// has none.
@immutable
class InterfaceInputInfo {
  /// Creates an [InterfaceInputInfo].
  const InterfaceInputInfo({
    this.level,
    this.pad,
    this.air,
    this.airChoices = 0,
    this.phantomGroup,
  });

  /// `0` Line, `1` Inst.
  final int? level;

  /// `0` off, `1` on.
  final int? pad;

  /// `0` off, `1` on or Presence, `2` Presence + Drive.
  final int? air;

  /// `0` none, `2` a switch, `3` Off / Presence / Presence + Drive.
  final int airChoices;

  /// The index into [InterfaceInputsInfo.phantom] of the 48 V switch that
  /// powers this input.
  final int? phantomGroup;
}

/// One 48 V switch and the inputs it powers.
@immutable
class PhantomSwitchInfo {
  /// Creates a [PhantomSwitchInfo].
  const PhantomSwitchInfo({
    required this.first,
    required this.last,
    required this.on,
  });

  /// The first input it powers, 0-based.
  final int first;

  /// The last input it powers, 0-based.
  final int last;

  /// Whether it is on.
  final bool on;
}

/// What the interface's input switches hold, read by
/// `InterfaceInputControl.readInterfaceInputs`.
@immutable
class InterfaceInputsInfo {
  /// Creates an [InterfaceInputsInfo].
  const InterfaceInputsInfo({
    required this.state,
    this.inputs = const [],
    this.phantom = const [],
    this.adapter = '',
  });

  /// An interface with nothing to set from the console.
  const InterfaceInputsInfo.none()
    : state = InterfaceInputsState.noControls,
      inputs = const [],
      phantom = const [],
      adapter = '';

  /// Projects a native `le_interface_inputs`.
  factory InterfaceInputsInfo.fromNative(Pointer<le_interface_inputs> ptr) {
    final ref = ptr.ref;
    int? some(int v) => v < 0 ? null : v;
    final inputs = [
      for (var i = 0; i < ref.input_count && i < LE_INTERFACE_MAX_INPUTS; i++)
        InterfaceInputInfo(
          level: some(ref.inputs[i].level),
          pad: some(ref.inputs[i].pad),
          air: some(ref.inputs[i].air),
          airChoices: ref.inputs[i].air_choices,
          phantomGroup: some(ref.inputs[i].phantom_group),
        ),
    ];
    final phantom = [
      for (
        var g = 0;
        g < ref.phantom_count && g < LE_INTERFACE_MAX_PHANTOM;
        g++
      )
        PhantomSwitchInfo(
          first: ref.phantom[g].first - 1,
          last: ref.phantom[g].last - 1,
          on: ref.phantom[g].on != 0,
        ),
    ];
    return InterfaceInputsInfo(
      state: InterfaceInputsState.fromCode(ref.state),
      inputs: inputs,
      phantom: phantom,
      adapter: readNativeString(ref.adapter, capacity: 16),
    );
  }

  /// What the console can do with the interface.
  final InterfaceInputsState state;

  /// The switches of Segno's inputs `0..inputs.length`; inputs past it have
  /// none.
  final List<InterfaceInputInfo> inputs;

  /// The interface's 48 V switches.
  final List<PhantomSwitchInfo> phantom;

  /// The engine adapter that described the card (`scarlett2`, `scarlett`,
  /// `generic`), or empty.
  final String adapter;
}
