import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/routing_facts.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// What the Input setup tab draws, read in one `select` so a meter tick does
/// not rebuild the page unless a value it draws moved.
typedef _SetupValues = ({
  InputSetup setup,
  int inputCount,
  int clipMask,
  List<double> peaks,
  bool locked,
});

_SetupValues _setupValues(LooperState state, int selected) {
  final count = math.max(state.status.inputChannels, 1);
  // A device can narrow under a chosen jack. Everything below reads the jack
  // the page can actually show, so the lock cannot end up describing one jack
  // while the controls edit another.
  final input = selected < count ? selected : 0;
  final setup = state.inputSetup;
  final lower = setup.pairOf(input) ?? (input.isEven ? input : input - 1);
  return (
    setup: setup,
    inputCount: state.status.inputChannels,
    clipMask: state.status.inputClipMask,
    peaks: state.inputPeaks,
    // The accepted lock: pairing and format cannot change while a track fed by
    // EITHER member of the pair is armed or capturing. Both members, because
    // that is the rule `setInputPair` enforces — asking about the shown jack
    // alone would draw a live control the repository then refuses.
    locked: inputBusy(state, lower) || inputBusy(state, lower + 1),
  );
}

/// Input setup (accepted design, Audio routing): pick a jack, record it on
/// its own or as one half of a stereo pair, place it, and set the gain the
/// capture branch records it at.
class InputSetupTab extends StatefulWidget {
  /// Creates an [InputSetupTab].
  const InputSetupTab({super.key});

  @override
  State<InputSetupTab> createState() => _InputSetupTabState();
}

class _InputSetupTabState extends State<InputSetupTab> {
  int _input = 0;

  /// The placement being dragged, so the slider previews without persisting
  /// a value per pointer move; `null` between touches.
  double? _dragPlacement;

  /// The trim being dragged, in dB.
  double? _dragTrim;

  /// The pen's first four cards; the rest scroll.
  static const double _cardWidth = 264;
  static const double _cardStep = 280;
  static const double _columnWidth = 828;

  /// Where the pan and trim columns sit.
  ///
  /// The lock note is a line of its own between the format row and these
  /// columns, so they move down by its height rather than sitting under it.
  static double _columnsTop({required bool locked}) => locked ? 636 : 563;

  void _select(int input) => setState(() {
    _input = input;
    _dragPlacement = null;
    _dragTrim = null;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _SetupValues>(
      (bloc) => _setupValues(bloc.state, _input),
    );
    final names = context.watch<InputsCubit>().state;
    final count = math.max(values.inputCount, 1);
    final input = _input < count ? _input : 0;
    final setup = values.setup;
    final paired = setup.pairOf(input) != null;
    final lower = setup.pairOf(input) ?? (input.isEven ? input : input - 1);
    final placement =
        _dragPlacement ??
        (paired ? setup.balanceOf(lower) : setup.panOf(input));
    final trimDb = _dragTrim ?? setup.trimDbOf(input);
    final peak = input < values.peaks.length ? values.peaks[input] : 0.0;
    final clipping = (values.clipMask & (1 << input)) != 0;

    return Stack(
      children: [
        Positioned(
          left: 100,
          top: 263,
          child: _InputCards(
            count: count,
            selected: input,
            names: names,
            setup: setup,
            onSelected: _select,
          ),
        ),
        Positioned(
          left: 100,
          top: 431,
          child: _FormatRow(
            input: input,
            paired: paired,
            lower: lower,
            names: names,
            locked: values.locked,
          ),
        ),
        Positioned(
          left: 100,
          top: _columnsTop(locked: values.locked),
          child: _PlacementColumn(
            label: paired ? l10n.routingBalance : l10n.routingPan,
            value: placement,
            onChanged: (v) => setState(() => _dragPlacement = v),
            onCommit: (v) {
              setState(() => _dragPlacement = null);
              final bloc = context.read<LooperBloc>();
              if (paired) {
                bloc.add(LooperInputBalanceChanged(lower, balance: v));
              } else {
                bloc.add(LooperInputPanChanged(input, pan: v));
              }
            },
          ),
        ),
        Positioned(
          left: 992,
          top: _columnsTop(locked: values.locked),
          child: _TrimColumn(
            side: paired
                ? (input == lower
                      ? l10n.routingPairLeft
                      : l10n.routingPairRight)
                : null,
            trimDb: trimDb,
            peak: peak,
            clipping: clipping,
            onChanged: (db) => setState(() => _dragTrim = db),
            onCommit: (db) {
              setState(() => _dragTrim = null);
              context.read<LooperBloc>().add(
                LooperInputTrimChanged(input, db: db),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _InputCards extends StatelessWidget {
  const _InputCards({
    required this.count,
    required this.selected,
    required this.names,
    required this.setup,
    required this.onSelected,
  });

  final int count;
  final int selected;
  final InputsState names;
  final InputSetup setup;
  final ValueChanged<int> onSelected;

  /// The pen's ordinal line: the jack, and which half of a linked pair it is.
  String _ordinal(AppLocalizations l10n, int input) {
    final pair = setup.pairOf(input);
    if (pair == null) return l10n.routingInputOrdinal(input + 1);
    return l10n.routingInputOrdinalSide(
      input + 1,
      setup.isPairLeft(input) ? l10n.routingPairLeft : l10n.routingPairRight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1720,
      height: 112,
      // Eighteen jacks do not fit the pen's four cards, so the row scrolls
      // horizontally rather than shrinking the cards past legibility.
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(
          width: _InputSetupTabState._cardStep - _InputSetupTabState._cardWidth,
        ),
        itemBuilder: (context, index) => RoutingSourceCard(
          key: Key('routing_input_card_$index'),
          ordinal: _ordinal(l10n, index),
          name: l10n.inputName(names.names, index),
          selected: index == selected,
          onTap: () => onSelected(index),
        ),
      ),
    );
  }
}

class _FormatRow extends StatelessWidget {
  const _FormatRow({
    required this.input,
    required this.paired,
    required this.lower,
    required this.names,
    required this.locked,
  });

  final int input;
  final bool paired;
  final int lower;
  final InputsState names;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1720,
      height: 74,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 21,
            child: LoopSectionLabel(l10n.routingRecordAs),
          ),
          Positioned(
            left: 328,
            top: 0,
            child: LoopChoiceRow<bool>(
              values: const [false, true],
              labelOf: (v) =>
                  v ? l10n.routingFormatStereo : l10n.routingFormatMono,
              keyOf: (v) => Key('routing_format_${v ? 'stereo' : 'mono'}'),
              selected: paired,
              enabled: !locked,
              onSelected: (v) => context.read<LooperBloc>().add(
                LooperInputPairChanged(lower, paired: v),
              ),
              width: 345,
              height: 74,
              gap: 5,
              fontSize: 22,
            ),
          ),
          Positioned(
            left: 713,
            top: 22,
            child: paired
                ? RoutingPairMembers(
                    leftName: l10n.inputName(names.names, lower),
                    rightName: l10n.inputName(names.names, lower + 1),
                    leftTag: l10n.routingPairLeft,
                    rightTag: l10n.routingPairRight,
                  )
                : LoopNote(l10n.routingFormatMonoNote),
          ),
          // The lock is a line of its own under the row, as the pen draws it:
          // it says why the choice is frozen without taking away the sentence
          // that says what the choice currently means.
          if (locked)
            Positioned(
              left: 328,
              top: 116,
              child: LoopNote(l10n.routingLockedFormat),
            ),
        ],
      ),
    );
  }
}

class _PlacementColumn extends StatelessWidget {
  const _PlacementColumn({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onCommit,
  });

  /// "Pan" for a mono jack, "Balance" for a linked pair.
  final String label;

  /// The placement in `-1..1`.
  final double value;

  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const width = _InputSetupTabState._columnWidth;
    return SizedBox(
      width: width,
      height: 238,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: RoutingInlineLabel(
              label: label,
              value: routingPlacementLabel(l10n, value),
              width: width,
            ),
          ),
          Positioned(
            left: 0,
            top: 44,
            child: LoopSlider(
              key: const Key('routing_placement_slider'),
              value: (value + 1) / 2,
              width: width,
              semanticLabel: label,
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
              width: width,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrimColumn extends StatelessWidget {
  const _TrimColumn({
    required this.side,
    required this.trimDb,
    required this.peak,
    required this.clipping,
    required this.onChanged,
    required this.onCommit,
  });

  /// Which half of a linked pair this jack is, or null for a mono jack.
  final String? side;

  final double trimDb;
  final double peak;
  final bool clipping;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  static const double _meterWidth = 659;

  double get _fraction =>
      (trimDb - kMinInputTrimDb) / (kMaxInputTrimDb - kMinInputTrimDb);

  double _dbOf(double fraction) {
    final raw =
        kMinInputTrimDb + fraction * (kMaxInputTrimDb - kMinInputTrimDb);
    // The accepted step is half a decibel, so the slider lands on a value the
    // readout can show exactly.
    return (raw / kInputTrimStepDb).roundToDouble() * kInputTrimStepDb;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const width = _InputSetupTabState._columnWidth;
    return SizedBox(
      width: width,
      height: 238,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: RoutingInlineLabel(
              label: side == null
                  ? l10n.routingTrim
                  : l10n.routingTrimSide(side!),
              value: l10n.routingTrimDb(trimDb.toStringAsFixed(1)),
              width: width,
            ),
          ),
          Positioned(
            left: 0,
            top: 44,
            child: LoopSlider(
              key: const Key('routing_trim_slider'),
              value: _fraction.clamp(0.0, 1.0),
              width: width,
              semanticLabel: l10n.routingTrim,
              onChanged: (v) => onChanged(_dbOf(v)),
              onChangeEnd: (v) => onCommit(_dbOf(v)),
            ),
          ),
          Positioned(
            left: 0,
            top: 124,
            child: RoutingInputMeter(
              key: const Key('routing_input_meter'),
              level: peak,
              clipping: clipping,
              width: _meterWidth,
              semanticLabel: l10n.routingSignal,
            ),
          ),
          // The reading beside the meter. A held clip says so in words: the
          // number would be the peak that clipped, which is the same 0.0 dBFS
          // the meter is already pinned at.
          Positioned(
            left: 683,
            top: 124,
            width: 145,
            child: Align(
              alignment: Alignment.centerRight,
              child: AppText(
                clipping ? l10n.routingClip : routingDbfsLabel(l10n, peak),
                key: const Key('routing_input_meter_readout'),
                style: TextStyle(
                  color: clipping
                      ? context.surface.rec
                      : context.surface.textSecondary,
                  fontSize: 22,
                  height: 1,
                ),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            top: 162,
            child: RoutingMeterScale(
              labels: ['−60', '−24', '−12', '0 dBFS'],
              width: _meterWidth,
            ),
          ),
          // Clipping adds a line rather than replacing one: the trim note says
          // what the control below does, which is still true while clipping.
          if (clipping)
            Positioned(
              left: 0,
              top: 183,
              child: LoopNote(
                l10n.routingClipNote,
                tone: LoopNoteTone.error,
              ),
            ),
          Positioned(
            left: 0,
            top: clipping ? 234 : 207,
            child: LoopNote(l10n.routingTrimNote),
          ),
        ],
      ),
    );
  }
}

/// The pen's placement readout: "Center", or the side and how far.
String routingPlacementLabel(AppLocalizations l10n, double value) {
  final percent = (value.abs() * 100).round();
  if (percent == 0) return l10n.routingPanCenter;
  return value < 0
      ? l10n.routingPanLeftAmount(percent)
      : l10n.routingPanRightAmount(percent);
}
