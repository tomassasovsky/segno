"""Reject surface-mount parts in the hand assembly."""

def _fail(errors, code, detail):
    errors.append({"check":code,"detail":detail})


def check_through_hole(board, errors):
    """Reject surface contacts even on a footprint incorrectly marked THT."""
    import pcbnew as p

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
                            .85 if name=='TO-92_Inline_Wide' else 0)
                if finished_min < required - 1e-6:
                    _fail(errors, 'hole_tolerance', f'{ref}.{pad.GetNumber()}: minimum finished hole {finished_min:.3f} mm is below {required:.2f} mm after fabrication tolerance')
            if ref.startswith('H') and min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y))-.2 < 3.2-1e-6:
                _fail(errors, 'hole_tolerance', f'{ref}: mounting hole lacks M3 clearance at minimum finished diameter')
            if ref in ("Q3", "Q4") and pad.GetNumber():
                # SUP70101EL maximum rectangular lead is 1.01 x 0.61mm:
                # a 1.180mm diagonal needs finished-hole insertion allowance.
                if min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y)) < 1.3:
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: hole too small for the selected power MOSFET lead")
                if min(pad.GetSize().x-pad.GetDrillSize().x,pad.GetSize().y-pad.GetDrillSize().y) < p.FromMM(.5):
                    _fail(errors,"hand_assembly",f"{ref}.{pad.GetNumber()}: power-device annulus below 0.25mm")
