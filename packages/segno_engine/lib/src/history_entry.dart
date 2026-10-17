import 'package:meta/meta.dart';

/// What one entry of a track's audio history represents (#1164). The wire
/// values are the engine's `le_hist_kind`.
enum HistoryKind {
  /// A retired overdub pass: the image from before the pass.
  layer(0),

  /// A Clear restore point. Captured only as the deepest Redo entry, where
  /// Redo re-clears the track.
  clear(1),

  /// A Peel. On the Undo side it holds the image the Peel removed; on the
  /// Redo side it is a marker without an image that re-peels.
  peel(2),

  /// A loop-close restoration: the raw take beneath a conditioned image.
  /// Undo and Redo swap it like a layer; Peel never consumes it.
  processed(3),

  /// A length edit (#1168): the image to put back at its own length, with
  /// the playhead map ([HistoryEntry.start]) applied when it swaps in.
  length(4),

  /// A Bounce (#1202): the whole track on the other side of a bounce. It is
  /// never saved — export cuts the history at it — so a Session that carries
  /// one is malformed.
  bounce(5);

  const HistoryKind(this.code);

  /// The engine's `le_hist_kind` value. Matches the enum index today; kept
  /// explicit so the engine's numbering, not declaration order, is the wire.
  final int code;

  /// The kind for an engine `le_hist_kind`, or `null` when unknown.
  static HistoryKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// One entry of a track's audio history (#1164).
@immutable
class HistoryEntry {
  /// Creates a [HistoryEntry].
  const HistoryEntry(this.kind, {this.skipped = 0, this.start = 0});

  /// What the entry represents.
  final HistoryKind kind;

  /// For a [HistoryKind.peel] entry, how many Peel entries sat above the
  /// layer it consumed; zero for every other kind.
  final int skipped;

  /// For a [HistoryKind.length] entry, the playhead map of the swap it makes:
  /// when the image swaps in, the playhead moves from frame `i` of the
  /// outgoing image to frame `(i - start)` modulo the incoming image's
  /// length, so it keeps its place in the bar. Zero for every other kind.
  final int start;

  @override
  bool operator ==(Object other) =>
      other is HistoryEntry &&
      other.kind == kind &&
      other.skipped == skipped &&
      other.start == start;

  @override
  int get hashCode => Object.hash(kind, skipped, start);

  @override
  String toString() =>
      'HistoryEntry(${kind.name}, skipped: $skipped, start: $start)';
}

/// A track's audio history (#1164): its [entries] in image-ordinal order (the
/// Undo stack oldest first, then the Redo stack newest-adjacent first) and
/// where they split. The split travels with the entries because it is the
/// engine's raw stack count, not the snapshot's published undo depth, which
/// reads 0 while a Clear restore is in flight.
@immutable
class TrackHistory {
  /// Creates a [TrackHistory] whose first [undoCount] [entries] are the Undo
  /// side.
  const TrackHistory(this.entries, {required this.undoCount});

  /// A track with no history: its live image only.
  static const TrackHistory none = TrackHistory([], undoCount: 0);

  /// The engine's image cap per lane (`LE_POOL_SLOTS`): the live image plus
  /// every image-bearing entry.
  static const int maxImages = 256;

  /// The entries, Undo side oldest first, then Redo side newest-adjacent
  /// first.
  final List<HistoryEntry> entries;

  /// Number of leading [entries] on the Undo side. Image ordinal [undoCount]
  /// is the live image.
  final int undoCount;

  /// Number of trailing [entries] on the Redo side.
  int get redoCount => entries.length - undoCount;

  /// How many images the history names: one per Undo entry, the live image,
  /// and one per Redo entry except Peel markers.
  int get imageCount {
    var images = undoCount + 1;
    for (var i = undoCount; i < entries.length; i++) {
      if (entries[i].kind != HistoryKind.peel) images++;
    }
    return images;
  }

  /// Why the engine could not hold this history, or null when it can. Mirrors
  /// `le_engine_finalize_history`, so a Session is refused at decode, before
  /// anything is cleared:
  ///
  /// - the split lies outside the entries, or the images exceed [maxImages];
  /// - a skipped count is negative, at least [maxImages], or set on a kind
  ///   other than Peel;
  /// - a Clear point is anywhere but the deepest Redo entry (Clear drops the
  ///   Redo branch, and on the Undo side it would leave the track empty);
  /// - an Undo-side Peel skipped more Peel entries than sit directly beneath
  ///   it, unless that run reaches the bottom (pool eviction removes the
  ///   oldest entries, and Undo clamps its re-insertion there);
  /// - a Redo-side Peel marker would find no layer to peel when Redo reaches
  ///   it;
  /// - a playhead map is set on a kind other than a length edit (#1168);
  /// - a Bounce entry, which a saved history never holds.
  ///
  /// The images' lengths are checked separately ([lengthMalformation]).
  String? get malformation {
    if (undoCount < 0 || undoCount > entries.length) {
      return 'undo count $undoCount outside ${entries.length} entries';
    }
    for (final (i, entry) in entries.indexed) {
      if (entry.kind == HistoryKind.bounce) {
        return 'entry $i is a Bounce, which a Session never carries';
      }
      if (entry.skipped < 0 || entry.skipped >= maxImages) {
        return 'entry $i has an invalid skipped count ${entry.skipped}';
      }
      if (entry.kind != HistoryKind.peel && entry.skipped != 0) {
        return 'entry $i has a skipped count on a ${entry.kind.name} entry';
      }
      if (entry.kind == HistoryKind.clear && i != entries.length - 1) {
        return 'entry $i is a Clear point that is not the deepest Redo entry';
      }
      if (entry.kind == HistoryKind.clear && i < undoCount) {
        return 'entry $i is a Clear point on the undo side';
      }
      if (entry.kind != HistoryKind.length && entry.start != 0) {
        return 'entry $i has a playhead map on a ${entry.kind.name} entry';
      }
      if (entry.kind == HistoryKind.peel && i < undoCount) {
        var run = 0;
        while (run < i && entries[i - 1 - run].kind == HistoryKind.peel) {
          run++;
        }
        if (entry.skipped > run && run < i) {
          return 'entry $i skipped ${entry.skipped} Peel entries but only '
              '$run sit beneath it';
        }
      }
    }
    if (imageCount > maxImages) {
      return '$imageCount images exceed the $maxImages cap';
    }
    // Walk the Redo side as Redo would, from the saved Undo stack.
    final stack = [for (final e in entries.take(undoCount)) e.kind];
    for (var i = undoCount; i < entries.length; i++) {
      final kind = entries[i].kind;
      if (kind != HistoryKind.peel) {
        stack.add(kind);
        continue;
      }
      var target = stack.length - 1;
      while (target >= 0 && stack[target] == HistoryKind.peel) {
        target--;
      }
      if (target < 0 || stack[target] != HistoryKind.layer) {
        return 'Redo entry $i re-peels with no layer to peel';
      }
      stack
        ..removeAt(target)
        ..add(HistoryKind.peel);
    }
    return null;
  }

  /// Why the engine could not take images of [lengths] (frames, by image
  /// ordinal) for this history, or null when it can (#1168). Mirrors
  /// `le_engine_finalize_history`: there are exactly [imageCount] lengths,
  /// each positive, and the lineage decides every one. An image is as long
  /// as the nearest length edit at or nearer live on its side names (its own
  /// image, for a length edit), else as long as the live image (ordinal
  /// [undoCount]). Only a length edit's image and the live image set a
  /// length; every other image repeats the one that rules it.
  String? lengthMalformation(List<int> lengths) {
    if (lengths.length != imageCount) {
      return '${lengths.length} image lengths but the history names '
          '$imageCount';
    }
    final live = lengths[undoCount];
    if (live <= 0) return 'the live image has no length';
    var ruling = live;
    for (var i = undoCount - 1; i >= 0; i--) {
      if (entries[i].kind == HistoryKind.length) ruling = lengths[i];
      if (ruling <= 0 || lengths[i] != ruling) {
        return 'image $i is ${lengths[i]} frames, its lineage gives $ruling';
      }
    }
    ruling = live;
    var ordinal = undoCount + 1;
    for (var i = undoCount; i < entries.length; i++) {
      final kind = entries[i].kind;
      if (kind == HistoryKind.peel) continue; // a marker holds no image
      if (kind == HistoryKind.length) ruling = lengths[ordinal];
      if (ruling <= 0 || lengths[ordinal] != ruling) {
        return 'image $ordinal is ${lengths[ordinal]} frames, its lineage '
            'gives $ruling';
      }
      ordinal++;
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (other is! TrackHistory ||
        other.undoCount != undoCount ||
        other.entries.length != entries.length) {
      return false;
    }
    for (var i = 0; i < entries.length; i++) {
      if (other.entries[i] != entries[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(undoCount, Object.hashAll(entries));

  @override
  String toString() => 'TrackHistory($entries, undoCount: $undoCount)';
}
