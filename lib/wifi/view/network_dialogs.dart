import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';

/// A Network page dialog on the pen canvas: a card-toned panel [width] wide,
/// centred on the 1920 x 1080 page and scaled with it, so the appliance draws
/// it 1:1 and a desktop window sees it smaller.
class NetworkDialogFrame extends StatelessWidget {
  /// Creates a [NetworkDialogFrame].
  const NetworkDialogFrame({
    required this.width,
    required this.label,
    required this.child,
    this.padding = const EdgeInsets.all(40),
    super.key,
  });

  /// The panel's width in pen pixels.
  final double width;

  /// The dialog's accessible name.
  final String label;

  /// The panel's content.
  final Widget child;

  /// The content's inset from the panel's edge.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: label,
              child: Material(
                color: surface.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: surface.borderStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: width,
                  child: Padding(padding: padding, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dialogs' heading: 32 px, wrapping a long network name rather than
/// cutting it.
class NetworkDialogTitle extends StatelessWidget {
  /// Creates a [NetworkDialogTitle].
  const NetworkDialogTitle(this.text, {super.key});

  /// The heading.
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: AppText(
      text,
      style: TextStyle(
        color: context.surface.textPrimary,
        fontSize: 32,
        height: 1.25,
      ),
    ),
  );
}

/// The pen's indeterminate progress bar: a 6 px accent bar that sweeps while a
/// join is in flight, and holds still when the platform asks for no motion.
class NetworkProgressBar extends StatefulWidget {
  /// Creates a [NetworkProgressBar].
  const NetworkProgressBar({this.width = 240, super.key});

  /// The track's width.
  final double width;

  @override
  State<NetworkProgressBar> createState() => _NetworkProgressBarState();
}

class _NetworkProgressBarState extends State<NetworkProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      label: context.l10n.networkConnectingTitle,
      child: Container(
        key: const Key('network_progress'),
        width: widget.width,
        height: 6,
        decoration: BoxDecoration(
          color: surface.control,
          borderRadius: BorderRadius.circular(3),
        ),
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) => Align(
            alignment: Alignment(-1 + 2 * _sweep.value, 0),
            child: FractionallySizedBox(
              widthFactor: 0.4,
              child: Container(
                decoration: BoxDecoration(
                  color: surface.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the Connecting dialog (pen 29/03) over a join of [ssid] that has
/// already started on [cubit], until the join ends or Cancel ends it.
///
/// [previous] is the network that was up when the join started: the copy
/// says the console goes back to it if this fails (#1270 D13).
Future<void> showNetworkConnectingDialog(
  BuildContext context, {
  required WifiCubit cubit,
  required String ssid,
  required String? previous,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierColor: context.surface.scrim,
  builder: (_) => BlocProvider.value(
    value: cubit,
    child: _ConnectingDialog(ssid: ssid, previous: previous),
  ),
);

class _ConnectingDialog extends StatefulWidget {
  const _ConnectingDialog({required this.ssid, required this.previous});

  final String ssid;
  final String? previous;

  @override
  State<_ConnectingDialog> createState() => _ConnectingDialogState();
}

class _ConnectingDialogState extends State<_ConnectingDialog> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    // A join that ended before this dialog was built never changes the state
    // again, so the listener below would wait forever.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.read<WifiCubit>().state.connectingSsid != widget.ssid) {
        _close();
      }
    });
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final previous = widget.previous;
    return BlocListener<WifiCubit, WifiState>(
      listenWhen: (before, now) => now.connectingSsid != widget.ssid,
      listener: (_, _) => _close(),
      child: NetworkDialogFrame(
        key: const Key('network_connecting_dialog'),
        width: 860,
        label: l10n.networkConnectingTo(widget.ssid),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NetworkDialogTitle(l10n.networkConnectingTo(widget.ssid)),
            const SizedBox(height: 24),
            const NetworkProgressBar(width: 780),
            const SizedBox(height: 24),
            BlocBuilder<WifiCubit, WifiState>(
              buildWhen: (before, now) => before.retrying != now.retrying,
              builder: (context, state) => AppText(
                state.retrying
                    ? l10n.networkRetrying
                    : previous != null && previous != widget.ssid
                    ? l10n.networkConnectingFallback(previous)
                    : l10n.networkConnectingChecking,
                key: const Key('network_connecting_note'),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(height: 32),
            Align(
              alignment: Alignment.centerRight,
              child: LoopOutlinedButton(
                key: const Key('network_connecting_cancel'),
                width: 180,
                label: l10n.cancel,
                onTap: () {
                  unawaited(context.read<WifiCubit>().cancelConnect());
                  _close();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the musician chose on the Network details dialog.
enum NetworkDetailsAction {
  /// Join the network with the key the console holds (or none, if open).
  connect,

  /// Drop the current connection.
  disconnect,

  /// Give the saved network a new key.
  changePassword,

  /// Remove the saved network, once confirmed.
  forget,
}

/// Shows the Network details dialog (pen 29/05) for [ssid]: its status, and
/// for a saved network Connect automatically, Change password and Forget,
/// then Connect or Disconnect. Connect automatically applies in place; the
/// other choices close the dialog and come back as its result.
Future<NetworkDetailsAction?> showNetworkDetailsDialog(
  BuildContext context, {
  required WifiCubit cubit,
  required String ssid,
}) => showDialog<NetworkDetailsAction>(
  context: context,
  barrierColor: context.surface.scrim,
  builder: (_) => BlocProvider.value(
    value: cubit,
    child: _DetailsDialog(ssid: ssid),
  ),
);

class _DetailsDialog extends StatelessWidget {
  const _DetailsDialog({required this.ssid});

  final String ssid;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<WifiCubit>().state;
    final status = state.status;
    final connected = status.connected && status.ssid == ssid;
    final autoConnect = status.autoConnect[ssid];
    final saved = autoConnect != null;
    final network = state.networks.where((n) => n.ssid == ssid).firstOrNull;
    final secured = network?.secured ?? saved;
    void choose(NetworkDetailsAction action) =>
        Navigator.of(context).pop(action);

    final line = connected
        ? (state.noInternet
              ? l10n.networkConnectedNoInternet
              : l10n.networkConnected)
        : saved
        ? l10n.networkSavedNetwork
        : secured
        ? l10n.networkPasswordRequired
        : l10n.networkOpenNetwork;
    final divider = Divider(height: 1, color: surface.line);

    return NetworkDialogFrame(
      key: const Key('network_details_dialog'),
      width: 880,
      padding: const EdgeInsets.all(36),
      label: ssid,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NetworkDialogTitle(ssid),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 26,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        AppText(
                          line,
                          key: const Key('network_details_status'),
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 22,
                            height: 1.4,
                          ),
                        ),
                        if (connected && status.ip.isNotEmpty)
                          NetworkIpChip(ip: status.ip),
                      ],
                    ),
                  ],
                ),
              ),
              LoopOutlinedButton(
                key: const Key('network_details_close'),
                width: 64,
                tone: LoopButtonTone.frame,
                icon: LucideIcons.x,
                semanticLabel: l10n.networkDetailsClose,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (saved) ...[
            const SizedBox(height: 26),
            divider,
            _DetailRow(
              label: l10n.networkAutoConnect,
              trailing: LoopSwitch(
                key: const Key('network_auto_connect'),
                value: autoConnect,
                semanticLabel: l10n.networkAutoConnect,
                onChanged: state.busy
                    ? null
                    : (value) => unawaited(
                        context.read<WifiCubit>().setAutoConnect(
                          ssid,
                          enabled: value,
                        ),
                      ),
              ),
            ),
            divider,
            if (secured) ...[
              _DetailRow(
                key: const Key('network_change_password'),
                label: l10n.networkChangePassword,
                onTap: state.busy
                    ? null
                    : () => choose(NetworkDetailsAction.changePassword),
              ),
              divider,
            ],
          ],
          const SizedBox(height: 26),
          Row(
            children: [
              if (saved)
                LoopOutlinedButton(
                  key: const Key('network_forget'),
                  width: 240,
                  borderColor: Colors.transparent,
                  label: l10n.wifiForgetConfirmAction,
                  onTap: state.busy
                      ? null
                      : () => choose(NetworkDetailsAction.forget),
                ),
              const Spacer(),
              if (connected)
                LoopOutlinedButton(
                  key: const Key('network_disconnect'),
                  width: 220,
                  label: l10n.networkDisconnect,
                  onTap: state.busy
                      ? null
                      : () => choose(NetworkDetailsAction.disconnect),
                )
              else
                LoopOutlinedButton(
                  key: const Key('network_connect'),
                  width: 220,
                  tone: LoopButtonTone.accent,
                  label: l10n.networkConnect,
                  // A saved network out of range has nothing to join.
                  onTap: state.busy || !(network?.inRange ?? false)
                      ? null
                      : () => choose(NetworkDetailsAction.connect),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One row of the details dialog: its name at the left, then a control, or a
/// chevron when the whole row leads somewhere.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    this.trailing,
    this.onTap,
    super.key,
  });

  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final onTap = this.onTap;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 94),
      child: Row(
        children: [
          Expanded(
            child: AppText(
              label,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 25,
                height: 1.2,
              ),
            ),
          ),
          ?trailing,
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Icon(
                LucideIcons.chevronRight,
                size: 28,
                color: surface.textSecondary,
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: LoopFocusable(
        onActivate: onTap,
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          child: row,
        ),
      ),
    );
  }
}

/// Asks before forgetting the saved network [ssid] (`c/wifi-forget`): the key
/// is deleted from the console. True when confirmed.
Future<bool> showNetworkForgetDialog(
  BuildContext context, {
  required String ssid,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (context) {
      final l10n = context.l10n;
      return NetworkDialogFrame(
        key: const Key('network_forget_dialog'),
        width: 860,
        label: l10n.wifiForgetTitleNamed(ssid),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NetworkDialogTitle(l10n.wifiForgetTitleNamed(ssid)),
            const SizedBox(height: 24),
            LoopNote(l10n.wifiForgetBody),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                LoopOutlinedButton(
                  key: const Key('network_forget_cancel'),
                  width: 180,
                  label: l10n.cancel,
                  onTap: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: 20),
                LoopOutlinedButton(
                  key: const Key('network_forget_confirm'),
                  width: 240,
                  tone: LoopButtonTone.accent,
                  label: l10n.wifiForgetConfirmAction,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  return confirmed ?? false;
}

/// The connection's address beside its status line: "IP 192.168.1.42".
class NetworkIpChip extends StatelessWidget {
  /// Creates a [NetworkIpChip].
  const NetworkIpChip({required this.ip, super.key});

  /// The IPv4 address.
  final String ip;

  @override
  Widget build(BuildContext context) => AppText(
    context.l10n.networkIp(ip),
    key: const Key('network_ip'),
    style: TextStyle(
      color: context.surface.textSecondary,
      fontSize: 20,
      height: 1.4,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}
