import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/foot_session_catalogue.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  test('maps the session state to the catalogue the Sessions face draws', () {
    final catalogue = footSessionCatalogueOf(
      const SessionState(
        currentSessionId: 'b',
        failureCount: 3,
        sessions: [
          SessionSummary(
            id: 'a',
            name: 'Intro',
            folder: 'Friday set',
            trackCount: 2,
            tempoBpm: 84,
            looperMode: LooperMode.song,
          ),
          SessionSummary(id: 'b', name: 'Outro'),
        ],
        hiddenFromFace: {'b'},
      ),
    );

    expect(
      catalogue,
      const FootSessionCatalogue(
        sessions: [
          FootSessionEntry(
            id: 'a',
            name: 'Intro',
            trackCount: 2,
            tempoBpm: 84,
            looperMode: LooperMode.song,
          ),
          // Hidden by the player: handed over, so the face can name the
          // open session, and not listed.
          FootSessionEntry(id: 'b', name: 'Outro', onFace: false),
        ],
        openId: 'b',
        failureCount: 3,
      ),
    );
  });

  test('a session renamed in place gives a different catalogue', () {
    FootSessionCatalogue named(String name) => footSessionCatalogueOf(
      SessionState(
        sessions: [SessionSummary(id: 'a', name: name)],
      ),
    );
    // The summary compares by id alone; the face's entry does not.
    expect(named('Before'), isNot(named('After')));
  });
}
