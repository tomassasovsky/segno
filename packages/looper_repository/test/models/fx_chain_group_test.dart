import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

/// One module of the rack [rackId], or a standalone effect when [rackId] is
/// null. The slot id makes each entry addressable in an expectation.
BuiltInEffect _fx(
  String slot, {
  String? rackId,
  String rackName = 'Funk Wah',
  TrackEffectType type = TrackEffectType.delay,
  FxPlacement placement = FxPlacement.post,
  FxChannels channels = FxChannels.defaults,
  bool enabled = true,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  placement: placement,
  channels: channels,
  rack: rackId == null
      ? null
      : FxRack(id: rackId, name: rackName, art: 'guitar'),
);

List<String> _slots(List<TrackEffect> chain) => [
  for (final fx in chain) fx.slotId!,
];

void main() {
  group('fxChainGroups', () {
    test('an effect with no rack is a group of its own', () {
      final groups = fxChainGroups([_fx('a'), _fx('b')]);

      expect(groups, hasLength(2));
      expect(groups.every((g) => g.isRack), isFalse);
      expect(groups[1].start, 1);
    });

    test('consecutive modules sharing a rack id are one group', () {
      final groups = fxChainGroups([
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.isRack, isTrue);
      expect(_slots(groups.single.entries), ['a', 'b', 'c']);
      expect(groups.single.end, 3);
    });

    test('two racks with the same NAME are two groups, because the id is '
        'what makes a rack', () {
      // The player can rename a rack to whatever another one is called; the
      // surfaces must still treat them as two instances.
      final groups = fxChainGroups([
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r2'),
      ]);

      expect(groups, hasLength(2));
      expect(groups.map((g) => g.rack!.id), ['r1', 'r2']);
    });

    test('a single effect between two racks does not join either', () {
      final groups = fxChainGroups([
        _fx('a', rackId: 'r1'),
        _fx('b'),
        _fx('c', rackId: 'r2'),
      ]);

      expect(groups.map((g) => g.rack?.id), ['r1', null, 'r2']);
      expect(groups.map((g) => g.start), [0, 1, 2]);
    });

    test('a rack is bypassed only when every module is', () {
      final chain = [
        _fx('a', rackId: 'r1', enabled: false),
        _fx('b', rackId: 'r1', enabled: false),
      ];

      expect(fxChainGroups(chain).single.anyEnabled, isFalse);
      expect(
        fxChainGroups([chain.first, _fx('b', rackId: 'r1')]).single.anyEnabled,
        isTrue,
      );
    });
  });

  group('group channel handling', () {
    test('reads the input off the first module and the output side off the '
        'last', () {
      final groups = fxChainGroups([
        _fx(
          'a',
          rackId: 'r1',
          channels: const FxChannels(input: FxChannelInput.monoSum),
        ),
        _fx('b', rackId: 'r1'),
        _fx(
          'c',
          rackId: 'r1',
          channels: const FxChannels(
            output: FxChannelOutput.mono,
            placement: -0.5,
            level: 0.8,
          ),
        ),
      ]);

      expect(
        groups.single.channels,
        const FxChannels(
          input: FxChannelInput.monoSum,
          output: FxChannelOutput.mono,
          placement: -0.5,
          level: 0.8,
        ),
      );
    });

    test('fxSetGroupChannels writes the input to the first module and the '
        'output, balance and level to the last', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ];

      final written = fxSetGroupChannels(
        chain,
        0,
        3,
        const FxChannels(
          input: FxChannelInput.left,
          output: FxChannelOutput.mono,
          placement: 0.25,
          level: 0.5,
        ),
      );

      expect(written[0].channels.input, FxChannelInput.left);
      expect(written[0].channels.output, FxChannelOutput.stereo);
      expect(written[0].channels.level, 1);
      expect(written[2].channels.output, FxChannelOutput.mono);
      expect(written[2].channels.placement, 0.25);
      expect(written[2].channels.level, 0.5);
      expect(written[2].channels.input, FxChannelInput.stereo);
    });

    test('fxSetGroupChannels resets the modules in between, so a rack is '
        'transparent between its own pedals', () {
      // A middle module left carrying a level or a pan would attenuate and
      // shift the signal INSIDE the rack, which no accepted control offers.
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx(
          'b',
          rackId: 'r1',
          channels: const FxChannels(
            output: FxChannelOutput.mono,
            placement: -1,
            level: 0.1,
          ),
        ),
        _fx('c', rackId: 'r1'),
      ];

      final written = fxSetGroupChannels(chain, 0, 3, FxChannels.defaults);

      expect(written[1].channels.isDefault, isTrue);
    });

    test('a one-entry group takes all four, which is the single effect', () {
      final written = fxSetGroupChannels(
        [_fx('a')],
        0,
        1,
        const FxChannels(input: FxChannelInput.right, level: 0.3),
      );

      expect(written.single.channels.input, FxChannelInput.right);
      expect(written.single.channels.level, 0.3);
    });

    test('fxGroupChannelWrites touches one entry for the input and one for '
        'the output side, and none when nothing changed', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ];
      final group = fxChainGroups(chain).single;

      expect(fxGroupChannelWrites(group, FxChannels.defaults), isEmpty);
      expect(
        fxGroupChannelWrites(
          group,
          const FxChannels(input: FxChannelInput.left),
        ).keys,
        [0],
      );
      expect(
        fxGroupChannelWrites(group, const FxChannels(level: 0.5)).keys,
        [2],
      );
    });

    test('applying fxGroupChannelWrites matches fxSetGroupChannels on a rack '
        'whose middle is at defaults', () {
      // The surface uses the targeted writes and preset recall uses the whole
      // rewrite; this is the proof that they are the same rule.
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ];
      const channels = FxChannels(
        input: FxChannelInput.monoSum,
        output: FxChannelOutput.mono,
        placement: -0.25,
        level: 0.6,
      );

      final writes = fxGroupChannelWrites(fxChainGroups(chain).single, channels);
      final applied = [
        for (var i = 0; i < chain.length; i++)
          if (writes[i] case final c?) chain[i].copyWith(channels: c)
          else chain[i],
      ];

      expect(applied, fxSetGroupChannels(chain, 0, 3, channels));
    });

    test('the group channels and the write are inverses', () {
      const channels = FxChannels(
        input: FxChannelInput.monoSum,
        output: FxChannelOutput.mono,
        placement: 0.75,
        level: 0.4,
      );
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
      ];

      final written = fxSetGroupChannels(chain, 0, 2, channels);

      expect(fxChainGroups(written).single.channels, channels);
    });
  });

  group('fxOrderGroups', () {
    test('puts the groups in the order the ids name', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c'),
      ];

      expect(_slots(fxOrderGroups(chain, ['c', 'r1'])), ['c', 'a', 'b']);
    });

    test('refuses an order that does not name exactly the groups there', () {
      // A reorder draft is made on a chain a pedal can still change under it.
      // Committing a stale one would drop or duplicate whatever moved.
      final chain = [_fx('a'), _fx('b')];

      expect(fxOrderGroups(chain, ['a']), same(chain));
      expect(fxOrderGroups(chain, ['a', 'b', 'c']), same(chain));
      expect(fxOrderGroups(chain, ['a', 'a']), same(chain));
    });

    test('refuses an order that would carry a group across the stage '
        'boundary', () {
      final chain = [
        _fx('a', placement: FxPlacement.pre),
        _fx('b', placement: FxPlacement.post),
      ];

      expect(fxOrderGroups(chain, ['b', 'a']), same(chain));
    });
  });

  group('fxOrderRackModules', () {
    test('puts one rack\'s modules in the order the slot ids name', () {
      final chain = [
        _fx('x'),
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
        _fx('z'),
      ];

      expect(
        _slots(fxOrderRackModules(chain, 'r1', ['c', 'a', 'b'])),
        ['x', 'c', 'a', 'b', 'z'],
      );
    });

    test('refuses a list that does not name exactly that rack\'s modules', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
      ];

      expect(fxOrderRackModules(chain, 'r1', ['a']), same(chain));
      expect(fxOrderRackModules(chain, 'r1', ['a', 'z']), same(chain));
      expect(fxOrderRackModules(chain, 'r1', ['a', 'a']), same(chain));
      expect(fxOrderRackModules(chain, 'nope', ['a', 'b']), same(chain));
    });
  });

  group('fxGroupId', () {
    test('is the rack id for a rack and the slot id for a single effect', () {
      final groups = fxChainGroups([_fx('a', rackId: 'r1'), _fx('b')]);

      expect(groups.map(fxGroupId), ['r1', 'b']);
    });
  });

  group('fxRenameRack', () {
    test('renames every module of the rack and leaves its id alone', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
      ];

      final renamed = fxRenameRack(chain, 'r1', 'Verse');

      expect(renamed.map((fx) => fx.rack!.name), ['Verse', 'Verse']);
      expect(renamed.every((fx) => fx.rack!.id == 'r1'), isTrue);
      expect(renamed.every((fx) => fx.rack!.art == 'guitar'), isTrue);
    });

    test('leaves another rack and a standalone effect untouched', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r2', rackName: 'Chorus'),
        _fx('c'),
      ];

      final renamed = fxRenameRack(chain, 'r1', 'Verse');

      expect(renamed[1].rack!.name, 'Chorus');
      expect(renamed[2].rack, isNull);
    });
  });

  group('fxRemoveRange', () {
    test('removing a rack takes all of its modules', () {
      final chain = [
        _fx('a'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
        _fx('d'),
      ];

      expect(_slots(fxRemoveRange(chain, 1, 3)), ['a', 'd']);
    });

    test('removing one module keeps the rest of the rack', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ];

      final left = fxRemoveRange(chain, 1, 2);

      expect(_slots(left), ['a', 'c']);
      expect(fxChainGroups(left), hasLength(1));
    });

    test('an out-of-range span changes nothing', () {
      final chain = [_fx('a')];

      expect(fxRemoveRange(chain, 0, 9), same(chain));
      expect(fxRemoveRange(chain, 1, 1), same(chain));
    });
  });

  group('fxMoveGroup', () {
    test('moves a whole rack, modules and all', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c'),
      ];

      expect(_slots(fxMoveGroup(chain, 0, 1)), ['c', 'a', 'b']);
    });

    test('refuses to carry a group across the Pre/Post boundary', () {
      // The accepted design says reorder moves an effect within its stage and
      // the explicit switch is what moves it between them. A reorder that
      // silently re-staged an effect would change whether it is recorded.
      final chain = [
        _fx('a', placement: FxPlacement.pre),
        _fx('b', placement: FxPlacement.post),
      ];

      expect(fxMoveGroup(chain, 0, 1), same(chain));
    });

    test('reorders freely inside one stage', () {
      final chain = [
        _fx('a', placement: FxPlacement.pre),
        _fx('b', placement: FxPlacement.pre),
        _fx('c', placement: FxPlacement.post),
      ];

      expect(_slots(fxMoveGroup(chain, 1, 0)), ['b', 'a', 'c']);
    });

    test('an out-of-range or no-op move changes nothing', () {
      final chain = [_fx('a'), _fx('b')];

      expect(fxMoveGroup(chain, 0, 0), same(chain));
      expect(fxMoveGroup(chain, 0, 5), same(chain));
      expect(fxMoveGroup(chain, -1, 0), same(chain));
    });
  });

  group('fxMoveWithinRack', () {
    test('moves one module inside its rack', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c', rackId: 'r1'),
      ];

      expect(_slots(fxMoveWithinRack(chain, 'r1', 2, 0)), ['c', 'a', 'b']);
    });

    test('leaves the racks on either side where they were', () {
      final chain = [
        _fx('x', rackId: 'r0'),
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('z', rackId: 'r2'),
      ];

      final moved = fxMoveWithinRack(chain, 'r1', 0, 1);

      expect(_slots(moved), ['x', 'b', 'a', 'z']);
    });

    test('an unknown rack changes nothing', () {
      final chain = [_fx('a', rackId: 'r1')];

      expect(fxMoveWithinRack(chain, 'nope', 0, 0), same(chain));
    });
  });

  group('fxSetGroupPlacement', () {
    test('moves every module of the rack, never half of it', () {
      // Half a rack on either side of the loop player is not a state any
      // accepted surface can draw, let alone one the player asked for.
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
      ];

      final moved = fxSetGroupPlacement(chain, 0, 2, FxPlacement.pre);

      expect(
        moved.every((fx) => fx.placement == FxPlacement.pre),
        isTrue,
      );
    });

    test('lands the moved rack at the END of its new stage, not where it '
        'stood', () {
      // The accepted design's own words. A switch that dropped an instance
      // into the middle of the other stage would be reordering it as well as
      // re-staging it, and reorder is a separate, cancellable surface.
      final chain = [
        _fx('a', placement: FxPlacement.pre),
        _fx('b', placement: FxPlacement.pre),
        _fx('c', placement: FxPlacement.post),
      ];

      final moved = fxSetGroupPlacement(chain, 0, 1, FxPlacement.post);

      expect(_slots(moved), ['b', 'c', 'a']);
      expect(fxPreCount(moved), 1);
    });

    test('re-partitions the chain so the moved rack lands at its stage end',
        () {
      final chain = [
        _fx('a', placement: FxPlacement.pre),
        _fx('b', rackId: 'r1', placement: FxPlacement.post),
        _fx('c', rackId: 'r1', placement: FxPlacement.post),
        _fx('d', placement: FxPlacement.post),
      ];

      final moved = fxSetGroupPlacement(chain, 1, 3, FxPlacement.pre);

      expect(_slots(moved), ['a', 'b', 'c', 'd']);
      expect(fxPreCount(moved), 3);
    });
  });

  group('persistence', () {
    test('a rack survives encode and decode', () {
      final chain = [
        _fx('a', rackId: 'r1'),
        _fx('b', rackId: 'r1'),
        _fx('c'),
      ];

      final back = decodeTrackEffects(encodeTrackEffects(chain));

      expect(back[0].rack, back[1].rack);
      expect(back[0].rack!.id, 'r1');
      expect(back[0].rack!.name, 'Funk Wah');
      expect(back[0].rack!.art, 'guitar');
      expect(back[2].rack, isNull);
      expect(fxChainGroups(back), hasLength(2));
    });

    test('an entry with no rack encodes no rack key at all', () {
      expect(encodeTrackEffects([_fx('a')]), isNot(contains('rack')));
    });

    test('renaming a rack does not change the chain fingerprint', () {
      // The fingerprint is sound identity. A rename that moved it would
      // invalidate the wet cache and re-render every take the rack is
      // printed into, for a change nobody can hear.
      final chain = [_fx('a', rackId: 'r1')];

      expect(
        fxChainFingerprint(fxRenameRack(chain, 'r1', 'Verse')),
        fxChainFingerprint(chain),
      );
    });
  });
}
