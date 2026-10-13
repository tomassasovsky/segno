import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('LooperState', () {
    test('defaults to all outputs enabled', () {
      const state = LooperState();
      expect(state.outputEnabledMask, 0xFFFFFFFF);
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(7), isTrue);
    });

    test('isOutputEnabled reads the gate bit (beyond-range reads enabled)', () {
      const state = LooperState(outputEnabledMask: 0x1); // only output 0 on
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(1), isFalse);
      // A negative / out-of-range index never reports "disabled".
      expect(state.isOutputEnabled(-1), isTrue);
    });

    test('outputEnabledMask participates in equality (props rigor)', () {
      const a = LooperState();
      const b = LooperState(outputEnabledMask: 0x1);
      expect(a, isNot(equals(b)));
      expect(a, equals(const LooperState()));
      expect(a.hashCode, const LooperState().hashCode);
    });

    test('output chain fields default and participate in equality', () {
      const state = LooperState();
      expect(state.outputEffects(0), isEmpty);
      expect(state.outputChainEnabled(0), isTrue);

      expect(
        state,
        isNot(
          const LooperState(
            outputChains: {0: FxChainEnvelope(chainEnabled: false)},
          ),
        ),
      );
      expect(
        state,
        isNot(
          LooperState(
            outputChains: {
              0: FxChainEnvelope(
                entries: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            },
          ),
        ),
      );
      // Keyed by destination: the same chain on another destination is a
      // different rig, which is the whole reason this is a map.
      expect(
        const LooperState(
          outputChains: {0: FxChainEnvelope(chainEnabled: false)},
        ),
        isNot(
          const LooperState(
            outputChains: {1: FxChainEnvelope(chainEnabled: false)},
          ),
        ),
      );
    });
  });

  group('isSection (#1323)', () {
    LooperState rig(
      LooperMode mode, {
      Track crown = const Track(lengthFrames: 100),
    }) => LooperState(
      transport: TransportState(looperMode: mode, primaryTrack: 0),
      tracks: [
        crown,
        const Track(channel: 1, lengthFrames: 100),
      ],
    );

    test('every Song track is a section', () {
      expect(rig(LooperMode.song).isSection(0), isTrue);
      expect(rig(LooperMode.song).isSection(1), isTrue);
    });

    test("Band's other tracks are sections under an established primary", () {
      expect(rig(LooperMode.band).isSection(0), isFalse);
      expect(rig(LooperMode.band).isSection(1), isTrue);
      final multiple = rig(
        LooperMode.band,
        crown: const Track(lengthFrames: 200, multiple: 2),
      );
      expect(multiple.isSection(1), isFalse);
      expect(
        rig(LooperMode.band, crown: const Track()).isSection(1),
        isFalse,
      );
    });

    test('no other mode has sections', () {
      for (final mode in [LooperMode.multi, LooperMode.sync, LooperMode.free]) {
        expect(rig(mode).isSection(1), isFalse);
      }
    });
  });

  group('sectionToStart (#1323)', () {
    LooperState rig({int last = -1}) => LooperState(
      transport: TransportState(
        looperMode: LooperMode.song,
        songLastSection: last,
      ),
    );
    const muted = Track(
      channel: 1,
      state: TrackState.stopped,
      lengthFrames: 100,
      muted: true,
    );
    const stopped = Track(
      channel: 2,
      state: TrackState.stopped,
      lengthFrames: 100,
    );
    const other = Track(
      channel: 3,
      state: TrackState.stopped,
      lengthFrames: 100,
    );

    test('prefers the sounding section', () {
      expect(
        rig(last: 2).sectionToStart([
          stopped,
          const Track(channel: 3, lengthFrames: 100, state: TrackState.playing),
        ]),
        3,
      );
    });

    test('passes over a sounding section that is muted', () {
      expect(
        rig().sectionToStart([
          const Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 100,
            muted: true,
          ),
          stopped,
        ]),
        2,
      );
    });

    test('else the last one that is not muted, else the first audible, else '
        'the first', () {
      expect(rig(last: 3).sectionToStart([muted, stopped, other]), 3);
      expect(rig(last: 1).sectionToStart([muted, stopped, other]), 2);
      expect(rig().sectionToStart([muted]), 1);
      expect(rig().sectionToStart(const [Track(channel: 4)]), isNull);
    });
  });

  group('songWaitingSection (#1077, #1323)', () {
    LooperState rig({
      LooperMode mode = LooperMode.song,
      int queued = 1,
      TrackState state = TrackState.stopped,
      int length = 100,
      bool record = false,
    }) => LooperState(
      transport: TransportState(
        looperMode: mode,
        songQueuedTrack: queued,
        songQueueRecord: record,
      ),
      tracks: [
        const Track(state: TrackState.playing, lengthFrames: 100),
        Track(channel: 1, state: state, lengthFrames: length),
      ],
    );

    test('names a waiting section with a take', () {
      expect(rig().songWaitingSection, 1);
    });

    test('names a waiting Band section', () {
      expect(rig(mode: LooperMode.band).songWaitingSection, 1);
    });

    test('names an empty section waiting to record', () {
      expect(
        rig(
          state: TrackState.empty,
          length: 0,
          record: true,
        ).songWaitingSection,
        1,
      );
    });

    test('is null outside Song and Band, without a queue, out of range, on '
        'an empty track waiting to play or on a capturing track', () {
      expect(rig(mode: LooperMode.multi).songWaitingSection, isNull);
      expect(rig(mode: LooperMode.free).songWaitingSection, isNull);
      expect(rig(queued: -1).songWaitingSection, isNull);
      expect(rig(queued: 5).songWaitingSection, isNull);
      expect(
        rig(state: TrackState.empty, length: 0).songWaitingSection,
        isNull,
      );
      expect(
        rig(state: TrackState.recording, record: true).songWaitingSection,
        isNull,
      );
    });
  });
}
