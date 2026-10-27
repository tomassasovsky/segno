import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/update/usb/usb_update_cubit.dart';
import 'package:segno/update/usb/usb_update_package.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:update_repository/update_repository.dart';

class _MockStorage extends Mock implements StorageRepository {}

class _MockUpdates extends Mock implements UpdateRepository {}

void main() {
  late Directory root;
  late _MockStorage storage;
  late _MockUpdates updates;
  late StreamController<List<RemovableVolume>> volumes;
  late bool takeRunning;
  late int staged;

  RemovableVolume volume({
    int generation = 1,
    RemovableVolumeStatus status = RemovableVolumeStatus.mounted,
  }) {
    final mount = Directory('${root.path}/usb$generation')
      ..createSync(recursive: true);
    return RemovableVolume(
      generation: generation,
      fingerprint: 'fp$generation',
      label: 'SEGNO_USB',
      fsType: 'vfat',
      sizeBytes: 1 << 30,
      status: status,
      mountPoint: mount.path,
    );
  }

  File file(String path, {int bytes = 2048}) => File('${root.path}/$path')
    ..createSync(recursive: true)
    ..writeAsBytesSync(List<int>.filled(bytes, 1));

  setUp(() {
    root = Directory.systemTemp.createTempSync('usb_update');
    storage = _MockStorage();
    updates = _MockUpdates();
    volumes = StreamController<List<RemovableVolume>>.broadcast();
    takeRunning = false;
    staged = 0;
    when(() => storage.volumes).thenAnswer((_) => volumes.stream);
    when(() => storage.current).thenReturn(const []);
    when(() => storage.space(const StorageDestination.internal())).thenAnswer(
      (_) async => const VolumeSpace(totalBytes: 1 << 34, freeBytes: 1 << 33),
    );
    when(() => updates.stagingDirectory).thenReturn('${root.path}/staging');
    when(
      () => updates.currentVersion(),
    ).thenAnswer((_) async => Version(1, 0, 0));
  });

  tearDown(() async {
    await volumes.close();
    root.deleteSync(recursive: true);
  });

  UsbUpdateCubit build() {
    final cubit = UsbUpdateCubit(
      storage: storage,
      updates: updates,
      takeRunning: () => takeRunning,
      onStaged: () => staged++,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<UsbUpdateCubit> listed(List<RemovableVolume> on) async {
    final cubit = build()..open();
    volumes.add(on);
    await pumpEventQueue();
    return cubit;
  }

  group('listing', () {
    test('no drive asks for one', () async {
      final cubit = await listed(const []);
      expect(cubit.state.phase, UsbUpdatePhase.noDrive);
    });

    test('finds packages at the root and in segno-updates, and nothing '
        'else', () async {
      final usb = volume();
      file('usb1/a-1.1.0.raucb');
      file('usb1/segno-updates/b.raucb');
      file('usb1/c.txt');
      final cubit = await listed([usb]);
      expect(cubit.state.phase, UsbUpdatePhase.list);
      expect(cubit.state.packages.map((p) => p.name), [
        'a-1.1.0.raucb',
        'b.raucb',
      ]);
      expect(cubit.state.packages.first.version, Version(1, 1, 0));
      expect(cubit.state.packages.first.sizeBytes, 2048);
    });

    test('a drive with no package says so, naming it', () async {
      final cubit = await listed([volume()]);
      expect(cubit.state.phase, UsbUpdatePhase.empty);
      expect(cubit.state.driveLabel, 'SEGNO_USB');
    });

    test('a read-only drive is read like any other', () async {
      final usb = volume(status: RemovableVolumeStatus.readOnly);
      file('usb1/a.raucb');
      final cubit = await listed([usb]);
      expect(cubit.state.packages, hasLength(1));
    });
  });

  group('installing a package', () {
    late UsbUpdatePackage package;

    Future<UsbUpdateCubit> ready() async {
      final usb = volume();
      file('usb1/segno-1.1.0.raucb');
      final cubit = await listed([usb]);
      package = cubit.state.packages.single;
      return cubit;
    }

    void copies() => when(
      () => storage.copyUpdatePackage(
        generation: any(named: 'generation'),
        sourcePath: any(named: 'sourcePath'),
        stagingDirectory: any(named: 'stagingDirectory'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => '${root.path}/staging/segno-1.1.0.raucb');

    test('copies into staging, installs it with progress, and lands in '
        'Ready to install', () async {
      final cubit = await ready();
      copies();
      final install = StreamController<double>();
      when(() => updates.installPackage(any())).thenAnswer(
        (_) => install.stream,
      );

      cubit.choose(package);
      await pumpEventQueue();
      verify(
        () => storage.copyUpdatePackage(
          generation: 1,
          sourcePath: package.path,
          stagingDirectory: '${root.path}/staging',
          cancelled: any(named: 'cancelled'),
        ),
      ).called(1);
      verify(
        () => updates.installPackage('${root.path}/staging/segno-1.1.0.raucb'),
      ).called(1);
      expect(cubit.state.phase, UsbUpdatePhase.installing);
      install.add(0.5);
      await pumpEventQueue();
      expect(cubit.state.progress, 0.5);
      await install.close();
      await pumpEventQueue();
      expect(cubit.state.phase, UsbUpdatePhase.closed);
      expect(staged, 1);
    });

    test('a take refuses it before anything is copied', () async {
      final cubit = await ready();
      takeRunning = true;
      cubit.choose(package);
      await pumpEventQueue();
      expect(cubit.state.phase, UsbUpdatePhase.failed);
      expect(cubit.state.error, UsbUpdateError.busy);
      expect(cubit.state.busyKind, 'capture');
      verifyNever(
        () => storage.copyUpdatePackage(
          generation: any(named: 'generation'),
          sourcePath: any(named: 'sourcePath'),
          stagingDirectory: any(named: 'stagingDirectory'),
          cancelled: any(named: 'cancelled'),
        ),
      );
    });

    test('too little room is refused with what it needs, before a byte is '
        'written', () async {
      final cubit = await ready();
      when(() => storage.space(const StorageDestination.internal())).thenAnswer(
        (_) async => const VolumeSpace(totalBytes: 1 << 34, freeBytes: 1000),
      );
      cubit.choose(package);
      await pumpEventQueue();
      expect(cubit.state.error, UsbUpdateError.noSpace);
      expect(cubit.state.neededBytes, 2048 + kUsbUpdateSpareBytes);
      verifyNever(
        () => storage.copyUpdatePackage(
          generation: any(named: 'generation'),
          sourcePath: any(named: 'sourcePath'),
          stagingDirectory: any(named: 'stagingDirectory'),
          cancelled: any(named: 'cancelled'),
        ),
      );
    });

    for (final (failure, error) in [
      (const StorageFailure.volumeLost(1), UsbUpdateError.removed),
      (const StorageFailure.full(), UsbUpdateError.noSpace),
      (const StorageFailure.busy(GuardKind.capture), UsbUpdateError.busy),
    ]) {
      test('a copy that fails $failure says ${error.name}', () async {
        final cubit = await ready();
        when(
          () => storage.copyUpdatePackage(
            generation: any(named: 'generation'),
            sourcePath: any(named: 'sourcePath'),
            stagingDirectory: any(named: 'stagingDirectory'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenThrow(failure);
        cubit.choose(package);
        await pumpEventQueue();
        expect(cubit.state.error, error);
        verifyNever(() => updates.installPackage(any()));
      });
    }

    test('an unverified package says so', () async {
      final cubit = await ready();
      copies();
      when(() => updates.installPackage(any())).thenAnswer(
        (_) => Stream.error(
          const UpdatePackageRefused(UpdatePackageRefusal.unverified),
        ),
      );
      cubit.choose(package);
      await pumpEventQueue();
      expect(cubit.state.error, UsbUpdateError.unverified);
      expect(staged, 0);
    });

    test('a package that is not newer names both versions', () async {
      final cubit = await ready();
      copies();
      when(() => updates.installPackage(any())).thenAnswer(
        (_) => Stream.error(
          UpdatePackageRefused(
            UpdatePackageRefusal.notNewer,
            version: Version(0, 9, 0),
          ),
        ),
      );
      cubit.choose(package);
      await pumpEventQueue();
      expect(cubit.state.error, UsbUpdateError.notNewer);
      expect(cubit.state.refusedVersion, Version(0, 9, 0));
      expect(cubit.state.installedVersion, Version(1, 0, 0));
    });

    test('Cancel during the copy goes back to the list and installs '
        'nothing', () async {
      final cubit = await ready();
      final copy = Completer<String>();
      bool Function()? cancelled;
      when(
        () => storage.copyUpdatePackage(
          generation: any(named: 'generation'),
          sourcePath: any(named: 'sourcePath'),
          stagingDirectory: any(named: 'stagingDirectory'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((invocation) {
        cancelled = invocation.namedArguments[#cancelled] as bool Function()?;
        return copy.future;
      });
      cubit.choose(package);
      await pumpEventQueue();
      expect(cubit.state.phase, UsbUpdatePhase.copying);
      cubit.cancel();
      expect(cancelled?.call(), isTrue);
      copy.completeError(const StorageFailure.io('cancelled'));
      await pumpEventQueue();
      expect(cubit.state.phase, UsbUpdatePhase.list);
      verifyNever(() => updates.installPackage(any()));
    });
  });
}
