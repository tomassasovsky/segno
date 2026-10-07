import 'package:equatable/equatable.dart';
import 'package:instrument_repository/src/models/instrument.dart';
import 'package:instrument_repository/src/models/working_copy.dart';
import 'package:segno_engine/segno_engine.dart';

/// What the compiler could not carry into the engine's table as defined.
enum RouteProblemKind {
  /// More remaps than the engine holds; the later ones were left out.
  tooManyRemaps,

  /// A remap plays more notes than the engine holds; the later ones were
  /// left out.
  tooManyRemapNotes,

  /// A field outside the engine's range; the instrument's MIDI is off until
  /// it is fixed.
  invalid,
}

/// One compile problem, for the instrument named.
class RouteProblem extends Equatable {
  /// Creates a [RouteProblem].
  const RouteProblem(this.instrumentId, this.kind);

  /// The instrument it concerns.
  final String instrumentId;

  /// What went wrong.
  final RouteProblemKind kind;

  @override
  List<Object?> get props => [instrumentId, kind];
}

/// The engine routing table for [copy]: one entry per slot. An instrument
/// plays MIDI only when it is enabled and its device is attached to an engine
/// port ([ports]: device id to port). Everything the engine cannot hold is
/// reported in `problems`, never dropped silently.
({List<InstrumentRoute> routes, List<RouteProblem> problems}) compileRoutes(
  InstrumentsWorkingCopy copy,
  Map<String, int> ports,
) {
  final routes = List<InstrumentRoute>.filled(
    kMaxInstruments,
    InstrumentRoute.disabled,
  );
  final problems = <RouteProblem>[];
  for (final instrument in copy.instruments) {
    final midi = instrument.midi;
    final port = ports[midi.deviceId];
    if (!midi.enabled || port == null) continue;
    void report(RouteProblemKind kind) {
      final problem = RouteProblem(instrument.id, kind);
      if (!problems.contains(problem)) problems.add(problem);
    }

    if (midi.remaps.length > kMaxInstrumentRemaps) {
      report(RouteProblemKind.tooManyRemaps);
    }
    final route = InstrumentRoute(
      midiEnabled: true,
      port: port,
      channel: midi.channel ?? 0,
      low: midi.low,
      high: midi.high,
      remaps: [
        for (final r in midi.remaps.take(kMaxInstrumentRemaps))
          _remap(r, port, () => report(RouteProblemKind.tooManyRemapNotes)),
      ],
    );
    if (!route.isValid) {
      report(RouteProblemKind.invalid);
      continue;
    }
    routes[instrument.slot] = route;
  }
  return (routes: routes, problems: problems);
}

InstrumentRemap _remap(NoteRemap r, int port, void Function() truncated) {
  if (r.notes.length > kMaxRemapNotes) truncated();
  return InstrumentRemap(
    port: port,
    channel: r.channel ?? 0,
    kind: r.trigger == RemapTrigger.note
        ? MidiRemapKind.note
        : MidiRemapKind.controller,
    number: r.number,
    notes: r.notes.take(kMaxRemapNotes).toList(growable: false),
  );
}
