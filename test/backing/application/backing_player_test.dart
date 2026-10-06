import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/backing/application/backing_player.dart';
import 'package:segno/backing/model/backing_state.dart';
import 'package:segno_engine/segno_engine.dart' show EngineConfig;
import 'package:session_repository/session_repository.dart';

import '../../helpers/backing_fixture.dart';

void main() {
  late BackingFixture f;
  late BackingPlayer player;

  setUp(() async {
    f = BackingFixture();
    player = f.player;
    await f.start();
  });
  tearDown(() => f.dispose());

  Future<List<BackingAsset>> prepare(List<String> names) async {
    final assets = [for (final name in names) await f.asset(name)];
    for (final asset in assets) {
      await player.addToPrepared(asset);
    }
    return assets;
  }

  List<String> order() => [for (final i in player.state.prepared) i.name];

  group('the prepared list', () {
    test('Add twice keeps one entry and selects it', () async {
      final [a, _] = await prepare(['a.wav', 'b.wav']);
      await player.addToPrepared(a);
      expect(order(), ['a.wav', 'b.wav']);
      expect(player.state.selected, a.digest);
    });

    test('Move up and down keep the selection on the moved file', () async {
      final [a, b, c] = await prepare(['a.wav', 'b.wav', 'c.wav']);
      player.select(c.digest);
      await player.moveUp(c.digest);
      expect(order(), ['a.wav', 'c.wav', 'b.wav']);
      expect(player.state.selected, c.digest);
      await player.moveUp(a.digest); // already first
      await player.moveDown(b.digest); // already last
      expect(order(), ['a.wav', 'c.wav', 'b.wav']);
      await player.moveDown(a.digest);
      expect(order(), ['c.wav', 'a.wav', 'b.wav']);
      expect(player.state.selected, c.digest);
    });

    test('Remove keeps the playing file and selects the neighbour', () async {
      final [a, b] = await prepare(['a.wav', 'b.wav']);
      player.select(a.digest);
      await player.play();
      await player.remove(a.digest);
      expect(order(), ['b.wav']);
      expect(player.state.selected, b.digest);
      expect(player.state.loaded?.digest, a.digest);
      expect(f.repository.state.playing, isTrue);
      await player.remove(b.digest);
      expect(player.state.selected, isNull);
    });
  });

  group('Play', () {
    test('loads the selection playing, then toggles Pause on it', () async {
      final [a, _] = await prepare(['a.wav', 'b.wav']);
      player.select(a.digest);
      await player.play();
      expect(player.state.loaded?.digest, a.digest);
      expect(f.repository.state.playing, isTrue);
      await player.play();
      expect(f.repository.state.transport, BackingTransport.paused);
      await player.play();
      expect(f.repository.state.playing, isTrue);
    });

    test('on another selection decodes it and switches, playing', () async {
      final [a, b] = await prepare(['a.wav', 'b.wav']);
      player.select(a.digest);
      await player.play();
      await f.advance(100);
      player.select(b.digest);
      await player.play();
      expect(player.state.loaded?.digest, b.digest);
      expect(f.repository.state.playing, isTrue);
      expect(f.repository.state.position, 0);
      expect(f.decoder.mock.live, 1); // a went back and was freed
    });

    test('a Missing item is refused with its name, nothing loaded', () async {
      const ghost = SessionBackingItem(
        digest:
            'sha256:00000000000000000000000000000000'
            '00000000000000000000000000000000',
        name: 'Evening lights.wav',
      );
      await player.recall(const SessionBacking(prepared: [ghost]));
      expect(player.state.missing, {ghost.digest});
      await player.play();
      expect(player.state.loaded, isNull);
      expect(player.state.failure?.reason, BackingFailureReason.missing);
      expect(player.state.failure?.name, 'Evening lights.wav');
      expect(f.decoder.mock.decoded, 0);
    });
  });

  group('automatic Next', () {
    test('stages the following item only while End is Next', () async {
      final [a, b, _] = await prepare(['a.wav', 'b.wav', 'c.wav']);
      player.select(a.digest);
      await player.play();
      expect(f.repository.state.staged, isNull);
      await f.settings.setEnd(BackingEnd.next);
      await pumpQueue();
      expect(f.repository.state.staged, b.digest);
      // Moving the loaded file last leaves nothing to follow: never wraps.
      await player.moveDown(a.digest);
      await player.moveDown(a.digest);
      expect(order(), ['b.wav', 'c.wav', 'a.wav']);
      expect(f.repository.state.staged, isNull);
      await f.settings.setEnd(BackingEnd.stop);
      await player.moveUp(a.digest);
      await pumpQueue();
      expect(f.repository.state.staged, isNull);
    });

    test('a Play selected decode releases the staged Next first and '
        're-stages for the new file', () async {
      final [a, b, c] = await prepare(['a.wav', 'b.wav', 'c.wav']);
      await f.settings.setEnd(BackingEnd.next);
      player.select(a.digest);
      await player.play();
      await pumpQueue();
      expect(f.repository.state.staged, b.digest);
      player.select(b.digest);
      var staged = 'unset';
      var resident = -1;
      f.decoder.beforeDecode = () async {
        f.decoder.beforeDecode = null;
        f.repository.refresh();
        staged = f.repository.state.staged ?? 'none';
        resident = f.decoder.mock.live;
      };
      await player.play();
      // While b decoded only a was resident: the stage went first.
      expect(staged, 'none');
      expect(resident, 1);
      expect(f.repository.state.loaded, b.digest);
      expect(f.repository.state.staged, c.digest);
      expect(f.decoder.mock.live, 2);
    });

    test(
      'the selection follows the file only when it was following it',
      () async {
        final [a, b, c] = await prepare(['a.wav', 'b.wav', 'c.wav']);
        await f.settings.setEnd(BackingEnd.next);
        player.select(a.digest);
        await player.play();
        await pumpQueue();
        await f.advance(300); // a ends: b continues
        expect(player.state.loaded?.digest, b.digest);
        expect(player.state.selected, b.digest);
        expect(f.repository.state.staged, c.digest);
        player.select(a.digest); // a manual selection stays put
        await f.advance(300); // b ends: c continues
        expect(player.state.loaded?.digest, c.digest);
        expect(player.state.selected, a.digest);
        // c is last: it stops at its end and does not wrap.
        await f.advance(300);
        expect(f.repository.state.transport, BackingTransport.stopped);
        expect(player.state.loaded?.digest, c.digest);
        expect(player.state.failure, isNull);
      },
    );

    test('a following item that cannot load stops and is reported', () async {
      final a = await f.asset('a.wav');
      const ghost = SessionBackingItem(
        digest:
            'sha256:11111111111111111111111111111111'
            '11111111111111111111111111111111',
        name: 'Ghost.wav',
      );
      await player.recall(
        SessionBacking(
          prepared: [
            SessionBackingItem(digest: a.digest, name: a.name),
            ghost,
          ],
          loaded: SessionBackingItem(digest: a.digest, name: a.name),
          endMode: BackingEnd.next,
        ),
      );
      await f.settings.setEnd(BackingEnd.next);
      await player.play();
      await pumpQueue();
      await f.advance(300);
      expect(f.repository.state.transport, BackingTransport.stopped);
      expect(f.repository.state.lastEnd, BackingEndEvent.nextMissing);
      expect(player.state.failure?.name, 'Ghost.wav');
      expect(player.state.failure?.reason, BackingFailureReason.missing);
    });
  });

  group('Use as backing', () {
    test(
      'prepares and loads stopped; asks first while another plays',
      () async {
        final [a] = await prepare(['a.wav']);
        final b = await f.asset('b.wav');
        expect(
          await player.useAsBacking(a),
          UseAsBackingOutcome.loaded,
        );
        expect(f.repository.state.loaded, a.digest);
        expect(f.repository.state.playing, isFalse);
        await player.play();
        expect(await player.useAsBacking(b), UseAsBackingOutcome.needsConfirm);
        expect(order(), ['a.wav']);
        expect(f.repository.state.loaded, a.digest);
        expect(
          await player.useAsBacking(b, confirmed: true),
          UseAsBackingOutcome.loaded,
        );
        expect(order(), ['a.wav', 'b.wav']);
        expect(player.state.selected, b.digest);
        expect(f.repository.state.loaded, b.digest);
        expect(f.repository.state.playing, isFalse);
      },
    );
  });

  group('an interface change (review of P5, M1)', () {
    Future<BackingAsset> loadedStopped() async {
      final a = await f.asset('a.wav', frames: 48000);
      await player.useAsBacking(a);
      expect(player.state.loaded?.digest, a.digest);
      return a;
    }

    void configureAt(int rate) => f.engine
      ..stop()
      ..start(EngineConfig(sampleRate: rate, outputChannels: 2));

    test('the restart reloads the file stopped, the player keeps it and '
        'Save keeps it', () async {
      final a = await loadedStopped();
      configureAt(44100);
      f.repository.refresh(); // what the app does when the engine restarts
      await pumpQueue();
      expect(f.engine.backingState().frames, 44100);
      expect(f.repository.state.loaded, a.digest);
      expect(f.repository.state.transport, BackingTransport.stopped);
      expect(player.state.loaded?.digest, a.digest);
      expect(player.state.loaded?.name, 'a.wav');
      expect(player.capture(f.settings.mix).loaded?.digest, a.digest);
      expect(f.decoder.mock.decoded, 2);
      await player.play();
      expect(f.repository.state.playing, isTrue);
      expect(f.decoder.mock.decoded, 2);
    });

    test('Play right after a restart nobody saw plays, first time, after '
        'one reload', () async {
      final a = await loadedStopped();
      configureAt(44100);
      await player.play();
      await pumpQueue();
      expect(f.repository.state.loaded, a.digest);
      expect(f.repository.state.playing, isTrue);
      expect(player.state.loaded?.digest, a.digest);
      expect(f.decoder.mock.decoded, 2);
    });

    test('the player follows the file the repository holds', () async {
      await loadedStopped();
      final b = await f.asset('b.wav');
      await f.repository.load(b.digest, name: 'b.wav');
      await pumpQueue();
      expect(player.state.loaded?.digest, b.digest);
      expect(player.state.loaded?.name, 'b.wav');
    });

    test('no state while it reloads says nothing is loaded', () async {
      await loadedStopped();
      final seen = <String?>[];
      final sub = player.states.listen((s) => seen.add(s.loaded?.name));
      configureAt(44100);
      f.repository.refresh();
      await pumpQueue();
      await sub.cancel();
      expect(seen, isNot(contains(isNull)));
    });
  });

  group('the Session', () {
    test('capture and recall round-trip; recall loads stopped at 0', () async {
      final [a, b] = await prepare(['a.wav', 'b.wav']);
      player.select(b.digest);
      await player.play();
      await f.advance(100);
      final saved = player.capture(f.settings.mix);
      expect(saved.prepared.map((i) => i.name), ['a.wav', 'b.wav']);
      expect(saved.loaded?.digest, b.digest);

      await player.remove(a.digest);
      player.clear();
      await player.recall(saved);
      expect(order(), ['a.wav', 'b.wav']);
      expect(player.state.loaded?.digest, b.digest);
      expect(player.state.selected, b.digest);
      expect(f.repository.state.loaded, b.digest);
      expect(f.repository.state.transport, BackingTransport.stopped);
      expect(f.repository.state.position, 0);
      expect(player.capture(f.settings.mix), saved);
    });

    test('a recalled id with no file stays listed as Missing', () async {
      final a = await f.asset('a.wav');
      const ghost = SessionBackingItem(
        digest:
            'sha256:22222222222222222222222222222222'
            '22222222222222222222222222222222',
        name: 'Ghost.wav',
      );
      await player.recall(
        SessionBacking(
          prepared: [
            ghost,
            SessionBackingItem(digest: a.digest, name: 'a.wav'),
          ],
          loaded: ghost,
        ),
      );
      expect(order(), ['Ghost.wav', 'a.wav']);
      expect(player.state.missing, {ghost.digest});
      expect(f.repository.state.loaded, isNull);
      expect(player.state.failure?.name, 'Ghost.wav');
      // Still named, and the next Save keeps it (review of P5, L1).
      expect(player.state.loaded, ghost.toItem);
      expect(player.capture(f.settings.mix).loaded, ghost);
      // Never matched by name: a file called Ghost.wav is another asset.
      final named = await f.asset('Ghost.wav');
      expect(named.digest, isNot(ghost.digest));
    });

    test('recalling the file already loaded stops it at 0', () async {
      final [a] = await prepare(['a.wav']);
      player.select(a.digest);
      await player.play();
      await f.advance(100);
      final decodes = f.decoder.mock.decoded;
      await player.recall(player.capture(f.settings.mix));
      expect(f.repository.state.loaded, a.digest);
      expect(f.repository.state.transport, BackingTransport.stopped);
      expect(f.repository.state.position, 0);
      expect(f.decoder.mock.decoded, decodes); // kept, not decoded again
    });

    test('recalling an empty setup stops and unloads', () async {
      final [a] = await prepare(['a.wav']);
      player.select(a.digest);
      await player.play();
      await player.recall(const SessionBacking());
      expect(player.state.prepared, isEmpty);
      expect(player.state.loaded, isNull);
      expect(f.repository.state.loaded, isNull);
    });
  });

  test('stop stops and rewinds; clear unloads and keeps the list', () async {
    final [a] = await prepare(['a.wav']);
    player.select(a.digest);
    await player.play();
    await f.advance(50);
    player.stop();
    expect(f.repository.state.transport, BackingTransport.stopped);
    expect(f.repository.state.position, 0);
    player.clear();
    expect(player.state.loaded, isNull);
    expect(order(), ['a.wav']);
  });
}

extension on SessionBackingItem {
  BackingItem get toItem => BackingItem(digest: digest, name: name);
}
