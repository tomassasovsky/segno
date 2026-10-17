import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalPowerSupply', () {
    const stale = PedalPowerSupply(
      profile: PedalPowerProfile.matches,
      millivolts: 20000,
      milliamps: 3000,
      maxMilliamps: 4700,
    );

    test('watts', () {
      expect(stale.watts, 60);
      expect(stale.copyWithAmps(4700).watts, closeTo(94, 1e-9));
    });

    test(
      'a contract under the offer needs a power cycle once the profile is in',
      () {
        expect(stale.needsPowerCycle, isTrue);
        expect(
          const PedalPowerSupply(
            profile: PedalPowerProfile.written,
            millivolts: 20000,
            milliamps: 3000,
            maxMilliamps: 4700,
          ).needsPowerCycle,
          isTrue,
        );
        expect(stale.copyWithAmps(4700).needsPowerCycle, isFalse);
      },
    );

    test('nothing to ask without the profile or without a contract', () {
      for (final profile in [
        PedalPowerProfile.notRead,
        PedalPowerProfile.writeFailed,
      ]) {
        expect(
          PedalPowerSupply(
            profile: profile,
            millivolts: 20000,
            milliamps: 3000,
            maxMilliamps: 4700,
          ).needsPowerCycle,
          isFalse,
        );
      }
      const none = PedalPowerSupply(profile: PedalPowerProfile.matches);
      expect(none.contracted, isFalse);
      expect(none.needsPowerCycle, isFalse);
    });
  });
}

extension on PedalPowerSupply {
  PedalPowerSupply copyWithAmps(int milliamps) => PedalPowerSupply(
    profile: profile,
    millivolts: millivolts,
    milliamps: milliamps,
    maxMilliamps: maxMilliamps,
    mismatch: mismatch,
  );
}
