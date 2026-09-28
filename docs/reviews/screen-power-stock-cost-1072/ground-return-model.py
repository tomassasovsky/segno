"""Conservative-cell DC sheet model of the screen board's actual GND copper.

Run with numpy, scipy and shapely installed. KiCad Python performs extraction
in a separate process; the source board is read but never saved/refilled.
Only cells entirely covered by actual copper are admitted, so a cell cannot
bridge a clearance slit. This is a geometry sensitivity, not thermal or USB
qualification. Generated results state the material and terminal assumptions.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys

KICAD_PYTHON = os.environ.get('KICAD_PYTHON',
    '/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3')


def extract(board_path):
    import pcbnew as p
    board = p.LoadBoard(str(board_path))
    data = {'board_sha256':hashlib.sha256(board_path.read_bytes()).hexdigest(),
            'polygons':{}, 'terminals':[], 'raw_tracks':[], 'coil_tracks':[], 'coil_return_tracks':[]}
    def points(chain):
        return [[p.ToMM(chain.CPoint(i).x),p.ToMM(chain.CPoint(i).y)] for i in range(chain.PointCount())]
    def polygons(poly):
        return [[points(poly.Outline(i))]+[points(poly.Hole(i,j)) for j in range(poly.HoleCount(i))]
                for i in range(poly.OutlineCount())]
    for layer, name in ((p.F_Cu,'F'),(p.B_Cu,'B')):
        data['polygons'][name] = []
        for zone in board.Zones():
            if not zone.GetIsRuleArea() and zone.GetLayer()==layer and str(zone.GetNetname()).lstrip('/')=='GND':
                data['polygons'][name] += polygons(zone.GetFilledPolysList(layer))
    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if str(pad.GetNetname()).lstrip('/')!='GND':continue
            outlines = {}
            for layer,name in ((p.F_Cu,'F'),(p.B_Cu,'B')):
                if pad.IsOnLayer(layer):
                    poly=p.SHAPE_POLY_SET();pad.TransformShapeToPolygon(poly,layer,0,1000,p.ERROR_INSIDE)
                    outlines[name]=polygons(poly)
            data['terminals'].append({'name':footprint.GetReference()+'.'+pad.GetNumber(),
                'x':p.ToMM(pad.GetPosition().x),'y':p.ToMM(pad.GetPosition().y),
                'drill_mm':min(p.ToMM(pad.GetDrillSize().x),p.ToMM(pad.GetDrillSize().y)),
                'copper':outlines,'via':False})
    for index,track in enumerate(board.GetTracks()):
        net=str(track.GetNetname()).lstrip('/')
        if isinstance(track,p.PCB_VIA) and net=='GND':
            x,y=p.ToMM(track.GetPosition().x),p.ToMM(track.GetPosition().y)
            radius=p.ToMM(track.GetWidth())/2
            ring=[[x+radius*math.cos(i*math.tau/128),y+radius*math.sin(i*math.tau/128)] for i in range(128)]
            data['terminals'].append({'name':f'via_{index}','x':x,'y':y,
                'drill_mm':p.ToMM(track.GetDrillValue()),'copper':{'F':[[ring]],'B':[[ring]]},'via':True})
        elif not isinstance(track,p.PCB_VIA):
            if net=='GND':
                layer=track.GetLayer();name='F' if layer==p.F_Cu else 'B'
                if layer in (p.F_Cu,p.B_Cu):
                    poly=p.SHAPE_POLY_SET();track.TransformShapeToPolygon(poly,layer,0,1000,p.ERROR_INSIDE)
                    data['polygons'][name] += polygons(poly)
            item={'length_mm':p.ToMM(track.GetLength()),'width_mm':p.ToMM(track.GetWidth()),'layer':track.GetLayer()}
            if net=='AUX_5V_IN':data['raw_tracks'].append(item)
            if net=='POWER_COIL_LOW':data['coil_return_tracks'].append(item)
            # Sum all 1mm protected-rail branches as an intentionally long
            # upper estimate for the light coil supply path. It includes
            # capacitor/clamp stubs that carry less than 150mA in steady state.
            if net=='AUX_5V' and .999<=item['width_mm']<=1.001:data['coil_tracks'].append(item)
    return data


def solve(data, step, copper_um, plating_um, temperature):
    import numpy as np
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    from scipy.sparse.linalg import spsolve
    import shapely
    from shapely.geometry import Polygon, Point
    from shapely.ops import unary_union
    def shape(polys):
        return unary_union([Polygon(rings[0],rings[1:]) for rings in polys])
    planes={layer:shape(polys) for layer,polys in data['polygons'].items()}
    terminals=[]; drilled_voids=[]
    for item in data['terminals']:
        # Native annular copper, with the physical drilled void removed.
        # Circular approximation is exact for selected circular GND drills.
        hole=Point(item['x'],item['y']).buffer(item['drill_mm']/2,quad_segs=64)
        drilled_voids.append(hole)
        regions={layer:shape(polys).difference(hole) for layer,polys in item['copper'].items()}
        terminals.append((item,regions))
        for layer,region in regions.items():planes[layer]=planes[layer].union(region)
    # Apply drilled voids after every same-net copper union: a ground track
    # through a pad center must not fill the actual drilled hole in the mesh.
    holes=unary_union(drilled_voids)
    planes={layer:plane.difference(holes) for layer,plane in planes.items()}
    minx=min(shape.bounds[0] for shape in planes.values());miny=min(shape.bounds[1] for shape in planes.values())
    maxx=max(shape.bounds[2] for shape in planes.values());maxy=max(shape.bounds[3] for shape in planes.values())
    x=np.arange(math.floor(minx/step)*step,maxx,step);y=np.arange(math.floor(miny/step)*step,maxy,step)
    xx,yy=np.meshgrid(x,y);boxes=shapely.box(xx.ravel(),yy.ravel(),xx.ravel()+step,yy.ravel()+step)
    centers=shapely.points(xx.ravel()+step/2,yy.ravel()+step/2)
    maps={};valids={};offset=0
    for layer in ('F','B'):
        valid=shapely.covers(planes[layer],boxes).reshape(xx.shape)
        ids=np.full(valid.shape,-1,dtype=np.int64);ids[valid]=np.arange(offset,offset+valid.sum())
        maps[layer]=ids;valids[layer]=valid;offset+=int(valid.sum())
    rho=1.724e-8*(1+.00393*(temperature-20));sheet=rho/(copper_um*1e-6)
    rows=[];cols=[];conductance=[]
    def edges(a,b,g):
        aa=np.atleast_1d(a);bb=np.atleast_1d(b)
        gg=np.broadcast_to(g,aa.shape)
        rows.extend(aa.tolist());cols.extend(bb.tolist());conductance.extend(gg.tolist())
    for layer in ('F','B'):
        ids=maps[layer]
        for a,b in ((ids[:,:-1],ids[:,1:]),(ids[:-1,:],ids[1:,:])):
            mask=(a>=0)&(b>=0);edges(a[mask],b[mask],1/sheet)
    port={};missing=[]
    for item,regions in terminals:
        side={}
        for layer,region in regions.items():
            # Equipotential terminal node ties only cells in the physical
            # annulus. It never reaches across the surrounding thermal gap.
            mask=shapely.covers(region,centers).reshape(xx.shape)&valids[layer]
            cells=maps[layer][mask]
            if not len(cells):
                missing.append(item['name']+':'+layer);continue
            side[layer]=offset;offset+=1
            edges(cells,np.full(cells.shape,side[layer]),1e6)
        if len(side)==2:
            barrel=rho*.0016/(math.pi*(item['drill_mm']*.001)*(plating_um*1e-6))
            edges([side['F']],[side['B']],1/barrel)
        if not item['via']:
            port[item['name']]=side
    a=np.asarray(rows);b=np.asarray(cols);g=np.asarray(conductance)
    graph=coo_matrix((np.ones(2*len(a)),(np.r_[a,b],np.r_[b,a])),shape=(offset,offset)).tocsr()
    _,labels=connected_components(graph)
    sink=port['J1.2']['B'];used=labels==labels[sink]
    required=['Q5.3','R8.2','J103.2','J203.2','J102.4','J202.4']
    if any(name not in port or 'B' not in port[name] or not used[port[name]['B']] for name in required):
        raise RuntimeError(f'{step}mm mesh loses a required return connection; refine it instead of bridging gaps')
    keep=used[a]&used[b];a,b,g=a[keep],b[keep],g[keep]
    ids=np.full(offset,-1,dtype=np.int64);ids[used]=np.arange(used.sum())
    a,b=ids[a],ids[b];sink=ids[sink]
    n=int(used.sum());mat=coo_matrix((np.r_[g,g,-g,-g],(np.r_[a,b,a,b],np.r_[a,b,b,a])),shape=(n,n)).tocsr()
    active=np.arange(n)!=sink;mat=mat[active][:,active]
    reindex=np.full(n,-1,dtype=np.int64);reindex[active]=np.arange(n-1)
    # Reciprocity: inject 1A at Q5 and read voltages at each output return.
    # These are the transfer resistances from each load to Q5's ground tap.
    rhs=np.zeros(n-1);q5=reindex[ids[port['Q5.3']['B']]];rhs[q5]=1
    voltage=spsolve(mat,rhs)
    residual=float(np.max(np.abs(mat@voltage-rhs)))
    transfers={name:float(voltage[reindex[ids[port[name]['B']]]]) for name in required}
    limits={'J103.2':3.,'J203.2':3.,'J102.4':.5,'J202.4':.5}
    remaining=4.25;allocation={};drop=0.
    for name in sorted(limits,key=lambda name:transfers[name],reverse=True):
        current=min(remaining,limits[name]);allocation[name]=current;remaining-=current
        drop+=current*transfers[name]
    # Put the whole 150mA control/coil allowance at the most adverse observed
    # control return, rather than silently treating it as zero ground current.
    control=[name for name in port if name != 'R8.2' and not name.startswith('J') and 'B' in port[name] and used[port[name]['B']]]
    control_transfer={name:float(voltage[reindex[ids[port[name]['B']]]]) for name in control if ids[port[name]['B']]!=sink}
    worst=max(control_transfer,key=control_transfer.get)
    drop+=.15*control_transfer[worst]+.06*transfers['R8.2']
    trace_r=lambda items:sum(rho*(item['length_mm']*.001)/((item['width_mm']*.001)*copper_um*1e-6) for item in items)
    raw_r=trace_r(data['raw_tracks']);branch_r=trace_r(data['coil_tracks'])
    coil_return_r=trace_r(data['coil_return_tracks'])
    total=4.46*raw_r+.15*branch_r+.05*coil_return_r+drop
    return {'mesh_mm':step,'admitted_cells':sum(int(v.sum()) for v in valids.values()),'connected_nodes':n,
        'maximum_KCL_residual_A':residual,'omitted_subcell_terminal_faces':missing,
        'transfer_ohms_at_Q5':transfers,'worst_screen_allocation_A':allocation,
        'control_return_worst_node':worst,'control_return_transfer_ohms':control_transfer[worst],
        'ground_drop_V':drop,'bleeder_allowance_A':.06,'total_input_allowance_A':4.46,'raw_feed_length_mm':sum(t['length_mm'] for t in data['raw_tracks']),
        'raw_feed_drop_V':4.46*raw_r,'coil_branch_sum_length_mm':sum(t['length_mm'] for t in data['coil_tracks']),
        'coil_branch_upper_drop_V':.15*branch_r,'coil_return_drop_V_at50mA':.05*coil_return_r,
        'total_copper_drop_V_model':total}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--extract',action='store_true')
    parser.add_argument('--mesh',type=float,nargs='+',default=[.15,.10])
    parser.add_argument('--copper-um',type=float,default=35)
    parser.add_argument('--plating-um',type=float,default=20)
    parser.add_argument('--temperature-c',type=float,default=60)
    args=parser.parse_args()
    if (not all(math.isfinite(x) and x > 0 for x in [*args.mesh,args.copper_um,args.plating_um])
            or not math.isfinite(args.temperature_c)):
        parser.error('Mesh, copper and plating dimensions must be finite and positive')
    if args.extract:
        print(json.dumps(extract(args.board)));return
    before=hashlib.sha256(args.board.read_bytes()).hexdigest()
    result=subprocess.run([KICAD_PYTHON,str(Path(__file__).resolve()),'--extract','--board',str(args.board)],capture_output=True,text=True,check=True)
    data=json.loads(result.stdout)
    results=[solve(data,step,args.copper_um,args.plating_um,args.temperature_c) for step in args.mesh]
    after=hashlib.sha256(args.board.read_bytes()).hexdigest()
    if before!=after or data['board_sha256']!=before:raise RuntimeError('Board changed during analysis')
    if any(r['maximum_KCL_residual_A'] > 1e-6 or r['omitted_subcell_terminal_faces'] for r in results):
        raise RuntimeError('Insufficient mesh resolution or solver residual')
    report={'board_sha256':before,'model_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'copper_um_assumption':args.copper_um,'plating_um_assumption':args.plating_um,
        'copper_temperature_C':args.temperature_c,'board_thickness_mm':1.6,'results':results,
        'scope':'Actual filled GND polygons and tracks plus annular pads/vias; only wholly covered cells, with no clearance-crossing mesh cells. Equipotential annular terminal approximation and specified material assumptions; no external ground-loop paths; not a fabrication guarantee.',
        'coil_branch_scope':'Entire 1mm AUX branch sum at 150 mA, including low-load stubs; downstream 5 mm contact feed excluded.',
        'load_scope':'Worst allocation with 4.25 A screens, 3 A per main and 0.5 A per touch, plus 150 mA worst observed control return and 60 mA bleeder; rounded total 4.46 A.',
        'input_voltage_reference':'4.75 V at J1 before F1; fuse/holder/driver drops excluded from copper result'}
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
