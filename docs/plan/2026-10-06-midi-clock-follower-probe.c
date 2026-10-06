/* The follower probe behind docs/plan/2026-10-06-feat-midi-clock-plan.md D3.
 * Adapted from the PR #1236 review's dll.c: two-stage DLL (0.5 Hz for eight
 * beats, then 0.2 Hz), outliers against a jitter estimate of non-outlier
 * errors, six same-sign outliers to re-acquire from the intervals since the
 * first, and gated missed-pulse counting. Times in seconds.
 * Build: cc -O2 -o probe 2026-10-06-midi-clock-follower-probe.c -lm */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
static double median(double*v,int n){double s[64];for(int i=0;i<n;i++)s[i]=v[i];qsort(s,n,sizeof(double),cmp);return n&1?s[n/2]:(s[n/2-1]+s[n/2])/2;}
static unsigned long rs=12345; static double urand(void){rs=rs*6364136223846793005ul+1442695040888963407ul;return ((rs>>11)&((1ul<<53)-1))/(double)(1ul<<53);}
typedef double (*jit)(double t);
static double j_alt(double t){static int k=0;return (k++&1)?0.001:-0.001;}
static double j_uni(double t){return (urand()-0.5)*0.002;}
static double j_usb(double t){return ceil(t*1000.0)/1000.0 - t;}
static double j_blk(double t){double b=512.0/44100.0;return ceil(t/b)*b - t;}
static double j_blk_uni(double t){return j_blk(t)+ (urand()-0.5)*0.001;}
/* truth: tempo bpm1 until tstep, then bpm2; optional drop of one pulse at tdrop */
static void run(const char*name,jit J,double bpm1,double bpm2,double tstep,int drop){
  double tt=0; int k=0; double last=-1; double iv[64]; int n=0;
  int synced=0; double P=0,tp=0, var=0; int same=0,sign=0,reacq=0,outl_start=0; double out_iv[64]; int nout=0;
  double maxbpm=0, disp=0; int flips=0; long pulses_counted=0, true_pulses=0; double settle_after=-1;
  int beats_since=0;
  while(tt<60.0){
    double bpm = tt<tstep?bpm1:bpm2; double P0=60.0/(bpm*24);
    double t=tt+J(tt); tt+=P0; true_pulses++;
    if(drop && true_pulses==drop) continue; /* lost pulse */
    if(last>=0){ double d=t-last; iv[n%64]=d; n++; }
    double prev=last; last=t;
    if(!synced){ if(n>=6){ double w[6]; for(int i=0;i<6;i++) w[i]=iv[(n-6+i)%64]; P=median(w,6); tp=t+P; synced=1; same=0; var=0; beats_since=0; pulses_counted=0;} continue; }
    /* missed pulses: count k = round((t - (tp - P)) / P) */
    double sg=sqrt(var); double kk=1;
    { static double eprev=0; double r=(t-prev)/P; double rr=round(r);
      if(sg < P/6 && beats_since>=48 && rr>=2 && fabs(r-rr)<0.25 && fabs(eprev)<fmax(0.002,4*sg)) kk=rr;
      eprev = t - tp - (kk-1)*P; }
    if(kk>1){ tp+= (kk-1)*P; } pulses_counted+= (long)kk;
    double e=t-tp; double B= beats_since<8*24?0.5:0.2; double w=2*M_PI*B*P, b=sqrt(2)*w, c=w*w;
    double sigma=sqrt(var); double thr=fmax(0.002,4*sigma); int s=(e>0)-(e<0);
    int outlier = fabs(e)>thr && beats_since>=48;
    if(outlier){ if(s==sign) same++; else {same=1;sign=s; nout=0;} out_iv[nout<64?nout:63]=t-prev; if(nout<64)nout++; } else {same=0;sign=0;nout=0;}
    if(same>=6){ int m = nout>=3? nout:0; if(m){ P=median(out_iv,m); tp=t+P; reacq++; same=0; nout=0; beats_since=0; var=0; continue; } }
    tp+=P+b*e; P+=c*e; if(!outlier || beats_since<48) var += (e*e - var)/48.0; beats_since++;
    double est=60.0/(24*P);
    double target = (bpm);
    if(tt>5 && !(tt>tstep && tt<tstep+4)){ double eb=fabs(est-target); if(eb>maxbpm)maxbpm=eb; }
    if(tt>tstep && settle_after<0 && fabs(est-bpm2)<0.1) settle_after=tt-tstep;
    double r=round(est*10)/10; if(fabs(est-disp)>0.15 && r!=disp){ if(tt>5 && !(tt>tstep&&tt<tstep+4)) flips++; disp=r; }
  }
  printf("%-24s %5.1f->%5.1f drop=%d: reacq=%2d maxerr=%.3f BPM flips=%d settle=%.2fs\n",name,bpm1,bpm2,drop,reacq,maxbpm,flips,settle_after);
}
int main(void){
  double bpms[]={90,120,124.9,174};
  for(int i=0;i<4;i++){ double b=bpms[i];
    run("alternating",j_alt,b,b,99,0); run("uniform 1ms",j_uni,b,b,99,0); run("usb frames",j_usb,b,b,99,0); run("block 512@44.1",j_blk,b,b,99,0); run("block+noise",j_blk_uni,b,b,99,0);
  }
  run("uniform step",j_uni,120,100,30,0); run("block step",j_blk,120,100,30,0); run("usb step",j_usb,174,90,30,0);
  run("uniform drop",j_uni,120,120,99,600); run("usb drop",j_usb,120,120,99,600);
}
