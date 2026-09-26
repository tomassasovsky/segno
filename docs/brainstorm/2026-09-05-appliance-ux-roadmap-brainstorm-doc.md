# Segno appliance UX and feature roadmap

## What we're building

A coherent Linux looping appliance whose performance, sounds, sessions and configuration have predictable homes. The owner wants the Looper X fully documented, Segno compared against it, better UX where possible, and a roadmap that stops repeated redesign and loss of project state. macOS remains a small-test development host; desktop product support is excluded.

This brainstorm consolidates current evidence under [919](https://github.com/tomassasovsky/segno/issues/919). It preserves the two-screen appliance, global rack scope, frozen input-to-take inheritance and autosave Library direction. The owner has explicitly reopened the settings navigation and visual design. The [audit](../research/segno-looper-x-comparison/README.md) separates code presence from reachable/device-verified behavior.

## Why this approach

| Approach | Benefit | Cost / conclusion |
|---|---|---|
| Start a new app/engine and port everything | Freedom to redraw architecture | Discards tested transport/history/FX work, creates two products and extends the period when capabilities are missing. Reject. |
| Make a visual pass over every current screen | Fast visible change | Leaves recall defects, duplicate routes and orphaned functions intact; likely creates another redesign. Reject as the programme's organizing principle. |
| Complete one musical task at a time in the existing app | Preserves the working instrument; each change has a demo, deletion list and testable end state | Requires some foundations before glamorous UI. Recommend. |

The Looper X groups live performance, configuration and stored media into distinct tasks and provides stable alternate views of the same tracks. Segno should adopt those useful patterns while keeping its two-screen readout, eight tracks, lanes, capture and deeper FX stages. The [source reference](../research/sheeran-looper-x-1.0.2/README.md) establishes the exact observed behavior and its limits.

## Key decisions

**Already established:** Linux appliance scope; macOS developer launch; current five modes and timing remain; `segno-ui.pen` is the design authority; Library entry is the Stage session block; global racks embed frozen copies in sessions/takes; one control dispatcher; obsolete code is removed without compatibility layers.

**Owner direction update — settings review:** the owner agreed that musical recording behavior belongs in Loop and audio hardware configuration belongs in Audio. The owner then explicitly requested a substantial UX/UI revamp closer to the Sheeran Looper X, with submenus. This supersedes the earlier recommendation to retain the current eight-domain tray. Retaining the engine does not constrain the navigation or visual design.

**Owner addition, 2026-09-06:** rotary-encoder UI control with visible focus is required alongside touch. The submenu redesign must include browsing, activation, editing, Back/Cancel and touch-to-encoder handoff. UI navigation must not accidentally change the current master-volume assignment. The [plan’s focus contract](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md#rotary-encoder-and-visible-focus) distinguishes the required capability from proposed turn/press gestures and hardware verification.

**Owner FX addition, 2026-09-06:** eight fully assignable FX-mode pedal positions in two banks of four; unlimited rack collection rather than an eight-rack cap; input-specific FX; and pedal-state mappings such as `1`/`!1`. Saved definitions, live rack instances and pedal positions are separate concepts. The plan assumes no artificial eight-rack cap on the current rig as well as the library; actual DSP capacity remains a separate measured budget. The owner clarified that both latched on/off and physical held/released conditions are required, with inversion for both. Assignment UI must distinguish the state source; exact gesture timing and notation remain design details. See the [rack/state contract](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md#fx-rack-collection-input-effects-and-eight-pedal-positions).

**Next design work:** map main destinations and their focused submenus from the Looper X reference, then adapt them for Segno's capabilities. Review page layout, control density, editing, encoder/touch interaction and Back/return-to-performance together. The exact menu names, hierarchy, entry presentation and default landing are not yet approved. Do not treat merely moving rows within the current tray as completion of the requested revamp.

**Recommended delivery approach retained:** first finish session fidelity while developing the submenu-based settings design; implement accepted settings journeys with predecessor removal; then complete Library, sounds and remaining parity as working slices. Keep hardware reliability gates active throughout.

**Progress discipline:** GitHub holds live delivery status. The roadmap defines dependencies and acceptance, the dated audit defines evidence, and the pen defines design. Limit active visual redesign to one slice. Every completed slice removes the replaced implementation and updates its owning issue/design record. A change of direction states the user problem, evidence, affected decisions and work it supersedes.

## Open decisions with proposed defaults

These are bounded decisions at the owning slice, not blockers to preparing this roadmap.

- **Library load while performing:** preserve pen row-tap load and chevron detail; preflight and preserve outgoing state, then offer an explicit stop-and-load transition if audio/capture is active. Do not imply seamless setlist switching in the first Library.
- **Rack modified/audition behavior:** compare saved topology, order, bypass and values; transient pedal holds do not rewrite the definition. Audition Cancel restores the opening placement and mapping state.
- **Linux plug-ins:** deliver curated built-in sounds first. Preserve existing host infrastructure but do not promise arbitrary desktop plug-ins or design an installer until ARM Linux hosting is explicitly selected and proven.
- **Hardware parity:** import/export to removable storage is a software workflow; USB audio/mass-storage device modes require a port/controller/ownership decision. Keep both on the roadmap as gated capabilities, not fake buttons.
- **Mode conversion:** initially preserve current clear-required transitions with a safe retained-session branch and truthful explanation. A non-destructive conversion matrix is a separate tested enhancement.

The [plan](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md) resolves the recommended defaults far enough to review each boundary. Consequential product departures remain proposals under the existing plan gate.
