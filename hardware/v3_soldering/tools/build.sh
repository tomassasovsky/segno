#!/usr/bin/env bash
# Regenerates the solder-order images in hardware/v3_soldering/ from the V3 boards.
# Needs KiCad 10 (kicad-cli and its bundled Python), ImageMagick and Python 3 with Pillow.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(dirname "$HERE")"
KICAD="$(cd "$HERE/../../kicad" && pwd)"
KAPP="${KICAD_APP:-/Applications/KiCad/KiCad.app}"
CLI="$KAPP/Contents/MacOS/kicad-cli"
KPY="$KAPP/Contents/Frameworks/Python.framework/Versions/Current/bin/python3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

board() { # name pcb
  "$KPY" "$HERE/geom.py" "$KICAD/$2" "$WORK/$1.json"
}
svg() { # name face pcb layers [--mirror]
  "$CLI" pcb export svg --mode-single --page-size-mode 2 --exclude-drawing-sheet \
    ${5:-} -l "$4" -o "$WORK/$1_$2.svg" "$KICAD/$3" >/dev/null
}

board console out_console/segno_console_board.kicad_pcb
board ring segno_pedal_ring.kicad_pcb
board screen screen_power/hand/screen_power_hand.kicad_pcb
svg console F out_console/segno_console_board.kicad_pcb F.Cu,F.Silkscreen,Edge.Cuts
svg ring F segno_pedal_ring.kicad_pcb F.Cu,F.Silkscreen,Edge.Cuts
svg ring B segno_pedal_ring.kicad_pcb B.Cu,B.Silkscreen,Edge.Cuts --mirror
svg screen F screen_power/hand/screen_power_hand.kicad_pcb F.Cu,F.Silkscreen,Edge.Cuts

python3 "$HERE/draw.py" "$WORK" "$OUT"
