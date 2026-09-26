// Target UX only: recorded-pitch state; no audio processing in this browser.
window.createTransposePerformanceStudy = ({state, trackNames, currentTrack, transport}) => {
  const limit=12;
  const selected=new Set();
  const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const pitch=i=>state.get(i);
  const enabled=()=>state.enabled();
  const effectivePitch=i=>enabled()?pitch(i):0;
  const signed=v=>v>0?'+'+v:v<0?'−'+Math.abs(v):'0';
  const targets=()=>[...selected].filter(i=>state.hasAudio(i));
  const canStep=delta=>targets().length>0&&targets().every(i=>Math.abs(pitch(i)+delta)<=limit);
  function enter(){selected.clear();const preferred=currentTrack();const first=state.hasAudio(preferred)?preferred:trackNames.findIndex((_,i)=>state.hasAudio(i));if(first>=0)selected.add(first);}
  function toggle(i){if(!state.hasAudio(i))return;if(selected.has(i))selected.delete(i);else selected.add(i);}
  function direct(tracks,delta){const list=[...new Set(tracks)].filter(i=>state.hasAudio(i));if(!list.length||![-1,0,1].includes(delta)||list.some(i=>Math.abs(delta===0?0:pitch(i)+delta)>limit))return false;state.write(list.map(i=>({track:i,pitch:delta===0?0:pitch(i)+delta})));return true;}
  function step(delta){direct(targets(),delta);}
  function reset(){const changed=targets().filter(i=>pitch(i)!==0);if(changed.length)state.write(changed.map(i=>({track:i,pitch:0})));}
  function toggleEnabled(){return state.setEnabled(!enabled())!==false;}
  function assignments(id){return id===2?{press:'Pitch down',hold:'Reset pitch'}:id===8?{press:'Pitch up',hold:'Reset pitch'}:{press:id===0?'Record / Play':id===1?'Stop':'Exit',hold:id===0?'Toggle transpose':'None'};}
  function role(id,bank){
    if(id>=4&&id<=7){const i=bank*4+id-4,hasAudio=state.hasAudio(i);return {name:trackNames[i],hint:hasAudio?signed(pitch(i))+' semitones':'Empty',pitch:hasAudio?signed(pitch(i)):null,enabled:hasAudio,active:hasAudio&&selected.has(i)};}
    if(id===2||id===8){const delta=id===2?-1:1;return {name:(delta<0?'−1':'+1')+' semitone',hint:targets().length?(canStep(delta)?'Hold · Reset':'Limit · Hold reset'):'Select tracks',enabled:targets().length>0,active:false};}
    if(id===0)return {name:'Record / Play',hint:'Hold · '+(enabled()?'Bypass':'Enable'),enabled:true,active:enabled()};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action){if(action==='Pitch down')step(-1);else if(action==='Pitch up')step(1);else if(action==='Reset pitch')reset();else if(action==='Toggle transpose')toggleEnabled();else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());}
  function body(){const list=targets();return `<section class="transpose-overview" aria-label="Transpose ${enabled()?'enabled':'bypassed'}"><h2>${enabled()?'Transpose enabled':'Transpose bypassed'} · All tracks</h2><div class="transpose-targets">${list.map(i=>`<div class="transpose-target"><span>${esc(trackNames[i])}${enabled()?'':' · Stored'}</span><strong>${signed(pitch(i))}<small>st</small></strong></div>`).join('')||'<p>Select tracks with their pedals.</p>'}</div></section>`;}
  return {direct,enter,toggle,toggleEnabled,effectivePitch,assignments,role,run,body,snapshot:()=>({selected:targets(),enabled:enabled(),pitches:trackNames.map((_,i)=>pitch(i)),effectivePitches:trackNames.map((_,i)=>effectivePitch(i)),hasAudio:trackNames.map((_,i)=>state.hasAudio(i)),limit,canDown:canStep(-1),canUp:canStep(1)})};
};
