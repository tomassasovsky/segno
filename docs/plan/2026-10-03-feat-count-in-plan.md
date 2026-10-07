# Shared Count-in delivery (#1026)

Status: reviewed direction, implementation authorized within the existing
delivery campaign. Base: `505fbcad19303b78396035c807409ee5a706f132`.

Count-in and Sound-start currently have independent optimistic writers. The
native countdown also handles only one defining recording. The accepted design
requires Off/1/2/4 bars, one coherent relationship with Sound-start, a shared
launch from stopped, and the same setting through touch and assigned controls.

Deliver three working increments in order:

1. [Confirmed recording-start pair](2026-10-03-feat-count-in-part-1-plan.md):
   atomic acceptance, persistence, touch, startup, Session and shutdown.
2. [Shared stopped launch](2026-10-03-feat-count-in-part-2-plan.md): one deadline,
   per-track membership and deterministic sample boundaries.
3. [Count-in mappings](2026-10-03-feat-count-in-part-3-plan.md): External and MIDI
   controls, temporary values and safe release.

Part 1 retains the existing one-track countdown until part 2. Part 3 follows
the scheduler; a mapping-only patch does not complete shared Count-in. Every
part needs its own source-bound independent oracle, implementation review,
required checks and current-head CI. No production edit precedes its oracle.

Authority: `docs/handoff/segno-app/accepted-behavior.md` sections 2 and 4,
the accepted Loop settings and transport studies, and the parameter-mapping
catalogue. The application default is one bar when neither key exists; explicit
Off and explicit Sound remain distinct. The fresh native engine starts Off
until application restoration confirms its preference.

Review corrected the package boundary and found a fourth Sound consumer in
the Loop settings hub. App value types must not become lower-package imports;
all four surfaces move together and the obsolete mirrored state is removed.
No-source Sound recording needs an explicit repair reason. Independent scope
review established these three increments. A mistaken first-capture-wins
hypothesis was withdrawn after tracing the prototype's successful zero-length
finish: later pending insertion wins without creating an empty layer.

Future external-clock Receive and a stopped failed-capture journal do not yet
have runtime producers. Keep those integration obligations explicit; do not
simulate completion with UI flags. Physical verification and human merge
approval remain separate. No deployment is authorized by these plans.
