# Recording timing proposal

September 8, 2026. This extends the silent prototype; the new timing policies remain proposals for review. It does not change the accepted independence of fixed recording length from click audibility.

## What the player sees

- Count-in stays in the affected track column. From stopped, Record, Overdub and Play use the selected Off, 1, 2 or 4 bars. Starting several stopped tracks together shares one count-in. Stop cancels it. Adding a part while music runs uses the existing execution grid. External clock receives no extra local count-in.
- Sync and Band Auto recording can start at the chosen primary-cycle phase. A second press queues its ending at the primary cycle boundary; the column shows the beats remaining. Starting late leaves silence before the captured part. A longer take spans whole primary cycles. A compatible fixed shorter length remains available.
- With Auto, click off, internal clock and no existing recording, finishing the defining take interprets its duration as a whole number of bars and updates tempo. The brief result appears in the track column; the normal tempo and bar readouts then carry it. Audio duration is unchanged.

## First-take interpretation

This prototype compares 1–64 whole bars with tempos from 30–300 BPM. It chooses the candidate with the smallest proportional difference from the previously selected tempo; ties choose fewer bars. For example, a 3.5-second phrase near 120 BPM becomes two bars at about 137.14 BPM. This is duration interpretation, not beat detection or analysis of the recorded signal.

Click on, an existing recording, fixed length or external clock prevents this inference. If no candidate fits, tempo and the measured take duration remain unchanged. The audio, loop span, inferred tempo and recovery journal publish together. A failed write keeps capture and the previous clock intact, and retry uses the actual accumulated duration. Remaining time inside a transport update is measured in seconds even if finishing the take changes tempo.

The official [Looper X guide](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf) describes tempo/bar detection for an Auto first take without click. The candidate scoring above is a Segno proposal; the guide does not specify this algorithm. Segno retains its accepted fixed-bar behavior with click off.

## Scope and remaining decisions

These demos cover first-take timing, queued Sync/Band endings and count-in scope. Recording against a sped-up, reversed, Once or independent-time primary is explicitly unavailable in this draft; it explains the required Normal speed, Forward, Loop and Follow tempo state before capture starts. Changing primary speed, direction, repetition or tempo following during an active Auto capture is also refused. This is a visible prototype limit pending a capture-timebase decision, not an accepted permanent restriction. Explicit primary reassignment and primary deletion are still separate decisions; this slice does not introduce automatic handoff. Exact sample-clock divisions, actual audio analysis, external-clock loss/restart boundaries and native audio remain implementation or decision gates.

The previous capture-recovery rules remain in force: Multi partial recovery preserves the established loop span and places silence outside captured regions. No mode switch is added.

## Verification

The focused model suite uses actual transport commands, including non-zero primary offsets, exact boundaries, storage refusal/retry, count-in signatures, tempo limits and interval updates that straddle a tempo change. The normal-host browser suite exercises Chrome and Firefox, persistence and visible cues. Browser and Pen references are collected in the shared-behavior gallery. These are author-run prototype checks, not device or CI evidence.
