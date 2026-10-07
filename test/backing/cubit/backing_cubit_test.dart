import 'package:flutter_test/flutter_test.dart';
import 'package:segno/backing/cubit/backing_cubit.dart';

import '../../helpers/backing_fixture.dart';

void main() {
  group(BackingCubit, () {
    late BackingFixture f;
    late BackingCubit cubit;
    setUp(() async {
      f = BackingFixture();
      await f.start();
      cubit = BackingCubit(player: f.player);
    });
    tearDown(() async {
      await cubit.close();
      await f.dispose();
    });

    test('presents the player and drives it', () async {
      final a = await f.asset('a.wav');
      final b = await f.asset('b.wav');
      cubit
        ..addToPrepared(a)
        ..addToPrepared(b);
      await pumpQueue();
      expect(cubit.state.backing.prepared.map((i) => i.name), [
        'a.wav',
        'b.wav',
      ]);
      cubit
        ..moveUp(b.digest)
        ..select(a.digest)
        ..play();
      await pumpQueue();
      expect(cubit.state.backing.loaded?.digest, a.digest);
      expect(cubit.state.backing.player.playing, isTrue);
      cubit.pause();
      expect(cubit.state.backing.player.playing, isFalse);
      cubit
        ..seek(const Duration(milliseconds: 2))
        ..stop()
        ..remove(b.digest);
      await pumpQueue();
      expect(cubit.state.backing.prepared.map((i) => i.name), ['a.wav']);
      cubit.clear();
      expect(cubit.state.backing.loaded, isNull);
    });

    test('Use as backing waits for a confirmation while another file '
        'plays', () async {
      final a = await f.asset('a.wav');
      final b = await f.asset('b.wav');
      await f.player.useAsBacking(a);
      await f.player.play();
      cubit.useAsBacking(b);
      await pumpQueue();
      expect(cubit.state.confirmUse, b);
      cubit.cancelUse();
      expect(cubit.state.confirmUse, isNull);
      expect(f.repository.state.loaded, a.digest);
      cubit.useAsBacking(b);
      await pumpQueue();
      cubit.confirmUse();
      await pumpQueue();
      expect(cubit.state.confirmUse, isNull);
      expect(f.repository.state.loaded, b.digest);
    });
  });
}
