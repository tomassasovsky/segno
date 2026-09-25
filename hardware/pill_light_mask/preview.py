"""Compare the same actual lens/carrier under the bench collar and sheet metal."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
import numpy as np

import tall_pill as p
from check_geometry import box


def polygons(solid):
    vertices, faces = solid.tessellate(0.06)
    vertices = np.array([vertex.toTuple() for vertex in vertices])
    return vertices[np.array(faces)]


def render():
    parts = p.build()
    colors = {"base": "#292d34", "diffuser": "#e7dfc9", "mask": "#292d34"}
    fig = plt.figure(figsize=(15, 8), facecolor="#f4f3ef")
    fig.text(0.055, 0.925, "One pill, flush in both setups", fontsize=25,
             weight="bold", color="#20252c")
    fig.text(0.055, 0.87, "The extra height sits inside the enclosure. The LED strip rests on a solid 2 mm floor.",
             fontsize=13, color="#525b65")
    # Through an LED and a pair of the real mounting stops.
    x = 2.5 * p.enclosure.LED_STRIP_PITCH
    cutter = box(0.05, 45, 24, (x, 0, -2))
    pcb_z = p.BED_TOP + p.ADHESIVE_T + p.enclosure.LED_STRIP_T / 2
    pcb = box(p.STRIP_LENGTH, p.STRIP_WIDTH, p.enclosure.LED_STRIP_T, (0, 0, pcb_z))
    led = box(5, 5, p.enclosure.LED_PKG_H, (x, 0, p.LED_TOP - p.enclosure.LED_PKG_H / 2))

    for i, title in enumerate(("NOW · TEMPORARY BLACK COLLAR", "LATER · 2 MM SHEET METAL")):
        ax = fig.add_axes((0.035 + i * 0.49, 0.28, 0.44, 0.48))
        ax.set_facecolor("#f4f3ef")
        objects = [(parts["base"], colors["base"]), (parts["diffuser"], colors["diffuser"]),
                   (pcb, "#28674e"), (led, "#88ac72")]
        objects.append((parts["mask"], colors["mask"]) if i == 0
                       else (p.panel_reference(), "#8293a3"))
        for solid, color in objects:
            cross = solid.intersect(cutter)
            ax.add_collection(PolyCollection(polygons(cross)[:, :, 1:3],
                                             facecolors=color, edgecolors=color, linewidths=0.15))
        ax.axhline(p.FACE_TOP, color="#a56d25", linestyle=(0, (4, 4)), linewidth=1)
        ax.annotate("Flush light face", xy=(0, p.FACE_TOP), xytext=(0, p.FACE_TOP + 2.6),
                    ha="center", fontsize=12, color="#87551a",
                    arrowprops={"arrowstyle": "->", "color": "#87551a"})
        ax.annotate("", xy=(0, p.FACE_UNDER), xytext=(0, p.LED_TOP),
                    arrowprops={"arrowstyle": "<->", "color": "#a97326", "lw": 1.3})
        ax.text(10.0, -2.6, "5 mm\nair gap", fontsize=10, color="#87551a")
        ax.set(xlim=(-17.5, 17.5), ylim=(p.BASE_BOTTOM - 1.4, p.FACE_TOP + 4), aspect="equal")
        ax.set_title(title, fontsize=12, color="#525b65", pad=12)
        ax.set_axis_off()
    fig.text(0.065, 0.22, "Collar masks the mounting flange and corners.\nIts upper surface matches the future metal panel.",
             fontsize=12, color="#36414a", linespacing=1.6)
    fig.text(0.555, 0.22, "Remove the collar; keep the lens and LED carrier.\nSmall seating pads set the height and glue space.",
             fontsize=12, color="#36414a", linespacing=1.6)
    fig.text(0.055, 0.10, "Unchanged 60 × 6 mm metal cutout   ·   Restored 68 × 14 mm mounting footprint   ·   8.13 mm below the sheet",
             fontsize=12, weight="bold", color="#36414a")
    fig.text(0.055, 0.055, "Actual CAD cross-sections. Nominal flush fit; print, adhesive and finished-metal tolerances still require a physical check.",
             fontsize=10, color="#66717b")
    p.OUT.mkdir(exist_ok=True)
    fig.savefig(p.OUT / "tall_pill_preview.png", dpi=130, facecolor=fig.get_facecolor())
    plt.close(fig)


if __name__ == "__main__":
    render()
