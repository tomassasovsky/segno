import 'package:daw_export/daw_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/application/performance_names.dart';
import 'package:segno/l10n/localized.dart' show storedDefaultTrackName;
import 'package:segno_engine/segno_engine.dart' show TrackEffectType;

void main() {
  group('performanceNames', () {
    test('keeps the names the player gave and leaves out the defaults and '
        'the empty ones', () {
      final names = performanceNames(
        tracks: [
          storedDefaultTrackName(0),
          'Rhythm',
          storedDefaultTrackName(2),
        ],
        inputs: const {0: 'Guitar', 3: ''},
      );
      expect(names.tracks, {1: 'Rhythm'});
      expect(names.inputs, {0: 'Guitar'});
    });
  });

  test("daw_export's effect names are the console's", () {
    // daw_export cannot import the engine, so it keeps its own copy.
    expect(effectTypeNames, {
      for (final type in TrackEffectType.values)
        if (type != TrackEffectType.none) type.code: type.label,
    });
  });
}
