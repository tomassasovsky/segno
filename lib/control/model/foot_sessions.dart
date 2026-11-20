import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// One saved session as the Sessions face shows it (#1910): what its switch
/// says, whether the player keeps it on the face, and the id an Open is
/// asked with.
///
/// The control layer's own value, compared by every field, so a renamed
/// session is a changed catalogue. The session catalogue's own summary
/// compares by id alone.
class FootSessionEntry extends Equatable {
  /// Creates one entry.
  const new({
    required this.id,
    required this.name,
    this.onFace = true,
    this.trackCount = 0,
    this.tempoBpm = 0,
    this.looperMode,
  });

  /// The session's identity: what an Open is asked with.
  final String id;

  /// The display name.
  final String name;

  /// Whether the face lists it (#1921). Every session is listed unless the
  /// player turned it off in the Library.
  final bool onFace;

  /// Tracks holding recorded audio.
  final int trackCount;

  /// The saved tempo in BPM; 0 when the session has none.
  final double tempoBpm;

  /// The looper mode the session was saved in, or null when its manifest
  /// does not say. A session can hold a setup and no recordings (#1921), so
  /// the card names the setup first.
  final LooperMode? looperMode;

  @override
  List<Object?> get props => [
    id,
    name,
    onFace,
    trackCount,
    tempoBpm,
    looperMode,
  ];
}

/// The session catalogue as the session layer last reported it. The control
/// layer never reads the session layer itself; the app hands this over when
/// it changes.
class FootSessionCatalogue extends Equatable {
  /// Creates a catalogue.
  const new({this.sessions = const [], this.openId, this.failureCount = 0});

  /// Every saved session, in no particular order, listed on the face or
  /// not.
  final List<FootSessionEntry> sessions;

  /// The session that is open, or null when none is.
  final String? openId;

  /// How many session actions have failed so far. An Open asked from the
  /// face that is followed by a higher count did not open.
  final int failureCount;

  @override
  List<Object?> get props => [sessions, openId, failureCount];
}

/// The Sessions face's transient choices while the mode is up: the page of
/// four the track switches show, the session a press shows, the session an
/// Open was asked for and has not settled, and the one whose Open failed.
/// Never stored.
class FootSessionsSelection extends Equatable {
  /// Creates a selection.
  const new({
    this.page = 0,
    this.openingId,
    this.failuresAtOpen = 0,
    this.failedId,
    this.previewId,
  });

  /// The page of four sessions the track switches show.
  final int page;

  /// The session an Open was asked for, until it opens or fails.
  final String? openingId;

  /// [FootSessionCatalogue.failureCount] when that Open was asked.
  final int failuresAtOpen;

  /// The session whose Open, asked from the face, failed. Its card says so
  /// until another Open is asked or the face is left.
  final String? failedId;

  /// The session a press on its switch shows in the readout (#1921), or
  /// null. Showing opens nothing. Another page has other sessions, so
  /// turning to one drops it.
  final String? previewId;

  /// Returns a copy on [page], with no preview.
  FootSessionsSelection onPage(int page) => FootSessionsSelection(
    page: page,
    openingId: openingId,
    failuresAtOpen: failuresAtOpen,
    failedId: failedId,
  );

  /// Returns a copy that previews [id].
  FootSessionsSelection previewing(String id) => FootSessionsSelection(
    page: page,
    openingId: openingId,
    failuresAtOpen: failuresAtOpen,
    failedId: failedId,
    previewId: id,
  );

  /// Returns a copy that waits for [id] to open, and previews it: the panel
  /// then shows what is being opened.
  FootSessionsSelection opening(String id, int failures) =>
      FootSessionsSelection(
        page: page,
        openingId: id,
        failuresAtOpen: failures,
        previewId: id,
      );

  /// Returns a copy with no pending Open, and [failed] as the session whose
  /// Open failed, if it did.
  FootSessionsSelection settled({String? failed}) =>
      FootSessionsSelection(page: page, failedId: failed, previewId: previewId);

  @override
  List<Object?> get props => [
    page,
    openingId,
    failuresAtOpen,
    failedId,
    previewId,
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
  /// A track switch: a press shows the session in this position of the
  /// page, and a Hold opens it (#1921).
  open,

  /// Saves the session on a press, and starts a new loop on a Hold (Undo).
  save,

  /// Shows the four sessions before these, wrapping to the last page
  /// (Clear).
  previousPage,

  /// Shows the next four sessions, wrapping to the first page (Bank).
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
    this.previewed = false,
    this.opens = false,
  });

  /// The physical switch.
  final PedalButton button;

  /// What it does.
  final FootSessionsRole role;

  /// The session a [FootSessionsRole.open] switch previews and opens, or
  /// null for an empty position.
  final FootSessionEntry? session;

  /// Whether its LED is lit: the switch under the open session, and the one
  /// under the session being opened.
  final bool lit;

  /// Whether a press does anything. False for an empty position, for Clear
  /// and Bank with one page, and for everything but the transport while an
  /// Open is in flight.
  final bool available;

  /// Whether this switch's session is the one being opened.
  final bool opening;

  /// Whether this switch's session is the one whose Open failed.
  final bool failed;

  /// Whether this switch's session is the one the panel previews.
  final bool previewed;

  /// Whether a Hold on this switch opens its session: it holds one, a press
  /// is taken, and the session is not the open one.
  final bool opens;

  /// Whether this switch's session is the open one.
  bool get current => lit && !opening;

  @override
  List<Object?> get props => [
    button,
    role,
    session,
    lit,
    available,
    opening,
    failed,
    previewed,
    opens,
  ];
}

/// The Sessions face: the sessions it lists in order, the page in view and
/// the ten switches.
class FootSessionsProjection extends Equatable {
  /// Creates a complete projection.
  const new({
    required this.sessions,
    required this.page,
    required this.open,
    required this.openingId,
    required this.previewId,
    required this.pedals,
  });

  /// The sessions the face lists, in its order: every saved session the
  /// player did not turn off, whatever folder it is in.
  final List<FootSessionEntry> sessions;

  /// The page of four in view, within [pageCount].
  final int page;

  /// The session that is open, or null. The face may not list it.
  final FootSessionEntry? open;

  /// The session an Open was asked for and has not settled, or null.
  final String? openingId;

  /// The session the panel previews: the selection's, while it is on the
  /// page in view, or null.
  final String? previewId;

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
    sessions,
    page,
    open,
    openingId,
    previewId,
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

/// The sessions of [catalogue] the face lists, in its order: the ones the
/// player did not turn off, by name.
List<FootSessionEntry> footSessionsListed(FootSessionCatalogue catalogue) =>
    orderedSessions([
      for (final session in catalogue.sessions)
        if (session.onFace) session,
    ]);

/// Projects the Sessions face from the [catalogue] and the transient
/// [selection]. Pure.
FootSessionsProjection projectFootSessions(
  FootSessionCatalogue catalogue,
  FootSessionsSelection selection,
) {
  final sessions = footSessionsListed(catalogue);
  final pageCount = FootSessionsProjection.pageCountOf(sessions.length);
  final page = selection.page.clamp(0, pageCount - 1);
  final onPage = sessions
      .skip(page * FootSessionsProjection.pageSize)
      .take(FootSessionsProjection.pageSize)
      .toList();
  final openingId = selection.openingId;
  // A session that is no longer on the page (deleted, turned off, renamed
  // onto another page) is no longer shown.
  final previewId = onPage.any((session) => session.id == selection.previewId)
      ? selection.previewId
      : null;
  FootSessionEntry? open;
  for (final session in catalogue.sessions) {
    if (session.id == catalogue.openId) open = session;
  }
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
          role: FootSessionsRole.previousPage,
          available: idle && pageCount > 1,
        );
      case PedalButton.bank:
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.nextPage,
          lit: page > 0,
          available: idle && pageCount > 1,
        );
      case PedalButton.track1 ||
          PedalButton.track2 ||
          PedalButton.track3 ||
          PedalButton.track4:
        final slot = button.index - PedalButton.track1.index;
        final session = slot < onPage.length ? onPage[slot] : null;
        final current = session != null && session.id == catalogue.openId;
        final opening = session != null && session.id == openingId;
        return FootSessionsPedal(
          button: button,
          role: FootSessionsRole.open,
          session: session,
          // The switch of the session being opened is lit whole: its fill
          // ended there (#1921).
          lit: current || opening,
          available: idle && session != null,
          opening: opening,
          failed: session != null && session.id == selection.failedId,
          previewed: session != null && session.id == previewId,
          opens: idle && session != null && !current,
        );
    }
  }

  return FootSessionsProjection(
    sessions: List.unmodifiable(sessions),
    page: page,
    open: open,
    openingId: openingId,
    previewId: previewId,
    pedals: Map.unmodifiable({
      for (final button in PedalButton.values) button: read(button),
    }),
  );
}
