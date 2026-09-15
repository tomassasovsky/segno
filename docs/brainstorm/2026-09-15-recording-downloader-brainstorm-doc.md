# Segno Transfer

<!-- cspell:words Elektron -->

## What We're Building

A small Mac app for connecting to a Segno appliance, browsing performances,
selecting recordings and individual audio files, and downloading verified copies
with meaningful names. The owner selected a standalone Mac app on September 15.

## Why This Approach

A native SwiftUI app can use the Mac's existing OpenSSH connection and native
folder chooser without adding a server to the appliance. A browser app would
need a new appliance service; an additional Flutter console target would bring
the instrument runtime into a file-transfer utility. Neither is needed here.

Established references: [Elektron Transfer](https://www.elektron.se/wp-content/uploads/2026/03/Transfer-User-Manual_ENG_OS1.10_260304.pdf)
uses connection, browsing and transfer progress; [Field Kit](https://teenage.engineering/guides/fieldkit)
is a focused companion for moving instrument content. Adopt the focused workflow,
while using SSH for Segno's existing network interface.

## Key Decisions

- Native Mac app, separate from the instrument app. No external Swift packages.
- Existing OpenSSH authentication and known-host verification; connection details
  and destination remembered locally, never committed.
- Default selection is the original main-output WAV. Additional input, loop and
  rendered stem WAVs are individually selectable and labeled by their roles.
- Names apply to downloaded files. Original appliance folders remain intact.
- Owner also requested full-length listening with seeking before downloading.
  Prepare a verified temporary copy, play it with AVFoundation, and remove it
  when the preview closes or the app quits. The download selection stays intact.
- Stream one file at a time, verify size and SHA-256, then publish the final file
  without replacing an existing file. Cancellation removes only our temporary copy.
- Read finalized manifests and complete WAVs; an unfinished or corrupt capture
  remains unavailable. File changes invalidate stale selections.
- Follow Segno's restrained typography and recording terminology; native Mac
  controls replace the appliance's touchscreen geometry. Record this companion
  layout and rationale in the design source.

## Open Questions

None blocking the first version. Appliance-side naming and broader platform
support require separate requests.

Tracked in #1056. Implementation and local delivery are authorized; merging is
subject to product review (`autonomy:merge-gate`).
