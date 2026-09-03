import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/pedal/pedal.dart';

import '../helpers/fake_pedal_link.dart';

/// The pedal LINK tests: the board's status and firmware version, mirrored
/// for the settings UI. The pedal's BEHAVIOR (footswitch decode, LED frames)
/// is `ControlCubit`'s and is covered by test/control/control_cubit_test.dart.
void main() {
  group('PedalCubit', () {
    late FakePedalLink link;
    late PedalRepository pedal;

    setUp(() {
      link = FakePedalLink();
      pedal = PedalRepository(link);
    });

    test('starts disconnected with no firmware version', () async {
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state, const PedalState());
      await cubit.close();
    });

    test('mirrors the board hello as connected + firmware version', () async {
      final cubit = PedalCubit(pedal: pedal);
      link.hello(firmwareMinor: 2);
      await pumpEventQueue();
      expect(cubit.state.status, PedalLinkStatus.connected);
      expect(cubit.state.firmwareVersion, '1.2');
      await cubit.close();
    });

    test('seeds from a repository that is already connected', () async {
      link.hello();
      await pumpEventQueue();
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state.status, PedalLinkStatus.connected);
      expect(cubit.state.firmwareVersion, '1.0');
      await cubit.close();
    });

    test('close sends a goodbye frame and releases the link', () async {
      final cubit = PedalCubit(pedal: pedal);
      await cubit.close();
      expect(link.lastFrame?.isGoodbye, isTrue);
      expect(link.disposed, isTrue);
    });
  });
}
