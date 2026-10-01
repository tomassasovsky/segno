import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/cubit/session_cubit.dart';

/// Refreshes monitor display state and the boot FX chains after a successful
/// session load. The session cubit saves the complete mix through the shared
/// coordinator before applying the rig; this listener does not write mix
/// settings. A failed load emits no [SessionOutcome.loaded] and does not enter
/// this listener. Lane routing has separate boot keys and is not synchronized
/// here.
class SessionPersistenceSyncListener extends StatelessWidget {
  /// Creates a [SessionPersistenceSyncListener] wrapping [child].
  const SessionPersistenceSyncListener({required this.child, super.key});

  /// The subtree rendered beneath the listener.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) =>
          current.status == SessionStatus.success &&
          current.outcome == SessionOutcome.loaded,
      listener: (context, _) {
        unawaited(context.read<MonitorCubit>().syncFromRepository());
        context.read<LooperBloc>().add(const LooperSessionLoaded());
      },
      child: child,
    );
  }
}
