"""Explicit USB pairs, high-current paths and local relay/gate-drive loops."""
import math
from pathlib import Path
import sys
import pcbnew as p
from pcb import point, xy
from layout import USB_ROWS, POWER_BUS_X, USB_WIDTH, USB_GAP
HERE=Path(__file__).resolve().parent
# Shared-load neck at the TO-220 terminals.
NECK=1.9
# Charge-pump/negative-rail supply and gate-drive signal widths.
SUPPLY=.5
CTRL=.25


def route(variant):
    path=HERE/variant/f'screen_power_{variant}.placed.kicad_pcb'
    board=p.LoadBoard(str(path));fps={f.GetReference():f for f in board.GetFootprints()};nets=board.GetNetsByName()
    def pad(ref,num):return max((a for a in fps[ref].Pads() if a.GetNumber()==str(num)), key=lambda a:a.GetSize().x*a.GetSize().y)
    def at(ref,num):return xy(pad(ref,num).GetPosition())
    def track(net,pts,width=USB_WIDTH,layer=p.B_Cu):
        for a,b in zip(pts,pts[1:]):
            if math.dist(a,b)<1e-6:continue
            t=p.PCB_TRACK(board);t.SetStart(point(*a));t.SetEnd(point(*b));t.SetWidth(p.FromMM(width));t.SetLayer(layer);t.SetNet(nets[net]);t.SetLocked(True);board.Add(t)
    def join(a,b,bends=(),width=USB_WIDTH,layer=p.B_Cu):
        assert pad(*a).GetNetname()==pad(*b).GetNetname(),(a,b)
        track(pad(*a).GetNetname(),[at(*a),*bends,at(*b)],width,layer)
    def region(net,points,layer=p.F_Cu):
        # Locked overlay that fixes the visible outline of a power path. The
        # tracks underneath still carry the checked widths on their own, so
        # removing every zone cannot break a minimum-width path.
        zone=p.ZONE(board);zone.SetLayer(layer);zone.SetNet(nets[net])
        zone.SetZoneName('POWER_TAPER');zone.SetAssignedPriority(20)
        zone.SetLocalClearance(p.FromMM(.2));zone.SetMinThickness(p.FromMM(.05))
        zone.SetPadConnection(p.ZONE_CONNECTION_FULL)
        zone.SetIslandRemovalMode(p.ISLAND_REMOVAL_MODE_ALWAYS);zone.SetLocked(True)
        poly=zone.Outline();poly.NewOutline()
        for xy in points:
            v=point(*xy);poly.Append(v.x,v.y)
        board.Add(zone)
    def taper(net,a,b,start_width,end_width,layer=p.F_Cu):
        # Gradual copper transition over an already continuous track.
        dx,dy=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dy)
        nx,ny=-dy/length,dx/length
        region(net,[(xy[0]+sign*nx*width/2,xy[1]+sign*ny*width/2)
                    for xy,width,sign in ((a,start_width,1),(b,end_width,1),
                                          (b,end_width,-1),(a,start_width,-1))],layer)
    def pair(a,b,centre,breakout=False):
        # Mitered parallel offsets for the two-layer coupled microstrip.
        normals=[]
        for x,y in zip(centre,centre[1:]):
            dx,dy=y[0]-x[0],y[1]-x[1];length=math.hypot(dx,dy)
            normals.append((dy/length,-dx/length))
        offsets=[normals[0]]
        for x,y in zip(normals,normals[1:]):
            scale=1+x[0]*y[0]+x[1]*y[1]
            offsets.append(((x[0]+y[0])/scale,(x[1]+y[1])/scale))
        offsets.append(normals[-1])
        def fanout(pad_xy, coupled, direction):
            # One axial neck and one 45-degree segment, symmetric on each pair.
            dx,dy=direction
            if abs(dx)>.5:
                knee=(coupled[0]-dx*abs(coupled[1]-pad_xy[1]),pad_xy[1])
            else:
                knee=(pad_xy[0],coupled[1]-dy*abs(coupled[0]-pad_xy[0]))
            assert (knee[0]-pad_xy[0])*dx+(knee[1]-pad_xy[1])*dy>=0
            return knee
        def spread(pad_xy, coupled):
            # Break out across the run instead of along it: one 45-degree miter
            # then an axial drop onto a terminal that sits past the coupled
            # section, where an along-axis miter would cross its neighbour pad.
            reach=pad_xy[0]-coupled[0]
            assert abs(reach)<=abs(pad_xy[1]-coupled[1])
            return (pad_xy[0],coupled[1]+math.copysign(abs(reach),pad_xy[1]-coupled[1]))
        for i,sign in enumerate((1,-1)):
            pts=[(c[0]+n[0]*(USB_WIDTH+USB_GAP)/2*sign,c[1]+n[1]*(USB_WIDTH+USB_GAP)/2*sign) for c,n in zip(centre,offsets)]
            ap,bp=at(*a[i]),at(*b[i]);first,last=normals[0],normals[-1]
            tail=spread(bp,pts[-1]) if breakout else fanout(bp,pts[-1],(last[1],-last[0]))
            bends=[fanout(ap,pts[0],(-first[1],first[0])),*pts,tail]
            join(a[i],b[i],bends)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=ch*100;host=f'J{n+1}';touch=f'J{n+2}';relay=f'K{n+1}'
        # The host side lands on the changeover commons 6/3, one terminal
        # column further in than the unused breaks 7/2. The pair therefore
        # stays coupled past those idle pads and separates across the row.
        pair([(host,3),(host,2)],[(relay,6),(relay,3)],
             [(11,y),(27.6,y)],breakout=True)
        pair([(relay,5),(relay,4)],[(touch,3),(touch,2)],
             [(35,y),(52,y)])
        # Keep the relay-drive return between contact columns, never beneath
        # the USB fanouts. This narrow control channel is routed explicitly.
        # The commons now carry the host pair, so the channel sits between the
        # common column and the make column and is recentred on that gap.
        join((relay,8),(f'Q{n+1}',3),
             [(23.2,y-4.6),(23.9,y-5.3),(28.75,y-5.3),
              (29.75,y-4.3),(29.75,y+6.2)],.25,p.F_Cu)
    # Revision L gate driver. Every loop that carries pump or negative-rail
    # current is placed here instead of being autorouted, and all of it stays
    # north of the first USB row so no inverter loop runs under a data pair.
    # GND returns close through the filled pours: U1.3, C3/C4/C5 and D2 all
    # sit on them, so only the driven nodes need copper.
    def miter(a,b):
        """Knee for one axial leg followed by a 45 degree approach to b."""
        dx,dy=b[0]-a[0],b[1]-a[1]
        if abs(dy)>=abs(dx):
            return (a[0],b[1]-math.copysign(abs(dx),dy))
        return (b[0]-math.copysign(abs(dy),dx),a[1])
    def bend(a_ref,a_pin,b_ref,b_pin,width):
        join((a_ref,a_pin),(b_ref,b_pin),
             [miter(at(a_ref,a_pin),at(b_ref,b_pin))],width,p.F_Cu)
    # Pump capacitor: symmetric legs from pins 2 and 4 to the 2mm terminals.
    for pin,cap_pin in (('2','1'),('4','2')):
        bend('U1',pin,'C3',cap_pin,SUPPLY)
    # The reservoir and the clamp on pin 5's negative rail.
    for nodes in (('U1','5','C4','2'),('D2','2','C4','2')):
        bend(*nodes,SUPPLY)
    # AUX bypass at pin 8. This one leaves its pad diagonally so the branch
    # below can run straight down the same column without doubling copper.
    c5_1,u1_8=at('C5','1'),at('U1','8')
    join(('C5','1'),('U1','8'),
         [(u1_8[0],c5_1[1]+abs(u1_8[0]-c5_1[0]))],SUPPLY,p.F_Cu)
    # Carry the negative rail to the optocoupler emitter between the DIP rows,
    # clear of pin 4 on its south side: the gate-drive run to R3 owns the lane
    # north of the coupler, and crossing it would need a via on either net.
    u1_5,u2_3,u2_4=at('U1','5'),at('U2','3'),at('U2','4')
    lane=u2_4[1]+1.6
    join(('U1','5'),('U2','3'),
         [(u1_5[0]+lane-u1_5[1],lane),(u2_3[0]-.6,lane),
          (u2_3[0],lane-.6)],SUPPLY,p.F_Cu)
    # Gate drive: coupler collector to its series resistor above the FETs,
    # threaded between the reservoir can and the Q4 courtyard.
    r3_1=at('R3','1')
    join(('U2','4'),('R3','1'),
         [(u2_4[0],r3_1[1]+2),(u2_4[0]+2,r3_1[1])],CTRL,p.F_Cu)
    # LED network and the sink node shared with Q1.
    for nodes in (('U2','1','R10','1'),('U2','2','R10','2')):
        bend(*nodes,CTRL)
    join(('R10','1'),('R9','2'),[],CTRL,p.F_Cu)
    # Q1 also sinks the relay-enable buffer's base divider, which sits south of
    # the first USB row. The data pairs and their front-copper keepouts leave
    # the left edge as the only crossing, so this one takes the bottom layer
    # there: the front channel stays clear for the AUX branch that follows the
    # same route, and the ground reference under the pairs is untouched. West
    # of the plugs at x=2.8 the pair copper and the pour keepout are both far.
    q1_3,r5_1=at('Q1','3'),at('R5','1')
    join(('Q1','3'),('R5','1'),
         [(q1_3[0],28.3),(q1_3[0]-1,29.3),(3.8,29.3),(2.8,30.3),
          (2.8,42),(3.8,43),(r5_1[0]-1,43),(r5_1[0],44)],CTRL,p.B_Cu)
    # AUX_5V feeds that buffer's emitter and pull-up as well, so it takes the
    # front half of the same crossing: down the column between the input stage
    # and the DIP, along the clear lane under Q1 and into the channel west of
    # the plugs. Signal copper is ample for a low-current buffer supply.
    join(('C5','1'),('Q2','1'),
         [(c5_1[0],27.5),(c5_1[0]-1,28.5),(4.5,28.5),(3.5,29.5),
          (3.5,44.1)],CTRL,p.F_Cu)
    # The front carries the 4.5mm shared trunk; main outputs use 2mm
    # bottom branches. Keep the narrower approaches local to closely spaced
    # device pins, then widen smoothly into the 3mm common-source bridge.
    q3d,q3s,q4d,q4s=at('Q3',2),at('Q3',3),at('Q4',2),at('Q4',3)
    track('AUX_5V',[at('J1',1),(55,14),(52,11),(47,11)],3,p.F_Cu)
    track('AUX_5V',[(47,11),(45.5,11),(44,9.5),q3d],NECK,p.F_Cu)
    taper('AUX_5V',(45.5,11),(47,11),NECK,3)
    # The input bulk capacitor gets its own short wide branch above the can
    # instead of a routed signal-width tail; it is the only local reservoir.
    cap=at('C2',1)
    track('AUX_5V',[(47,11),(45.5,12.5),(44.4,12.5),
                    (cap[0],12.5+44.4-cap[0]),cap],1.5,p.F_Cu)
    # The film bypass also has a deliberate local feed around its GND pad.
    film=at('C1',1)
    film_x=film[0]-1.7
    track('AUX_5V',[(47,11),(film_x,11+47-film_x),
                    (film_x,film[1]-1.7),film],.8,p.F_Cu)
    track('COMMON_SOURCE',[q3s,(41.46,10.5)],NECK,p.F_Cu)
    track('COMMON_SOURCE',[q4s,(33.54,10.5)],NECK,p.F_Cu)
    track('COMMON_SOURCE',[(33.54,10.5),(35.04,12),(39.96,12),(41.46,10.5)],3,p.F_Cu)
    taper('COMMON_SOURCE',(41.46,9),(41.46,10.5),NECK,3)
    taper('COMMON_SOURCE',(33.54,9.5),(33.54,10.5),NECK,3)
    # Feed the edge bus through the plated fuse terminal, and stitch that
    # transition with dedicated vias for parallel copper paths independent
    # of the fuse terminal's plated barrel.
    track('SWITCHED_5V',[q4d,(31,12)],NECK,p.B_Cu)
    taper('SWITCHED_5V',(31,10.3),(31,12),NECK,3,p.B_Cu)
    f=at('F101',1)
    track('SWITCHED_5V',[(31,12),(36,17),(36,18.5),(37.5,20),(43,20),(47,24),(f[0]-1,24),f],3,p.B_Cu)
    track('SWITCHED_5V',[f,(f[0]-1,24),(46.6,24)],3,p.F_Cu)
    for stitch in ((46.4,24.5),(47.5,24.5),(48.6,24.5)):
        v=p.PCB_VIA(board);v.SetPosition(point(*stitch));v.SetWidth(p.FromMM(.9));v.SetDrill(p.FromMM(.45))
        v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu)
        v.SetNet(nets['SWITCHED_5V']);v.SetLocked(True);board.Add(v)
    # Right-edge distribution bus. The spine holds the full 4.5mm copper that
    # the width check measures with every zone deleted; one locked overlay then
    # states the outline, because a bare track network draws this bus as a
    # capsule with round end caps and a trapezoid flare at every tap. The
    # contour is deliberate and repeats: straight sides one bus width apart,
    # the first tap's north edge and the last tap's south edge continuing as
    # the flat ends, a 45 degree chamfer on each of the two free corners, and a
    # 45 degree gusset where every tap widens into the trunk. Both ends stop a
    # clear millimetre short of the M3 washer keepouts, so the ground pour
    # beside the bus keeps an even width instead of pinching around a cap.
    BUS,TAP,GUSSET,CHAMFER=4.5,3,1,1.25
    taps=(29,43,54,65.25)
    west,east=POWER_BUS_X-BUS/2,POWER_BUS_X+BUS/2
    top,bottom=taps[0]-TAP/2,taps[-1]+TAP/2
    track('SWITCHED_5V',[(POWER_BUS_X,top+BUS/2+.25),
                         (POWER_BUS_X,bottom-BUS/2-.25)],BUS,p.F_Cu)
    outline=[(west-GUSSET,top),(east-CHAMFER,top),(east,top+CHAMFER),
             (east,bottom-CHAMFER),(east-CHAMFER,bottom),(west-GUSSET,bottom)]
    for y in reversed(taps):
        if y!=taps[-1]:
            outline+=[(west,y+TAP/2+GUSSET),(west-GUSSET,y+TAP/2)]
        if y!=taps[0]:
            outline+=[(west-GUSSET,y-TAP/2),(west,y-TAP/2-GUSSET)]
    region('SWITCHED_5V',outline)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=100*ch
        for offset in (1,2):
            f=at(f'F{n+offset}',1)
            # The branch reaches the broad trunk on the same face.
            bends=[(f[0],f[1]+2),(f[0]+4,f[1]+6),(POWER_BUS_X,f[1]+6)] if offset==1 else [(POWER_BUS_X,f[1])]
            if ch==2 and offset==2:
                # This feed climbs to the bus. It turns as late as the bus
                # allows, landing its 45 degree rise exactly on the trunk's
                # lower west corner: the bus keeps one contour along its whole
                # length, and the diagonal stays a full millimetre off the
                # corner of J202's nearest terminal, which a turn further west
                # would crowd. The rise equals the climb, so the corner is 45.
                # The turn also stops .75mm short of the gusset, which is more
                # than the .62mm a 45 degree corner's outer flank reaches past
                # its own vertex, so the flank cannot notch the bus edge.
                turn=west-GUSSET-.75
                bends=[(turn-(f[1]-taps[-1]),f[1]),(turn,taps[-1]),
                       (POWER_BUS_X,taps[-1])]
            track('SWITCHED_5V',[f,*bends],3,p.F_Cu)
        a,b=at(f'F{n+1}',2),at(f'J{n+3}',1)
        join((f'F{n+1}',2),(f'J{n+3}',1),
             [(a[0],a[1]+2),(a[0]+2,a[1]+4),(b[0]-2,a[1]+4)],2,p.B_Cu)
        a,b=at(f'F{n+2}',2),at(f'J{n+2}',1)
        join((f'F{n+2}',2),(f'J{n+2}',1),
             [(a[0]+3.25,b[1])],.8,p.F_Cu)
        c=at(f'C{n+2}',1)
        join((f'J{n+2}',1),(f'C{n+2}',1),
             [(57.5,b[1]),(58.5,b[1]-1),(58.5,y-6),(57.5,y-7),(c[0]+3,y-7)],.8,p.B_Cu)
    # Reserve front copper below each pair, and keep same-side ground far
    # enough away to use the coupled-microstrip calculation as a starting point.
    def keepout(layer,x1,y1,x2,y2,tracks=False,pours=False):
        z=p.ZONE(board);z.SetLayer(layer);z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(tracks);z.SetDoNotAllowVias(tracks)
        z.SetDoNotAllowZoneFills(pours);z.SetDoNotAllowPads(False);z.SetDoNotAllowFootprints(False)
        poly=z.Outline();poly.NewOutline()
        for at in [(x1,y1),(x2,y1),(x2,y2),(x1,y2)]:
            v=point(*at);poly.Append(v.x,v.y)
        board.Add(z)
    for y in USB_ROWS[variant]:
        for left,right in [(9,22),(35,54)]:
            keepout(p.F_Cu,left,y-2.8,right,y+2.8,tracks=True)
        keepout(p.F_Cu,22,y-1.4,25,y+1.4,tracks=True)
        keepout(p.B_Cu,8.5,y-5,54.5,y+5,pours=True)
    # Protect the fanouts as well: a control trace under either data line
    # breaks its return path even when it misses the straight pair corridor.
    for t in list(board.GetTracks()):
        if t.GetNetname() not in {f'S{ch}_{side}_{pol}' for ch in (1,2)
                                 for side in ('UP','DN') for pol in ('P','N')}:continue
        a,b=xy(t.GetStart()),xy(t.GetEnd());length=math.dist(a,b)
        ux,uy=(b[0]-a[0])/length,(b[1]-a[1])/length
        z=p.ZONE(board);z.SetLayer(p.F_Cu);z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(True);z.SetDoNotAllowVias(True)
        z.SetDoNotAllowZoneFills(False);z.SetDoNotAllowPads(False);z.SetDoNotAllowFootprints(False)
        poly=z.Outline();poly.NewOutline()
        # Rounded ends avoid a diagonal rectangle's oversized corners in the
        # relay's 2.2mm contact pitch. The 0.8mm radius exceeds the 0.425mm
        # track half-width; the filled-plane check still samples every edge.
        angle=math.atan2(uy,ux)
        for endpoint,start in ((a,angle+math.pi/2),(b,angle-math.pi/2)):
            for step in range(17):
                theta=start+math.pi*step/16
                v=point(endpoint[0]+.8*math.cos(theta),
                        endpoint[1]+.8*math.sin(theta));poly.Append(v.x,v.y)
        board.Add(z)
    # Ground stitching beside the data corridors and around the power ports.
    for y in USB_ROWS[variant]:
        for x in (10,20,37,49):
            for dy in (-5.8,5.8):
                # Keep stitching clear of the shifted fuse pads and branches.
                vx=51 if x==49 and dy<0 else 46 if x==49 else 34 if x==37 and dy>0 else x
                v=p.PCB_VIA(board);v.SetPosition(point(vx,y+dy));v.SetWidth(p.FromMM(.7));v.SetDrill(p.FromMM(.3));v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu);v.SetNet(nets['GND']);v.SetLocked(True);board.Add(v)
    # Join the small bottom ground pocket at the control pulldown to F.Cu.
    g=at('R7',2);stitch=(g[0],g[1]-1.8)
    track('GND',[g,stitch],.5,p.B_Cu)
    v=p.PCB_VIA(board);v.SetPosition(point(*stitch));v.SetWidth(p.FromMM(.7));v.SetDrill(p.FromMM(.3));v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu);v.SetNet(nets['GND']);v.SetLocked(True);board.Add(v)
    board.Save(str(path))

if __name__=='__main__':route(sys.argv[1])
