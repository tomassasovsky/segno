import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/session/session.dart';

/// The session catalogue as the Sessions face draws it (#1910), from the
/// session layer's state.
///
/// The control layer never reads the session layer: the app maps the state
/// here and hands the result to `ControlCubit.setSessionCatalogue` whenever
/// the session state changes.
FootSessionCatalogue footSessionCatalogueOf(SessionState state) =>
    FootSessionCatalogue(
      sessions: [
        for (final summary in state.sessions)
          FootSessionEntry(
            id: summary.id,
            name: summary.name,
            folder: summary.folder,
            trackCount: summary.trackCount,
            tempoBpm: summary.tempoBpm,
          ),
      ],
      openId: state.currentSessionId,
      failureCount: state.failureCount,
    );
