import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_mapping.dart';
import 'package:controller_repository/src/midi_protocol.dart';

/// A proposed operation. Its owner reports admission through
/// [MidiMappingEngine.settle].
sealed class MidiOperation {
  /// Creates an operation for one ordered control row.
  const MidiOperation(this.controlIndex, this.key);

  /// Position in the mapping's ordered controls.
  final int controlIndex;

  /// Stable application target key.
  final String key;
}

/// Write a parameter; [held] distinguishes a momentary hold or release.
final class MidiParameterWrite extends MidiOperation {
  /// Creates a parameter write.
  const MidiParameterWrite(
    super.controlIndex,
    super.key,
    this.value, {
    this.held,
    this.cleanup = false,
  });

  /// Requested normalized value.
  final double value;

  /// `true` for held, `false` for released, `null` for an unheld value.
  final bool? held;

  /// Whether this operation retires an accepted contribution.
  final bool cleanup;
}

/// Remove an accepted continuous or toggle contribution without changing sound.
final class MidiParameterEnd extends MidiOperation {
  /// Creates a parameter contribution retirement.
  const MidiParameterEnd(super.controlIndex, super.key);
}

/// Run an action. The runtime owns the accepted action identity until End.
final class MidiActionRun extends MidiOperation {
  /// Creates an action run.
  const MidiActionRun(super.controlIndex, super.key, {this.expectsEnd = false});

  /// A press action stays held until the matching accepted End.
  final bool expectsEnd;
}

/// End an accepted action run by its captured identity.
final class MidiActionEnd extends MidiOperation {
  /// Creates an action end.
  const MidiActionEnd(super.controlIndex, super.key);
}

/// One immutable admission request for one mapping generation.
final class MidiProposal {
  MidiProposal._(
    this.mappingId,
    this.generation,
    this.operations,
    this._effects,
  );

  /// Stable saved mapping identity.
  final String mappingId;

  /// Distinct lifetime even when a saved ID is reused.
  final int generation;

  /// Operations in configured row order.
  final List<MidiOperation> operations;

  final Map<int, void Function()> _effects;
}

/// Pure, admission-aware interpretation of complete MIDI readings.
///
/// Raw contact and position observations may advance on refusal. Pickup,
/// toggle, accepted holds and cleanup change only when their owner confirms a
/// row via [settle]. Call prepare/settle serially, including retirement.
class MidiMappingEngine {
  /// Creates an engine with application-owned current-value and step reads.
  MidiMappingEngine({
    required double? Function(String key) read,
    required double Function(String key) step,
  }) : _read = read,
       _step = step;

  final double? Function(String key) _read;
  final double Function(String key) _step;
  MidiMappingSet _mappings = MidiMappingSet.empty;
  final Map<String, _MappingState> _active = {};
  final Map<int, _MappingState> _retired = {};
  int _nextGeneration = 1;

  /// Current immutable mapping set.
  MidiMappingSet get mappings => _mappings;

  /// Replace configuration, retaining cleanup for every changed generation.
  List<MidiProposal> setMappings(MidiMappingSet next) {
    final cleanup = <MidiProposal>[];
    for (final entry in _active.entries.toList()) {
      final replacement = next.byId(entry.key);
      if (replacement != entry.value.mapping || replacement?.enabled != true) {
        cleanup.addAll(retire(mappingId: entry.key));
      }
    }
    _mappings = next;
    return cleanup;
  }

  /// Prepare every enabled mapping matched by a complete reading.
  List<MidiProposal> prepare(MidiControlEvent event) {
    final proposals = <MidiProposal>[];
    for (final mapping in _mappings.mappings) {
      if (!mapping.enabled || !mapping.source.sameAs(event.source)) continue;
      final state = _active.putIfAbsent(
        mapping.id,
        () => _MappingState(mapping, _nextGeneration++),
      );
      final proposal = _prepare(state, event);
      if (proposal != null) proposals.add(proposal);
    }
    return proposals;
  }

  MidiProposal? _prepare(_MappingState state, MidiControlEvent event) {
    final mapping = state.mapping;
    final program = event.source.kind == ControllerSourceKind.midiProgram;
    final wasDown = state.contacts.isNotEmpty;
    final channel = event.source.channel ?? 0;
    if (event.value > 0) {
      state.contacts.add(channel);
    } else {
      state.contacts.remove(channel);
    }
    final down = program || state.contacts.isNotEmpty;
    final edge = program
        ? MidiEdge.press
        : down && !wasDown
        ? MidiEdge.press
        : !down && wasDown
        ? MidiEdge.release
        : null;
    final fraction = event.value / event.maximum;
    final operations = <MidiOperation>[];
    final effects = <int, void Function()>{};
    for (final (index, control) in mapping.controls.indexed) {
      final row = state.rows.putIfAbsent(index, _RowState.new);
      if (edge == MidiEdge.release && (row.held || row.actionHeld)) {
        row.releasePending = true;
      }
      switch (control) {
        case MidiActionControl(:final key, :final trigger):
          if (row.actionHeld && edge == MidiEdge.release) {
            operations.add(MidiActionEnd(index, key));
            effects[index] = () {
              row
                ..actionHeld = false
                ..releasePending = false;
            };
          } else if (edge == trigger) {
            final expectsEnd = edge == MidiEdge.press && !program;
            operations.add(
              MidiActionRun(index, key, expectsEnd: expectsEnd),
            );
            effects[index] = () {
              row
                ..actionHeld = expectsEnd
                ..releasePending = false;
            };
          }
        case MidiParameterControl(:final key, :final low, :final high):
          final delta = event.delta;
          if (delta != null) {
            if (delta == 0) continue;
            final current = _read(key);
            if (current == null) continue;
            final direction = (high - low).sign;
            final lower = low < high ? low : high;
            final upper = low < high ? high : low;
            final moved = current + delta * _step(key) * direction;
            operations.add(
              MidiParameterWrite(index, key, moved.clamp(lower, upper)),
            );
            effects[index] = () => row.contributing = true;
          } else if (mapping.behavior == MidiBehavior.continuous) {
            final current = _read(key);
            if (current == null) continue;
            final value = low + (high - low) * fraction;
            final previous = state.previous;
            final near =
                (value - current).abs() <=
                _max(2 / event.maximum, _step(key)) / 2;
            final prior = previous == null
                ? null
                : low + (high - low) * previous;
            final crossed =
                prior != null && (prior - current) * (value - current) <= 0;
            if (row.caught || near || crossed) {
              operations.add(MidiParameterWrite(index, key, value));
              effects[index] = () {
                row
                  ..caught = true
                  ..contributing = true;
              };
            }
          } else if (mapping.behavior == MidiBehavior.toggle &&
              edge == MidiEdge.press) {
            final nextOn = !row.latched;
            operations.add(
              MidiParameterWrite(index, key, nextOn ? high : low),
            );
            effects[index] = () {
              row
                ..latched = nextOn
                ..contributing = true;
            };
          } else if (mapping.behavior == MidiBehavior.momentary &&
              edge == MidiEdge.press) {
            operations.add(MidiParameterWrite(index, key, high, held: true));
            effects[index] = () {
              row
                ..held = true
                ..contributing = true
                ..releasePending = false;
            };
          } else if (mapping.behavior == MidiBehavior.momentary &&
              edge == MidiEdge.release &&
              row.held) {
            operations.add(
              MidiParameterWrite(
                index,
                key,
                low,
                held: false,
                cleanup: true,
              ),
            );
            effects[index] = () {
              row
                ..held = false
                ..contributing = false
                ..releasePending = false;
            };
          } else if (mapping.behavior == MidiBehavior.trigger &&
              edge == MidiEdge.press) {
            operations.add(MidiParameterWrite(index, key, high));
            effects[index] = () => row.contributing = true;
          }
      }
    }
    state.previous = fraction;
    if (operations.isEmpty) return null;
    return MidiProposal._(
      mapping.id,
      state.generation,
      List.unmodifiable(operations),
      effects,
    );
  }

  /// Commit only rows whose downstream owner accepted the operation.
  void settle(MidiProposal proposal, Set<int> acceptedControlIndices) {
    final state = _active[proposal.mappingId];
    final same = state?.generation == proposal.generation
        ? state
        : _retired[proposal.generation];
    if (same == null) return;
    for (final index in acceptedControlIndices) {
      proposal._effects[index]?.call();
    }
    if (_retired.containsKey(proposal.generation) && !same.hasClaims) {
      _retired.remove(proposal.generation);
    }
  }

  /// Retire current mappings, preserving refused cleanup for later retry.
  List<MidiProposal> retire({String? device, String? mappingId}) {
    final proposals = <MidiProposal>[];
    for (final entry in _active.entries.toList()) {
      final state = entry.value;
      if (device != null && state.mapping.source.device != device) continue;
      if (mappingId != null && entry.key != mappingId) continue;
      _active.remove(entry.key);
      if (state.hasClaims) {
        _retired[state.generation] = state;
        proposals.add(_cleanup(state));
      }
    }
    return proposals;
  }

  /// Retry cleanup after owner eligibility changes, including old generations.
  List<MidiProposal> retryCleanup() => [
    for (final state in _active.values)
      if (state.rows.values.any((row) => row.releasePending))
        _cleanupReleased(state),
    for (final state in _retired.values)
      if (state.hasClaims) _cleanup(state),
  ];

  MidiProposal _cleanupReleased(_MappingState state) {
    final operations = <MidiOperation>[];
    final effects = <int, void Function()>{};
    for (final (index, control) in state.mapping.controls.indexed) {
      final row = state.rows[index];
      if (row == null) continue;
      switch (control) {
        case MidiActionControl(:final key):
          if (!row.actionHeld || !row.releasePending) continue;
          operations.add(MidiActionEnd(index, key));
          effects[index] = () {
            row
              ..actionHeld = false
              ..releasePending = false;
          };
        case MidiParameterControl(:final key, :final low):
          if (!row.held || !row.releasePending) continue;
          operations.add(
            MidiParameterWrite(index, key, low, held: false, cleanup: true),
          );
          effects[index] = () {
            row
              ..held = false
              ..contributing = false
              ..releasePending = false;
          };
      }
    }
    return MidiProposal._(
      state.mapping.id,
      state.generation,
      List.unmodifiable(operations),
      effects,
    );
  }

  MidiProposal _cleanup(_MappingState state) {
    final operations = <MidiOperation>[];
    final effects = <int, void Function()>{};
    for (final (index, control) in state.mapping.controls.indexed) {
      final row = state.rows[index];
      if (row == null) continue;
      switch (control) {
        case MidiActionControl(:final key):
          if (!row.actionHeld) continue;
          operations.add(MidiActionEnd(index, key));
          effects[index] = () {
            row
              ..actionHeld = false
              ..releasePending = false;
          };
        case MidiParameterControl(:final key, :final low):
          if (!row.contributing) continue;
          if (row.held) {
            operations.add(
              MidiParameterWrite(
                index,
                key,
                low,
                held: false,
                cleanup: true,
              ),
            );
          } else {
            operations.add(MidiParameterEnd(index, key));
          }
          effects[index] = () {
            row
              ..held = false
              ..contributing = false
              ..releasePending = false;
          };
      }
    }
    return MidiProposal._(
      state.mapping.id,
      state.generation,
      List.unmodifiable(operations),
      effects,
    );
  }

  /// Forget replaced target owners without replaying their old contact state.
  /// Other rows retain accepted claims and the physical contact stays down
  /// until its actual release, so reappearance never synthesizes a press.
  void invalidateTargets(Set<String> keys) {
    for (final state in [..._active.values, ..._retired.values]) {
      var changed = false;
      for (final (index, control) in state.mapping.controls.indexed) {
        if (!keys.contains(control.key)) continue;
        state.rows.remove(index);
        changed = true;
      }
      if (changed) state.previous = null;
    }
    _retired.removeWhere((_, state) => !state.hasClaims);
  }

  /// Discard all claims only when the entire owning session is replaced.
  void reset() {
    _active.clear();
    _retired.clear();
  }

  static double _max(double a, double b) => a > b ? a : b;
}

class _MappingState {
  _MappingState(this.mapping, this.generation);

  final MidiMapping mapping;
  final int generation;
  final Set<int> contacts = {};
  final Map<int, _RowState> rows = {};
  double? previous;

  bool get hasClaims => rows.values.any(
    (row) => row.actionHeld || row.contributing,
  );
}

class _RowState {
  bool caught = false;
  bool latched = false;
  bool held = false;
  bool contributing = false;
  bool actionHeld = false;
  bool releasePending = false;
}
