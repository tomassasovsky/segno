import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/performance_readout.dart';

void main() {
  const readout = PerformanceReadout(
    tracks: [
      ReadoutTrack(name: 'Drums', state: 'playing'),
      ReadoutTrack(name: 'Bass', state: 'recording', selected: true),
      ReadoutTrack(name: 'Keys', state: 'playing', muted: true),
      ReadoutTrack(name: 'Gtr', state: 'empty', pending: true),
    ],
    tempoBpm: 128,
    hasTempo: true,
    currentBeat: 2,
    countingIn: true,
    loopBars: 8,
    isRunning: true,
    mode: 'fx',
    activeBank: 1,
    elapsedSeconds: 71,
    recordArmed: true,
    recordSeconds: 12,
    deviceLost: true,
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

    test('defaults the console facts on a pre-console payload', () {
      // A v1 (pre-console-readout) sender never wrote these keys: the decode
      // must fall back to quiet defaults, and hasTempo must fall back to the
      // old "tempo > 0" reading rather than hiding the dots.
      final decoded = PerformanceReadout.fromMap(const {
        'tempoBpm': 120.0,
        'mode': 'mute',
      });
      expect(decoded.hasTempo, isTrue);
      expect(decoded.currentBeat, 0);
      expect(decoded.countingIn, isFalse);
      // A #696-era sender dropped activeBank as unrendered; the decode
      // defaults it to bank A rather than throwing — the "without ceremony"
      // re-add that removal promised.
      expect(decoded.activeBank, 0);
      expect(decoded.elapsedSeconds, 0);
      expect(decoded.recordArmed, isFalse);
      expect(decoded.recordSeconds, 0);
      // A pre-#453 sender never wrote the loss flag: nothing is lost until
      // a sender says so.
      expect(decoded.deviceLost, isFalse);
      expect(decoded.goodbye, ReadoutGoodbye.none);
      expect(
        PerformanceReadout.fromMap(const {'tempoBpm': 0.0}).hasTempo,
        isFalse,
      );
    });

    test('carries the volume-overlay facts through a round trip', () {
      // The #698 additions: per-track volume / chain / default-name flag /
      // source names, plus the configured-inputs group.
      const mixed = PerformanceReadout(
        tracks: [
          ReadoutTrack(
            name: 'GUITAR',
            state: 'playing',
            volume: 1.26,
            chainEnabled: false,
            inputNames: ['GUITAR'],
          ),
          ReadoutTrack(name: 'TRACK 5', state: 'empty', defaultName: true),
        ],
        inputs: [
          ReadoutInput(
            index: 1,
            name: 'MIC',
            volume: 0.5,
            listeningTracks: ['VOX'],
          ),
        ],
      );
      expect(PerformanceReadout.fromMap(mixed.toMap()), mixed);
    });

    test('defaults the volume-overlay facts on a pre-overlay payload', () {
      // A pre-#698 sender wrote none of these keys: volumes fall back to
      // unity (an unmoved fader, not silence), chains to engaged, and the
      // inputs group to empty.
      final decoded = PerformanceReadout.fromMap(const {
        'tracks': [
          {'name': 'Drums', 'state': 'playing'},
        ],
      });
      final track = decoded.tracks.single;
      expect(track.volume, 1);
      expect(track.chainEnabled, isTrue);
      expect(track.defaultName, isFalse);
      expect(track.inputNames, isEmpty);
      expect(decoded.inputs, isEmpty);
    });

    test('drops non-string entries from re-serialized name lists', () {
      // The plugin re-serializes typed lists as List<Object?> across the
      // engine boundary; junk entries must be dropped, not thrown on.
      final decoded = ReadoutInput.fromMap(const {
        'index': 2,
        'name': 'MIC',
        'listeningTracks': ['VOX', 3, null],
      });
      expect(decoded.listeningTracks, ['VOX']);
    });

    test('equality is by value, which is what makes the push diff work', () {
      expect(
        const PerformanceReadout(tempoBpm: 120),
        const PerformanceReadout(tempoBpm: 120),
      );
      expect(
        const PerformanceReadout(tempoBpm: 120),
        isNot(const PerformanceReadout(tempoBpm: 121)),
      );
    });

    test('goodbye survives a round trip and defaults to none', () {
      const marked = PerformanceReadout(goodbye: ReadoutGoodbye.mark);
      expect(PerformanceReadout.fromMap(marked.toMap()), marked);
      expect(
        PerformanceReadout.fromMap(const {'tempoBpm': 120}).goodbye,
        ReadoutGoodbye.none,
      );
    });
  });
}
