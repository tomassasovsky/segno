"""Explicit USB pairs, high-current paths and local relay loops."""
import math
from pathlib import Path
import sys
import pcbnew as p
from pcb import point, xy
from layout import USB_ROWS
HERE=Path(__file__).resolve().parent


def route(variant):
    path=HERE/variant/f'screen_power_{variant}.placed.kicad_pcb'
    board=p.LoadBoard(str(path));fps={f.GetReference():f for f in board.GetFootprints()};nets=board.GetNetsByName()
    def pad(ref,num):return max((a for a in fps[ref].Pads() if a.GetNumber()==str(num)), key=lambda a:a.GetSize().x*a.GetSize().y)
    def at(ref,num):return xy(pad(ref,num).GetPosition())
    def track(net,pts,width=.26,layer=p.B_Cu):
        for a,b in zip(pts,pts[1:]):
            if math.dist(a,b)<1e-6:continue
            t=p.PCB_TRACK(board);t.SetStart(point(*a));t.SetEnd(point(*b));t.SetWidth(p.FromMM(width));t.SetLayer(layer);t.SetNet(nets[net]);t.SetLocked(True);board.Add(t)
    def join(a,b,bends=(),width=.26,layer=p.B_Cu):
        assert pad(*a).GetNetname()==pad(*b).GetNetname(),(a,b)
        track(pad(*a).GetNetname(),[at(*a),*bends,at(*b)],width,layer)
    def pair(a,b,centre):
        # Mitered parallel offsets: 0.26mm copper + 0.16mm gap.
        normals=[]
        for x,y in zip(centre,centre[1:]):
            dx,dy=y[0]-x[0],y[1]-x[1];length=math.hypot(dx,dy)
            normals.append((dy/length,-dx/length))
        offsets=[normals[0]]
        for x,y in zip(normals,normals[1:]):
            scale=1+x[0]*y[0]+x[1]*y[1]
            offsets.append(((x[0]+y[0])/scale,(x[1]+y[1])/scale))
        offsets.append(normals[-1])
        for i,sign in enumerate((1,-1)):
            pts=[(c[0]+n[0]*.21*sign,c[1]+n[1]*.21*sign) for c,n in zip(centre,offsets)]
            ap,bp=at(*a[i]),at(*b[i]);first,last=normals[0],normals[-1]
            fanout=[(ap[0]-first[1]*.8,ap[1]+first[0]*.8),*pts,(bp[0]+last[1]*.8,bp[1]-last[0]*.8)]
            join(a[i],b[i],fanout)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=ch*100;host=f'J{n+1}';touch=f'J{n+2}';relay=f'K{n+1}'
        pair([(host,3),(host,2)],[(relay,6),(relay,3)],
             [(14.4,y-3.3),(14.4,y-4.3),(16.7,y-6.6),(21,y-6.6),(23.4,y-4.2),(23.4,y-2.2),(25.6,y),(30.8,y)])
        pair([(relay,5),(relay,4)],[(touch,3),(touch,2)],
             [(39,y),(44,y),(49,y+5),(54.2,y+5),(56.2,y+3),(56.2,y+1.8)])
    # Main current stays on the front; 4.5mm shared trunk and 2mm
    # branches. Short device-pin necks are 1.5mm, not signal tracks.
    if variant == 'hand':
        q3d,q3s,q4d,q4s=at('Q3',2),at('Q3',3),at('Q4',2),at('Q4',3)
        track('AUX_5V',[at('J1',1),(11.2425,3),(26,3),(32,7)],3,p.F_Cu)
        track('AUX_5V',[(32,7),q3d],1.5,p.F_Cu)
        track('COMMON_SOURCE',[q3s,(34.54,13)],1.5,p.F_Cu)
        track('COMMON_SOURCE',[q4s,(43.46,13)],1.5,p.F_Cu)
        track('COMMON_SOURCE',[(34.54,13),(43.46,13)],3,p.F_Cu)
        track('SWITCHED_5V',[q4d,(46,11)],1.5,p.B_Cu)
        track('SWITCHED_5V',[(46,11),(46,13),(42,17),(39.65,17)],3,p.B_Cu)
        track('SWITCHED_5V',[(44,17),(44,39)],4.5,p.F_Cu)
        # Control pads occupy the central aisle; a short back-side trunk
        # connects through the existing plated fuse terminals without vias.
        track('SWITCHED_5V',[(39.65,36),(41.65,38),(45,38),(50.5,43.5),(50.5,52),(46.5,56),(39.65,56)],3,p.B_Cu)
        track('SWITCHED_5V',[(44,39),(39.65,36)],3,p.F_Cu)
        track('SWITCHED_5V',[(39.65,56),(44,60.35),(44,75)],4.5,p.F_Cu)
    else:
        track('AUX_5V',[at('J1',1),(11.2425,3),(26,3),(29,6),at('Q3',2)],3,p.F_Cu)
        track('COMMON_SOURCE',[at('Q3',3),(23.225,16.3),(38.925,16.3),(40.225,15),at('Q4',3)],3,p.F_Cu)
        track('SWITCHED_5V',[at('Q4',2),(49.375,12),(44,17.375),(44,65)],4.5,p.F_Cu)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=100*ch
        for offset in (1,2):
            if variant=='hand' and ch==2 and offset==1: continue
            f=at(f'F{n+offset}',1)
            # The branch reaches the broad trunk on the same face.
            track('SWITCHED_5V',[f,(44,f[1])],3,p.F_Cu)
        a,b=at(f'F{n+1}',2),at(f'J{n+3}',1)
        join((f'F{n+1}',2),(f'J{n+3}',1),[(b[0]-1.55,a[1])],2,p.F_Cu)
        a,b=at(f'F{n+2}',2),at(f'J{n+2}',1)
        join((f'F{n+2}',2),(f'J{n+2}',1),[(57.3,a[1]),(57.8,a[1]-.5),(57.8,b[1]+2),(59.2,b[1]+.6)],.8,p.F_Cu)
        join((f'F{n+2}',2),(f'C{n+2}',1),[],.8,p.F_Cu)
    if variant=='factory':
        def via(net,at_xy):
            v=p.PCB_VIA(board);v.SetPosition(point(*at_xy));v.SetWidth(p.FromMM(.6));v.SetDrill(p.FromMM(.3));v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu);v.SetNet(nets[net]);board.Add(v)
        # Every SMD ground return gets a nearby plane connection.
        grounds={'C1':(19,15.9),'C101':(23.1,33),'C201':(23.1,62),
                 'Q1':(22.0625,42.1),'Q101':(26.0625,37.1),'Q201':(26.0625,66.1),
                 'R2':(19,37.8),'R7':(40,38.2),'R8':(50.4,71)}
        for ref,pos in grounds.items():
            track('GND',[at(ref,2),pos],.35,p.F_Cu);via('GND',pos)
        for ref,pos in [('Q3',(20.2,6.46)),('Q4',(38,3.5)),('R3',(26,20.2))]:
            pin=2 if ref=='R3' else 1
            track('POWER_GATE',[at(ref,pin),pos],.25,p.F_Cu);via('POWER_GATE',pos)
        track('POWER_GATE',[(20.2,6.46),(23.16,3.5),(38,3.5)],.25,p.B_Cu)
        track('POWER_GATE',[(20.2,6.46),(20.2,19),(21.4,20.2),(26,20.2)],.25,p.B_Cu)
    board.Save(str(path))

if __name__=='__main__':route(sys.argv[1])
