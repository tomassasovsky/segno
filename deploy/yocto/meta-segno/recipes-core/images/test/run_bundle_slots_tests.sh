#!/usr/bin/env bash
# Contract failures use RAUC's JSON format; Linux CI also builds signed bundles.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here/check_bundle.sh" <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

check = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="segno-bundle-") as temp:
    root = Path(temp)
    bundle = root / "test.raucb"
    bundle.write_text("artifact")
    inspector = root / "rauc"
    inspector.write_text('''#!/bin/sh
[ "$1" = info ] && [ "$2" = --no-verify ] && [ "$3" = --output-format=json ] || exit 9
cat "$BUNDLE_TEST_INFO"
exit "${BUNDLE_TEST_STATUS:-0}"
''')
    inspector.chmod(0o755)
    info = root / "info.json"
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
               BUNDLE_TEST_INFO=str(info))
    good = {
        "compatible": "segno-raspberrypi5", "version": "0.1.0-test.1",
        "format": "verity", "images": [
            {"rootfs": {"filename": "rootfs.ext4", "size": 4096,
                        "checksum": "a" * 64, "hooks": []}},
            {"firmware": {"filename": "segno-bootfs-raspberrypi5.tar", "size": 10240,
                          "checksum": "b" * 64, "hooks": ["install"]}},
        ],
    }
    cases = [("valid tar/install bundle", good, True)]
    for field, value in [("compatible", "another-board"), ("version", "old"),
                         ("images", good["images"][:1]),
                         ("images", good["images"] + good["images"][:1])]:
        bad = copy.deepcopy(good)
        bad[field] = value
        cases.append((f"reject {field}={value}", bad, False))
    for index, slot, field, value in [
        (1, "firmware", "filename", "boot.vfat"),
        (1, "firmware", "hooks", []),
        (1, "firmware", "hooks", ["post-install"]),
        (1, "firmware", "size", 0),
        (0, "rootfs", "filename", "rootfs.tar"),
        (0, "rootfs", "checksum", ""),
    ]:
        bad = copy.deepcopy(good)
        bad["images"][index][slot][field] = value
        cases.append((f"reject {slot}.{field}={value}", bad, False))
    for name, data, want in cases:
        info.write_text(json.dumps(data))
        result = subprocess.run(["bash", check, str(bundle), good["compatible"],
                                 good["version"]], env=env, capture_output=True)
        assert (result.returncode == 0) == want, (name, result.stderr)
    for text, status in [("not json", "0"), (json.dumps(good), "1")]:
        info.write_text(text)
        env["BUNDLE_TEST_STATUS"] = status
        result = subprocess.run(["bash", check, str(bundle), good["compatible"],
                                 good["version"]], env=env, capture_output=True)
        assert result.returncode != 0, "bad inspector result was accepted"
    print(f"bundle inspection: {len(cases) + 2} contract cases passed")
PY

if ! command -v rauc >/dev/null 2>&1; then
    echo "SKIP: signed-artifact cases require RAUC (installed in Linux CI)"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/input" "$work/boot"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=segno-test/ -days 1 \
    -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
printf 'root=XXX\n' > "$work/boot/cmdline.txt"
tar -cf "$work/input/boot.tar" -C "$work/boot" .
printf 'test rootfs payload\n' > "$work/input/rootfs.ext4"
printf '#!/bin/sh\nexit 0\n' > "$work/input/install.sh"
chmod +x "$work/input/install.sh"
cat > "$work/input/manifest.raucm" <<'EOF'
[update]
compatible=segno-raspberrypi5
version=0.1.0-test.1
[bundle]
format=verity
[hooks]
filename=install.sh
[image.rootfs]
filename=rootfs.ext4
[image.firmware]
filename=boot.tar
hooks=install
EOF
rauc bundle --cert="$work/cert.pem" --key="$work/key.pem" \
    --mksquashfs-args='-processors 1' "$work/input" "$work/good.raucb"
bash "$here/check_bundle.sh" "$work/good.raucb" segno-raspberrypi5 0.1.0-test.1

# The original failure shape: a valid signed bundle carrying rootfs alone.
sed '/^\[image.firmware\]/,$d' "$work/input/manifest.raucm" > "$work/manifest"
mv "$work/manifest" "$work/input/manifest.raucm"
rauc bundle --cert="$work/cert.pem" --key="$work/key.pem" \
    --mksquashfs-args='-processors 1' "$work/input" "$work/rootfs-only.raucb"
if bash "$here/check_bundle.sh" "$work/rootfs-only.raucb" segno-raspberrypi5 0.1.0-test.1; then
    echo "FAIL: rootfs-only signed artifact passed inspection" >&2
    exit 1
fi
echo "signed-artifact inspection: 2 cases passed"
