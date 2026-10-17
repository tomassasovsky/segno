import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';

/// One format- and channel-scoped learning lifetime.
class MidiLearn extends Equatable {
  /// Creates a capture owned by [token].
  const MidiLearn({
    required this.protocol,
    required this.token,
    this.channel,
    this.reading,
  });

  /// Explicit format; it is never inferred from an arbitrary byte.
  final MidiProtocol protocol;

  /// Identity invalidated by cancel, replacement or source change.
  final Object token;

  /// Zero-based wire channel, or null for All.
  final int? channel;

  /// Complete received sample; never replayed as a performance command.
  final MidiControlEvent? reading;

  /// Whether capture still awaits its first valid complete sample.
  bool get isListening => reading == null;

  @override
  List<Object?> get props => [protocol, token, channel, reading];
}
