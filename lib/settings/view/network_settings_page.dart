import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/view/network_dialogs.dart';
import 'package:segno/wifi/view/network_password_sheet.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:segno/wifi/wifi_join_failure.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// Settings > Network (pen 29): the Wi-Fi switch in the title row, the
/// connection card, and every network the console can see or has saved.
///
/// Owns its [WifiCubit] for as long as it is open, so the radio is read, and
/// the internet checked, only while the page is on screen.
class NetworkSettingsPage extends StatelessWidget {
  /// Creates a [NetworkSettingsPage].
  ///
  /// [repository] overrides the provided [WifiRepository], for tests.
  const NetworkSettingsPage({this.repository, super.key});

  /// Optional repository override.
  final WifiRepository? repository;

  /// How often the open page re-reads the connection and the internet.
  static const Duration refreshInterval = WifiCubit.connectivityInterval;

  /// The content's inset in the frame's main area: the pen's 100 px page
  /// margins, starting under the title row.
  static const EdgeInsets inset = EdgeInsets.fromLTRB(100, 120, 100, 40);

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) =>
        WifiCubit(repository: repository ?? context.read<WifiRepository>()),
    child: const _NetworkView(),
  );
}

class _NetworkView extends StatefulWidget {
  const _NetworkView();

  @override
  State<_NetworkView> createState() => _NetworkViewState();
}

class _NetworkViewState extends State<_NetworkView> {
  Timer? _refresh;

  WifiCubit get _cubit => context.read<WifiCubit>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final cubit = _cubit;
      await cubit.load();
      if (!mounted || !cubit.state.supported) return;
      _refresh = Timer.periodic(
        NetworkSettingsPage.refreshInterval,
        (_) => unawaited(cubit.refresh()),
      );
      if (cubit.state.status.enabled) await cubit.scan();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// Switches the radio; switched on, it looks for networks at once.
  Future<void> _setEnabled(bool enabled) async {
    final cubit = _cubit;
    await cubit.setEnabled(enabled: enabled);
    if (enabled && cubit.state.status.enabled) await cubit.scan();
  }

  /// Asks for [ssid]'s password and joins with it. [change] gives a saved
  /// network a new key instead; [error] says why the sheet is back.
  Future<void> _askPassword(
    String ssid, {
    bool change = false,
    String? error,
  }) async {
    final psk = await showNetworkPasswordSheet(
      context,
      ssid: ssid,
      error: error,
    );
    if (psk == null || !mounted) return;
    await _connect(ssid, psk: psk, change: change);
  }

  /// Joins [ssid], showing the Connecting dialog while it runs. A key the
  /// network refused goes back to the sheet that typed it (pen 29/04).
  Future<void> _connect(
    String ssid, {
    String? psk,
    bool change = false,
  }) async {
    final cubit = _cubit;
    final status = cubit.state.status;
    final previous = status.connected ? status.ssid : null;
    final join = change && psk != null
        ? cubit.changePassword(ssid, psk)
        : cubit.connect(ssid, psk: psk);
    if (cubit.state.connectingSsid == ssid) {
      await showNetworkConnectingDialog(
        context,
        cubit: cubit,
        ssid: ssid,
        previous: previous,
      );
    }
    await join;
    if (!mounted) return;
    final state = cubit.state;
    if (state.failedSsid == ssid &&
        state.errorKind == WifiJoinErrorKind.credentials) {
      await _askPassword(
        ssid,
        change: change,
        error: context.l10n.wifiConnectFailedPassword,
      );
    }
  }

  Future<void> _details(String ssid) async {
    final cubit = _cubit;
    final action = await showNetworkDetailsDialog(
      context,
      cubit: cubit,
      ssid: ssid,
    );
    if (!mounted) return;
    switch (action) {
      case null:
        return;
      case NetworkDetailsAction.connect:
        await _connect(ssid);
      case NetworkDetailsAction.disconnect:
        await cubit.disconnect();
      case NetworkDetailsAction.changePassword:
        await _askPassword(ssid, change: true);
      case NetworkDetailsAction.forget:
        if (await showNetworkForgetDialog(context, ssid: ssid)) {
          await cubit.forget(ssid);
        }
    }
  }

  void _open(WifiNetwork network) {
    final saved = network.saved;
    // A secured network the console holds no key for has one thing to do:
    // take a password. Everything else opens its details.
    if (network.secured && !saved) {
      unawaited(_askPassword(network.ssid));
    } else {
      unawaited(_details(network.ssid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<WifiCubit>().state;
    final title = l10n.settingsNetworkTitle;
    final on = state.status.enabled;
    final idle = !state.busy && state.connectingSsid == null;

    return BlocListener<WifiCubit, WifiState>(
      // A new connection is checked at once; the timer keeps it fresh.
      listenWhen: (before, now) =>
          now.status.connected &&
          (!before.status.connected || before.status.ssid != now.status.ssid),
      listener: (_, _) => unawaited(_cubit.checkConnectivity()),
      child: Scaffold(
        body: LoopSettingsFrame(
          crumb: l10n.settingsCrumb(title),
          title: title,
          titleLeft: 100,
          onBack: () => Navigator.maybePop(context),
          onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
          actions: state.supported
              ? LoopSwitch(
                  key: const Key('network_wifi_switch'),
                  label: l10n.networkWifiLabel,
                  semanticLabel: l10n.networkWifiLabel,
                  value: on,
                  autofocus: true,
                  onChanged: state.busy
                      ? null
                      : (value) => unawaited(_setEnabled(value)),
                )
              : null,
          children: [
            Positioned.fill(
              child: Padding(
                padding: NetworkSettingsPage.inset,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ConnectionCard(
                      state: state,
                      onManage: (ssid) => unawaited(_details(ssid)),
                      onReconnect: (ssid) => unawaited(_connect(ssid)),
                    ),
                    if (state.supported) ...[
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Semantics(
                            header: true,
                            child: LoopSectionLabel(
                              l10n.networkNetworksHeading,
                            ),
                          ),
                          const Spacer(),
                          LoopOutlinedButton(
                            key: const Key('network_scan'),
                            width: 200,
                            label: state.scanning
                                ? l10n.networkScanning
                                : l10n.networkScan,
                            onTap: on && idle && !state.scanning
                                ? () => unawaited(_cubit.scan())
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: _NetworkList(
                          state: state,
                          onOpen: idle ? _open : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The signal glyph for a reading that is dBm on some paths and a 0-100
/// quality on others: three bars, two, or one.
IconData _signalIcon(int signal) {
  final bars = switch (signal) {
    < 0 when signal >= -60 => 3,
    < 0 when signal >= -72 => 2,
    < 0 => 1,
    >= 67 => 3,
    >= 34 => 2,
    _ => 1,
  };
  return switch (bars) {
    3 => LucideIcons.wifi,
    2 => LucideIcons.wifiHigh,
    _ => LucideIcons.wifiLow,
  };
}

/// The connection card: what the console is on, or why it is on nothing, and
/// the one thing to do about it (Manage, Reconnect).
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.state,
    required this.onManage,
    required this.onReconnect,
  });

  final WifiState state;
  final ValueChanged<String> onManage;
  final ValueChanged<String> onReconnect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final status = state.status;
    final joining = state.connectingSsid;
    final lost = state.lostSsid;
    final connected = status.connected && status.ssid.isNotEmpty;
    final idle = !state.busy && joining == null;

    final (String title, String detail) = !state.supported
        ? (
            l10n.networkUnavailableTitle,
            state.errorMessage != null
                ? wifiErrorMessage(l10n, state.errorMessage)
                : l10n.wifiUnsupportedBody,
          )
        : !status.enabled
        ? (l10n.networkOffTitle, l10n.networkOffDetail)
        : joining != null
        ? (l10n.networkConnectingTitle, joining)
        : connected
        ? (
            status.ssid,
            state.noInternet
                ? l10n.networkConnectedNoInternet
                : l10n.networkConnected,
          )
        : lost != null
        ? (l10n.networkLostTitle, lost)
        : (l10n.networkIdleTitle, l10n.networkIdleDetail);

    // A join's own failure is told on the card; the unsupported card already
    // says what went wrong in its line.
    final error = state.supported && joining == null
        ? state.errorMessage
        : null;

    final action = !state.supported || !status.enabled
        ? null
        : joining != null
        ? const NetworkProgressBar(width: 160)
        : connected
        ? LoopOutlinedButton(
            key: const Key('network_manage'),
            width: 180,
            label: l10n.networkManage,
            onTap: idle ? () => onManage(status.ssid) : null,
          )
        : lost != null
        ? LoopOutlinedButton(
            key: const Key('network_reconnect'),
            width: 200,
            tone: LoopButtonTone.accent,
            label: l10n.networkReconnect,
            onTap: idle ? () => onReconnect(lost) : null,
          )
        : null;

    return Container(
      key: const Key('network_connection_card'),
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.line),
      ),
      child: Row(
        children: [
          Icon(
            !status.enabled
                ? LucideIcons.wifiOff
                : connected
                ? _signalIcon(status.signal)
                : LucideIcons.wifi,
            size: 44,
            color: connected ? surface.textPrimary : surface.textTertiary,
          ),
          const SizedBox(width: 26),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText(
                    title,
                    key: const Key('network_card_title'),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 28,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 26,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppText(
                        detail,
                        key: const Key('network_card_detail'),
                        style: TextStyle(
                          color: surface.textSecondary,
                          fontSize: 22,
                          height: 1.4,
                        ),
                      ),
                      if (connected && joining == null && status.ip.isNotEmpty)
                        NetworkIpChip(ip: status.ip),
                    ],
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Semantics(
                      liveRegion: true,
                      child: AppText(
                        wifiErrorMessage(
                          l10n,
                          error,
                          kind: state.errorKind,
                        ),
                        key: const Key('network_card_error'),
                        style: TextStyle(
                          color: surface.warning,
                          fontSize: 22,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 26),
            action,
          ],
        ],
      ),
    );
  }
}

/// Every network but the one the console is on: saved first, then what the
/// scan saw, each group strongest first.
class _NetworkList extends StatelessWidget {
  const _NetworkList({required this.state, required this.onOpen});

  final WifiState state;
  final ValueChanged<WifiNetwork>? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (!state.status.enabled || state.networks.isEmpty) {
      final message = !state.status.enabled
          ? l10n.networkListOff
          : state.scanning
          ? l10n.networkScanning
          : l10n.networkListEmpty;
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 34),
          child: AppText(
            message,
            key: const Key('network_list_empty'),
            style: TextStyle(color: surface.textSecondary, fontSize: 24),
          ),
        ),
      );
    }
    final visible = visibleWifiNetworks(state);
    final networks = [
      ...visible.where((n) => n.saved),
      ...visible.where((n) => !n.saved),
    ];
    return ListView.builder(
      key: const Key('network_list'),
      itemCount: networks.length,
      itemBuilder: (context, index) {
        final network = networks[index];
        final open = onOpen;
        return _NetworkRow(
          network: network,
          onTap: open == null ? null : () => open(network),
        );
      },
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({required this.network, required this.onTap});

  final WifiNetwork network;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final onTap = this.onTap;
    final note = !network.saved
        ? null
        : network.inRange
        ? l10n.networkSaved
        : l10n.networkSavedNotInRange;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: [
        network.ssid,
        ?note,
        if (network.secured && !network.saved) l10n.networkSecured,
      ].join(', '),
      excludeSemantics: true,
      child: LoopFocusable(
        key: Key('network_row_${network.ssid}'),
        enabled: onTap != null,
        onActivate: onTap ?? () {},
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 94),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Icon(
                    network.inRange
                        ? _signalIcon(network.signal)
                        : LucideIcons.wifiOff,
                    size: 36,
                    color: surface.textSecondary,
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppText(
                        network.ssid,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 28,
                          height: 1.2,
                        ),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 10),
                        AppText(
                          note,
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 20,
                            height: 1,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 24,
                  child: network.secured
                      ? Icon(
                          LucideIcons.lock,
                          size: 24,
                          color: surface.textSecondary,
                        )
                      : null,
                ),
                const SizedBox(width: 24),
                Icon(
                  LucideIcons.chevronRight,
                  size: 28,
                  color: surface.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
