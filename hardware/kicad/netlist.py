"""Reader for the KiCad netlists these generators emit.

Lives on its own because BOTH sides need it and they do not share an interpreter:
console_board_pcb.py runs under KiCad's Python (it needs pcbnew) and reads
console_board.net to lay the board out, while console_board.py runs under the
SKiDL venv and reads ring_board.net to prove the two ends of the ring cable still
agree. Stdlib only, so either interpreter can import it.
"""
import re


def _sexpr(text):
    """Minimal s-expression reader -> nested lists of str.

    A regex is not good enough here and the failure is silent: KiCad writes the
    netlist MULTI-LINE, so a pattern anchored on "(net (code N) (name ...)" never
    finds the next net and every net swallows the nodes of all those after it.
    That parses cleanly, produces plausible-looking output, and shorts the whole
    board together. Parse the parens properly instead.
    """
    tok = re.findall(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+', text)
    pos = 0

    def read():
        nonlocal pos
        out = []
        while pos < len(tok):
            t = tok[pos]; pos += 1
            if t == "(":
                out.append(read())
            elif t == ")":
                return out
            else:
                out.append(t[1:-1] if t.startswith('"') else t)
        return out

    return read()


def _find(node, key):
    return [n for n in node if isinstance(n, list) and n and n[0] == key]


def _val(node, key, default=None):
    got = _find(node, key)
    return got[0][1] if got and len(got[0]) > 1 else default


def parse_netlist(path):
    """-> (components{ref: (lib, fpname, value)}, nets{name: [(ref, pad)]})."""
    root = _sexpr(open(path).read())
    top = root[0] if root and isinstance(root[0], list) else root
    comps, nets = {}, {}
    for section in _find(top, "components"):
        for comp in _find(section, "comp"):
            ref = _val(comp, "ref")
            fp = _val(comp, "footprint")
            if ref and fp and ":" in fp:
                lib, name = fp.split(":", 1)
                comps[ref] = (lib, name, _val(comp, "value", ""))
    for section in _find(top, "nets"):
        for net in _find(section, "net"):
            name = _val(net, "name")
            nodes = [(_val(n, "ref"), _val(n, "pin")) for n in _find(net, "node")]
            if name and nodes:
                nets[name] = nodes
    return comps, nets


def pin_map(path, ref):
    """-> {pin: net_name} for one connector in a netlist. Pins stay as written."""
    _comps, nets = parse_netlist(path)
    out = {}
    for name, nodes in nets.items():
        for r, pin in nodes:
            if r == ref:
                out[pin] = name
    return out
