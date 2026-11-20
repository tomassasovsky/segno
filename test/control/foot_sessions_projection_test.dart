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
      expect(ordered(['New loop 10', 'New loop 9', 'New loop 2']), [
        'New loop 2',
        'New loop 9',
        'New loop 10',
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
      // The open session's switch still answers: its press closes the face.
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
          PedalButton.clear: FootSessionsRole.newLoop,
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

    test('Bank answers only with more than one page, and lights past the '
        'first', () {
      final one = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd']),
        const FootSessionsSelection(),
      );
      expect(one[PedalButton.bank].available, isFalse);
      final two = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e']),
        const FootSessionsSelection(page: 1),
      );
      expect(two[PedalButton.bank].available, isTrue);
      expect(two[PedalButton.bank].lit, isTrue);
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
      // Save and New loop are how the first session comes to be.
      expect(projection[PedalButton.undo].available, isTrue);
      expect(projection[PedalButton.clear].available, isTrue);
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

  group('folders', () {
    FootSessionEntry inFolder(String name, String? folder) =>
        FootSessionEntry(id: name, name: name, folder: folder);

    final catalogue = FootSessionCatalogue(
      sessions: [
        inFolder('loose', null),
        inFolder('b1', 'Friday set'),
        inFolder('b2', 'Friday set'),
        inFolder('a1', '2 Rehearsal'),
        inFolder('z1', '10 Old'),
      ],
      openId: 'b2',
    );

    test('are in name order, numbers as numbers, with Unfiled last', () {
      expect(footSessionFolders(catalogue.sessions), [
        '2 Rehearsal',
        '10 Old',
        'Friday set',
        null,
      ]);
    });

    test('with no session outside a folder there is no Unfiled', () {
      expect(footSessionFolders([inFolder('a', 'Set')]), ['Set']);
      expect(footSessionFolders(const []), isEmpty);
    });

    test('the face shows the sessions of the folder in view alone', () {
      final projection = projectFootSessions(
        catalogue,
        const FootSessionsSelection(folder: 'Friday set'),
      );
      expect(projection.folder, 'Friday set');
      expect([for (final s in projection.sessions) s.id], ['b1', 'b2']);
      expect(projection[PedalButton.track2].lit, isTrue);
      expect(projection[PedalButton.track3].session, isNull);
      expect(projection.hasOtherFolders, isTrue);
    });

    test('Bank answers with one page when another folder is there', () {
      final projection = projectFootSessions(
        catalogue,
        const FootSessionsSelection(folder: 'Friday set'),
      );
      expect(projection.pageCount, 1);
      expect(projection[PedalButton.bank].available, isTrue);
    });

    test('a held Bank goes through the folders and wraps', () {
      String? next(String? folder) => projectFootSessions(
        catalogue,
        FootSessionsSelection(folder: folder),
      ).nextFolder;
      expect(next('2 Rehearsal'), '10 Old');
      expect(next('10 Old'), 'Friday set');
      expect(next('Friday set'), isNull);
      expect(next(null), '2 Rehearsal');
    });

    test('the face opens on the folder of the open session', () {
      expect(footSessionsStartFolder(catalogue), 'Friday set');
    });

    test('with no open session it opens on the sessions outside a folder, or '
        'on the first folder when there are none', () {
      expect(
        footSessionsStartFolder(
          FootSessionCatalogue(sessions: catalogue.sessions),
        ),
        isNull,
      );
      expect(
        footSessionsStartFolder(
          FootSessionCatalogue(
            sessions: [inFolder('b', 'Zed'), inFolder('a', 'Alpha')],
          ),
        ),
        'Alpha',
      );
      expect(footSessionsStartFolder(const FootSessionCatalogue()), isNull);
    });

    test('a folder that is gone gives way to the first one there is', () {
      final projection = projectFootSessions(
        catalogue,
        const FootSessionsSelection(folder: 'Deleted'),
      );
      expect(projection.folder, '2 Rehearsal');
      expect([for (final s in projection.sessions) s.id], ['a1']);
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
      expect(projection.previewed?.name, 'b');
      expect(projection[PedalButton.track2].previewed, isTrue);
      expect(projection[PedalButton.track1].previewed, isFalse);
      expect(projection[PedalButton.track3].previewed, isFalse);
    });

    test('a preview ends when its session is no longer on the page', () {
      const previewing = FootSessionsSelection(previewId: 'b');
      // Deleted.
      final gone = projectFootSessions(
        _catalogue(['a', 'c'], openId: 'a'),
        previewing,
      );
      expect(gone.previewId, isNull);
      expect(gone.previewed, isNull);
      // On another page.
      final elsewhere = projectFootSessions(
        _catalogue(['a', 'b', 'c', 'd', 'e'], openId: 'a'),
        const FootSessionsSelection(page: 1, previewId: 'b'),
      );
      expect(elsewhere.previewId, isNull);
    });

    test('a page turn and another folder drop the preview; an Open previews '
        'what it opens and keeps it when it settles', () {
      final previewing = const FootSessionsSelection().previewing('b');
      expect(previewing.onPage(1).previewId, isNull);
      expect(previewing.inFolder('Set').previewId, isNull);
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
