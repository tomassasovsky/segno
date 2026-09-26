"""Add the documented fabrication stack and readable wiring labels."""
import json
from pathlib import Path
import sys
import pcbnew as p
from pcb import point

HERE = Path(__file__).resolve().parent
STACK = '''
    (stackup
      (layer "F.SilkS" (type "Top Silk Screen") (color "White"))
      (layer "F.Paste" (type "Top Solder Paste"))
      (layer "F.Mask" (type "Top Solder Mask") (color "Purple") (thickness 0.01524) (epsilon_r 3.8))
      (layer "F.Cu" (type "copper") (thickness 0.035))
      (layer "dielectric 1" (type "core") (thickness 1.53) (material "FR4") (epsilon_r 4.4))
      (layer "B.Cu" (type "copper") (thickness 0.035))
      (layer "B.Mask" (type "Bottom Solder Mask") (color "Purple") (thickness 0.01524) (epsilon_r 3.8))
      (layer "B.Paste" (type "Bottom Solder Paste"))
      (layer "B.SilkS" (type "Bottom Silk Screen") (color "White"))
      (copper_finish "ENIG") (dielectric_constraints no)
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
    path.write_text("\n".join(line.rstrip() for line in text.splitlines())+"\n")


def finish(variant):
    path = HERE / variant / f'screen_power_{variant}.kicad_pcb'
    board = p.LoadBoard(str(path))
    title=board.GetTitleBlock()
    title.SetTitle('Segno screen power')
    title.SetRevision('L')
    board.SetTitleBlock(title)
    for item in list(board.GetDrawings()):
        if isinstance(item, p.PCB_TEXT):
            board.RemoveNative(item)
    def label(text, x, y, size=1.0, layer=p.F_SilkS, angle=0):
        t=p.PCB_TEXT(board);t.SetText(text);t.SetPosition(point(x,y))
        t.SetTextSize(point(size,size));t.SetTextThickness(p.FromMM(.15))
        t.SetTextAngle(p.EDA_ANGLE(angle,p.DEGREES_T))
        t.SetLayer(layer);t.SetMirrored(layer==p.B_SilkS);board.Add(t)
    from layout import DIMENSIONS, USB_ROWS
    w,h = DIMENSIONS[variant]
    # Revision L fills the old mid-board name strip and the bay above J2, and
    # its top-edge parts reach the row the back title used to sit on, so both
    # identifications move to the clear lower edge and the control marking
    # reads up the left edge beside its plug, clear of the M3 washers.
    label('SEGNO SCREEN POWER / REV L',32,h-1.2,1.0,p.B_SilkS)
    label('SEGNO SCREEN POWER',28.5,h-2.4,1.0)
    label('REV L',11,h-2.4,1.0)
    label('5V IN',56,6.5,1.0)
    label('J25',2.2,10.1,1.0,angle=90)
    label('CTRL',2.2,14,1.0,angle=90)
    label('5V IN',56,6.5,1.0,p.B_SilkS)
    label('1=5V 2=GND',55,17.5,1.0,p.B_SilkS)
    label('GPIO17 / GND',8,17.3,1.0,p.B_SilkS)
    for ch,y in enumerate(USB_ROWS[variant],1):
        screen='15.6"' if ch==1 else '7"'
        # The bay above each Pi plug now carries control parts; read this one
        # along the left edge instead.
        label(f'PI USB {ch}',2.2,y,1.0,angle=90)
        label(f'{screen} TOUCH',45,y+1.5,1.0)
        label(f'{screen} POWER',41.5,y-8,1.0)
        label(f'S{ch} PI',6,y-6,1.0,p.B_SilkS)
        label(f'S{ch} TOUCH',56,y-6.5,1.0,p.B_SilkS)
        for x in (7,56):
            for text,dy in [('1 +5V',3.75),('2 D-',1.25),('3 D+',-1.25),('4 GND',-3.75)]:
                label(text,x-4,y+dy,1.0,p.B_SilkS)
        label(f'S{ch} 5V OUT',55,y-8.2,1.0,p.B_SilkS)
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
