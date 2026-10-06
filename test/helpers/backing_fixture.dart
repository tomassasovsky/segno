import 'dart:async';
import 'dart:io';

import 'package:backing_repository/backing_repository.dart';
import 'package:looper_repository/looper_repository.dart' show LooperRepository;
import 'package:segno/backing/application/backing_player.dart';
import 'package:segno/looper/application/backing_settings.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:settings_repository/settings_repository.dart';

import 'fake_audio_engine.dart';
import 'fake_key_value_store.dart';

/// A test digest: 64 hex digits from eight 32-bit FNV-1a runs. Not SHA-256,
/// but equal bytes give equal digests, which is all the store relies on.
Future<String?> fakeBackingDigest(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  final out = StringBuffer();
  for (var seed = 0; seed < 8; seed++) {
    var h = 0x811c9dc5 ^ seed;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    out.write(h.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}

/// A decoder that learns each file from its contents, `frames=N;tag`,
/// so a managed copy decodes like its source.
class ContentAudioDecoder implements AudioDecoder {
  /// The decoder doing the work and counting buffers.
  final MockAudioDecoder mock = MockAudioDecoder();

  /// Runs before each decode completes (a test seam for what happens while
  /// a decode is in flight).
  Future<void> Function()? beforeDecode;

  void _learn(String path) {
    final file = File(path);
    if (!file.existsSync()) return;
    final fields = {
      for (final part in file.readAsStringSync().split(';'))
        if (part.contains('=')) part.split('=').first: part.split('=').last,
    };
    mock.files[path] = MockAudioFile(
      sourceRate: 48000,
      sourceFrames: int.parse(fields['frames'] ?? '100'),
    );
  }

  @override
  Future<DecodedAudio> decode(
    String path, {
    required int sampleRate,
    int startFrame = 0,
    int maxFrames = 0,
  }) async {
    _learn(path);
    await beforeDecode?.call();
    return mock.decode(
      path,
      sampleRate: sampleRate,
      startFrame: startFrame,
      maxFrames: maxFrames,
    );
  }

  @override
  Future<AudioProbe> probe(String path, {int buckets = 512}) {
    _learn(path);
    return mock.probe(path, buckets: buckets);
  }
}

/// The backing stack over a mock engine at 48 kHz: the repository with its
/// store under a temp directory, the backing owners over a stored record,
/// and the player.
class BackingFixture {
  /// Builds the stack; call [start] before use and [dispose] after.
  BackingFixture() {
    temp = Directory.systemTemp.createTempSync('segno_backing');
    final root = '${temp.path}/exports';
    engine = MockAudioEngine()
      ..start(const EngineConfig(sampleRate: 48000, outputChannels: 2));
    store = BackingAssetStore(
      root: () async => root,
      decoder: decoder,
      copier: internalBackingCopier(() async => root),
      digester: fakeBackingDigest,
      syncDirectory: (_) {},
    );
    repository = BackingRepository(
      engine: engine,
      metering: engine,
      decoder: decoder,
      store: store,
      pollInterval: const Duration(hours: 1),
      retryDelay: const Duration(milliseconds: 1),
    );
    looper = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream.empty(),
    );
    settingsStore = FakeKeyValueStore();
    settings = BackingSettings(
      repository: looper,
      settings: SettingsRepository(store: settingsStore),
      backing: repository,
    );
    player = BackingPlayer(repository: repository, settings: settings);
  }

  late final Directory temp;
  late final MockAudioEngine engine;
  final ContentAudioDecoder decoder = ContentAudioDecoder();
  late final BackingAssetStore store;
  late final BackingRepository repository;
  late final LooperRepository looper;
  late final FakeKeyValueStore settingsStore;
  late final BackingSettings settings;
  late final BackingPlayer player;

  /// Loads the stored settings and starts the player.
  Future<void> start() async {
    await settings.load();
    await player.start();
  }

  /// Imports a [frames]-frame file called [name] into the store.
  Future<BackingAsset> asset(String name, {int frames = 300}) {
    final source = File('${temp.path}/src/$name')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('frames=$frames;$name');
    return store.import(source.path, name: name);
  }

  /// Plays [frames] frames and lets the repository and player see it.
  Future<void> advance(int frames) async {
    engine.advanceBacking(frames);
    repository.refresh();
    await pumpQueue();
  }

  /// Tears everything down.
  Future<void> dispose() async {
    await player.close();
    await settings.close();
    await repository.dispose();
    await looper.dispose();
    temp.deleteSync(recursive: true);
  }
}

/// Lets queued microtasks and timers at zero run.
Future<void> pumpQueue() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
