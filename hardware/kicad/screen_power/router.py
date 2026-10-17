"""Freerouting bridge: reserve USB return paths, retain precise USB geometry."""
import argparse
from pathlib import Path
import pcbnew as p
from pcb import HERE


def run(variant, action, exchange):
    placed = HERE / variant / f'screen_power_{variant}.placed.kicad_pcb'
    board = p.LoadBoard(str(placed))
    if action == 'export':
        for nc in board.GetAllNetClasses().values():
            nc.SetClearance(p.FromMM(.2))
        p.ExportSpecctraDSN(board, str(exchange))
    else:
        # DSN coordinates round to 0.1um. Restore the original full precision
        # data/clock networks after import instead of retaining microscopic stubs.
        names = {f'S{ch}_{suffix}' for ch in [1,2]
                 for suffix in ['UP_P','UP_N','DN_P','DN_N']}
        critical = [t.Duplicate() for t in board.GetTracks() if t.GetNetname() in names]
        if not p.ImportSpecctraSES(board,str(exchange)):
            raise RuntimeError('Could not import router session')
        for t in list(board.GetTracks()):
            if t.GetNetname() in names:
                board.RemoveNative(t)
        for t in critical:
            board.Add(t)
        board.Save(str(placed).replace('.placed',''))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('variant',choices=['hand'])
    parser.add_argument('action',choices=['export','import'])
    parser.add_argument('exchange',type=Path)
    a=parser.parse_args();run(a.variant,a.action,a.exchange)
