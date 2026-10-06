import 'dart:async';
import 'dart:typed_data';

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
      'select reads the preview of that session',
      build: build,
      act: (cubit) => cubit.select('s-a'),
      expect: () => [
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

    test(
      'clearSelection drops the selection and keeps the browsing state',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        cubit
          ..search('eve')
          ..setLocation(LibraryLocation.usb)
          ..clearSelection();

        expect(cubit.state.selectedId, isNull);
        expect(cubit.state.preview, isNull);
        expect(cubit.state.query, 'eve');
        expect(cubit.state.location, LibraryLocation.usb);
      },
    );

    test(
      'a read in flight when the selection is cleared never lands',
      () async {
        final slow = Completer<SessionPreview>();
        when(
          () => sessions.readPreview('s-slow'),
        ).thenAnswer((_) => slow.future);
        final cubit = build();
        addTearDown(cubit.close);

        final read = cubit.select('s-slow');
        cubit.clearSelection();
        slow.complete(_preview('s-slow'));
        await read;

        expect(cubit.state.selectedId, isNull);
        expect(cubit.state.preview, isNull);
      },
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
      'an unconvertible older preview reads as unconvertible',
      setUp: () => when(() => sessions.readPreview('s-old')).thenThrow(
        const SessionUnconvertible(version: 0, reason: 'older than 1'),
      ),
      build: build,
      act: (cubit) => cubit.select('s-old'),
      skip: 1,
      expect: () => [
        isA<LibraryState>().having(
          (s) => s.previewError,
          'error',
          LibraryPreviewError.unconvertible,
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

    group('Listen (plan D10)', () {
      /// What the mocked engine reports, poll by poll.
      late List<AuditionState> reports;

      setUp(() {
        reports = [];
        when(() => sessions.startAudition(any())).thenAnswer(
          (_) async => const AuditionStart(
            result: EngineResult.ok,
            frames: 480000,
            truncated: true,
          ),
        );
        when(sessions.stopAudition).thenReturn(EngineResult.ok);
        when(sessions.auditionState).thenAnswer(
          (_) => reports.isEmpty
              ? const AuditionState()
              : (reports.length == 1 ? reports.first : reports.removeAt(0)),
        );
      });

      LibraryCubit fast() => LibraryCubit(
        sessions: sessions,
        volumes: volumes,
        pedal: pedal,
        listenPoll: const Duration(milliseconds: 1),
      );

      Future<void> polls() => Future<void>.delayed(
        const Duration(milliseconds: 30),
      );

      test(
        "plays the selected session's preview and follows its progress",
        () async {
          reports = [
            const AuditionState(frames: 480000, position: 4800, bus: 0),
          ];
          final cubit = fast();
          addTearDown(cubit.close);
          await cubit.select('s-a');

          await cubit.listen();
          verify(() => sessions.startAudition('s-a')).called(1);
          expect(cubit.state.listen?.id, 's-a');
          expect(cubit.state.listen?.frames, 480000);
          expect(cubit.state.listen?.truncated, isTrue);
          expect(cubit.state.listen?.sampleRate, 48000);

          await polls();
          expect(cubit.state.listen?.position, 4800);
        },
      );

      test('ends when the engine no longer plays it: the end, a performance '
          'arm or a device reopen', () async {
        reports = [
          const AuditionState(frames: 480000, position: 4800, bus: 0),
          const AuditionState(),
        ];
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        await polls();
        expect(cubit.state.listen, isNull);
        verifyNever(sessions.stopAudition);
      });

      test('gives a start that has not landed a few polls', () async {
        reports = [
          const AuditionState(),
          const AuditionState(),
          const AuditionState(frames: 480000, position: 64, bus: 0),
        ];
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        await polls();
        expect(cubit.state.listen?.position, 64);
      });

      test('a preview never seen playing ends after five polls', () async {
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        await polls();
        expect(cubit.state.listen, isNull);
      });

      test('Listen again stops it', () async {
        reports = [const AuditionState(frames: 480000, bus: 0)];
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        await cubit.listen();
        expect(cubit.state.listen, isNull);
        verify(sessions.stopAudition).called(1);
      });

      test('another selection stops it', () async {
        reports = [const AuditionState(frames: 480000, bus: 0)];
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        await cubit.select('s-b');
        expect(cubit.state.listen, isNull);
        verify(sessions.stopAudition).called(1);
      });

      test('a footswitch press stops it', () async {
        reports = [const AuditionState(frames: 480000, bus: 0)];
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        await cubit.listen();

        events.add(const ButtonPressed(PedalButton.clear));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.listen, isNull);
        verify(sessions.stopAudition).called(1);
      });

      test('leaving the Library stops it', () async {
        reports = [const AuditionState(frames: 480000, bus: 0)];
        final cubit = fast();
        await cubit.select('s-a');
        await cubit.listen();

        await cubit.close();
        verify(sessions.stopAudition).called(1);
      });

      test('a start that lands after a stop is stopped', () async {
        final landed = Completer<AuditionStart>();
        when(
          () => sessions.startAudition(any()),
        ).thenAnswer((_) => landed.future);
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');
        final listening = cubit.listen();
        cubit.stopListening();

        landed.complete(const AuditionStart(result: EngineResult.ok));
        await listening;
        expect(cubit.state.listen, isNull);
        verify(sessions.stopAudition).called(1);
      });

      for (final (result, refusal) in [
        (EngineResult.invalid, LibraryListenRefusal.unplayable),
        (EngineResult.notRunning, LibraryListenRefusal.noDevice),
        (EngineResult.alreadyRunning, LibraryListenRefusal.performanceArmed),
        (EngineResult.notReady, LibraryListenRefusal.busy),
      ]) {
        test('a ${result.name} start reads ${refusal.name}', () async {
          when(
            () => sessions.startAudition(any()),
          ).thenAnswer((_) async => AuditionStart(result: result));
          final cubit = fast();
          addTearDown(cubit.close);
          await cubit.select('s-a');

          await cubit.listen();
          expect(cubit.state.listen, isNull);
          expect(cubit.state.listenRefusal, refusal);

          // The next selection forgets it.
          await cubit.select('s-b');
          expect(cubit.state.listenRefusal, isNull);
        });
      }

      test('a start that throws reads unplayable', () async {
        when(
          () => sessions.startAudition(any()),
        ).thenThrow(StateError('gone'));
        final cubit = fast();
        addTearDown(cubit.close);
        await cubit.select('s-a');

        await cubit.listen();
        expect(cubit.state.listenRefusal, LibraryListenRefusal.unplayable);
      });

      test('with nothing selected Listen does nothing', () async {
        final cubit = fast();
        addTearDown(cubit.close);

        await cubit.listen();
        verifyNever(() => sessions.startAudition(any()));
      });
    });

    group('peaks (plan D11)', () {
      const track0 = SessionPreviewTrack(
        channel: 0,
        lengthFrames: 48000,
        baseLengthFrames: 48000,
        bars: 0,
        layers: 1,
        muted: false,
        fxCount: 0,
        liveLayerFile: 'track0_lane0_L0.wav',
      );
      const track3 = SessionPreviewTrack(
        channel: 3,
        lengthFrames: 48000,
        baseLengthFrames: 48000,
        bars: 0,
        layers: 1,
        muted: false,
        fxCount: 0,
        liveLayerFile: 'track3_lane0_L0.wav',
      );

      setUpAll(() => registerFallbackValue(track0));

      test(
        "reads each track's peaks and leaves out the ones that fail",
        () async {
          when(() => sessions.readPreview(any())).thenAnswer(
            (_) async => const SessionPreview(
              summary: SessionSummary(id: 's-a', name: 's-a'),
              tracks: [track0, track3],
              fxCount: 0,
              sampleRate: 44100,
            ),
          );
          when(
            () => sessions.readPeaks(
              any(),
              any(),
            ),
          ).thenAnswer((call) async {
            final track = call.positionalArguments[1] as SessionPreviewTrack;
            if (track.channel == 3) throw StateError('unreadable');
            return Float32List.fromList([0.5, 1]);
          });
          final cubit = build();
          addTearDown(cubit.close);

          await cubit.select('s-a');

          expect(cubit.state.peaks.keys, [0]);
          expect(cubit.state.peaks[0], [0.5, 1]);
          verify(
            () => sessions.readPeaks('s-a', track0),
          ).called(1);
        },
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

    test('an unsupported or failed drive is the unusable one', () {
      RemovableVolume drive(RemovableVolumeStatus status) => RemovableVolume(
        generation: 3,
        fingerprint: 'h',
        label: 'Y',
        fsType: 'hfsplus',
        sizeBytes: 1,
        status: status,
      );
      expect(const LibraryState().unusableVolume, isNull);
      expect(
        LibraryState(
          volumes: [drive(RemovableVolumeStatus.unsupported)],
        ).unusableVolume?.status,
        RemovableVolumeStatus.unsupported,
      );
      expect(
        LibraryState(
          volumes: [drive(RemovableVolumeStatus.mountFailed)],
        ).unusableVolume?.status,
        RemovableVolumeStatus.mountFailed,
      );
      expect(
        LibraryState(
          volumes: [drive(RemovableVolumeStatus.ejecting)],
        ).unusableVolume,
        isNull,
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
