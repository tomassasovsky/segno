# Pedal setup reconstruction

Track controls now use the accepted hardware map, with Press and Hold edited
together, all four track pedals selected as a group, and fixed controls dimmed
and excluded from selection. Settings and the Control tray both open Pedals;
Stage closes the originating tray. Local verification and independent review
are complete. Remote CI and the existing human merge gate remain separate.

Base: `da0c1f70d9815f68f9f5bb43e16f36de01a0b365`.
Original setup parent: `f93a4b6d7579bad91a3721a46de2c1b98712e260`.
The exact source, tests, design annotation and screenshot hashes are recorded
in [source.json](source.json). Subsequent source changes invalidate that binding.

## Implemented behavior

Edits stay in the page until Save confirms storage. Startup waits for the
saved setup before exposing editable controls. Cancel discards only the draft.
A failed write restores the exact previous stored value, including absence.
If storage also refuses restoration, the warning survives Cancel and leaving
the page; Save remains available to confirm the desired configuration.

Malformed explicit assignments never become active defaults. They remain
unavailable until the user reviews and saves replacements. Cancel preserves
the damaged data. Fixed transport controls remain usable. Unknown Custom
action identities remain unavailable rather than selecting another action.

Mode has independent Press and Hold. Record/Play and track presses retain
immediate contact. Track Hold works in Tracks; Record/Play Hold also works in
Mute. Holds follow the selected track or bank when they fire, while existing
session and take-lock guards remain. Arm overdub preserves a capture already
running or waiting for its quantized start. Bank Hold retains the working
performance-recording path.

## Repaired findings

| Failure | Correction |
| --- | --- |
| A late startup read could overwrite a new setup. | One shared load completes before editing or saving. |
| A failed Save could leave a different setup in storage. | Read back the new value; on failure restore and verify the exact checkpoint. Report an uncertain restoration explicitly. |
| A malformed saved Hold activated the default overdub action. | Preserve the saved bytes and disable configured gestures until a confirmed replacement Save. |
| Arm overdub could finish a capture started by another control between UI polls. | Check the fresh repository capture state before the directional action. |
| Arm overdub could cancel an already queued overdub. | Preserve the existing pending operation. |
| Mode and track-hold changes removed working performance access or Record Hold in Mute. | Retain Bank Hold and keep the distinct Record/Track mode guards. |
| The raised Bank cap extended beyond its touch bounds. | Expand the map bounds while preserving the accepted visible positions. |
| Stage left the underlying Control tray open. | Use the existing route callback to close the calling tray. |
| The desktop picker had an unattached visible scrollbar. | Give the grid and scrollbar one owned, disposed controller. |

Three historical real-engine fixtures still assumed the removed three-mode
cycle. They now use the configured Mute-to-Tracks press, preserving the
original recorded-audio and recovery assertions. The theme scanner retains
its checks; only the Fusion hardware artwork has the same explicit material
color exemption as the existing hardware simulator.

## Verification

- Full application: 2,310 passing tests, six existing skips, 90.41% coverage
  using the CI exclusions and the required 90% floor. Inputs stayed unchanged.
- Settings repository: 145 passing tests, 90.13% coverage; no configured floor.
  Its passing run is reused with exact unchanged package and dependency hashes.
- Six unchanged package suites: 1,356 passing tests and their configured
  coverage floors, reused only after matching source, dependency and native
  library fingerprints.
- Formatting, strict analysis, actual Bloc lint over 663 files and whitespace
  checks pass. The original failed broad run and its test-file drift remain
  recorded; it is not represented as a passing run.
- Fourteen independent adversarial checks across explicitly bound phases,
  including real native audio-state probes. Both final failing cases pass
  unchanged after repair. Earlier passing checks are reused only after
  reviewing the narrower later changes.
- Nine author-machine screenshot references were visually reviewed. The
  actual macOS development app also exercised selection, Save, Cancel,
  restart persistence, picker scrolling and Stage navigation. These are
  separate from CI and from physical-appliance validation.

One non-author reviewer performed all five quality roles and the complete
source review. A separate non-author adversary challenged the accepted
behavior. Five role reports do not mean five different reviewers.

## Staged capabilities and limits

Custom setup returns with actual Custom dispatch in PR #1030, together with
the accepted Mode Hold = Custom default. This slice exposes working Track
controls; its interim Mode Hold = FX is not the final accepted default.
LED color, external pedals, double-press Solo and later performance actions
retain their own slices. No unsupported action is advertised as operational.

The working accepted Pen design supplied the layout and pedal component.
The committed Pen canvas is older; a scoped implementation annotation is
saved there, and the existing implementation note in the working design was
updated. This does not claim that all committed screens match the accepted
working design. Full design synchronization remains a final campaign task.

No native audio, FFI or firmware code changes in this slice. Existing native
safety evidence is retained. Electrical behavior, physical timing and LEDs
still require the appliance. No merge, deployment or hardware validation is
implied by these local results.
