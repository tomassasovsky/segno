"""Explicit USB, clock, power and bypass routes before general signal routing."""
import math
from pathlib import Path
import sys
import pcbnew as p
from pcb import point, xy

HERE = Path(__file__).resolve().parent


def route(variant):
    if variant == "hand":
        from hand_layout import route_critical
        return route_critical()
    out = HERE / variant
    path = out / f"screen_power_{variant}.placed.kicad_pcb"
    board = p.LoadBoard(str(path))
    fps = {fp.GetReference(): fp for fp in board.GetFootprints()}
    nets = board.GetNetsByName()

    def pad(ref, number):
        return next(pad for pad in fps[ref].Pads() if pad.GetNumber() == str(number))

    def at(ref, number):
        return xy(pad(ref, number).GetPosition())

    def track(name, pts, width=0.25, layer=p.F_Cu):
        for a, b in zip(pts, pts[1:]):
            if math.dist(a, b) < 1e-6:
                continue
            t = p.PCB_TRACK(board)
            t.SetStart(point(*a)); t.SetEnd(point(*b)); t.SetNet(nets[name])
            t.SetWidth(p.FromMM(width)); t.SetLayer(layer); t.SetLocked(True)
            board.Add(t)

    def via(name, pos, size=0.6, drill=0.3):
        v = p.PCB_VIA(board)
        v.SetPosition(point(*pos)); v.SetWidth(p.FromMM(size)); v.SetDrill(p.FromMM(drill))
        v.SetViaType(p.VIATYPE_THROUGH); v.SetLayerPair(p.F_Cu, p.B_Cu)
        v.SetNet(nets[name]); v.SetLocked(True); board.Add(v)

    def join(a, b, bends=(), width=0.25, layer=p.F_Cu):
        assert pad(*a).GetNetname() == pad(*b).GetNetname(), (a, b)
        track(pad(*a).GetNetname(), [at(*a), *bends, at(*b)], width, layer)

    def pair(a, b, centre, polarity=1):
        """Mitered offsets maintain 0.26 mm width / 0.16 mm gap on bends.

        Start/end pad fanouts are uncoupled only as required by package pitch.
        The fabricator must confirm 90 ohms for the specified four-layer stack.
        """
        vectors = []
        for x, y in zip(centre, centre[1:]):
            dx, dy = y[0]-x[0], y[1]-x[1]
            length = math.hypot(dx, dy)
            vectors.append((dy/length, -dx/length))
        offsets = [vectors[0]]
        for x, y in zip(vectors, vectors[1:]):
            scale = 1 + x[0]*y[0] + x[1]*y[1]
            offsets.append(((x[0]+y[0])/scale, (x[1]+y[1])/scale))
        offsets.append(vectors[-1])
        for index, sign in enumerate([polarity, -polarity]):
            pts = [(pos[0]+normal[0]*0.21*sign, pos[1]+normal[1]*0.21*sign)
                   for pos, normal in zip(centre, offsets)]
            first = vectors[0]
            last = vectors[-1]
            ap, bp = at(*a[index]), at(*b[index])
            pts = [(ap[0]-first[1]*0.8, ap[1]+first[0]*0.8), *pts,
                   (bp[0]+last[1]*0.8, bp[1]-last[0]*0.8)]
            join(a[index], b[index], pts, 0.26)

    # Every surface ground has a short path to both continuous planes.
    # Freerouting treats plane nets as complete, so these are explicit.
    for ref, pin, dx, dy in [("R2",2,0,1.2),("R4",2,0,1.2),("Q1",2,0,1.2)]:
        pos=at(ref,pin);vpos=(pos[0]+dx,pos[1]+dy)
        track("GND",[pos,vpos],.35);via("GND",vpos)
    gate = at("Q1",3)
    track("DISCHARGE",[gate,(69,44.0625),(69,67)],.35)
    via("DISCHARGE",(69,67))
    for ref,bx in [("Q102",55.5),("Q202",110.5)]:
        g=at(ref,1);v=(bx+.5,g[1])
        track("DISCHARGE",[g,v],.35);via("DISCHARGE",v)
        track("DISCHARGE",[(69,67),(bx,67),(bx,g[1]+.5),v],.35,p.B_Cu)
    g=at("Q101",1)
    track("DISCHARGE",[g,(12.5,42.05)],.35)
    via("DISCHARGE",(12.5,42.05));via("DISCHARGE",(69,44.0625))
    track("DISCHARGE",[(12.5,42.05),(13.65,43.2),(68.1375,43.2),(69,44.0625)],.35,p.B_Cu)
    # Distribute AUX to two 3 A main outputs plus limited touch branches.
    # Main-source branches use 3 mm copper; the shared input neck is 4.5 mm.
    # Combined fault limits can approach 8.8 A: validate temperature on hardware.
    power = at("J1", 1)
    track("AUX_5V", [power, (power[0], 50)], 4.5, p.B_Cu)
    for channel, x in [(1, 38), (2, 93)]:
        n, pre = channel*100, f"S{channel}"
        u = f"U{n+1}"
        source, jack = f"U{n+4}", f"J{n+3}"
        px = 17 if channel == 1 else 113
        bulk = at(f"C{n+11}", 1)
        edge = 7 if channel == 1 else 123
        track("AUX_5V", [(power[0], 50), (edge+3 if channel == 1 else edge-3, 50),
                          (edge, 47), (edge, 29),
                          (edge+3 if channel == 1 else edge-3, 26), bulk], 3, p.B_Cu)
        bus = (px-4, 18.5)
        track("AUX_5V", [bulk, (bulk[0], 23), (bus[0], 23-abs(bulk[0]-bus[0])), bus], 2, p.B_Cu)
        for dx, dy in [(-0.6, 0), (0.6, 0), (-0.6, 1.2), (0.6, 1.2)]:
            v = (bus[0]+dx, bus[1]+dy)
            via("AUX_5V", v, 1.0, 0.4)
            track("AUX_5V", [bus, v], 0.6, p.F_Cu)
        track("AUX_5V", [bus, (px-4, 16)], 1.2)
        for pin in [2, 3, 4, 5]:
            pos = at(source, pin)
            track("AUX_5V", [pos, (px-2.4, pos[1]), (px-3.15, 16), (px-4, 16)], 0.25)
        join((source, 2), (f"C{n+10}", 1), [(px-3.2, 15.25)], 0.35)
        for pin in [12]:
            pos = at(source, pin)
            track("GND", [pos, (px+0.7, pos[1])], 0.25)
        cc = at(jack, "B5")
        pos = (cc[0], cc[1]+1.1)
        track(f"{pre}_CC2", [cc, pos], 0.2)
        via(f"{pre}_CC2", pos)
        cc2 = at(source,13)
        vcc=(px+2.7,16.75)
        track(f"{pre}_CC2",[cc2,(px+2.2,16.25),vcc],.2)
        via(f"{pre}_CC2",vcc)
        track(f"{pre}_CC2",[pos,(pos[0],12),(px+2.7,15.2),vcc],.25,p.B_Cu)
        for ref,delta in [(f"C{n+10}",(-1.2,0)),(f"C{n+12}",(1.4,0))]:
            g=at(ref,2);v=(g[0]+delta[0],g[1]+delta[1]);track("GND",[g,v],.4);via("GND",v)
        for pin in [14, 15]:
            pos = at(source, pin)
            track(f"{pre}_MAIN_5V", [pos, (px+2.4, pos[1]), (px+3.1, 15.5)], 0.25)
        track(f"{pre}_MAIN_5V", [(px+2.4, 15.5), (px+3.7, 15.5)], 0.65)
        track(f"{pre}_MAIN_5V", [(px+3.7, 15.5), (px+4.5, 14.7), (px+4.5, 13.475),
                                  (px+3, 11.975), (px+3, 9.475), (px, 9.475)], 2)
        join((f"C{n+12}", 1), (source, 14), [(px+4.5, 13.475), (px+4.5, 14.7), (px+3.7, 15.5),
                                           (px+2.4, 15.75)], 0.4)
        for pin in ["A9", "B9"]:
            pos = at(jack, pin)
            track(f"{pre}_MAIN_5V", [pos, (pos[0], 8.475), (px, 9.475)], 0.65)
        for ref,pin,delta in [(f"U{n+2}",3,(0,1.2)),(f"U{n+3}",2,(-1.2,0)),
                              (f"Q{n+1}",2,(-1.2,0)),(f"Q{n+2}",2,(-1.2,0)),
                              (f"Y{n+1}",2,(-1.5,0)),(f"Y{n+1}",4,(-.7,.9))]:
            g=at(ref,pin);v=(g[0]+delta[0],g[1]+delta[1])
            track("GND",[g,v],.25);via("GND",v)
        for k in [0,1]:
            q=f"Q{n+1+k}";r=f"R{n+4+k}"
            qp,rp=at(q,3),at(r,2)
            bend=(qp[0]+1.2,qp[1])
            track(f"{pre}_DUMP{k}",[qp,bend,(bend[0],rp[1]+1.5),rp],.35)
        # The 0.75 A touch branch uses 0.7 mm copper to the cable and bulk cap.
        tap = (x-0.5, 62.5)
        track("AUX_5V", [(x-0.5, 50), tap], 0.7, p.B_Cu)
        via("AUX_5V", tap, 1.0, 0.4)
        join((f"C{n+8}", 1), (f"U{n+3}", 1), [(x-0.8125, 64.1375)], 0.7)
        track("AUX_5V", [tap, at(f"C{n+8}", 1)], 0.7)
        touch_bulk = at(f"C{n+9}", 1)
        join((f"U{n+3}", 6), (f"C{n+9}", 1), [(x+5.775, 61.5), (x+10, 61.5),
                                                         (touch_bulk[0], 61.5+touch_bulk[0]-x-10)], 0.7)
        usb_power = at(f"J{n+2}", 1)
        track(f"{pre}_TOUCH_5V", [touch_bulk, (x+17, 72), (x+17, usb_power[1]-5),
                                    usb_power], 0.7, p.B_Cu)
        # ESD devices are flow-through: connect their paired pads explicitly.
        for d in [f"D{n+1}", f"D{n+2}"]:
            join((d, 1), (d, 6), width=0.26)
            join((d, 3), (d, 4), width=0.26)
            for pin, offset in [(5, 0.55), (2, -0.55)]:
                pos = at(d, pin)
                vpos = (pos[0], pos[1]+offset)
                name = pad(d, pin).GetNetname()
                track(name, [pos, vpos], 0.25)
                via(name, vpos)
        # Upstream, ESD to isolator. + is left while travelling north.
        esd_mid = ((at(f"D{n+1}", 6)[0]+at(f"D{n+1}", 4)[0])/2,
                   at(f"D{n+1}", 6)[1])
        ymid = (at(u, 8)[1]+at(u, 9)[1])/2
        pair([(f"D{n+1}", 6), (f"D{n+1}", 4)], [(u, 8), (u, 9)],
             [(esd_mid[0], esd_mid[1]-1.5), (esd_mid[0], 84.5),
              (x-7.5, 84.5), (x-6, 83), (x-6, 81.15),
              (x-4.8, ymid), (at(u, 8)[0]-1.0, ymid)])
        # Downstream, isolator to ESD. Package pins put + below -.
        esd_mid2 = ((at(f"D{n+2}", 6)[0]+at(f"D{n+2}", 4)[0])/2,
                    at(f"D{n+2}", 6)[1])
        pair([(u, 12), (u, 13)], [(f"D{n+2}", 6), (f"D{n+2}", 4)],
             [(at(u, 12)[0]+1.0, ymid), (at(u, 12)[0]+2.3, ymid),
              (esd_mid2[0], ymid + esd_mid2[0]-at(u, 12)[0]-2.3),
              (esd_mid2[0], esd_mid2[1]-1.5)], -1)
        # The USB-B connector's vertical pin pair turns left, then north.
        j = f"J{n+1}"
        connector_mid = (at(j, 3)[0], (at(j, 3)[1]+at(j, 2)[1])/2)
        pair([(j, 3), (j, 2)], [(f"D{n+1}", 1), (f"D{n+1}", 3)],
             [(connector_mid[0]-1.2, connector_mid[1]),
              (connector_mid[0]-2.5, connector_mid[1]),
              (connector_mid[0]-4, connector_mid[1]-1.5),
              (connector_mid[0]-4, 96), (esd_mid[0], 91.6625),
              (esd_mid[0], 90.6375)], 1)
        # Downstream connector breakout turns east then approaches from the
        # right, preserving polarity. No data test pads or open stubs.
        j = f"J{n+2}"
        yj = (at(j, 3)[1]+at(j, 2)[1])/2
        pair([(f"D{n+2}", 1), (f"D{n+2}", 3)], [(j, 3), (j, 2)],
             [(esd_mid2[0], 90.6375), (esd_mid2[0], 92),
              (x+18, 92+x+18-esd_mid2[0]),
              (x+18, yj), (at(j, 3)[0]+1.3, yj)], -1)
        # Crystals and bypasses have their own short routes and ground vias.
        join((u, 1), (f"C{n+1}", 1), [(at(u, 1)[0], 72.55)], 0.3)
        join((u, 3), (f"C{n+2}", 1), width=0.3)
        join((u, 18), (f"C{n+3}", 1), width=0.3)
        join((u, 20), (f"C{n+4}", 1), [(at(u, 20)[0], 72.55)], 0.3)
        join((u, 5), (f"Y{n+1}", 1), [(x-8.5, 77.675), (x-8.5, 73.9), (x-12.15, 73.9)], 0.2)
        join((u, 6), (f"Y{n+1}", 3), width=0.2)
        join((f"Y{n+1}", 1), (f"C{n+5}", 1), width=0.2)
        join((f"Y{n+1}", 3), (f"C{n+6}", 1), width=0.2)
        for pin in [2, 4, 7, 10, 11, 15, 16, 17, 19]:
            pos = at(u, pin)
            vpos = (pos[0] + (1.35 if pin < 11 else -1.35), pos[1])
            track("GND", [pos, vpos], 0.25); via("GND", vpos)
        for ref in [f"C{n+i}" for i in range(1, 9)] + [f"R{n+2}", f"R{n+3}"]:
            pos = at(ref, 2)
            if pad(ref, 2).GetNetname() == "GND":
                other = at(ref, 1)
                distance = math.dist(pos, other)
                vpos = (pos[0]+(pos[0]-other[0])*1.1/distance,
                        pos[1]+(pos[1]-other[1])*1.1/distance)
                if ref == f"C{n+6}":
                    vpos = (pos[0]+1.2, pos[1])
                if ref == f"C{n+2}":
                    vpos = (pos[0], pos[1]-1.3)
                track("GND", [pos, vpos], 0.35); via("GND", vpos)
    board.Save(str(path))
    print("Critical routes written", path)


if __name__ == "__main__":
    route(sys.argv[1])
