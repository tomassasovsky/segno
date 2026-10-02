# Shared Playback: verification

The final ordinary application run passed 2,666 successful results, including
215 hidden setup/teardown results, with 112 native-only skips and no failures.
It used no native-library override or author fonts and excluded screenshots.
All bound inputs remained unchanged. Using only the workflow's existing
coverage exclusions, coverage is 24,836/27,354 lines (90.7948%), above the
unchanged 90% floor. No threshold or exclusion was added.

The final Looper repository suite passed 686 results, including 24 hidden
results, with 12 native-only skips. Coverage is 4,075/4,256 (95.7472%), above
the unchanged 95% floor. The earlier passing Settings run is reused against
unchanged package source: 166 results, three hidden, coverage 721/801 (90.0125%).
The unchanged Controller package retains its M3.12 result: 33 results, five
hidden, coverage 515/617 (83.4684%), above its 82% floor. Counts include hidden
results and do not imply additional independent cases. See [checks](checks.json).

Formatting, fatal-info analysis, Bloc lint and whitespace checks pass on final
source. Bloc scanned 733 intended Dart files through a verified non-hidden
alias. The ordinary suite and static runs had no source drift.

## Independent behavior and failure sensitivity

The reviewer froze a behavioral oracle before implementation. Its final 50
cases pass: 28 model/owner/source cases, ten actual native cases across all five
modes, eight lifetime/file cases and four edge cases. A prepared 8,192-frame
take stays playing just before its endpoint, then Once stops while Loop keeps
playing. Exported samples, length and history remain unchanged; Sync/Band
primary Once does not interrupt a sibling capture.

The isolated negative control bypassed native callback confirmation. It reached
actual enqueue with callback withheld, then failed the expected pending-owner
assertion. It did not fail compilation or a source-text check. The original
oracle, candidate source and frozen native library remained unchanged. The
[independent execution record](raw/adversary-independent-execution-v1.md)
preserves bindings, failures, fixture corrections and omitted permutations.

Root's actual App/Bloc integration checks passed six shutdown, pending-write,
refusal and inheritance cases. Two native Session Save/Save As cases wrote real
bundles with durable Released choices while live values stayed Held. All 41
bootstrap cases pass. Author runtime, repository, Settings, model and page tests
also pass; these overlap the aggregates and are not added into a total.

The standard native engine, MIDI and plugin result from M3.12 is reused after
comparing unchanged native sources and runner inputs. The frozen library hash
is unchanged. This slice modifies no native C, C++, FFI header or firmware.
Exact-head platform, sanitizer and telemetry-disabled CI still remain gates.

## Retained failures and corrections

- Review found Retry could skip malformed startup-value validation, and a
  reconnect during initial reads could strand readiness. Both were reproduced
  failing before repair. Retry now repeats initialization validation; startup
  follows the new device lifetime or adopts an already loaded session.
- The first aggregate failed on legacy fixtures exposing only one or two raw
  track slots. The device contract is eight slots, including empty tracks.
  Fixtures now model that topology; explicit malformed-vector tests remain.
  Out-of-range cases use the ninth slot, and invalid Once session intent is
  rejected without changing confirmed choices. Existing failure, audio,
  recovery and membership assertions remain.
- The first independent native attempt did not pump enough audio to finish
  the defining seam. The fixture now pumps 512 samples of the same input;
  its expected playback, PCM, length and history assertions are unchanged.

Initial and intermediate failed logs remain retained. The final fixture delta
is reviewed separately from the earlier independent product execution.

## Native UI and design

Two new 1920 by 1080 native renders cover MIDI Loop/Once endpoints and External
Held Once / Released Loop. Existing Custom Playback and generic shutdown
recovery references were rechecked or reused. The eight existing Loop settings
renders passed. The [saved design binding](design.json) records Pen section
`B5yE6R`, inspected bounds and file hash.

The actual development app was restarted onto this product. A new External
Playback mapping began Loop/Loop. Held Once and Released Loop saved correctly;
removing it then cancelling restored the saved row and endpoints. The temporary
review mapping was removed afterward, preserving existing assignments.

Desktop UI and deterministic callback checks do not prove physical controls,
appliance timing, hotplug or actual OS halt. The inherited M5 full Session Load
with a live Control owner remains separate; successful Save and owner adoption
do not constitute full recall proof.
