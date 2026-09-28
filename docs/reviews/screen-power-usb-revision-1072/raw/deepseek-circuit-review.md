<!-- cspell:words opencode deepseek -->

# DeepSeek independent circuit review

Model: opencode-go/deepseek-v4.1-flash. Date: 26 September 2026.
Read-only source review; report below is advisory and independently triaged.

Review complete. Note: the worktree changed under me during the review — the Revision M work was committed as `d4fde195`, and `check.py`/`circuit-evidence.json` have further uncommitted edits still landing. Findings below are against the stable circuit (`switch_circuit.py` `652502f1`) and `check.py` `c7f09c4d`/`ccbd1f5a`; the concurrent edits are a dedup refactor that does not change any conclusion.

## Review basis

Read: `hardware/kicad/screen_power/{switch_circuit.py,check.py,hand/screen_power_hand.net,validation.json}`, `docs/reviews/screen-power-usb-revision-1072/{circuit-assessment.md,circuit-evidence.json,verify-circuit-source.py,review.md}`, `README.md`, and the prior defect brief (`usb-requirements-followup.md`). I did not run the generators (read-only). The native board is still Rev L (excluded per instructions).

## Verified correct (evidence-backed)

- **Coil moved to AUX; host only qualifies.** `switch_circuit.py:144-163`, netlist `S1_DATA_COIL_LOW = {D101.2, K101.8, Q102.3}` and `HOST1_5V = {J101.1, R101.1}`. The host divider is 9.1 kΩ Thevenin; there is no host→coil, host→bypass, or host→screen DC path. Host DC load: 50.5 µA normal, 0.556 mA worst fault (`check.py:602-605`).
- **Off-state blocking is real, not just AND logic.** Both TN0702s are N-channel (symbol pinout `1=S,2=G,3=D` confirmed in `hand/screen_symbols.kicad_sym`), so body diodes point up the stack (`GND→STACK`, `STACK→COIL_LOW`) and block coil current. `check_usb_power_states` builds directed anode→cathode edges (`check.py:660-665`), so a *reversed* upper/lower FET is caught as a host-independent (or GPIO-independent) coil path; I traced both self-test mutations to a genuine `usb_relay_state` failure.
- **Vgs margins** (host 4.4 V, AUX 4.75 V, 5 Ω/FET hot allowance): upper gate ≈ 3.80 V, lower ≈ 4.35 V, both > 3 V TN0702 drive point; coil ≈ 4.41 V vs 3.38 V pickup. Flyback cathode correctly at AUX (`D101 {1:AUX,2:coil}`).
- **GPIO low/floating and unpowered Pi default off**: Q2 emitter/base are AUX-referenced (`switch_circuit.py:106-112`); with AUX absent DATA_ENABLE is 0; R7 holds it low (`check.py:649`). No AUX→Pi back-feed path (PI_GPIO17 only sees R1/Q1 base).
- **No cross-channel enable**: per-channel `HOST_PRESENT`/upper FET; the 10 kΩ/100 kΩ divider is per host, and the state sweep ties each coil to its own host. The `cross_host_presence`, `presence_gate_bypass`, `host_coil_supply`, `host_reservoir` and `wrong_shield_net` controls all assert the right `check` code.

## Findings

**F1 — Medium (evidence integrity): `validation.json` is stale and misleading.**
`hardware/kicad/screen_power/validation.json` records `source_sha256.check.py = fd84970a…` and `switch_circuit.py = 9869038e…`, which do not match the committed `c7f09c4d…`/`652502f1…`; its `self_test` has only the old 61 keys and no USB-power controls, yet `cad_ready: true`. `README.md:436` still tells users this file is the check output. Anyone auditing via `validation.json` sees a pass that predates Revision M and none of the 13 new controls. The source-level evidence in `circuit-evidence.json` + `verify-circuit-source.py` is consistent and hash-matched, so the fix is to regenerate/commit `validation.json` (or repoint README to the new evidence). No circuit defect.

**F2 — Low/Medium (thermal qualification): hot-restart margin is an estimate with an 85 °C hole.**
Coil is continuously powered up to 5.25 V = 1.167× the 4.5 V rating. The only margin evidence is the model at `circuit-assessment.md:94-104` / `circuit-evidence.json:62-79`: +0.265 V at 60 °C local air, −0.026 V at 85 °C, built on 150 K/W, 1.4× and 0.00393/K estimates. Enclosure-local air is unmeasured, and the TE "continuous curve through 85 °C" cited at `README.md:246` is not reproduced in-repo. Keep as a first-assembly measurement gate, not a guarantee.

**F3 — Low (operating-range gap): relay pickup assessed only at AUX ≥ 4.75 V.**
`check.py:607` and the relocated guard use 4.75 V, while `README.md:58` advertises "4.5–5.25 V at J1". At 4.5 V with a hot coil (≈160–175 Ω) the same conservative model gives only ≈+0.03 V (60 °C) and ≈−0.26 V (85 °C). The assessment states the 4.75 V relay floor (`circuit-assessment.md:42`), but README should say the relay requires ≥4.75 V even though the board accepts 4.5 V.

**F4 — Low (test rigor): the "48-state" sweep is really 24 unique states.**
`check.py:645-646` iterates a `suspended` axis that is never used in the logic (appears only in the failure string, `:676`). Suspend is DC-identical (VBUS retained), so the result is correct, but the advertised "48 states / 96 paths" (`circuit-evidence.json:4-5`) double-counts. Drop the axis or assert the suspend invariance explicitly.

**F5 — Low (system assumption): floating-ON GPIO is indistinguishable from commanded-ON.**
The board's floating→off behavior relies on R2 100 kΩ pulling Q1 off (`switch_circuit.py:65`). A powered Pi leaving GPIO17 as an input with a pull-up would read as ON and enable the channel. `README.md:74-79` already requires the Pi to drive low; add the Pi default pull state to acceptance checks.

**F6 — Info: residual hot gate-leakage with an unplugged host.** `absent_gate` is modeled at 1 µA into 100 kΩ (`check.py:606`); with the cable unplugged only R102 sinks the node. Unspecified 125 °C gate leakage could bias the upper FET, but sub-threshold current is far below the 23 mA pickup, so the relay cannot close. Worth stating as a bounded leak, not a compliance claim.

## Scope limitations

Source/netlist contracts, the directed-body-diode state model, and DC calculations are the only evidence here; there is no analog/transient simulation, no assembled hot/ESD/eye/attachment-timing test, and the native board is still Rev L. The relay's TE maximum-coil-voltage curve and 125 °C gate-leakage limit are not in-repo, so F2/F6 remain unverified against primary data. All of this is acknowledged in `circuit-assessment.md:141-147`; the correction does remove the documented host-powered-coil suspend-current defect.
