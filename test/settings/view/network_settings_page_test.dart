import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/view/network_settings_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// A radio with just enough behaviour to drive the page through pen 29's
/// eight screens.
class _PageWifiClient implements WifiClient {
  _PageWifiClient({
    this.supported = true,
    this.enabled = true,
    this.connectedSsid = 'HomeNet',
  });

  final bool supported;
  bool enabled;
  String connectedSsid;
  String lastSsid = 'HomeNet';
  final autoConnect = <String, bool>{'HomeNet': true, 'Old Studio': true};
  List<WifiNetwork> networks = const [
    WifiNetwork(ssid: 'HomeNet', signal: -40, secured: true, saved: true),
    WifiNetwork(ssid: 'Studio 5G', signal: -45, secured: true),
    WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
    WifiNetwork(
      ssid: 'Old Studio',
      signal: 0,
      secured: true,
      saved: true,
      inRange: false,
    ),
  ];

  final joined = <(String, String?)>[];
  final forgotten = <String>[];
  final autoConnectCalls = <(String, bool)>[];
  int disconnects = 0;
  bool internet = true;

  /// Thrown by the next [connect], once.
  Error? connectError;

  /// Holds [connect] open until completed.
  Completer<void>? connectGate;

  @override
  bool get isSupported => supported;

  @override
  Future<WifiStatus> status() async {
    if (!supported) return WifiStatus.unsupported;
    final up = enabled && connectedSsid.isNotEmpty;
    return WifiStatus(
      supported: true,
      enabled: enabled,
      connected: up,
      ssid: up ? connectedSsid : '',
      ip: up ? '10.0.0.4' : '',
      signal: up ? -40 : 0,
      autoConnect: Map.of(autoConnect),
      lastSsid: lastSsid,
    );
  }

  @override
  Future<List<WifiNetwork>> scan() async => enabled ? networks : const [];

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    final gate = connectGate;
    if (gate != null) await gate.future;
    final error = connectError;
    if (error != null) {
      connectError = null;
      throw error;
    }
    joined.add((ssid, psk));
    connectedSsid = ssid;
    lastSsid = ssid;
    autoConnect.putIfAbsent(ssid, () => true);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    connectedSsid = '';
  }

  @override
  Future<void> forget(String ssid) async {
    forgotten.add(ssid);
    autoConnect.remove(ssid);
    if (connectedSsid == ssid) connectedSsid = '';
  }

  @override
  Future<void> setEnabled({required bool enabled}) async =>
      this.enabled = enabled;

  @override
  Future<void> setAutoConnect(String ssid, {required bool enabled}) async {
    autoConnectCalls.add((ssid, enabled));
    autoConnect[ssid] = enabled;
  }

  @override
  Future<void> changePassword(String ssid, String psk) async {}

  @override
  Future<bool> checkConnectivity() async => internet;
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

void main() {
  Future<_PageWifiClient> pumpPage(
    WidgetTester tester, {
    _PageWifiClient? client,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wifi = client ?? _PageWifiClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The progress bar sweeps while a join runs; held still, a settled
        // pump means the page is idle rather than mid-animation.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: NetworkSettingsPage(repository: WifiRepository(client: wifi)),
      ),
    );
    await tester.pumpAndSettle();
    return wifi;
  }

  Finder row(String ssid) => find.byKey(Key('network_row_$ssid'));

  Future<void> type(WidgetTester tester, String text) async {
    for (final key in text.split('')) {
      await tester.tap(find.widgetWithText(InkWell, key).first);
      await tester.pump();
    }
  }

  Future<void> submitPassword(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(InkWell, 'Connect').last);
    await tester.pump();
  }

  group('29/01 connected', () {
    testWidgets('the card names the network, its status and IP, and Manage', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(
        tester
            .widget<Semantics>(
              find
                  .descendant(
                    of: find.byKey(const Key('network_wifi_switch')),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .toggled,
        isTrue,
      );
      expect(find.byKey(const Key('network_card_title')), findsOneWidget);
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('network_card_title')))
            .data,
        'HomeNet',
      );
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('IP 10.0.0.4'), findsOneWidget);
      expect(find.byKey(const Key('network_manage')), findsOneWidget);
    });

    testWidgets('the list leaves out the connected network, saved first', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(row('HomeNet'), findsNothing);
      final top = [
        'Old Studio',
        'Studio 5G',
        'Cafe Free',
      ].map((ssid) => tester.getTopLeft(row(ssid)).dy).toList();
      expect(top, orderedEquals([...top]..sort()));
      expect(find.text('Saved · Not in range'), findsOneWidget);
    });
  });

  group('29/02-04 joining', () {
    testWidgets('a secured network asks for its password and joins with it', (
      tester,
    ) async {
      final client = await pumpPage(tester);

      await tester.tap(row('Studio 5G'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network_password_sheet')), findsOneWidget);
      expect(find.text('Enter password'), findsOneWidget);

      await type(tester, 'segno123');
      // Masked until Show.
      expect(find.text('••••••••'), findsOneWidget);
      await tester.tap(find.byKey(const Key('network_password_visibility')));
      await tester.pump();
      expect(find.text('segno123'), findsOneWidget);

      await submitPassword(tester);
      await tester.pumpAndSettle();
      expect(client.joined, [('Studio 5G', 'segno123')]);
      expect(find.byKey(const Key('network_password_sheet')), findsNothing);
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('network_card_title')))
            .data,
        'Studio 5G',
      );
    });

    testWidgets("the sheet enforces WPA2's 8-character floor itself", (
      tester,
    ) async {
      final client = await pumpPage(tester);

      await tester.tap(row('Studio 5G'));
      await tester.pumpAndSettle();
      await type(tester, 'abc');
      await submitPassword(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('A WPA2 passphrase is at least 8 characters.'),
        findsOneWidget,
      );
      expect(client.joined, isEmpty);
    });

    testWidgets('Connecting shows progress, the fallback, and Cancel', (
      tester,
    ) async {
      final client = _PageWifiClient()..connectGate = Completer<void>();
      await pumpPage(tester, client: client);

      await tester.tap(row('Studio 5G'));
      await tester.pumpAndSettle();
      await type(tester, 'segno123');
      await submitPassword(tester);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('network_connecting_dialog')),
        findsOneWidget,
      );
      expect(find.text('Connecting to Studio 5G'), findsOneWidget);
      expect(
        find.text('If this fails, Segno reconnects to HomeNet.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('network_connecting_cancel')));
      await tester.pump();
      client.connectGate!.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('network_connecting_dialog')), findsNothing);
      // Cancel takes the link down, which ends the helper's activation.
      expect(client.disconnects, 1);
    });

    testWidgets('the dialog closes on its own when the join lands', (
      tester,
    ) async {
      final client = _PageWifiClient()..connectGate = Completer<void>();
      await pumpPage(tester, client: client);

      await tester.tap(row('Cafe Free'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_connect')));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('network_connecting_dialog')),
        findsOneWidget,
      );

      client.connectGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network_connecting_dialog')), findsNothing);
      expect(client.joined, [('Cafe Free', null)]);
    });

    testWidgets('a wrong password reopens the sheet saying so', (
      tester,
    ) async {
      final client = _PageWifiClient()
        ..connectError = StateError('segno-wifi-ctl: authentication failed');
      await pumpPage(tester, client: client);

      await tester.tap(row('Studio 5G'));
      await tester.pumpAndSettle();
      await type(tester, 'wrongpass');
      await submitPassword(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('network_password_sheet')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('network_password_sheet')),
          matching: find.text('Incorrect password. Try again.'),
        ),
        findsOneWidget,
      );
      // The field starts empty again: a password never outlives its sheet.
      expect(find.text('Enter password'), findsOneWidget);

      await type(tester, 'segno123');
      await submitPassword(tester);
      await tester.pumpAndSettle();
      expect(client.joined, [('Studio 5G', 'segno123')]);
    });
  });

  group('29/05 network details', () {
    testWidgets('Manage shows Connect automatically, Change password, Forget '
        'and Disconnect', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('network_details_dialog')), findsOneWidget);
      expect(find.text('Connect automatically'), findsOneWidget);
      expect(find.text('Change password'), findsOneWidget);
      expect(find.byKey(const Key('network_forget')), findsOneWidget);
      expect(find.byKey(const Key('network_disconnect')), findsOneWidget);
    });

    testWidgets('Connect automatically applies in place', (tester) async {
      final client = await pumpPage(tester);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_auto_connect')));
      await tester.pumpAndSettle();

      expect(client.autoConnectCalls, [('HomeNet', false)]);
      expect(find.byKey(const Key('network_details_dialog')), findsOneWidget);
    });

    testWidgets('Disconnect does not ask', (tester) async {
      final client = await pumpPage(tester);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_disconnect')));
      await tester.pumpAndSettle();

      expect(client.disconnects, 1);
      expect(find.byKey(const Key('network_forget_dialog')), findsNothing);
      expect(find.text('Choose a network'), findsOneWidget);
    });

    testWidgets('Forget asks to confirm, and Cancel forgets nothing', (
      tester,
    ) async {
      final client = await pumpPage(tester);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_forget')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network_forget_dialog')), findsOneWidget);
      expect(find.text('Forget “HomeNet”?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('network_forget_cancel')));
      await tester.pumpAndSettle();
      expect(client.forgotten, isEmpty);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_forget_confirm')));
      await tester.pumpAndSettle();
      expect(client.forgotten, ['HomeNet']);
    });

    testWidgets('Change password reopens the sheet for that network', (
      tester,
    ) async {
      final client = await pumpPage(tester);

      await tester.tap(find.byKey(const Key('network_manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network_change_password')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('network_details_dialog')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('network_password_sheet')),
          matching: find.text('HomeNet'),
        ),
        findsOneWidget,
      );

      await type(tester, 'n3wsecret');
      await submitPassword(tester);
      await tester.pumpAndSettle();
      // In range, so the new key is tested by joining with it.
      expect(client.joined, [('HomeNet', 'n3wsecret')]);
    });

    testWidgets('a saved network out of range cannot be joined', (
      tester,
    ) async {
      await pumpPage(tester);

      await tester.tap(row('Old Studio'));
      await tester.pumpAndSettle();
      expect(find.text('Saved network'), findsOneWidget);
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('network_connect')),
            )
            .onTap,
        isNull,
      );
    });
  });

  group('29/06 connection lost', () {
    testWidgets('Reconnect joins the lost network with the key it holds', (
      tester,
    ) async {
      final client = _PageWifiClient(connectedSsid: '');
      await pumpPage(tester, client: client);

      expect(find.text('Connection lost'), findsOneWidget);
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('network_card_detail')))
            .data,
        'HomeNet',
      );
      await tester.tap(find.byKey(const Key('network_reconnect')));
      await tester.pumpAndSettle();

      expect(client.joined, [('HomeNet', null)]);
      expect(find.text('Connected'), findsOneWidget);
    });
  });

  group('29/07 Wi-Fi off', () {
    testWidgets('the card and the list say so, and Scan is unavailable', (
      tester,
    ) async {
      final client = await pumpPage(
        tester,
        client: _PageWifiClient(enabled: false),
      );

      expect(find.text('Wi-Fi is off'), findsOneWidget);
      expect(find.text('Turn on to find nearby networks.'), findsOneWidget);
      expect(find.text('No networks while Wi-Fi is off.'), findsOneWidget);
      expect(
        tester
            .widget<LoopOutlinedButton>(find.byKey(const Key('network_scan')))
            .onTap,
        isNull,
      );

      await tester.tap(find.byKey(const Key('network_wifi_switch')));
      await tester.pumpAndSettle();
      expect(client.enabled, isTrue);
      expect(row('Studio 5G'), findsOneWidget);
    });
  });

  group('29/08 connected without internet', () {
    testWidgets('reads "Connected · No internet"', (tester) async {
      await pumpPage(tester, client: _PageWifiClient()..internet = false);

      expect(find.text('Connected · No internet'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });
  });

  group('other states', () {
    testWidgets('a scan that finds nothing says so', (tester) async {
      await pumpPage(
        tester,
        client: _PageWifiClient()..networks = const [],
      );

      expect(
        find.text('No networks found. Scan to try again.'),
        findsOneWidget,
      );
    });

    testWidgets('a build without the helper has no switch and no list', (
      tester,
    ) async {
      await pumpPage(tester, client: _PageWifiClient(supported: false));

      expect(find.text('Wi-Fi is not available'), findsOneWidget);
      expect(find.byKey(const Key('network_wifi_switch')), findsNothing);
      expect(find.byKey(const Key('network_scan')), findsNothing);
    });

    testWidgets('the Wi-Fi switch holds encoder focus when the page opens', (
      tester,
    ) async {
      await pumpPage(tester);

      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        find
            .ancestor(
              of: find.byElementPredicate((e) => e == focused),
              matching: find.byKey(const Key('network_wifi_switch')),
            )
            .evaluate(),
        isNotEmpty,
      );
    });
  });
}
