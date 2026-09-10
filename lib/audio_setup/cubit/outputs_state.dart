part of 'outputs_cubit.dart';

/// State for [OutputsCubit]: what each destination of the open device is
/// called.
class OutputsState extends Equatable {
  /// Creates an [OutputsState].
  const OutputsState({this.device = '', this.names = const {}});

  /// How many destinations a device change probes for stored names.
  ///
  /// A read bound, **not** a naming ceiling, for the same reason
  /// [InputsState.probeCeiling] is one: the store cannot be asked "every key
  /// under this device". The engine's own bus ceiling is the widest rig the
  /// output mask can address, so nothing past it is reachable to name.
  static const int probeCeiling = kMaxOutputBuses;

  /// The device these names belong to. Empty before the engine has opened
  /// anything.
  final String device;

  /// The given name per destination, keyed by bus. A destination with no name
  /// is **absent** rather than empty.
  final Map<int, String> names;

  /// Whether destination [bus] has been given a name.
  bool isNamed(int bus) => (names[bus] ?? '').isNotEmpty;

  /// The given name for [bus], or empty when it has none.
  String nameOf(int bus) => names[bus] ?? '';

  /// How many of the first [count] destinations carry a given name.
  int namedCount(int count) => [
    for (var bus = 0; bus < count; bus++)
      if (isNamed(bus)) bus,
  ].length;

  /// Returns a copy with the given overrides.
  OutputsState copyWith({String? device, Map<int, String>? names}) =>
      OutputsState(device: device ?? this.device, names: names ?? this.names);

  @override
  List<Object?> get props => [device, names];
}
