import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_protocol.dart';

/// The last reading each of a set of MIDI sources received — what the mapping
/// list's signal meters draw.
///
/// Separate from the mapping engine on purpose. The engine reads messages to
/// change the rig and stops reading while a device is paused or Control is
/// off; a meter reports what the controller sent, whatever happened to it.
/// It keeps its own decoder, so reading here never disturbs a pair the engine
/// is assembling.
class MidiSignalLevels {
  /// Creates a [MidiSignalLevels] on [clock], the monotonic clock the formats'
  /// pair freshness window is measured on.
  MidiSignalLevels({required Duration Function() clock})
    : _decoder = MidiDecoder(clock: clock);

  final MidiDecoder _decoder;
  final Map<MidiSource, MidiControlEvent> _last = {};

  /// Reads [message] from [device] for each of [sources] it completes.
  /// Returns whether any reading changed.
  bool feed(
    String device,
    RawControllerInput message,
    Iterable<MidiSource> sources,
  ) {
    var changed = false;
    for (final protocol in {for (final source in sources) source.protocol}) {
      final event = _decoder.feed(device, message, protocol);
      if (event == null) continue;
      for (final source in sources) {
        // The same control on the same device, on a channel that meets.
        if (!source.sameAs(event.source)) continue;
        final last = _last[source];
        if (last?.value == event.value && last?.delta == event.delta) continue;
        _last[source] = event;
        changed = true;
      }
    }
    return changed;
  }

  /// The last complete reading [source] received — its value out of the
  /// largest its format carries — or `null` before it has received anything.
  MidiControlEvent? lastOf(MidiSource source) => _last[source];

  /// Discards partial messages from [device] — when it disconnects, so a half
  /// sent before cannot pair with one sent after. The readings stay: they are
  /// the last values received.
  void reset(String device) => _decoder.reset(device);
}
