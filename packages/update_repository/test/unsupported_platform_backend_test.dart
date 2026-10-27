import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UnsupportedPlatformBackend', () {
    const backend = UnsupportedPlatformBackend();

    test('reports itself unsupported with inert reads', () async {
      expect(backend.isSupported, isFalse);
      expect(backend.channel, '');
      await backend.setChannel('experimental');
      expect(backend.channel, '');
      expect(await backend.currentVersion(), Version.none);
      expect(await backend.stagedVersion(), Version.none);
      expect(await backend.fetchManifest(), isNull);
      expect(await backend.recover(), const UpdateRecovery());
      await backend.clearInterrupted();
    });

    test(
      'downloadAndStage surfaces an error rather than pretending to work',
      () {
        expect(
          backend.downloadAndStage(
            UpdateManifest(version: Version(0, 1, 0), bundle: 'b.raucb'),
          ),
          emitsError(isA<UnsupportedError>()),
        );
      },
    );

    test('a USB package is refused the same way, with no staging', () {
      expect(backend.stagingDirectory, isEmpty);
      expect(
        backend.installPackage('/staging/segno.raucb'),
        emitsError(isA<UnsupportedError>()),
      );
    });

    test('a package refusal names itself', () {
      expect(
        const UpdatePackageRefused(UpdatePackageRefusal.unverified).toString(),
        'UpdatePackageRefused(unverified)',
      );
      expect(
        UpdatePackageRefused(
          UpdatePackageRefusal.notNewer,
          version: Version(0, 9, 0),
        ).toString(),
        'UpdatePackageRefused(notNewer, 0.9.0)',
      );
    });
  });
}
