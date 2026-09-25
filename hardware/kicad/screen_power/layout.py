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
    place("C1", 50, 16.5, 90)
    place("C2", 43, 16.5)
    place("R3", 17.25, 3.5)
    place("R4", 38, 3.5)
    place("R8", 44, 73)
    place("R1", 17.25, 9)
    place("R2", 17.25, 14)
    place("Q1", 27, 14)
    place("D1", 29, 19)
    place("R5", 29, 23)
    place("R6", 16, 23)
    place("R7", 18, 28)
    place("Q2", 29, 28)
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
    refs = {"R1": (17, 11.3), "R2": (17, 16.3), "R3": (17, 1.2),
            "R4": (38, 1.2), "Q1": (27, 11), "D1": (34, 16.7),
            "R5": (35, 25), "R6": (16, 20.5), "R7": (18, 25.6),
            "Q2": (34, 28), "C1": (50, 11.4), "C2": (38, 16.5),
            "J1": (51, 8), "J2": (6, 18), "R8": (44, 75)}
    for ch, y in enumerate(USB_ROWS[variant], 1):
        refs[f"J{ch*100+1}"] = (7, y+8)
        refs[f"J{ch*100+2}"] = (49, y+4.5)
        refs[f"J{ch*100+3}"] = (50, y-10)
        refs[f"D{ch*100+1}"] = (13.5, y+1)
        refs[f"Q{ch*100+1}"] = (31, y+8)
        refs[f"K{ch*100+1}"] = (27, y+5)
        refs[f"C{ch*100+1}"] = (15.5, y+12)
        refs[f"C{ch*100+2}"] = (50, y-8)
    for ref, at in refs.items():
        fps[ref].Reference().SetPosition(point(*at))
        fps[ref].Reference().SetTextAngle(p.EDA_ANGLE(0, p.DEGREES_T))
