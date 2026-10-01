# M3.4 independent visual review

The non-author reviewer opened all six frozen setup goldens: Tracks, grouped track pedals, Mode Hold picker, unreadable setup, Custom Bank B and Clear confirmation. Their hashes match freeze-v1, fingerprint f2f6fb73b326b5e7889b4ee4fdd6ff02b9d1d42d2cff74abee0c680226a3376f.

All six preserve Layout A: hardware map remains visible behind the paired editor; fixed controls are dimmed; Track controls select all four positions as one group; Custom Bank B labels positions 5–8 and keeps Mode fixed; selection feedback is distinct from runtime LEDs. The fresh Mode values read Mute/Custom. None, Exit, Mute, FX and Custom fit the picker without clipping. The unreadable warning occupies the gap between rows and remains clear of caps, LEDs and header actions. Clear confirmation states both-bank/both-gesture draft scope and Save/Restore behavior. No actionable visual finding in these images.

The saved integration design note qaI7U was independently read through the Pencil MCP with the integration canvas active. It records the current Custom runtime, shared Solo owner, fixed Exit/Bank, local Restore semantics, and warning placement. Its explicit boundary is correct: this older repository canvas does not represent the entire accepted working design. No raw design-file contents were read or edited.

These are independent inspections of author-generated captures, not independent screenshot generation or CI visual execution. The combined Clear/Restore plus persistence-uncertainty state is covered by the authored interaction/bounds regression, not by these six images. Electrical behavior, appliance timing, arbitrary viewport and whole-canvas acceptance are outside this review.
