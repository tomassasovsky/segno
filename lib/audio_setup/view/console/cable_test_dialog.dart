import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/view/device_dialog.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Opens the cable test dialog (pen 28/03) over [context]'s
/// [AudioSetupCubit]. It closes itself when the test is done, cancelled or
/// closed; Cancel and leaving the page cancel a run in flight.
Future<void> showCableTestDialog(BuildContext context) {
  final cubit = context.read<AudioSetupCubit>();
  return showDialog<void>(
    context: context,
    barrierColor: context.surface.scrim,
    barrierDismissible: false,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const CableTestDialog()),
  );
}

/// The cable test: which output sends the pulse and which input listens for
/// it, then Start test.
///
/// The encoder alone can run it: focus starts on the output, then the input,
/// Start test and Cancel. A press on a jack steps it to the next one, the way
/// a turn steps focus.
class CableTestDialog extends StatelessWidget {
  /// Creates a [CableTestDialog].
  const CableTestDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<AudioSetupCubit>().state;
    final cubit = context.read<AudioSetupCubit>();
    final running = state.measurePhase == MeasurePhase.running;
    final outputs = state.engineStatus.outputChannels;
    final inputs = state.engineStatus.inputChannels;
    final refusal = state.refusal?.busyKind;

    return BlocListener<AudioSetupCubit, AudioSetupState>(
      listenWhen: (previous, current) =>
          previous.measurePhase != current.measurePhase &&
          switch (current.measurePhase) {
            MeasurePhase.idle ||
            MeasurePhase.done ||
            MeasurePhase.cancelled => true,
            _ => false,
          },
      // This dialog's own route, which another (the power prompt) may have
      // covered: popping the top route would close that one instead.
      listener: (context, _) {
        final route = ModalRoute.of(context);
        if (route == null) return;
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: DeviceDialog(
          key: const Key('cable_test_dialog'),
          title: l10n.audioCableTitle,
          body: l10n.audioCableBody,
          content: [
            const SizedBox(height: 56),
            Row(
              children: [
                _JackPicker(
                  boxKey: const Key('cable_test_output'),
                  label: l10n.audioCableOutput,
                  jack: state.measureOutput,
                  order: 1,
                  autofocus: true,
                  onStep: running
                      ? null
                      : () => cubit.chooseCableJacks(
                          output: _next(state.measureOutput, outputs),
                        ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 23),
                    child: Container(height: 2, color: surface.textMuted),
                  ),
                ),
                _JackPicker(
                  boxKey: const Key('cable_test_input'),
                  label: l10n.audioCableInput,
                  jack: state.measureInput,
                  order: 2,
                  onStep: running
                      ? null
                      : () => cubit.chooseCableJacks(
                          input: _next(state.measureInput, inputs),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 56),
            AppText(
              state.playbackRunning
                  ? l10n.audioCableNoteStops
                  : l10n.audioCableNote,
              key: const Key('cable_test_note'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 22,
                height: 1.5,
              ),
            ),
            if (state.measurePhase == MeasurePhase.noReturn) ...[
              const SizedBox(height: 16),
              LoopNote(
                l10n.audioCableNoReturn,
                key: const Key('cable_test_no_return'),
                tone: LoopNoteTone.error,
              ),
            ],
            if (refusal != null) ...[
              const SizedBox(height: 16),
              LoopNote(
                l10n.operationBusy(refusal),
                key: const Key('cable_test_refused'),
                tone: LoopNoteTone.error,
              ),
            ],
          ],
          actions: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(4),
              child: LoopOutlinedButton(
                key: const Key('cable_test_cancel'),
                width: 125,
                label: l10n.cancel,
                onTap: cubit.cancelMeasure,
              ),
            ),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: running
                  ? Opacity(
                      opacity: surface.disabledOpacity,
                      child: LoopOutlinedButton(
                        key: const Key('cable_test_measuring'),
                        width: 155,
                        label: l10n.measuringEllipsis,
                        tone: LoopButtonTone.accent,
                        onTap: null,
                      ),
                    )
                  : LoopOutlinedButton(
                      key: const Key('cable_test_start'),
                      width: 155,
                      label: state.measurePhase == MeasurePhase.noReturn
                          ? l10n.audioCableRetry
                          : l10n.audioCableStart,
                      tone: LoopButtonTone.accent,
                      onTap: () => cubit.startCableTest(
                        state.measureOutput,
                        state.measureInput,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The jack after [jack], wrapping past [count] back to 1.
  static int _next(int jack, int count) =>
      count <= 0 || jack >= count ? 1 : jack + 1;
}

/// One jack of the cable: its label and its number in a box a press steps.
class _JackPicker extends StatelessWidget {
  const _JackPicker({
    required this.label,
    required this.jack,
    required this.order,
    required this.onStep,
    required this.boxKey,
    this.autofocus = false,
  });

  final String label;
  final int jack;
  final double order;
  final VoidCallback? onStep;
  final bool autofocus;

  /// The key of the box a press steps.
  final Key boxKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          label,
          style: TextStyle(color: surface.textPrimary, fontSize: 24),
        ),
        const SizedBox(width: 24),
        FocusTraversalOrder(
          order: NumericFocusOrder(order),
          child: Semantics(
            button: true,
            label: '$label $jack',
            child: LoopFocusable(
              key: boxKey,
              autofocus: autofocus,
              enabled: onStep != null,
              onActivate: onStep ?? () {},
              child: GestureDetector(
                onTap: onStep,
                child: Container(
                  width: 100,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: surface.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: surface.frameControlLine),
                  ),
                  child: ExcludeSemantics(
                    child: AppText(
                      '$jack',
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 26,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
