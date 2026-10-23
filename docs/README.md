# Documentation

This folder holds a few documents that are kept current, a few file-format
specifications, and several hundred dated records of how the project was
designed and reviewed. The current state of the project is in the documents
under "Start here". Everything under "Design records" is history: it records
what was decided or checked at the time and is generally not revised later,
so it can disagree with the code.

## Start here

| Document | Contents |
| --- | --- |
| [`PROGRESS.md`](PROGRESS.md) | Project status: the active work threads, how to build and test, the architecture, what is done, and the roadmap. Updated as work lands. |
| [`TRACKING.md`](TRACKING.md) | How work is tracked in GitHub Issues: the pipeline stages, the autonomy labels, the merge gate and auto-merge rules. |
| [`RUNNING_ON_RPI.md`](RUNNING_ON_RPI.md) | Running Segno on the console (Raspberry Pi 5): how the app starts, logs, profiling, storage, the power button, touchscreen calibration, the audio interface and the on-device checklist. |
| [`HARDWARE_VALIDATION.md`](HARDWARE_VALIDATION.md) | Checks that need real hardware and cannot run in CI, with the results of the first bench pass. |
| [`APPLIANCE_INTEGRATION.md`](APPLIANCE_INTEGRATION.md) | A record of the September 2026 integration of the console link and the update delivery: which release it was built from, what it covers, and what the release pipeline checks. |

The build and layout of the rest of the repository are described in
[`../hardware`](../hardware/README.md), [`../firmware`](../firmware/README.md)
and [`../deploy`](../deploy/README.md).

## Formats

Specifications of the files the app writes and other tools read. The code is
authoritative where a specification and the code disagree.

| Document | Format |
| --- | --- |
| [`design/session-bundle-format.md`](design/session-bundle-format.md) | A saved session (`.segno`): a directory with a JSON manifest, one WAV per audio layer and a mixdown. |
| [`design/performance-manifest-format.md`](design/performance-manifest-format.md) | `performance.json`, the manifest written with each performance recording and read by the DAW export and the offline renderer. |
| [`design/performance-event-log-format.md`](design/performance-event-log-format.md) | `events.log`, the sample-accurate record of every change made during a performance recording. |

## Design records

Most changes follow the same path: a brainstorm compares approaches, a plan
sets out the work and its acceptance criteria, and reviews record what was
checked before merging. Each record is dated, in its file name or its
contents, and usually names the GitHub issue it belongs to. Later records and
the code supersede earlier ones.

| Folder | Contents | Count |
| --- | --- | --- |
| [`brainstorm`](brainstorm/) | Problem explorations and approach comparisons, written before planning. Named `YYYY-MM-DD-<topic>-brainstorm-doc.md`. | about 60 |
| [`plan`](plan/) | Implementation plans. Most are named `YYYY-MM-DD-<type>-<topic>-plan.md`, where the type is `feat`, `fix`, `refactor`, `chore` and so on; a few are specifications, execution guides or ledgers. | about 280 |
| [`reviews`](reviews/) | Review and verification evidence, one folder per change. A folder usually has a `review.md`, a `verification.md` or both, plus the JSON data the checks produced. Many cover the circuit boards and the enclosure (folder names ending in `-1072` belong to the PCB work in #1072). | about 70 folders |
| [`code-review`](code-review/) | Bug-focused code review reports, one `review.md` per folder. Many share a folder name with the matching folder in `reviews/`. | about 55 folders |
| [`research`](research/) | Research notes: component selection, Raspberry Pi 5 boot, a DIN MIDI bench session and the enclosure stomp-load analysis. | 4 |
| [`design`](design/) | Besides the formats above: dated UX proposals for the app's screens (`YYYY-MM-DD-<topic>.md`), HTML mockups and prototypes, screen images, the pedal face widget, and the console grounding scheme. | about 20 entries |
| [`handoff`](handoff/) | Handoff notes for the app redesign: the accepted behavior and a map of where it lands in the code. | 2 |
| [`reference`](reference/) | A description of the Looper X device's features and UX, used for comparison. | 1 |
| [`simulations`](simulations/README.md) | Browser previews of approved LED animations. | 1 |

[`2026-07-13-backlog-triage.md`](2026-07-13-backlog-triage.md), at the top of
this folder, is a dated record of the same kind: a sweep of the backlog as it
stood on that date.
