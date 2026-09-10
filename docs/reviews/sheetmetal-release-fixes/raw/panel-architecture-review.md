## Architecture Review

Scope: the rear-panel follow-up changing nominal stock from 1.5 to 1.2 mm,
coating allowance/guard, derived drawing and paint metadata, panel assembly
placement and regressions, plus its manufacturing/Fusion/release documentation
and `SHOP_REVIEW.md`. Earlier branch changes were reviewed separately.

### Layer Separation

- Violations found: 0; all scoped files are clean.
- This is the existing Python/CadQuery enclosure tool. Its dimensions and
  `_check()` own the geometry contract; exporters derive panel geometry and
  material descriptions from those values. No Flutter application or Bloc
  layer is involved in this change.
- `REAR_PANEL_T` feeds the panel extrusion, assembly placement, drawing material
  and paint material. `COAT_MIN`/`COAT_MAX` feed the nominal fit guard and coating
  notes. Retiring the old fixed 1.5 mm material identifiers avoids a second
  conflicting specification path.
- The Spanish shop form requests unresolved shop/physical evidence and does
  not override the generator's geometry or authorize fabrication.

### State Management Assessment

- Generator: appropriate existing constant-and-function structure; no new
  mutable application state or lifecycle is introduced.
- The check enforces nominal finished thickness at both coating endpoints:
  1.2 + 2 × 0.06 = 1.32 mm and 1.2 + 2 × 0.10 = 1.40 mm, inside the documented
  1.20–1.50 mm requirement. Its comment and manufacturing prose distinguish
  this nominal design allowance from measurement of actual stock and finish.
- The new regression restores altered parameters through `patch.object` and
  rejects unsuitable 1.0 and 1.5 mm nominal panels. Existing assembly checks
  now verify the 1.2 mm solid and retained outer seating face.

### Dependency Direction

- Direction violations: 0.
- CAD geometry remains dependent on existing CadQuery and DXF input; generated
  drawings and paint summaries consume the shared dimensions. The independent
  native capture is evidence, not a runtime dependency or alternate source of
  panel geometry.
- No dependencies, packages, compatibility layers or circular imports were
  added by the follow-up.

### CAD and Manufacturing Contract

- The generated local panel spans −1.2 to 0 mm. Its assembly rotation reverses
  local depth; translating by `D - 3*T + DEV90 - REAR_PANEL_T` preserves the
  outer seat at `D - 3*T + DEV90` as thickness changes. This agrees with the
  Fusion recipe and the populated panel bounds of approximately
  417.710–418.910 mm.
- `panel-verification.json` records the author's save/reopen checks at
  sheet-metal version 129 and populated version 341: both panels are 1.2 mm,
  the outer seating face is retained, and all 17/414 other occurrences have
  unchanged geometry and placement. The manufacturing/source documentation
  agrees with that evidence without claiming physical jack retention.
- `SHOP_REVIEW.md`, `RELEASE_REVIEW.md` and `MANUFACTURING.md` consistently
  require actual finished panel measurement and first-piece retention checks.
  They retain shop acceptance for stock, bend development/tool access and
  the differing modeled versus laser corner details. The design choice is
  resolved; fabrication release remains conditional on those checks.

### Package Structure

- The correction belongs in the existing enclosure generator and dedicated
  manufacturing regression suite. No new package or abstraction is needed.
- One-decimal size formatting preserves the thin panel gauge in the paint
  summary instead of rounding it to an integer.

### Validation and Limits

Independently ran `unittest discover` for `hardware/enclosure/tests` using the
repository's CAD Python environment: **all 8 tests passed** (3.843 s).
Read the native panel capture and the final scoped documentation. Live Fusion
operations and save/reopen verification were performed by the author, not
this reviewer. PDF rendering/layout and final output cleanup are separately
owned by the author; this review does not substitute for those checks or
for stock/coating/retention measurements.

### Verdict

Architecture and the scoped CAD/source/manufacturing contracts are clean.
There are no actionable architecture findings.
