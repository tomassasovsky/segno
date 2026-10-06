import 'package:meta/meta.dart';

/// What one entry of a track's audio history represents (#1164). The wire
/// values are the engine's `le_hist_kind`.
enum HistoryKind {
  /// A retired overdub pass: the image from before the pass.
  layer,

  /// A Clear restore point. Captured only on the Redo side, where Redo
  /// re-clears the track.
  clear,

  /// A Peel. On the Undo side it holds the image the Peel removed; on the
  /// Redo side it is a marker without an image that re-peels.
  peel,

  /// A loop-close restoration: the raw take beneath a conditioned image.
  /// Undo and Redo swap it like a layer; Peel never consumes it.
  processed,

  /// A length edit (#1168): the image to put back at its own length. A
  /// Session cannot carry one yet; its finalize refuses it.
  length,
}

/// One entry of a track's audio history in image-ordinal order: the Undo
/// stack oldest first, then the Redo stack newest-adjacent first. The first
/// `undoCount` entries are the Undo side.
@immutable
class HistoryEntry {
  /// Creates a [HistoryEntry].
  const HistoryEntry(this.kind, {this.skipped = 0});

  /// What the entry represents.
  final HistoryKind kind;

  /// For a [HistoryKind.peel] entry, how many Peel entries sat above the
  /// layer it consumed; zero for every other kind.
  final int skipped;

  /// How many images a history holds: one per Undo entry, the live image, and
  /// one per Redo entry except Peel markers.
  static int imageCount(List<HistoryEntry> history, {required int undoCount}) {
    var images = undoCount + 1;
    for (var i = undoCount; i < history.length; i++) {
      if (history[i].kind != HistoryKind.peel) images++;
    }
    return images;
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryEntry && other.kind == kind && other.skipped == skipped;

  @override
  int get hashCode => Object.hash(kind, skipped);

  @override
  String toString() => 'HistoryEntry(${kind.name}, skipped: $skipped)';
}
