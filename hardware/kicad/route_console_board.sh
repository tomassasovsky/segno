#!/usr/bin/env bash
# Place -> DSN -> Freerouting -> SES -> refill -> DRC -> gerbers, for console board v2 (#747).
# The recipe is the repo's pcb-layout skill; the gotchas below cost real time to find.
set -euo pipefail
cd "$(dirname "$0")"

KPY="/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3"
CLI="/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
JAR="${FREEROUTING_JAR:-$HOME/.local/share/freerouting/freerouting-1.9.0.jar}"
OUT="out_console"; PCB="$OUT/segno_console_board.kicad_pcb"

[ -f "$JAR" ] || { echo "Freerouting jar not found at $JAR"; echo \
  "Get freerouting-1.9.0.jar from github.com/freerouting/freerouting/releases, or set FREEROUTING_JAR."; exit 1; }

echo "== 1. place =="
"$KPY" console_board_pcb.py --no-export

cp "$PCB" "$OUT/console.placed.kicad_pcb"

echo "== 2. export Specctra DSN =="
# ExportSpecctraDSN returns False and writes NOTHING if any footprint lacks a
# library id -- a bare pcbnew.FOOTPRINT() poisons the whole board silently. That
# is why the mounting holes are real MountingHole:* parts.
"$KPY" -c "
import pcbnew, os, sys
m = pcbnew.LoadBoard(os.path.abspath('$PCB'))
# Route with MORE margin than DRC demands. Freerouting works in integer DSN units
# and lands a hair under whatever clearance it is given -- routing to the 0.2 mm
# rule produced an actual 0.1979 mm and one clearance violation. Widening the rule
# only moves the problem, so the DSN gets 0.3 mm and the board keeps its 0.2 mm
# check; the difference is the rounding headroom.
# Widths as well as clearance. Freerouting takes BOTH from the DSN netclass, not
# from anything in console_board_pcb.py -- so TRACK_W/TRACK_PWR there were purely
# decorative and every one of the 268 tracks came out at Freerouting's own 0.2 mm
# default, including +5V feeding ~1 A of WS2812s (0.2 mm is good for about 0.5 A).
for _n, _nc in m.GetAllNetClasses().items():
    _nc.SetClearance(pcbnew.FromMM(0.3))
    _nc.SetTrackWidth(pcbnew.FromMM(0.6))
_pw = m.GetAllNetClasses().get('Power')
for _net in ('+5V', '+3V3'):
    _ni = m.FindNet(_net)
    if _ni:
        _ni.SetNetClass(_pw) if _pw else None
ok = pcbnew.ExportSpecctraDSN(m, os.path.abspath('$OUT/console.dsn'))
sys.exit(0 if ok else 'DSN export failed')" 2>&1 | grep -viE "wxApp|memory leak|Debug:" || true

# Steps 3-5 are ONE RETRY LOOP, because Freerouting is not deterministic: the same
# DSN routed 0 unconnected on one run and 2 on the next. Reporting whichever roll
# came up is not a result, so the loop keeps going until DRC is actually clean and
# fails loudly if it never is.
BEST=99999
for ATTEMPT in 1 2 3 4 5; do
  echo "== 3-5. autoroute + DRC (attempt $ATTEMPT) =="
  # NOT -Djava.awt.headless=true: Freerouting needs a real display even in batch.
  # -dct 0 kills its 20 s "dialog confirmation timeout" -- pure wall-clock waste.
  ( cd "$OUT" && java -jar "$JAR" -de console.dsn -do console.ses -mp 30 -dct 0 2>&1 \
      | grep -E "Auto-routing|optimization" ) || true

  cp "$OUT/console.placed.kicad_pcb" "$PCB" 2>/dev/null || true
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

echo "== 6. gerbers =="
rm -rf "$OUT/gerbers"; mkdir -p "$OUT/gerbers"
"$CLI" pcb export gerbers --no-protel-ext -o "$OUT/gerbers/" "$PCB" >/dev/null
"$CLI" pcb export drill --format excellon --excellon-separate-th -o "$OUT/gerbers/" "$PCB" >/dev/null
( cd "$OUT" && zip -qr segno_console_board_gerbers.zip gerbers )
echo "wrote $OUT/segno_console_board_gerbers.zip"

# pcbnew.Save() injects a phantom top_level_sheets ref into the .kicad_pro
git checkout -- ./*.kicad_pro 2>/dev/null || true
