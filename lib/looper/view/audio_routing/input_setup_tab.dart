import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/interface_inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/interface_switches_row.dart';
import 'package:segno/looper/view/audio_routing/routing_facts.dart';
import 'package:segno/looper/view/live_meter.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

/// What the Input setup tab draws, read in one `select` so a meter tick does
/// not rebuild the page unless a value it draws moved.
typedef _SetupValues = ({
  InputSetup setup,
  int inputCount,
  int clipMask,
  bool locked,
  bool interfaceLocked,
  int mixGeneration,
});

/// Whether a track fed by [input] is armed or capturing, or holds it for a
/// recording: what freezes a jack's settings.
bool _inputLocked(LooperState state, int input) =>
    inputBusy(state, input) ||
    state.recordingInputLocks.any((channel) {
      final track = state.tracks.where((t) => t.channel == channel);
      return track.any(
        (t) => t.lanes.any((lane) => lane.inputChannel == input),
      );
    });

_SetupValues _setupValues(
  LooperState state,
  int selected,
  InterfaceInputs interface,
) {
  final count = state.status.isConnected && state.status.devicePresent
      ? state.status.inputChannels
      : 0;
  // A device can narrow under a chosen jack. Everything below reads the jack
  // the page can actually show, so the lock cannot end up describing one jack
  // while the controls edit another.
  final input = selected < count ? selected : 0;
  final setup = state.inputSetup;
  final lower = setup.pairOf(input) ?? (input.isEven ? input : input - 1);
  // The interface's switches freeze with every input their 48 V switch
  // powers: a shared switch changes the level of all of them (#1646).
  final phantom = interface.phantomFor(input);
  final first = phantom?.firstInput ?? input;
  final last = phantom?.lastInput ?? input;
  return (
    setup: setup,
    inputCount: count,
    clipMask: state.status.inputClipMask,
    mixGeneration: state.mixGeneration,
    // The accepted lock: pairing and format cannot change while a track fed by
    // EITHER member of the pair is armed or capturing. Both members, because
    // that is the rule `setInputPair` enforces — asking about the shown jack
    // alone would draw a live control the repository then refuses.
    locked: _inputLocked(state, lower) || _inputLocked(state, lower + 1),
    // Only a jack with switches has anything to lock.
    interfaceLocked:
        interface.inputAt(input).hasSwitches &&
        [
          for (var jack = first; jack <= last; jack++) jack,
        ].any((jack) => _inputLocked(state, jack)),
  );
}

/// Input setup (accepted design, Audio routing): pick a jack, set the
/// interface's own switches for it, record it on its own or as one half of a
/// stereo pair, place it, and set the gain the capture branch records it at.
///
/// The interface's switches (#1646) are read while the tab is showing, so a
/// change made on the interface itself shows here.
class InputSetupTab extends StatelessWidget {
  /// Creates an [InputSetupTab].
  const InputSetupTab({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => InterfaceInputsCubit(
      repository: context.read<LooperRepository>(),
    )..startWatching(),
    child: const _InputSetupView(),
  );
}

class _InputSetupView extends StatefulWidget {
  const _InputSetupView();

  @override
  State<_InputSetupView> createState() => _InputSetupTabState();
}

class _InputSetupTabState extends State<_InputSetupView> {
  int _input = 0;

  /// The placement being dragged, so the slider previews without persisting
  /// a value per pointer move; `null` between touches.
  double? _dragPlacement;

  /// The trim being dragged, in dB.
  double? _dragTrim;
  double? _placementBase;
  double? _trimBase;
  String _draftDevice = '';
  int _draftGeneration = -1;
  int _draftInput = -1;
  bool _draftPaired = false;

  /// The pen's card: the cards share the content width, never narrower
  /// than this; past that the rest scroll.
  static const double _cardWidth = 264;
  static const double _cardGap = 16;

  /// The gap between the pan and trim columns, which share the width.
  static const double _columnGap = 64;

  /// Where the format row sits, under the cards.
  static const double _formatTop = 415;

  /// Where the interface's switches sit, under the format row (#1646).
  static const double _interfaceTop = 505;

  /// Where the lock note sits, under the interface row.
  static const double _lockTop = 603;

  /// Where the pan and trim columns sit.
  ///
  /// The lock note is a line of its own between the interface row and these
  /// columns, so they move down by its height rather than sitting under it.
  static double _columnsTop({required bool locked}) => locked ? 669 : 627;

  void _select(int input) => setState(() {
    _input = input;
    _dragPlacement = null;
    _dragTrim = null;
    _placementBase = null;
    _trimBase = null;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final interface = context.watch<InterfaceInputsCubit>().state;
    final values = context.select<LooperBloc, _SetupValues>(
      (bloc) => _setupValues(bloc.state, _input, interface.inputs),
    );
    final named = context.watch<InputsCubit>().state;
    final status = context.read<LooperBloc>().state.status;
    final names =
        status.isConnected &&
            status.devicePresent &&
            named.device == status.deviceName
        ? named
        : const InputsState();
    final count = values.inputCount;
    final input = _input < count ? _input : 0;
    final setup = values.setup;
    final paired = setup.pairOf(input) != null;
    final lower = setup.pairOf(input) ?? (input.isEven ? input : input - 1);
    final device = context.read<LooperBloc>().state.status.deviceName;
    if (_draftDevice != device ||
        _draftGeneration != values.mixGeneration ||
        _draftInput != input ||
        _draftPaired != paired) {
      _draftDevice = device;
      _draftGeneration = values.mixGeneration;
      _draftInput = input;
      _draftPaired = paired;
      _dragPlacement = null;
      _dragTrim = null;
      _placementBase = null;
      _trimBase = null;
    }
    final confirmedPlacement = paired
        ? setup.balanceOf(lower)
        : setup.panOf(input);
    if (_dragPlacement != null && _placementBase != confirmedPlacement) {
      _dragPlacement = null;
      _placementBase = null;
    }
    if (_dragTrim != null && _trimBase != setup.trimDbOf(input)) {
      _dragTrim = null;
      _trimBase = null;
    }
    final placement = _dragPlacement ?? confirmedPlacement;
    final trimDb = _dragTrim ?? setup.trimDbOf(input);
    final clipping = (values.clipMask & (1 << input)) != 0;

    if (count == 0) {
      return Stack(
        children: [
          Positioned(
            left: 0,
            top: 425,
            child: LoopNote(l10n.routingNoPortsYet),
          ),
        ],
      );
    }

    final anyLock = values.locked || values.interfaceLocked;
    return BlocListener<InterfaceInputsCubit, InterfaceInputsState>(
      listenWhen: (previous, current) => current.failures > previous.failures,
      listener: (context, _) => context.read<NoticesCubit>().show(
        Notice(
          id: AppNoticeId.interfaceSwitchRefused,
          tone: NoticeTone.warning,
          title: (l10n) => l10n.routingInterfaceRefused,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 263,
            child: _InputCards(
              count: count,
              selected: input,
              names: names,
              setup: setup,
              interface: interface.inputs,
              onSelected: _select,
            ),
          ),
          Positioned(
            left: 0,
            top: _formatTop,
            child: _FormatRow(
              input: input,
              inputCount: count,
              paired: paired,
              lower: lower,
              names: names,
              locked: values.locked,
            ),
          ),
          Positioned(
            left: 0,
            top: _interfaceTop,
            child: InterfaceSwitchesRow(
              input: input,
              state: interface,
              locked: values.interfaceLocked,
              canChange: () {
                if (!mounted) return false;
                final current = context.read<LooperBloc>().state;
                return current.status.isConnected &&
                    current.status.devicePresent &&
                    current.status.deviceName == device &&
                    current.mixGeneration == values.mixGeneration &&
                    !_setupValues(
                      current,
                      input,
                      context.read<InterfaceInputsCubit>().state.inputs,
                    ).interfaceLocked;
              },
            ),
          ),
          // The lock is a line of its own under the rows, as the pen draws it:
          // it says why a choice is frozen without taking away the sentence
          // that says what the choice currently means.
          if (anyLock)
            Positioned(
              left: _FormatRow.choiceLeft,
              top: _lockTop,
              child: LoopNote(
                key: const Key('routing_lock_note'),
                values.locked && values.interfaceLocked
                    ? l10n.routingLockedSetup
                    : values.locked
                    ? l10n.routingLockedFormat
                    : l10n.routingLockedInterface,
              ),
            ),
          Positioned(
            left: 0,
            top: _columnsTop(locked: anyLock),
            child: _PlacementColumn(
              key: ValueKey((
                input,
                paired,
                confirmedPlacement,
                device,
                values.mixGeneration,
              )),
              label: paired ? l10n.routingBalance : l10n.routingPan,
              value: placement,
              onCancel: () => setState(() {
                _dragPlacement = null;
                _placementBase = null;
              }),
              onReset: () {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent) {
                  return;
                }
                if (paired) {
                  context.read<LooperBloc>().add(
                    LooperInputBalanceChanged(lower, balance: 0),
                  );
                } else {
                  context.read<LooperBloc>().add(
                    LooperInputPanChanged(input, pan: 0),
                  );
                }
              },
              onChanged: (v) => setState(() {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent ||
                    (paired
                            ? current.inputSetup.balanceOf(lower)
                            : current.inputSetup.panOf(input)) !=
                        confirmedPlacement) {
                  return;
                }
                _placementBase ??= confirmedPlacement;
                _dragPlacement = v;
              }),
              onCommit: (v) {
                final current = context.read<LooperBloc>().state;
                final currentInput = input < current.status.inputChannels;
                final currentPlacement = paired
                    ? current.inputSetup.balanceOf(lower)
                    : current.inputSetup.panOf(input);
                final valid =
                    current.status.isConnected &&
                    current.status.devicePresent &&
                    current.status.deviceName == device &&
                    current.mixGeneration == values.mixGeneration &&
                    currentInput &&
                    (current.inputSetup.pairOf(input) != null) == paired &&
                    currentPlacement == _placementBase;
                setState(() {
                  _dragPlacement = null;
                  _placementBase = null;
                });
                if (!valid) return;
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
            right: 0,
            top: _columnsTop(locked: anyLock),
            child: _TrimColumn(
              key: ValueKey((
                input,
                setup.trimDbOf(input),
                device,
                values.mixGeneration,
              )),
              side: paired
                  ? (input == lower
                        ? l10n.routingPairLeft
                        : l10n.routingPairRight)
                  : null,
              trimDb: trimDb,
              input: input,
              clipping: clipping,
              onCancel: () => setState(() {
                _dragTrim = null;
                _trimBase = null;
              }),
              onReset: () {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent) {
                  return;
                }
                context.read<LooperBloc>().add(
                  LooperInputTrimChanged(input, db: 0),
                );
              },
              onChanged: (db) => setState(() {
                final current = context.read<LooperBloc>().state;
                if (current.mixGeneration != values.mixGeneration ||
                    !current.status.devicePresent ||
                    current.inputSetup.trimDbOf(input) !=
                        setup.trimDbOf(input)) {
                  return;
                }
                _trimBase ??= setup.trimDbOf(input);
                _dragTrim = db;
              }),
              onCommit: (db) {
                final current = context.read<LooperBloc>().state;
                final valid =
                    current.status.isConnected &&
                    current.status.devicePresent &&
                    current.status.deviceName == device &&
                    current.mixGeneration == values.mixGeneration &&
                    input < current.status.inputChannels &&
                    current.inputSetup.trimDbOf(input) == _trimBase;
                setState(() {
                  _dragTrim = null;
                  _trimBase = null;
                });
                if (!valid) return;
                context.read<LooperBloc>().add(
                  LooperInputTrimChanged(input, db: db),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InputCards extends StatelessWidget {
  const _InputCards({
    required this.count,
    required this.selected,
    required this.names,
    required this.setup,
    required this.interface,
    required this.onSelected,
  });

  final int count;
  final int selected;
  final InputsState names;
  final InputSetup setup;

  /// The interface's switches, for each card's Inst and 48 V tags.
  final InterfaceInputs interface;
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
    final width = LoopSettingsFrame.contentWidthOf(context);
    return SizedBox(
      width: width,
      height: 112,
      // The cards share the row; eighteen jacks do not fit at a legible
      // width, so past that the row scrolls rather than shrinking them.
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) =>
            const SizedBox(width: _InputSetupTabState._cardGap),
        itemBuilder: (context, index) => RoutingSourceCard(
          key: Key('routing_input_card_$index'),
          width: fillingCardWidth(
            width: width,
            count: count,
            gap: _InputSetupTabState._cardGap,
            minWidth: _InputSetupTabState._cardWidth,
          ),
          ordinal: _ordinal(l10n, index),
          name: l10n.inputName(names.names, index),
          selected: index == selected,
          tags: [
            if (interface.inputAt(index).level == InputLevel.inst)
              l10n.routingTagInst,
            if (interface.phantomFor(index)?.on ?? false)
              l10n.routingTagPhantom,
          ],
          onTap: () => onSelected(index),
        ),
      ),
    );
  }
}

class _FormatRow extends StatelessWidget {
  const _FormatRow({
    required this.input,
    required this.inputCount,
    required this.paired,
    required this.lower,
    required this.names,
    required this.locked,
  });

  final int input;
  final int inputCount;
  final bool paired;
  final int lower;
  final InputsState names;
  final bool locked;

  /// Where the choice starts, after its label.
  static const double choiceLeft = 328;

  /// Wide enough for "Separate mono" at the row's 22 px, so neither label is
  /// scaled down to fit its button.
  static const double _choiceWidth = 400;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: LoopSettingsFrame.contentWidthOf(context),
      height: 74,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 21,
            child: LoopSectionLabel(l10n.routingRecordAs),
          ),
          Positioned(
            left: choiceLeft,
            top: 0,
            child: LoopChoiceRow<bool>(
              values: const [false, true],
              labelOf: (v) =>
                  v ? l10n.routingFormatStereo : l10n.routingFormatMono,
              keyOf: (v) => Key('routing_format_${v ? 'stereo' : 'mono'}'),
              selected: paired,
              enabled: !locked && (paired || lower + 1 < inputCount),
              onSelected: (v) => context.read<LooperBloc>().add(
                LooperInputPairChanged(lower, paired: v),
              ),
              width: _choiceWidth,
              height: 74,
              gap: context.spacing.sm,
              fontSize: 22,
            ),
          ),
          Positioned(
            left: choiceLeft + _choiceWidth + 40,
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
    required this.onCancel,
    required this.onReset,
    super.key,
  });

  /// "Pan" for a mono jack, "Balance" for a linked pair.
  final String label;

  /// The placement in `-1..1`.
  final double value;

  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = LoopSettingsFrame.halfWidthOf(
      context,
      gap: _InputSetupTabState._columnGap,
    );
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
    required this.input,
    required this.clipping,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.onReset,
    super.key,
  });

  /// Which half of a linked pair this jack is, or null for a mono jack.
  final String? side;

  final double trimDb;

  /// The hardware input whose live level the meter follows.
  final int input;
  final bool clipping;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;
  final VoidCallback onReset;

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
    final width = LoopSettingsFrame.halfWidthOf(
      context,
      gap: _InputSetupTabState._columnGap,
    );
    return SizedBox(
      width: width,
      // Tall enough for the clip, gain and trim notes together.
      height: 290,
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
              onEditCancel: (_) => onCancel(),
              onDoubleTap: onReset,
            ),
          ),
          // The meter and its reading follow the input's live level on their
          // own (#1301), so a level tick redraws them and nothing else.
          Positioned.fill(
            child: LiveMeter<double>(
              key: ValueKey(input),
              select: (levels) => meterPeak(levels.inputPeak(input)),
              builder: (context, peak) => Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 124,
                    child: RoutingInputMeter(
                      key: const Key('routing_input_meter'),
                      level: peak,
                      clipping: clipping,
                      width: _meterWidth,
                      semanticLabel: l10n.routingSignal,
                      target: kInputGainTargetDb,
                    ),
                  ),
                  // The reading beside the meter. A held clip says so in
                  // words: the number would be the peak that clipped, which
                  // is the same 0.0 dBFS the meter is already pinned at.
                  Positioned(
                    left: 683,
                    top: 124,
                    width: 145,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AppText(
                        clipping
                            ? l10n.routingClip
                            : routingDbfsLabel(l10n, peak),
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
                ],
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
          // The meter reads the input before the trim, so it is where the
          // interface's gain knob is set: to the band (#1646).
          Positioned(
            left: 0,
            top: clipping ? 234 : 207,
            child: LoopNote(
              l10n.routingGainNote,
              key: const Key('routing_gain_note'),
            ),
          ),
          Positioned(
            left: 0,
            top: clipping ? 261 : 234,
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
