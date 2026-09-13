import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_mapping.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:equatable/equatable.dart';

/// One thing the engine asks its owner to do.
sealed class MidiOutput extends Equatable {
  const MidiOutput();
}

/// Set the parameter [key] to [value] (`0..1`).
final class MidiParameterWrite extends MidiOutput {
  /// Creates a [MidiParameterWrite].
  const MidiParameterWrite(this.key, this.value);

  /// The parameter, as its opaque key.
  final String key;

  /// The value to write.
  final double value;

  @override
  List<Object?> get props => [key, value];
}

/// Run the action [key] for [mappingId].
final class MidiActionRun extends MidiOutput {
  /// Creates a [MidiActionRun].
  const MidiActionRun({required this.mappingId, required this.key});

  /// The mapping that ran it — what a later [MidiActionEnd] names.
  final String mappingId;

  /// The action, as its opaque key.
  final String key;

  @override
  List<Object?> get props => [mappingId, key];
}

/// End whatever a held [MidiActionRun] for the same mapping and action
/// started. An action with nothing to hold ignores it.
final class MidiActionEnd extends MidiOutput {
  /// Creates a [MidiActionEnd].
  const MidiActionEnd({required this.mappingId, required this.key});

  /// The mapping.
  final String mappingId;

  /// The action.
  final String key;

  @override
  List<Object?> get props => [mappingId, key];
}

/// Turns MIDI messages into parameter writes and actions, according to the
/// saved mappings.
///
/// Pure apart from what it remembers between messages: it WRITES nothing, it
/// returns [MidiOutput]s for its owner to apply. The one thing it reads is a
/// parameter's current value, through `read`, because two of the accepted
/// rules need it — a knob only takes over once it reaches the value, and a
/// relative control moves from wherever the value is.
///
/// The runtime rules are the accepted design's, one for one:
///
/// - a button is down while any channel it listens on has a contact down; a
///   Program is always a press and is never released;
/// - a toggle flips on press; a momentary parameter holds its Held value while
///   down; a toggle parameter follows the latch;
/// - an action runs on its edge, and one run on press is ended on release;
/// - a knob writes nothing until it takes over — its value lands within a step
///   of the parameter's, or crosses it — so opening a rig never jumps a value;
/// - a relative control moves from the current value by the parameter's step,
///   in the direction its range runs, and stays inside that range;
/// - disabling a mapping, deleting it, pausing or disconnecting its device, or
///   turning Control off, ends every hold: momentary parameters return to
///   Released and held actions end, and no action is ever synthesized;
/// - reconnecting clears contacts, takeover and toggle latches, so the next
///   input starts from nothing.
class MidiMappingEngine {
  /// Creates a [MidiMappingEngine].
  MidiMappingEngine({
    required Duration Function() clock,
    required double? Function(String key) read,
    required double Function(String key) step,
  }) : _decoder = MidiDecoder(clock: clock),
       _read = read,
       _step = step;

  final MidiDecoder _decoder;
  final double? Function(String key) _read;
  final double Function(String key) _step;

  MidiMappingSet _mappings = const MidiMappingSet();
  bool _controlEnabled = true;
  final Set<String> _paused = {};
  final Map<String, _MappingRuntime> _runtime = {};

  /// The saved mappings.
  MidiMappingSet get mappings => _mappings;

  /// Whether remote assignments dispatch at all.
  bool get controlEnabled => _controlEnabled;

  /// Replaces the saved mappings.
  ///
  /// A mapping that is gone, disabled, or changed in any way is released first
  /// — its holds end under the mapping they were pressed under — and starts
  /// again from nothing.
  List<MidiOutput> setMappings(MidiMappingSet next) {
    final outputs = <MidiOutput>[];
    for (final previous in _mappings.mappings) {
      final now = next.byId(previous.id);
      if (now == previous && now!.enabled) continue;
      outputs.addAll(_release(previous));
    }
    _mappings = next;
    return outputs;
  }

  /// Turns remote assignments on or off. Off keeps every mapping and ends
  /// every hold.
  List<MidiOutput> setControlEnabled({required bool enabled}) {
    if (_controlEnabled == enabled) return const [];
    _controlEnabled = enabled;
    if (enabled) return const [];
    return [for (final mapping in _mappings.mappings) ..._release(mapping)];
  }

  /// Stops [device] dispatching while one of its mappings is being learned or
  /// edited, ending its holds.
  List<MidiOutput> pause(String device) {
    _paused.add(device);
    _decoder.reset(device);
    return _releaseDevice(device);
  }

  /// Lets [device] dispatch again.
  void resume(String device) {
    _paused.remove(device);
    _decoder.reset(device);
  }

  /// [device] went away, or came back. Either way its holds end, and the next
  /// message from it starts from nothing.
  List<MidiOutput> connectionChanged(String device) {
    _decoder.reset(device);
    return _releaseDevice(device);
  }

  /// The first learnable reading [message] completes from [device] in
  /// [protocol], or `null`.
  ///
  /// A Note release is not learnable — Learn wants the press — and neither is
  /// a relative reading that moves nothing.
  MidiControlEvent? learn(
    String device,
    RawControllerInput message,
    MidiProtocol protocol,
  ) {
    final event = _decoder.feed(device, message, protocol);
    if (event == null) return null;
    if (event.source.kind == ControllerSourceKind.midiNote &&
        event.value == 0) {
      return null;
    }
    if (event.delta == 0) return null;
    return event;
  }

  /// Discards partial messages from [device] — when Learn starts, so a half
  /// received before it cannot complete the reading Learn records.
  void resetDecoder(String device) => _decoder.reset(device);

  /// Applies [message] from [device] to every enabled mapping it completes.
  List<MidiOutput> receive(String device, RawControllerInput message) {
    if (!_controlEnabled || _paused.contains(device)) return const [];
    final live = [
      for (final mapping in _mappings.mappings)
        if (mapping.enabled && mapping.source.device == device) mapping,
    ];
    if (live.isEmpty) return const [];
    final outputs = <MidiOutput>[];
    for (final protocol in {for (final m in live) m.source.protocol}) {
      final event = _decoder.feed(device, message, protocol);
      if (event == null) continue;
      for (final mapping in live) {
        if (!mapping.source.sameAs(event.source)) continue;
        outputs.addAll(_apply(mapping, event));
      }
    }
    return outputs;
  }

  List<MidiOutput> _apply(MidiMapping mapping, MidiControlEvent event) {
    final runtime = _runtime.putIfAbsent(mapping.id, _MappingRuntime.new);
    final source = event.source;
    final program = source.kind == ControllerSourceKind.midiProgram;
    // The channel it arrived on: a mapping on All channels is down while any
    // of them is.
    final channel = source.channel ?? 0;
    if (event.value > 0) {
      runtime.contacts.add(channel);
    } else {
      runtime.contacts.remove(channel);
    }
    final down = program || runtime.contacts.isNotEmpty;
    final MidiEdge? edge;
    if (program) {
      edge = MidiEdge.press;
    } else if (down && !runtime.down) {
      edge = MidiEdge.press;
    } else if (!down && runtime.down) {
      edge = MidiEdge.release;
    } else {
      edge = null;
    }
    final fraction = event.value / event.maximum;
    final outputs = <MidiOutput>[];

    if (edge == MidiEdge.release) {
      for (final key in runtime.heldActions) {
        outputs.add(MidiActionEnd(mappingId: mapping.id, key: key));
      }
      runtime.heldActions.clear();
    }
    if (mapping.behavior == MidiBehavior.toggle && edge == MidiEdge.press) {
      runtime.latched = !runtime.latched;
    }

    for (final control in mapping.controls) {
      switch (control) {
        case MidiActionControl(:final key, :final trigger):
          if (edge != trigger) continue;
          outputs.add(MidiActionRun(mappingId: mapping.id, key: key));
          // An action run on release, or by a Program, has no release to wait
          // for; one run on press is held until the control comes up.
          if (edge == MidiEdge.release || program) {
            outputs.add(MidiActionEnd(mappingId: mapping.id, key: key));
          } else {
            runtime.heldActions.add(key);
          }
        case MidiParameterControl(:final key, :final low, :final high):
          final current = _read(key);
          if (current == null) continue; // gone from the rig: skipped
          final delta = event.delta;
          if (delta != null) {
            final direction = (high - low).sign;
            final lower = low < high ? low : high;
            final upper = low < high ? high : low;
            final moved = current + delta * _step(key) * direction;
            outputs.add(MidiParameterWrite(key, moved.clamp(lower, upper)));
          } else if (mapping.behavior == MidiBehavior.continuous) {
            final value = low + (high - low) * fraction;
            final previous = runtime.previous;
            if (!runtime.caught.contains(key)) {
              final near =
                  (value - current).abs() <=
                  _max(2 / event.maximum, _step(key)) / 2;
              final prior = previous == null
                  ? null
                  : low + (high - low) * previous;
              final crossed =
                  prior != null && (prior - current) * (value - current) <= 0;
              if (near || crossed) runtime.caught.add(key);
            }
            if (runtime.caught.contains(key)) {
              outputs.add(MidiParameterWrite(key, value));
            }
          } else if (mapping.behavior == MidiBehavior.toggle) {
            // Only when the latch moved. A toggle's release changes nothing,
            // and writing the unchanged value again would snap back a value
            // the performer has adjusted on screen since the press.
            if (edge == MidiEdge.press) {
              outputs.add(
                MidiParameterWrite(key, runtime.latched ? high : low),
              );
            }
          } else if (edge != null) {
            outputs.add(MidiParameterWrite(key, down ? high : low));
          }
      }
    }
    runtime
      ..previous = fraction
      ..down = down;
    return outputs;
  }

  List<MidiOutput> _releaseDevice(String device) => [
    for (final mapping in _mappings.mappings)
      if (mapping.source.device == device) ..._release(mapping),
  ];

  /// Ends [mapping]'s holds and forgets everything it remembered.
  List<MidiOutput> _release(MidiMapping mapping) {
    final runtime = _runtime.remove(mapping.id);
    if (runtime == null) return const [];
    return [
      for (final key in runtime.heldActions)
        MidiActionEnd(mappingId: mapping.id, key: key),
      if (runtime.down && mapping.behavior == MidiBehavior.momentary)
        for (final control in mapping.controls)
          if (control is MidiParameterControl)
            MidiParameterWrite(control.key, control.low),
    ];
  }

  static double _max(double a, double b) => a > b ? a : b;
}

/// What one mapping remembers between messages.
class _MappingRuntime {
  bool down = false;
  bool latched = false;
  double? previous;
  final Set<String> caught = {};
  final Set<int> contacts = {};
  final List<String> heldActions = [];
}
