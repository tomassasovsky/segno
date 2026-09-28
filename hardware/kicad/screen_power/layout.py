"""Hand-soldered floorplan: compact control, accessible plugs, straight USB."""
DIMENSIONS = {"hand": (68, 76)}
CORNER_RADIUS = 3
USB_ROWS = {"hand": (36, 61)}
POWER_BUS_X = 64
# Pin 1 of each screen-output plug. Revision O's five-contact USB headers grow
# 2.5 mm toward smaller y, so both VH plugs shift north out of their envelope.
# Channel 1 keeps a balanced bay between J1 and J102; channel 2's plug is
# pinned between two USB headers and sits centred in the gap that remains.
POWER_PLUG_Y = {1: 23.6, 2: 49.23}
# Coupled-pair geometry, from the converged coated-field solution for this
# stack: the pair keeps its 1.01 mm centre pitch, so every centreline, fanout
# and keepout in route_critical.py is unchanged, but the copper is narrower and
# the gap wider. The model target is 90.8 ohms; a two-layer service does not
# guarantee impedance and this is not a qualification claim.
USB_WIDTH = 0.78
USB_GAP = 0.23


def place_components(variant, place, fps):
    w, h = DIMENSIONS[variant]
    for i, at in enumerate(((4, 4), (w-4, 4), (4, h-4), (w-4, h-4)), 1):
        place(f"H{i}", *at)
    # All keyed headers have vertical pin rows, pin 1 at the bottom and
    # their retaining wall on the left. Keep the two edge columns aligned.
    place("J1", 56, 14, 90, centre=False)
    place("J2", 7, 14.25, 90, centre=False)
    # Revision N north strip. The input cartridge holder lies across the top
    # edge with its terminals on the board's own centre line, so the raw
    # pre-fuse run from J1 stays short and the 5 x 20 mm fuse lifts straight
    # out from above with nothing over it. Its 11.5 mm uncovered height leaves the
    # cartridge accessible from above; reserve its installation envelope.
    place("F1", 38, 6.3, 180)
    # The relay fills the bay the charge pump, optocoupler and pass MOSFETs
    # released. Rotated 180 degrees it presents both coil terminals on the
    # west face and both contact terminals on the east, so the AUX contact
    # faces the input and the switched contact faces the branch fuses.
    place("K1", 27, 21, 180)
    # The clamp stands vertically between the two coil terminals, one pad
    # opposite each, which is the shortest loop the 10.16 mm lead pitch allows.
    place("D3", 13.5, 21, 90)
    # Coil driver and its gate pulldown stay between the control plug and the
    # first USB row. The five-contact J101 reaches 2.5 mm further north than
    # the old four-way plug, and the 9.6 mm bay that leaves cannot hold the
    # MOSFET's 10.5 mm terminal row standing on end. Laying that row across
    # the bay fits it with 2.4 mm to spare on each side, keeps the drain a
    # short reach to the clamp, and frees the whole west edge channel for the
    # pulldown, whose own row then clears the plug entirely.
    place("Q5", 5.75, 23.7, 0)
    place("R7", 2, 14.5, 90)
    # GPIO input stage keeps the north-west corner beside its own plug.
    place("Q1", 13.5, 10.5, 90)
    place("R1", 15, 2)
    place("R2", 15, 5.2)
    # The AUX-referenced enable buffer stays in the pocket between the two
    # host plugs: it drives the power-relay gate to the north and both USB
    # coil gates to the south, so the middle keeps DATA_ENABLE shortest.
    place("Q2", 7.5, 45.74)
    # The sink resistor used to lie across the mouth of the lower host plug,
    # which the five-contact J201 now occupies. It moves one bay east, into
    # the lane between the presence divider and the lower flyback diode; its
    # terminals keep the same order, so the buffer base still faces Q2.
    place("R5", 23, 52.5, 180)
    # The pull-up stands in the west edge channel: the column between the two
    # flyback diodes is 12.04 mm tall and this 12.36 mm part does not fit it.
    # It sits 0.7 mm north of Revision N so its lower terminal stays clear of
    # the back-side legend row the shield contact adds.
    place("R6", 2, 47.8, 90)
    # AUX bypass north of the relay, reservoir east of it. Both sit on the
    # protected side of F1, close to the terminals they support.
    place("C1", 20.35, 10, 180)
    place("C2", 42.5, 16.5)
    # The bleeder lies along the south edge, clear of the lower USB pair
    # and the mounting washer keepout.
    place("R8", 52, 73)
    # Channel 1 keeps its divider under the relay row and channel 2 along the
    # south edge, each with its 10k arm nearest its own host plug so that
    # HOSTx_5V, which exists on exactly one connector pin, stays short.
    divider = {1: ((27.13, 49.0), (37.9, 55.6)),
               2: ((25, 73.35), (38.5, 73.35))}
    for ch, y in enumerate(USB_ROWS[variant], 1):
        n = 100 * ch
        place(f"J{n+1}", 7, y+3.75, 90, centre=False)
        place(f"J{n+2}", 56, y+3.75, 90, centre=False)
        place(f"K{n+1}", 23.2, y+2.54, 90, centre=False)
        place(f"J{n+3}", 56, POWER_PLUG_Y[ch], 90, centre=False)
        # The radial branch fuses replace the old axial pair on the same two
        # rows. Their terminals keep the existing bus tap and output geometry:
        # the switched input stays west and the protected output east.
        place(f"F{n+1}", 44.5, y-13, 180)
        place(f"F{n+2}", 44.5, y+7, 180)
        place(f"C{n+2}", 47, y-4)
        # The flyback moves one column east of the old position so the disc
        # bypass fits in the channel beside its own host plug without
        # narrowing the corridor either part needs.
        place(f"D{n+1}", 19, y, 90)
        place(f"Q{n+1}", 25, y+8)
        # The disc bypass stands on end: the 4.41 mm corridor the old film
        # body used cannot take its 8.09 mm width lying down, and no pad may
        # approach the data pair's ground reference.
        place(f"C{n+1}", 14, y+9.6, 90)
        place(f"Q{n+2}", 31.37, y+7.15, 90)
        place(f"R{n+1}", *divider[ch][0])
        place(f"R{n+2}", *divider[ch][1])

    from pcb import point
    import pcbnew as p
    for ref in ("H1", "H2", "H3", "H4"):
        # Mechanical features carry no designator there is room to print.
        fps[ref].Reference().SetVisible(False)
    # Printed references occupy clear gaps outside physical bodies and pads.
    # Courtyard margins remain reserved for assembly access, not blank ink.
    refs = {
        "C1": (22.25, 6.5, 0),
        "C101": (13.75, 40.5, 0),
        "C102": (49.25, 28.25, 0),
        "C2": (47.25, 16.25, 0),
        "C201": (13.75, 65.5, 0),
        "C202": (42, 58.25, 0),
        "D101": (19, 43.25, 0),
        "D201": (15.8, 54.75, 0),
        "D3": (16, 31.5, 0),
        "F1": (47.25, 12.5, 0),
        "F101": (44.5, 26.5, 0),
        "F102": (44.5, 39.5, 0),
        "F201": (48.25, 51.5, 0),
        "F202": (44.5, 64.5, 0),
        "J1": (52.5, 7, 0),
        "J101": (12.6, 28.7, 0),
        "J102": (62, 34.75, 90),
        "J103": (62, 21.62, 90),
        "J2": (9.5, 8, 0),
        "J201": (12.75, 61, 0),
        "J202": (62, 59.75, 90),
        "J203": (62, 47.25, 90),
        "K1": (23.25, 30, 0),
        "K101": (27, 31.5, 0),
        "K201": (27, 56.5, 0),
        "Q1": (5.5, 7.5, 0),
        "Q101": (25, 40.5, 0),
        "Q102": (34.75, 39.5, 0),
        "Q2": (12, 38.25, 0),
        "Q201": (25, 65.5, 0),
        "Q202": (34.75, 64.5, 0),
        "Q5": (8.5, 20.3, 0),
        "R1": (22.25, 2, 0),
        "R101": (35.7, 49, 0),
        "R102": (43.5, 53.25, 0),
        "R2": (22.25, 4.25, 0),
        "R201": (19.25, 71, 0),
        "R202": (37.5, 70.75, 0),
        "R5": (30.3, 52.5, 0),
        "R6": (2, 40.3, 0),
        "R7": (4.3, 18.9, 90),
        "R8": (52, 70.5, 0),
    }
    for ref, (x, y, angle) in refs.items():
        text = fps[ref].Reference()
        text.SetPosition(point(x, y))
        text.SetTextAngle(p.EDA_ANGLE(angle, p.DEGREES_T))
    # Keep the cathode mark by D3's cathode, outside the rotated Q5 body.
    for graphic in fps["D3"].GraphicalItems():
        if isinstance(graphic, p.PCB_TEXT) and graphic.GetText() == "K":
            graphic.SetPosition(point(15.5, 28))
    # The lower output plug's stock pin-one triangle extends into the longer
    # USB housing. Move just that marker beside the same end of the plug;
    # its body outline and the square pin-one copper pad stay unchanged.
    for graphic in fps["J203"].GraphicalItems():
        if isinstance(graphic, p.PCB_SHAPE) and graphic.GetLayer() == p.F_SilkS:
            box = graphic.GetBoundingBox()
            if (p.ToMM(box.GetLeft()) > 55.5
                    and p.ToMM(box.GetRight()) < 56.5
                    and p.ToMM(box.GetTop()) > 51.4):
                graphic.Move(point(5, .3))
