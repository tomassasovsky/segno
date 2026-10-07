import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('HistoryKind', () {
    test('carries the engine le_hist_kind codes, not enum indexes', () {
      expect(HistoryKind.layer.code, 0);
      expect(HistoryKind.clear.code, 1);
      expect(HistoryKind.peel.code, 2);
      expect(HistoryKind.processed.code, 3);
      expect(HistoryKind.bounce.code, 5);
      for (final kind in HistoryKind.values) {
        expect(HistoryKind.fromCode(kind.code), kind);
      }
      expect(HistoryKind.fromCode(4), isNull); // Multiply/Divide's
      expect(HistoryKind.fromCode(9), isNull);
    });
  });

  test('a saved history never holds a Bounce', () {
    const history = TrackHistory(
      [HistoryEntry(HistoryKind.layer), HistoryEntry(HistoryKind.bounce)],
      undoCount: 2,
    );
    expect(history.malformation, contains('Bounce'));
    const clean = TrackHistory(
      [HistoryEntry(HistoryKind.layer)],
      undoCount: 1,
    );
    expect(clean.malformation, isNull);
  });
}
