import 'package:equatable/equatable.dart';

/// One output destination's facts (accepted design, Output setup): its level,
/// mute, Stereo/Mono and balance. A destination is a stereo pair of hardware
/// outputs, bus `k` being outputs `2k` and `2k + 1`.
class OutputBus extends Equatable {
  /// Creates an [OutputBus].
  const OutputBus({
    this.level = 1,
    this.muted = false,
    this.mono = false,
    this.balance = 0,
  });

  /// The level, `0..1`; retained behind a mute.
  final double level;

  /// Whether the destination is muted (the level and balance are retained).
  final bool muted;

  /// Whether the destination sends the averaged mix to both jacks (balance
  /// disabled); Stereo restores the retained balance.
  final bool mono;

  /// The balance, `-1` (left only) .. `1` (right only); retained while Mono.
  final double balance;

  /// Whether every fact is at its default (unity, unmuted, Stereo, centre).
  bool get isDefault => level == 1 && !muted && !mono && balance == 0;

  /// A copy with the given facts replaced.
  OutputBus copyWith({
    double? level,
    bool? muted,
    bool? mono,
    double? balance,
  }) => OutputBus(
    level: level ?? this.level,
    muted: muted ?? this.muted,
    mono: mono ?? this.mono,
    balance: balance ?? this.balance,
  );

  @override
  List<Object?> get props => [level, muted, mono, balance];
}

/// The output setup (accepted design, Output setup): every destination that
/// is off its defaults, keyed by bus. Session-owned like the input setup,
/// and carried into New Loop; only the destinations' names are appliance
/// aliases.
class OutputSetup extends Equatable {
  /// Creates an [OutputSetup].
  const OutputSetup({this.buses = const {}});

  /// The destinations off their defaults, keyed by bus.
  final Map<int, OutputBus> buses;

  /// Bus [bus]'s facts, the defaults when unset.
  OutputBus of(int bus) => buses[bus] ?? const OutputBus();

  /// A copy with [bus] set to [value]; a default value drops the entry.
  OutputSetup withBus(int bus, OutputBus value) {
    final next = Map<int, OutputBus>.of(buses);
    if (value.isDefault) {
      next.remove(bus);
    } else {
      next[bus] = value;
    }
    return OutputSetup(buses: next);
  }

  /// The bus hardware output [output] belongs to.
  static int busOfOutput(int output) => output ~/ 2;

  /// The output channel mask that routes to every bus in [buses].
  static int maskOfBuses(Iterable<int> buses) {
    var mask = 0;
    for (final bus in buses) {
      mask |= 0x3 << (2 * bus);
    }
    return mask;
  }

  /// The buses an output channel [mask] touches.
  static Set<int> busesOfMask(int mask) => {
    for (var output = 0; output < 32; output++)
      if (mask & (1 << output) != 0) output ~/ 2,
  };

  @override
  List<Object?> get props => [buses];
}
