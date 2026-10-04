import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/model/foot_mixer.dart';

void main() {
  test(
    '18 inputs retain four slots and disable only absent final channels',
    () {
      final projection = projectFootMixer(
        const LooperState(status: EngineStatus(inputChannels: 18)),
        const FootMixerSelection(domain: FootMixerDomain.inputs, page: 4),
        monitors: const {},
      );
      expect(projection.channelCount, 18);
      expect(projection.pageCount, 5);
      expect(projection.channels.map((slot) => slot.channel), [16, 17, 18, 19]);
      expect(projection.channels.map((slot) => slot.available), [
        true,
        true,
        false,
        false,
      ]);
      expect(projection.selected!.channel, 16);
      expect(
        FootMixerProjection.pedalRoles[PedalButton.bank]!.hold,
        FootMixerAction.switchDomain,
      );
      expect(
        FootMixerProjection.pedalRoles[PedalButton.clear]!.press,
        FootMixerAction.increase,
      );
    },
  );

  test('Auto follows any armed input route while mute remains independent', () {
    const monitors = {
      1: InputMonitor(
        input: 1,
        mode: MonitorMode.auto,
        muted: true,
        volume: .6,
      ),
    };
    const selection = FootMixerSelection(
      domain: FootMixerDomain.inputs,
      channel: 1,
    );
    final live = projectFootMixer(
      const LooperState(
        status: EngineStatus(inputChannels: 2),
        tracks: [
          Track(channel: 5, pending: true, lanes: [Lane(inputChannel: 1)]),
        ],
      ),
      selection,
      monitors: monitors,
    );
    expect(live.selected!.live, isTrue);
    expect(live.selected!.muted, isTrue);
    expect(live.selected!.gain, .6);
    final idle = projectFootMixer(
      const LooperState(
        status: EngineStatus(inputChannels: 2),
      ),
      selection,
      monitors: monitors,
    );
    expect(idle.selected!.live, isFalse);
    expect(idle.selected!.monitorMode, MonitorMode.auto);
  });

  test('level setting read model excludes changing peaks and playhead', () {
    FootMixerProjection project(double peak, int position) => projectFootMixer(
      LooperState(
        tracks: [
          Track(
            state: TrackState.playing,
            lengthFrames: 1000,
            peak: peak,
            positionFrames: position,
            volume: .6,
          ),
        ],
      ),
      const FootMixerSelection(channel: 0),
      monitors: const {},
    );
    expect(project(.1, 10), project(.9, 500));
  });

  test('off-grid endpoint hints require a complete five percentage points', () {
    FootMixerProjection at(double gain) => projectFootMixer(
      const LooperState(status: EngineStatus(inputChannels: 1)),
      const FootMixerSelection(domain: FootMixerDomain.inputs),
      monitors: {0: InputMonitor(input: 0, volume: gain)},
    );
    expect(at(.98).canIncrease, isFalse);
    expect(at(.98).canDecrease, isTrue);
    expect(at(.02).canDecrease, isFalse);
    expect(at(.02).canIncrease, isTrue);
  });
}
