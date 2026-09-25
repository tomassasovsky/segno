"""Readable functional sheets using SKiDL's native KiCad symbol serializer.

SKiDL 2.3's automatic placement crashes on this circuit's unconnected terminals.
Explicit sheet placement avoids that placer while retaining its library-symbol
conversion. Global net labels express the same circuit as the generated netlist.
"""
import copy
import math
import uuid
from simp_sexp import Sexp
from skidl.tools.kicad9.sexp_schematic import (
    part_to_lib_symbol_definition, _write_sexp_schematic,
)


def uid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "segno/screen-power/" + name))


def write_schematic(circuit, out, variant):
    root_name = f"screen_power_{variant}"
    root_id = uid(root_name)
    # Ship the exact embedded definitions as a project-local library. SKiDL's
    # normalized drawing differs from the upstream library's field formatting;
    # preserving this local definition makes native ERC comparisons meaningful.
    definitions_by_ref, library_definitions = {}, {}
    for part in circuit.parts:
        definition = part_to_lib_symbol_definition(part)
        old_name = part.name
        new_name = definition[1].replace(":", "_")
        definition[1] = "screen_symbols:" + new_name
        del definition[2]
        # Place names inside symbol bodies, clear of numbers above the pins.
        definition[2][1][1] = 0.508
        if part.name.startswith("Conn_") or part.ref.startswith(("D", "Q", "Y", "K")):
            # Numbered headers and conventional discrete symbols already show
            # terminal numbers; redundant names overlap their compact graphics.
            definition[2].append(["hide", "yes"])
        for item in definition:
            if isinstance(item, list) and item and item[0] == "symbol":
                item[1] = item[1].replace(old_name + "_", new_name + "_", 1)
        definitions_by_ref[part.ref] = definition
        local = copy.deepcopy(definition)
        local[1] = new_name
        library_definitions[new_name] = local
    library = Sexp(["kicad_symbol_lib", ["version", 20231120],
                    ["generator", "kicad_symbol_editor"], *library_definitions.values()])
    _write_sexp_schematic(library, str(out / "screen_symbols.kicad_sym"))
    (out / "sym-lib-table").write_text('''(sym_lib_table
      (version 7)
      (lib (name "screen_symbols") (type "KiCad")
        (uri "${KIPRJMOD}/screen_symbols.kicad_sym")
        (options "") (descr "Project definitions generated from KiCad and manufacturer pin maps")))
''')
    sheets = {"control": [], "shared_power": [], "screen1_power": [], "screen1_touch": [],
              "screen2_power": [], "screen2_touch": []}
    for part in circuit.parts:
        number = int(''.join(c for c in part.ref if c.isdigit()) or 0)
        channel, local = divmod(number, 100)
        if channel not in (1, 2):
            section = "shared_power" if part.ref.startswith(("H", "#FLG")) or part.ref in {"Q3", "Q4", "R3", "R4", "R8", "C1", "C2", "J1"} else "control"
        else:
            touch = ((part.ref.startswith("J") and local in (1, 2))
                     or part.ref.startswith(("K", "Q", "D", "C")))
            section = f"screen{channel}_{'touch' if touch else 'power'}"
        sheets[section].append(part)
    for page, (section, parts) in enumerate(sheets.items(), 1):
        sheet_id = root_id if section == "control" else uid(root_name + section)
        path = f"/{root_id}" + ("" if section == "control" else f"/{sheet_id}")
        title = f"Segno screen power / {variant} / {section.replace('_', ' ')}"
        sch = Sexp(["kicad_sch", ["version", 20250114], ["generator", "eeschema"],
                    ["uuid", sheet_id], ["paper", "A3"],
                    ["title_block", ["title", title], ["rev", '"K prototype"'],
                     ["comment", 1, "Discrete 5V switch. Host VBUS powers only its own signal relay coil."],
                     ["comment", 2, "Physical verification required before release."]]])
        definitions = {}
        for part in parts:
            definition = definitions_by_ref[part.ref]
            definitions[definition[1]] = definition
        sch.append(Sexp(["lib_symbols", *definitions.values()]))
        for index, part in enumerate(sorted(parts, key=lambda p: (not p.ref.startswith("U"), p.ref))):
            x, y = 50.8 + (index % 4) * 101.6, 63.5 + (index // 4) * 50.8
            definition = definitions_by_ref[part.ref]
            symbol_id = uid(f"{root_name}/{part.ref}")
            rotation = 90 if part.ref.startswith(("R", "C")) else 0
            radians = math.radians(rotation)
            def relative(pin):
                return (round(pin.x*math.cos(radians)-pin.y*math.sin(radians), 6),
                        round(pin.x*math.sin(radians)+pin.y*math.cos(radians), 6))
            symbol = Sexp(["symbol", ["lib_id", definition[1]], ["at", x, y, rotation],
                           ["unit", 1], ["in_bom", "no" if part.ref.startswith("#") else "yes"],
                           ["on_board", "no" if part.ref.startswith("#") else "yes"],
                           ["dnp", "no"], ["uuid", symbol_id]])
            # Keep values clear of the body of the tallest symbol.
            pin_y = [relative(pin)[1] for pin in part.pins]
            top = y - max(pin_y, default=0) - 10.16
            # Vertical net names need their own space above/below the symbol.
            vertical_pin = (rotation == 0 and len(part.pins) > 1
                            and any(pin.orientation in (90, 270, "U", "D")
                                    for pin in part.pins))
            prop_x = x + 22.86 if vertical_pin else x
            for name, value, py, hide in [
                ("Reference", part.ref, top, False), ("Value", str(part.value), top + 2.54, False),
                ("Footprint", str(getattr(part, "footprint", "")), y, True),
                ("MPN", str(getattr(part, "MPN", "")), y, True),
            ]:
                effects = ["effects", ["font", ["size", 1.27, 1.27]]]
                if hide:
                    effects.append(["hide", "yes"])
                # KiCad applies the symbol rotation to the field orientation.
                # Matching that rotation keeps text horizontal on the sheet.
                symbol.append(Sexp(["property", name, value,
                                    ["at", prop_x, py, rotation], effects]))
            labeled_endpoints = set()
            for pin in part.pins:
                symbol.append(Sexp(["pin", str(pin.num), ["uuid", uid(f"{root_name}/{part.ref}/{pin.num}")]]))
                rx, ry = relative(pin)
                px, py = round(x + rx, 6), round(y - ry, 6)
                if not pin.nets or pin.net.name == "__NOCONNECT":
                    sch.append(Sexp(["no_connect", ["at", px, py], ["uuid", uid(f"nc/{symbol_id}/{pin.num}")]]))
                else:
                    pin_angle = {"R": 0, "L": 180, "U": 90, "D": 270}.get(pin.orientation, pin.orientation)
                    pin_angle = (pin_angle + rotation) % 360
                    endpoint = (px, py, pin_angle, pin.net.name)
                    # Stacked ground pins share one visible terminal and label.
                    if endpoint in labeled_endpoints:
                        continue
                    labeled_endpoints.add(endpoint)
                    angle = {0: 180, 180: 0, 90: 270, 270: 90}[pin_angle]
                    # A short wire separates labels from symbol pin names/numbers.
                    lx = round(px - 5.08 * math.cos(math.radians(pin_angle)), 6)
                    ly = round(py + 5.08 * math.sin(math.radians(pin_angle)), 6)
                    sch.append(Sexp(["wire", ["pts", ["xy", px, py], ["xy", lx, ly]],
                                     ["stroke", ["width", 0], ["type", "default"]],
                                     ["uuid", uid(f"wire/{symbol_id}/{pin.num}")]]))
                    sch.append(Sexp(["global_label", pin.net.name, ["shape", "bidirectional"],
                                     ["at", lx, ly, angle],
                                     ["effects", ["font", ["size", 1.0, 1.0]],
                                      ["justify", "left" if angle in (0, 90) else "right"]],
                                     ["uuid", uid(f"label/{symbol_id}/{pin.num}")]]))
            symbol.append(Sexp(["instances", ["project", root_name,
                ["path", path, ["reference", part.ref], ["unit", 1]]]]))
            sch.append(symbol)
        if section == "control":
            for i, child in enumerate(list(sheets)[1:]):
                child_id = uid(root_name + child)
                sx, sy = 25.4 + (i % 2) * 139.7, 218.44 + (i // 2) * 20.32
                sch.append(Sexp(["sheet", ["at", sx, sy], ["size", 101.6, 10.16],
                    ["stroke", ["width", 0], ["type", "default"]],
                    ["fill", ["color", 0, 0, 0, 0]], ["uuid", child_id],
                    ["property", "Sheetname", child.replace('_', ' '), ["at", sx, sy-1.27, 0],
                     ["effects", ["font", ["size", 1.27, 1.27]], ["justify", "left"]]],
                    ["property", "Sheetfile", child + ".kicad_sch", ["at", sx, sy+11.43, 0],
                     ["effects", ["font", ["size", 1.0, 1.0]], ["justify", "left"]]],
                    ["instances", ["project", root_name,
                     ["path", f"/{root_id}", ["page", str(i+2)]]]]]))
            sch.append(Sexp(["sheet_instances", ["path", "/", ["page", "1"]]]))
        sch.append(Sexp(["embedded_fonts", "no"]))
        # simp_sexp normalizes numeric strings to numbers. KiCad requires these
        # identifiers to remain strings, including library pins and sheet pages.
        def quote_identifiers(node):
            if not isinstance(node, list) or not node:
                return
            if node[0] in ("pin", "page") and len(node) > 1:
                if isinstance(node[1], (int, float)) or str(node[1]).isdigit():
                    node[1] = '"' + str(node[1]) + '"'
            for child in node:
                quote_identifiers(child)
        quote_identifiers(sch)
        name = root_name if section == "control" else section
        _write_sexp_schematic(sch, str(out / (name + ".kicad_sch")))
