Model: Claude Opus (subagent), in-session

# Review of PR #1208: plan, Settings as ten illustrated destinations; retire the settings tray and Bluetooth (#1199)

## Scope

- Branch `origin/claude/settings-tiles-plan-1199` at `cfe3989c1`, file
  `docs/plan/2026-10-06-feat-settings-destinations-plan.md` (7 parts, build
  record for Parts 1 and 2).
- Checked against the owner decisions in the brief: tray and Bluetooth page
  retired; boot-default mode retired (console starts in Record, one notice);
  DAW export moves to Library > Audio.
- Checked: retirement order and dead ends; Bluetooth retirement safety with
  paired devices; `PACKAGE_EXCLUDE` for bluez5 against the pinned upstream
  layers; the interim pages; open question Q1.
- Upstream Yocto sources were read at the commits pinned in
  `deploy/yocto/kas-segno-common.yml` (poky `d0b46a66`, meta-raspberrypi
  `0f68e875`, meta-openembedded `07330a98`), fetched as plain files from
  git.yoctoproject.org.

## Runs

- Pen: `05 Loop setup / 01 Settings` (`v7Ekz`), sections 28 (`Q3YCDg`) and
  30 (`hrXyj`) read through the pencil MCP (read and export only; the pen was
  not saved).
- Code claims spot-checked on the plan base with grep: dead `WifiPage` /
  `BluetoothPage` / `host_page_chrome` / `SignalKnob`; `fx_page.dart:786-794`
  Pedal assignments `onTap: () {}`; `segno.service` has no `User=` and
  `segno-kiosk-launch` execs the app directly (runs as root, so it can read
  `/data/bluetooth`).
- Part 1 and Part 2 suites: see the P1 and P2 reviews (full app suite green
  on both, analyzer and bloc lint clean).
- `npx cspell -c .github/cspell.json` on the plan file: 0 issues.

## Verified correct (traced)

- Tile map order and pen node ids match `v7Ekz` (effects, loop, pedal-setup,
  midi, route / device, wifi, display, storage, updates).
- Tile geometry in the plan (x 100 + {0, 349, 698, 1046, 1395}; main-local
  y 272 and 540; art 128 at (98, 32); name top 174) matches the pen.
- Deletion list: the "dead now" rows are dead on the base (barrels
  `lib/wifi/wifi.dart` and `lib/bluetooth/bluetooth.dart` are imported by
  nothing; `SignalKnob` is constructed only by its test).
- Removal order: P1 keeps every control reachable; P2 leaves the tray behind
  its handle; P4 removes the Bluetooth tab in the same change as BlueZ; P5's
  stated prerequisites (P2 for Effects/Loop tiles, P4, P1 for brightness) are
  the right ones; D6 gives `ControlCubit.setGlobalBindings` a home before P5
  deletes `PedalTrayBody`; D7 keeps the tuner reachable.
- D11 data handling: nothing in `deploy/`, `lib/`, `packages/` or `tool/`
  other than `segno-bt-persist` touches `/data/bluetooth`, so "left
  untouched" holds once that helper is deleted, and a fallback slot's
  `segno-bt-persist` re-binds it.
- D12 is right: nothing in this plan is recalled with a session.

## Findings

### High

**H1. `PACKAGE_EXCLUDE += "bluez5"` will fail the rootfs, and without it BlueZ
stays installed and running.** Plan §4 D11 and Part 4
(`docs/plan/...:261-266`, `:497-500`).
- The image keeps the default `IMAGE_INSTALL ?= "${CORE_IMAGE_BASE_INSTALL}"`
  (poky `meta/classes-recipe/core-image.bbclass:76-85`): the kiosk image and
  kas only use `IMAGE_INSTALL:append`. So `packagegroup-base-extended` is in
  the image.
- `packagegroup-base` hard-depends on `packagegroup-base-bluetooth` when
  `bluetooth` is in COMBINED_FEATURES (poky
  `meta/recipes-core/packagegroups/packagegroup-base.bb:61`), and
  `RDEPENDS:packagegroup-base-bluetooth = "bluez5"` (`:188-191`).
- `bluetooth` is in both feature sets: `MACHINE_FEATURES += "... bluetooth
  wifi ..."` (meta-raspberrypi `conf/machine/include/rpi-base.inc:124`) and
  `DISTRO_FEATURES_DEFAULT ?= "... bluetooth ..."` (poky
  `meta/conf/distro/include/default-distrovars.inc:29`). `kas-segno-common.yml`
  only appends `wayland opengl systemd pam`.
- Failure scenario: Part 4 as written (remove `bluez5` from
  `segno-kiosk-image.bb:39` and `segno-bundle.bb:114`, add `PACKAGE_EXCLUDE`)
  stops at `do_rootfs` with an unsatisfiable dependency. If someone drops the
  `PACKAGE_EXCLUDE` to get past it, bluez5 is still installed by the
  packagegroup and `bluetooth.service` is enabled (`bluez5.inc:158`), so
  `bluetoothd` runs on the new slot with no UI and no `/data` bind, and the
  Part 4 hardware check "`pidof bluetoothd` empty" fails.
- Fix: make `DISTRO_FEATURES:remove = "bluetooth"` in
  `kas-segno-common.yml`'s `local_conf_header` the primary path, not the
  fallback, and keep `PACKAGE_EXCLUDE` as the guard. Note in the plan that a
  DISTRO_FEATURES change invalidates sstate broadly, so the first build is a
  near-full rebuild; check the runner's 40 GB pre-flight headroom first. Add a
  build-host criterion that `packagegroup-base-bluetooth` is absent from the
  manifest.

### Medium

**M1. "After P2 ... nothing on it is lost" (§6, `:328-330`) is not true for
three old-page controls.**
- Boot default mode: an install that stored `mute` keeps booting in Mute
  after P2 with no control to change it, until P3 ships. The owner retired
  the setting, but the interval is a silent loss of a control (rule 3).
- Record offset text field (desktop, D5) and separate input / output device
  choice: the Device tab pairs playback and capture by name
  (`device_audio_tab.dart`, `_Interface`, and `AudioSetupCubit.setDevice`),
  so on the macOS dev host a built-in microphone plus built-in speakers (two
  names) cannot be chosen from any surface after P2. §1.3's "also editable at
  tray Audio > Device" overstates this. The ASIO driver picker is also
  old-page only, but Windows is banked (no `windows/`, no `src/asio`), so
  that part is moot.
- Fix: say P2 and P3 ship in the same release (or move D4's migration into
  P2), and either record the desktop split-device loss as accepted under the
  appliance-only decision or keep a desktop-only path until it is decided.

**M2. The P1 departure "Brightness is a `ConsoleValueBar`" removes keyboard,
encoder and screen-reader adjustment once P5 deletes the capsule.**
`BrightnessCapsule` has arrow-key nudges and `onIncrease` / `onDecrease`
(`lib/looper/view/tray/brightness_capsule.dart:124-134`); `ConsoleValueBar`
has no focus node, no shortcuts and no semantic adjust actions
(`lib/common/console_surface.dart`, class at `:1999`). It also maps the full
travel to 0..1, so the bottom 10% of the bar is dead travel under the 0.1
floor. Not a loss at P1 (the capsule still exists), but Part 5's criteria do
not check it. Fix: add a Part 5 criterion "brightness on Displays is
adjustable with arrow keys and exposes increase/decrease semantics", or give
the page the capsule's behaviour.

**M3. Two cross-branch merge hazards with USB P5 (#1217) are not recorded.**
- P1 + USB P5 merge textually clean but break three tests: USB P5's
  `StorageSystemTab` embeds `StoragePage`, which reads `StorageCubit`, and
  P1's `test/settings/view/destination_harness.dart` does not provide one
  (verified by merging and running; details in the P1 review).
- P2 + USB P5 conflict in `lib/appliance/power_off/power_off_host.dart`: USB
  P5 adds `transferInFlight` to the snapshot inside `_snapshot()`, which P2
  replaced with the shared `currentPowerOffSnapshot`. Resolving in P2's
  favour silently lets the Settings Power button (and the rear key) power off
  during a USB copy. Details in the P2 review.
- Fix: add both to the build record so the second merger knows what to
  carry.

### Low

**L1. D11's "recovery path" lasts one OTA.** The fallback slot keeps BlueZ only
until the next update writes over it. The plan should say so, and the toast
must not imply the pairings can be recovered from the console.

**L2. D11 toast copy needs a plural.** "{count} paired devices will not
reconnect" reads "1 paired devices" for one device; use an ICU plural in the
ARB.

**L3. Pairing link keys stay on `/data` indefinitely.** Acceptable for the
rollback, but name a release after which `/data/bluetooth` is deleted, or
record it as kept on purpose.

## Q1 (Maximum loop length and default multiple)

The pen has no home for either: section 28 (`Q3YCDg`) draws Audio device,
sample rate, buffer, round-trip latency, dropouts and engine status, and no
memory or loop-length row. My recommendation for the owner:
- Maximum loop length belongs on Device. It sizes memory, applies at engine
  start (`audio_bootstrap.dart:153-155`) and its own subtitle says changing
  it reopens the device. That is a property of the audio engine, not of a
  loop.
- The default multiple belongs in Loop settings > Length & quantize. It is
  the length non-defining tracks get, which is the same question that page
  answers per track (`le_engine_set_track_multiple` inherits it at 0). The
  page already has an All-tracks scope where an "inherit" default can sit.
- D3 as the interim default is fine: no stored value stops applying.

## Notes

- Q2 / D4 matches the owner decision.
- The interim pages are a sound application of rule 4; the build record's
  departures (D2 via `AudioRoutingCard`, About as its own route) are
  reasonable.
- §1.6's statement that the five routes' `onStage` only closes the tray was
  not re-traced for every route; Part 2 passes none, and the routes pop to
  the first route themselves.

Verdict: Request changes (H1 must be fixed before Part 4 is built; M1 to M3
are plan text).

## Delta review (c6a4dbf3e)

Scope: `c0458eec8` (build record for Parts 3 and 4) and `c6a4dbf3e` (review
round 1) on top of `cfe3989c1`. The P3 and P4 builds are reviewed in their
own files.

### Findings from the first round

- **H1 (bluez5): resolved.** D11 and Part 4 now make
  `DISTRO_FEATURES:remove = "bluetooth"` in `kas-segno-common.yml` the primary
  path, keep `PACKAGE_EXCLUDE += "bluez5"` as the guard, and say why
  (`packagegroup-base` -> `packagegroup-base-bluetooth` -> `bluez5`,
  `bluetooth.service`). The sstate cost and the runner's 40 GB pre-flight are
  stated, and Part 4 gains a criterion that greps the kas file plus a manifest
  check for both `bluez5` and `packagegroup-base-bluetooth`. The P4 branch
  implements it (see the P4 review).
- **M1 (controls lost at P2): resolved.** §6 now names the three losses; D4
  says Parts 2 and 3 ship in one release; new D13 records the desktop
  separate playback/capture loss under the appliance-only decision; §1.3's
  table carries the exception.
- **M2 (brightness without keyboard): resolved.** Part 1 now uses the Loop
  settings slider (built and verified in the P1 delta), and Part 5 gains a
  criterion that checks Enter / arrows / Escape and the screen-reader
  actions.
- **M3 (USB P5 seams): resolved.** The build record names both seams
  (`destination_extra_providers.dart`; `transferInFlight` in
  `currentPowerOffSnapshot`).
- **L1 to L3: resolved.** One-update recovery is stated and the toast makes no
  promise; the ARB string is an ICU plural; the pairing files are kept on
  purpose with that reasoning.
- **Q1:** D3 adopts the recommendation (Maximum loop length on Device; the
  default multiple to Length & quantize in Part 5, with a pen write-back
  entry).

### New in this round

- Part 7 is now the `LoopSettingsFrame` pen conformance (#1230), carrying the
  shared-frame mismatches from the P2 review, with the font question left to
  that part's plan; geometry tokens became Part 8. Reasonable.
- Note: D11 says the kept pairing files "go with a factory reset". I did not
  find or verify a factory-reset path; if there is none, drop the clause.

Verdict: Approve.
