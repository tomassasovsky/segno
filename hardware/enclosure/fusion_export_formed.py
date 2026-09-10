"""Fusion script: export verified native formed parts for the shop generator.

Run segno_enclosure.py --no-step first, synchronize the Fusion model, then run
this script with the populated console active. It compares imported vent, bend
and deferred-drill curves with the current DXF handoff, plus the lid and both bracket cut
curves. The lid's CUT/DRILL union permits an existing nominal hole to move to a
secondary operation. Every part exports its final unfolded contours; the base's
construction sketch precedes the corner trims. Finally run the full enclosure
generator; CadQuery compares all final flats with CUT/VENT/DRILL geometry and
validates the exported solids.
"""
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _point(p):
    return [round(p.x*10,4)+0.0, round(p.y*10,4)+0.0]


def _sketch_curves(component, layers):
    result = {}
    for layer in layers:
        sketch = component.sketches.itemByName(layer)
        assert sketch, f"{component.name}: missing {layer} sketch"
        rows = []
        # Preserve obsolete profile edges as construction references in Fusion.
        # Only actual CUT geometry must match the current cutting file; BEND
        # construction lines remain part of the explicit forming contract.
        used = lambda curve: layer != "CUT" or not curve.isConstruction
        for line in sketch.sketchCurves.sketchLines:
            if not used(line): continue
            ends = sorted([_point(line.startSketchPoint.geometry),_point(line.endSketchPoint.geometry)])
            if ends[0] != ends[1]: rows.append(["L",ends])
        for circle in sketch.sketchCurves.sketchCircles:
            if not used(circle): continue
            rows.append(["C",_point(circle.centerSketchPoint.geometry),round(circle.radius*10,4)])
        for arc in sketch.sketchCurves.sketchArcs:
            if not used(arc): continue
            evaluator = arc.geometry.evaluator
            ok, start, end = evaluator.getParameterExtents()
            assert ok
            ok, mid = evaluator.getPointAtParameter((start+end)/2)
            assert ok
            rows.append(["A",sorted([_point(arc.startSketchPoint.geometry),
                                     _point(arc.endSketchPoint.geometry)]),_point(mid)])
        assert len(rows) == sum(used(curve) for curve in sketch.sketchCurves), (
            f"{component.name}: unsupported sketch curve")
        result[layer] = sorted(rows,key=json.dumps)
    return result


def _native_forming(component, occurrence):
    import adsk.core
    import adsk.fusion
    rule = component.activeSheetMetalRule
    folds = []
    for feature in component.features.foldFeatures:
        for bend in feature.bendLines:
            assert bend.linePosition == adsk.fusion.FoldBendLinePositionTypes.CenterFoldBendLinePositionType
            line = bend.bendLine
            assert line.parentSketch.name == "BEND"
            ends = sorted([_point(line.startSketchPoint.geometry),_point(line.endSketchPoint.geometry)])
            folds.append({"line":["L",ends],"angle_deg":math.degrees(bend.bendAngle.value)})
    drill = []
    if component.name in ("base","faceplate"):
        for face in occurrence.bRepBodies.item(0).faces:
            cylinder = adsk.core.Cylinder.cast(face.geometry)
            if not cylinder or abs(cylinder.axis.y)<.999999 or face.pointOnFace.y>=0:
                continue
            ys = [vertex.geometry.y*10 for vertex in face.vertices]
            # Corner relief arcs also have Y axes; only closed through-holes
            # have the full cylindrical area between the two panel faces.
            full_area = 2*math.pi*cylinder.radius*10*(max(ys)-min(ys))
            if abs(face.area*100-full_area)>.0001:
                continue
            drill.append([cylinder.origin.x*10,cylinder.origin.z*10,
                          cylinder.radius*10,min(ys),max(ys)])
    return {"rule":{"thickness_mm":rule.thickness.value*10,
                    "radius_mm":rule.bendRadius.value*10,"k_factor":rule.kFactor},
            "folds":folds,"front_drill":drill}


def _validate_sketch_curves(stem, expected, actual):
    for layer, curves in expected.items():
        if stem == "segno_faceplate" and layer == "DRILL":
            continue
        found = actual[layer]
        if stem == "segno_faceplate" and layer == "CUT":
            curves = sorted(curves+expected["DRILL"], key=json.dumps)
            found = sorted(found+actual["DRILL"], key=json.dumps)
        assert found == curves, f"{stem}: {layer} sketch differs from the current DXF"


def _validate_forming(expected, actual):
    """Reject a correct sketch attached to a wrongly folded or drilled body."""
    for key, value in expected["rule"].items():
        assert abs(actual["rule"][key]-value)<1e-7, f"sheet rule differs: {key}"
    sort_fold = lambda fold: json.dumps(fold["line"])
    assert len(actual["folds"]) == len(expected["folds"]), "fold count differs"
    for wanted, found in zip(sorted(expected["folds"],key=sort_fold),
                             sorted(actual["folds"],key=sort_fold)):
        assert found["line"] == wanted["line"], "fold source line differs"
        assert abs(found["angle_deg"]-wanted["angle_deg"])<.0001, "fold angle/direction differs"
    wanted_drill, found_drill = sorted(expected["front_drill"]), sorted(actual["front_drill"])
    assert len(found_drill) == len(wanted_drill), "formed drill count differs"
    for wanted, found in zip(wanted_drill,found_drill):
        assert all(abs(a-b)<.005 for a,b in zip(wanted,found)), "formed drill axis/radius/span differs"


def run(_context):
    import adsk.core
    import adsk.fusion
    app = adsk.core.Application.get()
    assert app.activeDocument.name == "VAMP console (populated)", "Activate the populated console"
    design = adsk.fusion.Design.cast(app.activeProduct)
    expected = json.loads((HERE/"out/fusion_formed_input.json").read_text())
    directory = HERE/"formed"
    directory.mkdir(exist_ok=True)
    manifest = {}
    names = {"segno_base":"base", "segno_faceplate":"faceplate",
             "segno_corner_bracket_rear":"corner_bracket",
             "segno_corner_bracket_rear_mirrored":"corner_bracket_mirrored"}
    assert set(expected) == set(names), "formed handoff part set differs from the exporter"
    # Validate the whole set before writing any output.
    parts = {}
    for stem, name in names.items():
        occurrences = [o for o in design.rootComponent.allOccurrences if o.component.name == name]
        assert len(occurrences) == 1, (stem,len(occurrences))
        component = occurrences[0].component
        body = component.bRepBodies.item(0)
        assert component.bRepBodies.count == 1 and body.isSheetMetal, stem
        for feature in component.features:
            assert feature.healthState == adsk.fusion.FeatureHealthStates.HealthyFeatureHealthState, (stem,feature.name,feature.errorOrWarningMessage)
        # The base is trimmed after its first extrusion. Its final CUT contour
        # is verified from the actual unfolded body by the generator below.
        layers = {layer: curves for layer, curves in expected[stem]["curves"].items()
                  if stem != "segno_base" or layer != "CUT"}
        actual = _sketch_curves(component,layers)
        _validate_sketch_curves(stem,layers,actual)
        if name in ("base","faceplate"):
            drill = component.sketches.itemByName("FRONT_DRILL_AFTER_FORMING")
            assert drill and drill.sketchCurves.sketchCircles.count == 9, f"{stem}: missing formed drilling"
        forming = _native_forming(component,occurrences[0])
        _validate_forming(expected[stem],forming)
        parts[stem] = (component,occurrences,forming)
    for stem,(component,occurrences,forming) in parts.items():
        path = directory/(stem+".step")
        # Fusion omits a hidden occurrence even when exporting that component.
        visible = [(o,o.isLightBulbOn) for o in occurrences]
        visible += [(b,b.isLightBulbOn) for b in component.bRepBodies]
        try:
            for entity,_ in visible:
                entity.isLightBulbOn = True
            assert design.exportManager.execute(design.exportManager.createSTEPExportOptions(str(path),component)), stem
        finally:
            for entity,was_visible in visible:
                entity.isLightBulbOn = was_visible
        placements = []
        for occurrence in occurrences:
            values = occurrence.transform2.asArray()
            matrix = [list(values[i:i+4]) for i in range(0,16,4)]
            for row in matrix[:3]: row[3] *= 10
            placements.append(matrix)
        manifest[stem] = {"flat_sha256":expected[stem]["flat_sha256"],
                          "forming":forming,
                          "step_sha256":hashlib.sha256(path.read_bytes()).hexdigest(),
                          "placements_mm":placements,
                          "volume_mm3":component.bRepBodies.item(0).getPhysicalProperties(
                              adsk.fusion.CalculationAccuracy.VeryHighCalculationAccuracy).volume*1000,
                          "bounds_mm":[[v*10 for v in point.asArray()] for point in
                              (component.bRepBodies.item(0).preciseBoundingBox.minPoint,
                               component.bRepBodies.item(0).preciseBoundingBox.maxPoint)]}
    # Keep existing flat patterns and their dependencies. The verified lid flat
    # uses the underside (opposite the drawing's exterior); new flats use that
    # same prescribed face. A changed existing view must fail parity rather than
    # silently searching for a mirrored match.
    for stem,(component,_,_) in parts.items():
        body = component.bRepBodies.item(0)
        opposite = stem == "segno_faceplate"
        face_z = -component.activeSheetMetalRule.thickness.value if opposite else 0
        faces = []
        for face in body.faces:
            plane = adsk.core.Plane.cast(face.geometry)
            if not plane or abs(face.pointOnFace.z-face_z) > 1e-5:
                continue
            normal_z = plane.normal.z * (-1 if face.isParamReversed else 1)
            if abs(normal_z - (-1 if opposite else 1)) < 1e-7:
                faces.append(face)
        assert faces, f"{stem}: prescribed flat-pattern reference face missing"
        stationary = max(faces, key=lambda face: face.area)
        flat = component.flatPattern or component.createFlatPattern(stationary)
        flat_path = directory/(stem+"_flat.dxf")
        options = design.exportManager.createDXFFlatPatternExportOptions(str(flat_path),flat)
        options.isCenterLinesExported = False
        options.isExtentLinesExported = False
        assert design.exportManager.execute(options), f"{stem}: flat-pattern export failed"
        manifest[stem]["flat_pattern_sha256"] = hashlib.sha256(flat_path.read_bytes()).hexdigest()
        manifest[stem]["flat_pattern_drawn_face"] = "opposite" if opposite else "same"
    (directory/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print("Verified formed exports: "+", ".join(manifest))
