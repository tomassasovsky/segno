# FX and factory audio evidence — 2026-09-09

The local evidence pass is complete. Exact native control parity remains source-blocked. No FX domain, enum, reset default, playable factory file or audit closure is invented by this pass. The existing parameter descriptors are unchanged.

## Owner requirement — effects and parameters must match

The owner clarified the target after reviewing the completion pass: Segno must
have the same racks, their constituent effects, and the same parameters on
those effects as Looper X. Independent audio processing and different sounds
are acceptable. This is not permission to substitute a smaller effect catalogue,
omit controls, or use a generic parameter set for an unverified effect.

The distinction is catalogue and control parity versus sonic identity. Parameter
names and functions must correspond to the reference. Unverified control units,
ranges, choices, dependencies and reset defaults remain explicit evidence gaps;
this decision does not establish or waive them. Rack controls must not be assumed
to establish a similarly named Single FX schema.

The owner has no working Looper X or complete factory-content backup available.
Continue from the extracted sources and documented evidence. Original factory
audio is no longer a prerequisite for the Segno sound library; independently
provided sounds are acceptable and must not be described as Looper X originals.
The unavailable original collection remains a reference limitation, not a
mandatory product-completion gate. Production remains outside this pass.

The [evidence inspector](fx-reference-inspector.html) makes the remaining work reviewable: search 300 family/key identities, inspect values from all 159 saved presets, distinguish 61 established module enables from 239 unresolved control contracts, inspect the 26 unresolved Single FX schemas, and search 302 unavailable historical audio references. Its download contains the [exact missing-source list](fx-reference-evidence/missing-sources.json).

## Exact blockers

| Missing proof | Exact inventory | Required source |
|---|---|---|
| Native control type, units, domain, curve, enum labels and mode conditions for 239 family keys | `unresolvedControls` in [missing-sources.json](fx-reference-evidence/missing-sources.json) | Instantiated Looper X translator dump or official per-control schema, keyed by family and exact serialized key |
| Factory reset defaults | All 300 family keys; the 61 established enable controls also have no verified reset default | Reset/default capture with firmware version and provenance; a loaded preset is a separate state |
| Native Single FX control membership and behavior | All 26 names in `unresolvedSingles` in the same file | Native Single FX identity plus its own instantiated descriptor/schema; borrowed rack controls are insufficient |
| Usable factory audio and current collection identity | All 302 names in `unavailableFactoryAudio`; [historical name/byte manifest](../research/segno-looper-x-comparison/2026-09-08-recheck/factory-audio-reference-manifest.csv) | Looper X factory-content `Resources` and `looper.db`, or an authorized content export, with version and provenance |

A single content-partition export plus a runtime FX descriptor/reset capture would address these two source boundaries. The device capture must preserve exact source identities, all enum value/label pairs, dependent visibility/editability, and the normalized-to-display mapping. It must identify genuine factory reset values separately from initialization and preset values.

## New native evidence

The ARM binary contains more than isolated strings. A PC-relative reference trace located the constructor at ELF address/file offset `0x225b10`. Its 52 outgoing parameter calls have the exact Ed's Rack preset-key set. [native-constructor.json](fx-reference-evidence/native-constructor.json) records all 52 call sites, native indices and exact source names. It additionally captures five numeric arguments and a format argument for 24 calls, and ordered string-list arguments for four calls.

Examples:

- `Amp Drive`, native index 21, calls builder `0x223ffc` at `0x226990`, with float arguments approximately `0.18, 0.18, 0, 100, 0.1` and format argument `%.1f %%`.
- `Master Vol`, native index 51, reaches the same builder with arguments `0.5, 0.5, -12, 12, 0.1` and format `%.1f dB`.
- `Cab`, native index 25, calls `0x225468` at `0x226ce4`. The 12 ordered string arguments include `4x10"` twice, at indices 6 and 10. Both integer arguments are 6. The evidence retains the duplicate rather than deduplicating or interpreting those integers as defaults.

The [capture script](fx-reference-evidence/capture_native_constructor.py) pins binary SHA-256 `85b3339463dd5ad6a74f2d36d79ac58dd6afca6f5c539e41702429ab27929622`, executes only that constructor in an ARM emulator, intercepts its six outgoing builders, and fails if the binary, call targets, return or 52-index set changes. It does not run Qt, DSP, hardware code or the builders. This is reproducible argument evidence, **not an instantiated UI translator or factory reset capture**. The builder forwards the five float arguments into registers `s0–s4` at `0x2241d4–0x224210`; their final UI roles and transformation still require a complete trace or runtime observation.

Eight additional family constructor regions were located through `Master Vol` references (`0x20d3cc`, `0x21ac58`, `0x23b3b8`, `0x245eac`, `0x2507dc`, `0x25c73c`, `0x267d08`, `0x271ff0`). Limited execution reached inline property/processor dependencies before completing those constructors. These incomplete traces are not promoted into the inspector as schemas. The Guitar constructor also uses native `Wham` names where the saved schema uses `Whammy`, reinforcing the need to verify the mapping layer instead of matching approximate names.

The previous Qt metadata findings still apply: `NormalizedFloatTranslator` and `StringListTranslator` declare the fields needed for a complete schema, but declaration metadata does not supply each live instance's values. See the [prior reference closure pass](../research/segno-looper-x-comparison/2026-09-08-recheck/reference-closure-pass.md). No domains are inferred from preset extrema, adjacent strings or another HeadRush processor family.

## Official content check

The current Looper X specification explicitly lists **302** built-in drum/percussion loops. Its public support page links firmware 1.0.2, guides, a driver and a file converter; it did not expose a factory-content download in this check. [Official specification](https://www.sheeranloopers.com/looper-x.html), [official downloads](https://www.sheeranloopers.com/support-x.html).

The supplied Looper X 1.0.2 update has no content-partition payload. Its root filesystem expects a separate read-only `PARTLABEL=content` mount at `/media/hg03-content`, with `Resources` and `looper.db`. The exact prior source paths and hashes remain in [reference-closure-evidence.json](../research/segno-looper-x-comparison/2026-09-08-recheck/reference-closure-evidence.json). The cleanup script's 302 unique historical WAV names total 485,392,756 expected bytes; none is available as usable audio in the supplied extraction.

An additional meaningful public lead was checked: the official Looperboard 2.0.5 Mac updater, linked from the [HeadRush downloads page](https://www.headrushfx.com/downloads.html). Its [release notes](https://cdn.inmusicbrands.com/HeadRush/looperboard/READ%20ME%20-%20HeadRush%20Looperboard%20Firmware%20Update%20v2.0.5.pdf) describe moving factory loops into a separate non-user-editable location. This prompted inspection of the actual updater, without assuming Looperboard and Looper X collections are identical.

The downloaded FIT image contains only `splash`, `recoverysplash` and `rootfs`. The rootfs expands to 209,715,200 bytes; its regular-file common audio-header/extension scan finds only `usr/Looper/Resources/Metronome/metronome.wav`. Its `Scripts/runlooper`, lines 37–40, likewise requires the separate content `Resources` and `looper.db`. Payload offsets, sizes, archive/image/rootfs hashes and the exact download URL are in [public-package-check.json](fx-reference-evidence/public-package-check.json). The scan does not claim to exclude arbitrary embedded/custom encoding; the absent content payload and explicit mount contract are the decisive evidence. No substitute or generated sounds were added.

## Reproduce and demonstrate

For the existing design server, open:

- `/fx-reference-inspector.html` — Ed's Rack → Amp Drive. Change the saved preset; expand constructor evidence. Domain and reset default stay explicitly unverified.
- `/fx-reference-inspector.html?control=Cab&search=Cab` — inspect the ordered constructor strings. Switch to Guitar Rack; Ed's Rack evidence disappears instead of being reused.
- `/fx-reference-inspector.html?tab=singles` — inspect the borrowed rack source and the unresolved native Single FX schema.
- `/fx-reference-inspector.html?tab=audio&search=035%206-8%20Brushes%201.wav` — inspect exact historical file evidence and the unavailable playback state. Download the missing-source list.

These scenes are ready for the video as evidence scenes, not demonstrations of completed native FX or playable factory audio. Native controls retain normal browser keyboard navigation. The page is a standalone review tool and writes no application state.

```sh
node --test docs/design/verify_fx_reference_inspector.cjs
node docs/design/verify_fx_reference_inspector_browser.cjs
python3 docs/design/fx-reference-evidence/build_evidence.py --node node
```

The browser command uses the existing design server on port 8768, configured Playwright runtime, and local Chrome. `FX_REFERENCE_URL`, `FX_REFERENCE_OUTPUT` and `ATLAS_CHROME` may override those test inputs. To reproduce the native argument capture, install `pyelftools` and `unicorn` in an isolated Python environment and pass the original extracted `rootfs/usr/Looper/Looper` path:

```sh
python capture_native_constructor.py /path/to/rootfs/usr/Looper/Looper native-constructor.json
```

Validation on 2026-09-09: **7 Node cases passed; Chrome and Firefox browser journeys passed**. The browser tests cover exact preset selection, zero preservation, family isolation, all three collections, download contents, unavailable playback, no horizontal overflow, and no storage mutation. Eight browser screenshots were captured; the Amp Drive, Cab, Single FX and factory audio views were visually inspected. [Preview files](fx-reference-evidence/previews/). This evidence does not certify production/native behavior, hardware, CI or closure of the remaining reference rows.
