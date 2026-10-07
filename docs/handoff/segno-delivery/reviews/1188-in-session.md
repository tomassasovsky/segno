Model: Claude Opus (subagent), in-session

# Review of PR #1188: #1177 Part 3, `packages/usb_storage_client`

**Branch:** `claude/usb-storage-1177-p3` at 0d58caf18, base `claude/segno-integration`.

**Setup:** I worked in a temporary worktree and removed it afterwards.

**Runs:**
- `dart analyze --fatal-infos packages/usb_storage_client`: no issues.
- `dart test` in the package: +25, all passed.

## Verified correct (traced)

1. **A pure Dart package.** It depends on `equatable` only, with `test` and `very_good_analysis` as dev dependencies, and has no Flutter import. It mirrors the `wifi_client` shape: an interface, the Linux client, a fake and the unsupported client.
2. **The field names match P1's writer exactly.**
   - `generation`, `kname`, `fingerprint`, `label`, `fsType`, `mountPoint`, `sizeBytes`, `status`, `readOnly`, `writeBytesPerSecond`, `failureReason`, `eject{request, ok, reason}`.
   - The status values are `mounted`, `readOnly`, `unsupported`, `mountFailed` and `ejected`.
   - The JSON types match: integers, booleans, and strings or null.
   - The request body `{"generation":N,"request":"id"}` is what `segno-usb-ctl serve_one` reads with `json_get`.
3. **Watch versus initial scan.** The watch is started before the first `_readAll` in `onListen`, so a change landing between the two triggers a re-list. Events are filtered to `^[0-9]+\.json$`, on the path or the move destination, so the helper's `.<gen>.json.tmp` create is ignored. A burst of events within one event-loop turn coalesces into one list, and an unchanged list is not re-emitted.
4. **The un-awaited cancel is safe.**
   - The shared watch is reference-counted: the last listener's cancel drops the subscription and sets `_watch = null` without awaiting.
   - A listener arriving during that window gets a fresh watch, and the old cancel completes independently.
   - No leak: the old subscription is cancelled. No stuck watcher: the new one is fully live.
5. **Eject requests** are written to `.<id>.json.tmp` with `flush: true` and renamed into place, so the helper never sees a partial file. `cancelEject` tolerates a request the helper has already served.

## Findings

### 1. Medium: a record that is not valid UTF-8 is dropped silently

- **Where:** `linux_usb_storage_client.dart:115-133`. `file.readAsStringSync()` throws `FileSystemException` on invalid UTF-8, and the `on FileSystemException` branch treats that as "deleted between listing and read": the record is skipped with no log line.
- **Reproduced (with P1):** the helper's JSON for a FAT label `M\xe9SICA` (an accented Windows/OEM-codepage label) produced an empty list and **no** log entry. A control-byte label produced an empty list with a log entry.
- **Impact:** the stick is invisible, with nothing in the log to find it by. This is the client half of PR #1186 Finding 3.
- **Smallest fix:** read with `file.readAsBytesSync()` and decode with `utf8.decode(bytes, allowMalformed: true)`, so a bad label shows replacement characters instead of hiding the volume. Treat a `FileSystemException` other than not-found as a logged skip. Add a test with a 0xE9 byte in a label.

## Notes

- **The watch has no error handler.** `Directory(...).watch().listen(_onEvent)` has no `onError`. An inotify overflow or watcher error goes to the zone as an uncaught error, and the stream silently stops updating. Adding `onError` that logs and re-lists, and ideally re-establishes the watch, keeps the list live.
- **`isSupported` is decided once, at subscribe time.** If `volumes/` does not exist yet, the stream is a single empty list that never updates. On the appliance tmpfiles creates the directory at boot, so this is fine there.

**Verdict:** Approve with one fix. Finding 1 should land with P1's Finding 3, since together they make accented FAT sticks invisible.

## Delta review (33b522ec9)

Model: Claude Opus (subagent), in-session

**Scope:** `git diff 2124e9cd2..33b522ec9`: `linux_usb_storage_client.dart` (+63/-19) and its test file.

**Runs:** `packages/usb_storage_client` `flutter test` passes 30/30, and analyze is clean. Both runs were on the P4 head, which contains this commit.

### Earlier findings

1. **Fixed: a non-UTF-8 record was dropped silently.**
   - The client now reads bytes and decodes with `utf8.decode(..., allowMalformed: true)`.
   - `PathNotFoundException` is the only silent skip. Any other `FileSystemException` is logged.
   - The MÚSICA record through the client, with the fixed P1 helper output plus a hand-made raw-0xE9 record:

     | Record | Label shown |
     | --- | --- |
     | P1 helper output | `M\xe9SICA` |
     | control-byte label | `A\u0001B` |
     | raw-0xE9 record | `M�SICA` |

     All three volumes are listed.

### Earlier notes

- **Addressed.** The watch has `onError`, which logs and re-lists, and `onDone`, which logs, re-watches while the directory exists, and re-lists. A cancel does not reach `onDone`, so a deliberate unsubscribe does not restart the watch.
- **Not addressed.** `isSupported` is still decided at subscribe time. That is fine on the appliance, as noted before.

### New findings

1. **Low: the watch restart has no backoff.**
   - Suppose the platform watch errors and ends straight away while the directory still exists, for example when the inotify watch or instance limit is exhausted.
   - `onDone` then restarts it at once and re-lists, again and again, logging a line each time: a tight log-and-relist loop.
   - Fix: cap the restarts, or delay each one (for example 1 s, doubling).

- **Change from the original code (correct):** `entry is Directory` replaces `entry is! File`, so a record reached through a symlink is now read. The helper writes plain files, so this has no effect today.

**Verdict:** approve.
