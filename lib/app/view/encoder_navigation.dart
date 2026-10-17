import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/encoder_intents.dart';
import 'package:segno/control/control.dart';

/// Routes the console encoder: the one owner of what a turn or a press means.
///
/// On the stage (no page or dialog above it) a turn is the performance
/// control it always was, master volume or the foot Mixer level, and a press
/// opens Settings, so every page is reachable with the knob alone. With a page,
/// sheet or dialog open the encoder drives focus, the accepted rule: a turn
/// adjusts the focused control's open draft, or else moves focus to the next
/// or previous control; a press activates the focused control, which is how a
/// slider or stepper enters and commits its draft.
class EncoderNavigation extends StatefulWidget {
  /// Creates an [EncoderNavigation] around [child].
  const EncoderNavigation({
    required this.child,
    this.onStagePress = openSegnoSettings,
    super.key,
  });

  /// The app below the navigator's builder.
  final Widget child;

  /// What a press does on the stage: opens Settings.
  final Future<void> Function() onStagePress;

  @override
  State<EncoderNavigation> createState() => _EncoderNavigationState();
}

class _EncoderNavigationState extends State<EncoderNavigation> {
  StreamSubscription<PedalEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = context.read<PedalRepository>().events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _onEvent(PedalEvent event) {
    if (!mounted) return;
    switch (event) {
      case EncoderDelta(:final delta):
        _turn(delta);
      case EncoderPressed():
        _press();
      case ButtonPressed() ||
          ButtonReleased() ||
          EncoderReleased() ||
          CtrlChanged():
        break;
    }
  }

  /// Whether a page, sheet or dialog sits above the stage.
  bool get _overStage => segnoNavigatorKey.currentState?.canPop() ?? false;

  void _turn(int delta) {
    if (delta == 0) return;
    if (!_overStage) {
      context.read<ControlCubit>().encoderTurned(delta);
      return;
    }
    final focused = FocusManager.instance.primaryFocus;
    final target = focused?.context;
    final intent = EncoderTurnIntent(delta);
    if (target != null) {
      final action = Actions.maybeFind<EncoderTurnIntent>(
        target,
        intent: intent,
      );
      if (action != null && action.isEnabled(intent)) {
        Actions.invoke(target, intent);
        return;
      }
    }
    for (var step = 0; step < delta.abs(); step++) {
      final node = FocusManager.instance.primaryFocus;
      if (node == null) return;
      delta > 0 ? node.nextFocus() : node.previousFocus();
    }
  }

  void _press() {
    if (!_overStage) {
      unawaited(widget.onStagePress());
      return;
    }
    final target = FocusManager.instance.primaryFocus?.context;
    if (target == null) return;
    Actions.maybeInvoke(target, const ActivateIntent());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
