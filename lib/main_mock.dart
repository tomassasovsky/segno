import 'package:backing_repository/backing_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/run_segno.dart';
import 'package:segno/session_directory.dart';
import 'package:session_repository/session_repository.dart';

/// The mock flavor: a hardware-free engine that boots straight into the looper
/// with a deterministic default config, for UI work without an audio device.
///
/// The mock engine + its start config come from [createMockEngine], so this
/// entrypoint never imports the engine package. The single mock engine is
/// shared by all four repositories, matching the native wiring in
/// [runSegno].
Future<void> main(List<String> args) async {
  final mock = createMockEngine();
  final guards = GuardRegistry();
  final decoder = createMockAudioDecoder();
  await runSegno(
    args,
    repository: LooperRepository(engine: mock.engine),
    sessionRepository: SessionRepository(
      engine: mock.engine,
      sessionsRoot: defaultSessionsRoot,
      guards: guards,
    ),
    performanceRepository: PerformanceRepository(
      engine: mock.engine,
      exportsRoot: defaultExportDirectory,
      guards: guards,
    ),
    guards: guards,
    backingRepository: BackingRepository.forEngine(
      mock.engine,
      decoder: decoder,
      store: backingStoreFor(decoder),
    ),
    startConfig: mock.startConfig,
  );
}
