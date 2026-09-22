"""Reject surface-mount parts in the hand assembly."""

def _fail(errors, code, detail):
    errors.append({"check":code,"detail":detail})


def check_through_hole(board, errors):
    """Reject surface contacts even on a footprint incorrectly marked THT."""
    import pcbnew as p

    for footprint in board.GetFootprints():
        ref = footprint.GetReference()
        if footprint.GetAttributes() & p.FP_SMD:
            _fail(errors, "hand_assembly", f"{ref}: surface-mount footprint on THT carrier")
        for pad in footprint.Pads():
            if pad.GetAttribute() not in (p.PAD_ATTRIB_PTH, p.PAD_ATTRIB_NPTH):
                _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: pad is not through-hole")
            elif pad.GetAttribute() == p.PAD_ATTRIB_PTH:
                drill = pad.GetDrillSize()
                if drill.x <= 0 or drill.y <= 0:
                    _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: through-hole pad has no drill")
            if ref in ("Q3", "Q4") and pad.GetNumber():
                # SUP70101EL maximum rectangular lead is 1.01 x 0.61mm:
                # a 1.180mm diagonal needs finished-hole insertion allowance.
                if min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y)) < 1.3:
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: hole too small for the selected power MOSFET lead")
                if min(pad.GetSize().x-pad.GetDrillSize().x,pad.GetSize().y-pad.GetDrillSize().y) < p.FromMM(.5):
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: power-device annulus below 0.25mm")
