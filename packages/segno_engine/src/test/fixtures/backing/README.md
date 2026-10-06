# Backing decode fixtures

<!-- cspell:ignore lavfi libmp3lame msadpcm ADPCM -->

Read by `test_engine_backing.h` and used as seeds by the decoder fuzz driver
(`src/test/fuzz_backing_decode.c`, which takes every file in this directory
except this README).

## Generated with ffmpeg 8.0.1 (LAME 3.100)

Two one-second 1 kHz sines at 44.1 kHz, amplitude 1/8 (the ffmpeg `sine`
source's default), and three 0.2 s ones:

```sh
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" \
  -af "pan=stereo|c0=c0|c1=c0" -c:a libmp3lame -b:a 128k -y sine1k_44k1_stereo.mp3
ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" \
  -ac 1 -c:a flac -sample_fmt s16 -y sine1k_44k1_mono.flac
S="sine=frequency=1000:sample_rate=44100:duration=0.2"
ffmpeg -f lavfi -i "$S" -af "pan=stereo|c0=c0|c1=c0" -c:a libmp3lame -b:a 128k \
  -id3v2_version 3 -write_id3v1 1 -metadata title=short -y short_tagged.mp3
ffmpeg -f lavfi -i "$S" -ac 1 -c:a mp2 -b:a 64k -y layer2.mp2
ffmpeg -f lavfi -i "$S" -ac 1 -c:a pcm_s16be -y tiny.aiff
```

The stereo MP3 decodes to 47232 frames at 44.1 kHz (41 MPEG frames):
miniaudio's MP3 decoder does not read the LAME gapless tag, so the encoder
delay and the end padding stay in as silence (ffmpeg trims them to 44100).
The test bounds the length accordingly. The FLAC, MP2 and AIFF files are
refusal cases (FLAC is compiled out until #1235; MPEG Layer II and AIFF are
outside the whitelist). `short_tagged.mp3` has ID3v2.3 and ID3v1 tags around
ten MPEG frames: it was refused before the decoder learned to end the stream
at the ID3v1 tag.

## The #1223 review's reproducers

Crafted files from the Part 2 review (and one the fuzz driver found
afterwards), each now refused:

| File | What it did | Now |
|---|---|---|
| `ch256_s16.wav` | 256 channels: miniaudio freed a stack address and aborted the process | unsupported |
| `fact0_fmt1.wav` | a `fact` chunk of 0 bytes: dr_wav wrapped its size around and kept seeking for hours | damaged |
| `w64_huge_chunk.bin` | Wave64 with a huge chunk size: the same endless seek | unsupported |
| `msadpcm_oob.wav` | MS-ADPCM predictors of 250: an out-of-bounds table read | unsupported |
| `r44101.wav` | 44101 Hz: probed fine, then the converter refused it | unsupported |
| `f32_huge_values.wav` | found by the widened fuzz driver: float samples near `FLT_MAX`, finite, which the converter summed to Inf | damaged |

The WAV cases of the unit tests are written by the tests themselves.
