"""Through-hole carrier floorplan and deliberately routed USB/power paths."""
import math
from pathlib import Path
import pcbnew as p
from pcb import point, xy

HERE = Path(__file__).resolve().parent


def place_components(place, fps):
    place('J1',65,10)
    place('J2',65,22)
    place('R1',60,33,90)
    place('R2',70,33,90)
    place('R3',60,47,90)
    place('R4',70,47,90)
    place('Q1',65,57)
    place('R5',65,68,90)
    for i,at in enumerate([(5,5),(125,5),(5,115),(125,115)],1):
        place(f'H{i}',*at)
    for ch,x in [(1,38),(2,93)]:
        n=ch*100
        place(f'J{n+3}',18 if ch==1 else 112,12,0 if ch==1 else 180)
        place(f'J{n+4}',18 if ch==1 else 112,24)
        place(f'J{n+1}',x-10.75,103.7125,270,centre=False)
        place(f'J{n+2}',x+12,108.5,90)
        place(f'K{n+1}',x,89,90,centre=False)
        fps[f'K{n+1}'].Reference().SetPosition(point(x+7.5,87.5))
        fps[f'K{n+1}'].Reference().SetTextAngle(p.EDA_ANGLE(0,p.DEGREES_T))
        place(f'K{n+2}',x+4,62,90)
        place(f'F{n+1}',x-(21 if ch==1 else 17),62,90)
        place(f'R{n+1}',x-13,34)
        place(f'R{n+2}',x-13,43)
        place(f'R{n+3}',x+3,34)
        place(f'R{n+4}',x+15,43,90)
        place(f'R{n+5}',x-2,8)
        place(f'R{n+6}',x+15,82)
        place(f'Q{n+1}',x-3,17)
        place(f'Q{n+2}',x+3,43)
        place(f'Q{n+3}',x+6,49)
        place(f'Q{n+4}',x,78)
        place(f'D{n+1}',x-6,87,90)
        place(f'D{n+2}',x-10,62,90)
        fps[f'D{n+2}'].Reference().SetPosition(point(x-10,53))
        fps[f'D{n+2}'].Reference().SetTextAngle(p.EDA_ANGLE(0,p.DEGREES_T))
        fps[f'K{n+2}'].Reference().SetPosition(point(x+4,52.5))
        fps[f'K{n+2}'].Reference().SetTextAngle(p.EDA_ANGLE(0,p.DEGREES_T))
        place(f'C{n+1}',x-15,90)
        place(f'C{n+2}',x-7,48)
        place(f'C{n+3}',x+19,70)


def route_critical():
    path=HERE/'hand/screen_power_hand.placed.kicad_pcb'
    board=p.LoadBoard(str(path));fps={f.GetReference():f for f in board.GetFootprints()};nets=board.GetNetsByName()
    def pad(ref,num):return next(a for a in fps[ref].Pads() if a.GetNumber()==str(num))
    def at(ref,num):return xy(pad(ref,num).GetPosition())
    def track(net,pts,width=.26,layer=p.F_Cu):
        for a,b in zip(pts,pts[1:]):
            if math.dist(a,b)<1e-6:continue
            t=p.PCB_TRACK(board);t.SetStart(point(*a));t.SetEnd(point(*b));t.SetWidth(p.FromMM(width));t.SetLayer(layer);t.SetNet(nets[net]);t.SetLocked(True);board.Add(t)
    def join(a,b,bends=(),width=.26,layer=p.F_Cu):
        assert pad(*a).GetNetname()==pad(*b).GetNetname(),(a,b)
        track(pad(*a).GetNetname(),[at(*a),*bends,at(*b)],width,layer)
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

    # The external Type-C modules carry the main loads. Keep their AUX feeds
    # wide and outside the USB region; the inner planes remain continuous GND.
    power=at('J1',1)
    track('AUX_5V',[power,(power[0],4)],4.5,p.B_Cu)
    for ch,x in [(1,38),(2,93)]:
        n=100*ch;pre=f'S{ch}'
        edge=8 if ch==1 else 122
        j=at(f'J{n+3}',1)
        top=(12 if ch==1 else 118,4)
        track('AUX_5V',[(power[0],4),top,(edge,8),(edge,j[1]),j],3,p.B_Cu)
        # Both clips have two soldered legs; connect both legs deliberately.
        for number in ('1','2'):
            points=sorted([xy(a.GetPosition()) for a in fps[f'F{n+1}'].Pads() if a.GetNumber()==number])
            track(pad(f'F{n+1}',number).GetNetname(),points,1.2,p.B_Cu)
        f=at(f'F{n+1}',1)
        track('AUX_5V',[j,(edge,j[1]),(edge,69),(edge+(4 if ch==1 else -4),73),(f[0],73),f],1.5,p.F_Cu)
        # Per-port fuse and the power relay provide the touch VBUS branch.
        a=at(f'F{n+1}',2);b=at(f'K{n+2}',3)
        join((f'F{n+1}',2),(f'K{n+2}',3),[(a[0],60),(b[0]-8,60),(b[0]-8,64),(b[0]-4,68)],1,p.B_Cu)
        a=at(f'K{n+2}',1);b=at(f'C{n+3}',1)
        join((f'K{n+2}',1),(f'C{n+3}',1),[(x+7,62),(b[0]-3,70)],1,p.F_Cu)
        c=at(f'J{n+2}',1)
        join((f'C{n+3}',1),(f'J{n+2}',1),[(x+23,76),(x+23,112),(x+20,115),(x+15,115),(c[0],112)],1,p.B_Cu)
        # Flyback loops remain local, and the two coil returns are separate.
        join((f'D{n+2}',1),(f'K{n+2}',2),[(x-9,68)],.5)
        a=at(f'F{n+1}',1)
        join((f'F{n+1}',1),(f'D{n+2}',1),[(x-14,71.4),(x-10,67.4)],.5)
        join((f'D{n+2}',2),(f'K{n+2}',5),[(x-9,56)],.35)
        join((f'K{n+2}',5),(f'Q{n+3}',2),[(x+.8725,52.5),(x+6,52.5)],.35,p.B_Cu)
        join((f'K{n+1}',1),(f'D{n+1}',1),[(x+4.5,94.77),(x+4.5,97),(x-5,97),(x-6,96)],.35,p.B_Cu)
        join((f'J{n+1}',1),(f'D{n+1}',1),[(x-8,103.7125),(x-4,99.7125),(x-4,98),(x-6,96)],.35,p.B_Cu)
        join((f'C{n+1}',1),(f'D{n+1}',1),[(x-17.5,96.08),(x-10,96.08)],.35,p.B_Cu)
        join((f'K{n+1}',8),(f'D{n+1}',2),[(x-8,87.35),(x-8,83.92)],.35,p.B_Cu)
        join((f'D{n+1}',2),(f'Q{n+4}',3),[(x-4.46,80.38),(x+2.54,80.38)],.35,p.B_Cu)
        # Host coil supply is a separate low-current domain, never AUX.
        host=f'J{n+1}';relay=f'K{n+1}'
        mid=(at(host,3)[0],(at(host,3)[1]+at(host,2)[1])/2)
        pair([(host,3),(host,2)],[(relay,6),(relay,3)],
             [(mid[0]-1.2,mid[1]),(mid[0]-2.5,mid[1]),
              (mid[0]-4,mid[1]-1.5),(mid[0]-4,100),
              (mid[0]-2,98),(x-3,98),(x,95),(x,89)],1)
        touch=f'J{n+2}';yt=(at(touch,3)[1]+at(touch,2)[1])/2
        pair([(relay,5),(relay,4)],[(touch,3),(touch,2)],
             [(x,83.7),(x,81),(x+1,80),(x+4,80),
              (x+6,82),(x+6,99),(x+10,103),(at(touch,3)[0]-1.3,yt)],1)
    board.Save(str(path))
