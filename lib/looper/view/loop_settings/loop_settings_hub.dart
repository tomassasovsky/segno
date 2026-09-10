import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/looper_mode_change.dart';

/// The pages of the Loop settings route: the hub and its six submenus plus
/// the Time signature page the Tempo & click page opens.
enum LoopSettingsPageId {
  /// The six rows.
  hub,

  /// The five mode cards.
  mode,

  /// Pedal or Sound; Play or Overdub.
  recording,

  /// Tempo, click and count-in.
  tempo,

  /// The 17 time signatures.
  signature,

  /// Loop length and record timing.
  length,

  /// Loop/Once and overdub decay.
  playback,

  /// Tempo following and pitch, as a readout.
  audioTempo,
}

/// What the hub summarises beside each row.
typedef _HubValues = ({
  LooperMode mode,
  double bpm,
  int tsNum,
  int tsDen,
});

_HubValues _hubValues(LooperState state) => (
  mode: state.transport.looperMode,
  bpm: state.transport.tempoBpm,
  tsNum: state.transport.tsNum,
  tsDen: state.transport.tsDen,
);

/// The Loop settings hub: the six submenus, each with its current choice
/// beside it (the pen's `loop-menu`). 1848 x 680 at (36, 124) under the
/// title.
class LoopSettingsHub extends StatelessWidget {
  /// Creates a [LoopSettingsHub].
  const LoopSettingsHub({required this.onOpen, super.key});

  /// Opens a submenu.
  final ValueChanged<LoopSettingsPageId> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _HubValues>(
      (bloc) => _hubValues(bloc.state),
    );
    // The defaults are the cubits' own intent (what they persist and push),
    // the same source the pages read, so the hub and a page never show two
    // numbers for one setting.
    final options = context.watch<RecordOptionsCubit>().state;
    final playback = context.watch<PlaybackOptionsCubit>().state;
    final timing = context.watch<RecordTimingCubit>().state;
    // The tempo cubit's own intent, so the hub reads the same number the
    // Tempo page's slider holds; the live transport value only differs
    // while a tap or a derived tempo has moved the engine.
    final tempo = context.watch<TempoCubit>().state;
    final bpm = values.bpm > 0 ? values.bpm : tempo.bpm;
    final signature = timeSignatureLabel(values.tsNum, values.tsDen);
    final order = options.recDub
        ? l10n.loopSummaryRecordOverdubPlay
        : l10n.loopSummaryRecordPlayOverdub;
    final rows = <(LoopSettingsPageId, String, String)>[
      (
        LoopSettingsPageId.mode,
        l10n.loopHubMode,
        looperModeLabels(l10n)[values.mode]!.label,
      ),
      (
        LoopSettingsPageId.recording,
        l10n.loopHubRecording,
        options.autoRecord ? l10n.loopSummarySound(order) : order,
      ),
      (
        LoopSettingsPageId.tempo,
        l10n.loopHubTempo,
        bpm > 0
            ? l10n.loopSummaryTempo(_bpmText(bpm), signature)
            : l10n.loopSummaryTempoUnset(signature),
      ),
      (
        LoopSettingsPageId.length,
        l10n.loopHubLength,
        l10n.loopSummaryPair(
          lengthPresetLabel(l10n, options.defaultLengthBars),
          recordTimingLabels(l10n)[timing]!,
        ),
      ),
      (
        LoopSettingsPageId.playback,
        l10n.loopHubPlayback,
        l10n.loopSummaryPair(
          playback.once ? l10n.loopPlaybackOnce : l10n.loopPlaybackLoop,
          playback.overdubDecay > 0
              ? l10n.loopSummaryDecay(playback.overdubDecay)
              : l10n.loopSummaryNoDecay,
        ),
      ),
      (
        LoopSettingsPageId.audioTempo,
        l10n.loopHubAudioTempo,
        l10n.loopSummaryAudioTempo,
      ),
    ];
    return Positioned(
      left: 36,
      top: 124,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            LoopHubRow(
              key: Key('loop_hub_${rows[i].$1.name}'),
              title: rows[i].$2,
              summary: rows[i].$3,
              onTap: () => onOpen(rows[i].$1),
            ),
          ],
        ],
      ),
    );
  }

  /// A whole BPM reads without decimals; a fine one with two.
  static String _bpmText(double bpm) =>
      bpm == bpm.roundToDouble() ? '${bpm.round()}' : bpm.toStringAsFixed(2);
}
