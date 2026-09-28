"""Bounded quasi-static odd-mode section study using scikit-fem, not a channel qualification."""
import argparse,json,math
import numpy as np
from scipy.constants import epsilon_0,c
from skfem import MeshTri, Basis, ElementTriP0, ElementTriP1, BilinearForm, asm, condense, solve
from skfem.helpers import dot, grad

@BilinearForm
def energy(u,v,w):
    return w.er*dot(grad(u),grad(v))

def capacitance(mesh,er,signal,ground):
    b=Basis(mesh,ElementTriP1());e=Basis(mesh,ElementTriP0())
    A=asm(energy,b,er=e.interpolate(er));v=np.zeros(b.N);v[signal]=1
    u=solve(*condense(A,x=v,D=np.union1d(signal,ground)))
    return float(u@A@u)*epsilon_0

def run(w=.85,g=.16,h=1.53,t=.035,er=4.5,mask=True,n=1,D=6,side_ground=False,mask_scale=1):
    c1=.03048*mask_scale;c2=.01524*mask_scale
    left=g/2;right=left+w
    def line(a,b,N):return np.linspace(a,b,max(2,round(N*n))+1)
    # Every conductor/dielectric boundary is a tensor-grid coordinate.
    xx=np.unique(np.concatenate([line(0,left,20),line(left,right,50),line(right,right+.15,20),line(right+.15,D,60),[max(0,left-c2),right+c2,5]]))
    yy=np.unique(np.concatenate([line(0,h-.15,55),line(h-.15,h,25),line(h,h+t,16),line(h+t,h+t+.15,25),line(h+t+.15,h+D,70),[h+c1,h+t+c2]]))
    m=MeshTri.init_tensor(xx,yy);q=m.p[:,m.t].mean(axis=1)
    eps=np.where(q[1]<h,er,1.)
    if mask:
        coating=((q[1]>=h)&(q[1]<h+c1))|((q[0]>=left-c2)&(q[0]<=right+c2)&(q[1]>=h)&(q[1]<h+t+c2))
        eps[coating]=3.8
    x,y=m.p;signal=np.flatnonzero((x>=left-1e-10)&(x<=right+1e-10)&(y>=h-1e-10)&(y<=h+t+1e-10))
    ground=np.flatnonzero((x==0)|(x==D)|(y==0)|(y==h+D))
    if side_ground: ground=np.union1d(ground,np.flatnonzero((x>=5)&(y>=h)&(y<=h+t)))
    C=capacitance(m,eps,signal,ground);C0=capacitance(m,np.ones(len(eps)),signal,ground)
    return dict(width_mm=w,gap_mm=g,core_mm=h,copper_mm=t,er=er,mask=mask,mask_scale=mask_scale,mesh_scale=n,domain_mm=D,side_ground=side_ground,nodes=len(x),triangles=len(eps),C_odd_F_per_m=C,C0_odd_F_per_m=C0,differential_ohm=2/(c*math.sqrt(C*C0)))

def controls():
    # Exact two-series-dielectric parallel-plate solution with insulating sidewalls.
    m=MeshTri.init_tensor(np.linspace(0,1,21),np.linspace(0,1,41));q=m.p[:,m.t].mean(axis=1)
    e=np.where(q[1]<.5,4.5,1.);C=capacitance(m,e,np.flatnonzero(m.p[1]==1),np.flatnonzero(m.p[1]==0))
    expect=epsilon_0/(.5/4.5+.5);return dict(multi_dielectric_parallel_plate_computed_F_per_m=C,analytical_F_per_m=expect,relative_error=abs(C/expect-1))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--mesh',type=float,default=1);p.add_argument('--domain',type=float,default=6);p.add_argument('--output',default='fem-results.json');a=p.parse_args()
 rows=[]
 for w in [.85,.80,.78]:
  for mask in [False,True]:
   r=run(w=w,g=1.01-w,mask=mask,n=a.mesh,D=a.domain);rows.append(r);print(json.dumps(r),flush=True)
 result=dict(scope='Quasi-static engineering estimates, not measured impedance or tolerance guarantee',solver='scikit-fem12.0.1 / scipy1.16.2',controls=controls(),results=rows)
 open(a.output,'w').write(json.dumps(result,indent=2)+'\n');print(result['controls'])
