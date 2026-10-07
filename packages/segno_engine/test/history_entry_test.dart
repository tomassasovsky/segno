import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('HistoryEntry', () {
    test('a playhead map is part of the entry', () {
      const edit = HistoryEntry(HistoryKind.length, start: 4);
      expect(edit, const HistoryEntry(HistoryKind.length, start: 4));
      expect(edit, isNot(const HistoryEntry(HistoryKind.length)));
      expect(
        edit.hashCode,
        const HistoryEntry(HistoryKind.length, start: 4).hashCode,
      );
      expect(edit.toString(), 'HistoryEntry(length, skipped: 0, start: 4)');
    });
  });

  group('TrackHistory.malformation', () {
    test('accepts length edits anywhere, with or without a map (#1168)', () {
      const history = TrackHistory([
        HistoryEntry(HistoryKind.length, start: -8),
        HistoryEntry(HistoryKind.layer),
        HistoryEntry(HistoryKind.length, start: 8),
      ], undoCount: 2);
      expect(history.malformation, isNull);
    });

    test('refuses a playhead map on a kind that has none', () {
      const history = TrackHistory([
        HistoryEntry(HistoryKind.layer, start: 4),
      ], undoCount: 1);
      expect(history.malformation, contains('playhead map on a layer'));
    });
  });

  group('TrackHistory.lengthMalformation (#1168)', () {
    // Undo side: an overdub beneath a length edit. Redo side: a length edit,
    // a Peel marker (no image), then an overdub above the edit.
    const history = TrackHistory([
      HistoryEntry(HistoryKind.layer),
      HistoryEntry(HistoryKind.length),
      HistoryEntry(HistoryKind.length, start: 8),
      HistoryEntry(HistoryKind.layer),
    ], undoCount: 2);

    test('accepts the lengths the lineage gives', () {
      // The undo overdub repeats the edit's 8; the live image is 16; the
      // redo edit names 4 and the overdub above it repeats it.
      expect(history.lengthMalformation([8, 8, 16, 4, 4]), isNull);
      expect(TrackHistory.none.lengthMalformation([16]), isNull);
    });

    test('refuses an image count other than the history names', () {
      expect(
        history.lengthMalformation([8, 8, 16, 4]),
        '4 image lengths but the history names 5',
      );
    });

    test('refuses an undo image at another length than its ruling edit', () {
      expect(
        history.lengthMalformation([16, 8, 16, 4, 4]),
        'image 0 is 16 frames, its lineage gives 8',
      );
    });

    test('refuses an undo image beneath no edit at another length than '
        'live', () {
      const layers = TrackHistory([
        HistoryEntry(HistoryKind.layer),
      ], undoCount: 1);
      expect(
        layers.lengthMalformation([8, 16]),
        'image 0 is 8 frames, its lineage gives 16',
      );
    });

    test('refuses a redo image at another length than its ruling edit', () {
      expect(
        history.lengthMalformation([8, 8, 16, 4, 16]),
        'image 4 is 16 frames, its lineage gives 4',
      );
    });

    test('a Peel marker takes no length', () {
      const peeled = TrackHistory([
        HistoryEntry(HistoryKind.layer),
        HistoryEntry(HistoryKind.peel),
        HistoryEntry(HistoryKind.layer),
      ], undoCount: 1);
      expect(peeled.lengthMalformation([16, 16, 16]), isNull);
      expect(
        peeled.lengthMalformation([16, 16, 8]),
        'image 2 is 8 frames, its lineage gives 16',
      );
    });

    test('refuses a live image or an edit without a length', () {
      expect(
        TrackHistory.none.lengthMalformation([0]),
        'the live image has no length',
      );
      expect(
        history.lengthMalformation([0, 0, 16, 4, 4]),
        'image 1 is 0 frames, its lineage gives 0',
      );
    });
  });

  group('HistoryKind', () {
    test('carries the engine le_hist_kind codes, not enum indexes', () {
      expect(HistoryKind.layer.code, 0);
      expect(HistoryKind.clear.code, 1);
      expect(HistoryKind.peel.code, 2);
      expect(HistoryKind.processed.code, 3);
      expect(HistoryKind.length.code, 4);
      expect(HistoryKind.bounce.code, 5);
      for (final kind in HistoryKind.values) {
        expect(HistoryKind.fromCode(kind.code), kind);
      }
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
