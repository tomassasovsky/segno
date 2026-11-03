import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';

/// Where the console's ten pedals are drawn, on every screen that draws the
/// whole console: the foot views and Settings > Pedals (#1590 FT-4).
///
/// The rows are centred on the screen, so each view places a pedal by its
/// offset from its own centre line. Before, the foot views spread their
/// pedals across 1720 px (a 220 pitch from x=190) while the Pedals page used
/// the pen's 217 from x=200, so the same pedal sat in two places.
abstract final class ConsolePedalLayout {
  /// The front row, left to right, as the plate prints it.
  static const List<PedalButton> frontRow = [
    PedalButton.recPlay,
    PedalButton.stop,
    PedalButton.undo,
    PedalButton.mode,
    ...kTrackSwitches,
  ];

  /// The raised rear row, left to right.
  static const List<PedalButton> rearRow = [
    PedalButton.clear,
    PedalButton.bank,
  ];

  /// The distance between neighbouring pedal centres: the pen's 217.
  static const double pitch = 217;

  /// Each rear pedal stands behind a front one: CLEAR behind UNDO, BANK
  /// behind MODE.
  static const Map<PedalButton, PedalButton> _behind = {
    PedalButton.clear: PedalButton.undo,
    PedalButton.bank: PedalButton.mode,
  };

  /// How far [button]'s centre is from the centre of the rows, negative to
  /// the left.
  static double centreOffset(PedalButton button) {
    final index = frontRow.indexOf(_behind[button] ?? button);
    assert(index >= 0, '$button is not a console pedal');
    return (index - (frontRow.length - 1) / 2) * pitch;
  }
}
