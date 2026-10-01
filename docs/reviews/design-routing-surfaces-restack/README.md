# Routing surfaces integration review

Issue #1016, PR #1020, campaign #1009. Local verification completed October 1,
2026. Remote CI and the existing human merge gate remain separate requirements.

## Behavior

Settings opens one Audio routing destination for input setup, recording
sources, output routes, output setup and port naming. Input monitoring remains
separate from the sources recorded into loops. Stereo source selection and
whole-track destination edits use the shared atomic mix transaction.

Source selection reuses available lane slots without moving recorded audio,
history, effect identity or lane identity. Missing-port intent can be removed;
new unavailable sources and changes that exceed capacity or interrupt an owned
recording gesture are refused. Explicit whole-track output changes also cover
future lanes. Imported mixed lane routes remain intact until that whole-track
change is requested. Existing stereo pairs cannot be edited into half-pairs.
Contradictory saved lane counts are rejected before replacing current audio.

Device-scoped names save before becoming visible. Same-name interface reopen,
pending writes and failed-write rollback cannot publish stale names. Names
fall back to Input or Output plus the physical port number. The fixed bottom
keyboard retains its draft on failure and requires explicit completion or
cancellation. Mono output preserves balance while disabling its control.
Larger interfaces scroll instead of shrinking the controls.

## Verification

| Suite | Passed | Coverage | Required |
| --- | ---: | ---: | ---: |
| App | 2,353 | 93.33% | 90% |
| Looper repository | 552 | 97.32% | 95% |
| Engine Dart interface | 332 | 68.57% | No floor |
| Session repository | 99 | 95.53% | 89% |
| Settings repository | 140 | 91.37% | No floor |
| Performance repository | 128 | 99.31% | 99% |
| Audio export | 100 | 100% | 100% |

The app retains six existing skips. Strict analysis, formatting, whitespace
and the actual 636-file Bloc scan pass. Unchanged package evidence was reused
only after comparing all source and test hashes. The final app run changed no
source inputs. Earlier failures remain in private evidence, including older
mock fixtures corrected without weakening their behavioral assertions.

Native ordinary, AddressSanitizer and telemetry-disabled suites pass, as do
race ThreadSanitizer and the C++ atomics shim. All 170 generated symbol lookups
resolve in the complete macOS library. Independent recorded-sample replay
confirms that queued source growth followed by recording preserves new audio
through Undo. Existing-recording completion and arm cancellation still work.

Independent review closed thirteen findings across native publication, slider
ownership/cancellation/reset, fixed naming sheets, odd-port reachability,
encoder focus, stereo-pair and session validation, alias lifetime/write races,
coalesced lane growth and the Cubit API. Conventions, architecture, test
quality, simplicity and readiness are separate review lenses. Authors did not
certify their own implementation; original counterexamples were replayed.

Forty-four relevant author-machine visual cases pass. Actual macOS interaction
confirms pan reset, outside-tap draft retention, explicit Cancel and balance
retention through Mono/Stereo changes. The routing implementation note was
saved in the owner Pen source and its disk change verified; unrelated owner
design edits were not copied into this code branch.

Source/test/golden fingerprint:
`38628183d10e773ce182e08ba24795800f1b48bb9a460bbb533ee7cdda5dba5b`.

## Limits

Remote CI must pass on the published head before ready-to-merge. The existing
human merge gate remains; these checks do not authorize deployment or flashing.
Backing-audio routing depends on the later media slice. Offline multi-lane
reconstruction and downstream effect behavior retain their separate owners.
Desktop checks do not establish appliance port availability, physical encoder
timing, interface hotplug reliability or audible hardware behavior.
