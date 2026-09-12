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
  group('indicator state (the lit half of the accepted LED contract)', () {
    PedalStateFrame dark() => PedalStateFrame.blank();

    test('nothing is lit on a blank frame', () {
      for (final button in PedalButton.values) {
        expect(dark().isLit(button), isFalse, reason: button.name);
      }
    });

    test('Record / Play reports a live take, not the transport at rest', () {
      expect(
        dark()
            .copyWith(globalColor: GlobalColor.red)
            .isLit(
              PedalButton.recPlay,
            ),
        isTrue,
      );
      expect(
        dark()
            .copyWith(globalColor: GlobalColor.amber)
            .isLit(
              PedalButton.recPlay,
            ),
        isTrue,
      );
      // Playing is not capturing: a loop going round lights the tracks, not
      // the transport switch.
      expect(
        dark()
            .copyWith(globalColor: GlobalColor.green)
            .isLit(
              PedalButton.recPlay,
            ),
        isFalse,
      );
    });

    test('Stop and Undo are never lit', () {
      final busy = PedalStateFrame(
        globalColor: GlobalColor.red,
        trackLeds: List<PedalTrackLed>.filled(
          PedalStateFrame.trackCount,
          PedalTrackLed.green,
        ),
        activeBank: 1,
        selectedTrack: 0,
        mode: PedalMode.fx,
        loopLengthMicros: 1000,
        clearFadeActive: true,
      );
      expect(busy.isLit(PedalButton.stop), isFalse);
      expect(busy.isLit(PedalButton.undo), isFalse);
    });

    test('MODE is lit in every mode but the normal one', () {
      expect(
        dark().copyWith(mode: PedalMode.rec).isLit(PedalButton.mode),
        isFalse,
      );
      for (final mode in [PedalMode.play, PedalMode.fx, PedalMode.custom]) {
        expect(
          dark().copyWith(mode: mode).isLit(PedalButton.mode),
          isTrue,
          reason: mode.name,
        );
      }
    });

    test('a track switch follows the LED of the track its BANK drives', () {
      final leds = List<PedalTrackLed>.filled(
        PedalStateFrame.trackCount,
        PedalTrackLed.off,
      )..[5] = PedalTrackLed.green;
      final frame = dark().copyWith(trackLeds: leds);
      // Track 6 is the second switch of bank B, and nothing at all on bank A.
      expect(frame.copyWith(activeBank: 0).isLit(PedalButton.track2), isFalse);
      expect(frame.copyWith(activeBank: 1).isLit(PedalButton.track2), isTrue);
      expect(frame.copyWith(activeBank: 1).isLit(PedalButton.track1), isFalse);
    });

    test('Clear follows the fade and Bank follows the bank', () {
      expect(
        dark().copyWith(clearFadeActive: true).isLit(PedalButton.clear),
        isTrue,
      );
      expect(dark().copyWith(activeBank: 1).isLit(PedalButton.bank), isTrue);
      expect(dark().isLit(PedalButton.bank), isFalse);
    });

    test('the goodbye frame darkens everything that was lit', () {
      final lit = PedalStateFrame(
        globalColor: GlobalColor.red,
        trackLeds: List<PedalTrackLed>.filled(
          PedalStateFrame.trackCount,
          PedalTrackLed.green,
        ),
        activeBank: 1,
        selectedTrack: 0,
        mode: PedalMode.fx,
        loopLengthMicros: 1000,
        clearFadeActive: true,
      );
      expect(lit.isLit(PedalButton.mode), isTrue);
      final off = lit.copyWith(isGoodbye: true);
      for (final button in PedalButton.values) {
        expect(off.isLit(button), isFalse, reason: button.name);
      }
    });

    test('colorFor reads the colour the frame carries for that switch', () {
      final colors = [
        for (var i = 0; i < PedalButton.values.length; i++) PedalColor(i, 0, 0),
      ];
      final frame = dark().copyWith(pedalColors: colors);
      expect(frame.colorFor(PedalButton.recPlay), const PedalColor(0, 0, 0));
      expect(frame.colorFor(PedalButton.bank), const PedalColor(9, 0, 0));
      expect(dark().colorFor(PedalButton.mode), PedalColor.defaultColor);
    });
  });
}
