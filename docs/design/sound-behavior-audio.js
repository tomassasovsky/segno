// Deterministic illustrative audio for reviewing the processing contract, not Segno DSP.
(function(root){
 'use strict';
 const policies=Object.freeze({stop:'Stop the loop; existing delay and reverb finish.',clear:'Remove the loop; existing delay and reverb finish.',mute:'Mute the whole track. The shared output tail can finish.',bypass:'New notes stay dry. Existing effect tails finish.',cut:'Stop playback and empty every effect tail immediately.',pre:'Printed effects stop with the recording.'});
 function render(action,{sampleRate=24000,seconds=4,at=1.2,outputLevel=1,followOutput=false}={}){
  if(!Object.hasOwn(policies,action))throw new Error('Unknown sound example');
  const size=Math.round(sampleRate*seconds),dry=new Float32Array(size),track=new Float32Array(size),output=new Float32Array(size),heard=new Float32Array(size),recorded=new Float32Array(size);
  const bypassAt=action==='bypass'?at:Infinity,stopAt=['stop','clear','pre','cut'].includes(action)?at:2.1;
  for(let note=0;note<7;note++){
   const time=.12+note*.32,freq=[220,277.18,329.63,440][note%4],start=Math.round(time*sampleRate);
   for(let j=0;j<sampleRate*.28&&start+j<size;j++){
    const t=j/sampleRate,index=start+j;if(index/sampleRate>=stopAt)break;
    dry[index]+=.27*Math.sin(2*Math.PI*freq*t)*Math.exp(-t*17)*Math.min(1,t*250);
   }
  }
  const delay=Math.round(.24*sampleRate),room=Math.round(.13*sampleRate);
  for(let i=0;i<size;i++){
   const time=i/sampleRate;let processed=dry[i];
   for(let repeat=1;repeat<=7;repeat++){const source=i-delay*repeat;if(source>=0&&source/sampleRate<bypassAt)processed+=dry[source]*Math.pow(.56,repeat);}
   if(action==='pre'&&time>=at)processed=0;
   track[i]=action==='mute'&&time>=at?0:processed;
   let mix=track[i];for(let repeat=1;repeat<=10;repeat++){const source=i-room*repeat;if(source>=0)mix+=track[source]*Math.pow(.34,repeat)*.55;}
   if(action==='pre')mix=track[i];
   if(action==='cut'&&time>=at){track[i]=0;mix=0;}
   output[i]=mix;heard[i]=mix*outputLevel;recorded[i]=mix*(followOutput?outputLevel:1);
  }
  return {sampleRate,seconds,at,dry,track,output,heard,recorded};
 }
 function energy(samples,start=0,end=samples.length){let value=0;for(let i=start;i<end;i++)value+=samples[i]*samples[i];return value;}
 const api={policies,render,energy};if(typeof module!=='undefined'&&module.exports)module.exports=api;if(root)root.SegnoSoundExample=api;
})(typeof window==='undefined'?null:window);
