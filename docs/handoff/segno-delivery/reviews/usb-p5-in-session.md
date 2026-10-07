Model: Claude Opus (subagent), in-session

# Review of PR #1217: #1177 Part 5, the Storage page with USB volumes, eject and recording time

**Branch:** `claude/usb-storage-1177-p5` at a3de62da3 (one commit over P4 at a10cd2387), base `claude/segno-integration`.

## Scope

- The P5 commit only: 46 files, +2387/−253. That covers `lib/storage/**`, `StorageSystemTab`, the power-off gate, host and dialog, `ConsoleDialogTone.primary`, `PenIcon.drive`, the composition (`run_segno`, `App`, `AppRuntime`), the removed `ConsoleFactsClient` export API, the ARB files, the goldens and the plan diff.
- P4 is reviewed separately (usb-p4-in-session, delta at a10cd2387).
- Design: pen 31 `Storage & safe eject` (`PQ2W9`, six tiles `NxtNc`, `mEqa6`, `chgDv`, `gqcmf`, `p8bT0`, `Bn0vl`), read through the pencil MCP from the main checkout's `segno-ui.pen`, not saved. I exported three tiles to PNG in the scratchpad and compared them with the six new goldens.
- The builder's list of departures did not reach me (it is not in the PR body, the commit or #1177). The departures below are the ones I found myself comparing pen and code.

## Runs

- App suite (`flutter test`, `SEGNO_ENGINE_LIB` set): **3365 passed, 55 skipped**. The six `storage_*` goldens and `control_center_system_storage` ran and matched.
- `packages/performance_repository`: 130/130. `storage_repository` 60/60 and `usb_storage_client` 33/33 (P4 head, same code).
- `dart analyze --fatal-infos lib test packages/storage_repository packages/usb_storage_client packages/console_facts_client`: no issues. `bloc lint lib test packages`: 0 issues in 864 files.
- 9 mutations on `test/storage`, `test/appliance/power_off`, `test/system`: 7 killed. Survivors: the cubit's own lease check before `eject`, and its `on EjectRefused` catch (Finding 5).

## Verified correct (traced)

1. **Copy matches pen 31 verbatim** in all six tiles: `Internal` / `Sessions and audio`, `64.0 GB free`, `of 128 GB`, `Open library`, `60 hr 45 min recording remaining · estimated`, `48 kHz · 24-bit · Stereo`, `Internal storage · 1.0 GB reserved. Extra recordings and Undo audio use more space.`, `USB drive` / label / `Ejecting…` / `Safe to remove` / `Not connected`, `Your internal audio stays available.`, `Connect a drive to import or export audio.`, `Browse`, `Eject`, `Cancel`, `Could not eject. The drive is still connected. Try again.`, `No recording space`, `Internal storage is nearly full.`
2. **Numbers match the pen.** The recording time is stereo 24-bit at the applied rate (48 kHz → 288000 B/s), minus the 1 GB reserve: 64.0 GB free gives 60 hr 45 min, as the pen prints. Below one minute it reads `No recording space`, and with unknown capacity or rate `Remaining time unavailable`. Gigabytes are decimal, one place.
3. **Capacity is read only while the page is up** (review edit 11): on open, on every volume event, and on a 5 s `Timer.periodic` that `stopWatching` cancels in `dispose`. There is no app-wide timer; the cubit is app-wide only so shutdown can see it.
4. **Power-off reads `transferInFlight` from the repository at the press and again at every commit.** `PowerOffHost._snapshot()` asks `StorageRepository.transferInFlight` (leases or an eject in flight), not the cubit's last 5 s reading. `press`, `saveAndPowerOff`, `commitSave` and `retryPowerOff` all re-run `powerOffGate` on a fresh snapshot (`_prepareCommit`). The gate refuses on a take or a transfer. The dialog uses "Wait for the transfer" only when the transfer is the sole reason, so a take still gets "Stop the take first". The 2-minute in-flight eject from P4 also counts, which is right: halting mid-`umount` is what the guard is for. Mutations that drop the field, the gate term or the dialog choice are each killed.
5. **Eject is disabled while leased.** `StorageState.holders` comes from `leasesOn` on each refresh. A held drive draws Eject disabled (`IgnorePointer` + `ExcludeFocus` + `Semantics(enabled: false)` at the surface's disabled opacity) with the subtitle `<label> · in use for <purpose>`. A press that arrives before the next refresh hits the cubit's own `leasesOn` check, refreshes, and the button turns disabled. The repository refuses in any case (`EjectRefused`). Mutation "Eject enabled while leased" is killed.
6. **The console-facts storage API is removed cleanly.** `exportDestination` and `exportEverything` are gone from the interface, all three clients, the state, the cubit and their tests, along with `exportVolumeMounted` on the fake and `storageExportTitle`/`storageNoUsb` in both ARB files. `git grep` finds no reference left. The row never worked on the appliance (`LocalConsoleFactsClient.exportDestination` returned `''`), so nothing a user relied on goes. The open settings branches (#1199 p1-p3) host `StorageSystemTab` unchanged, so the page moves with that tab when the Settings tiles land, and none of them adds a use of the removed API.
7. **Composition.** `run_segno` builds one `StorageRepository` over `createUsbStorageClient()` with the engine's `statvfs` and directory sync. `App` builds an unsupported one only when none is injected, and disposes only that one. `AppRuntime` owns and closes the cubit.

## Pen departures (judged)

The host is the System tray's Storage tab, because the Settings tiles are not merged yet. Given that host:

| # | Departure | Judgement |
| --- | --- | --- |
| 1 | Host: no full-screen `SETTINGS` bar, back button, `Stage` button or `Storage` title; the cards head the tray's Storage tab. | **Accept.** The tray is the only host on trunk, and #1199 hosts the same `StorageSystemTab`. |
| 2 | Scale: cards about 106 px tall against the pen's 226, type 19/14 against 32/22, title column 250 against 340, actions slot 180 against 352, at the tray's scale with the pen's proportions. | **Accept.** The proportions and alignments hold: every bar ends at the same x, and the recording panel and warnings are inset from the cards as in the pen. |
| 3 | The breakdown (`This console`) and `Housekeeping` stay below the pen's content. | **Accept** (the plan keeps them as accepted housekeeping), but see Finding 4: Internal's free space is now printed twice on one screen from two readers. |
| 4 | Palette: Eject is solid app accent (saturated blue) with `onAccent` text, and the bar fill is the accent, where the pen draws Eject `#c4d4eb` with `#162132` text and the bar `#afc2dc`. | **Accept if** this is the app's standing mapping of the pen's primary (DS reconcile, #499). Otherwise write it back. The new `ConsoleDialogTone.primary` is the one place to change it. |
| 5 | Eject weight is `w600`; the pen's `Eject` is 700. The code comment says "Storage's `Eject` at 700" while the code sets 600. | **Nit:** fix the weight or the comment. |
| 6 | The pen draws an encoder focus ring on `Open library`. No golden shows focus. `StorageCardButton` is a `ConsoleDialogButton`, so it is focusable; a disabled one is excluded from focus. | **Accept.** A focused golden would pin it. |
| 7 | States the pen does not draw: read-only (`<label> · read-only`), in use (`<label> · in use for <purpose>`, Eject disabled), unsupported filesystem, unformatted, could not be opened, unnamed drive, capacity unavailable. | **Accept the behaviour, but write it back.** Per the "deviating updates the pen" rule, add these as tiles or `c/` notes in section 31. See Finding 3 for the purpose words. |
| 8 | `Browse` opens the sessions manager at Internal. | **Do not accept.** See Finding 1. |
| 9 | The low-space and could-not-eject notices are one line under their block, in the warning tone. | **Matches the pen** (`Bn0vl`, `p8bT0`). |
| 10 | `Ejecting…` keeps `Cancel` for the whole eject. | **Matches the pen's tile**, but see Finding 2 for after the helper has taken the request. |

## Findings

### 1. Medium: `Browse` on a USB card opens the Internal library

- **Where:** `lib/system/view/storage_system_tab.dart:77-80`: `onBrowse: (_) => unawaited(showSessionsManager(context))`, with the comment "The Library opens at Internal until #1178 gives it a USB view".
- **Scenario:** the player taps `Browse` on `SEGNO USB` and gets the Internal sessions list with nothing saying it is Internal. They believe they are looking at the stick: they delete or rename "old" sessions to free space on the stick, or conclude their export is not there.
- **Why it matters:** this is a silent behaviour substitution (rule 3) on a control whose whole meaning is "this drive".
- **Fix:** until #1178 lands, either leave `Browse` out of the card's actions (the pen's no-USB tile shows a card can carry fewer actions), or draw it disabled. Add a test that `Browse` is absent or disabled.

### 2. Low-Medium: `Cancel` does nothing once the helper has taken the request, and says nothing

- **Where:** `storage_page.dart:255-265` (`Cancel` in `ejecting`), `StorageCubit.cancelEject` → `StorageRepository.cancelEject`, which returns `Future<void>` and swallows the client's `false`.
- **Scenario:** after the helper takes the request, P4 keeps the eject in flight for up to 2 minutes (a slow `sync -f`/`umount`). The card shows `Ejecting…` and `Cancel`; tapping `Cancel` changes nothing on screen. On a slow stick this is the moment a player is most likely to tap it.
- **Fix:** have `StorageRepository.cancelEject` return whether it withdrew (the client already says so). On `false`, keep the card in `Ejecting…` and either hide `Cancel` or show a one-line "Already ejecting. Wait for it to finish." Better: expose "taken" on the eject phase so the card can drop `Cancel` as soon as the helper has it.

### 3. Low: the lease purpose is an untranslated identifier in UI copy

- **Where:** `storage_page.dart:244-246`: `l10n.storageUsbInUse(label, holders.join(', '))`. The ARB description says the purpose is "the writer's own word (recording, export, backup, copy)".
- **Scenario:**
  - In Spanish the subtitle reads `SEGNO USB · in use for export`. The template itself is also English-only, because `app_es.arb` gained none of the new keys.
  - Two copies show `in use for copy, copy`.
  - #1221 names the take's purpose `'recording'` and a session write `'saving a session'`, so the vocabulary is already drifting between owners.
- **Fix:** make the purpose an enum (or the guard table's `GuardKind` once #1221 lands), map it to localized words in the view, and de-duplicate.

### 4. Low: Internal's free space is drawn twice on one screen, from two readers

- **Where:** the Internal card (`StorageRepository.space`, statvfs at the exports root, refreshed every 5 s) and the `Free` row of the breakdown (`ConsoleFactsClient.storage`, statvfs at the sessions directory, read once on open). `_gigabytes` is also defined twice (`storage_page.dart:96`, `storage_system_tab.dart:197`).
- **Scenario:** during a recording or a copy the card ticks down every 5 s while `Free` keeps its value from page open, so the screen shows two different free figures. The committed `control_center_system_storage` golden shows the effect with fixture data: `64.0 GB free` above `Free 12.4 GB`.
- **Fix (rule 4):** drop the breakdown's `Free` row now that the card carries it. Or feed the breakdown's `Free` from the same `StorageState.internalSpace`. Share one `_gigabytes`.

### 5. Low: `StorageCubit.eject` has a dead branch with a wrong comment, and duplicates the repository's low-space rule

- **Where:** `storage_cubit.dart:120-137` and `:93-95`.
- **The dead branch:** there is no `await` between the cubit's `leasesOn` check and the repository's synchronous holder check inside `eject`, so `on EjectRefused` can never run. The comment "A lease was taken between the check above and the request" describes a race that cannot happen. Both survive mutation for that reason.
- **The duplicated rule:** `lowInternalSpace` recomputes `free < internalReserveBytes` instead of calling `StorageRepository.lowInternalSpace()`, so the rule now lives in two places.
- **Fix:** keep one guard (the repository's `EjectRefused`, caught, then refresh) and drop the pre-check. Use the repository's `lowInternalSpace`.

### 6. Low: `Could not eject` can sit under `Safe to remove`

- **Where:** `StorageCubit._onVolumes` keeps `ejectFailed` while the volume is still listed, and an ejected volume stays listed until it is pulled.
- **Scenario:** an eject reports `timeout` (P4's 2-minute cap, or the helper-side race in the P4 delta's Finding 1), then the helper finishes and the record turns `ejected`. The card says `Safe to remove` with `Could not eject. The drive is still connected. Try again.` under it.
- **Fix:** clear `ejectFailed` when that volume's status becomes `ejected`, and add a cubit test for it.

## Notes

- **Holders are polled.** The repository has no lease stream, so a lease taken or released shows on the card within 5 s, and only while the page is up. That is acceptable with the press-time recheck (Verified 5), but a `leases` stream on the repository would make it exact and remove the poll's reason to exist beyond capacity.
- **Overlapping refreshes.** The 5 s timer and a volume event can overlap; the later-starting refresh can emit before the earlier one, so a stale capacity can briefly win. Drop a refresh's result when a newer one has started (a generation counter).
- **`StorageSystemTab.initState`'s comment** still says "a USB stick may have arrived since the app started" about `ConsoleFactsCubit.load()`, which no longer reads USB.
- **`LocalConsoleFactsClient.deleteCapturesOlderThan` returns 0 without deleting** on the appliance. This predates P5, but `Delete old captures` now sits directly under a page that tells the user they are out of space. Worth a tracked follow-up.
- **Spanish:** none of the ~30 new strings is in `app_es.arb`. The plan allows "unchanged or only extended", but the tab now mixes the Spanish breakdown with English cards.

**Verdict:** Request changes, for Finding 1. It is small: hide or disable `Browse` until #1178. Findings 2-6 are low and can follow, though 2 is cheap to fix while the repository's `cancelEject` signature is still being shaped.

## Delta review (79e44868a)

Model: Claude Opus (subagent), in-session

**Scope:** the branch was rebuilt on the P4 follow-up (1dfb6a8ca, on trunk 890f04936). It now has three commits:
- ee04923d7: the original P5, rebased;
- 4236349ca: the review answers;
- 79e44868a: the Settings harness gets a `StorageCubit`.

I checked each earlier finding, the rebase resolution in the power-off code, the Settings harness, and Spanish completeness. Worked in a temporary worktree, removed afterwards.

**Runs:**
- App suite: 3493 passed, 62 skipped. The storage and `settings_storage` goldens ran and matched.
- `dart analyze --fatal-infos lib test packages`: no issues. `bloc lint`: 0 issues in 878 files.

### Earlier findings

| # | Now |
| --- | --- |
| 1 Medium: Browse opened Internal | **Fixed.** No Browse on a USB card, a doc note says why (#1178), and the key and criterion are dropped from the plan. |
| 2 Low-Medium: silent Cancel after the take | **Fixed.** `StorageRepository.cancelEject` returns whether it withdrew. On `false` the cubit sets `ejectTaken` while a drive is ejecting; the card drops Cancel and shows "Already ejecting. Wait for it to finish." It clears when no drive is ejecting. |
| 3 Low: raw purpose string | **Fixed in English.** `WritePurpose` enum (recording, copy, export, backup) in `storage_repository`, mapped to `storagePurpose*` words in the view, held as a `Set` so two copies read once. Spanish is missing; see new Finding 1. |
| 4 Low: free space drawn twice | **Fixed.** The breakdown's Free row and `storageFreeTitle` go (from both ARB files), and one `decimalGigabytes` serves the page and the tab. |
| 5 Low: dead branch, duplicated rule | **Fixed.** The pre-check and the dead catch are gone; `StorageRepository.isLowInternalSpace` is the one rule. |
| 6 Low: "Could not eject" under "Safe to remove" | **Fixed.** The failure stands only while the drive is listed and not `ejected`. A `stillEjecting` outcome is not reported as a failure (the drive keeps reading `Ejecting…`). |
| Nit: Eject weight | **Fixed** (`w700` for `primary`). |
| Pen write-backs | **Listed in the plan, not written.** See Finding 2. |

### Rebase and harness

- **`power_off_host`.** Trunk already carries the transfer guard: `currentPowerOffSnapshot` reads `StorageRepository.transferInFlight`, from the Settings Power work at ccb828632. The rebased P5 keeps trunk's host unchanged and adds only the dialog's "Wait for the transfer" copy and its tests. One snapshot function serves the rear button and the Settings Power destination, and there is no duplicate read. With the follow-up, `transferInFlight` also covers an unanswered eject. The resolution is correct.
- **Settings harness.** `extraProviders()` now provides `StorageCubit` over a `StorageRepository` with the unsupported client, an exports root that does not exist, and no `statvfs`. The page draws "Capacity unavailable", "Remaining time unavailable" and "Not connected" rather than the test machine's disk. `BlocProvider(create:)` closes the cubit.
  - In production the Settings Storage destination reads the app-wide `StorageCubit` that `App` provides (`app.dart:644`), so no second cubit exists outside tests.
  - The regenerated `settings_storage` golden now shows the page in pen 31's own host (`SETTINGS / Storage`, `Stage`, title `Storage`), which resolves the tray-host departure I accepted earlier.

### New findings

#### 1. Medium (owner rule: Spanish must be complete): 33 English strings have no Spanish

`app_es.arb` on trunk 890f04936 has every key `app_en.arb` has. This branch adds 33 keys to `app_en.arb` and none to `app_es.arb`, so a Spanish console shows the Storage page, its notices and the power-off refusal in English, next to a Spanish breakdown:

`storageInternalTitle`, `storageInternalSubtitle`, `storageOpenLibrary`, `storageFreeGigabytes`, `storageOfGigabytes`, `storageCapacityUnavailable`, `storageRecordingRemaining`, `storageNoRecordingSpace`, `storageRecordingTimeUnavailable`, `storageRecordingFormat`, `storageReserveNote`, `storageLowInternal`, `storageUsbTitle`, `storageUsbNotConnected`, `storageUsbConnectHint`, `storageUsbUnnamed`, `storageUsbEjecting`, `storageUsbSafeToRemove`, `storageUsbSafeToRemoveBody`, `storageUsbReadOnly`, `storageUsbInUse`, `storageUsbUnsupported`, `storageUsbUnformatted`, `storageUsbMountFailed`, `storageEject`, `storageEjectFailed`, `storageEjectUnderway`, `storagePurposeRecording`, `storagePurposeCopy`, `storagePurposeExport`, `storagePurposeBackup`, `powerOffTransferTitle`, `powerOffTransferBody`.

- **Fix:** add all 33 to `app_es.arb` in rioplatense Spanish, consistent with the existing `storage*` keys (for example "Libre", "Capturas").
- **Guard:** a test (or the gen-l10n `untranslated-messages-file` checked in CI) that fails when `app_es.arb` lacks a key `app_en.arb` has, so this cannot recur.
- **`storageUsbInUse` ("{label} · in use for {purpose}")** needs care. The purpose word is inserted, so the Spanish purposes must read after "en uso para…", for example "grabar", "copiar archivos", "exportar", "copia de seguridad".

#### 2. Low: the pen write-backs are listed but not written

- **Where:** the plan's new "Pen write-backs pending" list: read-only, in use, unsupported, unformatted, could not be opened, unnamed, capacity unavailable, and the Cancel-after-take state.
- **Why it matters:** the standing rule is that a shipped departure is written back into `segno-ui.pen` (geometry plus a `c/` note), not left only in a plan. Section 31 still has only six tiles, so the next reader of the pen will not know these states exist.
- **Fix:** add them to section 31 as tiles or `c/` notes before this lands, or record the owner's deferral.

### Notes

- **Card inside a card.** In the Settings host the Storage destination wraps its body in a bordered panel, so the Internal and USB cards sit inside an outer card (visible in `settings_storage.png`). Pen 31 draws the cards directly on the page. This belongs to the Settings host, not to P5. Mentioned so whoever owns the destination frame can decide.
- **Overlapping refreshes:** still possible (5 s timer and a volume event); unchanged and harmless in practice.
- **`LocalConsoleFactsClient.deleteCapturesOlderThan` still deletes nothing** on the appliance; unchanged.

**Verdict:** Request changes, for Finding 1 (the 33 Spanish strings). Everything else from the first review is fixed, and the rebase and harness are correct.

## Delta review (6f3ac7cfd)

Model: Claude Opus (subagent), in-session

**Scope:** P5 rebuilt on the follow-up at 79924ef02. The new commits are 003cb130e (the Storage page in Spanish) and 6f3ac7cfd (the still-ejecting hint). Worked in a temporary worktree, removed afterwards.

**Runs:** app suite 3495 passed, 62 skipped (including the follow-up's Spanish completeness test). `dart analyze --fatal-infos lib test packages`: no issues. `bloc lint`: 0 issues in 879 files.

### Checked

1. **The 33 Spanish keys.**
   - All 33 are in `app_es.arb`, and my script finds no English key missing in Spanish on this head.
   - Placeholders match key for key.
   - The words read naturally and match the existing Storage vocabulary ("Libre", "Capturas"). Examples: "{value} GB libres", "Quedan {hours} h {minutes} min de grabación · estimado", "Expulsar", "Ya puedes retirarla", "{label} · en uso para {purpose}" with purposes "grabar", "copiar archivos", "exportar", "hacer una copia de seguridad".
   - They use the tú forms ("Conecta", "Espera", "Formatéala") that the rest of `app_es.arb` uses, so the file is consistent. If the owner wants voseo ("Conectá", "Esperá"), that is a whole-file pass, not something to change here.
2. **The still-ejecting hint.**
   - The cubit sets `ejectStuck` only when its own eject returns `failed(stillEjecting)` and the drive still reads `ejecting`.
   - It clears on any volume event in which that drive is no longer ejecting: it answered, or it was pulled.
   - The card then shows "Still ejecting. If it does not finish, unplug the drive." ("Todavía se está expulsando. Si no termina, desconecta la unidad."), in place of the `ejectTaken` notice.
   - This gives the stranded-request case from the follow-up review a recovery path the player can see. The page and cubit tests cover it.

**Verdict:** Approve. Spanish is complete and the still-ejecting hint closes the dead end. The earlier pen write-back note (Low 2) remains as recorded.
