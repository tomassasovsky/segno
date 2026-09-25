"""Verify the walled carrier against the actual later cradle print release."""

import hashlib
import json
import math
import cadquery as cq
import numpy as np
from scipy.spatial import cKDTree
import top_mount as m


def clear(a, b, name):
    volume = a.intersect(b).Volume()
    assert volume < 1e-6, (name, volume)


def same_geometry(a, b):
    assert a.isValid() and b.isValid()
    assert abs(a.Volume()-b.Volume()) < 1e-4
    assert abs(a.Area()-b.Area()) < 1e-4
    assert (a.Center()-b.Center()).Length < 1e-5
    points = [np.array([v.toTuple() for v in s.Vertices()]) for s in (a, b)]
    for x, y in (points, points[::-1]):
        assert cKDTree(x).query(y)[0].max() < 1e-5


def mesh_check(path, shape):
    raw = path.read_bytes()
    count = int.from_bytes(raw[80:84], 'little')
    assert len(raw) == 84+50*count
    records = np.frombuffer(raw, dtype=np.dtype([
        ('normal','<f4',(3,)), ('vertices','<f4',(3,3)), ('attr','<u2')]), offset=84)
    t = records['vertices'].astype(np.float64)
    vertices, faces = np.unique(np.round(t.reshape(-1,3),6), axis=0, return_inverse=True)
    faces = faces.reshape(-1,3)
    edges = np.concatenate([faces[:,[0,1]], faces[:,[1,2]], faces[:,[2,0]]])
    _, counts = np.unique(np.sort(edges,axis=1), axis=0, return_counts=True)
    assert np.all(counts == 2), (path.name, 'open mesh')
    volume = np.einsum('ij,ij->i',t[:,0],np.cross(t[:,1],t[:,2])).sum()/6
    assert volume > 0 and abs(volume/shape.Volume()-1) < .005
    assert abs(vertices[:,2].min()) < 1e-5
    assert np.all(np.linalg.norm(np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]),axis=1) > 1e-10)
    return count


def check_carrier(base, lens):
    # Independent minimum bed, spanning the entire strip and cutting allowance.
    bed = m.box(m.pill.STRIP_WIDTH, m.E.LED_CH_L, 2.39,
                (m.PILL_X,0,m.BED_TOP-1.195))
    assert bed.cut(base).Volume() < 1e-6, 'missing continuous LED floor'
    # Real walls and ledges, not merely a flat floor supporting an old carrier.
    for side in (-1,1):
        wall = m.box(.6,45,4.6,(m.PILL_X+side*6.65,0,m.LENS_SEAT-2.3))
        assert wall.cut(base).Volume() < 1e-6, 'missing diffuser support wall'
    bearing = base.intersect(lens.translate((0,0,-.01))).Volume()/.01
    assert bearing > 80, ('insufficient white-flange seat',bearing)
    return bearing


def check_friction_fit(base, cover, lens):
    ribs = [m.fit_rib(side,end*m.FIT_Y) for side in (-1,1) for end in (-1,1)]
    allowed = cq.Compound.makeCompound(ribs)
    overlap = base.intersect(cover)
    assert overlap.Volume() > 1, 'no press contact at the housing ribs'
    assert overlap.cut(allowed).Volume() < 1e-6, 'housing binds outside fit ribs'
    for rib in ribs:
        contact = overlap.intersect(rib)
        assert contact.Volume() > .3, 'missing friction rib'
        assert .29 < contact.BoundingBox().xlen < .31, 'excessive or loose press fit'
    # Follow the base and diffuser from below. The deep platform jaws must not
    # obstruct the carrier; only the intentionally proud ribs can touch.
    for dz in np.linspace(-28,0,29):
        moved = base.translate((0,0,float(dz)))
        interference = moved.intersect(cover)
        if interference.Volume() > 1e-8:
            assert interference.cut(allowed.translate((0,0,float(dz)))).Volume() < 1e-6, ('blocked carrier approach',dz)
        clear(lens.translate((0,0,float(dz))),cover,'diffuser approach')
    # The top and bottom tapers allow insertion/removal without an undercut.
    for side in (-1,1):
        for end in (-1,1):
            entry = base.intersect(m.box(3,3,.1,(m.TRAY_X+side*10,end*m.FIT_Y,m.WALL_TOP-.5)))
            edge = entry.BoundingBox().xmax-m.TRAY_X if side==1 else m.TRAY_X-entry.BoundingBox().xmin
            assert edge < 9.85, 'rib lacks insertion lead-in'
    # Solid side bands replace the former flexure slots and hooks.
    for side in (-1,1):
        side_wall = m.box(1.5,46,2,(m.TRAY_X+side*8.6,0,m.BOTTOM+1))
        assert side_wall.cut(base).Volume() < 1e-6, 'slotted or missing housing wall'


def check_deep_grip(cover):
    for y in (-m.CLIP_Y,m.CLIP_Y):
        outside = m.box(2.3,13.8,13,(m.CHANNEL_BACK+1.2,y,-11))
        inside = m.box(1.1,13.8,15,(m.FRONT+.6,y,-9.5))
        assert outside.cut(cover).Volume() < 1e-6, 'missing deep outside brace'
        assert inside.cut(cover).Volume() < 1e-6, 'missing deep inside leaf'
        tip = cover.intersect(m.box(3,1,.0001,(m.FRONT+.6,y,m.CLIP_BOTTOM+.00005)))
        entry = m.CHANNEL_BACK-tip.BoundingBox().xmax
        assert 2.699 < entry < 2.701, 'missing platform entry chamfer'
    assert m.CLIP_BOTTOM == -18


def check_prewired_loading(base, cover, lens):
    # Sweep the complete strip vertically into the open carrier, then the
    # attached leads through each end. Connector bodies stay outside the case.
    strip_bottom = m.BED_TOP + m.pill.ADHESIVE_T
    sweep_top = m.WALL_TOP + 10
    strip_sweep = m.box(12, m.pill.STRIP_LENGTH, sweep_top-strip_bottom,
                        (m.PILL_X, 0, (sweep_top+strip_bottom)/2))
    clear(strip_sweep, base, 'prewired strip vertical loading')
    for end in (-1, 1):
        # A 7.6 mm wide, 2.6 mm high lead envelope leaves 0.2 mm each side
        # of the 8 mm slot and exits above the bed without a forced down-bend.
        leads = m.box(7.6, 15, 2.6,
                      (m.PILL_X, end*34.5, strip_bottom+1.3))
        for name, solid in (('base', base), ('cover', cover), ('lens', lens)):
            clear(leads, solid, 'seated soldered leads/'+name)
        lead_sweep = m.box(7.6, 15, sweep_top-strip_bottom,
                          (m.PILL_X, end*34.5, (sweep_top+strip_bottom)/2))
        clear(lead_sweep, base, 'lead drop-in path must have no roof')
        # The lid and diffuser approach from above: sweeping the leads down
        # relative to them proves their closure does not trap the wiring.
        closure_sweep = m.box(7.6, 15, 20,
                             (m.PILL_X, end*34.5, strip_bottom+2.6-10))
        clear(closure_sweep, cover, 'cover closure over leads')
        clear(closure_sweep, lens, 'diffuser closure over leads')


def print_check(name, solid, min_contact=850):
    shape = m.print_orientation(name,solid)
    b = shape.BoundingBox()
    assert abs(b.zmin)<1e-6 and max(b.xlen,b.ylen)<100 and b.zlen<35
    slab = m.box(120,120,.01,(0,0,.025))
    contact = shape.intersect(slab).Volume()/.01
    assert contact > min_contact, (name,'bed contact',contact)
    for i in range(1,int(b.zlen/.2)+1):
        upper=shape.intersect(slab.translate((0,0,i*.2)))
        if upper.Volume()<1e-8:
            continue
        lower=shape.intersect(slab.translate((0,0,(i-1)*.2))).translate((0,0,.2))
        assert lower.Volume()>1e-8, (name,i,'floating layer')
        support=lower.fuse(*[lower.translate((.22*math.cos(a*math.pi/4),
                          .22*math.sin(a*math.pi/4),0)) for a in range(8)])
        extra=upper.cut(support)
        assert extra.Volume()<1e-5, (name,i,'unsupported layer growth',extra.Volume())
    return {'size_mm':[round(v,3) for v in (b.xlen,b.ylen,b.zlen)],
            'bed_contact_mm2':round(contact,2)}


def check():
    parts=m.parts()
    cover,base=parts['cover'],parts['base']
    lens=m.placed_pill()['diffuser']
    local_base,local_cover,local_lens=[m.untilt(s) for s in (base,cover,lens)]
    results={}
    for name,solid in parts.items():
        assert solid.isValid() and len(solid.Solids())==1,name
        clear(solid,lens,name+'/lens')
        clear(solid,m.cable_clearance(),name+'/cable exit')
        pose=m.print_orientation(name,solid)
        same_geometry(cq.importers.importStep(str(m.OUT/f'pill_top_mount_{name}.step')).val(),pose)
        results[name]={'triangles':mesh_check(m.OUT/f'pill_top_mount_{name}.stl',pose)}
    bearing=check_carrier(local_base,local_lens)
    try:
        check_carrier(m.box(19.2,72,2.4,(m.PILL_X,0,m.BED_TOP-1.2)),local_lens)
    except AssertionError:
        pass
    else:
        raise AssertionError('wall-less bottom accepted')
    check_friction_fit(local_base,local_cover,local_lens)
    check_deep_grip(cover)
    plain = local_base.cut(cq.Compound.makeCompound([
        m.fit_rib(side,end*m.FIT_Y) for side in (-1,1) for end in (-1,1)]))
    try:
        check_friction_fit(plain,local_cover,local_lens)
    except AssertionError:
        pass
    else:
        raise AssertionError('housing without grip accepted')
    shallow = cover.cut(m.box(50,80,14,(m.PILL_X,0,-13)))
    try:
        check_deep_grip(shallow)
    except AssertionError:
        pass
    else:
        raise AssertionError('shallow platform clip accepted')
    check_prewired_loading(local_base,local_cover,local_lens)
    # A closed end tunnel must fail even when the final lead position clears.
    for end in (-1,1):
        roof = m.box(8,2,.6,(m.PILL_X,end*34,m.WALL_TOP-.3))
        try:
            check_prewired_loading(local_base.fuse(roof),local_cover,local_lens)
        except AssertionError:
            pass
        else:
            raise AssertionError('closed cable tunnel accepted')
    assert abs(local_lens.BoundingBox().zmax-local_cover.BoundingBox().zmax)<1e-6
    assert local_cover.intersect(local_lens.translate((0,0,.01))).Volume()>.2, 'lens lifts through bezel'
    strip=m.box(12,m.pill.STRIP_LENGTH,m.E.LED_STRIP_OA,
                (m.PILL_X,0,m.BED_TOP+m.pill.ADHESIVE_T+m.E.LED_STRIP_OA/2))
    clear(strip,local_base,'strip inside integral carrier')
    clear(strip,local_cover,'strip/cover')
    assert abs((m.FACE-m.pill.FACE_T)-strip.BoundingBox().zmax-5)<1e-6
    for side in (-1,1):
        wire=m.box(m.pill.WIRE_WIDTH,12,2.6,(m.PILL_X,side*36,m.BED_TOP-.3))
        for solid in parts.values():
            clear(m.tilt(wire),solid,'LED wire outlet')
    ribs=m.grip_rib(-m.CLIP_Y).fuse(m.grip_rib(m.CLIP_Y))
    for row,info in m.CRADLE['rows'].items():
        path=m.REFERENCE/f'platform_{row}.step'
        assert hashlib.sha256(path.read_bytes()).hexdigest()==info['reference_sha256']
        ring=m.platform(row)
        z=ring.BoundingBox().zmax
        local=ring.translate((0,0,-z))
        # Measure at the actual clips; a shared stale model cannot pass.
        for y in (-m.CLIP_Y,m.CLIP_Y):
            wall=local.intersect(m.box(6,1,.1,(58,y,-5.5)))
            assert abs(wall.BoundingBox().xlen-2.4)<1e-5, 'wrong cradle revision'
        assert abs(ring.BoundingBox().xlen-118.47)<1e-5
        assert abs(ring.BoundingBox().ylen-88.75)<1e-5
        for settle in (0,-.075,-.15):
            moved=cover.translate((settle,0,0))
            overlap=moved.intersect(local)
            assert overlap.Volume()>0
            assert overlap.cut(ribs.translate((settle,0,0))).Volume()<1e-6
            clear(base.translate((settle,0,0)),local,'carrier/cradle throughout settling')
        for y in (-m.CLIP_Y,m.CLIP_Y):
            zone=m.box(6,14,5,(58,y,-15))
            assert cover.translate((-.15,0,0)).intersect(local).intersect(zone).Volume()>.1
        body=m.box(m.CRADLE['pedal_depth_mm'],m.CRADLE['pedal_width_mm'],m.CRADLE['pedal_height_mm'],
                    (0,0,info['pedal_bottom_local_z_mm']+m.CRADLE['pedal_height_mm']/2))
        for solid in parts.values():
            clear(solid,body,'pedal at rest')
        for y in (-m.CLIP_Y,m.CLIP_Y):
            tongue=cover.intersect(m.box(2.4,14,18,(m.FRONT+.6,y,-9)))
            clear(tongue.translate((m.REAR_IN-m.RIB_TIP,0,0)),body,'fitted tongue/pedal')
        assert base.BoundingBox().zmin-info['cable_top_local_z_mm']>.5, 'floor blocks updated cable exit'
        # Compare the real planar face normals, not just the angle parameter.
        slope_faces=[f for f in ring.Faces() if f.geomType()=='PLANE'
                     and .15<abs(f.normalAt().x)<.3 and abs(f.normalAt().z)>.9]
        assert slope_faces, 'reference lacks sloping top plane'
        reference=max(slope_faces,key=lambda f:f.Area()).normalAt()
        if reference.z<0:
            reference=reference.multiply(-1)
        for label,shape in (('cover',cover),('diffuser',lens)):
            top_faces=[f for f in shape.Faces() if f.geomType()=='PLANE' and f.normalAt().z>.9]
            face=max(top_faces,key=lambda f:reference.dot(f.Center()))
            assert (face.normalAt()-reference).Length<1e-5, label+' is not parallel to platform'
        assembly=cq.importers.importStep(str(m.OUT/f'pill_top_mount_assembly_{row}.step')).val()
        assert assembly.isValid()
        expected=[ring,*[s.translate((0,0,z)) for s in [cover,base,lens]]]
        assert len(assembly.Solids())==4
        for a,b in zip(sorted(assembly.Solids(),key=lambda s:s.Volume()),sorted(expected,key=lambda s:s.Volume())):
            same_geometry(a,b)
    for name,solid in parts.items():
        results[name].update(print_check(name,solid))
    for name,solid in m.fit_samples(parts).items():
        assert solid.isValid() and len(solid.Solids())==1, 'invalid fit sample'
        pose=m.print_orientation(name,solid)
        stem=m.OUT/f'pill_top_mount_fit_sample_{name}'
        same_geometry(cq.importers.importStep(str(stem.with_suffix('.step'))).val(),pose)
        results['fit_sample_'+name]={'triangles':mesh_check(stem.with_suffix('.stl'),pose)}
        results['fit_sample_'+name].update(print_check(name,solid,min_contact=100))
    results.update({'white_flange_bearing_mm2':round(bearing,2),'rear_wall_mm':2.4,
                    'entry_gap_mm':2.70,
                    'straight_channel_gap_mm':round(m.CHANNEL_BACK-(m.FRONT+m.CLIP_T),2),
                    'spring_throat_mm':round(m.THROAT,2),'floor_thickness_mm':2.4,
                    'housing_rib_interference_per_side_mm':.30,'platform_grip_depth_mm':18,
                    'outer_jaw_thickness_mm':2.4,'inner_leaf_thickness_mm':1.2,
                    'face_centre_above_rear_rim_mm':m.FACE,'face_slope_degrees':m.SLOPE,
                    'minimum_base_clearance_above_cable_mm':round(base.BoundingBox().zmin-max(r['cable_top_local_z_mm'] for r in m.CRADLE['rows'].values()),3),
                    'prewired_loading':'strip and both lead paths clear normal to the tilted face; grip jaws remain vertical',
                    'lead_envelope_mm':[7.6,2.6],
                    'physical_limit':'PLA insertion/removal force, friction retention, rocking, creep and pedal travel require a print trial'})
    return results


if __name__=='__main__':
    print(json.dumps(check(),indent=2))
