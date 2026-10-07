Model: Claude Opus (subagent), in-session

# Review of PR #1186: #1177 Part 1, the image side

**Branch:** `claude/usb-storage-1177-p1` at 5ea4d5733, base `claude/segno-integration`.

**Read:**
- `segno-usb-ctl`;
- the udev rule;
- `segno-usb-mount@.service`, `segno-usb-eject.{path,service}`;
- `segno-runtime.conf`;
- the `segno.service` comment;
- the recipe diff;
- `run_usb_ctl_tests.sh`;
- the plan;
- the plan review.

**Setup:** I worked in a temporary worktree and removed it afterwards.

**Runs:** `run_usb_ctl_tests.sh` passes 66/66 under `TEST_SHELL=bash`, `TEST_SHELL=dash` and the default `sh`, from a script wrapper in a scratch TMPDIR. busybox is not available locally; I checked its applet flags by reading them.

## Verified correct (traced)

1. **Nothing from the drive reaches a path or a command line unfiltered.**
   - The mount point is `<gen>-<safe_name label>`, where `safe_name` is `LC_ALL=C tr -c 'A-Za-z0-9._-' '_'`. A label of `.` or `..` becomes `N-.` or `N-..` under `MEDIA_DIR`, which is not traversal.
   - Every expansion is quoted, including `mount -t "$(mount_type)" -o "$opts" "$dev" "$mp"`.
   - The fstype goes through a `case` allowlist before `mount`.
   - The label, fingerprint, fstype and request id are JSON-escaped for `\`, `"`, TAB and CR, and newlines are stripped.
2. **The kernel name agrees across udev and systemd.** udev's `SYSTEMD_WANTS+="segno-usb-mount@%k.service"` gives instance `sda1`. `BindsTo=dev-%i.device` and `After=dev-%i.device` name `dev-sda1.device`, and `ExecStart`/`ExecStop` use `%I` (`sda1`). USB kernel names need no escaping.
3. **Detach.**
   - After an eject, both umounts fail. Detach still removes the mount point and the JSON and exits 0 (tested).
   - A yanked busy device gets a lazy umount.
   - An unknown kname exits 0.
4. **Eject.** `sync`, then a non-lazy umount. Busy and error are told apart for both util-linux ("target is busy") and busybox ("Device or resource busy"). The request is deleted before it is served, and dotfiles are skipped.
5. **Mount options and fallback.**
   - vfat: `flush,utf8=1,uid/gid=0,fmask/dmask=0022`. exfat: same, without `flush`. ntfs goes through `ntfs3`. ext2/3/4: `noatime`.
   - A read-only fallback is tried once, and only after a failed read-write mount.
   - The JSON is written before the probe (review edit 2).
6. **Busybox and coreutils.**
   - The helper uses `sed -E`, `tr -c/-d`, `cut -c`, `head -n1`, `awk` (`index`, `substr`, `tolower`, `sprintf("%c")`), `dd conv=fsync`, `read -r`, `basename`, `mv -f`, `rmdir` and `udevadm`. All exist in busybox, and `coreutils` is already in RDEPENDS.
   - util-linux `mount`, `umount` and `blkid` are added to RDEPENDS.
   - Shell arithmetic is 64-bit in busybox ash and dash, so `sectors*512` for a 2 TB disk fits.
7. **The recipe.**
   - SRC_URI, FILES and `do_install` paths match. `98-*.rules` goes to `${sysconfdir}/udev/rules.d`.
   - Only `segno-usb-eject.path` is enabled (`WantedBy=multi-user.target`). The template and the eject service are not.
   - The tmpfiles lines live in the existing `segno-runtime.conf`.
   - No unit uses `PrivateMounts`, `ProtectSystem`, `PrivateTmp` or `MountFlags`, and the tests grep for that.
8. **The blank-media rule** has `DEVTYPE=="disk"` and `ID_PART_TABLE_TYPE==""` (review edit 7).
9. **The tests run the real helper end to end** with stubbed `mount`, `umount`, `udevadm`, `sync` and `dd`. They assert the JSON byte for byte, the option strings, the order of the two writes, both detach paths and both eject outcomes.

## Findings

### 1. Medium: concurrent attaches take the same generation, so one volume vanishes and its mount leaks

- **Where:** `next_generation` (`segno-usb-ctl:111-117`) reads `.generation`, adds one and writes it back, with no lock.
- **Trigger:** systemd starts one `segno-usb-mount@` instance per partition, in parallel. This happens for:
  - a stick with two partitions;
  - a multi-slot card reader;
  - two sticks present at boot.
- **Reproduced:** in 20 runs of `attach sda1 & attach sda2` with a 0.2 s `udevadm` stub, **13 runs** ended with two mounted volumes but only one JSON. The other record was overwritten under the same `<gen>.json`.
- **Impact:**
  - The app never sees the second volume.
  - At unplug, `detach` finds no record for that kname, so it never unmounts it. A stale mount and its directory stay under `/run/media/segno` until reboot.
- **Smallest fix:** serialize the helper. Wrap `attach`, `detach` and `serve-requests` in `exec 9>"$RUN_DIR/.lock"; flock 9`, and add `util-linux-flock` to RDEPENDS or use busybox `flock`. This also closes the attach-versus-eject lost update in the Notes below.

### 2. Medium: the write probe misreads `/proc/uptime` fractions `08` and `09` as octal

- **Where:** `uptime_cs` (`:179-186`) computes `$((whole * 100 + frac))` with `frac` taken verbatim.
- **What happens:** a two-digit fraction with a leading zero is octal in POSIX shell arithmetic, so `08` and `09` are arithmetic errors in bash, dash and busybox ash.
- **Reproduced** (real helper, stubbed `dd`), under dash and bash:

  | Uptime before | Uptime after | Probe prints |
  | --- | --- | --- |
  | 100.50 | 101.09 | **1677721600** (16 MiB × 100 / 1 cs), while the real rate was about 28 MB/s |
  | 100.08 | 101.09 | **null** |

  It affects about 4% of attaches.
- **Impact:** `writeBytesPerSecond` is what later parts use to decide whether a stick is fast enough to record onto. A bogus 1.6 GB/s can clear a slow stick for recording, which is the #710 zero-fill risk the review flagged.
- **Smallest fix:** `frac=${frac#0}` before the arithmetic, or `$((whole * 100 + 1$frac - 100))`. Add a test with uptimes `100.08` and `101.09`.

### 3. Medium: a FAT label with accented letters, or any control byte, makes the volume invisible

- **Where:** `decode_enc` (`:84-97`) turns every `\xNN` in `ID_FS_LABEL_ENC` back into a raw byte. `json_escape` (`:57-60`) escapes only `\`, `"`, TAB and CR.
- **What happens:**
  - A FAT label written on Windows is in the OEM codepage (for example `MÚSICA`, Ú = 0xE9 in CP850). udev escapes those invalid-UTF-8 bytes, and the helper writes them back raw, so the JSON is not valid UTF-8.
  - A label with a byte below 0x20 (other than TAB, CR or LF) writes a raw control character, which is illegal inside a JSON string.
- **Reproduced:**
  - The helper wrote `"label":"M\351SICA"` (byte 0xE9) and `"label":"A\001B"`.
  - Read through P3's `LinuxUsbStorageClient`, the list is **empty**.
  - The accented one is dropped **silently**: `readAsStringSync` throws `FileSystemException` on bad UTF-8, which the client treats as "deleted", so there is no log line.
  - The control-byte one is logged as `Control character in string`.
- **Impact:** for this owner, a FAT stick labelled with an accent never appears in the app, with no notice.
- **Smallest fix:**
  - Helper: decode a `\xNN` byte only when the result is valid UTF-8; otherwise keep the `\xNN` text or substitute `?`. Emit `\u00XX` for every byte below 0x20.
  - P3: read the bytes and decode with `utf8.decode(bytes, allowMalformed: true)`.
  - Test both cases.

## Notes

- **A stale request dotfile can disable eject for the rest of the boot.** `DirectoryNotEmpty=` also fires on a `.<id>.json.tmp` that the app left behind, for example after a crash between its write and its rename. `serve-requests` skips dotfiles but never deletes them, so the directory stays non-empty and systemd re-triggers until the path unit hits its trigger limit and fails. After that no eject is served until reboot. `PathExistsGlob=/run/segno/usb/requests/*.json` (glob skips dotfiles) avoids this, as does having `serve-requests` drop dotfiles older than a few seconds.
- **Attach and eject can overwrite each other.** `serve_one` rewrites the volume JSON from what it reads. If an eject unmounts between the probe's end and attach's second `write_volume`, attach writes `mounted` over `ejected`. The app then writes into the bare directory on tmpfs. The window is milliseconds; the lock in Finding 1 closes it.
- **Hardening:** no mount carries `nosuid,nodev` (or `noexec`), and ext4 is mounted with only `rw,noatime`. Everything runs as root and nothing executes from the stick today, but it is cheap to add for untrusted media.
- **A tab or CR in a label is not preserved across an eject.** `json_get` unescapes only `\"` and `\\`, so the rewrite turns them into literal `\t` or `\r`.
- **A superfloppy card in an attached reader may not mount.** The rules match `ACTION=="add"` only. Inserting a superfloppy SD card into a reader that is already plugged in raises `change` on `sdX`, not `add`, so it is not mounted. Partitioned cards add a partition and are fine.
- **Test gaps:** the tests do not cover concurrency, octal fractions or non-UTF-8 and control-byte labels. Findings 1-3 should each add a case.

**Verdict:** Request changes, for Findings 1-3. Each fix is a few lines, and none is visible in the stubbed suite today.

## Delta review (9eef51fe0)

Model: Claude Opus (subagent), in-session

**Scope:** `git diff 34e012bb8..origin/claude/usb-storage-1177-p1`, one commit, 5 files (+284/-56).

**Runs:**
- `run_usb_ctl_tests.sh` passes 79/79 under `TEST_SHELL=bash`, `TEST_SHELL=dash` and the default `sh`, from a scratch TMPDIR.
- macOS has no flock(1). Both the suite and my probes use a perl `flock(2)` stand-in on the inherited fd, which has the same semantics.

### Earlier findings

1. **Fixed: concurrent attaches.** `take_lock` (`exec 9>"$RUN_DIR/.lock"; flock 9`) wraps attach, detach and serve-requests, and `util-linux-flock` is in RDEPENDS.
   - Re-running my probe (20 rounds of `attach sda1 & attach sda2` with a 0.2 s `udevadm`) gave **0 of 20** collisions, down from 13 of 20. Generations were 1 and 2, with one record and one mount point each.
   - The suite adds ten rounds of three parallel attaches.
2. **Fixed: octal uptime fractions.** `frac=${frac#0}` is applied. Re-running my probe under dash and bash:
   - 100.50 → 101.09 gives 28435959, which is 16 MiB × 100 / 59.
   - 100.08 → 101.09 gives 16611104, which is 16 MiB × 100 / 101.
   - Before the fix these were 1677721600 and `null`.
3. **Fixed: labels.**
   - `decode_enc` decodes a `\xNN` only where the bytes form valid UTF-8. A lone 0xE9 stays as the text `\xe9`.
   - `json_escape` writes every byte below 0x20 as `\u00XX`, using awk under LC_ALL=C, which is byte-based in gawk, mawk and busybox awk.
   - Probe output: the helper wrote `"label":"M\\xe9SICA"` and `"label":"A\u0001B"`. Read through the fixed P3 client, all three records are listed: `M\xe9SICA`, `A\u0001B`, and a raw-0xE9 record as `M�SICA`.

### Earlier notes

- **Addressed.** `PathExistsGlob=/run/segno/usb/requests/*.json`, plus a `*.json` serve glob, so dotfiles can no longer wedge the path unit.
- **Addressed.** Every mount row carries `nosuid,nodev`.
- **Addressed.** The rules fire on `add|change`, and an empty reader slot (`ATTR{size}=="0"`) gets `SYSTEMD_READY=0`.
- **Addressed.** `serve_one` edits status and eject in place with sed, so a TAB or CR label survives. The edit is safe because every `"` inside a string value is escaped, so `"status":"` and `"eject":` can only match the keys. The request id is held to `[A-Za-z0-9._-]` before it reaches sed.

### Regression hunt

- **Deadlock: none found.** Under the lock, attach runs `udevadm info` (a database read), `mount`, `dd` and `sync`. Detach runs `umount` and `rmdir`. Serve runs `sync` and `umount`. None of these waits on udev, systemd or another helper instance. The units use SYSTEMD_WANTS, not `RUN+=`, so no udev worker blocks on the lock.
- **Lock-file permissions: fine.** `/run/segno/usb` is `0755 root root` (tmpfiles), and the helper runs as root with umask 022. Only root can create or replace `.lock`, so a symlink there is not a concern.
- **`change` does not remount.** The unit is `Type=oneshot` with `RemainAfterExit=yes`, so starting it while active does nothing. systemd also starts only newly added SYSTEMD_WANTS on `change`.
  - A superfloppy card cycles cleanly: pulling it sets size 0, then `SYSTEMD_READY=0`, the device unit goes inactive, `BindsTo` stops the mount unit, and `detach` runs. The next card arrives as a fresh plug.
- **fd 9 leaks into every child.** A `mount` stub found `/dev/fd/9` open in 40 of 40 calls.
  - This is harmless with today's image: every filesystem is a kernel driver, there is no FUSE package, and every child exits.
  - Leave this note so the case is covered if ntfs-3g or exfat-fuse is ever added: the FUSE daemon would inherit fd 9 and hold the lock for the life of the mount, and every later attach, detach and eject would block for good.
  - Cheap guard: run mount, umount and dd with `9>&-`.

### New findings

1. **Low: one stuck holder now blocks every drive.**
   - `flock 9` has no timeout, and a `Type=oneshot` unit has no default start timeout.
   - Before this commit, a `sync` or non-lazy `umount` stuck on a failing stick held only its own unit. Now it also holds every other drive's attach and detach. Note that `sync` is global, so a slow stick's dirty data delays an eject of a different stick.
   - The lock also lengthens what Part 4 sees:
     - A detach queued behind another drive's 16 MiB probe can arrive after P4's 2 s `volumeLossGrace`, so a pulled drive is reported as `io` rather than `volumeLost`.
     - An eject queued behind a slow probe or sync moves toward P4's 20 s timeout. See usb-p4 Finding 1.
   - Suggested fix: `flock -w 60 9 || { log "lock busy"; exit 1; }` for attach and serve. Let detach wait, because it is the cleanup path. Alternatively, sync only the target mount (`sync -f "$mp"`; coreutils is in RDEPENDS).

**Verdict:** approve. All three findings and the notes are fixed. New Finding 1 is low and worth a follow-up.
