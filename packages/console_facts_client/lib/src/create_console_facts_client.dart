import 'dart:io';

import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/fake_console_facts_client.dart';
import 'package:console_facts_client/src/local_console_facts_client.dart';
import 'package:console_facts_client/src/unsupported_console_facts_client.dart';

/// Whether `--dart-define=SEGNO_FAKE_RADIOS=true` swapped the appliance for an
/// in-memory stand-in.
///
/// The radios' own define, not a second one. Both flags would mean the same
/// thing — *this build is standing in for the appliance* — and a developer
/// holding two switches in their head to see one console is a worse cost than
/// a name that reads slightly wide of its contents.
const kFakeConsoleFacts = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// Factory: the fake under [kFakeConsoleFacts]; the real
/// [LocalConsoleFactsClient] on Linux and macOS; the honest "unknown" client
/// everywhere else.
///
/// [sessionsRoot] and [capturesRoot] are the composition root's own session /
/// capture directory resolvers — the same functions it hands the repositories —
/// so the real client measures the app's actual data volume (`/data` on the
/// appliance) rather than guessing where it lives.
///
/// Windows keeps [UnsupportedConsoleFactsClient]: it has no `df`, and the
/// Storage face's "this build can't read the console's disk" is the truthful
/// answer there. Disk accounting is real on Linux/macOS now; capture retention
/// and USB export remain unimplemented on every platform (see
/// [LocalConsoleFactsClient]).
ConsoleFactsClient createConsoleFactsClient({
  required Future<String> Function() sessionsRoot,
  required Future<String> Function() capturesRoot,
}) {
  if (kFakeConsoleFacts) return FakeConsoleFactsClient();
  if (Platform.isLinux || Platform.isMacOS) {
    return LocalConsoleFactsClient(
      sessionsRoot: sessionsRoot,
      capturesRoot: capturesRoot,
    );
  }
  return const UnsupportedConsoleFactsClient();
}
