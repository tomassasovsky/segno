import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/loop_settings/tempo_entry_sheet.dart';

void main() {
  group('typeTempoKey', () {
    test('takes up to three whole digits and two decimals', () {
      var text = '';
      for (final key in '128.47'.split('')) {
        text = typeTempoKey(text, key)!;
      }
      expect(text, '128.47');
      expect(typeTempoKey(text, '5'), isNull);
      expect(typeTempoKey('300', '0'), isNull);
    });

    test('takes one point', () {
      expect(typeTempoKey('', '.'), '.');
      expect(typeTempoKey('12.', '.'), isNull);
    });
  });

  group('parseTempoEntry', () {
    test('accepts 30.00 to 300.00', () {
      expect(parseTempoEntry('30'), 30);
      expect(parseTempoEntry('300.00'), 300);
      expect(parseTempoEntry('97.5'), 97.5);
      expect(parseTempoEntry('.5'), isNull);
    });

    test('refuses a tempo outside the range or no number', () {
      expect(parseTempoEntry('29.99'), isNull);
      expect(parseTempoEntry('300.01'), isNull);
      expect(parseTempoEntry('.'), isNull);
    });
  });
}
