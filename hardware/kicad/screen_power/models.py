"""Fail closed when a populated component cannot appear in the 3D assembly."""
from pathlib import Path


def check_models(board, project_dir, errors):
    covered = []
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        if ref.startswith("H"):
            continue  # Bare mounting holes intentionally have no solid body.
        models = list(fp.Models())
        reason = None
        if not models:
            reason = "no assigned 3D model"
        for model in models:
            path = Path(model.m_Filename.replace("${KIPRJMOD}", str(project_dir)))
            if not model.m_Show:
                reason = "3D model is disabled"
            elif not path.is_file():
                reason = "3D model file does not resolve: " + model.m_Filename
            elif not path.read_bytes().startswith(b"ISO-10303-21;"):
                reason = "3D model is not a STEP file: " + path.name
            elif min(model.m_Scale.x, model.m_Scale.y, model.m_Scale.z) <= 0:
                reason = "3D model has invalid scale"
        if reason:
            errors.append({"check": "model_coverage", "detail": ref + ": " + reason})
        else:
            covered.append(ref)
    return {"populated": len(covered), "references": sorted(covered)}
