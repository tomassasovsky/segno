"""Add the documented fabrication stack and readable wiring labels."""
import json
from pathlib import Path
import sys
import pcbnew as p
from pcb import point

HERE = Path(__file__).resolve().parent
STACK = '''
    (stackup
      (layer "F.SilkS" (type "Top Silk Screen"))
      (layer "F.Paste" (type "Top Solder Paste"))
      (layer "F.Mask" (type "Top Solder Mask") (thickness 0.01524) (epsilon_r 3.8))
      (layer "F.Cu" (type "copper") (thickness 0.035))
      (layer "dielectric 1" (type "prepreg") (thickness 0.2104) (material "7628") (epsilon_r 4.4))
      (layer "In1.Cu" (type "copper") (thickness 0.0152))
      (layer "dielectric 2" (type "core") (thickness 1.065) (material "FR4") (epsilon_r 4.6))
      (layer "In2.Cu" (type "copper") (thickness 0.0152))
      (layer "dielectric 3" (type "prepreg") (thickness 0.2104) (material "7628") (epsilon_r 4.4))
      (layer "B.Cu" (type "copper") (thickness 0.035))
      (layer "B.Mask" (type "Bottom Solder Mask") (thickness 0.01524) (epsilon_r 3.8))
      (layer "B.Paste" (type "Bottom Solder Paste"))
      (layer "B.SilkS" (type "Bottom Silk Screen"))
      (copper_finish "ENIG") (dielectric_constraints yes)
    )
'''


def stackup(path):
    text = path.read_text()
    # Replace an existing stackup as one balanced S-expression.
    start = text.find('(stackup')
    if start >= 0:
        depth = 0
        for end in range(start, len(text)):
            depth += (text[end] == '(') - (text[end] == ')')
            if depth == 0:
                text = text[:start] + text[end+1:]
                break
    text = text.replace('(setup', '(setup' + STACK, 1)
    path.write_text(text)


def finish(variant):
    path = HERE / variant / f'screen_power_{variant}.kicad_pcb'
    board = p.LoadBoard(str(path))
    for item in list(board.GetDrawings()):
        if isinstance(item, p.PCB_TEXT):
            board.RemoveNative(item)
    def label(text, x, y, size=1.0, layer=p.F_SilkS):
        t=p.PCB_TEXT(board);t.SetText(text);t.SetPosition(point(x,y))
        t.SetTextSize(point(size,size));t.SetTextThickness(p.FromMM(.15))
        t.SetLayer(layer);t.SetMirrored(layer==p.B_SilkS);board.Add(t)
    from layout import DIMENSIONS, USB_ROWS
    w,h = DIMENSIONS[variant]
    label('SEGNO SCREEN POWER / REV B',36,1.4,.8)
    if variant=='factory':
        next(f for f in board.GetFootprints() if f.GetReference()=='Q3').Reference().SetPosition(point(29,16))
    label('5V IN',13,14,.8,p.B_SilkS)
    label('1=5V 2=GND',13,2,.8,p.B_SilkS)
    label('GPIO17 / GND',9,52 if variant=='hand' else 48,.8,p.B_SilkS)
    for ch,y in enumerate(USB_ROWS[variant],1):
        label(f'S{ch} PI',6,y,.85,p.B_SilkS)
        label(f'S{ch} TOUCH',65,y,.8,p.B_SilkS)
        label(f'S{ch} 5V OUT',63,y-19,.8,p.B_SilkS)
    label('4L / GND L2 L3',29,h-3,.8,p.B_SilkS)
    label('USB 90 OHM',28,h-5.5,.8,p.B_SilkS)
    # Merge almost-coincident router nodes within 2um. A single grid rounding
    # could put opposite sides of a tiny gap into adjacent rounding cells.
    precise={f'S{ch}_{suffix}' for ch in [1,2] for suffix in ['UP_P','UP_N','DN_P','DN_N']}
    anchors={}
    def snap(net,v):
        cell=(v.x//2000,v.y//2000)
        for dx in [-1,0,1]:
            for dy in [-1,0,1]:
                for x,y in anchors.get((net,cell[0]+dx,cell[1]+dy),[]):
                    if (x-v.x)**2+(y-v.y)**2<=2000**2:return p.VECTOR2I(x,y)
        anchors.setdefault((net,*cell),[]).append((v.x,v.y))
        return v
    for t in list(board.GetTracks()):
        net=t.GetNetname()
        if net in precise:continue
        if isinstance(t,p.PCB_VIA):t.SetPosition(snap(net,t.GetPosition()))
        else:
            t.SetStart(snap(net,t.GetStart()));t.SetEnd(snap(net,t.GetEnd()))
            if t.GetStart()==t.GetEnd():board.RemoveNative(t)
    board.Save(str(path));stackup(path)
    project=path.with_suffix('.kicad_pro')
    data=json.loads(project.read_text());data.get('schematic',{}).pop('top_level_sheets',None)
    project.write_text(json.dumps(data,indent=2)+'\n')

if __name__=='__main__':
    finish(sys.argv[1])
