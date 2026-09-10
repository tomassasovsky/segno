import 'package:equatable/equatable.dart';

/// The output destination whose chain the app calls the Master insert
/// (`FxStage.master`): the first pair. Slice 3f rebuilds the FX surfaces
/// around one chain per destination, and this pin goes with it.
const int kMasterOutputBus = 0;

/// The hardware-output mask destination [bus] drives on a device with
/// [channels] outputs.
///
/// A destination is a stereo pair — outputs `2*bus` and `2*bus + 1` — so a
/// routing surface that offers destinations has to turn one into the pair of
/// bits the engine's masks are made of. An odd-channel device leaves the last
/// destination holding a single jack, and its mask carries the one bit the
/// interface actually has rather than promising a socket it has not got.
int outputBusMask(int bus, {required int channels}) {
  if (bus < 0) return 0;
  var mask = 0;
  for (var channel = 2 * bus; channel < 2 * bus + 2; channel++) {
    if (channel < channels) mask |= 1 << channel;
  }
  return mask;
}

/// Whether [mask] drives any jack of destination [bus].
///
/// EITHER jack counts: a mask that reaches half a pair still reaches the
/// destination, and a card that read it as unselected would offer to switch on
/// something that is already partly on.
bool outputMaskDrivesBus(int mask, int bus) =>
    bus >= 0 && mask & (0x3 << (2 * bus)) != 0;

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

  /// An [OutputSetup] from one map per fact, each holding only the
  /// destinations off that fact's default — the shape settings and the
  /// session manifest persist. A destination any map names is rebuilt whole,
  /// the rest of its facts at their defaults.
  factory OutputSetup.fromMaps({
    Map<int, double> level = const {},
    Map<int, bool> muted = const {},
    Map<int, bool> mono = const {},
    Map<int, double> balance = const {},
  }) {
    var result = const OutputSetup();
    for (final bus in <int>{
      ...level.keys,
      ...muted.keys,
      ...mono.keys,
      ...balance.keys,
    }) {
      result = result.withBus(
        bus,
        OutputBus(
          level: level[bus] ?? 1,
          muted: muted[bus] ?? false,
          mono: mono[bus] ?? false,
          balance: balance[bus] ?? 0,
        ),
      );
    }
    return result;
  }

  /// The destinations off their defaults, keyed by bus.
  final Map<int, OutputBus> buses;

  /// Bus [bus]'s facts, the defaults when unset.
  OutputBus of(int bus) => buses[bus] ?? const OutputBus();

  /// This setup as one map per fact, the inverse of [OutputSetup.fromMaps]:
  /// each map holds only the destinations off that fact's default, so an
  /// untouched rig yields four empty maps.
  ({
    Map<int, double> level,
    Map<int, bool> muted,
    Map<int, bool> mono,
    Map<int, double> balance,
  })
  toMaps() => (
    level: {
      for (final e in buses.entries)
        if (e.value.level != 1) e.key: e.value.level,
    },
    muted: {
      for (final e in buses.entries)
        if (e.value.muted) e.key: true,
    },
    mono: {
      for (final e in buses.entries)
        if (e.value.mono) e.key: true,
    },
    balance: {
      for (final e in buses.entries)
        if (e.value.balance != 0) e.key: e.value.balance,
    },
  );

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

  @override
  List<Object?> get props => [buses];
}
