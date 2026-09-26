"""Reproduce source contracts, fault controls and bounded thermal calculations.

Run with KiCad's Python after generating the hand-board netlist. This is not
a native PCB or analog transient validation.
"""
import ast, csv, hashlib, json, sys
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=root/'hardware/kicad/screen_power'
sys.path.insert(0,str(source))
import check
net=source/'hand/screen_power_hand.net'
components,raw=check.parse_netlist(net)
nets=check.semantic_nets(raw)
pins=check.pin_map(nets)
errors=[]
check.check_contract('hand',pins,nets,errors)
states=check.check_usb_power_states(pins,components,errors)
numeric=check.numerical_checks('hand',components,errors)
faults=check.usb_power_self_test('hand',pins,components)
records=json.loads(net.with_name('components.json').read_text())
rows=list(csv.DictReader(net.with_name('bom.csv').open()))
assert all(r['quantity']==0 for r in records if r['ref'].startswith('TP'))
assert not any(r['ref'].startswith('TP') for r in rows)
assert all(r['group']==f"Screen {r['ref'][1]}" for r in records if r['ref'] in ('R101','R102','R201','R202'))
thermal=[]
for ambient in (60,85):
    temp=ambient
    for _ in range(100):
        resistance=145*.9*(1+.00393*(temp-23))
        temp=ambient+150*5.25**2/resistance
    resistance=145*.9*(1+.00393*(temp-23))
    pickup=3.38*(1+.00393*(temp-23))
    actual=4.75*resistance/(resistance+10)
    thermal.append(dict(ambient_C=ambient,coil_C_estimate=temp,coil_ohms_estimate=resistance,pickup_V_estimate=pickup,restart_available_V_estimate=actual,margin_V_estimate=actual-pickup))
hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (source/'check.py',source/'switch_circuit.py')}
for p in hashes: ast.parse((root/p).read_text())
result=dict(errors=errors,states=states,usb_margins=numeric['usb_presence_and_relay_margins'],new_controls=faults,thermal_estimate=thermal,source_hashes=hashes,bare_shield_pads_excluded_from_bom=True)
Path(__file__).with_name('circuit-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
assert not errors,errors
assert all(faults.values()),faults
print(json.dumps(result,indent=2))
