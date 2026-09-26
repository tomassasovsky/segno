"""Hand-soldered floorplan: compact control, accessible plugs, straight USB."""
DIMENSIONS = {"hand": (68, 76)}
CORNER_RADIUS = 3
USB_ROWS = {"hand": (36, 61)}
POWER_BUS_X = 64
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
    place("Q3", 44, 8, 180)
    place("Q4", 31, 8)
    # Leave room for the complete VHR mating-housing envelope, not just the
    # bare header. The adjacent electrolytic retains its body clearance.
    place("C1", 48.5, 16.5, 90)
    place("C2", 43, 16.5)
    place("R8", 44, 73)
    # Both gate resistors sit directly above the transistors they drive, so
    # POWER_GATE stays a short top-edge net and the negative-rail parts get
    # the whole north strip.
    place("R3", 33.58, 2.7)
    place("R4", 46.38, 2.7)
    # North strip: the charge-pump satellites. C5 bypasses U1 pins 8/3, C4 is
    # the NEG_5V reservoir beside pin 5 and D2 clamps that rail along the
    # top edge. Their loops close through the filled GND pours. D2 faces east
    # so its cathode marker, which the DO-35 footprint places 1.8 mm beyond
    # the courtyard, points into the board instead of over the edge.
    place("C5", 13.0, 6.1, 90)
    # C4 sits on U1 pin 5's own column: its negative-rail terminal lines up
    # with the pin it reservoirs, which takes the jog out of that rail and
    # leaves twice the room between the 5.5mm can and Q4's 10.54mm tab body.
    place("C4", 22.22, 7.0, 270)
    place("D2", 22.09, 1.8, 180)
    # Anchor both DIPs on pin 1 with shared rows at y=19.25/11.63.
    # Split the correction: U1 moves down 0.25 mm and U2 up 0.75 mm.
    # Moving U2 alone by 1 mm would overlap Q4's stock courtyard.
    # C3 stays centered below U1 pins 2/4; all capacitors stay fixed.
    place("U1", 14.6, 19.25, 90, centre=False)
    place("C3", 19.68, 23.2)
    # Optocoupler and its LED network, east of the pump, on the same two rows:
    # pins 1/2 along y = 19.25 and the negative-rail pins 4/3 along y = 11.63.
    place("U2", 25.6, 19.25, 90, centre=False)
    place("R10", 28.89, 23.0)
    place("R9", 28.89, 26.6, 180)
    # GPIO input stage keeps its own bay between the two left-hand plugs.
    # Q1 sits at the bay's east end: the only front-copper channel past the
    # USB rows runs up the left edge, so its terminals stay out of it.
    place("R1", 6.65, 19.16, 180)
    place("R2", 6.65, 22.42)
    place("Q1", 8.54, 26.54)
    # The relay-enable buffer moves between the two relay channels: the
    # control area cannot hold it once the gate driver is in place, and the
    # gates it drives sit either side of this band.
    place("Q2", 4.04, 45.74)
    place("R5", 14.08, 48.8, 180)
    place("R6", 14.08, 52.3, 180)
    place("R7", 27.08, 52.3)
    # Revision M's two-switch coil stage, per channel. Everything new sits on
    # the same side of its own USB row as the FET it stacks on, so no new net
    # has to pass a data pair: the coil's low side keeps the one crossing it
    # always had, through the lane between the relay's contact columns.
    #
    # The upper FET stands vertically 7.15 mm below its row, which puts pin 1
    # (the stack node) about 4.4 mm from the lower FET's drain and pin 3 (the coil's
    # low side) pointing at that crossing lane, with pin 2 (the gate) between
    # them. 0.11 mm of its courtyard to the relay's is the tightest gap on the
    # board, in the same family as the 0.14 mm U2 to Q4 and 0.15 mm U1 to C3
    # gaps already accepted here.
    #
    # The dividers cannot take the same offset in both channels, and pretending
    # otherwise would cost a row crossing: channel 1 has the whole 25 mm band
    # between the rows below it, channel 2 only the 14 mm south of its own row,
    # where the mounting hole, the bleeder and the bypass can already be found.
    # So channel 1 stacks its divider under the relay and channel 2 lays it
    # along the south edge, each with its 10k arm nearest its own host plug so
    # that HOSTx_5V, which exists on exactly one connector pin, stays short.
    # The 100k arm of channel 1 takes the strip below the pulldown row: that is
    # the only 12.35mm slot left in the band, because the fuse holder owns the
    # rest of its own row and the bleeder its neighbour. Its tap terminal is the
    # west one, nearest the other two pads on that node.
    divider = {1: ((27.13, 49.0), (37.9, 55.6)),
               2: ((14.5, 73.3), (27.2, 73.5))}
    # Bare shield-drain pads beside their own headers. The host pad takes the
    # bay between the plug and the flyback diode; the touch pad the 3.3mm
    # channel between the reservoir can and the plug, which is the only gap on
    # that side clear of the main-output band on the back and the switched
    # branch to the edge bus on the front.
    shield_host, shield_touch = (13.5, -4.5), (51.47, -4.0)
    for ch, y in enumerate(USB_ROWS[variant], 1):
        n = 100 * ch
        place(f"J{n+1}", 7, y+3.75, 90, centre=False)
        place(f"J{n+2}", 56, y+3.75, 90, centre=False)
        place(f"K{n+1}", 23.2, y+2.54, 90, centre=False)
        place(f"J{n+3}", 56, y-11, 90, centre=False)
        place(f"F{n+1}", 43, y-13, 180)
        place(f"F{n+2}", 43, y+7, 180)
        place(f"C{n+2}", 47, y-4)
        place(f"D{n+1}", 17, y, 90)
        place(f"Q{n+1}", 25, y+8)
        place(f"C{n+1}", 15.5, y+9)
        place(f"Q{n+2}", 31.37, y+7.15, 90)
        place(f"R{n+1}", *divider[ch][0])
        place(f"R{n+2}", *divider[ch][1])
        place(f"TP{n+1}", shield_host[0], y+shield_host[1])
        place(f"TP{n+2}", shield_touch[0], y+shield_touch[1])

    from pcb import point
    import pcbnew as p
    for ref in ("H1", "H2", "H3", "H4",
                "TP101", "TP102", "TP201", "TP202"):
        # Mechanical features, and the shield pads are read by position beside
        # their own plug, not by a designator there is no room to print.
        fps[ref].Reference().SetVisible(False)
    # Bare shield pads need no decorative ring; the stock circle is too close
    # to its own mask opening after normalization to the fabrication stroke.
    for ref in ("TP101", "TP102", "TP201", "TP202"):
        fp = fps[ref]
        for graphic in list(fp.GraphicalItems()):
            if (isinstance(graphic, p.PCB_SHAPE)
                    and graphic.GetShape() == p.SHAPE_T_CIRCLE
                    and graphic.GetLayer() == p.F_SilkS):
                fp.RemoveNative(graphic)
    # Reference designators sit in the clear gaps left by the packing above:
    # every one is outside its own courtyard, so no designator hides under a
    # body in the 3D view, and none overlaps another footprint's silkscreen.
    refs = {"R1": (2.84, 16.8), "R2": (2.75, 24.67), "Q1": (4.88, 25.21),
            "R3": (37.39, 5.1), "R4": (50.36, 5.0), "R8": (52, 73),
            "Q3": (44, 11.35), "Q4": (29, 4.65),
            "C5": (15.7, 6.1), "C4": (23.83, 10.44), "D2": (18.64, 3.99),
            # References follow their respective package offsets.
            "U1": (17.94, 10.07), "C3": (20.29, 26.65), "U2": (30.77, 15.45),
            "R10": (30.55, 20.62), "R9": (29.08, 28.99),
            # The 1.48mm between this resistor's own body outline and the
            # shield pad's silk circle cannot hold a 1.70mm designator, so
            # this one reads off the west end of its own leads.
            "Q2": (4.58, 48.99), "R5": (10.27, 46.6), "R6": (5.5, 52.3),
            "R7": (27.27, 54.69),
            "C1": (50, 11.4), "C2": (38, 16.5), "J1": (51, 8), "J2": (11.82, 13),
            "C101": (13, 42.5), "C201": (13, 67.5),
            # Revision M. Each of these is in the nearest gap that is clear of
            # every courtyard; the board is full enough that two of them sit
            # beside their part rather than over it.
            "Q102": (35.6, 39.2), "Q202": (35.6, 64.2),
            # The 100k arm reads below its own body: the strip above it is the
            # screen-power connector legend's.
            "R101": (36.5, 51.5), "R102": (37.9, 58.2),
            "R201": (8.5, 70.6), "R202": (35.6, 73.6)}
    for ch, y in enumerate(USB_ROWS[variant], 1):
        refs[f"J{ch*100+1}"] = (12.61, y-0.44)
        refs[f"J{ch*100+2}"] = (49, y+4.5)
        refs[f"J{ch*100+3}"] = (50, y-10)
        refs[f"D{ch*100+1}"] = (13.3, y+1)
        # The lower FET's designator shares the 2.05mm strip between the relay
        # and the FET row with the relay's own, west of it; the upper FET's pad
        # column now owns the east end of that strip.
        refs[f"Q{ch*100+1}"] = (23, y+4.4)
        refs[f"K{ch*100+1}"] = (27, y+5)
        # North of the reservoir can, where its own silk circle and the shield
        # pad leave nothing on the plug side, and east of the screen-power
        # connector legend that shares this strip.
        refs[f"C{ch*100+2}"] = (49, y-8.5)
    for ref, at in refs.items():
        fps[ref].Reference().SetPosition(point(*at))
        fps[ref].Reference().SetTextAngle(p.EDA_ANGLE(0, p.DEGREES_T))
