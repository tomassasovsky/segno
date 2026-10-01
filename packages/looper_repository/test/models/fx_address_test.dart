import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('FxAddress', () {
    test('round-trips JSON for every stage', () {
      const addresses = [
        FxAddress(stage: FxStage.input, index: 3),
        FxAddress(stage: FxStage.loop, index: 1, lane: 2),
        FxAddress(stage: FxStage.track, index: 5),
        FxAddress(stage: FxStage.allTracks),
        FxAddress(stage: FxStage.output, index: 1),
      ];
      for (final address in addresses) {
        expect(FxAddress.fromJson(address.toJson()), address);
        expect(FxAddress.tryParse(address.canonicalString()), address);
      }
    });

    test('canonical string is byte-stable and key-order-pinned (R19)', () {
      const loop = FxAddress(stage: FxStage.loop, index: 1, lane: 2);
      // The pinned wire form parts 6/7 persist: fixed key order, enum name.
      expect(loop.canonicalString(), '{"stage":"loop","index":1,"lane":2}');
      expect(
        const FxAddress(stage: FxStage.allTracks).canonicalString(),
        '{"stage":"allTracks","index":0}',
      );
      expect(
        const FxAddress(stage: FxStage.output, index: 1).canonicalString(),
        '{"stage":"output","index":1}',
      );
      // Byte-stable: equal addresses always encode identically, so string
      // equality is target identity.
      expect(
        loop.canonicalString(),
        const FxAddress(
          stage: FxStage.loop,
          index: 1,
          lane: 2,
        ).canonicalString(),
      );
    });

    test('absent lane is omitted, never null-valued', () {
      const input = FxAddress(stage: FxStage.input);
      expect(input.toJson().containsKey('lane'), isFalse);
      expect(input.canonicalString(), isNot(contains('lane')));
    });

    test('unknown keys are ignored on decode (additive-only contract)', () {
      final decoded = FxAddress.fromJson(const {
        'stage': 'track',
        'index': 4,
        'futureKey': 'ignored',
      });
      expect(decoded, const FxAddress(stage: FxStage.track, index: 4));
    });

    test('unknown or missing stage decodes to null, as does bad JSON', () {
      expect(FxAddress.fromJson(const {'stage': 'sidechain'}), isNull);
      // The retired four-stage `master` among them: a binding saved against
      // it goes inert rather than retargeting itself at a destination its
      // author never chose.
      expect(FxAddress.fromJson(const {'stage': 'master'}), isNull);
      expect(FxAddress.fromJson(const {'index': 1}), isNull);
      expect(FxAddress.tryParse('not json'), isNull);
      expect(FxAddress.tryParse('[1,2]'), isNull);
    });

    test('wrong-TYPED fields never throw — corrupt persisted bindings decode '
        'to null or safe defaults, not a TypeError', () {
      // The corrupt shapes parts 6/7 can feed across package boundaries.
      expect(FxAddress.tryParse('{"stage":3,"index":0}'), isNull);
      expect(FxAddress.fromJson(const {'stage': 3}), isNull);
      expect(
        FxAddress.fromJson(const {'stage': 'track', 'index': 'four'}),
        const FxAddress(stage: FxStage.track),
      );
      expect(
        FxAddress.fromJson(const {'stage': 'loop', 'index': 1, 'lane': 'x'}),
        const FxAddress(stage: FxStage.loop, index: 1),
      );
    });

    test('equality and props cover stage, index, and lane', () {
      const a = FxAddress(stage: FxStage.loop, lane: 1);
      expect(a, const FxAddress(stage: FxStage.loop, lane: 1));
      expect(a, isNot(const FxAddress(stage: FxStage.loop, lane: 0)));
      expect(a, isNot(const FxAddress(stage: FxStage.loop, index: 1, lane: 1)));
      expect(
        a,
        isNot(const FxAddress(stage: FxStage.track, lane: 1)),
      );
    });

    test('copyWith replaces the given fields', () {
      const a = FxAddress(stage: FxStage.loop, lane: 1);
      expect(
        a.copyWith(index: 2),
        const FxAddress(stage: FxStage.loop, index: 2, lane: 1),
      );
      expect(
        a.copyWith(stage: FxStage.track),
        const FxAddress(stage: FxStage.track, lane: 1),
      );
    });
  });
}
