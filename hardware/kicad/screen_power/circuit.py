"""Hand-soldered screen-power circuit. Run with the repository's SKiDL environment.

A discrete 5 V switch controls both screens. No USB-C
source controller, evaluation module, clock or USB isolator is needed.
"""

import argparse
import os
from pathlib import Path

import skidl as s

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


def build(variant, schematic=False):
    from switch_circuit import build_switch
    build_switch(variant, schematic)


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("variant", choices=["hand"], nargs="?", default="hand")
    args.add_argument("--schematic", action="store_true")
    options = args.parse_args()
    build(options.variant, options.schematic)
