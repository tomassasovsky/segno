# Waveform reference audio

The Wave study uses measured PCM peaks, not generated shapes. `peaks.js` contains
1024 minimum/maximum sample pairs for each of four example recordings. Positive
and negative extrema are retained separately; no per-track normalization or
smoothing invents audio detail. The SVG joins those points into a continuous
amplitude envelope. A common amplitude scale leaves headroom for decoded MP3
peaks above full scale, without normalizing each track separately. It is an
overview, not a zoomed sample editor.

Sources: [MDN Web Audio multi-track example](https://github.com/mdn/webaudio-examples/tree/733def1c41939a7bb2ec4dc1be3603e3ae70af51/multi-track)
(`leadguitar.mp3`, `clav.mp3`, `drums.mp3`, `bassguitar.mp3`). MDN credits
[jPlayer](https://jplayer.org/) for the example tracks. The MDN repository supplies
[a CC0 license](https://github.com/mdn/webaudio-examples/blob/733def1c41939a7bb2ec4dc1be3603e3ae70af51/LICENSE).
Only derived peak data is included here, not the audio recordings.

To reproduce, download those four files at the pinned revision into a temporary
directory, then run `python3 build_peaks.py <directory>` with ffmpeg installed.
The output records each source file's SHA-256 and decoded duration.

The four peak sets demonstrate different musical shapes and repeat for Bank B.
They are not recordings of the prototype's named tracks. Capture reveals part of
these reference shapes; transport, overdubbing and edits remain simulated.
Production waveforms must be projected from each track's actual recorded buffer,
including edits and layers. This study does not claim that connection exists.
