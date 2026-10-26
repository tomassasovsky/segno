// Shared symbolic render contract for Bounce and Save audio. No native DSP.
(function(root){
 'use strict';
 const copy=v=>structuredClone(v),positive=v=>Number.isFinite(v)&&v>0;
 const gcd=(a,b)=>b?gcd(b,a%b):a;
 function fraction(value){const [base,exp='0']=String(value).split('e'),places=(base.split('.')[1]?.length||0)-Number(exp);let n=BigInt(base.replace('.','')),d=1n;if(places>0)d=10n**BigInt(places);else n*=10n**BigInt(-places);const g=gcd(n,d);return [n/g,d/g];}
 function commonCycle(values){
  if(!values.length||values.some(v=>!positive(v)))return null;
  const [n,d]=values.map(fraction).reduce(([n,d],[a,b])=>[n/gcd(n,a)*a,gcd(d,b)]);const value=Number(n)/Number(d);
  return positive(value)&&value<=1024?value:null;
 }
 function recipe(tracks,{tempo=120,tails='wrap',durationBeats,mixFx=false,sharedFx=[]}={}){
  if(!tracks.length||!positive(tempo)||tracks.some(t=>!positive(t.beats)||t.capturing)||new Set(tracks.map(t=>t.id)).size!==tracks.length)return {error:'Choose recorded tracks that are not recording.'};
  if(!['wrap','cut'].includes(tails))return {error:'Choose Wrap or Cut for effect tails.'};
  const beats=durationBeats??commonCycle(tracks.map(t=>t.beats));
  if(!positive(beats)||beats>1024)return {error:'Choose a length up to 256 bars. These tracks have no short common cycle.'};
  const sources=copy(tracks).map(t=>{delete t.playing;delete t.muted;delete t.solo;return t;});
  return {tracks:sources,sources,beats,seconds:beats*60/tempo,duration:{beats,method:durationBeats===undefined?'common-cycle':'chosen'},tails,trackFx:true,sourceLevels:true,mixFx:!!mixFx,sharedFx:mixFx?copy(sharedFx):[],liveInputs:false,backing:false,click:false,outputFx:false,globalSpeedPrinted:false,renderSelectedRegardlessOfTransportOrMute:true,scope:'selected-recorded-tracks',once:'play-once-then-silence',destination:{level:1,pan:.5,mono:false,pitch:0,reverse:false,fade:null,fx:[]}};
 }
 function adjust(options,action,plan,beatsPerBar){const next={...options};if(action==='common')delete next.durationBeats;else if(action==='shorter'||action==='longer'){const bars=Math.round((next.durationBeats??plan.beats??beatsPerBar*4)/beatsPerBar);next.durationBeats=Math.max(1,Math.min(Math.floor(1024/beatsPerBar),bars+(action==='longer'?1:-1)))*beatsPerBar;}else if(action==='mix')next.mixFx=!next.mixFx;else if(action==='wrap'||action==='cut')next.tails=action;return next;}
 function controls({button,prefix,options,plan,beatsPerBar=4,showTails=true}){
  const bars=plan.beats/beatsPerBar,explicit=options.durationBeats!==undefined,label=Number.isFinite(bars)?Number(bars.toFixed(3))+' bars':'Choose length';
  return `<div class="render-controls"><div class="render-length"><strong>Length</strong>${button(prefix+'common','Common cycle','quiet '+(!explicit?'selected':''),'aria-pressed="'+!explicit+'"')}${button(prefix+'shorter','−','quiet','aria-label="Shorter render"')}<span>${label}</span>${button(prefix+'longer','+','quiet','aria-label="Longer render"')}</div><div class="render-processing"><strong>Mix FX</strong>${button(prefix+'mix',options.mixFx?'On':'Off','quiet '+(options.mixFx?'selected':''),'aria-pressed="'+!!options.mixFx+'"')}<small>All tracks effects</small>${showTails?`<strong class="render-tails-label">Tails</strong>${['wrap','cut'].map(key=>button(prefix+key,key==='wrap'?'Wrap':'Cut','quiet '+((options.tails||'wrap')===key?'selected':''),'aria-pressed="'+((options.tails||'wrap')===key)+'"')).join('')}`:''}</div>${plan.error?'<p class="audio-error">'+plan.error+'</p>':''}</div>`;
 }
 const api={commonCycle,recipe,adjust,controls};if(typeof module!=='undefined'&&module.exports)module.exports=api;if(root)root.SegnoSelectedRender=api;
})(typeof window==='undefined'?null:window);
