"""Deep rear-rim pill grip and a walled, friction-fit LED carrier (mm)."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import math
import json
import cadquery as cq
import tall_pill as pill

E, OUT = pill.enclosure, pill.OUT
REFERENCE = Path(__file__).with_name('reference')
CRADLE = json.loads((REFERENCE / 'provenance.json').read_text())
REAR = CRADLE['outer_depth_mm'] / 2
REAR_IN = CRADLE['inner_depth_mm'] / 2
PILL_X = 71.7  # Clears the deeper outside jaw during carrier insertion.
# The current closed cable hole reaches Z=-2.917 relative to the rear rim.
# This height leaves the entire hole open below the 2.4 mm LED floor.
FACE = 10.2  # Centre height keeps the tilted floor above the pedal cable exit.
SLOPE = CRADLE['slope_degrees']
BEZEL_UNDER = FACE - 2.0
WALL_TOP = BEZEL_UNDER - 0.2
BED_TOP = pill.BED_TOP + FACE - pill.FACE_TOP
LENS_SEAT = -pill.FLANGE_T + FACE - pill.FACE_TOP
BOTTOM = BED_TOP - 2.4
CLIP_T = 1.2
# Move the full-thickness leaf towards the wall so the tighter contact pad
# still clears the pedal when deflected. Keep the existing housing outline.
FRONT = REAR_IN - CLIP_T
OUT_L, OUT_W = 75.7, 32.43
CAVITY_L, CAVITY_W = pill.LENGTH + 0.5, pill.WIDTH + 0.5
TRAY_X = PILL_X
TRAY_L, TRAY_W = 72.0, 19.2
CLIP_Y, CLIP_W = 20.0, 14.0
CLIP_BOTTOM = -18.0
CHANNEL_BACK = REAR + 0.15
THROAT = REAR - REAR_IN - 0.45
RIB_TIP = CHANNEL_BACK - THROAT
FIT_Y = 20.0
RIB_PROJECTION = .55


def box(x, y, z, center):
    return cq.Workplane('XY').box(x, y, z).translate(center).val()


def capsule(length, width, bottom, height):
    return pill.stadium(length, width, bottom, height).val().rotate(
        (0, 0, 0), (0, 0, 1), 90).translate((PILL_X, 0, 0))


def tilt(solid):
    return solid.rotate((PILL_X,0,FACE),(PILL_X,1,FACE),-SLOPE)


def untilt(solid):
    return solid.rotate((PILL_X,0,FACE),(PILL_X,1,FACE),SLOPE)


def platform(row):
    return cq.importers.importStep(str(REFERENCE / f'platform_{row}.step')).val()


def rim(x):
    return (x - REAR) * math.tan(math.radians(CRADLE['slope_degrees']))


def grip_rib(y):
    # Deep contact pads preload the wall against a full-height outer jaw.
    # The long inside leaf accommodates insertion with small bending strain.
    return cq.Workplane('XZ').polyline([
        (FRONT + CLIP_T, -17.7), (RIB_TIP, -16.5),
        (RIB_TIP, -14.0), (FRONT + CLIP_T, -12.8),
    ]).close().extrude(CLIP_W).val().translate((0, y + CLIP_W / 2, 0))


def outer_jaw(y):
    # The earlier outside face ended at the pill floor, allowing the housing
    # to rock around a shallow contact. Brace the same wall down to 18 mm.
    # Flare below the carrier so its solid bed remains removable.
    shoulder = PILL_X - (TRAY_W + .5)/2 - .35
    return cq.Workplane('XZ').polyline([
        (CHANNEL_BACK, -.5), (shoulder, -.5),
        (shoulder, BOTTOM-.3),
        (CHANNEL_BACK+2.4, BOTTOM-.3-(CHANNEL_BACK+2.4-shoulder)),
        (CHANNEL_BACK+2.4, CLIP_BOTTOM), (CHANNEL_BACK, CLIP_BOTTOM),
    ]).close().extrude(CLIP_W).val().translate((0, y+CLIP_W/2, 0))


def cover():
    # Make the optical housing in its own flat frame, then tip the complete
    # interface to match the cradle. The grip jaws stay vertical on the wall.
    body = capsule(OUT_L, OUT_W, BOTTOM, FACE - BOTTOM)
    body = body.cut(capsule(TRAY_L + .5, TRAY_W + .5,
                            BOTTOM-.1, BEZEL_UNDER-BOTTOM+.1))
    body = body.cut(capsule(E.LED_SLOT_W,E.LED_SLOT_H,BEZEL_UNDER-.1,2.2))
    body = body.cut(box(10,8,1.2,(PILL_X+14,0,BOTTOM+.5)))
    for side in (-1,1):
        top = BED_TOP+3
        body = body.cut(box(pill.WIRE_WIDTH,12,top-BOTTOM+.1,
                            (PILL_X,side*36,(top+BOTTOM-.1)/2)))
    body = tilt(body)
    for y in (-CLIP_Y, CLIP_Y):
        body = body.fuse(box(CLIP_T,CLIP_W,-.5-CLIP_BOTTOM,
                             (FRONT+CLIP_T/2,y,(CLIP_BOTTOM-.5)/2)))
        # This sloping neck reaches the angled shell at the widest jaw corners
        # and provides a printable transition into the vertical inside leaf.
        root = cq.Workplane('XZ').polyline([
            (FRONT+2,3), (FRONT+2.5,3),
            (FRONT+CLIP_T+.2,-.5), (FRONT,-.5),
        ]).close().extrude(CLIP_W).val().translate((0,y+CLIP_W/2,0))
        body = body.fuse(root).fuse(outer_jaw(y))
    channel = cq.Workplane('XZ').polyline([
        (FRONT+CLIP_T,-24), (CHANNEL_BACK,-24),
        (CHANNEL_BACK,rim(CHANNEL_BACK)),
        (FRONT+CLIP_T,rim(FRONT+CLIP_T)),
    ]).close().extrude(90).val().translate((0,45,0))
    body = body.cut(channel)
    for y in (-CLIP_Y,CLIP_Y):
        for edge in (y-CLIP_W/2-.4,y+CLIP_W/2+.4):
            slot = box(2.4,.8,21.5,(FRONT+.6,edge,-11.25))
            root = cq.Workplane('YZ').center(edge,-.5).circle(.4).extrude(2.4).val().translate((FRONT-.5,0,0))
            body = body.cut(slot.fuse(root))
        body = body.cut(box(2.4,CLIP_W+1.6,6,(FRONT+.6,y,CLIP_BOTTOM-3)))
        body = body.fuse(grip_rib(y))
        # Retain the 2.70 mm mouth with a short lead-in on the shifted leaf.
        edge = FRONT + CLIP_T
        entry = cq.Workplane('XZ').polyline([
            (edge-.15,CLIP_BOTTOM-.1), (edge-.15,CLIP_BOTTOM),
            (edge,CLIP_BOTTOM+.3), (edge+.1,CLIP_BOTTOM+.3),
            (edge+.1,CLIP_BOTTOM-.1),
        ]).close().extrude(CLIP_W+.2).val().translate((0,y+(CLIP_W+.2)/2,0))
        body = body.cut(entry)
    return body.cut(cable_clearance()).clean()


def fit_rib(side, y):
    """Solid tapered contact rib; no hook, undercut or bending arm."""
    root = TRAY_W/2-.1
    tip = TRAY_W/2+RIB_PROJECTION
    body = cq.Workplane('XY').polyline([
        (TRAY_X+side*root,y-1.5), (TRAY_X+side*tip,y),
        (TRAY_X+side*root,y+1.5),
    ]).close().extrude(WALL_TOP-BOTTOM).translate((0,0,BOTTOM)).val()
    ramp = cq.Workplane('XZ').polyline([
        (TRAY_X+side*root,BOTTOM+.4),
        (TRAY_X+side*tip,BOTTOM+1.2),
        (TRAY_X+side*tip,WALL_TOP-2),
        (TRAY_X+side*root,WALL_TOP-.4),
    ]).close().extrude(4).val().translate((0,y+2,0))
    return body.intersect(ramp)


def base():
    # One printed carrier: uninterrupted 2.4 mm floor, strip-locating walls,
    # and a ledge directly under the white flange. No separate tray or glue
    # joint is needed to support the diffuser.
    body = capsule(TRAY_L, TRAY_W, BOTTOM, WALL_TOP-BOTTOM)
    body = body.cut(capsule(pill.LENGTH-2*pill.CARRIER_WALL,
                            pill.WIDTH-2*pill.CARRIER_WALL,
                            BED_TOP, LENS_SEAT-BED_TOP+.01))
    body = body.cut(capsule(CAVITY_L, CAVITY_W, LENS_SEAT, WALL_TOP-LENS_SEAT+.1))
    for side in (-1, 1):
        for end in (-1, 1):
            body = body.fuse(fit_rib(side, end*FIT_Y))
        # Open to the rim so a soldered strip drops in without threading its
        # connectors. The cut begins beyond the full strip-support footprint.
        bottom, top = BED_TOP-1.7, WALL_TOP+.1
        body = body.cut(box(pill.WIRE_WIDTH, 12, top-bottom,
                            (PILL_X, side*36, (top+bottom)/2)))
    return body.clean()


def cable_clearance():
    # Preserve the current release's closed stadium and its rearward cable
    # route. The highest top across both row references governs this opening.
    top = max(r['cable_top_local_z_mm'] for r in CRADLE['rows'].values())+.3
    return box(35, CRADLE['cable_opening_width_mm']+.6, top-(BOTTOM-5),
               (PILL_X, 0, (top+BOTTOM-5)/2))


def parts():
    return {'cover': cover(), 'base': tilt(base())}


def placed_pill():
    return {name: tilt(solid.rotate((0, 0, 0), (0, 0, 1), 90).translate(
        (PILL_X, 0, FACE - pill.FACE_TOP))) for name, solid in pill.build().items()
        if name == 'diffuser'}


def fit_samples(models):
    # One complete platform jaw pair plus one pair of housing contact ribs.
    # This is a local fit check, not a strength test of the complete housing.
    section = box(50,16,40,(PILL_X,FIT_Y,-2))
    sample_cover = models['cover'].intersect(section)
    # Closing only the optical slot keeps this cut section in one piece.
    # The mating cavity and both platform jaws retain their actual geometry.
    sample_cover = sample_cover.fuse(tilt(box(8,16,2,(PILL_X,FIT_Y,FACE-1))))
    return {'cover':sample_cover.clean(), 'base':models['base'].intersect(section).clean()}


def print_orientation(name, solid):
    # Flatten the optical frame first; the mounting jaws remain angled in
    # the print pose. Cover bezel down; carrier floor down.
    solid = untilt(solid)
    if name == 'cover':
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 180)
    b = solid.BoundingBox()
    return solid.translate((-(b.xmin + b.xmax) / 2, -(b.ymin + b.ymax) / 2, -b.zmin))


def export():
    models = parts()
    for name, solid in {**models, **{f'fit_sample_{n}':s for n,s in fit_samples(models).items()}}.items():
        stem = OUT / f'pill_top_mount_{name}'
        oriented = print_orientation('cover' if name.endswith('cover') else 'base', solid)
        cq.exporters.export(oriented, str(stem.with_suffix('.step')))
        cq.exporters.export(oriented, str(stem.with_suffix('.stl')), tolerance=0.03, angularTolerance=0.1)
    for row in ('front', 'mid'):
        cradle = platform(row)
        z = cradle.BoundingBox().zmax
        assembly = cq.Assembly(name=f'pill_top_mount_{row}')
        assembly.add(cradle, name='existing_cradle', color=cq.Color(0.22, 0.23, 0.25))
        for name, solid in models.items():
            assembly.add(solid.translate((0, 0, z)), name=name, color=cq.Color(0.075, 0.08, 0.085))
        for name, solid in placed_pill().items():
            color = (0.94, 0.93, 0.89) if name == 'diffuser' else (0.09, 0.10, 0.11)
            assembly.add(solid.translate((0, 0, z)), name=f'existing_{name}', color=cq.Color(*color))
        assembly.export(str(OUT / f'pill_top_mount_assembly_{row}.step'))
    for path in OUT.glob('pill_top_mount_*.step'):
        path.write_text('\n'.join(line.rstrip() for line in path.read_text().splitlines()) + '\n')


def pack():
    files = [OUT / f'pill_top_mount_{name}.{ext}' for name in ('cover', 'base') for ext in ('stl', 'step')]
    files += [OUT / f'pill_top_mount_fit_sample_{name}.{ext}' for name in ('cover', 'base') for ext in ('stl', 'step')]
    files += [OUT / f'tall_pill_diffuser.{ext}' for ext in ('stl', 'step')]
    files += [OUT / f'pill_top_mount_assembly_{row}.step' for row in ('front', 'mid')]
    files += [Path(__file__).with_name('PLATFORM_MOUNT.md')]
    preview = OUT / 'pill_top_mount_preview.png'
    if preview.exists():
        files.append(preview)
    with ZipFile(OUT / 'pill_friction_mount_print_pack.zip', 'w', ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, 'pill-friction-mount/' + path.name)


if __name__ == '__main__':
    export()
    pack()
    print('Exported the cover, walled LED carrier and two current cradle reference assemblies.')
