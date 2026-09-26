"""Explicit USB pairs, high-current paths and local relay/gate-drive loops."""
import math
from pathlib import Path
import sys
import pcbnew as p
from pcb import point, xy
from layout import USB_ROWS, POWER_BUS_X, USB_WIDTH, USB_GAP
HERE=Path(__file__).resolve().parent
# Uniform width of the source bridge and drain feed that carry the whole
# switched load, and of the input path feeding them. Each run holds its own
# width from pad to pad; they differ from one another only where the terminal
# pitch forces it.
TRUNK=2.5
AUX=2.
# The bulk and bypass branches off the input, and where they leave it.
CAP,FILM=1.5,.8
CAP_TAP,FILM_TAP=46.5,50.
# Charge-pump/negative-rail supply and gate-drive signal widths.
SUPPLY=.5
CTRL=.25
# Centreline radius for a bend in a power band: every one of them leaves a 1mm
# radius on the inner edge, so all the wide corners on the board read the same.
def sweep(width):return width/2+1
ARC3,ARC2=sweep(3),sweep(2)


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
        """
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
    def blend(x,width,edge,turn=None,radius=.8,reach=.5,overlap=.2):
        """Round both inside corners where a branch leaves a run at 90 degrees.

        A union of tracks is bounded by convex arcs and straight lines only, so
        the concave corner where a branch meets the run it taps has to be
        stated as copper of its own. Each side carries a quarter circle tangent
        to the branch edge and to the run's own edge: the straight edge the run
        holds there, or, where the run is already turning, the outer arc of
        that turn, passed as (centre x, centre y, radius). The rest of each
        outline sits inside the run and the branch, where it adds no copper the
        eye can see, so the boundary runs from one edge into the other with no
        step and no sliver left between them.

        Both closures overlap the copper they run into, and the branch side has
        to: the wedge between an arc and its own tangent is thinner than the
        fill's 0.05mm minimum for the last 0.28mm, so a tail that closed on the
        branch edge exactly was opened away and left a notch short of tangency.
        Closing `overlap` inside the branch instead keeps the outline at least
        that thick all the way to the tangent point, where the branch track
        carries the copper on.
        """
        for side in (-1,1):
            e=x+side*width/2;centre=e+side*radius;inward=e-side*overlap
            if turn and side<0:
                cx,cy,outer=turn
                cy_f=cy+math.sqrt((outer+radius)**2-(centre-cx)**2)
                scale=outer/(outer+radius)
                far=(cx+(centre-cx)*scale,cy+(cy_f-cy)*scale)
                shape=[(e,cy_f),*quarter((centre,cy_f),(e,cy_f),far),
                       (far[0]+(cx-far[0])*reach/outer,
                        far[1]+(cy-far[1])*reach/outer),
                       (inward,cy_f-radius-reach),(inward,cy_f)]
            else:
                shape=[(e,edge+radius),
                       *quarter((centre,edge+radius),(e,edge+radius),
                                (centre,edge)),
                       (centre,edge-reach),(inward,edge-reach),
                       (inward,edge+radius)]
            region('AUX_5V',shape,p.F_Cu,name='POWER_FILLET')
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
    # bottom branches.
    q3d,q3s,q4d,q4s=at('Q3',2),at('Q3',3),at('Q4',2),at('Q4',3)
    # Input path, J1 to the high-side drain: one width from pad to pad, turning
    # on arcs, with no neck and no taper. AUX is narrower than TRUNK because
    # this run ends on the terminal next to Q3's source, and the source bridge
    # is already 2.5mm there: two 2.5mm runs on a 2.54mm pitch leave 0.040mm
    # between their end caps, which no departure angle can recover. At 2.0mm
    # the same gap is 0.290mm, and the input carries the 4.25A planning load
    # with an 11.8C rise nominal, 17.0C at a 20% negative width tolerance.
    track('AUX_5V',curve([at('J1',1),(55,14),(52,11),(45.5,11),(44,9.5),q3d],
                         sweep(AUX)),AUX,p.F_Cu)
    # The bulk capacitor keeps its own 1.5mm branch and the film bypass its
    # 0.8mm one: the reservoir and the high-frequency bypass stay separate
    # feeds, both tapped off the input at right angles so each join is a pair
    # of blended corners instead of an acute wedge. Each tap then turns on the
    # same 1mm inner radius as the trunk and lands square on its pad, the bulk
    # can from the north, the film from the north-east around its ground pad.
    cap=at('C2',1)
    track('AUX_5V',curve([(CAP_TAP,11),(CAP_TAP,14.5),(cap[0],14.5),cap],
                         sweep(CAP)),CAP,p.F_Cu)
    film=at('C1',1)
    track('AUX_5V',curve([(FILM_TAP,11),(FILM_TAP,17.5),film],sweep(FILM)),
          FILM,p.F_Cu)
    # Both joins are concave, and a union of tracks is bounded by convex arcs
    # and straight lines only, so each blend is stated as copper of its own.
    # The bulk tap's west corner lands where the input has already started its
    # own turn toward Q3, so that blend is tangent to the outer arc of the turn
    # instead of to a straight edge.
    lead=sweep(AUX)*math.tan(math.radians(22.5))
    blend(CAP_TAP,CAP,11+AUX/2,
          turn=(45.5+lead,11-sweep(AUX),sweep(AUX)+AUX/2))
    # The film tap's blend is trimmed a little so it, too, stays on the
    # straight part of that edge rather than reaching into the next turn.
    blend(FILM_TAP,FILM,11+AUX/2,radius=.7)
    # Common-source bridge: one width from pad to pad, turning on arcs. The
    # old neck-taper-band-taper-neck changed width three times over 8mm for
    # no electrical reason, which is what read as lumps. TRUNK is the widest
    # standard track the TO-220's 2.54mm terminal pitch takes - 0.3375mm to
    # the neighbouring pads against a 0.2mm rule, where 3mm cannot clear at
    # all. The uniform-power-width review records the current, voltage-drop
    # and thermal estimates for the 4.25A screen planning load.
    deck=13.2
    track('COMMON_SOURCE',curve([q4s,(33.54,deck),(41.46,deck),q3s],ARC3),
          TRUNK,p.F_Cu)
    # Feed the edge bus through the plated fuse terminal, and stitch that
    # transition with dedicated vias for parallel copper paths independent of
    # the fuse terminal's plated barrel. This is the board's other shared-load
    # run, so it is the same uniform TRUNK width from the drain pad to the
    # fuse, again with no neck and no taper: down the diagonal, along the clear
    # lane at y=20 and into the terminal on the terminal's own row. Ending
    # level with the pad keeps the whole 2mm pad inside the band, so the
    # terminal needs neither a mitred stub nor a round cap standing proud of
    # it, and the transition vias sit inside the copper on both faces instead
    # of just outside its edge, which is what left facing nibs in the pour.
    term=23
    f=at('F101',1)
    track('SWITCHED_5V',curve([q4d,(31,12),(39,20),(44,20),
                               (47,term),f],ARC3),TRUNK,p.B_Cu)
    track('SWITCHED_5V',[(46.6,term),f],TRUNK,p.F_Cu)
    # Each barrel sits wholly inside the copper on both faces: no centre is
    # more than 0.65mm off either centreline, against the 0.8mm a 0.9mm disk
    # has to spare inside a 2.5mm band, and each keeps 0.44mm to the fuse hole.
    for stitch in ((46.4,22.7),(47.5,23),(48.35,23.6)):
        v=p.PCB_VIA(board);v.SetPosition(point(*stitch));v.SetWidth(p.FromMM(.9));v.SetDrill(p.FromMM(.45))
        v.SetViaType(p.VIATYPE_THROUGH);v.SetLayerPair(p.F_Cu,p.B_Cu)
        v.SetNet(nets['SWITCHED_5V']);v.SetLocked(True);board.Add(v)
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
    taps=(29,43,54,65.25)
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
            bends=[(f[0],f[1]+2),(f[0]+4,f[1]+6),(POWER_BUS_X,f[1]+6)] if offset==1 else [(POWER_BUS_X,f[1])]
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
        flow((f'F{n+1}',2),(f'J{n+3}',1),
             [(a[0],a[1]+2),(a[0]+2,a[1]+4),(b[0]-2,a[1]+4)],2,p.B_Cu,ARC2)
        a,b=at(f'F{n+2}',2),at(f'J{n+2}',1)
        join((f'F{n+2}',2),(f'J{n+2}',1),
             [(a[0]+3.25,b[1])],.8,p.F_Cu)
        c=at(f'C{n+2}',1)
        join((f'J{n+2}',1),(f'C{n+2}',1),
             [(57.5,b[1]),(58.5,b[1]-1),(58.5,y-6),(57.5,y-7),(c[0]+3,y-7)],.8,p.B_Cu)
    # Reserve front copper below each pair, and keep same-side ground far
    # enough away to use the coupled-microstrip calculation as a starting point.
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
    # One dead-end ground nib is left over between power copper, on the front
    # under Q3 in the wedge between the AUX approach and the source bridge.
    # Blunt it with a local pour-only cutback whose own outline is rounded, so
    # the pour ends on a curve instead of a tip and the cutback adds no sharp
    # corner of its own. It only removes fill: the tracks and vias that bound
    # it, the power zones and the USB reference ground are untouched, and the
    # area is a dead end, so no ground region loses a path.
    keepout(p.F_Cu,43.15,10.35,44.5,11.9,pours=True,radius=.35)
    # The pair of facing nibs on the back under F101 needed the same treatment
    # while the trunk ran a millimetre south of the fuse terminal and its three
    # transition vias sat just outside the band's edge. The trunk now ends on
    # the terminal's own row with those vias inside the copper, so the pour's
    # northern boundary there is one straight edge with nothing to poke into.
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
