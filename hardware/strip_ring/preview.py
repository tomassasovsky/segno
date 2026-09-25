"""Render actual prototype CAD; no claim of simulated diffusion."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import to_rgb
import numpy as np
import vtk
from vtkmodules.util.numpy_support import numpy_to_vtk, numpy_to_vtkIdTypeArray, vtk_to_numpy
import cadquery as cq
import strip_ring as m


def render_view(objects, camera=(130, -170, 145), focal=(0, 0, 0), scale=62):
    renderer = vtk.vtkRenderer()
    renderer.SetBackground(*to_rgb("#f4f3ef"))
    for solid, color in objects:
        if not solid.Solids():
            continue
        vertices, faces = solid.tessellate(0.12, 0.18)
        points = vtk.vtkPoints()
        points.SetData(numpy_to_vtk(np.array([v.toTuple() for v in vertices]), deep=True))
        cells = vtk.vtkCellArray()
        indices = np.column_stack((np.full(len(faces), 3), np.array(faces))).astype(np.int64)
        cells.ImportLegacyFormat(numpy_to_vtkIdTypeArray(indices.ravel(), deep=True))
        poly = vtk.vtkPolyData()
        poly.SetPoints(points)
        poly.SetPolys(cells)
        normals = vtk.vtkPolyDataNormals()
        normals.SetInputData(poly)
        normals.ConsistencyOn()
        normals.AutoOrientNormalsOn()
        normals.SetFeatureAngle(30)
        mapper = vtk.vtkPolyDataMapper()
        mapper.SetInputConnection(normals.GetOutputPort())
        actor = vtk.vtkActor()
        actor.SetMapper(mapper)
        actor.GetProperty().SetColor(*to_rgb(color))
        actor.GetProperty().SetAmbient(0.3)
        actor.GetProperty().SetDiffuse(0.7)
        renderer.AddActor(actor)
    cam = renderer.GetActiveCamera()
    cam.SetPosition(*camera)
    cam.SetFocalPoint(*focal)
    cam.SetViewUp(0, 0, 1)
    cam.ParallelProjectionOn()
    cam.SetParallelScale(scale)
    win = vtk.vtkRenderWindow()
    win.SetOffScreenRendering(1)
    win.SetSize(1000, 680)
    win.AddRenderer(renderer)
    win.Render()
    capture = vtk.vtkWindowToImageFilter()
    capture.SetInput(win)
    capture.Update()
    data = vtk_to_numpy(capture.GetOutput().GetPointData().GetScalars()).reshape(680,1000,3)
    out = data[::-1].copy()
    win.Finalize()
    return out


def main():
    p = m.parts()
    fpc, leds = m.led_strip()
    basic = [(s, "#ede9da" if n in ("diffuser", "cup") else "#22262b") for n,s in p.items()]
    basic += [(fpc, "#d7cab3"), (cq.Compound.makeCompound(leds), "#dda44b")]
    basic += [(s, "#a4acb5") for s in m.cap_screws()+m.base_screws()]
    installed = basic + [(m.knob(), "#20242a")]
    # Remove the front half of all parts and reference hardware to show the
    # cylindrical backing, strip orientation and open path above the board.
    back = m.box(130, 65, 70, (0, 32.5, 0))
    cutaway = [(s.intersect(back), c) for s,c in basic]
    cutaway += [(m.controller().intersect(back), "#785b86"),
                (m.knob().intersect(back), "#30353b")]
    fastening = [(p["shield"], "#22262b"),
                 (p["bottom_cover"].translate((0,0,-13)), "#22262b")]
    fastening += [(s.translate((0,0,-25)), "#a4acb5") for s in m.base_screws()]
    fig = plt.figure(figsize=(16,9), facecolor="#f4f3ef")
    fig.text(.04,.93,"One screw size for the whole ring",fontsize=26,
             weight="bold",color="#20252c")
    fig.text(.04,.875,"Five M3 × 5 mm SSD screws · Ø7 mm heads · Two in the centre cap, three underneath.",
             fontsize=14,color="#58616a")
    views = [(installed,"STANDALONE ENCLOSURE",(130,-170,155),(0,0,-1),57),
             (cutaway,"CUTAWAY · LEDS ABOVE THE PCB",(70,-190,85),(0,0,-2),54),
             (fastening,"BOTTOM COVER · RECESSED SSD SCREWS",(110,-170,-130),(0,0,-18),63)]
    for i,(items,title,cam,focal,scale) in enumerate(views):
        ax=fig.add_axes((.01+i*.33,.24,.33,.57))
        ax.imshow(render_view(items,cam,focal,scale))
        ax.set_axis_off()
        ax.set_title(title,fontsize=12,color="#58616a",pad=10)
    fig.text(.04,.20,"Full 18 mm knob above the face\n0.5 mm running gap underneath",fontsize=13,
             color="#36414a",linespacing=1.7)
    fig.text(.37,.20,"Smaller passive encoder PCB\nOriginal encoder mounting height",fontsize=13,
             color="#36414a",linespacing=1.7)
    fig.text(.70,.20,"0.2 mm recess with 2.4 mm-tall heads\n4 mm nominal thread engagement",fontsize=13,
             color="#36414a",linespacing=1.7)
    fig.text(.04,.095,"White: diffuser + mixing cup   ·   Black: all six other print parts   ·   Silver: five metal screws (not printed)",
             fontsize=11,color="#58616a")
    fig.text(.04,.05,"Actual CAD. Nominal shaft insertion: 8 mm. Purchased D-bore depth/grip and optical performance still need a physical trial.",
             fontsize=11,color="#58616a")
    fig.savefig(m.OUT / "strip_ring_preview.png",dpi=140,facecolor=fig.get_facecolor())
    plt.close(fig)
    print_colours(p)
    m.pack()


def print_colours(parts):
    labels=[("diffuser","Diffuser"),("cup","Mixing cup"),
            ("shield","Outer housing"),("top_cover","Top cover"),
            ("centre_disc","Centre cap"),("encoder_retainer","Encoder retainer"),
            ("bottom_cover","Bottom cover"),("encoder_spacer","3.5 mm spacer")]
    fig=plt.figure(figsize=(16,10),facecolor="#f4f3ef")
    fig.text(.04,.95,"Print colours — one of each part",fontsize=25,weight="bold",color="#20252c")
    fig.text(.04,.90,"Only the diffuser and mixing cup are WHITE. Everything else below is BLACK.",fontsize=14,color="#58616a")
    for i,(name,label) in enumerate(labels):
        white=name in ("diffuser","cup")
        x=.01+(i%4)*.25
        y=.48-(i//4)*.40
        shape=m.print_pose(name,parts[name])
        size=shape.BoundingBox()
        ax=fig.add_axes((x,y,.245,.32))
        ax.imshow(render_view([(shape,"#ede9da" if white else "#22262b")],
                             (120,-170,180),(0,0,size.zlen/2),max(size.xlen*.57,12)))
        ax.set_axis_off()
        ax.set_title(f'{"WHITE" if white else "BLACK"} · {label}',fontsize=12,weight="bold",color="#343c44")
        fig.text(x+.1225,y-.015,f"strip_ring_{name}.stl",ha="center",fontsize=9,color="#58616a")
    fig.text(.04,.025,"Files are separated into WHITE and BLACK folders in the ZIP. Supports and assembly order: README.md.",fontsize=12,color="#58616a")
    fig.savefig(m.OUT/"strip_ring_print_colours.png",dpi=140,facecolor=fig.get_facecolor())
    plt.close(fig)


if __name__ == "__main__":
    main()
