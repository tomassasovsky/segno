---
title: A take from the pedal, opened in Ableton Live
date: 2026-11-22
summary: Segno now writes every recorded performance as an Ableton Live set, with a stem for each loop and the console's effects as plugins, and a Mac app opens it in Live in one click.
---

Segno can record a whole performance, a take, while you loop. Until this week the take came out as finished audio: what the speakers played, plus each track as it sounded. That's fine for listening back, but not for working on the take later. This week the take became an Ableton Live set you can keep editing, and a small Mac app opens it in one click. Segno is still in development, and all of this runs on the bench console.

## What gets recorded

First the console had to record the clean signal. Before [#1809](https://github.com/tomassasovsky/segno/pull/1809), a take tapped each input after its monitor chain, so an input played with monitoring off came out silent. Now every input monitored at arm, and every instrument with a patch, is also written raw, before its effects.

At the end of a take, the console renders stems from that recording and its event log. Since [#1826](https://github.com/tomassasovsky/segno/pull/1826), every lane of every looper track gets two: a dry stem, the loop as it played with nothing after it, and a wet stem, the lane after its volume, effects and mute. The console writes the Live set right after that render, at the end of every take.

## The Live set

Each looper track is a Group track in Live. Inside it, each lane has a track that plays its dry stem through that lane's effects, and an "(as heard)" track with the wet stem, switched off, kept as a reference.

The effects are Segno's own. The console's effects code also builds as VST3 plugins, and [#1811](https://github.com/tomassasovsky/segno/pull/1811) loads each lane's chain into Live as those plugins, with the settings it had at arm. To check them I rendered a set of 31 tracks, one plugin each, from Live 12.2.7 and compared it with the engine's own render. 19 plugins were bit-identical, 5 were below -120 dBFS, and the other 7 were between -101 and -116 dBFS at their peak. Those 7 are bit-identical in our own test host, so the difference comes from rounding in Live's host. For a real take of 150 seconds, Live's render of the track was -139.6 dBFS (peak) away from what the console played.

A loop doesn't stand still while you play it, so [#1839](https://github.com/tomassasovsky/segno/pull/1839) replays the take's changes as Live automation: every effect switched on or off, every knob moved and every effect swapped in a slot. Each change is a step at the frame it happened. The same PR stopped the plugins from reporting a latency, because the console doesn't compensate one. With nothing reported, Live plays every lane with the same timing the console did.

The plugins also have a face now. [#1819](https://github.com/tomassasovsky/segno/pull/1819) gives each one an editor that draws its pedal the way the console's Effects page does, with every value printed, and Live's parameter list reads values the way the console shows them ("348 ms", "1/8D").

## Getting it onto the Mac

Segno Transfer is the Mac app that browses and downloads takes from the console. [Segno Transfer 0.3.0](https://github.com/tomassasovsky/segno/releases/tag/transfer-v0.3.0), released this week, adds Open in Live ([#1830](https://github.com/tomassasovsky/segno/pull/1830)). It downloads the set and only the files it references, checks each one's SHA-256 against the console's copy, and moves the folder into place only after every file passes. On the bench, a take of 547 MB (the set and 11 audio files) came over in 17.5 seconds. A second click reused the verified copy in 10 ms.

The app carries Segno.vst3 and offers to install it when the set needs it and it's missing or older ([#1831](https://github.com/tomassasovsky/segno/pull/1831)). The set is written as a Live Project folder ([#1838](https://github.com/tomassasovsky/segno/pull/1838)), so Cmd+S saves it in place, and Open in Live now reopens your edited copy instead of downloading a fresh one ([#1841](https://github.com/tomassasovsky/segno/pull/1841)).

## Still open

The app and the plugin are signed locally, not notarized by Apple, so macOS asks you to approve each once in Privacy & Security. Live's own save of the reference set with the new Group tracks is still owed ([#1826](https://github.com/tomassasovsky/segno/pull/1826) explains the check), and Cmd+S saving in place still needs a check in Live 12.
