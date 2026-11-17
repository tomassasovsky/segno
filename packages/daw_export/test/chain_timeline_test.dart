import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

import 'helpers/fx_log.dart';

/// 48 kHz at 120 BPM: a beat is 24000 frames.
const int _rate = 48000;
const double _bpm = 120;

/// [lane]'s points as (beat, value) pairs.
List<(double, double)> _points(AutomationLane? lane) => [
  for (final b in lane!.breakpoints) (b.beat, b.value),
];

/// Points [expected], each within a float's precision: the log carries
/// 32-bit values.
Matcher _are(List<(double, double)> expected) =>
    pairwiseCompare<(double, double), (double, double)>(
      expected,
      (e, a) => (a.$1 - e.$1).abs() < 1e-6 && (a.$2 - e.$2).abs() < 1e-6,
      'within 1e-6 of',
    );

ChainTimeline _lane(
  List<RawLogEntry> entries, {
  Object? effects,
  bool chainEnabled = true,
}) => ChainTimeline.lane(
  entries,
  0,
  1,
  effects: effects,
  chainEnabled: chainEnabled,
  sampleRate: _rate,
  tempoBpm: _bpm,
);

const Map<String, Object> _delay = {
  'type': 3,
  'params': [0.35, 0.4, 0.5],
};
const Map<String, Object> _drive = {
  'type': 1,
  'params': [0.5, 0.8],
};

void main() {
  group('ChainTimeline', () {
    test("steps an entry's switch at the frames it changed, the value "
        'before and after at each', () {
      final timeline = _lane(
        [
          FxLog.laneEnabled(24000, 0, 1, 0, on: false),
          FxLog.laneEnabled(36000, 0, 1, 0, on: true),
        ],
        effects: [_delay],
      );
      final delay = timeline.slot(0).single;
      expect(delay.type, 3);
      expect(delay.enabled, isTrue);
      expect(delay.params, [0.35, 0.4, 0.5]);
      expect(delay.switching!.initialValue, 1);
      expect(
        _points(delay.switching),
        _are([(1.0, 1.0), (1.0, 0.0), (1.5, 0.0), (1.5, 1.0)]),
      );
      expect(delay.parameters, isEmpty);
    });

    test('steps each setting that changed, at its normalized value', () {
      final timeline = _lane(
        [
          FxLog.laneParam(12000, 0, 1, 0, 1, 0.5),
          FxLog.laneParam(48000, 0, 1, 0, 1, 0.75),
        ],
        effects: [_delay],
      );
      final delay = timeline.slot(0).single;
      expect(delay.switching, isNull);
      expect(delay.parameters.keys, [1]);
      expect(delay.parameters[1]!.initialValue, 0.4);
      expect(
        _points(delay.parameters[1]),
        _are([(0.5, 0.4), (0.5, 0.5), (2.0, 0.5), (2.0, 0.75)]),
      );
    });

    test('an entry is on only while its chain is', () {
      final timeline = _lane(
        [
          FxLog.laneChain(24000, 0, 1, on: true),
          FxLog.laneEnabled(48000, 0, 1, 1, on: false),
        ],
        effects: [_delay, _drive],
        chainEnabled: false,
      );
      final [delay] = timeline.slot(0);
      final [drive] = timeline.slot(1);
      expect(delay.enabled, isFalse);
      expect(_points(delay.switching), _are([(1.0, 0.0), (1.0, 1.0)]));
      expect(
        _points(drive.switching),
        _are([(1.0, 0.0), (1.0, 1.0), (2.0, 1.0), (2.0, 0.0)]),
      );
    });

    test('a switched-off entry starts off', () {
      final timeline = _lane(
        const [],
        effects: [
          {..._delay, 'enabled': false},
        ],
      );
      final delay = timeline.slot(0).single;
      expect(delay.enabled, isFalse);
      expect(delay.switching, isNull);
    });

    test('a slot whose effect changes gets one device for each, the new one '
        'at its defaults and on, each switched by its own Enabled (D6)', () {
      final timeline = _lane(
        [
          FxLog.laneEnabled(6000, 0, 1, 0, on: false),
          FxLog.laneType(24000, 0, 1, 0, 1),
          FxLog.laneParam(36000, 0, 1, 0, 0, 0.9),
          FxLog.laneType(48000, 0, 1, 0, 3),
        ],
        effects: [_delay],
      );
      final [delay, drive] = timeline.slot(0);
      expect(delay.type, 3);
      expect(drive.type, 1);
      // The Drive comes on where it lands: a type change switches the entry
      // on, as the engine's setter does.
      expect(drive.enabled, isFalse);
      expect(drive.params, [0.5, 0.8]);
      expect(
        _points(drive.switching),
        _are([(1.0, 0.0), (1.0, 1.0), (2.0, 1.0), (2.0, 0.0)]),
      );
      expect(_points(drive.parameters[0]), _are([(1.5, 0.5), (1.5, 0.9)]));
      // The Delay goes off at its switch, stays off under the Drive, and
      // comes back at its defaults.
      expect(
        _points(delay.switching),
        _are([(0.25, 1.0), (0.25, 0.0), (2.0, 0.0), (2.0, 1.0)]),
      );
      // Back at its defaults: its Time was at its default already.
      expect(delay.parameters.containsKey(0), isFalse);
      expect(_points(delay.parameters[1]), _are([(2.0, 0.4), (2.0, 0.35)]));
      expect(_points(delay.parameters[2]), _are([(2.0, 0.5), (2.0, 0.35)]));
    });

    test('a type that is the same changes nothing; one that Segno does not '
        'run gets no device and switches the slot off', () {
      final timeline = _lane(
        [FxLog.laneType(24000, 0, 1, 0, 3), FxLog.laneType(48000, 0, 1, 0, 8)],
        effects: [_delay],
      );
      final delay = timeline.slot(0).single;
      expect(_points(delay.switching), _are([(2.0, 1.0), (2.0, 0.0)]));
      expect(delay.parameters, isEmpty);
    });

    test('a slot past the chain length is off, and one entering it comes on, '
        'as the engine seeds it', () {
      final timeline = _lane(
        [
          FxLog.laneCount(24000, 0, 1, 1),
          FxLog.laneEnabled(30000, 0, 1, 1, on: false),
          FxLog.laneCount(48000, 0, 1, 2),
        ],
        effects: [_delay, _drive],
      );
      expect(timeline.slot(0).single.switching, isNull);
      expect(
        _points(timeline.slot(1).single.switching),
        _are([(1.0, 1.0), (1.0, 0.0), (2.0, 0.0), (2.0, 1.0)]),
      );
    });

    test('a slot empty at arm gets the device of the effect that lands on '
        'it, off until it does', () {
      final timeline = _lane(
        [FxLog.laneCount(24000, 0, 1, 3), FxLog.laneType(24000, 0, 1, 2, 7)],
        effects: [_delay],
      );
      expect(timeline.slots, [0, 2]);
      final reverb = timeline.slot(2).single;
      expect(reverb.type, 7);
      expect(reverb.enabled, isFalse);
      expect(reverb.params, [0.5, 0.5, 0.35]);
      expect(_points(reverb.switching), _are([(1.0, 0.0), (1.0, 1.0)]));
      expect(timeline.slot(1), isEmpty);
    });

    test('the entries at frame 0 are where the take starts', () {
      final timeline = _lane(
        [
          FxLog.laneEnabled(0, 0, 1, 0, on: false),
          FxLog.laneParam(0, 0, 1, 0, 2, 0.9),
        ],
        effects: [_delay],
      );
      final delay = timeline.slot(0).single;
      expect(delay.enabled, isFalse);
      expect(delay.params[2], closeTo(0.9, 1e-6));
      expect(delay.switching, isNull);
      expect(delay.parameters, isEmpty);
    });

    test('what stands after every entry at one frame is the change, in the '
        "log's order across its two streams", () {
      final timeline = _lane(
        [
          // The control stream's entries come after the audio stream's in
          // the file, earlier frames included.
          FxLog.laneEnabled(48000, 0, 1, 0, on: false),
          FxLog.laneEnabled(24000, 0, 1, 0, on: false),
          FxLog.laneEnabled(24000, 0, 1, 0, on: true),
        ],
        effects: [_delay],
      );
      expect(
        _points(timeline.slot(0).single.switching),
        _are([(2.0, 1.0), (2.0, 0.0)]),
      );
    });

    test("reads only its own chain's entries", () {
      final timeline = _lane(
        [
          FxLog.laneEnabled(24000, 1, 1, 0, on: false),
          FxLog.laneEnabled(24000, 0, 0, 0, on: false),
          FxLog.monitorEnabled(24000, 0, 0, on: false),
          FxLog.other(24000),
        ],
        effects: [_delay],
      );
      expect(timeline.slot(0).single.switching, isNull);
    });

    test("reads an input monitor's chain from the monitor codes", () {
      final timeline = ChainTimeline.monitor(
        [
          FxLog.monitorEnabled(24000, 2, 0, on: false),
          FxLog.monitorParam(24000, 2, 1, 0, 0.25),
          FxLog.monitorChain(48000, 2, on: false),
          FxLog.monitorChain(60000, 2, on: true),
          FxLog.monitorCount(72000, 2, 1),
          FxLog.monitorType(84000, 2, 0, 1),
          FxLog.laneEnabled(96000, 2, 0, 0, on: true),
        ],
        2,
        effects: const [_delay, _drive],
        chainEnabled: true,
        sampleRate: _rate,
        tempoBpm: _bpm,
      );
      final [delay, drive] = timeline.slot(0);
      expect(_points(delay.switching), _are([(1.0, 1.0), (1.0, 0.0)]));
      // A type change switches the entry on again.
      expect(_points(drive.switching), _are([(3.5, 0.0), (3.5, 1.0)]));
      final second = timeline.slot(1).single;
      expect(_points(second.parameters[0]), _are([(1.0, 0.5), (1.0, 0.25)]));
      expect(
        _points(second.switching),
        _are([
          (2.0, 1.0),
          (2.0, 0.0),
          (2.5, 0.0),
          (2.5, 1.0),
          (3.0, 1.0),
          (3.0, 0.0),
        ]),
      );
    });

    test('a chain at arm changes nothing', () {
      final timeline = ChainTimeline.atArm(
        effects: const [_delay, 'not an entry', _drive],
        chainEnabled: true,
      );
      expect(timeline.slots, [0, 2]);
      expect(timeline.slot(2).single.switching, isNull);
    });

    test('keeps the settings an entry lists, the rest at their defaults', () {
      final timeline = ChainTimeline.atArm(
        effects: const [
          {
            'type': 3,
            'params': [0.1, 'x'],
          },
        ],
        chainEnabled: true,
      );
      expect(timeline.slot(0).single.params, [closeTo(0.1, 1e-9), 0.35, 0.35]);
    });

    group('anyRuns', () {
      test('is on while any of the slots runs, a step at each change', () {
        final timeline = _lane(
          [
            FxLog.laneEnabled(24000, 0, 1, 0, on: false),
            FxLog.laneEnabled(36000, 0, 1, 1, on: false),
            FxLog.laneEnabled(48000, 0, 1, 1, on: true),
          ],
          effects: [_delay, _drive],
        );
        final runs = timeline.anyRuns([0, 1]);
        expect(runs.on, isTrue);
        expect(
          _points(runs.lane),
          _are([(1.5, 1.0), (1.5, 0.0), (2.0, 0.0), (2.0, 1.0)]),
        );
        expect(timeline.anyRuns([0]).lane, isNotNull);
        expect(timeline.anyRuns([5]).on, isFalse);
        expect(timeline.anyRuns([5]).lane, isNull);
      });
    });
  });
}
