import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// One saved session as the Sessions face shows it (#1910): what its card
/// says, and the id an Open is asked with.
///
/// The control layer's own value, compared by every field, so a renamed
/// session is a changed catalogue. The session catalogue's own summary
/// compares by id alone.
class FootSessionEntry extends Equatable {
  /// Creates one entry.
  const new({
    required this.id,
    required this.name,
    this.folder,
    this.trackCount = 0,
    this.tempoBpm = 0,
  });

  /// The session's identity: what an Open is asked with.
  final String id;

  /// The display name.
  final String name;

  /// The one-level folder it sits in, or null outside any folder.
  final String? folder;

  /// Tracks holding recorded audio.
  final int trackCount;

  /// The saved tempo in BPM; 0 when the session has none.
  final double tempoBpm;

  @override
  List<Object?> get props => [id, name, folder, trackCount, tempoBpm];
}

/// The session catalogue as the session layer last reported it. The control
/// layer never reads the session layer itself; the app hands this over when
/// it changes.
class FootSessionCatalogue extends Equatable {
  /// Creates a catalogue.
  const new({this.sessions = const [], this.openId, this.failureCount = 0});

  /// Every saved session, in no particular order.
  final List<FootSessionEntry> sessions;

  /// The session that is open, or null when none is.
  final String? openId;

  /// How many session actions have failed so far. An Open asked from the
  /// face that is followed by a higher count did not open.
  final int failureCount;

  @override
  List<Object?> get props => [sessions, openId, failureCount];
}

/// The Sessions face's transient choices while the mode is up: the folder
/// and the page of four the track switches show, the session an Open was
/// asked for and has not settled, and the one whose Open failed. Never
/// stored.
class FootSessionsSelection extends Equatable {
  /// Creates a selection.
  const new({
    this.folder,
    this.page = 0,
    this.openingId,
    this.failuresAtOpen = 0,
    this.failedId,
  });

  /// The folder in view, or null for the sessions outside any folder.
  final String? folder;

  /// The page of four sessions the track switches show.
  final int page;

  /// The session an Open was asked for, until it opens or fails.
  final String? openingId;

  /// [FootSessionCatalogue.failureCount] when that Open was asked.
  final int failuresAtOpen;

  /// The session whose Open, asked from the face, failed. Its card says so
  /// until another Open is asked or the face is left.
  final String? failedId;

  /// Returns a copy on [page] of the same folder.
  FootSessionsSelection onPage(int page) => FootSessionsSelection(
    folder: folder,
    page: page,
    openingId: openingId,
    failuresAtOpen: failuresAtOpen,
    failedId: failedId,
  );

  /// Returns a copy on the first page of [folder].
  FootSessionsSelection inFolder(String? folder) => FootSessionsSelection(
    folder: folder,
    openingId: openingId,
    failuresAtOpen: failuresAtOpen,
    failedId: failedId,
  );

  /// Returns a copy that waits for [id] to open.
  FootSessionsSelection opening(String id, int failures) =>
      FootSessionsSelection(
        folder: folder,
        page: page,
        openingId: id,
        failuresAtOpen: failures,
      );

  /// Returns a copy with no pending Open, and [failed] as the session whose
  /// Open failed, if it did.
  FootSessionsSelection settled({String? failed}) =>
      FootSessionsSelection(folder: folder, page: page, failedId: failed);

  @override
  List<Object?> get props => [
    folder,
    page,
    openingId,
    failuresAtOpen,
    failedId,
  ];
}

/// What an Open asked now would end, said on every card that can be opened
/// (#1910 D3). One line: the one that costs the player most.
enum FootSessionsInterruption {
  /// Nothing plays or records.
  none,

  /// A track plays: the Open stops it.
  playback,

  /// A performance recording runs: the Open finishes and saves it.
  recording,

  /// A track records, overdubs or is armed: the Open ends the take and
  /// saves it with the session that is left.
  take,
}

/// What an Open would end on [looper]'s rig, with a performance [recording]
/// running or not.
FootSessionsInterruption footSessionsInterruption(
  LooperState looper, {
  required bool recording,
}) {
  final tracks = looper.tracks;
  if (tracks.any(
    (t) => t.isCapturing || t.pending || t.pendingLaunch != null,
  )) {
    return FootSessionsInterruption.take;
  }
  if (recording) return FootSessionsInterruption.recording;
  if (tracks.any((t) => t.state == TrackState.playing)) {
    return FootSessionsInterruption.playback;
  }
  return FootSessionsInterruption.none;
}

/// What one switch does on the Sessions face.
enum FootSessionsRole {
  /// Opens the session in this position of the page (a track switch).
  open,

  /// Saves the session (Undo).
  save,

  /// Starts a new loop, on a Hold (Clear).
  newLoop,

  /// Shows the next four sessions; a Hold shows the next folder (Bank).
  nextPage,

  /// Record / Play on the selected track, as on the stage.
  recordPlay,

  /// Stops every track, as on the stage.
  stop,

  /// Back to the mode the face was entered from (MODE).
  exit,
}

/// One switch on the Sessions face.
class FootSessionsPedal extends Equatable {
  /// Creates one switch's read.
  const new({
    required this.button,
    required this.role,
    this.session,
    this.lit = false,
    this.available = true,
    this.opening = false,
    this.failed = false,
  });

  /// The physical switch.
  final PedalButton button;

  /// What it does.
  final FootSessionsRole role;

  /// The session a [FootSessionsRole.open] switch opens, or null for an
  /// empty position.
  final FootSessionEntry? session;

  /// Whether its LED is lit.
  final bool lit;

  /// Whether a press does anything. False for an empty position, for Bank
  /// with one page, and for everything but the transport while an Open is
  /// in flight.
  final bool available;

  /// Whether this switch's session is the one being opened.
  final bool opening;

  /// Whether this switch's session is the one whose Open failed.
  final bool failed;

  @override
  List<Object?> get props => [
    button,
    role,
    session,
    lit,
    available,
    opening,
    failed,
  ];
}

/// The Sessions face: the folders, the sessions of the folder in view in
/// order, the page in view and the ten switches.
class FootSessionsProjection extends Equatable {
  /// Creates a complete projection.
  const new({
    required this.folders,
    required this.folder,
    required this.sessions,
    required this.page,
    required this.openId,
    required this.openingId,
    required this.pedals,
  });

  /// The folders that hold a session, in the order a held Bank goes
  /// through them; null is the sessions outside any folder, last.
  final List<String?> folders;

  /// The folder in view, or null for the sessions outside any folder.
  final String? folder;

  /// Whether a held Bank has another folder to show.
  bool get hasOtherFolders => folders.length > 1;

  /// The folder a held Bank shows next.
  String? get nextFolder => folders.isEmpty
      ? folder
      : folders[(folders.indexOf(folder) + 1) % folders.length];

  /// The sessions of [folder], in the face's order.
  final List<FootSessionEntry> sessions;

  /// The page of four in view, within [pageCount].
  final int page;

  /// The session that is open, or null.
  final String? openId;

  /// The session an Open was asked for and has not settled, or null.
  final String? openingId;

  /// All ten switches.
  final Map<PedalButton, FootSessionsPedal> pedals;

  /// Sessions per page: one per track switch.
  static const int pageSize = 4;

  /// How many pages there are (at least one).
  int get pageCount => pageCountOf(sessions.length);

  /// The sessions on [page], at most four.
  List<FootSessionEntry> get pageSessions =>
      sessions.skip(page * pageSize).take(pageSize).toList();

  /// The read of [button].
  FootSessionsPedal operator [](PedalButton button) => pedals[button]!;

  /// How many pages [count] sessions fill (at least one).
  static int pageCountOf(int count) =>
      count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize;

  /// The page of [sessions] (in the face's order) that holds [id], or 0.
  static int pageOf(List<FootSessionEntry> sessions, String? id) {
    final index = sessions.indexWhere((session) => session.id == id);
    return index < 0 ? 0 : index ~/ pageSize;
  }

  @override
  List<Object?> get props => [
    folders,
    folder,
    sessions,
    page,
    openId,
    openingId,
    pedals,
  ];
}

final RegExp _digits = RegExp(r'\d+');

/// Compares two session names the way the face orders them: ignoring case,
/// with each run of digits compared as a number, so `2 Verse` comes before
/// `10 Outro`. Names that differ only in case or in leading zeros fall back
/// to their plain order, so the result is the same on every listing.
int compareSessionNames(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    final dx = _digits.matchAsPrefix(x, i);
    final dy = _digits.matchAsPrefix(y, j);
    if (dx != null && dy != null) {
      // By value without parsing: a longer run of digits, leading zeros
      // aside, is the larger number.
      final nx = dx.group(0)!.replaceFirst(RegExp('^0+(?=.)'), '');
      final ny = dy.group(0)!.replaceFirst(RegExp('^0+(?=.)'), '');
      final byValue = nx.length != ny.length
          ? nx.length.compareTo(ny.length)
          : nx.compareTo(ny);
      if (byValue != 0) return byValue;
      i = dx.end;
      j = dy.end;
      continue;
    }
    final byChar = x.codeUnitAt(i).compareTo(y.codeUnitAt(j));
    if (byChar != 0) return byChar;
    i++;
    j++;
  }
  final byLength = (x.length - i).compareTo(y.length - j);
  if (byLength != 0) return byLength;
  return a.compareTo(b);
}

/// [sessions] in the face's order: by name ([compareSessionNames]), then by
/// id for two sessions with one name.
List<FootSessionEntry> orderedSessions(List<FootSessionEntry> sessions) =>
    [...sessions]..sort((a, b) {
      final byName = compareSessionNames(a.name, b.name);
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });

/// The folders of [sessions] that a held Bank goes through: by name, with
/// the sessions outside any folder (null) last. A folder with no session is
/// not in the catalogue, so it is never shown.
List<String?> footSessionFolders(List<FootSessionEntry> sessions) {
  final named = {
    for (final session in sessions)
      if (session.folder != null) session.folder!,
  }.toList()..sort(compareSessionNames);
  return [...named, if (sessions.any((s) => s.folder == null)) null];
}

/// The folder the face opens on: the open session's, or the sessions
/// outside any folder, or the first folder when there are none of those.
String? footSessionsStartFolder(FootSessionCatalogue catalogue) {
  for (final session in catalogue.sessions) {
    if (session.id == catalogue.openId) return session.folder;
  }
  final folders = footSessionFolders(catalogue.sessions);
  return folders.contains(null) || folders.isEmpty ? null : folders.first;
}

/// Projects the Sessions face from the [catalogue] and the transient
/// [selection]. Pure.
FootSessionsProjection projectFootSessions(
  FootSessionCatalogue catalogue,
  FootSessionsSelection selection,
) {
  final folders = footSessionFolders(catalogue.sessions);
  // A folder that is gone (its last session moved or deleted) gives way to
  // the first one there is.
  final folder = folders.contains(selection.folder) || folders.isEmpty
      ? selection.folder
      : folders.first;
  final sessions = orderedSessions([
    for (final session in catalogue.sessions)
      if (session.folder == folder) session,
  ]);
  final pageCount = FootSessionsProjection.pageCountOf(sessions.length);
  final page = selection.page.clamp(0, pageCount - 1);
  final onPage = sessions
      .skip(page * FootSessionsProjection.pageSize)
      .take(FootSessionsProjection.pageSize)
      .toList();
  final openingId = selection.openingId;
  // While an Open is in flight only the transport and Exit answer: the rig
  // is about to be replaced.
  final idle = openingId == null;
  FootSessionsPedal read(PedalButton button) {
    switch (button) {
      case PedalButton.mode:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.exit,
          lit: true,
        );
      case PedalButton.recPlay:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.recordPlay,
        );
      case PedalButton.stop:
        return FootSessionsPedal(button: button, role: FootSessionsRole.stop);
      case PedalButton.undo:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.save,
          available: idle,
        );
      case PedalButton.clear:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.newLoop,
          available: idle,
        );
      case PedalButton.bank:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.nextPage,
          lit: page > 0,
          available: idle && (pageCount > 1 || folders.length > 1),
        );
      case PedalButton.track1 ||
          PedalButton.track2 ||
          PedalButton.track3 ||
          PedalButton.track4:
        final slot = button.index - PedalButton.track1.index;
        final session = slot < onPage.length ? onPage[slot] : null;
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.open,
          session: session,
          lit: session != null && session.id == catalogue.openId,
          available: idle && session != null,
          opening: session != null && session.id == openingId,
          failed: session != null && session.id == selection.failedId,
        );
    }
  }

  return FootSessionsProjection(
    folders: List.unmodifiable(folders),
    folder: folder,
    sessions: List.unmodifiable(sessions),
    page: page,
    openId: catalogue.openId,
    openingId: openingId,
    pedals: Map.unmodifiable({
      for (final button in PedalButton.values) button: read(button),
    }),
  );
}
