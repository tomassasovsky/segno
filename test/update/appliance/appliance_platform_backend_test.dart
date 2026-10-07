import 'package:flutter_test/flutter_test.dart';
import 'package:segno/update/appliance/appliance_env.dart';
import 'package:segno/update/appliance/appliance_platform_backend.dart';
import 'package:update_repository/update_repository.dart';

class _FakeEnv implements ApplianceEnv {
  _FakeEnv({
    Map<String, String> files = const {},
    this.body,
    this.stageProgress = const [0.5, 1.0],
    this.stageError,
  }) : files = Map.of(files);

  final Map<String, String> files;
  final String? body;
  final List<double> stageProgress;
  final Object? stageError;

  Uri? fetchedUrl;
  String? stagedVersionArg;
  int rebootCalls = 0;

  @override
  String? readTextSync(String path) => files[path];

  @override
  void writeTextSync(String path, String contents) {
    files[path] = contents;
  }

  @override
  bool existsSync(String path) => files.containsKey(path);

  @override
  Future<String?> httpGetText(Uri url) async {
    fetchedUrl = url;
    return body;
  }

  @override
  Stream<double> stage(String version) {
    stagedVersionArg = version;
    if (stageError != null) return Stream.error(stageError!);
    return Stream.fromIterable(stageProgress);
  }

  @override
  Future<void> reboot() async {
    rebootCalls++;
  }

  int powerOffCalls = 0;

  @override
  Future<void> powerOff() async {
    powerOffCalls++;
  }

  int reconcileCalls = 0;

  /// What reconcile-staged answers; it clears the staged marker whenever it
  /// names a reason, as the helper does.
  String? reconcileReason;

  @override
  Future<String?> reconcileStaged() async {
    reconcileCalls++;
    if (reconcileReason != null) files.remove(_staged);
    return reconcileReason;
  }

  String? attempt;
  int clearAttemptCalls = 0;

  @override
  Future<String?> updateAttempt() async => attempt;

  @override
  Future<void> clearUpdateAttempt() async {
    clearAttemptCalls++;
    attempt = null;
  }
}

const _version = '/etc/segno/build-version';
const _channel = '/etc/segno/update-channel';
const _channelOverride = '/data/segno/update-channel';
const _staged = '/data/.ota-staged-version';

AppliancePlatformBackend backend(ApplianceEnv env) =>
    AppliancePlatformBackend(env: env);

void main() {
  group('isSupported', () {
    test('true only when both the version file and the helper exist', () {
      expect(
        backend(
          _FakeEnv(files: {_version: '0.2.0', kApplianceHelperPath: ''}),
        ).isSupported,
        isTrue,
      );
      expect(
        backend(_FakeEnv(files: {_version: '0.2.0'})).isSupported,
        isFalse,
      );
      expect(
        backend(_FakeEnv(files: {kApplianceHelperPath: ''})).isSupported,
        isFalse,
      );
      expect(backend(_FakeEnv()).isSupported, isFalse);
    });
  });

  group('channel', () {
    test('reads and trims the baked channel file', () {
      expect(
        backend(_FakeEnv(files: {_channel: 'experimental\n'})).channel,
        'experimental',
      );
    });

    test('defaults to production when unset or empty', () {
      expect(backend(_FakeEnv()).channel, 'production');
      expect(backend(_FakeEnv(files: {_channel: '  '})).channel, 'production');
    });

    test('prefers the /data override over the baked marker', () {
      expect(
        backend(
          _FakeEnv(
            files: {
              _channel: 'production',
              _channelOverride: 'experimental\n',
            },
          ),
        ).channel,
        'experimental',
      );
    });

    test(
      'setChannel writes the override and normalizes unknown values',
      () async {
        final env = _FakeEnv(files: {_channel: 'production'});
        final b = backend(env);

        await b.setChannel('experimental');
        expect(b.channel, 'experimental');
        expect(env.files[_channelOverride], 'experimental\n');

        await b.setChannel('nightly');
        expect(b.channel, 'production');
        expect(env.files[_channelOverride], 'production\n');
      },
    );
  });

  group('version reads', () {
    test(
      'parses the marker files as semver, defaulting to Version.none',
      () async {
        final env = _FakeEnv(files: {_version: '0.2.0\n', _staged: '0.3.0'});
        final b = backend(env);
        expect(await b.currentVersion(), Version.parse('0.2.0'));
        expect(await b.stagedVersion(), Version.parse('0.3.0'));
        // Reconciling is the startup recover's job, once, not every read's.
        expect(env.reconcileCalls, 0);
      },
    );

    test('parses a prerelease (experimental) semver', () async {
      final b = backend(_FakeEnv(files: {_version: '0.2.0-experimental.7'}));
      expect(await b.currentVersion(), Version.parse('0.2.0-experimental.7'));
    });

    test('treats missing/garbage as Version.none', () async {
      final b = backend(_FakeEnv(files: {_version: 'x'}));
      expect(await b.currentVersion(), Version.none);
      expect(await b.stagedVersion(), Version.none);
    });
  });

  group('recover', () {
    test('a tryboot that did not take names the staged version that rolled '
        'back, read before the reconcile cleared it', () async {
      final env = _FakeEnv(files: {_version: '1.0.0', _staged: '1.1.0'})
        ..reconcileReason = 'tryboot-not-taken';

      final recovery = await backend(env).recover();

      expect(recovery.rolledBack, Version.parse('1.1.0'));
      expect(recovery.interrupted, isNull);
      expect(env.reconcileCalls, 1);
      expect(env.files.containsKey(_staged), isFalse);
    });

    test('already running the staged version is no rollback', () async {
      final env = _FakeEnv(files: {_version: '1.1.0', _staged: '1.1.0'})
        ..reconcileReason = 'already-running';

      expect((await backend(env).recover()).rolledBack, isNull);
    });

    test('a kept marker is no rollback', () async {
      final env = _FakeEnv(files: {_version: '1.0.0', _staged: '1.1.0'});

      expect((await backend(env).recover()).rolledBack, isNull);
      expect(env.files[_staged], '1.1.0');
    });

    test('reports the install that was cut off', () async {
      final env = _FakeEnv(files: {_version: '1.0.0'})..attempt = '1.1.0';

      expect(
        (await backend(env).recover()).interrupted,
        Version.parse('1.1.0'),
      );
    });

    test('an unreadable attempt is none', () async {
      final env = _FakeEnv(files: {_version: '1.0.0'})..attempt = 'garbage';

      expect((await backend(env).recover()).interrupted, isNull);
    });

    test('clearInterrupted forgets the attempt through the helper', () async {
      final env = _FakeEnv()..attempt = '1.1.0';

      await backend(env).clearInterrupted();

      expect(env.clearAttemptCalls, 1);
      expect(env.attempt, isNull);
    });
  });

  group('fetchManifest', () {
    test('parses the manifest and hits the per-channel URL', () async {
      final env = _FakeEnv(
        files: {_channel: 'experimental'},
        body: '{"version":"0.2.0","bundle":"b.raucb","sha256":"s"}',
      );

      final manifest = await backend(env).fetchManifest();

      expect(manifest?.version, Version.parse('0.2.0'));
      expect(
        env.fetchedUrl.toString(),
        'https://segno.aquiles.dev/updates/appliance/experimental/manifest.json',
      );
    });

    test('returns null when the server is unreachable', () async {
      expect(await backend(_FakeEnv()).fetchManifest(), isNull);
    });

    test('returns null on malformed or non-object JSON', () async {
      expect(
        await backend(_FakeEnv(body: 'not json')).fetchManifest(),
        isNull,
      );
      expect(await backend(_FakeEnv(body: '[1,2]')).fetchManifest(), isNull);
    });
  });

  group('stage and reboot', () {
    test(
      'downloadAndStage forwards the version string and streams progress',
      () async {
        final env = _FakeEnv(stageProgress: const [0.25, 1.0]);
        final manifest = UpdateManifest(
          version: Version.parse('0.7.0'),
          bundle: 'b.raucb',
        );

        final progress = await backend(env).downloadAndStage(manifest).toList();

        expect(progress, [0.25, 1.0]);
        expect(env.stagedVersionArg, '0.7.0');
      },
    );

    test('downloadAndStage surfaces a helper failure', () {
      final env = _FakeEnv(stageError: Exception('rauc failed'));
      final manifest = UpdateManifest(
        version: Version.parse('0.7.0'),
        bundle: 'b.raucb',
      );
      expect(
        backend(env).downloadAndStage(manifest),
        emitsError(isA<Exception>()),
      );
    });

    test('staging never reboots; the power flow owns the restart', () async {
      final env = _FakeEnv(stageProgress: const [1.0]);
      await backend(env)
          .downloadAndStage(
            UpdateManifest(version: Version.parse('0.7.0'), bundle: 'b.raucb'),
          )
          .drain<void>();
      await backend(env).stagedVersion();
      expect(env.rebootCalls, 0);
    });
  });
}
