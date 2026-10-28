# Rig art provenance (2026-10-28, issue tomassasovsky/segno#1501)

All 19 source images in `source/` were generated on 2026-10-28 with OpenAI
`gpt-image-2.5` (Figma's `generate_image`, model id `gpt-image-2.5-sunburst`).
The owner approved the set the same day. The images replace the Looper X rig art.

`source/`, the review sheet and the approved pedal template are not in this
repository: they are in tomassasovsky/segno-design, under
`docs/design/own-art/`. The `assets/` crops below are the `strip/`,
`selector/` and `footswitch/` folders here.

`assets/` holds the crops used by the app, at twice the slot size:
- strip: 582x458, from `flat-*`
- selector: 452x250, from `flat-*`
- footswitch: 580x250, from `photo-*`

The crops are centred.

## Flat illustrations (strip and selector)

Every flat prompt uses the same frame:

> Flat vector line-art illustration of SUBJECT. Monochrome palette in
> shades of COLOUR only: outlines and fills on a vertical gradient
> background. Bold clean uniform strokes, crisp modern app-icon
> illustration style. No text, no letters, no numbers, no logos, no brand
> shapes, no border, no frame.

| Rig | Subject | Colour |
|---|---|---|
| drum | generic five-piece drum kit with two cymbals, front view | azure #1e6ff0 |
| dub | bass speaker cone with concentric sound-wave rings and echo arcs | magenta-purple #b012e0 |
| edsguitar | small-body acoustic guitar standing upright | amber #f5a400 |
| guitar | solid-body electric guitar, diagonal, three-a-side symmetric headstock, original double-cutaway body | sky blue #7aa6dc |
| lo-fi | retro cassette in front of warped waveform lines | lime green #3dbb00 |
| rhythmic | top-down drum machine and mixer surface: pads, faders, knobs | cyan #12d6f0 |
| studio | home studio desk: screen with waveform, two monitors, keyboard and mixer | pink-magenta #e84cf0 |
| vocal | handheld ball-grille vocal mic, diagonal | coral red #e83c3c |
| vocaltuner | top of a vocal mic under a tuner meter arc with a needle pointing up | lemon yellow #d6e000 |
| singlefx | one stomp-box pedal from the top, two knobs and a round footswitch | emerald teal #12b98a |

## Footswitch photos

Every photo prompt uses the same frame:

> Moody cinematic photograph of SUBJECT, shallow depth of field, wide
> panoramic composition with the subject across the middle band. No text,
> no letters, no logos, no brand markings, no border.

| Rig | Subject |
|---|---|
| drum | drum kit on a dark stage, magenta and pink stage light through haze |
| dub | wall of stacked vintage speaker cabinets, warm low light, purple shadows |
| edsguitar | small-body acoustic guitar against a dark wall, warm amber raking light |
| guitar | glossy blue electric guitar body, red rim light from the left and blue from the right, original body outline |
| lo-fi | cassette deck and tapes on a desk at night, teal and magenta neon, film grain |
| rhythmic | drum machine and console at a low angle, pads glowing magenta and cyan |
| studio | cosy home studio: synth on a stand, acoustic guitar, monitors, warm lamp light |
| vocal | handheld mic lying on a glossy dark stage floor under a teal spotlight |
| vocaltuner | mic grille rising under a glowing tuner arc with a green needle, blue haze |

## What the app ships

- `strip/`, `selector/` and `footswitch/` hold the crops above under the
  slugs the Looper X art used, so `FxFamily.stripAsset`, `selectorAsset` and
  `footswitchAsset` resolve as before.
- `selector/edsguitar.png` is 1004x246, twice the 502x123 wide card the
  library gives Ed's Rack. It is the same vertical band of `flat-edsguitar`
  the 452x250 selector crop shows, scaled to 246 high and widened to 1004 by
  extending each row's edge colour; the background is a vertical gradient, so
  the extension has no seam.
- `selector/my-presets.png` is our own art from 2026-10-01 and is not part of
  this set.
- The new images are square-cornered. The widgets that draw the selector
  cards round them, as the old images had the corners baked in.
- The 38 stomp pedals are no longer images. The app draws each pedal in code
  from one template (the approved V2 design), in the colour of the Looper X
  illustration it replaces (`kFxStompColours` in the app).
- `assets/manifest.json` records only the presets now: the image entries
  named Looper X files and checksums these images no longer match.
