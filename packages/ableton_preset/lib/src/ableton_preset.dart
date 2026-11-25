// cspell:words Wavetable

import 'package:meta/meta.dart';

/// What a preset file holds: one device, or a rack of devices.
enum PresetKind {
  /// An `.adv`: one device and its parameters.
  device,

  /// An `.adg`: a rack (Instrument, Audio Effect, MIDI Effect or Drum Rack)
  /// holding devices in chains. Listed, not read further for now.
  rack,
}

/// A parameter's value as the preset stores it.
///
/// [raw] is the `Value` attribute, unparsed: a number in the parameter's
/// own unit, an enum index, or `true`/`false`. [min] and [max] are the
/// parameter's `MidiControllerRange` when the preset stores one.
@immutable
final class StoredValue {
  /// A stored value and its range.
  const new(this.raw, {this.min, this.max});

  /// The `Value` attribute as written in the file.
  final String raw;

  /// The stored range's minimum, when the preset has one.
  final double? min;

  /// The stored range's maximum, when the preset has one.
  final double? max;

  @override
  bool operator ==(Object other) =>
      other is StoredValue &&
      other.raw == raw &&
      other.min == min &&
      other.max == max;

  @override
  int get hashCode => Object.hash(raw, min, max);

  @override
  String toString() => 'StoredValue($raw, $min..$max)';
}

/// One Live device preset, as read from its file.
final class AbletonPreset {
  /// A read preset.
  const new({
    required this.device,
    required this.kind,
    required this.name,
    required this.folderPath,
    required this.values,
    required this.unread,
  });

  /// The device's element name in the file: `Drift`, `Operator`,
  /// `InstrumentVector` (Wavetable) and so on. For a rack, the rack's own
  /// device (`InstrumentGroupDevice`, `AudioEffectGroupDevice` ...).
  final String device;

  /// Whether the file is one device or a rack.
  final PresetKind kind;

  /// The preset's name: its file name without the extension, as Live's
  /// browser shows it.
  final String name;

  /// The folders between the library's root and the file, outermost first
  /// (`['Instruments', 'Drift', 'Bass']`). Empty when read on its own.
  final List<String> folderPath;

  /// Every parameter of the device, by element name, in file order. Empty
  /// for a rack.
  final Map<String, StoredValue> values;

  /// Elements of the device the reader could not read as a parameter and
  /// does not know to be Live's own bookkeeping, by element name.
  final List<String> unread;
}
