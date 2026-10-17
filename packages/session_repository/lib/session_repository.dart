/// Session persistence for Segno: the `.segno` bundle catalog (ids, names,
/// one-level folders), save/load, and the mixdown + stems exports of a saved
/// bundle.
library;

// The Library's Listen answers in the engine's audition types (#1178).
export 'package:segno_engine/segno_engine.dart'
    show AuditionStart, AuditionState, EngineResult, kAuditionMaxSeconds;
export 'src/models/session.dart';
export 'src/models/session_mixdown.dart';
export 'src/models/session_preview.dart';
export 'src/models/session_summary.dart';
export 'src/session_exception.dart';
export 'src/session_id.dart';
export 'src/session_migration.dart'
    show
        SessionConversion,
        SessionConversionChange,
        SessionMigrationContext,
        SessionMigrationStep,
        decodeSessionManifest,
        oldestConvertibleSessionVersion,
        sessionMigrationSteps;
export 'src/session_name.dart';
export 'src/session_repository.dart';
