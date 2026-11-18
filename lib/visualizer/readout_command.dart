import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart' show RecordTiming;

/// A change the player asks for on the 7" readout (#1654). The readout sends
/// it over the screen link and the main screen applies it through the same
/// settings classes the Loop settings pages use; the readout sees the result
/// in its next readout push.
///
/// Both engines run the same build, so this one schema is the contract. A
/// command that arrives garbled, or that this build does not know, is
/// dropped ([fromMap] returns null).
sealed class ReadoutCommand extends Equatable {
  const new();

  /// The command [map] describes, or null when it describes none.
  static ReadoutCommand? fromMap(Object? map) {
    if (map is! Map<Object?, Object?>) return null;
    final kind = map['kind'];
    return switch (kind) {
      TempoNudge.kind => switch (map['delta']) {
        final num delta when delta.isFinite => TempoNudge(delta.toDouble()),
        _ => null,
      },
      TempoSet.kind => switch (map['bpm']) {
        final num bpm when bpm.isFinite => TempoSet(bpm.toDouble()),
        _ => null,
      },
      TempoTap.kind => const TempoTap(),
      TempoClear.kind => const TempoClear(),
      SignatureSet.kind => switch ((map['num'], map['den'])) {
        (final int beats, final int note) => SignatureSet(beats, note),
        _ => null,
      },
      LengthSet.kind => switch (map['bars']) {
        final int bars => LengthSet(bars),
        _ => null,
      },
      TimingSet.kind => switch (RecordTiming.values
          .asNameMap()[map['timing']]) {
        final RecordTiming timing => TimingSet(timing),
        null => null,
      },
      _ => null,
    };
  }

  /// The map that crosses the screen link.
  Map<String, Object?> toMap();
}

/// Moves the tempo by [delta] BPM from wherever it is now: a delta, so a
/// held button never works from the readout's own copy of the tempo.
final class TempoNudge extends ReadoutCommand {
  /// Creates a [TempoNudge].
  const new(this.delta);

  /// The wire name.
  static const kind = 'tempo.nudge';

  /// BPM to add; negative slows down.
  final double delta;

  @override
  Map<String, Object?> toMap() => {'kind': kind, 'delta': delta};

  @override
  List<Object?> get props => [delta];
}

/// Sets the tempo to exactly [bpm], from the readout's keypad.
final class TempoSet extends ReadoutCommand {
  /// Creates a [TempoSet].
  const new(this.bpm);

  /// The wire name.
  static const kind = 'tempo.set';

  /// The tempo.
  final double bpm;

  @override
  Map<String, Object?> toMap() => {'kind': kind, 'bpm': bpm};

  @override
  List<Object?> get props => [bpm];
}

/// One tap of tap tempo.
final class TempoTap extends ReadoutCommand {
  /// Creates a [TempoTap].
  const new();

  /// The wire name.
  static const kind = 'tempo.tap';

  @override
  Map<String, Object?> toMap() => {'kind': kind};

  @override
  List<Object?> get props => const [];
}

/// Clears the tempo, as the main screen's Clear tempo does (#1653). The
/// engine's tempo lock decides; a refusal comes back as a [ReadoutRefusal].
final class TempoClear extends ReadoutCommand {
  /// Creates a [TempoClear].
  const new();

  /// The wire name.
  static const kind = 'tempo.clear';

  @override
  Map<String, Object?> toMap() => {'kind': kind};

  @override
  List<Object?> get props => const [];
}

/// Sets the time signature to [num]/[den].
final class SignatureSet extends ReadoutCommand {
  /// Creates a [SignatureSet].
  const new(this.num, this.den);

  /// The wire name.
  static const kind = 'signature.set';

  /// Beats in a bar.
  final int num;

  /// The note value of a beat.
  final int den;

  @override
  Map<String, Object?> toMap() => {'kind': kind, 'num': num, 'den': den};

  @override
  List<Object?> get props => [num, den];
}

/// Sets the default length of the next take to [bars]; `0` is Auto.
final class LengthSet extends ReadoutCommand {
  /// Creates a [LengthSet].
  const new(this.bars);

  /// The wire name.
  static const kind = 'length.set';

  /// Bars, `0` for Auto.
  final int bars;

  @override
  Map<String, Object?> toMap() => {'kind': kind, 'bars': bars};

  @override
  List<Object?> get props => [bars];
}

/// Sets the default record timing to [timing].
final class TimingSet extends ReadoutCommand {
  /// Creates a [TimingSet].
  const new(this.timing);

  /// The wire name.
  static const kind = 'timing.set';

  /// When a record press acts.
  final RecordTiming timing;

  @override
  Map<String, Object?> toMap() => {'kind': kind, 'timing': timing.name};

  @override
  List<Object?> get props => [timing];
}

/// Why the main screen refused a readout's [TempoClear], sent back over the
/// screen link: the reasons the main screen's own notice gives (#1653).
enum ReadoutRefusal {
  /// A recording, a count-in or recorded material holds the tempo.
  tempoClearLocked,

  /// The audio interface is stopped.
  tempoClearStopped,

  /// Refused for another reason, such as an external clock owning the tempo.
  tempoClearOther;

  /// The refusal [name] names, or null when it names none.
  static ReadoutRefusal? fromName(Object? name) => values.asNameMap()[name];
}
