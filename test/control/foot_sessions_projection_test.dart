import 'package:flutter_test/flutter_test.dart';
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
