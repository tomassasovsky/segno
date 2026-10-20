import 'dart:convert';
import 'dart:io';

import 'package:wifi_client/src/fake_wifi_client.dart';
import 'package:wifi_client/src/unsupported_wifi_client.dart';
import 'package:wifi_client/src/wifi_client.dart';
import 'package:wifi_client/src/wifi_exception.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// Production [WifiClient]: shells out to `/usr/bin/segno-wifi-ctl`.
class SystemWifiClient implements WifiClient {
  /// Creates a [SystemWifiClient].
  const SystemWifiClient({
    this.helperPath = '/usr/bin/segno-wifi-ctl',
    this.holdPath = '/run/segno/wifi-hold',
  });

  /// Path to the WiFi helper.
  final String helperPath;

  /// The file `segno-wifi-retry` holds off on while it exists. It carries this
  /// process's PID, so a file left behind by a crashed app is ignored.
  final String holdPath;

  @override
  bool get isSupported => File(helperPath).existsSync();

  @override
  Future<WifiStatus> status() async {
    if (!isSupported) return WifiStatus.unsupported;
    final json = await _runJson(['status']);
    if (json is Map<String, dynamic>) {
      return WifiStatus.fromJson(json);
    }
    return WifiStatus.unsupported;
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    if (!isSupported) return const [];
    final json = await _runJson(['scan']);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map<String, dynamic>) WifiNetwork.fromJson(item),
    ];
  }

  /// The key goes to the helper on stdin, like [changePassword]'s.
  @override
  Future<void> connect(String ssid, {String? psk}) async {
    final key = psk ?? '';
    await _run(
      ['connect', ssid],
      stdin: key.isEmpty ? null : '$key\n',
      secret: key,
    );
  }

  @override
  Future<void> disconnect() => _run(const ['disconnect']);

  @override
  Future<void> forget(String ssid) => _run(['forget', ssid]);

  @override
  Future<void> setEnabled({required bool enabled}) {
    return _run(['radio', if (enabled) 'on' else 'off']);
  }

  @override
  Future<void> setAutoConnect(String ssid, {required bool enabled}) =>
      _run(['autoconnect', ssid, if (enabled) 'on' else 'off']);

  /// The key goes to the helper on stdin: an argument would be readable by
  /// every process on the console through `/proc/<pid>/cmdline`.
  @override
  Future<void> changePassword(String ssid, String psk) =>
      _run(['set-password', ssid], stdin: '$psk\n', secret: psk);

  @override
  Future<bool> checkConnectivity() async {
    final json = await _runJson(const ['connectivity']);
    return json is Map<String, dynamic> && json['internet'] == true;
  }

  /// Written to a sibling and renamed into place, so the retry never reads a
  /// half-written PID. Best effort: a hold that cannot be written only means
  /// the console may reconnect mid-show, so it is not an error to report.
  @override
  Future<void> holdReconnects({required bool hold}) async {
    if (!isSupported) return;
    try {
      if (!hold) {
        await File(holdPath).delete();
        return;
      }
      final staged = File('$holdPath.$pid');
      await staged.writeAsString('$pid\n', flush: true);
      await staged.rename(holdPath);
    } on FileSystemException {
      // Already released, or no /run/segno to hold in.
    }
  }

  Future<Object?> _runJson(List<String> args) async {
    final stdout = await _run(args);
    final text = stdout.trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  /// Runs the helper with [args], writing [stdin] to it when given, and
  /// returns its stdout.
  ///
  /// A non-zero exit throws a [WifiHelperException] with the helper's stderr
  /// and, for a failed join, the network it brought back. Never the
  /// arguments: [secret], when given, is scrubbed from the text as well, so no
  /// key can reach an error message or a log.
  Future<String> _run(
    List<String> args, {
    String? stdin,
    String secret = '',
  }) async {
    final process = await Process.start(helperPath, args);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    if (exitCode == 0) return stdout;
    var err = (await stderr).trim();
    if (err.isEmpty) err = 'segno-wifi-ctl failed ($exitCode)';
    if (secret.isNotEmpty) err = err.replaceAll(secret, '***');
    throw WifiHelperException(err, restored: _restored(await stdout));
  }

  /// The network a failed join printed as `{"restored":<ssid>}`, if any.
  static String? _restored(String stdout) {
    for (final line in const LineSplitter().convert(stdout)) {
      try {
        final json = jsonDecode(line);
        if (json is Map<String, dynamic> && json['restored'] is String) {
          return json['restored'] as String;
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }
}

/// Whether `--dart-define=SEGNO_FAKE_RADIOS=true` swapped the radios for
/// in-memory stacks.
///
/// Read here rather than at a call site so **every** entry point picks it up
/// with no app wiring change, and read *before* the platform test so the fake
/// is reachable on the desktop — which is the whole point, since both radios
/// are Linux-only appliance helpers and the domain with the richest
/// interaction is otherwise the one surface that cannot be exercised while
/// building it.
const kFakeRadios = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// Factory: fake stack when [kFakeRadios], else the real helper on Linux when
/// present, else unsupported.
WifiClient createWifiClient() {
  if (kFakeRadios) return FakeWifiClient();
  if (!Platform.isLinux) return const UnsupportedWifiClient();
  const system = SystemWifiClient();
  if (!File(system.helperPath).existsSync()) {
    return const UnsupportedWifiClient();
  }
  return system;
}
