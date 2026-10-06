import 'dart:async';
import 'dart:io';

import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

import 'helpers/fakes.dart';

const _at48 = EngineConfig(sampleRate: 48000, outputChannels: 2);

void main() {
  late Directory temp;
  late ContentDecoder decoder;
  late BackingAssetStore store;
  late MockAudioEngine inner;
  late NotReadyEngine engine;
  late BackingRepository repo;
  late List<BackingFailure> failures;
  late List<BackingNotice> notices;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('backing_repo');
    final root = '${temp.path}/exports';
    decoder = ContentDecoder();
    store = BackingAssetStore(
      root: () async => root,
      decoder: decoder,
      copier: FakeCopier(root).call,
      digester: fakeDigest,
      syncDirectory: (_) {},
    );
    inner = MockAudioEngine()..start(_at48);
    engine = NotReadyEngine(inner);
    repo = BackingRepository(
      engine: engine,
      metering: inner,
      decoder: decoder,
      store: store,
      pollInterval: const Duration(milliseconds: 5),
      retryDelay: const Duration(milliseconds: 1),
    );
    failures = [];
    notices = [];
    repo.failures.listen(failures.add);
    repo.notices.listen(notices.add);
  });
  tearDown(() async {
    await repo.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<BackingAsset> asset(String name, {int frames = 300}) => store.import(
    writeAudio(temp, 'src/$name', frames: frames, tag: name),
    name: name,
  );

  test(
    'load decodes at the engine rate, plays, and maps the token back',
    () async {
      final a = await asset('a.wav');
      final states = <BackingPlayerState>[];
      repo.states.listen(states.add);
      expect(await repo.load(a.digest, play: true), isTrue);
      expect(states.first.loading, a.digest);
      final s = repo.state;
      expect(s.loaded, a.digest);
      expect(s.loading, isNull);
      expect(s.playing, isTrue);
      expect(s.frames, 300);
      expect(s.sampleRate, 48000);
      expect(s.length, const Duration(microseconds: 6250));
      expect(decoder.mock.live, 1);
    },
  );

  test('the old file plays on until the new one has decoded', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav');
    await repo.load(a.digest, play: true);
    final gate = Completer<void>();
    decoder.beforeDecode = () => gate.future;
    final pending = repo.load(b.digest, play: true);
    await Future<void>.delayed(Duration.zero);
    expect(repo.state.loaded, a.digest);
    expect(repo.state.loading, b.digest);
    gate.complete();
    expect(await pending, isTrue);
    expect(repo.state.loaded, b.digest);
    expect(decoder.mock.live, 1); // a went back and was freed
  });

  test('Stop cancels a pending load: its result is freed, the old file '
      'stays, stopped', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav');
    await repo.load(a.digest, play: true);
    final gate = Completer<void>();
    decoder.beforeDecode = () => gate.future;
    final pending = repo.load(b.digest, play: true);
    await Future<void>.delayed(Duration.zero);
    repo.stop();
    gate.complete();
    expect(await pending, isFalse);
    expect(repo.state.loaded, a.digest);
    expect(repo.state.loading, isNull);
    expect(repo.state.transport, BackingTransport.stopped);
    expect(decoder.mock.live, 1);
    expect(failures, isEmpty);
  });

  test('a later load supersedes an earlier one still decoding', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav');
    final gate = Completer<void>();
    decoder.beforeDecode = () => gate.future;
    final first = repo.load(a.digest);
    decoder.beforeDecode = null;
    expect(await repo.load(b.digest), isTrue);
    gate.complete();
    expect(await first, isFalse);
    expect(repo.state.loaded, b.digest);
    expect(decoder.mock.live, 1);
  });

  test('NOT_READY is retried once, then reported busy', () async {
    final a = await asset('a.wav');
    engine.notReadyCount = 1;
    expect(await repo.load(a.digest), isTrue);
    expect(engine.handoffs, 2);
    expect(repo.state.loaded, a.digest);

    final b = await asset('b.wav');
    engine.notReadyCount = 2;
    expect(await repo.load(b.digest), isFalse);
    expect(failures.single.reason, BackingFailureReason.busy);
    expect(failures.single.name, 'b.wav');
    expect(repo.state.loaded, a.digest);
    expect(decoder.mock.live, 1);
  });

  test('an engine refusal is reported and frees the decode', () async {
    final a = await asset('a.wav');
    engine.refuseWith = EngineResult.capacity;
    expect(await repo.load(a.digest), isFalse);
    expect(failures.single.reason, BackingFailureReason.noMemory);
    expect(decoder.mock.live, 0);
    engine.refuseWith = EngineResult.notRunning;
    expect(await repo.stageNext(a.digest), isFalse);
    expect(failures.last.reason, BackingFailureReason.notRunning);
  });

  test('a missing or damaged asset is reported, nothing decoded', () async {
    expect(await repo.load('sha256:${'0' * 64}', name: 'gone.wav'), isFalse);
    expect(failures.single.reason, BackingFailureReason.missing);
    expect(failures.single.name, 'gone.wav');
    final a = await asset('a.wav');
    File(a.path).writeAsStringSync('rate=48000;frames=9');
    expect(await repo.load(a.digest), isFalse);
    expect(failures.last.reason, BackingFailureReason.damaged);
    expect(decoder.mock.decoded, 0);
  });

  test('a decoder refusal is reported by its reason', () async {
    final a = await asset('a.wav');
    decoder.beforeDecode = () async =>
        decoder.mock.files[a.path] = const MockAudioFile.refused(
          EngineResult.tooLong,
        );
    // ContentDecoder registers from the file before the hook runs, so the
    // hook's refusal is what the decode meets.
    expect(await repo.load(a.digest), isFalse);
    expect(failures.single.reason, BackingFailureReason.tooLong);
  });

  test('End = Next: the staged file becomes the loaded one', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav', frames: 200);
    repo.setEnd(BackingEnd.next);
    await repo.load(a.digest, play: true);
    expect(await repo.stageNext(b.digest), isTrue);
    expect(repo.state.staged, b.digest);
    inner.advanceBacking(350);
    repo.refresh();
    expect(repo.state.loaded, b.digest);
    expect(repo.state.staged, isNull);
    expect(repo.state.position, 50);
    expect(repo.state.lastEnd, BackingEndEvent.advanced);
    expect(await repo.stageNext(null), isTrue);
    expect(decoder.mock.live, 1);
  });

  test('transport, seek, mix and clear reach the engine', () async {
    final a = await asset('a.wav', frames: 48000);
    await repo.load(a.digest);
    repo
      ..seek(const Duration(milliseconds: 500))
      ..play();
    expect(repo.state.position, 24000);
    expect(repo.state.positionTime, const Duration(milliseconds: 500));
    repo.pause();
    expect(repo.state.transport, BackingTransport.paused);
    repo
      ..setLevel(0.5)
      ..setPan(-0.5)
      ..setOutput(3);
    expect(repo.state.level, 0.5);
    expect(repo.state.pan, -0.5);
    expect(repo.state.outputMask, 3);
    repo.clear();
    expect(repo.state.loaded, isNull);
    expect(decoder.mock.live, 0);
  });

  test('a configure: settings replayed, the file decoded again at the new '
      'rate, stopped, and the performer told', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav');
    repo
      ..setEnd(BackingEnd.repeat)
      ..setLevel(0.25)
      ..setPan(0.5)
      ..setOutput(12);
    await repo.load(a.digest, play: true);
    await repo.stageNext(b.digest);
    engine.settings.clear();
    final decodes = decoder.mock.decoded;
    inner
      ..stop()
      ..start(const EngineConfig(sampleRate: 96000, outputChannels: 2));
    expect(decoder.mock.live, 0); // the configure freed both
    repo.refresh();
    await pumpEventQueue();
    expect(engine.settings, [
      'end repeat',
      'level 0.25',
      'pan 0.5',
      'output 12',
    ]);
    expect(notices, [BackingNotice.interfaceChanged]);
    expect(decoder.mock.decoded, decodes + 2);
    expect(repo.state.loaded, a.digest);
    expect(repo.state.staged, b.digest);
    expect(repo.state.frames, 600); // 300 at 48 kHz is 600 at 96 kHz
    expect(repo.state.transport, BackingTransport.stopped);
  });

  test('a retained reopen keeps the file and only tells', () async {
    final a = await asset('a.wav');
    await repo.load(a.digest, play: true);
    final decodes = decoder.mock.decoded;
    inner.backingTransport(BackingTransportOp.stop);
    engine.extraEpoch++;
    repo.refresh();
    await pumpEventQueue();
    expect(notices, [BackingNotice.interfaceChanged]);
    expect(decoder.mock.decoded, decodes);
    expect(repo.state.loaded, a.digest);
  });

  test('a restart while stopped says nothing', () async {
    final a = await asset('a.wav');
    await repo.load(a.digest);
    engine.extraEpoch++;
    repo.refresh();
    await pumpEventQueue();
    expect(notices, isEmpty);
  });

  test(
    'a decode that finishes after the rate changed is decoded again',
    () async {
      final a = await asset('a.wav');
      var restarted = false;
      decoder.beforeDecode = () async {
        if (restarted) return;
        restarted = true;
        inner
          ..stop()
          ..start(const EngineConfig(sampleRate: 96000, outputChannels: 2));
      };
      expect(await repo.load(a.digest), isTrue);
      expect(decoder.mock.decoded, 2);
      expect(decoder.mock.live, 1);
      expect(repo.state.frames, 600);
    },
  );

  test('a rate that keeps changing gives up as busy', () async {
    final a = await asset('a.wav');
    var rate = 48000;
    decoder.beforeDecode = () async {
      rate = rate == 48000 ? 96000 : 48000;
      inner
        ..stop()
        ..start(EngineConfig(sampleRate: rate, outputChannels: 2));
    };
    expect(await repo.load(a.digest), isFalse);
    expect(failures.single.reason, BackingFailureReason.busy);
    expect(decoder.mock.live, 0);
  });

  test('playing, the state follows the engine on its own', () async {
    final a = await asset('a.wav', frames: 48000);
    await repo.load(a.digest, play: true);
    inner.advanceBacking(1000);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repo.state.position, 1000);
    repo.stop();
    inner.advanceBacking(10);
    expect(repo.state.position, 0);
  });

  test('many loads keep mapping the current token to its asset', () async {
    final a = await asset('a.wav');
    final b = await asset('b.wav');
    for (var i = 0; i < 20; i++) {
      await repo.load(i.isEven ? a.digest : b.digest);
    }
    expect(repo.state.loaded, b.digest);
    expect(decoder.mock.live, 1);
  });

  test(
    'a load still decoding when the repository goes frees its result',
    () async {
      final a = await asset('a.wav');
      final gate = Completer<void>();
      decoder.beforeDecode = () => gate.future;
      final pending = repo.load(a.digest);
      await Future<void>.delayed(Duration.zero);
      await repo.dispose();
      gate.complete();
      expect(await pending, isFalse);
      expect(decoder.mock.live, 0);
      repo.refresh(); // a no-op once disposed
    },
  );
}
