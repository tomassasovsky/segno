# Shared FX domain lookup review

Issue #1107, part of #1026. Reviewed October 4, 2026 against
`cc41ff7fcfad014fcd5c51af4f2556f18dc9cd2d`. Human merge gate retained.

The complete intended diff, including the new package file, has a clean
independent review. Correctness, removed behavior, callers, architecture,
conventions, simplicity, test quality, efficiency and publication scope were
checked. The existing lookup moves unchanged into the repository package; all
consumers use its public barrel. The unused MixTarget type, export and sole test
are removed together. No compatibility export or replacement model is added.

Two repository tests cover missing-owner refusal, absent lane identity, invalid
addresses and configured empty chains. Their fixtures specify stable slot IDs,
non-default empty-chain state and an explicit output-bus count. Initial fixture
failures are preserved in the private validation record; production behavior
was not changed to accommodate them. The independent reviewer inspected the
final fixture and compared the moved lookup with its original implementation.

Validation: 687 repository tests passed with 12 native-conditional skips and
95.172% coverage; 2,676 app tests passed with 124 conditional skips, excluding
the author-only screenshots tag. App coverage exceeds the existing 90% gate.
Strict workspace analysis and explicit formatting pass; Bloc analyzed 763 files
with zero issues. Tested and reviewed source hashes agree.

An additional unfiltered app run encountered 62 existing author-only screenshot
fixture failures. Those are outside this nonvisual correction; no screenshot
baseline was updated. They remain work for the visual reconciliation pass.
There are no unresolved actionable findings in this correction. Remote CI must
pass on its published head before it is ready to merge; this report does not
certify hardware or the wider Session/FX ownership refactor.
