<!-- cspell:words datasheets pinouts VBUS MOSFETs Littelfuse onsemi milliohm Mbps fanout Kimi -->
# Claude cloud review and disposition

25 September 2026. A real Claude Code cloud session, showing Opus 5, completed
an independent adversarial review of commit
`cc236a6cf0b26785f2fe7e83083a6964ed595743`. This is a coordinator summary and
assessment of its delivered report, not a verbatim transcript. Private session
and account information are retained outside the repository.

The reviewer verified the native board SHA-256
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`
and manufacturing ZIP SHA-256
`171034c87f3d371db9f7017a196960bdb7e01c249c1178eba90abb3ab2f05e3c`.
It recommended first-prototype bare-board fabrication and reported no verified
circuit, pinout, polarity, relay-contact or artwork defect. It did not qualify
assembled production hardware. No circuit, geometry, component or manufacturing
archive change follows from the verified findings below.

The owner's subsequent request to resolve the findings is recorded in the
[implementation follow-up](../screen-power-claude-fixes-1072/verification.md).
It specifies the missing external fuse/holder, exposes the supply-loss budget
and replaces the approximate R8 model. The initial dispositions below are
retained as review history; F1's missing-part selection and F6's preview
approximation are superseded by that follow-up.

## What Claude actually checked

The cloud reviewer parsed the native PCB, netlist, symbols and custom footprints
with its own scripts. It traced semiconductor and relay pins, body diodes,
power/control states and drive arithmetic. Its independent 0.05 mm copper
raster checked minimum-width power paths with and without the eight taper
zones, different-net clearances, ground regions and bottlenecks, thermal spokes,
USB neighbours and footprint courtyards. It also reconciled the drill census,
layer count and manufacturing archive. It formed its circuit assessment before
reading the earlier review conclusions.

KiCad and a STEP parser were unavailable in that environment. It did not rerun
ERC/DRC or inspect actual STEP solids. Direct manufacturer PDF access was
blocked; locally verified, page-referenced Vishay, TE and onsemi specifications
were supplied and explicitly treated as supplied evidence. Search summaries
provided secondary corroboration. Its first numerical ground-resistance solve
failed; its subsequent ground connectivity/bottleneck checks do not turn that
failed solve into a validated resistance result. This pass complements the
local KiCad and mechanical checks; it does not replace them.

## Disposition of the eight reported items

### F1 — Upstream 5 V protection: assembly requirement remains open

The coverage gap is real and was already explicit in the board README and
`external_bom.csv`: faults to ground at J1, C1/C2 or the shared switch/rail can
bypass all four downstream branch fuses. The 20 V input T5A fuse does not
establish protection of those 5 V faults. A short across a MOSFET or between
the live tabs can instead bypass the switch without excess current; an added
fuse cannot restore isolation in that failure mode.

Claude proposed a generic fast 6.3 A inline fuse. That is **not a verified
correction**. For example, Eaton S500-6.3-R must withstand 9.45 A for at least
one hour, and its maximum opening time at 13.23 A is 30 minutes. A nominal
10 A buck with unknown current-limit behaviour therefore cannot establish
prompt clearing from the fuse's nominal rating alone. This example is not a
purchase recommendation. [Eaton S500, page 2](https://www.eaton.com/content/dam/eaton/products/electronic-components/resources/data-sheet/eaton-s500-glass-tube-fuses-data-sheet.pdf).

Normal assembled operation still requires an exact protective device and
holder coordinated with the real source, conductors, ambient temperature and
startup energy. Put branch protection near the buck's positive output. The
existing current-limited first-power-up procedure remains applicable. Neither
this gap nor an unverified fuse choice justifies another bare-PCB revision.

### F2 — Removing data relays: optional architecture experiment

Claude suggested testing a VBUS-only cutoff to see whether the relays could be
removed. This does not demonstrate a defect in the retained deliberate data
disconnect, and it creates no new owner pre-order test requirement.

Its claim that every device's pull-up is powered from the same VBUS is too
broad: self-powered devices can use local power and VBUS sensing. The large
screen's high-speed disconnect behaviour also involves its high-speed
terminations, rather than only the full-speed 1.5 kΩ pull-up.
[ST AN4879, sections 2.6 and 3.1.1](https://www.st.com/resource/en/application_note/an4879-usb-hardware-and-pcb-guidelines-using-stm32-mcus-stmicroelectronics.pdf),
[Microchip disconnect guidance](https://support.microchip.com/s/article/USB-Device-Disconnect-Detection).

Retain the existing topology. The complete 480 Mbps path through purchased
cables, XH connectors and mechanical contacts remains an assembled qualification
item, already documented. Neither review establishes that the actual screens
would or would not remain powered through data lines without those relays.

### F3 — Gate-drive margin: retain the conditional rating

The nominal calculation gives about 4.626 V gate drive at J1 = 5.0 V and
4.478 V at J1 = 4.85 V, using 4.25 A and the assumed hot resistance. This
supports the existing warning about source/harness drop. Typical curves cannot
restore a worst-case resistance guarantee below the specified −4.5 V condition.
Claude's suggested curve-based recalculation is not accepted as qualification.
Its assertion that no component change could improve margin is also too
categorical. No component substitution is needed to record this existing limit.
[Vishay SUP70101EL, page 2](https://www.vishay.com/docs/77632/sup70101el.pdf).

### F4 — Startup and fuse energy: reject unsupported numerical fixes

Startup and fuse coordination remain unqualified, as previously documented.
Claude's 110 µs drain-transition estimate uses a single constant input
capacitance. The two MOSFETs have nonlinear capacitance and Miller charge;
Vishay specifies a typical 7 nF input capacitance per device at −50 V. That
simple RC calculation does not establish the actual output ramp or inrush.

The exact 0251.750MXL fuse has nominal melting I²t of **0.153 A²·s**, rather
than the unsourced generic range in Claude's report. Nominal melting energy
alone still does not qualify startup or fault clearing.
[Littelfuse 251, page 2](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).

Do not adopt the proposed 100 nF gate capacitor as an established fix. It would
alter turn-on, turn-off and linear-region stress; SOA and shutdown behaviour
would need evaluation. No such capacitor was added.

### F5 — Gerber-job wording: corrected

The job in the shipped ZIP contains no `ImpedanceControlled` key. The README
now says the field is omitted and no impedance-control declaration is made,
rather than claiming an explicit false value. The two-layer order and artwork
are unchanged.

### F6 — R8 preview approximation: documented

R8 uses a generic 6.3 mm model. The PR01 drawing distinguishes its **6.5 mm
maximum main body** from **8.0 mm maximum coating extent**; describing it as
an 8 mm body would overstate the discrepancy. The model notes now identify
the approximation and the actual dimensions. The existing 10.16 mm pitch
leaves 1.08 mm beyond each end of the coating, and minimum finished hole
0.72 mm accommodates maximum 0.63 mm leads. The conservative envelope clears
F202 by 2.38 mm and the board edge by 1.75 mm. No footprint or placement
change is justified. [Vishay PR01, drawing on page 16](https://www.vishay.com/docs/28729/pr010203.pdf).

### F7 — Courtyard gaps: no demonstrated body collision

Claude correctly reported small courtyard gaps, but then treated those as body
gaps. Independent STEP checks give body/solid separations of 1.37, 1.59, 1.95,
1.50 and 1.54 mm for the five cited pairs. Expanding resistor bodies to their
published maximum leaves the closest separation at 1.23 mm. A 0.1 mm assembly
offset does not establish the claimed contact. Normal centred lead forming
suffices; no extra assembly gate or PCB move follows.

### F8 — USB neighbours: informational

The relay-coil routes remain beside, not beneath, the data pairs. The nearby
enable route is essentially DC and crosses the data fanout rather than running
parallel. Claude recommended no change. These observations do not constitute
USB signal-integrity qualification.

## Result and publication boundary

Two documentation corrections were accepted. Known supply, protection, startup,
thermal and USB qualification limits remain visible; speculative relay removal,
generic fuse selection and gate-capacitor rework were not applied. No new
confirmed fabrication-blocking circuit or routing defect was found.

This is one completed external-model review. The requested OpenCode Go
DeepSeek/Kimi/Grok reports remain incomplete after provider limits; their partial
runs are not approvals. The stacked PR remains subject to its existing CI,
review and assembled-hardware gates. The cloud review did not order, merge,
deploy, flash or change account settings.
