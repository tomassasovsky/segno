"""Two screen-power variants. Run with the repository's SKiDL environment.

Both assembly variants use the same discrete 5 V switch circuit. No USB-C
source controller, evaluation module, clock or USB isolator is needed.
"""

import argparse
import builtins
import csv
import json
import os
from pathlib import Path

import skidl as s
from simp_sexp import Sexp

HERE = Path(__file__).resolve().parent
SYMBOLS = Path(os.environ.get(
    "KICAD_SYMBOL_DIR",
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols",
))
s.set_default_tool(s.KICAD9)
s.lib_search_paths[s.KICAD9].extend([str(SYMBOLS), str(HERE)])


def require_physical_footprint(part):
    if not part.ref.startswith("#FLG"):
        raise ValueError(f"Missing footprint: {part.ref}")


s.empty_footprint_handler = require_physical_footprint


def custom_symbols():
    """Native USB-B connector and RF relay definitions with complete pins."""
    symbols = []
    # USB_B marks its ground as power_out. Two host ports share ground here;
    # derive a local symbol with a passive ground, leaving VBUS power_out.
    library = Sexp((SYMBOLS / "Connector.kicad_sym").read_text().replace(
        '(property "Datasheet" ""', '(property "Datasheet" "~"'))
    usb = next(x for x in library if isinstance(x, list) and str(x[0]) == "symbol" and x[1] == "USB_B")
    usb[1] = "USB_B_Host"
    for child in usb:
        if isinstance(child, list) and str(child[0]) == "symbol":
            child[1] = child[1].replace("USB_B_", "USB_B_Host_")
            for pin in child:
                if isinstance(pin, list) and str(pin[0]) == "pin":
                    if any(isinstance(v, list) and str(v[0]) == "number" and v[1] == "4" for v in pin):
                        pin[1] = "passive"
    usb = Sexp(usb)
    usb.add_quotes(lambda item: item[0] in ("symbol", "property", "name", "number"))
    symbols.append(usb.to_str())
    # The RF relay has the G6K contact numbering plus four case-ground leads.
    # The normal G6K footprint is not interchangeable with this RF package.
    relay_library = Sexp((SYMBOLS / "Relay.kicad_sym").read_text().replace(
        '(property "Datasheet" ""', '(property "Datasheet" "~"'))
    relay = next(x for x in relay_library if isinstance(x, list)
                 and str(x[0]) == "symbol" and x[1] == "G6K-2")
    relay[1] = "G6K-2P-RF"
    for child in relay:
        if isinstance(child, list) and str(child[0]) == "symbol":
            child[1] = child[1].replace("G6K-2_", "G6K-2P-RF_")
    relay_pins = next(child for child in relay if isinstance(child, list)
                      and str(child[0]) == "symbol" and child[1] == "G6K-2P-RF_1_1")
    relay_pins.append(Sexp('''(pin passive line (at -15.24 0 0) (length 2.54)
          (name "CASE" (effects (font (size 1 1))))
          (number "SH" (effects (font (size 1 1)))))'''))
    relay = Sexp(relay)
    relay.add_quotes(lambda item: item[0] in ("symbol", "property", "name", "number"))
    symbols.append(relay.to_str())
    (HERE / "screen_power.kicad_sym").write_text(
        '(kicad_symbol_lib (version 20231120) (generator "kicad_symbol_editor")\n'
        + '\n'.join(symbols) + ')\n')


def build(variant, schematic=False):
    from switch_circuit import build_switch
    build_switch(variant, schematic)


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("variant", choices=["hand", "factory"])
    args.add_argument("--schematic", action="store_true")
    options = args.parse_args()
    custom_symbols()
    build(options.variant, options.schematic)
