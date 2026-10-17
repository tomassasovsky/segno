#!/usr/bin/env bash
# Rebuild schematic, placement, critical routes, remaining routes and package.
set -euo pipefail
cd "$(dirname "$0")"
: "${SKIDL_PYTHON:=$PWD/.venv/bin/python}"
: "${KICAD_PYTHON:=/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3}"
: "${KICAD_CLI:=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli}"
: "${FREEROUTING_JAR:=$HOME/.local/share/freerouting/freerouting-1.9.0.jar}"
export KICAD_CLI
if (( $# )); then
  echo 'Usage: build.sh' >&2
  exit 2
fi
[[ -x "$SKIDL_PYTHON" && -x "$KICAD_PYTHON" && -x "$KICAD_CLI" && -f "$FREEROUTING_JAR" ]] || {
  echo 'Configure the SKiDL, KiCad Python/CLI and Freerouting paths described in README.md.' >&2; exit 2;
}
route_temp=$(mktemp -d)
trap 'rm -rf "$route_temp"' EXIT
variant=hand
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
# Round what the router mitred, after finish.py has snapped its endpoints and
# before cleanup.py's final DRC judges the board. The eight USB data nets are
# excluded by name: a coupled pair's geometry belongs to route_critical.py, and
# rounding one side of a pair on its own is a coupling change. The gate-drive
# and power paths route_critical.py draws are locked, so they keep their own
# arcs; this reaches the logic and control copper Freerouting returned.
"$KICAD_PYTHON" ../round_routes.py "$variant/screen_power_$variant.kicad_pcb" \
  --skip S1_UP_P,S1_UP_N,S1_DN_P,S1_DN_N,S2_UP_P,S2_UP_N,S2_DN_P,S2_DN_N
"$KICAD_PYTHON" cleanup.py "$variant"
"$KICAD_PYTHON" check.py "$variant" --self-test --output validation.json
"$KICAD_PYTHON" export.py "$variant"
