import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/theme/theme.dart';

/// The plate, to scale, with the switch being edited marked on it.
///
/// The map stays on screen the whole time the setup is open, which is the
/// whole point of the accepted layout: the question a performer is answering
/// is "what should THAT switch do", and that switch is a position under a
/// foot, not a row in a list.
///
/// The hit-test bounds include the raised rear row and LEDs. The pedal
/// positions match the pen's map; no tappable area hangs outside this box.
class PedalSetupMap extends StatelessWidget {
  /// Creates a [PedalSetupMap].
  const PedalSetupMap({
    required this.frame,
    required this.selected,
    required this.editable,
    required this.onSelect,
    required this.bank,
    required this.bankSelectable,
    required this.onToggleBank,
    super.key,
  });

  /// The actual frame sent to the board; selection never lights an indicator.
  final PedalStateFrame? frame;

  /// The switches drawn as a group with the selected one — the four track
  /// caps, when Track controls is editing them as one.
  final Set<PedalButton> selected;

  /// The switches that can be edited in this context; everything else is
  /// drawn dimmed and refuses the tap.
  final Set<PedalButton> editable;

  /// Selects a switch.
  final ValueChanged<PedalButton> onSelect;

  /// The bank the track caps are showing.
  final int bank;

  /// Whether BANK pages the map here. It does in Custom controls, where the
  /// four track caps carry a pair per bank; it does not in Track controls,
  /// where the one track hold covers both.
  final bool bankSelectable;

  /// Pages the bank.
  final VoidCallback onToggleBank;

  /// The pen's map with its raised row included in the hit-test bounds.
  static const Size penSize = Size(1720, 566);

  /// The pen's front-row cap slot.
  static const Size _frontSlot = Size(201, 216);

  /// The pen's rear-row cap slot — narrower, because the rear row has only
  /// two caps and the plate spaces them by the screens between them.
  static const Size _rearSlot = Size(168, 216);

  /// The pen's front-row pitch.
  static const double _frontPitch = 217;

  /// The raised row, including space for its LED above the cap.
  static const double _rearTop = 30;

  /// Where the front row sits.
  static const double _frontTop = 350;

  /// The pen's front-row order, left to right.
  static const List<PedalButton> _frontRow = [
    PedalButton.recPlay,
    PedalButton.stop,
    PedalButton.undo,
    PedalButton.mode,
    ...kTrackSwitches,
  ];

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: penSize,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 451,
          top: _rearTop,
          child: _cap(context, PedalButton.clear, _rearSlot),
        ),
        Positioned(
          left: 668,
          top: _rearTop,
          child: _cap(context, PedalButton.bank, _rearSlot),
        ),
        for (final (index, button) in _frontRow.indexed)
          Positioned(
            left: index * _frontPitch,
            top: _frontTop,
            child: _cap(context, button, _frontSlot),
          ),
      ],
    ),
  );

  Widget _cap(BuildContext context, PedalButton button, Size slot) {
    final channel = pedalTrackChannel(button, bank);
    final live =
        editable.contains(button) ||
        (button == PedalButton.bank && bankSelectable);
    return PedalSetupCap(
      key: Key('pedal_setup_cap_${button.name}'),
      // The cap's own silkscreen. A track cap prints the channel its bank
      // drives, so the map says 5 6 7 8 while bank B is being edited — the
      // same thing the plate under the foot says.
      legend: channel == null
          ? pedalButtonLegend(button)
          : 'TRACK ${channel + 1}',
      badge: button == PedalButton.bank ? _bankLetter : null,
      slot: slot,
      selected: selected.contains(button),
      ledColor: frame?.colorFor(button) ?? PedalColor.defaultColor,
      // A draft bank is not a performance bank change. Do not show another
      // track's live state beside a different assignment's label.
      ledActive:
          (frame?.isLit(button) ?? false) &&
          (channel == null || frame?.activeBank == bank),
      enabled: live,
      onTap: !live
          ? null
          : button == PedalButton.bank
          ? onToggleBank
          : () => onSelect(button),
    );
  }

  String get _bankLetter => String.fromCharCode(65 + bank);
}

/// One hardware pedal and its LED, with one touch and encoder target.
class PedalSetupCap extends StatelessWidget {
  /// Creates a selectable hardware pedal.
  const PedalSetupCap({
    required this.ledColor,
    required this.ledActive,
    required this.legend,
    required this.slot,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.badge,
    super.key,
  });

  /// The published hue, independent of selection and editability.
  final PedalColor ledColor;

  /// Whether this physical indicator is currently lit.
  final bool ledActive;

  /// The physical pedal's label and accessible name.
  final String legend;

  /// The current bank, when this is the Bank pedal.
  final String? badge;

  /// The accepted layout's allocation for this pedal.
  final Size slot;

  /// Whether this pedal belongs to the group being edited.
  final bool selected;

  /// Whether the pedal can be selected here.
  final bool enabled;

  /// Selects the pedal; null for fixed controls.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox.fromSize(
      size: slot,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: (slot.width - 114) / 2,
            top: -30,
            width: 114,
            height: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ledActive
                    ? Color.fromARGB(255, ledColor.r, ledColor.g, ledColor.b)
                    : surface.cardHigh,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: enabled ? 1 : surface.disabledOpacity,
              child: FocusableTapTarget(
                onTap: enabled ? onTap : null,
                selected: selected,
                semanticLabel: legend,
                focusColor: surface.warning,
                borderRadius: 8,
                child: Center(
                  child: SizedBox(
                    width: 159.16,
                    height: 216,
                    child: PedalHardwareFace(
                      label: legend.startsWith('TRACK ')
                          ? legend.substring(6)
                          : legend,
                      selected: selected,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              right: 6,
              top: 4,
              child: IgnorePointer(
                child: AppText(
                  badge!,
                  style: TextStyle(color: surface.textPrimary, fontSize: 20),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
