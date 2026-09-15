#!/usr/bin/env bash
# Inspect the built artifact, not recipe text. RAUC decodes its manifest;
# signature trust remains the device's install-time check.
set -euo pipefail

bundle=${1:?bundle path required}
compatible=${2:?expected compatible required}
version=${3:?expected version required}
test -s "$bundle"
info=$(rauc info --no-verify --output-format=json "$bundle")
jq -e --arg compatible "$compatible" --arg version "$version" '
    .compatible == $compatible and .version == $version
    and (.images | length == 2)
    and ([.images[] | keys[]] | sort == ["firmware", "rootfs"])
    and (.images[] | select(has("rootfs")) | .rootfs |
        (.filename | endswith(".ext4")) and .size > 0
        and (.checksum | test("^[0-9a-f]{64}$")))
    and (.images[] | select(has("firmware")) | .firmware |
        (.filename | endswith(".tar.img")) and .size > 0
        and (.checksum | test("^[0-9a-f]{64}$")) and .hooks == ["install"])
' <<< "$info" >/dev/null
echo "bundle verified: $compatible $version, rootfs + boot archive with install hook"
