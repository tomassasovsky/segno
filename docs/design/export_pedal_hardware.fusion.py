"""Export Segno's ten assembled pedals from the active populated Fusion model.

Run through Fusion's script API with an orthographic viewport. Visibility and
camera are restored; this does not change geometry, appearances, references,
or save the CAD document.
"""

import json
from pathlib import Path

import adsk.core
import adsk.fusion


def run(_context: str):
    app = adsk.core.Application.get()
    assert app.activeDocument.name == "VAMP console (populated)"
    design = adsk.fusion.Design.cast(app.activeProduct)
    viewport = app.activeViewport
    output = Path(_context)
    output.mkdir(parents=True, exist_ok=True)
    roots = list(design.rootComponent.occurrences)
    pedals = [
        occurrence for occurrence in design.rootComponent.allOccurrences
        if occurrence.fullPathName.startswith("pedals:1+Cherub WTB-006 Footswitch:")
        and occurrence.fullPathName.count("+") == 1
    ]
    labels = ["REC_PLAY", "STOP", "UNDO", "MODE", "TRACK1", "TRACK2",
              "TRACK3", "TRACK4", "CLEAR", "BANK"]
    original_visibility = [(o, o.isLightBulbOn) for o in roots + pedals]
    original = viewport.camera
    assert original.cameraType == adsk.core.CameraTypes.OrthographicCameraType, (
        "Select an orthographic view before exporting pedal references."
    )
    restore = adsk.core.Camera.create()
    restore.cameraType = original.cameraType
    restore.eye = original.eye
    restore.target = original.target
    restore.upVector = original.upVector
    restore.isSmoothTransition = False
    restore.isFitView = False
    _, width, height = original.getExtents()
    restore.setExtents(width, height)
    manifest = []
    try:
        for index, label in enumerate(labels, 1):
            target = next(o for o in pedals if o.name == f"Cherub WTB-006 Footswitch:{index}")
            tile_name = f"tile_{label}:1"
            assert any(o.name == tile_name for o in roots)
            for occurrence in roots:
                occurrence.isLightBulbOn = occurrence.name in ["pedals:1", tile_name]
            for occurrence in pedals:
                occurrence.isLightBulbOn = occurrence == target
            bounds = target.boundingBox
            center = adsk.core.Point3D.create(
                (bounds.minPoint.x + bounds.maxPoint.x) / 2,
                (bounds.minPoint.y + bounds.maxPoint.y) / 2,
                (bounds.minPoint.z + bounds.maxPoint.z) / 2,
            )
            camera = adsk.core.Camera.create()
            camera.cameraType = adsk.core.CameraTypes.OrthographicCameraType
            camera.eye = adsk.core.Point3D.create(center.x, center.y, center.z + 50)
            camera.target = center
            camera.upVector = adsk.core.Vector3D.create(0, 1, 0)
            camera.isSmoothTransition = False
            camera.isFitView = False
            camera.setExtents(9.6, 12.8)
            viewport.camera = camera
            viewport.refresh()
            adsk.doEvents()
            filename = label.lower() + ".png"
            options = adsk.core.SaveImageFileOptions.create(str(output / filename))
            options.width = 720
            options.height = 960
            options.isBackgroundTransparent = True
            options.isAntiAliased = True
            assert viewport.saveAsImageFileWithOptions(options)
            manifest.append({"file": filename, "pedal": target.fullPathName, "nameplate": tile_name})
    finally:
        for occurrence, visible in original_visibility:
            occurrence.isLightBulbOn = visible
        viewport.camera = restore
        viewport.refresh()
    assert all(o.isLightBulbOn == visible for o, visible in original_visibility)
    (output / "manifest.json").write_text(json.dumps({
        "source": app.activeDocument.name,
        "projection": "Orthographic top view of assembled pedal and raised nameplate",
        "size": [720, 960],
        "assets": manifest,
    }, indent=2) + "\n")
    print(json.dumps({"exported": len(manifest), "visibilityRestored": True}))
