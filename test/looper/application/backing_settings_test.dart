import 'dart:convert';

import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/looper/model/owned_setting.dart';

import '../../helpers/backing_fixture.dart';

void main() {
  group('BackingSettings (#1200)', () {
    late BackingFixture f;
    setUp(() => f = BackingFixture());
    tearDown(() => f.dispose());

    test('an absent record is a silent, unrouted backing and a centred '
        'click; nothing is written for the defaults', () async {
      await f.start();
      expect(f.settings.mix, BackingMix.defaults);
      expect(f.settings.clickPan, 0);
      expect(f.settingsStore.values, isEmpty);
    });

    test('each edit is stored, applied to the voice, and survives a '
        'restart', () async {
      await f.start();
      await f.settings.setLevel(0.5);
      await f.settings.setPan(-0.25);
      await f.settings.setOutput(0xC);
      await f.settings.setEnd(BackingEnd.repeat);
      await f.settings.setClickPan(0.75);
      final engine = f.engine.backingState();
      expect(engine.level, 0.5);
      expect(engine.pan, -0.25);
      expect(engine.outputMask, 0xC);
      expect(engine.endMode, BackingEnd.repeat);
      expect(engine.clickPan, 0.75);
      expect(
        jsonDecode(f.settingsStore.values['backing.mix']! as String),
        {'level': 0.5, 'pan': -0.25, 'outputMask': 12, 'end': 'repeat'},
      );
      expect(f.settingsStore.values['tempo.click_pan'], 0.75);

      // A fresh start over the same store replays both into the engine.
      final again = BackingFixture();
      addTearDown(again.dispose);
      again.settingsStore.values.addAll(f.settingsStore.values);
      await again.start();
      expect(
        again.settings.mix,
        const BackingMix(
          level: 0.5,
          pan: -0.25,
          outputMask: 0xC,
          end: BackingEnd.repeat,
        ),
      );
      expect(again.engine.backingState().outputMask, 0xC);
      expect(again.engine.backingState().clickPan, 0.75);
    });

    test('a held controller level stays live while its Released value is '
        'durable, and an edit of another field keeps it', () async {
      await f.start();
      final owner = f.settings.mixOwner;
      await owner.setController(
        const BackingMix(level: 0.9),
        lifetime: owner.lifetime,
        released: const BackingMix(level: 0.2),
        address: BackingMixField.level,
      );
      expect(owner.live.level, 0.9);
      expect(owner.durable.level, 0.2);
      expect(f.engine.backingState().level, closeTo(0.9, 1e-6));
      await f.settings.setPan(0.5);
      expect(owner.durable, const BackingMix(level: 0.2, pan: 0.5));
      expect(owner.live, const BackingMix(level: 0.9, pan: 0.5));
    });

    test('centre click pan over an absent key stays absent', () async {
      await f.start();
      await f.settings.setClickPan(0);
      expect(f.settingsStore.values.containsKey('tempo.click_pan'), isFalse);
      await f.settings.setClickPan(0.5);
      await f.settings.setClickPan(0);
      expect(f.settingsStore.values['tempo.click_pan'], 0);
    });

    test('out-of-range values are refused before they are queued', () async {
      await f.start();
      expect(() => f.settings.setLevel(2.5), throwsRangeError);
      expect(() => f.settings.setPan(-1.5), throwsRangeError);
      expect(() => f.settings.setClickPan(double.nan), throwsRangeError);
      expect(f.settings.mix, BackingMix.defaults);
    });

    test('an unreadable record makes only the mix need recovery; Retry '
        'stores the defaults', () async {
      f.settingsStore.values['backing.mix'] = '{"level": "loud"}';
      await f.start();
      expect(f.settings.mixOwner.ready, isFalse);
      expect(f.settings.clickPanOwner.ready, isTrue);
      expect((await f.settings.mixOwner.recover()).isOk, isTrue);
      expect(f.settings.mixOwner.ready, isTrue);
      expect(
        BackingMix.fromJson(
          jsonDecode(f.settingsStore.values['backing.mix']! as String),
        ),
        BackingMix.defaults,
      );
    });

    test('a Session install needs the exclusion, then replaces both', () async {
      await f.start();
      const mix = BackingMix(level: 0.3, outputMask: 3, end: BackingEnd.next);
      await expectLater(f.settings.installSession(mix, -1), throwsStateError);
      await f.settings.mixOwner.runExclusive(
        () => f.settings.clickPanOwner.runExclusive(
          () => f.settings.installSession(mix, -1),
        ),
      );
      expect(f.settings.mix, mix);
      expect(f.settings.clickPan, -1);
      expect(f.engine.backingState().endMode, BackingEnd.next);
      expect(f.engine.backingState().clickPan, -1);
    });

    test('the owners carry their own keys', () {
      expect(
        f.settings.owners.map((owner) => owner.key),
        [OwnedSetting.backingMix, OwnedSetting.clickPan],
      );
    });
  });

  group(BackingMix, () {
    test('reads its record strictly', () {
      const mix = BackingMix(level: 2, pan: -1, outputMask: 0xffffffff);
      expect(BackingMix.fromJson(jsonDecode(jsonEncode(mix.toJson()))), mix);
      for (final bad in <Object?>[
        null,
        <String, dynamic>{},
        {'level': 1, 'pan': 0, 'outputMask': 0},
        {'level': 1, 'pan': 0, 'outputMask': 0, 'end': 'loop'},
        {'level': 3, 'pan': 0, 'outputMask': 0, 'end': 'stop'},
        {'level': 1, 'pan': 0, 'outputMask': -1, 'end': 'stop'},
        {'level': 1, 'pan': 0, 'outputMask': 0, 'end': 'stop', 'x': 1},
      ]) {
        expect(() => BackingMix.fromJson(bad), throwsFormatException);
      }
    });

    test('withField takes one field', () {
      const a = BackingMix.defaults;
      const b = BackingMix(level: 0.5, pan: 1, outputMask: 3);
      expect(a.withField(BackingMixField.pan, b), const BackingMix(pan: 1));
      expect(
        a.withField(BackingMixField.output, b),
        const BackingMix(outputMask: 3),
      );
    });
  });
}
