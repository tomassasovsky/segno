import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_palette.dart';

/// The LED palette: eight built-in hues, the ones a performer mixes, and which
/// of them each of the ten footswitches uses.
void main() {
  group('PedalPaletteEntry', () {
    test('parses every key it can produce', () {
      for (final color in PedalPaletteColor.values) {
        final entry = BuiltInPaletteEntry(color);
        expect(PedalPaletteEntry.tryParse(entry.key), entry);
      }
      expect(
        PedalPaletteEntry.tryParse('custom:7'),
        const CustomPaletteEntry(7),
      );
    });

    test('refuses a key that names nothing', () {
      expect(PedalPaletteEntry.tryParse(''), isNull);
      expect(PedalPaletteEntry.tryParse('puce'), isNull);
      expect(PedalPaletteEntry.tryParse('custom:'), isNull);
      expect(PedalPaletteEntry.tryParse('custom:nope'), isNull);
      // Custom numbers are 1-based names, and a zeroth colour has none.
      expect(PedalPaletteEntry.tryParse('custom:0'), isNull);
      expect(PedalPaletteEntry.tryParse('custom:-3'), isNull);
    });
  });

  group('PedalPalette', () {
    test('every footswitch starts white', () {
      const palette = PedalPalette();
      for (final button in PedalButton.values) {
        expect(palette.entryFor(button), PedalPalette.defaultEntry);
        expect(palette.colorFor(button), PedalColor.white);
      }
      expect(palette.frameColors, hasLength(PedalButton.values.length));
      expect(palette.frameColors, everyElement(PedalColor.white));
      expect(palette.isEmpty, isTrue);
    });

    test('the swatch row is the built-ins, then the customs by number', () {
      const palette = PedalPalette(
        customs: {3: PedalColor.red, 1: PedalColor.blue},
      );
      expect(palette.entries, [
        for (final color in PedalPaletteColor.values)
          BuiltInPaletteEntry(color),
        const CustomPaletteEntry(1),
        const CustomPaletteEntry(3),
      ]);
    });

    test('a new custom takes the lowest free number', () {
      expect(const PedalPalette().nextCustomNumber, 1);
      expect(
        const PedalPalette(customs: {1: PedalColor.red}).nextCustomNumber,
        2,
      );
      // A palette that lost its second colour fills that gap rather than
      // growing a number it cannot explain.
      expect(
        const PedalPalette(
          customs: {1: PedalColor.red, 3: PedalColor.blue},
        ).nextCustomNumber,
        2,
      );
    });

    test('choosing a colour puts it on that switch and nothing else', () {
      const palette = PedalPalette();
      final next = palette.withChoice(
        PedalButton.track2,
        const BuiltInPaletteEntry(PedalPaletteColor.blue),
      );
      expect(next.colorFor(PedalButton.track2), PedalColor.blue);
      expect(next.colorFor(PedalButton.track1), PedalColor.white);
    });

    test('choosing white back again is not an edit', () {
      // Absent and explicitly-default must be the same palette, or a draft
      // that ended where it started would leave Save enabled with nothing to
      // save.
      const palette = PedalPalette();
      final away = palette.withChoice(
        PedalButton.mode,
        const BuiltInPaletteEntry(PedalPaletteColor.cyan),
      );
      expect(away, isNot(palette));
      expect(
        away.withChoice(PedalButton.mode, PedalPalette.defaultEntry),
        palette,
      );
    });

    test('editing a custom colour moves every switch using it', () {
      var palette = const PedalPalette().withCustom(1, PedalColor.red);
      palette = palette
          .withChoice(PedalButton.track1, const CustomPaletteEntry(1))
          .withChoice(PedalButton.clear, const CustomPaletteEntry(1));
      expect(palette.colorFor(PedalButton.track1), PedalColor.red);
      expect(palette.colorFor(PedalButton.clear), PedalColor.red);

      final edited = palette.withCustom(1, PedalColor.violet);
      expect(edited.colorFor(PedalButton.track1), PedalColor.violet);
      expect(edited.colorFor(PedalButton.clear), PedalColor.violet);
      // The assignments are untouched: the colour moved, not the choice.
      expect(edited.choices, palette.choices);
    });

    test('a switch pointing at a colour the palette lost reads as white', () {
      final palette = const PedalPalette()
          .withChoice(PedalButton.bank, const CustomPaletteEntry(4))
          .copyWith(customs: const {});
      expect(palette.entryFor(PedalButton.bank), PedalPalette.defaultEntry);
      expect(palette.colorFor(PedalButton.bank), PedalColor.white);
    });

    test('frameColors is in footswitch order', () {
      final palette = const PedalPalette()
          .withChoice(
            PedalButton.recPlay,
            const BuiltInPaletteEntry(PedalPaletteColor.red),
          )
          .withChoice(
            PedalButton.bank,
            const BuiltInPaletteEntry(PedalPaletteColor.green),
          );
      expect(palette.frameColors.first, PedalColor.red);
      expect(palette.frameColors.last, PedalColor.green);
    });

    test('round-trips through JSON', () {
      final palette = const PedalPalette()
          .withCustom(1, const PedalColor(0xED, 0x63, 0x9B))
          .withCustom(2, const PedalColor(0xD9, 0x9B, 0xFF))
          .withChoice(PedalButton.track1, const CustomPaletteEntry(1))
          .withChoice(
            PedalButton.mode,
            const BuiltInPaletteEntry(PedalPaletteColor.amber),
          );
      expect(PedalPalette.fromJson(palette.toJson()), palette);
    });

    test('encodes the same bytes whatever order it was built in', () {
      final one = const PedalPalette()
          .withCustom(1, PedalColor.red)
          .withCustom(2, PedalColor.blue)
          .withChoice(PedalButton.track1, const CustomPaletteEntry(2))
          .withChoice(PedalButton.stop, const CustomPaletteEntry(1));
      final other = const PedalPalette()
          .withChoice(PedalButton.stop, const CustomPaletteEntry(1))
          .withCustom(2, PedalColor.blue)
          .withChoice(PedalButton.track1, const CustomPaletteEntry(2))
          .withCustom(1, PedalColor.red);
      expect(other, one);
      expect(other.toJson().toString(), one.toJson().toString());
    });

    test('an empty palette encodes to nothing at all', () {
      expect(const PedalPalette().toJson(), isEmpty);
    });

    test('a blob this build cannot read degrades instead of throwing', () {
      expect(PedalPalette.fromJson(const {}), const PedalPalette());
      expect(
        PedalPalette.fromJson(const {'customs': 'nope', 'leds': 7}),
        const PedalPalette(),
      );
      final salvaged = PedalPalette.fromJson(const {
        'customs': [
          {'number': 1, 'rgb': 0x112233},
          {'number': 0, 'rgb': 0},
          {'number': 2, 'rgb': 0x1000000},
          'junk',
        ],
        'leds': {'track1': 'custom:1', 'mode': 'puce', 'bank': 12},
      });
      expect(salvaged.customs, {1: const PedalColor(0x11, 0x22, 0x33)});
      expect(salvaged.choices, {
        PedalButton.track1: const CustomPaletteEntry(1),
      });
    });
  });
}
