import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';

/// The single owner of `LooperRepository.setCacheTelemetryEnabled` (#418):
/// telemetry polls only while the Signal face is actually showing AND the
/// track-indicator preference is on.
///
/// The preference alone used to be the gate, and it defaults ON for desktop
/// builds — so a desktop session paid a per-poll engine sweep from boot, on
/// every screen, for telemetry only the Signal surface renders. The Signal
/// face cannot own the flag itself: the tray sheet is never unmounted (the
/// shell translates it off-screen, and `closeTray` parks the destination back
/// at Signal), so its widget lifecycle says "mounted" even while nothing is
/// visible — and its test harness deliberately does not provide [TracksCubit].
/// Both signals are therefore combined HERE, above the surface, from the two
/// cubits that own them: "showing" is [SettingsTrayCubit]'s open-ness and
/// destination, "wanted" is [TracksCubit]'s indicator preference.
///
/// Plain listeners with no `listenWhen`, mirroring the repository setter's own
/// equality guard: the FIRST TracksCubit emission — the one `load()` makes
/// once the persisted preference has been read — must land even when it
/// compares equal to the compile-time default, and every drag frame of the
/// tray handle is made free by the setter's no-op path rather than filtered
/// here. No initial push is needed: the repository starts with telemetry off
/// and [SettingsTrayCubit] starts closed, so the first flip can only arrive
/// through a listener. Dispose turns telemetry off — leaving this scope (the
/// tracks screen unmounting) is exactly "nobody is looking any more".
class CacheTelemetryScope extends StatefulWidget {
  /// Creates a [CacheTelemetryScope] gating telemetry over [child]'s
  /// lifecycle.
  const CacheTelemetryScope({required this.child, super.key});

  /// The subtree (the tracks screen's stack, tray included) whose lifetime
  /// bounds the telemetry.
  final Widget child;

  @override
  State<CacheTelemetryScope> createState() => _CacheTelemetryScopeState();
}

class _CacheTelemetryScopeState extends State<CacheTelemetryScope> {
  /// Grabbed in [didChangeDependencies] so [dispose] — where `context.read`
  /// on an ancestor may already be unsafe — can still turn telemetry off.
  LooperRepository? _repository;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repository = context.read<LooperRepository>();
  }

  @override
  void dispose() {
    _repository?.setCacheTelemetryEnabled(enabled: false);
    super.dispose();
  }

  void _push(BuildContext context) {
    final wanted = context.read<TracksCubit>().state.showIndicators;
    final tray = context.read<SettingsTrayCubit>().state;
    final signalShowing =
        tray.dragProgress > 0 &&
        tray.destination == SettingsTrayDestination.signal;
    _repository?.setCacheTelemetryEnabled(enabled: wanted && signalShowing);
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<TracksCubit, TracksState>(
        listener: (context, _) => _push(context),
      ),
      BlocListener<SettingsTrayCubit, SettingsTrayState>(
        listener: (context, _) => _push(context),
      ),
    ],
    child: widget.child,
  );
}
