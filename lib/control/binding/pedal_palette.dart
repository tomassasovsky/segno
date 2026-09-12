import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// One of the eight built-in indicator hues the LED palette ships with.
///
/// The values are the ones driven onto the LED, not swatch paint: the screen
/// shows the same number the wire carries, so what a performer picks is what
/// the plate does.
enum PedalPaletteColor {
  /// The default on every footswitch.
  white(PedalColor.white),

  /// Amber.
  amber(PedalColor.amber),

  /// Red.
  red(PedalColor.red),

  /// Orange.
  orange(PedalColor.orange),

  /// Green.
  green(PedalColor.green),

  /// Cyan.
  cyan(PedalColor.cyan),

  /// Blue.
  blue(PedalColor.blue),

  /// Violet.
  violet(PedalColor.violet);

  const PedalPaletteColor(this.color);

  /// The hue itself.
  final PedalColor color;
}

/// Which palette colour a footswitch's indicator uses.
///
/// A REFERENCE, not a value: a custom entry names a number, and the colour
/// behind that number lives once in [PedalPalette.customs]. That is what makes
/// a custom colour reusable — editing it moves every pedal pointing at it,
/// which is the accepted behaviour and would be impossible if each pedal held
/// its own copy of the hue.
sealed class PedalPaletteEntry extends Equatable {
  /// Creates a [PedalPaletteEntry].
  const PedalPaletteEntry();

  /// Parses a persisted [key], or `null` when it names nothing.
  static PedalPaletteEntry? tryParse(String key) {
    if (key.startsWith(_customPrefix)) {
      final number = int.tryParse(key.substring(_customPrefix.length));
      if (number == null || number < 1) return null;
      return CustomPaletteEntry(number);
    }
    for (final color in PedalPaletteColor.values) {
      if (color.name == key) return BuiltInPaletteEntry(color);
    }
    return null;
  }

  static const String _customPrefix = 'custom:';

  /// The stable, locale-independent key this entry persists as.
  String get key;
}

/// One of the eight built-in hues.
final class BuiltInPaletteEntry extends PedalPaletteEntry {
  /// Creates a [BuiltInPaletteEntry].
  const BuiltInPaletteEntry(this.color);

  /// Which built-in.
  final PedalPaletteColor color;

  @override
  String get key => color.name;

  @override
  List<Object?> get props => [color];
}

/// A hue the performer mixed, addressed by the number its name carries —
/// Custom 1, Custom 2.
final class CustomPaletteEntry extends PedalPaletteEntry {
  /// Creates a [CustomPaletteEntry].
  const CustomPaletteEntry(this.number);

  /// Its 1-based number, stable for the life of the entry so that editing a
  /// colour never re-points the pedals using it.
  final int number;

  @override
  String get key => '${PedalPaletteEntry._customPrefix}$number';

  @override
  List<Object?> get props => [number];
}

/// The LED palette: the hues available, and which one each footswitch uses.
///
/// Two maps rather than ten colours, because the accepted design makes a
/// custom colour a reusable thing with a name: several pedals point at Custom
/// 1, and editing Custom 1 moves all of them at once.
///
/// A footswitch with no entry uses [defaultEntry]. Storing the default
/// explicitly is avoided on write ([withChoice] drops it), so "never touched"
/// and "set back to white" are the same palette and a draft that ended where
/// it started does not read as an edit.
class PedalPalette extends Equatable {
  /// Creates a [PedalPalette].
  const PedalPalette({
    this.customs = const <int, PedalColor>{},
    this.choices = const <PedalButton, PedalPaletteEntry>{},
  });

  /// Rebuilds a palette from its [toJson] map.
  ///
  /// Never throws: an entry this build cannot read is dropped, and a pedal
  /// pointing at nothing falls back to [defaultEntry]. The pedal has to light
  /// up at boot whatever a settings file holds.
  factory PedalPalette.fromJson(Map<String, dynamic> json) {
    final customs = <int, PedalColor>{};
    final raw = json['customs'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final number = entry['number'];
        final rgb = entry['rgb'];
        if (number is! int || number < 1) continue;
        if (rgb is! int || rgb < 0 || rgb > 0xFFFFFF) continue;
        customs[number] = PedalColor.fromRgb(rgb);
      }
    }
    final choices = <PedalButton, PedalPaletteEntry>{};
    final leds = json['leds'];
    if (leds is Map<String, dynamic>) {
      for (final button in PedalButton.values) {
        final key = leds[button.name];
        if (key is! String) continue;
        final entry = PedalPaletteEntry.tryParse(key);
        if (entry == null || entry == defaultEntry) continue;
        choices[button] = entry;
      }
    }
    return PedalPalette(
      customs: Map.unmodifiable(customs),
      choices: Map.unmodifiable(choices),
    );
  }

  /// What a footswitch uses until someone chooses otherwise.
  static const PedalPaletteEntry defaultEntry = BuiltInPaletteEntry(
    PedalPaletteColor.white,
  );

  /// The hues the performer mixed, by number.
  final Map<int, PedalColor> customs;

  /// Which entry each footswitch uses; absent means [defaultEntry].
  final Map<PedalButton, PedalPaletteEntry> choices;

  /// The swatch row, in the order the accepted design lists it: the eight
  /// built-ins, then the customs by number.
  List<PedalPaletteEntry> get entries => [
    for (final color in PedalPaletteColor.values) BuiltInPaletteEntry(color),
    for (final number in _orderedCustomNumbers) CustomPaletteEntry(number),
  ];

  /// The number a newly added custom colour takes: the lowest free one, so a
  /// palette never grows a gap it cannot name.
  int get nextCustomNumber {
    var number = 1;
    while (customs.containsKey(number)) {
      number++;
    }
    return number;
  }

  /// Which entry [button] uses.
  ///
  /// A choice naming a custom colour that is no longer in the palette reads as
  /// [defaultEntry] rather than as a colourless pedal.
  PedalPaletteEntry entryFor(PedalButton button) {
    final entry = choices[button];
    if (entry == null) return defaultEntry;
    return colorOf(entry) == null ? defaultEntry : entry;
  }

  /// The hue [button]'s indicator uses.
  PedalColor colorFor(PedalButton button) =>
      colorOf(entryFor(button)) ?? PedalColor.defaultColor;

  /// The hue behind [entry], or `null` when it names a custom colour this
  /// palette does not have.
  PedalColor? colorOf(PedalPaletteEntry entry) => switch (entry) {
    BuiltInPaletteEntry(:final color) => color.color,
    CustomPaletteEntry(:final number) => customs[number],
  };

  /// The ten colours a state frame carries, in [PedalButton] order.
  List<PedalColor> get frameColors => [
    for (final button in PedalButton.values) colorFor(button),
  ];

  /// Returns a copy with [button] using [entry].
  PedalPalette withChoice(PedalButton button, PedalPaletteEntry entry) {
    final next = {...choices};
    if (entry == defaultEntry) {
      next.remove(button);
    } else {
      next[button] = entry;
    }
    return copyWith(choices: Map.unmodifiable(next));
  }

  /// Returns a copy with custom [number] set to [color] — adding it, or
  /// editing it in place so that every pedal pointing at it moves too.
  PedalPalette withCustom(int number, PedalColor color) => copyWith(
    customs: Map.unmodifiable({...customs, number: color}),
  );

  /// Returns a copy with the given fields replaced.
  PedalPalette copyWith({
    Map<int, PedalColor>? customs,
    Map<PedalButton, PedalPaletteEntry>? choices,
  }) => PedalPalette(
    customs: customs ?? this.customs,
    choices: choices ?? this.choices,
  );

  /// The canonical encoding, ordered so that a palette that changed only in
  /// iteration order never looks like an edit.
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

  /// Whether anything has been chosen or mixed — what tells a saved palette
  /// from the shipped default.
  bool get isEmpty => customs.isEmpty && choices.isEmpty;

  List<int> get _orderedCustomNumbers => customs.keys.toList()..sort();

  @override
  List<Object?> get props => [
    // Ordered flattenings, not the maps: two palettes built in different
    // insertion orders must compare equal, which a Map does not promise
    // through Equatable.
    for (final number in _orderedCustomNumbers) ...[number, customs[number]],
    for (final button in PedalButton.values) choices[button],
  ];
}
