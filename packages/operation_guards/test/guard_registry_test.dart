import 'package:operation_guards/operation_guards.dart';
import 'package:test/test.dart';

/// The D8 table of the recording-recovery plan, with one change from the
/// Library's review (#1178 Part 7, finding 1): a sessionWrite is refused
/// over a transfer of the same item. Transcribed:
/// rows want to commit, columns are active, in the order capture,
/// sessionApply, sessionWrite, transfer, eject, deviceChange, calibration,
/// restart. a = allow, r = refuse, v = refuse on the same volume,
/// i = refuse on the same item.
const Map<GuardKind, String> _d8 = {
  GuardKind.capture: 'r r a v v r r r',
  GuardKind.sessionApply: 'a r r a a r r r',
  GuardKind.sessionWrite: 'a a i i a a a r',
  GuardKind.transfer: 'v a a a v a a r',
  GuardKind.eject: 'v a a v r a a r',
  GuardKind.deviceChange: 'r r a a a r r r',
  GuardKind.calibration: 'r r a a a r r r',
  GuardKind.restart: 'r r r r r r a r',
};

class _Source implements ActiveOperationSource {
  final List<ActiveOperation> ops = [];

  @override
  Iterable<ActiveOperation> get activeOperations => ops;
}

void main() {
  const internal = GuardScope.internal();
  const usb1 = GuardScope.removable(1);
  const usb2 = GuardScope.removable(2);

  group('GuardRegistry table', () {
    for (final wants in GuardKind.values) {
      for (final active in GuardKind.values) {
        final letter = _d8[wants]!.split(' ')[active.index];
        test('$wants while $active is active: $letter', () {
          bool refused(GuardScope a, GuardScope b) {
            final registry = GuardRegistry()..enter(active, a, purpose: 'x');
            try {
              registry.enter(wants, b, purpose: 'y').release();
              return false;
            } on GuardRefused catch (e) {
              expect(e.wants, wants);
              expect(e.blockers.single.kind, active);
              expect(e.blockers.single.purpose, 'x');
              return true;
            }
          }

          const bundleA = GuardScope.internal(item: '/s/a');
          const bundleB = GuardScope.internal(item: '/s/b');
          final sameVolume = refused(usb1, usb1);
          final otherVolume = refused(usb1, usb2);
          final sameItem = refused(bundleA, bundleA);
          final otherItem = refused(bundleA, bundleB);
          switch (letter) {
            case 'a':
              expect(
                [sameVolume, otherVolume, sameItem, otherItem],
                [
                  false,
                  false,
                  false,
                  false,
                ],
              );
            case 'r':
              expect(
                [sameVolume, otherVolume, sameItem, otherItem],
                [
                  true,
                  true,
                  true,
                  true,
                ],
              );
            case 'v':
              expect(
                [sameVolume, otherVolume, sameItem, otherItem],
                [
                  true,
                  false,
                  true,
                  true,
                ],
              );
            case 'i':
              expect(
                [sameVolume, otherVolume, sameItem, otherItem],
                [
                  true,
                  false,
                  true,
                  false,
                ],
              );
            default:
              fail('unknown rule $letter');
          }
          expect(
            GuardRegistry.ruleFor(wants, active),
            {
              'a': GuardRule.allow,
              'r': GuardRule.refuse,
              'v': GuardRule.refuseSameVolume,
              'i': GuardRule.refuseSameItem,
            }[letter],
          );
        });
      }
    }
  });

  group('GuardRegistry', () {
    test('a released guard no longer blocks, and release is idempotent', () {
      final registry = GuardRegistry();
      final take = registry.enter(
        GuardKind.capture,
        internal,
        purpose: 'recording',
      );
      expect(take.isHeld, isTrue);
      expect(take.operation.purpose, 'recording');
      expect(registry.active, [take.operation]);
      expect(
        () => registry.enter(GuardKind.deviceChange, internal, purpose: 'x'),
        throwsA(isA<GuardRefused>()),
      );
      take.release();
      expect(take.isHeld, isFalse);
      expect(registry.active, isEmpty);
      take.release();
      registry.enter(GuardKind.deviceChange, internal, purpose: 'x').release();
    });

    test('two guards of the same kind are two operations', () {
      final registry = GuardRegistry();
      final a = registry.enter(GuardKind.transfer, usb1, purpose: 'export');
      final b = registry.enter(GuardKind.transfer, usb1, purpose: 'export');
      a.release();
      expect(registry.blockers(GuardKind.eject, usb1), [b.operation]);
      b.release();
      expect(registry.blockers(GuardKind.eject, usb1), isEmpty);
    });

    test('a refused enter registers nothing', () {
      final registry = GuardRegistry()
        ..enter(GuardKind.restart, internal, purpose: 'power off');
      expect(
        () => registry.enter(GuardKind.capture, internal, purpose: 'take'),
        throwsA(isA<GuardRefused>()),
      );
      expect(registry.active.map((o) => o.kind), [GuardKind.restart]);
    });

    test('blockers lists every active operation that refuses', () {
      final registry = GuardRegistry();
      final export = registry.enter(
        GuardKind.transfer,
        usb1,
        purpose: 'Exporting Take 1',
      );
      final backup = registry.enter(
        GuardKind.transfer,
        usb1,
        purpose: 'Backing up Evening loop',
      );
      registry.enter(GuardKind.transfer, usb2, purpose: 'other drive');
      expect(registry.blockers(GuardKind.eject, usb1), [
        export.operation,
        backup.operation,
      ]);
      expect(registry.blockers(GuardKind.capture, internal), isEmpty);
    });

    test('reports operations an owner tracks itself', () {
      final storage = _Source();
      final registry = GuardRegistry(sources: [storage]);
      const lease = ActiveOperation(
        kind: GuardKind.transfer,
        scope: usb1,
        purpose: 'Exporting Take 1',
      );
      storage.ops.add(lease);
      expect(registry.active, [lease]);
      final refusal = () {
        try {
          registry.enter(GuardKind.eject, usb1, purpose: 'eject');
        } on GuardRefused catch (e) {
          return e;
        }
        return null;
      }();
      expect(refusal?.blockers, [lease]);
      expect(refusal.toString(), contains('Exporting Take 1'));
      storage.ops.clear();
      registry.enter(GuardKind.eject, usb1, purpose: 'eject').release();
    });
  });

  group('GuardScope', () {
    test('compares by volume and item', () {
      expect(const GuardScope.internal(), internal);
      expect(internal.hashCode, const GuardScope.internal().hashCode);
      expect(usb1 == usb2, isFalse);
      expect(internal.sameVolume(usb1), isFalse);
      expect(
        const GuardScope.removable(1, item: 'a').sameItem(usb1),
        isTrue,
      );
      expect(
        const GuardScope.removable(1, item: 'a').sameItem(
          const GuardScope.removable(2, item: 'a'),
        ),
        isFalse,
      );
      expect(internal.toString(), contains('internal'));
      expect(usb1.toString(), contains('removable(1'));
    });

    test('ActiveOperation compares by value', () {
      const a = ActiveOperation(
        kind: GuardKind.capture,
        scope: internal,
        purpose: 'p',
      );
      expect(
        a,
        const ActiveOperation(
          kind: GuardKind.capture,
          scope: GuardScope.internal(),
          purpose: 'p',
        ),
      );
      expect(a.hashCode, isNot(0));
      expect(a.toString(), contains('capture'));
    });
  });
}
