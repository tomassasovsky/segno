import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

const _rig = LooperState(
  tracks: [Track(), Track(channel: 1)],
  status: EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 4i4 USB',
    inputChannels: 4,
    outputChannels: 4,
  ),
  outputBusCount: 2,
);

/// A Scarlett 4i4 3rd Gen: Inst/Line, Pad and Air on 1-2, one 48 V switch
/// for both, nothing on the rear line inputs 3-4.
InterfaceInputs _fourI4({bool phantom = false}) => InterfaceInputs(
  status: InterfaceInputsStatus.controls,
  inputs: const [
    InterfaceInput(
      level: InputLevel.inst,
      pad: false,
      air: InputAir.off,
      phantomSwitch: 0,
    ),
    InterfaceInput(
      level: InputLevel.line,
      pad: true,
      air: InputAir.presence,
      phantomSwitch: 0,
    ),
  ],
  phantomSwitches: [PhantomSwitch(firstInput: 0, lastInput: 1, on: phantom)],
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> states;
  late InterfaceInputs onInterface;
  late NoticesCubit notices;

  setUpAll(() {
    registerFallbackValue(InputLevel.line);
    registerFallbackValue(InputAir.off);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    states = StreamController<LooperState>.broadcast();
    addTearDown(states.close);
    onInterface = _fourI4();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(_rig);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.meters).thenReturn(const MeterLevels());
    when(
      () => repository.meterLevels,
    ).thenAnswer((_) => const Stream<MeterLevels>.empty());
    when(
      () => repository.readInterfaceInputs(),
    ).thenAnswer((_) async => onInterface);
    when(
      () => repository.setInterfaceInputLevel(any(), any()),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setInterfaceInputPad(any(), on: any(named: 'on')),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setInterfaceInputAir(any(), any()),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setInterfacePhantomPower(any(), on: any(named: 'on')),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.turnOffInterfaceSetupMode(),
    ).thenAnswer((_) async => EngineResult.ok);
  });

  Future<void> pump(WidgetTester tester, {LooperState state = _rig}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
    final inputs = InputsCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(inputs.close()));
    notices = NoticesCubit();
    addTearDown(() => unawaited(notices.close()));
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider.value(value: inputs),
            BlocProvider.value(value: notices),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              extensions: const [
                SurfaceTheme.dark,
                SpacingTheme.standard,
                NoticeTheme.standard,
              ],
            ),
            home: const Scaffold(body: InputSetupTab()),
          ),
        ),
      ),
    );
    // The tab's first read of the interface, then the frame it draws.
    await tester.pump();
    await tester.pump();
  }

  Finder key(String name) => find.byKey(Key(name));

  LoopSwitch switchOf(WidgetTester tester, String name) =>
      tester.widget<LoopSwitch>(key(name));

  group('the interface row', () {
    testWidgets('shows exactly the switches the selected input has', (
      tester,
    ) async {
      await pump(tester);
      expect(key('routing_interface_level'), findsOneWidget);
      expect(
        tester
            .widget<LoopChoiceRow<InputLevel>>(key('routing_interface_level'))
            .selected,
        InputLevel.inst,
      );
      expect(switchOf(tester, 'routing_interface_pad').value, isFalse);
      expect(switchOf(tester, 'routing_interface_air').value, isFalse);
      expect(switchOf(tester, 'routing_interface_phantom').value, isFalse);
      expect(key('routing_interface_air_choice'), findsNothing);

      // Input 2: the pad and Air are on.
      await tester.tap(find.byKey(const Key('routing_input_card_1')));
      await tester.pump();
      expect(switchOf(tester, 'routing_interface_pad').value, isTrue);
      expect(switchOf(tester, 'routing_interface_air').value, isTrue);

      // Input 3, a rear line input, has none.
      await tester.tap(find.byKey(const Key('routing_input_card_2')));
      await tester.pump();
      expect(key('routing_interface_level'), findsNothing);
      expect(key('routing_interface_phantom'), findsNothing);
      expect(key('routing_interface_no_switches'), findsOneWidget);
    });

    testWidgets('a shared 48 V switch shows on both inputs and names both', (
      tester,
    ) async {
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final label = l10n.routingInterfacePhantomInputs(1, 2);
      expect(switchOf(tester, 'routing_interface_phantom').label, label);
      await tester.tap(find.byKey(const Key('routing_input_card_1')));
      await tester.pump();
      expect(switchOf(tester, 'routing_interface_phantom').label, label);
    });

    testWidgets('a three-way Air is a choice', (tester) async {
      onInterface = const InterfaceInputs(
        status: InterfaceInputsStatus.controls,
        inputs: [
          InterfaceInput(
            level: InputLevel.line,
            air: InputAir.presenceDrive,
            airThreeWay: true,
          ),
        ],
      );
      await pump(tester);
      expect(key('routing_interface_air'), findsNothing);
      expect(
        tester
            .widget<LoopChoiceRow<InputAir>>(
              key('routing_interface_air_choice'),
            )
            .selected,
        InputAir.presenceDrive,
      );
      await tester.tap(key('routing_interface_air_presence'));
      await tester.pump();
      verify(() => repository.setInterfaceInputAir(0, InputAir.presence));
    });

    testWidgets('choosing what is already set writes nothing', (tester) async {
      await pump(tester);
      await tester.tap(key('routing_interface_level_inst'));
      await tester.pump();
      verifyNever(() => repository.setInterfaceInputLevel(any(), any()));
    });

    testWidgets('each switch writes the selected input', (tester) async {
      await pump(tester);
      await tester.tap(key('routing_interface_level_line'));
      await tester.tap(key('routing_interface_pad'));
      await tester.tap(key('routing_interface_air'));
      await tester.pump();
      verify(() => repository.setInterfaceInputLevel(0, InputLevel.line));
      verify(() => repository.setInterfaceInputPad(0, on: true));
      verify(() => repository.setInterfaceInputAir(0, InputAir.presence));
    });
  });

  group('48 V', () {
    testWidgets('asks first, naming the inputs, and writes once on confirm', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(key('routing_interface_phantom'));
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.routingPhantomTitle), findsOneWidget);
      expect(find.text(l10n.routingPhantomBodyRange(1, 2)), findsOneWidget);
      verifyNever(
        () => repository.setInterfacePhantomPower(any(), on: any(named: 'on')),
      );
      await tester.tap(find.byKey(const Key('device_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => repository.setInterfacePhantomPower(0, on: true)).called(1);
    });

    testWidgets('a recording that starts while it asks writes nothing', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(key('routing_interface_phantom'));
      await tester.pumpAndSettle();
      const recording = LooperState(
        tracks: [
          Track(state: TrackState.recording, lanes: [Lane(inputChannel: 1)]),
        ],
        status: EngineStatus(
          isConnected: true,
          devicePresent: true,
          deviceName: 'Scarlett 4i4 USB',
          inputChannels: 4,
          outputChannels: 4,
        ),
      );
      when(() => bloc.state).thenReturn(recording);
      states.add(recording);
      await tester.pump();
      await tester.tap(find.byKey(const Key('device_confirm_confirm')));
      await tester.pumpAndSettle();
      verifyNever(
        () => repository.setInterfacePhantomPower(any(), on: any(named: 'on')),
      );
    });

    testWidgets('a cancelled confirmation writes nothing', (tester) async {
      await pump(tester);
      await tester.tap(key('routing_interface_phantom'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_confirm_cancel')));
      await tester.pumpAndSettle();
      verifyNever(
        () => repository.setInterfacePhantomPower(any(), on: any(named: 'on')),
      );
    });

    testWidgets('one input names just that input', (tester) async {
      onInterface = const InterfaceInputs(
        status: InterfaceInputsStatus.controls,
        inputs: [
          InterfaceInput.none,
          InterfaceInput(phantomSwitch: 0),
        ],
        phantomSwitches: [
          PhantomSwitch(firstInput: 1, lastInput: 1, on: false),
        ],
      );
      await pump(tester);
      await tester.tap(find.byKey(const Key('routing_input_card_1')));
      await tester.pump();
      await tester.tap(key('routing_interface_phantom'));
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.routingPhantomBodyOne(2)), findsOneWidget);
    });

    testWidgets('turns off without asking', (tester) async {
      onInterface = _fourI4(phantom: true);
      await pump(tester);
      await tester.tap(key('routing_interface_phantom'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_confirm_dialog')), findsNothing);
      verify(() => repository.setInterfacePhantomPower(0, on: false)).called(1);
    });
  });

  group('the lock', () {
    LooperState recording(int input) => LooperState(
      tracks: [
        Track(
          state: TrackState.recording,
          lanes: [Lane(inputChannel: input)],
        ),
      ],
      status: const EngineStatus(
        isConnected: true,
        devicePresent: true,
        deviceName: 'Scarlett 4i4 USB',
        inputChannels: 4,
        outputChannels: 4,
      ),
    );

    testWidgets('a recording on the input disables the row and says why', (
      tester,
    ) async {
      await pump(tester, state: recording(0));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(switchOf(tester, 'routing_interface_pad').onChanged, isNull);
      expect(switchOf(tester, 'routing_interface_phantom').onChanged, isNull);
      expect(
        tester
            .widget<LoopChoiceRow<InputLevel>>(key('routing_interface_level'))
            .enabled,
        isFalse,
      );
      // The format of the pair locks too: one note says both.
      expect(find.text(l10n.routingLockedSetup), findsOneWidget);

      // Input 3 is free, and its pair with 4.
      await tester.tap(find.byKey(const Key('routing_input_card_2')));
      await tester.pump();
      expect(key('routing_lock_note'), findsNothing);
    });

    testWidgets('a recording on an input the 48 V switch also powers locks '
        'the row', (tester) async {
      onInterface = const InterfaceInputs(
        status: InterfaceInputsStatus.controls,
        inputs: [
          InterfaceInput(pad: false, phantomSwitch: 0),
          InterfaceInput(pad: false, phantomSwitch: 0),
          InterfaceInput(pad: false, phantomSwitch: 0),
          InterfaceInput(pad: false, phantomSwitch: 0),
        ],
        phantomSwitches: [
          PhantomSwitch(firstInput: 0, lastInput: 3, on: false),
        ],
      );
      await pump(tester, state: recording(3));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      // Input 1 is not recording, nor is its pair partner, but the switch
      // that powers it also powers input 4.
      expect(switchOf(tester, 'routing_interface_pad').onChanged, isNull);
      expect(switchOf(tester, 'routing_interface_phantom').onChanged, isNull);
      expect(find.text(l10n.routingLockedInterface), findsOneWidget);
    });
  });

  group('interfaces without switches', () {
    testWidgets('say to use the interface itself', (tester) async {
      onInterface = InterfaceInputs.none;
      await pump(tester);
      expect(key('routing_interface_none'), findsOneWidget);
      expect(key('routing_interface_level'), findsNothing);
    });

    testWidgets('setup mode says so and turns off on request', (tester) async {
      onInterface = const InterfaceInputs(
        status: InterfaceInputsStatus.setupMode,
      );
      await pump(tester);
      expect(key('routing_interface_setup_mode'), findsOneWidget);
      // The test font draws every glyph a full em wide, which pushes the
      // button past the row; press it as the encoder would.
      tester
          .widget<LoopOutlinedButton>(key('routing_interface_setup_mode_off'))
          .onTap!();
      await tester.pump();
      verify(() => repository.turnOffInterfaceSetupMode()).called(1);
    });

    testWidgets('after setup mode, asks for a power cycle', (tester) async {
      onInterface = const InterfaceInputs(
        status: InterfaceInputsStatus.setupModeRestart,
      );
      await pump(tester);
      expect(key('routing_interface_restart'), findsOneWidget);
    });
  });

  group('the input cards', () {
    testWidgets('tag Inst and 48 V where the interface has them set', (
      tester,
    ) async {
      onInterface = _fourI4(phantom: true);
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final first = find.byKey(const Key('routing_input_card_0'));
      final second = find.byKey(const Key('routing_input_card_1'));
      final third = find.byKey(const Key('routing_input_card_2'));
      Finder tag(Finder card, String text) =>
          find.descendant(of: card, matching: find.text(text));
      expect(tag(first, l10n.routingTagInst), findsOneWidget);
      expect(tag(first, l10n.routingTagPhantom), findsOneWidget);
      expect(tag(second, l10n.routingTagInst), findsNothing);
      expect(tag(second, l10n.routingTagPhantom), findsOneWidget);
      expect(tag(third, l10n.routingTagPhantom), findsNothing);
    });
  });

  group('the meter', () {
    for (final interface in [_fourI4(), InterfaceInputs.none]) {
      testWidgets('shows the gain band and how to use it, '
          '${interface.status.name}', (tester) async {
        onInterface = interface;
        await pump(tester);
        expect(
          tester
              .widget<RoutingInputMeter>(
                find.byKey(const Key('routing_input_meter')),
              )
              .target,
          kInputGainTargetDb,
        );
        expect(find.byKey(const Key('routing_gain_note')), findsOneWidget);
      });
    }
  });

  testWidgets('a change the interface refuses is said', (tester) async {
    when(
      () => repository.setInterfaceInputPad(any(), on: any(named: 'on')),
    ).thenAnswer((_) async => EngineResult.device);
    await pump(tester);
    final log = NoticeLog(notices);
    addTearDown(() => unawaited(log.close()));
    await tester.tap(key('routing_interface_pad'));
    await tester.pump();
    await tester.pump();
    expect(log.said(AppNoticeId.interfaceSwitchRefused), isTrue);
    // The message goes by itself.
    await tester.pump(const Duration(seconds: 10));
  });
}
