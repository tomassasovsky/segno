#!/usr/bin/env bash
# Rip up -> DSN -> class widths -> Freerouting -> SES -> refill -> DRC -> gerbers,
# for the encoder ring board (#794). Recipe is the repo's pcb-layout skill.
set -euo pipefail
cd "$(dirname "$0")"

KPY="/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/3.9/bin/python3"
CLI="/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
JAR="${FREEROUTING_JAR:-$HOME/.local/share/freerouting/freerouting-1.9.0.jar}"
PCB="segno_pedal_ring.kicad_pcb"
FAB_LAYERS="F.Cu,B.Cu,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,Edge.Cuts"
WORK="$(mktemp -d)"

# Freerouting 2.x is built for Java 25; 1.9.0 runs on 17, which is what is here.
[ -f "$JAR" ] || { echo "Freerouting jar not found at $JAR"; echo \
  "Get freerouting-1.9.0.jar from github.com/freerouting/freerouting/releases, or set FREEROUTING_JAR."; exit 1; }

# THE POINT OF THIS SCRIPT. KiCad exports every net in one 'kicad_default' class,
# so a plain autoroute returns EVERYTHING at the default 0.30 mm -- including
# +5V_LED, which carries ~1.44 A with 24 WS2812Bs at full white and wants 0.50 mm
# by IPC-2221 (10 C rise, 1 oz external). DRC does not catch an undersized power
# trace, so that mistake ships silently. Splitting the class in the DSN is what
# makes the autorouter hand back the right width instead of it being reapplied by
# hand afterwards and forgotten the next time the board is routed.
#
# 0.55 is a CEILING, not a preference: 0.65 and 0.80 each leave a clearance
# violation on this board. If the layout changes, re-check before raising it.
POWER_NET="+5V_LED"
POWER_UM=550
SIGNAL_UM=300

echo "== 1. rip up existing routing (keeping the stitching vias on file) =="
# The two GND pours are joined ONLY by hand-placed stitching vias, and the rip-up
# below destroys them along with everything else: Freerouting routes nets, not
# zones, so it never puts them back, and the board came out of step 5 with
# "Missing connection between items: Zone [GND] on F.Cu / Zone [GND] on B.Cu".
# That is why they are written out here and restored after the session import.
"$KPY" - "$PCB" <<'PY'
import pcbnew, sys
m = pcbnew.LoadBoard(sys.argv[1])
n = kept = 0
for t in list(m.GetTracks()):
    if t.GetClass() == 'PCB_VIA':
        kept += 1                      # a stitching via: leave it in the DSN so
        continue                       # Freerouting routes AROUND it
    m.RemoveNative(t); n += 1          # Remove() only DETACHES -- the file saves
m.Save(sys.argv[1])                    # unchanged and DRC then lies to you
print("   ripped up %d segments, kept %d vias" % (n, kept))
PY

echo "== 2. export Specctra DSN =="
"$KPY" - "$PCB" "$WORK/board.dsn" <<'PY'
import pcbnew, sys
m = pcbnew.LoadBoard(sys.argv[1])
# Route with MORE margin than DRC demands -- the same lesson route_console_board.sh
# records, which this script was missing. Freerouting works in integer DSN units and
# lands a hair under whatever clearance it is given: exported at the board's own
# 0.2 mm rule it came back with 26 clearance violations, 20 of them genuinely under
# 0.19 mm and the worst at 0.1362 mm. The DSN gets 0.3 mm and the board keeps its
# 0.2 mm check; the difference is the rounding headroom.
# Via geometry too: Freerouting inserts its own vias and takes their size from here,
# and left unset they come back at KiCad's 0.6/0.3 default -- JLCPCB's minimum drill,
# which is no place to sit for no reason.
for _n, _nc in m.GetAllNetClasses().items():
    _nc.SetClearance(pcbnew.FromMM(0.3))
    _nc.SetViaDiameter(pcbnew.FromMM(0.8))
    _nc.SetViaDrill(pcbnew.FromMM(0.4))
assert pcbnew.ExportSpecctraDSN(m, sys.argv[2]), "DSN export failed"
print("   ok (clearance 0.3 mm, vias 0.8/0.4)")
PY

echo "== 3. give the power net its own class =="
"$KPY" - "$WORK/board.dsn" "$POWER_NET" "$POWER_UM" "$SIGNAL_UM" <<'PY'
import re, sys
path, net, pw, sw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(path).read()
m = re.search(r'\n(\s*)\(class (\S+) ([^\n]*)\n((?:.*?\n)*?\1\)\n)', s)
assert m, "no class block in the DSN"
indent, cname, nets, body = m.group(1), m.group(2), m.group(3).split(), m.group(4)
assert net in nets, "%s is not in the exported class" % net
rest = [n for n in nets if n != net]
block = s[m.start():m.end()]
signal = block.replace(' '.join(nets), ' '.join(rest))
power = block.replace('(class %s %s' % (cname, ' '.join(nets)), '(class power %s' % net)
power = re.sub(r'\(width \d+\)', '(width %s)' % pw, power)
# s[m.end():] is NOT optional: it carries the rest of the file, including the
# parens that close the network and pcb scopes. Dropping it produced a DSN that
# Freerouting rejected with 'unexpected end of file' and no session at all.
s = s[:m.start()] + signal.rstrip('\n') + '\n' + power + s[m.end():]
open(path, 'w').write(s)
assert s.count('(') == s.count(')'), 'patched DSN has unbalanced parens'
for c, w in re.findall(r'\(class (\S+)[^\n]*\n(?:.*?\n)*?\s+\(width (\d+)\)', s):
    print("   class %-14s width %s um" % (c, w))
PY

echo "== 4. autoroute =="
java -jar "$JAR" -de "$WORK/board.dsn" -do "$WORK/board.ses" -mp 12 2>&1 \
  | grep -iE "auto-routing|optimization|error" || true
[ -f "$WORK/board.ses" ] || { echo "Freerouting produced no session file"; exit 1; }

echo "== 5. import session + refill zones =="
"$KPY" - "$PCB" "$WORK/board.ses" <<'PY'
import pcbnew, sys
from collections import Counter
m = pcbnew.LoadBoard(sys.argv[1])
assert pcbnew.ImportSpecctraSES(m, sys.argv[2]), "SES import failed"
vias = sum(1 for t in m.GetTracks() if t.GetClass() == 'PCB_VIA')
print("   %d vias on the board after import" % vias)
pcbnew.ZONE_FILLER(m).Fill(m.Zones())
m.Save(sys.argv[1])
w = Counter()
for t in pcbnew.LoadBoard(sys.argv[1]).GetTracks():
    if t.GetClass() == 'PCB_VIA': continue
    w[(t.GetNetname(), round(pcbnew.ToMM(t.GetWidth()), 2))] += 1
for (net, ww), c in sorted(w.items()):
    print("   %-11s %.2f mm x%d" % (net, ww, c))
PY

echo "== 6. DRC =="
"$CLI" pcb drc --format json -o "$WORK/drc.json" "$PCB" >"$WORK/drc.log" 2>&1 || true
tail -2 "$WORK/drc.log"
python3 - "$WORK/drc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
v, u = d.get('violations', []), d.get('unconnected_items', [])
for x in v:
    print("   [%s] %s" % (x['severity'], x['type']))
errs = [x for x in v if x['severity'] == 'error']
print("   violations %d (errors %d), unconnected %d" % (len(v), len(errs), len(u)))
sys.exit(1 if errs or u else 0)
PY

echo "== 7. gerbers =="
"$CLI" pcb export gerbers --output "$WORK/gb" --no-protel-ext --layers "$FAB_LAYERS" "$PCB" >/dev/null
"$CLI" pcb export drill --output "$WORK/gb" --format excellon --drill-origin absolute --excellon-separate-th "$PCB" >/dev/null
( cd "$WORK/gb" && zip -q -X segno_pedal_ring_gerbers.zip *.gbr *.gbrjob *.drl )
cp "$WORK/gb/segno_pedal_ring_gerbers.zip" fab/

# pcbnew.Save() injects a phantom zero-UUID top_level_sheets block into the
# .kicad_pro every single time. It is never a real change.
git checkout -- segno_pedal_ring.kicad_pro 2>/dev/null || true

echo "== done: fab/segno_pedal_ring_gerbers.zip =="
