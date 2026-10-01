# Architecture review

Status: complete for freeze-v2, fingerprint `263eb7002dcaf03c6b1f23a24c406a81541e1e5cdb3aea95b7d4d85bcc630582`; all 31 paths rechecked. Critical: 0. Important: 0. Suggestions: 0. No unresolved actionable finding.

Reviewer disclosure: the independent source reviewer performed all five roles sequentially. These are distinct review perspectives, not five separate independent agents. Product authors and the adversarial tester are separate. No product edits, tests, builds or Git mutations were performed by this reviewer.

Layer violations: 0. Dependency direction violations: 0. New package/dependency additions: 0.

The palette belongs to the app-owned pedal setup vocabulary, beside gesture assignments. Its immutable built-in/custom references and validated detached maps separate identity from RGB. SettingsRepository persists the encoded setup atomically as opaque data. The repository and protocol remain free of Flutter imports and editor concerns.

Presentation owns draft selection and the HSV dialog; ControlCubit owns confirmed setup and action lifecycle. Projection reads confirmed palette hue while computing activation from the existing action/engine state. PedalCubit continues to expose the repository's actual published frame. PedalSetupMap overrides only hues for a local draft and preserves unknown-frame darkness, independent selection, and bank semantics. LED context displays physical controls across banks without changing the active bank.

Hue-only comparison excludes palette values from behavioral equality, preserving Hold target identity, pending gestures and FX restoration obligations. The completion guard still checks accepted result, closed/unavailable state, mode, true behavioral replacement, session and per-button token. No native mutation is used to preserve a lamp.
