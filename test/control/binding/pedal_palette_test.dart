import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_palette.dart';

void main() {
  test('all ten physical controls start at the current white default', () {
    const palette = PedalPalette();
    expect(palette.frameColors, hasLength(10));
    expect(palette.frameColors, everyElement(PedalColor.defaultColor));
    expect(palette.isEmpty, isTrue);
    expect(PedalPaletteColor.white.color.rgb, 0xFFFFFF);
    expect(PedalPaletteEntry.tryParse('custom:01'), isNull);
  });

  test('a custom ID is shared and keeps its identity after editing', () {
    final first = const PedalPalette()
        .withCustom(1, const PedalColor(0, 0, 0))
        .withChoice(PedalButton.track1, const CustomPaletteEntry(1))
        .withChoice(PedalButton.bank, const CustomPaletteEntry(1));
    expect(first.colorFor(PedalButton.track1).rgb, 0);
    final edited = first.withCustom(1, const PedalColor(17, 34, 51));
    expect(edited.entryFor(PedalButton.track1), const CustomPaletteEntry(1));
    expect(edited.entryFor(PedalButton.bank), const CustomPaletteEntry(1));
    expect(edited.colorFor(PedalButton.track1).rgb, 0x112233);
    expect(edited.colorFor(PedalButton.bank).rgb, 0x112233);
    expect(first.colorFor(PedalButton.bank).rgb, 0);
  });

  test(
    'maps are detached, immutable, and canonical in any insertion order',
    () {
      final customs = <int, PedalColor>{
        2: const PedalColor(1, 2, 3),
        1: const PedalColor(4, 5, 6),
      };
      final choices = <PedalButton, PedalPaletteEntry>{
        PedalButton.stop: const CustomPaletteEntry(2),
        PedalButton.track1: const CustomPaletteEntry(1),
      };
      final palette = PedalPalette.fromMaps(customs: customs, choices: choices);
      final encoding = palette.toJson().toString();
      customs.clear();
      choices.clear();
      expect(palette.customs, hasLength(2));
      expect(palette.choices, hasLength(2));
      expect(palette.customs.clear, throwsUnsupportedError);
      expect(palette.choices.clear, throwsUnsupportedError);
      final reversed = PedalPalette.fromMaps(
        customs: const {1: PedalColor(4, 5, 6), 2: PedalColor(1, 2, 3)},
        choices: const {
          PedalButton.track1: CustomPaletteEntry(1),
          PedalButton.stop: CustomPaletteEntry(2),
        },
      );
      expect(palette, reversed);
      expect(palette.toJson().toString(), encoding);
      expect(reversed.toJson().toString(), encoding);
    },
  );

  test('constructors reject dangling references and nonpositive IDs', () {
    expect(
      () => const PedalPalette().withChoice(
        PedalButton.mode,
        const CustomPaletteEntry(1),
      ),
      throwsFormatException,
    );
    expect(
      () => const PedalPalette().withCustom(0, PedalColor.defaultColor),
      throwsFormatException,
    );
    final withReference = const PedalPalette()
        .withCustom(1, PedalColor.defaultColor)
        .withChoice(PedalButton.mode, const CustomPaletteEntry(1));
    expect(() => withReference.copyWith(customs: {}), throwsFormatException);
  });

  test('strict decoder rejects every malformed explicit palette', () {
    final bad = <Map<String, dynamic>>[
      {'customs': 'nope'},
      {'leds': <Object>[]},
      {'unknown': 2},
      {
        'customs': [
          {'number': 0, 'rgb': 0},
        ],
      },
      {
        'customs': [
          {'number': 1, 'rgb': -1},
        ],
      },
      {
        'customs': [
          {'number': 1, 'rgb': 0x1000000},
        ],
      },
      {
        'customs': [
          {'number': 1, 'rgb': '0'},
        ],
      },
      {
        'customs': [
          {'number': 1, 'rgb': 0},
          {'number': 1, 'rgb': 1},
        ],
      },
      {
        'customs': [
          {'number': 1, 'rgb': 0, 'extra': 1},
        ],
      },
      {
        'leds': {'bogus': 'white'},
      },
      {
        'leds': {'mode': 'bogus'},
      },
      {
        'leds': {'mode': 3},
      },
      {
        'leds': {'mode': 'custom:1'},
      },
    ];
    for (final json in bad) {
      expect(
        () => PedalPalette.fromJson(json),
        throwsFormatException,
        reason: json.toString(),
      );
    }
  });

  test('black and all physical switches survive JSON round-trip', () {
    var palette = const PedalPalette().withCustom(1, const PedalColor(0, 0, 0));
    for (final button in PedalButton.values) {
      palette = palette.withChoice(button, const CustomPaletteEntry(1));
    }
    final decoded = PedalPalette.fromJson(palette.toJson());
    expect(decoded, palette);
    expect(decoded.frameColors, everyElement(const PedalColor(0, 0, 0)));
  });
}
