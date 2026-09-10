import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// What the Output setup tab draws for the destination being edited.
typedef _OutputValues = ({
  OutputBus bus,
  int busCount,
  int outputChannels,
  List<double> peaks,
});

_OutputValues _outputValues(LooperState state, int bus) => (
  bus: state.outputSetup.of(bus),
  busCount: state.outputBusCount,
  outputChannels: state.status.outputChannels,
  peaks: state.outputPeaks,
);

/// Output setup (accepted design, Output setup): pick a destination, then the
/// format, level, balance and mute everything routed there is heard through.
class OutputSetupTab extends StatefulWidget {
  /// Creates an [OutputSetupTab].
  const OutputSetupTab({super.key});

  @override
  State<OutputSetupTab> createState() => _OutputSetupTabState();
}

class _OutputSetupTabState extends State<OutputSetupTab> {
  int _bus = kMasterOutputBus;

  /// The value being dragged, so a slider previews without persisting a value
  /// per pointer move; `null` between touches.
  double? _dragLevel;
  double? _dragBalance;

  /// The pen's `source-grid` step.
  static const double _cardStep = 280;

  /// The pen's column width, shared with Input setup.
  static const double _column = 828;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _OutputValues>(
      (bloc) => _outputValues(bloc.state, _bus),
    );
    final names = context.watch<OutputsCubit>().state.names;
    final bus = values.bus;
    final level = _dragLevel ?? bus.level;
    final balance = _dragBalance ?? bus.balance;

    return Stack(
      children: [
        Positioned(
          left: 100,
          top: 263,
          child: SizedBox(
            width: 1720,
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: values.busCount,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: _cardStep - 264),
              itemBuilder: (context, bus) => RoutingSourceCard(
                key: Key('output_card_$bus'),
                ordinal: l10n.outputBusLabel(
                  bus,
                  channels: values.outputChannels,
                ),
                name: l10n.outputName(
                  names,
                  bus,
                  channels: values.outputChannels,
                ),
                selected: bus == _bus,
                onTap: () => setState(() => _bus = bus),
              ),
            ),
          ),
        ),
        if (values.busCount == 0)
          Positioned(
            left: 100,
            top: 425,
            child: LoopNote(l10n.routingNoDestinationsYet),
          )
        else ...[
          Positioned(
            left: 100,
            top: 425,
            child: _FormatRow(bus: _bus, mono: bus.mono, muted: bus.muted),
          ),
          Positioned(
            left: 100,
            top: 563,
            child: _BalanceColumn(
              balance: balance,
              onChanged: (v) => setState(() => _dragBalance = v),
              onCommit: (v) {
                setState(() => _dragBalance = null);
                context.read<LooperBloc>().add(
                  LooperOutputBalanceChanged(_bus, balance: v),
                );
              },
            ),
          ),
          Positioned(
            left: 992,
            top: 563,
            child: _LevelColumn(
              level: level,
              muted: bus.muted,
              peaks: values.peaks,
              bus: _bus,
              onChanged: (v) => setState(() => _dragLevel = v),
              onCommit: (v) {
                setState(() => _dragLevel = null);
                context.read<LooperBloc>().add(
                  LooperOutputLevelChanged(_bus, level: v),
                );
              },
            ),
          ),
          Positioned(
            left: 100,
            top: 807,
            child: LoopNote(l10n.routingOutputAppliesNote),
          ),
        ],
      ],
    );
  }
}

/// The pen's `output-format-row`: Stereo or Mono, and the mute.
class _FormatRow extends StatelessWidget {
  const _FormatRow({
    required this.bus,
    required this.mono,
    required this.muted,
  });

  final int bus;
  final bool mono;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The pen's muted pill is the narrower of the two, right-aligned with the
    // wider one: the control keeps its right edge as its label changes.
    final muteWidth = muted ? 176.0 : 241.0;
    return SizedBox(
      width: 1720,
      height: 74,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: LoopChoiceRow<bool>(
              values: const [false, true],
              labelOf: (v) =>
                  v ? l10n.routingOutputMono : l10n.routingOutputStereo,
              keyOf: (v) => Key('output_format_${v ? 'mono' : 'stereo'}'),
              selected: mono,
              onSelected: (v) => context.read<LooperBloc>().add(
                LooperOutputMonoChanged(bus, mono: v),
              ),
              width: 198,
              height: 74,
              gap: 5,
              fontSize: 22,
            ),
          ),
          if (mono)
            Positioned(
              left: 230,
              top: 22,
              child: LoopNote(l10n.routingOutputMonoNote),
            ),
          Positioned(
            left: 1720 - muteWidth,
            top: 1,
            child: LoopChoiceButton(
              key: const Key('output_mute'),
              label: muted ? l10n.routingOutputMuted : l10n.routingOutputMute,
              icon: muted ? LucideIcons.volumeX : LucideIcons.volume2,
              selected: muted,
              onTap: () => context.read<LooperBloc>().add(
                LooperOutputMuteChanged(bus, muted: !muted),
              ),
              width: muteWidth,
              height: 72,
              fontSize: 22,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pen's left column: where a stereo destination sits between its jacks.
class _BalanceColumn extends StatelessWidget {
  const _BalanceColumn({
    required this.balance,
    required this.onChanged,
    required this.onCommit,
  });

  final double balance;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: _OutputSetupTabState._column,
      height: 196,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: RoutingInlineLabel(
              label: l10n.routingBalance,
              value: routingPlacementLabel(l10n, balance),
              width: _OutputSetupTabState._column,
            ),
          ),
          Positioned(
            left: 0,
            top: 44,
            child: LoopSlider(
              key: const Key('output_balance_slider'),
              value: (balance + 1) / 2,
              width: _OutputSetupTabState._column,
              semanticLabel: l10n.routingBalance,
              onChanged: (v) => onChanged(v * 2 - 1),
              onChangeEnd: (v) => onCommit(v * 2 - 1),
            ),
          ),
          Positioned(
            left: 0,
            top: 124,
            child: RoutingSliderEnds(
              start: l10n.routingPanLeft,
              end: l10n.routingPanRight,
              width: _OutputSetupTabState._column,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pen's right column: how loud the destination is, and what it is
/// putting out right now.
class _LevelColumn extends StatelessWidget {
  const _LevelColumn({
    required this.level,
    required this.muted,
    required this.peaks,
    required this.bus,
    required this.onChanged,
    required this.onCommit,
  });

  final double level;
  final bool muted;
  final List<double> peaks;
  final int bus;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  /// The pen's output-meter width.
  static const double _meterWidth = 633;

  /// The pen's output-meter cell count.
  static const int _meterCells = 32;

  /// The peak hardware output [channel] is putting out, `0` when the rig has
  /// no such jack.
  double _peak(int channel) => channel < peaks.length ? peaks[channel] : 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: _OutputSetupTabState._column,
      height: 196,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: RoutingInlineLabel(
              label: l10n.routingOutputLevel,
              value: l10n.routingOutputLevelPercent((level * 100).round()),
              width: _OutputSetupTabState._column,
            ),
          ),
          Positioned(
            left: 0,
            top: 44,
            child: LoopSlider(
              key: const Key('output_level_slider'),
              value: level.clamp(0.0, 1.0),
              width: _OutputSetupTabState._column,
              semanticLabel: l10n.routingOutputLevel,
              onChanged: onChanged,
              onChangeEnd: onCommit,
            ),
          ),
          for (final (row, side) in [
            (0, l10n.routingPairLeft),
            (1, l10n.routingPairRight),
          ])
            Positioned(
              left: 0,
              top: 124 + 45.0 * row,
              child: _MeterRow(
                key: Key('output_meter_$row'),
                side: side,
                // A muted destination is putting out nothing, whatever the
                // engine's last block said.
                peak: muted ? 0 : _peak(2 * bus + row),
              ),
            ),
        ],
      ),
    );
  }
}

/// One jack's meter and its reading.
class _MeterRow extends StatelessWidget {
  const _MeterRow({required this.side, required this.peak, super.key});

  final String side;
  final double peak;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final db = 20 * (math.log(peak) / math.ln10);
    return SizedBox(
      width: _OutputSetupTabState._column,
      height: 28,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: AppText(
              side,
              style: TextStyle(
                color: context.surface.textTertiary,
                fontSize: 22,
                height: 1,
              ),
            ),
          ),
          Positioned(
            left: 31,
            top: 0,
            child: RoutingInputMeter(
              level: peak,
              clipping: false,
              width: _LevelColumn._meterWidth,
              segments: _LevelColumn._meterCells,
              semanticLabel: side,
            ),
          ),
          Positioned(
            left: 682,
            top: 0,
            width: 146,
            child: Align(
              alignment: Alignment.centerRight,
              child: AppText(
                // Below the meter's floor there is no reading to give, and a
                // large negative number would read as a level rather than as
                // silence.
                peak <= 0 || db < kMeterFloorDb
                    ? l10n.routingOutputSilent
                    : l10n.routingOutputDbfs(db.toStringAsFixed(1)),
                style: TextStyle(
                  color: context.surface.textSecondary,
                  fontSize: 22,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
