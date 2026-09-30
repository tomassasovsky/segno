"""Read-only recording access. Executed over SSH; never installed on the device."""

import math
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys


def safe_path(root, relative):
    parts = relative.split("/")
    if not relative or any(p in ("", ".", "..") for p in parts):
        raise ValueError("Invalid recording path. Refresh the recordings.")
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Linked files cannot be downloaded.")
    path.resolve().relative_to(root.resolve())
    return path


def read_manifest(directory):
    path = directory / "performance.json"
    if path.is_symlink() or path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError("Recording information is unavailable.")
    # Yocto ships jq, while its minimal Python has no json or hashlib modules.
    result = subprocess.run([
        "jq", "-er", 'if type == "object" and .finalized == true and '
        '(.sample_rate | type) == "number" and (.capture_frames | type) == "number" '
        'then [.sample_rate, .capture_frames, (.slug // "")] | @tsv '
        'else error("Recording is not ready") end', str(path)
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError("This recording's information is unavailable or it is still being saved.")
    fields = result.stdout.decode("utf-8").rstrip("\n").split("\t")
    rate, frames = float(fields[0]), float(fields[1])
    if not math.isfinite(rate) or not math.isfinite(frames) or rate <= 0 or frames < 0 or frames > 2**63 - 1:
        raise ValueError("Recording duration is invalid.")
    return {"sample_rate": rate, "capture_frames": frames, "slug": fields[2] if len(fields) > 2 else ""}


def wav_complete(path):
    # The appliance writes its declared sizes before audio. Comparing them to
    # the actual file length prevents offering an in-progress or truncated WAV.
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            return False
        if struct.unpack("<I", header[4:8])[0] + 8 != size:
            return False
        position = 12
        has_format = False
        while position + 8 <= size and position < 65536:
            chunk = stream.read(8)
            if len(chunk) != 8:
                return False
            length = struct.unpack("<I", chunk[4:])[0]
            if position + 8 + length > size:
                return False
            if chunk[:4] == b"fmt ":
                has_format = length >= 16
            if chunk[:4] == b"data":
                return has_format and length > 0
            step = length + (length % 2)
            stream.seek(step, 1)
            position += 8 + step
    return False


def version(path):
    info = path.stat()
    return f"{info.st_dev}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}"


def audio_files(directory):
    files = []
    for base, dirs, names in os.walk(directory, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not (Path(base) / d).is_symlink())
        for name in sorted(names):
            path = Path(base) / name
            if path.suffix.lower() != ".wav" or path.is_symlink():
                continue
            if not stat.S_ISREG(path.stat().st_mode) or not wav_complete(path):
                continue
            files.append({"path": path.relative_to(directory).as_posix(),
                          "bytes": path.stat().st_size, "version": version(path)})
    return sorted(files, key=lambda f: (f["path"] != "master.wav", f["path"]))


def catalog(root):
    recordings = []
    unavailable = 0
    candidates = list(root.iterdir())
    recovered = root / "recovered"
    if recovered.is_dir() and not recovered.is_symlink():
        candidates += list(recovered.iterdir())
    for directory in candidates:
        if directory == recovered or directory.is_symlink() or not directory.is_dir():
            continue
        if not (directory / "performance.json").exists():
            continue
        try:
            manifest = read_manifest(directory)
            files = audio_files(directory)
            if not any(f["path"] == "master.wav" for f in files):
                raise ValueError("Main recording is not ready.")
            rate = manifest.get("sample_rate", 0)
            frames = manifest.get("capture_frames", 0)
            duration = frames / rate
            if not math.isfinite(duration):
                raise ValueError("Recording duration is invalid.")
            match = re.fullmatch(r"perf-(\d{8})-(\d{6})(?:-\d+)?", str(manifest.get("slug", "")))
            timestamp = "" if match is None else match[1] + match[2]
            recordings.append({"id": directory.relative_to(root).as_posix(),
                               "name": directory.name, "timestamp": timestamp,
                               "modified": directory.stat().st_mtime,
                               "duration": duration, "files": files})
        except (OSError, ValueError, TypeError, OverflowError):
            unavailable += 1
    return {"recordings": recordings, "unavailable": unavailable}


def selected_file(root, request):
    directory = safe_path(root, request["recording"])
    read_manifest(directory)
    path = safe_path(directory, request["file"])
    if path.suffix.lower() != ".wav" or not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("Select an audio file from the recording list.")
    if version(path) != request["version"] or not wav_complete(path):
        raise ValueError("This audio file changed. Refresh the recordings and try again.")
    return path


def run(request):
    root = Path(request["root"])
    if not root.is_absolute() or not root.is_dir():
        raise ValueError("The recordings folder was not found on this appliance.")
    action = request["action"]
    if action == "catalog":
        return catalog(root)
    if action not in ("download", "hash", "read"):
        raise ValueError("Unknown recording operation.")
    path = selected_file(root, request)
    with path.open("rb") as stream:
        if action == "hash":
            digest = subprocess.check_output(["sha256sum"], stdin=stream).split()[0].decode("ascii")
        elif action == "read":
            offset, length = int(request["offset"]), int(request["length"])
            size = os.fstat(stream.fileno()).st_size
            if offset < 0 or length <= 0 or length > 1024 * 1024 or offset > size - length:
                raise ValueError("The requested audio range is invalid. Refresh and try again.")
            stream.seek(offset)
            chunk = stream.read(length)
            if len(chunk) != length:
                raise ValueError("The audio read was incomplete. Try the preview again.")
            sys.stdout.buffer.write(chunk)
        else:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    if version(path) != request["version"]:
        raise ValueError("The recording changed during transfer. Refresh and try again.")
    return {"sha256": digest} if action == "hash" else None


def emit_catalog(result):
    # jq encodes raw fields so this helper needs no extra Python packages.
    fields = []
    for recording in result["recordings"]:
        for file in recording["files"]:
            fields.extend(str(v) for v in [recording["id"], recording["name"], recording["timestamp"],
                recording["modified"], recording["duration"], file["path"], file["bytes"], file["version"]])
    payload = ("\0".join(fields) + ("\0" if fields else "")).encode("utf-8")
    program = 'split("\\u0000") | if .[-1] == "" then .[:-1] else . end | '
    program += '[range(0; length; 8) as $i | .[$i:$i+8] | '
    program += '{id:.[0], name:.[1], timestamp:.[2], modified:(.[3]|tonumber), duration:(.[4]|tonumber), '
    program += 'file:{path:.[5], bytes:(.[6]|tonumber), version:.[7]}}] | '
    program += 'group_by(.id) | map(.[0] as $r | {id:$r.id, name:$r.name, timestamp:$r.timestamp, '
    program += 'modified:$r.modified, duration:$r.duration, files:map(.file)}) | {recordings:., unavailable:$unavailable}'
    subprocess.run(["jq", "-Rs", "--argjson", "unavailable", str(result["unavailable"]), program], input=payload, check=True)


if __name__ == "__main__":
    try:
        request = dict(zip(["action", "root", "recording", "file", "version", "offset", "length"], sys.argv[1:]))
        result = run(request)
        if request["action"] == "catalog":
            emit_catalog(result)
        elif result is not None:
            subprocess.run(["jq", "-cn", "--arg", "sha", result["sha256"], '{sha256:$sha}'], check=True)
    except (OSError, ValueError, KeyError, TypeError, OverflowError, subprocess.SubprocessError) as error:
        print("Segno Transfer: " + str(error), file=sys.stderr)
        sys.exit(1)
