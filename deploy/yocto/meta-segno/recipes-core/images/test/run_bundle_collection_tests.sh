#!/usr/bin/env bash
# Execute the release collector against current, stale and missing artifacts.
set -euo pipefail
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
python3 - "$repo/.github/workflows/appliance-release.yml" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap

workflow = Path(sys.argv[1]).read_text()
match = re.search(
    r"^      - name: Collect bundle \+ write manifest\n"
    r"        id: artifacts\n        run: \|\n((?:          .*\n|\n)+)",
    workflow, re.MULTILINE,
)
assert match, "release collection step not found"
collector = textwrap.dedent(match.group(1))
version = "0.1.0-experimental.140"
payload = b"current checked bundle"
cases = [("raspberrypi4-64", "current"), ("raspberrypi5", "current"),
         ("raspberrypi5", "missing"), ("raspberrypi5", "empty")]
for machine, state in cases:
    with tempfile.TemporaryDirectory(prefix="segno-collection-") as temp:
        root = Path(temp)
        cache = root / "yocto"
        deploy = cache / "build/tmp/deploy/images" / machine
        deploy.mkdir(parents=True)
        stale = deploy / f"segno-update-bundle-{machine}-old.raucb"
        stale.write_bytes(b"stale cached bundle")
        (deploy / f"segno-update-bundle-{machine}.raucb").symlink_to(stale.name)
        current = deploy / f"segno-update-bundle-{machine}-{version}.raucb"
        if state != "missing":
            current.write_bytes(payload if state == "current" else b"")
        script = collector
        for key, value in {"machine": machine, "version": version,
                           "channel": "experimental"}.items():
            script = script.replace("${{ needs.determine-meta.outputs." + key + " }}", value)
        result = subprocess.run(["bash", "-c", script], cwd=root,
                                env=dict(os.environ, YOCTO_WORK_DIR=str(cache)),
                                capture_output=True, text=True)
        output = root / "release-artifacts"
        if state == "current":
            assert result.returncode == 0, (machine, result.stderr)
            name = f"segno-appliance-{version}.raucb"
            assert (output / name).read_bytes() == payload
            assert json.loads((output / "manifest.json").read_text()) == {
                "version": version, "bundle": name, "channel": "experimental",
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        else:
            assert result.returncode != 0, (state, "stale bundle accepted")
            assert not (output / "manifest.json").exists()
            assert not list(output.glob("*.raucb"))
print(f"bundle collection: {len(cases)} behavior cases passed")
PY
