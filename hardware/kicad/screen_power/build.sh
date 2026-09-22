#!/usr/bin/env bash
# Rebuild schematic, placement, critical routes, remaining routes and package.
set -euo pipefail
cd "$(dirname "$0")"
: "${SKIDL_PYTHON:=$PWD/.venv/bin/python}"
: "${KICAD_PYTHON:=/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3}"
: "${KICAD_CLI:=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli}"
: "${FREEROUTING_JAR:=$HOME/.local/share/freerouting/freerouting-1.9.0.jar}"
export KICAD_CLI
case "${1:-all}" in
  hand|factory) variants=("$1");;
  all) variants=(hand factory);;
  *) echo 'Usage: build.sh [hand|factory|all]' >&2; exit 2;;
esac
[[ -x "$SKIDL_PYTHON" && -x "$KICAD_PYTHON" && -x "$KICAD_CLI" && -f "$FREEROUTING_JAR" ]] || {
  echo 'Configure the SKiDL, KiCad Python/CLI and Freerouting paths described in README.md.' >&2; exit 2;
}
route_temp=$(mktemp -d)
trap 'rm -rf "$route_temp"' EXIT
for variant in "${variants[@]}"; do
  "$SKIDL_PYTHON" circuit.py "$variant" --schematic
  "$KICAD_PYTHON" pcb.py "$variant"
  "$KICAD_PYTHON" route_critical.py "$variant"
  "$KICAD_CLI" pcb drc --refill-zones --save-board --severity-all --format json \
    -o "$route_temp/critical.json" "$variant/screen_power_$variant.placed.kicad_pcb"
  "$KICAD_PYTHON" - "$route_temp/critical.json" <<'PY'
import json,sys
report=json.load(open(sys.argv[1]))
invalid=[v for v in report['violations'] if v['type'] not in ('via_dangling','track_dangling')]
if invalid:raise SystemExit('Critical routing DRC failed: '+str(invalid))
PY
  "$KICAD_PYTHON" router.py "$variant" export "$route_temp/board.dsn"
  java -jar "$FREEROUTING_JAR" -de "$route_temp/board.dsn" -do "$route_temp/board.ses" -mp 30 -dct 0
  "$KICAD_PYTHON" router.py "$variant" import "$route_temp/board.ses"
  "$KICAD_PYTHON" finish.py "$variant"
  "$KICAD_PYTHON" cleanup.py "$variant"
  "$KICAD_PYTHON" check.py "$variant" --self-test
  "$KICAD_PYTHON" export.py "$variant"
done
