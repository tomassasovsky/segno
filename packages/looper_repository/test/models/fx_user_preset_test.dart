import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  final effect = BuiltInEffect(type: TrackEffectType.delay);

  test('one-module rack kind is independent of instance metadata', () {
    final preset = FxUserPreset(
      id: 'saved-rack',
      name: 'One pedal rack',
      entries: [effect],
      isRack: true,
    );

    expect(preset.entries.single.rack, isNull);
    expect(preset.isRack, isTrue);
    expect(preset.toJson()['isRack'], isTrue);
    expect(preset.copyWith(name: 'Renamed').isRack, isTrue);
    expect(preset.copyWith(isRack: false).isRack, isFalse);
    expect(preset.copyWith(isRack: false), isNot(preset));
  });

  test('stored kind distinguishes identical one-entry sounds', () {
    final chain = encodeTrackEffects([effect]);
    final saved = FxUserPreset.decodeAll(
      jsonEncode([
        {
          'id': 'rack',
          'name': 'Rack',
          'chain': chain,
          'isRack': true,
        },
        {
          'id': 'single',
          'name': 'Single',
          'chain': chain,
          'isRack': false,
        },
      ]),
    );

    expect(saved.map((preset) => preset.isRack), [true, false]);
    expect(saved.map((preset) => preset.entries.single.rack), [null, null]);
  });

  test('missing or invalid kind cannot silently change a saved sound', () {
    final data = {
      'id': 'sound',
      'name': 'Sound',
      'chain': encodeTrackEffects([effect]),
    };

    expect(FxUserPreset.fromJson(data), isNull);
    expect(FxUserPreset.fromJson({...data, 'isRack': 'true'}), isNull);
  });

  test('invalid channel data only discards the affected preset', () {
    final good = FxUserPreset(
      id: 'good',
      name: 'Good',
      entries: [effect],
      isRack: true,
    ).toJson();
    final bad = {
      ...good,
      'id': 'damaged',
      'chain': jsonEncode([
        {
          'type': TrackEffectType.delay.code,
          'channels': {'input': 'unknown'},
        },
      ]),
    };

    expect(FxUserPreset.fromJson(bad), isNull);
    final remaining = FxUserPreset.decodeAll(
      jsonEncode([
        good,
        bad,
        {...good, 'id': 'also-good'},
      ]),
    );
    expect(remaining.map((preset) => preset.id), ['good', 'also-good']);
  });
}
