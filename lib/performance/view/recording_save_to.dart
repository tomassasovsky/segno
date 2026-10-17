import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/performance/cubit/recording_destination_cubit.dart';
import 'package:segno/storage/view/storage_destination_picker.dart';
import 'package:segno/theme/theme.dart';
import 'package:storage_repository/storage_repository.dart';

/// The recorder's `Save to` row (pen 48 `cH9UX`, `FwjUV`): the destination
/// picker over [RecordingDestinationCubit], locked to the chosen name while a
/// take records, finalizes or renders.
///
/// A drive must sustain twice the frozen format's rate to be offered
/// (headroom for the drain's bursts). Choosing USB with no drive opens the
/// Connect USB sheet.
class RecordingSaveTo extends StatelessWidget {
  /// Creates a [RecordingSaveTo].
  const RecordingSaveTo({super.key});

  @override
  Widget build(BuildContext context) {
    final destination = context.watch<RecordingDestinationCubit>();
    final recorder = context.watch<PerformanceRecorderCubit>().state;
    final state = destination.state;
    final required = state.bytesPerSecond * RecordingDestinationCubit.headroom;
    return StorageDestinationPicker(
      volumes: state.volumes,
      value: state.destination,
      requiredBytesPerSecond: required > 0 ? required : null,
      enabled: switch (recorder) {
        PerformanceRecorderIdle() || PerformanceRecorderCompleted() => true,
        PerformanceRecorderArmed() ||
        PerformanceRecorderFinalizing() ||
        PerformanceRecorderRendering() => false,
      },
      onChanged: (value) => unawaited(destination.choose(value)),
      onConnectUsb: () => unawaited(showConnectUsbSheet(context)),
    );
  }
}

/// Opens the Connect USB sheet over [RecordingDestinationCubit]: it closes on
/// its own once a drive that can take the recording is chosen, and a cancel
/// leaves the take on Internal.
Future<void> showConnectUsbSheet(BuildContext context) async {
  final cubit = context.read<RecordingDestinationCubit>()..awaitDrive();
  if (cubit.state.destination is RemovableDestination) return;
  final chosen = await showDialog<bool>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (dialogContext) =>
        BlocListener<RecordingDestinationCubit, RecordingDestinationState>(
          bloc: cubit,
          // Once: the choice's own remaining-time read emits again, and a
          // second pop would close the page under the sheet.
          listenWhen: (previous, current) =>
              previous.destination is! RemovableDestination &&
              current.destination is RemovableDestination,
          listener: (_, _) => Navigator.of(dialogContext).pop(true),
          child: ConnectUsbSheet(
            onTryAgain: cubit.awaitDrive,
            onCancel: () => Navigator.of(dialogContext).pop(false),
          ),
        ),
  );
  if (chosen != true) cubit.stopAwaitingDrive();
}
