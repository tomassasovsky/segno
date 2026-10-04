import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_availability.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';

/// The only presentation adapter assembling the mapping owners' read models.
ControlAvailability controlAvailability(
  BuildContext context, {
  bool watch = false,
}) {
  final tempo = watch
      ? context.watch<TempoCubit>()
      : context.read<TempoCubit>();
  final playback = watch
      ? context.watch<PlaybackOptionsCubit>()
      : context.read<PlaybackOptionsCubit>();
  final record = watch
      ? context.watch<RecordOptionsCubit>()
      : context.read<RecordOptionsCubit>();
  final timing = watch
      ? context.watch<RecordTimingCubit>()
      : context.read<RecordTimingCubit>();
  return ControlAvailability(
    looper: context.read<LooperRepository>(),
    clickVolume: tempo.state.confirmedClickVolume,
    clickModeSnapshot: tempo.state.clickModeSnapshot,
    recordStartSnapshot: tempo.state.recordStartSnapshot,
    decaySnapshot: playback.state.decaySnapshot,
    oneShotSnapshot: playback.state.oneShotSnapshot,
    recordLengthSnapshot: record.state.options.recordLengthSnapshot,
    recordTimingSnapshot: timing.state.recordTimingSnapshot,
  );
}

List<ExpressionDestination> controlDestinations(
  AppLocalizations l10n,
  List<String> names,
  ControlAvailability availability, {
  bool withActivations = false,
}) => expressionDestinations(
  l10n,
  names,
  availability.looper,
  withActivations: withActivations,
  clickVolume: availability.clickVolume,
  clickModeSnapshot: availability.clickModeSnapshot,
  recordStartSnapshot: availability.recordStartSnapshot,
  decaySnapshot: availability.decaySnapshot,
  oneShotSnapshot: availability.oneShotSnapshot,
  recordLengthSnapshot: availability.recordLengthSnapshot,
  recordTimingSnapshot: availability.recordTimingSnapshot,
);
