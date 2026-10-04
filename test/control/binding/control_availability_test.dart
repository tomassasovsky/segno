import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/control_availability.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';

class _Looper extends Mock implements LooperRepository {}

void main() {
  late _Looper looper;
  setUp(() => looper = _Looper());

  test('missing and temporarily locked click retain distinct meanings', () {
    const target = ClickModeValueTarget();
    final missing = ControlAvailability(looper: looper);
    expect(missing.resolves(target), isFalse);
    expect(missing.canAssign(target), isFalse);
    expect(missing.blockedBy(target), isNull);
    final locked = ControlAvailability(
      looper: looper,
      clickModeSnapshot: const ClickModeSnapshot(
        mode: ClickMode.rec,
        captureLocked: true,
      ),
    );
    expect(locked.resolves(target), isTrue);
    expect(locked.canAssign(target), isFalse);
    expect(locked.blockedBy(target), ControlEditBlock.clickCapture);
  });

  test('Multi length locks track override but keeps defaults assignable', () {
    final available = ControlAvailability(
      looper: looper,
      recordLengthSnapshot: RecordLengthSnapshot(
        defaultBars: 4,
        trackOverrides: const {},
        mode: LooperMode.multi,
        captureLocked: false,
      ),
    );
    const target = TrackRecordLengthTarget(3);
    expect(available.resolves(target), isTrue);
    expect(available.blockedBy(target), ControlEditBlock.sharedLength);
    expect(available.canAssign(target), isFalse);
    expect(available.canAssign(const DefaultRecordLengthTarget()), isTrue);
    expect(available.canAssign(const TrackRecordLengthTarget(8)), isFalse);
  });

  test(
    'capture blocks length and timing without making saved targets missing',
    () {
      final available = ControlAvailability(
        looper: looper,
        recordLengthSnapshot: RecordLengthSnapshot(
          defaultBars: 4,
          trackOverrides: const {},
          mode: LooperMode.free,
          captureLocked: true,
        ),
        recordTimingSnapshot: RecordTimingSnapshot(
          defaultTiming: RecordTiming.bar,
          rememberedDivision: GridDivision.bar,
          trackOverrides: const {},
          captureLocked: true,
        ),
      );
      const length = DefaultRecordLengthTarget();
      const timing = TrackRecordTimingTarget(7);
      expect(available.resolves(length), isTrue);
      expect(available.resolves(timing), isTrue);
      expect(available.blockedBy(length), ControlEditBlock.lengthCapture);
      expect(available.blockedBy(timing), ControlEditBlock.timingCapture);
      expect(available.canAssign(timing), isFalse);
    },
  );

  test(
    'removed effect and malformed saved key never retarget another slot',
    () {
      when(
        () => looper.allTrackChains(),
      ).thenReturn({0: const FxChainEnvelope()});
      when(() => looper.trackEffects(0)).thenReturn([
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'new-slot'),
      ]);
      final available = ControlAvailability(looper: looper);
      const old = FxParamTarget(
        address: FxAddress(stage: FxStage.track),
        slotId: 'old-slot',
        param: 0,
      );
      expect(available.resolvesKey(old.canonicalString()), isFalse);
      expect(available.canAssign(old), isFalse);
      expect(available.resolvesKey('not a target'), isFalse);
    },
  );
}
