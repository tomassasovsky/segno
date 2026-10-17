"""Explicit USB pairs, high-current paths and local relay/coil/gate loops."""
import math
from pathlib import Path
import sys
import pcbnew as p
from pcb import point, xy
from layout import USB_ROWS, POWER_BUS_X, USB_WIDTH, USB_GAP
HERE=Path(__file__).resolve().parent
# Revision N power widths. Each run holds one width from pad to pad; they
# differ from one another only where the terminal pitch or a fixed corridor
# forces it. RAW carries the whole board before F1; AUXFEED carries the screen
# allocation from the fuse to the relay's normally open contact; TRUNK carries
# the same current back out of that contact to the branch fuses. COIL is the
# light branch that leaves the protected side of F1 for the coils and control,
# so the long switched-load runs never spend the coil's voltage allowance.
RAW=4.
AUXFEED=5.
TRUNK=3.5
COIL=1.
# Gate, sense and coil-return control widths.
CTRL=.25
# Centreline radius for a bend in a power band: every one of them leaves a 1mm
# radius on the inner edge, so all the wide corners on the board read the same.
def sweep(width):return width/2+1
ARC3,ARC2=sweep(3),sweep(2)



def add_aux_junction_fillets(board):
    """Round three concave branch edges without narrowing the track backbone.

    Derive the junctions from the union of the actual wide AUX routes. This
    avoids a decorative polygon whose edge silently drifts off the route after
    placement changes. The small buried overlap keeps each fill connected even
    when KiCad applies its minimum polygon thickness during zone refill.
    """
    merged=p.SHAPE_POLY_SET()
    for t in board.GetTracks():
        if (isinstance(t,p.PCB_VIA) or t.GetNetname()!='AUX_5V'
                or t.GetLayer()!=p.F_Cu or t.GetWidth()<p.FromMM(COIL)):
            continue
        shape=p.SHAPE_POLY_SET()
        t.TransformShapeToPolygon(shape,p.F_Cu,0,1000,p.ERROR_INSIDE)
        merged.BooleanAdd(shape)
    merged.Simplify()
    candidates=[]
    for n in range(merged.OutlineCount()):
        edge=merged.COutline(n)
        pts=[xy(edge.CPoint(i)) for i in range(edge.PointCount())]
        for i,corner in enumerate(pts):
            before,after=pts[i-1],pts[(i+1)%len(pts)]
            a=(corner[0]-before[0],corner[1]-before[1])
            b=(after[0]-corner[0],after[1]-corner[1])
            if a[0]*b[1]-a[1]*b[0]<0:
                candidates.append((corner,before,after))
    for target in ((34.951,16.),(35.606,17.),(25.032,8.486)):
        corner,before,after=min(candidates,key=lambda c:math.dist(c[0],target))
        assert math.dist(corner,target)<.05, ('AUX junction moved',target,corner)
        u=[]
        for end in (before,after):
            length=math.dist(end,corner)
            u.append(((end[0]-corner[0])/length,(end[1]-corner[1])/length))
        angle=math.acos(max(-1,min(1,u[0][0]*u[1][0]+u[0][1]*u[1][1])))
        radius=.5
        tangent=radius/math.tan(angle/2)
        assert tangent<min(math.dist(before,corner),math.dist(after,corner))
        centre_distance=radius/math.sin(angle/2)
        bisector=(u[0][0]+u[1][0],u[0][1]+u[1][1])
        length=math.hypot(*bisector)
        centre=(corner[0]+bisector[0]*centre_distance/length,
                corner[1]+bisector[1]*centre_distance/length)
        ends=[(corner[0]+v[0]*tangent,corner[1]+v[1]*tangent) for v in u]
        a0=math.atan2(ends[0][1]-centre[1],ends[0][0]-centre[0])
        a1=math.atan2(ends[1][1]-centre[1],ends[1][0]-centre[0])
        turn=(a1-a0+math.pi)%math.tau-math.pi
        arc=[(centre[0]+radius*math.cos(a0+turn*i/24),
              centre[1]+radius*math.sin(a0+turn*i/24)) for i in range(25)]
        # The union is CCW. Its left normals point into existing copper.
        n1=(u[0][1],-u[0][0]);n2=(-u[1][1],u[1][0])
        polygon=[*arc,
                 (ends[1][0]+.1*n2[0],ends[1][1]+.1*n2[1]),
                 (corner[0]+.1*(n1[0]+n2[0]),corner[1]+.1*(n1[1]+n2[1])),
                 (ends[0][0]+.1*n1[0],ends[0][1]+.1*n1[1])]
        z=p.ZONE(board);z.SetLayer(p.F_Cu);z.SetNet(board.GetNetsByName()['AUX_5V'])
        z.SetZoneName('POWER_FILLET');z.SetAssignedPriority(20)
        z.SetLocalClearance(p.FromMM(.2));z.SetMinThickness(p.FromMM(.05))
        z.SetPadConnection(p.ZONE_CONNECTION_FULL)
        z.SetIslandRemovalMode(p.ISLAND_REMOVAL_MODE_ALWAYS);z.SetLocked(True)
        outline=z.Outline();outline.NewOutline()
        for position in polygon:
            v=point(*position);outline.Append(v.x,v.y)
        board.Add(z)


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
    def quarter(centre,frm,to,steps=12):
        """Fine polyline along the circular arc frm -> to about centre.

        Zone outlines are polygons, so a fillet is drawn as a chord sequence.
        Twelve chords per quarter turn keep the deviation from the true circle
        under 3um, far below any fabrication resolution, and the arc stays
        tangent to both edges it joins.
        """
        radius=math.dist(centre,frm)
        a0=math.atan2(frm[1]-centre[1],frm[0]-centre[0])
        a1=math.atan2(to[1]-centre[1],to[0]-centre[0])
        if a1-a0>math.pi:a1-=math.tau
        if a0-a1>math.pi:a1+=math.tau
        return [(centre[0]+radius*math.cos(a0+(a1-a0)*i/steps),
                 centre[1]+radius*math.sin(a0+(a1-a0)*i/steps))
                for i in range(steps+1)]
    def curve(points,radius,steps=8):
        """Centreline with a tangent circular arc at every interior corner.

        A wide band drawn as mitred straight segments shows a point on the
        outside of each bend and a notch on the inside; running the centreline
        through an arc instead keeps it one width wide the whole way round and
        leaves a positive radius on both edges. The arc is emitted as chords,
        not as a PCB_ARC: the DSN export that feeds the router flattens an arc
        to its chord and would lose the bow. Eight chords per corner hold the
        deviation from the true circle under 13um: 12.04um at a 2.5mm
        radius over a 90-degree bend.

        The first and last leg may spend their whole length on a tangent
        because nothing else claims it; an interior leg keeps half for its
        other end, which is also how KiCad clamps a zone fillet.

        Repeated points come in from the miter helper whenever a knee lands on
        the pad it is aiming at - two aligned terminals give [a,b,b] - so they
        go before anything is normalised.
        """
        points=[q for i,q in enumerate(points)
                if i==0 or math.dist(q,points[i-1])>1e-9]
        if len(points)<3:return points
        out=[points[0]];last=len(points)-3
        for i,corner in enumerate(points[1:-1]):
            before,after=points[i],points[i+2]
            v1=(before[0]-corner[0],before[1]-corner[1])
            v2=(after[0]-corner[0],after[1]-corner[1])
            l1,l2=math.hypot(*v1),math.hypot(*v2)
            u1,u2=(v1[0]/l1,v1[1]/l1),(v2[0]/l2,v2[1]/l2)
            angle=math.acos(max(-1,min(1,u1[0]*u2[0]+u1[1]*u2[1])))
            if angle>math.pi-1e-9:
                out.append(corner);continue
            tangent=min(radius/math.tan(angle/2),
                        l1 if i==0 else l1/2,l2 if i==last else l2/2)
            r=tangent*math.tan(angle/2)
            t1=(corner[0]+u1[0]*tangent,corner[1]+u1[1]*tangent)
            t2=(corner[0]+u2[0]*tangent,corner[1]+u2[1]*tangent)
            bisector=(u1[0]+u2[0],u1[1]+u2[1]);bl=math.hypot(*bisector)
            centre=(corner[0]+bisector[0]/bl*(r/math.sin(angle/2)),
                    corner[1]+bisector[1]/bl*(r/math.sin(angle/2)))
            out+=quarter(centre,t1,t2,steps)
        out.append(points[-1])
        return [q for i,q in enumerate(out) if i==0 or math.dist(q,out[i-1])>1e-9]
    def flow(a,b,bends,width,layer,radius):
        """join(), with circular corners instead of mitred ones."""
        assert pad(*a).GetNetname()==pad(*b).GetNetname(),(a,b)
        track(pad(*a).GetNetname(),curve([at(*a),*bends,at(*b)],radius),
              width,layer)
    def region(net,points,layer=p.F_Cu,fillet=0,name='POWER_TAPER'):
        # Locked overlay that fixes the visible outline of a power path. The
        # tracks underneath still carry the checked widths on their own, so
        # removing every zone cannot break a minimum-width path.
        zone=p.ZONE(board);zone.SetLayer(layer);zone.SetNet(nets[net])
        zone.SetZoneName(name);zone.SetAssignedPriority(20)
        zone.SetLocalClearance(p.FromMM(.2));zone.SetMinThickness(p.FromMM(.05))
        zone.SetPadConnection(p.ZONE_CONNECTION_FULL)
        zone.SetIslandRemovalMode(p.ISLAND_REMOVAL_MODE_ALWAYS);zone.SetLocked(True)
        if fillet:
            # Native corner smoothing rounds convex corners when KiCad fills.
            # Concave joins require explicit arcs in the source outline. KiCad
            # shrinks the convex radius where an edge is too short to carry it.
            zone.SetCornerSmoothingType(2);zone.SetCornerRadius(p.FromMM(fillet))
        poly=zone.Outline();poly.NewOutline()
        for xy in points:
            v=point(*xy);poly.Append(v.x,v.y)
        board.Add(zone)
    def via(net,at_xy,diameter=.9,drill=.45):
        v=p.PCB_VIA(board);v.SetPosition(point(*at_xy))
        v.SetWidth(p.FromMM(diameter));v.SetDrill(p.FromMM(drill))
        v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu)
        v.SetNet(nets[net]);v.SetLocked(True);board.Add(v)
        return at_xy
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
            flow(a[i],b[i],bends,USB_WIDTH,p.B_Cu,1.0)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=ch*100;host=f'J{n+1}';touch=f'J{n+2}';relay=f'K{n+1}'
        # The host side lands on the changeover commons 6/3, one terminal
        # column further in than the unused breaks 7/2. The pair therefore
        # stays coupled past those idle pads and separates across the row.
        pair([(host,3),(host,2)],[(relay,6),(relay,3)],
             [(10.6,y),(28.15,y)],breakout=True)
        pair([(relay,5),(relay,4)],[(touch,3),(touch,2)],
             [(34.6,y),(52.4,y)])
        # Keep the relay-drive return between contact columns, never beneath
        # the USB fanouts. This narrow control channel is routed explicitly.
        # The commons carry the host pair, so the channel sits between the
        # common column and the make column and is recentred on that gap.
        # The coil's low side lands on the UPPER series FET's drain: the two
        # FETs are in series, and only the drain that faces the relay belongs
        # on this net. The crossing is the one this run always made - north of
        # the row, then down the lane between the relay's contact columns -
        # and it stays the only net on the board that passes a data pair.
        flow((relay,8),(f'Q{n+2}',3),
             [(23.2,y-4.6),(23.9,y-5.3),(28.75,y-5.3),
              (29.75,y-4.3),(29.75,y+4.6)],CTRL,p.F_Cu,sweep(CTRL))
    def miter(a,b):
        """Knee for one axial leg followed by a 45 degree approach to b."""
        dx,dy=b[0]-a[0],b[1]-a[1]
        if abs(dy)>=abs(dx):
            return (a[0],b[1]-math.copysign(abs(dx),dy))
        return (b[0]-math.copysign(abs(dy),dx),a[1])
    def bend(a_ref,a_pin,b_ref,b_pin,width,layer=p.F_Cu):
        flow((a_ref,a_pin),(b_ref,b_pin),
             [miter(at(a_ref,a_pin),at(b_ref,b_pin))],width,layer,sweep(width))
    # Revision N coil stage. The clamp stands between the two coil terminals,
    # so the suppression loop is two short links and the coil itself; the
    # driver's drain joins that loop at the clamp's own terminal rather than
    # reaching past it. Gate and gate-return close locally on R7.
    bend('D3','2','K1','8',COIL)
    bend('D3','1','K1','1',COIL)
    # Revision O lays Q5's terminal row across the bay. Take the uniform 1mm
    # drain route north of that row before turning toward the clamp, so its
    # rounded corner clears the adjacent source pad.
    drain=at('Q5','2');lane=at('Q5','3')[1]-4.65
    flow(('Q5','2'),('D3','1'),
         [(drain[0],lane),miter((drain[0],lane),at('D3','1'))],
         COIL,p.F_Cu,sweep(COIL))
    bend('R7','1','Q5','1',CTRL)
    # Raw input. Only this run and J1's own terminal are ahead of the fuse;
    # it swings south of J1's ground terminal rather than squeezing past it.
    track('AUX_5V_IN',curve([at('J1',1),(54,14),(49.25,9.),at('F1',1)],
                            sweep(RAW)),RAW,p.F_Cu)
    # Protected side of F1. The coil and control branch leaves at the fuse
    # terminal itself, through the bypass capacitor, so the screen allocation
    # never shares copper with the coil feed beyond this pad.
    track('AUX_5V',curve([at('F1',2),(30.,13.),(35.89,22.),at('K1',4)],
                         sweep(AUXFEED)),AUXFEED,p.F_Cu)
    track('AUX_5V',curve([at('F1',2),(25.2,7.6),at('C1',1)],sweep(COIL)),
          COIL,p.F_Cu)
    track('AUX_5V',curve([at('C1',1),(21.,12.4),at('K1',8)],sweep(COIL)),
          COIL,p.F_Cu)
    # Reservoir tap off the contact feed, square onto its own terminal.
    c2=at('C2',1)
    track('AUX_5V',[(32.6,c2[1]),c2],COIL,p.F_Cu)
    # Switched output. The contact's middle terminal is the switched one, so
    # this run has to leave between the coil column and the terminal that
    # faces the input. It climbs north of both, crosses the bay on the back
    # layer - the front there carries the contact feed - and lands on the
    # first main fuse, which is also where the front distribution bus starts.
    f=at('F101',1)
    track('SWITCHED_5V',curve([at('K1',3),(28.27,19.6),(45.5,19.6),f],
                              sweep(TRUNK)),TRUNK,p.B_Cu)
    # Both faces carry copper past the terminal so the transition vias sit
    # wholly inside each of them instead of just outside an edge.
    track('SWITCHED_5V',[f,(f[0],f[1]-3.5)],3.,p.F_Cu)
    # Each barrel sits wholly inside the copper on both faces, and the three
    # of them give the transition parallel paths that do not depend on the
    # fuse terminal's own plated barrel.
    for stitch in ((f[0],f[1]-1.2),(f[0],f[1]-2.),(f[0],f[1]-2.8)):
        via('SWITCHED_5V',stitch)
    # Right-edge distribution bus. The spine holds the full 4.5mm copper that
    # the width check measures with every zone deleted; one locked overlay then
    # states the outline, because a bare track network draws this bus as a
    # capsule with round end caps and a trapezoid flare at every tap. The
    # contour is deliberate and repeats: straight sides one bus width apart,
    # the first tap's north edge and the last tap's south edge continuing as
    # the flat ends, and a step out to the tap width wherever a tap meets the
    # trunk. Every corner of that outline is then rounded with a true arc, so
    # the free ends are radiused and each tap blends into the bus instead of
    # meeting it in a notch. Both ends stop a clear millimetre short of the M3
    # washer keepouts, so the ground pour beside the bus keeps an even width
    # rather than pinching around a cap.
    BUS,TAP,GUSSET,FILLET=4.5,3,1,1
    # The added shield contacts occupy the old horizontal branch lanes.
    # Centre each 3mm feed in the remaining gap between the adjacent pads.
    taps=(26.925,42.26,52.24,65.25)
    west,east=POWER_BUS_X-BUS/2,POWER_BUS_X+BUS/2
    top,bottom=taps[0]-TAP/2,taps[-1]+TAP/2
    track('SWITCHED_5V',[(POWER_BUS_X,top+BUS/2+.25),
                         (POWER_BUS_X,bottom-BUS/2-.25)],BUS,p.F_Cu)
    # Native smoothing only rounds convex corners, and this outline's convex
    # corners all sit inside the branch tracks, so the joins the eye sees have
    # to carry their arc explicitly: each tap edge leaves the bus on a quarter
    # circle tangent to both, which continues the branch's straight edge with
    # no kink. The free ends stay square here and take the native 1mm radius.
    outline=[(west-GUSSET,top),(east,top),(east,bottom),(west-GUSSET,bottom)]
    for y in reversed(taps):
        if y!=taps[-1]:
            outline+=quarter((west-GUSSET,y+TAP/2+GUSSET),
                             (west,y+TAP/2+GUSSET),(west-GUSSET,y+TAP/2))
        if y!=taps[0]:
            outline+=quarter((west-GUSSET,y-TAP/2-GUSSET),
                             (west-GUSSET,y-TAP/2),(west,y-TAP/2-GUSSET))
    region('SWITCHED_5V',outline,fillet=FILLET)
    for ch,y in enumerate(USB_ROWS[variant],1):
        n=100*ch
        for offset in (1,2):
            f=at(f'F{n+offset}',1)
            # The branch reaches the broad trunk on the same face.
            tap=taps[(ch-1)*2+offset-1]
            bends=([(f[0]+tap-f[1],tap),(POWER_BUS_X,tap)]
                   if offset==1 else
                   [(f[0]+6,tap),(POWER_BUS_X,tap)])
            if ch==2 and offset==2:
                # This feed climbs to the bus. It turns as late as the bus
                # allows, so the whole rise stays at 45 degrees, the bus keeps
                # one contour along its length, and the diagonal clears the
                # corner of J202's nearest terminal, which a turn further west
                # would crowd.
                # The turn also stops .75mm short of the gusset, which is more
                # than the .62mm a 45 degree corner's outer flank reaches past
                # its own vertex, so the flank cannot notch the bus edge.
                turn=west-GUSSET-.75
                bends=[(turn-(f[1]-taps[-1]),f[1]),(turn,taps[-1]),
                       (POWER_BUS_X,taps[-1])]
            track('SWITCHED_5V',curve([f,*bends],ARC3),3,p.F_Cu)
        a,b=at(f'F{n+1}',2),at(f'J{n+3}',1)
        # The main output passes south of its own fuse's switched terminal and
        # then runs under the output plug's bay. This 2.5mm run and the 0.8mm
        # touch return below occupy separate lanes north of the shield pad.
        flow((f'F{n+1}',2),(f'J{n+3}',1),
             [(a[0],a[1]+1.8),(a[0]+2,a[1]+3.175),(b[0]-2,a[1]+3.175)],
             2.5,p.B_Cu,ARC2)
        a,b=at(f'F{n+2}',2),at(f'J{n+2}',1)
        flow((f'F{n+2}',2),(f'J{n+2}',1),
             [(a[0]+3.25,b[1])],.8,p.F_Cu,sweep(.8))
        c=at(f'C{n+2}',1)
        flow((f'J{n+2}',1),(f'C{n+2}',1),
             [(57.5,b[1]),(58.5,b[1]-1),(58.5,y-7),(57.5,y-8),(c[0]+3,y-8)],
             .8,p.B_Cu,sweep(.8))
    # The three control nets that pass a data row - the enable, the buffer's
    # sink and the AUX feed to that buffer - are left to the constrained
    # router. Every corridor beneath a pair is already reserved below, so it
    # cannot take the reference copper with it, and these are sub-milliamp
    # nets with no width or symmetry contract of their own.
    # Reserve front copper below each pair, and keep same-side ground far
    # enough away to use the coupled-microstrip calculation as a starting point.
    add_aux_junction_fillets(board)
    def keepout(layer,x1,y1,x2,y2,tracks=False,pours=False,radius=0):
        z=p.ZONE(board);z.SetLayer(layer);z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(tracks);z.SetDoNotAllowVias(tracks)
        z.SetDoNotAllowZoneFills(pours);z.SetDoNotAllowPads(False);z.SetDoNotAllowFootprints(False)
        poly=z.Outline();poly.NewOutline()
        if radius:
            # A rule area carries no fill, so it cannot use the zone smoothing
            # the filled overlays use; draw the rounded outline directly.
            radius=min(radius,(x2-x1)/2,(y2-y1)/2)
            corners=[((x2-radius,y1+radius),(x2-radius,y1),(x2,y1+radius)),
                     ((x2-radius,y2-radius),(x2,y2-radius),(x2-radius,y2)),
                     ((x1+radius,y2-radius),(x1+radius,y2),(x1,y2-radius)),
                     ((x1+radius,y1+radius),(x1,y1+radius),(x1+radius,y1))]
            shape=[xy for corner in corners for xy in quarter(*corner)]
        else:
            shape=[(x1,y1),(x2,y1),(x2,y2),(x1,y2)]
        for xy in shape:
            v=point(*xy);poly.Append(v.x,v.y)
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
        for x in (10,37,49):
            for dy in (-5.8,5.8):
                # Keep stitching clear of the shifted fuse pads and branches.
                vx=40 if x==49 else 34 if x==37 and dy>0 else x
                via('GND',(vx,y+dy),.7,.3)
    board.Save(str(path))

if __name__=='__main__':route(sys.argv[1])
