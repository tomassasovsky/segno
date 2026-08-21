#!/usr/bin/env bash
# Place -> DSN -> Freerouting -> SES -> refill -> DRC -> gerbers, for console board v2 (#747).
# The recipe is the repo's pcb-layout skill; the gotchas below cost real time to find.
set -euo pipefail
cd "$(dirname "$0")"

KPY="/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3"
CLI="/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
JAR="${FREEROUTING_JAR:-$HOME/.local/share/freerouting/freerouting-1.9.0.jar}"
OUT="out_console"; PCB="$OUT/segno_console_board.kicad_pcb"   # ROUTED deliverable
PLACED="$OUT/console.placed.kicad_pcb"                        # what the generator writes
# What a fab is given: copper, mask, paste, silk, outline. NOT Courtyard/Fab/Adhesive/Eco/
# User, which are ours to read -- the zip shipped 27 files, and every one a CAM
# operator has to decide about is a chance to decide wrong.
FAB_LAYERS="F.Cu,B.Cu,F.Mask,B.Mask,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,Edge.Cuts"

[ -f "$JAR" ] || { echo "Freerouting jar not found at $JAR"; echo \
  "Get freerouting-1.9.0.jar from github.com/freerouting/freerouting/releases, or set FREEROUTING_JAR."; exit 1; }

place_and_export() {
mkdir -p "$OUT/logs"
DSN_RC=0
echo "== 1. place =="
"$KPY" console_board_pcb.py --no-export     # writes $OUT/console.placed.kicad_pcb

echo "== 2. export Specctra DSN =="
# ExportSpecctraDSN returns False and writes NOTHING if any footprint lacks a
# library id -- a bare pcbnew.FOOTPRINT() poisons the whole board silently. That
# is why the mounting holes are real MountingHole:* parts.
"$KPY" -c "
import pcbnew, os, sys
m = pcbnew.LoadBoard(os.path.abspath('$PLACED'))
# Route with MORE margin than DRC demands. Freerouting works in integer DSN units
# and lands a hair under whatever clearance it is given -- routing to the 0.2 mm
# rule produced an actual 0.1979 mm and one clearance violation. Widening the rule
# only moves the problem, so the DSN gets 0.3 mm and the board keeps its 0.2 mm
# check; the difference is the rounding headroom.
# Widths as well as clearance. Freerouting takes BOTH from the DSN netclass, not
# from anything in console_board_pcb.py -- so TRACK_W/TRACK_PWR there were purely
# decorative and every one of the 268 tracks came out at Freerouting's own 0.2 mm
# default, including +5V feeding ~1 A of WS2812s (0.2 mm is good for about 0.5 A).
# Via geometry as well as width and clearance. Freerouting inserts its OWN vias and
# takes their size from here too -- left unset, 15 of them came back at KiCad's
# default 0.6/0.3, which is exactly JLCPCB's minimum drill while the board's own
# stitching vias are 0.8/0.4. Sitting on a fab floor for no reason is how a batch
# gets scrapped for a plating fault.
for _n, _nc in m.GetAllNetClasses().items():
    _nc.SetClearance(pcbnew.FromMM(0.3))
    _nc.SetTrackWidth(pcbnew.FromMM(0.6))
    _nc.SetViaDiameter(pcbnew.FromMM(0.8))
    _nc.SetViaDrill(pcbnew.FromMM(0.4))
ok = pcbnew.ExportSpecctraDSN(m, os.path.abspath('$OUT/console.dsn'))
sys.exit(0 if ok else 'DSN export failed')" > "$OUT/logs/dsn.log" 2>&1 || DSN_RC=$?
grep -viE "wxApp|memory leak|Debug:|assert" "$OUT/logs/dsn.log" || true
[ "${DSN_RC:-0}" -eq 0 ] || { echo "DSN export FAILED -- see $OUT/logs/dsn.log"; exit 1; }
}

# EVERY step is inside the retry loop, placement included, and that is the whole
# point of the retry. Freerouting has no seed, and given one DSN it returns the same
# board every time -- five attempts on one file produced the same "1 unconnected"
# five times over, and so did five DIFFERENT -mp/-us configurations. What actually
# varies is the DSN: the PLACEMENT is deterministic in geometry but not in bytes,
# because KiCad stamps fresh UUIDs on every run, and ExportSpecctraDSN emits in an
# order those UUIDs influence. A re-placed board is the same board presented to the
# router in a different order, which is a genuinely different routing problem -- it
# is the only knob here that changes the outcome, and it is why this board routed
# clean on one run and left a net on the next. Config still varies too; it costs
# nothing and covers the case where order is not the obstacle.
CONFIGS=("-mp 30" "-mp 100" "-mp 30 -us global" "-mp 60 -us hybrid -hr 1:1" "-mp 200")
BEST=99999
for ATTEMPT in 1 2 3 4 5; do
  CFG="${CONFIGS[$ATTEMPT-1]}"
  echo "== attempt $ATTEMPT: re-place, re-export, route ($CFG) =="
  place_and_export >/dev/null
  # NOT -Djava.awt.headless=true: Freerouting needs a real display even in batch.
  # -dct 0 kills its 20 s "dialog confirmation timeout" -- pure wall-clock waste.
  # shellcheck disable=SC2086
  ( cd "$OUT" && java -jar "$JAR" -de console.dsn -do console.ses $CFG -dct 0 2>&1 \
      | grep -E "Auto-routing|optimization" ) || true

  cp "$PLACED" "$PCB"
  "$KPY" -c "
import pcbnew, os, sys
p = os.path.abspath('$PCB'); m = pcbnew.LoadBoard(p)
ok = pcbnew.ImportSpecctraSES(m, os.path.abspath('$OUT/console.ses'))
m.Save(p)
print('   tracks:', len([t for t in m.GetTracks() if t.GetClass()!='PCB_VIA']),
      'vias:', len([t for t in m.GetTracks() if t.GetClass()=='PCB_VIA']))
sys.exit(0 if ok else 'SES import failed')" 2>&1 | grep -viE "wxApp|memory leak|Debug:" || true

  # Which stitching vias are useful is decided by the FILL, not by placement: the
  # ones left in islands the fill deleted connect to nothing on either layer. They
  # can only be found here, after routing, so they are pruned here -- this pours,
  # asks DRC, deletes, and repeats until a pour comes back clean.
  "$KPY" console_board_pcb.py --prune-vias 2>&1 | grep -viE "wxApp|memory leak|Debug:" || true

  # --refill-zones is what pours the plane: in-process pcbnew.ZONE_FILLER segfaults
  # without a wxApp, and gerbers plotted before this ship an EMPTY ground plane.
  "$CLI" pcb drc --refill-zones --save-board --format json -o "$OUT/drc.json" \
         --severity-all "$PCB" >/dev/null 2>&1
  # --severity-all, NOT --severity-error. With errors only, this pipeline reported
  # "0 violations" for an entire design cycle while the board actually carried 131:
  # 100 holes_co_located (stitching vias landing dead on through-hole pad centres),
  # 30 via_dangling, 1 starved_thermal. Warnings are where the fab problems live.
  BAD=$(python3 -c "
import json, collections
d = json.load(open('$OUT/drc.json'))
v, u = d.get('violations', []), d.get('unconnected_items', [])
print('   violations: %d | unconnected: %d' % (len(v), len(u)), file=__import__('sys').stderr)
for t, n in collections.Counter(x['type'] for x in v).most_common():
    print('      %-26s %d' % (t, n), file=__import__('sys').stderr)
print(len(v) + len(u))")
  [ "$BAD" -lt "$BEST" ] && BEST=$BAD
  [ "$BAD" -eq 0 ] && break
done
if [ "$BEST" -ne 0 ]; then
  echo "ROUTE: no attempt came back clean (best: $BEST outstanding). Not shipping gerbers."
  exit 1
fi

echo "== 6. fab checks + gerbers =="
"$KPY" console_board_pcb.py --check-routed 2>&1 | grep -viE "wxApp|memory leak|Debug:"
rm -rf "$OUT/gerbers"; mkdir -p "$OUT/gerbers"
"$CLI" pcb export gerbers --no-protel-ext --layers "$FAB_LAYERS" \
       -o "$OUT/gerbers/" "$PCB" >/dev/null
"$CLI" pcb export drill --format excellon --excellon-separate-th -o "$OUT/gerbers/" "$PCB" >/dev/null
rm -f "$OUT/segno_console_board_gerbers.zip"
( cd "$OUT" && zip -qr segno_console_board_gerbers.zip gerbers )
echo "wrote $OUT/segno_console_board_gerbers.zip"

# pcbnew.Save() injects a phantom top_level_sheets ref into the .kicad_pro
git checkout -- ./*.kicad_pro 2>/dev/null || true
