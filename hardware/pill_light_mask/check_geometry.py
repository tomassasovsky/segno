"""Check actual solids, glue support, wiring access, and print orientation."""

import json

import cadquery as cq

import tall_pill as p


def box(length, width, height, center):
    return cq.Workplane("XY").box(length, width, height).translate(center).val()


def check(parts):
    for name, solid in parts.items():
        assert solid.isValid() and len(solid.Solids()) == 1, name
        assert solid.Volume() > 0, name
        printed = p.print_orientation(name, solid)
        bounds = printed.BoundingBox()
        assert abs(bounds.zmin) < 1e-6, name
        assert bounds.xlen < 220 and bounds.ylen < 220 and bounds.zlen < 250
        # Each slice must be supported, except the diffuser's short roof bridge.
        slab = box(100, 100, 0.01, (0, 0, 0.025))
        footprint = printed.intersect(slab).Volume() / 0.01
        assert footprint > 150, (name, footprint)
        for step in range(1, int(bounds.zlen / 0.2)):
            lower = printed.intersect(slab.translate((0, 0, step * 0.2 - 0.2)))
            upper = printed.intersect(slab.translate((0, 0, step * 0.2)))
            unsupported = upper.cut(lower.translate((0, 0, 0.2)))
            if name == "diffuser" and unsupported.Volume() > 1e-6:
                bridge = p.stadium(
                    p.LENS_LENGTH - 2 * p.CAP_WALL,
                    p.LENS_WIDTH - 2 * p.CAP_WALL,
                    p.FACE_UNDER + p.FLANGE_T, p.FACE_T,
                ).val()
                assert p.LENS_WIDTH - 2 * p.CAP_WALL <= 4.2 + 1e-6
                unsupported = unsupported.cut(bridge)
            assert unsupported.Volume() < 1e-6, name

    names = list(parts)
    for index, name in enumerate(names):
        for other in names[index + 1:]:
            assert parts[name].intersect(parts[other]).Volume() < 1e-6

    # Full contact even at the enclosure's maximum allowed scissor-cut length.
    support = box(p.enclosure.LED_CH_L, p.STRIP_WIDTH, p.BASE_T,
                  (0, 0, p.BASE_BOTTOM + p.BASE_T / 2))
    assert support.cut(parts["base"]).Volume() < 1e-6
    pcb = box(p.enclosure.LED_CH_L, p.STRIP_WIDTH, p.enclosure.LED_STRIP_T,
              (0, 0, p.BED_TOP + p.ADHESIVE_T + p.enclosure.LED_STRIP_T / 2))
    assert pcb.intersect(parts["base"]).Volume() < 1e-6
    assert pcb.intersect(parts["diffuser"]).Volume() < 1e-6
    assert pcb.intersect(parts["mask"]).Volume() < 1e-6
    # Base and cap can move in opposite directions inside the slip-fit mask.
    # Check a conservative box of relative offsets, including diagonal corners,
    # so the cap cannot transfer any of its load to the glued PCB's edges.
    play = 2 * p.FIT_CLEARANCE
    for dx in (-play, 0, play):
        for dy in (-play, 0, play):
            moved_cap = parts["diffuser"].translate((dx, dy, 0))
            assert pcb.intersect(moved_cap).Volume() < 1e-6, (dx, dy)

    for index in range(8):
        x = (index - 3.5) * p.enclosure.LED_STRIP_PITCH
        package = box(5, 5, p.enclosure.LED_PKG_H,
                      (x, 0, p.LED_TOP - p.enclosure.LED_PKG_H / 2))
        light_path = box(5, 4, p.AIR_GAP, (x, 0, p.LED_TOP + p.AIR_GAP / 2))
        for solid in parts.values():
            assert solid.intersect(package).Volume() < 1e-6
            assert solid.intersect(light_path).Volume() < 1e-6

    # Each outlet clears a bundle 7 mm wide and 2 mm high after it bends down
    # beyond the strip's solder pads. This is a routing envelope, not strain relief.
    for direction in (-1, 1):
        cable = box(10, 7, 2, (direction * (p.WIRE_START + 5), 0, p.BASE_BOTTOM + 1.9))
        for solid in parts.values():
            assert solid.intersect(cable).Volume() < 1e-6

    # The mask can be lifted off; no clips or hidden undercuts trap the cap.
    for lift in (0.2, 2, 6, 12):
        raised = parts["mask"].translate((0, 0, lift))
        for name in ("base", "diffuser"):
            assert raised.intersect(parts[name]).Volume() < 1e-6

    # The same lens/carrier mounts under the metal after removing the collar.
    panel = p.panel_reference()
    assert abs(parts["diffuser"].BoundingBox().zmax - panel.BoundingBox().zmax) < 1e-6
    assert abs(parts["mask"].BoundingBox().zmax - panel.BoundingBox().zmax) < 1e-6
    for name in ("base", "diffuser"):
        assert panel.intersect(parts[name]).Volume() < 1e-6
    # A 0.01 mm push into the sheet contacts all four seating pads: positive
    # mechanical stops hold the 0.2 mm bond line rather than relying on glue.
    contact = panel.intersect(parts["diffuser"].translate((0, 0, 0.01)))
    assert abs(contact.Volume() - 4 * 8 * 1.2 * 0.01) < 1e-5
    for drop in (0.2, 2, 6, 12):
        assert panel.intersect(parts["diffuser"].translate((0, 0, -drop))).Volume() < 1e-6
    # Keep everything below the panel inside the original mounting footprint.
    envelope = p.stadium(p.LENGTH, p.WIDTH, p.BASE_BOTTOM, -p.BASE_BOTTOM).val()
    lower = box(100, 100, -p.BASE_BOTTOM, (0, 0, p.BASE_BOTTOM / 2))
    for name in ("base", "diffuser"):
        assert parts[name].intersect(lower).cut(envelope).Volume() < 1e-6

    return {
        "valid_single_solids": 3,
        "part_interference_mm3": 0,
        "full_strip_support_mm": [p.enclosure.LED_CH_L, p.STRIP_WIDTH],
        "base_thickness_mm": p.BASE_T,
        "air_gap_mm": p.AIR_GAP,
        "face_thickness_mm": p.FACE_T,
        "cap_to_base_relative_play_checked_mm": play,
        "bench_assembly_mm": [round(v, 2) for v in (
            parts["mask"].BoundingBox().xlen,
            parts["mask"].BoundingBox().ylen, p.MASK_TOP - p.BASE_BOTTOM)],
        "sheet_thickness_mm": p.PANEL_T,
        "lens_to_sheet_step_mm": 0,
        "depth_below_sheet_mm": round(p.MOUNT_GAP - p.BASE_BOTTOM, 2),
        "print_orientation": "carrier floor down; lens flange down; collar face down",
        "optical_roof_bridge_mm": p.LENS_WIDTH - 2 * p.CAP_WALL,
        "physical_fit_and_light_leakage": "not established by geometry checks",
    }


if __name__ == "__main__":
    parts = p.build()
    result = check(parts)
    # Round-trip the delivered STEP files as well as checking constructed solids.
    for name, expected in parts.items():
        actual = cq.importers.importStep(str(p.OUT / f"tall_pill_{name}.step")).val()
        assert actual.isValid() and len(actual.Solids()) == 1
        assert expected.cut(actual).Volume() + actual.cut(expected).Volume() < 1e-5
    print(json.dumps(result, indent=2))
