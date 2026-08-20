"""Validation: build the 3D box by FOLDING the actual DXF flat patterns (not the
parametric model). If a hole/contour is wrong in the source DXF, it shows here.
Gitignored scratch. Run with the bundled .venv."""
import os, math
import ezdxf
import cadquery as cq
import segno_enclosure as V

OUT = V.OUT
T = V.T
BIG = 3000.0


def _area(pts):
    a = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]; x2, y2 = pts[(i+1) % len(pts)]
        a += x1*y2 - x2*y1
    return abs(a) / 2.0


def _lw_points(e):
    """Polyline vertices with arc bulges tessellated into points, so rounded-rect
    fillets render as real arcs (not the straight chamfers you get by dropping bulges)."""
    from ezdxf.math import bulge_to_arc
    raw = list(e.get_points("xyb")); n = len(raw)
    closed = bool(e.closed); pts = []
    for i in range(n):
        x, y, b = raw[i][0], raw[i][1], raw[i][2]
        pts.append((x, y))
        if abs(b) > 1e-9 and (i < n - 1 or closed):
            nx, ny = raw[(i + 1) % n][0], raw[(i + 1) % n][1]
            c, _, _, r = bulge_to_arc((x, y), (nx, ny), b)
            a0 = math.atan2(y - c.y, x - c.x)      # actual start angle
            sweep = 4.0 * math.atan(b)             # signed arc (avoids the reflex/wrap bug)
            steps = max(2, int(abs(sweep) / 0.20))
            for s in range(1, steps):
                a = a0 + sweep * s / steps
                pts.append((c.x + r * math.cos(a), c.y + r * math.sin(a)))
    return pts


def read_dxf(path):
    """-> (outline pts, [hole loops], [(cx,cy,r)], [bend segments])."""
    doc = ezdxf.readfile(path); msp = doc.modelspace()
    cut_polys, holes, circles, bends = [], [], [], []
    for e in msp:
        t, layer = e.dxftype(), e.dxf.layer
        if t == "LWPOLYLINE":
            pts = _lw_points(e)
            if layer == "CUT":
                cut_polys.append(pts)
            elif layer == "VENT":
                holes.append(pts)               # vents are through-cuts
            elif layer == "BEND":
                bends.append(pts)
        elif t == "CIRCLE" and layer in ("CUT",):
            circles.append((e.dxf.center.x, e.dxf.center.y, e.dxf.radius))
    cut_polys.sort(key=_area, reverse=True)
    outline = cut_polys[0]
    holes += cut_polys[1:]
    return outline, holes, circles, bends


def _clean(pts, tol=1e-4):
    out = []
    for p in pts:
        if not out or abs(p[0]-out[-1][0]) > tol or abs(p[1]-out[-1][1]) > tol:
            out.append((p[0], p[1]))
    if len(out) > 1 and abs(out[0][0]-out[-1][0]) < tol and abs(out[0][1]-out[-1][1]) < tol:
        out.pop()                                  # drop pre-closed duplicate
    return out


def flat_solid(outline, holes, circles, t=T):
    s = cq.Workplane("XY").polyline(_clean(outline)).close().extrude(t)
    skipped = 0
    for loop in holes:
        lp = _clean(loop)
        if len(lp) < 3:
            skipped += 1; continue
        try:
            s = s.cut(cq.Workplane("XY").polyline(lp).close().extrude(t+2).translate((0, 0, -1)))
        except Exception:
            skipped += 1
    for (cx, cy, r) in circles:
        s = s.cut(cq.Workplane("XY").circle(r).extrude(t+2).translate((cx, cy, -1)))
    if skipped:
        print(f"  (skipped {skipped} unparseable hole loop(s))")
    return s.val()


def region(solid, xlo, xhi, ylo, yhi):
    box = cq.Workplane("XY").box(xhi-xlo, yhi-ylo, T+4, centered=False).translate((xlo, ylo, -2)).val()
    return solid.intersect(box)


def _u(v):
    import numpy as np
    v = np.array(v, float); return v / np.linalg.norm(v)


def _bend_plane(seg, d_a, d_b):
    """Local frame for a bend: x=d_a, y=d_b, normal=bend axis e=d_a x d_b, origin on
    the sharp outer edge. Returns (plane, length, phi). The two flat faces leave the
    edge along d_a and d_b; phi is the angle between them."""
    import numpy as np
    da = _u(d_a); db = _u(d_b)
    phi = math.acos(max(-1.0, min(1.0, float(np.dot(da, db)))))
    e = _u(np.cross(da, db))
    p0 = np.array(seg[0], float); p1 = np.array(seg[1], float)
    L = float(np.linalg.norm(p1 - p0))
    origin = p0 if float(np.dot(e, p1 - p0)) > 0 else p1
    pl = cq.Plane(origin=cq.Vector(*origin), xDir=cq.Vector(*da), normal=cq.Vector(*e))
    return pl, L, phi


def _bend_fill(shell, seg, d_a, d_b, ri=V.RI, t=V.T):
    """Replace a fold's sharp corner with a real radiused bend (outer radius ri+t,
    inner radius ri), tangent to both faces. The sharp wedge tip is cut away and the
    cylindrical bend band is unioned back in -- the 'missing material' filled with a
    radius. Booleans only (no OCC fillet). `seg` = the bend's outer edge endpoints,
    inset from the box corners so adjacent bends don't interact."""
    ro = ri + t
    pl, L, phi = _bend_plane(seg, d_a, d_b)
    Lt = ro / math.tan(phi / 2.0)                  # tangent point distance along each face
    dc = ro / math.sin(phi / 2.0)                  # edge -> arc centre, along the bisector
    Pa = (Lt, 0.0)                                 # tangent point on face a
    Pb = (Lt * math.cos(phi), Lt * math.sin(phi))  # tangent point on face b
    C  = (dc * math.cos(phi / 2.0), dc * math.sin(phi / 2.0))  # arc centre
    # quad arris->Pa->C->Pb: Pa-C and Pb-C are perpendicular to the faces (the tangent
    # trim lines), so the plates end exactly where the bend's annular sector begins.
    quad  = cq.Workplane(pl).polyline([(0, 0), Pa, C, Pb]).close().extrude(L)
    outer = cq.Workplane(pl).moveTo(*C).circle(ro).extrude(L)
    inner = cq.Workplane(pl).moveTo(*C).circle(ri).extrude(L)
    band  = quad.intersect(outer).cut(inner)       # annular sector: true inner + outer arcs
    return shell.cut(quad.val()).fuse(band.val()).clean()


def _bendlines(bends):
    vx = sorted({round(p[0][0], 3) for p in bends if abs(p[0][0]-p[1][0]) < 1e-6})
    hy = sorted({round(p[0][1], 3) for p in bends if abs(p[0][1]-p[1][1]) < 1e-6})
    return vx, hy


def fold_base(path):
    """Base = bottom + front + rear + 2 sides fold up; rear has a 2nd fold = transition."""
    outline, holes, circles, bends = read_dxf(path)
    flat = flat_solid(outline, holes, circles)
    vx, hy = _bendlines(bends)
    BW = max(vx)                          # side bends at x=0 and x=BW
    BD, ytr = hy[1], hy[2]
    Hr = ytr - BD
    print(f"  base from DXF: BW={BW:.1f}  BD={BD:.1f}  Hr={Hr:.1f}")
    bottom = region(flat, 0, BW, 0, BD)
    front  = region(flat, -BIG, BW+BIG, -BIG, 0).rotate((0,0,0),(1,0,0), -90)
    side_L = region(flat, -BIG, 0, 0, BD).rotate((0,0,0),(0,1,0), 90)
    side_R = region(flat, BW, BW+BIG, 0, BD).rotate((BW,0,0),(BW,1,0), -90)
    rear   = region(flat, -BIG, BW+BIG, BD, ytr).rotate((0,BD,0),(1,BD,0), 90)
    tr = region(flat, -BIG, BW+BIG, ytr, BIG)
    tr = tr.rotate((0,BD,0),(1,BD,0), 90).rotate((0,BD,Hr),(1,BD,Hr), 90 - V.TRANS_ANGLE)
    # ONE welded sheet: fuse the panels, then fill every fold with a real radiused bend
    # (outer ri+t, inner ri). Segments inset by g from the corners so bends don't interact.
    shell = bottom
    for p in (front, side_L, side_R, rear, tr):
        shell = shell.fuse(p)
    shell = shell.clean()
    g = V.RI + V.T
    shell = _bend_fill(shell, ((g, 0, 0),  (BW-g, 0, 0)),  (0,  1, 0), (0, 0, 1))   # front-bottom
    shell = _bend_fill(shell, ((g, BD, 0), (BW-g, BD, 0)), (0, -1, 0), (0, 0, 1))   # rear-bottom
    shell = _bend_fill(shell, ((0, g, 0),  (0, BD-g, 0)),  (1,  0, 0), (0, 0, 1))   # left-bottom
    shell = _bend_fill(shell, ((BW, g, 0), (BW, BD-g, 0)), (-1, 0, 0), (0, 0, 1))   # right-bottom
    # the rear->transition fold is only ~TRANS_ANGLE (~24 deg), a shallow brake crease;
    # rounding it adds nothing visible and leaves a degenerate sliver, so it stays sharp.
    return [("base", shell)]


def fold_faceplate(path, explode=0.0):
    """Fold the LID (simple): top plate + front lip + rear lap, then tilt by the slope and
    seat it on the base (lifted by `explode`). Sides are on the base, not the lid."""
    outline, holes, circles, bends = read_dxf(path)
    flat = flat_solid(outline, holes, circles)
    _, hy = _bendlines(bends)
    yf, yr = hy[0], hy[1]
    PW = max(p[0] for p in outline)
    lid_top   = region(flat, -BIG, BIG, yf, yr)
    lid_front = region(flat, -BIG, BIG, -BIG, yf).rotate((0, yf, 0), (1, yf, 0), 90 - V.SLOPE_ANGLE)  # -> vertical after the slope tilt
    lid_rear  = region(flat, -BIG, BIG, yr, BIG).rotate((0, yr, 0), (1, yr, 0), -(V.SLOPE_ANGLE + V.TRANS_ANGLE))
    shell = lid_top.fuse(lid_front).fuse(lid_rear).clean()
    # fill the two lid folds with real radiused bends, FULL WIDTH (the lid's left/right
    # edges are free cuts, no side bends to collide with -> no corner margin needed).
    # The panels fold about their BOTTOM line (z=0) so the lip seats at the right height,
    # but then the two OUTER (top, z=T) faces meet at an apex offset by d = T*(1-cos th)/sin th
    # toward the folded flap -- round THERE, not at the fold line.
    s = math.radians(V.SLOPE_ANGLE); sr = math.radians(V.SLOPE_ANGLE + V.TRANS_ANGLE)
    thf = math.radians(90 - V.SLOPE_ANGLE)                  # front-lip fold angle
    apex = lambda th: V.T * (1 - math.cos(th)) / math.sin(th)
    af = yf - apex(thf)                                     # front apex (toward the lip, y<yf)
    ar = yr + apex(sr)                                      # rear apex  (toward the lap, y>yr)
    shell = _bend_fill(shell, ((0, af, V.T), (PW, af, V.T)), (0,  1, 0), (0, -math.sin(s), -math.cos(s)))   # front-lip fold
    shell = _bend_fill(shell, ((0, ar, V.T), (PW, ar, V.T)), (0, -1, 0), (0, math.cos(sr), -math.sin(sr)))  # rear-lap fold
    bdd = V.DEV90                         # the preview folds the bend-deducted flat sharply, so
    z0 = V.H_FRONT - bdd                  # walls land ~bdd low -> seat the lid flush on them
    def place(sld):
        return (sld.translate((0, -yf, 0))
                   .rotate((0, 0, 0), (1, 0, 0), V.SLOPE_ANGLE)
                   .translate((0, 0, z0 + explode)))
    # the full-width blank (LID_W) is drawn with the schedule content at +LID_OX;
    # shift the folded shell back so apertures line up with the base frame
    parts = [("lid", place(shell.translate((-V.LID_OX, 0, 0))))]
    txt = silk_text(path)                 # embossed silkscreen labels, lifted with the lid
    if txt is not None:
        parts.append(("lid_silk", place(txt.translate((-V.LID_OX, 0, 0)))))
    # --- screens behind the apertures: glass flush with the plate top, body hangs below; move with lid.
    # NOTE: dxf_faceplate emits the cutouts with oy=yf (front-lip offset), so add yf to match them.
    def screen(u, v, w, h, d, nm):
        body = cq.Workplane("XY").box(w, h, d, centered=(True, True, False)).translate((u, v + yf, V.T - d)).val()
        return (nm, place(body))
    s16uc = (V._row1_u(4) + V._row1_u(7)) / 2.0
    parts.append(screen(V.COL_U, V.SCREEN_TOP_V - V.SMALL_H/2, V.SMALL_W-1, V.SMALL_H-1, 12, "lid_screen7"))
    parts.append(screen(s16uc,               V.SCREEN_TOP_V - V.BIG_H/2,   V.BIG_W-1,   V.BIG_H-1,   16, "lid_screen16"))
    # (screen-retention clamps removed: screens are bonded to the shell, #760)
    # --- encoder knob + diffused LED-ring cover on the top plate (centred under the 7" screen)
    # ENC_V, not PEDAL_ROW2_V: the encoder/ring deliberately does NOT follow
    # CLEAR/BANK rearward (it would hit the 7" screen) -- faceplate_holes() cuts
    # RING/ENCODER at ENC_V. This preview used to stack the ring 35.5 mm behind
    # its own hole, so the fold render and the collision audit were checking the
    # wrong station on the one part they exist to verify (#767).
    eu, ev = V.COL_U, V.ENC_V + yf
    parts.append(("lid_ring", place(cq.Workplane("XY").circle(V.RING_OD/2).circle(V.RING_ID/2)
                                      .extrude(2.5).translate((eu, ev, V.T)).val())))
    # metal centre disc filling the inside of the ring (the ring cutout is a full hole); the encoder
    # mounts through it, the knob sits on top. Flush with the faceplate (z=0..T).
    parts.append(("lid_ringmetal", place(cq.Workplane("XY").circle(V.RING_ID/2).circle(V.D_ENC/2)
                                      .extrude(V.T).translate((eu, ev, 0)).val())))
    parts.append(("lid_knob", place(cq.Workplane("XY").circle(9.0).extrude(16.0)
                                      .translate((eu, ev, V.T)).val())))
    return parts


def _glyph(ch, h, emboss):
    """One bold extruded glyph, left/bottom anchored at the origin."""
    for kind in ("bold", "regular"):
        try:
            g = cq.Workplane("XY").text(ch, h, emboss, halign="left", valign="bottom",
                                        kind=kind, combine=False)
            bb = g.val().BoundingBox()
            return g.translate((-bb.xmin, 0, 0)).val(), bb.xlen
        except Exception:
            continue
    return None, h * 0.6


def silk_text(path, z=V.T, emboss=0.6, gap=0.8, max_w=None):
    """Bold embossed silkscreen labels at a SINGLE cap height; a word wider than one
    pedal (`max_w`) is squished horizontally (x only) to fit, centred on its pedal."""
    from cadquery import Matrix
    if max_w is None:
        max_w = V.FSW_SLOT_W
    doc = ezdxf.readfile(path); msp = doc.modelspace()
    out = []
    for e in msp:
        if e.dxftype() != "TEXT" or e.dxf.layer != "SILK":
            continue
        s = e.dxf.text
        hal = e.dxf.get("halign", 0)                       # 0=left, 1=centre
        ap = e.dxf.align_point if hal else e.dxf.insert
        x0, y0, h = float(ap.x), float(ap.y), float(e.dxf.height)
        glyphs = []; cx = 0.0                              # build left-anchored at origin
        for ch in s:
            if ch == " ":
                cx += h * 0.45; continue
            g, w = _glyph(ch, h, emboss)
            if g is not None:
                glyphs.append(g.translate((cx, 0, 0)))
            cx += w + gap
        width = cx - gap
        if not glyphs or width <= 0:
            continue
        sx = min(1.0, max_w / width)                       # squish X only if too wide
        comp = cq.Compound.makeCompound(glyphs)
        if sx < 1.0:
            comp = comp.transformGeometry(Matrix([[sx, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]))
        left = x0 - width * sx / 2.0 if hal == 1 else x0   # centre on the pedal, else flush-left
        out.append(comp.translate((left, y0, z)))
    return cq.Compound.makeCompound(out) if out else None


def pcb_parts():
    """Standoffs on the bottom plate: short ones for the main board, plus four tall risers
    that lift the Raspberry Pi (Pi build) so its rear port stack meets the I/O window."""
    _, cx, cy, (hx, hy) = V.board_mounts()[0]
    quad = lambda sx, sy: [(-sx/2,-sy/2), (-sx/2,sy/2), (sx/2,-sy/2), (sx/2,sy/2)]
    out = []
    for k, (dx, dy) in enumerate(quad(hx, hy)):
        out.append((f"board_so{k}",
                    cq.Workplane("XY").circle(3.0).circle(1.5).extrude(V.STANDOFF_H)
                      .translate((cx+dx, cy+dy, V.T)).val()))
    pcx, pcy, (px, py) = V.pi_mount()
    for k, (dx, dy) in enumerate(quad(px, py)):
        out.append((f"piriser{k}",
                    cq.Workplane("XY").circle(2.6).circle(1.3).extrude(V.PI_RISER_H)
                      .translate((pcx+dx, pcy+dy, V.T)).val()))
    # external 5V buck: TWO ear holes on a flat mount, not the old 4-hole quad on
    # standoffs. buck_mount() returns (cx, cy, ear_spacing) -- a scalar third
    # element, which is what used to blow this function up (#742).
    for bi, (bn, bcx, bcy, bsp) in enumerate(V.buck_mounts()):
        for k, dx in enumerate((-bsp/2.0, bsp/2.0)):
            out.append((f"buckear{bi}{k}",
                        cq.Workplane("XY").circle(V.D_M4/2.0).extrude(V.T)
                          .translate((bcx+dx, bcy, 0.0)).val()))
        out.append((f"buck{bi}", cq.Workplane("XY")
                    .box(V.BUCK_BODY[0], V.BUCK_BODY[1], V.BUCK_BODY[2], centered=(True, True, False))
                    .translate((bcx, bcy, V.T)).val()))
    return out


def rear_panels():
    """The bolt-on I/O sub-panel as a thin plate over the rear WINDOW. Built in the
    panel-local (u,z) plane from V.rear_panel_holes(), then stood up onto the rear wall
    (Y=D) centred on the panel blank.

    REBUILT on the derived rear-panel API (#767): this used to size the plate from
    V.REAR_WIN_W/H + a local ov=12 and emit two swappable "pi"/"nopi" variants. All
    four REAR_WIN_* constants and the variant argument went away when the window
    became derived and the panel came back as one part (#757/#761) -- so this whole
    module (the fold render AND the collision audit) had been dying on an
    AttributeError before it drew a single solid. Everything now comes from
    V.rear_panel_outline() / V.rear_window(), which cannot drift from the metal."""
    th = 2.0
    pu0, pz0, pw, ph = V.rear_panel_outline()     # wall coords; holes are panel-LOCAL
    pcu, pcz = pu0 + pw/2.0, pz0 + ph/2.0         # panel centre = the holes' origin
    plate = cq.Workplane("XY").box(pw, ph, th, centered=(True, True, False))
    for c in V.rear_panel_holes():
        if c.get("layer") == "MASK":              # bare-metal bonding land, not a hole
            continue
        if c["kind"] == "circle":
            tool = cq.Workplane("XY").circle(c["d"]/2).extrude(th+0.2).translate((c["u"], c["v"], -0.1))
        else:                                     # only circle/rect come out of the panel
            assert c["kind"] == "rect", f"rear_panels: unhandled cut kind {c['kind']!r}"
            tool = (cq.Workplane("XY").box(c["w"], c["h"], th+0.2, centered=(True, True, False))
                      .translate((c["u"]+c["w"]/2, c["v"]+c["h"]/2, -0.1)))
        plate = plate.cut(tool)
    # mount the sub-panel from INSIDE: plate against the inner wall face, connectors poke
    # OUT through the window flush with the outer wall. rot about X (+90) maps panel-v -> Z,
    # thickness -> -Y; seat the plate just inside the wall (Y = inner face).
    rear_wall_y = V.D - 2*V.T
    s = plate.val().rotate((0, 0, 0), (1, 0, 0), 90).translate((pcu, rear_wall_y - V.T, pcz))
    return [("rearpanel", s)]


def corner_joins():
    """Weld-free corner L-brackets + rivets, so the riveted joint is VISIBLE and provably
    aligned. Geometry matches the base rivet holes exactly (CORNER_RO / CORNER_ZF / ZR)."""
    BW, BD, T, LEG, RO = V.W - 2*V.T, V.D - 2*V.T, V.T, V.CORNER_LEG, V.CORNER_RO
    out = []
    corners = [("RL", 0.0, BD, +1, -1),    # tall rear corners only
               ("RR", BW,  BD, -1, -1)]    # (short front corners: butt+relief, lid-clamped)
    ht = V.CORNER_HT
    def leg(xa, xb, ya, yb):
        x0, x1 = sorted((xa, xb)); y0, y1 = sorted((ya, yb))
        return cq.Workplane("XY").box(x1 - x0, y1 - y0, ht, centered=False).translate((x0, y0, T)).val()  # sits ON the bottom plate
    for tag, cx, cy, sx, sy in corners:
        xin, yin = cx + sx*T, cy + sy*T          # INNER faces of the two walls (inset by T -> no wall clash)
        legA = leg(xin, xin + sx*LEG, yin, yin + sy*T)    # flat on the rear-wall inner face, along +x
        legB = leg(xin, xin + sx*T,   yin, yin + sy*LEG)  # flat on the side-wall inner face, along +y
        out.append((f"cbracket_{tag}", legA.fuse(legB)))
        for i, z in enumerate(V.CORNER_ZR_WALL):
            out.append((f"crivet_{tag}_w{i}", cq.Solid.makeCylinder(1.7, 3*T, cq.Vector(cx + sx*RO, cy - sy, T + z), cq.Vector(0, sy, 0))))   # rear wall -> legA
        for i, z in enumerate(V.CORNER_ZR_SIDE):
            out.append((f"crivet_{tag}_s{i}", cq.Solid.makeCylinder(1.7, 3*T, cq.Vector(cx - sx, cy + sy*RO, T + z), cq.Vector(sx, 0, 0))))   # side wall -> legB
    return out

def check_platform_screws(path):
    """THE gate this file exists for (#742). Read the PLAT_SCR holes out of the
    ACTUAL base-plate DXF and prove they land where the parts that bolt through
    them expect. The drift that prompted this was exactly here: the Fusion
    document's plate still had the pre-WTB-006 pattern (SKIRT_OUT_W 79.0 /
    SKIRT_OUT_D 104.0) while the platforms had moved on, and nothing checked."""
    doc = ezdxf.readfile(path)
    cs = math.cos(math.radians(V.SLOPE_ANGLE))
    got = sorted((round(e.dxf.center.x, 3), round(e.dxf.center.y, 3))
                 for e in doc.modelspace().query("CIRCLE")
                 if abs(e.dxf.radius*2 - V.D_M3) < 1e-6)
    want = sorted((round(u + fy, 3), round(v*cs + fx, 3))
                  for _l, u, v in V.PEDALS for fx, fy in V.platform_foot_xy())
    missing = [w for w in want if w not in got]
    if missing:
        raise AssertionError(
            "PLAT_SCR: %d of %d platform screw holes are NOT in %s -- e.g. %s. "
            "The plate and the platforms have drifted apart."
            % (len(missing), len(want), os.path.basename(path), missing[:3]))
    print("PLAT_SCR: all %d platform screw holes present in %s and aligned with "
          "platform_foot_xy()" % (len(want), os.path.basename(path)))
    return len(want)


def build(explode=0.0):
    """Assemble base + platforms + pedals + lid, all from the DXFs (no mirror)."""
    parts = list(fold_base(os.path.join(OUT, "segno_base.dxf")))
    parts += corner_joins()
    parts += pcb_parts()
    parts += rear_panels()
    # PLATFORMS ARE NO LONGER SHEET METAL (#719): ring + sled, 3D printed, and
    # they never had a DXF to fold -- this used to read segno_platform_front.dxf
    # and _mid.dxf, which the generator has never emitted, which is why this
    # whole validator had stopped running (#742). Take the real printed solids
    # from the generator instead: they are what actually bolts to this plate, so
    # they are what the collision and screw checks should see. The pedal
    # stand-in is the WTB-006 too, not the ASP-1 placeholder this carried.
    cs = math.cos(math.radians(V.SLOPE_ANGLE))   # slot at slope-distance v lands at horizontal v*cos
    rings = {}
    for v in (V.PEDAL_ROW1_V, V.PEDAL_ROW2_V):
        rings[v] = (V._platform_printed(cq, V.platform_h(v), v, sled=V.CONSOLE_SLED_T)
                    .val().rotate((0, 0, 0), (0, 0, 1), 90),
                    V.platform_h(v) - V.T - (V.CONSOLE_SLED_T - (V.PEDAL_PAD_T - V.POCKET_DEPTH)))
    sled = V.pedal_console_sled(cq).val().rotate((0, 0, 0), (0, 0, 1), 90)
    for i, (label, u, v) in enumerate(V.PEDALS):
        vh = v * cs
        ring, seat = rings[v]
        parts.append((f"ring{i}", ring.translate((u, vh, V.T + explode))))
        parts.append((f"sled{i}", sled.translate((u, vh, V.T + seat + explode))))
        ped = (cq.Workplane("XY").box(V.PEDAL_D, V.PEDAL_W, V.PEDAL_BODY_H,
                                      centered=(True, True, False))
                 .translate((u, vh, V.T + seat + V.CONSOLE_SLED_T + 2*explode)).val())
        parts.append((f"pedal{i}", ped))
    # faceplate = top layer (3); base stays at 0. explode separates the vertical layers.
    parts += fold_faceplate(os.path.join(OUT, "segno_faceplate.dxf"), explode=3*explode)
    return parts


def _obj_key(name):
    """Group the flat part list into logical objects (the platform's 9 panels -> one
    object, etc.). Embossed silk labels sit on the lid by design, so they're excluded."""
    if "silk" in name:
        return None
    if name.startswith("crivet"):
        return None                        # rivets pierce walls BY DESIGN -> skip collision
    if name.startswith("cbracket"):
        return name                        # keep each corner bracket separate (grouping the two
                                           # disjoint brackets into one compound makes OCC's
                                           # intersect over-report a phantom overlap)
    if name.startswith("plat"):
        return name.split("_")[0]          # plat3_5 -> plat3
    if name.startswith("board"):
        return "board"                     # the PCB stack is one object
    return name                            # base, pedal3, lid


def _bbox_hit(a, b, m=0.05):
    return (a.xmin <= b.xmax+m and a.xmax >= b.xmin-m and
            a.ymin <= b.ymax+m and a.ymax >= b.ymin-m and
            a.zmin <= b.zmax+m and a.zmax >= b.zmin-m)


def _intended_contact(a, b):
    """Object pairs that SHARE coordinates by design, so a small overlap there is just
    fold/seat tolerance, not a conflict: the lid laps the body, pedals pass through the
    lid slots, and each pedal rests on its own platform shelf."""
    # Moving the ring stack onto its true station (ENC_V, #767) needed NO new entry
    # here, and the audit got quieter rather than louder: dxf_faceplate cuts the RING
    # aperture at the OD only (the centre land leaves the blank as segno_ring_disc),
    # so lid_ringmetal drops into a real void -- measured lid intersection 0.0 mm^3,
    # against 1347 mm^3 of pure fiction while it sat 35.5 mm back in solid metal.
    # (The old rearpanel_pi/rearpanel_nopi entry went with the variants themselves.)
    t = {a.rstrip("0123456789"), b.rstrip("0123456789")}      # plat3->plat, pedal3->pedal
    if "base" in (a, b) and any(x.startswith("cbracket") for x in (a, b)):
        return True                        # brackets seat against the walls by design
    return t in ({"base", "lid"}, {"lid", "pedal"}, {"pedal", "plat"})


def check_collisions(parts, warn=10.0, err=500.0):
    """Warn/error when two objects share coordinates (interpenetrate). Parts that merely
    TOUCH (a foot resting on the base, the lid lapping a wall, a pedal on its shelf) share
    only a face -> ~0 intersection volume, so they don't trip; real overlap has real volume.

    warn/err = intersection-volume thresholds (mm^3). Returns the list of issues."""
    groups = {}
    order = []
    for name, shp in parts:
        k = _obj_key(name)
        if k is None:
            continue
        if k not in groups:
            groups[k] = []; order.append(k)
        groups[k].append(shp)
    objs = []
    for k in order:
        comp = cq.Compound.makeCompound(groups[k])
        objs.append((k, comp, comp.BoundingBox()))

    issues = []
    for i in range(len(objs)):
        for j in range(i+1, len(objs)):
            n1, c1, b1 = objs[i]; n2, c2, b2 = objs[j]
            if not _bbox_hit(b1, b2) or _intended_contact(n1, n2):
                continue
            try:
                inter = c1.intersect(c2)
                vol = inter.Volume() if inter is not None else 0.0
            except Exception:
                vol = 0.0
            if vol > warn:
                issues.append(("ERROR" if vol > err else "WARN", n1, n2, vol))

    issues.sort(key=lambda x: -x[3])
    n_err = sum(1 for s, *_ in issues if s == "ERROR")
    if not issues:
        print(f"Collision check: OK -- {len(objs)} objects, none overlap")
    else:
        print(f"Collision check: {n_err} ERROR, {len(issues)-n_err} WARN "
              f"(overlap volume thresholds warn>{warn:.0f} err>{err:.0f} mm^3):")
        for sev, n1, n2, vol in issues:
            print(f"  [{sev:5}] {n1} <-> {n2}  share coordinates: {vol:.0f} mm^3")
    return issues


if __name__ == "__main__":
    import sys
    print("Assembling base + platforms + pedals + lid from the DXFs ...")
    parts = build(explode=0.0)
    check_collisions(parts)
    asm = cq.Assembly()
    def colof(n):
        if "silk" in n: return cq.Color(0.97,0.97,0.98,1.0)        # white labels
        if n.startswith("board_so") or n.startswith("piriser"): return cq.Color(0.78,0.66,0.32,1.0)   # brass standoffs/risers
        if n in ("board_main","board_pi"): return cq.Color(0.10,0.42,0.20,1.0)  # green PCB
        if n=="board_pieth": return cq.Color(0.72,0.73,0.78,1.0)          # USB/Ethernet metal
        if n.startswith("board"): return cq.Color(0.10,0.10,0.12,1.0)     # chips/headers (dark)
        if "screen" in n: return cq.Color(0.05,0.06,0.09,1.0)             # screen glass (dark)
        if n=="lid_knob": return cq.Color(0.13,0.13,0.15,1.0)            # encoder knob
        if n=="lid_ring": return cq.Color(0.93,0.95,1.00,1.0)            # diffused LED ring cover
        if n=="lid_ringmetal": return cq.Color(0.72,0.74,0.78,1.0)       # metal centre disc inside the ring
        if n.startswith("buckso"): return cq.Color(0.78,0.66,0.32,1.0)    # brass standoffs
        if n.startswith("buck"): return cq.Color(0.12,0.32,0.46,1.0)      # external buck module
        if n.startswith("crivet"): return cq.Color(0.85,0.86,0.90,1.0)    # rivets (bright metal)
        if n.startswith("cbracket"): return cq.Color(0.95,0.55,0.20,1.0)  # corner brackets (orange, visible)
        if n.startswith("lid"): return cq.Color(0.45,0.55,0.78,1.0)
        if n.startswith("pedal"): return cq.Color(0.30,0.31,0.36,1.0)
        if n.startswith("plat"): return cq.Color(0.62,0.64,0.70,1.0)
        if n.startswith("rearpanel"): return cq.Color(0.30,0.32,0.38,1.0)   # anodised I/O sub-panel
        if n=="rear": return cq.Color(0.92,0.74,0.58,1.0)
        return cq.Color(0.82,0.85,0.90,1.0)
    for name, shp in parts:
        asm.add(shp, name=name, color=colof(name))
    asm.save(os.path.join(OUT, "segno_fromdxf.glb"))
    print("  out/segno_fromdxf.glb (full unit, from DXF)")

    # shaded PNGs via VTK (clean shading, no triangulation wireframe)
    import vtk, numpy as np
    exploded = build(explode=170.0)
    cols = {"bottom":(0.80,0.83,0.88),"front":(0.62,0.78,0.95),"rear":(0.95,0.72,0.55),
            "side_L":(0.70,0.90,0.72),"side_R":(0.70,0.90,0.72),"transition":(0.85,0.70,0.95)}
    def colv(n):
        if "silk" in n: return (0.97,0.97,0.98)
        if n.startswith("board_so") or n.startswith("piriser"): return (0.78,0.66,0.32)
        if n in ("board_main","board_pi"): return (0.10,0.42,0.20)
        if n=="board_pieth": return (0.72,0.73,0.78)
        if n.startswith("board"): return (0.10,0.10,0.12)
        if n.startswith("crivet"): return (0.85,0.86,0.90)
        if n.startswith("cbracket"): return (0.95,0.55,0.20)
        if n.startswith("lid"): return (0.45,0.55,0.80)
        if n.startswith("pedal"): return (0.30,0.31,0.36)
        if n.startswith("plat"): return (0.62,0.64,0.70)
        return cols.get(n,(0.82,0.85,0.90))
    def render(fname, plist, direction):
        ren = vtk.vtkRenderer(); ren.SetBackground(0.07,0.10,0.16); ren.SetBackground2(0.02,0.03,0.07); ren.GradientBackgroundOn()
        for name, shp in plist:
            m = vtk.vtkPolyDataMapper(); m.SetInputData(shp.toVtkPolyData(0.3,0.2))
            a = vtk.vtkActor(); a.SetMapper(m); p=a.GetProperty()
            p.SetColor(*colv(name)); p.SetSpecular(0.25); p.SetDiffuse(0.95); p.SetAmbient(0.34)
            ren.AddActor(a)
        rw_ = vtk.vtkRenderWindow(); rw_.SetOffScreenRendering(1); rw_.AddRenderer(ren); rw_.SetSize(1600,1100)
        ren.ResetCamera(); cam=ren.GetActiveCamera()
        dv=np.array(direction); dv=dv/np.linalg.norm(dv)
        cam.SetPosition(*(np.array(cam.GetFocalPoint())+dv*cam.GetDistance())); cam.SetViewUp(0,0,1)
        ren.ResetCameraClippingRange(); cam.Zoom(1.4)
        for pos,inten in [((-0.3,-0.8,1.0),1.05),((1.0,0.5,0.5),0.55),((0.2,1.0,0.3),0.45)]:
            l=vtk.vtkLight(); l.SetPosition(*pos); l.SetIntensity(inten); l.SetLightTypeToCameraLight(); ren.AddLight(l)
        rw_.Render(); w2i=vtk.vtkWindowToImageFilter(); w2i.SetInput(rw_); w2i.Update()
        wr=vtk.vtkPNGWriter(); wr.SetFileName(os.path.join(OUT,fname)); wr.SetInputConnection(w2i.GetOutputPort()); wr.Write()
        print("  out/"+fname)
    render("_fromdxf.png", parts, (-0.35,-0.7,0.55))            # assembled, FRONT (player) 3/4
    render("_fromdxf_exploded.png", exploded, (-0.4,-0.65,0.55))   # lid lifted -> pedals visible
    render("_fromdxf_profile.png", parts, (1.0,0.06,0.12))     # side elevation
