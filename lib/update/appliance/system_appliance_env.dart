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
  ///
  /// Deliberately not `const`: it bought one instance for the app's life (the
  /// sole construction site is `env ?? SystemApplianceEnv()`) at the price of
  /// making the live-flash handle a process-global static.
  SystemApplianceEnv({
    this.helperPath = '/usr/bin/segno-update-ctl',
    this.termGrace = const Duration(seconds: 8),
    this.killGrace = const Duration(seconds: 2),
  });

  /// Path to the update helper (run directly; the appliance app is root).
  final String helperPath;

  /// How long [abortPedalFlash] gives the helper to honour SIGTERM before it
  /// escalates.
  ///
  /// It has to cover the helper's own trap — which SIGTERMs its avrdude child,
  /// waits `SEGNO_FLASH_CHILD_GRACE` (3 s) for it, kills it, and sweeps the
  /// work dir — or the SIGKILL fires while the helper is doing exactly what it
  /// was asked to, and skipping that trap is what orphans avrdude. Shortened
  /// by tests, which drive real processes and should not wait out the real
  /// budget.
  final Duration termGrace;

  /// A bound on [abortPedalFlash]'s post-SIGKILL wait.
  ///
  /// A helper blocked in an uninterruptible USB write does not die on SIGKILL
  /// either — not until the kernel unblocks it — and this is awaited by a
  /// `dismissible: false` gate. Waiting here without a bound is the console
  /// hostage the stall timer exists to prevent, one layer down.
  final Duration killGrace;

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

  @override
  Stream<double> flashPedal() => _runHelper(const ['flash-pedal'], track: true);

  /// The live `flash-pedal` helper, kept so [abortPedalFlash] can kill it.
  Process? _pedalFlash;

  /// The abort in flight, so a second caller awaits the same kill instead of
  /// being told "it is dead" while the first is still waiting for it to die.
  Future<void>? _aborting;

  @override
  Future<void> abortPedalFlash() {
    final process = _pedalFlash;
    if (process == null) return Future<void>.value();
    // The handle is NOT dropped here: it is released when the process actually
    // exits (see [_runHelper]), so "returns only once it is dead" holds for
    // concurrent callers too rather than for whoever arrives first.
    return _aborting ??= _kill(process).whenComplete(() => _aborting = null);
  }

  /// SIGTERM, grace, SIGKILL — each wait bounded. Never throws: the caller is
  /// a UI gate, and every failure here (an already-reaped pid, a signal that
  /// cannot be delivered) leaves nothing further to try.
  Future<void> _kill(Process process) async {
    try {
      // SIGTERM, not SIGKILL. Dart signals a single pid, and the helper is a
      // shell: SIGKILL would skip the trap that takes avrdude down with it and
      // leave a privileged flasher orphaned on the Caterina bootloader port —
      // exactly the fight over that port this call exists to prevent.
      process.kill();
      await process.exitCode.timeout(termGrace);
    } on TimeoutException {
      // The helper never reached its trap, which means it is blocked in the
      // kernel (a USB ioctl) rather than ignoring the signal. SIGKILL is all
      // that is left; its child stays bounded by the helper's own
      // `timeout $AVRDUDE_TIMEOUT`.
      try {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(killGrace);
      } on Exception {
        // Nothing further to try, and returning beats holding the gate shut.
      }
    } on Exception {
      // Documented never to throw.
    }
  }

  @override
  Future<String?> pedalPending() async {
    try {
      final result = await Process.run(helperPath, const ['pedal-pending']);
      if (result.exitCode != 0) return null;
      final version = '${result.stdout}'.trim();
      return version.isEmpty ? null : version;
    } on Exception {
      // Helper missing / old image: no gate, rather than no app.
      return null;
    }
  }

  /// Runs the privileged helper with [args], republishing its
  /// `PROGRESS <0-100>` lines as `[0, 1]` and throwing with the collected
  /// stderr on a non-zero exit. With [track], the live process is exposed to
  /// [abortPedalFlash] until it exits.
  Stream<double> _runHelper(List<String> args, {bool track = false}) async* {
    final process = await Process.start(helperPath, args);
    if (track) {
      _pedalFlash = process;
      // The handle is dropped when the PROCESS dies, never when this stream is
      // merely cancelled — cancelling is exactly what the stall path does, a
      // microtask before it asks for the kill, so clearing it there would let
      // a wedged helper escape [abortPedalFlash] and go on holding the
      // bootloader port. A handle to an already-exited process is a harmless
      // target: killing it is a no-op.
      unawaited(
        process.exitCode.whenComplete(() {
          if (identical(_pedalFlash, process)) _pedalFlash = null;
        }),
      );
    }
    final stderrLines = <String>[];
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(stderrLines.add);
    final progress = RegExp(r'^PROGRESS\s+(\d+)');
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final match = progress.firstMatch(line);
      if (match != null) {
        yield (int.parse(match.group(1)!) / 100).clamp(0.0, 1.0);
      }
    }
    final code = await process.exitCode;
    await stderrDone;
    if (code != 0) {
      final reason = stderrLines.isEmpty
          ? 'update helper failed'
          : stderrLines.join('\n');
      throw ProcessException(helperPath, args, reason, code);
    }
    yield 1;
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
  Future<void> reconcileStaged() async {
    try {
      await Process.run(helperPath, const ['reconcile-staged']);
    } on Exception {
      // Helper missing / old image — leave the marker alone.
    }
  }
}
