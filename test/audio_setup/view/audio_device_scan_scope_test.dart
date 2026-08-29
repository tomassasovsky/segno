import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/view/audio_device_scan_scope.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

const _plugged = AudioDevice(
  id: 'in-9',
  name: 'Scarlett 4i4',
  isDefault: false,
  isInput: true,
);

void main() {
  late LooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> stateController;
  late AudioSetupCubit cubit;

  setUp(() {
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lastEngineConfig).thenReturn(null);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(repository.asioDrivers).thenReturn(const []);
    when(repository.devices).thenReturn(const []);
    cubit = AudioSetupCubit(
      repository: repository,
      settings: settings,
      deviceRefreshInterval: const Duration(milliseconds: 10),
    );
    addTearDown(cubit.close);
    addTearDown(stateController.close);
  });

  Widget wrap(Widget child) => BlocProvider<AudioSetupCubit>.value(
    value: cubit,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: child,
    ),
  );

  testWidgets('nothing polls until a scope is mounted', (tester) async {
    await tester.pumpWidget(wrap(const SizedBox()));
    // Only the cubit's construction-time hydration.
    verify(repository.devices).called(1);

    await tester.pump(const Duration(milliseconds: 60));

    verifyNever(repository.devices);
  });

  testWidgets('a mounted scope enumerates and keeps polling', (tester) async {
    verify(repository.devices).called(1);
    when(repository.devices).thenReturn(const [_plugged]);

    await tester.pumpWidget(
      wrap(const AudioDeviceScanScope(child: SizedBox())),
    );

    // Immediately on mount, so an interface plugged in while nothing was
    // watching is already listed on the frame the picker opens.
    expect(cubit.state.devices, const [_plugged]);
    verify(repository.devices).called(1);

    await tester.pump(const Duration(milliseconds: 60));

    verify(repository.devices).called(greaterThan(1));
  });

  testWidgets('unmounting the scope stops the poll', (tester) async {
    await tester.pumpWidget(
      wrap(const AudioDeviceScanScope(child: SizedBox())),
    );
    await tester.pumpWidget(wrap(const SizedBox()));
    // Construction plus the scope's own mount-time refresh.
    verify(repository.devices).called(greaterThanOrEqualTo(2));

    await tester.pump(const Duration(milliseconds: 60));

    verifyNever(repository.devices);
  });

  testWidgets('the scope renders its child', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AudioDeviceScanScope(
          child: SizedBox(key: Key('picker'), width: 4, height: 4),
        ),
      ),
    );
    expect(find.byKey(const Key('picker')), findsOneWidget);
  });
}
