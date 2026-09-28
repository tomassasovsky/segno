#!/usr/bin/env python3
"""Read-only independent console/ring CAM audit; requires Python 3.9+ and Git.

python verify_console_ring.py --repo REPOSITORY --output REPORT.json

Fresh CLI exports go into an automatically removed temporary directory. No
board, project, package, or repository source is saved or regenerated in place.
The JSON report is written on success AND failure. Do not infer acceptance from
its existence: require passed=true and matching final board/archive hashes.
Tracked loose CAM, the published ZIP, and a fresh export must all agree except
for the existing strict timestamp normalization. Missing or extra CAM fails.
"""
# cspell:words gbrjob gmtime protel soldermask sklib
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from time import gmtime, strftime
import zipfile


CONFIGS = {
    "console": {
        "board": "out_console/segno_console_board.kicad_pcb",
        "project": "out_console/segno_console_board.kicad_pro",
        "netlist": "console_board.net", "pads": 206,
        "zip": "fab/segno_console_v3_gerbers.zip",
        "loose": "out_console",
        "layers": ["F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste",
                   "F.Silkscreen", "B.Silkscreen", "Edge.Cuts"],
        "mask": "R80G0B80", "legend": "White", "members": 12,
    },
    "ring": {
        "board": "segno_pedal_ring.kicad_pcb",
        "project": "segno_pedal_ring.kicad_pro",
        "netlist": "ring_board.net", "pads": 63,
        "zip": "fab/segno_pedal_ring_gerbers.zip",
        "loose": "out_ring/gerbers",
        "layers": ["F.Cu", "B.Cu", "F.Mask", "B.Mask",
                   "F.Silkscreen", "B.Silkscreen", "Edge.Cuts"],
        "mask": "White", "legend": "Black", "members": 10,
    },
}
JOB_FUNCTIONS = {
    "F_Cu": "Copper,L1,Top", "B_Cu": "Copper,L2,Bot",
    "F_Mask": "SolderMask,Top", "B_Mask": "SolderMask,Bot",
    "F_Paste": "SolderPaste,Top", "B_Paste": "SolderPaste,Bot",
    "F_Silkscreen": "Legend,Top", "B_Silkscreen": "Legend,Bot",
    "Edge_Cuts": "Profile",
}
GERBER_FUNCTIONS = dict(JOB_FUNCTIONS, F_Mask="Soldermask,Top",
                        B_Mask="Soldermask,Bot", Edge_Cuts="Profile,NP",
                        F_Paste="Paste,Top", B_Paste="Paste,Bot")

NATIVE_READER = r'''
import json,sys
from pathlib import Path
import pcbnew as p
sys.path.insert(0,sys.argv[1])
from netlist import parse_netlist
board=p.LoadBoard(sys.argv[2])
components,nets=parse_netlist(sys.argv[3])
want={ref+'.'+str(pin):net for net,nodes in nets.items()
      for ref,pin in nodes if ref in components}
got={};duplicates=[]
for f in board.GetFootprints():
    for pad in f.Pads():
        if not pad.GetNumber() or not pad.GetNetname():continue
        key=f.GetReference()+'.'+pad.GetNumber()
        if key in got and got[key]!=pad.GetNetname():duplicates.append(key)
        got[key]=pad.GetNetname()
result={'expected_pad_map':want,'native_pad_map':got,
        'conflicting_duplicate_pads':duplicates,
        'copper_layers':board.GetCopperLayerCount(),
        'board_thickness_mm':board.GetDesignSettings().GetBoardThickness()/1e6}
print('AUDIT_JSON:'+json.dumps(result,sort_keys=True))
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def strict_normalizers(helper_bytes):
    """Execute the existing two strict helpers without importing PDF support.

    Their bodies and timestamp expression come directly from the reviewed
    verifier; this script neither copies nor broadens normalization rules.
    The complete helper file is hashed before execution and checked at exit.
    """
    tree = ast.parse(helper_bytes)
    selected = []
    names = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in {"read_json", "normalize_cam"}:
            selected.append(node)
            names.append(node.name)
        elif isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "ISO_DATE" for t in node.targets):
            selected.append(node)
            names.append("ISO_DATE")
    if sorted(names) != ["ISO_DATE", "normalize_cam", "read_json"]:
        raise ValueError("Expected strict normalization definitions absent")
    namespace = {"json": json, "re": re}
    exec(compile(ast.Module(body=selected, type_ignores=[]),
                 "reviewed-normalize-cam-helper", "exec"), namespace)
    return namespace["read_json"], namespace["normalize_cam"]


def git_paths(repo, include_untracked=False):
    """Include new shared helpers before they are committed, excluding ignores."""
    command = ["git", "ls-files", "-z", "--cached"]
    if include_untracked:
        command += ["--others", "--exclude-standard"]
    result = subprocess.run(command + ["--", "hardware/kicad"], cwd=repo,
                            capture_output=True, timeout=30, check=True)
    return {Path(name.decode("utf-8")) for name in result.stdout.split(b"\0") if name}


def source_inventory(repo):
    base = repo / "hardware/kicad"
    paths = set()
    for pattern in ("*.py", "*.sh", "*.net", "*.kicad_pro", "*.kicad_dru"):
        paths.update(p for p in base.glob(pattern) if not p.name.endswith("_sklib.py"))
    # Shared routing helpers may live below hardware/kicad rather than its root.
    # Discover both tracked and new, non-ignored Python/shell inputs recursively.
    paths.update(repo / p for p in git_paths(repo, include_untracked=True)
                 if p.suffix in {".py", ".sh"} and not p.name.endswith("_sklib.py"))
    paths.update(p for p in (base / "segno.pretty").rglob("*.kicad_mod"))
    for c in CONFIGS.values():
        paths.add(base / c["board"])
        paths.add(base / c["project"])
        rules = (base / c["board"]).with_suffix(".kicad_dru")
        if rules.exists():paths.add(rules)
    for p in (base / "fp-lib-table", base / "sym-lib-table"):
        if p.exists():paths.add(p)
    paths.add(repo / "docs/reviews/screen-power-rev-l-1072/verify_fabrication.py")
    result = {}
    for path in sorted(paths):
        if path.is_symlink():raise ValueError("Symlink in production inputs")
        result[path.relative_to(repo).as_posix()] = sha(path.read_bytes())
    return result


def loose_inventory(repo):
    """Hash every loose manufacturing file, including unexpected additions."""
    result = {}
    for cfg in CONFIGS.values():
        folder = repo / "hardware/kicad" / cfg["loose"]
        if folder.is_symlink():
            raise ValueError("Symlink in loose CAM directory")
        for path in sorted(folder.iterdir()):
            if path.suffix not in {".gbr", ".gbrjob", ".drl"}:
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError("Non-regular loose CAM input: " + path.name)
            result[path.relative_to(repo).as_posix()] = sha(path.read_bytes())
    return result


class Audit:
    def __init__(self):
        self.checks = []
        self.commands = []

    def check(self, passed, name, detail):
        self.checks.append({"check": name, "detail": detail, "passed": bool(passed)})
        return bool(passed)

    def command(self, args, name, cwd, timeout=180):
        result = subprocess.run(list(map(str, args)), cwd=cwd, text=True,
                                capture_output=True, timeout=timeout)
        self.commands.append({"command": name, "returncode": result.returncode})
        return result


def run_board(name, cfg, args, folder, audit, read_json, normalize):
    base = args.repo / "hardware/kicad"
    board = base / cfg["board"]
    archive = base / cfg["zip"]
    stem = board.stem
    layers = [x.replace(".", "_") for x in cfg["layers"]]
    expected = {stem + "-" + x + ".gbr" for x in layers}
    expected.update({stem + "-PTH.drl", stem + "-NPTH.drl", stem + "-job.gbrjob"})
    result = {"board": board.relative_to(args.repo).as_posix(),
              "zip": archive.relative_to(args.repo).as_posix(),
              "board_sha256": sha(board.read_bytes()),
              "expected_inventory": sorted(expected)}
    loose = base / cfg["loose"]
    loose_relative = loose.relative_to(args.repo)
    tracked_names = {p.name for p in args.tracked_paths if p.parent == loose_relative
                     and p.suffix in {".gbr", ".gbrjob", ".drl"}}
    audit.check(tracked_names == expected, "tracked_loose_cam_inventory", name)
    loose_names = {p.name for p in loose.iterdir()
                   if p.suffix in {".gbr", ".gbrjob", ".drl"}}
    audit.check(loose_names == expected, "loose_cam_inventory", name)
    native = audit.command([args.kicad_python, "-c", NATIVE_READER, base,
                            board, base / cfg["netlist"]], name + ":native-read", base)
    if audit.check(native.returncode == 0, "native_reader_exit", name):
        records = [line[11:] for line in native.stdout.splitlines()
                   if line.startswith("AUDIT_JSON:")]
        if audit.check(len(records) == 1, "native_reader_result", name):
            data = read_json(records[0])
            result["native"] = data
            audit.check(data["expected_pad_map"] == data["native_pad_map"],
                        "exact_netlist_pad_parity", name)
            audit.check(len(data["expected_pad_map"]) == len(data["native_pad_map"]) == cfg["pads"],
                        "connected_pad_count", name)
            audit.check(not data["conflicting_duplicate_pads"], "duplicate_pad_consistency", name)
            audit.check(data["copper_layers"] == 2, "native_copper_layers", name)
            audit.check(data["board_thickness_mm"] == 1.6, "native_board_thickness", name)

    report = folder / "drc.json"
    drc = audit.command([args.kicad_cli, "pcb", "drc", "--refill-zones", "--format", "json",
                         "--severity-all", "--all-track-errors", "--exit-code-violations",
                         "-o", report, board], name + ":drc", base)
    audit.check(drc.returncode == 0, "native_drc_exit", name)
    if audit.check(report.is_file(), "native_drc_report", name):
        data = read_json(report.read_bytes())
        result["drc"] = {k: data[k] for k in
                         ("included_severities", "ignored_checks", "violations", "unconnected_items")}
        audit.check(set(data["included_severities"]) == {"error", "warning", "exclusion"},
                    "native_drc_all_severities", name)
        audit.check(data["violations"] == [], "native_drc_no_violations", name)
        audit.check(data["unconnected_items"] == [], "native_drc_no_unconnected", name)

    cam = folder / "cam"
    cam.mkdir()
    gerbers = audit.command([args.kicad_cli, "pcb", "export", "gerbers", "--no-protel-ext",
                            "--check-zones", "--layers", ",".join(cfg["layers"]),
                            "-o", str(cam) + "/", board], name + ":fresh-gerbers", base)
    drill = audit.command([args.kicad_cli, "pcb", "export", "drill", "--format", "excellon",
                          "--drill-origin", "absolute", "--excellon-separate-th",
                          "-o", str(cam) + "/", board], name + ":fresh-drill", base)
    audit.check(gerbers.returncode == drill.returncode == 0, "fresh_export_exit", name)
    fresh_names = {p.name for p in cam.iterdir() if p.is_file()}
    audit.check(fresh_names == expected, "fresh_cam_inventory", name)

    archive_bytes = archive.read_bytes()
    result["archive_sha256"] = sha(archive_bytes)
    import io
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as z:
        infos = z.infolist()
        audit.check(len(infos) == cfg["members"] and {i.filename for i in infos} == expected,
                    "exact_zip_inventory", name)
        audit.check(len({i.filename for i in infos}) == len(infos), "no_duplicate_zip_members", name)
        audit.check(z.testzip() is None, "zip_crc", name)
        result["cam"] = {}
        for member in sorted(expected):
            if member not in z.namelist() or not (cam / member).is_file():continue
            published, fresh = z.read(member), (cam / member).read_bytes()
            matches = normalize(member, published) == normalize(member, fresh)
            audit.check(matches, "fresh_cam_matches_zip_except_timestamps", name + ":" + member)
            result["cam"][member] = {"zip_sha256": sha(published), "fresh_sha256": sha(fresh),
                                      "bytes_equal": published == fresh,
                                      "equal_except_timestamps": matches}
            loose_path = loose / member
            if audit.check(loose_path.is_file() and not loose_path.is_symlink(),
                           "loose_cam_file", name + ":" + member):
                loose_bytes = loose_path.read_bytes()
                normalized_loose = normalize(member, loose_bytes)
                zip_matches = normalized_loose == normalize(member, published)
                fresh_matches = normalized_loose == normalize(member, fresh)
                audit.check(zip_matches, "loose_cam_matches_zip_except_timestamps",
                            name + ":" + member)
                audit.check(fresh_matches, "loose_cam_matches_fresh_except_timestamps",
                            name + ":" + member)
                result["cam"][member].update(
                    loose_sha256=sha(loose_bytes), loose_matches_zip=zip_matches,
                    loose_matches_fresh=fresh_matches)
            if member.endswith(".gbr"):
                layer = member[len(stem) + 1:-4]
                functions = re.findall(rb"(?m)^%TF\.FileFunction,([^*]+)\*%$", published)
                audit.check(functions == [GERBER_FUNCTIONS[layer].encode()],
                            "gerber_file_function", name + ":" + member)
        if stem + "-job.gbrjob" in z.namelist():
            job = read_json(z.read(stem + "-job.gbrjob"))
            result["stackup"] = job["MaterialStackup"]
            result["general_specs"] = job["GeneralSpecs"]
            audit.check(job["GeneralSpecs"]["LayerNumber"] == 2 and
                        job["GeneralSpecs"]["BoardThickness"] == 1.6, "job_board_stack", name)
            copper = [x for x in job["MaterialStackup"] if x["Type"] == "Copper"]
            audit.check(len(copper) == 2 and {x["Name"] for x in copper} == {"F.Cu", "B.Cu"}
                        and all(x["Thickness"] == .035 for x in copper), "job_one_ounce_copper", name)
            for material, color in (("SolderMask", cfg["mask"]), ("Legend", cfg["legend"])):
                items = [x for x in job["MaterialStackup"] if x["Type"] == material]
                audit.check(len(items) == 2 and all(x["Color"] == color for x in items),
                            "job_" + material + "_color", name)
            attrs = job["FilesAttributes"]
            audit.check(len(attrs) == len(layers) and
                        {x["Path"] for x in attrs} == {stem + "-" + x + ".gbr" for x in layers},
                        "job_file_inventory", name)
            for entry in attrs:
                layer = entry["Path"][len(stem) + 1:-4]
                audit.check(layer in JOB_FUNCTIONS and entry["FileFunction"] == JOB_FUNCTIONS[layer],
                            "job_file_function", name + ":" + entry["Path"])
    return result


def output_path(parser, requested, repo, helper):
    """Reject direct, symlink and hard-link aliases of protected inputs."""
    if requested.is_symlink() or (requested.exists() and requested.stat().st_nlink > 1):
        parser.error("The report must not replace a symbolic or hard link")
    target = requested.resolve()
    try:
        target.relative_to(repo / "hardware/kicad")
    except ValueError:
        pass
    else:
        parser.error("Write the audit report outside hardware/kicad")
    if target in {Path(__file__).resolve(), helper.resolve()}:
        parser.error("The report must not overwrite its verifier or normalization source")
    return target


def main():
    script_hash = sha(Path(__file__).read_bytes())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true",
                        help="Label the report as an intermediate-input smoke test; checks are identical")
    parser.add_argument("--kicad-cli", default=os.environ.get("KICAD_CLI") or
                        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")
    parser.add_argument("--kicad-python", default=os.environ.get("KICAD_PYTHON") or
                        "/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3")
    args = parser.parse_args()
    args.repo = args.repo.resolve()
    requested_output = args.output
    audit = Audit()
    helper = args.repo / "docs/reviews/screen-power-rev-l-1072/verify_fabrication.py"
    args.output = output_path(parser, requested_output, args.repo, helper)
    result = {"purpose": "intermediate-input smoke test" if args.smoke else "final console/ring CAM audit",
              "verifier_sha256": script_hash, "boards": {},
              "limits": ["CAM parity and CAD connectivity do not establish assembled hardware operation.",
                         "DRC ignored checks are recorded; configured severity exclusions are checked.",
                         "Power-route capacity and final visual finish require their separate review."]}
    temporary_path = None

    def failure(name, error):
        # Do not leak host-specific paths into durable JSON records.
        detail = str(error).replace(str(args.repo), "<repository>")
        if temporary_path:
            detail = detail.replace(temporary_path, "<temporary>")
        for tool in (str(args.kicad_cli), str(args.kicad_python)):
            detail = detail.replace(tool, "<tool>")
        audit.check(False, name, type(error).__name__ + ": " + detail)

    try:
        helper_bytes = helper.read_bytes()
        read_json, normalize = strict_normalizers(helper_bytes)
        args.tracked_paths = git_paths(args.repo)
        sources_before = source_inventory(args.repo)
        archives_before = {name: sha((args.repo / "hardware/kicad" / c["zip"]).read_bytes())
                           for name, c in CONFIGS.items()}
        loose_before = loose_inventory(args.repo)
        result.update(normalizer_source_sha256=sha(helper_bytes),
                      sources_before=sources_before, archives_before=archives_before,
                      loose_before=loose_before)
        version = audit.command([args.kicad_cli, "version"], "kicad-version", args.repo)
        result["kicad_version"] = version.stdout.strip()
        audit.check(version.returncode == 0 and version.stdout.strip().startswith("10."),
                    "kicad_10", "KiCad CLI")
        with tempfile.TemporaryDirectory(prefix="segno-console-ring-cam-") as tmp:
            temporary_path = tmp
            for name, cfg in CONFIGS.items():
                folder = Path(tmp) / name
                folder.mkdir()
                try:
                    result["boards"][name] = run_board(name, cfg, args, folder, audit,
                                                     read_json, normalize)
                except Exception as error:
                    failure(name + ":board_audit_completed", error)
        sources_after = source_inventory(args.repo)
        archives_after = {name: sha((args.repo / "hardware/kicad" / c["zip"]).read_bytes())
                          for name, c in CONFIGS.items()}
        loose_after = loose_inventory(args.repo)
        result.update(sources_after=sources_after, archives_after=archives_after,
                      loose_after=loose_after)
        audit.check(sources_before == sources_after, "production_sources_unchanged", "all inputs")
        audit.check(archives_before == archives_after, "archives_unchanged", "both ZIPs")
        audit.check(loose_before == loose_after, "loose_cam_unchanged", "all loose CAM")
        audit.check(args.tracked_paths == git_paths(args.repo), "tracked_inventory_unchanged", "Git inputs")
        audit.check(sha(helper_bytes) == sha(helper.read_bytes()), "normalizer_source_unchanged", "strict helper")
    except Exception as error:
        failure("audit_completed", error)
    try:
        audit.check(script_hash == sha(Path(__file__).read_bytes()), "verifier_unchanged", "this script")
    except OSError as error:
        failure("verifier_unchanged", error)
    result["assertions"] = audit.checks
    result["commands"] = audit.commands
    result["checks_passed"] = sum(c["passed"] for c in audit.checks)
    result["checks_failed"] = sum(not c["passed"] for c in audit.checks)
    result["passed"] = result["checks_failed"] == 0
    result["finished_at"] = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime())
    args.output = output_path(parser, requested_output, args.repo, helper)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({k: result[k] for k in ("passed", "checks_passed", "checks_failed")}))
    for check in audit.checks:
        if not check["passed"]:print("FAIL " + check["check"] + ": " + check["detail"])
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
