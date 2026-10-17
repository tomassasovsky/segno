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

  group('songWaitingSection (#1077)', () {
    LooperState rig({
      LooperMode mode = LooperMode.song,
      int queued = 1,
      TrackState state = TrackState.stopped,
      int length = 100,
    }) => LooperState(
      transport: TransportState(looperMode: mode, songQueuedTrack: queued),
      tracks: [
        const Track(state: TrackState.playing, lengthFrames: 100),
        Track(channel: 1, state: state, lengthFrames: length),
      ],
    );

    test('names a waiting section with a take', () {
      expect(rig().songWaitingSection, 1);
    });

    test('is null outside Song, without a queue, out of range, on an empty '
        'or a capturing track', () {
      expect(rig(mode: LooperMode.multi).songWaitingSection, isNull);
      expect(rig(queued: -1).songWaitingSection, isNull);
      expect(rig(queued: 5).songWaitingSection, isNull);
      expect(
        rig(state: TrackState.empty, length: 0).songWaitingSection,
        isNull,
      );
      expect(rig(state: TrackState.recording).songWaitingSection, isNull);
    });
  });
}
