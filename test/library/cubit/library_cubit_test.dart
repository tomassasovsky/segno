import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:session_repository/session_repository.dart';

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _FakeVolumes implements RemovableVolumes {
  final controller = StreamController<List<RemovableVolume>>.broadcast();

  @override
  List<RemovableVolume> current = const [];

  @override
  Stream<List<RemovableVolume>> get volumes => controller.stream;

  @override
  Future<VolumeSpace?> space(StorageDestination destination) async => null;

  @override
  Future<T> withWriteLease<T>(
    StorageDestination target,
    String purpose,
    Future<T> Function(String mountPoint) body,
  ) => throw UnimplementedError();

  @override
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  }) => throw UnimplementedError();
}

const _usb = RemovableVolume(
  generation: 1,
  fingerprint: 'f',
  label: 'SEGNO USB',
  fsType: 'vfat',
  mountPoint: '/run/media/segno/1',
  sizeBytes: 1,
  status: RemovableVolumeStatus.mounted,
);

SessionPreview _preview(String id) => SessionPreview(
  summary: SessionSummary(id: id, name: id),
  tracks: const [],
  fxCount: 0,
  sampleRate: 48000,
);

void main() {
  group(LibraryCubit, () {
    late StreamController<PedalEvent> events;
    late PedalRepository pedal;
    late SessionRepository sessions;
    late _FakeVolumes volumes;

    setUp(() {
      events = StreamController<PedalEvent>.broadcast();
      pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);
      sessions = _MockSessionRepository();
      when(sessions.listFolders).thenAnswer((_) async => ['Gigs']);
      when(
        () => sessions.readPreview(any()),
      ).thenAnswer(
        (call) async => _preview(call.positionalArguments.first as String),
      );
      volumes = _FakeVolumes();
    });

    tearDown(() async {
      await events.close();
      await volumes.controller.close();
    });

    LibraryCubit build() =>
        LibraryCubit(sessions: sessions, volumes: volumes, pedal: pedal);

    test('starts on Internal, All, no selection, with the port drives', () {
      volumes.current = const [_usb];
      final cubit = build();
      addTearDown(cubit.close);

      expect(cubit.state.location, LibraryLocation.internal);
      expect(cubit.state.folderFilter, const AllSessions());
      expect(cubit.state.selectedId, isNull);
      expect(cubit.state.volumes, const [_usb]);
      expect(cubit.state.hasReadableVolume, isTrue);
    });

    blocTest<LibraryCubit, LibraryState>(
      'start reads the folders and selects the current session',
      build: build,
      act: (cubit) => cubit.start(selected: 's-a'),
      expect: () => [
        isA<LibraryState>().having((s) => s.folders, 'folders', ['Gigs']),
        isA<LibraryState>()
            .having((s) => s.selectedId, 'selected', 's-a')
            .having((s) => s.preview, 'preview', isNull),
        isA<LibraryState>().having(
          (s) => s.preview?.summary.id,
          'preview',
          's-a',
        ),
      ],
    );

    blocTest<LibraryCubit, LibraryState>(
      'start without a current session selects nothing',
      build: build,
      act: (cubit) => cubit.start(),
      expect: () => [
        isA<LibraryState>()
            .having((s) => s.folders, 'folders', ['Gigs'])
            .having((s) => s.selectedId, 'selected', isNull),
      ],
      verify: (_) => verifyNever(() => sessions.readPreview(any())),
    );

    blocTest<LibraryCubit, LibraryState>(
      'an unreadable folder list keeps the default chips and still selects',
      setUp: () => when(
        sessions.listFolders,
      ).thenThrow(const FileSystemException('denied')),
      build: build,
      act: (cubit) => cubit.start(selected: 's-a'),
      expect: () => [
        isA<LibraryState>()
            .having((s) => s.folders, 'folders', isEmpty)
            .having((s) => s.selectedId, 'selected', 's-a'),
        isA<LibraryState>().having(
          (s) => s.preview?.summary.id,
          'preview',
          's-a',
        ),
      ],
    );

    blocTest<LibraryCubit, LibraryState>(
      'a newer-schema preview reads as unsupportedVersion',
      setUp: () => when(() => sessions.readPreview('s-new')).thenThrow(
        const SessionUnsupportedVersion(version: 99, supported: 11),
      ),
      build: build,
      act: (cubit) => cubit.select('s-new'),
      skip: 1,
      expect: () => [
        isA<LibraryState>()
            .having((s) => s.preview, 'preview', isNull)
            .having(
              (s) => s.previewError,
              'error',
              LibraryPreviewError.unsupportedVersion,
            ),
      ],
    );

    blocTest<LibraryCubit, LibraryState>(
      'a preview that does not decode reads as unreadable',
      setUp: () => when(
        () => sessions.readPreview('s-bad'),
      ).thenThrow(const FormatException('bad')),
      build: build,
      act: (cubit) => cubit.select('s-bad'),
      skip: 1,
      expect: () => [
        isA<LibraryState>().having(
          (s) => s.previewError,
          'error',
          LibraryPreviewError.unreadable,
        ),
      ],
    );

    test('a superseded preview read never lands', () async {
      final slow = Completer<SessionPreview>();
      when(() => sessions.readPreview('s-slow')).thenAnswer((_) => slow.future);
      final cubit = build();
      addTearDown(cubit.close);

      final first = cubit.select('s-slow');
      await cubit.select('s-fast');
      slow.complete(_preview('s-slow'));
      await first;

      expect(cubit.state.selectedId, 's-fast');
      expect(cubit.state.preview?.summary.id, 's-fast');
    });

    test('a new selection clears the previous error', () async {
      when(
        () => sessions.readPreview('s-bad'),
      ).thenThrow(const FormatException('bad'));
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.select('s-bad');
      await cubit.select('s-good');

      expect(cubit.state.previewError, isNull);
      expect(cubit.state.preview?.summary.id, 's-good');
    });

    blocTest<LibraryCubit, LibraryState>(
      'search, folder chip and location are plain state',
      build: build,
      act: (cubit) => cubit
        ..search('eve')
        ..filterFolder(const FolderSessions('Gigs'))
        ..setLocation(LibraryLocation.usb),
      expect: () => [
        isA<LibraryState>().having((s) => s.query, 'query', 'eve'),
        isA<LibraryState>().having(
          (s) => s.folderFilter,
          'filter',
          const FolderSessions('Gigs'),
        ),
        isA<LibraryState>().having(
          (s) => s.location,
          'location',
          LibraryLocation.usb,
        ),
      ],
    );

    blocTest<LibraryCubit, LibraryState>(
      'follows the drives the port reports',
      build: build,
      act: (_) => volumes.controller.add(const [_usb]),
      expect: () => [
        isA<LibraryState>().having((s) => s.volumes, 'volumes', const [_usb]),
      ],
    );

    group('pedal', () {
      blocTest<LibraryCubit, LibraryState>(
        'requests the return to Tracks once on repeated presses',
        build: build,
        act: (_) => events
          ..add(const ButtonPressed(PedalButton.clear))
          ..add(const ButtonPressed(PedalButton.recPlay)),
        expect: () => [
          isA<LibraryState>().having(
            (s) => s.dismissalRequested,
            'dismissal',
            isTrue,
          ),
        ],
      );

      blocTest<LibraryCubit, LibraryState>(
        'ignores encoder turns and releases',
        build: build,
        act: (_) => events
          ..add(const EncoderDelta(1))
          ..add(const ButtonReleased(PedalButton.clear)),
        expect: () => <LibraryState>[],
      );
    });

    test('close cancels the pedal and drive subscriptions', () async {
      final cubit = build();
      expect(events.hasListener, isTrue);
      expect(volumes.controller.hasListener, isTrue);

      await cubit.close();

      expect(events.hasListener, isFalse);
      expect(volumes.controller.hasListener, isFalse);
    });
  });

  group(LibraryState, () {
    const rows = [
      SessionSummary(id: 's-1', name: 'Evening loop'),
      SessionSummary(id: 's-2', name: 'Morning EVE', folder: 'Gigs'),
      SessionSummary(id: 's-3', name: 'Bridge', folder: 'Demos'),
    ];

    List<String> ids(LibraryState state) =>
        state.filter(rows).map((s) => s.id).toList();

    test('All lists every row; search is a case-insensitive substring', () {
      expect(ids(const LibraryState()), ['s-1', 's-2', 's-3']);
      expect(ids(const LibraryState(query: ' eve ')), ['s-1', 's-2']);
      expect(ids(const LibraryState(query: 'zzz')), isEmpty);
    });

    test('Unfiled is the root; a folder chip is that folder', () {
      expect(ids(const LibraryState(folderFilter: UnfiledSessions())), [
        's-1',
      ]);
      expect(ids(const LibraryState(folderFilter: FolderSessions('Gigs'))), [
        's-2',
      ]);
      expect(
        ids(
          const LibraryState(
            folderFilter: FolderSessions('Gigs'),
            query: 'evening',
          ),
        ),
        isEmpty,
      );
    });

    test('an ejected drive is not readable; a mounted one is', () {
      expect(const LibraryState().hasReadableVolume, isFalse);
      expect(
        const LibraryState(
          volumes: [
            RemovableVolume(
              generation: 2,
              fingerprint: 'g',
              label: 'X',
              fsType: 'exfat',
              sizeBytes: 1,
              status: RemovableVolumeStatus.ejected,
            ),
          ],
        ).hasReadableVolume,
        isFalse,
      );
      expect(const LibraryState(volumes: [_usb]).hasReadableVolume, isTrue);
    });
  });
}
