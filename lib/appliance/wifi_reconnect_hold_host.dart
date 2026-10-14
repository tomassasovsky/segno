import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/idle_dim_host.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/performance.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// Holds the appliance's background WiFi reconnect while the music plays or
/// records, by the measure that keeps the panels awake ([idleKeepsAwake]).
///
/// A reconnect scans every channel, and a scan takes the radio off-channel;
/// that must not happen mid-show. Released, the reconnect catches up (#1337).
/// The looper emits every poll while music runs, so only a change of the hold
/// is written, and writes go out in order: a quick play-and-stop must not
/// land its release before its hold.
class WifiReconnectHoldHost extends StatefulWidget {
  /// Creates a [WifiReconnectHoldHost] around [child].
  const WifiReconnectHoldHost({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  State<WifiReconnectHoldHost> createState() => _WifiReconnectHoldHostState();
}

class _WifiReconnectHoldHostState extends State<WifiReconnectHoldHost> {
  late final WifiRepository _wifi;

  /// Unknown until the first sync, which therefore always writes: a release
  /// at startup clears a hold a previous run of the app left behind.
  bool? _held;
  Future<void> _writes = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _wifi = context.read<WifiRepository>();
    _sync();
  }

  @override
  void dispose() {
    if (_held ?? false) _write(hold: false);
    super.dispose();
  }

  void _sync() {
    final hold = idleKeepsAwake(
      context.read<LooperBloc>().state,
      context.read<PerformanceRecorderCubit>().state,
    );
    if (hold == _held) return;
    _held = hold;
    _write(hold: hold);
  }

  /// A write that fails must not stop the ones after it: a hold that is never
  /// released would keep the console offline after the show.
  void _write({required bool hold}) => _writes = _writes
      .then((_) => _wifi.holdReconnects(hold: hold))
      .catchError((Object _) {});

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<LooperBloc, LooperState>(listener: (_, _) => _sync()),
      BlocListener<PerformanceRecorderCubit, PerformanceRecorderState>(
        listener: (_, _) => _sync(),
      ),
    ],
    child: widget.child,
  );
}
