import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  PedalStateFrame sample() => PedalStateFrame(
    globalColor: GlobalColor.amber,
    trackLeds: List<PedalTrackLed>.filled(
      PedalStateFrame.trackCount,
      PedalTrackLed.green,
    ),
    activeBank: 1,
    selectedTrack: 4,
    mode: PedalMode.play,
    loopLengthMicros: 1000,
    clearFadeActive: true,
  );

  group('PedalStateFrame.blank', () {
    test('is fully off and not a goodbye by default', () {
      final blank = PedalStateFrame.blank();
      expect(blank.globalColor, GlobalColor.off);
      expect(blank.trackLeds, everyElement(PedalTrackLed.off));
      expect(blank.trackLeds, hasLength(PedalStateFrame.trackCount));
      expect(blank.activeBank, 0);
      expect(blank.selectedTrack, 0);
      expect(blank.mode, PedalMode.rec);
      expect(blank.loopLengthMicros, 0);
      expect(blank.clearFadeActive, isFalse);
      expect(blank.isGoodbye, isFalse);
      expect(blank.performanceArmed, isFalse);
      expect(blank.looperMode, PedalLooperMode.multi);
      expect(blank.countingIn, isFalse);
      expect(blank.queuedTrack, isNull);
      expect(blank.queuedProgress, 0);
    });

    test('sets isGoodbye when requested', () {
      expect(PedalStateFrame.blank(goodbye: true).isGoodbye, isTrue);
    });
  });

  group('equality', () {
    test('frames with equal fields are equal', () {
      expect(sample(), sample());
      expect(sample().hashCode, sample().hashCode);
    });

    test('frames differ when a field differs', () {
      expect(sample(), isNot(sample().copyWith(selectedTrack: 5)));
    });

    test('frames differ when only performanceArmed differs', () {
      expect(sample(), isNot(sample().copyWith(performanceArmed: true)));
    });

    test('frames differ when only looperMode differs', () {
      expect(
        sample(),
        isNot(sample().copyWith(looperMode: PedalLooperMode.band)),
      );
    });

    test('frames differ when only countingIn differs', () {
      expect(sample(), isNot(sample().copyWith(countingIn: true)));
    });

    test('toString surfaces the salient fields', () {
      final text = sample().toString();
      expect(text, contains('amber'));
      expect(text, contains('bank: 1'));
      expect(text, contains('selected: 4'));
      expect(text, contains('performanceArmed: false'));
      expect(text, contains('looperMode: multi'));
      expect(text, contains('countingIn: false'));
    });
  });

  group('copyWith', () {
    test('queue progress changes equality and can be cleared together', () {
      final queued = sample().copyWith(queuedTrack: 7, queuedProgress: 127);
      expect(queued.queuedTrack, 7);
      expect(queued.queuedProgress, 127);
      expect(queued.copyWith(), queued);
      expect(queued, isNot(queued.copyWith(queuedProgress: 128)));
      expect(queued, isNot(queued.copyWith(queuedTrack: 6)));
      expect(queued.copyWith(clearQueue: true), sample());
      expect(
        queued.toString(),
        contains('queuedTrack: 7, queuedProgress: 127'),
      );
    });
    test('replaces only the given fields', () {
      final updated = sample().copyWith(
        globalColor: GlobalColor.red,
        activeBank: 0,
        selectedTrack: 2,
        mode: PedalMode.rec,
        loopLengthMicros: 50,
        clearFadeActive: false,
        isGoodbye: true,
        performanceArmed: true,
        trackLeds: List<PedalTrackLed>.filled(
          PedalStateFrame.trackCount,
          PedalTrackLed.red,
        ),
        looperMode: PedalLooperMode.song,
        countingIn: true,
      );
      expect(updated.globalColor, GlobalColor.red);
      expect(updated.activeBank, 0);
      expect(updated.selectedTrack, 2);
      expect(updated.mode, PedalMode.rec);
      expect(updated.loopLengthMicros, 50);
      expect(updated.clearFadeActive, isFalse);
      expect(updated.isGoodbye, isTrue);
      expect(updated.performanceArmed, isTrue);
      expect(updated.trackLeds, everyElement(PedalTrackLed.red));
      expect(updated.looperMode, PedalLooperMode.song);
      expect(updated.countingIn, isTrue);
    });

    test('keeps the original values when no override is given', () {
      expect(sample().copyWith(), sample());
    });
  });

  group('assertions', () {
    test('rejects invalid queue targets and completion without a queue', () {
      for (final target in [-1, 8]) {
        expect(
          () => sample().copyWith(queuedTrack: target),
          throwsA(isA<AssertionError>()),
        );
      }
      expect(
        () => sample().copyWith(queuedProgress: 1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(queuedTrack: 0, queuedProgress: 255),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(queuedTrack: 0, queuedProgress: -1),
        throwsA(isA<AssertionError>()),
      );
    });
    test('rejects the wrong number of track LEDs', () {
      expect(
        () => PedalStateFrame(
          globalColor: GlobalColor.off,
          trackLeds: const [PedalTrackLed.off],
          activeBank: 0,
          selectedTrack: 0,
          mode: PedalMode.rec,
          loopLengthMicros: 0,
          clearFadeActive: false,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects an out-of-range bank', () {
      expect(
        () => sample().copyWith(activeBank: 2),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects an out-of-range armed track', () {
      expect(
        () => sample().copyWith(selectedTrack: PedalStateFrame.trackCount),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(selectedTrack: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a loop length outside the 32-bit range', () {
      expect(
        () => sample().copyWith(loopLengthMicros: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => sample().copyWith(
          loopLengthMicros: PedalStateFrame.maxLoopLengthMicros + 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts the maximum loop length', () {
      expect(
        sample()
            .copyWith(loopLengthMicros: PedalStateFrame.maxLoopLengthMicros)
            .loopLengthMicros,
        PedalStateFrame.maxLoopLengthMicros,
      );
    });
  });
}
