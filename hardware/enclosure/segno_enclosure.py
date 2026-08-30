"""Segno — parametric sheet-metal enclosure for the segno Pi loopstation.

Generates a **manufacturing package** for a wedge-shaped floor console modelled on
the "Chewie II" / Sonnit reference (850 x 465 x 100 mm, top sloping toward the
player), housing this repo's standalone build: a Raspberry Pi 4/5 running segno,
the console board v2 (#747), ten foot pedals, the EC11 encoder + diffused LED ring,
SMD LED-strip status indicators (WS2812B segments behind diffuser slots) and a
7" + 16" touchscreen pair. Branded **Segno**.

Construction (see ../segno_enclosure_design.md and
../../docs/plan/2026-06-27-feat-segno-enclosure-rework-plan.md):

  FOLDED LOWER BODY (one rigid tray)        REMOVABLE TOP LID
  - front wall (12) + top flange (ledge)    - faceplate pan (sloped top, all cutouts)
  - rear wall (100) + I/O + vents + flange    + down-turned front/side/rear skirts
  - 2x side panel + top flange (ledge)        (lid screws on the SKIRTS, not the top)
  - bottom plate (folded, vented, Pi/board)   (screens are BONDED, no brackets)
  - 10x inner pedal platform (3D printed)

Foot controls = ten Cherub WTB-006 footswitches (109.87x76.35, 29.3 mm tall with
anti-slip pads; caliper-measured, see hardware/cherub_wtb006_pedal/) standing
toe-forward on printed pedestals, protruding through ~79x113 mm slots. No
top-face fasteners; pedal wiring stays internal. Service = back out the side +
front-lip screws and lift the lid (screens + ring PCB + LEDs go with it; pedals
stay on their platforms).

Geometry is validated by an **assertion suite** (`_check()`) run before any output,
so "the generator runs" means the geometry is valid (width budget, no overlapping
cutouts, platform head-room, screen depth, vent free-area, bezel overlap).

The DOCUMENTS are validated separately by `_verify_drawing_package()`, which runs
on the finished files at the end of a build: through-cut layers actually render,
every drawn fold is in a bend table, no sheet inherits a default material or
quantity, coating masks never sit on a cutting layer, and the sheet-metal zip
carries sheet metal only. That path used to have no checks at all, which is where
the whole RED list of the #775 DFM sweep came from.

Outputs (./out, mm): STEP (assembly + per-part), DXF flat patterns
(CUT + VENT = through-cut, BEND = fold reference, MASK = no-paint, NOTE/ENGRAVE/
SILK = lettering), PDF drawing sheets with a bend table and title block, and
the 2-ply pedal-tile pack (CUT outline + ENGRAVE fills, #946).

Run with the bundled venv (cadquery + ezdxf + matplotlib):
    .venv/bin/python segno_enclosure.py            # check + STEP + DXF + PDF
    .venv/bin/python segno_enclosure.py --report   # report + checks only
    .venv/bin/python segno_enclosure.py --no-step   # DXF + PDF only
    .venv/bin/python segno_enclosure.py --tiles-only  # 2-ply tile pack only
"""
from __future__ import annotations

import math
import os
import sys
import time

# When this run began. The packager holds every shipped file against it so a
# hand-made leftover cannot ride along in a vendor zip -- see pack().
_RUN_STARTED = time.time()

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")

# ===========================================================================
# PARAMETERS — edit here; everything downstream is derived
# ===========================================================================

W        = 850.0     # overall width
FACE_RUN = 397.0     # depth of the TOP PLATE control area (front edge -> the peak),
                     # sized so the screen block sits FRONT_GAP behind the front row
                     # with an EDGE rear margin
H_REAR   = 100.0     # peak height (rear edge of the Top plate = tallest point)
H_FRONT  = 12.0      # front lip height (low end) -- nearly at the floor. The lid front lip
                     # screws horizontally into this wall. DFM CAVEAT: at 12mm the flat wall
                     # is only ~9mm, so the M4 lands ~2.5mm from the fold -- laser the hole and
                     # tap/finish AFTER bending. A fully-clear front screw needs a taller front
                     # (~17mm); an inward screw-ledge is blocked by the front-pedal row (~8mm).

# Rear of the body steps down via an ANGLED TRANSITION SURFACE (a beveled shoulder)
# instead of the Top plate folding straight to the Rear panel. The transition is a
# flange folded forward+up from the (shortened) Rear panel's top, steeper than the
# Top plate; the Top plate's rear edge laps onto it and screws down -- so it is a
# NATURAL SUPPORT for the Top plate.
TRANS_RUN  = 22.0    # transition horizontal run (depth added behind the control area) --
                     # short, so the transition shoulder is only as deep as the lid's
                     # rear lap covers (keeps the ~25deg rake, pulls the rear panel
                     # forward, reduces the bottom-plate depth)
TRANS_DROP = 10.0    # transition vertical drop (peak -> rear-panel top)

T        = 2.0       # sheet thickness (2.0 mm 5052-H32 aluminium)
RI       = 2.0       # inside bend radius (= T, safe for 5052)
KF       = 0.33      # K-factor for bend-allowance development
FLANGE   = 18.0      # return-flange depth (lid side wings + wall top flange)
# Weld-free corner join: internal L-brackets riveted through both walls. These MUST match
# between the base rivet holes, the bracket parts, and the viewer render.
CORNER_RO = 8.0      # rivet offset ALONG each wall from the corner (hug the corner, clear the I/O panel)
CORNER_LEG = 12.0    # bracket leg width (along the wall)
# REAR-corner rivets are STAGGERED between the two legs so a wall-leg rivet and a side-leg
# rivet never sit at the same height (their tips would meet at the corner). Heights are from
# the bottom-plate top.
CORNER_ZR_WALL = (8.0, 40.0, 72.0)    # rear-wall leg rivets (3)
CORNER_ZR_SIDE = (24.0, 56.0)         # side-wall leg rivets (2), interleaved with the wall leg
CORNER_HT      = 80.0                  # rear bracket height (covers the ~90 mm rear wall)
# LID_FRONT_FL (front-lip flange flat) is DERIVED below from the seam solver:
# the lip runs from the fold to the VERY BOTTOM of the base (#760).
# LID_REAR_LAP (rear-lap length) is DERIVED by the rear-seam solver below
LID_SIDE_LIP = 16.0  # inward lip at the bottom of each lid side wall (screws to the base from below)
# Lid -> body fixing scheme:
#   FRONT  : the Top plate's front lip screws horizontally into the Front panel.
#   REAR   : the Top plate's rear edge laps onto the angled TRANSITION SURFACE and
#            screws straight down into hand-tapped M3 holes there (no fixing on the
#            Rear panel). Same joint as the front lip: ONE tap, ONE screw SKU.
#   SIDES  : the Top plate has down-turned WINGS that tuck INSIDE the Side panels
#            for repeatable lateral alignment (locating only, no screws).

# --- foot pedals: Cherub WTB-006, caliper-measured 2026-07-28 (issues #358/#360)
# Reference CAD: hardware/cherub_wtb006_pedal/ + the "Cherub WTB-006 Footswitch"
# Fusion doc. The pedal is a WEDGE: wider + taller at the back (cable end),
# mounted toe toward the player (back = rear/high v). Box model uses the MAX
# cross-section; the taper only ever adds clearance.
PEDAL_W      = 76.35          # case width at the back (tapers to PEDAL_TOE_W at the toe)
PEDAL_TOE_W  = 73.08          # ...and at the toe: the case is a WEDGE IN PLAN too, not
                              # just in height. Anything that has to sit CLOSE to a side
                              # wall must ask pedal_half_width() where along the case it
                              # is; PEDAL_W alone is only honest at the back edge.
PEDAL_D      = 109.87         # case length, back to front
PEDAL_BODY_H = 24.9           # case height at the back (slopes to 22.1 at the toe)
PEDAL_PAD_T  = 2.2            # anti-slip pad thickness, bottom AND top
PEDAL_H      = PEDAL_BODY_H + 2*PEDAL_PAD_T   # 29.3 overall standing height
# One horizontal through-screw per side pins the shell halves; each end has a
# 10mm-dia boss + head protruding 3.45mm from the case wall. The bosses pass
# UNDER the faceplate beside the slot -- checked in _check() 3b.
PEDAL_SCREW_BACK   = 23.24    # boss axis, distance from the case BACK edge (v)
PEDAL_SCREW_Z      = 10.10    # boss axis height above the case bottom (excl. pad)
PEDAL_SCREW_BOSS_D = 10.0     # boss/sleeve outer dia at the wall
PEDAL_SCREW_SPAN   = 83.25    # overall width across both screw heads
# Bottom anti-slip pad footprint (from the user-refined Fusion model 2026-07-28):
# inset from the case back edge, used for the pedestal locating pocket.
PEDAL_PAD_W          = 64.61  # bottom pad width
PEDAL_PAD_D          = 90.0   # bottom pad length
PEDAL_PAD_BACK_INSET = 16.43  # pad rear edge inset from the case back edge
# Four BASE screw holes on the underside, in two rows across the case
# (user-measured 2026-08-16, issue #716). They sit UNDER the anti-slip pad, so
# both rows are dimensioned off the SIDE screw axis -- the only datum you can
# find on the case without pulling the pad. Bolting through these replaces the
# pedestal's provisional gravity+pocket retention.
PEDAL_BASE_ROW_BACK_OFF = 4.0    # rear row, rearward of the side-screw axis
PEDAL_BASE_ROW_PITCH    = 80.0   # rear row to front row, toe-ward
PEDAL_BASE_SPAN_REAR    = 55.75  # centre-to-centre across the rear pair. FOURTH reading,
                                 # and it lands back on the first: 55.75 -> 54.05 -> 54.5
                                 # -> 55.75 (all 2026-08-16). The 54.5 print read narrow,
                                 # which points the same way. Note the front pair has only
                                 # ever been measured ONCE (53.00) -- if the rear needed
                                 # four passes, the front deserves a second.
PEDAL_BASE_SPAN_FRONT   = 53.0   # ...and the front pair (the case tapers toe-ward)
PEDAL_BASE_HOLE_D       = 4.0    # INFERRED, not measured. First called M3-ish (3.0-3.4),
                                 # but the Ø3.5 pin later asked for cannot enter a 3.2 hole,
                                 # so the pin call supersedes it and the hole reads M4-ish.
                                 # Confirm with a drill shank or pin gauge before this
                                 # number reaches the pedestal decks.
PEDAL_BASE_REAR_BACK  = PEDAL_SCREW_BACK - PEDAL_BASE_ROW_BACK_OFF   # 19.24 from the back edge
PEDAL_BASE_FRONT_BACK = PEDAL_BASE_REAR_BACK + PEDAL_BASE_ROW_PITCH  # 99.24 from the back edge
FSW_SLOT_W = PEDAL_W + 2.0    # slot width (u) = 78.35, 1.0mm/side. The side screws DON'T
                              # drive this: their bosses duck ~6.6mm under the faceplate
                              # beside the slot (checked in 3b). The case governs, and its
                              # taper means the widest section crossing the plate plane is
                              # only ~76.05 -- real clearance is >=1.15mm/side. Floor is the
                              # lid-drop alignment over 10 pedals (~0.6mm tolerance stack).
FSW_SLOT_CLR_D = 3.0          # HORIZONTAL front+rear clearance target around the pedal.
# FSW_SLOT_D is defined after SLOPE_ANGLE below: the slot lives in the SLOPED
# faceplate but the pedal is HORIZONTAL, so the on-slope slot depth must be the
# horizontal envelope divided by cos(slope) -- without that the projected
# opening was only 0.16mm/side for the WTB-006 (and 0.28mm/side for the ASP-1).
# Pedal seating rule (issue #373, replaces the old FOOTPLATE_PROUD=12 constant):
# the pedal's BODY TOP (case top, under the top pad) sits FLUSH with the sloped
# faceplate surface at the slot's UPPER (rear) rim; only the pad stands above the
# metal. The plate keeps rising for half a slot past the pedal centre, so with the
# old +12 rule the pad top ended up ~0.8 mm BELOW the rear rim and the pedals read
# sunken. Flush-at-rim lands the pad ~15 mm over the slot centre-line -- taller
# front pedestals as a bonus (more insert depth).
PLATFORM_MARGIN = 2.0         # platform shelf overhang past the pedal footprint (stay within the slot)
PLATFORM_FOOT   = 18.0        # base screw inset band (holes ff/2 from the platform edge)
# The pedal platforms are 3D-PRINTED pedestals (they replaced the folded sheet
# boxes): PETG/ASA, solid walls, >=40% infill. M3 brass heat-set inserts
# (~M3 x 5.7 long x 4.6 OD) melt in from BELOW at the base's PLAT_SCR holes
# (bolted from under the floor). The WTB-006 has NO base screws (side screws
# only), so the deck instead gets a shallow LOCATING POCKET for the bottom
# anti-slip pad -- PROVISIONAL retention: gravity + pocket + foot pressure.
INSERT_PILOT_D  = 4.5         # heat-set pilot bore -- sized for M3 5x5 inserts
                              # (5.0 OD knurled, ~0.5mm interference; the old 4.0
                              # suited the 4.6-OD x 5.7 type)
INSERT_DEPTH    = 6.0         # pilot depth (5.0 insert + 1.0 melt allowance)
PLAT_WALL       = 3.0         # printed perimeter wall (cavity hollowing)
PLAT_DECK       = 8.0         # printed top deck (full insert engagement)
POCKET_DEPTH    = 1.2         # bottom-pad locating pocket depth (< PEDAL_PAD_T)
POCKET_CLR      = 0.6         # pocket clearance over the pad footprint (total)
# --- pedal SLED (issue #719): the pedestal split in two -----------------------
# The pedal is retained by M3s driven DOWN through its four base holes, so the
# screw head lands INSIDE the pedal and the pedal must be open to be fastened.
# But the shell halves are held by one ~83 mm through-pin, which needs ~91 mm of
# clear axial run to insert -- and the widest gap beside a seated pedal is
# 12.4 mm, in either enclosure. So the pedal can only be closed on the bench,
# which means it must be screwed down on the bench too. The deck therefore has
# to come OUT: a flat sled the pedal bolts to, dropped into the tub as one unit.
# Walls are not the blocker and no wall shape fixes this -- the neighbouring
# pedal is.
SLED_T       = 7.0            # >= INSERT_DEPTH 6.0 plus a 1.0 floor under it
SLED_CLR     = 0.2            # slip fit per side in the tub bore. 0.5 printed and
                              # seated but WIGGLED (2026-08-16) -- 1.0 mm of total
                              # play, and since the retention screw only clamps
                              # (its Ø3.5 bore adds +/-0.25 of its own), the bore
                              # fit is the ONLY thing locating the pedal.
                              # Deliberately on the sled, not the bore: the sled
                              # derives from SKIRT_IN_*, so tightening reprints a
                              # 19 g part instead of the tray. If 0.2 binds on a
                              # given printer, open it up -- that is another 19 g,
                              # whereas a too-tight BORE would be a tray reprint.
SLED_BOT_CHAM = 0.6           # bottom-edge lead-in. Elephant foot on the first
                              # layers is what makes a tight printed fit bind at
                              # the very bottom, exactly where it has to seat --
                              # chamfering it is what buys the tighter nominal.
# The BOTTOM anti-slip pad comes off (it has to -- the base holes are under it),
# so the metal base clamps straight onto the sled instead of through 2.2 mm of
# rubber. The tub deck drops by exactly enough to put the metal base back where
# the pad-on design had it, so EVERYTHING above the base -- case top, top pad,
# faceplate slot, the flush-at-rim rule of #373 -- is untouched.
SLED_DECK_DROP = SLED_T - (PEDAL_PAD_T - POCKET_DEPTH)   # 6.0
# --- the SAME idea on the 10-pedal console, with the ring SANDWICHED ----------
# The mini's tub is part of the tray, so it needs no fixing of its own. A console
# ring is a free part, and a ring held only by the faceplate has 0.30 mm of
# vertical play -- the buzz the SKIRT_GAP comment already warns about. So the
# ring gets a floor, the sled lands on it, and the FOUR EXISTING chassis screws
# pass up through clearance holes in that floor and thread into the sled:
# ring + sled + base plate clamped in one joint. No new fastener, and no new or
# moved hole in segno_base.dxf -- the sled footprint swallows the pattern that
# is already there.
CONSOLE_SLED_T = 12.633   # thicker than the mini's, because this sled takes M3x5
                          # from BOTH faces (pedal above, chassis below) where the
                          # mini's only takes them from one. Derived as the FRONT
                          # row's metal-base height less RING_FLOOR; _check() holds
                          # that, so the three numbers cannot drift apart.
# Reseat recalibration (#760): the lid now seats on the SEAM-SOLVER anchor, a
# plane 2.0 mm forward of the frame the 2026-07-28 platform measurements were
# taken against -- i.e. 2*tan(SLOPE_ANGLE) HIGHER. Frozen at the measured
# 3-decimal figure (= round(2*math.tan(math.radians(SLOPE_ANGLE)), 3) = 0.443,
# which lands within 0.02 mm of both rows' re-measured drops); kept a literal so
# the platform heights stay bit-for-bit what is already printed/cut. The full
# story is at FACE_SEAT. One named source now, not a constant pasted per site.
RESEAT_CAL = 0.443
RING_FLOOR = 1.6 + RESEAT_CAL  # front-row ring floor (+#760 reseat recal). The mid row's "floor" is the tall
                          # pedestal deck it already had -- same formula, and only
                          # the front row is tight enough for this to bind.
# Light-baffle TUB around the pedal: the pedestal's walls rise from the deck to
# ~1mm under the sloped faceplate with their INNER faces set back SKIRT_SETBACK
# behind the slot cut line -- from above you see ONLY faceplate, and the reveal
# reads as the slot continuing down a dark channel (the wall face), not as a
# ledge or the enclosure interior. Print BLACK (PETG/ASA).
# The side screw bosses (span 83.25) would cross the wall line, so each side
# wall gets a full-height vertical CHANNEL the boss slides down at drop-in --
# it also guides the pedal into the pad pocket.
SKIRT_SETBACK = 0.4           # wall inner face tucked behind the slot cut line
SKIRT_GAP    = 0.0            # wall top FLUSH on the REAL faceplate underside
                              # (user call 2026-08-18, #760: the 0.3 standoff read
                              # as a visible gap). Risk accepted: an FDM-proud
                              # tower can lift the lid off its flange seats -- if
                              # assembly rocks on hardware, restore 0.3 here (or
                              # sand the tub tops).
# The assembled faceplate seats ABOVE lid_top_z's bare
# slope, and by a row-dependent amount -- measured in "Segno console (populated)"
# (the manufacturing source of truth) 2026-07-28: +1.6 over row 1, +0.7 over
# row 2. Without this the skirt gap came out 2.6/1.7 instead of 1.0.
# Measured seating offset of the REAL plate above the bare geometric slope, from
# the "Segno console (populated)" doc. It used to be a two-point LINE,
# face_drift(v) = 1.96 - 0.00533*v, fitted at the row-1 and old row-2 lines.
#
# That slope was not the plate. -0.00533 is the tan/sin unit error (0.005253) to
# within 1.5 %: the fit was measuring #742's bug, not a physical taper. Re-reduce
# the same three measurements against a sin slope and they land on
# +1.955 / +1.942 / +1.939 -- a CONSTANT, to within 0.016 mm. Three independent
# points agreeing that closely is the evidence that sin is right.
#
# Correcting both together moves platform_h by -0.0003 mm at the front row and
# +0.015 mm at the mid row, so nothing already printed or cut is invalidated.
#
# 2026-08-18 (#760): the lid now seats on the SEAM-SOLVER anchor. The plane the
# 2026-07-28 measurements were taken against sat 2.0 mm rearward (the old doc
# frame), i.e. 2*tan(SLOPE) = 0.443 mm LOWER than the real seat. Re-measured in
# the reseated doc: pedals 0.46 (row 1) / 0.423 (row 2) below the slot rims --
# the uniform +RESEAT_CAL recalibration lands within 0.02 mm of both. Platforms
# printed before this are 0.44 mm short.
FACE_SEAT = 1.95 + RESEAT_CAL

SKIRT_DRIFT_ROW1 = FACE_SEAT   # was 1.6 -- the same #742 fit; see FACE_SEAT
SKIRT_DRIFT_ROW2 = FACE_SEAT   # was 0.5 -- ditto; both rows share one constant now
                         # rearward move + #373 flush-raise: 0.5 leaves 0.3 mm to the
                         # REAL plate at the tub's rear band (probed in the populated doc)
SKIRT_NOTCH_W = 12.0          # cable notch in the rear tub wall, centred (the
                              # WTB-006 cable leaves the case at the back)
SKIRT_OUT_W  = 88.75          # pedestal footprint W (unchanged from the fence rev)
SKIRT_OUT_D  = 115.37         # pedestal footprint D (rear must clear the posts)
# Tub inner opening = the slot outline (projected flat) + setback. Slot depth is
# an on-slope figure; horizontal = *cos(SLOPE_ANGLE). Defined after SLOPE_ANGLE.
SKIRT_BOSS_CH_W    = 14.0     # boss drop-in channel width (boss dia 10 + 4)
SKIRT_BOSS_CH_HALF = PEDAL_SCREW_SPAN/2 + 0.7   # channel floor: swallows the boss tip
SKIRT_BOSS_CH_X    = PEDAL_D/2 - PEDAL_SCREW_BACK   # +31.695: boss axis, rearward of centre

# --- screens (capacitive touch, mounted from BEHIND; aperture < bezel) --------
BIG_BEZEL  = (353.0, 208.0)   # 15.6" panel BODY -- UPERFECT (PROVISIONAL listing 13.9x8.2in, caliper
                              # on arrival): cased portable monitor, connectors exit the SIDE edges,
                              # bezel ~symmetric (no bottom connector strip). Replaces the old bare
                              # panel's 359.5x223.75 (glass + 17mm bottom strip) -- that strip was a
                              # fiction here and pinned the support posts 23mm too far forward.
BIG_W, BIG_H     = 342.5, 193.0   # 15.6" faceplate APERTURE -- ~0.8mm/side inside the 344.16 x 193.59
                              # ACTIVE area so the faceplate lip overlaps the active edge (no light leak).
                              # The decal (active image, 344.2x193.6) stays; the aperture reveals IT, not
                              # the full glass -- the glass bezel (up to 359.5x206.5) hides behind the lip.
BIG_DEPTH  = 8.0              # thin panel (3-6 mm); HDMI/USB driver board mounts flat inside
SMALL_BEZEL = (165.0, 100.0)  # 7" module outline (APROTII: ears 164x99)
SMALL_W, SMALL_H = 153.75, 85.5   # 7" aperture = the 153.75 x 85.5 visible (active) area; reveals it
                              # fully (mounted from behind), no lip overlap on this screen.
SMALL_DEPTH = 12.0           # 7" panel body 9 mm + connectors (APROTII sheet)

# --- 7" screen cradle (3D print, #762) -----------------------------------------
# Floor-anchored printed stand for the APROTII 7": a flat FRAME the module screws
# onto by its corner-ear holes, on two wedge LEGS whose top face is cut at
# SLOPE_ANGLE so the frame lies parallel to the faceplate underside. The glass is
# pressed against the lid by a 2 mm FELT layer on the frame rim (the user's
# compliance call: felt absorbs the height tolerance, the leg slots absorb the
# rest). The screens do NOT lift with the lid on this scheme: service = lift the
# lid, screens + cables stay put.
# All 7"-cradle geometry is DISPLAY-WINDOW-CENTRED. Source of truth: the vendor
# STEP ("lcd 7inch cap 1024 600.stp", user-supplied 2026-08-19). The model's
# front face decomposes into the cover GLASS (164 x 100.1, centred on the
# model origin -- the datasheet's "164x99" was the glass, not the module) and
# a CLEAR DISPLAY WINDOW of 154.5 x 89.1 centred at model (-1.75, +2.5): that
# window is the hard optical boundary, so the aperture centres on IT and it is
# the origin here. STEP-derived window-to-module-edge margins L3.55 / R8.0 /
# B22.6 / T12.6 (user calipers said L4.3/R7.3/B21.8/T16.3 -- top differs by
# 3.7 mm; the powered-screen FIT TEST is the final referee on where the lit
# pixels sit inside the window). FIT-TEST VERDICT (printed 2026-08-19): the
# lit area sits 2.75 mm LOWER than the STEP's window centre (2.75 black strip
# at the aperture top, bottom flush) -- consistent with the calipers. The
# frame origin is therefore re-anchored to the LIT area: every window-centred
# y below carries +2.75 vs the raw STEP values. Reprint the fit test after
# any further change here. Module body over-all: 166.1 x 124.3 (the PCB
# hangs ~22 below the glass). The four M3 TABS (O3.1, 1.7 thick) live
# S7C_GLASS_TO_TABF (5.6, user-measured) BEHIND the glass front, protruding
# above/below the glass -- screws come from the module's front side into
# bosses that rise to the tab plane.
S7C_HOLES = ((-76.80, 55.25), (80.30, 55.25),
             (-76.80, -59.75), (80.30, -59.75))   # tab holes, lit-centred
S7C_MOD_BB   = (-80.80, -64.40, 85.25, 59.90)     # module outline, lit-centred
S7C_TAB_T    = 1.7     # tab thickness
S7C_GLASS_TO_TABF = 5.6   # glass front -> tab FRONT face. USER-MEASURED
                          # 2026-08-19: the vendor STEP said 6.7, but the
                          # round-1 fit test held the glass 1.1 off the plate
                          # ("lower the standoffs by 1.1"). Physical unit wins.
                          # (Glass altitude in the tower is invariant to this:
                          # deck + boss_h + TAB_T + GLASS_TO_TABF collapses to
                          # deck + MOD_DEPTH + GAP.)
S7C_MOD_DEPTH = 14.8      # glass front -> module back (PCB) plane
S7C_GAP      = 0.5     # deck sits this far behind the module back --
                       # only the bosses touch the module (PCB never contacts)
S7C_FRAME_W  = 180.0   # tower outline (centred on the module body)
S7C_FRAME_H  = 138.0
# --- one-piece support TOWER (v3, "more beefy" -- user call 2026-08-19) -------
# A closed wedge box: 4 mm perimeter walls, sloped deck carrying the window +
# tab bosses, wide floor flange with SIX M3 anchors into the base floor (the
# #762 stations). Touch loads on the screen go tabs -> bosses -> deck -> four
# walls -> floor; no slender columns, no bolted joints in the load path.
S7T_WALL   = 4.0       # wall thickness
S7T_DECK   = 5.0       # deck thickness (along the deck normal)
S7T_FLANGE = 12.0      # floor flange width (outward)
S7T_H0     = 66.06     # deck-top height (mm, above the base floor TOP) under the
                       # display-window centre. From the MEASURED underside plane
                       # in Fusion (world: z = 12.43 + tan(SLOPE)*y mm): glass
                       # kisses the lid with ZERO shim; if the print lands low,
                       # M3 washers under the module tabs take up the gap.
S7C_FRAME_T  = 5.0     # frame plate thickness
S7C_WIN_W    = 146.0   # open window: PCB + connectors + backlight switch live
S7C_WIN_H    = 96.0    # here untouched (ports point rearward through the window)
S7C_LEG_SEP  = 158.0   # leg centres, symmetric about COL_U -- ON the frame's side
                       # rails (u +-70..88), clear of the open window
S7C_LEG_W    = 30.0    # leg web width (along u)
S7C_LEG_T    = 6.0     # leg web thickness (along v)
S7C_FOOT_L   = 40.0    # foot flange (along v), 2x M3 to floor anchors (#762)
S7C_FOOT_GAUGE = 24.0  # foot hole spacing along v
S7C_ADJ      = 6.0     # height regulation budget: felt compression (~1) + up to
                       # ~5 of M3 washer shims between leg pad and frame
# (nominal leg height is computed in build_screen7_cradle_steps -- it needs
#  SCREEN_TOP_V, which is defined further down)

# --- LEDs / encoder -----------------------------------------------------------
# Status indicators = SMD LEDs (WS2812B), NOT through-hole: ONE single-LED
# board per indicator pedal (hardware/led_strip/, 16 x 8 mm puck) stuck to the
# faceplate UNDERSIDE with VHB tape; a WHITE PLA pill diffuser insert sets into
# each slot and glows through. Boards daisy-chain pedal-to-pedal with 3 wires
# (5V/data/GND) on the castellated end pads.
LED_SLOT_H = 6.0          # diffuser-slot height (v); corner r = H/2 -> full round ends
LED_SLOT_W = 60.0         # pill window per indicator pedal (one 5050 diffused behind it)
LED_INS_CLR   = 0.2       # diffuser-insert lateral clearance in the slot (total)
LED_INS_PROUD = 0.4       # lens stands this far above the outer skin
LED_INS_FLANGE = 3.0      # shoulder overhang past the slot, all around (seats on the
                          # faceplate UNDERSIDE -- the insert pushes in from INSIDE)
LED_INS_FL_T  = 1.5       # shoulder thickness
LED_INS_POCKET = (6.0, 6.0, 0.8)  # LED nest recess in the shoulder's back face
D_ENC     = 7.2      # EC11 encoder bush (M7 thread; 7.0 was nominal-tight,
                     # the vendor STEP shows the thread OD needs the 0.2, #762)
# EC11 anti-rotation tab: NO keyway in the disc (user call 2026-08-19: the
# slot looked bad -- the tab gets snapped off the EC11 instead; the nut alone
# clamps the disc).
# Encoder knob -- a PURCHASED part: O50 x 18 x O6 bore, black aluminium, plain
# barrel (the owner's chosen knob). These are the VENDOR's numbers, not design
# freedom: KNOB_D is what the ring window was sized around and KNOB_BORE_D is the
# EC11's 6 mm shaft. The only modelled guess is the nut relief -- see
# build_encoder_knob_step.
KNOB_D        = 50.0
KNOB_H        = 18.0
KNOB_BORE_D   = 6.0
KNOB_BORE_TOP = 12.0   # blind bore: stops 6 mm short of the top face
KNOB_NUT_D    = 22.0   # underside relief over the EC11 mounting nut (assumed)
KNOB_NUT_H    = 4.5
KNOB_TOP_FILLET = 1.6
RING_OD   = 67.0     # diffused-annulus ring window, sized over the NeoPixel
RING_ID   = 51.5     # RING 24 (O65.5 / O52.3 / 3.2) -- the ring the owner fitted,
                     # mounted ON the ring board around the EC11. It replaced a
                     # Ring 16 (44.5/31.7) in 2026-08-22; the ring BOARD has not
                     # caught up (it is O60 with its module pads on a O42.1
                     # circle, both Ring-16 numbers) -- see #794.
IND_PITCH = 50.0     # indicator LED pitch

# --- rear I/O -----------------------------------------------------------------
# Issue #743. The Pi moved inboard and its port WINDOW came out, so there is no
# opening in the rear wall and no swappable I/O sub-panel any more: every
# connector is a panel-mount part fitted straight into the FOLDED rear wall
# (segno_base is ONE blank -- floor + 4 walls, weld-free, corner brackets rivet).
# Losing HDMI / Ethernet / SD access from outside is deliberate.
#
# EVERY dimension below carries a provenance in REAR_IO_PROVENANCE. Cutting a
# panel against a number nobody checked is how a 850 mm blank becomes scrap, so
# the unchecked ones are listed by name on the drawing and in the build summary
# rather than hidden behind an optimistic comment.
# Power button: APIELE 19 mm HIGH ROUND momentary (B079HTQ7XD). Stainless, IP65,
# M19x1, 1e6 mechanical cycles, screw terminals, 3-year warranty. MOMENTARY, which
# the soft-shutdown wiring requires -- it drives the Pi's own PWR pads (not a
# GPIO; a Pi 5 cannot wake from one), it does not break power.
#
# Chosen over the UL+CE ZJWZJH (B09CCPDC1C) at HALF the price: that listing's
# UL/CE and IP67 buy nothing here -- this is a dry contact to a 3.3 V logic pad,
# not a mains switch on a wet deck -- while APIELE has 1039 reviews at 4.7 against 9 at
# 3.9, and a TALLER head. Both ship dimension drawings and both land inside the
# constants below, so the choice does not touch the panel.
#
# NOT ILLUMINATED, deliberately. An LED ring forces a flat waterproof face with
# almost no travel, which is exactly the dead "touch pad" feel we were rejecting;
# the domed head is what buys real travel and a positive click. Nothing is lost:
# the button faces AWAY from the player, and a 7" and a 16" screen are far better
# "it is on" indicators than a lamp nobody can see from the playing position.
# faceplate_holes()'s "power state shows on the rear power button" no longer
# holds -- see the note there.
# Both constants deliberately BRACKET the two candidates rather than tracking one,
# so swapping switch does not re-cut the panel:
D_PWRBTN      = 19.5  # M19x1 needs >19.0 to pass. APIELE says "19", ZJWZJH's
                      # drawing says Ø19.5 -- 19.5 accepts both, and a Ø25 bezel
                      # covers the slop. Cutting 19.0 would jam the ZJWZJH thread.
PWRBTN_HEAD_D = 25.2  # hex bezel ACROSS CORNERS: ZJWZJH 25.2, APIELE 25.0. The
                      # corners are what has to clear a neighbour, not the flats.
# Fuse: a GENERIC 5x20 screw-cap panel holder, by decision -- it is a small black
# cap on a rear panel, the one station where generic costs nothing to look at.
# That class is consistently Ø12.0, NOT the Ø12.5 the SCI R3-11 wants, and the
# error is not symmetric: a 12.5 hole around a 12.0 thread sits loose and lets the
# holder spin when the cap is turned. Plastic body with a metal cap -- which is
# also right, since an insulating body around a live fuse in an earthed metal
# chassis beats a metal one. Rated 10 A / 250 V AC, far above this job.
#
# These holders ship FAST-BLOW fuses. See the T5A slow-blow note in the design
# doc: the two bucks' inrush will nuisance-blow a fast fuse at switch-on.
D_FUSE    = 12.0     # NeoLum B0GF33P9FF: "12 mm diameter aperture"; B0DLKJ813T:
                     # "Installation Hole 12mm". Two independent listings agree.
D_GND     = 6.5      # M6 earth / bond stud
# The inlet is USB-C PD (#754): one 20 V PD contract feeds the whole console and
# two bucks make 5 V at the load. It replaces a 9 V barrel because the barrel was
# only ever the buck's input -- nothing in the design uses 9 V -- and because a
# USB-C panel coupler takes the SAME D punch as the TRS jacks, so the inlet stops
# being a hole type of its own. Part: QIANRENON D-type USB-C F/F, 100 W, 10 Gbps
# (Amazon B0CQ4VD2N2). 10 Gbps matters: it means all 24 ways are wired, so CC
# passes and PD can negotiate. A charge-only coupler drops CC and nothing works.
# The chosen TRS is a D-SERIES jack (MEIRIYFA B0G5GHCCHM, "fits standard D Series
# panel mount designs"), NOT a threaded-bushing jack -- so it takes the Neutrik D
# punch, a Ø24 bore with two M3 fixings, not a Ø10 round hole.
D_TRS_BORE       = 24.0  # Neutrik: "standardized D sized 24 mm panel cutout"
D_TRS_SCREW_D    = 3.2   # M3 clearance
# The D-series flange carries its two M3 on DIAGONALLY OPPOSITE corners, not a
# horizontal pair. Pattern SOURCED 2026-08-18: the QIANRENON PD coupler states
# "XLR panel / D-type panel mounting dimensions (19mm*24mm)" on its listing --
# 19 across, 24 vertical, one hole per diagonal corner: centres at
# (+-9.5, -+12) about the bore. Screw centre sits sqrt(9.5^2+12^2)=15.3 from
# the bore centre, 1.7 clear of the Ø24 bore edge + M3 radius, so _check()'s
# bore-edge rejection passes. A D shell is point-symmetric about the bore, so a
# part whose holes run the other diagonal mounts by turning it 180 deg -- one
# cut diagonal fits every D shell.
D_TRS_SCREW_DIAG = (19.0, 24.0)   # (du, dz) between the two diagonal M3 centres
D_TRS_KEEPOUT    = 30.4  # bore + the M3 pair
D_PD_BORE = D_TRS_BORE   # same D-series punch as CTRL_1/CTRL_2 (same M3 pair too)
USB3_SQ       = 22.1 # USB 3.0 panel coupler: square across flats
USB3_CORNER_D = 24.1 # ...corners on this circle -> corner radius derived below
USB3_FLANGE_D = 28.5 # flange OD. This, not the cutout, is the real keep-out
MIDI_BODY_D      = 15.1  # REAN NYS325 panel cutout (distributor spec)
MIDI_SCREW_PITCH = 22.2  # RS attribute "Mounting Hole Distance 0.874 in" = 22.2
MIDI_SCREW_D     = 3.2   # M3 clearance

# What each rear-I/O dimension actually rests on. "measured" = the user's own
# calipers or dimensioned photo; "datasheet" = manufacturer or distributor
# figure, with the source named; "UNCONFIRMED" = nobody has checked it.
REAR_IO_PROVENANCE = {
    "D_PWRBTN":          "datasheet: APIELE + ZJWZJH drawings, M19x1; 19.5 brackets both",
    "PWRBTN_HEAD_D":     "datasheet: APIELE 25.0 / ZJWZJH 25.2 across hex corners; 25.2 brackets both",
    "D_FUSE":            "datasheet: two generic 5x20 screw-cap listings, 12 mm aperture",
    "D_GND":             "design: M6 stud clearance",
    "D_PD_BORE":         "datasheet: QIANRENON B0CQ4VD2N2 states D-type/XLR panel "
                         "dimensions 19x24 mm; the 24 mm bore is the D standard",
    "D_TRS_BORE":        "datasheet: neutrik.com NC3FD-L-1, 'standardized D sized 24 mm panel cutout'",
    "D_TRS_SCREW_DIAG":  "datasheet: QIANRENON B0CQ4VD2N2 'D-type panel mounting "
                         "dimensions (19mm*24mm)'; MEIRIYFA B0G5FZNH49 is the same "
                         "standard D shell (photos show the diagonal pair + screws)",
    "D_TRS_KEEPOUT":     "design: bore + the M3 pair",
    "D_TRS_SCREW_D":     "datasheet: D-series fixings are M3",
    "USB3_SQ":           "measured: user, coupler BODY across flats (PENGLIN B09VGK59XQ: "
                         "a round M24 barrel with two anti-rotation flats; NUT-mounted, "
                         "no screws -- the square cut grips the flats)",
    "USB3_CORNER_D":     "measured: user, coupler BODY across corners (= thread OD)",
    "USB3_FLANGE_D":     "measured: user, flange OD",
    "MIDI_BODY_D":       "datasheet: REAN NYS325, Ø15.1 panel cutout (Farnell/CPC)",
    "MIDI_SCREW_PITCH":  "datasheet: RS 70088596 attribute 'Mounting Hole Distance "
                         "0.874 in' = 22.2 (cutout attr 0.595 in = 15.1 anchors the template)",
    "MIDI_SCREW_D":      "datasheet: DIN-5 chassis sockets take M3",
}

def rear_io_unconfirmed():
    """Rear-I/O dimensions that rest on nothing yet, name -> value. Non-empty is
    NOT a build failure -- it is a do-not-cut-the-panel-yet list."""
    return {k: globals()[k] for k, v in REAR_IO_PROVENANCE.items()
            if v.startswith("UNCONFIRMED")}

# 22.1 / 24.1 are the coupler's BODY, so the hole has to be bigger than both or
# the part will not enter at all. 0.2 per side is deliberately the TIGHT end of a
# panel fit: the errors are not symmetric. Too tight is one hole eased with a file
# in a minute; too loose either rattles under the Ø28.5 flange or, if the coupler
# turns out to be a snap-in, never grips and cannot be undone on a cut blank.
USB3_FIT = 0.2

def _rr_from_corner_circle(side, corner_d):
    """Corner radius of a rounded square of `side` whose corner arcs are tangent
    to a circle of diameter `corner_d` -- i.e. that circle passes through the
    corners. Solves (side/2 - r)*sqrt(2) + r = corner_d/2 for r."""
    a, rr = side/2.0, corner_d/2.0
    r = (a*math.sqrt(2) - rr) / (math.sqrt(2) - 1.0)
    assert 0.0 < r <= a, (
        f"USB3: corner circle {corner_d} is not compatible with a {side} square "
        f"(derived corner radius {r:.2f})")
    return r

USB3_CUT_SQ = USB3_SQ + 2*USB3_FIT
USB3_CORNER_R = _rr_from_corner_circle(USB3_CUT_SQ, USB3_CORNER_D + 2*USB3_FIT)

# The old REAR_WIN_U did two jobs -- it placed the window AND anchored the board,
# Pi and buck inside. Those are now separate: the internal layout keeps its 175
# anchor (nothing inside moves because of a rear-panel change), and the connector
# cluster is free to use as much of the wall as it needs. It needs it: swapping
# the TRS to D-series took its keep-out from 16 to 30.4 and squeezed the gaps to
# 7.2 mm on the old 290 strip. The vents give the width back -- they run at 4x the
# free-area minimum, and _check() holds that.
BOARD_ANCHOR_U = 175.0  # main board / buck datum. NOT the connector cluster,
                        # and since #743 not the Pi either -- see pi_mount().
REAR_IO_SPAN   = 360.0  # cluster width; REAR_IO_Z set below (= wall mid-height)
REAR_IO_U      = None   # set to SCREEN_16_U below -- the panel is CENTRED ON THE
                        # 16" SCREEN, which is the thing a player lines it up with
                        # by eye. It was RIGHT-justified against EDGE. It used to be left-justified
                        # at 210, from when the console board lived under the 7"
                        # screen: the board terminates five of these stations, so the
                        # cluster follows the board. Both boards now sit under the
                        # 16" screen (see BOARD_U / pi_mount), which took the Pi
                        # ribbon from 402 mm to 30 mm. _check() asserts the
                        # right-justified form, so this constant cannot drift.

# --- rear I/O sub-panel (#751) ------------------------------------------------
# The cluster is DISMOUNTABLE: the wall carries a window, and a bolt-on panel
# carries the nine connectors. It was folded straight into the wall for one
# revision (77e0ef9b) on the grounds that the Pi's port window had gone away and
# the sub-panel had no home -- but that reasoning was about the WINDOW, not about
# the connectors. Cut into the wall, the loom can only be worked on inside a
# 850x423 box through a 46 mm slot, and a single stripped thread scraps the base.
# On a panel it lifts out, gets soldered on a bench, and a mis-drilled panel costs
# a panel. It is NOT a folded face of the base; it needs its own bond -- see
# docs/design/console-grounding-and-bonding.md.
REAR_WIN_CLR        = 3.0   # window clearance around the outermost station cutouts (v)
REAR_WIN_SIDE_CLR   = 6.0   # window side padding BEYOND the outermost station KEEP-OUTS
                            # (u). The window used to clear only the cutouts, which let
                            # the PD coupler's keep-out poke 0.2 past the opening's edge
                            # -- the flange visually kissed the window and there was no
                            # room to offer it up square (user call, 2026-08-18). Sides
                            # clear what has to PASS (flanges, nuts), not just the holes.
REAR_WIN_H_MIN      = 46.0  # minimum window height. Derived tight, the opening came
                            # out 30 mm on a 90 mm wall -- a letterbox that makes
                            # every connector a knuckle-scrape to reach and looks
                            # like a mistake next to the panel around it. 46 is the
                            # height the sub-panel carried before it was retired.
REAR_PANEL_OV       = 15.0  # panel overlap past the window, every side
REAR_PANEL_BOLT_OFF = 9.0   # bolt centres past the window edge (>=4 mm inside the
                            # panel edge at OV 15, and clear of every flange)
MASK_BOND_D         = 12.0  # bare bonding land around ONE panel bolt, both faces.
                            # The panel carries the TRS sleeves (which ARE board
                            # GND) and both USB coupler flanges, and it bolts to a
                            # powder-coated wall through four painted holes -- so
                            # without this it is a floating metal plate holding
                            # every shield in the machine. ONE land, not four:
                            # a single defined path, same rule as H1 on the board.

# --- ventilation / mounting ---------------------------------------------------
VENT_SLOT   = (40.0, 4.0)     # one louvre slot (l x w)
VENT_PITCH  = 8.0             # slot row pitch (web = pitch - slot = 4mm = 2T)
VENT_FREE_AREA_MIN = 4000.0   # mm^2 minimum open area (bottom + rear), ~40 cm^2
STANDOFF_H  = 15.0            # under-board gap: the THT leads + buck-module header pins
                              # hang ~4.5mm below the PCB, so 10mm left ~5mm of real
                              # airflow; 15mm (standard M3 brass) restores the margin
PI_STACK_MID = 9.7            # USB/RJ45 stack centreline above the Pi PCB BOTTOM
                              # (1.6 PCB + ~8.1 to the middle of the 16mm-tall stack);
                              # PI_RISER_H is derived from it below REAR_IO_Z
PI_HOLES    = (58.0, 49.0)    # Raspberry Pi 4/5 mounting-hole rectangle (M2.5)
# The board on this plate is the CONSOLE BOARD v2 (#747) -- the RP2350 board that
# carries the MIDI front end and a header for every rear-panel connector. It is not
# the V1 THT Pro Micro board any more; that one stays with the standalone pedal,
# which is the product it was designed for.
#
# These two numbers are NOT measured or copied. They are checked in _check() against
# hardware/kicad/out_console/console_board_mount.json, which the board generator
# writes -- the mirror of the rear_io_stations.json handoff going the other way. The
# plate spent a while drilling 85 x 87 for a board whose holes had moved to 89.5 x
# 89.5, and neither part had been ordered only by luck.
BOARD_HOLES = (89.5, 89.5)    # M3 mount rectangle (console board v2, 5 mm inset)
BOARD_SIZE  = (99.5, 99.5)    # board outline (for the 3D render + clearance gates)
BOARD_MOUNT_JSON = os.path.join(HERE, "..", "kicad", "out_console",
                                "console_board_mount.json")
# What actually stacks up at the Pi, bottom to top (#743):
#   plate -> STANDOFF_H -> N07 NVMe bottom board -> its SSD -> standoffs -> Pi PCB
#   -> the tallest thing on top (the USB-A double stack beats the Active Cooler).
# GeeekPi N07 (B0CWD266XR) is a BOTTOM board on an FPC: it costs height, not
# footprint. The official Active Cooler is ~10 above the PCB, so the USB-A stack
# still sets the number.
PI_N07_H    = 7.6             # what sits between the riser top and the Pi: the N07
                              # PCB (1.6) + the 6 mm male/female extender that
                              # threads into the riser through it
PI_TALLEST  = 16.0            # USB-A double stack above the Pi PCB
BOARD_STACK_H = 16.0          # PCB + the tallest thing on it (Pro Micro on its
                              # header, JST shrouds). Same 16 the 3D render
                              # blocks it out at. #743 made this load-bearing:
                              # moving the Pi forward slid it OVER the board, so
                              # PI_RISER_H - (STANDOFF_H + this) is the only gap
                              # between them, and _check() holds it >= 3.
# --- rubber feet (issue #743) -------------------------------------------------
# Screw-on, M4 from inside the case. The head therefore lands on the plate's TOP
# face, so no fixing may sit under a pedestal -- the rings have to seat flat on
# that same face.
# At the old x=45 the two front fixings landed squarely under REC/PLAY and
# TRACK4, and the first fix was to relieve the ring floor and pocket the sled.
# Unnecessary: the front corners are CLEAR. The corner brackets are at the REAR
# (y 405..419), not the front, so the 24.6 mm margin outboard of the end tubs is
# free. Moving the fixings into it removes the interference instead of
# accommodating it -- and widens the stance from 756 to 817 mm as a bonus.
D_FOOT       = 4.5   # M4 clearance for the foot screw. The foot is a uxcell
                     # buffer foot, Ø18 (chassis face) x Ø15 (floor) x 5 tall,
                     # rubber with a metal washer insert; the screw is NOT
                     # supplied and goes DOWN from inside, so the head sits on
                     # the plate's top face -- hence the clear-of-every-pedestal
                     # rule below rather than a countersink, which a 2.0 mm
                     # plate cannot take without leaving a knife edge.
FOOT_INSET_X = 14.3  # from each side. Window is 8.2..20.4: bend relief (RI+T) +
                     # hole radius at the low end, tub edge 24.6 at the high end.
                     # _check() holds it inside that, and holds every fixing clear
                     # of every pedestal.
FOOT_INSET_Y = 45.0  # from front and rear

# --- fasteners ----------------------------------------------------------------
D_M3      = 3.2      # M3 clearance (Pi/board standoffs)
D_M2      = 2.4      # M2 clearance (external buck standoffs)
D_M4      = 4.3      # M4 clearance (bottom plate -> shell)
# The whole lid fixes with ONE screw SKU: M3 into hand-tapped Ø2.5 pilots (front
# lip AND rear lap seam -- user call 2026-08-18, no clinch nuts anywhere). Taps
# are cut AFTER powder-coat, so no thread masking is needed.
# --- powder-coat masking (annotation only; issue #396) ---
# The earth stud needs a bare land on both faces or the ring terminal bonds to paint.
MASK_GND_D = 20.0    # bare bonding land around the M6 earth stud
PEM_EDGE  = 8.0      # min centre-to-edge distance (named for the retired PEM
                     # scheme; KEPT as the seam-row solver input so the 9 hole
                     # stations stay exactly where every doc and model has them)
R_FILLET  = 3.0      # inside corner radius on rectangular cutouts

# ===========================================================================
# DERIVED GEOMETRY
# ===========================================================================

D           = FACE_RUN + TRANS_RUN + 2*T  # overall depth: +2T so the bottom plate
                                          # BD (= D-2T) = FACE_RUN+TRANS_RUN, i.e. the side
                                          # wall's rear edge spans TRANS_RUN at TRANS_ANGLE,
                                          # matching the transition flap exactly
# Profile A: the Top plate rises to the PEAK at its rear edge (H_REAR), then the angled
# transition DROPS from the peak down to the shorter Rear panel at the very back.
REAR_WALL_H = H_REAR - TRANS_DROP     # Rear panel height (reduced; below the peak)
REAR_IO_Z   = REAR_WALL_H / 2.0       # connector cluster centreline up the rear wall
# The Pi used to ride bespoke 35.3 mm risers, sized so its rear port stack centred
# in the old I/O window. #743 deleted the window, and moving the Pi under the 16"
# screen (see pi_mount) took away the second reason -- it no longer has to clear
# the main board either. So it drops to the SAME plain M2.5 standoffs the board
# uses: one fastener kind instead of two, a lower stack, and more air over it.
# The Pi does NOT ride the same 15 mm standoff as the board. Its stack is
# 12 mm standoff -> N07 NVMe board -> 6 mm male/female extender -> Pi, so the first
# standoff is 12 and the Pi PCB ends up 12 + 1.6 + 6 = 19.6 above the plate. It was
# tied to STANDOFF_H when the N07 was a guess; it is a bought part now.
PI_RISER_H  = 12.0
PI_STACK_H  = PI_RISER_H + PI_N07_H + 1.6 + PI_TALLEST   # plate -> tallest on the Pi
SLOPE_DROP  = H_REAR - H_FRONT
L_SLOPE     = math.hypot(FACE_RUN, SLOPE_DROP)            # Top-plate sloped length
SLOPE_ANGLE = math.degrees(math.atan2(SLOPE_DROP, FACE_RUN))
# Pedal slot depth ON THE SLOPE: horizontal envelope / cos(slope) (see pedal block).
FSW_SLOT_D = (PEDAL_D + FSW_SLOT_CLR_D) / math.cos(math.radians(SLOPE_ANGLE))
# Tub inner opening (see the pedal block): slot outline projected flat + setback.
SKIRT_IN_W = FSW_SLOT_W + 2*SKIRT_SETBACK                                    # 79.15
SKIRT_IN_D = FSW_SLOT_D * math.cos(math.radians(SLOPE_ANGLE)) + 2*SKIRT_SETBACK  # 113.67
TRANS_LEN   = math.hypot(TRANS_RUN, TRANS_DROP)          # transition facet length
TRANS_ANGLE = math.degrees(math.atan2(TRANS_DROP, TRANS_RUN))   # transition rake (from horizontal)

def bend_allowance(angle_deg, t=T, ri=RI, k=KF):
    return math.radians(angle_deg) * (ri + k * t)

BA90 = bend_allowance(90.0)

def dev_deduct(angle_deg):
    """Per-flap development deduction for a fold of the given rotation angle
    (exact K-factor development, bend line on the mold line, centre-line
    convention): flap flat = target outer length - dev_deduct(angle)."""
    a = math.radians(angle_deg)
    return (RI + T) * math.tan(a / 2.0) - bend_allowance(angle_deg) / 2.0

DEV90 = dev_deduct(90.0)              # = 1.911 for T2/RI2/K0.33 (issue #237: the old
                                      # T + K*T = 2.66 over-deducted every 90 deg bend
                                      # ~0.75mm, leaving all walls short of nominal)
# Front-lip screw HEIGHT on the flat pattern, shared by both encodings of the
# joint: the base's front wall (tap pilot, dxf_base._fscrew_flat) and the lid's
# front lip (clearance, dxf_faceplate). One tap, one screw SKU, one height --
# it centres the hole on the developed 9 mm front wall. Was written twice, once
# as (H_FRONT-bdd)*0.5 and once as (H_FRONT-DEV90)/2.0 (bdd == DEV90, so bit-
# identical); the assert pins it so the next H_FRONT change is a conscious one.
FRONT_SCREW_Z = (H_FRONT - DEV90) / 2.0
assert abs(FRONT_SCREW_Z - 5.045) <= 0.01, \
    f"FRONT_SCREW_Z {FRONT_SCREW_Z:.4f} drifted from the frozen 5.045 mm"
# The lap must STOP SHORT of the wall->flange bend knuckle: the flange's outer
# surface starts curving (RI+T)*tan(fold/2) = 2.58 before the outside mold
# corner, so the lap tip stops there plus a margin -- as LONG as possible while
# still lying flat on the flange.
KNUCKLE_CLEAR = 3.5
FP_W = W - 2.0 * T                    # control-area width (schedule coordinate frame)
LID_W = W - 0.2                       # lid blank full outer width: covers the wall tops,
                                      # flush with the side skins (issue #237)
LID_OX = (LID_W - FP_W) / 2.0         # schedule content offset inside the wider blank
FP_V = L_SLOPE                        # faceplate length up the slope (control area)

# --- rear-seam development solver (issue #237) --------------------------------
# Side view of the FOLDED part: Z = depth from the front wall OUTER face,
# Y = height above the bottom plate OUTER face. Every position is derived from
# the flats' own developed geometry (bend lines + dev_deduct), NOT from the
# idealized design polygon -- development shifts the real planes a couple of mm
# from the polygon, and the seam must close on the planes the flats actually
# produce.
_ra, _rth = math.radians(SLOPE_ANGLE), math.radians(TRANS_ANGLE)
DD_LIP = dev_deduct(90.0 - SLOPE_ANGLE)         # lid front-lip fold (77.5 deg)
DD_LAP = dev_deduct(SLOPE_ANGLE + TRANS_ANGLE)  # lid rear-lap fold (36.9 deg)
DD_TR  = dev_deduct(90.0 - TRANS_ANGLE)         # wall -> flange fold (65.6 deg)
_bd  = D - 2.0 * T                              # bottom plate flat depth (= BD)
# lid front mold corner (lip outer face x lid outer skin), lip hugging the wall.
#
# MEASURED 2026-08-21 (#775): "hugging" is literal -- in the folded assembly the
# lip's inner face and the front wall's outer face are COINCIDENT, lid<->base
# minimum distance 0.0000 mm at mid-wall height. Both are OUTSIDE faces, so both
# take powder coat (~0.06-0.10 mm each): the joint is ~0.16 mm interference
# before a single tolerance is counted, on the one seam that cannot be reworked
# once the part is finished.
#
# NOT fixed by moving this corner. _cfy sets the flange LENGTH, not its standoff
# (raising it just drops the lip tip below the base floor -- tried, reverted).
# The standoff would have to come from shifting the floor's front bend line,
# which re-bases every feature on the base flat, or from lengthening the lid
# plate, which moves all the faceplate content. Both are large ripples through a
# solver whose two halves currently agree to 15 decimals, for a 0.3 mm gap that
# press-brake tolerance (+/-0.5 deg over a 12.19 mm lip = +/-0.11 mm) swamps
# anyway. So this is specified as a FIT, not carried as a CAD dimension:
# LIP_FIT_CLEAR is the number the drawing asks the shop to hold, and the owner's
# call (2026-08-21) is a tight fit with everything coated -- no masking.
LIP_FIT_CLEAR = 0.3    # mm, lip inner face -> wall outer face, AFTER coating
_cfy = H_FRONT - T * math.tan(_ra) + T / math.cos(_ra)
_cfz = -DEV90 - T
# Front-lip flange: the lip TIP lands flush with the base's bottom face (z=0),
# covering the whole front -- wall, floor edge and all (user call 2026-08-18,
# #760; the old 9mm flange stopped ~3.2mm short). A flat point f past the bend
# line lands at station f + DD from the mold corner, so tip-at-zero needs
# flat = corner height - DD_LIP.
LID_FRONT_FL = _cfy - DD_LIP
_mtop   = FP_V + DD_LIP + DD_LAP                # lid top-plate mold length
RIDGE_Z = _cfz + _mtop * math.cos(_ra)          # lid rear mold corner (the ridge)
RIDGE_Y = _cfy + _mtop * math.sin(_ra)
_zw  = _bd + DEV90                              # rear wall OUTER plane depth
_y90 = RIDGE_Y - (_zw - RIDGE_Z) * math.tan(_rth)   # lap outer  x  wall outer
YC_TRANS = _y90 - T / math.cos(_rth)            # transition OUTSIDE mold corner: the
                                                # flange outer sits ONE SHEET below
                                                # the lap outer so the lap rests ON it
HR_FLAT = YC_TRANS - DEV90 - DD_TR              # rear wall web, developed flat
RIDGE_CLEAR = 2.0                               # flange tip stops this short of the
                                                # ridge mold corner (lap-bend zone)
# along-facet axis d: from the ridge mold corner DOWN the lap/flange facet.
# A point at flat distance f beyond a bend line lands at facet station f + DD
# from that bend's mold corner (the straight flap starts sb past the corner but
# only BA/2 past the line) -- so a target station d needs flat = d - DD.
D_WALL    = (_zw - RIDGE_Z) * math.cos(_rth) + (RIDGE_Y - YC_TRANS) * math.sin(_rth)
HT_FLAT   = (D_WALL - RIDGE_CLEAR) - DD_TR      # transition flange, developed flat:
                                                # as LONG as possible (to the ridge
                                                # clearance, NOT just TRANS_LEN --
                                                # development stretches the facet)
D_FL_TIP  = D_WALL - (HT_FLAT + DD_TR)          # flange tip (= RIDGE_CLEAR)
D_LAP_TIP = D_WALL - KNUCKLE_CLEAR              # lap tip: clear of the wall knuckle
# screw row: centred on the lap/flange overlap, pushed down-facet if needed to
# keep PEM_EDGE from the flange tip (solved for the retired PEM scheme; frozen --
# generous for a tapped hole, and every model carries these stations)
D_SEAM_SCREW = max((D_FL_TIP + D_LAP_TIP) / 2.0, D_FL_TIP + PEM_EDGE)
LID_REAR_LAP = D_LAP_TIP - DD_LAP               # lap developed flat length
LRL = LID_REAR_LAP
SEAM_LAP_V = LID_FRONT_FL + FP_V + (D_SEAM_SCREW - DD_LAP)     # lap screw row (lid flat v)
SEAM_TAP_V = HR_FLAT + (D_WALL - D_SEAM_SCREW) - DD_TR         # flange tap-pilot row (base
                                                               # flat, from the rear
                                                               # wall bend line)
# hard DFM guards: a parameter tweak must not silently collapse the lap/flange
# overlap or push the screw row off the lap (holes in air pass no other check)
assert HR_FLAT > 0 and LID_REAR_LAP > 0, "seam solver: degenerate rear seam"
assert D_FL_TIP + PEM_EDGE <= D_SEAM_SCREW <= D_LAP_TIP - (3.4 / 2.0 + 2.0), (
    f"seam screw row d={D_SEAM_SCREW:.2f} outside the lap/flange overlap "
    f"[{D_FL_TIP:.2f}, {D_LAP_TIP:.2f}] with edge margins")
assert HR_FLAT > max(CORNER_ZR_WALL) + T + 2.0, (
    "rear web too short: corner-bracket rivet holes cross the transition fold")

def lid_top_z(v):
    """Z of the Top-plate surface at control-area depth v (0..FP_V).

    v is measured ALONG THE SLOPE, not in plan: FP_V == L_SLOPE (406.64), which is
    the faceplate's own length, not FACE_RUN (397). Rising a distance v along a
    plane inclined at SLOPE_ANGLE lifts you by v*sin -- so sin, not tan.

    This used to divide by FACE_RUN, i.e. treat an along-slope v as a horizontal
    run, overstating the height by v*(tan - sin) = 0.00525*v -- 0.36 mm at the
    front row, 1.42 mm at the mid row, 1.95 mm at the back of the 16in aperture
    (issue #742). face_drift's docstring already named the bug ("lid_top_z uses
    the tan-slope shortcut, the real plate follows sin") and a two-point fit was
    used to cancel it; see FACE_SEAT for why that fit collapses to a constant now.
    """
    return H_FRONT + min(v, L_SLOPE) * math.sin(math.radians(SLOPE_ANGLE))

def lid_under_z(v):
    """Z of the faceplate UNDERSIDE at depth v."""
    return lid_top_z(v) - T

# ===========================================================================
# CUTOUT SCHEDULE  (faceplate local: u=0..FP_W L->R = player's left->right,
#                   v=0..FP_V front->rear)
# ===========================================================================

# Two pedal rows, faithful to the reference: a FRONT row of 8 (4 transport |
# 4 tracks, with a centre gap) and an upper CENTRE pair (CLEAR/BANK). Each pedal
# is a whole Cherub WTB-006 on a printed pedestal; a status LED sits directly ABOVE each
# (aligned in u). CLEAR/BANK ride centre so the 16" screen still fits depth-wise.
EDGE         = 30.0      # uniform edge margin (sides / rear)
FRONT_PEDAL_MARGIN = 10.0 # front-row pedals sit this close to the front edge
LED_GAP      = 12.0      # status-LED offset behind a pedal (toward rear)
SILK_H       = 25.0      # silkscreen cap height -- SAME for every label (a too-wide word
SILK_CW      = 0.66      # gets squished horizontally). bold char advance / cap height.
PEDAL_ROW1_V = FRONT_PEDAL_MARGIN + FSW_SLOT_D / 2.0   # front row pulled to the edge
# The platform stack (platform_foot_holes and everything on it) converts lid-v
# to plan as v*cos(SLOPE) -- but the DEVELOPED lid's content v=0 does NOT land
# at plan 0: the lip hugs the wall at -(DEV90+T) and the flat starts DD_LIP past
# the front mold corner (rear-seam solver, #237). Net: raw-v apertures cut
# ~2.6mm forward of where the floor actually puts the pedals, and the pedal rear
# edge fouls the slot. The slot cut ALONE carries the correction (#760): labels,
# LED pills, screens and the platform stack keep the frozen approved layout.
PEDAL_AP_DEV = (DEV90 + T) / math.cos(_ra) - DD_LIP
# The slot grows FORWARD only, back to the APPROVED front gap of 1.93mm: the
# pedal's front lip carries the case screws and needs that room, but on the
# sloped plate a bigger gap drops the slot's front rim BELOW the pedal floor
# (each mm of gap lowers the lip by tan(SLOPE)). At 1.93mm the floor sits
# +0.16mm on the lip -- visually flush, exactly the approved relation now that
# the pedal rides +RESEAT_CAL on the reseated plate. Rear clearance stays nominal. (#760)
# NOTE: this front-gap term is the SAME reseat concept, but frozen at 2-decimal
# 0.43, not RESEAT_CAL's 0.443. Folding it in would shift the slot's front rim
# ~0.013 mm and is a real geometry change -- out of scope for this zero-delta
# dedup. Reconcile 0.43 vs RESEAT_CAL in the #762 caliper batch, not here.
FSW_FRONT_EXTRA = 0.43 / math.cos(_ra)
# 7" screen, LED ring and encoder share ONE vertical centre-line (COL_U, defined
# with the pedal layout below): the gap between pedals 1 and 2.
# SCREEN_TOP_V is FROZEN at the value the console was built around (the screens,
# decals and the Fusion "Segno console (populated)" doc all embody it). When the
# pedal slot deepened for the Cherub WTB-006 (103 -> 112.87), the front gap
# absorbed the change instead of growing the console: FRONT_GAP is now DERIVED
# and asserted >= 40 in _check().
SCREEN_TOP_V = 371.0
FRONT_GAP    = SCREEN_TOP_V - BIG_H - (PEDAL_ROW1_V + FSW_SLOT_D / 2.0)
# CLEAR/BANK sit so their LABEL TOP aligns with the screens' shared top line
# (SCREEN_TOP_V) -- the layout the user approved in the LED trial (issue #366).
# SILK_CAP is the cap-height/em ratio of the label font as it actually renders
# (measured in the "Segno console (populated)" doc; Arial-class bold ~0.717): the
# silk `h` parameter is an em size, so glyph caps top out at v_lbl + SILK_H*SILK_CAP.
SILK_CAP     = 0.7168
# Play-triangle height as a fraction of SILK_H. Named because ROW1_LEGEND_TOP
# below depends on it: the triangle is the tallest glyph in row 1, so the ring
# placement moves if this changes. Don't inline it back into the glyph.
SILK_TRI_H   = 0.82
# Vertical offset of a pedal label above its slot, measured from the slot's rear
# edge. Pedals WITH a pill clear the pill first; pedals without one sit on the
# pill's BOTTOM LINE, so the whole row shares one baseline -- that line is what
# the eye follows across the row, and at the old 8.0 the plain labels floated
# 1 mm under it and the row read as two bands (owner call 2026-08-22).
#
# DERIVED, not a literal: the pill centre is LED_GAP above the slot and the pill
# is LED_SLOT_H tall, so its bottom edge is LED_GAP - LED_SLOT_H/2. Write 9.0
# here and it silently stops matching the moment either of those changes.
LABEL_DV_LED   = LED_GAP + 12.0
LABEL_DV_PLAIN = LED_GAP - LED_SLOT_H / 2.0
PEDAL_ROW2_V = SCREEN_TOP_V - SILK_H * SILK_CAP - LABEL_DV_LED - FSW_SLOT_D / 2.0
# The encoder + LED ring do NOT follow the pedals rearward: the ring would hit the
# 7" screen. It used to be pinned to the OLD row-2 centre (the 16"-screen-bottom
# line), which held while the ring was the Ring 16's O46 -- that left 26.7 mm of
# air under the 7" aperture. The Ring 24's O67 grew the radius by 10.5 mm and ate
# the gap down to 16.2 (12.2 to the diffuser's glue land), which is why the ring
# started reading as crowded up against the screen.
#
# So the ring is placed off the CLEARANCE now, not off a line that has nothing to
# do with it: the gap is the number that actually matters, it is stated once, and
# the ring re-places itself if RING_OD ever changes again.
# The rule is CENTRED, not clearance-from-one-side: the ring sits midway between
# the top of the row-1 legend band and the bottom of the 7" aperture, so the air
# above and below it is equal and stays equal when either bound moves. Hanging it
# off a single gap to the screen (what this was) leaves the other side to chance,
# and by eye it still sat high (owner call 2026-08-22).
#
# The band top is the play triangle's tip -- it is the tallest thing in row 1,
# taller than the cap height of UNDO/MODE, so it is what the eye reads as the
# edge of the legend band.
ROW1_LEGEND_TOP = (PEDAL_ROW1_V + FSW_SLOT_D / 2.0 + LABEL_DV_PLAIN
                   + SILK_H * (SILK_CAP / 2.0 + SILK_TRI_H / 2.0))
ENC_V        = (ROW1_LEGEND_TOP + (SCREEN_TOP_V - SMALL_H)) / 2.0

# Front row of 8, EVENLY spaced across the faceplate (no 4+4 grouping).
_ROW1 = ["REC/PLAY", "STOP", "UNDO", "MODE", "TRACK1", "TRACK2", "TRACK3", "TRACK4"]
# Pedal centres are FROZEN at the layout the console was built around (originally
# EDGE + slot/2 .. FP_W - EDGE - slot/2 with the 78mm ASP-1 slot). Everything
# downstream hangs off these: COL_U (7" screen/ring/encoder), the 16" aperture
# centre, LED slots, LED-strip PCBs and the Fusion doc. The wider Cherub slot
# (79.35) just eats 0.675mm of the side margin instead of shifting all of that.
ROW1_U_FIRST = 69.0
ROW1_U_LAST  = 777.0
def _row1_u(i):
    """Evenly spaced across the faceplate (frozen span, see above)."""
    return ROW1_U_FIRST + (ROW1_U_LAST - ROW1_U_FIRST) * i / (len(_ROW1) - 1)

# Shared vertical centre-line for the LEFT control column (7" screen + LED ring +
# encoder): the gap between pedals 1 and 2, so the whole column sits above that gap.
COL_U = (_row1_u(0) + _row1_u(1)) / 2.0

# Centre-line of the 16" screen: over the four TRACK pedals (row-1 right group).
# Hoisted out of faceplate_holes() because the Pi now mounts under it (#743).
SCREEN_16_U = (_row1_u(4) + _row1_u(7)) / 2.0
# The rear I/O cluster (and so the window and the bolt-on panel) is centred on the
# 16" screen. Right-justifying it against EDGE put the panel 11 mm off that centre
# for no reason a player could see, and the panel is the one rear feature anyone
# looks at while plugging in.
REAR_IO_U = SCREEN_16_U

# CLEAR/BANK ride row 2, aligned in u with UNDO (i=2) and MODE (i=3).
PEDALS = [(_ROW1[i], _row1_u(i), PEDAL_ROW1_V) for i in range(8)] + [
    ("CLEAR", _row1_u(2), PEDAL_ROW2_V), ("BANK", _row1_u(3), PEDAL_ROW2_V)]

# Front-lip screws: ONE PER PEDAL GAP plus one OUTBOARD of each end pedal at the
# mirrored half-pitch (9 total; was 3 -- #760). The knuckle trim left the front
# wall 10.09 tall with the screw row at ~6.95, so each hole keeps only ~1.0mm of
# metal above its edge; spreading the lid load over every station cuts the
# per-screw pull ~3x. All 9 land clear of every foot-plate by construction.
# Shared by the lid lip and the front wall.
_FS_HP = (_row1_u(1) - _row1_u(0)) / 2.0
FRONT_SCREW_U = ([_row1_u(0) - _FS_HP]
                 + [(_row1_u(i) + _row1_u(i + 1)) / 2.0 for i in range(len(_ROW1) - 1)]
                 + [_row1_u(len(_ROW1) - 1) + _FS_HP])

# Status-LED pedals. #366 gave a pill to ALL ten; the four TRANSPORT pedals lose
# theirs again (owner call 2026-08-21): REC/PLAY, STOP, UNDO and MODE are fixed
# functions, not mappable, so a per-pedal status light has nothing to report --
# their state is already on the screens. The six that keep a pill are the four
# TRACKs (which show arm/record/play per lane) plus CLEAR and BANK. The encoder
# ring is unaffected.
NO_LED_PEDALS = ("REC/PLAY", "STOP", "UNDO", "MODE")

def _has_led(label):
    return label not in NO_LED_PEDALS

# Legends. Two transport controls read as SYMBOLS rather than words (owner call
# 2026-08-21): "REC/PLAY" was a two-line block eating the tallest label slot on
# the plate for what is one button, and a record dot beside a play triangle says
# it in a fraction of the space; STOP becomes the universal square. Symbols are
# emitted as GEOMETRY (see SILK_SYMBOLS / _silk_symbol_geometry), not glyphs --
# the legend is a printed vinyl overlay, and a filled shape is unambiguous where
# a font substitution on the vendor's RIP would not be.
SILK_SYMBOLS = {"REC/PLAY": "rec_play", "STOP": "stop"}
SILK_ICON_R  = 0.10   # fillet radius as a fraction of h -- play + stop (owner)


def _fillet_closed(pts, r, n=10):
    """Closed ring with a circular fillet of radius r at every vertex.

    Used for the play triangle and the stop square so they read as the same
    family of icons (rounded, not knife-cut). n is arc segments per corner.
    """
    pts = list(pts)
    m = len(pts)
    if m < 3 or r <= 0.0:
        return pts
    out = []
    for i in range(m):
        p0 = pts[(i - 1) % m]
        p1 = pts[i]
        p2 = pts[(i + 1) % m]
        v1 = (p0[0] - p1[0], p0[1] - p1[1])
        v2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1 = math.hypot(*v1)
        l2 = math.hypot(*v2)
        if l1 < 1e-9 or l2 < 1e-9:
            out.append(p1)
            continue
        u1 = (v1[0] / l1, v1[1] / l1)
        u2 = (v2[0] / l2, v2[1] / l2)
        dot = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
        theta = math.acos(dot)
        if theta < 1e-6 or theta > math.pi - 1e-6:
            out.append(p1)
            continue
        trim = r / math.tan(theta / 2.0)
        trim = min(trim, l1 * 0.45, l2 * 0.45)
        rr = trim * math.tan(theta / 2.0)
        a = (p1[0] + u1[0] * trim, p1[1] + u1[1] * trim)
        b = (p1[0] + u2[0] * trim, p1[1] + u2[1] * trim)
        bis = (u1[0] + u2[0], u1[1] + u2[1])
        bl = math.hypot(*bis)
        if bl < 1e-9:
            out.append(p1)
            continue
        bis = (bis[0] / bl, bis[1] / bl)
        c = (p1[0] + bis[0] * (rr / math.sin(theta / 2.0)),
             p1[1] + bis[1] * (rr / math.sin(theta / 2.0)))
        a0 = math.atan2(a[1] - c[1], a[0] - c[0])
        a1 = math.atan2(b[1] - c[1], b[0] - c[0])
        # Interior angle is < 180, so the fillet is the minor arc (central
        # angle π-θ). The long way around bites a concave chunk out of the
        # corner -- that is how stop looked like a square with four bites.
        ccw = (a1 - a0) % (2.0 * math.pi)
        if ccw <= math.pi:
            sweep, sign = ccw, 1.0
        else:
            sweep, sign = (2.0 * math.pi - ccw), -1.0
        for j in range(n + 1):
            ang = a0 + sign * sweep * j / n
            out.append((c[0] + rr * math.cos(ang), c[1] + rr * math.sin(ang)))
    return out


def _silk_symbol_geometry(kind, u, v, h):
    """Filled legend symbols, returned as {"kind": "poly"/"disc"} entries in the
    ENGRAVE stream. u,v = centre; h = cap height, so a symbol sits on the same
    optical baseline as the word labels it replaces.

    rec_play: record DOT + play TRIANGLE, side by side, reading left to right in
              the order the one button cycles. Triangle corners are filleted
              (SILK_ICON_R) so they match the stop square.
    stop:     the universal filled square, drawn slightly smaller than h because
              a square reads visually larger than a circle of the same height.
              Corners filleted to the same SILK_ICON_R.
    """
    out = []
    if kind == "rec_play":
        d = h * 0.78                       # dot diameter
        tw, th = h * 0.72, h * SILK_TRI_H  # triangle width / height
        gap = h * 0.20                     # tighter than the old 0.34 -- the plus
        pw = h * 0.36                      # goes BETWEEN the two, and the group
        pt = h * 0.10                      # still has to fit inside the pedal
        # Fillet first, then scale the triangle back to `th` so the rounded
        # tips do not shrink it under the record dot (they read as one pair).
        tri = _fillet_closed([(0.0, -th / 2.0), (0.0, th / 2.0), (tw, 0.0)],
                             h * SILK_ICON_R)
        ys = [p[1] for p in tri]
        xs = [p[0] for p in tri]
        # Same bbox height as the dot. 1.16 overshot (play read larger);
        # unscaled after the fillet undershot (dot read larger).
        s = d / (max(ys) - min(ys))
        cx, cy0 = (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0
        tri = [(cx + s * (x - cx), s * (y - cy0)) for x, y in tri]
        tw = max(p[0] for p in tri) - min(p[0] for p in tri)
        total = d + gap + pw + gap + tw
        x0 = u - total / 2.0
        out.append({"kind": "disc", "u": x0 + d / 2.0, "v": v, "d": d})
        # The PLUS is deliberately smaller than the dot and the triangle: it is a
        # conjunction between them, not a third transport symbol competing with
        # them (owner call 2026-08-22). One 12-point cross, not two overlapping
        # bars -- the overlap would be a self-intersecting fill boundary.
        px = x0 + d + gap + pw / 2.0
        a, b = pw / 2.0, pt / 2.0
        out.append({"kind": "poly", "pts": [
            (px - b, v - a), (px + b, v - a), (px + b, v - b),
            (px + a, v - b), (px + a, v + b), (px + b, v + b),
            (px + b, v + a), (px - b, v + a), (px - b, v + b),
            (px - a, v + b), (px - a, v - b), (px - b, v - b)]})
        tx = x0 + d + gap + pw + gap - min(p[0] for p in tri)
        out.append({"kind": "poly",
                    "pts": [(x + tx, y + v) for x, y in tri]})
    elif kind == "stop":
        a = h * 0.70
        sq = [(u - a/2, v - a/2), (u + a/2, v - a/2),
              (u + a/2, v + a/2), (u - a/2, v + a/2)]
        out.append({"kind": "poly", "pts": _fillet_closed(sq, h * SILK_ICON_R)})
    else:
        raise ValueError("unknown silk symbol: %r" % (kind,))
    return out


def _silk_lines(label):
    if label in SILK_SYMBOLS:
        return []                 # drawn as geometry, not text
    if label.startswith("TRACK"):
        return []                 # tracks are identified by the meter screen, no silk text
    return [label]

def pedal_half_width(x):
    """Half the case width at depth x in the PEDESTAL frame (+X toward the case
    BACK). The WTB-006 tapers in PLAN as well as in height -- PEDAL_W at the back
    edge down to PEDAL_TOE_W at the toe -- so a clearance quoted off PEDAL_W is
    understated everywhere except the back edge."""
    t = (PEDAL_D/2.0 - x) / PEDAL_D          # 0 at the back edge, 1 at the toe
    return (PEDAL_W - t * (PEDAL_W - PEDAL_TOE_W)) / 2.0

def pedal_base_holes():
    """The four base screw holes in the PEDESTAL frame: X = depth with +X toward
    the case BACK (cable end), Y = width, origin at the pedal centre. Rear pair
    first. Anything that bolts a pedal down from below reads this."""
    return [(PEDAL_D/2.0 - back, side * span/2.0)
            for back, span in ((PEDAL_BASE_REAR_BACK, PEDAL_BASE_SPAN_REAR),
                               (PEDAL_BASE_FRONT_BACK, PEDAL_BASE_SPAN_FRONT))
            for side in (-1, 1)]

def platform_h(v):
    """Platform shelf height that lands the pedal's BODY TOP (case top, under the
    top pad) FLUSH with the faceplate surface at the slot's UPPER (rear) rim --
    pad above the metal (issue #373). The pedal sinks POCKET_DEPTH into the
    deck's locating pocket, so the deck compensates. face_drift closes the gap
    between the bare lid_top_z frame and the REAL plate seating (flush was still
    1.4 mm short at row 1 without it -- measured in the populated doc)."""
    v_rim = v + FSW_SLOT_D / 2.0
    return lid_top_z(v_rim) + face_drift(v_rim) + PEDAL_PAD_T - PEDAL_H + POCKET_DEPTH


def face_drift(_v=None):
    """Kept as a call so the intent stays greppable; the offset is CONSTANT now."""
    return FACE_SEAT

# ---------------------------------------------------------------------------
# FACEPLATE SUPPORT POSTS  (base-anchored props -- issue #292)
# ---------------------------------------------------------------------------
# The shop's STD aluminium is soft 1050 (yield ~105 vs 193 MPa for 5052). The
# faceplate's own perimeter folds already stiffen its edges (~70x at a fold line),
# so the pedal band (close to the front lip) is fine. The ONE zone the perimeter
# folds do NOT reach is the interior just in front of the big 16in aperture: bare
# 2 mm 1050 there dents at only ~11 kg (issue #292). Rather than a rib on the
# VISIBLE top face, TWO vertical posts rise from the base floor to just under that
# zone -- load runs faceplate -> post -> base -> floor. The posts anchor to the
# BASE only; the faceplate bears on their felt caps, so the lid still lifts off and
# NOTHING shows on the top face. Cut+bend only.
POST_V     = 165.0                 # web depth (user call 2026-08-19: "move the screws back, make the
                                   # posts taller"): the pad now sits 13mm in front of the 16in aperture
                                   # edge (178) -- the actual dent zone -- instead of jammed at 146.5
                                   # against the OLD panel's fictitious connector strip. Rear limit is
                                   # the UPERFECT body's bottom edge (~170.5 plan, PROVISIONAL, VESA
                                   # float +/-2.5); the intake vent field below yields instead (slots
                                   # under the feet are skipped, see _bottom_vents_local).
POST_U     = [625.0, 726.0]        # in the TRACK LED-slot GAPS (T2-T3 @625, T3-T4 @726) so the pad also
                                   # clears the LED slots; still under the 16in aperture, clear of the vent
POST_PW    = 40.0                  # post width (u) -- lateral stability
POST_PAD   = 20.0                  # top pad length (v) -- bears on the faceplate underside
POST_FOOTL = 20.0                  # foot flange length (v) -- bolts to the base floor
                                   # (briefly 17 while the post was wedged against the v375 platforms
                                   # at POST_V=146.5; restored to 20 when POST_V moved to 165 -- the
                                   # foot front now clears the platform rear wall by ~17 mm)
POST_FELT  = 1.0                   # ASSEMBLED metal gap: a thicker (2-3 mm) felt/foam cap on the
                                   # pad compresses into this ~1 mm when the lid seats -> preloaded,
                                   # firm, rattle-free contact without jacking the lid.
POST_TILT  = SLOPE_ANGLE           # pad tilt (deg) so it beds FLUSH on the sloped faceplate underside
POST_BOLT_DU = 12.0                # M4 foot bolts at +/- this in u
# The shell is soft 1050 aluminium, but the posts are made in STEEL 1.6 mm: ~3x stiffer
# (E 200 vs 69 GPa), tougher, and only ~+60 g for the pair -- rigidity where it costs no
# weight (issue #292). Felt cap isolates the steel pad from the soft-Al faceplate.
POST_T     = 1.6                   # post sheet thickness (cold-rolled steel), NOT the shell's 2.0 Al
# foot + pad both extend FORWARD of the web (a C, all in the clear strip in front of the
# aperture); nothing sits under the display.
# web height: derived from the MEASURED faceplate-underside plane of "Segno
# console (populated)" (the MANUFACTURING source of truth) -- the same plane
# build_screen16_stand_steps seats the monitor deck against:
#   z_underside(y_world) = 12.437 + tan(SLOPE)*y_world   (above the base floor TOP)
#   y_world              = cos(SLOPE)*v_plan - 2.093
# The pad TOP (hinge line, at web top + pad-sheet POST_T) sits POST_FELT below
# that plane; the foot rests ON the base floor top, and build_post_step() measures
# the web from that same face -- so the bottom-plate T is already inside the datum
# and must NOT be subtracted again (the old stack subtracted it because lid_top_z
# is referenced to the floor's OUTER face). Earlier revisions stacked
# lid_top_z(POST_V) - POST_FACEDRIFT + POST_DOC_CAL instead: a constant-drift
# model that needed a fresh SINGLE-POINT doc probe at every POST_V move (the
# 1.5+0.443 FACE_SEAT-style drift, then a 3.85 mm patch at v=165). The plane
# derivation RETIRES both constants (#767): it reproduces the v=165 doc probe
# to 0.026 mm and generalizes to any POST_V.
_POST_Y_WORLD = math.cos(math.radians(SLOPE_ANGLE)) * POST_V - 2.093
_POST_UNDER_Z = 12.437 + math.tan(math.radians(SLOPE_ANGLE)) * _POST_Y_WORLD
POST_H     = _POST_UNDER_Z - POST_T - POST_FELT
# PIN to the doc probe: at POST_V=165 the populated doc gave web 45.107 mm at
# exactly the 1.0 mm felt gap (2026-08-19). This pin moves ONLY with a fresh
# doc probe -- if it trips, the plane model and the doc have drifted apart;
# re-probe the doc before cutting posts.
assert abs(POST_H - 45.107) <= 0.05, (
    f"POST_H {POST_H:.3f} drifted from the doc-probed 45.107 +/- 0.05 -- "
    "re-probe the populated doc before cutting posts")
_POST_VP   = POST_V * math.cos(math.radians(SLOPE_ANGLE))   # projected web depth on the flat base
_POST_FOOT_VP = _POST_VP - POST_FOOTL/2.0                   # foot-bolt depth (forward of the web)

def faceplate_holes():
    """All faceplate features. Pedal slots have NO mounting holes (the pedals
    stand on internal printed platforms). u=player L->R, v=front->rear."""
    cuts, engr = [], []
    # --- 10 pedal slots (two rows); a status LED pill above EVERY pedal --------
    for label, u, v in PEDALS:
        cuts.append({"kind": "rect", "u": u - FSW_SLOT_W/2,
                     "v": v - FSW_SLOT_D/2 + PEDAL_AP_DEV - FSW_FRONT_EXTRA,  # development offset:
                     "w": FSW_SLOT_W, "h": FSW_SLOT_D + FSW_FRONT_EXTRA,        # meet the pedals where the
                     "r": 0.0, "ref": label})                                   # floor puts them (#760)
        led = _has_led(label)   # (slot cutouts below replace the old per-pedal LED holes;
                                #  the flag still sets the label offset, unchanged)
        # silkscreen label ABOVE the pedal (rear side); every line is drawn at
        # EXACTLY the pill width (LED_SLOT_W) so labels and LED pills read as one
        # family of bars: common cap height, width factor forces the advance.
        lines = _silk_lines(label)
        if label in SILK_SYMBOLS:                      # transport symbol, drawn as geometry
            v_sym = v + FSW_SLOT_D/2 + (LABEL_DV_LED if led else LABEL_DV_PLAIN) + SILK_H*SILK_CAP/2.0
            engr.extend(_silk_symbol_geometry(SILK_SYMBOLS[label], u, v_sym, SILK_H))
            continue
        if not lines:                                  # tracks carry no silk text
            continue
        v_lbl = v + FSW_SLOT_D/2 + (LABEL_DV_LED if led else LABEL_DV_PLAIN)
        infos = []                                     # (text, width-factor, displayed width)
        for ln in lines:
            est_w = SILK_H * len(ln) * SILK_CW         # natural width at the common height
            infos.append((ln, LED_SLOT_W / est_w, LED_SLOT_W))
        left_x = u - max(d for _, _, d in infos) / 2.0   # multiline: flush-left, block centred
        for k, (ln, wf, disp_w) in enumerate(infos):
            vpos = v_lbl + (len(lines)-1-k)*(SILK_H*0.95)   # tight 2-line stack (issue #366)
            if len(lines) > 1:                         # multiline (REC/PLAY) -> left-aligned
                engr.append({"u": left_x, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "left"})
            else:                                      # single line -> centred on the pedal
                engr.append({"u": u, "v": vpos, "h": SILK_H, "s": ln, "wf": wf, "halign": "center"})
    # --- LED diffuser slots: ONE small pill window per indicator pedal, on the
    #     old status-LED centre-line (a single-LED WS2812B board under each,
    #     VHB-taped to the faceplate underside; white-PLA pill diffuser set into
    #     the slot). Full-round ends: corner r = LED_SLOT_H/2.
    for label, u, v in PEDALS:
        if not _has_led(label):
            continue
        vc = v + FSW_SLOT_D/2 + LED_GAP              # same centre-line the LED holes used
        cuts.append({"kind": "rect", "u": u - LED_SLOT_W/2, "v": vc - LED_SLOT_H/2,
                     "w": LED_SLOT_W, "h": LED_SLOT_H, "r": LED_SLOT_H/2,
                     "ref": label + "_LEDSLOT"})
    # --- screens: top edges aligned on SCREEN_TOP_V ------------------------
    cuts.append({"kind": "rect", "u": COL_U - SMALL_W/2.0, "v": SCREEN_TOP_V - SMALL_H, "w": SMALL_W, "h": SMALL_H, "ref": "SCREEN_7IN"})
    s16_uc = SCREEN_16_U                        # centre over the 4 track pedals (row-1 right group)
    cuts.append({"kind": "rect", "u": s16_uc - BIG_W/2.0, "v": SCREEN_TOP_V - BIG_H, "w": BIG_W, "h": BIG_H, "ref": "SCREEN_16IN"})
    # --- encoder + diffused ring: on the OLD row-2 centre line (ENC_V -- it does
    #     NOT follow CLEAR/BANK rearward, see the PEDAL_ROW2_V note), and on
    #     COL_U -- the SAME vertical centre-line as the 7" screen (pedal 1/2 gap) -
    enc_v = ENC_V
    enc_u = COL_U                        # shared left-column centre-line (7" screen + ring)
    cuts.append({"kind": "ring",   "u": enc_u, "v": enc_v, "od": RING_OD, "id": RING_ID, "ref": "RING"})
    cuts.append({"kind": "circle", "u": enc_u, "v": enc_v, "d": D_ENC, "ref": "ENCODER"})
    # NOTE: no LEDs flank the encoder -- like the reference, the ring stands alone.
    # There is NO power indicator anywhere on this machine (#743): the rear
    # button is deliberately unlit, and two lit screens say "on" from the side
    # the player actually stands on.
    # The lid bolts to the body through its DOWN-TURNED SKIRT FLANGES (front lip +
    # sides + rear), NOT through this top face -- those screw holes live on the
    # flanges, added in dxf_faceplate / the render. So nothing more on the top here.
    # NOTE: the faceplate is reinforced by base-anchored SUPPORT POSTS (issue #292)
    # that bear on the underside -- they add NO holes here, keeping the top face clean.
    return cuts, engr

# Rear I/O stations, LEFT to RIGHT along the wall, with the KEEP-OUT width each
# one needs -- the nut, bezel or flange a fitter has to get a spanner around, NOT
# the hole. That distinction matters for the USB 3.0 coupler, whose flange (28.5)
# is 6.4 wider than its own 22.1 cutout; spacing on cutouts alone would have the
# two couplers' flanges fouling each other.
REAR_IO_STATIONS = [
    ("PD_IN",    D_TRS_KEEPOUT),                         # power first, at the far
    ("POWER",    PWRBTN_HEAD_D + 4.0),                   # left, away from signal.
                                                         # Sized off the HEAD, not the
                                                         # hole -- the head is what
                                                         # has to clear its neighbour
    ("FUSE",     D_FUSE + 6.0),                          # screw cap + a spanner
    ("MIDI_IN",  MIDI_SCREW_PITCH + 2*MIDI_SCREW_D),     # DIN-5 fixings set the
    ("MIDI_OUT", MIDI_SCREW_PITCH + 2*MIDI_SCREW_D),     # width, not the bore
    ("CTRL_1",   D_TRS_KEEPOUT),                         # D-series: the M3 pair is
    ("CTRL_2",   D_TRS_KEEPOUT),                         # wider than the Ø24 bore
    ("USB3_1",   USB3_FLANGE_D),
    ("USB3_2",   USB3_FLANGE_D),
]

def rear_io_layout():
    """Centre u of every connector station, spread across REAR_IO_SPAN with EQUAL
    clear gaps between keep-outs (not equal centres -- the stations are different
    widths). Returns {ref: (centre_u, keepout_w)}."""
    total = sum(w for _r, w in REAR_IO_STATIONS)
    gap = (REAR_IO_SPAN - total) / (len(REAR_IO_STATIONS) - 1)
    out, x = {}, REAR_IO_U - REAR_IO_SPAN/2.0
    for ref, w in REAR_IO_STATIONS:
        out[ref] = (x + w/2.0, w)
        x += w + gap
    return out

def rear_io_cutouts():
    """The nine panel-mount connector cutouts, in WALL coords (u=0..W, z=0..REAR_WALL_H).

    They are cut in the bolt-on sub-panel, not in the wall -- but they are laid out
    against the wall's own u so the panel, the window and the wall all agree without
    anyone converting coordinates by hand. rear_panel_holes() shifts them to
    panel-local; nothing else re-derives them."""
    z = REAR_IO_Z
    at = rear_io_layout()
    cuts = []
    for ref, d in (("POWER", D_PWRBTN), ("FUSE", D_FUSE)):     # nut-mounted: bore only
        cuts.append({"kind": "circle", "u": at[ref][0], "v": z, "d": d, "ref": ref})
    # DIN-5 stations: a bore with a HORIZONTAL M3 pair straddling it (the panel
    # is 46 tall; across the panel there is room to spare).
    for ref in ("MIDI_IN", "MIDI_OUT"):
        cu = at[ref][0]
        cuts.append({"kind": "circle", "u": cu, "v": z, "d": MIDI_BODY_D, "ref": ref})
        for s in (-1, 1):
            cuts.append({"kind": "circle", "u": cu + s*MIDI_SCREW_PITCH/2.0, "v": z,
                         "d": MIDI_SCREW_D, "ref": ref + "_SCR"})
    # D-series stations (both TRS jacks AND the PD coupler -- same D shell): the
    # Ø24 bore plus the DIAGONAL M3 pair, 19 across x 24 vertical (see
    # D_TRS_SCREW_DIAG provenance). One diagonal fits every D shell: the flange
    # is point-symmetric about the bore, so an opposite-diagonal part mounts by
    # turning it 180 deg.
    ddu, ddz = D_TRS_SCREW_DIAG
    for ref in ("PD_IN", "CTRL_1", "CTRL_2"):
        cu = at[ref][0]
        cuts.append({"kind": "circle", "u": cu, "v": z, "d": D_TRS_BORE, "ref": ref})
        for s in (-1, 1):
            cuts.append({"kind": "circle", "u": cu + s*ddu/2.0, "v": z - s*ddz/2.0,
                         "d": D_TRS_SCREW_D, "ref": ref + "_SCR"})
    for ref in ("USB3_1", "USB3_2"):                       # square, heavily radiused
        cu = at[ref][0]
        cuts.append({"kind": "rect", "u": cu - USB3_CUT_SQ/2.0, "v": z - USB3_CUT_SQ/2.0,
                     "w": USB3_CUT_SQ, "h": USB3_CUT_SQ, "r": USB3_CORNER_R, "ref": ref})
    return cuts

def _feat_extent(f):
    """(u_lo, u_hi, z_lo, z_hi) of one cutout feature."""
    if f["kind"] == "circle":
        r = f["d"] / 2.0
        return (f["u"] - r, f["u"] + r, f["v"] - r, f["v"] + r)
    return (f["u"], f["u"] + f["w"], f["v"], f["v"] + f["h"])

def rear_window():
    """The I/O WINDOW in the rear wall: (u_lo, z_lo, w, h).

    Derived from the cutouts it has to pass, not typed. The window used to be a
    290x46 constant while the cluster it framed was laid out by rear_io_layout(),
    so the two could drift apart silently -- and did, when the cluster moved right
    to follow the boards (#743). Now the wall opening is whatever the connectors
    need plus REAR_WIN_CLR, and a station that grows drags the window with it."""
    ext = [_feat_extent(f) for f in rear_io_cutouts()]
    # u: the opening must pass the station KEEP-OUTS (flanges, nuts), not just the
    # holes -- the panel mounts from the inside, so every connector's widest part
    # crosses the window plane. See REAR_WIN_SIDE_CLR.
    lay = rear_io_layout()
    u_lo = min(cu - kw/2.0 for cu, kw in lay.values()) - REAR_WIN_SIDE_CLR
    u_hi = max(cu + kw/2.0 for cu, kw in lay.values()) + REAR_WIN_SIDE_CLR
    z_lo = min(e[2] for e in ext) - REAR_WIN_CLR
    z_hi = max(e[3] for e in ext) + REAR_WIN_CLR
    if z_hi - z_lo < REAR_WIN_H_MIN:            # open it up about the cluster centreline
        z_mid = (z_lo + z_hi) / 2.0
        z_lo, z_hi = z_mid - REAR_WIN_H_MIN/2.0, z_mid + REAR_WIN_H_MIN/2.0
    return (u_lo, z_lo, u_hi - u_lo, z_hi - z_lo)

def rear_panel_bolts():
    """Bolt centres (u, z) in WALL coords -- drilled in the wall AND the panel from
    this one list, so they cannot disagree."""
    u0, z0, w, h = rear_window()
    cu, cz = u0 + w/2.0, z0 + h/2.0
    return [(cu + su*(w/2.0 + REAR_PANEL_BOLT_OFF), cz + sz*(h/2.0 + REAR_PANEL_BOLT_OFF))
            for su in (-1, 1) for sz in (-1, 1)]

def rear_panel_outline():
    """Panel blank (u_lo, z_lo, w, h) in WALL coords: the window plus an overlap wide
    enough that the bolts clear its edge."""
    u0, z0, w, h = rear_window()
    return (u0 - REAR_PANEL_OV, z0 - REAR_PANEL_OV, w + 2*REAR_PANEL_OV, h + 2*REAR_PANEL_OV)

def rear_panel_holes():
    """Sub-panel features in PANEL-LOCAL coords (origin = panel centre)."""
    u0, z0, w, h = rear_panel_outline()
    cu, cz = u0 + w/2.0, z0 + h/2.0
    out = []
    for f in rear_io_cutouts():
        g = dict(f)
        g["u"] = f["u"] - cu
        g["v"] = f["v"] - cz
        out.append(g)
    _bond = rear_panel_bolts()[0]
    for bu, bz in rear_panel_bolts():
        out.append({"kind": "circle", "u": bu - cu, "v": bz - cz, "d": D_M3,
                    "ref": "PANEL_BOLT"})
        if (bu, bz) == _bond:
            out.append({"kind": "circle", "u": bu - cu, "v": bz - cz,
                        "d": MASK_BOND_D, "ref": "PANEL_BOND", "layer": "MASK"})
    return out

def rear_holes():
    """Rear WALL features: the I/O WINDOW and its four bolt holes, the fixed exhaust
    vents and the earth stud. The connectors themselves are NOT here -- they are in
    the bolt-on sub-panel (segno_rear_panel), so the whole connector loom lifts out
    as one assembly instead of being trapped in a folded face of the base.
    u=0..W, z=0..REAR_WALL_H."""
    u0, z0, w, h = rear_window()
    cuts = [{"kind": "rect", "u": u0, "v": z0, "w": w, "h": h, "ref": "IO_WINDOW"}]
    _bond = rear_panel_bolts()[0]                          # the one nearest the stud
    for bu, bz in rear_panel_bolts():
        cuts.append({"kind": "circle", "u": bu, "v": bz, "d": D_M3, "ref": "PANEL_BOLT"})
        if (bu, bz) == _bond:
            cuts.append({"kind": "circle", "u": bu, "v": bz, "d": MASK_BOND_D,
                         "ref": "PANEL_BOND", "layer": "MASK"})
    # Vents fill the wall to the LEFT of the panel: the wall's EDGE margin to the
    # panel's left edge - EDGE, columns evenly pitched to land exactly on both.
    # (Mirror of the original rule, which had them to the RIGHT -- they swapped when
    # the cluster moved right to follow the boards.)
    sl = VENT_SLOT[0]
    cl_l = rear_panel_outline()[0]                         # panel LEFT edge
    v_l = EDGE                                             # first vent column
    v_r = cl_l - EDGE                                      # last column's right edge
    ncol = max(2, round((v_r - v_l - sl) / (sl + 8.0)) + 1)
    cp = (v_r - v_l - sl) / (ncol - 1)
    cuts.append({"kind": "circle", "u": (v_r + cl_l)/2.0, "v": REAR_WALL_H/2.0,
                 "d": D_GND, "ref": "EARTH_STUD"})         # centred in that gap
    vr = 7                                                 # rows, centred on mid-height
    vz0 = REAR_WALL_H/2.0 - ((vr-1)*VENT_PITCH + VENT_SLOT[1])/2.0
    cuts += _vent_array(u0=v_l, z0=vz0, cols=ncol, rows=vr, cp=cp)
    return cuts

def _vent_array(u0, z0, cols, rows, cp=None):
    """A block of louvre slots in BRICK BOND; returns rect features on the VENT
    layer. cp = column pitch. Odd rows are phase-shifted half a period like
    running bond (user call, 2026-08-18) and their edge slots clip to the same
    envelope as the even rows, so the block keeps its rectangular outline. The
    stagger keeps every web the same size while breaking the continuous cut
    lines of an aligned grid -- better looking AND stiffer."""
    sl, sw = VENT_SLOT
    if cp is None:
        cp = sl + 8.0
    u_hi = u0 + (cols - 1) * cp + sl                       # block envelope, right edge
    min_sl = sl * 0.3                                      # drop stubs, keep half-bricks
    out = []
    for r in range(rows):
        phase = cp / 2.0 if r % 2 else 0.0
        u = u0 + phase - cp                                # a period early: clipped heads
        while u < u_hi:
            lo, hi = max(u, u0), min(u + sl, u_hi)
            if hi - lo >= min_sl:
                out.append({"kind": "rect", "u": lo, "v": z0 + r * VENT_PITCH,
                            "w": hi - lo, "h": sw, "ref": "VENT", "layer": "VENT"})
            u += cp
    return out

def _vent_free_area(feats):
    sl, sw = VENT_SLOT
    return sum(f["w"] * f["h"] for f in feats if f.get("ref") == "VENT")

# ===========================================================================
# ASSERTION SUITE — the real acceptance gate (raises on bad geometry)
# ===========================================================================

def _bbox(f):
    """(umin, vmin, umax, vmax) of a faceplate feature in schedule coords."""
    if f["kind"] == "rect":
        return (f["u"], f["v"], f["u"] + f["w"], f["v"] + f["h"])
    r = (f["od"] if f["kind"] == "ring" else f["d"]) / 2.0
    return (f["u"] - r, f["v"] - r, f["u"] + r, f["v"] + r)

def _overlap(a, b, clr=2.0):
    return not (a[2] + clr <= b[0] or b[2] + clr <= a[0] or
                a[3] + clr <= b[1] or b[3] + clr <= a[1])

def _check(strict_board_mount=True):
    """Validate the geometry. Raises AssertionError with a clear message."""
    # The plate drills holes for a board this file does not own. Those numbers came
    # from measuring the V1 board, and stayed put while the board they were meant
    # for was replaced and then resized twice -- so they are read from the board
    # generator now instead of remembered.
    if strict_board_mount:
        import json
        assert os.path.exists(BOARD_MOUNT_JSON), (
            f"BOARD_MOUNT: {os.path.relpath(BOARD_MOUNT_JSON, HERE)} is missing -- run "
            "console_board_pcb.py; the plate cannot drill for a board it cannot see")
        with open(BOARD_MOUNT_JSON) as fh:
            _bm = json.load(fh)
        assert tuple(_bm["hole_pattern_mm"]) == BOARD_HOLES, (
            f"BOARD_MOUNT: the plate drills {BOARD_HOLES} but {_bm['board']} puts its "
            f"holes on {tuple(_bm['hole_pattern_mm'])} -- the standoffs would not line "
            "up with the board")
        assert tuple(_bm["outline_mm"]) == BOARD_SIZE, (
            f"BOARD_MOUNT: the plate reserves {BOARD_SIZE} for the board but "
            f"{_bm['board']} is {tuple(_bm['outline_mm'])} -- every clearance gate "
            "below is measuring the wrong rectangle")
    # 0. THE SLOPE CONVENTION (issue #742). v is measured ALONG THE SLOPE --
    # FP_V == L_SLOPE, not FACE_RUN -- so height is v*sin, never v*tan. This went
    # wrong once and was masked for months by a two-point "drift" fit that was
    # really cancelling the error, so pin it rather than trust a comment.
    assert abs(FP_V - L_SLOPE) < 1e-9, (
        f"SLOPE_CONV: FP_V {FP_V:.3f} != L_SLOPE {L_SLOPE:.3f} -- if the faceplate "
        "v axis is no longer the slope length, every lid_top_z caller changes meaning")
    _sin = math.sin(math.radians(SLOPE_ANGLE))
    for _v in (0.0, 67.8, 200.0, FP_V):
        assert abs(lid_top_z(_v) - (H_FRONT + min(_v, L_SLOPE)*_sin)) < 1e-9, (
            f"SLOPE_CONV: lid_top_z({_v}) is not H_FRONT + v*sin -- a tan there "
            "overstates the plate by 0.00525*v (1.95 mm at the 16in aperture)")
    assert abs(lid_top_z(FP_V) - H_REAR) < 1e-9, \
        f"SLOPE_CONV: the top of the slope is {lid_top_z(FP_V):.3f}, not H_REAR {H_REAR}"
    # ...and the seating offset must stay a CONSTANT. The moment it grows a v term
    # again it is almost certainly re-absorbing a unit error, which is what the old
    # face_drift(v) = 1.96 - 0.00533*v turned out to be.
    assert face_drift(0.0) == face_drift(400.0) == FACE_SEAT, (
        "SLOPE_CONV: face_drift is v-dependent again -- that is how #742 hid. A "
        "real seating offset does not taper along the plate")

    cuts, _ = faceplate_holes()
    rear = rear_holes()            # WALL: window, bolts, vents, earth stud
    rear_io = rear_io_cutouts()    # PANEL: the nine connector stations
    byref = {c["ref"]: c for c in cuts}

    # 1. width budget: the front row of 8 pedals must fit across FP_W
    row1 = sorted(u for _, u, v in PEDALS if v == PEDAL_ROW1_V)
    assert row1[0] - FSW_SLOT_W/2 >= 8 and row1[-1] + FSW_SLOT_W/2 <= FP_W - 8, (
        f"WIDTH_BUDGET: front row spans {row1[0]:.0f}..{row1[-1]:.0f}, "
        f"slot {FSW_SLOT_W:.0f} won't fit in {FP_W:.0f}")
    gaps = [b - a for a, b in zip(row1, row1[1:])]
    assert min(gaps) >= FSW_SLOT_W + 2.0, (
        f"WIDTH_BUDGET: min pedal gap {min(gaps):.0f} < slot {FSW_SLOT_W:.0f}+2")

    # 2. no two faceplate cutouts overlap (encoder bush is concentric in the ring)
    exempt = {frozenset(("RING", "ENCODER"))}
    boxes = [(c["ref"], _bbox(c)) for c in cuts]
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            (ra, a), (rb, b) = boxes[i], boxes[j]
            if frozenset((ra, rb)) in exempt:
                continue
            assert not _overlap(a, b), f"NO_OVERLAP: {ra} intersects {rb}"

    # everything must sit inside the usable faceplate (margin from folded edges)
    for ref, b in boxes:
        assert b[0] >= 8 and b[2] <= FP_W - 8 and b[1] >= 8 and b[3] <= FP_V - 8, \
            f"BOUNDS: {ref} outside the faceplate usable area"

    # 2b. support posts (issue #292): bear on the panel JUST in front of the 16in
    # aperture (v<178), under the aperture width, tall enough to reach the underside.
    _aperture_edge_v = SCREEN_TOP_V - BIG_H
    assert POST_V < _aperture_edge_v, \
        f"POST_V {POST_V:.0f} not in front of the aperture edge ({_aperture_edge_v:.0f})"
    assert POST_H > 10.0, f"POST height {POST_H:.1f} mm too short at v={POST_V:.0f}"
    s16 = byref["SCREEN_16IN"]
    for u in POST_U:
        assert s16["u"] <= u <= s16["u"] + s16["w"], \
            f"post u={u:.0f} not under the 16in aperture ({s16['u']:.0f}..{s16['u']+s16['w']:.0f})"
    # COMPACT post sits in the band between the front pedals and the 15.6in BODY, and in the
    # TRACK LED-slot GAPS (in u) so the pad also clears the slots.
    assert POST_V - POST_PAD > PEDAL_ROW1_V + FSW_SLOT_D/2.0, \
        f"POST pad reaches back over the front pedals (v{POST_V-POST_PAD:.0f} vs {PEDAL_ROW1_V+FSW_SLOT_D/2:.0f})"
    # the printed pedal platforms stand on the FLAT base: their ring rear wall (world
    # depth) ends at PEDAL_ROW1_V*cos + SKIRT_OUT_D/2. The post's forwardmost metal
    # (foot AND pad front, both at _POST_VP - POST_FOOTL) must clear it -- the 20 mm C
    # overhung this by ~1 mm and collided in the populated doc (user-caught 2026-08-19).
    _plat_rear_w = PEDAL_ROW1_V * math.cos(math.radians(SLOPE_ANGLE)) + SKIRT_OUT_D / 2.0
    assert _POST_VP - POST_FOOTL > _plat_rear_w + 1.5, \
        f"POST front (w{_POST_VP-POST_FOOTL:.1f}) hits the pedal platform rear (w{_plat_rear_w:.1f} + 1.5 margin)"
    # 15.6in body bottom edge: the UPERFECT bezel is ~symmetric around the aperture
    # (the old formula assumed the whole bezel surplus hung below -- true only for
    # the old bare panel's connector strip). PROVISIONAL until the monitor arrives;
    # the 3.0 margin absorbs the VESA float's +/-2.5 adjustment.
    body_front = (SCREEN_TOP_V - BIG_H) - (BIG_BEZEL[1] - BIG_H) / 2.0
    assert POST_V < body_front - 3.0, \
        f"POST web v={POST_V:.0f} not clear of the 15.6in body bottom edge (v={body_front:.0f} - 3 margin)"
    # posts in the LED-slot gaps: no TRACK LED slot overlaps a post's pad (u +/- POST_PW/2)
    led = [_bbox(c) for c in cuts if c.get("ref","").endswith("_LEDSLOT")]
    for u in POST_U:
        for lb in led:
            assert not (lb[0] < u+POST_PW/2 and u-POST_PW/2 < lb[2]), \
                f"POST at u={u:.0f} overlaps an LED slot (u {lb[0]:.0f}..{lb[2]:.0f}) -- move to a gap"
    # post feet on the base must clear the intake vent SLOTS (the field now skips
    # slots under the feet -- see _bottom_vents_local -- so check slot-by-slot,
    # not against the field's bounding box)
    vent_bb = [_bbox(c) for c in _bottom_vents_local(W-2*T, D-2*T) if c.get("kind") == "rect"]
    for u in POST_U:
        fu0, fu1 = u - POST_PW/2 - 2, u + POST_PW/2 + 2
        fv0, fv1 = _POST_VP - POST_FOOTL - 2, _POST_VP + POST_T + 2
        for b in vent_bb:
            assert not (b[0] < fu1 and fu0 < b[2] and b[1] < fv1 and fv0 < b[3]), \
                f"POST foot at u={u:.0f} overlaps intake vent slot (u {b[0]:.0f}..{b[2]:.0f}, v {b[1]:.0f}..{b[3]:.0f})"

    # 3. platform head-room for BOTH rows: top pad flush+proud at each depth
    for v in (PEDAL_ROW1_V, PEDAL_ROW2_V):
        ph = platform_h(v)
        assert ph > T + 2.0, f"PLATFORM_HEADROOM: platform {ph:.1f} mm too low at v={v:.0f}"
        proud = ph + PEDAL_H - lid_top_z(v)        # how far the pedal stands proud
        assert -8.0 <= proud <= PEDAL_H, f"PLATFORM_HEADROOM: pedal proud {proud:.1f} mm at v={v:.0f}"
        # heat-set pilots need >= 3mm even in the LOW front pedestal (M3 x 3 shorts)
        pil = min(INSERT_DEPTH, (ph - T - 1.0) / 2.0)
        assert pil >= 3.0, f"PLATFORM_INSERTS: pilot depth {pil:.1f} mm < 3 at v={v:.0f} -- deck too shallow"
        # pocket floor must keep a solid web above the toe-side pilot bores
        assert (ph - T) - POCKET_DEPTH - pil >= 2.0, \
            f"PLATFORM_POCKET: web {(ph-T)-POCKET_DEPTH-pil:.1f} mm under the pocket at v={v:.0f}"

    # 3b. Cherub side-screw bosses pass UNDER the faceplate beside the slot: the
    # boss top must clear the underside where the sheet is solid. Pedal mounts
    # toe-forward, so its back edge sits at v + PEDAL_D/2 and the boss axis at
    # PEDAL_SCREW_BACK forward of it.
    for v in (PEDAL_ROW1_V, PEDAL_ROW2_V):
        v_screw = v + PEDAL_D / 2.0 - PEDAL_SCREW_BACK
        boss_top = platform_h(v) + PEDAL_PAD_T + PEDAL_SCREW_Z + PEDAL_SCREW_BOSS_D / 2.0
        # REAL clearance: bare-frame underside + the doc-calibrated seating drift
        # (the flush-at-rim seating (#373) eats the old margin; the bare frame
        # alone under-reports by face_drift and would false-fail row 2).
        clr = lid_under_z(v_screw) + face_drift(v_screw) - boss_top
        # flush-at-rim seating (#373) eats the old margin: real clearance is now
        # ~1.0 row 1 / ~0.95 row 2 (doc-probed). Static parts, no relative motion.
        assert clr >= 0.8, f"SCREW_BOSS: only {clr:.1f} mm under the faceplate at v={v_screw:.0f}"

    # 3b'. base screw holes: both rows land on the case underside, inboard of
    # the walls, and under the anti-slip pad (which is why they need a datum
    # that is NOT the pad -- see the PEDAL_BASE_* block). Issue #716.
    pad_x0 = PEDAL_D/2.0 - (PEDAL_PAD_BACK_INSET + PEDAL_PAD_D)   # toe end of the pad
    pad_x1 = PEDAL_D/2.0 - PEDAL_PAD_BACK_INSET                   # back end of the pad
    for hx, hy in pedal_base_holes():
        r = PEDAL_BASE_HOLE_D/2.0
        assert abs(hx) + r <= PEDAL_D/2.0 - 1.0, \
            f"PEDAL_BASE: hole at x={hx:.2f} runs off the case underside (depth)"
        assert abs(hy) + r <= pedal_half_width(hx) - 1.0, \
            f"PEDAL_BASE: hole at y={hy:.2f} runs into the case side wall " \
            f"(the wall is at {pedal_half_width(hx):.2f} there, not {PEDAL_W/2.0:.2f} -- the case tapers)"
        assert pad_x0 + r <= hx <= pad_x1 - r, \
            f"PEDAL_BASE: hole at x={hx:.2f} is not under the anti-slip pad"
        assert abs(hy) + r <= PEDAL_PAD_W/2.0, \
            f"PEDAL_BASE: hole at y={hy:.2f} is not under the anti-slip pad"

    # 3b''. the console RING + SLED (issue #719). The pedal is bolted to the sled
    # on the bench because the ~83 mm through-pin needs ~91 mm of clear axial run
    # and no gap beside a seated pedal is close to that.
    for tag, v in (("front", PEDAL_ROW1_V), ("mid", PEDAL_ROW2_V)):
        deck = platform_h(v) - T - (CONSOLE_SLED_T - (PEDAL_PAD_T - POCKET_DEPTH))
        base_z = deck + CONSOLE_SLED_T
        want = (platform_h(v) - T) + PEDAL_PAD_T - POCKET_DEPTH
        # the whole point: the pedal's metal base must not move, or the faceplate,
        # the slot and the flush-at-rim rule of #373 all have to be re-derived
        assert abs(base_z - want) < 1e-9, \
            f"CONSOLE_SLED: {tag} metal base moves {base_z - want:+.3f} mm"
        assert deck >= 1.2, \
            f"CONSOLE_SLED: {tag} ring floor {deck:.2f} too thin to clamp against"
        if tag == "front":
            assert abs(deck - RING_FLOOR) < 1e-3, \
                f"CONSOLE_SLED: front floor {deck:.3f} != RING_FLOOR {RING_FLOOR}"
    # ...and the sled's top must stay UNDER the faceplate everywhere it reaches.
    # It fills the tub bore, which is SKIRT_SETBACK wider than the slot opening,
    # so its toe-side corner sits beneath the plate -- exactly where a 12.5 deg
    # plate is lowest. Without the sloped cut this fouled the faceplate (9.3 mm3
    # front / 10.6 mm3 mid, measured in the populated doc).
    tn_ = math.tan(math.radians(SLOPE_ANGLE))
    half_d = (SKIRT_IN_D - 2*SLED_CLR)/2.0
    for tag, v, drift in (("front", PEDAL_ROW1_V, SKIRT_DRIFT_ROW1),
                          ("mid", PEDAL_ROW2_V, SKIRT_DRIFT_ROW2)):
        seat = platform_h(v) - T - (CONSOLE_SLED_T - (PEDAL_PAD_T - POCKET_DEPTH))
        plate = (lid_top_z(v) + drift - 2*T - SKIRT_GAP) - seat      # sled frame, x=0
        assert plate - tn_*half_d < CONSOLE_SLED_T, (
            f"CONSOLE_SLED: {tag} sled toe would clear the plate without a cut -- "
            "the sloped top in pedal_console_sled() has become dead code")
        # the four pedal inserts must survive that cut: their bores start at the top
        for hx, _hy in pedal_base_holes():
            assert plate + tn_*(hx - INSERT_PILOT_D/2.0) > CONSOLE_SLED_T - 0.5, (
                f"CONSOLE_SLED: {tag} sloped top cuts more than 0.5 mm into the "
                f"pedal insert at x={hx:.2f} -- the bore rim would not seat flat")
    # RUBBER FEET (#743). The screw head sits on the plate's top face, so the
    # rule is simply that NO fixing may land under a pedestal -- then no ring or
    # sled needs relieving. foot_relief_xy() reports any that do; it must be empty.
    stray = foot_relief_xy()
    assert not stray, (
        f"FOOT_CLEAR: {len(stray)} foot fixing(s) land under a pedestal at "
        f"{stray[:2]} -- the screw head would stop the ring seating flat")
    _bend = RI + T
    _tub_lo = min(u for _l, u, v in PEDALS if v == PEDAL_ROW1_V) - SKIRT_OUT_W/2.0
    assert _bend + D_FOOT/2.0 + 2.0 <= FOOT_INSET_X <= _tub_lo - D_FOOT/2.0 - 2.0, (
        f"FOOT_CLEAR: inset {FOOT_INSET_X} outside the window "
        f"{_bend + D_FOOT/2.0 + 2.0:.1f}..{_tub_lo - D_FOOT/2.0 - 2.0:.1f}")
    # the sled takes M3x5 from BOTH faces -- that is what sets its thickness
    assert CONSOLE_SLED_T >= 2*INSERT_DEPTH + 0.5, (
        f"CONSOLE_SLED: {CONSOLE_SLED_T:.2f} cannot take {INSERT_DEPTH:.1f} mm "
        "inserts from both faces")
    # ...and every chassis station must land ON the sled, or the screws have
    # nothing to thread into and the base plate would need new holes
    shd = (SKIRT_IN_D - 2*SLED_CLR)/2.0
    shw = (SKIRT_IN_W - 2*SLED_CLR)/2.0
    for fx, fy in platform_foot_xy():
        assert abs(fx) + INSERT_PILOT_D/2 <= shd - 1.5 and \
               abs(fy) + INSERT_PILOT_D/2 <= shw - 1.5, (
            f"CONSOLE_SLED: chassis station ({fx:.1f}, {fy:.1f}) falls off the "
            "sled -- segno_base.dxf would need new holes")
        clear = min(math.hypot(fx - hx, fy - hy) for hx, hy in pedal_base_holes())
        assert clear >= INSERT_PILOT_D + 1.0, (
            f"CONSOLE_SLED: chassis station ({fx:.1f}, {fy:.1f}) is {clear:.2f} mm "
            "from a pedal insert -- the two bores crowd")

    # 3c. the front gap absorbed the deeper Cherub slot; keep it usable
    assert FRONT_GAP >= 40.0, f"FRONT_GAP: {FRONT_GAP:.1f} mm < 40 -- pedals crowd the screen block"

    # 3d. light-baffle tub: pedal drops in, bosses ride the channels, walls stay
    # hidden behind the slot line, and the footprint clears neighbours + posts
    assert SKIRT_IN_W - PEDAL_W >= 2.0, "SKIRT: tub opening pinches the case"
    assert SKIRT_BOSS_CH_HALF >= PEDAL_SCREW_SPAN/2 + 0.5, "SKIRT: boss channel too shallow"
    assert SKIRT_BOSS_CH_W >= PEDAL_SCREW_BOSS_D + 2.0, "SKIRT: boss channel too narrow"
    assert SKIRT_IN_W - FSW_SLOT_W >= 2*SKIRT_SETBACK - 1e-9, "SKIRT: wall proud of the slot line (u)"
    assert 2*SKIRT_BOSS_CH_HALF < SKIRT_OUT_W, "SKIRT: boss channel exits the footprint"
    row1 = sorted(u for _, u, v in PEDALS if v == PEDAL_ROW1_V)
    pitch = min(b - a for a, b in zip(row1, row1[1:]))
    assert pitch - SKIRT_OUT_W >= 4.0, f"SKIRT: outer {SKIRT_OUT_W:.1f} vs pitch {pitch:.1f}"
    skirt_rear = PEDAL_ROW1_V + SKIRT_OUT_D / 2.0
    assert POST_V - POST_PAD - skirt_rear >= 0.8, \
        f"SKIRT: row-1 skirt rear v{skirt_rear:.1f} hits the post pad (front v{POST_V-POST_PAD:.1f})"

    # 4. screen depth: each module clears the interior under the lid (read positions)
    for ref, dep in (("SCREEN_16IN", BIG_DEPTH), ("SCREEN_7IN", SMALL_DEPTH)):
        s = byref[ref]; v_mid = s["v"] + s["h"] / 2.0
        interior = lid_under_z(v_mid)
        assert dep <= interior, (
            f"SCREEN_DEPTH: {ref} needs {dep} mm, interior {interior:.1f} mm at v={v_mid:.0f}")

    # 4b. front-row pedals must clear the 16" module in v OR u (no in-box clash)
    s16 = byref["SCREEN_16IN"]
    pedal_v_max = PEDAL_ROW1_V + FSW_SLOT_D / 2.0
    for label, u, v in PEDALS:
        if v != PEDAL_ROW1_V:
            continue
        if pedal_v_max + 4.0 > s16["v"]:                       # overlaps in v
            assert u + FSW_SLOT_W/2 <= s16["u"] or u - FSW_SLOT_W/2 >= s16["u"] + s16["w"], \
                f"SCREEN_DEPTH: pedal {label} clashes with 16in screen"

    # 5. ventilation free area + standoff height
    _bw_v = W - 2*T
    _side = sum(c["w"] * c["h"]
                for c in side_vents('R', _bw_v) + side_vents('L', _bw_v))
    # the side louvres are foam-backed and only count for what gets through it
    area = (_vent_free_area(rear) + _vent_free_area(_bottom_vents())
            + _side * FOAM_OPEN_FRACTION)
    assert area >= VENT_FREE_AREA_MIN, (
        f"VENT_FREE_AREA: {area:.0f} mm^2 < target {VENT_FREE_AREA_MIN:.0f}")
    # ...and every side louvre has to be ON the side wall, under a wedge top that
    # slopes: a slot that is fine at the front of the band can be through the top
    # edge at the back of it, and the blank would just unfold with a gap in it.
    for _c in side_vents('R', _bw_v) + side_vents('L', _bw_v):
        _off = abs(_c["u"] - _bw_v) if _c["u"] > _bw_v / 2 else abs(_c["u"])
        _top = _side_wall_top(_c["v"] + _c["h"])          # shallowest end of the slot
        assert _off + _c["w"] <= _top - SIDE_VENT_MARGIN, (
            f"SIDE_VENT: a louvre reaches {_off + _c['w']:.1f} mm up a wall that is "
            f"{_top:.1f} mm tall at v={_c['v'] + _c['h']:.0f}, leaving less than the "
            f"{SIDE_VENT_MARGIN:.0f} mm margin to the wedge top")
        # ...and off the FOLD. A slot cut too close to a bend line distorts when the
        # flap is folded: the material there is being stretched. The usual floor is
        # the inside radius plus twice the thickness, and it is the reason
        # SIDE_VENT_MARGIN is 12 and not "whatever looks fine".
        assert _off >= RI + 2*T - 1e-9, (
            f"SIDE_VENT: a louvre starts {_off:.1f} mm from the fold, inside the "
            f"{RI + 2*T:.1f} mm (bend radius {RI:.1f} + 2T) a bend needs to form "
            "cleanly -- the slot would draw out into the radius")
        assert _c["v"] + _c["h"] <= (D - 2*T) - REAR_CONN_DEPTH + 1e-9, (
            f"SIDE_VENT: a louvre reaches v={_c['v'] + _c['h']:.0f}, inside the "
            f"{REAR_CONN_DEPTH:.0f} mm the rear connectors need for their bodies and "
            "wiring -- foam and a DIN socket cannot share the same space")
    assert STANDOFF_H >= 8.0, "VENT: under-board gap too small for airflow"

    # 6. screen bezel overlaps the aperture (mount from behind)
    assert BIG_W < BIG_BEZEL[0] and BIG_H < BIG_BEZEL[1], "SCREEN_RETENTION: 16in aperture >= bezel"
    assert SMALL_W < SMALL_BEZEL[0] and SMALL_H < SMALL_BEZEL[1], "SCREEN_RETENTION: 7in aperture >= bezel"

    # 7. PEM land width sufficient on the bottom flange
    assert FLANGE >= PEM_EDGE + 2.0, f"PEM: flange {FLANGE} < edge dist {PEM_EDGE}+2"

    # 8. every rear-wall feature fits inside the (lowered) rear wall (u 0..W, z 0..REAR_WALL_H)
    for c in rear:
        if c["kind"] == "circle":
            r = c["d"] / 2.0
            lo_u, hi_u, lo_z, hi_z = c["u"]-r, c["u"]+r, c["v"]-r, c["v"]+r
        else:
            lo_u, hi_u, lo_z, hi_z = c["u"], c["u"]+c["w"], c["v"], c["v"]+c["h"]
        assert 0 <= lo_u and hi_u <= W and 0 <= lo_z and hi_z <= REAR_WALL_H, \
            f"REAR_BOUNDS: {c['ref']} outside the rear wall (z<= {REAR_WALL_H:.0f})"

    # 8a. the rear bay has to be deep enough for the connectors that now live in
    # it. The Pi is the thing that reaches furthest back, so it is what gets held.
    _bd = D - 2*T
    _pu, _pv, _ = pi_mount()
    _pu0, _pu1, _pv0, _pv1 = pi_pcb_extent()
    _clear = _bd - _pv1
    assert _clear >= REAR_CONN_DEPTH, (
        f"REAR_BAY: only {_clear:.1f} mm between the Pi's port edge and the rear "
        f"wall, need {REAR_CONN_DEPTH:.0f} for the connector bodies + wiring")
    # The BUCK still sits inside that bay (v to bd-31), and that is fine -- but for
    # a 3D reason, not a planar one, so it gets its own gate rather than a shrug.
    # The connectors are centred REAR_IO_Z up the wall; the lowest metal on the
    # widest of them is REAR_IO_Z - keepout/2. The buck is a 22.1-tall brick bolted
    # flat to the floor, so it passes UNDERNEATH them. The Pi cannot do the same --
    # it rides a 35.3 riser straight into that band, which is why it had to move in
    # plan and the buck did not.
    _lowest = REAR_IO_Z - max(kw for _cu, kw in rear_io_layout().values())/2.0
    assert BUCK_BODY[2] + 5.0 <= _lowest, (
        f"REAR_BAY: the buck is {BUCK_BODY[2]:.1f} tall and the lowest connector "
        f"metal is at z={_lowest:.1f} -- it no longer passes under them")

    # The Pi must not be stacked over anything -- that is the whole reason it moved
    # under the 16" screen rather than straight forward, and it is what lets the
    # bespoke riser reduce to a plain standoff. Test in BOTH axes: an earlier
    # version of this gate checked only v and fired on a Pi 400 mm away in u.
    _pi = (_pu0, _pu1, _pv0, _pv1)                               # PCB 85 x 56, rotated
    _b = board_mounts()[0]                                       # (ref, u, v, holes)
    _obs = [("console board", (_b[1] - BOARD_SIZE[0]/2.0, _b[1] + BOARD_SIZE[0]/2.0,
                               _b[2] - BOARD_SIZE[1]/2.0, _b[2] + BOARD_SIZE[1]/2.0))]
    for _bn, _bku, _bkv, _ in buck_mounts():
        _obs.append((_bn, (_bku - BUCK_BODY[0]/2.0, _bku + BUCK_BODY[0]/2.0,
                           _bkv - BUCK_BODY[1]/2.0, _bkv + BUCK_BODY[1]/2.0)))
    for _nm, _o in _obs:
        if _pi[0] < _o[1] and _o[0] < _pi[1] and _pi[2] < _o[3] and _o[2] < _pi[3]:
            _head = PI_RISER_H - (STANDOFF_H + BOARD_STACK_H)
            assert _head >= 3.0, (
                f"REAR_BAY: Pi overlaps the {_nm} in plan with only {_head:.1f} mm "
                "of head -- raise PI_RISER_H or move the Pi clear in u")
    # ...and it has to actually fit under the 16" screen module it now lives beneath
    _s16 = {c["ref"]: c for c in faceplate_holes()[0]}["SCREEN_16IN"]
    assert (_s16["u"] <= _pi[0] and _pi[1] <= _s16["u"] + _s16["w"]
            and _s16["v"] <= _pi[2] and _pi[3] <= _s16["v"] + _s16["h"]), (
        f"REAR_BAY: Pi footprint {_pi} is not inside the 16in screen bay "
        f"({_s16['u']:.0f}..{_s16['u']+_s16['w']:.0f}, {_s16['v']:.0f}..{_s16['v']+_s16['h']:.0f})")
    _free = lid_under_z(_pv) - BIG_DEPTH
    _stack = PI_STACK_H
    assert _stack + 8.0 <= _free, (
        f"REAR_BAY: Pi stack {_stack:.1f} (incl. N07 + cooler) + 8 clearance does not fit the {_free:.1f} mm "
        "left under the 16in screen module")

    # 8b. rear I/O cluster (#743). Each station reserves the width of its NUT or
    # FLANGE, not its hole, so a spanner fits; those keep-outs must not overlap
    # each other, must stay on the wall, and must clear the vent block.
    lay = rear_io_layout()
    # The keep-out has to actually CONTAIN the station's own cutouts. Without this
    # a station can reserve less than it cuts and the overlap check below passes on
    # a lie -- which is exactly what happened when the D-series jack (Ø24 bore + an
    # M3 pair) was carrying a Ø10 threaded-bushing keep-out.
    for ref, (cu, kw) in lay.items():
        own = [c for c in rear_io if c["ref"] == ref or c["ref"] == ref + "_SCR"]
        assert own, f"REAR_IO: station {ref} is laid out but cuts nothing"
        for c in own:
            r = c["d"]/2.0 if c["kind"] == "circle" else 0.0
            lo = c["u"] - r if c["kind"] == "circle" else c["u"]
            hi = c["u"] + r if c["kind"] == "circle" else c["u"] + c["w"]
            assert cu - kw/2.0 - 1e-9 <= lo and hi <= cu + kw/2.0 + 1e-9, (
                f"REAR_IO: {c['ref']} spans {lo:.2f}..{hi:.2f} but {ref} only "
                f"reserves {cu - kw/2.0:.2f}..{cu + kw/2.0:.2f} -- the keep-out "
                "does not contain what it is meant to protect")
    # A fixing hole that breaks into its own bore is not a fixing hole. This is
    # the check that caught the "D-series M3 pair sits at 24 mm" figure: on a Ø24
    # bore that puts the screw centres exactly on the bore edge, leaving no land.
    for c in rear_io:
        if not c["ref"].endswith("_SCR"):
            continue
        base = c["ref"][:-4]
        bore = next(b for b in rear_io if b["ref"] == base)
        off = math.hypot(c["u"] - bore["u"], c["v"] - bore["v"])
        assert off - c["d"]/2.0 >= bore["d"]/2.0 + 1.5, (
            f"REAR_IO: {c['ref']} at {off:.2f} from centre leaves "
            f"{off - c['d']/2.0 - bore['d']/2.0:.2f} mm of land against the "
            f"Ø{bore['d']:g} bore -- the screw would break into the hole")
    boxes = sorted(((cu - kw/2.0, cu + kw/2.0, ref) for ref, (cu, kw) in lay.items()))
    for (a_lo, a_hi, a_ref), (b_lo, b_hi, b_ref) in zip(boxes, boxes[1:]):
        assert a_hi <= b_lo + 1e-9, (
            f"REAR_IO: {a_ref} and {b_ref} keep-outs overlap by "
            f"{a_hi - b_lo:.2f} mm -- their nuts/flanges would foul")
    _bw_r = W - 2*T
    assert abs(REAR_IO_U - SCREEN_16_U) < 1e-9, (
        f"REAR_IO: cluster centre {REAR_IO_U:.1f} is not the 16in screen centre "
        f"({SCREEN_16_U:.1f}) -- the panel is centred on the screen, which is what "
        "anyone plugging into it lines it up against")
    assert boxes[0][0] >= EDGE - 1e-9, (
        f"REAR_IO: {boxes[0][2]} keep-out starts at u={boxes[0][0]:.1f}, inside "
        f"the {EDGE:.0f} mm edge margin")

    # 8c. the dismountable I/O panel (#751). The wall carries a window; the panel
    # carries the connectors and bolts over it. Four ways that goes wrong, four
    # gates -- the panel is derived from the cutouts, so each one is a statement
    # about what the derivation must keep true, not a repetition of it.
    _pu0, _pz0, _pw, _ph = rear_panel_outline()
    _wu0, _wz0, _ww, _wh = rear_window()
    # (i) the window has to pass every cutout it frames. Derived, but a station
    # that grows past the derivation -- a rect with a corner radius, a bore that
    # picks up a flange -- would be trimmed by the wall instead of the panel.
    for c in rear_io:
        lo, hi, zlo, zhi = _feat_extent(c)
        assert (_wu0 <= lo and hi <= _wu0 + _ww
                and _wz0 <= zlo and zhi <= _wz0 + _wh), (
            f"REAR_PANEL: {c['ref']} spans u {lo:.1f}..{hi:.1f}, z {zlo:.1f}..{zhi:.1f} "
            f"but the window is u {_wu0:.1f}..{_wu0+_ww:.1f}, z {_wz0:.1f}..{_wz0+_wh:.1f} "
            "-- the wall would cut into the connector")
    # (ii) a bolt through a flange is a panel that cannot be done up. The bolts sit
    # outside the window; the flanges reach past the cutouts, and on the outermost
    # stations they reach FURTHER than the window edge does.
    for _bu, _bz in rear_panel_bolts():
        for _ref, (_cu, _kw) in lay.items():
            _clr = abs(_bu - _cu) - _kw/2.0 - D_M3/2.0
            assert _clr >= 0.0 or abs(_bz - REAR_IO_Z) > _kw/2.0 + D_M3/2.0, (
                f"REAR_PANEL: bolt at ({_bu:.1f}, {_bz:.1f}) fouls {_ref}'s "
                f"Ø{_kw:.1f} flange by {-_clr:.1f} mm")
        assert (_bu - _pu0 >= 4.0 and _pu0 + _pw - _bu >= 4.0
                and _bz - _pz0 >= 4.0 and _pz0 + _ph - _bz >= 4.0), (
            f"REAR_PANEL: bolt at ({_bu:.1f}, {_bz:.1f}) leaves under 4 mm of "
            f"panel edge -- REAR_PANEL_OV {REAR_PANEL_OV} vs bolt offset "
            f"{REAR_PANEL_BOLT_OFF}")
    # (iii) the panel is a plate bolted to the OUTSIDE of a wedge-topped wall, so
    # it does not owe the wall's EDGE margin -- that margin is for features cut
    # into a face that has to fold and take a corner bracket. What it does owe:
    # staying on the wall, and lying FLAT. The corner brackets are pop-riveted
    # from inside, which puts their heads on the outside, in the panel's plane --
    # CORNER_RO is 8 mm precisely so they hug the corner and clear this panel, and
    # that intent is worth a gate rather than a comment.
    _bw_wall = W - 2*T
    assert _pu0 >= 4.0 and _pu0 + _pw <= _bw_wall - 4.0, (
        f"REAR_PANEL: panel spans u {_pu0:.1f}..{_pu0+_pw:.1f}, off a "
        f"{_bw_wall:.0f} mm wall")
    assert _pz0 >= 4.0 and _pz0 + _ph <= REAR_WALL_H - 4.0, (
        f"REAR_PANEL: panel spans z {_pz0:.1f}..{_pz0+_ph:.1f}, which does not "
        f"leave 4 mm of wall above and below on a {REAR_WALL_H:.0f} mm wall")
    for _ru in (CORNER_RO, _bw_wall - CORNER_RO):
        for _rz in CORNER_ZR_WALL:
            _clr = max(_pu0 - _ru, _ru - (_pu0 + _pw), _pz0 - _rz, _rz - (_pz0 + _ph))
            assert _clr >= 4.0, (
                f"REAR_PANEL: corner rivet head at ({_ru:.1f}, {_rz:.1f}) is "
                f"{_clr:.1f} mm from the panel -- the panel will not lie flat")
    # (iv) the gap to the vent block carries the earth stud (D_GND) and still has
    # to leave a spanner's width either side. Measured to the PANEL edge now, not
    # the first station: the panel overhangs the cluster by REAR_PANEL_OV, and it
    # is the panel a spanner collides with.
    _v_r = max(c["u"] + c.get("w", 0.0) for c in rear if c["ref"] == "VENT")
    _gap = _pu0 - _v_r
    assert _gap >= D_GND + 2*8.0, (
        f"REAR_PANEL: only {_gap:.1f} mm between the last vent column and the "
        f"panel edge -- the earth stud (Ø{D_GND}) and its spanner do not fit")
    # every station has to fit BETWEEN the wall's top and bottom edges too -- the
    # USB coupler flange is the tall one, and the wall is only REAR_WALL_H
    _tall = max(kw for _cu, kw in lay.values())
    assert _tall <= REAR_WALL_H - 2*4.0, (
        f"REAR_IO: widest keep-out {_tall:.1f} does not leave 4 mm of wall above "
        f"and below on a {REAR_WALL_H:.0f} mm wall")
    # 8c. the two bricks (#754). They are split BY RAIL and must not overlap each
    #     other in plan, or the second one has nowhere to bolt down.
    _bk = buck_mounts()
    assert len(_bk) == 2, f"BUCK_SPLIT: expected 2 bricks, got {len(_bk)}"
    (_n1, _u1, _v1, _), (_n2, _u2, _v2, _) = _bk
    _clear = abs(_u2 - _u1) - BUCK_BODY[0]
    assert _clear >= 8.0, (
        f"BUCK_SPLIT: {_n1} and {_n2} leave {_clear:.1f} mm between bodies -- no room "
        "to land the wiring, and no air between two things that both make heat")
    #     ...and both have to stay on the plate in u. NOT in v: the bricks are
    #     DELIBERATELY under the connector band -- that is what the REAR_BAY height
    #     gate above checks, and it is why they are 22.1 mm tall things bolted flat
    #     rather than anything on standoffs. A planar "clear of REAR_CONN_DEPTH"
    #     rule would contradict it and push them off the plate for no reason.
    for _bn, _bu, _bv, _ in _bk:
        assert _bu - BUCK_BODY[0]/2.0 >= EDGE and _bu + BUCK_BODY[0]/2.0 <= W - 2*T - EDGE, (
            f"BUCK_SPLIT: {_bn} spans u {_bu - BUCK_BODY[0]/2.0:.1f}.."
            f"{_bu + BUCK_BODY[0]/2.0:.1f}, outside the {EDGE:.0f} mm edge margins")

    # ...and no rear-I/O dimension may exist without a recorded provenance, so a
    # new connector cannot be added without saying where its numbers came from
    _dims = [k for k in globals()
             if k.startswith(("D_TRS", "MIDI_", "USB3_")) and k not in
             ("USB3_CORNER_R", "USB3_CUT_SQ", "USB3_FIT")]
    _dims += ["D_PD_BORE", "D_PWRBTN", "PWRBTN_HEAD_D", "D_FUSE", "D_GND"]
    _missing = sorted(set(_dims) - set(REAR_IO_PROVENANCE))
    assert not _missing, (
        f"REAR_IO: {_missing} have no entry in REAR_IO_PROVENANCE -- say whether "
        "each is measured, from a datasheet, or unconfirmed before it is cut")

    # 2-ply tile ink must fit the trapezoid the same way the 3D tiles do (#946).
    for label, _u, _v in PEDALS:
        _tile_ink(label)
    return True

# ---- side-wall exhaust vents (#753) ------------------------------------------
# The rear vents moved LEFT when the I/O cluster took the right-hand wall, which put
# the exhaust 200..400 mm upstream of the Pi -- the hottest thing in the box and now
# the furthest from an opening. These put an outlet in each side wall directly
# beside the electronics bay instead, so hot air leaves where it is made.
#
# They are FOAM-BACKED, and that is a requirement, not a finish note: a bare louvre
# at eye level on a stage box shows the loom and the LEDs through it. Open-cell
# filter foam on the inside face fixes that and costs airflow, so the free-area
# check below derates them rather than counting the slots at face value.
SIDE_VENT_V     = (250.0, 372.0)   # depth band: over the boards, clear of the rear
                                   # connectors' 45 mm wiring reserve
SIDE_VENT_MARGIN = 12.0            # keep clear of the bottom fold and the wedge top
SIDE_VENT_MIN_SL = 20.0            # a trailing column may shorten to this rather
                                   # than be dropped -- the stepped field should
                                   # run the full band
FOAM_OPEN_FRACTION = 0.5           # open-cell PU filter foam, ~45 ppi: half the
                                   # geometric area survives as free area. Measured
                                   # figures for this class run 0.5..0.7; the low end
                                   # is taken because it is the one that has to hold.


def _side_wall_top(y):
    """Conservative side-wall height at depth y, in the flat pattern's frame.

    The blank's own wedge solver (shf_f/shf_r in dxf_base) is exact and delicate;
    this is deliberately a hair LOW -- it ignores the bend deduction, so slots
    placed under it sit below the real wedge top with margin to spare.
    """
    return H_FRONT + y * math.tan(math.radians(SLOPE_ANGLE))


def side_vents(flap, bw):
    """Louvre slots in one side wall, in flat-pattern coordinates.

    flap: 'R' (extends +x from bw) or 'L' (extends -x from 0). Slots run ALONG the
    depth axis and stack up the wall, which is the way a louvre sheds anything that
    lands on it when the case is upright.

    The field is BRICK-BOND on the wedge (user call, 2026-08-18): rows of parallel
    slots with every other row phase-shifted half a period, like running bond, and
    each row starts only where the sloped wall above it is tall enough -- so the
    field's leading edge follows the hypotenuse diagonally instead of floating as
    a rectangle on a triangular wall. Structure: the webs between slots stay
    2T = 4 mm vertically and 8 mm along the row (same as the rear array), and the
    stagger means no web line is cut twice in a row -- stiffer than aligned
    columns, not weaker. Edge slots clip to the band/slope and are dropped below
    SIDE_VENT_MIN_SL rather than left as stubs.
    """
    sl, sw = VENT_SLOT
    v0, v1 = SIDE_VENT_V
    period = sl + 8.0
    tan_s = math.tan(math.radians(SLOPE_ANGLE))
    out = []
    r = 0
    while True:
        off = SIDE_VENT_MARGIN + r * VENT_PITCH
        # depth from which the wedge above is tall enough for this row's top edge
        v_min = max(v0, (off + sw + SIDE_VENT_MARGIN - H_FRONT) / tan_s)
        if v1 - v_min < SIDE_VENT_MIN_SL:
            break
        phase = period / 2.0 if r % 2 else 0.0
        u = (bw + off) if flap == 'R' else (-off - sw)
        v = v0 + phase - period          # start a period early so clipped heads emit
        while v < v1:
            lo, hi = max(v, v_min), min(v + sl, v1)
            if hi - lo >= SIDE_VENT_MIN_SL:
                out.append({"kind": "rect", "u": u, "v": lo, "w": sw, "h": hi - lo,
                            "ref": "SIDE_VENT", "layer": "VENT"})
            v += period
        r += 1
    return out


def _bottom_vents_local(bw, bd):
    """Intake-vent block in the clear gap between the front and CLEAR/BANK platform
    rows (air enters here, crosses the boards, exits the rear-wall vents). Same
    brick bond as every other vent field -- nobody sees the underside, but the
    stagger costs nothing and the floor takes the machine's weight."""
    sl, sw = VENT_SLOT
    cols, rows = 6, 5
    gap_y = (PEDAL_ROW1_V + FSW_SLOT_D/2 + PLATFORM_MARGIN +
             PEDAL_ROW2_V - FSW_SLOT_D/2 - PLATFORM_MARGIN) / 2.0
    u0, v0 = bw/2 - (cols*(sl+14))/2, gap_y - (rows*VENT_PITCH)/2
    cuts = _vent_array(u0=u0, z0=v0, cols=cols, rows=rows, cp=sl + 14)
    # SUPPORT-POST KEEP-OUT (POST_V=165 sits over this field): drop any slot that
    # would land under a post foot/pad footprint (+4 mm margin) so the feet bolt
    # to solid floor. The free-area gate still enforces VENT_FREE_AREA_MIN --
    # currently ~16k mm^2 total, so the dropped slots cost nothing that matters.
    keep = []
    for c in cuts:
        b = _bbox(c)
        hit = False
        for u in POST_U:
            fu0, fu1 = u - POST_PW/2 - 4, u + POST_PW/2 + 4
            fv0 = _POST_VP - POST_FOOTL - 4
            fv1 = _POST_VP + POST_T + 4
            if b[0] < fu1 and fu0 < b[2] and b[1] < fv1 and fv0 < b[3]:
                hit = True
        if not hit:
            keep.append(c)
    return keep


def _bottom_vents():
    return _bottom_vents_local(W - 2*T, D - 2*T)

# --- internal board mounting -------------------------------------------------
# Bottom-plate frame: x = width (0..W-2T), y = depth (0..D-2T, 0 = front).
# The pedal platforms hang from the walls at the front + CLEAR/BANK rows, so the
# REAR strip of the bottom plate is the clear floor for the electronics. ONE
# control board -- the console board v2 (#747) -- mounts there on M3 standoffs
# (>= STANDOFF_H for airflow); the 16" screen above is shallow and clears it.
# The board's position is BOARD_U below (both boards under the 16" screen); the
# V1-era rationale about a Pro Micro USB plug facing the platform column died
# with that board -- the v2 board's only cable to the Pi is the keyed ribbon.
# Both boards live under the 16" screen now. The console board terminates five rear
# stations, so the cluster moved with it (see REAR_IO_U) -- which is what makes this
# possible: the board is still under its own connectors, and the Pi is 30 mm away
# instead of 402, so the ribbon is a stock 10 cm part rather than something to hunt.
#
# THE CLUSTER FOLLOWS THE BOARD, and that is electrical, not tidiness: the CTRL
# tip lines are unshielded analog running into an ADC -- the noisiest thing in
# the box to lengthen -- so wherever the board goes, CTRL_1/CTRL_2 (and the rest
# of the five stations) go with it. A reshuffle that parks the CTRL jacks away
# from the board's end of the cluster buys hum on an expression pedal.

# --- screen-stand floor anchors (#762): M3 tap pilots for the 7in tower (6)
# and the 15.6in bridge stands (4+4). Stations from the verified Fusion
# assembly (stand flanges), floor-flat coords (u=x, v=y world -- the floor has
# no slope projection).
STAND_ANCHORS_7IN = [
    # 7in tower (RE-MEASURED from the tower flange holes in the verified doc,
    # 2026-08-19: the previous frozen values predated BOTH the lit-area
    # re-anchor (+2.75) and the tower placement correction -- they were 6.0 mm
    # forward of the actual flange holes, caught by /code-review + a Fusion
    # probe. These MUST track the tower: after any S7C_*/placement change,
    # re-probe the doc's flange holes before cutting the base.
    # build_screen7_tower_step() cross-checks the RELATIVE pattern against its
    # own computed flange stations at build time (#767).)
    (25.8, 279.5), (25.8, 359.5), (217.8, 279.5), (217.8, 359.5),   # 7in tower sides
    (121.8, 246.1), (121.8, 392.8),                                  # 7in tower f/r
]
STAND_ANCHORS_156 = [
    # 15.6in bridge stands (doc-verified 0.1; build_screen16_stand_steps()
    # cross-checks these against its computed flange stations at build time, #767)
    (480.0, 205.0), (480.0, 327.0), (454.0, 236.0), (454.0, 296.0),  # 15.6 L
    (765.0, 205.0), (765.0, 327.0), (739.0, 236.0), (739.0, 296.0),  # 15.6 R
]
STAND_ANCHORS = STAND_ANCHORS_7IN + STAND_ANCHORS_156
STAND_ANCHOR_TOL = 0.15   # mm; tighter than any real drift, looser than float noise


def _check_stand_anchors(computed, frozen, who, tol=STAND_ANCHOR_TOL):
    """Frozen base-floor stations == the stations the stand builder just computed,
    ABSOLUTELY (both in world plan coords). Order-independent: each frozen station
    must have exactly one computed partner inside tol."""
    assert len(computed) == len(frozen), \
        f"{who}: {len(computed)} computed flange holes vs {len(frozen)} frozen STAND_ANCHORS"
    left = list(computed)
    for fx, fy in frozen:
        hit = [c for c in left if abs(c[0] - fx) <= tol and abs(c[1] - fy) <= tol]
        assert hit, (f"{who}: frozen STAND_ANCHOR ({fx:.1f}, {fy:.1f}) has no computed flange hole "
                     f"within {tol} mm -- re-probe the doc and update STAND_ANCHORS "
                     f"(computed: {['(%.1f, %.1f)' % c for c in left]})")
        left.remove(hit[0])


def _check_stand_anchor_pattern(computed, frozen, who, tol=STAND_ANCHOR_TOL):
    """Same idea for a part whose STEP is built in a LOCAL frame and placed in Fusion
    by a translation the generator does not know: compare the RELATIVE pattern, i.e.
    every pairwise (dx, dy) between stations. Translation-invariant by construction,
    so it still bites on any size/spacing/count change. Both lists must be in the
    same station ORDER (they are: the frozen list was transcribed from this loop)."""
    assert len(computed) == len(frozen), \
        f"{who}: {len(computed)} computed flange holes vs {len(frozen)} frozen STAND_ANCHORS"
    n = len(frozen)
    for i in range(n):
        for j in range(i + 1, n):
            cd = (computed[j][0] - computed[i][0], computed[j][1] - computed[i][1])
            fd = (frozen[j][0] - frozen[i][0], frozen[j][1] - frozen[i][1])
            assert abs(cd[0] - fd[0]) <= tol and abs(cd[1] - fd[1]) <= tol, (
                f"{who}: station {i}->{j} spacing drifted -- builder ({cd[0]:+.2f}, {cd[1]:+.2f}) "
                f"vs frozen STAND_ANCHORS ({fd[0]:+.2f}, {fd[1]:+.2f}), tol {tol} mm. "
                "Re-probe the doc's flange holes and update STAND_ANCHORS before cutting the base.")


# stand anchors: each station must clear the ACTUAL bottom vent slots (derived,
# not a frozen field box -- the old hardcoded 256..576 x 145..191 window would
# have silently stopped covering the real field on any vent/pedal-row change)
for (_au, _av) in STAND_ANCHORS:
    for _vc in _bottom_vents_local(W - 2*T, D - 2*T):
        _vb = _bbox(_vc)
        assert not (_vb[0] - 3.0 < _au < _vb[2] + 3.0 and _vb[1] - 3.0 < _av < _vb[3] + 3.0), \
            f"STAND_ANCHOR ({_au},{_av}) lands in vent slot (u {_vb[0]:.0f}..{_vb[2]:.0f}, v {_vb[1]:.0f}..{_vb[3]:.0f})"

BOARD_U = 560.0   # +48 from 512 (user call 2026-08-19: centre the cluster under
                  # the 16" screen; the Pi moved +48 WITH it -- PI_PCB_U0=670.5,
                  # PCB 670.5..726.5 -- keeping the 10cm ribbon's ~61 gap).
                  # Electrically BETTER: CTRL_1/2 at u 662/706, so the move
                  # SHORTENS the unshielded analog runs by 48. Nearby limits:
                  # Pi right edge 726.5 vs the 15.6 R-stand flange at ~733
                  # (6.5 clear). Also widens the 15.6 L-tower strip to ~93.
def board_mounts():
    bw, bd = W - 2*T, D - 2*T
    return [("CONSOLE_BOARD", BOARD_U, bd - 145.0, BOARD_HOLES)]

# Depth the rear wall needs behind it, clear of everything, for the panel-mount
# connectors and their wiring (#743). Deepest body is ~30 (D-series TRS, fuse
# holder), then solder lugs stick out ~5 and the wire wants ~10 of bend before it
# turns -- so 45 is the floor and the Pi is placed at ~50.
REAR_CONN_DEPTH = 45.0

# Pi build only: the Raspberry Pi rides four M2.5 risers (PI_RISER_H tall), sitting
# ABOVE the main board and the buck so none of the three clash.
# Returns (centre_u, centre_depth, (u_span, depth_span)) for the 58x49 Pi 4 hole pattern.
# NOTE the Pi 4's hole pattern is NOT centred on the board: along the 85 mm length the
# holes sit 3.5/61.5 mm from the SD edge, i.e. the pattern centre is 10 mm SD-ward of the
# board centre; the PCB port edge is centre_depth + 52.5.
#
# #743 MOVED IT, twice. It used to sit at (BOARD_ANCHOR_U, bd - 56), which put the
# PCB port edge 3.5 mm off the plate's rear edge -- correct while a window existed,
# because the Pi's own USB/Ethernet stack poked through it. With the window gone
# that stack faces solid folded metal, and those 3.5 mm are where nine connector
# bodies and their wiring now live.
#
# Sliding it straight forward fixed the depth but put it on top of the main board,
# leaving 4.3 mm of head and making the bespoke riser load-bearing. Moving it
# SIDEWAYS instead, to the floor under the 16" screen, is strictly better: that bay
# is empty (board, buck and both mid pedestals are all left of the screen), the
# screen module is only BIG_DEPTH deep so ~72 mm of interior stays free beneath it,
# and it sits right in front of the rear exhaust vents. Nothing is stacked over
# anything, so the riser reduces to a plain standoff.
#
# Cost, for the record: the run to the USB couplers gets ~250 mm longer. The 16"
# HDMI gets shorter, the 7" longer.
# ...and ROTATED 90 deg. The Pi 5 carries USB-A x4 + Ethernet on one 56 mm edge and
# USB-C + both micro-HDMI on an 85 mm edge. Unrotated, the 85 ran along v and that
# port edge faced the REAR -- which made sense pointing at a window and makes none
# now, because every cable goes LEFT: the panel USB couplers (u 332/376), the buck
# (u 300) and the 7" screen (u 42..196) are all to the left, and only the 16" screen
# is overhead. Rotated, the port edge faces -u and the runs are straight. It also
# drops the depth from 85 to 56, which buys back rear-bay clearance.
# The Pi is ROTATED so its 40-pin header runs along DEPTH, on the board-facing
# edge. That is what makes the ribbon a straight shot: J2 sits on the console
# board's +u edge with its pins running along v, so the Pi's header has to run
# along v too, or the cable leaves one connector and turns 90 deg to reach the
# other. The script used to have the 85 mm axis along u, which is a quarter turn
# from that -- caught by eye in the Fusion assembly, not by a gate.
#
#   u: 56 mm across, holes 49 apart, symmetric (3.5 in from each long edge)
#   v: 85 mm along,  holes 58 apart, NOT symmetric -- 3.5 from one end, 23.5 from
#      the other, so the hole pattern sits 10 mm toward the SD-card end
PI_HDR_LEN   = 50.8           # 2x20 on 0.1in
PI_HDR_V_OFF = 32.5           # header centre from the Pi's 3.5 mm hole end -- which
                              # is also where the hole pattern centres, so aligning
                              # the header to J2 aligns the hole pattern with it
PI_PCB_U0    = 670.5          # board-facing long edge: sets the ribbon run (below).
                              # +48 with BOARD_U (user call 2026-08-19): the PAIR
                              # moves together so the 10 cm ribbon keeps its
                              # designed ~60 mm hop and the cluster centres under
                              # the 16" screen (centre 618 vs 625).
PI_HDR_V     = 281.75         # header centre in v == J2's centre in v, so the two
                              # connectors face each other square across the gap


def pi_mount():
    bd = D - 2*T
    # Hole-pattern centre. u: midway between holes 3.5 in from each 56 mm edge.
    # v: the pattern centres on PI_HDR_V by construction (see PI_HDR_V_OFF).
    return (PI_PCB_U0 + 28.0, PI_HDR_V, (PI_HOLES[1], PI_HOLES[0]))  # 49 across u, 58 along v

def pi_pcb_extent():
    """PCB footprint (u_lo, u_hi, v_lo, v_hi) for the ROTATED Pi.

    85 mm along v, 56 mm across u. The hole pattern is not centred along the 85 mm
    axis: 3.5 mm from one end and 23.5 from the other, i.e. 10 mm toward the SD
    edge, so the PCB reaches 32.5 one way and 52.5 the other from the hole centre.
    """
    u, v, _ = pi_mount()
    return (u - 28.0, u + 28.0, v - 32.5, v + 52.5)                  # SD edge at -v

# External 5V buck: eleUniverse 8-36V -> 5V 10A 50W IP67 potted brick (Amazon
# B0GGHN97TK; envelope 63.8 x 57.7 x 22.1 incl. mounting ears, 116 g, passive
# aluminium shell) — the add-on that makes 5V for the Pi + screens (the
# in-production board is untouched). Screws FLAT to the floor of the rear
# airflow bay by its two end ears (no standoffs), long axis along u.
# (Replaces the Pololu D24V90F5 — too expensive / hard to source.)
BUCK_BODY = (63.8, 57.7, 22.1)
BUCK_EAR_SPACING = 56.0       # ear hole centres along the long axis — PROVISIONAL
                              # until the unit arrives; drill to the real part
# TWO of them (#754). One 10 A brick cannot carry the whole console: worst case is
# 11.7 A at 5 V (58.5 W) and a 50 W part would be 18% over. They are split BY RAIL,
# never paralleled -- two buck outputs tied together have no current sharing, so one
# hogs the load until it limits and then they hunt. Same 20 V input, separate 5 V
# outputs, common ground only:
#   BUCK_PI  -> Pi 5 + its USB + the NVMe        ~5.0 A / 25 W   (50% of part)
#   BUCK_AUX -> both screens + this board + LEDs ~6.7 A / 34 W   (67% of part)
# BUCK_AUX is the tighter one and the one that wants airflow; a cheap 10 A module
# is rarely honest at 10 A in still air.
BUCK_GAP = 12.0               # between the two bricks, for wiring and air
def buck_mounts():
    """Both bricks, side by side in the rear airflow bay, long axis along u. Left of
    the console board keeps the runs to the inlet and to J3 short and stays clear of
    the CLEAR/BANK pedal platform, which owns u 230..313."""
    bd = D - 2*T
    v = bd - 60.0
    pitch = BUCK_BODY[0] + BUCK_GAP
    return [("BUCK_PI",  410.0 - pitch/2.0, v, BUCK_EAR_SPACING),
            ("BUCK_AUX", 410.0 + pitch/2.0, v, BUCK_EAR_SPACING)]

# ===========================================================================
# DXF  (ezdxf)
# ===========================================================================

def _doc():
    import ezdxf
    doc = ezdxf.new("R2018", setup=True)
    doc.units = 4  # mm
    # bold face for printed legends (the overlay shop substitutes their Arial
    # Bold; the DXF style just names it -- thicker strokes than the default)
    doc.styles.add("SILKBOLD", font="arialbd.ttf")
    doc.layers.add("CUT", color=7)
    doc.layers.add("BEND", color=4, linetype="DASHED")
    doc.layers.add("ENGRAVE", color=3)
    doc.layers.add("VENT", color=7)
    doc.layers.add("NOTE", color=8)
    doc.layers.add("SILK", color=5)    # silkscreen (printed labels)
    # MASK is annotation, never cut: rings around the features the powder coater
    # has to keep bare (thread pilots, the earth stud's bonding land). Excluded from
    # every area/extents pass the same way NOTE/ENGRAVE are.
    #
    # DASHDOT is load-bearing, not decoration (#775 R3): a plain solid CIRCLE on an
    # unfamiliar layer is geometrically indistinguishable from a hole, and the biggest
    # one here is Ø20 straight through the M6 earth-stud land -- cut it and the base is
    # scrap AND the safety earth is gone. Dash-dot + red + a per-ring callout (see
    # _mask_circle) means no operator can mistake it for cutting data.
    doc.layers.add("MASK", color=1, linetype="DASHDOT")
    return doc

def _circle(msp, x, y, d, layer="CUT"):
    msp.add_circle((x, y), d / 2.0, dxfattribs={"layer": layer})

def _silk_fill(msp, kind, spec):
    """SOLID-fill a SILK symbol so it prints as artwork, not as a hairline outline.

    Glyphs on this layer are TEXT -- the printer's RIP fills them. The transport
    symbols (see _silk_symbol_geometry) are plain geometry, so without a hatch an
    overlay printer would trace the outline and leave the middle black: an empty
    ring where the record dot belongs. The outline entity stays as well, so the
    shape survives in readers that ignore hatches.
    """
    # color=256 is BYLAYER, and it has to be the NAMED argument -- add_hatch
    # overwrites dxfattribs["color"] with it. A HATCH left at add_hatch's ACI 7
    # default renders WHITE on a white sheet and the symbol prints as a bare
    # outline: the same bug that hid the VENT louvres (#775 R1), one level down
    # at the entity. Do NOT "tidy up" by adding set_solid_fill() back either --
    # add_hatch already sets solid_fill and the SOLID pattern, and that call
    # would reset the colour to 7 all over again.
    h = msp.add_hatch(color=256, dxfattribs={"layer": "SILK"})
    if kind == "circle":
        cx, cy, r = spec
        h.paths.add_edge_path().add_arc((cx, cy), r, 0.0, 360.0)
    elif kind == "poly":
        h.paths.add_polyline_path(spec, is_closed=True)
    else:
        raise ValueError("unknown silk fill kind: %r" % (kind,))
    return h


def _engrave_fill(msp, kind, spec, holes=None):
    """SOLID-fill an ENGRAVE region so a 2-ply laser burns through the cap.

    Same hatch trap as `_silk_fill`: color=256 is BYLAYER (named argument), and
    the outline stays on the layer so a reader that ignores hatches still sees
    the glyph. ENGRAVE is color 3, so BYLAYER cannot vanish on a white sheet.
    """
    h = msp.add_hatch(color=256, dxfattribs={"layer": "ENGRAVE"})
    if kind == "circle":
        cx, cy, r = spec
        h.paths.add_edge_path().add_arc((cx, cy), r, 0.0, 360.0)
    elif kind == "poly":
        h.paths.add_polyline_path(spec, is_closed=True)
        for hole in holes or []:
            h.paths.add_polyline_path(hole, is_closed=True)
    else:
        raise ValueError("unknown engrave fill kind: %r" % (kind,))
    return h


def _poly(msp, pts, layer="CUT", closed=True):
    msp.add_lwpolyline(pts, close=closed, dxfattribs={"layer": layer})

# Feature refs that are coating masks, not holes. Named so _emit can hold the one
# invariant that matters: a mask can never be emitted onto a cutting layer (#775 R3).
MASK_REFS = ("PANEL_BOND", "EARTH_MASK")

def _mask_circle(msp, x, y, d, what):
    """A NO-PAINT coating-mask ring plus its own leader and callout.

    Never a cut. Every mask ring in the package gets one of these instead of a bare
    circle: the ring is dash-dot red on layer MASK, and the leader carries the words
    "NO CORTAR" right next to the geometry, so the warning travels with the feature
    even if someone flattens layers or looks only at the PDF (#775 R3, Spanish #778)."""
    r = d / 2.0
    _circle(msp, x, y, d, "MASK")
    _poly(msp, [(x + r * 0.707, y + r * 0.707), (x + r + 6.0, y + r + 6.0),
                (x + r + 30.0, y + r + 6.0)], "MASK", closed=False)
    _text(msp, x + r + 7.0, y + r + 8.0, 4.5,
          f"MASK Ø{d:.0f} - NO PINTAR, NO CORTAR ({what})", "MASK")

def _rrect(msp, x, y, w, h, r=R_FILLET, layer="CUT"):
    r = max(0.0, min(r, w / 2.0, h / 2.0))
    if r == 0.0:
        _poly(msp, [(x, y), (x+w, y), (x+w, y+h), (x, y+h)], layer); return
    b = math.tan(math.radians(22.5))      # bulge for a 90 deg corner fillet (NOT 45 -> that is a 180 deg bump)
    pts = [(x+r, y, 0.0), (x+w-r, y, b), (x+w, y+r, 0.0), (x+w, y+h-r, b),
           (x+w-r, y+h, 0.0), (x+r, y+h, b), (x, y+h-r, 0.0), (x, y+r, b)]
    msp.add_lwpolyline(pts, format="xyb", close=True, dxfattribs={"layer": layer})

def _text(msp, x, y, h, s, layer="ENGRAVE", wf=1.0, halign="left"):
    from ezdxf.enums import TextEntityAlignment
    al = TextEntityAlignment.CENTER if halign == "center" else TextEntityAlignment.LEFT
    attrs = {"layer": layer, "width": wf}
    if layer == "SILK":
        attrs["style"] = "SILKBOLD"          # legends print BOLD
    msp.add_text(s, height=h, dxfattribs=attrs).set_placement((x, y), align=al)

def _emit(msp, feats, ox=0.0, oy=0.0):
    for f in feats:
        layer = f.get("layer", "CUT")
        assert not (f.get("ref") in MASK_REFS and layer != "MASK"), \
            f"{f.get('ref')} is a coating mask -- it must never be emitted on layer {layer}"
        x, y = f["u"] + ox, f["v"] + oy
        if f["kind"] == "circle":
            if layer == "MASK":
                _mask_circle(msp, x, y, f["d"], f.get("ref", "coating mask"))
            else:
                _circle(msp, x, y, f["d"], layer)
        elif f["kind"] == "ring":
            # only the OD is a real cut: the ID/shaft geometry belongs to the
            # ring_disc part (its own DXF) -- emitting the ID here put a scrap
            # circle inside the aperture (2 wasted laser pierces, #760 audit)
            _circle(msp, x, y, f["od"], layer)
        elif f["kind"] == "rect":
            r = f.get("r", 0.0 if layer in ("ENGRAVE",) else R_FILLET)
            _rrect(msp, x, y, f["w"], f["h"], r=r, layer=layer)

# ---- parts -----------------------------------------------------------------

def _mirror_u(feats, width):
    """Mirror a feature list across width/2 (u -> width-u) so the flat pattern matches
    the geometry, whose canonical (7"-left) orientation is baked in by a Y-mirror."""
    out = []
    for c in feats:
        c = dict(c)
        if c["kind"] == "rect":
            c["u"] = width - (c["u"] + c["w"])
        else:
            c["u"] = width - c["u"]
        out.append(c)
    return out

def dxf_faceplate(path):
    """REMOVABLE LID (top plate), developed flat = a simple rectangle: the sloped top
    plate (all cutouts) + a down-turned FRONT LIP (screws into the front wall) + a REAR LAP
    (folds onto the transition shoulder, screws DOWN into tapped M3 holes). The SIDES are on the base;
    the lid drops in and rests on the side-wall top edges. NOTE: the front-lip hole sits
    close to the fold (12mm front) -- laser + tap after bending (see H_FRONT)."""
    doc = _doc(); msp = doc.modelspace()
    ffl, rl = LID_FRONT_FL, LRL
    PW, PV = FP_W, FP_V
    LW, ox = LID_W, LID_OX               # full-width blank; schedule content offset inside it
    yr0 = ffl + PV                       # rear fold (top plate -> rear lap)
    yr1 = yr0 + rl
    _poly(msp, [(0, 0), (LW, 0), (LW, yr1), (0, yr1)], "CUT")
    _poly(msp, [(0, ffl), (LW, ffl)], "BEND", closed=False)                # front lip fold (FULL width)
    _poly(msp, [(0, yr0), (LW, yr0)], "BEND", closed=False)                # rear lap fold (FULL width)

    cuts, _engr = faceplate_holes()                   # canonical layout, 7" left
    # the ENCODER shaft hole lives in the ring_disc part, not this plate -- the
    # entry stays in faceplate_holes() for the renders/assembly, but cutting it
    # here would just pierce scrap inside the RING aperture (#760 audit)
    _emit(msp, [c for c in cuts if c.get("ref") != "ENCODER"], ox=ox, oy=ffl)
    # legends are NOT silkscreened on the metal -- they live on a printed adhesive overlay
    # (dxf_overlay / segno_overlay). Keeps the metal a plain cut+bend+powder part (cheap).
    for u in FRONT_SCREW_U:
        # lip hole HEIGHT matched to the wall hole (z = FRONT_SCREW_Z + DEV90
        # = 6.955): station from the lid's front mold corner = _cfy - z, flat from
        # the fold line = station - DD_LIP. The old ffl/2 sat 0.74 high. (#760)
        _circle(msp, ox + u, ffl - ((_cfy - FRONT_SCREW_Z - DEV90) - DD_LIP), 3.4)  # M3 clearance
    for u in FRONT_SCREW_U:
        _circle(msp, ox + u, SEAM_LAP_V, 3.4)                             # rear lap -> transition: SAME 9
                                                                          # stations as the front lip (#760),
                                                                          # Ø3.4 M3 clearance, concentric
                                                                          # with the flange tap pilots
    _text(msp, 10, yr1+8, 8, f"Segno TAPA SUPERIOR (segno_faceplate)  chapa 2.0 mm  CANT. 1  tapa + pestaña frontal + solapa trasera (= {180-(SLOPE_ANGLE+TRANS_ANGLE):.0f}°); apoya sobre las paredes laterales del cuerpo; sin tornillos a la vista; las leyendas van en el CALCO impreso (ver segno_overlay); PLEGAR con la cara DIBUJADA como CARA EXTERIOR (espejado canónico: el encoder queda a la IZQUIERDA del músico) AJUSTE DE LA PESTAÑA FRONTAL: plegar la pestaña de modo que quede {LIP_FIT_CLEAR:.1f} mm de holgura entre la cara INTERIOR de la pestaña y la cara EXTERIOR de la pared frontal del cuerpo, MEDIDO DESPUÉS DE PINTAR (ambas caras se pintan, no se enmascara nada). En el CAD el ajuste es cara contra cara, por lo que la pestaña debe plegarse levemente abierta; verificar que la tapa entre sobre el cuerpo terminado antes del plegado definitivo", "NOTE")
    doc.saveas(path)
    return {"blank": (LW, yr1)}

def dxf_overlay(path):
    """PRINTED ADHESIVE TOP-PLATE OVERLAY -- replaces silkscreen. A polycarbonate/vinyl
    graphic bonded to the faceplate: BLACK field, WHITE legends, apertures die-cut to match
    the metal cutouts. Goes to a label/overlay printer, NOT the sheet-metal shop -- so the
    metal stays a plain cut+bend+powder part and there is no per-screen silkscreen setup."""
    doc = _doc(); msp = doc.modelspace()
    _poly(msp, [(0, 0), (FP_W, 0), (FP_W, FP_V), (0, FP_V)], "CUT")     # overlay outline (top-plate face)
    cuts, engr = faceplate_holes()
    _emit(msp, cuts, ox=0, oy=0)                                        # die-cut apertures (match the metal)
    for e in engr:
        k = e.get("kind")
        if k == "disc":                                                # symbol legends are SHAPES
            _circle(msp, e["u"], e["v"], e["d"], layer="SILK")         # (see _silk_symbol_geometry)
            _silk_fill(msp, "circle", (e["u"], e["v"], e["d"] / 2.0))  # ...printed SOLID, like a glyph
        elif k == "poly":
            _poly(msp, e["pts"], "SILK")
            _silk_fill(msp, "poly", e["pts"])
        else:
            _text(msp, e["u"], e["v"], e["h"], e["s"], layer="SILK",   # WHITE legend on the print
                  wf=e.get("wf", 1.0), halign=e.get("halign", "left"))
    _text(msp, 10, FP_V + 8, 8, "Segno CALCO SUPERIOR (segno_overlay)  CANT. 1  adhesivo impreso (policarbonato/vinilo); fondo NEGRO + leyendas BLANCAS; aberturas troqueladas; se pega sobre la tapa superior (no lleva serigrafía sobre el metal)", "NOTE")
    doc.saveas(path); return {}

def dxf_base(path):
    """ONE-PIECE BASE developed as a SINGLE flat blank: the bottom plate in the centre,
    with the FRONT, REAR and both SIDE walls as flaps that fold UP 90 deg on the four
    bottom edges (folding up from the flat bottom works at any front height). Corners
    are OPEN butt seams with a small relief hole each, closed by riveted internal
    L-brackets -- nothing on this build is welded. The rear flap has a SECOND fold
    = the transition shoulder. The lid drops in on top, screwed at the front + rear."""
    doc = _doc(); msp = doc.modelspace()
    BW, BD = W - 2*T, D - 2*T               # bottom plate (folds up to ~W x D outer)
    # Exact bend allowance: each flap's flat extent = wall height - the 90-deg bend
    # deduction (T + K*T), so the folded OUTER dimensions come out at nominal.
    bdd = DEV90                              # exact 90-deg development (issue #237)
    # The front wall must NOT rise to H_FRONT: the lid's lip-fold KNUCKLE (inner
    # radius RI about an axis RI behind the lip inner face and RI perpendicular
    # below the lid underside) rolls through the wall's top-corner band, and a
    # straight top edge across the T thickness only clears the roll below the
    # bend-axis height (the pocket is tangent to the lip plane exactly there).
    # The sides already carry the LIPR_R cove for the same roll; the front wall
    # takes a height drop instead (an edge bevel across 2mm is not a flat-pattern
    # feature). The gap is invisible: the lip skirts down over it. (#760)
    _axis_h = ((_cfy - T / math.cos(_ra))                       # underside @ lip corner
               + ((-DEV90 + RI) - _cfz) * math.tan(_ra)         # ...out to the bend axis
               - RI / math.cos(_ra))                            # RI perpendicular below
    FRONT_LIP_CLEAR = 0.3
    Hf = (_axis_h - FRONT_LIP_CLEAR) - bdd
    # NO HEM (#760, reverted): a 180-deg hem's bend zone (~4mm at the T2 rule)
    # plus the floor bend's (~4mm) leaves a ~2mm straight band on the 10.1mm
    # wall -- the screw holes would sit 3/4 INSIDE the hem's crown and wrap
    # around it. The wall stays single-thickness with a plain top edge (hidden
    # behind the full-drop lip); the screws drop to M3 -- 4 full threads when
    # hand-tapped in the T2 sheet (Ø2.5 pilot below), with drill-to-Ø5.1 +
    # M3 rivnut as the per-station repair path.
    _fscrew_flat = FRONT_SCREW_Z             # lip screws keep their ORIGINAL height
                                             # (= (H_FRONT - bdd)*0.5; bdd == DEV90)
    Hr = HR_FLAT                             # rear web from the seam solver: the flange
    Ht = HT_FLAT                             # outer lands ONE SHEET below the lap outer
    rrel = T + 1.0                          # small bend-relief radius at each corner
    LIPR_R = 3.0                            # lip-bend relief radius: a cove TANGENT
                                            # to the top edge AND the front edge
                                            # (mirrors the lid lip's roll)
    tan_a, tan_th = math.tan(_ra), math.tan(_rth)
    # side-wall wedge top, FRONT segment: ON the lid underside plane, anchored at
    # the front wall outer top corner (solver Z = -DEV90, i.e. flat y = -bdd -- the
    # solver frame's origin is the front BEND LINE, same axis as the flat's y)
    shf_f = lambda y: (H_FRONT + (y + bdd) * tan_a) - bdd
    # REAR segment: FLUSH on the transition FLANGE underside (two sheets below the
    # lap outer skin) so the full-width flange rests on the wedge tops with no gap.
    # RIDGE_Z is already in the flat-y frame -- adding bdd here drew the whole
    # segment ~0.87 low (caught by hand-editing the Fusion model).
    shf_r = lambda y: (RIDGE_Y - (y - RIDGE_Z) * tan_th
                       - 2.0 * T / math.cos(_rth)) - bdd
    # the two top segments meet in a single CREASE (no apex step): the flange
    # seat plane extended forward until it intersects the lid underside plane
    y_x = ((RIDGE_Y - 2.0 * T / math.cos(_rth) + RIDGE_Z * tan_th
            - H_FRONT - bdd * tan_a) / (tan_a + tan_th))
    _hyp = math.hypot(1.0, tan_a)
    h_F = (shf_f(0.0) + tan_a * LIPR_R - LIPR_R * _hyp)   # cove mouth on the front edge
    y_T = LIPR_R * (1.0 - tan_a / _hyp)                   # tangency depth on the top line
    h_T = shf_f(y_T)                                      # tangency height (on the line)
    lb  = math.tan(math.radians(90.0 - SLOPE_ANGLE) / 4.0)  # cove bulge (sweep 90-slope)
    fext  = (LID_W - BW) / 2.0              # flange side extension past the wall webs
    # the REAR flap is FULL OUTER WIDTH (like the lid): it folds up OUTSIDE the
    # side walls' rear edges and covers the corner seam from the back. The side
    # wedges stop a hair short of the rear wall's inner face, and the flap's
    # overhangs start a ROOT RELIEF above the fold band (beyond the bottom plate
    # there is nothing for the band to wrap -- same rule as any wing root).
    y_edge = BD - 0.15                      # side wedge rear edge (clears the rear
                                            # wall inner face at BD - 0.089)
    ROOT_REL = 2.6                          # overhang root relief past the rear
                                            # fold band (BA90/2 = 2.09 + margin)
    CORNER_R = 2.0                          # fillet where the wedge top meets it
    h_x = shf_f(y_x)                        # crease height (= shf_r(y_x))
    h_corner = shf_r(y_edge)                # wedge top at the rear edge

    # ---- one closed outer CUT contour (CCW): bottom + 4 fold-up flaps; the side flaps
    #      run the full edge and BUTT the front/rear flaps at the corners. The rear
    #      flap's FLANGE section is FULL OUTER WIDTH (steps out at the hinge) so it
    #      seats on the side-wall wedge tops; the wedge tops carry bend-radius
    #      reliefs for the lid's lip and lap folds (issue #237). --------------------
    turn = math.radians(90.0 - TRANS_ANGLE)     # corner turn: wedge top -> rear edge
    ft = CORNER_R * math.tan(turn / 2.0)        # fillet tangent setback
    fb = math.tan(turn / 4.0)                   # fillet bulge (CCW round-off)
    ax = h_corner + ft * math.sin(_rth)         # tangent on the wedge-top slope
    ay = y_edge - ft * math.cos(_rth)
    bx = h_corner - ft                          # tangent on the rear edge
    outline = [
        (0, -Hf), (BW, -Hf), (BW, 0),                                  # FRONT flap
        (BW+h_F, 0, lb), (BW+h_T, y_T),                               # lip relief cove: tangent
                                                                       # to the front edge, sweeps
                                                                       # up to kiss the top line
        (BW+h_x, y_x),                                                 # RIGHT flap: crease onto
        (BW+ax, ay, fb), (BW+bx, y_edge),                              # the flange seat plane,
        (BW, y_edge),                                                  # edge clear of the rear wall
        (BW, BD+ROOT_REL), (BW+fext, BD+ROOT_REL),                     # REAR flap: FULL OUTER
        (BW+fext, BD+Hr+Ht),                                           # WIDTH from the overhang
        (-fext, BD+Hr+Ht),                                             # roots up -- web + flange
        (-fext, BD+ROOT_REL), (0, BD+ROOT_REL),                        # fold OUTSIDE the side
        (0, y_edge),                                                   # walls' rear edges
        (-bx, y_edge, fb),                                             # LEFT flap: rear edge,
        (-ax, ay), (-h_x, y_x),                                        # fillet, crease
        (-h_T, y_T, lb), (-h_F, 0), (0, 0),                           # lip relief cove
    ]
    msp.add_lwpolyline([(pt + (0.0,))[:3] for pt in outline], format="xyb",
                       close=True, dxfattribs={"layer": "CUT"})

    # ---- bend lines: fold UP 90 on the four bottom edges; rear has a 2nd fold ------
    _poly(msp, [(0, 0), (BW, 0)], "BEND", closed=False)                # front
    _poly(msp, [(0, BD), (BW, BD)], "BEND", closed=False)             # rear
    _poly(msp, [(0, 0), (0, BD)], "BEND", closed=False)               # left
    _poly(msp, [(BW, 0), (BW, BD)], "BEND", closed=False)             # right
    _poly(msp, [(-fext, BD+Hr), (BW+fext, BD+Hr)], "BEND", closed=False)  # rear -> transition (full flange width)

    # ---- corner bend-relief holes + WELD-FREE riveted corners ----------------------
    # The 4 vertical corners join via internal L-brackets (segno_corner_bracket), pop-riveted
    # through both walls -- NO welding, so the whole shell is instant-quote (cut+bend+powder).
    for (cxr, cyr) in ((0, 0), (BW, 0), (0, BD), (BW, BD)):
        _circle(msp, cxr, cyr, 2*rrel)                                  # corner bend-relief
    # Rivets are placed at the SAME heights (z) on BOTH faces of a corner so a single folded
    # L-bracket lines up with all of them. z = height up the wall; RO = offset along the wall.
    # Only the TALL rear corners get riveted L-brackets. The short 12 mm FRONT corners are
    # already clamped top (lid front-lip screws into the front wall) + bottom (bottom-plate
    # fold ties both walls), so they stay a plain butt+relief corner -- no bracket needed.
    RV = D_M3; RO = CORNER_RO                  # 3.2 mm rivet clearance; offset from the corner
    # heights z are measured from the BOTTOM-PLATE TOP (the bracket rests there), so add T
    # to convert to a wall height above the fold line.
    for sgn, xc in ((+1, 0.0), (-1, BW)):     # +1 left (side flap -x) | -1 right (side flap +x)
        for z in CORNER_ZR_WALL:               # rear-wall leg (3 rivets)
            _circle(msp, xc + sgn*RO, BD + T + z, RV)      # rear-wall face   (flat y = BD + T + z)
        for z in CORNER_ZR_SIDE:               # side-wall leg (2 rivets, staggered)
            _circle(msp, xc - sgn*(T + z), BD - RO, RV)    # side-wall face

    # ---- bottom features: vents + Pi/board M3 standoffs + rubber feet -------------
    _emit(msp, _bottom_vents_local(BW, BD))
    _emit(msp, side_vents('R', BW))          # exhaust beside the electronics bay,
    _emit(msp, side_vents('L', BW))          # foam-backed -- see SIDE_VENT_V
    for name, cx, cy, (sx, sy) in board_mounts():
        for dx in (-sx/2, sx/2):
            for dy in (-sy/2, sy/2):
                _circle(msp, cx+dx, cy+dy, D_M3)
        _text(msp, cx - sx/2, cy + sy/2 + 4, 5, name, "NOTE")
    pcx, pcy, (psx, psy) = pi_mount()              # Pi build: 4 riser holes (M2.5) at the Pi pattern
    for dx in (-psx/2, psx/2):
        for dy in (-psy/2, psy/2):
            _circle(msp, pcx+dx, pcy+dy, D_M3)
    _text(msp, pcx - psx/2, pcy + psy/2 + 4, 5, f"PI_RISER separadores {PI_RISER_H:.0f} mm (versión Raspberry Pi)", "NOTE")
    for _i, (_bn, bkx, bky, bsp) in enumerate(buck_mounts()):   # 2x 20V->5V brick, 2 ear holes each
        for dx in (-bsp/2, bsp/2):
            _circle(msp, bkx+dx, bky, D_M4)
        # the two bricks sit one brick-pitch apart and their labels are far wider
        # than that, so stack them instead of printing one over the other
        _text(msp, bkx - bsp/2, bky + BUCK_BODY[1]/2 + 4 + 8.0*_i, 5,
              f"{_bn} 20V>5V 10A (B0GGHN97TK; paso de orejas PROVISORIO)", "NOTE")
    for x, y in base_foot_xy():                    # M4 clearance, plain hole: the
        _circle(msp, x, y, D_FOOT)                 # head is relieved in the RING
    _emit(msp, platform_foot_holes())              # M3 holes for the 10 pedal-platform feet
    for (au, av) in STAND_ANCHORS:                 # screen-stand feet: M3 tap pilots (#762)
        _circle(msp, au, av, 2.5)
    for u in POST_U:                               # 2 base-anchored support-post feet (issue #292)
        for du in (-POST_BOLT_DU, POST_BOLT_DU):   # foot forward of the web, clear of vent + display
            _circle(msp, u+du, _POST_FOOT_VP, D_M4)
    _text(msp, POST_U[0]-24, _POST_FOOT_VP + 8, 5,
          "Pies del POSTE DE APOYO, CANT. 2 (M4; issue #292)", "NOTE")

    # ---- front wall: lid front-lip screws | rear wall: I/O + transition taps ------
    for u in FRONT_SCREW_U:
        _circle(msp, u, -_fscrew_flat, 2.5)                            # front-lip screws: Ø2.5 M3
                                                                       # TAP PILOT (hand-tap M3; the
                                                                       # lid lip carries Ø3.4 clearance)
    io = rear_holes()                                                  # canonical; no mirror
    for c in io:
        c["v"] = BD + c["v"]                                           # rear z -> depth on the flap
    _emit(msp, io)
    for u in FRONT_SCREW_U:
        _circle(msp, u, BD + SEAM_TAP_V, 2.5)                          # lid-lap screws on the transition:
                                                                       # Ø2.5 M3 TAP PILOT (hand-tap, same
                                                                       # tool + screw as the front lip; taps
                                                                       # cut after paint so no masking; #760)
    for c in io:                                                       # bonding land: paint is an
        if c.get("ref") == "EARTH_STUD":                               # insulator, so the ring
            _mask_circle(msp, c["u"], c["v"], MASK_GND_D,               # terminal needs bare metal
                         "zona de puesta a tierra del perno M6, AMBAS CARAS")
    _text(msp, 8, BD+Hr+Ht+22, 7,
          "MASK (rojo trazo y punto) = máscara de pintura, NO ES UN CORTE: zona de metal "
          "desnudo para la puesta a tierra alrededor del perno M6, en AMBAS CARAS. Los "
          "agujeros piloto M3 se roscan DESPUÉS de pintar, así que no llevan máscara.", "MASK")

    _text(msp, 8, BD+Hr+Ht+10, 9,
          f"Segno CUERPO (segno_base)  chapa 2.0 mm  CANT. 1  piso + frente/trasera/laterales plegados hacia arriba (deducción {bdd:.2f}); SIN SOLDADURA: las 4 esquinas se remachan con ángulos internos; el 2do plegado de la trasera es la transición (pestaña de ANCHO COMPLETO, apoya sobre los laterales aliviados); PLEGAR con la cara DIBUJADA como CARA INTERIOR (espejado canónico: el encoder queda a la IZQUIERDA del músico)",
          "NOTE")
    doc.saveas(path); return {"blank": (BW + 2*h_x, BD + Hf + Hr + Ht)}

def dxf_corner_bracket(path, ht, wall_zs, side_zs, tag):
    """Internal L-bracket that joins a vertical corner WITHOUT welding: one leg pop-rivets to
    the rear wall, the other to the side wall. Folded 90 deg. Rivet holes MATCH the base corner
    holes exactly (CORNER_RO from the fold; staggered heights per leg so no two rivets meet)."""
    doc = _doc(); msp = doc.modelspace()
    LEG = CORNER_LEG
    _poly(msp, [(0, 0), (2*LEG, 0), (2*LEG, ht), (0, ht)], "CUT")
    _poly(msp, [(LEG, 0), (LEG, ht)], "BEND", closed=False)             # 90 deg fold between the legs
    for z in wall_zs:
        _circle(msp, LEG - CORNER_RO, z, D_M3)                          # rear-wall leg
    for z in side_zs:
        _circle(msp, LEG + CORNER_RO, z, D_M3)                          # side-wall leg
    _text(msp, 0, ht+6, 6, f"Segno ÁNGULO DE ESQUINA (segno_corner_bracket_rear, {tag})  chapa 2.0 mm  CANT. 2  unión de esquina sin soldadura; remachar a las dos paredes", "NOTE")
    doc.saveas(path); return {}

def platform_foot_u(sw):
    """The two x-fractions of the foot-flange screws, as offsets from the shelf centre."""
    return (-sw*0.25, sw*0.25)

def platform_foot_holes():
    """M3 clearance holes in the bottom plate, 4 per pedal, projected from each
    pedal onto the flat bottom. Since #719 the bolt passes UP through the plate,
    on through a clearance hole in the RING's floor, and threads into the SLED --
    one joint clamping ring + sled + plate. Positions are unchanged, which is why
    the sled arrived needing no sheet-metal work: it reads platform_foot_xy(),
    the same source the ring drills and the sled takes its inserts from."""
    cs = math.cos(math.radians(SLOPE_ANGLE))
    out = []
    for _label, u, v in PEDALS:
        vb = v * cs                                # pedal depth projected onto the flat bottom
        for fx, fy in platform_foot_xy():          # x = depth, y = width
            out.append({"kind": "circle", "u": u + fy, "v": vb + fx,
                        "d": D_M3, "ref": "PLAT_SCR"})
    return out

def dxf_rear_panel(path):
    """The dismountable rear I/O panel: a flat plate that closes the rear WINDOW with
    a bolt-on overlap and carries all nine connector stations. Same 2 mm sheet as the
    base, so it is one more part on the same cut+bend quote (it has no bends).

    Everything here is derived: the outline from the window, the window from the
    cutouts, the cutouts from rear_io_layout(). Move a station and the panel, the
    window and the wall's bolt pattern all follow."""
    doc = _doc(); msp = doc.modelspace()
    _u0, _z0, pw, ph = rear_panel_outline()
    _poly(msp, [(-pw/2, -ph/2), (pw/2, -ph/2), (pw/2, ph/2), (-pw/2, ph/2)], "CUT")
    _emit(msp, rear_panel_holes())
    _text(msp, -pw/2 + 4, ph/2 + 6, 6,
          "Segno PANEL TRASERO DE CONECTORES (segno_rear_panel)  chapa 2.0 mm  CANT. 1  "
          "PIEZA PLANA, sin plegados: alimentación 9V + apagado + fusible + 2 x DIN-5 + "
          "2 x TRS + 2 x USB3",
          "NOTE")
    doc.saveas(path); return {}

# screen_bracket REMOVED (#760): the screens are bonded to the shell; the
# bracket fallback was dropped entirely (user call 2026-08-18).

def dxf_post(path):
    """Base-anchored faceplate support post (issue #292), x2: a folded C -- foot
    (bolts to the base floor, M4 x2) + vertical web + top pad, foot and pad both
    forward of the web (all in the clear strip in front of the 16in aperture, nothing
    under the display). A felt cap on the pad bears on the faceplate underside,
    propping the one zone the perimeter folds do not reach. Load runs to the base, not
    the lid, so nothing shows on the top face and the lid still lifts off. The
    pad->web fold is 90 + POST_TILT deg so the pad beds FLUSH on the sloped underside;
    the foot->web fold is 90. Bend deduction PROVISIONAL (nominal segments)."""
    doc = _doc(); msp = doc.modelspace()
    pw, pad, web, foot = POST_PW, POST_PAD, POST_H, POST_FOOTL
    Wd = pad + web + foot
    _poly(msp, [(0, 0), (pw, 0), (pw, Wd), (0, Wd)], "CUT")
    _poly(msp, [(0, pad), (pw, pad)], "BEND", closed=False)           # pad -> web (fold 90 + tilt)
    _poly(msp, [(0, pad+web), (pw, pad+web)], "BEND", closed=False)   # web -> foot (fold 90)
    for du in (-POST_BOLT_DU, POST_BOLT_DU):                          # 2 M4 in the foot
        _circle(msp, pw/2.0 + du, pad + web + foot/2.0, D_M4)
    _text(msp, 5, Wd+6, 9,
          f"Segno POSTE DE APOYO DE LA TAPA (segno_post)  ACERO LAMINADO EN FRÍO de {POST_T:.1f} mm "
          f"(NO es el aluminio del gabinete)  CANT. 2  plegado en C (apoyo {pad:.0f} / alma {web:.0f} / "
          f"pie {foot:.0f} mm); plegado del apoyo {90+POST_TILT:.1f}° (asienta al ras sobre la pendiente "
          f"de {POST_TILT:.1f}°), plegado del pie 90°; el pie se abulona al piso del cuerpo (M4 x 2), "
          f"fieltro sobre el apoyo; deducción PROVISORIA", "NOTE")
    doc.saveas(path); return {}

# ===========================================================================
# STEP  (cadquery)
# ===========================================================================

def _cut(cq, plate, feats, mapxy):
    for c in feats:
        if c.get("layer", "CUT") not in ("CUT", "VENT"):
            continue
        if c["kind"] in ("circle", "ring"):
            d = c["d"] if c["kind"] == "circle" else c["od"]
            x, y = mapxy(c["u"], c["v"])
            cutter = cq.Workplane("XY").center(x, y).circle(d/2).extrude(3*T).translate((0,0,-T))
        elif c["kind"] == "rect":
            x, y = mapxy(c["u"] + c["w"]/2, c["v"] + c["h"]/2)
            cutter = cq.Workplane("XY").center(x, y).rect(c.get("_rx", c["w"]), c.get("_ry", c["h"])).extrude(3*T).translate((0,0,-T))
        else:
            continue
        plate = plate.cut(cutter)
    return plate

def _faceplate_flat(cq):
    fp = cq.Workplane("XY").box(FP_V, LID_W, T, centered=False)  # X=v, Y=u (full-width lid)
    cuts, _ = faceplate_holes()
    for c in cuts:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["h"], c["w"]
    return _cut(cq, fp, cuts, lambda u, v: (v, LID_OX + u))

def _rear_flat(cq):
    wall = cq.Workplane("XY").box(W-2*T, REAR_WALL_H, T, centered=False)  # X=u, Y=z
    feats = rear_holes()
    for c in feats:
        if c["kind"] == "rect":
            c["_rx"], c["_ry"] = c["w"], c["h"]
    return _cut(cq, wall, feats, lambda u, v: (u, v))

def _transition_face(cq):
    """The angled transition shoulder, located in the body: a flat facet from the peak
    line (X=FACE_RUN, Z=H_REAR) raked DOWN to the rear-panel top (X=D, Z=REAR_WALL_H).
    +TRANS_ANGLE so the +X (rearward) end DROPS (matches the side-panel profile)."""
    box = cq.Workplane("XY").box(TRANS_LEN, LID_W, T, centered=False)  # X along the facet (FULL width)
    loc = (cq.Location(cq.Vector(FACE_RUN, (W - LID_W) / 2.0, H_REAR))
           * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), TRANS_ANGLE))
    return box.val().moved(loc)

def base_foot_xy():
    """The four rubber-foot fixings, in bottom-plate (u, v) coordinates. ONE
    source: dxf_base() drills them and foot_relief_xy() asks which land under a
    pedestal."""
    BW, BD = W - 2*T, D - 2*T
    return [(x, y) for x in (FOOT_INSET_X, BW - FOOT_INSET_X)
            for y in (FOOT_INSET_Y, BD - FOOT_INSET_Y)]

def foot_relief_xy(v=None):
    """Foot fixings that land UNDER a pedestal, in the PEDESTAL frame (X = depth,
    Y = width) -- i.e. where the ring floor needs a clearance hole and the sled a
    pocket for the M4 head. Pass a row v for that row only; omit it for the union
    across every row, which is what the single sled part has to carry.

    The pedestal occurrence is rotated +90 deg about Z (local X -> world +v,
    local Y -> world -u), so a world offset (du, dv) maps to local (dv, -du)."""
    cs = math.cos(math.radians(SLOPE_ANGLE))
    out = set()
    for fu, fv in base_foot_xy():
        for _label, u, pv in PEDALS:
            if v is not None and pv != v:
                continue
            du, dv = fu - u, fv - pv*cs
            if abs(du) <= SKIRT_OUT_W/2.0 and abs(dv) <= SKIRT_OUT_D/2.0:
                out.add((round(dv, 3), round(-du, 3)))
    return sorted(out)

def platform_foot_xy():
    """The four chassis-screw stations, in the pedestal frame. ONE source: the
    ring drills clearance here, the sled takes its inserts here, and
    platform_foot_holes() punches the base plate here."""
    sd, sw = SKIRT_OUT_D, SKIRT_OUT_W
    # y-outer / x-inner deliberately: it reproduces the emission order
    # platform_foot_holes() had before it read from here, so the base-plate DXF
    # stays byte-identical and the diff shows what actually moved (nothing).
    return [(x, y) for y in platform_foot_u(sw)
            for x in (-(sd/2.0 - PLATFORM_FOOT/2.0), sd/2.0 - PLATFORM_FOOT/2.0)]

def pedal_console_sled(cq):
    """The 10-pedal console's sled (issue #719). Unlike the mini's it carries M3
    heat-set inserts on BOTH faces: the pedal bolts down into the top, and the
    four chassis screws come up from under the base plate -- through clearance
    holes in the ring's floor -- into the bottom. That is what clamps the ring
    down, so the ring itself needs no fastener and no hole of its own.

    One part for all ten: every pedestal shares the tub bore, and the row height
    is absorbed by the RING, not by this. Origin: pedal centre, z=0 at the sled's
    underside (which sits on the ring floor)."""
    sd = SKIRT_IN_D - 2*SLED_CLR
    sw = SKIRT_IN_W - 2*SLED_CLR
    s = (cq.Workplane("XY").box(sd, sw, CONSOLE_SLED_T, centered=(True, True, False))
         .edges("|Z").fillet(3.0)
         .faces("<Z").chamfer(SLED_BOT_CHAM))
    for hx, hy in pedal_base_holes():                 # pedal, from above
        s = s.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)
                  .extrude(-INSERT_DEPTH).translate((hx, hy, CONSOLE_SLED_T)))
    for fx, fy in platform_foot_xy():                 # chassis, from below
        s = s.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)
                  .extrude(INSERT_DEPTH).translate((fx, fy, 0)))
    # SLOPED TOP, toe end. The sled fills the tub BORE, which is SKIRT_SETBACK
    # larger than the slot's horizontal opening -- so its toe-side top corner ends
    # up UNDER the faceplate, and a 12.5 deg plate is at its lowest exactly there.
    # The ring's top already gets this cut; the sled needs it too, or it fouls the
    # plate (measured 9.3 mm3 front / 10.6 mm3 mid before this existed).
    # ONE plane serves both rows: the flush-at-rim rule (#373) fixes the pedal to
    # the plate identically, so the overshoot comes out 2.458 front / 2.473 mid --
    # cut to the tighter of the two and the other clears by 0.015.
    v_c = PEDAL_ROW1_V
    seat = platform_h(v_c) - T - (CONSOLE_SLED_T - (PEDAL_PAD_T - POCKET_DEPTH))
    zc = (lid_top_z(v_c) + SKIRT_DRIFT_ROW1 - 2*T - SKIRT_GAP) - seat   # plane at x=0, sled frame
    s = s.cut(cq.Workplane("XY").box(400.0, 400.0, 200.0, centered=(True, True, False))
              .rotate((0, 0, 0), (0, 1, 0), -SLOPE_ANGLE)
              .translate((0, 0, zc)))
    return s

def pedal_sled(cq):
    """The removable deck the pedal bolts to (issue #719). Flat plate, a slip fit
    in the tub bore, carrying four M3 heat-set inserts pressed from ABOVE -- the
    screw comes down through the pedal's base, so insert and screw share a side
    and the knurl works in the direction it is loaded.

    ONE retention insert goes in from BELOW, dead centre, for a screw driven up
    through the tub deck. Centre because the nearest pedal hole is 44.9 mm away
    and nothing crowds it; ONE because the tub walls already take rotation, and
    because two placed near the ends put a Ø4.5 bore 4.0 mm from the front pedal
    hole -- the bores overlapped.

    That same central bore is the extraction route: back the screw out, push a
    3 mm rod up it, and the sled lifts. The sled cannot carry a finger relief of
    its own -- the pedal overhangs it to within 0.9 mm per side, so any notch in
    its edge would be covered by the pedal.

    Origin: pedal centre, z=0 at the sled's underside. Same frame as
    pedal_base_holes()."""
    sd = SKIRT_IN_D - 2*SLED_CLR
    sw = SKIRT_IN_W - 2*SLED_CLR
    s = (cq.Workplane("XY").box(sd, sw, SLED_T, centered=(True, True, False))
         .edges("|Z").fillet(3.0)
         .faces("<Z").chamfer(SLED_BOT_CHAM))
    for hx, hy in pedal_base_holes():                 # pedal inserts, from above
        s = s.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)
                  .extrude(-INSERT_DEPTH).translate((hx, hy, SLED_T)))
    s = s.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)   # retention, from below
              .extrude(INSERT_DEPTH))
    return s

def _platform_printed(cq, ph, v_c, standalone=True, baffle_t=None, sled=False):
    """3D-printed pedal pedestal: solid deck + perimeter wall, hollowed below
    (tall MID parts) with boss columns at the insert stations. M3 heat-set
    inserts press in from BELOW at the base PLAT_SCR pattern; the deck top gets
    a shallow LOCATING POCKET for the Cherub's bottom anti-slip pad (the WTB-006
    has no base screws -- side screws only; retention PROVISIONAL), and a
    perimeter light-baffle SKIRT rises from the deck to SKIRT_GAP under the
    sloped faceplate (top cut at SLOPE_ANGLE; v_c = the pedal's slot centre in
    faceplate v, needed to height the skirt). Print BLACK. Origin: pedal
    centre, z=0 at the BASE PLATE TOP; height ph - T puts the deck at the
    pedal standing plane. Assembly frame: X = depth (v), Y = width (u); the
    pedal mounts TOE-FORWARD (back/cable end at +X)."""
    sw = SKIRT_OUT_W
    sd = SKIRT_OUT_D
    # A grown baffle ring takes the BODY with it. Sizing the ring alone left it
    # standing 0.75 mm proud of the pedestal face all round -- a lip, both a
    # down-facing ledge and simply wrong to look at (#539). Resolved here so
    # body, ring, notch and relief all read the same number.
    ring_od = sd if baffle_t is None else max(sd, SKIRT_IN_D + 2*baffle_t)
    sd = ring_od
    h = ph - T
    # SLED MODE (#719): the deck drops so the sled's top face lands where the
    # pad-on deck used to put the pedal's metal base. Nothing above the base
    # moves, so the faceplate, the slot and the flush-at-rim rule are untouched.
    # The ring is unchanged -- its top still follows the same sloped plane, it
    # just starts SLED_DECK_DROP lower and is that much taller.
    if sled:
        h -= sled - (PEDAL_PAD_T - POCKET_DEPTH)
    # cap the pilot depth in the LOW front pedestal (keeps a solid mid web and
    # clears the pad pocket above) and fit SHORT inserts (M3 x 3) instead of 5.7s
    pil = min(INSERT_DEPTH, (h - 1.0) / 2.0)
    body = cq.Workplane("XY").box(sd, sw, h, centered=(True, True, False))
    cav_h = h - PLAT_DECK
    foot_x = (-(sd/2 - PLATFORM_FOOT/2), sd/2 - PLATFORM_FOOT/2)
    # `standalone` = this pedestal is its own printed part, bolted to the base
    # plate from below. It then prints deck-down, so the weight-saving cavity
    # opens upward and costs nothing, and the base-insert pilots are reachable.
    # Built INTO the mini tray neither holds: the tray prints floor-down, which
    # turns the cavity into a 17,000 mm2 ceiling over a sealed void (nothing can
    # bridge it, and any support the slicer drops in is trapped forever), and
    # the pilots end up buried against the tray floor. Solid instead, and let
    # INFILL do the hollowing (#539).
    if standalone and cav_h > 2.0:
        body = body.cut(cq.Workplane("XY").box(
            sd - 2*PLAT_WALL, sw - 2*PLAT_WALL, cav_h, centered=(True, True, False)))
        for dx in foot_x:                      # boss columns for the base inserts
            for dy in platform_foot_u(sw):
                body = body.union(cq.Workplane("XY").cylinder(
                    cav_h, 6.0, centered=(True, True, False)).translate((dx, dy, 0)))
    if standalone and not sled:
        for dx in foot_x:                      # base inserts, from below
            for dy in platform_foot_u(sw):
                body = body.cut(cq.Workplane("XY").cylinder(
                    pil, INSERT_PILOT_D/2,
                    centered=(True, True, False)).translate((dx, dy, 0)))
    # bottom-pad locating pocket, from above. The pad is inset from the case
    # back edge, so its centre sits forward (toe-ward, -X) of the pedal centre:
    # pad centre from back = INSET + PAD_D/2; pedal centre from back = PEDAL_D/2.
    pocket_dx = (PEDAL_PAD_BACK_INSET + PEDAL_PAD_D/2.0) - PEDAL_D/2.0   # +X = rearward
    if sled:
        # no pad pocket: the pad is OFF and the SLED lands on this deck, flat.
        if standalone:
            # CONSOLE RING -- SANDWICHED. The four chassis screws pass straight
            # THROUGH this floor and thread into the sled above, so the one joint
            # clamps ring + sled + base plate. The ring therefore carries no
            # insert and no fastener of its own: clearance only.
            for dx in foot_x:
                for dy in platform_foot_u(sw):
                    body = body.cut(cq.Workplane("XY").circle(D_M3/2.0 + 0.25)
                                    .extrude(h + 1.0).translate((dx, dy, 0)))
        else:
            # MINI TUB -- part of the tray, so it needs no clamping of its own.
            # A single central retention bore instead; the caller cuts the head
            # pocket under the tray FLOOR, where it can be reached.
            body = body.cut(cq.Workplane("XY").circle(D_M3/2.0 + 0.15).extrude(h + 1.0))
    else:
        body = body.cut(cq.Workplane("XY").box(
            PEDAL_PAD_D + POCKET_CLR, PEDAL_PAD_W + POCKET_CLR, POCKET_DEPTH,
            centered=(True, True, False)).translate((-pocket_dx, 0, h - POCKET_DEPTH)))
    # light-baffle skirt: perimeter ring above the deck, top following the
    # sloped faceplate underside at SKIRT_GAP. Local +X = rearward = up-slope.
    # The ring's DEPTH walls are only (SKIRT_OUT_D - SKIRT_IN_D)/2 = 0.85 mm --
    # two beads, free-standing, ~28 mm tall. The inner face cannot move (it is
    # already only SKIRT_SETBACK behind the slot cut line), so a caller that
    # wants a printable baffle grows the ring OUTWARD instead; the 0.75 mm
    # ledge that leaves on the pedestal face is a trivial overhang. (#539)
    ring = (cq.Workplane("XY").box(ring_od, sw, 60.0, centered=(True, True, False))
            .cut(cq.Workplane("XY").box(SKIRT_IN_D, SKIRT_IN_W, 60.0,
                                        centered=(True, True, False)))
            .translate((0, 0, h)))
    drift = SKIRT_DRIFT_ROW1 if v_c < 150.0 else SKIRT_DRIFT_ROW2
    zc = lid_top_z(v_c) + drift - 2*T - SKIRT_GAP   # tub-top plane at x=0, local z (z0 = base top)
    cutter = (cq.Workplane("XY").box(400.0, 400.0, 200.0, centered=(True, True, False))
              .rotate((0, 0, 0), (0, 1, 0), -SLOPE_ANGLE)
              .translate((0, 0, zc)))
    ring = ring.cut(cutter)
    # boss drop-in channels: full-height vertical slots in BOTH side walls at the
    # screw axis, from the inner face out past the boss tip
    for side in (-1, 1):
        y0 = side * (SKIRT_IN_W/2 - 1.0)
        y1 = side * SKIRT_BOSS_CH_HALF
        ring = ring.cut(cq.Workplane("XY").box(
            SKIRT_BOSS_CH_W, abs(y1 - y0), 60.0,
            centered=(True, False, False)).translate(
                (SKIRT_BOSS_CH_X, min(y0, y1), h)))
    # cable notch: full-height slot centred in the REAR wall (+X = cable end).
    # Referenced to the RING's outer face, not to sd -- when baffle_t grows the
    # ring outward, a notch positioned off sd stops short and seals the slot
    # the pedal's cable leaves through (#539). The asserts below say so.
    NOTCH_L = 4.0
    notch_c = ring_od/2.0 - 1.5
    assert notch_c + NOTCH_L/2.0 >= ring_od/2.0 + 0.2, \
        "SKIRT: cable notch stops short of the ring's outer face -- slot sealed"
    assert notch_c - NOTCH_L/2.0 <= SKIRT_IN_D/2.0 - 0.2, \
        "SKIRT: cable notch does not reach the ring bore -- slot blind"
    ring = ring.cut(cq.Workplane("XY").box(
        NOTCH_L, SKIRT_NOTCH_W, 60.0,
        centered=(True, True, False)).translate((notch_c, 0, h)))
    body = body.union(ring)
    # PERIMETER RELIEF (#373): the tub footprint overhangs the slot opening
    # (1.25 mm front/rear, ~5.2 mm per side), so those strips lie UNDER the
    # faceplate (and under the down-turned front lip on row 1). With the
    # flush-raise the DECK BOX itself reaches that zone, so shave everything in
    # the perimeter region (outside the opening footprint) with the SAME
    # sloped plane the skirt cut uses -- which already sits ~0.3 under the
    # REAL plate (drift-calibrated per row). Deck inside the opening keeps
    # full height; the pedal (76.35 x 109.87) never sits on the shaved strips.
    opening_d = FSW_SLOT_D * math.cos(math.radians(SLOPE_ANGLE))
    ring_region = (cq.Workplane("XY").box(ring_od, sw, 200.0,
                                          centered=(True, True, False))
                   .cut(cq.Workplane("XY").box(opening_d, FSW_SLOT_W, 200.0,
                                               centered=(True, True, False))))
    body = body.cut(ring_region.intersect(cutter))
    return body

def build_platform_steps():
    """Printed pedestals, now RING + SLED (issue #719): rings FRONT x8 / MID x2,
    and ONE sled design x10. The pedal bolts to the sled on the bench -- it has
    to, because the shell's ~83 mm through-pin needs ~91 mm of clear axial run
    and the widest gap beside a seated pedal is 12.4 mm -- then sled and pedal
    drop into the ring as a unit and the four existing chassis screws clamp
    ring + sled + base plate together."""
    import cadquery as cq
    outp = []
    for tag, v in (("front", PEDAL_ROW1_V), ("mid", PEDAL_ROW2_V)):
        body = _platform_printed(cq, platform_h(v), v, sled=CONSOLE_SLED_T)
        base = os.path.join(OUT, f"segno_platform_{tag}_ring")
        cq.exporters.export(body.val(), base + ".step")
        cq.exporters.export(body, base + ".stl", tolerance=0.05)
        outp.append(base + ".step")
    sled = pedal_console_sled(cq)
    base = os.path.join(OUT, "segno_platform_sled")
    cq.exporters.export(sled.val(), base + ".step")
    cq.exporters.export(sled, base + ".stl", tolerance=0.05)
    outp.append(base + ".step")
    return outp

def build_mini_console():
    """Fully 3D-printable STANDALONE MINI CONSOLE (issue #362; evolved from the
    #360 fit-test): 2 Cherub WTB-006 pedals (TRACK3/TRACK4 geometry, verbatim
    console constants -- so it doubles as the metal-order fit test) in a
    closed, openable wedge enclosure with a Pro Micro bay -- a working
    2-switch USB desk unit.
      TRAY -- floor + four REAL walls (tops follow the faceplate underside,
      row-1 drift incl.), both pedestal TUBS integrated (pocket, boss
      channels, cable notches facing the rear board bay), a Pro Micro POCKET
      boss against the rear wall with a USB cutout through it, and two rear
      screw BOSSES (M3 heat-set, vertical) the lid closes onto.
      LID  -- prints FLAT: the faceplate section (2 pedal slots + 2 LED
      pills), four registration tabs, two rear M3 through-holes. Open/close =
      two screws; the tabs + slope keep it located.

    PRINTABILITY (#539 -- the first tray warped at the sides). This is a
    199 x 156 mm flat print, which survives only if it is anchored over its
    whole footprint. The first rev stood on four 14 x 14 feet, so it gripped
    the bed over 2.5% of what it spanned and the entire floor started 2 mm up
    in the air: every mm of contraction pulled on four pads and the free edges
    curled. So: no printed feet (rubber ones stick into shallow recesses), the
    floor is its own bed contact, and it is 3.2 mm of PRINTED floor rather than
    the 2.0 mm aluminium sheet gauge it used to borrow. Walls run into the
    pedestal tubs instead of standing free beside them, the plan corners are
    radiused, and the wall/floor junction carries a gusset.
    Frame: X = across the tray from its LEFT edge (symmetric about CX = Wt/2),
    Y = FLAT (projected) v, Z = world z."""
    import cadquery as cq
    cs = math.cos(math.radians(SLOPE_ANGLE))
    tn = math.tan(math.radians(SLOPE_ANGLE))
    # The tray is SYMMETRIC about its own centre-line. It used to inherit the
    # pedals' absolute console u and put its left edge at 0, which left the pair
    # sitting 1.74 mm right of centre: the right tub fused into its wall while
    # the left needed a filler block, and every hard-coded x -- anchors, feet,
    # ribs, lid tabs -- was then tuned around that offset. Only the PITCH has to
    # be faithful (it is what makes this a fit test), so keep the pitch and
    # centre the pair. Both tubs now fuse into their walls and the filler is gone.
    PITCH = _row1_u(7) - _row1_u(6)
    V1S = 160.0                      # depth on-slope (pedals + pills + board bay)
    D = V1S * cs
    # PRINTED wall/floor gauges -- deliberately NOT T (that is sheet metal)
    FLOOR_T  = 3.2      # 16 layers at 0.2: enough section to resist curl
    WALL_T   = 3.2
    CORNER_R = 6.0      # plan corner radius: square corners peel first
    BOT_CHAM = 0.6      # bottom edge: kills elephant foot and the lifting knife edge
    GUSSET   = 2.5      # 45deg ramp along the wall/floor junction
    FOOT_D, FOOT_REC = 12.0, 0.5      # stick-on rubber feet, located by a groove
    FOOT_RING_W = 1.2                 # groove width (a solid recess would be a
                                      # 12 mm flat ceiling -> slicer adds support)
    MINI_BAFFLE_T = 1.6               # 4 beads on the tub's light-baffle ring
    ZLIFT = FLOOR_T - T               # everything above the floor rises with it
    # BOTH walls overlap their tub by 0.5 so each fuses into one braced section
    # -- a bare +0.5 gap would leave a 0.5 mm slot the nozzle cannot resolve,
    # running 115 mm up a 44 mm wall. Symmetric, so the width follows from the
    # pitch rather than from one pedal's absolute u.
    TUB_FUSE = 0.5
    Wt = PITCH + SKIRT_OUT_W - 2*TUB_FUSE + 2*WALL_T
    CX = Wt/2.0                                  # THE centre-line; every x below
    PEDS = [CX - PITCH/2.0, CX + PITCH/2.0]      # is CX +/- something
    C0 = (lid_top_z(PEDAL_ROW1_V) + SKIRT_DRIFT_ROW1 - T) - tn * (PEDAL_ROW1_V * cs) + ZLIFT
    # under-base lid anchors: triangle clamp, nothing on top. The screws lean
    # REARWARD going down (they follow the lid normal), so each bottom exit
    # lands ~(pillar-top z)*tan(slope) behind the pillar -- the rear pair
    # therefore sits at y=139 in the side strips (clear of the diffuser flanges
    # and the board bay) so the exits stay in open floor instead of breaking
    # through the rear wall footprint. The apex sits ON the centre-line.
    ANCHOR_DX = CX - 8.5
    ANCHORS = ((CX - ANCHOR_DX, 139.0), (CX + ANCHOR_DX, 139.0), (CX, 20.0))
    BOARD_W, BOARD_D = 34.2, 18.8    # Pro Micro pocket (33 x 18 board + clearance)
    BOARD_XC = CX                    # centred between the tubs == centred in the tray

    def slope_cut(sol, z0):
        cutter = (cq.Workplane("XY").box(900.0, 900.0, 300.0, centered=(True, True, False))
                  .rotate((0, 0, 0), (1, 0, 0), SLOPE_ANGLE)
                  .translate((0, 0, z0)))
        return sol.cut(cutter)

    # --- tray -------------------------------------------------------------
    # ONE rounded-rect shell hollowed from above, not five unioned boxes: the
    # corners come out radiused (nothing for a peeling edge to start from) and
    # there are no coincident union faces for the slicer to trip over. The
    # cavity's own bottom edge is chamfered, so cutting it leaves a 45deg
    # gusset all the way round the wall/floor junction.
    shell = (cq.Workplane("XY").box(Wt, D, 80.0, centered=False)
             .edges("|Z").fillet(CORNER_R))
    shell = shell.faces("<Z").chamfer(BOT_CHAM)
    cav = (cq.Workplane("XY").box(Wt - 2*WALL_T, D - 2*WALL_T, 80.0, centered=False)
           .edges("|Z").fillet(max(0.6, CORNER_R - WALL_T)))
    cav = cav.faces("<Z").chamfer(GUSSET).translate((WALL_T, WALL_T, FLOOR_T))
    tray = slope_cut(shell, C0).cut(cav)
    # NO top-face fasteners (same language as the big console): the lid clamps
    # from BELOW. Anchor pillars stop LID_BOSS_H short of the wall-top plane;
    # the lid carries insert bosses that land on them, and M3 screws come up
    # through the floor along the LID NORMAL (12.5deg from vertical), heads
    # recessed in pockets that stay clear of the table on their own.
    LID_BOSS_H = 8.0   # boss deep enough that the insert pilot NEVER enters the
                       # 2mm plate (tilted pilot tip rim stays below it) -- the
                       # top face stays pristine
    ncs, nsn = math.cos(math.radians(SLOPE_ANGLE)), math.sin(math.radians(SLOPE_ANGLE))
    for (bx, byy) in ANCHORS:
        by = (D - WALL_T - 6.8) if byy is None else byy
        # VERTICAL screw (user call): the bore drops straight through pillar and
        # floor -- no drift, exit directly under the pillar, flat head seat.
        # The 12.5deg lives in the LID's insert pilot instead (pressed tilted).
        pillar = cq.Workplane("XY").box(10.0, 12.0, 60.0, centered=False)\
            .translate((bx - 5.0, by - 6.0, FLOOR_T))
        # vertical drop of the boss bottom = LID_BOSS_H / cos(slope), +0.2 so the
        # WALLS stay the seating datum and the screws preload across the gap
        pillar = slope_cut(pillar, C0 - (LID_BOSS_H / ncs + 0.2))
        tray = tray.union(pillar)
        # exit pocket sits concentric under the pillar: keep it whole in the floor
        exit_rim = by + 4.25
        assert exit_rim <= (D - WALL_T) - 0.8, \
            f"MINI_ANCHOR: exit pocket rim y{exit_rim:.1f} too close to the rear wall"
        bore = cq.Workplane("XY").circle(1.8).extrude(90.0).translate((bx, by, -5.0))
        # 8.5 head/driver pocket from below, seat 1.5 above the floor top: the
        # head ends up ~4.7 mm off the table, so nothing has to lift the case
        pocket = cq.Workplane("XY").circle(4.25).extrude(40.0)\
            .translate((bx, by, FLOOR_T + 1.5 - 40.0))
        tray = tray.cut(bore).cut(pocket)
    # FEET: not printed. Printed pads made the floor a 30,000 mm2 bridge over
    # 784 mm2 of bed contact -- the warp that killed the first tray (#539).
    # Stick-on rubber feet drop into these recesses instead, which a floor unit
    # wants anyway, and the floor itself is what grips the bed.
    # ...located by an engraved RING, not a solid recess. A recess is a flat
    # 12 mm ceiling 0.5 mm off the bed, which every slicer supports; the groove
    # only ever has to bridge its own 1.2 mm width.
    FOOT_DX_R = 62.5                   # rear pair, either side of the centre-line
    for (fx, fy) in ((15.0, 15.0), (Wt - 15.0, 15.0),
                     (CX - FOOT_DX_R, D - 14.0), (CX + FOOT_DX_R, D - 14.0)):
        tray = tray.cut(cq.Workplane("XY")
                        .circle(FOOT_D/2.0).circle(FOOT_D/2.0 - FOOT_RING_W)
                        .extrude(FOOT_REC).translate((fx, fy, 0.0)))
    yc = PEDAL_ROW1_V * cs
    for u in PEDS:
        ped = (_platform_printed(cq, platform_h(PEDAL_ROW1_V), PEDAL_ROW1_V,
                                 standalone=False, baffle_t=MINI_BAFFLE_T, sled=SLED_T)
               .rotate((0, 0, 0), (0, 0, 1), 90)
               .translate((u, yc, FLOOR_T)))
        tray = tray.union(ped)
        # SLED retention (#719): carry the pedestal's central bore on down
        # through the tray floor and seat the head UNDER it -- same idiom as the
        # lid anchors, so nothing has to lift the case off the table. Backing
        # this screw out and pushing a 3 mm rod up the same hole is also how the
        # sled comes back out; it has no finger relief of its own, because the
        # pedal overhangs its edge to within 0.9 mm.
        tray = tray.cut(cq.Workplane("XY").circle(D_M3/2.0 + 0.15)
                        .extrude(FLOOR_T + 6.0).translate((u, yc, -3.0)))
        tray = tray.cut(cq.Workplane("XY").circle(4.25).extrude(40.0)
                        .translate((u, yc, FLOOR_T + 1.5 - 40.0)))
    # BRACING. The tall thin side walls have to lean on something, and the bare
    # floor between and behind the tubs is where the warp map peaked.
    tub_x = [(u - SKIRT_OUT_W/2.0, u + SKIRT_OUT_W/2.0) for u in PEDS]
    tub_od = max(SKIRT_OUT_D, SKIRT_IN_D + 2*MINI_BAFFLE_T)   # body AND ring
    tub_y = (yc - tub_od/2.0, yc + tub_od/2.0)
    # Both walls fuse into their tub by TUB_FUSE, by construction -- so the
    # filler block the asymmetric layout needed on the LEFT (where the wall used
    # to stand in a 3 mm canyon) is gone, not merely skipped.
    for side, gap in (("left", tub_x[0][0] - WALL_T),
                      ("right", (Wt - WALL_T) - tub_x[1][1])):
        assert abs(gap + TUB_FUSE) < 1e-6, (
            f"MINI_SYM: {side} wall/tub overlap {-gap:.2f} != {TUB_FUSE:.2f} -- "
            "the walls no longer fuse symmetrically into the tubs")
    for ry in (35.0, 66.0, 108.0):         # ties the two tubs to each other
        # (clear of the centre anchor at y=20: its pillar spans y 14..26 and the
        # lid's boss drops onto the pillar TOP, not onto a rib)
        tray = tray.union(cq.Workplane("XY").box(
            tub_x[1][0] - tub_x[0][1] + 0.4, 5.0, 8.0, centered=False)
            .translate((tub_x[0][1] - 0.2, ry - 2.5, FLOOR_T)))
    RIB_DX = (27.0, 67.0)                  # stiffens the open rear bay, mirrored
    for rx in [CX + s*d for d in RIB_DX for s in (-1, 1)]:
        # (kept off the Pro Micro boss, which straddles CX: a rib landing just
        # beside it leaves a 0.8 mm slot the nozzle cannot resolve -- the assert
        # after this loop is what actually holds that, not the chosen numbers)
        tray = tray.union(cq.Workplane("XY").box(
            4.0, (D - WALL_T) - tub_y[1] + 0.4, 8.0, centered=False)
            .translate((rx - 2.0, tub_y[1] - 0.2, FLOOR_T)))
    # the rib-to-boss slot that the old hand-picked x values were guarding by
    # eye. Stated once, checked once.
    boss_half = BOARD_W/2.0 + 4.0
    for d in RIB_DX:
        slot = d - 2.0 - boss_half
        assert slot < -2.0 or slot > 0.8, (
            f"MINI_RIB: rib at CX+/-{d:.1f} leaves a {slot:.2f} mm slot beside "
            "the Pro Micro boss -- the nozzle cannot resolve it")
    # Pro Micro bay: raised boss against the rear wall, open-top pocket, and a
    # USB cutout through the rear wall (board slides in from above; the USB
    # lead + pocket friction retain it -- PROVISIONAL, fine for the mini)
    boss = cq.Workplane("XY").box(BOARD_W + 8.0, BOARD_D + 4.0, 4.0, centered=False)\
        .translate((BOARD_XC - BOARD_W/2.0 - 4.0, D - WALL_T - BOARD_D - 4.0, FLOOR_T))
    pocket = cq.Workplane("XY").box(BOARD_W, BOARD_D, 3.0, centered=False)\
        .translate((BOARD_XC - BOARD_W/2.0, D - WALL_T - BOARD_D, FLOOR_T + 1.8))
    tray = tray.union(boss).cut(pocket)
    # USB pass-through, with a 45deg GABLE over it. A plain rectangle leaves a
    # 12 mm flat ceiling inside the wall -- bridgeable, but slicers support it.
    usb_w, usb_h, usb_x0 = 12.0, 5.0, BOARD_XC - 6.0
    usb_y0, usb_z0 = D - WALL_T - 1.0, FLOOR_T + 2.6
    usb_t = WALL_T + 2.0
    usb = cq.Workplane("XY").box(usb_w, usb_t, usb_h, centered=False)\
        .translate((usb_x0, usb_y0, usb_z0))
    # 50 deg flanks (margin over the 45 deg self-supporting limit) narrowing to
    # a 4 mm flat -- the extruder never reaches more than 4 mm unsupported, and
    # the opening stays short instead of growing a full gable's worth of height
    roof_top, roof_a = 4.0, 50.0
    roof_rise = (usb_w - roof_top)/2.0 * math.tan(math.radians(roof_a))
    roof = (cq.Workplane("XZ")
            .polyline([(usb_x0, usb_z0 + usb_h),
                       (usb_x0 + usb_w, usb_z0 + usb_h),
                       (usb_x0 + (usb_w + roof_top)/2.0, usb_z0 + usb_h + roof_rise),
                       (usb_x0 + (usb_w - roof_top)/2.0, usb_z0 + usb_h + roof_rise)])
            .close().extrude(usb_t))
    bb = roof.val().BoundingBox()
    roof = roof.translate((0, usb_y0 - bb.ymin, 0))   # land it in the rear wall
    tray = tray.cut(usb).cut(roof)

    # --- lid (prints FLAT; seats on the wall tops at the real slope) ------
    # Built LONGER than V1S by T*tan(slope): raked over, a square-cut rear edge
    # leaves the lid's top face T*sin short of the rear wall. The extra is
    # trimmed off plumb below, so the top face lands exactly on the wall.
    LID_RAKE = T * tn
    lid = cq.Workplane("XY").box(Wt, V1S + LID_RAKE, T, centered=False)
    for u in PEDS:
        x = u
        lid = lid.cut(cq.Workplane("XY").box(FSW_SLOT_W, FSW_SLOT_D, 3*T, centered=(True, True, False))
                      .translate((x, PEDAL_ROW1_V, -T)))
        vc = PEDAL_ROW1_V + FSW_SLOT_D/2 + LED_GAP
        lid = lid.cut(cq.Workplane("XY").slot2D(LED_SLOT_W, LED_SLOT_H).extrude(3*T)
                      .translate((x, vc, -T)))
    # insert bosses on the UNDERSIDE over each anchor pillar: take the M3
    # heat-set inserts the under-base screws thread into. Nothing on top.
    sn = math.sin(math.radians(SLOPE_ANGLE))
    for (bx, byy) in ANCHORS:
        by = (D - WALL_T - 6.8) if byy is None else byy
        # pilot axis VERTICAL in the assembled (tilted) state -> drilled at
        # SLOPE_ANGLE in the flat print, leaning rearward (+y_l) going up.
        # Entry point on the boss bottom chosen so the assembled axis passes
        # through (bx, by): y_l = (by - LID_BOSS_H*sin)/cos.
        y_pl = (by - LID_BOSS_H * sn) / cs
        lid = lid.union(cq.Workplane("XY").box(10.0, 10.0, LID_BOSS_H, centered=False)
                        .translate((bx - 5.0, y_pl - 4.25, -LID_BOSS_H)))
        # start the cutter 2mm BELOW the boss face: a tilted cylinder starting
        # AT the face leaves its tilted base disc proud on the forward side --
        # a wedge half-covering the mouth (the user's "half-hole")
        lid = lid.cut(cq.Workplane("XY").circle(INSERT_PILOT_D/2.0)
                      .extrude(INSERT_DEPTH + 0.4 + 2.0)
                      .rotate((0, 0, 0), (1, 0, 0), -SLOPE_ANGLE)
                      .translate((bx, y_pl - 2.0*sn, -LID_BOSS_H - 2.0*cs)))
    # registration tabs (pure locators; the anchors do the clamping).
    # FRONT pair: shallow, inside the y<8.5 strip before the tub front walls.
    # FRONT pair: they live in the strip between the front wall and the tub, and
    # that strip is now 4.56 mm wide (the baffle ring took the tub face out to
    # y=7.76). A tab hangs BELOW the lid plane, and the lid is tilted, so its
    # bottom edge lands tan(slope) further REARWARD than its top -- 5 mm of tab
    # walked 1.08 mm into the tub. Sized against the swept envelope, not the
    # footprint, with the two asserts spelling the strip out.
    FT_D, FT_H = 2.8, 3.0
    ft_y = (WALL_T + 0.3) / cs
    assert ft_y * cs >= WALL_T + 0.25, \
        "MINI_TAB: front tab overhangs the front wall top"
    assert (ft_y + FT_D) * cs + FT_H * sn <= tub_y[0] - 0.4, \
        "MINI_TAB: front tab sweeps into the pedestal tub"
    for tx in (CX - 62.5, CX + 62.5):
        lid = lid.union(cq.Workplane("XY").box(10.0, FT_D, FT_H, centered=False)
                        .translate((tx - 5.0, ft_y, -FT_H)))
    for tx in (CX - 54.0, CX + 54.0):
        lid = lid.union(cq.Workplane("XY").box(10.0, 10.0, 5.0, centered=False)
                        .translate((tx - 5.0, (D - WALL_T)/cs - 12.0, -5.0)))

    # FLUSH OUTLINE. The lid is a flat plate seated at 12.5 deg, so square-cut
    # edges left its top face T*sin = 0.43 PROUD of the front wall and 0.43 SHY
    # of the rear one, while its square plan corners overhung the tray's R6
    # fillets by 6 - 6/sqrt(2) = 1.76. Both had been there since the first tray.
    #
    # Fixed in ONE exact operation rather than two computed bevels: in the
    # SEATED frame, intersect the lid with a VERTICAL prism of the tray's own
    # plan outline. Front and rear come out plumb, the corners come out on the
    # tray's radius at EVERY height (a fillet applied in the flat frame would
    # rake over and only approximate it), and no bevel angle is computed
    # anywhere -- the tray's outline is the definition.
    def _seat(s):
        return s.rotate((0, 0, 0), (1, 0, 0), SLOPE_ANGLE).translate((0, 0, C0))

    def _unseat(s):
        return s.translate((0, 0, -C0)).rotate((0, 0, 0), (1, 0, 0), -SLOPE_ANGLE)

    outline = (cq.Workplane("XY").box(Wt, D, 400.0, centered=False)
               .edges("|Z").fillet(CORNER_R).translate((0, 0, -100.0)))
    lid = _unseat(_seat(lid).intersect(outline))
    lb = _seat(lid).val().BoundingBox()
    assert abs(lb.xmin) < 1e-6 and abs(lb.xmax - Wt) < 1e-6 \
        and abs(lb.ymin) < 1e-6 and abs(lb.ymax - D) < 1e-6, (
        f"MINI_FLUSH: seated lid {lb.xmin:.3f}..{lb.xmax:.3f} x "
        f"{lb.ymin:.3f}..{lb.ymax:.3f} does not sit inside the tray outline "
        f"0..{Wt:.3f} x 0..{D:.3f}")

    # SYMMETRY GATE. Enumerating the hard-coded x values and mirroring them by
    # hand is exactly how the asymmetry got in -- it only takes one nobody
    # re-derived -- so ask the SOLID instead.
    #
    # NOT by cutting the solid against its own mirror: when the part IS
    # symmetric the two are geometrically identical, every face is coincident,
    # and OCC's boolean returns EMPTY. That reads as "totally asymmetric" and is
    # the exact opposite of the truth. (Confirmed four ways: Shape.mirror,
    # reversed, gp_Trsf, and reversed gp_Trsf all return 0.)
    #
    # Instead split at x = CX -- axis-aligned half-space booleans are well
    # behaved -- and compare the two halves by MASS PROPERTIES, which needs no
    # boolean between them. A mirror about CX negates (x - CX), so a symmetric
    # part has equal volumes, centroids that are equal and opposite in x and
    # equal in y/z, and an inertia tensor whose Ixy/Ixz flip sign while the
    # rest match.
    from OCP.BRepGProp import BRepGProp
    from OCP.GProp import GProp_GProps

    def _props(shape):
        g = GProp_GProps()
        BRepGProp.VolumeProperties_s(shape.wrapped, g)
        c, m = g.CentreOfMass(), g.MatrixOfInertia()
        return (g.Mass(), (c.X(), c.Y(), c.Z()),
                tuple(m.Value(i, j) for i in (1, 2, 3) for j in (1, 2, 3)))

    BIG = 1000.0
    for tag, sol in (("tray", tray), ("lid", lid)):
        halves = []
        for s in (-1, 1):
            hs = (cq.Workplane("XY").box(BIG, BIG, BIG, centered=True)
                  .translate((CX + s*BIG/2.0, 0, 0)))
            halves.append(_props(sol.val().intersect(hs.val())))
        (vl, cl, il), (vr, cr, ir) = halves
        assert abs(vl - vr) < 1.0, (
            f"MINI_SYM: {tag} halves differ by {vl - vr:+.1f} mm3 about x={CX:.2f} "
            "-- some feature is still placed off an absolute x")
        assert abs((CX - cl[0]) - (cr[0] - CX)) < 0.01 and \
               abs(cl[1] - cr[1]) < 0.01 and abs(cl[2] - cr[2]) < 0.01, (
            f"MINI_SYM: {tag} half-centroids are not mirror images: "
            f"left {cl} right {cr} about x={CX:.2f}")
        # inertia: index 1 = Ixy and 2 = Ixz in row-major 3x3, both flip sign
        for k, (a, b) in enumerate(zip(il, ir)):
            want = -b if k in (1, 2, 3, 6) else b
            assert abs(a - want) < max(1.0, abs(b)*1e-6), (
                f"MINI_SYM: {tag} half-inertia component {k} differs "
                f"({a:.1f} vs expected {want:.1f}) -- the halves are not mirrors")

    # ASSEMBLY GATE. Three separate clashes got into this part by moving tray
    # geometry without re-checking what the lid drops into it (#539): the left
    # filler under the rear anchor bosses, a centre rib under the middle one,
    # and the front tabs after the tub grew. Cheap to just ask.
    seated = lid.rotate((0, 0, 0), (1, 0, 0), SLOPE_ANGLE).translate((0, 0, C0))
    clash = tray.val().intersect(seated.val())
    clash_v = clash.Volume() if clash is not None else 0.0
    assert clash_v < 0.5, (
        f"MINI_FIT: tray and lid overlap by {clash_v:.1f} mm3 -- "
        + "; ".join(f"{c.Volume():.1f}mm3 near "
                    f"x{c.BoundingBox().xmin:.0f} y{c.BoundingBox().ymin:.0f} "
                    f"z{c.BoundingBox().zmin:.0f}" for c in clash.Solids()))

    # EVERY per-part file ships in PRINT orientation -- STEP and STL alike.
    # Shipping the STL flipped and the STEP in the assembly frame was a trap:
    # slicers import STEP, and the lid sliced from its assembly frame stands on
    # the tips of seven bosses with the whole 12,400 mm2 faceplate floating
    # 8 mm up (#539). The assembled relationship lives in ONE file instead,
    # which is more use than two parts that happen to share a frame.
    lid_print = lid.rotate((0, 0, 0), (1, 0, 0), 180)
    bb = lid_print.val().BoundingBox()
    lid_print = lid_print.translate((0, -bb.ymin, -bb.zmin))

    # SLED GATE (#719). The sled has to clear the tub bore it drops into, and it
    # has to put the pedal's metal base back exactly where the pad-on deck did --
    # that equality is the whole reason the faceplate above did not have to move.
    sled = pedal_sled(cq)
    sbb = sled.val().BoundingBox()
    assert SKIRT_IN_D - (sbb.xmax - sbb.xmin) >= 2*SLED_CLR - 1e-6 and \
           SKIRT_IN_W - (sbb.ymax - sbb.ymin) >= 2*SLED_CLR - 1e-6, \
        "MINI_SLED: sled fouls the tub bore"
    deck_pad_on = FLOOR_T + (platform_h(PEDAL_ROW1_V) - T)
    base_pad_on = deck_pad_on + PEDAL_PAD_T - POCKET_DEPTH
    base_sled = (deck_pad_on - SLED_DECK_DROP) + SLED_T
    assert abs(base_sled - base_pad_on) < 1e-6, (
        f"MINI_SLED: metal base moved {base_sled - base_pad_on:+.3f} mm -- the "
        "faceplate, the slot and the flush-at-rim rule all assume it did not")
    # the four pedal inserts must not break out of the sled's underside, and the
    # central retention insert must not run into them
    assert INSERT_DEPTH <= SLED_T - 0.8, "MINI_SLED: pedal inserts break through"
    # the bore fit is the ONLY thing locating the pedal, so it has a floor and a
    # ceiling: too loose and the pedal wanders, too tight and a printed sled will
    # not drop into a printed bore at all
    assert 0.1 <= SLED_CLR <= 0.4, (
        f"MINI_SLED: {SLED_CLR:.2f} mm/side is outside the printable locating "
        "band -- below 0.1 a printed pair will not assemble, above 0.4 it wiggles")
    assert SLED_BOT_CHAM < SLED_T - INSERT_DEPTH + 0.5, \
        "MINI_SLED: bottom chamfer eats the floor under the pedal inserts"
    # A thicker sled is legal -- the deck drop compensates and the base stays put
    # -- right up until the deck it stands on is too thin to be a deck. The
    # retention screw pulls through this section, and it also has to bridge the
    # head pocket beneath it.
    tub_deck = platform_h(PEDAL_ROW1_V) - T - SLED_DECK_DROP
    assert tub_deck >= 5.0, (
        f"MINI_SLED: sled {SLED_T:.1f} leaves only {tub_deck:.1f} mm of tub deck "
        "under it -- too little to carry the retention screw")
    assert min(math.hypot(hx, hy) for hx, hy in pedal_base_holes()) \
        >= INSERT_PILOT_D + 1.0, "MINI_SLED: retention insert crowds a pedal insert"
    # ...and the real question, which bounding boxes cannot answer: does the sled
    # actually DROP IN? Seat one at each tub and intersect with the finished
    # tray -- ribs, fillets, the cable notch and the boss channels all included.
    sled_z = FLOOR_T + (platform_h(PEDAL_ROW1_V) - T - SLED_DECK_DROP)
    for u in PEDS:
        seat = (sled.rotate((0, 0, 0), (0, 0, 1), 90)
                    .translate((u, yc, sled_z)))
        c = tray.val().intersect(seat.val())
        cv = sum(s.Volume() for s in c.Solids()) if c is not None else 0.0
        assert cv < 0.5, (
            f"MINI_SLED: sled fouls the tray by {cv:.1f} mm3 at u={u:.1f} "
            "-- it cannot be dropped in, which is the one thing it exists to do")

    outp = []
    for tag, sol in (("tray", tray), ("lid", lid_print), ("sled", sled)):
        base = os.path.join(OUT, f"segno_mini_console_{tag}")
        cq.exporters.export(sol.val(), base + ".step")
        cq.exporters.export(sol, base + ".stl", tolerance=0.05)
        bb = sol.val().BoundingBox()
        print(f"Mini console {tag}: {base}.step/.stl  footprint "
              f"{bb.xmax-bb.xmin:.1f} x {bb.ymax-bb.ymin:.1f} x {bb.zmax-bb.zmin:.1f} mm"
              f"  (as printed: lay it down exactly as the file sits)")
        outp.append(base + ".step")

    # ...and the assembly, lid seated on the wall tops at the real slope: a
    # point (x, y_l, 0) on the lid maps to z = C0 + y_l*sin(slope), which is
    # the wall-top plane z = C0 + tan(slope)*y at y = y_l*cos(slope).
    asm = os.path.join(OUT, "segno_mini_console_assembly.step")
    cq.exporters.export(
        cq.Compound.makeCompound([tray.val(), seated.val()]), asm)
    print(f"Mini console assembly (CAD reference, NOT for slicing): {asm}")
    outp.append(asm)
    return outp

def build_diffuser_step():
    """LED pill diffuser INSERT (3D-print in WHITE PLA, x6 per console):
    a stadium lens that pushes into the faceplate slot FROM THE INSIDE until its
    shoulder flange seats on the sheet's underside; the lens stands LED_INS_PROUD
    above the outer skin. The single-LED module (hardware/led_strip/ puck or an
    off-the-shelf WS2812B breakout) nests in a shallow pocket on the back and is
    VHB-taped over the flange, which also retains the insert."""
    import cadquery as cq
    lens_l = LED_SLOT_W - LED_INS_CLR
    lens_w = LED_SLOT_H - LED_INS_CLR
    lens_h = T + LED_INS_PROUD
    fl_l = LED_SLOT_W + 2 * LED_INS_FLANGE
    fl_w = LED_SLOT_H + 2 * LED_INS_FLANGE
    lens = cq.Workplane("XY").slot2D(lens_l, lens_w).extrude(lens_h)
    lens = lens.edges(">Z").chamfer(0.3)             # soft glow edge on the proud lip
    ins = lens.union(cq.Workplane("XY").slot2D(fl_l, fl_w).extrude(-LED_INS_FL_T))
    px, py, pd = LED_INS_POCKET                       # LED nest, back face
    ins = ins.cut(cq.Workplane("XY").workplane(offset=-LED_INS_FL_T)
                  .rect(px, py).extrude(pd))
    step = os.path.join(OUT, "segno_led_diffuser.step")
    stl = os.path.join(OUT, "segno_led_diffuser.stl")
    cq.exporters.export(ins.val(), step)
    cq.exporters.export(ins.val(), stl)
    return step


# --- pedal name tiles (#795, trapezoid #922) ---------------------------------
# The WTB-006's top pad has a window through it, and the pad is a uniform 2.2
# slab lying on a case top tilted to match -- so the window is a parallel-sided
# 2.2 deep pocket and a FLAT tile fits it (flat in Z; see the plan taper below).
# The tile FILLS the window: at 0.25/side the pedal's own case colour showed
# through the gap around it. 0.05/side is below what FDM resolves, so this is a
# press fit into a compliant rubber window -- which also retains it.
#
# THE TILE IS A TRAPEZOID, NOT A RECTANGLE (#922). The owner rule is 5 mm of pad
# each side, ALWAYS -- and the WTB-006 is a wedge IN PLAN as well as in height,
# so a constant width can only be right at one station along the length. The
# tile's sides run PARALLEL TO THE PAD'S SIDES: wide edge toward the case BACK
# (cable end), narrow edge toward the TOE. That is also the reading direction --
# the top of the glyphs points at the wide edge -- so the tile cannot be fitted
# the wrong way round without the label reading upside down.
TILE_WALL   = 5.0     # pad left each side of the window. OWNER RULE, and the
                      # thing the width is DERIVED from. The old 54.45 was a
                      # transcribed constant: it satisfied this rule at ONE
                      # station and was wrong at every other.
# Top-pad width at the window's two ends, MEASURED off the `Top Pad` body in the
# "Cherub WTB-006 Footswitch" Fusion doc (its PAD_WINDOW sketch carries the pad's
# own side edges, so the taper comes from the part, not from the case). The pad
# runs 64.55 at its widest -- that is the number the owner confirmed, and it is
# the pad's BACK EDGE, not the window's station.
TILE_PAD_W_BACK = 64.459   # at the window's back (cable-end) edge
TILE_PAD_W_TOE  = 63.855   # at the window's toe edge -- the pad is a wedge in plan
TILE_WIN_W  = 20.00   # window length along the pedal
TILE_CLR    = 0.05    # per side, all four sides
TILE_WIN_L_BACK = TILE_PAD_W_BACK - 2*TILE_WALL          # 54.459
TILE_WIN_L_TOE  = TILE_PAD_W_TOE  - 2*TILE_WALL          # 53.855
TILE_W      = TILE_WIN_W - 2*TILE_CLR                    # 19.90, along the pedal
TILE_L_BACK = TILE_WIN_L_BACK - 2*TILE_CLR               # 54.359, wide edge
TILE_L_TOE  = TILE_WIN_L_TOE  - 2*TILE_CLR               # 53.755, narrow edge
TILE_BODY_T = 1.8     # black body
TILE_TEXT_T = 0.4     # white glyph layer; 1.8 + 0.4 = the 2.2 pocket, so the
                      # LETTERS finish flush with the pad and the black field
                      # sits 0.4 below it, out of the scuff line
TILE_MARGIN = 6.0     # clear tile around the glyph block
TILE_FONT   = "Helvetica Neue Light"  # THIN-looking but printable. At the tile's
                      # 7.9 mm glyph height, Helvetica Neue *Thin* measures 0.39 mm
                      # of stroke -- under a 0.4 nozzle, so a slicer drops or gaps
                      # it. Light holds 0.61. The two asks (thinner AND smaller)
                      # collide at the nozzle; this is where they meet. Measured,
                      # not guessed -- see the stroke check when regenerating.
TILE_SYM_H  = 14.0    # symbol em: play triangle 0.82*h = 11.5 tall

# What each pedal's tile SAYS. The track pedals carry only their number -- the
# word is redundant next to three identical neighbours, and a lone digit can be
# set far larger in the same window.
TILE_TEXT = {"TRACK1": "1", "TRACK2": "2", "TRACK3": "3", "TRACK4": "4"}

# 2-ply engraved plastic (#946). 2.0 mm is the closest standard stock to the
# 2.2 mm pad pocket; the tile sits 0.2 mm recessed. Black cap / white core:
# ENGRAVE burns the cap and the glyph reads white. The plan is the same
# trapezoid as the 3D tiles -- only the process changes.
TILE_PLY_T     = 2.0
TILE_NEST_GAP  = 4.0
TILE_NEST_COLS = 5


def _tile_stem(label):
    return "segno_pedal_tile_" + label.replace("/", "_")


def _tile_outline():
    """Trapezoid in the tile frame: +Y is the wide (cable-end) edge."""
    return [(-TILE_L_BACK / 2.0,  TILE_W / 2.0),
            ( TILE_L_BACK / 2.0,  TILE_W / 2.0),
            ( TILE_L_TOE  / 2.0, -TILE_W / 2.0),
            (-TILE_L_TOE  / 2.0, -TILE_W / 2.0)]


def _tile_font_props(size):
    """Helvetica Neue Light -- the same face TILE_FONT names for CadQuery.

    matplotlib finds it as family + weight, not as the PostScript face name.
    The path is gated so a machine without the font cannot silently ship
    DejaVu outlines to the shop.
    """
    from matplotlib.font_manager import FontProperties, findfont
    fp = FontProperties(family="Helvetica Neue", weight="light", size=size)
    path = findfont(fp)
    assert "helveticaneue" in os.path.basename(path).lower().replace(" ", ""), (
        f"tile font resolved to {path}, not Helvetica Neue Light")
    return fp


def _signed_area(pts):
    a = 0.0
    n = len(pts)
    for i in range(n):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % n]
        a += x0 * y1 - x1 * y0
    return a / 2.0


def _point_in_poly(x, y, pts):
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi + 0.0) + xi):
            inside = not inside
        j = i
    return inside


def _clean_ring(pts):
    ring = [(float(x), float(y)) for x, y in pts]
    if len(ring) >= 2 and ring[0] == ring[-1]:
        ring = ring[:-1]
    return ring if len(ring) >= 3 else None


def _group_outers_and_holes(polys):
    """Pair each outer contour with the holes that sit inside it.

    matplotlib TextPath emits one polygon per contour; Helvetica Neue Light
    winds outers clockwise (negative area) and counters the other way.
    """
    rings = [r for r in (_clean_ring(p) for p in polys) if r]
    outers = [r for r in rings if _signed_area(r) < 0]
    holes = [r for r in rings if _signed_area(r) > 0]
    if not outers:
        return [(r, []) for r in rings]
    groups = []
    used = set()
    for outer in outers:
        own = []
        for i, hole in enumerate(holes):
            if i in used:
                continue
            cx = sum(p[0] for p in hole) / len(hole)
            cy = sum(p[1] for p in hole) / len(hole)
            if _point_in_poly(cx, cy, outer):
                own.append(hole)
                used.add(i)
        groups.append((outer, own))
    return groups


def _text_glyph_groups(txt, em):
    from matplotlib.textpath import TextPath
    path = TextPath((0.0, 0.0), txt, prop=_tile_font_props(em), size=em)
    return _group_outers_and_holes(path.to_polygons())


def _ink_bbox(glyphs):
    xs, ys = [], []
    for e in glyphs:
        if e["kind"] == "disc":
            xs += [e["u"] - e["d"] / 2.0, e["u"] + e["d"] / 2.0]
            ys += [e["v"] - e["d"] / 2.0, e["v"] + e["d"] / 2.0]
        else:
            for p in e["pts"]:
                xs.append(p[0]); ys.append(p[1])
            for hole in e.get("holes") or []:
                for p in hole:
                    xs.append(p[0]); ys.append(p[1])
    return min(xs), min(ys), max(xs), max(ys)


def _translate_glyphs(glyphs, dx, dy):
    out = []
    for e in glyphs:
        e = dict(e)
        if e["kind"] == "disc":
            e["u"] += dx
            e["v"] += dy
        else:
            e["pts"] = [(x + dx, y + dy) for x, y in e["pts"]]
            e["holes"] = [[(x + dx, y + dy) for x, y in h]
                          for h in e.get("holes") or []]
        out.append(e)
    return out


def _tile_ink(label):
    """Fitted, centred ink for one tile -- the 2-ply ENGRAVE source (#946).

    Symbols come from `_silk_symbol_geometry` (same as the faceplate and the
    3D tiles). Words are Helvetica Neue Light outlines, never TEXT entities:
    a shop font substitution would change the stroke that already sits at
    0.61 mm. Auto-fit and ink-centre match `build_pedal_name_tiles`.
    """
    fit_l = TILE_L_TOE - 2 * TILE_MARGIN
    fit_w = TILE_W - 2 * TILE_MARGIN
    if label in SILK_SYMBOLS:
        probe = _silk_symbol_geometry(SILK_SYMBOLS[label], 0.0, 0.0, 10.0)
        xmin, ymin, xmax, ymax = _ink_bbox(probe)
        h = 10.0 * min(fit_l / (xmax - xmin), fit_w / (ymax - ymin))
        glyphs = _silk_symbol_geometry(SILK_SYMBOLS[label], 0.0, 0.0, h)
    else:
        txt = TILE_TEXT.get(label, label)
        probe = [{"kind": "poly", "pts": o, "holes": hs}
                 for o, hs in _text_glyph_groups(txt, 10.0)]
        xmin, ymin, xmax, ymax = _ink_bbox(probe)
        em = 10.0 * min(fit_l / (xmax - xmin), fit_w / (ymax - ymin))
        glyphs = [{"kind": "poly", "pts": o, "holes": hs}
                  for o, hs in _text_glyph_groups(txt, em)]
    xmin, ymin, xmax, ymax = _ink_bbox(glyphs)
    glyphs = _translate_glyphs(glyphs, -(xmin + xmax) / 2.0, -(ymin + ymax) / 2.0)
    xmin, ymin, xmax, ymax = _ink_bbox(glyphs)
    avail = tile_width_at(ymin)
    assert (xmax - xmin) <= avail + 1e-6 and (ymax - ymin) <= TILE_W + 1e-6, (
        f"pedal tile {label!r}: glyph {xmax - xmin:.2f} x {ymax - ymin:.2f} overflows "
        f"the {avail:.2f} available at y={ymin:.2f} on the "
        f"{TILE_L_TOE:.2f}(toe)/{TILE_L_BACK:.2f}(back) x {TILE_W} tile")
    return glyphs, (xmin, ymin, xmax, ymax)


def tile_width_at(y):
    """Tile width at station y, with +Y toward the case BACK (the wide edge).
    The sides are straight, so this is a plain interpolation between the toe and
    back widths -- and it is what anything laid on the tile must clear."""
    return ((TILE_L_BACK + TILE_L_TOE) / 2.0
            + (TILE_L_BACK - TILE_L_TOE) * (y / TILE_W))


def build_pedal_name_tiles():
    """One drop-in name tile per pedal, for the pad window.

    PRINT FACE-DOWN with a filament change at z = TILE_TEXT_T. The glyphs stand
    proud of the body, so face-down they are the first 0.4 mm off the bed: print
    that in WHITE, swap to BLACK for the rest, flip, done. One extruder, crisp
    glyph edges, and the letters get the bed finish.

    The text comes from PEDALS and SILK_SYMBOLS -- the same source as the
    faceplate legends -- so REC/PLAY and STOP carry the dot+plus+triangle and the
    square here too, and the two can never drift apart.

    The tile is a TRAPEZOID (#922): the pad it drops into is a wedge in plan, and
    the wall is 5 mm each side at EVERY station, so the tile's sides run parallel
    to the pad's. The WIDE edge faces the case BACK (cable end) and carries the
    top of the glyphs -- fit it the other way round and the label is upside down,
    which is the intended tell.
    """
    import cadquery as cq
    made = []
    for label, _u, _v in PEDALS:
        # Trapezoid: +Y is toward the case BACK (the wide edge, and the top of
        # the glyphs), -Y toward the toe. The sides are parallel to the pad's.
        body = (cq.Workplane("XY")
                .polyline([(-TILE_L_BACK/2.0,  TILE_W/2.0),
                           ( TILE_L_BACK/2.0,  TILE_W/2.0),
                           ( TILE_L_TOE /2.0, -TILE_W/2.0),
                           (-TILE_L_TOE /2.0, -TILE_W/2.0)])
                .close().extrude(TILE_BODY_T))
        # Fit the glyphs to the NARROW edge: a block sized off the wide edge would
        # cross the tapered sides at the toe end.
        fit_l, fit_w = TILE_L_TOE - 2*TILE_MARGIN, TILE_W - 2*TILE_MARGIN
        if label in SILK_SYMBOLS:
            # fit the symbol group to the SAME box the words get, so a symbol
            # tile and a word tile read at one size
            probe = _silk_symbol_geometry(SILK_SYMBOLS[label], 0.0, 0.0, 10.0)
            pxs = [p2[0] for e2 in probe if e2["kind"] == "poly" for p2 in e2["pts"]]
            pys = [p2[1] for e2 in probe if e2["kind"] == "poly" for p2 in e2["pts"]]
            for e2 in probe:
                if e2["kind"] == "disc":
                    pxs += [e2["u"] - e2["d"]/2, e2["u"] + e2["d"]/2]
                    pys += [e2["v"] - e2["d"]/2, e2["v"] + e2["d"]/2]
            sym_h = 10.0 * min(fit_l / (max(pxs)-min(pxs)), fit_w / (max(pys)-min(pys)))
            glyph = None
            for e in _silk_symbol_geometry(SILK_SYMBOLS[label], 0.0, 0.0, sym_h):
                w = cq.Workplane("XY").workplane(offset=TILE_BODY_T)
                if e["kind"] == "disc":
                    solid = w.center(e["u"], e["v"]).circle(e["d"] / 2.0).extrude(TILE_TEXT_T)
                else:
                    solid = w.polyline(e["pts"]).close().extrude(TILE_TEXT_T)
                glyph = solid if glyph is None else glyph.union(solid)
        else:
            # Auto-fit: scale each label to the largest em that still clears
            # TILE_MARGIN on every side. A fixed em would either shrink the words
            # to fit or leave a single digit swimming in the window.
            txt = TILE_TEXT.get(label, label)
            probe = (cq.Workplane("XY").text(txt, 10.0, TILE_TEXT_T, font=TILE_FONT)
                     .val().BoundingBox())
            em = 10.0 * min(fit_l / probe.xlen, fit_w / probe.ylen)
            glyph = (cq.Workplane("XY").workplane(offset=TILE_BODY_T)
                     .text(txt, em, TILE_TEXT_T, font=TILE_FONT))
        # Centre on the INK, not on the font's advance box: cadquery's text()
        # centres the latter, which leaves the glyphs up to 0.5 mm off and the
        # baseline 0.33 high. Measure what was actually drawn and re-centre it.
        gb = glyph.val().BoundingBox()
        glyph = glyph.translate((-(gb.xmin + gb.xmax) / 2.0,
                                 -(gb.ymin + gb.ymax) / 2.0, 0))
        part = body.union(glyph)
        # Gate the GLYPH, not the part envelope: the part IS the trapezoid, so its
        # bbox always measures TILE_L_BACK and would gate nothing. Compare the ink
        # against the tile width at the ink's OWN toe-most station -- that is the
        # narrowest the tile gets anywhere the glyph reaches.
        gb = glyph.val().BoundingBox()
        avail = tile_width_at(gb.ymin)
        assert gb.xlen <= avail + 1e-6 and gb.ylen <= TILE_W + 1e-6, (
            f"pedal tile {label!r}: glyph {gb.xlen:.2f} x {gb.ylen:.2f} overflows "
            f"the {avail:.2f} available at y={gb.ymin:.2f} on the "
            f"{TILE_L_TOE:.2f}(toe)/{TILE_L_BACK:.2f}(back) x {TILE_W} tile")
        bb = part.val().BoundingBox()
        assert abs(bb.xlen - TILE_L_BACK) < 1e-6 and abs(bb.ylen - TILE_W) < 1e-6, (
            f"pedal tile {label!r}: envelope {bb.xlen:.3f} x {bb.ylen:.3f} is not "
            f"the {TILE_L_BACK:.3f} x {TILE_W:.3f} trapezoid")
        stem = "segno_pedal_tile_" + label.replace("/", "_")
        # STEP keeps the body and the glyphs as TWO SOLIDS -- that is the colour
        # split, so a CAD assembly can paint them black/white per body instead of
        # per face (800 face assignments across ten tiles is slow enough to time
        # out) and a multi-material slicer can read the split directly.
        two = cq.Compound.makeCompound([body.val(), glyph.val()])
        cq.exporters.export(two, os.path.join(OUT, stem + ".step"))
        # STL is the fused single mesh: that is what a single-extruder,
        # filament-change print wants.
        cq.exporters.export(part.val(), os.path.join(OUT, stem + ".stl"))
        made.append(stem)
    return made


def build_ring_disc_step():
    """3D reference solid for the LED-ring centre disc, generated from the SAME
    constants as its DXF.

    It used to be a hand-made file that the packager simply picked up off disk
    and shipped: by 2026-08-22 that file was O40 x 2 while the DXF the shop
    actually cuts had moved to RING_ID = O51.5 -- an 11.5 mm disagreement inside
    one vendor zip, and nothing in the build noticed for three ring resizes.
    Generating it here is the whole point; do not go back to a checked-in file.
    """
    import cadquery as cq
    d = (cq.Workplane("XY").circle(RING_ID / 2.0).circle(D_ENC / 2.0).extrude(T))
    step = os.path.join(OUT, "segno_ring_disc.step")
    cq.exporters.export(d.val(), step)
    return step


def build_encoder_knob_step():
    """ENCODER KNOB -- **PURCHASED**, not printed. O50 x 18, O6 bore, black
    aluminium, PLAIN SIDES (owner's chosen part, 2026-08-22).

    This is a REFERENCE model of a bought part, not a thing anyone fabricates
    from this repo. It exists so the assembly, the ring-window sizing and the
    collision audit have the real knob in them; the STEP is deliberately NOT in
    the 3D-print vendor pack, and MANUFACTURING.md lists it under purchased
    parts. Do not "restore" the grip flutes an earlier revision had -- the part
    the owner bought has a smooth barrel, and modelling notches that are not
    there would quietly overstate the clearance to the ring window.

    Why it is O50: the Ring 24's window is O67 and its ID is O52.3, so a O50 hub
    fills the middle and leaves a ~1 mm dark gap inside the lit annulus.

      body O50 x 18, 0.6 bottom chamfer, 1.6 top edge fillet;
      O22 x 4.5 NUT RELIEF from below -- ASSUMED, not measured off the vendor
      part: it is what lets the knob clear the EC11's mounting nut, and without
      some relief there the knob fouls the nut and never seats (0.022/0.027 cm3
      of interference measured before it was added). If the real knob has a
      solid underside, it will sit ~3 mm proud of where this model puts it --
      worth a caliper check on the part before the faceplate is cut.
      O6 shaft bore for the EC11's 6 mm shaft, BLIND -- the top is unbroken.
    z=0 is the knob's underside (it rides on the EC11 nut, not the faceplate).
    """
    import cadquery as cq
    r_out, h = KNOB_D / 2.0, KNOB_H
    k = cq.Workplane("XY").circle(r_out).extrude(h)
    k = k.faces(">Z").edges().fillet(KNOB_TOP_FILLET)   # the domed top edge
    k = k.faces("<Z").edges().chamfer(0.6)
    k = k.faces("<Z").workplane().circle(KNOB_NUT_D / 2.0).cutBlind(-KNOB_NUT_H)
    k = k.cut(cq.Workplane("XY").workplane(offset=KNOB_NUT_H)
              .circle(KNOB_BORE_D / 2.0).extrude(KNOB_BORE_TOP - KNOB_NUT_H))
    step = os.path.join(OUT, "segno_encoder_knob.step")
    cq.exporters.export(k.val(), step)
    cq.exporters.export(k.val(), os.path.join(OUT, "segno_encoder_knob.stl"))
    return step


def build_ring_diffuser_step():
    """Encoder ring DIFFUSER + DISC HOLDER, one piece (3D-print WHITE PLA, x1,
    user call 2026-08-19): replaces the plain annular insert. From the top:
    - the LENS annulus pushes into the faceplate's RING_OD (O67) ring window
      (proud);
    - the aluminium RING DISC (RING_ID = O51.5 x 2) drops into a front-side
      pocket inside the lens bore and sits FLUSH with the faceplate top; the
      EC11 clamps it (bushing through the disc's O7.2, nut under the knob);
    - a full BACK PLATE extends past the window to O75 -- the exposed front
      ring (window edge r33.5 .. plate r37.5) is the CA-GLUE land against the
      faceplate underside, 4.0 mm wide. NOTE: the back-plate/lip radii (37.5,
      32.0, 25.6, 24.2) are hardcoded and were RE-DERIVED for the Ring 24;
      they do not scale themselves -- re-derive them again with any window
      resize, and keep plate_r > RING_OD/2 or the glue land vanishes.
    The NeoPixel RING 24 (65.5 OD / 52.3 ID / 3.2 thick, the ring the owner
    has) is MOUNTED ON THE RING BOARD around the EC11 -- no nest here; its
    LEDs shine up through the 0.8 mm web.
    z=0 is the faceplate-underside/glue plane."""
    import cadquery as cq
    ro = (RING_OD - LED_INS_CLR) / 2.0
    ri = (RING_ID + LED_INS_CLR) / 2.0
    plate_t = 2.0
    lens = (cq.Workplane("XY").circle(ro).circle(ri)
            .extrude(T + LED_INS_PROUD))
    lens = lens.edges(">Z").chamfer(0.3)
    ins = lens.union(cq.Workplane("XY").circle(37.5).circle(24.2)
                     .extrude(-plate_t))
    # disc lip: the disc rests on the inner lip at z=0, flush with the sheet
    # top when glued (disc top = T). Thin the web over the LED circle so the
    # board-mounted ring glows through 0.8 mm of white PLA.
    ins = ins.cut(cq.Workplane("XY").workplane(offset=-plate_t)
                  .circle(32.0).circle(25.6).extrude(plate_t - 0.8))
    step = os.path.join(OUT, "segno_ring_diffuser.step")
    cq.exporters.export(ins.val(), step)
    cq.exporters.export(ins.val(), os.path.join(OUT, "segno_ring_diffuser.stl"))
    return step


def build_screen7_fit_test():
    """7" screen FIT TEST plate (3D print, x1, #762): a stand-in for the
    faceplate around the 7" aperture, at the REAL sheet gauge (T = 2.0) so the
    reveal through the aperture is what the aluminum will give. Lay the module
    glass-down onto the plate BACK; four bosses rise toward the tab plane
    (S7C_GLASS_TO_TABF behind the glass) but stop 0.2 SHORT: the M3 x 8 screws
    (down through the O3.1 tab holes, self-tapping into the boss pilots) pull
    the tabs onto the bosses and that preload clamps the GLASS FLAT against
    the plate back -- flatness comes from the screws, not from print height.
    Bare slab, no stiffener (user call: it's a test, don't waste material).
    Then look through the FRONT: the ACTIVE AREA must fill the aperture -- no bezel
    visible, no pixels hidden -- and all four screws must land without
    forcing. Hole positions come from the vendor STEP; if anything misses,
    measure it and correct S7C_HOLES / the aperture offset. The notch marks
    TOP; the chamfered aperture rim is the FRONT face."""
    import cadquery as cq
    pw, ph, pt = 200.0, 152.0, T          # T: the faceplate's actual 2.0 gauge
    plate = cq.Workplane("XY").rect(pw, ph).extrude(pt)
    plate = plate.cut(cq.Workplane("XY").rect(SMALL_W, SMALL_H).extrude(pt))
    plate = plate.edges("|Z").chamfer(0.6)
    try:
        plate = plate.faces(">Z").edges("<X or >X or <Y or >Y").chamfer(0.4)
    except Exception:
        pass
    plate = plate.cut(cq.Workplane("XY").center(0, ph / 2.0).circle(3.0).extrude(pt))
    # bosses on the BACK (z<0 side is the back once flipped: build them below
    # z=0 by extruding negative): top face of the plate (z=pt) is the FRONT.
    # 0.2 SHORT of the tab plane = designed clamp preload (see docstring).
    boss_h = S7C_GLASS_TO_TABF - 0.2
    for (hx, hy) in S7C_HOLES:
        plate = plate.union(cq.Workplane("XY").center(hx, hy)
                            .circle(4.5).extrude(-boss_h))
        plate = plate.cut(cq.Workplane("XY").workplane(offset=-boss_h)
                          .center(hx, hy).circle(2.6 / 2.0).extrude(boss_h + pt))
    sp = os.path.join(OUT, "segno_screen7_fit_test.step")
    cq.exporters.export(plate.val(), sp)
    cq.exporters.export(plate.val(), os.path.join(OUT, "segno_screen7_fit_test.stl"))
    return sp


# --- 15.6" screen stand (3D print x2, #762, PROVISIONAL until the monitor
# arrives) -- the 7" tower concept, split for the Ender 3 V3 bed (220^2) and
# bridging OVER the electronics bay (boards at x 46-68, y 23-32: no floor
# there). LEFT part = end tower + half-deck; RIGHT part mirrors; they lap-
# splice near the screen centre (2x M3) where the VESA M4s also clamp the
# monitor. Towers only touch the monitor BACK via pads -- the side edges stay
# completely free for the panel connectors (right-angle USB-C/mini-HDMI
# adapters assumed). ALL monitor numbers are the LISTING values -- caliper on
# arrival: body 353x208x5.8, VESA 75x75 M4 assumed CENTRED on the viewport.
S16_BODY_W  = 353.0   # PROVISIONAL listing dims
S16_BODY_H  = 208.0
S16_BODY_D  = 5.8
S16_VESA    = 75.0    # PROVISIONAL: pattern, M4, centred
S16_GAP     = 0.5     # deck sits behind the monitor back; only pads/bosses touch
S16_BEAM_D  = 110.0   # deck beam depth (v)
S16_BEAM_T  = 10.0    # deck plate thickness
S16_RIB_H   = 15.0    # stiffening ribs under the beam edges
S16_WALL    = 4.0
S16_FLANGE  = 12.0
ENDER_BED   = 218.0   # Ender 3 V3 printable square (2mm margin) -- gate below


def build_screen16_stand_steps():
    """15.6" monitor stand, LEFT + RIGHT prints (PETG, #762, PROVISIONAL).
    World-mm coordinates (origin = plan origin at base floor TOP; place in
    Fusion at z = floor top). Lid underside (measured): z(y) = 12.437 +
    tan(SLOPE)*y; world y = cos(SLOPE)*v_plan - 2.093. The monitor's glass
    presses the underside, its back is S16_BODY_D below, the deck plane sits
    S16_GAP further back -- only the VESA bosses and tower pads rise to touch.
    Bed constraint: splice at x=600 (off-centre, clear of the VESA bosses),
    outboard flange edges trimmed flush so each part stays under ENDER_BED."""
    import cadquery as cq
    cs = math.cos(math.radians(SLOPE_ANGLE))
    sn = math.sin(math.radians(SLOPE_ANGLE))
    xc = SCREEN_16_U
    v_c = SCREEN_TOP_V - BIG_H / 2.0
    yc = cs * v_c - 2.093
    drop = (S16_BODY_D + S16_GAP) / cs
    z0 = 12.437 - drop                    # deck plane height AT y=0
    def wp(off=0.0):
        return (cq.Workplane("XY").workplane(offset=z0)
                .transformed(rotate=(SLOPE_ANGLE, 0, 0)).workplane(offset=off))
    pyc = yc / cs                          # deck centreline, in-plane y

    def deck_half(x0, x1, lapdir):
        d = (wp().center((x0 + x1) / 2.0, pyc)
             .rect(x1 - x0, S16_BEAM_D).extrude(-S16_BEAM_T))
        for sy in (-1, 1):
            d = d.union(wp(-S16_BEAM_T)
                        .center((x0 + x1) / 2.0, pyc + sy * (S16_BEAM_D / 2.0 - 5.0))
                        .rect(x1 - x0, 10.0).extrude(-S16_RIB_H))
        lap_x = x1 if lapdir > 0 else x0
        if lapdir > 0:   # lower lap tongue continues past the joint
            d = d.union(wp(-S16_BEAM_T).center(lap_x + 11.0, pyc)
                        .rect(22.0, S16_BEAM_D - 12.0).extrude(S16_BEAM_T / 2.0))
        else:            # upper half relieved so the tongue nests under it
            d = d.cut(wp(-S16_BEAM_T).center(lap_x + 11.0, pyc)
                      .rect(22.4, S16_BEAM_D).extrude(S16_BEAM_T / 2.0 + 0.2))
        return d

    def tower(x0, x1, fl_out_sign):
        t = (cq.Workplane("XY").center((x0 + x1) / 2.0, yc).rect(x1 - x0, S16_BEAM_D)
             .extrude(300.0))
        t = t.cut(cq.Workplane("XY").center((x0 + x1) / 2.0, yc)
                  .rect(x1 - x0 - 2 * S16_WALL, S16_BEAM_D - 2 * S16_WALL).extrude(301.0))
        t = t.cut(wp(-S16_BEAM_T - S16_RIB_H).center((x0 + x1) / 2.0, pyc)
                  .rect(2000, 2000).extrude(500))
        # flange: fl_out_sign=+1/-1 adds the inboard x flange; 0 = y-only
        # (the LEFT tower lives in a 48mm strip between platform_mid's body
        # edge at x~417 and the board standoffs at x~465 -- no x room at all)
        fx0 = x0 - (S16_FLANGE if fl_out_sign < 0 else 0.0)
        fx1 = x1 + (S16_FLANGE if fl_out_sign > 0 else 0.0)
        fl = (cq.Workplane("XY").center((fx0 + fx1) / 2.0, yc)
              .rect(fx1 - fx0, S16_BEAM_D + 2 * S16_FLANGE).extrude(5.0))
        fl = fl.cut(cq.Workplane("XY").center((x0 + x1) / 2.0, yc)
                    .rect(x1 - x0 - 2 * S16_WALL, S16_BEAM_D - 2 * S16_WALL).extrude(5.0))
        t = t.union(fl)
        anchors = []
        sites = [((x0 + x1) / 2.0, yc - (S16_BEAM_D + S16_FLANGE) / 2.0),
                 ((x0 + x1) / 2.0, yc + (S16_BEAM_D + S16_FLANGE) / 2.0)]
        if fl_out_sign != 0:
            inx = (x1 + S16_FLANGE / 2.0) if fl_out_sign > 0 else (x0 - S16_FLANGE / 2.0)
            sites += [(inx, yc - 30.0), (inx, yc + 30.0)]
        for ax, ay in sites:
            anchors.append((ax, ay))
            t = t.cut(cq.Workplane("XY").center(ax, ay).circle(3.2 / 2.0).extrude(5.0))
        # pad rising to the monitor back plane
        t = t.union(wp().center((x0 + x1) / 2.0, pyc).rect(x1 - x0, 30.0)
                    .extrude(S16_GAP))
        return t, anchors

    SPLICE = 600.0
    lt, la = tower(460.0, 500.0, -1)  # strip: platform_mid 417 | board PCB now 510
    left = lt.union(deck_half(460.0, SPLICE, +1))
    rt, ra = tower(745.0, 785.0, -1)
    right = rt.union(deck_half(SPLICE, 785.0, -1))
    # CROSS-CHECK the frozen base-floor stations against what the stands just
    # computed (#767). These flange holes ARE the base holes: the stands are
    # built in world plan coords (x, y_world) with the floor's own frame, so the
    # comparison is ABSOLUTE -- no placement transform to guess. STAND_ANCHORS
    # used to be a pure transcription; a 6.0 mm drift got as far as /code-review
    # once (46ab3221). Now any S16_*/splice/tower-x change that moves a flange
    # hole trips here instead of on the cut base plate.
    _check_stand_anchors(la + ra, STAND_ANCHORS_156, "15.6in stand")

    def add_vesa(d, sxs):
        for sx in sxs:
            for sy in (-1, 1):
                hx = xc + sx * S16_VESA / 2.0
                hy = pyc + sy * S16_VESA / 2.0
                # O9.3 float hole: M4 + O12 fender washer gives +-2.5 of
                # monitor position adjust in BOTH axes -- the metal aperture
                # never depends on the panel's viewport offsets (11-day
                # de-risk, user-approved 2026-08-19)
                d = d.union(wp().center(hx, hy).circle(9.0).extrude(S16_GAP))
                d = d.cut(wp(S16_GAP).center(hx, hy).circle(9.3 / 2.0)
                          .extrude(-(S16_GAP + S16_BEAM_T + 1.0)))
                d = d.cut(wp(-S16_BEAM_T).center(hx, hy).circle(14.0 / 2.0)
                          .extrude(-S16_RIB_H))
        return d
    left = add_vesa(left, (-1,))
    right = add_vesa(right, (+1,))
    def add_splice(d):
        for sy in (-1, 1):
            d = d.cut(wp(1.0).center(SPLICE + 11.0, pyc + sy * (S16_BEAM_D / 2.0 - 20.0))
                      .circle(3.4 / 2.0).extrude(-(S16_BEAM_T + 3.0)))
        return d
    left = add_splice(left)
    right = add_splice(right)

    out = []
    for nm, sol, anc in (("segno_screen16_stand_L", left, la),
                          ("segno_screen16_stand_R", right, ra)):
        bb = sol.val().BoundingBox()
        dims = (bb.xmax - bb.xmin, bb.ymax - bb.ymin, bb.zmax - bb.zmin)
        assert max(dims) <= ENDER_BED, (
            f"{nm}: {dims[0]:.0f}x{dims[1]:.0f}x{dims[2]:.0f} exceeds the Ender bed ({ENDER_BED})")
        print("  %s: %.0f x %.0f x %.0f mm, floor anchors %s" % (
            nm, dims[0], dims[1], dims[2], ["(%.0f, %.0f)" % a for a in anc]))
        sp = os.path.join(OUT, nm + ".step")
        cq.exporters.export(sol.val(), sp)
        cq.exporters.export(sol.val(), os.path.join(OUT, nm + ".stl"))
        out.append(sp)
    return out


def build_post_step():
    """Folded 3D of the base-anchored support post (issue #292, x2): foot flat on
    the floor, vertical web, top pad. X=u (width POST_PW), Y=v, Z=up.
    (Restored: the def line was dropped by accident in 845e3e31, which made the
    whole --no-step block die here and silently skip every later STEP build.)"""
    import cadquery as cq
    pw, pad, web, foot, t = POST_PW, POST_PAD, POST_H, POST_FOOTL, POST_T
    # C-fold, foot + pad both FORWARD of the web. Local X=u(width), Y=v(depth), Z=up.
    # foot on the floor (Y 0..foot), web vertical at its back edge (Y=foot), pad hinged
    # at the web top and TILTED down-forward by POST_TILT to bed on the sloped underside.
    foot_p = cq.Workplane("XY").box(pw, foot, t, centered=False)                          # floor, Y 0..foot
    web_p  = cq.Workplane("XY").box(pw, t, web, centered=False).translate((0, foot, 0))   # vertical at Y=foot
    pad_p  = (cq.Workplane("XY").box(pw, pad, t, centered=False)
              .translate((0, foot - pad, web))                                            # flat at the top, forward
              .rotate((0, foot, web), (1, foot, web), POST_TILT))                         # tilt to the slope: +x right-hand rule drops the free (front) end
                                                                                         # (the restored original had -POST_TILT, which LIFTED the pad into the lid)
    # hinge weld: the tilted pad only meets the web along the fold LINE, so a
    # plain union leaves it a separate lump (2-solid STEP, renders broken).
    # A t-sized block across the fold volume-overlaps both and fuses the part
    # into ONE solid -- it also stands in for the real bend radius.
    weld_p = (cq.Workplane("XY").box(pw, 2 * t, 2 * t, centered=False)
              .translate((0, foot - t, web - t)))
    body = foot_p.union(web_p).union(weld_p).union(pad_p)
    for du in (-POST_BOLT_DU, POST_BOLT_DU):                                              # M4 through the foot
        body = body.cut(cq.Workplane("XY").cylinder(
            2*t, D_M4/2.0, centered=(True, True, False)).translate((pw/2.0+du, foot/2.0, 0)))
    step = os.path.join(OUT, "segno_post.step")
    cq.exporters.export(body.val(), step)
    return step


def build_screen7_tower_step():
    """7" screen support TOWER (3D print in PETG, x1, #762): the one-piece
    replacement for the frame+legs cradle ("more beefy", user call). A closed
    wedge box in WORLD coordinates (x = console x, y = depth, z = up; origin =
    the base-floor point under the display-window centre):

    - sloped DECK (parallel to the faceplate underside) carrying the open
      window and the four tab BOSSES -- module mounts exactly as before
      (M3 x 8 through the O3.1 tabs into heat-set inserts / self-tap pilots),
      only the bosses touch the module, the PCB floats over the window;
    - 4 mm perimeter WALLS from the deck straight down to the floor -- the box
      section takes touch loads without racking;
    - floor FLANGE with SIX M3 anchor stations (these define the #762 base
      floor holes; positions printed at build time);
    - cable windows in both side walls.

    Height: S7T_H0 puts the glass in kiss contact with the lid per the
    measured underside plane; shim M3 washers under the tabs if a print runs
    short. No mirror games: built in world frame, holes at front-view
    positions, placed by translation only."""
    import cadquery as cq
    c = math.cos(math.radians(SLOPE_ANGLE))
    W, D = S7C_FRAME_W, S7C_FRAME_H
    x0, y0, x1, y1 = S7C_MOD_BB
    mcx, mcy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    H0, wall, fl, dt = S7T_H0, S7T_WALL, S7T_FLANGE, S7T_DECK
    boss_h = S7C_MOD_DEPTH + S7C_GAP - (S7C_GLASS_TO_TABF + S7C_TAB_T)

    def wp(off=0.0):
        return (cq.Workplane("XY").workplane(offset=H0)
                .transformed(rotate=(SLOPE_ANGLE, 0, 0))
                .workplane(offset=off))

    # deck: a THICK slab whose window is cut with 45-degree expanding sides,
    # leaving corbels that carry the deck rim into the walls (the "structure"
    # in the hollow box: monocoque walls + corbelled deck + two ribs below).
    # The corbels also make the standing print support-free.
    tower = wp().center(mcx, mcy).rect(W, D).extrude(-(dt + 26.0))
    tower = tower.cut(wp(1.0).center(mcx, mcy).rect(S7C_WIN_W, S7C_WIN_H)
                      .extrude(-(dt + 29.0), taper=-45.0))
    # walls: vertical prism ring, cut above the deck's bottom plane
    cy_w = mcy * c                                   # footprint centre, world y
    ring = (cq.Workplane("XY").center(mcx, cy_w).rect(W, D * c)
            .extrude(H0 + 60.0))
    ring = ring.cut(cq.Workplane("XY").center(mcx, cy_w)
                    .rect(W - 2 * wall, D * c - 2 * wall).extrude(H0 + 61.0))
    above_deck = wp(-dt).center(mcx, mcy).rect(2000, 2000).extrude(500)
    ring = ring.cut(above_deck)
    tower = tower.union(ring)
    # keep the deck stack inside the wall footprint
    tower = tower.intersect(cq.Workplane("XY").center(mcx, cy_w)
                            .rect(W, D * c).extrude(H0 + 60.0)
                            .union(cq.Workplane("XY").center(mcx, cy_w)
                                   .rect(W + 2 * fl, D * c + 2 * fl).extrude(5.0)))
    # two full-height transverse RIBS flanking the window, deck to floor
    for sx in (-1, 1):
        rib = (cq.Workplane("XY").center(mcx + sx * (S7C_WIN_W / 2.0 + 6.0), cy_w)
               .rect(4.0, D * c - 2 * wall).extrude(H0 + 60.0))
        rib = rib.cut(wp(-dt).center(mcx, mcy).rect(2000, 2000).extrude(500))
        tower = tower.union(rib)
    # floor flange + six anchor stations
    flange = (cq.Workplane("XY").center(mcx, cy_w).rect(W + 2 * fl, D * c + 2 * fl)
              .extrude(5.0))
    flange = flange.cut(cq.Workplane("XY").center(mcx, cy_w)
                        .rect(W - 2 * wall, D * c - 2 * wall).extrude(5.0))
    anchors = []
    for ax, ay in ((-(W + fl) / 2.0, -40.0), (-(W + fl) / 2.0, 40.0),
                   ((W + fl) / 2.0, -40.0), ((W + fl) / 2.0, 40.0),
                   (0.0, -(D * c + fl) / 2.0), (0.0, (D * c + fl) / 2.0)):
        anchors.append((mcx + ax, cy_w + ay))
        flange = flange.cut(cq.Workplane("XY").center(mcx + ax, cy_w + ay)
                            .circle(3.2 / 2.0).extrude(5.0))
    # CROSS-CHECK the frozen base-floor stations for the tower (#767). Unlike the
    # 15.6 stands this STEP is built in a LOCAL frame (origin = the display-window
    # centre) and placed in Fusion by a translation the generator never sees, so an
    # absolute comparison is impossible here. The RELATIVE pattern is not: every
    # pairwise delta between the six computed stations must match the pairwise
    # deltas of the six frozen tower stations. That catches any S7C_*/frame/flange
    # change that resizes or re-spaces the flange -- only a pure rigid translation
    # of the whole tower can slip through, and that is exactly the one thing the
    # generator cannot know.
    _check_stand_anchor_pattern(anchors, STAND_ANCHORS_7IN, "7in tower")
    tower = tower.union(flange)
    # cable windows, both side walls
    for sx in (-1, 1):
        cutter = (cq.Workplane("XY").workplane(offset=8.0)
                  .center(mcx + sx * W / 2.0, cy_w).rect(3 * wall, 40.0)
                  .extrude(26.0))
        tower = tower.cut(cutter)
    # RING-BOARD CLEARANCE NOTCH (#762): the populated 60x60 ring/encoder board
    # hangs over the tower's front rim with its under-side pins -- the real
    # board came within 1.7 mm of the wall top. Drop the front wall/rim centre
    # (70 wide, x-centred on the ring axis = the window centre) to 30 mm so the
    # board passes with >=6 mm of air. The front tab bosses sit outside this
    # span; their corbels are untouched.
    notch = (cq.Workplane("XY").workplane(offset=30.0)
             .center(0.0, -64.0).rect(70.0, 32.0).extrude(80.0))
    tower = tower.cut(notch)
    # tab bosses + heat-set counterbores + pilots (front-view positions)
    for (hx, hy) in S7C_HOLES:
        tower = tower.union(wp().center(hx, hy).circle(4.5).extrude(boss_h))
        tower = tower.cut(wp(boss_h).center(hx, hy).circle(4.0 / 2.0).extrude(-5.0))
        tower = tower.cut(wp(boss_h).center(hx, hy).circle(2.6 / 2.0)
                          .extrude(-(boss_h + dt + 2.0)))
    print("  tower floor anchors (world mm, relative to the display-window centre):")
    for a in anchors:
        print("    (%+.1f, %+.1f)" % a)
    sp = os.path.join(OUT, "segno_screen7_tower.step")
    cq.exporters.export(tower.val(), sp)
    cq.exporters.export(tower.val(), os.path.join(OUT, "segno_screen7_tower.stl"))
    return sp


def build_step(write_parts=True):
    import cadquery as cq
    os.makedirs(OUT, exist_ok=True)
    asm = cq.Assembly(name="Segno")
    # global: X=depth (0 front->D rear), Y=width (0..W), Z=up
    bottom = cq.Workplane("XY").box(D-2*T, W-2*T, T, centered=False).translate((T, T, 0))
    front  = cq.Workplane("XY").box(T, W-2*T, H_FRONT, centered=False).translate((0, T, 0))
    rear   = _rear_flat(cq)
    trans  = _transition_face(cq)
    side   = cq.Workplane("XZ").polyline([(0,0),(D,0),(D,REAR_WALL_H),(FACE_RUN,H_REAR),(0,H_FRONT)]).close().extrude(-T)
    fp     = _faceplate_flat(cq)
    # Canonical layout (7" left) is in the schedule itself -- no mirror. Parts are built
    # in design coords (Y=u, X=v front->rear) and placed directly; the player view is a
    # camera choice in the render/viewer, not a geometry flip.
    addw = lambda shape, name, loc=None: asm.add(
        (shape.val().located(loc) if loc else shape.val()), name=name)

    addw(bottom, "bottom")
    addw(front,  "front")
    rear_loc = (cq.Location(cq.Vector(D - T, T, 0))
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), 90)
                * cq.Location(cq.Vector(0,0,0), cq.Vector(0,0,1), 90))
    addw(rear, "rear", rear_loc)
    addw(side, "side_L")
    addw(side, "side_R", cq.Location(cq.Vector(0, W - T, 0)))
    asm.add(trans, name="transition")
    fp_loc = (cq.Location(cq.Vector(0, (W - LID_W) / 2.0, H_FRONT))
              * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), -SLOPE_ANGLE))
    addw(fp, "faceplate", fp_loc)
    # 10 printed platform pedestals under the pedal slots (X = pedal v, Y = pedal u);
    # mid-row (CLEAR/BANK) pedestals are taller because the lid is higher there.
    # Depth uses the SLOPE-PROJECTED station (v*cos) — the same projection
    # platform_foot_holes() drills the bottom plate with — so platform, floor
    # holes, and faceplate slot share one centre at every pedal position.
    _cs = math.cos(math.radians(SLOPE_ANGLE))
    for i, (label, u, v) in enumerate(PEDALS):
        plat = _platform_printed(cq, platform_h(v), v)
        addw(plat, f"platform_{i}", cq.Location(cq.Vector(v * _cs, u + T, T)))
    # representative console board v2 on standoffs, rear clear zone (visual stand-in;
    # the fully-detailed KiCad model is rendered in the 3D viewer, not the STEP)
    blk = {"CONSOLE_BOARD": (BOARD_SIZE[0], BOARD_SIZE[1], 16.0)}
    for name, cx, cy, pat in board_mounts():
        bx, by, bz = blk[name]
        b = cq.Workplane("XY").box(bx, by, bz, centered=(True, True, False)).translate((cy + T, cx + T, STANDOFF_H))
        addw(b, name.lower())
        # the 4 M3 standoff posts under the board (STANDOFF_H tall, on the hole pattern)
        for du in (-pat[0] / 2.0, pat[0] / 2.0):
            for dv in (-pat[1] / 2.0, pat[1] / 2.0):
                post = cq.Workplane("XY").circle(2.75).extrude(STANDOFF_H).translate((cy + T + dv, cx + T + du, 0))
                addw(post, f"{name.lower()}_standoff_u{int(cx + du)}_d{int(cy + dv)}")

    asm.save(os.path.join(OUT, "segno_assembly.step"))
    if write_parts:
        exp = cq.exporters.export
        # The base is ONE folded blank (see segno_base.dxf); the assembly STEP shows it
        # in 3D. Per-part STEPs: the removable lid (platforms export in
        # build_platform_steps as print files).
        exp(fp.val(), os.path.join(OUT, "segno_faceplate.step"))
    return os.path.join(OUT, "segno_assembly.step")

# ===========================================================================
# DRAWING METADATA -- material, quantity, package, bend table   (issue #775)
# ---------------------------------------------------------------------------
# The geometry engine is gated by _check(); the DOCUMENT path had no assertions at
# all, and every RED finding of the #775 DFM sweep landed in that gap. Everything a
# sheet says about itself now comes from here, and _verify_drawing_package() reads
# the generated files back and holds it.
# ===========================================================================

# Shop-facing text is SPANISH: the parts are fabricated in Argentina and the floor
# reads Spanish (issue #778). What stays English is deliberate -- layer names
# (CUT/BEND/VENT/MASK/NOTE/ENGRAVE/SILK) and part stems (segno_base, ...) are
# identifiers shared with the DXF/STEP files and the vendor zips, and the shop
# matches a sheet to a file by them. Numbers, units, symbols (Ø ± °) and standard
# designations (5052-H32, M3, K, R2) are international and are left alone.
AL_SHEET  = f"aluminio 5052-H32 de {T:.1f} mm"
STEEL_CR  = f"acero laminado en frío de {POST_T:.1f} mm"
VINYL     = "vinilo adhesivo impreso / policarbonato, troquelado - NO ES METAL"
PLY_2MM   = (f"plástico bicapa de grabado de {TILE_PLY_T:.1f} mm "
             "(capa negra / núcleo blanco) - NO ES METAL")

# stem -> (material printed on the sheet, qty per console, vendor package).
# Quantities track the cut list in hardware/MANUFACTURING.md section 1.
# Before #775 dxf_to_pdf defaulted these and the one call site passed neither, so
# EVERY sheet claimed "2.0 mm 5052-H32 Al | qty 1" -- including the 1.6 mm steel
# post (x2) and the vinyl overlay.
PKG_SHEETMETAL = "sheetmetal"   # laser + brake + powder coat
PKG_OVERLAY    = "overlay"      # label/overlay printer, die-cut, no metal
PKG_TILES      = "tiles"        # 2-ply engraved plastic, laser cut + engrave
PART_SPECS = {
    "segno_base":                (AL_SHEET, 1, PKG_SHEETMETAL),
    "segno_faceplate":           (AL_SHEET, 1, PKG_SHEETMETAL),
    "segno_rear_panel":          (AL_SHEET, 1, PKG_SHEETMETAL),
    "segno_ring_disc":           (AL_SHEET, 1, PKG_SHEETMETAL),
    "segno_corner_bracket_rear": (AL_SHEET, 2, PKG_SHEETMETAL),
    "segno_post":                (STEEL_CR, 2, PKG_SHEETMETAL),
    "segno_overlay":             (VINYL,    1, PKG_OVERLAY),
    "segno_pedal_tiles":         (PLY_2MM, 10, PKG_TILES),
}

# Spanish part name for the title block. The FILE STEM still travels with it --
# the shop pairs a printed sheet to a DXF by the stem, so translating that away
# would break the pairing (and the zips). Name for the human, stem for the file.
PART_TITLES_ES = {
    "segno_base":                "CUERPO (piso + frente + laterales + trasera)",
    "segno_faceplate":           "TAPA SUPERIOR",
    "segno_rear_panel":          "PANEL TRASERO DE CONECTORES",
    "segno_ring_disc":           "DISCO CENTRAL DEL ARO DE LEDS",
    "segno_corner_bracket_rear": "ÁNGULO DE ESQUINA TRASERA",
    "segno_post":                "POSTE DE APOYO DE LA TAPA",
    "segno_overlay":             "CALCO SUPERIOR IMPRESO (no es metal)",
    "segno_pedal_tiles":         "AZULEJOS DE PEDAL (plástico bicapa grabado)",
}

# --- tolerance block (issue #778) ------------------------------------------
# A flat pattern with no tolerances is quoted at whatever the shop feels like: a
# hole pattern that has to line up with a 9-station lid seam, two riveted corner
# brackets and a Ø22 M6 stud cannot be left to "as cut". These are the general
# tolerances, applied wherever a dimension is not called out individually.
#
# Values are what a laser + press brake shop actually holds on 2 mm 5052:
#   posición ± 0,15   - laser positional repeatability is ~± 0,10; 0,15 leaves the
#                       rivet/screw pairs inside the Ø3.4-on-M3 clearance.
#   diámetro ± 0,10   - kerf variation on 2 mm; M3/M4 clearance holes tolerate it.
#   plegado  ± 0,5°   - a good brake holds ± 0,5°; over the 45 mm post web that is
#                       ± 0,4 mm at the pad, which the felt cap absorbs.
#   exteriores ± 0,3  - flat/blank dimensions off the laser.
# The fifth row is an ADDITION to the four asked for: a dimension measured ACROSS
# a fold stacks bend deduction, springback and gauge scatter, and ± 0,3 mm is not
# holdable across the base's five folds. Calling it out at ± 0,5 mm is honest;
# leaving it at ± 0,3 mm invites a rejection the part does not deserve.
# NB the tolerance block is the ONE place that writes decimals the Argentine way
# (comma). Every other number on a sheet is generated from the model and appears
# with a point in the DXF the shop opens next to it; switching separators between
# the drawing and its own geometry is how a 0,15 becomes a 15.
TOLERANCE_TITLE = "TOLERANCIAS (salvo indicación contraria)"
TOLERANCE_ROWS = [
    ("posición de agujeros",                "± 0,15 mm"),
    ("diámetro de agujeros",                "± 0,10 mm"),
    ("ángulos de plegado",                  "± 0,5°"),
    ("dimensiones exteriores (desarrollo)", "± 0,3 mm"),
    ("dimensiones medidas sobre un pliegue", "± 0,5 mm"),
]

def _tolerance_lines():
    """The tolerance block as rendered text rows, heading first."""
    wdt = max(len(k) for k, _v in TOLERANCE_ROWS) + 3
    return [TOLERANCE_TITLE] + [f"  {k.ljust(wdt)}{v}" for k, v in TOLERANCE_ROWS]

# Layers whose geometry is CUT CLEAN THROUGH the sheet. Both of these must render
# black on every PDF: VENT is 127 louvres and ~5.6 m of cut path, and it used to
# render ACI-7 white on a white sheet -- invisible on every drawing, missing from
# every quote, and the failure tail is a Pi 5 in a sealed aluminium box (#775 R1).
THRU_CUT_LAYERS = ("CUT", "VENT")
# Annotation layers: text, fold references and coating masks. Never cut.
ANNOT_LAYERS    = ("BEND", "NOTE", "ENGRAVE", "SILK", "MASK", "ACRYLIC")

# The legend, as one string so it can be asserted on. It used to read
# "CUT(thru) - BEND(score) - VENT - ENGRAVE", which tells a shop that (a) VENT is
# some other process and (b) the fold lines want scoring: 3 380 mm of score in
# 2 mm 5052 is a scrapped base (#775 R1 + R4).
# (Layer NAMES stay in English -- they are the identifiers inside the DXF.)
SHEET_LEGEND = ("CUT + VENT = CORTE PASANTE (las dos capas, la misma operación)   |   "
                "BEND = LÍNEA DE PLEGADO, SOLO REFERENCIA - no cortar, no marcar, no rayar ni grabar   |   "
                "MASK = máscara de pintura (no pintar), NO CORTAR   |   "
                "NOTE / ENGRAVE = texto, no es geometría   |   "
                "SILK = ARTE IMPRESO: texto + símbolos rellenos (imprimir en blanco, NO CORTAR)")
# The exact prohibition clause, so the guard can hold both halves of it: the words
# must be PRESENT (BEND is not an operation) and must appear NOWHERE ELSE in the
# legend, where they would read as an instruction to perform them.
LEGEND_NO_SCORE = "no cortar, no marcar, no rayar ni grabar"

# Tile sheet: ENGRAVE is the process, not annotation. Do not reuse SHEET_LEGEND
# here -- that one tells the metal shop ENGRAVE is "texto, no es geometría".
TILE_LEGEND = ("CUT = CORTE PASANTE (contorno del azulejo)   |   "
               "ENGRAVE = GRABADO RELLENO: quema la capa negra, deja ver el núcleo blanco "
               "(NO es texto, es geometría)   |   "
               "NOTE = instrucciones, no cortar")

# --- bend tables -----------------------------------------------------------
# A flat pattern with no angles is not a drawing. The base's transition fold is
# neither 90 nor 180 deg and appeared in no document at all; guess it and the lid's
# rear lap and its nine M3 pilots all land in the wrong plane (#775 R2).
#
# Row: (seq, name, axis, position mm, line length mm, fold rotation deg,
#       direction, inside radius mm, development deduction mm)
# "fold rotation" is the angle the flap turns THROUGH from flat; the included
# angle printed beside it is 180 - rotation, which is what a brake operator reads
# off a protractor. Direction is stated relative to the DRAWN face because that is
# the only reference on a flat pattern -- each part's NOTE says which face is which.
UP_TOWARD = "ARRIBA, hacia la cara dibujada"
DN_AWAY   = "ABAJO, opuesto a la cara dibujada"

def _bend_tables():
    BW, BD = W - 2*T, D - 2*T
    lid_w  = LID_W                      # transition + both lid folds run the FULL blank width
    ffl    = LID_FRONT_FL
    tabs = {}
    # Base, listed in the only fold order that is buildable on a brake: the
    # transition while the blank is still flat, then the two long walls, then the
    # sides last (their punch has to fit between the standing front and rear walls,
    # which the Ø6 corner reliefs open up to 413 mm).
    tabs["segno_base"] = [
        (1, "trasera -> transición", "y", BD + HR_FLAT, lid_w, 90.0 - TRANS_ANGLE, UP_TOWARD, RI, DD_TR),
        (2, "pared frontal",         "y", 0.0,          BW,    90.0,               UP_TOWARD, RI, DEV90),
        (3, "pared trasera",         "y", BD,           BW,    90.0,               UP_TOWARD, RI, DEV90),
        (4, "pared izquierda",       "x", 0.0,          BD,    90.0,               UP_TOWARD, RI, DEV90),
        (5, "pared derecha",         "x", BW,           BD,    90.0,               UP_TOWARD, RI, DEV90),
    ]
    tabs["segno_faceplate"] = [
        (1, "pestaña frontal", "y", ffl,        lid_w, 90.0 - SLOPE_ANGLE,        DN_AWAY, RI, DD_LIP),
        (2, "solapa trasera",  "y", ffl + FP_V, lid_w, SLOPE_ANGLE + TRANS_ANGLE, DN_AWAY, RI, DD_LAP),
    ]
    tabs["segno_corner_bracket_rear"] = [
        (1, "ala / ala", "x", CORNER_LEG, CORNER_HT, 90.0, UP_TOWARD, RI, DEV90),
    ]
    tabs["segno_post"] = [
        (1, "apoyo -> alma", "y", POST_PAD,          POST_PW, 90.0 + POST_TILT, UP_TOWARD, POST_T, 0.0),
        (2, "alma -> pie",   "y", POST_PAD + POST_H, POST_PW, 90.0,             UP_TOWARD, POST_T, 0.0),
    ]
    return tabs

BEND_TABLES = _bend_tables()

# Per-part footnote printed under the bend table. The post is the odd one out: its
# flat is nominal segments with NO deduction applied, which is worth saying out
# loud on the sheet rather than leaving a fabricator to assume it was developed.
BEND_FOOTNOTES = {
    "segno_base": (f"Factor K {KF} | desarrollo del plegado = rad(rotación) x (Ri + K x T) | pestaña plana = longitud exterior - deducción. "
                   f"LAS FILAS ESTÁN EN ORDEN DE PLEGADO - no reordenar. Los laterales (4, 5) necesitan un punzón <= 410 mm: los "
                   f"4 alivios de esquina de Ø 6.0 abren 413 mm entre las paredes frontal y trasera ya levantadas. Referenciar los "
                   f"plegados 4 y 5 contra las caras ya formadas de las paredes frontal/trasera (la pestaña lateral es una cuña y no "
                   f"queda escuadra con su plegado). Matriz V12 en todos los plegados; el Ri {RI:.1f} mm es obligatorio - si aparecen "
                   f"fisuras en el sentido del laminado PARAR, no abrir el radio: hay que volver a desarrollar el plano."),
    "segno_faceplate": (f"Factor K {KF} | desarrollo del plegado = rad(rotación) x (Ri + K x T) | pestaña plana = longitud exterior - deducción. "
                        f"El plegado de la pestaña frontal cruza las aberturas de los pedales (quedan 12.1 mm de material): matriz V12, "
                        f"punzón segmentado, prever enderezado."),
    "segno_corner_bracket_rear": (f"Factor K {KF} | pestaña plana = longitud exterior - deducción. CANT. 2, y la segunda se monta DADA "
                                  f"VUELTA - la pieza es casi simétrica, sólo el patrón de agujeros es de mano."),
    "segno_post": (f"ACERO LAMINADO EN FRÍO de 1.6 mm, no el aluminio de 2.0 mm del gabinete. Ri {POST_T:.1f} mm (1.0 x T). "
                   f"DEDUCCIÓN NO APLICADA - el desarrollo son segmentos nominales (PROVISORIO): verificar la longitud desarrollada "
                   f"contra el herramental propio antes de cortar."),
}

def _bend_table_lines(stem):
    """The bend table as rendered text rows, header first. Empty for a flat part."""
    rows = BEND_TABLES.get(stem, ())
    if not rows:
        return []
    # Column widths carry the Spanish, which is longer than the English they
    # replaced: "ABAJO, opuesto a la cara dibujada" is 33 characters where
    # "DOWN, away from drawn face" was 26, and at the old width 28 the fold
    # direction ran straight over the Ri column.
    cols = ((" #", 4), ("LÍNEA DE PLEGADO", 24), ("POSICIÓN", 14), ("LONGITUD", 10),
            ("ROTACIÓN", 13), ("INCLUIDO", 13), ("SENTIDO", 36), ("Ri", 10),
            ("DEDUCCIÓN", 0))
    def row(cells):
        return "".join(c if wdt == 0 else c.ljust(wdt) for c, (_h, wdt) in zip(cells, cols))
    out = ["TABLA DE PLEGADOS   ( rotación = ángulo que gira la pestaña DESDE el plano;   incluido = 180 - rotación )",
           row([h for h, _w in cols])]
    for seq, name, axis, pos, ln, rot, direction, ri, ded in rows:
        out.append(row([f" {seq}", name, f"{axis} = {pos:8.2f}", f"{ln:8.1f}",
                        f"{rot:8.3f}°", f"{180.0-rot:8.3f}°", direction,
                        f"{ri:.1f} mm", f"{ded:.3f} mm" if ded else "sin deducción (nominal)"]))
    return out

# ===========================================================================
# PDF drawing sheets
# ===========================================================================

def _force_pdf_layer_colours(doc):
    """Make every through-cut layer render BLACK and prove nothing else renders white.

    ezdxf's matplotlib backend maps ACI 7 to white on a white sheet. `CUT` was
    forced black here by hand; `VENT` -- 127 louvres, 18 425 mm2, ~5.6 m of cut
    path -- was not, so it was invisible on every PDF ever generated (#775 R1).
    Returns the layers it touched; the assert below is the actual gate."""
    blackened = []
    for lname in THRU_CUT_LAYERS:
        if doc.layers.has_entry(lname):
            doc.layers.get(lname).rgb = (0, 0, 0)
            blackened.append(lname)
    if doc.layers.has_entry("MASK"):
        doc.layers.get("MASK").rgb = (220, 30, 30)
    used = {e.dxf.layer for e in doc.modelspace()}
    for lname in sorted(used):
        assert lname in THRU_CUT_LAYERS + ANNOT_LAYERS, \
            f"layer {lname!r} carries geometry but is neither a declared through-cut nor annotation layer"
        lay = doc.layers.get(lname)
        if lname in THRU_CUT_LAYERS:
            assert lay.rgb == (0, 0, 0), f"through-cut layer {lname!r} would not render black"
        else:
            assert lay.rgb is not None or lay.color != 7, \
                f"layer {lname!r} is ACI 7 -- it renders white on a white sheet and vanishes"
    # Same trap one level down: an ENTITY may carry its own ACI 7 and vanish on a
    # layer that is itself fine. Only the through-cut layers are forced black
    # above, so an explicit 7 anywhere else is the invisible case.
    for e in doc.modelspace():
        if e.dxf.layer in THRU_CUT_LAYERS:
            continue
        assert e.dxf.hasattr("color") is False or e.dxf.color != 7, \
            f"{e.dxftype()} on layer {e.dxf.layer!r} carries ACI 7 -- it renders " \
            f"white on a white sheet and vanishes from the PDF"
    return blackened

SHEET_HEADING = "Segno - gabinete de controlador de audio"

# Every human-readable line each sheet actually carried, keyed by stem, recorded
# as the sheet is drawn. matplotlib PDFs subset their fonts, so there is no
# in-process way to read the text back out of the file -- this registry is what
# _verify_drawing_package() holds the Spanish and the tolerance block against.
SHEET_TEXT = {}

def dxf_to_pdf(dxf_path, pdf_path, title, material, qty, stem=None, legend=None):
    """One drawing sheet: the flat pattern, a bend table, a title block and a legend.

    `material` and `qty` are REQUIRED, deliberately: they used to default to
    "2.0 mm 5052-H32 Al" / 1 and the single call site passed neither, so the 1.6 mm
    steel post (x2) and the vinyl overlay both shipped sheets calling for 2 mm
    aluminium, qty 1 (#775 R5/R6). `legend` defaults to SHEET_LEGEND; the 2-ply
    tile sheet passes TILE_LEGEND so ENGRAVE is not described as annotation."""
    import textwrap
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import ezdxf
    from ezdxf.addons.drawing import RenderContext, Frontend
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
    from ezdxf.bbox import extents
    doc = ezdxf.readfile(dxf_path)
    _force_pdf_layer_colours(doc)
    msp = doc.modelspace()
    stem = stem if stem is not None else os.path.splitext(os.path.basename(dxf_path))[0]

    fig = plt.figure(figsize=(16, 10))
    ax = fig.add_axes([0.04, 0.10, 0.92, 0.86]); ax.set_axis_off()
    # NB the matplotlib backend RESIZES the figure to the data aspect in finalize(),
    # so nothing below may assume the 16x10 above -- read the size back instead.
    Frontend(RenderContext(doc), MatplotlibBackend(ax)).draw_layout(msp, finalize=True)
    ax.set_aspect("equal")
    bb = extents(e for e in msp if e.dxf.layer not in ("NOTE", "ENGRAVE", "ACRYLIC", "MASK"))
    if bb.has_data:
        x0, y0, _ = bb.extmin; x1, y1, _ = bb.extmax
        ax.annotate(f"{x1-x0:.1f}", ((x0+x1)/2, y0), ha="center", va="top", fontsize=11, color="#0a4")
        ax.annotate(f"{y1-y0:.1f}", (x0, (y0+y1)/2), ha="right", va="center", rotation=90, fontsize=11, color="#0a4")

    # ---- bottom strip: bend table, then the title block + legend ---------------
    # Everything here is sized against the FINISHED page width: the sheets are
    # auto-fitted to their part, so a fixed point size that suits the 1040 mm base
    # runs straight off the edge of the 402 mm rear panel (which is how the post
    # sheet ended up with its title block printed over its own heading).
    w, h = fig.get_size_inches()
    usable_pt = w * 72.0 * 0.94
    mono_cols = lambda fs: max(40, int(usable_pt / (0.602 * fs)))
    fit_fs    = lambda text, want, ratio=0.55: min(want, usable_pt / (ratio * max(len(text), 1)))

    table = _bend_table_lines(stem)
    foot  = BEND_FOOTNOTES.get(stem, "")
    ROW, FS = 0.20, 7.4                      # inches per row / point size
    # The Spanish table rows are ~10 characters wider than the English ones were,
    # and the sheets are auto-fitted to their part -- so size the table to the page
    # instead of trusting a fixed 7.4 pt to keep fitting.
    tbl_fs = min(FS, usable_pt / (0.602 * max((len(ln) for ln in table), default=1)))
    block = [(ln, tbl_fs, True) for ln in table]
    if foot:
        block += [("", tbl_fs, False)]
        block += [(ln, tbl_fs - 0.9, False) for ln in textwrap.wrap(foot, mono_cols(tbl_fs - 0.9))]
    # The tolerance block sits in the right-hand third beside the title block, so
    # the legend gets the left ~58% and wraps there rather than running under it.
    tol = _tolerance_lines() if PART_SPECS.get(stem, (None, None, None))[2] == PKG_SHEETMETAL else []
    legend_src = SHEET_LEGEND if legend is None else legend
    legend = textwrap.wrap(legend_src,
                           max(40, int(mono_cols(FS) * (0.58 if tol else 1.0)))) or [legend_src]

    # the bend spec is PER PART -- the post is 1.6 mm steel on Ri 1.6, and a flat
    # part has no radius at all. A blanket "bend Ri 2.0" was wrong on both.
    radii = sorted({r[7] for r in BEND_TABLES.get(stem, ())})
    bend_spec = ("   |   PIEZA PLANA, sin plegados" if not radii else
                 "   |   plegado Ri " + " / ".join(f"{r:.1f}" for r in radii) + f" mm, factor K {KF}")
    tb = f"{title}   |   {material}   |   CANT. {qty}   |   medidas en mm{bend_spec}"

    legend_h = 0.155 * max(len(legend), len(tol))
    strip = 0.62 + legend_h + (ROW * len(block) + 0.30 if block else 0.0)
    pos  = ax.get_position()
    y0_in, h_in = pos.y0 * h, pos.height * h
    newh = h + strip                          # grow the PAGE, never shrink the drawing
    fig.set_size_inches(w, newh, forward=True)
    ax.set_position([pos.x0, (y0_in + strip) / newh, pos.width, h_in / newh])
    fy = lambda inches: inches / newh
    y = strip - 0.22
    for i, (line, fs, bold) in enumerate(block):
        fig.text(0.03, fy(y), line, family="monospace", fontsize=fs,
                 weight="bold" if i < 2 and bold else "normal",
                 color="#000" if bold else "#333")
        y -= ROW
    # With a tolerance block on the right, the heading and the title-block line get
    # the left 58% of the page and are sized to it -- at full width the title block
    # ran straight under the tolerance rows.
    # 0.62, not the 0.55 fit_fs uses: these two lines are BOLD, and the Spanish
    # title block is long enough that the optimistic ratio walked it off the right
    # edge of the narrow overlay sheet.
    room = 0.58 if tol else 1.0
    bold_fs = lambda text, want: min(want, usable_pt * room / (0.62 * max(len(text), 1)))
    fig.text(0.03, fy(legend_h + 0.40), SHEET_HEADING,
             fontsize=bold_fs(SHEET_HEADING, 12.0), weight="bold")
    fig.text(0.03, fy(legend_h + 0.18), tb, fontsize=bold_fs(tb, 10.0),
             weight="bold", color="#000")
    for i, line in enumerate(legend):
        fig.text(0.03, fy(legend_h - 0.115 - 0.155 * i), line,
                 family="monospace", fontsize=FS, color="#333")
    # ---- tolerance block, right of the title block (issue #778) --------------
    # Sized to the right-hand third of the FINISHED page, same reason the title
    # block is: a fixed point size that fits the 1152 pt base sheet walks off the
    # edge of a narrower one.
    if tol:
        tol_fs = min(FS, (0.33 * w * 72.0) / (0.602 * max(len(t) for t in tol)))
        for i, line in enumerate(tol):
            fig.text(0.635, fy(legend_h + 0.40 - 0.155 * i), line, family="monospace",
                     fontsize=tol_fs, weight="bold" if i == 0 else "normal",
                     color="#000" if i == 0 else "#333")
    SHEET_TEXT[stem] = ([ln for ln, _f, _b in block] + [SHEET_HEADING, tb]
                        + list(legend) + list(tol))
    fig.savefig(pdf_path, dpi=150); plt.close(fig)

# ===========================================================================
# PAINT QUOTE PACK  (issue #396)
# ---------------------------------------------------------------------------
# Powder coaters quote by m^2, so the one number they cannot work without is the
# painted surface -- and nobody can eyeball it off a flat pattern riddled with
# pedal slots and screen apertures. Everything here is DERIVED (areas from the
# CUT layer of the generated DXFs, sizes from the STEPs) so the sheet cannot go
# stale the way a hand-typed parts table does.
# ===========================================================================

AL_2MM = "Aluminio 5052-H32 2,0 mm"
ST_16  = "Acero laminado en frío 1,6 mm"

PAINT_FINISH = "Negro texturado mate (RAL 9005) - a confirmar contra cupón de muestra"

# dxf stem, label (ES), qty per unit, material, remark (ES).
# segno_overlay is a printed adhesive graphic, NOT metal -- it is never painted.
# There is no screen bracket part: the screens are bonded to the shell. The
# bracket fallback was deleted outright in the #760 audit (user call 2026-08-18).
PAINT_BOM = [
    ("segno_base",               "Cuerpo: piso + frente + laterales + trasera", 1, AL_2MM, "Pieza más grande"),
    ("segno_faceplate",          "Tapa superior",                               1, AL_2MM, "Cara vista principal"),
    ("segno_corner_bracket_rear","Ángulo de esquina trasera",                   2, AL_2MM, "Interno"),
    ("segno_ring_disc",          "Disco central del aro de LEDs",               1, AL_2MM, "Interno"),
    ("segno_post",               "Poste de apoyo de la tapa",                   2, ST_16,  "ACERO: otro pretratamiento"),
]

def _poly_area(pts):
    a = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i][0], pts[i][1]
        x1, y1 = pts[(i + 1) % len(pts)][0], pts[(i + 1) % len(pts)][1]
        a += x0 * y1 - x1 * y0
    return abs(a) / 2.0

def _flat_area_mm2(dxf_path):
    """Net area of one face of the flat blank: the outer contour minus every
    aperture inside it. Cut-outs live on CUT and VENT; bulges are ignored, which
    costs a rounding error on fillets and nothing on the total."""
    import ezdxf
    msp = ezdxf.readfile(dxf_path).modelspace()
    areas = []
    for e in msp:
        if e.dxf.layer not in ("CUT", "VENT"):
            continue
        if e.dxftype() == "LWPOLYLINE":
            pts = [(p[0], p[1]) for p in e.get_points()]
            if len(pts) >= 3:
                areas.append(_poly_area(pts))
        elif e.dxftype() == "CIRCLE":
            areas.append(math.pi * e.dxf.radius ** 2)
    if not areas:
        return 0.0
    areas.sort(reverse=True)
    return max(0.0, areas[0] - sum(areas[1:]))

def _step_size(stem):
    """Folded bounding box (mm) of the modelled part, or None when there is no
    STEP for it. Sorted big-to-small: orientation in the file is not meaningful
    to a coater, only whether it fits the oven."""
    p = os.path.join(OUT, stem + ".step")
    if not os.path.exists(p):
        return None
    try:
        import cadquery as cq
        bb = cq.importers.importStep(p).val().BoundingBox()
        return tuple(sorted((bb.xlen, bb.ylen, bb.zlen), reverse=True))
    except Exception:  # pragma: no cover - STEP is optional for this sheet
        return None

def _paint_rows():
    rows, tot = [], {}
    for stem, label, qty, mat, remark in PAINT_BOM:
        dxf = os.path.join(OUT, stem + ".dxf")
        if not os.path.exists(dxf):
            continue
        one = _flat_area_mm2(dxf) / 1e6           # m^2, one face
        total = one * 2 * qty                      # both faces get coated
        size = _step_size(stem)
        rows.append({"label": label, "qty": qty, "mat": mat, "remark": remark,
                     "size": size, "one": one, "total": total})
        tot[mat] = tot.get(mat, 0.0) + total
    return rows, tot

def _draw_dxf(ax, dxf_path):
    """Render a flat pattern into an axes: cuts black, masking rings red."""
    import ezdxf
    from ezdxf.addons.drawing import RenderContext, Frontend
    from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
    doc = ezdxf.readfile(dxf_path)
    _force_pdf_layer_colours(doc)          # VENT black too, not just CUT (#775 R1)
    ax.set_axis_off()
    Frontend(RenderContext(doc), MatplotlibBackend(ax)).draw_layout(doc.modelspace(), finalize=True)
    ax.set_aspect("equal")

def paint_quote_pdf(path):
    """Supplier-facing sheet (Spanish) for the powder-coating quote: parts table
    with painted area, then a masking page per part that has bare-metal zones."""
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.backends.backend_pdf import PdfPages
    rows, tot = _paint_rows()
    grand = sum(tot.values())
    mono = {"family": "monospace", "fontsize": 8.6}

    with PdfPages(path) as pdf:
        # ---- page 1: what has to be painted -------------------------------
        fig = plt.figure(figsize=(11.7, 8.3))   # A4 landscape
        fig.text(0.06, 0.995, SHEET_HEADING, va="top",
                 fontsize=17, weight="bold")
        fig.text(0.06, 0.945, "Pedido de cotización: pintura en polvo (termolaqueado)",
                 va="top", fontsize=12, color="#444")
        y = 0.885
        for k, v in (("Envolvente del equipo armado",
                      f"{W:.0f} x {D:.0f} x {H_REAR:.0f} mm (lo que tiene que entrar al horno)"),
                     ("Material del cuerpo", "Aluminio 5052-H32 de 2,0 mm (chapa cortada por láser)"),
                     ("Terminación pedida", PAINT_FINISH),
                     ("Superficie total a pintar", f"{grand:.2f} m2 por equipo (ambas caras, sin contar cantos)"),
                     ("Cantidad", "1 unidad prototipo; después por lotes")):
            fig.text(0.06, y, k, fontsize=9.5, color="#666")
            fig.text(0.30, y, v, fontsize=10.5, weight="bold")
            y -= 0.042

        hdr = (f"{'Pieza':<42}{'CANT.':>6}{'Material':>31}{'Tamaño (mm)':>20}"
               f"{'1 cara m2':>11}{'Total m2':>10}")
        y -= 0.030
        fig.text(0.06, y, hdr, **mono, weight="bold")
        y -= 0.012
        fig.text(0.06, y, "-" * len(hdr), **mono, color="#999")
        for r in rows:
            y -= 0.030
            sz = ("%.0f x %.0f x %.0f" % r["size"]) if r["size"] else "-"
            fig.text(0.06, y, f"{r['label']:<42}{r['qty']:>6}{r['mat']:>31}"
                              f"{sz:>20}{r['one']:>11.4f}{r['total']:>10.4f}", **mono)
            y -= 0.018
            fig.text(0.075, y, r["remark"], fontsize=7.6, color="#777", style="italic")
        y -= 0.030
        fig.text(0.06, y, "-" * len(hdr), **mono, color="#999")
        for mat, m2 in sorted(tot.items()):
            y -= 0.030
            fig.text(0.06, y, f"{'Subtotal ' + mat:<110}{m2:>10.4f}", **mono, weight="bold")
        y -= 0.032
        fig.text(0.06, y, f"{'TOTAL por equipo':<110}{grand:>10.4f}",
                 **mono, weight="bold", color="#0a4")

        notes = [
            "Notas para el aplicador:",
            "  1. La superficie es NETA: contorno exterior menos aberturas (ranuras de pedales, pantallas, ranuras de ventilación). No incluye cantos.",
            "  2. Las piezas llegan cortadas y plegadas, sin ningún recubrimiento ni aceite protector. Pretratamiento para aluminio a cargo del aplicador.",
            "  3. Los postes son ACERO laminado en frío, no aluminio: van en línea aparte porque llevan otro pretratamiento.",
            "  4. Enmascarado: ver las páginas siguientes. Sólo la zona de puesta a tierra alrededor del perno M6 va sin pintura, en ambas caras (los agujeros piloto se roscan M3 después de pintar).",
            "  5. Las aberturas de pantalla son ajustadas: la película come décimas por cara. Si el espesor supera 100 um avisar antes de aplicar.",
            "  6. El aluminio es blando: colgar para pintar, no apoyar sobre las caras vistas.",
            "  7. La tapa figura con su tamaño en DESARROLLO (850 x 407 x 2): plegada suma la pestaña frontal de 12 mm y la solapa trasera.",
        ]
        # anchored, not flowed: the table above grows with the BOM and the notes
        # must not walk off the bottom of the sheet when it does
        y = 0.150
        for i, n in enumerate(notes):
            fig.text(0.06, y, n, fontsize=8.2, color="#222" if i == 0 else "#444",
                     weight="bold" if i == 0 else "normal")
            y -= 0.0195
        pdf.savefig(fig); plt.close(fig)

        # ---- masking / detail pages ---------------------------------------
        sheets = [
            ("segno_base", "CUERPO - plano de enmascarado",
             "Rojo = NO PINTAR. Zona de puesta a tierra de 20 mm alrededor del perno M6, en "
             "ambas caras. Los agujeros piloto de la transición se roscan M3 después de pintar."),
            ("segno_faceplate", "TAPA SUPERIOR - aberturas críticas",
             "Sin enmascarado. Las dos aberturas grandes son de pantalla y quedan ajustadas "
             "contra el display: contemplar el espesor de película."),
        ]
        for stem, title, note in sheets:
            dxf = os.path.join(OUT, stem + ".dxf")
            if not os.path.exists(dxf):
                continue
            fig = plt.figure(figsize=(11.7, 8.3))
            ax = fig.add_axes([0.04, 0.12, 0.92, 0.80])
            _draw_dxf(ax, dxf)
            fig.text(0.04, 0.965, title, fontsize=14, weight="bold")
            fig.text(0.04, 0.055, note, fontsize=9.5, color="#b00")
            fig.text(0.04, 0.025, f"{SHEET_HEADING}   |   medidas en mm   |   "
                                  "desarrollo / patrón plano (la pieza se entrega plegada)",
                     fontsize=8, color="#555")
            pdf.savefig(fig); plt.close(fig)
    return path

# ===========================================================================
# REPORT
# ===========================================================================

def report():
    cuts, _ = faceplate_holes()
    L = []; P = L.append
    P("="*68)
    P("Segno sheet-metal enclosure — manufacturing package")
    P("="*68)
    P(f"Envelope        : {W:.0f} W x {D:.0f} D x {H_REAR:.0f} H mm (front lip {H_FRONT:.0f})")
    P(f"Top slope       : {SLOPE_ANGLE:.2f}deg, sloped length {L_SLOPE:.1f} mm")
    P(f"Material        : {T:.1f} mm 5052-H32 Al, bend R {RI:.1f}, K={KF}, BA90 {BA90:.2f}")
    P(f"Construction    : folded weld-free lower body + REMOVABLE TOP LID (faceplate carries")
    P(f"                  screens + encoder/ring PCB + LEDs; pedals stay on platforms)")
    P("-"*68)
    n1 = sum(1 for _, _, v in PEDALS if v == PEDAL_ROW1_V)
    P(f"Foot pedals     : {len(PEDALS)}x Cherub WTB-006 ({PEDAL_W:.1f}x{PEDAL_D:.1f}x{PEDAL_H:.1f}mm incl. pads, toe-forward)")
    P(f"  layout        : {n1} front row + {len(PEDALS)-n1} centre (CLEAR/BANK), LEDs aligned above")
    P(f"  slot          : {FSW_SLOT_W:.0f}(u) x {FSW_SLOT_D:.0f}(v) mm  [PROVISIONAL]")
    P(f"  platform H    : front {platform_h(PEDAL_ROW1_V):.1f} / mid {platform_h(PEDAL_ROW2_V):.1f} mm "
      f"(case top flush with the slot's upper rim, pad +{PEDAL_PAD_T:.1f} above, #373)  [PROVISIONAL]")
    P(f"Screens         : 7in {SMALL_W:.0f}x{SMALL_H:.0f} (left) | 15.6in {BIG_W:.0f}x{BIG_H:.0f} (right), tops aligned, from behind")
    P(f"Rear I/O        : USB-C PD + btn + fuse + 2x MIDI DIN-5 + 2x TRS (D-series) + 2x USB3 + vents + earth (no window)")
    _unc = rear_io_unconfirmed()
    if _unc:
        P("  DO NOT CUT     : " + ", ".join(
            f"{k}={'not cut' if v is None else format(v, 'g')}"
            for k, v in sorted(_unc.items())) + "  <- unconfirmed, no source")
    _bwv = W - 2*T
    _sv = side_vents('R', _bwv) + side_vents('L', _bwv)
    _sv_area = sum(c["w"] * c["h"] for c in _sv)
    P(f"Ventilation     : free area {_vent_free_area(rear_holes())+_vent_free_area(_bottom_vents())+_sv_area*FOAM_OPEN_FRACTION:.0f} mm^2 (>= {VENT_FREE_AREA_MIN:.0f}), standoff {STANDOFF_H:.0f}mm")
    P(f"  side louvres  : {len(_sv)} slots ({_sv_area:.0f} mm^2 geometric, counted at "
      f"{FOAM_OPEN_FRACTION:.0%} through foam), v {SIDE_VENT_V[0]:.0f}..{SIDE_VENT_V[1]:.0f}")
    P(f"  FOAM REQUIRED : open-cell filter foam on the INSIDE face of both side "
      f"louvre blocks -- they look straight into the loom otherwise")
    P("-"*68)
    P(f"Faceplate cutouts : {len(cuts)}  |  rear-wall cutouts : {len(rear_holes())}")
    area = (W*D + W*L_SLOPE + W*REAR_WALL_H + W*H_FRONT) + 2*(D*(H_FRONT+H_REAR)/2)
    for mat, rho in (("5052 Al", 2.70), ("mild steel", 7.85)):
        P(f"Bare weight     : {area*T*rho/1e6:4.1f} kg  ({mat}, {T:.1f} mm, {area/1e6:.2f} m2)")
    P("="*68)
    return "\n".join(L)

# ===========================================================================
# ANNOTATED LAYOUT SVG  (player view, generated from the schedule)
# ===========================================================================

def layout_svg(path):
    """Draw the faceplate + rear panel in player view (u left->right, front at the
    bottom), straight from faceplate_holes()/rear_holes() so it never drifts. Mirrored
    to match the baked-in canonical orientation (7" on the player's left)."""
    cuts, engr = faceplate_holes()
    M, GAP, fw, fh = 44, 64, FP_W, FP_V
    rear_base = M + fh + GAP + 24
    Wv, Hv = fw + 2*M, rear_base + REAR_WALL_H + 70
    X = lambda u: M + u
    Yf = lambda v: M + (fh - v)            # faceplate: front (low v) at bottom
    Yr = lambda z: rear_base + (REAR_WALL_H - z)
    e = [f'<svg viewBox="0 0 {Wv:.0f} {Hv:.0f}" xmlns="http://www.w3.org/2000/svg" '
         'font-family="Helvetica,Arial,sans-serif">',
         f'<rect width="{Wv:.0f}" height="{Hv:.0f}" fill="#0f1623"/>',
         f'<text x="{M}" y="{M-12}" fill="#94a3b8" font-size="12" font-weight="600">'
         f'Segno TOP FACEPLATE — player view · {W:.0f} x {D:.0f} x {H_REAR:.0f} mm · '
         f'folded shell · slope {SLOPE_ANGLE:.1f}deg</text>',
         f'<rect x="{M}" y="{M}" width="{fw:.1f}" height="{fh:.1f}" rx="9" '
         'fill="#131c2c" stroke="#5b6b86" stroke-width="2"/>']
    for c in cuts:
        ref = c["ref"]
        if c["kind"] == "rect":
            x, y, w, h = X(c["u"]), Yf(c["v"] + c["h"]), c["w"], c["h"]
            if ref.startswith("SCREEN"):
                lbl = '16" TOUCH - main UI' if "16" in ref else '7" TOUCH - waveform'
                e.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="5" fill="#0c1a24" stroke="#38bdf8" stroke-width="2"/>')
                e.append(f'<text x="{x+w/2:.1f}" y="{y+h/2:.1f}" fill="#4a7f96" font-size="12" text-anchor="middle">{lbl}</text>')
            else:
                fill = "#243149" if ref.startswith("TRACK") else "#1c2740"
                e.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="3" fill="{fill}" stroke="#8aa0c0" stroke-width="1.4"/>')
        elif c["kind"] == "circle":
            r = max(c["d"]/2, 2.0)
            col = ("#22c55e" if ref.endswith("_LED") or ref == "PWR_LED" else
                   "#f59e0b" if ref == "MODE_LED" else
                   "#cbd5e1" if ref == "ENCODER" else "#8aa0c0")
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yf(c["v"]):.1f}" r="{r:.1f}" fill="{col}"/>')
        elif c["kind"] == "ring":
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yf(c["v"]):.1f}" r="{c["od"]/2:.1f}" fill="none" stroke="#a855f7" stroke-width="3"/>')
    for lab in engr:
        k = lab.get("kind")
        if k == "disc":                       # symbol legends (see _silk_symbol_geometry)
            e.append(f'<circle cx="{X(lab["u"]):.1f}" cy="{Yf(lab["v"]):.1f}" r="{lab["d"]/2:.1f}" fill="#9fb0c8"/>')
        elif k == "poly":
            pts = " ".join(f'{X(px):.1f},{Yf(pv):.1f}' for px, pv in lab["pts"])
            e.append(f'<polygon points="{pts}" fill="#9fb0c8"/>')
        else:
            e.append(f'<text x="{X(lab["u"]+16):.1f}" y="{Yf(lab["v"])+10:.1f}" fill="#9fb0c8" font-size="8" text-anchor="middle">{lab["s"]}</text>')
    # rear panel
    e.append(f'<text x="{M}" y="{rear_base-12:.1f}" fill="#94a3b8" font-size="12" font-weight="600">REAR I/O PANEL — {W:.0f} x {REAR_WALL_H:.0f} mm (lowered; transition shoulder carries the lid-lap screws)</text>')
    e.append(f'<rect x="{M}" y="{rear_base:.1f}" width="{fw:.1f}" height="{REAR_WALL_H:.1f}" rx="6" fill="#131c2c" stroke="#5b6b86" stroke-width="2"/>')
    for c in rear_holes():
        if c.get("layer") == "VENT":
            e.append(f'<rect x="{X(c["u"]):.1f}" y="{Yr(c["v"]+c["h"]):.1f}" width="{c["w"]:.1f}" height="{c["h"]:.1f}" fill="none" stroke="#7c8aa3" stroke-width="1"/>')
        elif c["kind"] == "circle":
            rcol = "#22c55e" if c["ref"] == "EARTH_STUD" else "#cbd5e1"
            e.append(f'<circle cx="{X(c["u"]):.1f}" cy="{Yr(c["v"]):.1f}" r="{max(c["d"]/2,3):.1f}" fill="#0f1623" stroke="{rcol}" stroke-width="1.5"/>')
        elif c["kind"] == "rect":
            e.append(f'<rect x="{X(c["u"]):.1f}" y="{Yr(c["v"]+c["h"]):.1f}" width="{c["w"]:.1f}" height="{c["h"]:.1f}" fill="#0f1623" stroke="#cbd5e1" stroke-width="1.3"/>')
    fy = rear_base + REAR_WALL_H + 28
    e.append(f'<text x="{M}" y="{fy:.1f}" fill="#7c8aa3" font-size="10.5">USB-C PD · power · fuse · USB-A x2 · earth stud · vents   |   service: back out the front-lip + rear-lap screws, lift the lid (side wings just locate)</text>')
    e.append(f'<text x="{M}" y="{fy+18:.1f}" fill="#7c8aa3" font-size="10.5">10x Cherub WTB-006 pedals on printed pedestals (PROVISIONAL) · 10 indicator LED pills (one per pedal) + encoder ring · Pi+board mount on the rear bottom plate</text>')
    e.append('</svg>')
    with open(path, "w") as f:
        f.write("\n".join(e) + "\n")
    return path

# ===========================================================================
# SHADED 3D RENDER  (VTK -- populated "all components" hero, optional)
# ===========================================================================

def _render_parts(cq, explode=0.0):
    """(shape, rgb) for the lower body + all representative components. Un-mirrored,
    matches the DXF. explode>0 lifts the LID parts (faceplate + screens + encoder/
    ring + LEDs) straight up while the pedals/platforms/body stay -- shows service."""
    fp_loc = (cq.Location(cq.Vector(0, (W - LID_W) / 2.0, H_FRONT + explode))
              * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), -SLOPE_ANGLE))
    on_fp = lambda wp: wp.val().moved(fp_loc)
    # brighter, more colourful palette (GLTF export darkens, so keep these light)
    ALU=(0.86,0.88,0.92); FACE=(0.40,0.45,0.55); PED=(0.34,0.35,0.40)
    PLAT=(0.55,0.57,0.62); STRIP=(0.92,0.40,0.62)
    P=[]; add=lambda s,c: P.append((s,c))
    add(cq.Workplane("XY").box(D-2*T, W-2*T, T, centered=False).translate((T,T,0)).val(), ALU)
    add(cq.Workplane("XY").box(T, W-2*T, H_FRONT, centered=False).translate((0,T,0)).val(), ALU)
    rl=(cq.Location(cq.Vector(D-T,T,0))*cq.Location(cq.Vector(0,0,0),cq.Vector(0,1,0),90)*cq.Location(cq.Vector(0,0,0),cq.Vector(0,0,1),90))
    add(_rear_flat(cq).val().moved(rl), ALU)
    side=cq.Workplane("XZ").polyline([(0,0),(D,0),(D,REAR_WALL_H),(FACE_RUN,H_REAR),(0,H_FRONT)]).close().extrude(-T)
    add(side.val(), ALU); add(side.val().moved(cq.Location(cq.Vector(0,W-T,0))), ALU)
    add(_transition_face(cq), (0.80,0.82,0.88))      # the angled transition shoulder (body)
    add(on_fp(_faceplate_flat(cq)), FACE)
    # lid folded faces (all lift with the lid): front lip + two side wings (inside the
    # side panels). The rear LAP (folded onto the transition) is placed separately below.
    add(on_fp(cq.Workplane("XY").box(T, LID_W, LID_FRONT_FL, centered=False)
              .translate((0, 0, -LID_FRONT_FL))), FACE)               # front lip (full width;
                                                                      # the lid has NO side wings)
    # rear lap: raked DOWN at the transition angle, resting on the shoulder (lifts with the lid)
    lap_loc = (cq.Location(cq.Vector(FACE_RUN, T, H_REAR + T + explode))
               * cq.Location(cq.Vector(0,0,0), cq.Vector(0,1,0), TRANS_ANGLE))
    add(cq.Workplane("XY").box(LID_REAR_LAP, LID_W, T, centered=False).val().moved(lap_loc), FACE)
    cuts,_=faceplate_holes()
    for label,u,v in PEDALS:
        ph=platform_h(v); add(_platform_printed(cq,ph,v).val().moved(cq.Location(cq.Vector(v,u+T,T))), PLAT)
        add(cq.Workplane("XY").box(PEDAL_D,PEDAL_W,PEDAL_H,centered=(True,True,False)).translate((v,u+T,ph)).val(), PED)
        # pink/magenta bumper strip across the foot-plate (reference accent)
        add(cq.Workplane("XY").box(16,PEDAL_W-8,2,centered=(True,True,False)).translate((v-PEDAL_D*0.22,u+T,ph+PEDAL_H)).val(), STRIP)
    for c in cuts:
        if c["kind"]=="rect" and c["ref"].startswith("SCREEN"):
            vm=c["v"]+c["h"]/2; um=c["u"]+c["w"]/2; tint=(0.18,0.62,0.55) if "7" in c["ref"] else (0.28,0.40,0.70)
            add(on_fp(cq.Workplane("XY").box(c["h"]-4,c["w"]-4,1.4).translate((vm,um,T+0.7))), tint)
        if c["kind"]=="circle" and c["ref"]=="ENCODER": add(on_fp(cq.Workplane("XY").circle(11).extrude(13).translate((c["v"],c["u"],T))),(0.18,0.18,0.22))
        if c["kind"]=="ring" and c["ref"]=="RING": add(on_fp(cq.Workplane("XY").circle(RING_OD/2).circle(RING_ID/2).extrude(2.2).translate((c["v"],c["u"],T))),(0.78,0.45,1.0))
        if c["kind"]=="circle" and (c["ref"].endswith("_LED") or c["ref"]=="PWR_LED"):
            col=(1.0,0.72,0.20) if c["ref"]=="MODE_LED" else (0.35,1.0,0.50)
            add(on_fp(cq.Workplane("XY").circle(max(c["d"]/2,2.7)).extrude(3.6).translate((c["v"],c["u"],T))), col)
    blk={"CONSOLE_BOARD":(BOARD_SIZE[0],BOARD_SIZE[1],16,(0.26,0.52,0.92))}
    for name,cx,cy,_ in board_mounts():
        bx,by,bz,col=blk[name]; add(cq.Workplane("XY").box(bx,by,bz,centered=(True,True,False)).translate((cy+T,cx+T,STANDOFF_H)).val(), col)
    # --- fasteners (show how it bolts together; visible from the underside) ----
    bw,bd=W-2*T,D-2*T; SCR=(0.70,0.71,0.76); FEET=(0.10,0.10,0.12); BRASS=(0.74,0.62,0.34)
    gx=lambda yd: yd+T; gy=lambda xw: xw+T          # bottom-plate (width,depth) -> global (X=depth,Y=width)
    perim=[(x,12) for x in (25,bw/2,bw-25)]+[(x,bd-12) for x in (25,bw/2,bw-25)]
    perim+=[(12,y) for y in (bd*0.33,bd*0.66)]+[(bw-12,y) for y in (bd*0.33,bd*0.66)]
    for x,y in perim:                               # M4 bottom-plate screw heads
        add(cq.Workplane("XY").circle(4).extrude(2.6).translate((gx(y),gy(x),-2.6)).val(), SCR)
    for x in (35,bw-35):                            # rubber feet at the corners
        for y in (35,bd-35):
            add(cq.Workplane("XY").circle(9).extrude(7).translate((gx(y),gy(x),-7)).val(), FEET)
    for name,cx,cy,(sx,sy) in board_mounts():       # M3 standoffs under Pi + board
        for dx in (-sx/2,sx/2):
            for dy in (-sy/2,sy/2):
                add(cq.Workplane("XY").circle(3).extrude(STANDOFF_H).translate((gx(cy+dy),gy(cx+dx),0)).val(), BRASS)
    # --- lid fixings: front lip -> Front panel (horizontal); rear lap -> transition (down)
    for u in FRONT_SCREW_U:                          # Front panel, into the lid front lip
        add(cq.Solid.makeCylinder(3.5,2.5,cq.Vector(0,u+T,H_FRONT-5),cq.Vector(-1,0,0)), SCR)
    nrm = cq.Vector(math.sin(math.radians(TRANS_ANGLE)),0,math.cos(math.radians(TRANS_ANGLE)))  # transition outward normal
    # screw station from the seam solver (distance down the facet from the ridge)
    lapx = FACE_RUN + D_SEAM_SCREW*math.cos(math.radians(TRANS_ANGLE))
    lapz = H_REAR - D_SEAM_SCREW*math.sin(math.radians(TRANS_ANGLE)) + T
    for u in FRONT_SCREW_U:                          # rear LAP screws down into the tapped transition:
                                                     # the SAME 9 stations the metal carries (#760) --
                                                     # the render used to draw 3 legacy fractional
                                                     # stations (0.18/0.5/0.82 of the width), so every
                                                     # render-based review saw a seam pattern the parts
                                                     # do not have (#767).
        add(cq.Solid.makeCylinder(3.3,2.8,cq.Vector(lapx,u+T,lapz),nrm), SCR)
    return P    # raw geometry (canonical layout is in the schedule); player view = camera choice

def render_png(path, direction=(-0.32, 0.05, 1.0), explode=0.0):
    """Shaded VTK hero of the populated enclosure (needs cadquery + vtk).
    explode>0 raises the removable lid to show how it comes apart."""
    import cadquery as cq, vtk, numpy as np
    ren=vtk.vtkRenderer(); ren.SetBackground(0.07,0.10,0.16); ren.SetBackground2(0.02,0.03,0.07); ren.GradientBackgroundOn()
    for s,rgb in _render_parts(cq, explode):
        m=vtk.vtkPolyDataMapper(); m.SetInputData(s.toVtkPolyData(0.4,0.25))
        a=vtk.vtkActor(); a.SetMapper(m); p=a.GetProperty()
        p.SetColor(*rgb); p.SetInterpolationToPhong(); p.SetSpecular(0.28); p.SetSpecularPower(28); p.SetDiffuse(0.95); p.SetAmbient(0.30)
        ren.AddActor(a)
    rw=vtk.vtkRenderWindow(); rw.SetOffScreenRendering(1); rw.AddRenderer(ren); rw.SetSize(1700,1150)
    ren.ResetCamera(); cam=ren.GetActiveCamera()
    dv=np.array(direction); dv=dv/np.linalg.norm(dv)
    cam.SetPosition(*(np.array(cam.GetFocalPoint())+dv*cam.GetDistance())); cam.SetViewUp(0,0,1)
    ren.ResetCameraClippingRange(); cam.Zoom(1.45)
    for pos,inten in [((-0.3,-0.8,1.0),1.05),((1.0,0.5,0.5),0.55),((0.2,1.0,0.3),0.45)]:
        l=vtk.vtkLight(); l.SetPosition(*pos); l.SetIntensity(inten); l.SetLightTypeToCameraLight(); ren.AddLight(l)
    rw.Render(); w2i=vtk.vtkWindowToImageFilter(); w2i.SetInput(rw); w2i.Update()
    wr=vtk.vtkPNGWriter(); wr.SetFileName(path); wr.SetInputConnection(w2i.GetOutputPort()); wr.Write()
    # No image flip: the canonical orientation is baked into the geometry (see _render_parts).
    return path

def dxf_ring_disc(path):
    """Metal centre disc that fills the inside of the diffused LED ring (the ring cutout removes a
    full RING_OD hole, so this centre is a separate piece). The EC11 encoder mounts through the
    centre hole and its nut clamps the disc; the knob sits on top. Cut from 2mm sheet."""
    doc = _doc(); msp = doc.modelspace()
    _circle(msp, 0, 0, RING_ID)                 # outline: OD = ring inner diameter
    _circle(msp, 0, 0, D_ENC)                   # encoder bush hole (centre)
    _text(msp, -RING_ID/2, RING_ID/2 + 6, 5, "Segno DISCO CENTRAL DEL ARO DE LEDS (segno_ring_disc)  chapa 2.0 mm  CANT. 1  PIEZA PLANA, sin plegados (queda sujeto por la tuerca del encoder; el agujero central es el paso del buje)", "NOTE")
    doc.saveas(path); return {}


def _emit_tile(msp, ox, oy, label):
    """One tile at (ox, oy): CUT trapezoid + ENGRAVE filled glyphs."""
    # Repeat the first point so viewers that ignore the closed flag still
    # draw the last side. The ezdxf matplotlib backend used to drop it, and
    # every tile's top-left corner vanished on the PDF (#946).
    outline = [(x + ox, y + oy) for x, y in _tile_outline()]
    _poly(msp, outline + [outline[0]], "CUT", closed=True)
    glyphs, _bb = _tile_ink(label)
    for e in glyphs:
        if e["kind"] == "disc":
            _circle(msp, e["u"] + ox, e["v"] + oy, e["d"], "ENGRAVE")
            _engrave_fill(msp, "circle", (e["u"] + ox, e["v"] + oy, e["d"] / 2.0))
        else:
            pts = [(x + ox, y + oy) for x, y in e["pts"]]
            holes = [[(x + ox, y + oy) for x, y in h] for h in e.get("holes") or []]
            _poly(msp, pts, "ENGRAVE")
            for hole in holes:
                _poly(msp, hole, "ENGRAVE")
            _engrave_fill(msp, "poly", pts, holes=holes)


def _tile_size_callout(msp, ox, oy):
    """NOTE-only: both widths, so the 0.6 mm taper cannot be missed on screen.

    The pad is a wedge in plan (#922). 54.36 vs 53.76 over 19.90 is 0.87° a side
    -- a viewer that only looks at the outline will swear the tile is a rectangle.
    """
    yb = oy + TILE_W / 2.0
    yt = oy - TILE_W / 2.0
    xb, xt = TILE_L_BACK / 2.0, TILE_L_TOE / 2.0
    gap = 2.4
    _poly(msp, [(ox - xb, yb + 0.5), (ox - xb, yb + gap),
                (ox + xb, yb + gap), (ox + xb, yb + 0.5)], "NOTE", closed=False)
    _text(msp, ox, yb + gap + 0.3, 1.8, f"{TILE_L_BACK:.2f}  (ancho)", "NOTE",
          halign="center")
    _poly(msp, [(ox - xt, yt - 0.5), (ox - xt, yt - gap),
                (ox + xt, yt - gap), (ox + xt, yt - 0.5)], "NOTE", closed=False)
    _text(msp, ox, yt - gap - 2.0, 1.8, f"{TILE_L_TOE:.2f}  (estrecho)", "NOTE",
          halign="center")
    _poly(msp, [(ox - xb - 0.5, yb), (ox - xb - gap, yb),
                (ox - xb - gap, yt), (ox - xb - 0.5, yt)], "NOTE", closed=False)
    _text(msp, ox - xb - gap - 6.5, oy - 0.9, 1.8, f"{TILE_W:.2f}", "NOTE")


def dxf_one_pedal_tile(path, label):
    """Single-tile DXF for a replacement cut. Origin at the tile centre."""
    doc = _doc(); msp = doc.modelspace()
    _emit_tile(msp, 0.0, 0.0, label)
    _tile_size_callout(msp, 0.0, 0.0)
    _text(msp, -TILE_L_BACK / 2.0, TILE_W / 2.0 + 6.5, 2.6,
          f"Segno {_tile_stem(label)}  CANT. 1  TRAPECIO "
          f"{TILE_L_BACK:.2f}/{TILE_L_TOE:.2f} x {TILE_W:.2f}  "
          f"plástico bicapa {TILE_PLY_T:.1f} mm "
          f"capa NEGRA / núcleo BLANCO; CUT = contorno; ENGRAVE = grabado relleno; "
          f"borde ANCHO hacia el cable", "NOTE")
    doc.saveas(path)
    return {}


def _tile_nest_origin(i):
    col, row = i % TILE_NEST_COLS, i // TILE_NEST_COLS
    return (TILE_L_BACK / 2.0 + col * (TILE_L_BACK + TILE_NEST_GAP),
            TILE_W / 2.0 + row * (TILE_W + TILE_NEST_GAP))


def dxf_pedal_tiles(path):
    """Nested sheet of all ten tiles -- the file the 2-ply shop cuts (#946).

    CUT is the trapezoid outline (through-cut). ENGRAVE is filled glyph geometry
    (raster/vector-engrave through the black cap). Glyphs are NEVER TEXT: the
    shop must not substitute a font. Wide edge toward the cable end.
    """
    doc = _doc(); msp = doc.modelspace()
    labels = [lab for lab, _u, _v in PEDALS]
    for i, label in enumerate(labels):
        ox, oy = _tile_nest_origin(i)
        _emit_tile(msp, ox, oy, label)
        _text(msp, ox - TILE_L_BACK / 2.0, oy - TILE_W / 2.0 - 3.2, 2.4, label, "NOTE")
    # One tile carries the size callout -- the 0.6 mm taper is invisible at nest
    # scale unless both widths are written next to the outline.
    _tile_size_callout(msp, *_tile_nest_origin(0))
    rows = (len(labels) + TILE_NEST_COLS - 1) // TILE_NEST_COLS
    _text(msp, 0.0, rows * (TILE_W + TILE_NEST_GAP) + 10.0, 4.0,
          f"Segno AZULEJOS DE PEDAL (segno_pedal_tiles)  CANT. {len(labels)}  "
          f"TRAPECIO {TILE_L_BACK:.2f} (ancho, cable) / {TILE_L_TOE:.2f} (estrecho, punta) "
          f"x {TILE_W:.2f}  "
          f"plástico bicapa de grabado de {TILE_PLY_T:.1f} mm "
          f"(capa NEGRA / núcleo BLANCO) - NO ES METAL; "
          f"CUT = corte pasante del trapecio; "
          f"ENGRAVE = grabado relleno (quema la capa, deja ver el blanco); "
          f"el borde ANCHO va hacia el cable y lleva la parte superior de los glifos; "
          f"medidas NOMINALES -- el 0,05 mm por lado ya está en la pieza, no agrandar; "
          f"el taller aplica compensación de kerf; "
          f"no sustituir fuente, los glifos ya son geometría", "NOTE")
    doc.saveas(path)
    return {}


def _draw_tile_on_ax(ax, ox, oy, label, cut="#b00", fill="#111"):
    """Closed trapezoid + filled glyphs. Used for the shop PDF so corners meet."""
    from matplotlib.patches import Circle, Polygon
    outline = [(x + ox, y + oy) for x, y in _tile_outline()]
    ax.add_patch(Polygon(outline, closed=True, fill=False, edgecolor=cut,
                         linewidth=0.6, joinstyle="miter", capstyle="projecting"))
    glyphs, _bb = _tile_ink(label)
    for e in glyphs:
        if e["kind"] == "disc":
            ax.add_patch(Circle((e["u"] + ox, e["v"] + oy), e["d"] / 2.0,
                                facecolor=fill, edgecolor="none"))
        else:
            ax.add_patch(Polygon([(x + ox, y + oy) for x, y in e["pts"]],
                                 closed=True, facecolor=fill, edgecolor="none"))
            for hole in e.get("holes") or []:
                ax.add_patch(Polygon([(x + ox, y + oy) for x, y in hole],
                                     closed=True, facecolor="white",
                                     edgecolor="none"))


def pdf_pedal_tiles(path):
    """1:1 shop PDF -- the file to send for 2-ply. Drawn from the same
    geometry as the DXF, not via the DXF renderer (which dropped a corner).

    Red outline = CUT. Black fill = ENGRAVE (burn the cap). White counters
    stay the cap. Scale is millimetres, print at 100 %.
    """
    import textwrap
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    labels = [lab for lab, _u, _v in PEDALS]
    cols, gap = TILE_NEST_COLS, TILE_NEST_GAP
    rows = (len(labels) + cols - 1) // cols
    nest_w = cols * TILE_L_BACK + (cols - 1) * gap
    nest_h = rows * TILE_W + (rows - 1) * gap
    note = (f"Segno AZULEJOS DE PEDAL (segno_pedal_tiles)  CANT. {len(labels)}  "
            f"TRAPECIO {TILE_L_BACK:.2f} (ancho, cable) / {TILE_L_TOE:.2f} "
            f"(estrecho, punta) x {TILE_W:.2f}  "
            f"plástico bicapa {TILE_PLY_T:.1f} mm capa NEGRA / núcleo BLANCO; "
            f"rojo = CUT; negro = ENGRAVE; borde ANCHO hacia el cable; "
            f"imprimir al 100 %; medidas en mm")
    margin, strip = 12.0, 22.0
    page_w = nest_w + 2 * margin
    page_h = nest_h + 2 * margin + strip
    fig = plt.figure(figsize=(page_w / 25.4, page_h / 25.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(-margin, nest_w + margin)
    ax.set_ylim(-margin - strip, nest_h + margin)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.patch.set_facecolor("white")
    for i, label in enumerate(labels):
        ox, oy = _tile_nest_origin(i)
        _draw_tile_on_ax(ax, ox, oy, label)
        ax.text(ox, oy - TILE_W / 2.0 - 2.6, label, fontsize=6, ha="center",
                va="top", color="#333")
    # Size callout on the first tile -- both widths, so the 0.6 mm taper reads.
    ox0, oy0 = _tile_nest_origin(0)
    ax.annotate("", xy=(ox0 - TILE_L_BACK / 2.0, oy0 + TILE_W / 2.0 + 1.6),
                xytext=(ox0 + TILE_L_BACK / 2.0, oy0 + TILE_W / 2.0 + 1.6),
                arrowprops=dict(arrowstyle="-", color="#333", lw=0.4))
    ax.text(ox0, oy0 + TILE_W / 2.0 + 2.0, f"{TILE_L_BACK:.2f} ancho",
            fontsize=5.5, ha="center", va="bottom", color="#333")
    ax.annotate("", xy=(ox0 - TILE_L_TOE / 2.0, oy0 - TILE_W / 2.0 - 1.6),
                xytext=(ox0 + TILE_L_TOE / 2.0, oy0 - TILE_W / 2.0 - 1.6),
                arrowprops=dict(arrowstyle="-", color="#333", lw=0.4))
    ax.text(ox0, oy0 - TILE_W / 2.0 - 1.8, f"{TILE_L_TOE:.2f} estrecho",
            fontsize=5.5, ha="center", va="top", color="#333")
    wrapped = textwrap.wrap(note, 110)
    for i, line in enumerate(wrapped):
        ax.text(0.0, -margin - 4.0 - 3.4 * i, line, fontsize=6, ha="left",
                va="top", color="#111", family="sans-serif")
    tb = (f"{PART_TITLES_ES['segno_pedal_tiles']}  [segno_pedal_tiles]   |   "
          f"{PLY_2MM}   |   CANT. {len(labels)}   |   medidas en mm   |   "
          f"PIEZA PLANA, sin plegados")
    SHEET_TEXT["segno_pedal_tiles"] = (
        [SHEET_HEADING, tb, TILE_LEGEND, note] + wrapped)
    fig.savefig(path, dpi=300)
    plt.close(fig)


def pdf_one_pedal_tile(path, label):
    """Single-tile 1:1 PDF, same paint as the nest."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    margin = 10.0
    fig = plt.figure(figsize=((TILE_L_BACK + 2 * margin) / 25.4,
                              (TILE_W + 2 * margin + 8.0) / 25.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(-TILE_L_BACK / 2.0 - margin, TILE_L_BACK / 2.0 + margin)
    ax.set_ylim(-TILE_W / 2.0 - margin - 4.0, TILE_W / 2.0 + margin)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.patch.set_facecolor("white")
    _draw_tile_on_ax(ax, 0.0, 0.0, label)
    ax.text(0.0, -TILE_W / 2.0 - 3.2,
            f"{_tile_stem(label)}  TRAPECIO {TILE_L_BACK:.2f}/{TILE_L_TOE:.2f} "
            f"x {TILE_W:.2f}",
            fontsize=6, ha="center", va="top", color="#333")
    fig.savefig(path, dpi=300)
    plt.close(fig)

# ===========================================================================
# MAIN
# ===========================================================================

DXF_PARTS = [
    ("segno_faceplate",        dxf_faceplate),
    ("segno_overlay",          dxf_overlay),  # printed adhesive top-plate graphic (replaces silkscreen)
    ("segno_base",             dxf_base),     # bottom + front/rear/side walls, ONE folded blank
    ("segno_rear_panel",       dxf_rear_panel),  # dismountable I/O panel (#751)
    ("segno_ring_disc",        dxf_ring_disc),                        # LED-ring centre disc
    ("segno_corner_bracket_rear",  lambda p: dxf_corner_bracket(p, CORNER_HT, CORNER_ZR_WALL, CORNER_ZR_SIDE, "REAR x2")),
    ("segno_post",             dxf_post),  # base-anchored faceplate support post x2 (issue #292)
]
NO_PDF = set()   # every sheet part ships with a PDF drawing


def build_pedal_tile_vectors(with_pdf=True):
    """Write the 2-ply tile pack: one nested sheet + ten single-tile DXFs (#946)."""
    os.makedirs(OUT, exist_ok=True)
    stems = []
    for label, _u, _v in PEDALS:
        stem = _tile_stem(label)
        dxf_one_pedal_tile(os.path.join(OUT, stem + ".dxf"), label)
        stems.append(stem)
    nest = "segno_pedal_tiles"
    dxf_pedal_tiles(os.path.join(OUT, nest + ".dxf"))
    if with_pdf:
        pdf_pedal_tiles(os.path.join(OUT, nest + ".pdf"))
        for label, _u, _v in PEDALS:
            pdf_one_pedal_tile(os.path.join(OUT, _tile_stem(label) + ".pdf"), label)
    return stems


def _pack_tile_zip(with_pdf=True):
    """segno_pedal_tiles.zip -- 2-ply shop only. Nest + singles, never metal."""
    import zipfile
    zp = os.path.join(OUT, "segno_pedal_tiles.zip")
    files = ["segno_pedal_tiles.pdf", "segno_pedal_tiles.dxf"] if with_pdf else ["segno_pedal_tiles.dxf"]
    files += [_tile_stem(lab) + ".dxf" for lab, _u, _v in PEDALS]
    if with_pdf:
        files += [_tile_stem(lab) + ".pdf" for lab, _u, _v in PEDALS]
    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        for name in files:
            p = os.path.join(OUT, name)
            assert os.path.exists(p), f"{name} missing -- tile pack would ship a hole"
            age = _RUN_STARTED - os.path.getmtime(p)
            assert age <= 0, (
                f"{name} is STALE -- it was not regenerated by this run "
                f"({age:.0f}s older) but segno_pedal_tiles.zip would ship it.")
            z.write(p, name)
    return zp


def build_quote_packages(with_step=True, with_pdf=True, tiles_only=False):
    """Refresh the manufacturer zips from the CURRENT outputs so they can never
    go stale (a hand-built segno_sheetmetal.zip once shipped three-week-old
    flats). Four packs: laser/bend sheet metal, overlay, 2-ply tiles, 3D prints.

    with_step/with_pdf mirror which builders actually ran THIS run: the
    freshness gate in pack() (rightly) refuses to ship anything this run did
    not write, so a --no-step / --no-pdf / no-cadquery run must skip the packs
    (or the extensions) whose builders were skipped — otherwise the gate turns
    every documented partial invocation into a crash after all its useful work
    (found in review of #792)."""
    import zipfile
    zips = []

    def pack(zname, names, exts):
        zp = os.path.join(OUT, zname)
        with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
            for n in names:
                for ext in exts:
                    p = os.path.join(OUT, n + ext)
                    if os.path.exists(p):
                        # FRESHNESS GATE. Everything a vendor pack ships must have
                        # been written by THIS run. segno_ring_disc.step was a
                        # hand-made file the packager just picked up: it sat at
                        # O40 x 2 while its own DXF moved to O51.5, and shipped
                        # that way through three ring resizes because nothing
                        # checked. A stale solid next to a live flat is worse than
                        # no solid at all -- the shop cannot tell which one lies.
                        age = _RUN_STARTED - os.path.getmtime(p)
                        assert age <= 0, (
                            f"{n}{ext} is STALE -- it was not regenerated by this "
                            f"run ({age:.0f}s older) but {zname} would ship it. "
                            f"Give it a builder, or drop it from the pack.")
                        z.write(p, n + ext)
        zips.append(zp)

    # The sheet-metal pack carries SHEET METAL only. segno_overlay used to ride in
    # here with a title block reading "2.0 mm 5052-H32 Al | qty 1" -- an 846 x 406.6
    # printed vinyl graphic quoted as 0.34 m2 of aluminium, cut and powder coated for
    # nothing, roughly a third of the metal spend (#775 R6). It now has its own pack.
    if tiles_only:
        return [_pack_tile_zip(with_pdf)]
    sheet   = [n for n, _ in DXF_PARTS if PART_SPECS[n][2] == PKG_SHEETMETAL]
    overlay = [n for n, _ in DXF_PARTS if PART_SPECS[n][2] == PKG_OVERLAY]
    flat_exts = (".dxf", ".pdf") if with_pdf else (".dxf",)
    pack("segno_sheetmetal.zip", sheet, flat_exts)
    pack("segno_overlay.zip", overlay, flat_exts)
    zips.append(_pack_tile_zip(with_pdf))
    # segno_base and segno_corner_bracket_rear are deliberately NOT here. Nothing
    # generates a per-part STEP for either (see build_assembly_step: the base is
    # ONE folded blank and the assembly STEP is where its 3D form lives), so the
    # files that used to satisfy this list were 17-day-old leftovers the packer
    # picked up off disk and shipped next to DXFs that had moved on. The
    # freshness gate in pack() now refuses that outright.
    if not with_step:
        print("(quote packs: STEP/STL packs skipped -- no STEP builders ran)")
        if with_pdf:
            pack("segno_pintura.zip",
                 ["segno_paint_quote"] + [s for s, *_ in PAINT_BOM], (".pdf",))
        return zips
    pack("segno_sheetmetal_step.zip",
         ["segno_assembly", "segno_faceplate", "segno_ring_disc", "segno_post"],
         (".step",))
    pack("segno_3dprint.zip",
         ["segno_platform_front", "segno_platform_mid",
          "segno_led_diffuser", "segno_ring_diffuser"]
         + ["segno_pedal_tile_" + l.replace("/", "_") for l, _u, _v in PEDALS] + [
          "segno_screen7_tower",
          "segno_screen16_stand_L", "segno_screen16_stand_R"],
         (".step", ".stl"))
    # segno_screen7_fit_test deliberately NOT in the vendor pack: it is a
    # calibration jig (its verdict is already folded into the S7C_* block),
    # and shipping it invites the vendor to quote/print a non-product part.
    # It stays buildable for reprints after any S7C_* change.
    # Powder-coat quote pack: the Spanish sheet + every painted part's PDF.
    # Deliberately NO DXFs -- the coater cuts nothing, and a flat pattern only
    # invites confusion. Narrowed to the paint BOM -- not every DXF_PART.
    if with_pdf:
        pack("segno_pintura.zip",
             ["segno_paint_quote"] + [s for s, *_ in PAINT_BOM], (".pdf",))
    return zips


# ===========================================================================
# DRAWING / PACKAGE GATES   (issue #775)
# ---------------------------------------------------------------------------
# _check() proves the GEOMETRY. Nothing proved the DOCUMENTS, and that is exactly
# where the DFM sweep found every one of its RED items: a through-cut layer that
# rendered white, folds with no angle anywhere, mask rings shaped like holes, a
# legend telling the shop to score the bend lines, a default material and quantity
# on every sheet, and a vinyl part inside the aluminium package. These run on the
# generated files, after the fact, so they hold whatever the generator does.
# ===========================================================================

def _dxf_bend_lines(dxf_path):
    """Every BEND line actually drawn, as (axis, position, length)."""
    import ezdxf
    out = []
    for e in ezdxf.readfile(dxf_path).modelspace():
        if e.dxf.layer != "BEND" or e.dxftype() != "LWPOLYLINE":
            continue
        pts = [(pt[0], pt[1]) for pt in e.get_points()]
        xs = [q[0] for q in pts]; ys = [q[1] for q in pts]
        if abs(max(ys) - min(ys)) < 1e-6:
            out.append(("y", round(min(ys), 3), round(max(xs) - min(xs), 3)))
        elif abs(max(xs) - min(xs)) < 1e-6:
            out.append(("x", round(min(xs), 3), round(max(ys) - min(ys), 3)))
        else:
            raise AssertionError(f"{os.path.basename(dxf_path)}: BEND line is neither "
                                 f"horizontal nor vertical -- it cannot be tabled")
    return sorted(out)


def _verify_tile_package(with_pdf=True):
    """Gates on the 2-ply tile pack: geometry, not TEXT, Spanish notes, own zip."""
    import zipfile
    import ezdxf

    nest = os.path.join(OUT, "segno_pedal_tiles.dxf")
    assert os.path.exists(nest), "segno_pedal_tiles.dxf was not written"
    doc = ezdxf.readfile(nest)
    used = {e.dxf.layer for e in doc.modelspace()}
    assert used <= set(THRU_CUT_LAYERS + ANNOT_LAYERS), (
        f"tile nest uses undeclared layers: {sorted(used - set(THRU_CUT_LAYERS + ANNOT_LAYERS))}")
    cuts = [e for e in doc.modelspace()
            if e.dxf.layer == "CUT" and e.dxftype() == "LWPOLYLINE"]
    assert len(cuts) == len(PEDALS), (
        f"tile nest: expected {len(PEDALS)} CUT trapezoids, got {len(cuts)}")
    for e in doc.modelspace():
        if e.dxftype() == "TEXT":
            assert e.dxf.layer == "NOTE", (
                f"tile nest: TEXT on {e.dxf.layer} -- glyphs must be geometry, not font")
    hatches = [e for e in doc.modelspace()
               if e.dxftype() == "HATCH" and e.dxf.layer == "ENGRAVE"]
    assert len(hatches) >= len(PEDALS), (
        f"tile nest: {len(hatches)} ENGRAVE hatches for {len(PEDALS)} tiles")
    notes = [e.dxf.text for e in doc.modelspace() if e.dxftype() == "TEXT"]
    blob = " ".join(notes)
    assert "CANT." in blob and "segno_pedal_tiles" in blob
    assert "bicapa" in blob and "borde ANCHO" in blob
    assert "TRAPECIO" in blob and f"{TILE_L_BACK:.2f}" in blob and f"{TILE_L_TOE:.2f}" in blob
    for english in ("2.0mm", "DO NOT CUT", " x10 "):
        assert english.lower() not in blob.lower(), (
            f"tile nest: untranslated shop text {english!r}")

    for label, _u, _v in PEDALS:
        path = os.path.join(OUT, _tile_stem(label) + ".dxf")
        assert os.path.exists(path), f"{_tile_stem(label)}.dxf missing"
        one = ezdxf.readfile(path)
        cut = [e for e in one.modelspace()
               if e.dxf.layer == "CUT" and e.dxftype() == "LWPOLYLINE"]
        assert len(cut) == 1, f"{label}: {len(cut)} CUT outlines"
        pts = [(p[0], p[1]) for p in cut[0].get_points()]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        assert abs((max(xs) - min(xs)) - TILE_L_BACK) < 1e-3, (
            f"{label}: cut width {max(xs) - min(xs):.3f} != {TILE_L_BACK:.3f}")
        assert abs((max(ys) - min(ys)) - TILE_W) < 1e-3, (
            f"{label}: cut depth {max(ys) - min(ys):.3f} != {TILE_W:.3f}")
        back = [p for p in pts if abs(p[1] - max(ys)) < 1e-6]
        toe = [p for p in pts if abs(p[1] - min(ys)) < 1e-6]
        if len(back) >= 2:
            assert abs(abs(back[0][0] - back[1][0]) - TILE_L_BACK) < 1e-3
        if len(toe) >= 2:
            assert abs(abs(toe[0][0] - toe[1][0]) - TILE_L_TOE) < 1e-3
        assert not any(e.dxftype() == "TEXT" and e.dxf.layer != "NOTE"
                       for e in one.modelspace())
        assert any(e.dxftype() == "HATCH" for e in one.modelspace()), (
            f"{label}: no ENGRAVE hatch -- the shop would cut a blank tile")

    if with_pdf:
        assert os.path.exists(os.path.join(OUT, "segno_pedal_tiles.pdf"))
        sheet = SHEET_TEXT["segno_pedal_tiles"]
        assert TILE_LEGEND.split("|")[0].strip() in " ".join(sheet), (
            "tile sheet is missing TILE_LEGEND")
        title_line = next(t for t in sheet if t.startswith(PART_TITLES_ES["segno_pedal_tiles"]))
        assert "segno_pedal_tiles" in title_line and "CANT." in title_line
        for label, _u, _v in PEDALS:
            assert os.path.exists(os.path.join(OUT, _tile_stem(label) + ".pdf"))

    zp = os.path.join(OUT, "segno_pedal_tiles.zip")
    if os.path.exists(zp):
        with zipfile.ZipFile(zp) as z:
            names = set(z.namelist())
        assert "segno_pedal_tiles.dxf" in names
        for label, _u, _v in PEDALS:
            assert _tile_stem(label) + ".dxf" in names
        if with_pdf:
            assert "segno_pedal_tiles.pdf" in names
        assert not any(n.endswith((".step", ".stl")) for n in names)
        assert not any(n.startswith("segno_base") or n.startswith("segno_faceplate")
                       for n in names)


def _verify_drawing_package(with_pdf=True):
    import inspect, zipfile
    import ezdxf

    stems = [n for n, _ in DXF_PARTS]

    # --- R5/R6: nothing ships on a default material or quantity ---------------
    sig = inspect.signature(dxf_to_pdf)
    for arg in ("material", "qty"):
        assert sig.parameters[arg].default is inspect.Parameter.empty, \
            f"dxf_to_pdf({arg}=...) has a default again -- a sheet can silently inherit it"
    for stem in stems:
        assert stem in PART_SPECS, f"{stem} has no PART_SPECS row (material/qty/package)"
        mat, qty, pkg = PART_SPECS[stem]
        assert mat and isinstance(qty, int) and qty >= 1, f"{stem}: bad material/qty {mat!r}/{qty!r}"
        assert pkg in (PKG_SHEETMETAL, PKG_OVERLAY, PKG_TILES), f"{stem}: unknown package {pkg!r}"
    assert PART_SPECS["segno_post"][0] == STEEL_CR and PART_SPECS["segno_post"][1] == 2, \
        "the support post is 1.6 mm cold-rolled steel x2, per MANUFACTURING.md section 1"
    assert PART_SPECS["segno_corner_bracket_rear"][1] == 2, "corner bracket is x2"
    assert PART_SPECS["segno_overlay"][2] == PKG_OVERLAY, "the overlay is not sheet metal"

    # --- R1/R4: the legend names VENT as a through-cut and never says "score" --
    # Same intent as when the legend was English, held against the Spanish (#778):
    # BEND must be a fold REFERENCE, VENT must be named a through-cut, and the
    # marking verbs may appear only inside the prohibition clause.
    low = SHEET_LEGEND.lower()
    assert LEGEND_NO_SCORE in low, \
        "the legend must forbid cutting/marking/scoring the fold lines"
    for verb in ("marcar", "rayar", "grabar"):
        assert low.count(verb) == LEGEND_NO_SCORE.count(verb), \
            f"the legend mentions {verb!r} outside the prohibition clause -- " \
            f"that reads as an instruction to do it to the BEND lines"
    assert "solo referencia" in low, \
        "the legend must say the BEND layer is reference only"
    assert "corte pasante" in low and "vent" in low, \
        "the legend must state that VENT is a through-cut like CUT"
    assert "línea de plegado" in low, "the legend must state that BEND is a fold reference"

    # --- #778: the sheets speak Spanish, and the accents survive the pipeline ---
    for stem in stems:
        assert stem in PART_TITLES_ES and PART_TITLES_ES[stem], \
            f"{stem} has no Spanish title-block name (PART_TITLES_ES)"
    for stem, (mat, _q, _p) in PART_SPECS.items():
        assert not any(w in mat.lower() for w in ("aluminium", "steel", "vinyl")), \
            f"{stem}: material {mat!r} is still English"
    assert TOLERANCE_TITLE.startswith("TOLERANCIAS")
    for _k, v in TOLERANCE_ROWS:
        assert "," in v and "." not in v, \
            f"tolerance {v!r} must use the comma decimal separator on the Spanish sheet"

    all_notes = []
    for stem in stems:
        dxf = os.path.join(OUT, stem + ".dxf")
        if not os.path.exists(dxf):
            continue
        doc = ezdxf.readfile(dxf)
        used = {e.dxf.layer for e in doc.modelspace()}

        # --- R1: every through-cut layer present renders black -----------------
        black = _force_pdf_layer_colours(doc)   # asserts internally; also proves no
        for lname in used & set(THRU_CUT_LAYERS):   # geometry layer is left ACI-7 white
            assert lname in black, f"{stem}: through-cut layer {lname} not forced black"

        # --- R3: mask rings are annotation, never cutting data ------------------
        masks = [e for e in doc.modelspace() if e.dxf.layer == "MASK"]
        mask_rings = [e for e in masks if e.dxftype() == "CIRCLE"]
        for e in mask_rings:
            for other in doc.modelspace():
                if other.dxf.layer not in THRU_CUT_LAYERS or other.dxftype() != "CIRCLE":
                    continue
                same = (abs(other.dxf.center.x - e.dxf.center.x) < 1e-6
                        and abs(other.dxf.center.y - e.dxf.center.y) < 1e-6
                        and abs(other.dxf.radius - e.dxf.radius) < 1e-6)
                assert not same, (f"{stem}: a MASK ring at ({e.dxf.center.x:.3f}, "
                                  f"{e.dxf.center.y:.3f}) is duplicated on a cut layer")
            assert doc.layers.get("MASK").dxf.linetype == "DASHDOT", \
                f"{stem}: MASK must be dash-dot so it cannot read as a cut contour"
        if mask_rings:
            says = [t for t in masks if t.dxftype() == "TEXT"
                    and "NO CORTAR" in t.dxf.text.upper()]
            assert len(says) >= len(mask_rings), \
                (f"{stem}: {len(mask_rings)} mask ring(s) but only {len(says)} "
                 f"'NO CORTAR' callout(s) -- every ring needs its own")

        # --- R2: every drawn fold is in the bend table, and vice versa ----------
        drawn = _dxf_bend_lines(dxf)
        tabled = sorted((axis, round(pos, 3), round(ln, 3))
                        for _s, _n, axis, pos, ln, *_r in BEND_TABLES.get(stem, ()))
        assert drawn == tabled, (
            f"{stem}: bend table does not match the drawn BEND layer.\n"
            f"  drawn : {drawn}\n  tabled: {tabled}")
        for _s, name, _a, _p, _l, rot, direction, ri, _d in BEND_TABLES.get(stem, ()):
            assert 0.0 < rot < 180.0, f"{stem}/{name}: fold rotation {rot} is not a fold"
            assert direction in (UP_TOWARD, DN_AWAY), f"{stem}/{name}: no fold direction"
            assert ri > 0.0, f"{stem}/{name}: no inside radius"
        if drawn:
            assert stem in BEND_FOOTNOTES, f"{stem} has folds but no bend-table footnote"

        # --- #778: the DXF's own shop text is Spanish and round-trips its accents -
        # ezdxf writes R2018 as UTF-8; re-reading the saved file and finding the
        # accented characters intact is the proof that nothing on the way out
        # mojibaked them or silently fell back to ASCII.
        notes = [e.dxf.text for e in doc.modelspace()
                 if e.dxftype() == "TEXT" and e.dxf.layer in ("NOTE", "MASK")]
        assert notes, f"{stem}: no NOTE/MASK text on the flat pattern at all"
        joined = " ".join(notes)
        all_notes.append(joined)
        assert "CANT." in joined and stem in joined, \
            (f"{stem}: the part note lost its Spanish quantity or its file stem -- "
             f"the shop pairs the printed sheet to the DXF by that stem")
        for english in (" x1 ", " x2 ", "2.0mm", "DO NOT CUT", "FOLD with",
                        "weld-free", "NO PAINT"):
            assert english.lower() not in joined.lower(), \
                f"{stem}: untranslated shop text {english!r} is still on the drawing"

        if with_pdf:
            assert os.path.exists(os.path.join(OUT, stem + ".pdf")), f"{stem}: no PDF sheet"
            # --- #778: every SHEET-METAL sheet carries the tolerance block ------
            assert stem in SHEET_TEXT, \
                f"{stem}: a PDF exists but the sheet recorded no text -- it bypassed dxf_to_pdf"
            sheet = SHEET_TEXT[stem]
            assert SHEET_LEGEND.split("|")[0].strip() in " ".join(sheet), \
                f"{stem}: the sheet carries no layer legend"
            title_line = next(t for t in sheet if t.startswith(PART_TITLES_ES[stem]))
            assert stem in title_line and "CANT." in title_line and "medidas en mm" in title_line, \
                f"{stem}: title block lost its file stem, quantity or units: {title_line!r}"
            if PART_SPECS[stem][2] == PKG_SHEETMETAL:
                assert TOLERANCE_TITLE in sheet, \
                    f"{stem}: sheet-metal drawing with no tolerance block"
                for k, v in TOLERANCE_ROWS:
                    assert any(k in ln and v in ln for ln in sheet), \
                        f"{stem}: tolerance block is missing the {k!r} row"

    # --- #778: the accents made it through ezdxf's UTF-8 write and back --------
    # If the DXF encoding ever regresses to a code page, or someone "fixes" the
    # Spanish by stripping its accents, these exact phrases stop matching. They
    # are the ones a fabricator acts on, so they are the ones worth pinning.
    if all_notes:
        blob = "\n".join(all_notes)
        for probe in ("espejado canónico", "deducción", "transición", "pestaña frontal",
                      "máscara de pintura", "ACERO LAMINADO EN FRÍO", "AMBAS CARAS"):
            assert probe in blob, \
                (f"{probe!r} is not in the drawing text -- either the wording changed "
                 f"or the DXF encoding mangled its accents")

    # --- R6: the sheet-metal zip carries sheet metal and nothing else ----------
    sheet = {n for n, _ in DXF_PARTS if PART_SPECS[n][2] == PKG_SHEETMETAL}
    other = {n for n, _ in DXF_PARTS if PART_SPECS[n][2] != PKG_SHEETMETAL}
    zp = os.path.join(OUT, "segno_sheetmetal.zip")
    if os.path.exists(zp):
        with zipfile.ZipFile(zp) as z:
            members = {os.path.splitext(n)[0] for n in z.namelist()}
        assert members <= sheet, \
            f"segno_sheetmetal.zip carries non-sheet-metal parts: {sorted(members - sheet)}"
        assert not (members & other), f"non-metal part in the metal pack: {sorted(members & other)}"
        if with_pdf:
            assert members == sheet, f"segno_sheetmetal.zip is missing {sorted(sheet - members)}"
    zo = os.path.join(OUT, "segno_overlay.zip")
    if other and os.path.exists(zo):
        with zipfile.ZipFile(zo) as z:
            assert {os.path.splitext(n)[0] for n in z.namelist()} == other, \
                "segno_overlay.zip must carry exactly the non-metal die-cut parts"

    if os.path.exists(os.path.join(OUT, "segno_pedal_tiles.dxf")):
        _verify_tile_package(with_pdf=with_pdf)

def write_rear_io_stations():
    """Publish the rear-panel station list for the CONSOLE BOARD generator (#747).

    hardware/kicad/console_board.py asserts it terminates every station declared
    here, so a connector added to the panel with no header on the board fails a
    gate instead of surfacing during assembly. It cannot simply import this module
    -- that needs cadquery, which the KiCad venv does not have -- hence a JSON
    handoff.

    Written from main() BEFORE the --report early-return on purpose: emitting it
    alongside the DXF loop would force a full run (every DXF, PDF, STEP, printed
    part and four quote zips, minutes of cadquery) just to refresh one small file.
    """
    import json
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "rear_io_stations.json")
    lay = rear_io_layout()
    payload = {
        "source": "segno_enclosure.py",
        "wall": {"w": W, "h": REAR_WALL_H, "z": REAR_IO_Z},
        "stations": [
            {"ref": ref, "keepout": kw, "centre_u": round(lay[ref][0], 3)}
            for ref, kw in REAR_IO_STATIONS
        ],
    }
    with open(path, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    return path

def main(argv):
    print(report())
    print("\nGeometry assertions ...", end=" ")
    _check()
    print("ALL PASS")
    print("Rear I/O stations: out/%s" % os.path.basename(write_rear_io_stations()))
    if "--report" in argv:
        return
    if "--tiles-only" in argv:
        os.makedirs(OUT, exist_ok=True)
        stems = build_pedal_tile_vectors(with_pdf="--no-pdf" not in argv)
        print("\nPedal name tiles (2-ply vector, x%d -- TRAPEZOID %.2f(back)/%.2f(toe)\n"
              "  x %.2f x %.1f mm bicapa; wide edge to the cable end):\n"
              "  out/segno_pedal_tiles.dxf + %d singles"
              % (len(stems), TILE_L_BACK, TILE_L_TOE, TILE_W, TILE_PLY_T, len(stems)))
        for z in build_quote_packages(with_step=False, with_pdf="--no-pdf" not in argv,
                                      tiles_only=True):
            print("Quote package: out/" + os.path.basename(z))
        print("\nDrawing/package assertions ...", end=" ")
        _verify_tile_package(with_pdf="--no-pdf" not in argv)
        print("ALL PASS")
        return
    os.makedirs(OUT, exist_ok=True)
    layout_svg(os.path.join(HERE, "segno_panel_layout.svg"))
    print("\nAnnotated layout: segno_panel_layout.svg")
    print("DXF flat patterns:")
    for name, fn in DXF_PARTS:
        dxf = os.path.join(OUT, name + ".dxf"); fn(dxf)
        print("  out/" + name + ".dxf")
        if "--no-pdf" not in argv and name not in NO_PDF:
            try:
                mat, qty, _pkg = PART_SPECS[name]
                dxf_to_pdf(dxf, os.path.join(OUT, name + ".pdf"),
                           title=f"{PART_TITLES_ES[name]}  [{name}]",
                           material=mat, qty=qty, stem=name)
                print("  out/" + name + ".pdf")
            except Exception as e:  # pragma: no cover
                print(f"    (pdf skipped: {e})")
    tile_stems = build_pedal_tile_vectors(with_pdf="--no-pdf" not in argv)
    print("  out/segno_pedal_tiles.dxf  (2-ply nest, x%d)" % len(tile_stems))
    if "--no-pdf" not in argv:
        print("  out/segno_pedal_tiles.pdf")
    if "--no-pdf" not in argv:
        try:
            paint_quote_pdf(os.path.join(OUT, "segno_paint_quote.pdf"))
            print("\nPaint quote sheet: out/segno_paint_quote.pdf")
        except Exception as e:  # pragma: no cover
            print(f"\n(paint quote skipped: {e})")
    steps_built = "--no-step" not in argv
    if "--no-step" not in argv:
        try:
            d = build_diffuser_step()
            print("\nLED diffuser insert (3D print, x6): out/" + os.path.basename(d) + " (+ .stl)")
            r = build_ring_diffuser_step()
            print("Ring diffuser insert (3D print, x1): out/" + os.path.basename(r) + " (+ .stl)")
            tiles = build_pedal_name_tiles()
            print("Pedal name tiles (3D print, x%d -- TRAPEZOID %.2f(back)/%.2f(toe)\n"
                  "  x %.2f, wide edge to the cable end; print FACE-DOWN, filament\n"
                  "  change at z=%.1f: white glyphs then black body): out/%s.step ..."
                  % (len(tiles), TILE_L_BACK, TILE_L_TOE, TILE_W, TILE_TEXT_T, tiles[0]))
            rd = build_ring_disc_step()
            print("Ring centre disc (2.0 Al, x1): out/" + os.path.basename(rd))
            kb = build_encoder_knob_step()
            print("Encoder knob (PURCHASED O50x18x6 alu -- reference model only,\n  deliberately not in the 3D-print pack): out/" + os.path.basename(kb))
            s = build_post_step()
            print("Faceplate support post (base-anchored, x2): out/" + os.path.basename(s))
            tw = build_screen7_tower_step()
            print("7in screen support tower (3D print, x1): out/" + os.path.basename(tw) + " (+ .stl)")
            for sp16 in build_screen16_stand_steps():
                print("15.6in stand (3D print, PROVISIONAL): out/" + os.path.basename(sp16) + " (+ .stl)")
            ftp = build_screen7_fit_test()
            print("7in screen FIT TEST plate (3D print, x1): out/" + os.path.basename(ftp) + " (+ .stl)")
            for pp in build_platform_steps():
                print("Printed platform: out/" + os.path.basename(pp) + " (+ .stl)")
            build_mini_console()
            p = build_step()
            print("\n3D STEP:\n  " + os.path.relpath(p, HERE) + " (+ per-part .step)")
        except ImportError as e:  # pragma: no cover -- no cadquery in this env
            print(f"\n(STEP skipped: {e})")
            steps_built = False
        # anything else is a real build failure: let it crash the run. The old
        # blanket `except Exception` swallowed a NameError here for weeks and
        # shipped stale tower/stand/fit-test STEPs while printing EXIT=0.
    for z in build_quote_packages(with_step=steps_built,
                                  with_pdf="--no-pdf" not in argv):
        print("Quote package: out/" + os.path.basename(z))
    print("\nDrawing/package assertions ...", end=" ")
    _verify_drawing_package(with_pdf="--no-pdf" not in argv)
    print("ALL PASS")
    if "--render" in argv:
        try:
            r = render_png(os.path.join(OUT, "segno_render.png"))
            print("\nShaded render:\n  out/segno_render.png")
        except Exception as e:  # pragma: no cover
            print(f"\n(render skipped: {e})")

if __name__ == "__main__":
    main(set(sys.argv[1:]))
