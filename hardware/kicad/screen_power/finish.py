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
    if variant == 'hand':
        main_input = next(f for f in board.GetFootprints() if f.GetReference()=='J1')
        main_input.Reference().SetPosition(point(72,10))
        label('SEGNO SCREEN POWER / THROUGH-HOLE / REV A',65,4,1.0)
        label('AUX 5V',65,16,.8)
        label('SCREEN CTRL',83,22,.8)
        label('1=GPIO17 / 2=GND',83,25,.8)
        label('THROUGH-HOLE',65,85,.8)
        label('CARRIER',65,88,.8)
        for ch,x in [(1,38),(2,93)]:
            px=18 if ch==1 else 112
            label('1=+5V  2=GND',px,3.5,.8)
            next(f for f in board.GetFootprints() if f.GetReference()==f'J{ch*100+3}').Reference().SetVisible(False)
            label(f'J{ch*100+3} EVM 5V',px,18,.8)
            label('EN / UFP / OUT / GND',px,29,.8)
            label('S'+str(ch)+' PI USB',x-13,98,.8)
            label('S'+str(ch)+' TOUCH',x+12,97,.8)
            label('S'+str(ch),x,108,.8)
            label('UPERFECT' if ch==1 else 'APROTII',x,115,.8)
        label('4L / 1.6mm',65,78,.8,p.B_SilkS)
        label('JLC04161H-7628',65,80.5,.8,p.B_SilkS)
        label('GND: INNER 1+2',65,83,.8,p.B_SilkS)
        label('USB: 0.26/0.16mm',65,85.5,.8,p.B_SilkS)
        label('CONFIRM 90 OHM',65,88,.8,p.B_SilkS)
    else:
        label(f'SEGNO SCREEN POWER / {variant.upper()} / REV A',65,4,1.1)
        label('PROTOTYPE - VERIFY BEFORE INSTALLATION',65,7,.8)
        label('J2 FROM MAIN BOARD',65,26,.85)
        label('1=GPIO17  2=GND',65,28,.85)
        label('5V AUX ONLY',83,47,1)
        label('+',61.5,43,1.2);label('GND',69.5,43,.8)
        for ch,x in [(1,38),(2,93)]:
            label('S'+str(ch)+' PI USB',x-12,98,.85)
            label('S'+str(ch)+' TOUCH',x+12,98,.85)
            label('USB2 / 500mA',x+12,95.7,.8)
            label('S1 UPERFECT' if ch==1 else 'S2 APROTII',x,117.7,.9)
            px=17 if ch==1 else 113
            label('S'+str(ch)+' POWER 5V 3A',px,33,.85)
        label('4 LAYERS / 1.6mm / JLC04161H-7628',65,58,.8,p.B_SilkS)
        label('F + B SIGNAL / INNER 1 + 2 GROUND',65,60.5,.8,p.B_SilkS)
        label('USB PAIRS: 0.26mm WIDTH / 0.16mm GAP',65,63,.8,p.B_SilkS)
        label('FABRICATOR: CONFIRM 90 OHM DIFFERENTIAL',65,65.5,.8,p.B_SilkS)
    # Merge almost-coincident router nodes within 2um. A single grid rounding
    # could put opposite sides of a tiny gap into adjacent rounding cells.
    precise={f'S{ch}_{suffix}' for ch in [1,2] for suffix in ['UP_P','UP_N','DN_P','DN_N','XI','XO']}
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
