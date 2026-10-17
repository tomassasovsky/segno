import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:segno/update/appliance/appliance_env.dart';

/// The production [ApplianceEnv]: real files, HTTP, and the privileged helper.
///
/// The helper (`segno-update-ctl`, shipped by the appliance image) does the
/// RAUC work. On the single-purpose appliance the kiosk app runs as root, so
/// the helper is invoked directly — no pkexec/polkit/setuid. This class is the
/// I/O boundary and is excluded from coverage; the testable logic lives in
/// `AppliancePlatformBackend` over a fake [ApplianceEnv].
class SystemApplianceEnv implements ApplianceEnv {
  /// Creates a [SystemApplianceEnv]. [helperPath] is the update helper.
  const SystemApplianceEnv({this.helperPath = kApplianceHelperPath});

  /// Path to the update helper (run directly; the appliance app is root).
  final String helperPath;

  @override
  String? readTextSync(String path) {
    try {
      return File(path).readAsStringSync();
    } on IOException {
      return null;
    }
  }

  @override
  void writeTextSync(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  @override
  bool existsSync(String path) => File(path).existsSync();

  @override
  Future<String?> httpGetText(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      return await response.transform(utf8.decoder).join();
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<double> stage(String version) => _runHelper(['install', version]);

  /// Runs the privileged helper with [args], republishing its
  /// `PROGRESS <0-100>` lines as `[0, 1]` and failing with the collected
  /// stderr on a non-zero exit.
  ///
  /// Cancelling the subscription sends the helper SIGTERM and completes once
  /// it has exited, so whatever the helper leaves behind on a kill is in
  /// place by the time the caller goes on.
  Stream<double> _runHelper(List<String> args) {
    Process? process;
    var cancelled = false;
    late final StreamController<double> controller;

    Future<void> run() async {
      try {
        final started = process = await Process.start(helperPath, args);
        if (cancelled) {
          started.kill();
          return;
        }
        final stderrLines = <String>[];
        final stderrDone = started.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(stderrLines.add);
        final progress = RegExp(r'^PROGRESS\s+(\d+)');
        await for (final line
            in started.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          final match = progress.firstMatch(line);
          if (match != null && !cancelled) {
            controller.add((int.parse(match.group(1)!) / 100).clamp(0.0, 1.0));
          }
        }
        final code = await started.exitCode;
        await stderrDone;
        if (cancelled) return;
        if (code != 0) {
          final reason = stderrLines.isEmpty
              ? 'update helper failed'
              : stderrLines.join('\n');
          controller.addError(ProcessException(helperPath, args, reason, code));
        } else {
          controller.add(1);
        }
      } on Object catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      } finally {
        if (!cancelled) await controller.close();
      }
    }

    controller = StreamController<double>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        cancelled = true;
        final running = process;
        if (running == null) return;
        running.kill();
        await running.exitCode;
      },
    );
    return controller.stream;
  }

  @override
  Future<String?> updateAttempt() async {
    final json = await _runJson(const ['attempt']);
    final version = json?['version'];
    return version is String && version.isNotEmpty ? version : null;
  }

  @override
  Future<void> clearUpdateAttempt() async {
    try {
      await Process.run(helperPath, const ['clear-attempt']);
    } on Exception {
      // Helper missing / old image — there is no marker to clear.
    }
  }

  @override
  Future<void> reboot() async {
    final result = await Process.run(helperPath, ['reboot']);
    if (result.exitCode != 0) {
      throw ProcessException(
        helperPath,
        const ['reboot'],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  @override
  Future<void> powerOff() async {
    final result = await Process.run(helperPath, const ['poweroff']);
    if (result.exitCode != 0) {
      throw ProcessException(
        helperPath,
        const ['poweroff'],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  @override
  Future<String?> reconcileStaged() async {
    final json = await _runJson(const ['reconcile-staged']);
    if (json == null || json['cleared'] != true) return null;
    final reason = json['reason'];
    return reason is String ? reason : null;
  }

  /// Runs a helper verb that answers with one JSON object, or returns `null`
  /// when the helper is missing, fails, or prints anything else (an old
  /// image without the verb).
  Future<Map<String, dynamic>?> _runJson(List<String> args) async {
    try {
      final result = await Process.run(helperPath, args);
      if (result.exitCode != 0) return null;
      final json = jsonDecode('${result.stdout}'.trim());
      return json is Map<String, dynamic> ? json : null;
    } on Exception {
      return null;
    }
  }
}
