import 'package:backing_repository/backing_repository.dart' show BackingEnd;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/control/binding/owned_value_control.dart';
import 'package:segno/control/view/control_value_readout.dart';
import 'package:segno/l10n/l10n.dart';

import '../../helpers/backing_fixture.dart';
import '../../helpers/helpers.dart';

void main() {
  group('OwnedValuePort backing targets (#1200)', () {
    late BackingFixture f;
    late OwnedValuePort port;

    setUp(() async {
      f = BackingFixture();
      await f.start();
      port = OwnedValuePort(
        looper: f.looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: testFadeSettings(repository: f.looper),
        backing: f.settings,
      );
    });
    tearDown(() => f.dispose());

    test('the three targets resolve and read the live values', () async {
      await f.settings.setLevel(1);
      await f.settings.setPan(-0.5);
      await f.settings.setClickPan(0.5);
      expect(port.resolves(const BackingLevelTarget()), isTrue);
      expect(port.read(const BackingLevelTarget()), mixerTravelFor(1));
      expect(port.read(const BackingPanTarget()), 0.25);
      expect(port.read(const ClickPanTarget()), 0.75);
      expect(
        ownedValueTargets,
        containsAll(const [
          BackingLevelTarget(),
          BackingPanTarget(),
          ClickPanTarget(),
        ]),
      );
    });

    test('a controller moves each value through its owner, with its '
        'released value durable', () async {
      final level = port.origin(const BackingLevelTarget());
      expect(
        await port.writeController(
          const BackingLevelTarget(),
          0.5,
          origin: level,
          released: mixerTravelFor(1),
        ),
        isTrue,
      );
      expect(f.settings.mixOwner.live.level, closeTo(mixerGainAt(0.5), 1e-9));
      expect(f.settings.mix.level, closeTo(1, 1e-9));
      expect(
        f.engine.backingState().level,
        closeTo(mixerGainAt(0.5), 1e-6),
      );

      final pan = port.origin(const BackingPanTarget());
      expect(
        await port.writeController(const BackingPanTarget(), 1, origin: pan),
        isTrue,
      );
      expect(f.settings.mix.pan, 1);
      // The level's held value survives a pan write.
      expect(f.settings.mixOwner.live.level, closeTo(mixerGainAt(0.5), 1e-9));

      final click = port.origin(const ClickPanTarget());
      expect(
        await port.writeController(const ClickPanTarget(), 0, origin: click),
        isTrue,
      );
      expect(f.settings.clickPan, -1);
      expect(f.engine.backingState().clickPan, -1);
    });

    test('an ordinary edit supersedes the controller origin of its own '
        'field only, and is reported', () async {
      final changes = <OwnedValueChange>[];
      final sub = port.ordinaryChanges.listen(changes.add);
      addTearDown(sub.cancel);
      final level = port.origin(const BackingLevelTarget());
      final pan = port.origin(const BackingPanTarget());
      await f.settings.setPan(0.5);
      expect(port.originCurrent(const BackingLevelTarget(), level), isTrue);
      expect(port.originCurrent(const BackingPanTarget(), pan), isFalse);
      expect(
        await port.writeController(const BackingPanTarget(), 0, origin: pan),
        isFalse,
      );
      await f.settings.setClickPan(-0.5);
      await f.settings.setEnd(BackingEnd.next);
      expect(changes.map((c) => (c.target, c.value)), [
        (const BackingPanTarget(), 0.75),
        (const ClickPanTarget(), 0.25),
      ]);
    });

    test('without the backing owners the targets never resolve', () {
      final bare = OwnedValuePort(
        looper: f.looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: testFadeSettings(repository: f.looper),
      );
      expect(bare.resolves(const BackingLevelTarget()), isFalse);
      expect(bare.resolves(const ClickPanTarget()), isFalse);
    });
  });

  group('the backing targets read out and name themselves', () {
    late BackingFixture f;
    setUp(() => f = BackingFixture());
    tearDown(() => f.dispose());

    test('in the Mixer units', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        controlValueReadout(
          l10n,
          const BackingLevelTarget(),
          mixerTravelFor(1),
        ),
        '0.0 dB',
      );
      expect(
        controlValueReadout(l10n, const BackingPanTarget(), 0.5),
        l10n.routingPanCenter,
      );
      expect(
        controlValueReadout(l10n, const ClickPanTarget(), 0),
        l10n.routingPanLeftAmount(100),
      );
      expect(
        valueTargetLabel(l10n, const [], f.looper, const ClickPanTarget()),
        l10n.mixerClickPan,
      );
    });

    test('the pickers offer them under Backing track and Click while their '
        'owners are ready', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      List<ControlValueTarget> under(String id, OwnedValueSnapshots owned) => [
        for (final d in expressionDestinations(
          l10n,
          const [],
          f.looper,
          owned: owned,
        ))
          if (d.id == id)
            for (final g in d.groups)
              for (final c in g.controls) c.target,
      ];
      const owned = OwnedValueSnapshots(
        backingMix: BackingMix.defaults,
        clickPan: 0,
      );
      expect(under('backing', owned), const [
        BackingLevelTarget(),
        BackingPanTarget(),
      ]);
      expect(under('click', owned), contains(const ClickPanTarget()));
      expect(under('backing', const OwnedValueSnapshots()), isEmpty);
    });
  });

  group('the backing targets serialize', () {
    test('byte-stable, and refuse malformed strings', () {
      for (final (target, encoded) in const [
        (BackingLevelTarget(), '{"ctl":"backingLevel"}'),
        (BackingPanTarget(), '{"ctl":"backingPan"}'),
        (ClickPanTarget(), '{"ctl":"clickPan"}'),
      ]) {
        expect(target.canonicalString(), encoded);
        expect(ControlValueTarget.tryParse(encoded), target);
        expect(target.isStructurallyValid, isTrue);
      }
      for (final bad in [
        '{"ctl":"backingLevel","index":0}',
        '{"ctl":"backingPan","extra":true}',
        '{"ctl":"clickPan","index":1}',
        '{"ctl":"backingVolume"}',
      ]) {
        expect(ControlValueTarget.tryParse(bad), isNull, reason: bad);
      }
    });

    test('level travels the Mixer gain axis; pans run left to right', () {
      const level = BackingLevelTarget();
      expect(level.toDomain(0), 0);
      expect(level.toDomain(1), closeTo(2, 1e-9));
      expect(level.fromDomain(1), mixerTravelFor(1));
      expect(level.mappingTop, mixerTravelFor(1));
      const pan = ClickPanTarget();
      expect(pan.toDomain(0), -1);
      expect(pan.toDomain(0.5), 0);
      expect(pan.fromDomain(1), 1);
      expect(const BackingPanTarget().coerce(1.5), 1);
    });
  });
}
