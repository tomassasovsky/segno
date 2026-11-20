import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/model/foot_sessions.dart';

FootSessionEntry _session(String name, {String? id}) =>
    FootSessionEntry(id: id ?? name, name: name);

FootSessionCatalogue _catalogue(List<String> names, {String? openId}) =>
    FootSessionCatalogue(
      sessions: [for (final name in names) _session(name)],
      openId: openId,
    );

void main() {
  group('the order of the sessions', () {
    List<String> ordered(List<String> names) => [
      for (final s in orderedSessions([for (final n in names) _session(n)]))
        s.name,
    ];

    test('is by name, ignoring case', () {
      expect(ordered(['outro', 'Bridge', 'intro', 'Chorus']), [
        'Bridge',
        'Chorus',
        'intro',
        'outro',
      ]);
    });

    test('compares a run of digits as a number', () {
      expect(ordered(['10 Outro', '2 Verse', '1 Intro', '02b', 'Take 12']), [
        '1 Intro',
        '2 Verse',
        '02b',
        '10 Outro',
        'Take 12',
      ]);
      expect(ordered(['New session 10', 'New session 9', 'New session 2']), [
        'New session 2',
        'New session 9',
        'New session 10',
      ]);
    });

    test('is the same whatever order the catalogue lists them in', () {
      final names = ['b', 'A', 'a', '01', '1', 'B'];
      final once = ordered(names);
      expect(ordered(names.reversed.toList()), once);
      expect(once.toSet(), names.toSet());
    });

    test('puts two sessions with one name in id order', () {
      final sessions = orderedSessions([
        _session('Set', id: 'z'),
        _session('Set', id: 'a'),
      ]);
      expect([for (final s in sessions) s.id], ['a', 'z']);
    });

    test('puts a longer name after the name it starts with', () {
      expect(ordered(['Song two', 'Song']), ['Song', 'Song two']);
    });
  });

  group('the face', () {
    test('shows four sessions a page and pads the last page', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e', 'f']),
        const FootSessionsSelection(page: 1),
      );
      expect(projection.pageCount, 2);
      expect([for (final s in projection.pageSessions) s.name], ['e', 'f']);
      expect(projection[PedalButton.track1].session?.name, 'e');
      expect(projection[PedalButton.track2].session?.name, 'f');
      expect(projection[PedalButton.track3].session, isNull);
      expect(projection[PedalButton.track3].available, isFalse);
      expect(projection[PedalButton.track4].available, isFalse);
    });

    test('marks the open session and lights its switch alone', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b', 'c'], openId: 'b'),
        const FootSessionsSelection(),
      );
      expect(projection[PedalButton.track2].lit, isTrue);
      expect(projection[PedalButton.track1].lit, isFalse);
      expect(projection[PedalButton.track3].lit, isFalse);
      // The open session's switch still answers: a press shows it.
      expect(projection[PedalButton.track2].available, isTrue);
    });

    test('gives every switch its role', () {
      final projection = projectFootSessions(
        _catalogue(['a']),
        const FootSessionsSelection(),
      );
      expect(
        {
          for (final pedal in projection.pedals.values)
            pedal.button: pedal.role,
        },
        {
          PedalButton.recPlay: FootSessionsRole.recordPlay,
          PedalButton.stop: FootSessionsRole.stop,
          PedalButton.undo: FootSessionsRole.save,
          PedalButton.clear: FootSessionsRole.previousPage,
          PedalButton.mode: FootSessionsRole.exit,
          PedalButton.bank: FootSessionsRole.nextPage,
          PedalButton.track1: FootSessionsRole.open,
          PedalButton.track2: FootSessionsRole.open,
          PedalButton.track3: FootSessionsRole.open,
          PedalButton.track4: FootSessionsRole.open,
        },
      );
      expect(projection[PedalButton.mode].lit, isTrue);
    });

    test('Clear and Bank answer only with more than one page, and Bank '
        'lights past the first', () {
      final one = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd']),
        const FootSessionsSelection(),
      );
      expect(one[PedalButton.bank].available, isFalse);
      expect(one[PedalButton.clear].available, isFalse);
      final two = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e']),
        const FootSessionsSelection(page: 1),
      );
      expect(two[PedalButton.bank].available, isTrue);
      expect(two[PedalButton.clear].available, isTrue);
      expect(two[PedalButton.bank].lit, isTrue);
      expect(two[PedalButton.clear].lit, isFalse);
    });

    test('keeps a page that no longer exists inside the pages there are', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b']),
        const FootSessionsSelection(page: 7),
      );
      expect(projection.page, 0);
    });

    test('with no sessions has one empty page and nothing to open', () {
      final projection = projectFootSessions(
        const FootSessionCatalogue(),
        const FootSessionsSelection(),
      );
      expect(projection.pageCount, 1);
      expect(projection.sessions, isEmpty);
      for (final button in [
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
        PedalButton.track4,
        PedalButton.bank,
      ]) {
        expect(projection[button].available, isFalse, reason: button.name);
      }
      // Save, and New session on its Hold, are how the first session comes to
      // be.
      expect(projection[PedalButton.undo].available, isTrue);
      expect(projection[PedalButton.clear].available, isFalse);
    });

    test('while an Open is in flight only the transport and Exit answer', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e'], openId: 'a'),
        const FootSessionsSelection().opening('c', 0),
      );
      expect(projection[PedalButton.track3].opening, isTrue);
      expect(projection[PedalButton.track1].opening, isFalse);
      for (final button in [
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
        PedalButton.track4,
        PedalButton.bank,
        PedalButton.undo,
        PedalButton.clear,
      ]) {
        expect(projection[button].available, isFalse, reason: button.name);
      }
      expect(projection[PedalButton.recPlay].available, isTrue);
      expect(projection[PedalButton.stop].available, isTrue);
      expect(projection[PedalButton.mode].available, isTrue);
    });

    test('starts on the page that holds the open session', () {
      final ordered = orderedSessions([
        for (final name in ['a', 'b', 'c', 'd', 'e', 'f']) _session(name),
      ]);
      expect(FootSessionsProjection.pageOf(ordered, 'f'), 1);
      expect(FootSessionsProjection.pageOf(ordered, 'a'), 0);
      expect(FootSessionsProjection.pageOf(ordered, null), 0);
      expect(FootSessionsProjection.pageOf(ordered, 'gone'), 0);
    });
  });

  group('one list (#1921)', () {
    test('sessions in different folders are in one list, by name: the '
        'control layer does not know the folders', () {
      final projection = projectFootSessions(
        _catalogue(['loose', 'b2', 'a1', 'b1']),
        const FootSessionsSelection(),
      );
      expect(
        [for (final s in projection.sessions) s.id],
        ['a1', 'b1', 'b2', 'loose'],
      );
      expect(projection.pageCount, 1);
    });

    test('a session the player hid is not listed, and the others close up', () {
      final catalogue = FootSessionCatalogue(
        sessions: [
          _session('a'),
          const FootSessionEntry(id: 'b', name: 'b', onFace: false),
          _session('c'),
        ],
      );
      final projection = projectFootSessions(
        catalogue,
        const FootSessionsSelection(),
      );
      expect([for (final s in projection.sessions) s.id], ['a', 'c']);
      expect(projection.hiddenCount, 1);
      expect(projection[PedalButton.track2].session?.id, 'c');
      expect(projection[PedalButton.track3].session, isNull);
      expect([for (final s in footSessionsListed(catalogue)) s.id], ['a', 'c']);
    });

    test('hiding counts for the pages: five sessions with one hidden are one '
        'page', () {
      final projection = projectFootSessions(
        FootSessionCatalogue(
          sessions: [
            for (final name in ['a', 'b', 'c', 'd']) _session(name),
            const FootSessionEntry(id: 'e', name: 'e', onFace: false),
          ],
        ),
        const FootSessionsSelection(),
      );
      expect(projection.pageCount, 1);
      expect(projection[PedalButton.bank].available, isFalse);
    });

    test('the open session is named, listed or not, and a hidden one lights '
        'no switch', () {
      final hidden = projectFootSessions(
        FootSessionCatalogue(
          sessions: [
            _session('a'),
            const FootSessionEntry(id: 'b', name: 'b', onFace: false),
          ],
          openId: 'b',
        ),
        const FootSessionsSelection(),
      );
      expect(hidden.open?.id, 'b');
      expect(hidden.open?.onFace, isFalse);
      expect([
        for (final pedal in hidden.pedals.values)
          if (pedal.role == FootSessionsRole.open && pedal.lit) pedal.button,
      ], isEmpty);
      final listed = projectFootSessions(
        _catalogue(['a', 'b'], openId: 'b'),
        const FootSessionsSelection(),
      );
      expect(listed.open?.onFace, isTrue);
      expect(listed[PedalButton.track2].lit, isTrue);
      expect(
        projectFootSessions(
          _catalogue(['a']),
          const FootSessionsSelection(),
        ).open,
        isNull,
      );
    });

    test('a session hidden or shown is a changed catalogue', () {
      expect(
        const FootSessionCatalogue(
          sessions: [FootSessionEntry(id: 'a', name: 'a')],
        ),
        isNot(
          const FootSessionCatalogue(
            sessions: [FootSessionEntry(id: 'a', name: 'a', onFace: false)],
          ),
        ),
      );
    });
  });

  group('a tap previews and a hold opens (#1921)', () {
    test('a switch with a session that is not the open one has a Hold that '
        'opens it', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b'], openId: 'a'),
        const FootSessionsSelection(),
      );
      // The open session: a tap is taken, and there is nothing to open.
      expect(projection[PedalButton.track1].available, isTrue);
      expect(projection[PedalButton.track1].opens, isFalse);
      expect(projection[PedalButton.track1].current, isTrue);
      expect(projection[PedalButton.track2].opens, isTrue);
      expect(projection[PedalButton.track2].current, isFalse);
      // An empty position has neither.
      expect(projection[PedalButton.track3].available, isFalse);
      expect(projection[PedalButton.track3].opens, isFalse);
    });

    test('the previewed session is marked on its switch alone', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b', 'c'], openId: 'a'),
        const FootSessionsSelection().previewing('b'),
      );
      expect(projection.previewId, 'b');
      expect(projection[PedalButton.track2].previewed, isTrue);
      expect(projection[PedalButton.track1].previewed, isFalse);
      expect(projection[PedalButton.track3].previewed, isFalse);
    });

    test('a preview ends when its session is no longer on the page', () {
      const previewing = FootSessionsSelection(previewId: 'b');
      // Deleted, or hidden.
      final gone = projectFootSessions(
        _catalogue(['a', 'c'], openId: 'a'),
        previewing,
      );
      expect(gone.previewId, isNull);
      // On another page.
      final elsewhere = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e'], openId: 'a'),
        const FootSessionsSelection(page: 1, previewId: 'b'),
      );
      expect(elsewhere.previewId, isNull);
    });

    test('a page turn drops the preview; an Open previews what it opens and '
        'keeps it when it settles', () {
      final previewing = const FootSessionsSelection().previewing('b');
      expect(previewing.onPage(1).previewId, isNull);
      final opening = previewing.opening('c', 0);
      expect(opening.previewId, 'c');
      expect(opening.settled(failed: 'c').previewId, 'c');
    });

    test('the switch of the session being opened is lit, and is not the '
        'open one yet', () {
      final projection = projectFootSessions(
        _catalogue(['a', 'b', 'c'], openId: 'a'),
        const FootSessionsSelection().opening('c', 0),
      );
      expect(projection[PedalButton.track3].lit, isTrue);
      expect(projection[PedalButton.track3].current, isFalse);
      expect(projection[PedalButton.track3].opens, isFalse);
      expect(projection[PedalButton.track1].lit, isTrue);
      expect(projection[PedalButton.track1].current, isTrue);
      expect(projection[PedalButton.track2].lit, isFalse);
    });

    test('a session saved in another looper mode is a changed catalogue', () {
      FootSessionCatalogue saved(LooperMode mode) => FootSessionCatalogue(
        sessions: [FootSessionEntry(id: 'a', name: 'a', looperMode: mode)],
      );
      expect(saved(LooperMode.song), isNot(saved(LooperMode.band)));
    });
  });

  test('the session whose Open failed is marked on its switch', () {
    final projection = projectFootSessions(
      _catalogue(['a', 'b', 'c'], openId: 'a'),
      const FootSessionsSelection().opening('c', 0).settled(failed: 'c'),
    );
    expect(projection[PedalButton.track3].failed, isTrue);
    expect(projection[PedalButton.track3].opening, isFalse);
    // It can be tried again.
    expect(projection[PedalButton.track3].available, isTrue);
    expect(projection[PedalButton.track2].failed, isFalse);
  });

  group('what an Open would end', () {
    LooperState rig(List<Track> tracks) => LooperState(tracks: tracks);
    const playing = Track(state: TrackState.playing, lengthFrames: 48000);
    const stopped = Track(state: TrackState.stopped, lengthFrames: 48000);
    const taking = Track(channel: 1, state: TrackState.overdubbing);

    test('nothing, with every track stopped or empty', () {
      expect(
        footSessionsInterruption(
          rig(const [stopped, Track(channel: 1)]),
          recording: false,
        ),
        FootSessionsInterruption.none,
      );
    });

    test('playback, while a track plays', () {
      expect(
        footSessionsInterruption(rig(const [playing]), recording: false),
        FootSessionsInterruption.playback,
      );
    });

    test('the recording, over playback', () {
      expect(
        footSessionsInterruption(rig(const [playing]), recording: true),
        FootSessionsInterruption.recording,
      );
      expect(
        footSessionsInterruption(rig(const [stopped]), recording: true),
        FootSessionsInterruption.recording,
      );
    });

    test('the take, over everything else', () {
      expect(
        footSessionsInterruption(rig(const [playing, taking]), recording: true),
        FootSessionsInterruption.take,
      );
      expect(
        footSessionsInterruption(
          rig(const [Track(pending: true)]),
          recording: false,
        ),
        FootSessionsInterruption.take,
      );
    });
  });

  test('a renamed session is a changed catalogue', () {
    expect(
      const FootSessionCatalogue(
        sessions: [FootSessionEntry(id: 'x', name: 'Before')],
      ),
      isNot(
        const FootSessionCatalogue(
          sessions: [FootSessionEntry(id: 'x', name: 'After')],
        ),
      ),
    );
  });
}
