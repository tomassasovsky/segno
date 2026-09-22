"""Export prototype manufacturing packages only after fresh CAD verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile
from check import source_hashes

HERE = Path(__file__).resolve().parent
CLI = os.environ.get('KICAD_CLI','/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli')
MODELS = os.environ.get('KICAD10_3DMODEL_DIR','/Applications/KiCad/KiCad.app/Contents/SharedSupport/3dmodels')


def run(*args):
    subprocess.run([CLI,*map(str,args)],check=True)


def publish_package(out, destination):
    """Prepare on the destination filesystem, then replace with rollback.

    Keep the previous package until the complete replacement is installed.
    If rollback itself fails, retain its backup for recovery instead of letting
    temporary-directory cleanup delete the last complete package.
    """
    staging=Path(tempfile.mkdtemp(prefix='.'+destination.name+'-staging-',
                                dir=destination.parent))
    prepared,backup=staging/'prepared',staging/'previous'
    try:
        shutil.copytree(out,prepared)
        if destination.exists():destination.rename(backup)
        try:
            prepared.rename(destination)
        except BaseException:
            if backup.exists():
                try:
                    backup.rename(destination)
                except OSError as error:
                    raise RuntimeError('Package publication and rollback failed; '
                                       'previous package retained at '+str(backup)) from error
            raise
        if backup.exists():shutil.rmtree(backup)
    finally:
        if not backup.exists():shutil.rmtree(staging)


def export(variant):
    source=HERE/variant
    board=source/f'screen_power_{variant}.kicad_pcb'
    schematic=source/f'screen_power_{variant}.kicad_sch'
    destination=source/'fabrication'
    def inputs():
        hashes=source_hashes(source,board)
        for path in [HERE/'README.md',HERE/'external_bom.csv',*sorted((HERE/'screen_power.pretty').glob('*.kicad_mod'))]:
            hashes[str(path.relative_to(HERE))]=hashlib.sha256(path.read_bytes()).hexdigest()
        return hashes
    before=inputs()
    # Build in a temporary directory. A failed check/export never replaces the
    # last complete package or leaves a partially updated manufacturing ZIP.
    with tempfile.TemporaryDirectory(prefix='screen-power-export-') as folder:
        out=Path(folder);gerbers=out/'gerbers';gerbers.mkdir()
        subprocess.run([sys.executable,str(HERE/'check.py'),variant,'--output',str(out/'validation.json')],check=True)
        run('pcb','export','gerbers','--layers','F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,Edge.Cuts',
            '--no-protel-ext','--subtract-soldermask','--check-zones','-o',str(gerbers)+'/',board)
        run('pcb','export','drill','--excellon-separate-th','--generate-map','--generate-report',
            '--report-path',out/'drill-report.txt','-o',str(gerbers)+'/',board)
        run('pcb','export','pos','--format','csv','--units','mm','-o',out/'positions-all.csv',board)
        run('pcb','export','pos','--format','csv','--units','mm','--smd-only','--exclude-fp-th','-o',out/'positions-smd.csv',board)
        run('sch','export','pdf','-o',out/'schematic.pdf',schematic)
        run('pcb','export','pdf','--layers','F.Fab,F.SilkS,Edge.Cuts','--mode-single','-o',out/'assembly.pdf',board)
        run('pcb','export','step','--force','-D','KICAD10_3DMODEL_DIR='+MODELS,'-o',out/'board.step',board)
        for side in ['top','bottom']:
            run('pcb','render','--side',side,'--quality','high','--width','1600','--height','1600',
                '-D','KICAD10_3DMODEL_DIR='+MODELS,'-o',out/(side+'.png'),board)
        shutil.copy2(source/'bom.csv',out/'bom.csv')
        shutil.copy2(HERE/'external_bom.csv',out/'external_bom.csv')
        shutil.copy2(HERE/'README.md',out/'README.md')
        layers=['F_Cu.gbr','In1_Cu.gbr','In2_Cu.gbr','B_Cu.gbr','Edge_Cuts.gbr']
        for suffix in layers:
            matches=list(gerbers.glob('*'+suffix))
            if len(matches)!=1 or matches[0].stat().st_size<500:
                raise RuntimeError('Missing/empty fabrication layer '+suffix)
        if not list(gerbers.glob('*PTH.drl')):
            raise RuntimeError('Missing drill files')
        with zipfile.ZipFile(out/f'screen_power_{variant}_prototype_gerbers.zip','w',zipfile.ZIP_DEFLATED) as z:
            for path in sorted(gerbers.iterdir()):
                z.write(path,path.name)
        manifest={'status':'CAD verified prototype; physical acceptance pending',
                  'source_sha256':before,
                  'board_sha256':hashlib.sha256(board.read_bytes()).hexdigest(),
                  'files':{str(path.relative_to(out)):hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted(out.rglob('*')) if path.is_file()}}
        (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        if inputs()!=before:
            raise RuntimeError('Sources changed during export; package not published')
        publish_package(out,destination)
        print('Verified prototype package:',destination)

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('variant',choices=['hand','factory']);export(a.parse_args().variant)
