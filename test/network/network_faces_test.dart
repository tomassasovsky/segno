import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/network/network_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// A WiFi stack with just enough behaviour to drive the face.
class _FaceWifiClient implements WifiClient {
  _FaceWifiClient({this.enabled = true});

  bool enabled;
  String connectedSsid = 'HomeNet';
  final List<String> forgotten = [];
  final List<String> joined = [];
  String? lastPsk;
  bool failNextConnect = false;

  /// While positive, each [connect] throws [connectError] and decrements —
  /// so a test can shape a backend race that outlasts the retry budget, or
  /// one that recovers.
  int failConnects = 0;
  Error connectError = StateError('authentication failed');
  int connectAttempts = 0;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: enabled && connectedSsid.isNotEmpty,
    ssid: enabled ? connectedSsid : '',
    ip: '10.0.0.4',
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [
    WifiNetwork(ssid: 'HomeNet', signal: -40, secured: true, saved: true),
    WifiNetwork(ssid: 'Studio 5G', signal: -48, secured: true),
    WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
  ];

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    connectAttempts++;
    if (failConnects > 0) {
      failConnects--;
      throw connectError;
    }
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('authentication failed');
    }
    joined.add(ssid);
    lastPsk = psk;
    connectedSsid = ssid;
  }

  @override
  Future<void> disconnect() async => connectedSsid = '';

  @override
  Future<void> forget(String ssid) async => forgotten.add(ssid);

  @override
  Future<void> setEnabled({required bool enabled}) async =>
      this.enabled = enabled;
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    // `FocusableTapTarget` reads this, so a harness that omits it crashes
    // every focusable row — the app always carries both.
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

void main() {
  late SettingsTrayCubit tray;

  setUp(() {
    tray = SettingsTrayCubit()..open();
  });

  tearDown(() => tray.close());

  Future<void> pumpFace(
    WidgetTester tester, {
    _FaceWifiClient? wifi,
  }) async {
    tester.view
      ..physicalSize = const Size(1400, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: tray),
            BlocProvider(
              create: (_) => WifiCubit(
                repository: WifiRepository(
                  client: wifi ?? _FaceWifiClient(),
                ),
              ),
            ),
          ],
          child: const Scaffold(body: NetworkTrayPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the domain', () {
    testWidgets('is the Wi-Fi face alone: no tab strip, no chrome bar', (
      tester,
    ) async {
      await pumpFace(tester);

      expect(find.byKey(const Key('network_tabs')), findsNothing);
      expect(find.text('Bluetooth'), findsNothing);
      expect(find.byKey(const Key('wifi_tray_body')), findsOneWidget);
      // No back chevron on a domain face — the rail is the only way back.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.chevron_left), findsNothing);
    });
  });

  group('WiFi face', () {
    testWidgets('switched off, the title row is the whole face', (
      tester,
    ) async {
      await pumpFace(tester, wifi: _FaceWifiClient(enabled: false));

      expect(find.byKey(const Key('wifi_power')), findsOneWidget);
      // Nothing else exists until it is on — no list, and no rescan control
      // to press against a radio that is down.
      expect(find.byKey(const Key('wifi_scan')), findsNothing);
      expect(find.byType(ConsoleCard), findsNothing);
    });

    testWidgets('the power switch turns the radio on', (tester) async {
      final client = _FaceWifiClient(enabled: false);
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_power')));
      await tester.pumpAndSettle();

      expect(client.enabled, isTrue);
      expect(find.byType(ConsoleCard), findsOneWidget);
    });

    testWidgets('a saved row opens in place into its actions', (tester) async {
      await pumpFace(tester);

      expect(find.text('Disconnect'), findsNothing);
      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_disconnect')), findsOneWidget);
      expect(find.byKey(const Key('wifi_forget')), findsOneWidget);
    });

    testWidgets('only one row is open at a time', (tester) async {
      await pumpFace(tester);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wifi_forget')), findsOneWidget);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      // The row's container stays in the tree so opening and shutting can
      // animate; what goes is its actions. A shut row holds nothing tappable,
      // which is the property worth pinning — testing for the container
      // instead would pass while leaving invisible chips live.
      expect(find.byKey(const Key('wifi_forget')), findsNothing);
    });

    testWidgets('a row that is shut holds no action, mid-close included', (
      tester,
    ) async {
      await pumpFace(tester);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));

      // Half way through the close the chips are still drawn — clipped and
      // fading — and must not be reachable by a stray tap.
      await tester.pump(kConsoleMotion ~/ 2);
      final chip = find.byKey(const Key('wifi_forget'));
      expect(tester.getSize(chip).height, greaterThan(0));

      await tester.pumpAndSettle();
      expect(chip, findsNothing);
    });

    testWidgets('disconnect is reversible, so it asks nothing', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_disconnect')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
      expect(client.connectedSsid, isEmpty);
    });

    testWidgets('forget destroys a credential, so it confirms first', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);
      expect(client.forgotten, isEmpty, reason: 'not until confirmed');

      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      expect(client.forgotten, ['HomeNet']);
    });

    testWidgets('cancelling the confirm forgets nothing', (tester) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi_forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();

      expect(client.forgotten, isEmpty);
    });

    testWidgets('an open network joins on tap, with no sheet', (tester) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_join_sheet')), findsNothing);
      expect(client.joined, ['Cafe Free']);
      expect(client.lastPsk, isNull);
    });

    testWidgets('a secured network raises the sheet and joins with its text', (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Studio 5G')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);

      for (final key in ['s', 'e', 'g', 'n', 'o', '1', '2', '3']) {
        await tester.tap(find.widgetWithText(InkWell, key).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, 'Join').last);
      await tester.pumpAndSettle();

      expect(client.joined, ['Studio 5G']);
      expect(client.lastPsk, 'segno123');
    });

    testWidgets("the sheet enforces WPA2's 8-character floor itself", (
      tester,
    ) async {
      final client = _FaceWifiClient();
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Studio 5G')));
      await tester.pumpAndSettle();
      for (final key in ['a', 'b', 'c']) {
        await tester.tap(find.widgetWithText(InkWell, key).first);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(InkWell, 'Join').last);
      await tester.pumpAndSettle();

      // Corrected here, rather than handed to the supplicant and returned
      // seconds later as a generic association failure.
      expect(find.byKey(const Key('wifi_join_too_short')), findsOneWidget);
      expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);
      expect(client.joined, isEmpty);
    });

    testWidgets('a refusal rides as a banner naming the network', (
      tester,
    ) async {
      final client = _FaceWifiClient()..failNextConnect = true;
      await pumpFace(tester, wifi: client);

      await tester.tap(find.byKey(const Key('wifi_network_Cafe Free')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wifi_banner')), findsOneWidget);
      // A dialog would take the list away; the banner sits in it.
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('could not join Cafe Free'), findsOneWidget);
    });

    testWidgets(
      'a backend failure retries and never asks for the password — the #824 '
      'race must not teach the owner to forget the network',
      (tester) async {
        final client = _FaceWifiClient()
          ..connectedSsid = ''
          ..failConnects = 3
          ..connectError = StateError(
            'Activation: (wifi) Network.Connect failed: '
            'GDBus.Error:net.connman.iwd.Failed',
          );
        await pumpFace(tester, wifi: client);

        // HomeNet is saved: the row opens in place, the chip joins.
        await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wifi_connect')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // First failure: the console says it is retrying, not re-asking.
        expect(find.text('Network error — retrying HomeNet…'), findsOneWidget);
        expect(find.byKey(const Key('wifi_join_sheet')), findsNothing);

        // Ride out the bounded backoff (2s, then 5s) — no pumpAndSettle here,
        // it would race the pending retry timers.
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 300));

        // Exhausted: a neutral network error, still not a password problem.
        expect(client.connectAttempts, 3);
        expect(
          find.text('Couldn’t join — network error, not a password problem.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('wifi_join_sheet')), findsNothing);

        // Try again re-activates with what the console holds — no prompt.
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wifi_join_sheet')), findsNothing);
        expect(client.joined, ['HomeNet']);
        expect(client.lastPsk, isNull);
      },
    );

    testWidgets(
      'a genuine key rejection on a saved network routes Try again back to '
      'the passphrase sheet — the known answer is known wrong',
      (tester) async {
        final client = _FaceWifiClient()
          ..connectedSsid = ''
          ..failConnects = 1
          ..connectError = StateError('segno-wifi-ctl: 4-way handshake failed');
        await pumpFace(tester, wifi: client);

        await tester.tap(find.byKey(const Key('wifi_network_HomeNet')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wifi_connect')));
        await tester.pumpAndSettle();

        expect(
          find.text('Couldn’t join — check the password and try again.'),
          findsOneWidget,
        );

        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wifi_join_sheet')), findsOneWidget);
      },
    );
  });
}
