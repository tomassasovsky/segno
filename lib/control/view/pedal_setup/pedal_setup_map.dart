import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/common/pedal_face.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/theme/theme.dart';

/// The plate, to scale, with the switch being edited marked on it.
///
/// The map stays on screen the whole time the setup is open, which is the
/// whole point of the accepted layout: the question a performer is answering
/// is "what should THAT switch do", and that switch is a position under a
/// foot, not a row in a list.
///
/// Drawn in the pen's own coordinates inside a 1720 x 480 box: the rear row
/// (Clear and Bank) sits ABOVE the box, which is why the stack does not clip.
class PedalSetupMap extends StatelessWidget {
  /// Creates a [PedalSetupMap].
  const PedalSetupMap({
    required this.selected,
    required this.editable,
    required this.onSelect,
    required this.bank,
    required this.bankSelectable,
    required this.onToggleBank,
    required this.palette,
    required this.lit,
    super.key,
  });

  /// The switches drawn as a group with the selected one — the four track
  /// caps, when Track controls is editing them as one.
  final Set<PedalButton> selected;

  /// The switches that can be edited in this context; everything else is
  /// drawn dimmed and refuses the tap.
  final Set<PedalButton> editable;

  /// Selects a switch.
  final ValueChanged<PedalButton> onSelect;

  /// The bank the track caps are showing, or `null` in a context that has no
  /// bank — LED colors, where a switch's colour is the switch's whatever bank
  /// it is driving.
  final int? bank;

  /// Whether BANK pages the map here. It does in Custom controls, where the
  /// four track caps carry a pair per bank; it does not in Track controls,
  /// where the one track hold covers both.
  final bool bankSelectable;

  /// Pages the bank.
  final VoidCallback onToggleBank;

  /// Which colour each indicator uses. The map shows the palette being
  /// edited, so a colour picked in the LED colors context is on the plate
  /// before Save — that is the whole reason the map stays on screen.
  final PedalPalette palette;

  /// The switches whose indicator is lit right now, from the live rig.
  ///
  /// State, not selection: which switch is being EDITED is drawn on the cap.
  /// The accepted design is explicit that setup feedback must not read as a
  /// saved performance latch, so nothing here lights a pill that the rig is
  /// not lighting.
  final Set<PedalButton> lit;

  /// The pen's box for the whole map.
  static const Size penSize = Size(1720, 480);

  /// The pen's front-row cap slot.
  static const Size _frontSlot = Size(201, 216);

  /// The pen's rear-row cap slot — narrower, because the rear row has only
  /// two caps and the plate spaces them by the screens between them.
  static const Size _rearSlot = Size(168, 216);

  /// The pen's front-row pitch.
  static const double _frontPitch = 217;

  /// Where the rear row sits, relative to the box. Negative on purpose: the
  /// pen hangs it above the front row's band.
  static const double _rearTop = -56;

  /// Where the front row sits.
  static const double _frontTop = 264;

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
      // The rear row hangs above the box (see [_rearTop]).
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
    final channel = pedalTrackChannel(button, bank ?? 0);
    // BANK pages the map where the assignments are per-bank, and is an
    // ordinary selectable cap everywhere else — including LED colors, where it
    // has a colour of its own like the other nine.
    final pagesBank = button == PedalButton.bank && bankSelectable;
    final live = editable.contains(button) || pagesBank;
    return PedalSetupCap(
      key: Key('pedal_setup_cap_${button.name}'),
      ledKey: Key('pedal_setup_led_${button.name}'),
      color: palette.colorFor(button),
      lit: lit.contains(button),
      // The cap's own silkscreen. A track cap prints the channel its bank
      // drives, so the map says 5 6 7 8 while bank B is being edited — the
      // same thing the plate under the foot says.
      legend: channel == null
          ? pedalButtonLegend(button)
          : 'TRACK ${channel + 1}',
      // The bank letter is on the cap wherever a bank is in play. In LED
      // colors there is none to name: a colour belongs to the switch whatever
      // bank it happens to be driving.
      badge: button == PedalButton.bank && bank != null ? _bankLetter : null,
      slot: slot,
      selected: selected.contains(button),
      enabled: live,
      onTap: !live
          ? null
          : pagesBank
          ? onToggleBank
          : () => onSelect(button),
    );
  }

  String get _bankLetter => String.fromCharCode(65 + (bank ?? 0));
}

/// One footswitch on the map: the metal cap, its nameplate legend, and the
/// LED pill behind it.
///
/// Shapes, not an illustration. The cap is a tapered slab with a rubber pad
/// and a nameplate, which is what the real switch is; drawing the plate's
/// photoreal rendering by hand would look worse than the geometry it stands
/// for, and would still have to be redrawn every time the hardware moves.
class PedalSetupCap extends StatelessWidget {
  /// Creates a [PedalSetupCap].
  const PedalSetupCap({
    required this.ledKey,
    required this.legend,
    required this.slot,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.color,
    required this.lit,
    this.badge,
    super.key,
  });

  /// Names the indicator itself, the way the plate's own LEDs are named.
  final Key ledKey;

  /// The silkscreen on the cap.
  final String legend;

  /// A short mark in the cap's corner — the bank letter, and nothing else so
  /// far.
  final String? badge;

  /// The pen's box for this cap.
  final Size slot;

  /// Whether this is the switch being edited.
  final bool selected;

  /// Whether this switch can be edited in the current context.
  final bool enabled;

  /// Selects it; `null` while it cannot be edited.
  final VoidCallback? onTap;

  /// The hue this switch's indicator uses when it is lit.
  final PedalColor color;

  /// Whether the rig is lighting it.
  final bool lit;

  /// The pen's LED pill: 114 x 11, sitting 30 above the cap.
  static const Size _ledSize = Size(114, 11);
  static const double _ledGap = 30;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final pad = (slot.width - _ledSize.width) / 2;
    return SizedBox(
      width: slot.width,
      height: slot.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: pad,
            top: -_ledGap,
            width: _ledSize.width,
            height: _ledSize.height,
            child: DecoratedBox(
              key: ledKey,
              decoration: BoxDecoration(
                // The plate's own LED: its hue is the configured colour and
                // what lights it is the rig. Unlit it is the dark pill the
                // hardware shows, not a dimmed version of the colour — an
                // indicator that is faintly its own colour while off would
                // make every switch look half-engaged.
                color: lit ? color.display : surface.ledOff,
                borderRadius: BorderRadius.circular(_ledSize.height / 2),
                // The rim is the unlit pill's own edge. A lit one takes the
                // colour right to the edge, because a dark rim around a lit
                // LED is a thing the hardware cannot do.
                border: Border.all(color: lit ? color.display : surface.line),
              ),
            ),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: enabled ? 1 : surface.disabledOpacity,
              child: Center(
                child: SizedBox(
                  width: PedalFace.widthFor(slot.height),
                  height: slot.height,
                  child: FocusableTapTarget(
                    onTap: onTap,
                    selected: selected,
                    semanticLabel: legend,
                    borderRadius: 14,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: PedalFace(
                            selected: selected,
                            // The nameplate is the one part of the switch that
                            // is not moulded metal: it is what the plate has
                            // printed on it, and here it is what the map is
                            // naming.
                            legend: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: AppText(
                                  legend,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    color: PedalFace.labelInk,
                                    fontFamily: SurfaceTheme.monoFont,
                                    fontSize: 18,
                                    height: 1,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (badge != null)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: surface.accentSurface,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                child: AppText(
                                  badge!,
                                  style: TextStyle(
                                    color: surface.textPrimary,
                                    fontSize: 20,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
