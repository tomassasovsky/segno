import 'dart:io';

import 'package:meta/meta.dart';
import 'package:usb_storage_client/src/fake_usb_storage_client.dart';
import 'package:usb_storage_client/src/linux_usb_storage_client.dart';
import 'package:usb_storage_client/src/unsupported_usb_storage_client.dart';
import 'package:usb_storage_client/src/usb_storage_client.dart';

/// Whether `--dart-define=SEGNO_FAKE_RADIOS=true` swapped the appliance for an
/// in-memory stand-in. The radios' own define, as `console_facts_client` and
/// the radio clients use: one switch means "this build stands in for the
/// appliance".
const kFakeUsbStorage = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// Factory: the fake under [kFakeUsbStorage]; the real
/// [LinuxUsbStorageClient] on Linux when the helper's state directory exists;
/// the honest "unsupported" client everywhere else.
///
/// [fake] and [isLinux] default to the build's define and the running
/// platform; tests pass them so every branch runs on every machine.
UsbStorageClient createUsbStorageClient({
  String runDir = '/run/segno/usb',
  @visibleForTesting bool fake = kFakeUsbStorage,
  @visibleForTesting bool? isLinux,
}) {
  if (fake) return FakeUsbStorageClient();
  if (!(isLinux ?? Platform.isLinux)) {
    return const UnsupportedUsbStorageClient();
  }
  final client = LinuxUsbStorageClient(runDir: runDir);
  if (!client.isSupported) return const UnsupportedUsbStorageClient();
  return client;
}
