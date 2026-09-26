#include <iostream>
#include <iomanip>
#include <transline_calculations/coupled_microstrip.h>
int main(){double w,s,h,t,er,f;while(std::cin>>w>>s>>h>>t>>er>>f){COUPLED_MICROSTRIP c;using P=TRANSLINE_PARAMETERS; c.SetParameter(P::PHYS_WIDTH,w*.001);c.SetParameter(P::PHYS_S,s*.001);c.SetParameter(P::H,h*.001);c.SetParameter(P::T,t*.001);c.SetParameter(P::EPSILONR,er);c.SetParameter(P::H_T,1e6);c.SetParameter(P::FREQUENCY,f);c.SetParameter(P::PHYS_LEN,.05);c.SetParameter(P::MURC,1);c.SetParameter(P::SIGMA,5.8e7);c.SetParameter(P::ROUGH,0);c.SetParameter(P::TAND,.02);c.Analyse();std::cout<<std::setprecision(12)<<c.GetAnalysisResults().at(P::Z_DIFF).first<<'\n';}}
