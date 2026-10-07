import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_drive.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockPerformance extends Mock implements PerformanceRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late AppLocalizations l10n;
  late Directory temp;
  late SessionCubit session;
  late SessionRepository sessions;
  late PerformanceRepository performance;
  late PedalRepository pedal;
  late StreamController<PedalEvent> pedalEvents;
  late FakeDrive drive;
  late CaptureSummary recovered;
  late CaptureSummary single;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
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

  CaptureSummary take(String name, {int parts = 1, bool recovered = false}) {
    final dir = '${temp.path}/exports/$name';
    return CaptureSummary(
      path: dir,
      name: name,
      durationFrames: 48000 * 83 * parts,
      sampleRate: 48000,
      recovered: recovered,
      parts: [
        for (var i = 1; i <= parts; i++)
          CapturePart(
            stream: 0,
            index: i,
            file: 'master-00$i.wav',
            frames: 48000 * 83,
            bytes:
                (File('$dir/master-00$i.wav')
                      ..createSync(recursive: true)
                      ..writeAsBytesSync([i]))
                    .lengthSync(),
          ),
      ],
    );
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_audio_tab');
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    recovered = take('Night set', parts: 3, recovered: true);
    single = take('Evening loop');
    session = _MockSessionCubit();
    whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: const SessionState(),
    );
    when(session.refreshSessions).thenAnswer((_) async {});
    sessions = _MockSessionRepository();
    when(() => sessions.listSessions()).thenAnswer(
      (_) async => const [
        SessionSummary(id: 's-gig', name: 'Gig'),
        SessionSummary(id: 's-empty', name: 'Empty'),
      ],
    );
    when(() => sessions.mixdownOf('s-gig')).thenAnswer(
      (_) async =>
          const SessionMixdown(frames: 48000 * 61, sampleRate: 48000, bytes: 4),
    );
    when(() => sessions.mixdownOf('s-empty')).thenAnswer((_) async => null);
    when(
      () => sessions.readMixdownPeaks(any(), buckets: any(named: 'buckets')),
    ).thenAnswer((_) async => null);
    when(() => sessions.stopAudition()).thenReturn(EngineResult.ok);
    when(
      () => sessions.auditionState(),
    ).thenReturn(const AuditionState(frames: 480000, position: 96000));
    performance = _MockPerformance();
    when(() => performance.rendering).thenReturn(false);
    when(
      () => performance.listCaptures(),
    ).thenAnswer((_) async => [single, recovered]);
    when(
      () => performance.readPeaks(any(), buckets: any(named: 'buckets')),
    ).thenAnswer((_) async => Float32List.fromList([0.2, 0.9, 0.4]));
    pedalEvents = StreamController<PedalEvent>.broadcast();
    pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => pedalEvents.stream);
  });

  tearDown(() async {
    await pedalEvents.close();
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  /// Pumps the Library at the pen's 1920 x 1080 and shows its Audio
  /// section.
  Future<void> openAudio(
    WidgetTester tester, {
    RemovableVolumes? volumes,
    Stream<LooperState> looperStates = const Stream.empty(),
    GuardRegistry? guards,
  }) async {
    final looper = _MockLooperBloc();
    whenListen(looper, looperStates, initialState: const LooperState());
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SessionRepository>.value(value: sessions),
          RepositoryProvider<PerformanceRepository>.value(value: performance),
          RepositoryProvider<PedalRepository>.value(value: pedal),
          RepositoryProvider<GuardRegistry>.value(
            value: guards ?? GuardRegistry(),
          ),
          RepositoryProvider<RemovableVolumes>.value(value: volumes ?? drive),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SessionCubit>.value(value: session),
            BlocProvider<LooperBloc>.value(value: looper),
          ],
          child: const LibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_tab_audio')));
    await tester.pumpAndSettle();
  }

  Future<void> openPerformances(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('library_audio_folder_performances')),
    );
    await tester.pumpAndSettle();
  }

  Finder row(String key) => find.byKey(Key('library_audio_row_$key'));

  Finder inCard(Finder finder) => find.descendant(
    of: find.byKey(const Key('library_audio_card')),
    matching: finder,
  );

  testWidgets('the Audio crumb shows the audio library with its two folders, '
      'and Sessions goes back', (tester) async {
    await openAudio(tester);

    expect(find.text(l10n.libraryAudioTitle), findsOneWidget);
    expect(find.text(l10n.librarySearchAudio), findsOneWidget);
    expect(find.text(l10n.libraryUsbDrive), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('library_audio_folder_performances')),
        matching: find.text('2 files'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('library_audio_folder_sessions')),
        matching: find.text('1 file'),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.libraryAudioNoSelection), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_tab_sessions')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryTitle), findsOneWidget);
  });

  testWidgets('Performances lists every take with its length, the recovered '
      'one marked, and the card describes the selection', (tester) async {
    await openAudio(tester);
    await openPerformances(tester);

    expect(find.text(l10n.libraryAudioPerformances), findsOneWidget);
    expect(
      find.descendant(of: row(single.path), matching: find.text('1:23')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row(recovered.path),
        matching: find.text(l10n.libraryAudioRecovered),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row(single.path),
        matching: find.text(l10n.libraryAudioRecovered),
      ),
      findsNothing,
    );

    await tester.tap(row(recovered.path));
    await tester.pumpAndSettle();

    expect(
      inCard(find.text('WAV · 3 parts · ${l10n.libraryAudioRecovered}')),
      findsOneWidget,
    );
    expect(inCard(find.text('4:09')), findsOneWidget);
    expect(inCard(find.text('Night set')), findsOneWidget);
    expect(inCard(find.byKey(const Key('library_audio_peaks'))), findsOne);
    expect(inCard(find.text(l10n.libraryAudioExportUsb)), findsOneWidget);
    expect(inCard(find.text(l10n.libraryAudioDawProject)), findsOneWidget);
    expect(inCard(find.text(l10n.libraryAudioDelete)), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_audio_parent')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('library_audio_folder_sessions')),
      findsOneWidget,
    );
  });

  testWidgets('Preview plays the selection and shows how far it has played', (
    tester,
  ) async {
    when(
      () => performance.startAudition(
        any(),
        stillWanted: any(named: 'stillWanted'),
      ),
    ).thenAnswer(
      (_) async => const AuditionStart(
        result: EngineResult.ok,
        frames: 480000,
        rate: 48000,
        sourceRate: 48000,
      ),
    );
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_audio_preview')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    verify(
      () => performance.startAudition(
        single,
        stillWanted: any(named: 'stillWanted'),
      ),
    ).called(1);
    expect(find.text(l10n.libraryListenStop), findsOneWidget);
    expect(find.text('0:02 / 0:10'), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_audio_preview')));
    await tester.pump();
    expect(find.text(l10n.libraryAudioPreview), findsOneWidget);
  });

  testWidgets('Export to USB asks which package, copies, and shows where it '
      'landed', (tester) async {
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryAudioChooseRecording), findsOneWidget);
    expect(find.text(l10n.libraryAudioChooseDaw), findsOneWidget);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();

    expect(drive.files, ['Segno/Performances/Evening loop.wav']);
    expect(drive.leases, [l10n.libraryAudioPurpose('Evening loop')]);
    expect(find.text(l10n.libraryAudioExported), findsOneWidget);
    expect(find.text('Evening loop.wav'), findsOneWidget);
    expect(
      find.text(l10n.libraryAudioExportPlace(l10n.libraryAudioPerformances)),
      findsOneWidget,
    );
    expect(find.text(l10n.libraryAudioRecordingKept), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_export_done_button')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryAudioTitle), findsOneWidget);
  });

  testWidgets('Cancel on the chooser exports nothing', (tester) async {
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_export_chooser_cancel')));
    await tester.pumpAndSettle();

    expect(drive.copies, isEmpty);
  });

  testWidgets('20/08 shows the running export, and Cancel leaves nothing', (
    tester,
  ) async {
    final hold = Completer<void>();
    drive.hold = hold;
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(recovered.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pump();
    await tester.pump();

    expect(find.text(l10n.libraryAudioExporting), findsOneWidget);
    expect(
      find.text(l10n.libraryAudioExportRoute(l10n.libraryAudioPerformances)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('library_export_bar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_export_cancel')));
    hold.complete();
    await tester.pumpAndSettle();

    expect(drive.copies, hasLength(1));
    expect(drive.files, isEmpty);
    expect(find.text(l10n.libraryAudioTitle), findsOneWidget);
  });

  testWidgets('a name already on the drive asks first; Keep both writes '
      'beside it', (tester) async {
    File('${drive.mount}/Segno/Performances/Evening loop.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.libraryAudioConflictTitle), findsOneWidget);
    expect(drive.copies, isEmpty);

    await tester.tap(find.byKey(const Key('library_export_keep_both')));
    await tester.pumpAndSettle();

    expect(
      drive.files,
      contains('Segno/Performances/Evening loop (2).wav'),
    );
    expect(find.text('Evening loop (2).wav'), findsOneWidget);
  });

  testWidgets('without a drive, 20/10 asks for one and Cancel closes it', (
    tester,
  ) async {
    await openAudio(tester, volumes: const InternalOnlyVolumes());
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.libraryAudioConnectBody), findsOneWidget);
    await tester.tap(find.byKey(const Key('library_export_try_again')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryAudioConnectBody), findsOneWidget);

    await tester.tap(find.byKey(const Key('library_export_dialog_cancel')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.libraryAudioConnectBody), findsNothing);
  });

  testWidgets('a full drive is reported on the card (20/11)', (tester) async {
    drive.spaceAnswer = const VolumeSpace(totalBytes: 10, freeBytes: 0);
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();

    expect(inCard(find.text(l10n.libraryAudioNotEnoughSpace)), findsOneWidget);
    expect(drive.copies, isEmpty);
  });

  testWidgets('Delete asks first, then deletes the recording', (tester) async {
    when(() => performance.deleteCapture(any())).thenAnswer((_) async {});
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_audio_delete')));
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.libraryAudioDeleteTitle('Evening loop')),
      findsOneWidget,
    );
    await tester.tap(find.text(l10n.libraryAudioDelete).last);
    await tester.pumpAndSettle();

    verify(() => performance.deleteCapture(single)).called(1);
  });

  testWidgets("Sessions lists each session's mixdown with its exports", (
    tester,
  ) async {
    when(() => sessions.exportMixdown('s-gig', any())).thenAnswer((
      call,
    ) async {
      File(call.positionalArguments[1] as String).writeAsBytesSync([5]);
    });
    await openAudio(tester);
    await tester.tap(find.byKey(const Key('library_audio_folder_sessions')));
    await tester.pumpAndSettle();

    expect(row('session:s-empty'), findsNothing);
    await tester.tap(row('session:s-gig'));
    await tester.pumpAndSettle();
    expect(inCard(find.text('1:01')), findsOneWidget);
    expect(inCard(find.text(l10n.libraryAudioExportStems)), findsOneWidget);
    expect(inCard(find.text(l10n.libraryAudioDelete)), findsNothing);

    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();

    expect(drive.files, ['Segno/Sessions/Gig.wav']);
    expect(find.text(l10n.libraryAudioSessionKept), findsOneWidget);
  });

  testWidgets('a track that starts recording ends Preview', (tester) async {
    when(
      () => performance.startAudition(
        any(),
        stillWanted: any(named: 'stillWanted'),
      ),
    ).thenAnswer(
      (_) async => const AuditionStart(
        result: EngineResult.ok,
        frames: 480000,
        rate: 48000,
        sourceRate: 48000,
      ),
    );
    final looperStates = StreamController<LooperState>();
    addTearDown(looperStates.close);
    await openAudio(tester, looperStates: looperStates.stream);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_preview')));
    await tester.pump();
    expect(find.text(l10n.libraryListenStop), findsOneWidget);

    looperStates.add(
      const LooperState(
        tracks: [Track(state: TrackState.recording)],
      ),
    );
    await tester.pump();
    await tester.pump();

    verify(() => sessions.stopAudition()).called(1);
    expect(find.text(l10n.libraryAudioPreview), findsOneWidget);
  });

  testWidgets('going back to Sessions ends Preview', (tester) async {
    when(
      () => performance.startAudition(
        any(),
        stillWanted: any(named: 'stillWanted'),
      ),
    ).thenAnswer(
      (_) async => const AuditionStart(
        result: EngineResult.ok,
        frames: 480000,
        rate: 48000,
        sourceRate: 48000,
      ),
    );
    await openAudio(tester);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_audio_preview')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('library_tab_sessions')));
    await tester.pumpAndSettle();

    verify(() => sessions.stopAudition()).called(1);
  });

  testWidgets('while an export holds the take, Delete is off and the card '
      'says what it waits for', (tester) async {
    final guards = GuardRegistry();
    final held = guards.enter(
      GuardKind.transfer,
      GuardScope.internal(item: single.path),
      purpose: 'Exporting Evening loop',
    );
    addTearDown(held.release);
    await openAudio(tester, guards: guards);
    await openPerformances(tester);
    await tester.tap(row(single.path));
    await tester.pumpAndSettle();

    final delete = tester.widget<LoopOutlinedButton>(
      find.byKey(const Key('library_audio_delete')),
    );
    expect(delete.onTap, isNull);
    expect(
      inCard(find.text(l10n.libraryAudioDeleteWaits('Exporting Evening loop'))),
      findsOneWidget,
    );
  });
}
