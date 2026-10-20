"""Compare the new power board against the pre-redesign USB copper snapshot."""

import argparse
import hashlib
import json
from pathlib import Path

import pcbnew as pcb


def xy(point):
    return [point.x, point.y]


def capture(board):
    names = {
        f"S{channel}_{side}_{polarity}"
        for channel in (1, 2)
        for side in ("UP", "DN")
        for polarity in ("P", "N")
    }
    tracks = []
    for track in board.GetTracks():
        if track.GetNetname() not in names:
            continue
        item = {
            "net": track.GetNetname(),
            "type": track.GetClass(),
            "start": xy(track.GetStart()),
            "end": xy(track.GetEnd()),
            "width": track.GetWidth(),
            "layer": int(track.GetLayer()),
        }
        if isinstance(track, pcb.PCB_ARC):
            item["mid"] = xy(track.GetMid())
        tracks.append(item)
    anchors = {}
    for footprint in board.GetFootprints():
        ref = footprint.GetReference()
        if not ref.startswith(("J", "K10", "K20", "TP", "H")):
            continue
        anchors[ref] = {
            "pos": xy(footprint.GetPosition()),
            "angle": footprint.GetOrientationDegrees(),
            "pads": {
                pad.GetNumber(): {
                    "pos": xy(pad.GetPosition()),
                    "net": pad.GetNetname(),
                    "size": xy(pad.GetSize()),
                    "drill": xy(pad.GetDrillSize()),
                }
                for pad in footprint.Pads()
            },
        }
    return sorted(tracks, key=lambda item: json.dumps(item, sort_keys=True)), anchors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    before = json.loads(args.baseline.read_text())
    tracks, anchors = capture(pcb.LoadBoard(str(args.board)))
    # The only intentional anchor-net change is the new input fuse. The
    # header's pin number, physical location and pad geometry remain fixed.
    expected = before["anchors"]
    expected["J1"]["pads"]["1"]["net"] = "AUX_5V_IN"
    errors = []
    if tracks != before["usb_tracks"]:
        errors.append("USB copper differs from the pre-redesign snapshot")
    if anchors != expected:
        errors.extend(
            f"Anchor differs: {ref}"
            for ref in sorted(set(anchors) | set(expected))
            if anchors.get(ref) != expected.get(ref)
        )
    result = {
        "baseline_board_sha256": before["board_sha256"],
        "board_sha256": hashlib.sha256(args.board.read_bytes()).hexdigest(),
        "baseline_sha256": hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
        "usb_copper_items": len(tracks),
        "fixed_anchors": len(anchors),
        "passed": not errors,
        "errors": errors,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
