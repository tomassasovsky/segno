"""Annotated solder-order images for the V3 boards.

Usage: python3 draw.py <workdir> <outdir>. <workdir> holds <name>.json from geom.py
and <name>_<F|B>.svg from kicad-cli; build.sh prepares it. Fonts are macOS Arial.
"""
import json, os, subprocess, sys, textwrap
from PIL import Image, ImageDraw, ImageFont

HERE = sys.argv[1]
OUT = sys.argv[2]
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
PALETTE = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b",
           "#e377c2", "#17becf", "#bcbd22", "#7f7f7f", "#393b79", "#ad494a"]


def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)


def hex_rgba(h, a=255):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (a,)


# ---- per-board configuration ---------------------------------------------------------

CONSOLE_VALUES = {
    **{r: "220" for r in ("R3", "R4", "R5")}, "R2": "330",
    **{r: "1k" for r in ("R7", "R9")},
    **{r: "4.7k" for r in ("R19", "R20", "R21", "R22")}, "R18": "6.8k",
    **{r: "10k" for r in ("R6", "R8", "R10", "R11", "R12", "R17")},
    **{r: "100k" for r in ("R14", "R16")},
    **{f"C{i}": "100n" for i in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 20)},
    "C13": "10n", "C14": "10n", "C30": "470u 25V", "C31": "100u",
    "D1": "1N4148", "U1": "74AHCT125", "U2": "H11L1", "J1": "Pico 2",
    "J2": "PI 2x20", "J3": "5V IN", "J24": "PILLS", "J22": "EXP",
    "J4": "MIDI OUT", "J5": "MIDI IN", "J6": "RING", "J8": "PWR BTN", "J9": "PI PWR",
    "J20": "CTRL 1", "J21": "CTRL 2", "J23": "PD", "J25": "SCREEN",
    **{f"J{10 + i}": n for i, n in enumerate(
        ["REC", "STOP", "UNDO", "MODE", "TRK1", "TRK2", "TRK3", "TRK4", "CLR", "BANK"])},
}
CONSOLE_VALUES.update({f"R{n}": "1k" for n in range(23, 33)})
CONSOLE_VALUES.update({f"D{n}": "PESD5V2S2UT" for n in range(2, 7)})
CONSOLE_R = ["R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
             "R14", "R16", "R17", "R18", "R19", "R20", "R21", "R22"]
CONSOLE_C = [f"C{i}" for i in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 20)]
CONSOLE_XH = ["J4", "J5", "J6", "J8", "J9", "J20", "J21", "J23", "J25"] + [f"J{i}" for i in range(10, 20)]

# The footswitch protection parts (#1391) are surface-mount on the back and go
# on first, while the board still lies flat.
CONSOLE_STEPS = [
    ("D2-D6 PESD5V2S2UT - back", [f"D{n}" for n in range(2, 7)], "SOT-23: the single pin points down, toward the headers.", "B"),
    ("R23-R32 1k 1206 - back", [f"R{n}" for n in range(23, 33)], "No polarity. Tack one pad, then the other.", "B"),
    ("Pico 2 (J1)", ["J1"], "USB to the left. Tack pads 1 and 21, then all 40 castellations and the 3 SWD holes.", "F"),
    ("D1  1N4148", ["D1"], "Cathode band on the K side (left).", "F"),
    ("19 resistors", CONSOLE_R, "Values are printed on each part. Meter them.", "F"),
    ("14 ceramic caps", CONSOLE_C, "C13, C14 are 10 nF (103); the rest 100 nF (104).", "F"),
    ("U2 H11L1, U1 74AHCT125", ["U2", "U1"], "Notch / pin 1 at the top. Clean flux around U2 and D1.", "F"),
    ("JST XH headers", CONSOLE_XH, "Pin 1 on the left. Press flat while reheating one pin.", "F"),
    ("JST VH J3, J24", ["J3", "J24"], "Pin 1 is the BOTTOM pin. J24 pin 1 = GND.", "F"),
    ("J2 Pi ribbon", ["J2"], "Pin 1 bottom-right. Shroud notch to the silk.", "F"),
    ("C31, then C30", ["C31", "C30"], "+ lead in the LEFT hole on both.", "F"),
    ("J22 EXP (optional)", ["J22"], "Pin 1 top-left: +3V3, +5V ... GND.", "F"),
]

BOARDS = [
    {
        "name": "console", "face": "B", "scale": 13,
        "title": "Console v3.2 - BACK face (view looking at the back)",
        "values": CONSOLE_VALUES,
        "steps": "CONSOLE",
        "marks": {},
        "dots": [f"D{n}" for n in range(2, 7)],
    },
    {
        "name": "console", "face": "F", "scale": 13,
        "title": "Console v3.2 - solder order (top face)",
        "values": CONSOLE_VALUES,
        "steps": "CONSOLE",
        "marks": {"D1": "K", "C30": "+", "C31": "+"},
        "dots": ["J1", "J2", "J3", "J24", "U1", "U2", "J22"] + CONSOLE_XH,
    },
    {
        "name": "ring", "face": "B", "scale": 15,
        "title": "Ring carrier - BACK face (view looking at the back)",
        "values": {"U1": "XIAO RP2350", "C1": "470u", "C2": "10n", "C3": "10n", "C4": "10n",
                   "C5": "100n", "D1": "1N5819", "U2": "74AHCT125", "J1": "J1 LINK",
                   "R1": "330", "R2": "10k", "R3": "10k", "R4": "10k", "R5": "100k"},
        "steps": "RING",
        "marks": {"D1": "K", "C1": "+"},
        "dots": ["U1", "U2", "J1"],
    },
    {
        "name": "ring", "face": "F", "scale": 15, "suffix": "front_order",
        "title": "Ring carrier - FRONT face",
        "values": {"ENC1": "ENC1 ACZ11", "J2": "J2"},
        "steps": "RING",
        "marks": {},
        "dots": [],
        "pad_labels": {"J2": {"1": "x", "2": "x", "3": "DIN", "4": "x"}},
    },
    {
        "name": "screen", "face": "F", "scale": 15,
        "title": "Screen power Rev P - solder order (top face)",
        "values": {"R1": "1k", "R2": "4.7k", "R5": "5.6k", "R6": "100k", "R7": "10k",
                   "R101": "10k", "R102": "100k", "R201": "10k", "R202": "100k", "R8": "100R 1W",
                   "D101": "1N4007", "D201": "1N4007", "D3": "P6KE6.8CA",
                   "C1": "100n", "C101": "100n", "C201": "100n",
                   "C102": "150u", "C202": "150u", "C2": "220u",
                   "F101": "4A", "F201": "4A", "F102": "800mA", "F202": "800mA",
                   "Q1": "3904", "Q2": "3906", "Q101": "TN0702", "Q102": "TN0702",
                   "Q201": "TN0702", "Q202": "TN0702", "Q5": "IRLZ44N",
                   "K1": "G6C-1117P", "K101": "IM02TS", "K201": "IM02TS", "F1": "F1 8A holder",
                   "J1": "5V IN", "J103": "15.6 PWR", "J203": "7 PWR", "J2": "CTRL",
                   "J101": "PI USB1", "J102": "TOUCH1", "J201": "PI USB2", "J202": "TOUCH2"},
        "steps": [
            ("Resistors", ["R1", "R2", "R5", "R6", "R7", "R8", "R101", "R102", "R201", "R202"], "R8 is the 1 W part."),
            ("Diodes", ["D101", "D201", "D3"], "1N4007 band on the K side. D3 is bidirectional."),
            ("100 nF caps", ["C1", "C101", "C201"], "No polarity."),
            ("Signal relays K101, K201", ["K101", "K201"], "They fit rotated: pin-1 mark to the silk bar."),
            ("Fuses", ["F101", "F102", "F201", "F202"], "F101/F201 = 4 A, F102/F202 = 800 mA."),
            ("TO-92 transistors", ["Q1", "Q2", "Q101", "Q102", "Q201", "Q202"], "Flat face to the silk. Q1 3904, Q2 3906. ESD care."),
            ("Electrolytics", ["C2", "C102", "C202"], "+ lead to the silk +."),
            ("JST XH", ["J2", "J101", "J102", "J201", "J202"], "5-pin: 1 VBUS, 2 D-, 3 D+, 4 GND, 5 shield."),
            ("JST VH", ["J1", "J103", "J203"], "Triangle on the silk = pin 1."),
            ("K1 power relay", ["K1"], "Fits one way. Not the G6C-2117."),
            ("Q5 IRLZ44N", ["Q5"], "Metal tab toward the top edge. Tab is live."),
            ("F1 fuse holder", ["F1"], "Last. Cartridge in after the checks."),
        ],
        "marks": {"D101": "K", "D201": "K", "C2": "+", "C102": "+", "C202": "+"},
        "dots": ["J1", "J2", "J101", "J102", "J103", "J201", "J202", "J203",
                 "K1", "K101", "K201", "Q1", "Q2", "Q5", "Q101", "Q102", "Q201", "Q202"],
    },
]

RING_STEPS = [
    ("XIAO RP2350 (U1) - back", ["U1"], "Component side up, USB-C to the edge, D0 on the dot. 14 castellations.", "B"),
    ("R1-R5, D1 - back", ["R1", "R2", "R3", "R4", "R5", "D1"], "Solder on the front face. D1 band on K.", "B"),
    ("C2-C4 10 nF, C5 100 nF - back", ["C2", "C3", "C4", "C5"], "C2-C4 are 10 nF, not 100 nF.", "B"),
    ("U2 74AHCT125 - back", ["U2"], "Notch to the silk notch.", "B"),
    ("J1 XH 4-pin - back", ["J1"], "1 +5V, 2 GND, 3/4 UART to console J6.", "B"),
    ("C1 470 uF - back", ["C1"], "+ lead to the silk +.", "B"),
    ("ENC1 encoder - front", ["ENC1"], "LAST. 350 C max, 3 s max per terminal.", "F"),
    ("J2: DIN wire to pad 3 - front", ["J2"], "Pads 1, 2, 4 stay empty. No J3/J4/RING1.", "F"),
]


def rasterize(svg, scale):
    png = svg[:-4] + f"_{scale}.png"
    if not os.path.exists(png):
        subprocess.run(["magick", "-density", str(scale * 25.4), "-background", "white",
                        svg, "-flatten", png], check=True)
    return Image.open(png).convert("RGBA")


def fit_text(draw, text, w, h, bold=True, max_size=26, min_size=9):
    for size in range(max_size, min_size - 1, -1):
        f = font(size, bold)
        l, t, r, b = draw.textbbox((0, 0), text, font=f, stroke_width=2)
        if r - l <= w and b - t <= h:
            return f
    return font(min_size, bold)


def render(cfg):
    data = json.load(open(os.path.join(HERE, cfg["name"] + ".json")))
    face, S = cfg["face"], cfg["scale"]
    bg = rasterize(os.path.join(HERE, f"{cfg['name']}_{face}.svg"), S)
    # Fade the copper so the step colours dominate.
    bg = Image.blend(bg, Image.new("RGBA", bg.size, (255, 255, 255, 255)), 0.7)
    W, H = bg.size
    x0, y0, x1, y1 = data["board"]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2

    def px(x, y):
        if face == "B":
            x = 2 * cx - x
        return ((x - cx) * S + W / 2, (y - cy) * S + H / 2)

    if isinstance(cfg["steps"], str):
        faced = {"RING": RING_STEPS, "CONSOLE": CONSOLE_STEPS}[cfg["steps"]]
        steps = [(t, refs, note) for t, refs, note, _ in faced]
        active = [f == face for *_, f in faced]
    else:
        steps = cfg["steps"]
        active = [True] * len(steps)

    parts = {p["ref"]: p for p in data["parts"]}
    overlay = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    labels = []
    for i, (title, refs, note) in enumerate(steps):
        if not active[i]:
            continue
        col = PALETTE[i % len(PALETTE)]
        for ref in refs:
            p = parts[ref]
            box = p["fab"] or p["crt"] or p["pads_box"]
            (ax, ay), (bx, by) = px(box[0], box[1]), px(box[2], box[3])
            ax, bx = sorted((ax, bx))
            ay, by = sorted((ay, by))
            pad = 2
            d.rectangle([ax - pad, ay - pad, bx + pad, by + pad], fill=hex_rgba(col, 95),
                        outline=hex_rgba(col), width=4)
            labels.append((i, col, ref, p, (ax, ay, bx, by)))
    img = Image.alpha_composite(bg, overlay)
    d = ImageDraw.Draw(img)

    for i, col, ref, p, (ax, ay, bx, by) in labels:
        value = cfg["values"].get(ref, p["value"])
        w, h = bx - ax, by - ay
        vertical = h > w * 1.4
        text = value
        if vertical:
            f = fit_text(d, text, h - 6, w - 4)
            tmp = Image.new("RGBA", (int(h), int(w)), (0, 0, 0, 0))
            td = ImageDraw.Draw(tmp)
            td.text((h / 2, w / 2), text, font=f, fill="black", anchor="mm",
                    stroke_width=2, stroke_fill="white")
            tmp = tmp.rotate(90, expand=True)
            img.alpha_composite(tmp, (int(ax), int(ay)))
        else:
            f = fit_text(d, text, w - 6, h - 4)
            d.text(((ax + bx) / 2, (ay + by) / 2), text, font=f, fill="black", anchor="mm",
                   stroke_width=2, stroke_fill="white")
        # Step badge at the box's top-left corner.
        r = 13
        bxc, byc = ax, ay
        d.ellipse([bxc - r, byc - r, bxc + r, byc + r], fill=col, outline="white", width=2)
        d.text((bxc, byc), str(i + 1), font=font(15, True), fill="white", anchor="mm")
        # Polarity / pin-1 markers.
        mark = cfg["marks"].get(ref)
        pin1 = next((q for q in p["pads"] if q["n"] == "1"), None)
        if pin1 and (mark or ref in cfg["dots"]):
            qx, qy = px(pin1["x"], pin1["y"])
            rr = 11 if mark else 7
            # Move the marker just outside the outline, on the edge nearest pin 1,
            # so it never covers the value label.
            gap = {"l": qx - ax, "r": bx - qx, "t": qy - ay, "b": by - qy}
            side = min(gap, key=gap.get)
            off = rr + 5
            if side == "l":
                qx = ax - off
            elif side == "r":
                qx = bx + off
            elif side == "t":
                qy = ay - off
            else:
                qy = by + off
            d.ellipse([qx - rr, qy - rr, qx + rr, qy + rr], fill="black", outline="white", width=2)
            if mark:
                d.text((qx, qy), mark, font=font(15, True), fill="white", anchor="mm")
        for n, lab in cfg.get("pad_labels", {}).get(ref, {}).items():
            q = next(q for q in p["pads"] if q["n"] == n)
            qx, qy = px(q["x"], q["y"])
            fill = "#d62728" if lab == "x" else "#2ca02c"
            d.rectangle([qx - 14, qy - 30, qx + 14, qy - 12], fill=fill)
            d.text((qx, qy - 21), "X" if lab == "x" else lab, font=font(13, True), fill="white", anchor="mm")

    # Legend panel to the right, title strip on top.
    LW, TH = 560, 70
    M = 30
    canvas = Image.new("RGBA", (W + LW + 2 * M, max(H + TH + M, TH + 90 + 74 * len(steps))), "white")
    canvas.alpha_composite(img, (M, TH))
    W += 2 * M
    cd = ImageDraw.Draw(canvas)
    cd.text((20, TH / 2), cfg["title"], font=font(30, True), fill="black", anchor="lm")
    y = TH + 10
    for i, (title, refs, note) in enumerate(steps):
        col = PALETTE[i % len(PALETTE)] if active[i] else "#c8c8c8"
        tc = "black" if active[i] else "#a0a0a0"
        cd.ellipse([W + 10, y, W + 42, y + 32], fill=col)
        cd.text((W + 26, y + 16), str(i + 1), font=font(17, True), fill="white", anchor="mm")
        cd.text((W + 54, y + 2), title + ("" if active[i] else "  (other face)"), font=font(19, True), fill=tc)
        for k, line in enumerate(textwrap.wrap(note, 48)[:2]):
            cd.text((W + 54, y + 27 + 20 * k), line, font=font(16), fill=tc)
        y += 74
    cd.text((W + 10, y + 8), "Black dot = pin 1.  K = cathode.  + = positive lead.", font=font(15), fill="black")
    if face == "B":
        cd.text((W + 10, y + 30), "Back view is mirrored: it matches the board", font=font(15), fill="black")
        cd.text((W + 10, y + 50), "when you hold it back-face up.", font=font(15), fill="black")
    name = cfg["name"] + "_" + cfg.get("suffix", "back_order" if face == "B" else "order") + ".png"
    canvas.convert("RGB").save(os.path.join(OUT, name), optimize=True)
    print("wrote", name, canvas.size)


for cfg in BOARDS:
    render(cfg)
