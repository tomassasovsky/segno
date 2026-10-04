import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';

/// Gives static screenshots a confirmed timing/start tuple behind real owners.
/// Setters update the readback; readiness still comes from each owner's load.
void stubScreenshotSettings(LooperRepository repository) {
  when(() => repository.clickVolumeSettled).thenReturn(true);
  when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
  when(() => repository.clickModeCaptureLocked).thenReturn(false);
  var timing = RecordTiming.immediately;
  var division = GridDivision.bar;
  var overrides = <int, RecordTiming>{};
  var countIn = 1;
  var soundStart = false;
  registerFallbackValue(RecordTiming.immediately);
  registerFallbackValue(GridDivision.bar);
  registerFallbackValue(RecordStartEditKind.restore);
  when(() => repository.sessionTransport).thenAnswer(
    (_) => TransportState(
      recordTiming: timing,
      quantizeDiv: division,
      countInBars: countIn,
      autoRecord: soundStart,
    ),
  );
  when(() => repository.recordTimingSettingsSettled).thenReturn(true);
  when(() => repository.recordTimingRecoveryRequired).thenReturn(false);
  when(() => repository.recordTimingCaptureLocked).thenAnswer(
    (_) => repository.state.tracks.any((track) => track.isCapturing),
  );
  when(() => repository.defaultRecordTiming).thenAnswer((_) => timing);
  when(() => repository.trackRecordTimingOverrides).thenAnswer(
    (_) => Map.unmodifiable(overrides),
  );
  when(() => repository.settleRecordTimingSettings()).thenAnswer(
    (_) async => EngineResult.ok,
  );
  when(
    () => repository.setRecordTimingSettings(
      defaultTiming: any(named: 'defaultTiming'),
      rememberedDivision: any(named: 'rememberedDivision'),
      trackOverrides: any(named: 'trackOverrides'),
    ),
  ).thenAnswer((call) {
    timing = call.namedArguments[#defaultTiming] as RecordTiming;
    division = call.namedArguments[#rememberedDivision] as GridDivision;
    overrides = Map.of(
      call.namedArguments[#trackOverrides] as Map<int, RecordTiming>,
    );
    return EngineResult.ok;
  });
  when(() => repository.recordStartSettingsSettled).thenReturn(true);
  when(() => repository.recordStartRecoveryRequired).thenReturn(false);
  when(() => repository.recordStartCaptureLocked).thenAnswer(
    (_) => repository.state.tracks.any((track) => track.isCapturing),
  );
  when(() => repository.recordStartSettings).thenAnswer(
    (_) => (countInBars: countIn, soundStart: soundStart),
  );
  when(() => repository.recordStartRestartIntent).thenAnswer(
    (_) => (countInBars: countIn, soundStart: soundStart),
  );
  when(() => repository.settleRecordStartSettings()).thenAnswer(
    (_) async => EngineResult.ok,
  );
  when(
    () => repository.setRecordStartSettings(
      countInBars: any(named: 'countInBars'),
      soundStart: any(named: 'soundStart'),
      editKind: any(named: 'editKind'),
    ),
  ).thenAnswer((call) {
    countIn = call.namedArguments[#countInBars] as int;
    soundStart = call.namedArguments[#soundStart] as bool;
    return EngineResult.ok;
  });
}
