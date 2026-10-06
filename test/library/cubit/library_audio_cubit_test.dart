import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_audio_cubit.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:session_repository/session_repository.dart';

import '../helpers/fake_drive.dart';

class _MockPerformance extends Mock implements PerformanceRepository {}

class _MockSessions extends Mock implements SessionRepository {}

const _mixdown = SessionMixdown(frames: 48000, sampleRate: 48000, bytes: 4);

void main() {
  late Directory temp;
  late String exports;
  late FakeDrive drive;
  late PerformanceRepository performance;
  late SessionRepository sessions;
  late List<String> dawWrites;
  late GuardRegistry guards;

  setUpAll(() {
    registerFallbackValue(
      const CaptureSummary(
        path: '',
        name: '',
        durationFrames: 0,
        sampleRate: 0,
        parts: [],
      ),
    );
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_audio_cubit');
    exports = '${temp.path}/exports';
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    performance = _MockPerformance();
    guards = GuardRegistry();
    when(() => performance.rendering).thenReturn(false);
    sessions = _MockSessions();
    dawWrites = [];
    when(() => performance.listCaptures()).thenAnswer((_) async => []);
    when(() => sessions.listSessions()).thenAnswer((_) async => []);
    when(() => sessions.mixdownOf(any())).thenAnswer((_) async => null);
    when(
      () => performance.readPeaks(any(), buckets: any(named: 'buckets')),
    ).thenAnswer((_) async => Float32List.fromList([0.5]));
    when(
      () => sessions.readMixdownPeaks(any(), buckets: any(named: 'buckets')),
    ).thenAnswer((_) async => Float32List.fromList([0.25]));
    when(() => sessions.stopAudition()).thenReturn(EngineResult.ok);
    when(() => sessions.auditionState()).thenReturn(const AuditionState());
  });

  tearDown(() async {
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  LibraryAudioCubit build({DawProjectWriter? dawProject}) => LibraryAudioCubit(
    performance: performance,
    sessions: sessions,
    volumes: drive,
    guards: guards,
    previewPoll: const Duration(milliseconds: 1),
    dawProject:
        dawProject ??
        (dir) async {
          dawWrites.add(dir);
          File('$dir/project.als').writeAsBytesSync([7]);
          return null;
        },
  );

  /// A finished take named [name] with [parts] main-output parts on disk.
  CaptureSummary take(String name, {int parts = 1, bool recovered = false}) {
    final dir = '$exports/$name';
    final list = <CapturePart>[];
    for (var i = 1; i <= parts; i++) {
      final file = 'master-00$i.wav';
      File('$dir/$file')
        ..createSync(recursive: true)
        ..writeAsBytesSync([i, i]);
      list.add(
        CapturePart(stream: 0, index: i, file: file, frames: 24000, bytes: 2),
      );
    }
    return CaptureSummary(
      path: dir,
      name: name,
      durationFrames: 24000 * parts,
      sampleRate: 48000,
      recovered: recovered,
      parts: list,
    );
  }

  Future<LibraryAudioCubit> withRecording(
    CaptureSummary capture, {
    DawProjectWriter? dawProject,
  }) async {
    when(() => performance.listCaptures()).thenAnswer((_) async => [capture]);
    final cubit = build(dawProject: dawProject);
    addTearDown(cubit.close);
    await cubit.load();
    cubit.openFolder(LibraryAudioFolder.performances);
    await cubit.select(cubit.state.items.single);
    return cubit;
  }

  Future<LibraryAudioCubit> withSession(String id, String name) async {
    when(
      () => sessions.listSessions(),
    ).thenAnswer((_) async => [SessionSummary(id: id, name: name)]);
    when(() => sessions.mixdownOf(id)).thenAnswer((_) async => _mixdown);
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.load();
    cubit.openFolder(LibraryAudioFolder.sessions);
    await cubit.select(cubit.state.items.single);
    return cubit;
  }

  group('the folders', () {
    test('lists every finished take, recovered ones too, and the sessions '
        'that have a mixdown', () async {
      final a = take('perf-a');
      final b = take('perf-b', recovered: true);
      when(() => performance.listCaptures()).thenAnswer((_) async => [a, b]);
      when(() => sessions.listSessions()).thenAnswer(
        (_) async => const [
          SessionSummary(id: 's-a', name: 'Gig'),
          SessionSummary(id: 's-b', name: 'Empty'),
          SessionSummary(id: 's-c', name: 'Broken', unreadable: true),
        ],
      );
      when(() => sessions.mixdownOf('s-a')).thenAnswer((_) async => _mixdown);
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.loaded, isTrue);
      expect(cubit.state.items, isEmpty);
      cubit.openFolder(LibraryAudioFolder.performances);
      expect(cubit.state.items.map((i) => i.name), ['perf-a', 'perf-b']);
      cubit.openFolder(LibraryAudioFolder.sessions);
      expect(cubit.state.items.map((i) => i.name), ['Gig']);
      verifyNever(() => sessions.mixdownOf('s-c'));
      cubit.closeFolder();
      expect(cubit.state.folder, isNull);
    });

    test('a listing that fails leaves the folders empty', () async {
      when(
        () => performance.listCaptures(),
      ).thenThrow(const FileSystemException());
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.loaded, isTrue);
      expect(cubit.state.recordings, isEmpty);
    });

    test('search filters the open folder by name', () async {
      final cubit = await withRecording(take('Evening loop'));
      cubit.search('even');
      expect(cubit.state.items, hasLength(1));
      cubit.search('nothing');
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.selected, isNull);
    });

    test('a reload keeps a selection that is still there, and drops one '
        'that is gone', () async {
      final cubit = await withRecording(take('perf-a'));
      await cubit.load();
      expect(cubit.state.selectedKey, '$exports/perf-a');

      when(() => performance.listCaptures()).thenAnswer((_) async => []);
      await cubit.load();
      expect(cubit.state.selectedKey, isNull);
    });
  });

  group('the waveform', () {
    test("a recording's comes from its parts, a mixdown's from the "
        'session', () async {
      final recording = await withRecording(take('perf-a'));
      expect(recording.state.peaks, [0.5]);

      final session = await withSession('s-a', 'Gig');
      expect(session.state.peaks, [0.25]);
    });

    test('none when it does not read', () async {
      when(
        () => performance.readPeaks(any(), buckets: any(named: 'buckets')),
      ).thenThrow(StateError('no'));
      final cubit = await withRecording(take('perf-a'));
      expect(cubit.state.peaks, isNull);
    });
  });

  group('Preview', () {
    test("plays a recording's first part, polls it, and stops", () async {
      final capture = take('perf-a');
      when(
        () => performance.startAudition(
          any(),
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer(
        (_) async => const AuditionStart(
          result: EngineResult.ok,
          frames: 4800,
          rate: 48000,
          sourceRate: 48000,
        ),
      );
      when(
        () => sessions.auditionState(),
      ).thenReturn(const AuditionState(frames: 4800, position: 960));
      final cubit = await withRecording(capture);

      await cubit.preview();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.preview?.key, capture.path);
      expect(cubit.state.preview?.position, 960);
      verify(
        () => performance.startAudition(
          capture,
          stillWanted: any(named: 'stillWanted'),
        ),
      ).called(1);

      await cubit.preview();
      expect(cubit.state.preview, isNull);
      verify(() => sessions.stopAudition()).called(1);
    });

    test('ends when the engine ends it', () async {
      when(
        () => sessions.startAudition(
          's-a',
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer(
        (_) async => const AuditionStart(
          result: EngineResult.ok,
          frames: 4800,
          rate: 48000,
          sourceRate: 48000,
        ),
      );
      final cubit = await withSession('s-a', 'Gig');

      await cubit.preview();
      expect(cubit.state.preview, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(cubit.state.preview, isNull);
    });

    test('a refusal is kept with its reason', () async {
      when(
        () => performance.startAudition(
          any(),
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer(
        (_) async => const AuditionStart(result: EngineResult.alreadyRunning),
      );
      final cubit = await withRecording(take('perf-a'));

      await cubit.preview();

      expect(cubit.state.previewRefusal, LibraryListenRefusal.performanceArmed);
      expect(cubit.state.preview, isNull);
    });

    test('a new selection and the close stop it', () async {
      when(
        () => performance.startAudition(
          any(),
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer(
        (_) async => const AuditionStart(
          result: EngineResult.ok,
          frames: 4800,
          rate: 48000,
          sourceRate: 48000,
        ),
      );
      when(
        () => sessions.auditionState(),
      ).thenReturn(const AuditionState(frames: 4800));
      final cubit = await withRecording(take('perf-a'));
      await cubit.preview();

      cubit.closeFolder();
      expect(cubit.state.preview, isNull);

      cubit.openFolder(LibraryAudioFolder.performances);
      await cubit.select(cubit.state.items.single);
      await cubit.preview();
      await cubit.close();
      verify(() => sessions.stopAudition()).called(2);
    });
  });

  group('Export to USB', () {
    test('a one-part recording lands as one WAV, through one copy under a '
        'named lease', () async {
      final cubit = await withRecording(take('Evening loop'));

      await cubit.export(
        LibraryAudioExportKind.recording,
        purpose: 'Exporting Evening loop',
      );

      expect(drive.leases, ['Exporting Evening loop']);
      // Staged copies overwrite only the export's own staging.
      expect(drive.copies.single.policy, ConflictPolicy.replace);
      expect(drive.files, ['Segno/Performances/Evening loop.wav']);
      expect(
        cubit.state.export,
        const LibraryExportDone(
          name: 'Evening loop.wav',
          folder: LibraryAudioFolder.performances,
        ),
      );
      cubit.dismissExport();
      expect(cubit.state.export, isNull);
    });

    test(
      'a multi-part take lands as consecutive files from its parts list',
      () async {
        final cubit = await withRecording(take('Evening loop', parts: 3));

        await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');

        expect(drive.files, [
          'Segno/Performances/Evening loop · Part 001.wav',
          'Segno/Performances/Evening loop · Part 002.wav',
          'Segno/Performances/Evening loop · Part 003.wav',
        ]);
        expect(
          File(
            '${drive.mount}/Segno/Performances/Evening loop · Part 002.wav',
          ).readAsBytesSync(),
          [2, 2],
        );
      },
    );

    test('the DAW package writes the project first when it is missing, '
        'then copies the bundle as one directory', () async {
      final capture = take('Evening loop');
      when(() => performance.dawPackageFiles(any())).thenAnswer(
        (_) => ['master-001.wav', 'project.als'],
      );
      final cubit = await withRecording(capture);

      await cubit.export(LibraryAudioExportKind.dawPackage, purpose: 'p');

      expect(dawWrites, [capture.path]);
      expect(drive.files, [
        'Segno/Performances/Evening loop/master-001.wav',
        'Segno/Performances/Evening loop/project.als',
      ]);
      expect(cubit.state.export, isA<LibraryExportDone>());

      // Written once: the next package finds it.
      await cubit.export(LibraryAudioExportKind.dawPackage, purpose: 'p');
      expect(dawWrites, hasLength(1));
    });

    test('a name already on the drive asks first, writing nothing, and '
        'Keep both writes beside it', () async {
      final cubit = await withRecording(take('Evening loop'));
      File('${drive.mount}/Segno/Performances/Evening loop.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync([9]);

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');

      expect(cubit.state.export, const LibraryExportConflict('Evening loop'));
      expect(drive.copies, isEmpty);

      await cubit.resolveConflict(ConflictPolicy.keepBoth);

      expect(drive.files, [
        'Segno/Performances/Evening loop (2).wav',
        'Segno/Performances/Evening loop.wav',
      ]);
      expect(
        drive.copies.single.relativePath,
        endsWith('Evening loop (2).wav'),
      );
    });

    test('Replace writes over it; Cancel leaves it', () async {
      final cubit = await withRecording(take('Evening loop'));
      final there =
          File(
              '${drive.mount}/Segno/Performances/Evening loop.wav',
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync([9]);

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      cubit.cancelExport();
      expect(cubit.state.export, isNull);
      await cubit.resolveConflict(ConflictPolicy.replace);
      expect(there.readAsBytesSync(), [9]);

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      await cubit.resolveConflict(ConflictPolicy.replace);
      expect(there.readAsBytesSync(), [1, 1]);
    });

    test('with no drive it asks for one, and Try again exports once one is '
        'there', () async {
      final cubit = await withRecording(take('Evening loop'));
      drive.present = false;

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      expect(cubit.state.export, const LibraryExportNeedsDrive());

      await cubit.retryExport();
      expect(cubit.state.export, const LibraryExportNeedsDrive());

      drive.present = true;
      await cubit.retryExport();
      expect(drive.files, ['Segno/Performances/Evening loop.wav']);
    });

    test('a read-only drive is reported on the line', () async {
      final cubit = await withRecording(take('Evening loop'));
      drive.status = RemovableVolumeStatus.readOnly;

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');

      expect(cubit.state.error, LibraryAudioError.readOnly);
      expect(cubit.state.export, isNull);
      expect(drive.copies, isEmpty);
    });

    test('a full drive on the third file of a package removes the two '
        'already placed, and says so', () async {
      final capture = take('Evening loop', parts: 3);
      when(() => performance.dawPackageFiles(any())).thenAnswer(
        (_) => ['master-001.wav', 'master-002.wav', 'master-003.wav'],
      );
      final cubit = await withRecording(capture);
      drive
        ..failOnCopy = 3
        ..failure = const StorageFailure.full();

      await cubit.export(LibraryAudioExportKind.dawPackage, purpose: 'p');

      expect(drive.copies, hasLength(3));
      expect(drive.files, isEmpty);
      expect(cubit.state.error, LibraryAudioError.notEnoughSpace);
      expect(cubit.state.export, isNull);
      expect(File('${capture.path}/master-003.wav').readAsBytesSync(), [3, 3]);
    });

    test(
      'a drive lost part-way leaves no package and asks for the drive',
      () async {
        when(() => performance.dawPackageFiles(any())).thenAnswer(
          (_) => ['master-001.wav', 'master-002.wav'],
        );
        final cubit = await withRecording(take('Evening loop', parts: 2));
        drive
          ..failOnCopy = 2
          ..failure = const StorageFailure.volumeLost(3);

        await cubit.export(LibraryAudioExportKind.dawPackage, purpose: 'p');

        expect(drive.files, isEmpty);
        expect(cubit.state.export, const LibraryExportNeedsDrive());
      },
    );

    test('any other failure is reported, with nothing left behind', () async {
      final cubit = await withRecording(take('Evening loop', parts: 2));
      drive.failOnCopy = 2;

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');

      expect(drive.files, isEmpty);
      expect(cubit.state.error, LibraryAudioError.exportFailed);
    });

    test('Cancel while it runs removes what it placed', () async {
      final cubit = await withRecording(take('Evening loop', parts: 3));
      drive.beforeCopy = (n) {
        if (n == 2) cubit.cancelExport();
      };

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');

      expect(drive.copies, hasLength(2));
      expect(drive.files, isEmpty);
      expect(cubit.state.export, isNull);
      expect(cubit.state.error, isNull);
    });

    test('reports progress while it copies', () async {
      final cubit = await withRecording(take('Evening loop', parts: 2));
      final seen = <double>[];
      final sub = cubit.stream.listen((s) {
        if (s.export case LibraryExportRunning(:final fraction)) {
          seen.add(fraction);
        }
      });
      addTearDown(sub.cancel);

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      await pumpEventQueue();

      expect(seen, [0, 0.5, 1]);
    });

    test("a session's mixdown lands under Sessions, named safely for the "
        'drive', () async {
      when(() => sessions.exportMixdown('s-a', any())).thenAnswer((call) async {
        File(call.positionalArguments[1] as String).writeAsBytesSync([5]);
      });
      final cubit = await withSession('s-a', 'Gig: night?');

      await cubit.export(LibraryAudioExportKind.mixdown, purpose: 'p');

      expect(drive.files, ['Segno/Sessions/Gig- night-.wav']);
      final scratch =
          verify(
                () => sessions.exportMixdown('s-a', captureAny()),
              ).captured.single
              as String;
      expect(File(scratch).existsSync(), isFalse);
      expect(
        cubit.state.export,
        const LibraryExportDone(
          name: 'Gig- night-.wav',
          folder: LibraryAudioFolder.sessions,
        ),
      );
    });

    test("a session's stems land in one directory", () async {
      when(() => sessions.exportStems('s-a', any())).thenAnswer((call) async {
        final dir = call.positionalArguments[1] as String;
        File('$dir/track1_lane0_L0.wav').writeAsBytesSync([1]);
        File('$dir/track0_lane0_L0.wav').writeAsBytesSync([0]);
      });
      final cubit = await withSession('s-a', 'Gig');

      await cubit.export(LibraryAudioExportKind.stems, purpose: 'p');

      expect(drive.files, [
        'Segno/Sessions/Gig stems/track0_lane0_L0.wav',
        'Segno/Sessions/Gig stems/track1_lane0_L0.wav',
      ]);
    });
  });

  group('DAW project', () {
    test('writes it into the recording and says so', () async {
      final capture = take('perf-a');
      final cubit = await withRecording(capture);

      await cubit.writeProject();

      expect(dawWrites, [capture.path]);
      expect(cubit.state.dawProjectWritten, isTrue);
      verify(() => performance.listCaptures()).called(2);
    });

    test('a failed write is reported', () async {
      final cubit = await withRecording(
        take('perf-a'),
        dawProject: (_) async => throw const FileSystemException('full'),
      );

      await cubit.writeProject();

      expect(cubit.state.error, LibraryAudioError.dawProjectFailed);
      expect(cubit.state.dawProjectWritten, isFalse);
    });
  });

  group('Delete', () {
    test('deletes the recording and lists again', () async {
      final capture = take('perf-a');
      when(() => performance.deleteCapture(any())).thenAnswer((_) async {});
      final cubit = await withRecording(capture);
      when(() => performance.listCaptures()).thenAnswer((_) async => []);

      await cubit.deleteRecording();

      verify(() => performance.deleteCapture(capture)).called(1);
      expect(cubit.state.recordings, isEmpty);
      expect(cubit.state.selectedKey, isNull);
    });

    for (final (refusal, error) in <(Object, LibraryAudioError)>[
      (const PerformanceCaptureBusy(), LibraryAudioError.deleteBusy),
      (
        const GuardRefused(wants: GuardKind.sessionWrite, blockers: []),
        LibraryAudioError.deleteBusy,
      ),
      (const FileSystemException('denied'), LibraryAudioError.deleteFailed),
    ]) {
      test('$refusal is reported as ${error.name}', () async {
        when(() => performance.deleteCapture(any())).thenThrow(refusal);
        final cubit = await withRecording(take('perf-a'));

        await cubit.deleteRecording();

        expect(cubit.state.error, error);
        expect(cubit.state.recordings, hasLength(1));
      });
    }
  });

  group('review fixes (#1265)', () {
    test('an export holds the take, so its Delete waits and says for what, '
        'even in a Library opened later', () async {
      final capture = take('Evening loop', parts: 2);
      final cubit = await withRecording(capture);
      final hold = Completer<void>();
      drive.hold = hold;

      final exporting = cubit.export(
        LibraryAudioExportKind.recording,
        purpose: 'Exporting Evening loop',
      );
      await pumpEventQueue();
      expect(
        guards
            .blockers(
              GuardKind.sessionWrite,
              GuardScope.internal(item: capture.path),
            )
            .single
            .purpose,
        'Exporting Evening loop',
      );

      // The page closed and opened again: a fresh cubit sees the hold.
      final later = await withRecording(capture);
      expect(later.state.deleteBlockedBy, 'Exporting Evening loop');

      hold.complete();
      await exporting;
      expect(guards.active, isEmpty);
      expect(cubit.state.deleteBlockedBy, isNull);
      await later.select(later.state.items.single);
      expect(later.state.deleteBlockedBy, isNull);
    });

    test('the DAW package and the DAW project wait for a running render; '
        'the recording itself may go', () async {
      when(() => performance.rendering).thenReturn(true);
      final cubit = await withRecording(take('Evening loop'));

      await cubit.export(LibraryAudioExportKind.dawPackage, purpose: 'p');
      expect(cubit.state.error, LibraryAudioError.stillRendering);
      expect(drive.copies, isEmpty);

      await cubit.writeProject();
      expect(cubit.state.error, LibraryAudioError.stillRendering);
      expect(dawWrites, isEmpty);

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      expect(drive.files, ['Segno/Performances/Evening loop.wav']);
    });

    test('a session export that fails while building its files leaves no '
        'scratch behind', () async {
      String? scratch;
      when(() => sessions.exportStems('s-a', any())).thenAnswer((call) async {
        scratch = call.positionalArguments[1] as String;
        File('$scratch/track0_lane0_L0.wav').writeAsBytesSync([1]);
        throw const FileSystemException('disk full');
      });
      final cubit = await withSession('s-a', 'Gig');

      await cubit.export(LibraryAudioExportKind.stems, purpose: 'p');

      expect(cubit.state.error, LibraryAudioError.exportFailed);
      expect(Directory(scratch!).existsSync(), isFalse);
    });

    test('Replace of a two-part take over an earlier three-part export '
        'leaves no part of the earlier one', () async {
      for (var i = 1; i <= 3; i++) {
        File('${drive.mount}/Segno/Performances/Evening loop · Part 00$i.wav')
          ..createSync(recursive: true)
          ..writeAsBytesSync([9]);
      }
      final cubit = await withRecording(take('Evening loop', parts: 2));

      await cubit.export(LibraryAudioExportKind.recording, purpose: 'p');
      await cubit.resolveConflict(ConflictPolicy.replace);

      expect(drive.files, [
        'Segno/Performances/Evening loop · Part 001.wav',
        'Segno/Performances/Evening loop · Part 002.wav',
      ]);
    });

    test('Preview reads Stop while it decodes, a second press withdraws the '
        'start, and its clock counts at the engine rate', () async {
      final landed = Completer<AuditionStart>();
      bool Function()? wanted;
      when(
        () => performance.startAudition(
          any(),
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer((call) {
        wanted = call.namedArguments[#stillWanted] as bool Function()?;
        return landed.future;
      });
      final cubit = await withRecording(take('Evening loop'));

      final previewing = cubit.preview();
      expect(cubit.state.preview?.starting, isTrue);
      await cubit.preview();
      expect(cubit.state.preview, isNull);
      expect(wanted!(), isFalse);
      verifyNever(() => sessions.stopAudition());
      landed.complete(
        const AuditionStart(result: EngineResult.invalid, cancelled: true),
      );
      await previewing;
      expect(cubit.state.previewRefusal, isNull);

      when(
        () => performance.startAudition(
          any(),
          stillWanted: any(named: 'stillWanted'),
        ),
      ).thenAnswer(
        (_) async => const AuditionStart(
          result: EngineResult.ok,
          frames: 4800,
          rate: 48000,
          sourceRate: 44100,
        ),
      );
      await cubit.preview();
      expect(cubit.state.preview?.sampleRate, 48000);
    });

    test(
      'a start never seen playing is withdrawn when the cubit gives up',
      () async {
        when(
          () => performance.startAudition(
            any(),
            stillWanted: any(named: 'stillWanted'),
          ),
        ).thenAnswer(
          (_) async => const AuditionStart(
            result: EngineResult.ok,
            frames: 4800,
            rate: 48000,
          ),
        );
        final cubit = await withRecording(take('Evening loop'));

        await cubit.preview();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(cubit.state.preview, isNull);
        verify(() => sessions.stopAudition()).called(1);
      },
    );
  });
}
