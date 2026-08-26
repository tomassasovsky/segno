# A lost interface holds the screen until it is found again (#453)

Status: **design pinned in the pen, implementation unstarted.** The direction
call this issue was gated on is answered — the owner drew `STAGE / device-lost`
into `segno-ui.pen` (reached master via #636, confirmed present in the live pen
on the 2026-08-20 sweep) — so this plan is the build map from that design to
the code, plus the two small calls the pen does not settle.

## Current state (verified against master, 2026-08-25)

Both loss conditions are still toast-only, exactly the D1 stopgap from
`docs/plan/2026-08-02-closeout-plan.md`:

- `lib/app/app_toasts.dart` defines `AppToastId.deviceLost`
  (`app_deviceLost_banner`) and `AppToastId.midiLost` (`app_midiLost_banner`) —
  the ids still *say* banner; the surface is a Toastification toast.
- `lib/app/view/app.dart:758` (`_showConnectivityBanner`) maps
  `AudioSetupState.deviceConnectivity` — `lost` → warning toast, `restored` →
  snack toast; `:784` (`_showMidiConnectivityBanner`) does the MIDI analog off
  `MidiSetupState.connection.connectivity`.
- No persistent surface exists anywhere in `lib` for either condition; the two
  banner tests deleted by the closeout are still unwritten.

The idiom the pen reuses already exists: `ConsoleBanner` with
`ConsoleBannerTone` (`pending` / `failure` / `steady`), used in
`lib/wifi/wifi_tray_body.dart:201`, `lib/looper/view/signal/signal_cards.dart:394`,
`lib/system/view/display_system_tab.dart:61`. The 7" echo target exists too:
the console's second panel is `ConsoleReadoutView`
(`lib/visualizer/console_readout_view.dart`, the pen's `STAGE / readout`),
driven by the `PerformanceReadout` model
(`lib/visualizer/performance_readout.dart`) that `app.dart` projects and pushes
over the window channel — the projection already carries `mode`, `recordArmed`,
`countingIn`, so two loss flags ride the same pipe.

## The pinned design (from the pen, via #603/#636)

- New screen `STAGE / device-lost`: standing loss conditions render in the
  `Banner` idiom on the stage. Device-lost in **record red** — "Audio
  interface disconnected — the engine is stopped and nothing is heard",
  action **Choose device**. MIDI-lost in **warning amber**, action
  **Control**. Both at once stack in severity order, device first.
- A banner holds the screen exactly as long as its condition holds and leaves
  on its own. Toasts stay for *events* (reconnected). **Never a dialog** — a
  lost interface mid-song must not also steal the transport.
- The 7" readout echoes the same line in its status strip.
- Rationale in `c/device-lost`.

Pencil was not reachable this session; **build step 0 is re-reading
`STAGE / device-lost` in the pen** for exact placement, insets, and copy —
this plan cites the design record, not fresh pixels. Nothing new needs
drawing.

## Decisions for the owner

**D1 — does the lost toast survive alongside the banner?** Options: (a) the
banner replaces the lost toast outright; (b) keep both, toast as the
attention-getter, banner as the standing record. Recommend **(a)**: the toast
was the stopgap this issue exists to retire, the banner's arrival is itself
the attention event, and two surfaces saying one thing is the "too many places
to look" smell the IA rebuild just cleaned. Restored stays a snack toast — it
is an event, the pen keeps toasts for events.

**D2 — desktop parity.** The pen draws the console stage. The condition is
exactly as true in a desktop window. Options: (a) mount the banner in both
builds; (b) console-only, desktop keeps toasts. Recommend **(a)** — the widget
is build-agnostic and `StageStatusBar`'s pattern (host mounts it console-only)
shows how to scope later if the desktop chrome fights it; shipping a known
regression-shaped gap on desktop to match a console drawing is backwards.

One tone check belongs to the build, not the owner: `ConsoleBannerTone` today
has `pending`/`failure`/`steady`; the pen wants record red and warning amber.
Verify `failure` renders record red and `pending` (or a new `warning`) renders
amber against `LooperTheme` tokens — if a tone is missing, add it to the
enum + theme extension rather than hard-coding a color (VGV token rule).

## Implementation outline

1. **`ConnectivityBanners` widget** (new, `lib/app/view/` or the stage chrome
   next to `lib/looper/view/stage_status_bar.dart` — the pen's placement
   decides which): a column of up to two `ConsoleBanner`s, device first,
   subscribed via `BlocSelector` to `AudioSetupCubit` (`deviceConnectivity`,
   `connectivityDeviceName`) and the MIDI cubit
   (`connection.connectivity`, names) — render on `lost`, gone otherwise.
   Actions: **Choose device** drives the tray to the Audio domain, **Control**
   to the Control domain, through `SettingsTrayCubit`'s existing destination
   API — navigation, no new routing.
2. **Retire the lost toasts**: `_showConnectivityBanner` /
   `_showMidiConnectivityBanner` in `app.dart` drop their `lost` branches
   (keep `restored`); delete the now-unused lost toast ids or repoint their
   names to the truth.
3. **7" echo**: extend `PerformanceReadout` with `deviceLost` / `midiLost`
   (+ device name), set in `app.dart`'s projection, rendered as the pen's
   status-strip line in `ConsoleReadoutView`. The model is `Equatable`-style
   pushed-on-change — two booleans ride free.
4. **Copy** through `l10n` ARBs as always; the pen's line is the English
   source.

## Verification plan

- Widget tests — the D1-deferred replacement tests, written against the real
  surface at last: banner appears when connectivity goes `lost`, persists
  across pumps (no auto-hide), leaves on `restored`/`none`; both-lost stacks
  device-first; actions open the right tray domain; no dialog route exists.
- `PerformanceReadout` projection test: loss flags set/cleared; readout view
  test renders the echo line.
- Toast regression: `restored` still snacks; `lost` no longer toasts.
- Goldens: stage with device-lost, with both banners; regen + eyeball
  (author-machine only, they rot silently).
- `dart analyze` + `bloc lint` clean.

## Acceptance criteria

- Unplugging the pinned interface shows a standing red banner that outlives
  any toast timeout and disappears on its own when the device returns.
- MIDI loss shows the amber banner; both conditions stack in severity order.
- The 7" readout carries the same line while the condition holds.
- Zero dialogs anywhere in the flow.
- The deleted banner tests have named successors in the suite.

## Non-goals

- Engine-side reconnect/recovery behavior (`_showAudioRecoveryBanner` and the
  recovery cubit are untouched).
- A general toast→banner framework migration — only these two conditions.
- Redesigning the readout face beyond one status line.
