import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/performance.dart';

/// Whether the music keeps both panels awake: the transport or a track
/// playing, a track recording, or a performance recording running.
bool idleKeepsAwake(LooperState looper, PerformanceRecorderState performance) =>
    looper.transport.isRunning ||
    looper.tracks.any(
      (track) => track.state == TrackState.playing || track.isCapturing,
    ) ||
    performance is PerformanceRecorderArmed;

/// Feeds the [IdleDimCubit] and carries its dim to the panels.
///
/// Activity comes from every way a player acts on the console: touch and
/// keys (here), the encoder and the pedals (the console board's events) and
/// MIDI input. The music's state comes from the looper and the performance
/// recorder. The dim goes to [DisplayBrightnessCubit], which owns what each
/// panel shows.
class IdleDimHost extends StatefulWidget {
  /// Creates an [IdleDimHost] around [child].
  const IdleDimHost({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  State<IdleDimHost> createState() => _IdleDimHostState();
}

class _IdleDimHostState extends State<IdleDimHost> {
  StreamSubscription<PedalEvent>? _pedal;
  StreamSubscription<Object?>? _midi;

  @override
  void initState() {
    super.initState();
    _pedal = context.read<PedalRepository>().events.listen((_) => _activity());
    _midi = context.read<MidiDeviceRepository>().messages.listen(
      (_) => _activity(),
    );
    HardwareKeyboard.instance.addHandler(_onKey);
    _syncBusy();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    unawaited(_pedal?.cancel());
    unawaited(_midi?.cancel());
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _activity();
    return false;
  }

  void _activity() {
    if (mounted) context.read<IdleDimCubit>().activity();
  }

  void _syncBusy() => context.read<IdleDimCubit>().setBusy(
    busy: idleKeepsAwake(
      context.read<LooperBloc>().state,
      context.read<PerformanceRecorderCubit>().state,
    ),
  );

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<LooperBloc, LooperState>(listener: (_, _) => _syncBusy()),
      BlocListener<PerformanceRecorderCubit, PerformanceRecorderState>(
        listener: (_, _) => _syncBusy(),
      ),
      BlocListener<IdleDimCubit, IdleDimState>(
        listenWhen: (previous, current) => previous.dimmed != current.dimmed,
        listener: (context, idle) => context
            .read<DisplayBrightnessCubit>()
            .setDimmed(dimmed: idle.dimmed),
      ),
    ],
    child: IdleDimBarrier(child: widget.child),
  );
}

/// Reports every touch on [child] as activity, and while the panels are
/// dimmed lays a barrier over it: the touch that wakes the console lands on
/// the barrier, so it never presses the control under the finger.
class IdleDimBarrier extends StatelessWidget {
  /// Creates an [IdleDimBarrier] around [child].
  const IdleDimBarrier({required this.child, super.key});

  /// What the barrier covers.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dimmed = context.select<IdleDimCubit, bool>(
      (cubit) => cubit.state.dimmed,
    );
    void wake(PointerDownEvent _) => context.read<IdleDimCubit>().activity();
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: wake,
          child: child,
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !dimmed,
            child: ExcludeSemantics(
              child: Listener(
                key: const Key('idle_dim_wake'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: wake,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
