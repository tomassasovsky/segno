import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  group('SessionSummary', () {
    test('value equality and hashCode are by id, not name', () {
      const a = SessionSummary(id: 's-1', name: 'My Song');
      const renamed = SessionSummary(id: 's-1', name: 'Other');
      const other = SessionSummary(id: 's-2', name: 'My Song');
      expect(a, renamed);
      expect(a.hashCode, renamed.hashCode);
      expect(a, isNot(other));
    });

    test('toString names the id and the session', () {
      final text = const SessionSummary(
        id: 's-20261006-120000',
        name: 'My Song',
      ).toString();
      expect(text, contains('s-20261006-120000'));
      expect(text, contains('My Song'));
    });
  });

  group('sessionIdFor', () {
    test('folds a timestamp to s-YYYYMMDD-HHMMSS', () {
      expect(sessionIdFor(DateTime(2026, 10, 6, 9, 5, 3)), 's-20261006-090503');
    });

    test('isValidSessionId refuses path components', () {
      expect(isValidSessionId('s-20261006-090503'), isTrue);
      expect(isValidSessionId('Evening loop'), isTrue);
      expect(isValidSessionId(''), isFalse);
      expect(isValidSessionId('.'), isFalse);
      expect(isValidSessionId('..'), isFalse);
      expect(isValidSessionId('a/b'), isFalse);
      expect(isValidSessionId(r'a\b'), isFalse);
    });
  });
}
