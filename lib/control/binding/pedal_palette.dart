import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_binding.dart';

/// The named hues offered by the pedal editor. These are design values; the
/// pedal's renderer applies its own gamma, spatial weighting, and current cap.
enum PedalPaletteColor {
  white(PedalColor.defaultColor),
  amber(PedalColor(0xEF, 0xBC, 0x72)),
  red(PedalColor(0xEE, 0x6B, 0x70)),
  orange(PedalColor(0xEF, 0x96, 0x66)),
  green(PedalColor(0x7A, 0xCB, 0x9E)),
  cyan(PedalColor(0x73, 0xCF, 0xDF)),
  blue(PedalColor(0x82, 0xAA, 0xFF)),
  violet(PedalColor(0xB1, 0x9A, 0xFA));

  const PedalPaletteColor(this.color);
  final PedalColor color;
}

/// A stable reference to one built-in or performer-defined hue.
sealed class PedalPaletteEntry extends Equatable {
  const PedalPaletteEntry();

  static PedalPaletteEntry? tryParse(String key) {
    if (key.startsWith(_customPrefix)) {
      final token = key.substring(_customPrefix.length);
      final number = int.tryParse(token);
      if (number == null || number < 1 || number.toString() != token) {
        return null;
      }
      return CustomPaletteEntry(number);
    }
    for (final color in PedalPaletteColor.values) {
      if (color.name == key) return BuiltInPaletteEntry(color);
    }
    return null;
  }

  static const String _customPrefix = 'custom:';
  String get key;
}

final class BuiltInPaletteEntry extends PedalPaletteEntry {
  const BuiltInPaletteEntry(this.color);
  final PedalPaletteColor color;

  @override
  String get key => color.name;

  @override
  List<Object?> get props => [color];
}

final class CustomPaletteEntry extends PedalPaletteEntry {
  const CustomPaletteEntry(this.number)
    : assert(number > 0, 'Custom palette IDs must be positive');
  final int number;

  @override
  String get key => '${PedalPaletteEntry._customPrefix}$number';

  @override
  List<Object?> get props => [number];
}

/// Named hues and per-physical-switch references. Empty choices use white.
/// Every populated instance owns detached, unmodifiable maps.
class PedalPalette extends Equatable {
  const PedalPalette()
    : customs = const <int, PedalColor>{},
      choices = const <PedalButton, PedalPaletteEntry>{};

  PedalPalette._(
    Map<int, PedalColor> customs,
    Map<PedalButton, PedalPaletteEntry> choices,
  ) : customs = Map.unmodifiable(customs),
      choices = Map.unmodifiable(choices);

  factory PedalPalette.fromMaps({
    Map<int, PedalColor> customs = const {},
    Map<PedalButton, PedalPaletteEntry> choices = const {},
  }) {
    if (customs.entries.any(
      (item) =>
          item.key < 1 ||
          item.value.r < 0 ||
          item.value.r > 255 ||
          item.value.g < 0 ||
          item.value.g > 255 ||
          item.value.b < 0 ||
          item.value.b > 255,
    )) {
      throw const FormatException('Invalid custom palette color');
    }
    for (final entry in choices.values) {
      if (entry is CustomPaletteEntry && !customs.containsKey(entry.number)) {
        throw const FormatException('Dangling custom palette reference');
      }
    }
    // Colour is the performer's only on the switches Custom mode can assign
    // (#1274): a stored MODE or BANK choice is dropped, not kept unreachable.
    final normalized = Map<PedalButton, PedalPaletteEntry>.of(choices)
      ..removeWhere(
        (button, entry) =>
            entry == defaultEntry ||
            PedalBindingKey.unbindable.contains(button),
      );
    return PedalPalette._(customs, normalized);
  }

  /// Rejects every malformed explicit palette; absence is handled by Setup.
  factory PedalPalette.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((key) => key != 'customs' && key != 'leds')) {
      throw const FormatException('Unknown pedal palette field');
    }
    final customs = <int, PedalColor>{};
    if (json.containsKey('customs')) {
      final raw = json['customs'];
      if (raw is! List) {
        throw const FormatException('Invalid custom palette list');
      }
      for (final item in raw) {
        if (item is! Map<String, dynamic> ||
            item.keys.any((key) => key != 'number' && key != 'rgb')) {
          throw const FormatException('Invalid custom palette entry');
        }
        final number = item['number'];
        final rgb = item['rgb'];
        if (number is! int ||
            number < 1 ||
            customs.containsKey(number) ||
            rgb is! int ||
            rgb < 0 ||
            rgb > 0xFFFFFF) {
          throw const FormatException('Invalid custom palette ID or RGB');
        }
        customs[number] = PedalColor.fromRgb(rgb);
      }
    }
    final choices = <PedalButton, PedalPaletteEntry>{};
    if (json.containsKey('leds')) {
      final raw = json['leds'];
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid pedal LED choices');
      }
      for (final item in raw.entries) {
        PedalButton? button;
        for (final value in PedalButton.values) {
          if (value.name == item.key) button = value;
        }
        final token = item.value;
        final entry = token is String
            ? PedalPaletteEntry.tryParse(token)
            : null;
        if (button == null || entry == null) {
          throw const FormatException('Invalid pedal LED choice');
        }
        choices[button] = entry;
      }
    }
    return PedalPalette.fromMaps(customs: customs, choices: choices);
  }

  static const PedalPaletteEntry defaultEntry = BuiltInPaletteEntry(
    PedalPaletteColor.white,
  );

  final Map<int, PedalColor> customs;
  final Map<PedalButton, PedalPaletteEntry> choices;

  List<PedalPaletteEntry> get entries => [
    for (final color in PedalPaletteColor.values) BuiltInPaletteEntry(color),
    for (final number in _orderedCustomNumbers) CustomPaletteEntry(number),
  ];

  int get nextCustomNumber {
    var number = 1;
    while (customs.containsKey(number)) {
      number++;
    }
    return number;
  }

  PedalPaletteEntry entryFor(PedalButton button) =>
      choices[button] ?? defaultEntry;

  PedalColor colorFor(PedalButton button) => colorOf(entryFor(button))!;

  /// Unknown custom IDs have no color; stored choices can never name them.
  PedalColor? colorOf(PedalPaletteEntry entry) => switch (entry) {
    BuiltInPaletteEntry(:final color) => color.color,
    CustomPaletteEntry(:final number) => customs[number],
  };

  List<PedalColor> get frameColors => [
    for (final button in PedalButton.values) colorFor(button),
  ];

  PedalPalette withChoice(PedalButton button, PedalPaletteEntry entry) {
    final next = {...choices};
    if (entry == defaultEntry) {
      next.remove(button);
    } else {
      next[button] = entry;
    }
    return copyWith(choices: next);
  }

  PedalPalette withCustom(int number, PedalColor color) => copyWith(
    customs: {...customs, number: color},
  );

  PedalPalette copyWith({
    Map<int, PedalColor>? customs,
    Map<PedalButton, PedalPaletteEntry>? choices,
  }) => PedalPalette.fromMaps(
    customs: customs ?? this.customs,
    choices: choices ?? this.choices,
  );

  Map<String, dynamic> toJson() => {
    if (customs.isNotEmpty)
      'customs': [
        for (final number in _orderedCustomNumbers)
          {'number': number, 'rgb': customs[number]!.rgb},
      ],
    if (choices.isNotEmpty)
      'leds': {
        for (final button in PedalButton.values)
          if (choices.containsKey(button)) button.name: choices[button]!.key,
      },
  };

  bool get isEmpty => customs.isEmpty && choices.isEmpty;

  List<int> get _orderedCustomNumbers => customs.keys.toList()..sort();

  @override
  List<Object?> get props => [
    for (final number in _orderedCustomNumbers) ...[number, customs[number]],
    for (final button in PedalButton.values) choices[button],
  ];
}
