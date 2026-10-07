## Verdict: approve with required plan edits

### Claim verification (22 spot-checked on `c3714abc2`)

Correct: `segno-kiosk-launch:15-20` (HOME=/data, root), `segno-bundle.bb:126` SYSTEMD_SERVICE, `:128-180` FILES, `:240-275` do_install, `main.yaml:395-442` and `:43-47`, `segno-update-ctl:43-56`, `local_console_facts_client.dart:117-121,135-169`, `console_facts_client.dart:12-38`, `storage_system_tab.dart:37-39,62-63,151-166` (208 lines), `console_facts_cubit.dart:42,115-126`, `system_tray_panel.dart:46`, `create_console_facts_client.dart:15`, `performance_recorder_cubit.dart:42-50,66-80,97-131`, `performance_repository.dart:60,193,284-310`, `session_directory.dart:18-21`, `power_off_gate.dart:47-69`, `power_off_host.dart:67-73`, `run_segno.dart:97-100,155-158`, `app.dart:446-471,593-603`, `system_faces_test.dart:616,648+`, `test_engine_core.c:9279-9296`, `audio_engine.dart:1436`, `native_audio_engine.dart:2266`, `mock_audio_engine.dart:1645`, `PROGRESS.md:506-512`, accepted-behavior §6.6-6.8/§6.12/§7.7/§7.8 line ranges, pen 31 copy (verbatim match for all six tiles).

Wrong or incomplete:
- `perf_drain.c`, `segno_engine_api.h`, `engine_snapshot.c` live at `packages/segno_engine/src/core/`; the plan cites bare filenames (the line numbers themselves are right: `:126-150`, `:485-500`, `:706-709`, `:1268-1276`, `:1434`, api `:2980`, snapshot `:392`).
- `stage_library` is in `lib/looper/view/stage_top_bar.dart:52` (`showSessionsManager(context)`), not `tracks_commands.dart` (no library command there).
- `.github/cspell.json` exists and the `spell-check` job runs `**/*.md` with `modified_files_only: false`. The plan .md itself uses ~20 words absent from `words`: exfat, ntfs, ntfs3, vfat, udev, blkid, statvfs, kname, fmask, dmask, superfloppy, udisks, hfsplus, apfs, btrfs, LUKS, inotify, EROFS, exfatprogs, fsync, umount. Merging the plan as written fails CI.

### 1. Correctness on the appliance

Confirmed sound: `segno.service` has no `User=`, `PrivateMounts`, `ProtectSystem` or `PrivateTmp`, so root-namespace mounts under `/run/media/segno` are visible and `uid=0,gid=0` options give the app write access. `98-` sorts before `99-systemd.rules`, which consumes `TAG+="systemd"`/`SYSTEMD_WANTS`. `BindsTo=dev-%i.device` + `After=` is the right pair; `segno-runtime.conf` is installed as tmpfiles.d, so the `d /run/...` lines are the right place.

Problems:
- **Detach after eject.** Once ejected, the device unit stays active until unplug; then `ExecStop` runs `umount` (fails: not mounted) and `umount -l` (also fails). Unless detach tolerates both, the unit enters failed state and the "ten cycles, `systemctl --failed` empty" criterion cannot pass.
- **Attach latency.** The 16 MiB probe runs before the JSON exists, so a 2 MB/s stick takes 8+ s to appear and the 3 s criterion fails. Wear is negligible; ordering is the issue.
- **Probe timing source.** Busybox `date` has no `%N`; coreutils is not in the image. The plan names no clock, so the literal `writeBytesPerSecond: 16777216` oracle is undefined.
- **inotify race.** Writing `3.json.tmp` inside `volumes/` emits a create event for the tmp name; the "one list of three" criterion is racy unless the client filters names.
- **Label in mount point.** `/run/media/segno/1-SEGNO USB` embeds an arbitrary FAT label in a POSIX-sh helper; needs sanitising.
- **Second udev rule** (blank stick) has no `DEVTYPE` restriction, so it fires on an unformatted partition of a partitioned stick too.
- **vfat `flush` vs the 2 s ring.** `LE_PERF_CAPTURE_SECONDS` is 2 (`engine_private.h:162`). `flush` makes every FAT write near-synchronous; a stall >2 s zero-fills the take (#710). Part 6 records straight onto that mount and only checks `perfOverruns`.

### 2. Real-time safety

Clean. Detection is inotify, eject is a file write, statvfs is a synchronous FFI call on the Dart main isolate (control thread), recorder cadence stays 5 s. The gap: Part 5 never states how often `StorageCubit` calls statvfs; an app-wide periodic timer would be wasteful (not audio-unsafe, but unbounded).

### 3. Layering

VGV-correct: `usb_storage_client` (pure Dart, mirrors `wifi_client`) → `storage_repository` → `StorageCubit`. No duplication of power/update services. `StorageUsage.freeBytes` and `StorageRepository.space(internal)` both answer internal free space, but Part 2 routes both through the same injected statvfs reader, so they agree; acceptable.

### 4. Removing the export placeholders

Not silent and no conflict. Pen 20 shows per-item "Export to USB" under LIBRARY / Audio (E7-13, a consumer of this service); pen 44 covers whole-appliance backup. No accepted screen has "Export everything". `LocalConsoleFactsClient.exportDestination` returns `''`, so the row was never tappable on the appliance, and §2.5 documents the removal. DAW export (`daw_export`, `.als`/stems from `exportsRoot`) does not touch `exportEverything`. Two issues: the removal list omits `console_facts_state.dart`, `fake_console_facts_client.dart` (`exportVolumeMounted`), `unsupported_console_facts_client.dart`, `console_facts_client_test.dart`, `console_facts_cubit_test.dart` (8 refs) and `app_es.arb` (2 keys); and deleting Spanish keys contradicts Part 5's "Spanish file unchanged or only extended".

### 5. Part split

Parts 1-4 and 6 are independently mergeable. Part 5 ships `StorageDestinationPicker` and `ConnectUsbSheet` with no consumer (Library is #1178, recorder is Part 6): dead code at merge, against AGENTS "smallest version that works end to end". Hardware criteria are realistic except the 3 s attach (fixed by edit 2) and the Part 6 overrun check (edit 10).

### 6. Tests

Parts 1, 3, 4 and 6 literal oracles fail without the change. Part 2's "free equals the test's own statvfs" is flaky on a CI disk that is being written between the two calls. Part 5's grep criterion is sound.

### Required edits (apply mechanically)

1. Add to §5 Part 1 files: "`.github/cspell.json`: add to `words`: exfat, ntfs, ntfs3, vfat, udev, blkid, statvfs, kname, fmask, dmask, superfloppy, udisks, hfsplus, apfs, btrfs, LUKS, inotify, EROFS, exfatprogs, fsync, umount." Add to every part's VERIFICATION COMMAND: `npx cspell --config .github/cspell.json docs/plan/*.md`. Delete any sentence claiming no cspell config exists.
2. Part 1 attach: "write `<gen>.json` with `status: mounted`, `writeBytesPerSecond: null` before the probe; rewrite it (tmp + mv) after." Criterion 1 becomes two JSON writes; the first with null.
3. Part 1 helper: "elapsed time from `/proc/uptime` (centiseconds), path overridable by `SEGNO_USB_UPTIME_FILE`; the test supplies two readings 1.00 s apart." Remove any dependence on `date`.
4. Part 1: tmp files are `volumes/.<gen>.json.tmp` and `requests/.<uuid>.json.tmp`; `serve-requests` ignores dotfiles. Part 3: client ignores names not matching `^[0-9]+\.json$`; add criterion "a `.3.json.tmp` create emits nothing".
5. Part 1 criterion 3: append "detach of a volume already `ejected` (both umounts fail 'not mounted') still removes the mount point, deletes the JSON and exits 0."
6. §2.2 mount point: "`<generation>-<label>` with the label reduced to `[A-Za-z0-9._-]`, other bytes replaced by `_`; empty label falls back to the kernel name." Oracle path becomes `/run/media/segno/1-SEGNO_USB`.
7. Part 1 second udev rule: add `ENV{DEVTYPE}=="disk"`.
8. Part 1 criterion: "`run_usb_ctl_tests.sh` greps that no unit under `files/segno-usb-*` and `segno.service` contains `PrivateMounts`, `ProtectSystem`, `PrivateTmp` or `MountFlags`"; add a comment line to `segno.service` stating why.
9. Part 2 criterion 1: replace "free equal to the test's own statvfs" with "`total` equals the test's `f_blocks*f_frsize` exactly; `free` within 64 MiB of its `f_bavail*f_frsize`; `total >= free`."
10. Part 6 HARDWARE: add "`perfZeroFilledFrames` stays 0". §8 open point 4: "vfat `flush` is kept for yank-safety; if Part 6 shows zero-fill on a stick above 4 MB/s, Part 6 drops `flush` from the vfat row in Part 1 (one-line change, logged)."
11. Part 5: "StorageCubit reads statvfs on page open, on every volume-list event, and on a 5 s timer only while the Storage page is mounted; no app-wide timer."
12. Move `StorageDestinationPicker`, `ConnectUsbSheet` and their criterion (picker bullet) from Part 5 to Part 6; Part 5 becomes about 450 lines, Part 6 about 530; §6 unchanged.
13. §2.4: replace "`stage_library` in `lib/looper/view/tracks_commands.dart`" with "`lib/looper/view/stage_top_bar.dart:52` (`showSessionsManager`)".
14. §2.5: list the six extra files from §4 above; Part 5 criterion becomes "the Spanish file only loses the two removed keys or gains new ones."
15. §1: cite engine sources once as `packages/segno_engine/src/core/{perf_drain.c,segno_engine_api.h,engine_snapshot.c}`.
