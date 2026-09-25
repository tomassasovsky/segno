"""Render the actual top mount, cradle and existing pill CAD."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import to_rgb
import numpy as np
import vtk
from vtkmodules.util.numpy_support import numpy_to_vtk, numpy_to_vtkIdTypeArray, vtk_to_numpy

import top_mount as m


def draw(objects, camera_position, focal, scale):
    renderer = vtk.vtkRenderer()
    renderer.SetBackground(*to_rgb("#f4f3ef"))
    for solid, color in objects:
        if not solid.Solids():
            continue
        vertices, faces = solid.tessellate(0.16, 0.2)
        points = vtk.vtkPoints()
        points.SetData(numpy_to_vtk(np.array([v.toTuple() for v in vertices]), deep=True))
        cells = vtk.vtkCellArray()
        indices = np.column_stack((np.full(len(faces), 3), np.array(faces))).astype(np.int64)
        cells.ImportLegacyFormat(numpy_to_vtkIdTypeArray(indices.ravel(), deep=True))
        mesh = vtk.vtkPolyData()
        mesh.SetPoints(points)
        mesh.SetPolys(cells)
        normals = vtk.vtkPolyDataNormals()
        normals.SetInputData(mesh)
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
    camera = renderer.GetActiveCamera()
    camera.SetPosition(*camera_position)
    camera.SetFocalPoint(*focal)
    camera.SetViewUp(0, 0, 1)
    camera.ParallelProjectionOn()
    camera.SetParallelScale(scale)
    window = vtk.vtkRenderWindow()
    window.SetOffScreenRendering(1)
    window.SetSize(1000, 650)
    window.AddRenderer(renderer)
    window.Render()
    capture = vtk.vtkWindowToImageFilter()
    capture.SetInput(window)
    capture.Update()
    pixels = vtk_to_numpy(capture.GetOutput().GetPointData().GetScalars()).reshape(650, 1000, 3)
    result = pixels[::-1].copy()
    window.Finalize()
    return result


def render():
    fig = plt.figure(figsize=(17, 9), facecolor="#f4f3ef")
    fig.text(0.04, 0.93, "Friction closure. Angled with the platform.", fontsize=25,
             color="#20252c", weight="bold")
    fig.text(0.04, 0.875, "12.5° pill face · 18 mm vertical grip · Solid LED bed · Open-top wire slots",
             fontsize=14, color="#525b65")
    cradle = m.platform('front')
    z = cradle.BoundingBox().zmax
    models = m.parts()
    pill = m.placed_pill()
    objects = [(cradle, "#93999c")]
    objects += [(s.translate((0, 0, z)), "#22262b") for s in models.values()]
    objects += [(s.translate((0, 0, z)), "#eee8d8" if n == "diffuser" else "#242a30")
                for n, s in pill.items()]
    fpc=m.box(12,m.pill.STRIP_LENGTH,m.E.LED_STRIP_T,
              (m.PILL_X,0,m.BED_TOP+m.pill.ADHESIVE_T+m.E.LED_STRIP_T/2))
    leds=[m.box(5,5,m.E.LED_PKG_H,(m.PILL_X,(i-3.5)*m.E.LED_STRIP_PITCH,
          m.BED_TOP+m.pill.ADHESIVE_T+m.E.LED_STRIP_T+m.E.LED_PKG_H/2)) for i in range(8)]
    fpc=m.tilt(fpc)
    leds=[m.tilt(s) for s in leds]
    back=m.box(110,45,50,(m.PILL_X,22.5,5))
    detail=[(s.intersect(back),'#22262b') for s in models.values()]
    detail += [(pill['diffuser'].intersect(back),'#eee8d8'),(fpc.intersect(back),'#b4a88c')]
    detail += [(s.intersect(back),'#dba948') for s in leds]
    exploded=[(models['base'],'#30363c'),
              (pill['diffuser'].translate((0,0,8)),'#eee8d8'),
              (models['cover'].translate((0,0,23)),'#22262b')]
    views=[(objects,'CURRENT CRADLE · DEEPER GRIP',(235,200,190),(8,0,25),85),
           (detail,'SECTION · SOLID FLOOR AND LENS LEDGE',(155,-150,90),(m.PILL_X,0,3),44),
           (exploded,'TWO BLACK PARTS + REUSED WHITE LENS',(160,140,120),(m.PILL_X,0,15),45)]
    for i, (items, title, camera, focal, scale) in enumerate(views):
        ax = fig.add_axes((0.01 + i * 0.33, 0.24, 0.33, 0.56))
        ax.imshow(draw(items,camera,focal,scale))
        ax.set_axis_off()
        ax.set_title(title, fontsize=12, color="#525b65", pad=0)
    fig.text(0.04, 0.18, "18 mm jaws on both sides of the rim\n2.4 mm outside brace · 14 mm wide grips", fontsize=12,
             color="#36414a", linespacing=1.6)
    fig.text(0.37, 0.18, "Pill face follows the 12.5° platform slope\n2.4 mm floor · Open-top cable slots", fontsize=12,
             color="#36414a", linespacing=1.6)
    fig.text(0.70, 0.18, "Four shallow tapered friction ribs\nNo bending tabs or latch windows", fontsize=12,
             color="#36414a", linespacing=1.6)
    fig.text(0.04, 0.09, "Black: new housing   ·   Grey: existing cradle   ·   White: reused diffuser",
             fontsize=12, color="#36414a")
    fig.text(0.04, 0.045, "Actual CAD. Print the small PLA fit samples first. Friction force, rocking, wear and pedal travel still need a physical trial.",
             fontsize=10, color="#66717b")
    fig.savefig(m.OUT / "pill_top_mount_preview.png", dpi=140, facecolor=fig.get_facecolor())
    plt.close(fig)
    m.pack()


if __name__ == '__main__':
    render()
