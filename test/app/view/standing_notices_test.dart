import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show
        EngineReopened,
        EngineStatus,
        FxAddress,
        FxStage,
        LooperState,
        ReopenOutcome;
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/app/view/standing_notices.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/notices/notices.dart';

import '../../helpers/helpers.dart';
import '../../helpers/text_fit.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockTracksCubit extends MockCubit<TracksState> implements TracksCubit {}

class _MockInputsCubit extends MockCubit<InputsState> implements InputsCubit {}

class _MockOutputsCubit extends MockCubit<OutputsState>
    implements OutputsCubit {}

/// The console's standing conditions as must-act messages (#1562): raised
/// while they hold, cleared the moment they are over, on whatever screen is
/// up.
void main() {
  late _MockAudioSetupCubit audio;
  late StreamController<AudioSetupState> audioStates;
  late _MockLooperBloc looper;
  late StreamController<LooperState> looperStates;
  late NoticesCubit notices;

  const connected = LooperState(status: EngineStatus(isConnected: true));

  setUpAll(() async {
    registerFallbackValue(const LooperFxHoldNoticeDismissed());
    // The console's faces, so a message's body is measured as drawn.
    await loadBundledFonts();
  });

  setUp(() {
    audio = _MockAudioSetupCubit();
    audioStates = StreamController<AudioSetupState>();
    looper = _MockLooperBloc();
    looperStates = StreamController<LooperState>();
    notices = NoticesCubit();
    addTearDown(notices.close);
    // Never awaited: a controller nothing listened to never finishes closing.
    addTearDown(() => unawaited(audioStates.close()));
    addTearDown(() => unawaited(looperStates.close()));
  });

  Future<void> pump(
    WidgetTester tester, {
    AudioSetupState audioState = const AudioSetupState(),
    LooperState looperState = connected,
  }) async {
    whenListen(audio, audioStates.stream, initialState: audioState);
    whenListen(looper, looperStates.stream, initialState: looperState);
    final tracks = _MockTracksCubit();
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(
        names: ['', '', 'Vox', '', '', '', '', ''],
      ),
    );
    final inputs = _MockInputsCubit();
    whenListen(
      inputs,
      const Stream<InputsState>.empty(),
      initialState: const InputsState(names: {0: 'Guitar'}),
    );
    final outputs = _MockOutputsCubit();
    whenListen(
      outputs,
      const Stream<OutputsState>.empty(),
      initialState: const OutputsState(),
    );
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<AudioSetupCubit>.value(value: audio),
          BlocProvider<LooperBloc>.value(value: looper),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<InputsCubit>.value(value: inputs),
          BlocProvider<OutputsCubit>.value(value: outputs),
        ],
        child: const StandingNotices(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 96,
                child: NoticeBar(
                  child: TopBarLayout(
                    leading: SizedBox.shrink(),
                    centre: NoticeBarMessage(),
                    trailing: SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      notices: notices,
    );
    await tester.pump();
  }

  String? bannerId() => notices.state.banner?.notice.id;

  testWidgets('raises nothing while nothing is wrong', (tester) async {
    await pump(tester);
    expect(notices.state.banners, isEmpty);
  });

  group('a lost audio interface', () {
    testWidgets('is critical, names the device and offers Open setup', (
      tester,
    ) async {
      await pump(
        tester,
        audioState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.lost,
          connectivityDeviceName: 'Scarlett 2i2',
        ),
        // The engine stops with it; the engine-stopped message never stands
        // beside it.
        looperState: const LooperState(),
      );
      expect(bannerId(), AppNoticeId.deviceLost);
      expect(notices.state.banners, hasLength(1));
      expect(notices.state.banner?.notice.tone, NoticeTone.critical);
      expect(
        find.text('Scarlett 2i2 disconnected. Nothing is heard.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('deviceLost_setup')), findsOneWidget);
    });

    testWidgets('with no name known says the plain line', (tester) async {
      await pump(
        tester,
        audioState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.lost,
        ),
      );
      expect(find.text('No audio device. Nothing is heard.'), findsOneWidget);
    });

    testWidgets('a boot that waits for it says so, and when it comes back', (
      tester,
    ) async {
      await pump(
        tester,
        audioState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.waiting,
        ),
      );
      expect(bannerId(), AppNoticeId.deviceLost);
      expect(find.text('Waiting for the audio interface'), findsOneWidget);
      expect(find.text('Audio starts when it is back'), findsOneWidget);
    });

    testWidgets('clears the moment the device returns', (tester) async {
      await pump(
        tester,
        audioState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.lost,
        ),
      );
      expect(bannerId(), AppNoticeId.deviceLost);
      audioStates.add(
        const AudioSetupState(deviceConnectivity: DeviceConnectivity.restored),
      );
      await tester.pump();
      expect(notices.state.banners, isEmpty);
    });
  });

  testWidgets('loops cleared on the way back are critical, with Library', (
    tester,
  ) async {
    await pump(
      tester,
      audioState: const AudioSetupState(
        deviceConnectivity: DeviceConnectivity.restoredCleared,
        engineStatus: EngineStatus(
          reopen: EngineReopened(
            outcome: ReopenOutcome.clearedRate,
            droppedTracks: 0,
            sampleRate: 44100,
            previousSampleRate: 48000,
          ),
        ),
      ),
    );
    expect(bannerId(), AppNoticeId.deviceMaterialCleared);
    expect(find.text('The loops were cleared'), findsOneWidget);
    expect(
      find.byKey(const Key('deviceMaterialCleared_library')),
      findsOneWidget,
    );
  });

  group('the engine', () {
    testWidgets('stopped with a device present is critical, with Open '
        'setup', (tester) async {
      await pump(tester, looperState: const LooperState());
      expect(bannerId(), AppNoticeId.engineStopped);
      expect(find.text('Audio engine stopped'), findsOneWidget);
      looperStates.add(connected);
      await tester.pump();
      expect(notices.state.banners, isEmpty);
    });

    testWidgets('starting is neutral and ends by itself', (tester) async {
      await pump(
        tester,
        looperState: const LooperState(
          status: EngineStatus(isConnected: true, warmingUp: true),
        ),
      );
      expect(bannerId(), AppNoticeId.audioStarting);
      expect(notices.state.banner?.notice.tone, NoticeTone.neutral);
      expect(notices.state.banner?.notice.action, isNull);
      looperStates.add(connected);
      await tester.pump();
      expect(notices.state.banners, isEmpty);
    });
  });

  group('effects held off (#1515)', () {
    LooperState held(List<FxAddress> notice) => LooperState(
      status: const EngineStatus(isConnected: true, outputChannels: 4),
      fxHeld: notice.toSet(),
      fxHoldNotice: notice,
    );

    testWidgets('a warning naming the chains, one name per track', (
      tester,
    ) async {
      await pump(
        tester,
        looperState: held(const [
          FxAddress(stage: FxStage.loop, index: 2, lane: 1),
          FxAddress(stage: FxStage.loop, index: 2),
          FxAddress(stage: FxStage.input),
        ]),
      );
      expect(bannerId(), AppNoticeId.fxHeld);
      expect(notices.state.banner?.notice.tone, NoticeTone.warning);
      expect(find.text('Some effects are off'), findsOneWidget);
      expect(find.text("Vox and Guitar's input chain are off"), findsOneWidget);
    });

    testWidgets('offers the fix, Open effects, beside Dismiss', (
      tester,
    ) async {
      await pump(
        tester,
        looperState: held(const [FxAddress(stage: FxStage.allTracks)]),
      );
      expect(find.byKey(const Key(AppNoticeId.fxHeldOpen)), findsOneWidget);
      await tester.tap(find.byKey(const Key(AppNoticeId.fxHeldDismiss)));
      verify(() => looper.add(const LooperFxHoldNoticeDismissed())).called(1);
    });

    test('Open effects goes to the first chain that is off', () {
      expect(
        fxDestinationOf(const FxAddress(stage: FxStage.input, index: 1)),
        const FxDestination.liveInput(1),
      );
      expect(
        fxDestinationOf(const FxAddress(stage: FxStage.track, index: 3)),
        const FxDestination.recordedTrack(3),
      );
      expect(
        fxDestinationOf(const FxAddress(stage: FxStage.output, index: 2)),
        const FxDestination.output(2),
      );
    });

    testWidgets('clears when every chain is back on', (tester) async {
      await pump(
        tester,
        looperState: held(const [FxAddress(stage: FxStage.allTracks)]),
      );
      looperStates.add(connected);
      await tester.pump();
      expect(notices.state.banners, isEmpty);
    });
  });
}
