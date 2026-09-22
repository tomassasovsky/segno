"""Connector-led floorplans: power across top, two straight USB channels."""
DIMENSIONS = {"hand": (72, 84), "factory": (72, 74)}
USB_ROWS = {"hand": (29, 68), "factory": (29, 58)}


def place_components(variant, place, fps):
    hand = variant == "hand"
    w, h = DIMENSIONS[variant]
    for i, at in enumerate(((4, 4), (w-4, 4), (4, h-4), (w-4, h-4)), 1):
        place(f"H{i}", *at)
    place("J1", 13, 8)
    place("J2", 7, 46 if hand else 43)
    if hand:
        place("Q3", 32, 9)
        place("Q4", 46, 9, 180)
        place("C1", 11, 18)
        place("C2", 21, 10)
        place("R3", 28, 16)
        place("R4", 43, 5)
        place("R8", 46, 81)
        place("R1", 19, 44)
        place("R2", 19, 49)
        place("Q1", 31, 43)
        place("Q2", 42, 43)
        place("D1", 30, 49)
        place("R5", 42, 49)
        place("R6", 30, 54)
        place("R7", 56, 46, 90)
    else:
        place("Q3", 29, 9, 0)
        place("Q4", 46, 9, 0)
        place("C1", 19, 18, 90)
        place("C2", 14, 17)
        place("R3", 25, 19)
        place("R4", 34, 19)
        place("R8", 46, 71)
        place("R1", 16, 40)
        place("R2", 19, 40, 90)
        place("Q1", 23, 40)
        place("Q2", 36, 40)
        place("D1", 27, 44)
        place("R5", 31, 40)
        place("R6", 36, 36)
        place("R7", 40, 40, 90)
    for ch, y in enumerate(USB_ROWS[variant], 1):
        n = 100 * ch
        place(f"J{n+1}", 15.4, y+1.25, 180, centre=False)
        place(f"J{n+2}", w-12.8, y, 180, centre=False)
        place(f"K{n+1}", 32, y, 0, centre=False)
        place(f"J{n+3}", 64, y-13)
        place(f"F{n+1}", 46, y-9 if not hand and ch==1 else y-12)
        place(f"F{n+2}", 46, y+7)
        place(f"C{n+2}", 57 if not hand else 60, y+9)
        if hand:
            place(f"D{n+1}", 26, y-8.5)
            place(f"Q{n+1}", 26, y+8)
            place(f"C{n+1}", 17, y+11)
        else:
            place(f"D{n+1}", 26.5, y-6)
            place(f"Q{n+1}", 27, y+6)
            place(f"C{n+1}", 21, y+4)

    from pcb import point
    import pcbnew as p
    for ref in ("H1", "H2", "H3", "H4"):
        fps[ref].Reference().SetVisible(False)
    refs = {"R1":(19,46.2),"R2":(19,51.4)} if hand else {"R2":(19,37),"C1":(22,18),"C2":(20,15)}
    for ch,y in enumerate(USB_ROWS[variant],1):
        refs[f"J{ch*100+2}"]=(65,y+6)
        if not hand: refs[f"Q{ch*100+1}"]=(31, y+7.5)
    for ref,at in refs.items():
        fps[ref].Reference().SetPosition(point(*at))
        fps[ref].Reference().SetTextAngle(p.EDA_ANGLE(0,p.DEGREES_T))
