import 'package:equatable/equatable.dart';
import 'package:instrument_repository/src/models/instrument.dart';
import 'package:segno_engine/segno_engine.dart';

/// Why [InstrumentsWorkingCopy.add] refused.
enum AddRefusal {
  /// Every slot holds an instrument.
  full,

  /// Every free slot is held by a removed instrument's recorded material;
  /// clearing those routes frees them.
  tombstoned,
}

/// The persisted instruments family: every definition and every tombstone.
/// Immutable; each edit returns the next copy for the owner to write.
class InstrumentsWorkingCopy extends Equatable {
  /// Creates an [InstrumentsWorkingCopy].
  const InstrumentsWorkingCopy({
    this.instruments = const [],
    this.tombstones = const [],
  });

  /// Decodes [json]; throws [FormatException] when it is malformed or two
  /// entries claim one slot or id.
  factory InstrumentsWorkingCopy.fromJson(Map<String, dynamic> json) {
    if (json['version'] != version) {
      throw FormatException('Unknown instruments version', json['version']);
    }
    final copy = InstrumentsWorkingCopy(
      instruments: [
        for (final i in json['instruments'] as List<dynamic>? ?? const [])
          Instrument.fromJson(i as Map<String, dynamic>),
      ],
      tombstones: [
        for (final t in json['tombstones'] as List<dynamic>? ?? const [])
          Tombstone.fromJson(t as Map<String, dynamic>),
      ],
    );
    final slots = [
      ...copy.instruments.map((i) => i.slot),
      ...copy.tombstones.map((t) => t.slot),
    ];
    if (slots.any((s) => s < 0 || s >= kMaxInstruments) ||
        slots.toSet().length != slots.length ||
        copy.instruments.map((i) => i.id).toSet().length !=
            copy.instruments.length) {
      throw FormatException('Conflicting instrument slots or ids', json);
    }
    return copy;
  }

  /// The stored format's version.
  static const int version = 1;

  /// The definitions, in slot order.
  final List<Instrument> instruments;

  /// The removed instruments still labelling material.
  final List<Tombstone> tombstones;

  /// The instrument with [id], or null.
  Instrument? byId(String id) {
    for (final i in instruments) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// The instrument in [slot], or null.
  Instrument? bySlot(int slot) {
    for (final i in instruments) {
      if (i.slot == slot) return i;
    }
    return null;
  }

  /// The first slot neither an instrument nor a tombstone holds, or null.
  int? get freeSlot {
    final taken = {
      ...instruments.map((i) => i.slot),
      ...tombstones.map((t) => t.slot),
    };
    for (var s = 0; s < kMaxInstruments; s++) {
      if (!taken.contains(s)) return s;
    }
    return null;
  }

  /// Adds a definition in the first free slot, or says why it cannot. New
  /// instruments start with their MIDI and computer keys off.
  ({InstrumentsWorkingCopy? copy, AddRefusal? refusal}) add({
    required String id,
    required String name,
    required String soundId,
    required List<double> params,
  }) {
    final slot = freeSlot;
    if (slot == null) {
      return (
        copy: null,
        refusal: tombstones.isEmpty ? AddRefusal.full : AddRefusal.tombstoned,
      );
    }
    final added = Instrument(
      id: id,
      slot: slot,
      name: name,
      soundId: soundId,
      params: params,
    );
    return (
      copy: InstrumentsWorkingCopy(
        instruments: [...instruments, added]
          ..sort((a, b) => a.slot.compareTo(b.slot)),
        tombstones: tombstones,
      ),
      refusal: null,
    );
  }

  /// This copy with [next] replacing the instrument of the same id.
  InstrumentsWorkingCopy replace(Instrument next) => InstrumentsWorkingCopy(
    instruments: [
      for (final i in instruments)
        if (i.id == next.id) next else i,
    ],
    tombstones: tombstones,
  );

  /// This copy without [id]. With [keepLabel] (its slot still names recorded
  /// material) a tombstone keeps the name and holds the slot.
  InstrumentsWorkingCopy remove(String id, {required bool keepLabel}) {
    final gone = byId(id);
    if (gone == null) return this;
    return InstrumentsWorkingCopy(
      instruments: [
        for (final i in instruments)
          if (i.id != id) i,
      ],
      tombstones: [
        ...tombstones,
        if (keepLabel) Tombstone(slot: gone.slot, name: gone.name),
      ],
    );
  }

  /// This copy with [slot]'s tombstone cleared (no route names it any more).
  InstrumentsWorkingCopy clearTombstone(int slot) => InstrumentsWorkingCopy(
    instruments: instruments,
    tombstones: [
      for (final t in tombstones)
        if (t.slot != slot) t,
    ],
  );

  /// The JSON form.
  Map<String, dynamic> toJson() => {
    'version': version,
    'instruments': [for (final i in instruments) i.toJson()],
    'tombstones': [for (final t in tombstones) t.toJson()],
  };

  @override
  List<Object?> get props => [instruments, tombstones];
}
