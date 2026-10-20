import 'package:console_facts_client/console_facts_client.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';

/// Where the controller's firmware facts came from.
enum ControllerFactsSource {
  /// The board's own HELLO, while it is talking.
  reported,

  /// The record this console's boot-time flasher left after its last verified
  /// program. What the console put on the board, not what the board says.
  lastFlashed,

  /// Neither: no version was read.
  notReported,
}

/// What the About and Controller firmware pages state about the console
/// board (the controller): its firmware, the link protocol it speaks, and
/// where those two came from.
///
/// The board is only ever *asked* over its link. While it talks, its HELLO is
/// the answer; while it does not, the flasher's record is the best the
/// console has, and it is captioned as such. Nothing is inferred from the
/// firmware this image ships: shipping it is not having put it there.
class ControllerFacts extends Equatable {
  /// Creates a [ControllerFacts].
  const ControllerFacts({required this.source, this.firmware, this.protocol});

  /// Reads the facts from the live link first, then the flash record.
  factory ControllerFacts.read({
    required PedalState pedal,
    required ConsoleBoardFlash? lastFlashed,
  }) {
    final hello = pedal.firmwareVersion;
    if (pedal.status != PedalLinkStatus.disconnected && hello != null) {
      return ControllerFacts(
        source: ControllerFactsSource.reported,
        firmware: hello,
        protocol: pedal.protocolVersion,
      );
    }
    if (lastFlashed != null) {
      return ControllerFacts(
        source: ControllerFactsSource.lastFlashed,
        firmware: lastFlashed.firmware,
        protocol: lastFlashed.protocol,
      );
    }
    return const ControllerFacts(source: ControllerFactsSource.notReported);
  }

  /// Where [firmware] and [protocol] came from.
  final ControllerFactsSource source;

  /// The firmware version, `major.minor`, or null when not reported.
  final String? firmware;

  /// The link protocol, or null when not reported.
  final int? protocol;

  /// Whether this console can update the board's firmware itself.
  ///
  /// Always false: in-app controller updating has not been established for
  /// this hardware, so the Controller firmware page says so rather than
  /// offering an action that cannot be trusted.
  bool get updateSupported => false;

  @override
  List<Object?> get props => [source, firmware, protocol];
}
