# Backing decode fixtures

Two one-second 1 kHz sines at 44.1 kHz, amplitude 1/8 (the ffmpeg `sine`
source's default), read by `test_engine_backing.h`
(`test_backing_decode_mp3_flac`). They are generated, not recorded, and can
be rebuilt with ffmpeg 8.0.1 (LAME 3.100):

```sh
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" \
  -af "pan=stereo|c0=c0|c1=c0" -c:a libmp3lame -b:a 128k -y sine1k_44k1_stereo.mp3
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" \
  -ac 1 -c:a flac -sample_fmt s16 -y sine1k_44k1_mono.flac
```

The MP3 decodes to 47232 frames at 44.1 kHz (41 MPEG frames): miniaudio's
MP3 decoder does not read the LAME gapless tag, so the encoder delay and the
end padding stay in as silence (ffmpeg trims them to 44100). The test bounds
the length accordingly.

The WAV cases are written by the test itself.
