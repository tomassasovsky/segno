#!/usr/bin/env python3
"""Independently compare a screen-power package with fresh KiCad CLI CAM.

Requires Python 3.9+, pypdf, and KiCad CLI 10. No repository exporter,
validator, generator, or pcbnew module is imported. Run after final export:

    python verify_fabrication.py --board BOARD --package FABRICATION \
        --zip PUBLISHED_GERBERS.zip --output fabrication-verification.json

The output contains repository-relative paths and hashes, never host paths.
Only manufacturing CAM is regenerated; other package files receive byte-hash
and inventory checks. Passing this check does not qualify assembled hardware.
"""

# cspell:words gbrjob gmtime idnum Parms protel soldermask

import argparse
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from time import gmtime, strftime
import zipfile

from pypdf import PdfReader
from pypdf.errors import PdfReadError
from pypdf.generic import (
    ArrayObject, BooleanObject, ByteStringObject, DictionaryObject,
    IndirectObject, NullObject, StreamObject,
)


LAYER_FUNCTIONS = {
    "F_Cu": "Copper,L1,Top",
    "B_Cu": "Copper,L2,Bot",
    "F_Mask": "SolderMask,Top",
    "B_Mask": "SolderMask,Bot",
    "F_Silkscreen": "Legend,Top",
    "B_Silkscreen": "Legend,Bot",
    "Edge_Cuts": "Profile",
}
# KiCad 10 exports different case-sensitive values in job and layer files.
# The routed board outline is explicitly non-plated in the Gerber header.
GERBER_FUNCTIONS = {
    **LAYER_FUNCTIONS,
    "F_Mask": "Soldermask,Top",
    "B_Mask": "Soldermask,Bot",
    "Edge_Cuts": "Profile,NP",
}
ISO_DATE = rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})"
LIMITS = [
    "Non-CAM artifacts receive manifest byte-hash checks, not independent "
    "regeneration or visual QA.",
    "Drill PDFs are compared by decoded drawing bytes, page geometry and "
    "resources. Container compression, object numbers, document IDs and "
    "creation/modification dates are not drawing content.",
    "CAM/source parity proves manufacturing data matches the supplied native "
    "board; it does not establish circuit correctness or hardware acceptance.",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(data):
    """Reject duplicate keys rather than silently trusting the final value."""
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def inventory(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise ValueError("Symlink in package/source tree: " + path.name)
        if path.is_file():
            result[path.relative_to(folder).as_posix()] = digest(path.read_bytes())
    return result


def sources(base, board):
    """Discover production inputs independently of the exporter hash helper."""
    paths = set(base.glob("*.sh"))
    # SKiDL's generated symbol cache is an output, not a production input.
    paths.update(p for p in base.glob("*.py") if not p.name.endswith("_sklib.py"))
    for directory in (base / "models", base / "screen_power.pretty"):
        paths.update(p for p in directory.rglob("*") if p.is_file())
    for pattern in ("*.net", "*.kicad_sch", "*.kicad_sym", "*.kicad_pro",
                    "*.kicad_dru", "*-lib-table", "components.json", "bom.csv"):
        paths.update(board.parent.glob(pattern))
    paths.update((board, base / "README.md", base / "COSTS.md",
                  base / "external_bom.csv", base / "LIBRARY_LICENSE.txt",
                  base.parents[2] / "LICENSE", base.parent / "netlist.py",
                  base.parent / "round_routes.py",
                  base.parent / "silkscreen.py",
                  base.parent / "console_board.net",
                  base.parent / "out_console/segno_console_board.kicad_pcb"))
    result = {}
    for path in sorted(paths):
        if path.is_symlink():
            raise ValueError("Symlink production input: " + path.name)
        result[os.path.relpath(path, base)] = digest(path.read_bytes())
    return result


def normalize_cam(name, data):
    """Remove only known KiCad date fields; preserve all manufacturing bytes."""
    if name.endswith(".gbrjob"):
        job = read_json(data)
        date = job["Header"].pop("CreationDate")
        if not re.fullmatch(ISO_DATE.decode(), date):
            raise ValueError("Unexpected Gerber job creation date")
        return job
    if name.endswith(".gbr"):
        patterns = (
            (rb"(?m)^(%TF\.CreationDate,)" + ISO_DATE + rb"(\*%)$", rb"\1<DATE>\2"),
            (rb"(?m)^(G04 Created by KiCad \(PCBNEW [^)]+\) date )"
             rb"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\*)$", rb"\1<DATE>\2"),
        )
    elif name.endswith(".drl"):
        patterns = (
            (rb"(?m)^(; #@! TF\.CreationDate,)" + ISO_DATE + rb"$", rb"\1<DATE>"),
            (rb"(?m)^(; DRILL file KiCad \S+ date )"
             rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", rb"\1<DATE>"),
        )
    else:
        raise ValueError("Unsupported CAM file type: " + name)
    for pattern, replacement in patterns:
        data, count = re.subn(pattern, replacement, data)
        if count != 1:
            raise ValueError("Expected exactly one KiCad timestamp field in " + name)
    return data


def pdf_value(value, seen=frozenset()):
    """Resolve resources without relying on PDF object numbering/compression."""
    if isinstance(value, IndirectObject):
        key = (value.idnum, value.generation)
        if key in seen:
            raise ValueError("Cyclic object in PDF drawing resources")
        return pdf_value(value.get_object(), seen | {key})
    if isinstance(value, StreamObject):
        attrs = {str(k): pdf_value(v, seen) for k, v in value.items()
                 if k not in ("/Length", "/Filter", "/DecodeParms")}
        return ("stream", attrs, value.get_data())
    if isinstance(value, DictionaryObject):
        return {str(k): pdf_value(v, seen) for k, v in value.items()}
    if isinstance(value, ArrayObject):
        return [pdf_value(v, seen) for v in value]
    if isinstance(value, ByteStringObject):
        return ("bytes", bytes(value))
    if isinstance(value, BooleanObject):
        return ("boolean", value.value)
    if isinstance(value, NullObject):
        return None
    if isinstance(value, (str, int, float)):
        return (type(value).__name__, str(value))
    raise ValueError("Unsupported PDF object: " + type(value).__name__)


def pdf_drawing(data):
    reader = PdfReader(io.BytesIO(data), strict=True)
    if reader.is_encrypted:
        raise ValueError("Encrypted drill map")
    metadata = {str(k): pdf_value(v) for k, v in (reader.metadata or {}).items()
                if k not in ("/CreationDate", "/ModDate")}
    pages = []
    for page in reader.pages:
        attributes = {str(k): pdf_value(v) for k, v in page.items()
                      if k not in ("/Parent", "/Contents", "/Resources")}
        # PdfReader resolves inherited page resources and geometry on access.
        resources = pdf_value(page.get("/Resources", DictionaryObject()))
        contents = page.get_contents()
        pages.append((attributes, resources,
                      contents.get_data() if contents is not None else b""))
    if not pages:
        raise ValueError("Drill map has no pages")
    return metadata, pages


class Audit:
    def __init__(self):
        self.counts = Counter()

    def check(self, condition, category, detail):
        if not condition:
            raise ValueError(category + ": " + detail)
        self.counts[category] += 1

    def zip_matches(self, data, manufacturing):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = archive.namelist()
            self.check(len(names) == len(set(names))
                       and set(names) == set(manufacturing),
                       "zip_member_inventory", "Members differ or repeat")
            for name, expected in manufacturing.items():
                self.check(archive.read(name) == expected,
                           "zip_member_bytes", name)


def run_cli(cli, *arguments):
    process = subprocess.run([cli, *map(str, arguments)], capture_output=True,
                             text=True, timeout=180, check=False)
    if process.returncode:
        # Host paths and full logs stay in the terminal, not committed JSON.
        raise RuntimeError("KiCad CLI failed: " + " ".join(arguments[:3]))
    return process.stdout.strip()


def verify(args):
    verifier_hash = digest(Path(__file__).read_bytes())
    audit = Audit()
    board, package = args.board.resolve(), args.package.resolve()
    base = board.parent.parent
    repository = base.parents[2]
    # Explicitly require the project's hierarchy; do not produce absolute paths
    # in evidence if called on an unrelated directory or external package.
    source_base = base.relative_to(repository).as_posix()
    audit.check(source_base == "hardware/kicad/screen_power",
                "source_location", "Unexpected production source hierarchy")
    artifact_base = package.relative_to(repository).as_posix()
    audit.check(not args.output.resolve().is_relative_to(package),
                "output_location", "Evidence must be outside the package")
    initial_sources = sources(base, board)
    source_paths = {(base / name).resolve() for name in initial_sources}
    audit.check(args.output.resolve() not in source_paths
                and args.output.resolve() not in (args.zip.resolve(), Path(__file__).resolve()),
                "output_location", "Evidence must not replace a production input")
    initial_package = inventory(package)
    manifest_bytes = (package / "manifest.json").read_bytes()
    manifest = read_json(manifest_bytes)
    audit.check(digest(manifest_bytes) == initial_package["manifest.json"],
                "input_unchanged_between_reads", "manifest.json")
    artifact_hashes = {k: v for k, v in initial_package.items() if k != "manifest.json"}
    audit.check(set(manifest["files"]) == set(artifact_hashes),
                "manifest_artifact_inventory", "Missing or unlisted package file")
    for name, actual in artifact_hashes.items():
        audit.check(manifest["files"][name] == actual, "manifest_artifact_hash", name)
    audit.check(set(manifest["source_sha256"]) == set(initial_sources),
                "manifest_source_coverage", "Source inventory differs")
    for name, actual in initial_sources.items():
        audit.check(manifest["source_sha256"][name] == actual,
                    "manifest_source_hash", name)
    board_name = os.path.relpath(board, base)
    board_hash = initial_sources[board_name]
    audit.check(manifest["board_sha256"] == board_hash,
                "manifest_board_hash", board.name)
    portable = package / "native" / board.parent.name / board.name
    audit.check(digest(portable.read_bytes()) == board_hash,
                "portable_board_matches_source", board.name)

    validation = read_json((package / "validation.json").read_bytes())
    variants = validation.get("variants", [])
    audit.check(validation.get("cad_ready") is True and len(variants) == 1
                and variants[0].get("variant") == board.parent.name
                and variants[0].get("errors") == [],
                "packaged_validation_passed", "CAD report is not clean")
    validation_sources = variants[0]["source_sha256"]
    documentation_only = {"README.md", "COSTS.md", "LIBRARY_LICENSE.txt", "../../../LICENSE"}
    audit.check(set(validation_sources) == set(initial_sources) - documentation_only,
                "validation_source_coverage", "CAD report production input inventory differs")
    for name, expected in validation_sources.items():
        audit.check(initial_sources.get(name) == expected, "validation_source_hash", name)

    stem = board.stem
    expected_names = {stem + "-" + layer + ".gbr" for layer in LAYER_FUNCTIONS}
    expected_names.update(stem + suffix for suffix in
                          ("-job.gbrjob", "-PTH.drl", "-NPTH.drl",
                           "-PTH-drl_map.pdf", "-NPTH-drl_map.pdf"))
    manufacturing_dir = package / "gerbers"
    audit.check(set(inventory(manufacturing_dir)) == expected_names,
                "manufacturing_file_inventory", "Unexpected manufacturing files")
    manufacturing = {name: (manufacturing_dir / name).read_bytes()
                     for name in sorted(expected_names)}
    zip_names = [name for name in artifact_hashes if name.endswith(".zip")]
    audit.check(len(zip_names) == 1, "package_has_manufacturing_zip", "Expected one ZIP")
    audit.zip_matches((package / zip_names[0]).read_bytes(), manufacturing)
    published_zip = args.zip.resolve().read_bytes()
    audit.zip_matches(published_zip, manufacturing)

    version = run_cli(args.kicad_cli, "version")
    audit.check(re.match(r"^10\.", version) is not None,
                "kicad_major_version", "This audit requires KiCad 10")
    with tempfile.TemporaryDirectory(prefix="screen-cam-audit-") as directory:
        fresh = Path(directory)
        run_cli(args.kicad_cli, "pcb", "export", "gerbers", "--layers",
                "F.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,Edge.Cuts",
                "--no-protel-ext", "--subtract-soldermask", "--check-zones",
                "--output", str(fresh) + os.sep, str(board))
        run_cli(args.kicad_cli, "pcb", "export", "drill", "--format", "excellon",
                "--excellon-separate-th", "--generate-map", "--map-format", "pdf",
                "--output", str(fresh) + os.sep, str(board))
        audit.check(set(inventory(fresh)) == expected_names,
                    "fresh_export_inventory", "Unexpected fresh CAM files")
        for name, packaged in manufacturing.items():
            regenerated = (fresh / name).read_bytes()
            if name.endswith(".pdf"):
                equal = pdf_drawing(packaged) == pdf_drawing(regenerated)
            else:
                equal = normalize_cam(name, packaged) == normalize_cam(name, regenerated)
            audit.check(equal, "independent_manufacturing_match", name)
        for directory_path in (manufacturing_dir, fresh):
            job = read_json((directory_path / (stem + "-job.gbrjob")).read_bytes())
            copper = [layer for layer in job["MaterialStackup"] if layer["Type"] == "Copper"]
            audit.check(job["GeneralSpecs"]["LayerNumber"] == 2 and len(copper) == 2
                        and {layer["Name"] for layer in copper} == {"F.Cu", "B.Cu"}
                        and all(layer["Thickness"] == 0.035 for layer in copper),
                        "two_layer_1oz_stackup", "Copper stack differs")
            functions = {entry["Path"]: entry["FileFunction"] for entry in job["FilesAttributes"]}
            wanted = {stem + "-" + layer + ".gbr": value
                      for layer, value in LAYER_FUNCTIONS.items()}
            audit.check(len(job["FilesAttributes"]) == 7 and functions == wanted,
                        "job_layer_inventory", "Gerber job layers differ")
            for layer, function in GERBER_FUNCTIONS.items():
                data = (directory_path / (stem + "-" + layer + ".gbr")).read_bytes()
                declared = re.findall(rb"(?m)^%TF\.FileFunction,([^\r\n]+)\*%$", data)
                audit.check(declared == [function.encode()], "gerber_file_function", layer)

    final_sources, final_package = sources(base, board), inventory(package)
    audit.check(set(final_sources) == set(initial_sources),
                "source_inventory_unchanged", "Source files changed during audit")
    audit.check(set(final_package) == set(initial_package),
                "package_inventory_unchanged", "Package files changed during audit")
    for name, value in initial_sources.items():
        audit.check(final_sources[name] == value, "input_unchanged_during_verification", name)
    for name, value in initial_package.items():
        audit.check(final_package[name] == value, "input_unchanged_during_verification", name)
    audit.check(args.zip.resolve().read_bytes() == published_zip,
                "input_unchanged_during_verification", "Published ZIP")
    audit.check(digest(Path(__file__).read_bytes()) == verifier_hash,
                "verifier_unchanged_during_verification", "Verifier source")
    return {
        "passed": True, "finished_at": strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()),
        "kicad_version": version, "board_sha256": board_hash,
        "screen_zip_sha256": digest(published_zip),
        "verifier_sha256": verifier_hash,
        "checks_passed": sum(audit.counts.values()),
        "counts_by_check": dict(sorted(audit.counts.items())),
        "source_base": source_base, "source_sha256": initial_sources,
        "artifacts_base": artifact_base, "artifact_sha256": artifact_hashes,
        "limits": LIMITS,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("board", "package", "zip", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--kicad-cli", default=os.environ.get("KICAD_CLI")
                        or shutil.which("kicad-cli")
                        or "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")
    args = parser.parse_args()
    try:
        result = verify(args)
    except (OSError, ValueError, KeyError, RuntimeError, PdfReadError, subprocess.TimeoutExpired,
            zipfile.BadZipFile) as error:
        print("Fabrication audit FAILED: " + str(error))
        # Preserve existing files on failure. Success evidence is identified by
        # its board/source hashes, verifier hash and finish time, not existence.
        raise SystemExit(1) from error
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in
                      ("passed", "checks_passed", "board_sha256", "screen_zip_sha256")}))


if __name__ == "__main__":
    main()
