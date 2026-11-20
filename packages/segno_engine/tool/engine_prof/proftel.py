#!/usr/bin/env python3
"""Snapshots the section profiler (src/core/engine_prof.h, le_prof_state) out
of a running process's memory, with no tracing and no ptrace stop (#1914).
Build the engine with -DLE_PROFILE_SECTIONS=1 (the app's library, or a bench).
usage: proftel.py <pid> <file whose mapping holds it> <symbol offset hex> <out>
The symbol offset is `nm <file> | grep le_prof_state`; the address is the
file's first mapping (offset 0) plus it. Snapshot at both ends of a window
and compare them with profan.py."""
import sys
pid, name, off, out = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), sys.argv[4]
base = None
for ln in open(f'/proc/{pid}/maps'):
    f = ln.split()
    if len(f) >= 6 and name in f[5] and int(f[2], 16) == 0:
        base = int(f[0].split('-')[0], 16); break
if base is None: sys.exit(f'no mapping of {name} in {pid}')
SIZE = 3227920  # sizeof(le_prof): keep in step with engine_prof.h
with open(f'/proc/{pid}/mem', 'rb', 0) as m:
    m.seek(base + off); b = m.read(SIZE)
open(out, 'wb').write(b)
