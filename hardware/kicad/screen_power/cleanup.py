"""Remove short or fully duplicated router tails, then require clean final DRC."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import pcbnew as p

HERE=Path(__file__).resolve().parent
CLI=os.environ.get('KICAD_CLI','/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli')


def covered_by_track(track, other):
    """Recognize a duplicate tail contained by another same-layer trace.

    Router endpoints can differ by up to the 2 um snapping tolerance used by
    finish.py. Compare the whole segment, retaining the longer copper path.
    """
    if (track is other or isinstance(other,p.PCB_VIA)
            or track.GetNetCode()!=other.GetNetCode()
            or track.GetLayer()!=other.GetLayer()
            or track.GetWidth()>other.GetWidth()
            or track.GetLength()>=other.GetLength()):return False
    start,end=other.GetStart(),other.GetEnd()
    dx,dy=end.x-start.x,end.y-start.y
    length2=dx*dx+dy*dy
    if not length2:return False
    # A track is a capsule. Its eroded capsule is convex, so containing both
    # endpoints of the narrower centerline proves the entire copper is covered.
    margin=(other.GetWidth()-track.GetWidth())/2+2000
    for point in (track.GetStart(),track.GetEnd()):
        px,py=point.x-start.x,point.y-start.y
        factor=max(0,min(1,(px*dx+py*dy)/length2))
        if (px-factor*dx)**2+(py-factor*dy)**2>margin**2:return False
    return True


def clean(variant):
    board_path=HERE/variant/f'screen_power_{variant}.kicad_pcb'
    with tempfile.TemporaryDirectory(prefix='screen-route-check-') as directory:
        report=Path(directory)/'drc.json'
        def drc():
            subprocess.run([CLI,'pcb','drc','--refill-zones','--save-board','--severity-all','--format','json','-o',str(report),str(board_path)],check=True)
            return json.loads(report.read_text())
        result=drc();board=p.LoadBoard(str(board_path))
        by_id={t.m_Uuid.AsString():t for t in board.GetTracks()}
        removed=[]
        for finding in result['violations']:
            if finding['type']!='track_dangling':continue
            for item in finding['items']:
                track=by_id.get(item['uuid'])
                if (track is not None and not isinstance(track,p.PCB_VIA)
                        and (track.GetLength()<p.FromMM(1)
                             or any(covered_by_track(track,other) for other in board.GetTracks()))):
                    removed.append(item['uuid']);board.RemoveNative(track)
        if removed:
            board.Save(str(board_path));result=drc()
        if result['violations'] or result['unconnected_items']:
            for finding in result['violations']+result['unconnected_items']:print(finding['description'],finding['items'])
            raise RuntimeError('Final DRC is not clean; do not export this board')
        project=board_path.with_suffix('.kicad_pro')
        data=json.loads(project.read_text())
        schematic=data.get('schematic',{})
        # pcbnew.Save injects a zero-UUID phantom sheet; retain real sheet records.
        if 'top_level_sheets' in schematic:
            schematic['top_level_sheets']=[sheet for sheet in schematic['top_level_sheets']
                if sheet.get('uuid')!='00000000-0000-0000-0000-000000000000']
            if not schematic['top_level_sheets']:schematic.pop('top_level_sheets')
        project.write_text(json.dumps(data,indent=2)+'\n')
        print(variant,'DRC clean; removed redundant router tails:',len(removed))

if __name__=='__main__':clean(sys.argv[1])
