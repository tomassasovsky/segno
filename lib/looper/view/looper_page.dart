import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/power_off/power_off_host.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/looper/view/tracks_view.dart';
import 'package:segno/session/session.dart';

/// Projects the shared session and transport owners onto the Tracks surface.
class LooperPage extends StatelessWidget {
  /// Creates the main performance surface.
  const LooperPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocListener<SessionCubit, SessionState>(
        listenWhen: (before, after) =>
            before != after && after.outcome == SessionOutcome.loaded,
        listener: (context, _) =>
            context.read<MonitorCubit>().projectFromRepository(),
        child: const PowerOffHost(child: TracksView()),
      );
}
