import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';

/// The single owner of [AudioSetupCubit]'s device re-enumeration poll: the
/// host is re-enumerated while a device picker is on screen, and not
/// otherwise.
///
/// The poll used to run unconditionally from boot at 1 Hz. Enumeration is a
/// synchronous engine call on the UI isolate, and #649 measured 0.146 ms/tick
/// on the appliance's `/proc/asound/cards` path against 950 ms/tick on the
/// miniaudio fall-through — which is what the appliance takes whenever an
/// interface is unplugged, i.e. exactly when the user is trying to get audio
/// back, and on a device whose RT audio thread shares four cores.
///
/// Gating it is safe because nothing outside a picker reads the list: the
/// disconnect banner rides `looperState.status.devicePresent`, and
/// `AudioRecoveryCubit` enumerates through the repository directly.
///
/// Same shape as `CacheTelemetryScope` (#418) and for the same reason — the
/// surfaces that want the data are the ones whose lifetime should bound it —
/// but claimed by REFERENCE COUNT on the cubit rather than pushed as a flag,
/// since there are two such surfaces (the console's Device tab and the desktop
/// audio settings section) and a transition can overlap them.
class AudioDeviceScanScope extends StatefulWidget {
  /// Creates an [AudioDeviceScanScope] polling over [child]'s lifetime.
  const AudioDeviceScanScope({required this.child, super.key});

  /// The picker subtree whose lifetime bounds the enumeration.
  final Widget child;

  @override
  State<AudioDeviceScanScope> createState() => _AudioDeviceScanScopeState();
}

class _AudioDeviceScanScopeState extends State<AudioDeviceScanScope> {
  /// Grabbed in [initState] so [dispose] — where `context.read` on an ancestor
  /// may already be unsafe — can still release the claim. The cubit is
  /// app-scoped and never swapped under this subtree, so it is read once.
  late final AudioSetupCubit _cubit = context.read<AudioSetupCubit>();

  /// Whether the deferred claim actually landed, so an unmount inside the
  /// mounting frame does not release one that was never taken.
  bool _claimed = false;

  @override
  void initState() {
    super.initState();
    // Deferred by one frame ON PURPOSE. `beginDeviceScan` enumerates straight
    // away, and that call is the 950 ms one on the miniaudio fall-through this
    // whole gate exists for — running it inside the frame that mounts the
    // picker would stall the tray's opening animation on exactly the rig state
    // (interface unplugged) that makes someone open it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _claimed = true;
      _cubit.beginDeviceScan();
    });
  }

  @override
  void dispose() {
    if (_claimed) _cubit.endDeviceScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
