---
date: 2026-08-31
topic: appliance-power-off-button
---

# Appliance power-off button — confirmation gate and goodbye screen

Tracking: [#959](https://github.com/tomassasovsky/segno/issues/959).
Hardware path: console board v2 ([#747](https://github.com/tomassasovsky/segno/issues/747)).
Related (OS/SD survival, not this): Part 6 safe-shutdown
([`2026-06-26-feat-raspberry-pi-floor-console-part-6-plan.md`](../plan/2026-06-26-feat-raspberry-pi-floor-console-part-6-plan.md)).

## What We're Building

The rear power button already exists in hardware. It is a momentary switch on
the console board (J8), passed straight through J9 to the **Pi 5's own J2
power-button solder pads** — not a GPIO, not `dtoverlay=gpio-shutdown`, not
through the RP2350. A short press is a `KEY_POWER` event. A several-second hold
is the PMIC's force-off and cannot be intercepted.

Today the kiosk image has **no logind** and **no app handler**, so that short
press either does nothing or (if something in weston/systemd later consumes it)
takes the machine down with live loops still only in RAM. Named sessions write
only on explicit Save; there is no dirty flag; performance captures have boot
salvage but loops do not.

This slice makes a short press a **product action**:

1. If a take is in flight (count-in, recording, overdub, performance capture
   armed/finalizing) → a dialog that only offers **Keep playing** ("stop
   recording first"). Accidental bump mid-set must not offer discard.
2. If live loops exist and nothing is recording → three choices: **Save &
   power off** (Save As if unnamed) · **Power off without saving** · **Keep
   playing**.
3. If there is nothing that would vanish → skip the confirm.
4. Once power-off is committed → a goodbye screen (a brief **Saving…** face
   if a save was chosen, then a full-screen wordmark/logo hold on every
   window), pedal LEDs go dark via the existing goodbye frame, then
   `systemctl poweroff`.

A further press of the rear button while any of this UI is up is **ignored**.
Only the on-screen actions proceed.

## Why This Approach

Three ways the press could reach that UI:

| Approach | Verdict |
|---|---|
| **App owns `KEY_POWER`** — appliance-only evdev listener → Flutter confirm/goodbye → `segno-update-ctl poweroff`. Weston must not bind `XF86PowerOff`. | **Chosen.** The kiosk already runs as root, already has a privileged helper for reboot, and already refuses logind. One listener, one UI owner. |
| Tiny systemd helper watches the input device and notifies the app | Same UX, extra process. YAGNI until the listener itself is the problem. |
| Add systemd-logind, `HandlePowerKey=ignore`, inhibit shutdown | The image is built *without* a logind session (weston + seatd). Do not add a session manager to handle one key. |

`gpio-shutdown` is not a candidate. The button is not on a GPIO; on a Pi 5
nothing on the 40-way can wake the machine, which is why the hardware went to
J2 in the first place
([`console_board.py` J8 block](../../hardware/kicad/console_board.py)).

## Key Decisions

- **Hardware fact, not a preference:** J8 → J9 → Pi 5 J2 PWR pads. The app
  listens for `KEY_POWER`; it does not bit-bang a line.
- **Gate on work that would vanish**, not on "a named session is open" and not
  always. Predicate: any track `hasContent` or `isCapturing`, a count-in
  sounding, or a performance recorder in `Armed` / `Finalizing` (and the
  cubit's `Rendering` if a disarm just landed). Empty console → goodbye
  directly. **Do not add session dirty tracking in this slice** — there is
  none today; a previously-saved named session still has `hasContent`, so it
  still asks. That is the conservative reading of "never lose by accident."
  "Power off without saving" leaves the last on-disk save intact.
- **Mid-take is refuse, not confirm-to-discard.** The operator's worry is a
  bump during a performance. While a take is in flight the dialog has one
  action: Keep playing. They stop the take the normal way (pedal / UI), then
  the next press sees loops and offers the three-choice dialog.
- **Three choices when loops exist and the take has ended:** Save & power off
  · Power off without saving · Keep playing. Matches a document quit, and
  discard is still an explicit on-screen act. `showConsoleConfirmDialog` is
  two-button with a fixed "keep it" label — this dialog is a new shell in
  that visual language, not a call to the helper as it stands.
- **Save & power off** is `SessionCubit.save()` when a named session is
  open, otherwise the existing Save As name flow. Canceling Save As aborts
  the power-off (Keep playing). The save already waits in-flight overdub
  layers (`_awaitLayersSettled`).
- **Empty / discard → logo hold.** Save → a **Saving…** face that becomes
  the logo hold once the bundle is on disk. The logo is the full-screen
  wordmark on a black field, on **every window** (stage and waveform). No
  spinner, no "Powering off" copy. Hold long enough to read (~2 s) then
  halt. The screens are the power indicator
  ([`segno_wiring.md`](../../hardware/segno_wiring.md) § power button).
- **Second press is ignored** while confirm, Save As, Saving…, or the logo
  hold is up. A bump-bump on the rear panel must not discard.
- **Committed shutdown sequence:** flush `WriteDebouncer`s / mappings (the
  same `close()` flushes that already exist) → pedal goodbye frame → logo
  hold → `segno-update-ctl poweroff` (new verb next to `reboot`,
  `exec systemctl poweroff`). Cubit `close()` is not a substitute for this
  sequence; a halt must not rely on Dart destructors.
- **Long-press force-off is out of scope.** Several seconds on J2 is the
  PMIC. It will drop RAM, skip flushes, skip the pedal goodbye. Document it
  as the emergency path; do not try to fake a gate on it.
- **Desktop is out of scope.** Cmd-Q / window close are not this button.
- **Loop checkpoint/restore is out of scope.** Still the deferred Part 6
  durability item. This slice prevents *accidental* loss; it does not make
  a yank-the-cable survive.

## What already exists (do not reinvent)

- Console dialog idiom: `ConsoleDialogShell` /
  `showConsoleConfirmDialog` in `lib/common/console_surface.dart`.
- Session document model: `SessionCubit.save` / `saveAs` /
  `saveAsRequested` → existing name dialog.
- Pedal darken: `PedalStateFrame.blank(goodbye: true)` from
  `PedalCubit.close` / `PedalRepository.unbind`.
- Debounced FX/mappings flush on cubit `close()`.
- Appliance halt sibling: `segno-update-ctl reboot` → `systemctl reboot`
  (`deploy/yocto/.../files/segno-update-ctl`). App runs as root.
- Performance boot salvage: `PerformanceRepository.runBootRecovery`. A
  capture already on the export volume is not "work that would vanish" once
  it has left `Armed`/`Finalizing`.
- Update restart confirm (`UpdatesSystemTab`) always asks and never
  inspects `hasContent`. **Do not silently change that** in this slice;
  it is a different button. A follow-up may reuse the same "work that
  would vanish" predicate.

## Open Questions

For planning, not for this doc:

- How the appliance identifies the `KEY_POWER` node (scan `/dev/input/event*`
  for the capability vs a named device). Prefer capability-scan so a kernel
  rename does not break the button.
- Whether weston currently binds `XF86PowerOff` on this image (likely not;
  confirm in the weston ini and turn it off if it does).
- Exact logo asset / wordmark already used at boot, so goodbye matches it.
- Dual-display: the waveform window is a second `FlutterView`. Goodbye must
  cover it; planning names the widget.
- l10n keys (en + es), matching every other console dialog.

## Non-goals

- Session dirty tracking / autosave / loop checkpoint.
- Intercepting PMIC long-press.
- Desktop quit / SIGTERM / `didRequestAppExit` on macOS/Windows.
- Adding logind or a GPIO overlay.
- Changing the update-restart confirm to use this predicate (related, not
  this slice).
- Making a hard power-cut recover unsaved loops.
