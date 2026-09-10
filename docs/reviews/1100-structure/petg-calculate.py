"""Engineering sensitivity screen; not validated printed-material allowables.
Units N, mm, MPa. Independent analytic Navier plate + local compression.
"""
import numpy as np, math, json, pathlib
out=pathlib.Path(__file__).resolve().parent
geom=json.loads((out/'petg-geometry.json').read_text())
a,b=112.47,82.75
nu=.35

def inertia(t,k,skin=1.2):
    return (t**3-(1-k)*max(0,t-2*skin)**3)/12

def navier(P=700,c=30,d=30,xc=0,yc=0,core_ratio=.16,E=1000,t_sled=12.633,modes=61,grid=161):
    # Cavity span. Idealized same-curvature, unbonded/coextensive slabs.
    ii=inertia(8,core_ratio)+inertia(t_sled,core_ratio)
    D=E*ii/(1-nu**2)
    kx=np.arange(1,modes+1)*np.pi/a; ky=np.arange(1,modes+1)*np.pi/b
    A=16*(P/(c*d))/(a*b)*np.outer(np.sin(kx*(xc+a/2))*np.sin(kx*c/2)/kx,np.sin(ky*(yc+b/2))*np.sin(ky*d/2)/ky)
    wave=kx[:,None]**2+ky[None,:]**2
    W=A/(D*wave**2)
    x=np.linspace(0,a,grid);y=np.linspace(0,b,grid)
    sx=np.sin(np.outer(x,kx));sy=np.sin(np.outer(y,ky));cx=np.cos(np.outer(x,kx));cy=np.cos(np.outer(y,ky))
    w=sx@W@sy.T
    Mx=sx@(D*(kx[:,None]**2+nu*ky[None,:]**2)*W)@sy.T
    My=sx@(D*(nu*kx[:,None]**2+ky[None,:]**2)*W)@sy.T
    Mxy=cx@(-D*(1-nu)*kx[:,None]*ky[None,:]*W)@cy.T
    z=max(8,t_sled)/2
    sigx=Mx*z/ii;sigy=My*z/ii;tau=Mxy*z/ii
    vm=np.sqrt(sigx**2+sigy**2-sigx*sigy+3*tau**2)
    principal=(sigx+sigy)/2+np.sqrt(((sigx-sigy)/2)**2+tau**2)
    idx=np.unravel_index(vm.argmax(),vm.shape)
    return dict(force_N=P,patch_mm=[c,d],patch_center_mm=[xc,yc],skin_E_MPa=E,core_E_ratio=core_ratio,sled_t_mm=t_sled,modes=modes,span_mm=[a,b],I_per_width_mm3=ii,D_Nmm=D,max_deflection_mm=float(w.max()),max_principal_tension_MPa=float(principal.max()),max_von_mises_MPa=float(vm.max()),max_vm_at_mm=[float(x[idx[0]]-a/2),float(y[idx[1]]-b/2)])

# Textbook uniform simply-supported square benchmark, dimensionless wcenter q a4/D.
m=np.arange(1,100,2)
mm,nn=np.meshgrid(m,m,indexing='ij')
wc=float(np.sum(16*np.sin(mm*np.pi/2)*np.sin(nn*np.pi/2)/(np.pi**6*mm*nn*(mm**2+nn**2)**2)))
assert abs(wc-.00406235266)<1e-9, wc

loads=[200,350,700,1400]
records=[]
for P in loads:
 for k in [.16,.4]:
  for key,c,d,xc,yc,ts in [('central_30x30',30,30,0,0,12.633),('broad_90x60',90,60,0,0,12.633),('toe_corner_30x30',30,30,-39.935,21.54,10.84)]:
   r=navier(P,c,d,xc,yc,k,1000,ts)
   r['case']=key;r['max_deflection_at_E2000_mm']=r['max_deflection_mm']/2
   records.append(r)
conv=[navier(modes=n) for n in [31,61,101]]

Aw=118.47*88.75-112.47*82.75
Ab=math.pi/4*(12**2-4.5**2)
Asolid=math.pi/4*(12**2-7.2**2)  # six0.4 perimeterpaths leaves7.2corediameter
Ac=math.pi/4*7.2**2
Atop=Asolid+.4*Ac
columnI=math.pi/64*(12**4-7.2**4) # excludes all infill in Euler buckling check
compression=[]
for P in loads:
 compression.append(dict(force_N=P,front_mean_MPa=P/10471.204096572355,mid_mean_MPa=P/(Aw+4*Ab),all_load_via_four_columns_MPa=P/(4*min(Ab,Atop)),all_load_via_one_column_MPa=P/min(Ab,Atop),all_load_via_one_column_skin_only_MPa=P/Asolid,pressure_30x30_MPa=P/900,nominal_core_stress_30x30_MPa=P/(900*.4)))

# Optional horizontal-load sensitivity, NOT an asserted user's load.
# No thread tensile demand from vertical forces within the contact polygon.
# If H/P=.2 acts at outer pedal edge, opposite pair of inserts resists rocking.
def rock(P,ratio,height,edge,bearing,bolt):
 e=edge+ratio*height
 return max(0,P*(e-bearing)/(bearing+bolt))/2
rocking=[]
for P in loads:
 rocking.append(dict(force_N=P,H_to_P=.2,base_side_per_insert_N=rock(P,.2,78.078008866405,38.175,44.375,22.1875),base_toe_per_insert_N=rock(P,.2,78.078008866405,54.935,59.235,48.685),deck_side_per_insert_N=rock(P,.2,39.733,38.175,39.375,18),deck_toe_per_insert_N=rock(P,.2,39.733,54.935,56.635,30)))
result=dict(description='Approximate PETG sensitivity calculation, not certification',geometry=geom,printed_assumptions=dict(layer_height_mm=.2,perimeters=6,assumed_line_width_mm=.4,solid_top_bottom_layers=6,skin_mm=1.2,nominal_infill=.4,skin_E_MPa=[1000,2000],core_E_ratio=[.16,.4],nu=nu),benchmark=dict(square_uniform_w_coefficient=wc,expected=.00406235266),convergence=conv,plate_cases=records,compression=compression,column_euler_skin_only_E1000_N=math.pi**2*1000*columnI/30.345008866405**2,contact_area=dict(front_mm2=10471.204096572355,mid_perimeter_mm2=Aw,mid_each_column_bottom_mm2=Ab,mid_total_mm2=Aw+4*Ab,column_upper_effective_area_mm2=Atop),rocking_sensitivity=rocking)
(out/'petg-results.json').write_text(json.dumps(result,indent=2))
print(json.dumps({'benchmark':result['benchmark'],'convergence':conv,'at700N':[r for r in records if r['force_N']==700],'compression':compression,'rocking':rocking,'column_euler':result['column_euler_skin_only_E1000_N']},indent=2))
