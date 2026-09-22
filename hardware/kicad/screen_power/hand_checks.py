"""Electrical and assembly contracts for the through-hole screen carrier.

These checks establish CAD invariants, not USB compliance, fuse coordination,
relay lifetime, or operation of the attached screens.
"""

import re


def _fail(errors, code, detail):
    errors.append({"check": code, "detail": detail})


def _resistance(components, ref):
    value = components[ref][2]
    match = re.match(r"^(\d+(?:\.\d+)?)\s*([kKMR]?)", value)
    if not match:
        raise ValueError(f"Unrecognized resistor value {ref}: {value}")
    return float(match[1]) * {"": 1, "R": 1, "k": 1000,
                             "K": 1000, "M": 1000000}[match[2]]


def check_through_hole(board, errors):
    """Reject surface contacts even on a footprint incorrectly marked THT."""
    import pcbnew as p

    for footprint in board.GetFootprints():
        ref = footprint.GetReference()
        if footprint.GetAttributes() & p.FP_SMD:
            _fail(errors, "hand_assembly", f"{ref}: surface-mount footprint on THT carrier")
        for pad in footprint.Pads():
            if pad.GetAttribute() not in (p.PAD_ATTRIB_PTH, p.PAD_ATTRIB_NPTH):
                _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: pad is not through-hole")
            elif pad.GetAttribute() == p.PAD_ATTRIB_PTH:
                drill = pad.GetDrillSize()
                if drill.x <= 0 or drill.y <= 0:
                    _fail(errors, "hand_assembly", f"{ref}.{pad.GetNumber()}: through-hole pad has no drill")


def check_contract(pins, nets, errors):
    """Protect the supply boundaries and fail-off relay connections."""
    def require(ref, mapping):
        for number, name in mapping.items():
            got = pins.get((ref, str(number)))
            if got != name:
                _fail(errors, "hand_contract", f"{ref}.{number}: {got!r}, required {name}")

    def nodes(name, expected, code="hand_contract"):
        actual = nets.get(name, set())
        if actual != expected:
            _fail(errors, code, f"{name}: missing {sorted(expected-actual)}; extra {sorted(actual-expected)}")

    require("J1", {1: "AUX_5V", 2: "GND"})
    require("J2", {1: "PI_GPIO17", 2: "GND"})
    nodes("PI_GPIO17", {("J2", "1"), ("R1", "1")}, "pi_isolation")
    if any(name.startswith("PI_PIN_") for name in nets) or any(ref == "J3" for ref, _ in pins):
        _fail(errors, "control_interface", "Obsolete 40-pin pass-through remains")
    require("R1", {1: "PI_GPIO17", 2: "DISPLAY_ENABLE"})
    require("R2", {1: "DISPLAY_ENABLE", 2: "GND"})
    require("Q1", {1: "GND", 2: "DUMP_BASE", 3: "DISCHARGE"})
    require("R3", {1: "DISPLAY_ENABLE", 2: "DUMP_BASE"})
    require("R4", {1: "DUMP_BASE", 2: "GND"})
    require("R5", {1: "AUX_5V", 2: "DISCHARGE"})
    nodes("DISPLAY_ENABLE", {("R1", "2"), ("R2", "1"), ("R3", "1"),
                              ("J104", "1"), ("J204", "1")})
    nodes("DUMP_BASE", {("R3", "2"), ("R4", "1"), ("Q1", "2")})
    nodes("DISCHARGE", {("Q1", "3"), ("R5", "2"), ("Q101", "2"), ("Q201", "2")})

    for ch in (1, 2):
        n, pre = 100 * ch, f"S{ch}"
        host, main, touch = f"HOST{ch}_5V", f"{pre}_MAIN_5V", f"{pre}_TOUCH_5V"
        ufp, base, enable = f"{pre}_UFP_N", f"{pre}_ATTACH_BASE", f"{pre}_TOUCH_EN"
        data_low, power_low = f"{pre}_DATA_COIL_LOW", f"{pre}_POWER_COIL_LOW"
        require(f"J{n+1}", {1: host, 2: f"{pre}_UP_N", 3: f"{pre}_UP_P", 4: "GND", "SH": "GND"})
        require(f"J{n+2}", {1: touch, 2: f"{pre}_DN_N", 3: f"{pre}_DN_P", 4: "GND", "SH": "GND"})
        require(f"J{n+3}", {1: "AUX_5V", 2: "GND"})
        require(f"J{n+4}", {1: "DISPLAY_ENABLE", 2: ufp, 3: main, 4: "GND"})
        require(f"K{n+1}", {1: host, 8: data_low, 3: f"{pre}_UP_N", 4: f"{pre}_DN_N",
                              6: f"{pre}_UP_P", 5: f"{pre}_DN_P", "SH": "GND"})
        if any((f"K{n+1}", pin) in pins for pin in ("2", "7")):
            _fail(errors, "hand_data_relay", f"K{n+1}: unused NC contacts must be disconnected")
        for side, connector, terminal in (("UP", n+1, {"N": 3, "P": 6}),
                                          ("DN", n+2, {"N": 4, "P": 5})):
            for polarity, usb_pin in (("N", "2"), ("P", "3")):
                nodes(f"{pre}_{side}_{polarity}", {(f"J{connector}", usb_pin),
                      (f"K{n+1}", str(terminal[polarity]))}, "hand_data_relay")
        nodes(host, {(f"J{n+1}", "1"), (f"K{n+1}", "1"),
                     (f"C{n+1}", "1"), (f"D{n+1}", "1")}, "host_isolation")
        require(f"Q{n+4}", {1: "GND", 2: enable, 3: data_low})
        require(f"Q{n+3}", {1: enable, 2: power_low, 3: "GND"})
        nodes(data_low, {(f"K{n+1}", "8"), (f"D{n+1}", "2"),
                         (f"Q{n+4}", "3")}, "relay_supply_isolation")
        nodes(power_low, {(f"K{n+2}", "5"), (f"D{n+2}", "2"),
                          (f"Q{n+3}", "2")}, "relay_supply_isolation")
        require(f"D{n+1}", {1: host, 2: data_low})
        require(f"D{n+2}", {1: "AUX_5V", 2: power_low})
        require(f"K{n+2}", {1: touch, 2: "AUX_5V", 3: f"{pre}_TOUCH_FUSED",
                              4: f"{pre}_TOUCH_DUMP", 5: power_low})
        require(f"F{n+1}", {1: "AUX_5V", 2: f"{pre}_TOUCH_FUSED"})
        nodes(f"{pre}_TOUCH_FUSED", {(f"F{n+1}", "2"), (f"K{n+2}", "3")})
        nodes(touch, {(f"K{n+2}", "1"), (f"J{n+2}", "1"), (f"C{n+3}", "1")})
        require(f"R{n+6}", {1: f"{pre}_TOUCH_DUMP", 2: "GND"})
        nodes(f"{pre}_TOUCH_DUMP", {(f"K{n+2}", "4"), (f"R{n+6}", "1")})
        require(f"R{n+1}", {1: "AUX_5V", 2: ufp})
        require(f"R{n+2}", {1: ufp, 2: base})
        require(f"R{n+3}", {1: "AUX_5V", 2: base})
        require(f"R{n+4}", {1: enable, 2: "GND"})
        require(f"Q{n+2}", {1: "AUX_5V", 2: base, 3: enable})
        nodes(ufp, {(f"J{n+4}", "2"), (f"R{n+1}", "2"), (f"R{n+2}", "1")})
        nodes(base, {(f"R{n+2}", "2"), (f"R{n+3}", "2"), (f"Q{n+2}", "2")})
        nodes(enable, {(f"Q{n+2}", "3"), (f"R{n+4}", "1"),
                       (f"Q{n+3}", "1"), (f"Q{n+4}", "2")})
        require(f"R{n+5}", {1: main, 2: f"{pre}_MAIN_DUMP"})
        require(f"Q{n+1}", {1: "GND", 2: "DISCHARGE", 3: f"{pre}_MAIN_DUMP"})
        nodes(main, {(f"J{n+4}", "3"), (f"R{n+5}", "1")})
        nodes(f"{pre}_MAIN_DUMP", {(f"R{n+5}", "2"), (f"Q{n+1}", "3")})
        for offset, rail in ((1, host), (2, "AUX_5V"), (3, touch)):
            require(f"C{n+offset}", {1: rail, 2: "GND"})


def numerical_checks(components, errors):
    """Check /UFP loading and driver margins; leave fault clearing to the bench."""
    results = {"channels": {}, "touch_fuse_nominal_A": 0.8,
               "touch_continuous_design_load_A": 0.5,
               "touch_fuse_is_current_limiter": False,
               "usb_suspend_compliance": "not established: host-powered relay coil exceeds 2.5mA",
               "relay_pickup_conditions": "initial, approximately 23C; temperature testing required"}
    models = {"Q1": "2N3904"}
    for ch in (1, 2):
        n = 100 * ch
        models.update({f"K{n+1}": "G6K-2P-RF DC5", f"K{n+2}": "G5LE-1 DC5",
                       f"Q{n+1}": "2N7000", f"Q{n+2}": "2N3906",
                       f"Q{n+3}": "IRLZ44NPBF", f"Q{n+4}": "2N7000",
                       f"D{n+1}": "1N4007", f"D{n+2}": "1N4007"})
        fuse = components.get(f"F{n+1}")
        if not fuse or fuse[2] != "0.8A fast / two clips":
            _fail(errors, "hand_fuse", f"F{n+1}: requires specified 0.8A cartridge and two clips")
        try:
            pullup, base_r, emitter_r, gate_r = (
                _resistance(components, f"R{n+i}") for i in range(1, 5))
            if min(pullup, base_r, emitter_r, gate_r) <= 0:
                raise ValueError("Control resistances must be positive")
            if any("1%" not in components[f"R{n+i}"][2] for i in range(1, 5)):
                _fail(errors, "hand_driver", f"Screen {ch}: control calculations require 1% resistors")
            # TI guarantees /UFP VOL <= 0.25V at 1mA. Use VOL=0 for
            # maximum sink load, and 0.25V for minimum PNP base drive.
            sink_max = 5.5 / (pullup * .99) + (5.5 - .5) / (base_r * .99)
            base_min = (4.75 - .95 - .25) / (base_r * 1.01) - .95 / (emitter_r * .99)
            gate_load_max = 5.5 / (gate_r * .99) + 1e-6
            if sink_max > .001:
                _fail(errors, "hand_ufp_load", f"Screen {ch}: /UFP can sink {sink_max*1000:.3f}mA, above its 1mA VOL test load")
            if base_min < gate_load_max / 10:
                _fail(errors, "hand_driver", f"Screen {ch}: insufficient PNP base drive for saturated gate control")
            if gate_r * 1.01 * 1e-6 >= .5:
                _fail(errors, "hand_default_off", f"Screen {ch}: gate pulldown cannot hold leakage below 0.5V")
            dumps = []
            for offset in (5, 6):
                ref = f"R{n+offset}"
                resistance = _resistance(components, ref)
                if resistance <= 0:
                    raise ValueError(f"{ref}: discharge resistance must be positive")
                watts = 5.5 ** 2 / (resistance * .99)
                if "1W" not in components[ref][2] or "1%" not in components[ref][2] or watts > .5:
                    _fail(errors, "hand_discharge", f"{ref}: discharge must stay below 0.5W in a specified 1W resistor")
                dumps.append(watts)
            # Datasheet on-resistance at >=4.5V gate for 2N7000,
            # >=4V gate for IRLZ44N; coil resistance tolerance is +/-10%.
            data_coil_min = 4.75 * (237 * .9) / (237 * .9 + 5.3)
            power_coil_min = 4.75 * (63 * .9) / (63 * .9 + .035)
            results["channels"][str(ch)] = {
                "ufp_sink_maximum_mA": sink_max * 1000,
                "pnp_base_minimum_mA": base_min * 1000,
                "gate_static_load_maximum_mA": gate_load_max * 1000,
                "gate_assumed_minimum_on_V": 4.5,
                "data_coil_minimum_V": data_coil_min,
                "power_coil_minimum_V": power_coil_min,
                "data_coil_nominal_mA": 1000 * 5 / 237,
                "power_coil_nominal_mA": 1000 * 5 / 63,
                "discharge_resistor_maximum_W": dumps,
            }
            if data_coil_min < 4 or power_coil_min < 3.75:
                _fail(errors, "hand_driver", f"Screen {ch}: insufficient initial relay pickup voltage")
        except (KeyError, ValueError) as exc:
            _fail(errors, "hand_numeric", f"Screen {ch}: {exc}")
    for ref, expected in models.items():
        actual = components.get(ref)
        if not actual or actual[2] != expected:
            _fail(errors, "hand_component", f"{ref}: requires {expected} for the checked pinout and ratings")
    return results
