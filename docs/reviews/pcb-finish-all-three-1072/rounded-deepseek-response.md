<!-- cspell:words mitre miter Collide fanout fanouts autorouter AUX -->

# DeepSeek rounding review response

The retry completed and returned the following source-only review. The reviewer
received the routing helper and critical-route source; it did not read native
boards. This is the actual model response, not accepted findings. See the
[adjudication](rounded-deepseek-adjudication.md) for the native/source checks.
Private invocation, session and runtime metadata are omitted.

---

Review of `round_routes.py` and `route_critical.py` (sources only; no board files read).

**Finding 1 — same-net contact preservation guards exact touches only** (`round_routes.py:436-439`)
`lost_contact` rejects a radius only when the mitre *touches* a same-net contact at `Collide(contact, 0)` and the arc does not. A contact the mitre holds at a small nonzero gap (e.g., a parallel same-net run passing 0.05–0.2 mm from the corner — the `AUX_5V` trunk beside a `POWER_FILLET` blend) is never in `contacts`-checked at all, so the arc may close that gap to a touch. Electrically a same-net touch is inert, so the concrete effect is copper-bridging and, if the board ever sets a nonzero same-net clearance, a refill/DRC violation the stated fixtures (which assert pad/keepout/topology) would not catch. Triggering geometry: any corner whose inside void is bridged by a same-net run closer than the mitre's own width.

**Finding 2 — `spread()` relies on an assert stripped by `-O`** (`route_critical.py:181-188`)
`spread` guards its 45° breakout only with `assert abs(reach) <= abs(pad_xy[1]-coupled[1])`. Under `python -O` (or a geometry where the relay common column is less than a 45° drop from the coupled end, x=28.15), the assertion vanishes and the tail collapses to `(pad_x, coupled_y)` — a fold-back miter that re-enters the pad, changing the fanout length and gap. The USB checks ("shorter uncoupled fanouts", "unchanged minimum gap") would detect that only on the exact fixture geometry. The assert is the only guard and is not a runtime check.

**Finding 3 — locked `POWER_TAPER`/`POWER_FILLET` zone outlines are authored against pre-rounding track edges** (`route_critical.py:104-121`, `round_routes.py` full pass)
`region()` fixes each overlay outline to abut hand-track edges exactly; `round_routes` then rounds adjacent *unlocked* autorouter copper, moving the edge a zone outline butted against, and the refill re-intersects. The blend arcs' `0.05 mm` minimum-thickness closure (`route_critical.py:135-142`) is vulnerable to slivers where a rounded arc meets a zone boundary. Not covered by DRC (no clearance violation) or the topology fixtures.

**Material limits:** pad/footprint coordinates and zone-refill behavior were not verified (board files unavailable), so Finding 2's assert-triggering geometry and Finding 3's sliver formation could not be confirmed as active; Findings 1–2 stand on the code alone. No other concrete bugs established; the rounding geometry (miter→arc→chord math, room/tangent caps, anchor preservation, idempotence via CHORD_TURN < MIN_TURN) is internally consistent.
