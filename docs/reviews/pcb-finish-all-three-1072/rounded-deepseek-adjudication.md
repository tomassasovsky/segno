<!-- cspell:words Collide spread fanout -->

# DeepSeek rounding review adjudication

26 September 2026, issue #1072. All three suggestions in the completed
[source-only response](rounded-deepseek-response.md) were checked against the
current source and accepted native inputs. **No actionable current-board or
helper-integrity defect was established.** No routing source was changed in
response. This bounded adjudication does not approve the manufacturing package.

| Reviewed input | SHA-256 |
| --- | --- |
| `round_routes.py` | `0de2ded7f6c115f5465c98f6408e9514169ed63ffa6335a147ceea692bfd0a05` |
| `screen_power/route_critical.py` | `cbcc9e5cafb4c0577889beb1bb5d0c70b2fa7555982ee3701b9ff2e8982ee547` |
| Screen native | `c06e6b35438b2fc7208cdc50feeebee92e6c01a56a00dadd280f697d1e49d79b` |
| Ring native | `188fd6ee4d395d1152fd5d840536ab0699a499cb50bf74539e2bb27273ddcbf2` |
| Console native | `27e690947142c2a31af171c4e2fc82c74b66183d790098299b0fb33b412b75aa` |

## 1. Same-net contact preservation

The source deliberately preserves existing electrical copper contacts. Native
`Collide(shape, 0)` covers overlap as well as touching; it is not restricted to
exact tangency. The helper does not promise to preserve every empty gap between
two pieces of the same net. Closing such a gap is not an electrical short to
another net. The proposed failure depends on a future nonzero same-net rule
that these boards do not specify, rather than a violated present requirement.

The [native regression and board review](rounding-review.md) verifies retained
contacts, foreign-net clearances, keepouts and fixed anchors. Current accepted
boards pass native DRC with no unconnected items; protected high-current paths
retain their locked geometry and required widths. Actual filled-copper review
remains necessary for appearance. A generic same-net gap-preservation feature
is outside this helper's stated contract; this source-only scenario establishes
no present defect and does not justify changing the finished routes.

## 2. The `spread()` assertion

The relay breakout uses fixed board/source coordinates, not arbitrary external
input. The actual saved coordinates for K101/K201 pins 6 and 3 give the same
result on all four terminals:

- Horizontal reach from x=28.15 to the pad column x=28.60: **0.450 mm**.
- Available vertical drop from the pair offset to the terminal: **2.035 mm**.
- Margin in the asserted inequality: **1.585 mm**.

Thus enabling Python optimization would not change these inputs or resulting
geometry. The actual build calls use ordinary KiCad Python without `-O`.
The report's claimed collapsed tail also misstates the formula: the returned
y-coordinate adds a signed `abs(reach)` to the coupled y-coordinate, so it
equals that coupled coordinate only when the reach is zero. An invalid future
placement is not evidence that this valid fixed placement folds back.

The [independent USB record](usb-review.md) additionally verifies actual native
terminal coordinates, simple connected paths, lengths, minimum 0.16 mm pair gap
and shorter uncoupled portions after rounding. No fabricated invalid input or
new mutation test is needed to establish the accepted geometry here.

## 3. Power overlays and rounded tracks

The premise does not hold for the accepted power blends. The critical screen
input, MOSFET bridge/feed and output runs, console 1.7 mm strip supply, and
ring 1.5 mm feed with its accepted taps are locked. The shared helper excludes
locked tracks. Those attachment paths and their power-overlay definitions
remain exact across its pass; the shared helper changes only eligible unlocked
narrower routes. Native outline/track-shape collision checks make the specific
premise testable: the five screen POWER overlays have 39 contacts with 32 distinct same-net
tracks, all locked, with **zero unlocked contacts**. The console POWER_FILLET contacts
one locked track and zero unlocked tracks. There is no adjacent unlocked
attachment edge for the helper to pull out of these overlays.

The [filled-copper and source review](rounding-review.md) checks the actual
unions after refill, including the console's former 0.050 mm slot, smooth
power joins and retained strip capacity. The [screen USB review](usb-review.md)
separately proves its scoped replacement left all non-ground filled copper
unchanged before the shared pass. None of these accepted contours relies on
an unverified claim that DRC alone detects cosmetic slivers. The model did not
read these native shapes and supplied no active sliver coordinates.

## Limits

The model review usefully challenges the scope of the helper, but its three
suggestions do not override the observed native evidence. The helper is a
bounded two-layer routing pass, not a solver for arbitrary future custom rules.
Final export-byte parity, final visuals and the existing first-assembly
qualification remain separate from this source-review result.
