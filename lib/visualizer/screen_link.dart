import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show IsolateNameServer;

/// Which of the console's two screens this Flutter engine renders.
///
/// ivi-homescreen on the appliance starts one engine per screen from the same
/// bundle and the same `main`, and names each one's role in its Dart arguments
/// (homescreen.toml): `--segno-screen=main` or `--segno-screen=readout`. The
/// macOS dev host names none and runs the main screen alone.
enum SegnoScreen {
  /// The main console UI. Owns the audio engine and every repository.
  main,

  /// The 7" readout. Owns nothing: it draws what the main screen sends it and
  /// reports a touch on it back to the main screen as activity.
  readout,
}

/// The argument prefix an embedder uses to name the screen.
const segnoScreenArgPrefix = '--segno-screen=';

/// The screen named in [args], or `null` when none is named (the macOS dev
/// host).
///
/// Throws [ArgumentError] for a value that names no screen: a typo in the
/// embedder config must not start a second main screen, with a second audio
/// engine, in the same process.
SegnoScreen? segnoScreenFrom(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith(segnoScreenArgPrefix)) continue;
    final name = arg.substring(segnoScreenArgPrefix.length);
    for (final screen in SegnoScreen.values) {
      if (screen.name == name) return screen;
    }
    throw ArgumentError.value(arg, 'args', 'names no Segno screen');
  }
  return null;
}

/// Where each end of the screen link publishes its inbox.
///
/// The two screens are two Flutter engines in one process, and therefore two
/// isolate groups in one Dart VM. They cannot share objects, but they share the
/// VM's isolate name registry, so each end publishes a [SendPort] under a fixed
/// name and looks the other end's up.
abstract interface class PortDirectory {
  /// The port published under [name], or `null` when none is.
  SendPort? lookup(String name);

  /// Publishes [port] under [name], replacing anything published there before.
  void publish(String name, SendPort port);
}

/// [PortDirectory] over `dart:ui`'s [IsolateNameServer], which is one registry
/// per Dart VM and therefore shared by every engine in the process.
class IsolateNameServerDirectory implements PortDirectory {
  /// Creates an [IsolateNameServerDirectory].
  const IsolateNameServerDirectory();

  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);

  @override
  void publish(String name, SendPort port) {
    // Registering refuses a taken name, and a name outlives the isolate that
    // took it, so a stale mapping has to be removed first.
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port, name);
  }
}

/// The name the main screen publishes its inbox under.
const screenLinkMainPort = 'segno.screen.main';

/// The name the readout screen publishes its inbox under.
const screenLinkReadoutPort = 'segno.screen.readout';

/// The message kinds on the screen link. Every message is a map whose `op` key
/// holds one of these.
abstract final class ScreenLinkOp {
  /// Main to readout: "I am up; announce yourself."
  static const hello = 'hello';

  /// Readout to main: "I am up and hold nothing", carrying the readout's inbox
  /// under `port`.
  static const ready = 'ready';

  /// Main to readout: draw the readout.
  static const show = 'show';

  /// Main to readout: draw nothing (the readout preference is off).
  static const hide = 'hide';

  /// Main to readout: one waveform frame, with `seq`, `progress`,
  /// `selectedTrack` and, only when the peaks changed, `samples`.
  static const waveform = 'waveform';

  /// Main to readout: a performance readout map under `readout`, with `seq`.
  static const readout = 'readout';

  /// Readout to main: the message carrying `seq` has been applied.
  static const ack = 'ack';

  /// Readout to main: a player touched the readout, which wakes an
  /// idle-dimmed console like a touch on the main screen.
  static const activity = 'activity';

  /// Main to readout: touch calibration of the readout's own touchscreen.
  /// `target` is the point to tap, `[x, y]` in the readout's normalized
  /// coordinates, and `label` says which step it is; a `null` target ends
  /// calibration and the readout goes back to what it was showing.
  static const calibrate = 'calibrate';

  /// Readout to main: a tap during calibration, `x` and `y` in the readout's
  /// normalized coordinates.
  static const calibrationTap = 'calibrationTap';
}

/// A copy of [value] that a [SendPort] can carry between isolate groups.
///
/// Engines in one process do not share code in the VM's sense, so a message
/// between them may only hold null, booleans, numbers, strings, lists and maps
/// made by literals or by the plain constructors, [TransferableTypedData] and
/// [SendPort]s. An unmodifiable or typed list nested in a readout map would
/// make [SendPort.send] throw, so maps and lists are rebuilt as plain literals
/// rather than trusted. A typed list therefore arrives as a plain list of its
/// numbers; bulk data that should stay compact goes through [packSamples]
/// instead.
///
/// Throws [ArgumentError] for anything else, at the sender, where the stack
/// still says which field it was.
Object? sendableCopy(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  TransferableTypedData() || SendPort() => value,
  Map<Object?, Object?>() => <Object?, Object?>{
    for (final MapEntry(:key, :value) in value.entries)
      sendableCopy(key): sendableCopy(value),
  },
  List<Object?>() => <Object?>[for (final item in value) sendableCopy(item)],
  _ => throw ArgumentError.value(
    value,
    'value',
    'cannot cross between engines: ${value.runtimeType}',
  ),
};

/// Packs waveform peaks for the link: a [Float32List] cannot cross between
/// isolate groups, but its bytes can.
TransferableTypedData packSamples(Float32List samples) =>
    TransferableTypedData.fromList([samples]);

/// Unpacks what [packSamples] packed. Anything else yields `null`, so a garbled
/// frame keeps the peaks already on screen.
Float32List? unpackSamples(Object? packed) {
  if (packed is! TransferableTypedData) return null;
  return packed.materialize().asFloat32List();
}
