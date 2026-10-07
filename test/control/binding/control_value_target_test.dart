import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/mix_value_scale.dart';

void main() {
  group('ControlValueTarget canonical strings', () {
    test('an FX param round-trips and extends the part 3a address form', () {
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        slotId: 'slot-7',
        param: 2,
      );

      final encoded = target.canonicalString();
      expect(ControlValueTarget.tryParse(encoded), target);
      // The address contributes its own keys, so the SAME map still decodes as
      // a part 3a address — the additive-only contract R19 relies on.
      final map = jsonDecode(encoded) as Map<String, dynamic>;
      expect(FxAddress.fromJson(map), target.address);
      expect(map['slot'], 'slot-7');
      expect(map['param'], 2);
    });

    test('the rig-level controls round-trip', () {
      const volume = TrackVolumeTarget(3);
      const master = MasterGainTarget();
      const click = ClickVolumeTarget();

      expect(ControlValueTarget.tryParse(volume.canonicalString()), volume);
      expect(ControlValueTarget.tryParse(master.canonicalString()), master);
      expect(click.canonicalString(), '{"ctl":"clickVolume"}');
      expect(ControlValueTarget.tryParse(click.canonicalString()), click);
    });

    test('all Mixer coordinates keep distinct canonical identities', () {
      const targets = <MixValueTarget>[
        TrackVolumeTarget(3),
        LaneVolumeTarget(3, 1),
        MonitorVolumeTarget(2),
        TrackPanTarget(3),
        InputPanTarget(2),
        PairBalanceTarget(2),
        OutputLevelTarget(1),
        OutputBalanceTarget(1),
      ];

      expect(
        targets.map((target) => target.canonicalString()).toSet(),
        hasLength(targets.length),
      );
      for (final target in targets) {
        expect(target.isStructurallyValid, isTrue);
        expect(ControlValueTarget.tryParse(target.canonicalString()), target);
      }
    });

    test('Mixer travel uses actual fader law and physical pan/level', () {
      const gain = TrackVolumeTarget(0);
      expect(gain.toDomain(0), 0);
      expect(gain.toDomain(0.5), closeTo(0.04472135955, 1e-10));
      expect(gain.fromDomain(1), closeTo(0.90880725226, 1e-10));
      expect(gain.toDomain(gain.fromDomain(1)), closeTo(1, 1e-12));
      expect(const LaneVolumeTarget(0, 1).toDomain(0.5), gain.toDomain(0.5));
      expect(const MonitorVolumeTarget(0).fromDomain(1), 1);
      expect(mixerGainAt(1), closeTo(2, 1e-12));

      for (final target in <MixValueTarget>[
        const TrackPanTarget(0),
        const InputPanTarget(0),
        const PairBalanceTarget(0),
        const OutputBalanceTarget(0),
      ]) {
        expect(target.toDomain(0), -1);
        expect(target.toDomain(0.5), 0);
        expect(target.toDomain(1), 1);
        expect(target.fromDomain(0), 0.5);
      }
      expect(const OutputLevelTarget(0).toDomain(0.75), 0.75);
    });

    test('live-input travel is linear silence to unity', () {
      const target = MonitorVolumeTarget(0);
      for (final value in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(target.toDomain(value), value);
        expect(target.fromDomain(value), value);
      }
      expect(target.toDomain(-1), 0);
      expect(target.toDomain(2), 1);
      expect(target.toDomain(0.5 + target.relativeStep), 0.52);
    });

    test('Click travel is linear physical gain, with unity at halfway', () {
      const click = ClickVolumeTarget();
      for (final (travel, gain) in <(double, double)>[
        (0, 0),
        (0.125, 0.25),
        (0.5, 1),
        (0.75, 1.5),
        (1, 2),
      ]) {
        expect(click.toDomain(travel), gain);
        expect(click.fromDomain(gain), travel);
      }
      expect(click.relativeStep, 0.01);
      expect(click.isStructurallyValid, isTrue);
    });

    test('Hear click has one strict key and four user-ordered choices', () {
      const target = ClickModeValueTarget();
      expect(target.canonicalString(), '{"ctl":"clickMode"}');
      expect(ControlValueTarget.tryParse(target.canonicalString()), target);
      expect(target.isStructurallyValid, isTrue);
      expect(target.relativeStep, 1 / 3);
      for (final (position, mode) in <(double, ClickMode)>[
        (0, ClickMode.off),
        (1 / 3, ClickMode.recFirst),
        (2 / 3, ClickMode.rec),
        (1, ClickMode.playRec),
      ]) {
        expect(target.toDomain(position), mode);
        expect(target.fromDomain(mode), position);
      }
      expect(target.toDomain(0.16), ClickMode.off);
      expect(target.toDomain(0.17), ClickMode.recFirst);
      expect(target.toDomain(0.5), ClickMode.rec);
      expect(target.toDomain(-1), ClickMode.off);
      expect(target.toDomain(2), ClickMode.playRec);
      expect(() => target.toDomain(double.nan), throwsArgumentError);
      expect(() => target.toDomain(double.infinity), throwsArgumentError);
      for (final malformed in [
        '{"ctl":"clickMode","index":0}',
        '{"ctl":"clickMode","mode":0}',
        '{"ctl":"clickMode","lane":null}',
      ]) {
        expect(ControlValueTarget.tryParse(malformed), isNull);
      }
    });

    test(
      'Count-in encodes option index, including the four-bar final step',
      () {
        const target = CountInValueTarget();
        expect(target.canonicalString(), '{"ctl":"countIn"}');
        expect(ControlValueTarget.tryParse(target.canonicalString()), target);
        expect(target.isStructurallyValid, isTrue);
        expect(target.relativeStep, 1 / 3);
        for (final (position, bars) in <(double, int)>[
          (0, 0),
          (1 / 3, 1),
          (2 / 3, 2),
          (1, 4),
        ]) {
          expect(target.toDomain(position), bars);
          expect(target.fromDomain(bars), position);
        }
        for (final (position, bars) in <(double, int)>[
          (0.20, 1),
          (0.49, 1),
          (0.51, 2),
          (0.80, 2),
          (0.90, 4),
        ]) {
          expect(target.toDomain(position), bars);
        }
        expect(() => target.toDomain(double.nan), throwsArgumentError);
        expect(() => target.toDomain(double.infinity), throwsArgumentError);
        expect(() => target.fromDomain(3), throwsArgumentError);
        for (final malformed in [
          '{"ctl":"countIn","index":0}',
          '{"ctl":"countIn","bars":2}',
          '{"ctl":"countIn","lane":null}',
        ]) {
          expect(ControlValueTarget.tryParse(malformed), isNull);
        }
      },
    );

    test('Record timing identities and seven musical positions are exact', () {
      const defaults = DefaultRecordTimingTarget();
      const track = TrackRecordTimingTarget(7);
      expect(defaults.canonicalString(), '{"ctl":"defaultRecordTiming"}');
      expect(
        track.canonicalString(),
        '{"ctl":"trackRecordTiming","index":7}',
      );
      expect(ControlValueTarget.tryParse(defaults.canonicalString()), defaults);
      expect(ControlValueTarget.tryParse(track.canonicalString()), track);
      expect(track.isStructurallyValid, isTrue);
      expect(const TrackRecordTimingTarget(8).isStructurallyValid, isFalse);
      expect(defaults.relativeStep, 1 / 6);
      for (var code = 0; code <= 6; code++) {
        final choice = RecordTiming.values[code];
        expect(defaults.toDomain(code / 6), choice);
        expect(defaults.fromDomain(choice), code / 6);
      }
      expect(defaults.toDomain(0.249), RecordTiming.loopStart);
      expect(defaults.toDomain(0.25), RecordTiming.bar);
      expect(defaults.toDomain(-1), RecordTiming.immediately);
      expect(defaults.toDomain(2), RecordTiming.sixteenth);
      expect(() => defaults.toDomain(double.nan), throwsArgumentError);
      for (final encoded in [
        '{"ctl":"defaultRecordTiming","index":0}',
        '{"ctl":"trackRecordTiming"}',
        '{"ctl":"trackRecordTiming","index":8}',
        '{"ctl":"trackRecordTiming","index":0.5}',
        '{"ctl":"trackRecordTiming","index":0,"extra":true}',
      ]) {
        expect(ControlValueTarget.tryParse(encoded), isNull);
      }
    });

    test('decay identity and percent travel are strict and fixed', () {
      const defaults = DefaultDecayTarget();
      const lastTrack = TrackDecayTarget(7);
      expect(defaults.canonicalString(), '{"ctl":"overdubDecay"}');
      expect(
        lastTrack.canonicalString(),
        '{"ctl":"trackOverdubDecay","index":7}',
      );
      expect(ControlValueTarget.tryParse(defaults.canonicalString()), defaults);
      expect(
        ControlValueTarget.tryParse(lastTrack.canonicalString()),
        lastTrack,
      );
      expect(lastTrack.address.channel, 7);
      expect(const TrackDecayTarget(8).isStructurallyValid, isFalse);
      expect(defaults.toDomain(0.495), 50);
      expect(defaults.toDomain(0), 0);
      expect(defaults.toDomain(1), 100);
      expect(defaults.fromDomain(50), 0.5);
      expect(defaults.relativeStep, 0.01);
      expect(() => defaults.toDomain(double.nan), throwsArgumentError);
      expect(() => defaults.toDomain(double.infinity), throwsArgumentError);
      for (final malformed in [
        '{"ctl":"overdubDecay","index":0}',
        '{"ctl":"trackOverdubDecay"}',
        '{"ctl":"trackOverdubDecay","index":8}',
        '{"ctl":"trackOverdubDecay","index":-1}',
        '{"ctl":"trackOverdubDecay","index":0.5}',
        '{"ctl":"trackOverdubDecay","index":"0"}',
        '{"ctl":"trackOverdubDecay","index":0,"lane":0}',
      ]) {
        expect(ControlValueTarget.tryParse(malformed), isNull);
      }
    });

    test('Fade duration identity and half-second travel are exact', () {
      const defaults = DefaultFadeTarget();
      const track = TrackFadeTarget(7);
      expect(defaults.canonicalString(), '{"ctl":"fadeSeconds"}');
      expect(track.canonicalString(), '{"ctl":"trackFadeSeconds","index":7}');
      expect(ControlValueTarget.tryParse(defaults.canonicalString()), defaults);
      expect(ControlValueTarget.tryParse(track.canonicalString()), track);
      expect(defaults.channel, isNull);
      expect(track.channel, 7);
      expect(const TrackFadeTarget(8).isStructurallyValid, isFalse);
      // 0.5 s to 30 s is 60 values, so 59 equal intervals of travel.
      for (final (travel, milliseconds) in <(double, int)>[
        (0, 500),
        (1 / 59, 1000),
        (7 / 59, 4000),
        (1, 30000),
        (-1, 500),
        (2, 30000),
      ]) {
        expect(defaults.toDomain(travel), milliseconds);
      }
      // Nearest half second: 0.4 of 59 intervals is 23.6, so 24 steps.
      expect(defaults.toDomain(0.4), 12500);
      expect(defaults.fromDomain(500), 0);
      expect(defaults.fromDomain(4000), 7 / 59);
      expect(defaults.fromDomain(30000), 1);
      expect(defaults.relativeStep, 1 / 59);
      expect(() => defaults.toDomain(double.nan), throwsArgumentError);
      expect(() => defaults.toDomain(double.infinity), throwsArgumentError);
      for (final malformed in [
        '{"ctl":"fadeSeconds","index":0}',
        '{"ctl":"trackFadeSeconds"}',
        '{"ctl":"trackFadeSeconds","index":8}',
        '{"ctl":"trackFadeSeconds","index":-1}',
        '{"ctl":"trackFadeSeconds","index":0.5}',
        '{"ctl":"trackFadeSeconds","index":"0"}',
        '{"ctl":"trackFadeSeconds","index":0,"lane":0}',
      ]) {
        expect(ControlValueTarget.tryParse(malformed), isNull);
      }
    });

    test('Loop/Once identities are fixed and threshold at half travel', () {
      const defaults = DefaultOneShotTarget();
      const track = TrackOneShotTarget(7);
      expect(defaults.canonicalString(), '{"ctl":"defaultOneShot"}');
      expect(track.canonicalString(), '{"ctl":"trackOneShot","index":7}');
      expect(ControlValueTarget.tryParse(defaults.canonicalString()), defaults);
      expect(ControlValueTarget.tryParse(track.canonicalString()), track);
      expect(track.address.channel, 7);
      expect(const TrackOneShotTarget(8).isStructurallyValid, isFalse);
      for (final (travel, once) in <(double, bool)>[
        (0, false),
        (0.49, false),
        (0.5, true),
        (1, true),
      ]) {
        expect(defaults.toDomain(travel), once);
      }
      expect(defaults.fromDomain(oneShot: false), 0);
      expect(defaults.fromDomain(oneShot: true), 1);
      expect(defaults.relativeStep, 1);
      expect(() => defaults.toDomain(double.nan), throwsArgumentError);
      expect(() => defaults.toDomain(double.infinity), throwsArgumentError);
      for (final malformed in [
        '{"ctl":"defaultOneShot","index":0}',
        '{"ctl":"trackOneShot"}',
        '{"ctl":"trackOneShot","index":8}',
        '{"ctl":"trackOneShot","index":-1}',
        '{"ctl":"trackOneShot","index":0.5}',
        '{"ctl":"trackOneShot","index":"0"}',
        '{"ctl":"trackOneShot","index":0,"lane":0}',
      ]) {
        expect(ControlValueTarget.tryParse(malformed), isNull);
      }
    });

    test('Record length keys and Auto/bar travel are exact', () {
      const defaults = DefaultRecordLengthTarget();
      const track = TrackRecordLengthTarget(7);
      expect(defaults.canonicalString(), '{"ctl":"defaultRecordLength"}');
      expect(track.canonicalString(), '{"ctl":"trackRecordLength","index":7}');
      expect(ControlValueTarget.tryParse(defaults.canonicalString()), defaults);
      expect(ControlValueTarget.tryParse(track.canonicalString()), track);
      expect(track.address.channel, 7);
      expect(const TrackRecordLengthTarget(8).isStructurallyValid, isFalse);
      expect(defaults.toDomain(0), 0);
      expect(defaults.toDomain(0.5 / 64), 1);
      expect(defaults.toDomain(1 / 64), 1);
      expect(defaults.toDomain(1), 64);
      expect(defaults.fromDomain(0), 0);
      expect(defaults.fromDomain(1), 1 / 64);
      expect(defaults.fromDomain(64), 1);
      expect(defaults.relativeStep, 1 / 64);
      expect(() => defaults.toDomain(double.nan), throwsArgumentError);
      expect(() => defaults.toDomain(double.infinity), throwsArgumentError);
      for (final malformed in [
        '{"ctl":"defaultRecordLength","index":0}',
        '{"ctl":"trackRecordLength"}',
        '{"ctl":"trackRecordLength","index":8}',
        '{"ctl":"trackRecordLength","index":-1}',
        '{"ctl":"trackRecordLength","index":0.5}',
        '{"ctl":"trackRecordLength","index":"0"}',
        '{"ctl":"trackRecordLength","index":0,"lane":0}',
      ]) {
        expect(ControlValueTarget.tryParse(malformed), isNull);
      }
    });

    test('equal targets encode byte-identically', () {
      const a = FxParamTarget(
        address: FxAddress(stage: FxStage.output),
        slotId: 's',
        param: 0,
      );
      const b = FxParamTarget(
        address: FxAddress(stage: FxStage.output),
        slotId: 's',
        param: 0,
      );

      expect(a.canonicalString(), b.canonicalString());
    });

    test('a corrupt or partial string decodes to null, never a guess', () {
      expect(ControlValueTarget.tryParse('not json'), isNull);
      expect(ControlValueTarget.tryParse('[]'), isNull);
      expect(ControlValueTarget.tryParse('{"ctl":"nope"}'), isNull);
      expect(ControlValueTarget.tryParse('{"ctl":"trackVolume"}'), isNull);
      expect(
        ControlValueTarget.tryParse('{"ctl":"trackVolume","index":0.5}'),
        isNull,
      );
      for (final encoded in [
        '{"ctl":"laneVolume","index":2}',
        '{"ctl":"laneVolume","index":2,"lane":0.5}',
        '{"ctl":"pairBalance","index":1}',
        '{"ctl":"outputLevel","index":null}',
        '{"ctl":"trackPan","index":0,"lane":0}',
        '{"ctl":"masterGain","index":0}',
        '{"ctl":"clickVolume","index":0}',
        '{"ctl":"clickVolume","extra":true}',
        '{"ctl":"clickGain"}',
      ]) {
        expect(ControlValueTarget.tryParse(encoded), isNull);
      }
      // An FX target missing its slot or param would otherwise widen to
      // "some parameter of some effect", which is exactly the retarget A9
      // forbids.
      expect(
        ControlValueTarget.tryParse(
          jsonEncode({
            ...const FxAddress(stage: FxStage.track, index: 1).toJson(),
            'param': 0,
          }),
        ),
        isNull,
      );
      expect(
        ControlValueTarget.tryParse(
          '{"stage":"track","index":1,"slot":"x","param":0.5}',
        ),
        isNull,
      );
      expect(
        ControlValueTarget.tryParse(
          jsonEncode({
            ...const FxAddress(stage: FxStage.track, index: 1).toJson(),
            'slot': 'x',
          }),
        ),
        isNull,
      );
    });

    test('a chain-level (part 6b) string is not a value target', () {
      // The two sealed families are deliberately disjoint: a stomp target
      // names an `enabled` flag, not something to sweep.
      const chain = FxAddress(stage: FxStage.track, index: 2);

      expect(ControlValueTarget.tryParse(chain.canonicalString()), isNull);
    });

    test(
      'invalid coordinates reject while a valid missing target survives',
      () {
        expect(const TrackVolumeTarget(-1).isStructurallyValid, isFalse);
        expect(const LaneVolumeTarget(0, -1).isStructurallyValid, isFalse);
        expect(const PairBalanceTarget(1).isStructurallyValid, isFalse);
        expect(
          const FxParamTarget(
            address: FxAddress(stage: FxStage.loop),
            slotId: 's',
            param: 0,
          ).isStructurallyValid,
          isFalse,
        );
        expect(
          ControlValueTarget.tryParse(
            '{"stage":"allTracks","index":3,"slot":"s","param":0}',
          ),
          isNull,
        );
        const unavailable = FxParamTarget(
          address: FxAddress(stage: FxStage.loop, index: 999, lane: 7),
          slotId: 'removed-slot',
          param: 99,
        );
        expect(unavailable.isStructurallyValid, isTrue);
        expect(
          ControlValueTarget.tryParse(unavailable.canonicalString()),
          unavailable,
        );
      },
    );
  });
}
