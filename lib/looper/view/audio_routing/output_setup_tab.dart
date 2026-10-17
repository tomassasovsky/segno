import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/live_meter.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// What the Output setup tab draws for the destination being edited.
typedef _OutputValues = ({
  int selected,
  OutputBus bus,
  int busCount,
  int outputChannels,
  int mixGeneration,
});

_OutputValues _outputValues(LooperState state, int chosen) {
  // A device can narrow under a chosen destination. Everything below reads the
  // destination the page can actually show, so the controls cannot go on
  // editing a bus with no card and no jack.
  final count = state.status.isConnected && state.status.devicePresent
      ? state.outputBusCount
      : 0;
  final selected = chosen < count ? chosen : 0;
  return (
    selected: selected,
    bus: state.outputSetup.of(selected),
    busCount: count,
    outputChannels: state.status.outputChannels,
    mixGeneration: state.mixGeneration,
  );
}

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
  double? _levelBase;
  double? _balanceBase;
  String _draftDevice = '';
  int _draftGeneration = -1;
  int _draftBus = -1;
  int _draftChannels = -1;
  bool _draftMono = false;

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
    final named = context.watch<OutputsCubit>().state;
    final status = context.read<LooperBloc>().state.status;
    final names =
        status.isConnected &&
            status.devicePresent &&
            named.device == status.deviceName
        ? named.names
        : const <int, String>{};
    final selected = values.selected;
    final bus = values.bus;
    if (_draftDevice != status.deviceName ||
        _draftGeneration != values.mixGeneration ||
        _draftBus != selected ||
        _draftChannels != values.outputChannels ||
        _draftMono != bus.mono) {
      _draftDevice = status.deviceName;
      _draftGeneration = values.mixGeneration;
      _draftBus = selected;
      _draftChannels = values.outputChannels;
      _draftMono = bus.mono;
      _dragLevel = null;
      _dragBalance = null;
      _levelBase = null;
      _balanceBase = null;
    }
    if (_dragLevel != null && _levelBase != bus.level) {
      _dragLevel = null;
      _levelBase = null;
    }
    if (_dragBalance != null && _balanceBase != bus.balance) {
      _dragBalance = null;
      _balanceBase = null;
    }
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
                selected: bus == selected,
                onTap: () => setState(() {
                  _bus = bus;
                  _dragLevel = null;
                  _dragBalance = null;
                  _levelBase = null;
                  _balanceBase = null;
                }),
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
            child: _FormatRow(
              bus: selected,
              mono: bus.mono,
              muted: bus.muted,
            ),
          ),
          Positioned(
            left: 100,
            top: 563,
            child: _BalanceColumn(
              key: ValueKey((
                selected,
                bus.balance,
                bus.mono,
                status.deviceName,
                values.mixGeneration,
              )),
              balance: balance,
              enabled: !bus.mono,
              onCancel: () => setState(() {
                _dragBalance = null;
                _balanceBase = null;
              }),
              onReset: () {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent) {
                  return;
                }
                context.read<LooperBloc>().add(
                  LooperOutputBalanceChanged(selected, balance: 0),
                );
              },
              onChanged: (v) => setState(() {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent ||
                    current.outputSetup.of(selected).balance != bus.balance) {
                  return;
                }
                _balanceBase ??= bus.balance;
                _dragBalance = v;
              }),
              onCommit: (v) {
                final current = context.read<LooperBloc>().state;
                final valid =
                    current.status.isConnected &&
                    current.status.devicePresent &&
                    current.status.deviceName == status.deviceName &&
                    current.mixGeneration == values.mixGeneration &&
                    current.status.outputChannels == values.outputChannels &&
                    selected < current.outputBusCount &&
                    !current.outputSetup.of(selected).mono &&
                    current.outputSetup.of(selected).balance == _balanceBase;
                setState(() {
                  _dragBalance = null;
                  _balanceBase = null;
                });
                if (!valid) return;
                context.read<LooperBloc>().add(
                  LooperOutputBalanceChanged(selected, balance: v),
                );
              },
            ),
          ),
          Positioned(
            left: 992,
            top: 563,
            child: _LevelColumn(
              key: ValueKey((
                selected,
                bus.level,
                status.deviceName,
                values.mixGeneration,
              )),
              level: level,
              muted: bus.muted,
              bus: selected,
              onCancel: () => setState(() {
                _dragLevel = null;
                _levelBase = null;
              }),
              onReset: () {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent) {
                  return;
                }
                context.read<LooperBloc>().add(
                  LooperOutputLevelChanged(selected, level: 1),
                );
              },
              onChanged: (v) => setState(() {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent ||
                    current.outputSetup.of(selected).level != bus.level) {
                  return;
                }
                _levelBase ??= bus.level;
                _dragLevel = v;
              }),
              onCommit: (v) {
                final current = context.read<LooperBloc>().state;
                final valid =
                    current.status.isConnected &&
                    current.status.devicePresent &&
                    current.status.deviceName == status.deviceName &&
                    current.mixGeneration == values.mixGeneration &&
                    current.status.outputChannels == values.outputChannels &&
                    selected < current.outputBusCount &&
                    current.outputSetup.of(selected).level == _levelBase;
                setState(() {
                  _dragLevel = null;
                  _levelBase = null;
                });
                if (!valid) return;
                context.read<LooperBloc>().add(
                  LooperOutputLevelChanged(selected, level: v),
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
    required this.enabled,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.onReset,
    super.key,
  });

  final double balance;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;
  final VoidCallback onReset;

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
              enabled: enabled,
              onChanged: (v) => onChanged(v * 2 - 1),
              onChangeEnd: (v) => onCommit(v * 2 - 1),
              onEditCancel: (_) => onCancel(),
              onDoubleTap: onReset,
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
    required this.bus,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.onReset,
    super.key,
  });

  final double level;
  final bool muted;
  final int bus;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  /// The pen's output-meter width.
  static const double _meterWidth = 633;

  /// The pen's output-meter cell count.
  static const int _meterCells = 32;

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
              onEditCancel: (_) => onCancel(),
              onDoubleTap: onReset,
            ),
          ),
          for (final (row, side) in [
            (0, l10n.routingPairLeft),
            (1, l10n.routingPairRight),
          ])
            Positioned(
              left: 0,
              top: 124 + 45.0 * row,
              child: muted
                  // A muted destination is putting out nothing, whatever the
                  // engine's last block said.
                  ? _MeterRow(
                      key: Key('output_meter_$row'),
                      side: side,
                      peak: 0,
                    )
                  // The live level, followed by this row alone (#1301).
                  : LiveMeter<double>(
                      key: ValueKey(2 * bus + row),
                      select: (levels) =>
                          meterPeak(levels.outputChannelPeak(2 * bus + row)),
                      builder: (context, peak) => _MeterRow(
                        key: Key('output_meter_$row'),
                        side: side,
                        peak: peak,
                      ),
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
              height: 24,
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
                routingDbfsLabel(l10n, peak),
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
