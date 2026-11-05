import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show RecordTiming, TempoFollowState;
import 'package:segno/appliance/power_off/power_step.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/visualizer/performance_readout.dart';

void main() {
  const readout = PerformanceReadout(
    selected: ReadoutTrack(
      channel: 2,
      name: 'Bass',
      state: 'recording',
      primary: true,
      bars: 4,
    ),
    tempoBpm: 128,
    hasTempo: true,
    tsNum: 3,
    tsDen: 8,
    mode: 'fx',
    activeBank: 1,
    notice: ReadoutNotice(
      title: 'Recording did not start',
      body: 'Press Record again',
      tone: NoticeTone.warning,
      track: 'GUITAR',
    ),
  );

  group('PerformanceReadout wire format', () {
    test('survives a round trip through the channel payload', () {
      // The payload crosses a method channel between two Flutter engines, so
      // the map is the contract — not the Dart type.
      expect(PerformanceReadout.fromMap(readout.toMap()), readout);
    });

    test('a decoded empty payload is the default readout', () {
      expect(PerformanceReadout.fromMap(const {}), const PerformanceReadout());
    });

    test('ignores unknown fields, so a newer sender is readable', () {
      // A newer main window may grow the payload; an older sub-window must
      // read the fields it knows and drop the rest, never throw.
      final map = readout.toMap()..['someFutureFact'] = 42;
      expect(PerformanceReadout.fromMap(map), readout);
    });

    test('defaults every fact on a partial payload', () {
      // An older sender never wrote these keys: the decode must fall back to
      // quiet defaults, and hasTempo must fall back to the old "tempo > 0"
      // reading rather than hiding the tempo.
      final decoded = PerformanceReadout.fromMap(const {
        'tempoBpm': 120.0,
        'mode': 'mute',
      });
      expect(decoded.hasTempo, isTrue);
      expect(decoded.selected, isNull);
      expect(decoded.activeBank, 0);
      expect(decoded.notice, isNull);
      expect(decoded.goodbye, ReadoutGoodbye.none);
      expect(
        PerformanceReadout.fromMap(const {'tempoBpm': 0.0}).hasTempo,
        isFalse,
      );
    });

    test('a garbled notice decodes to none, and an unknown tone to '
        'neutral', () {
      expect(
        PerformanceReadout.fromMap(const {'notice': 'Saved'}).notice,
        isNull,
      );
      expect(
        PerformanceReadout.fromMap(const {
          'notice': {'title': 'Saved', 'tone': 'loud'},
        }).notice,
        const ReadoutNotice(title: 'Saved', tone: NoticeTone.neutral),
      );
      expect(
        PerformanceReadout.fromMap(const {
          'notice': {'title': 'Saved', 'body': 3, 'track': false},
        }).notice,
        const ReadoutNotice(title: 'Saved', tone: NoticeTone.neutral),
      );
    });

    test('a garbled selected track decodes to none, never throws', () {
      expect(
        PerformanceReadout.fromMap(const {'selected': 'GUITAR'}).selected,
        isNull,
      );
    });

    test('the selected track defaults its own missing facts', () {
      final track = ReadoutTrack.fromMap(const {'name': 'Keys'});
      expect(track.channel, 0);
      expect(track.state, 'empty');
      expect(track.primary, isFalse);
      expect(track.bars, 0);
      expect(track.defaultName, isFalse);
    });

    test('goodbye tokens decode, unknown ones read as none', () {
      for (final face in ReadoutGoodbye.values) {
        expect(
          PerformanceReadout.fromMap({'goodbye': face.name}).goodbye,
          face,
        );
      }
      expect(
        PerformanceReadout.fromMap(const {'goodbye': 'mark'}).goodbye,
        ReadoutGoodbye.none,
      );
    });

    test('the save step and its progress cross the channel', () {
      const saving = PerformanceReadout(
        goodbye: ReadoutGoodbye.saving,
        savingStep: PowerStep.writeSession,
        savingProgress: 0.5,
      );
      final decoded = PerformanceReadout.fromMap(saving.toMap());
      expect(decoded, saving);
      expect(PerformanceReadout.fromMap(const {}).savingStep, isNull);
      expect(PerformanceReadout.fromMap(const {}).savingProgress, 0);
      expect(
        PerformanceReadout.fromMap(const {'savingStep': 'later'}).savingStep,
        isNull,
      );
    });

    test('the Track display dim crosses the channel; a sender without it '
        'means none', () {
      const dimmed = PerformanceReadout(brightness: 0.3);
      expect(PerformanceReadout.fromMap(dimmed.toMap()).brightness, 0.3);
      expect(PerformanceReadout.fromMap(const {}).brightness, 1);
    });

    test('the Loop panel facts cross the channel (#1654)', () {
      const panel = PerformanceReadout(
        tempoFollow: TempoFollowState.retimes,
        clockOwnsTempo: true,
        loop: ReadoutLoopSettings(
          lengthBars: 4,
          trackLengthBars: 8,
          timing: RecordTiming.bar,
          trackTiming: RecordTiming.eighth,
          captureLocked: true,
          ready: true,
        ),
        dimmed: true,
      );
      expect(PerformanceReadout.fromMap(panel.toMap()), panel);
      final none = PerformanceReadout.fromMap(const {});
      expect(none.tempoFollow, TempoFollowState.free);
      expect(none.clockOwnsTempo, isFalse);
      expect(none.loop, const ReadoutLoopSettings());
      expect(none.loop.editable, isFalse);
      expect(none.dimmed, isFalse);
    });

    test('an unknown tempo follow reads as locked, never as free', () {
      expect(
        PerformanceReadout.fromMap(const {'tempoFollow': 'later'}).tempoFollow,
        TempoFollowState.busy,
      );
    });

    test('garbled loop facts read as the defaults, not ready', () {
      final loop = PerformanceReadout.fromMap(const {
        'loop': {
          'lengthBars': '4',
          'trackLengthBars': 2.0,
          'timing': 'beat',
          'captureLocked': 1,
          'ready': true,
        },
      }).loop;
      expect(loop.lengthBars, 0);
      expect(loop.trackLengthBars, isNull);
      expect(loop.timing, RecordTiming.immediately);
      expect(loop.captureLocked, isFalse);
      expect(loop.ready, isFalse);
      expect(
        PerformanceReadout.fromMap(const {'loop': 'Auto'}).loop,
        const ReadoutLoopSettings(),
      );
    });

    test('loop settings are editable when ready and no take holds them', () {
      expect(const ReadoutLoopSettings(ready: true).editable, isTrue);
      expect(
        const ReadoutLoopSettings(ready: true, captureLocked: true).editable,
        isFalse,
      );
    });
  });
}
