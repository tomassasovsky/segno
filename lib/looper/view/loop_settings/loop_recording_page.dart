import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

/// The Recording page: how recording starts (Pedal or Sound) and what the
/// second pedal press does (Play or Overdub), with one sentence under the
/// start row saying when the take begins (the pen's `recording-layout`,
/// 1440 x 288 at (240, 398)). A capture in progress locks both rows behind
/// a banner and moves the layout down under it.
class LoopRecordingPage extends StatelessWidget {
  /// Creates a [LoopRecordingPage].
  const LoopRecordingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = context.watch<RecordOptionsCubit>().state;
    final countIn = context.select<TempoCubit, int>(
      (cubit) => cubit.state.countInBars,
    );
    final capturing = context.select<LooperBloc, bool>(
      (bloc) => bloc.state.tracks.any((t) => t.isCapturing),
    );
    final note = options.autoRecord
        ? l10n.loopRecordingNoteSound
        : countIn > 0
        ? l10n.loopRecordingNoteCountIn(countIn)
        : l10n.loopRecordingNotePedal;
    return Positioned.fill(
      child: Stack(
        children: [
          if (capturing)
            Positioned(
              left: 36,
              top: 124,
              child: LoopLockBanner(
                text: l10n.loopRecordingLocked,
                width: 1848,
              ),
            ),
          Positioned(
            left: 240,
            top: capturing ? 444 : 398,
            child: SizedBox(
              width: 1440,
              height: 288,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 32,
                    child: LoopSectionLabel(l10n.loopRecordingStart),
                  ),
                  Positioned(
                    left: 408,
                    top: 0,
                    child: LoopChoiceRow<bool>(
                      values: const [false, true],
                      labelOf: (sound) => sound
                          ? l10n.loopRecordingStartSound
                          : l10n.loopRecordingStartPedal,
                      keyOf: (sound) => Key(
                        sound ? 'loop_recording_sound' : 'loop_recording_pedal',
                      ),
                      selected: options.autoRecord,
                      enabled: !capturing,
                      onSelected: (sound) => unawaited(
                        context.read<RecordOptionsCubit>().setAutoRecord(
                          value: sound,
                        ),
                      ),
                      width: 1032,
                    ),
                  ),
                  Positioned(
                    left: 408,
                    top: 116,
                    child: LoopNote(
                      note,
                      key: const Key('loop_recording_note'),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 224,
                    child: LoopSectionLabel(l10n.loopRecordingSecondPress),
                  ),
                  Positioned(
                    left: 408,
                    top: 192,
                    child: LoopChoiceRow<bool>(
                      values: const [false, true],
                      labelOf: (overdub) => overdub
                          ? l10n.loopRecordingSecondOverdub
                          : l10n.loopRecordingSecondPlay,
                      keyOf: (overdub) => Key(
                        overdub
                            ? 'loop_recording_overdub'
                            : 'loop_recording_play',
                      ),
                      selected: options.recDub,
                      enabled: !capturing,
                      onSelected: (overdub) => unawaited(
                        context.read<RecordOptionsCubit>().setRecDub(
                          value: overdub,
                        ),
                      ),
                      width: 1032,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
