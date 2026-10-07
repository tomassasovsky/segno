Model: Claude Opus (subagent), in-session

# Review of claude/settings-1199-p7 at 1796d67c9: fix(ui): the settings frame matches the pen (#1230, #1199 Part 7)

## Scope

- **Branch:** `claude/settings-1199-p7` at `1796d67c9`, one commit on trunk
  `c4b5cf909`. There is no PR yet.
- **What changes in `LoopSettingsFrame`** (every Loop settings, Settings,
  Effects, Pedals, MIDI, routing and Library page):
  - seven new `SurfaceTheme` tokens (`frameBackground`, `frameRule`,
    `frameControlLine`, `frameControlFill`, `frameText`, `frameCrumb`,
    `frameIcon`);
  - two `LoopButtonTone`s (`frame`, `frameRaised`) and a chevron Back;
  - Arimo for the crumb, Stage and title, with a bundled
    `assets/fonts/Arimo-Regular.ttf`;
  - a 64-high title row when the frame carries actions;
  - about 90 goldens regenerated.
- Checked against pen group `01 CURRENT UX`, AGENTS.md and the owner rules.

## Runs

- Full app suite with `SEGNO_ENGINE_LIB`: `+3467 ~56: All tests passed!`
  (`app_exit=0`).
- `dart analyze --fatal-infos lib test`: no issues. `bloc lint lib test
  packages` from a scratchpad worktree: 0 issues, 870 files.
- **Pen comparison** through the pencil MCP (read and export only, never
  saved). Five pen screens were exported at scale 1, each against its golden:

  | Pen screen | Node | Golden |
  |---|---|---|
  | 05/01 Settings | `v7Ekz` | `settings_home` |
  | 05/02 Loop settings | `g37kn` | `loop_settings_hub` |
  | 05/04 Recording | `UV1lE` | `loop_settings_recording` |
  | 06/01 Length and quantization | `rmQ4f` | `loop_settings_length_defaults` |
  | 08/01 Pedals / Track controls | `KPWLz` | `pedal_setup_tracks` |

  - I sampled pixels and measured glyph bounding boxes. The text nodes'
    family, weight and letterSpacing were read with `Get`.
- **Weight probe:** a scratch widget test (deleted afterwards) read the
  resolved text styles in the frame:
  - crumb: Arimo, w400, letterSpacing 0.25;
  - Stage: Arimo, w400, letterSpacing 0.25;
  - title: Arimo, w400, letterSpacing -1.1.
  - The goldens' text has about 25% more ink than the pen's at the same
    weight. That is the difference between Skia's and the pen's rasteriser,
    not synthetic bold.
- **Font and licences:**
  - `fontTools` read the name tables of Arimo, Inter and JetBrains Mono;
  - I searched `lib`, `packages` and `assets` for `LicenseRegistry`
    registrations and font licence files.

## Verified correct (traced)

- On all five screens these match the pen exactly:
  - page and top-bar background `#111215`;
  - top-bar rule `#3d3d3d`;
  - Back line `#515d6e` with no fill;
  - Stage fill `#202735` and line `#515d6e`.
- The Back glyph is now a chevron, at the pen's position within 1 px.
- Crumb x is 126 in both. Title glyph tops match the pen and bottoms are
  within 1 px, which meets the plan's criterion.
- The 64-high action row puts Power (Settings) and Cancel / Save (Pedals)
  where the pen draws them. This removes the 2 px offset noted in the P2
  delta.
- All seven tokens:
  - are defined in both flavours and in `copyWith` / `lerp`;
  - are pinned by `test/looper/view/loop_settings/loop_settings_frame_test.dart`;
  - are the only colours the frame and its two button tones read.
- Arimo is registered as its own family in `pubspec.yaml`; page bodies keep
  Inter.

## Findings

### Medium

**M1. The app's licence notices leave out all three bundled fonts, and P7
adds a third.**
- No font licence text is shipped or registered:
  - `packages/segno_engine/lib/src/vendored_licenses.dart` registers only
    clap, miniaudio, rnnoise, signalsmith-dsp, signalsmith-stretch and
    vst3sdk;
  - `assets/fonts/` holds only the `.ttf` files;
  - nothing else calls `LicenseRegistry.addLicense`.
- So the About > Licences sheet lists none of Arimo, Inter or JetBrains
  Mono.
- **Arimo (Apache-2.0, new here):** Apache §4(a) requires giving recipients a
  copy of the licence. The font's name table carries only "Licensed under
  the Apache License, Version 2.0" and the URL (nameID 13/14), not the
  licence.
- **Inter and JetBrains Mono (SIL OFL 1.1, already on the trunk since
  `dc062bb0e`):** OFL condition 2 requires each copy to carry the copyright
  notice and the licence. Their name tables hold the copyright line and a
  144-character pointer to the OFL, not the licence text.
- On a GPLv3 appliance image that ships these files, that is a compliance
  gap.
- Fix:
  - commit `assets/fonts/LICENSE-Arimo.txt` (Apache-2.0),
    `OFL-Inter.txt` and `OFL-JetBrainsMono.txt` with their copyright lines;
  - register them through `LicenseRegistry`, either as a font entry beside
    `registerVendoredLicenses` or in its list;
  - extend `test/app/vendored_licenses_test.dart` to expect the three fonts.

**M2. The Arimo file comes from Autodesk Fusion's bundled copy, not from
upstream.**
- According to the coordinator, `assets/fonts/Arimo-Regular.ttf` was copied
  from the copy bundled inside Autodesk Fusion. I could not find that copy
  on this machine to compare hashes.
- The file reports:
  - "Arimo Version 1.23", vendor Monotype, Google's 2010-2012 copyright,
    Apache-2.0;
  - 2,584 glyphs;
  - sha256 `eafef8c9…b19e148`.
- Version 1.23 is the 2012 Croscore release. The current upstream Arimo is
  1.33, from `googlefonts/arimo` or `google/fonts/apache/arimo`.
- The licence permits redistribution, but a font lifted from a third
  party's application bundle has no provenance anyone can check: it may be
  modified or subset, and the repo records no source, version or hash.
- Fix:
  - replace it with the upstream release (static Regular, or the variable
    font if a weight axis is wanted);
  - record the source URL and hash in the commit or beside the licence
    file;
  - regenerate the goldens, since metrics may shift slightly between 1.23
    and 1.33.

**M3. The high-contrast flavour now draws the frame at dark-flavour
contrast.**
- `SurfaceTheme`'s high-contrast constructor gets the same seven values as
  `dark`. Before this commit, the high-contrast frame used `borderStrong`
  `#8a8a8a` for the Back and Stage lines (5.43:1 on the page) and `line`
  `#6e6e6e` for the rule (3.67:1).
- It now uses `#515d6e` on `#111215`, which is 2.8:1, and `#3d3d3d`, which
  is 1.72:1.
- Back has no fill, so its line is its only boundary. 2.8:1 is under the
  WCAG 1.4.11 minimum of 3:1 for a control's edge, and it falls exactly in
  the mode a user picks (the OS setting or the Displays page's High
  contrast switch) to get more contrast.
- Fix: keep the pen's values in `dark` and give the high-contrast flavour
  stronger frame values, for example `frameControlLine` = `borderStrong`
  and `frameRule` = `line`. Pin both flavours in the frame test.

### Low

**L1. The title's letter spacing is the same on every page, but the pen
varies it.**
- The frame always sets -1.1.
- The pen's titles use -1.1 on the Loop settings screens (`g37kn`, `UV1lE`,
  `rmQ4f`) but none on Settings (`v7Ekz`) and Pedals (`KPWLz`).
- As a result "Settings" is 140 px wide against the pen's 147, and "Pedals"
  117 against 122. Either pass the spacing in from the page, or align the
  pen.

**L2. The crumb and Stage inherit letter spacing 0.25 from the theme.** The
pen sets none. "SETTINGS" is 98 px against 96. Set `letterSpacing: 0` in the
frame's text styles.

**L3. Stage's label is 2 px low.** Its glyphs sit at y 40-61 against the
pen's 38-59 on every screen compared. Arimo's line metrics in a box with
`height: 1` put the label below the pen's text box.

**L4. Content differences remain that the frame cannot fix.**
- The Pedals crumb reads "SETTINGS / Pedals" where the pen's `KPWLz` reads
  "SETTINGS".
- The hub's body cards are `#1e1e21` where the pen's are `#22252b`.
- Both are page or string choices outside #1230's scope; list them for the
  owner.

## Notes

- **Merge with P5 (#1251):** two golden binaries conflict
  (`loop_settings_length_defaults.png`, `settings_device.png`). Every golden
  P5 adds for a framed page was drawn with the old frame, so whichever lands
  second must regenerate all of them, not only the two that conflict.
- The goldens' heavier text is a rasteriser difference (checked above), so
  it is not a finding.

Verdict: Request changes (M1 and M2 are licence and provenance issues that
should not ship in an image; M3 is an accessibility regression in an
existing mode).
