"""Hand-soldered floorplan: compact control, accessible plugs, straight USB."""
DIMENSIONS = {"hand": (68, 76)}
CORNER_RADIUS = 3
USB_ROWS = {"hand": (36, 61)}
POWER_BUS_X = 64
USB_WIDTH = 0.85
USB_GAP = 0.16


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
    # Both DIPs are anchored on pin 1 rather than their bounding-box centre,
    # so route_critical.py works in pin coordinates: U1 pins 1-4 run east
    # along y = 19 with pins 8-5 along y = 11.38, and C3 bridges pins 2/4
    # symmetrically below the package.
    place("U1", 14.6, 19.0, 90, centre=False)
    place("C3", 19.68, 23.2)
    # Optocoupler and its LED network, east of the pump: pins 1/2 along
    # y = 20 and the negative-rail pins 4/3 along y = 12.38.
    place("U2", 25.6, 20.0, 90, centre=False)
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

    from pcb import point
    import pcbnew as p
    for ref in ("H1", "H2", "H3", "H4"):
        fps[ref].Reference().SetVisible(False)
    # Reference designators sit in the clear gaps left by the packing above:
    # every one is outside its own courtyard, so no designator hides under a
    # body in the 3D view, and none overlaps another footprint's silkscreen.
    refs = {"R1": (2.84, 16.8), "R2": (2.75, 24.67), "Q1": (4.88, 25.21),
            "R3": (37.39, 4.9), "R4": (50.36, 5.0), "R8": (44, 75),
            "C5": (15.7, 6.1), "C4": (23.83, 10.44), "D2": (18.64, 3.99),
            "U1": (17.94, 9.82), "C3": (20.29, 26.65), "U2": (30.77, 16.2),
            "R10": (30.55, 20.62), "R9": (29.08, 28.79),
            "Q2": (4.58, 48.79), "R5": (10.27, 46.6), "R6": (14.27, 54.49),
            "R7": (27.27, 54.49),
            "C1": (50, 11.4), "C2": (38, 16.5), "J1": (51, 8), "J2": (11.82, 13),
            "C101": (15.31, 42.81), "C201": (15.69, 72.19)}
    for ch, y in enumerate(USB_ROWS[variant], 1):
        refs[f"J{ch*100+1}"] = (12.61, y-0.44)
        refs[f"J{ch*100+2}"] = (49, y+4.5)
        refs[f"J{ch*100+3}"] = (50, y-10)
        refs[f"D{ch*100+1}"] = (13.5, y+1)
        refs[f"Q{ch*100+1}"] = (31, y+8)
        refs[f"K{ch*100+1}"] = (27, y+5)
        refs[f"C{ch*100+2}"] = (50, y-8)
    for ref, at in refs.items():
        fps[ref].Reference().SetPosition(point(*at))
        fps[ref].Reference().SetTextAngle(p.EDA_ANGLE(0, p.DEGREES_T))
