"""Reject surface-mount parts in the hand assembly."""

def _fail(errors, code, detail):
    errors.append({"check":code,"detail":detail})


def check_through_hole(board, errors):
    """Reject surface contacts even on a footprint incorrectly marked THT."""
    import pcbnew as p
    import math

    for footprint in board.GetFootprints():
        ref = footprint.GetReference()
        name = str(footprint.GetFPID().GetLibItemName())
        if footprint.GetAttributes() & p.FP_SMD:
            _fail(errors, "hand_assembly", f"{ref}: surface-mount footprint on THT carrier")
        for pad in footprint.Pads():
            if pad.GetAttribute() not in (p.PAD_ATTRIB_PTH, p.PAD_ATTRIB_NPTH):
                _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: pad is not through-hole")
            elif pad.GetAttribute() == p.PAD_ATTRIB_PTH:
                drill = pad.GetDrillSize()
                if drill.x <= 0 or drill.y <= 0:
                    _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: through-hole pad has no drill")
                finished_min = min(p.ToMM(drill.x), p.ToMM(drill.y)) - .08
                required = (1.0 if name.startswith('JST_XH_') and len(list(footprint.Pads()))==2 else
                            .9 if name.startswith('JST_XH_') else
                            1.65 if name.startswith('JST_VH_') else
                            .8 if name.startswith('DIP-') else
                            .85 if name=='TO-92_Inline_Wide' else
                            1.30 if ref == 'F1' else
                            1.10 if ref == 'K1' else
                            .90 if ref in ('F101','F102','F201','F202') else
                            1.30 if ref == 'Q5' else 0)
                if finished_min < required - 1e-6:
                    _fail(errors, 'hole_tolerance', f'{ref}.{pad.GetNumber()}: minimum finished hole {finished_min:.3f} mm is below {required:.2f} mm after fabrication tolerance')
            if ref.startswith('H') and min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y))-.2 < 3.2-1e-6:
                _fail(errors, 'hole_tolerance', f'{ref}: mounting hole lacks M3 clearance at minimum finished diameter')
            if ref == "Q5" and pad.GetNumber():
                # IRLZ44NPBF maximum rectangular lead is 1.01 x 0.61mm:
                # a 1.180mm diagonal needs finished-hole insertion allowance.
                if min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y)) < 1.4 - 1e-6:
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: hole too small for the selected power MOSFET lead")
                if min(pad.GetSize().x-pad.GetDrillSize().x,pad.GetSize().y-pad.GetDrillSize().y) < p.FromMM(.5):
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: power-device annulus below 0.25mm")

        # Pin distances are rotation invariant; they reject the wrong part's
        # apparently similar footprint without constraining placement.
        wanted = ({"1":(0,0), "8":(0,10.16), "3":(-10.16,0), "4":(-17.78,0)} if ref == "K1" else
                  {"1":(0,0), "2":(22.5,0)} if ref == "F1" else
                  {"1":(0,0), "2":(5.08,0)} if ref in ("F101","F102","F201","F202") else
                  {"1":(0,0), "2":(2.54,0), "3":(5.08,0)} if ref == "Q5" else None)
        if wanted:
            pads = {pad.GetNumber():pad for pad in footprint.Pads()}
            if len(pads) != len(list(footprint.Pads())) or set(pads) != set(wanted):
                _fail(errors, "part_geometry", f"{ref}: wrong physical terminal inventory")
                continue
            for a in wanted:
                for b in wanted:
                    delta = pads[a].GetPosition() - pads[b].GetPosition()
                    actual = math.hypot(p.ToMM(delta.x), p.ToMM(delta.y))
                    if abs(actual - math.dist(wanted[a], wanted[b])) > .001:
                        _fail(errors, "part_geometry", f"{ref}.{a}/{b}: terminal pitch differs from selected part")

            if ref == "K1":
                origin = pads["1"].GetPosition()
                coil = pads["8"].GetPosition() - origin
                contact = pads["3"].GetPosition() - origin
                if coil.x * contact.y - coil.y * contact.x <= 0:
                    _fail(errors, "part_geometry", "K1: mirrored bottom-view pin map on the top copper")
