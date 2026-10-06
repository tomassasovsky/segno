import 'dart:convert';
import 'dart:io';

import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

void main() {
  late Directory temp;
  late String root;
  late FakeCopier copier;
  late ContentDecoder decoder;
  late List<String> synced;
  late BackingAssetStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('backing_store');
    root = '${temp.path}/exports';
    Directory(root).createSync();
    copier = FakeCopier(root);
    decoder = ContentDecoder();
    synced = [];
    store = BackingAssetStore(
      root: () async => root,
      decoder: decoder,
      copier: copier.call,
      digester: fakeDigest,
      syncDirectory: synced.add,
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Directory storeDir() => Directory('$root/${BackingAssetStore.folder}');

  Matcher failure(BackingFailureReason reason) =>
      isA<BackingFailure>().having((f) => f.reason, 'reason', reason);

  group('import', () {
    test('copies, probes and publishes the asset durably', () async {
      final source = writeAudio(temp, 'usb/Evening lights.wav', frames: 4800);
      final asset = await store.import(source);
      final hex = await fakeDigest(source);
      expect(asset.digest, 'sha256:$hex');
      expect(asset.id, hex!.substring(0, 16));
      expect(asset.name, 'Evening lights.wav');
      expect(
        asset.path,
        '${storeDir().path}/${asset.id}/Evening lights.wav',
      );
      expect(asset.sourceRate, 48000);
      expect(asset.sourceFrames, 4800);
      expect(asset.sourceChannels, 2);
      expect(asset.seconds, 0.1);
      expect(asset.peaks, hasLength(512));
      expect(asset.available, isTrue);
      expect(copier.calls, ['Backing tracks/${asset.id}/Evening lights.wav']);
      // The copy keeps nothing in memory: the probe decodes, nothing stays.
      expect(decoder.probes, 1);
      expect(decoder.mock.live, 0);
      // info.json renamed into place, the asset and the store synced.
      final info =
          jsonDecode(
                File(
                  '${storeDir().path}/${asset.id}/info.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(info['digest'], asset.digest);
      expect(info['sourceFrames'], 4800);
      expect(
        File('${storeDir().path}/${asset.id}/info.json.part').existsSync(),
        isFalse,
      );
      expect(synced, ['${storeDir().path}/${asset.id}', storeDir().path]);
      expect(await store.list(), [asset]);
    });

    test('the same bytes again reuse the copy', () async {
      final source = writeAudio(temp, 'a.wav');
      final first = await store.import(source);
      final again = await store.import(
        writeAudio(temp, 'elsewhere/a copy.wav'),
        name: 'renamed.wav',
      );
      expect(again, first);
      expect(copier.calls, hasLength(1));
    });

    test('one name, other bytes: two assets', () async {
      final a = await store.import(writeAudio(temp, 'x/song.wav', tag: '1'));
      final b = await store.import(writeAudio(temp, 'y/song.wav', tag: '2'));
      expect(a.digest, isNot(b.digest));
      expect(await store.list(), hasLength(2));
    });

    test('a file that does not decode leaves nothing', () async {
      await expectLater(
        store.import(writeAudio(temp, 'bad.wav', fail: 'invalid')),
        throwsA(failure(BackingFailureReason.damaged)),
      );
      await expectLater(
        store.import(writeAudio(temp, 'notes.txt', fail: 'invalid')),
        throwsA(failure(BackingFailureReason.unsupported)),
      );
      await expectLater(
        store.import(writeAudio(temp, 'long.mp3', fail: 'tooLong')),
        throwsA(failure(BackingFailureReason.tooLong)),
      );
      expect(storeDir().listSync(), isEmpty);
      expect(await store.list(), isEmpty);
    });

    test('a failed copy leaves nothing and says storage', () async {
      copier.failWith = const FileSystemException('disk full');
      await expectLater(
        store.import(writeAudio(temp, 'a.wav')),
        throwsA(failure(BackingFailureReason.storage)),
      );
      expect(
        storeDir().existsSync() ? storeDir().listSync() : <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('a copy whose bytes differ from the source is refused', () async {
      copier.corruptTo = utf8.encode('rate=48000;frames=100;tag=other');
      await expectLater(
        store.import(writeAudio(temp, 'a.wav')),
        throwsA(failure(BackingFailureReason.damaged)),
      );
      expect(storeDir().listSync(), isEmpty);
    });

    test('an unreadable source is missing', () async {
      await expectLater(
        store.import('${temp.path}/absent.wav'),
        throwsA(failure(BackingFailureReason.missing)),
      );
      expect(copier.calls, isEmpty);
    });

    test('a broken earlier copy is replaced', () async {
      final source = writeAudio(temp, 'a.wav');
      final first = await store.import(source);
      File('${storeDir().path}/${first.id}/info.json').deleteSync();
      final again = await store.import(source);
      expect(again.available, isTrue);
      expect(copier.calls, hasLength(2));
    });
  });

  group('list', () {
    test('an empty or absent store lists nothing', () async {
      expect(await store.list(), isEmpty);
      storeDir().createSync();
      expect(await store.list(), isEmpty);
    });

    test('marks what cannot be trusted, ignores what is not ours', () async {
      final ok = await store.import(writeAudio(temp, 'b ok.wav', tag: 'ok'));
      final gone = await store.import(writeAudio(temp, 'c gone.wav', tag: 'g'));
      File(gone.path).deleteSync();
      final broken = await store.import(writeAudio(temp, 'a broken.wav'));
      File('${storeDir().path}/${broken.id}/info.json').writeAsStringSync('{');
      Directory('${storeDir().path}/not-an-id').createSync();
      Directory('${storeDir().path}/0000000000000000').createSync();
      File('${storeDir().path}/stray.txt').writeAsStringSync('x');

      final listed = await store.list();
      expect(listed.map((a) => a.name), [
        'a broken.wav',
        'b ok.wav',
        'c gone.wav',
      ]);
      expect(listed[0].problem, BackingFailureReason.damaged);
      expect(listed[0].digest, startsWith('sha256:${broken.id}'));
      expect(listed[1], ok);
      expect(listed[2].problem, BackingFailureReason.missing);
    });
  });

  group('resolve', () {
    test('returns the asset whose bytes still match', () async {
      final asset = await store.import(writeAudio(temp, 'a.wav'));
      expect(await store.resolve(asset.digest), asset);
    });

    test('a malformed or unknown digest is missing', () async {
      await expectLater(
        store.resolve('a.wav'),
        throwsA(failure(BackingFailureReason.missing)),
      );
      await expectLater(
        store.resolve('sha256:${'a' * 64}', name: 'Evening lights.wav'),
        throwsA(
          isA<BackingFailure>()
              .having((f) => f.reason, 'reason', BackingFailureReason.missing)
              .having((f) => f.name, 'name', 'Evening lights.wav'),
        ),
      );
    });

    test('changed bytes are damaged; a removed file is missing', () async {
      final asset = await store.import(writeAudio(temp, 'a.wav'));
      File(asset.path).writeAsStringSync('rate=48000;frames=7');
      await expectLater(
        store.resolve(asset.digest),
        throwsA(failure(BackingFailureReason.damaged)),
      );
      File(asset.path).deleteSync();
      await expectLater(
        store.resolve(asset.digest),
        throwsA(failure(BackingFailureReason.missing)),
      );
    });

    test('an asset whose directory names another digest is missing', () async {
      final asset = await store.import(writeAudio(temp, 'a.wav'));
      final other = 'sha256:${asset.id}${'f' * 48}';
      await expectLater(
        store.resolve(other),
        throwsA(failure(BackingFailureReason.missing)),
      );
    });
  });

  test('BackingAsset digests and ids', () {
    const digest =
        'sha256:0123456789abcdef0123456789abcdef'
        '0123456789abcdef0123456789abcdef';
    expect(BackingAsset.isDigest(digest), isTrue);
    expect(BackingAsset.isDigest('sha256:XYZ'), isFalse);
    expect(BackingAsset.idOf(digest), '0123456789abcdef');
    expect(
      const BackingAsset(digest: digest, name: 'a', path: 'p').seconds,
      0,
    );
    const failure = BackingFailure(
      BackingFailureReason.storage,
      name: 'a.wav',
    );
    expect(
      failure,
      const BackingFailure(BackingFailureReason.storage, name: 'a.wav'),
    );
    expect(failure.toString(), contains('storage'));
  });
}
