import 'package:segno/looper/model/tempo_state.dart';

/// The input rules of every exact-tempo keypad: the Tempo page's (#1653)
/// and the readout's (#1654).

/// [text] with [key] typed after it, or null when the key would make it no
/// tempo: a second point, a third decimal, or a fourth whole digit.
String? typeTempoKey(String text, String key) {
  final next = text + key;
  return _tempoText.hasMatch(next) ? next : null;
}

/// Up to three whole digits and two decimals.
final _tempoText = RegExp(r'^\d{0,3}(\.\d{0,2})?$');

/// Whether [character] types into a tempo: a digit or the point.
bool isTempoKey(String character) => _tempoKey.hasMatch(character);

final _tempoKey = RegExp(r'^[\d.]$');

/// The tempo [text] names, or null when it is outside [kTempoRange].
double? parseTempoEntry(String text) {
  final bpm = double.tryParse(text);
  if (bpm == null) return null;
  final (min, max) = kTempoRange;
  return bpm >= min && bpm <= max ? bpm : null;
}
