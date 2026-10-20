import 'package:equatable/equatable.dart';

/// What the console's disk holds.
///
/// [known] is the load-bearing field, and the reason this is a value type
/// rather than five nullable numbers. A build that cannot read the disk has to
/// say so; drawing five zeroes instead would be the app stating, in the
/// definite tone of a measurement, that the disk is empty. Absence is modelled,
/// not defaulted.
class StorageUsage extends Equatable {
  /// Creates a known [StorageUsage].
  const StorageUsage({
    required this.sessionBytes,
    required this.captureBytes,
    required this.pluginBytes,
    required this.systemBytes,
    required this.freeBytes,
    this.pluginCount = 0,
  }) : known = true;

  /// What a build that cannot read the disk reports.
  const StorageUsage.unknown()
    : known = false,
      sessionBytes = 0,
      captureBytes = 0,
      pluginBytes = 0,
      systemBytes = 0,
      freeBytes = 0,
      pluginCount = 0;

  /// Whether the figures below mean anything.
  final bool known;

  /// Recorded sessions and their takes.
  final int sessionBytes;

  /// Rendered captures — exports and stems.
  final int captureBytes;

  /// Installed plugin bundles.
  final int pluginBytes;

  /// The running system and the standby slot an update stages into.
  final int systemBytes;

  /// What is left.
  final int freeBytes;

  /// How many plugin bundles [pluginBytes] is made of. Read here rather than
  /// from the app's plugin catalog because it comes off the same directory
  /// walk, and two counts of one thing can disagree.
  final int pluginCount;

  @override
  List<Object?> get props => [
    known,
    sessionBytes,
    captureBytes,
    pluginBytes,
    systemBytes,
    freeBytes,
    pluginCount,
  ];
}

/// What the console board's boot-time flasher last wrote onto the board: the
/// record `segno-console-flash` leaves after a verified program.
///
/// It is what this console *put* there, not what the board *says*: a board
/// reflashed from a laptop since, or swapped for another, still reads as this
/// record until it talks. The About face therefore captions it as such and
/// prefers the board's own HELLO whenever the link is up.
class ConsoleBoardFlash extends Equatable {
  /// Creates a [ConsoleBoardFlash].
  const ConsoleBoardFlash({required this.firmware, required this.protocol});

  /// The firmware version flashed, `major.minor`.
  final String firmware;

  /// The link protocol that firmware speaks.
  final int protocol;

  @override
  List<Object?> get props => [firmware, protocol];
}

/// What this console *is* — the facts printed on the box rather than compiled
/// into the app.
///
/// Every string is **empty when unknown**, every list empty and
/// [lastFlashed] null, and every face that reads one omits its row rather than
/// drawing a dash. A desktop build is not a console, and a serial number that
/// is not there is not a serial number that is blank.
class ConsoleFacts extends Equatable {
  /// Creates a [ConsoleFacts].
  const ConsoleFacts({
    this.name = '',
    this.serial = '',
    this.systemImage = '',
    this.panels = const [],
    this.lastFlashed,
  });

  /// What a build that is not a console reports.
  static const unknown = ConsoleFacts();

  /// The console's default name, before the user renames it.
  final String name;

  /// The serial printed on the box. Also the key anything recorded about
  /// *this* rig hangs off — the same rule the audio face's per-device
  /// settings follow.
  final String serial;

  /// The running system image's build, e.g. `1.2.3`.
  final String systemImage;

  /// The attached display panels' own names, as their EDID reports them, in
  /// connector order.
  final List<String> panels;

  /// What the boot-time flasher last put on the console board, or null when
  /// it has recorded nothing.
  final ConsoleBoardFlash? lastFlashed;

  @override
  List<Object?> get props => [name, serial, systemImage, panels, lastFlashed];
}
