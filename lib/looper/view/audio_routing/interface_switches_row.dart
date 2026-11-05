import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/interface_inputs_cubit.dart';
import 'package:segno/audio_setup/view/device_dialog.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The Input setup tab's "Interface" row (#1646): the switches the audio
/// interface itself has for the selected input — Inst or Line, Pad, Air and
/// 48 V — drawn only where the interface reports them, and written straight
/// to it. An interface that lets no software set them says so in the row's
/// place.
///
/// 48 V asks before it turns on, naming every input the switch powers; it
/// turns off without asking. The row is read-only while [locked].
class InterfaceSwitchesRow extends StatelessWidget {
  /// Creates an [InterfaceSwitchesRow].
  const InterfaceSwitchesRow({
    required this.input,
    required this.state,
    required this.locked,
    required this.canChange,
    super.key,
  });

  /// The selected input, 0-based.
  final int input;

  /// What the interface reports.
  final InterfaceInputsState state;

  /// Whether a recording holds the input (or an input its 48 V switch
  /// powers).
  final bool locked;

  /// Whether the input can still be changed right now: asked again when the
  /// 48 V confirmation closes, since a recording may have started, or the
  /// device changed, while it was open.
  final bool Function() canChange;

  /// The row's height: the format row's.
  static const double height = 74;

  /// Where the controls start, after the label: the format row's choice.
  static const double contentLeft = 328;

  /// The Line / Inst choice.
  static const double levelWidth = 260;

  /// Each option of the three-way Air choice: wide enough for
  /// "Presence + Drive" at the row's 22 px (#1672).
  static const double airOptionWidth = 212;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: LoopSettingsFrame.contentWidthOf(context),
      height: height,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 21,
            child: LoopSectionLabel(l10n.routingInterface),
          ),
          Positioned(
            left: contentLeft,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _content(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final l10n = context.l10n;
    if (!state.loaded) return const SizedBox.shrink();
    final inputs = state.inputs;
    switch (inputs.status) {
      case InterfaceInputsStatus.noControls:
        return LoopNote(
          l10n.routingInterfaceNone,
          key: const Key('routing_interface_none'),
        );
      case InterfaceInputsStatus.setupMode:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LoopNote(
              l10n.routingInterfaceSetupMode,
              key: const Key('routing_interface_setup_mode'),
            ),
            const SizedBox(width: 32),
            LoopOutlinedButton(
              key: const Key('routing_interface_setup_mode_off'),
              width: 460,
              label: l10n.routingInterfaceSetupModeOff,
              onTap: () =>
                  context.read<InterfaceInputsCubit>().turnOffSetupMode(),
            ),
          ],
        );
      case InterfaceInputsStatus.setupModeRestart:
        return LoopNote(
          l10n.routingInterfaceRestart,
          key: const Key('routing_interface_restart'),
        );
      case InterfaceInputsStatus.controls:
        final switches = inputs.inputAt(input);
        if (!switches.hasSwitches) {
          return LoopNote(
            l10n.routingInterfaceNoSwitches,
            key: const Key('routing_interface_no_switches'),
          );
        }
        return _Switches(
          input: input,
          switches: switches,
          phantom: inputs.phantomFor(input),
          phantomIndex: switches.phantomSwitch,
          locked: locked,
          canChange: canChange,
        );
    }
  }
}

class _Switches extends StatelessWidget {
  const _Switches({
    required this.input,
    required this.switches,
    required this.phantom,
    required this.phantomIndex,
    required this.locked,
    required this.canChange,
  });

  final int input;
  final InterfaceInput switches;
  final PhantomSwitch? phantom;
  final int? phantomIndex;
  final bool locked;
  final bool Function() canChange;

  /// The visible gap between the row's controls.
  static const double _gap = 32;

  Future<void> _phantomChanged(BuildContext context, {required bool on}) async {
    final cubit = context.read<InterfaceInputsCubit>();
    final index = phantomIndex;
    final phantom = this.phantom;
    if (index == null || phantom == null) return;
    if (!on) {
      cubit.setPhantomPower(index, on: false);
      return;
    }
    final l10n = context.l10n;
    final confirmed = await showDeviceConfirmDialog(
      context,
      title: l10n.routingPhantomTitle,
      body: phantom.firstInput == phantom.lastInput
          ? l10n.routingPhantomBodyOne(phantom.firstInput + 1)
          : l10n.routingPhantomBodyRange(
              phantom.firstInput + 1,
              phantom.lastInput + 1,
            ),
      confirmLabel: l10n.routingPhantomConfirm,
    );
    if (!confirmed || cubit.isClosed || !canChange()) return;
    // The switch the dialog named must still be the one that powers this
    // input.
    final now = cubit.state.inputs;
    final still = now.phantomFor(input);
    if (now.inputAt(input).phantomSwitch != index ||
        still == null ||
        still.firstInput != phantom.firstInput ||
        still.lastInput != phantom.lastInput) {
      return;
    }
    cubit.setPhantomPower(index, on: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<InterfaceInputsCubit>();
    final level = switches.level;
    final pad = switches.pad;
    final air = switches.air;
    final phantom = this.phantom;
    final phantomLabel = phantom == null
        ? ''
        : phantom.firstInput == phantom.lastInput
        ? l10n.routingInterfacePhantom
        : l10n.routingInterfacePhantomInputs(
            phantom.firstInput + 1,
            phantom.lastInput + 1,
          );
    // Each control with how far its ink sits inside its box: a switch's
    // touch margin.
    const switchMargin = LoopSwitch.touchMargin;
    final controls = <(Widget, double)>[
      if (level != null)
        (
          LoopChoiceRow<InputLevel>(
            key: const Key('routing_interface_level'),
            values: InputLevel.values,
            labelOf: (v) => switch (v) {
              InputLevel.line => l10n.routingInterfaceLine,
              InputLevel.inst => l10n.routingInterfaceInst,
            },
            keyOf: (v) => Key('routing_interface_level_${v.name}'),
            selected: level,
            enabled: !locked,
            onSelected: (v) {
              if (v != level) cubit.setLevel(input, v);
            },
            width: InterfaceSwitchesRow.levelWidth,
            height: InterfaceSwitchesRow.height,
            gap: context.spacing.sm,
            fontSize: 22,
          ),
          0.0,
        ),
      if (pad != null)
        (
          LoopSwitch(
            key: const Key('routing_interface_pad'),
            label: l10n.routingInterfacePad,
            semanticLabel: l10n.routingInterfacePad,
            value: pad,
            onChanged: locked ? null : (on) => cubit.setPad(input, on: on),
          ),
          switchMargin,
        ),
      if (air != null && !switches.airThreeWay)
        (
          LoopSwitch(
            key: const Key('routing_interface_air'),
            label: l10n.routingInterfaceAir,
            semanticLabel: l10n.routingInterfaceAir,
            value: air != InputAir.off,
            onChanged: locked
                ? null
                : (on) => cubit.setAir(
                    input,
                    on ? InputAir.presence : InputAir.off,
                  ),
          ),
          switchMargin,
        ),
      if (air != null && switches.airThreeWay)
        (
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoopSectionLabel(l10n.routingInterfaceAir, fontSize: 26),
              const SizedBox(width: 26),
              LoopChoiceRow<InputAir>(
                key: const Key('routing_interface_air_choice'),
                values: InputAir.values,
                labelOf: (v) => switch (v) {
                  InputAir.off => l10n.routingInterfaceAirOff,
                  InputAir.presence => l10n.routingInterfaceAirPresence,
                  InputAir.presenceDrive => l10n.routingInterfaceAirDrive,
                },
                keyOf: (v) => Key('routing_interface_air_${v.name}'),
                selected: air,
                enabled: !locked,
                onSelected: (v) {
                  if (v != air) cubit.setAir(input, v);
                },
                width:
                    InputAir.values.length *
                        InterfaceSwitchesRow.airOptionWidth +
                    (InputAir.values.length - 1) * context.spacing.sm,
                height: InterfaceSwitchesRow.height,
                gap: context.spacing.sm,
                fontSize: 22,
              ),
            ],
          ),
          0.0,
        ),
      if (phantom != null)
        (
          LoopSwitch(
            key: const Key('routing_interface_phantom'),
            label: phantomLabel,
            semanticLabel: phantomLabel,
            value: phantom.on,
            onChanged: locked ? null : (on) => _phantomChanged(context, on: on),
          ),
          switchMargin,
        ),
    ];
    // One visible gap between controls: a switch's touch margin counts
    // towards it, and a leading switch's margin sits left of the column so
    // its label starts on the column line.
    final lead = controls.isEmpty ? 0.0 : controls.first.$2;
    return Transform.translate(
      offset: Offset(-lead, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < controls.length; i++) ...[
            if (i > 0)
              SizedBox(width: _gap - controls[i - 1].$2 - controls[i].$2),
            controls[i].$1,
          ],
        ],
      ),
    );
  }
}
