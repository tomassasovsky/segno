// Silent target UX: a playback envelope, separate from saved mixer gain and mute.
window.createFadePerformanceStudy = ({state, trackNames, currentTrack, transport}) => {
  const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  let selected=-1;
  const seconds=(i=selected)=>state.seconds(i);
  function select(i){if(i===-1||state.hasAudio(i))selected=i;}
  const enter=()=>{selected=-1;};
  function read(i) {
    const job=state.get(i),available=state.hasAudio(i),now=Date.now();
    const fraction=job?Math.min(1,Math.max(0,(now-job.startedAt)/Math.max(1,job.durationMs))):1;
    const amount=job?job.from+(job.to-job.from)*fraction:1;
    const moving=!!job&&fraction<1&&job.from!==job.to;
    return {available,amount,target:job?.to??1,moving,active:available&&(amount<1||moving),label:!available?'Empty':moving?(job.to===0?'Fading out':'Fading in'):amount===0?'Faded out':'Full level'};
  }
  function toggle(i) {
    const r=read(i);if(!r.available)return;
    const to=r.target===0?1:0;
    state.write(i,{from:r.amount,to,startedAt:Date.now(),durationMs:seconds(i)*1000*Math.abs(to-r.amount)});
  }
  function assignments(id){if(id===9)return {press:'Next bank',hold:'Default fade time'};return {press:id>=4&&id<=7?'Toggle fade':id===2?'Shorter fade':id===8?'Longer fade':id===0?'Record / Play':id===1?'Stop':'Exit',hold:id>=4&&id<=7?'Select fade time':id===2||id===8?'Reset fade time':'None'};}
  function role(id,bank) {
    if(id===9)return {name:'Bank '+(bank?'B':'A'),hint:'Hold · Default time',enabled:true,active:!!bank};
    if(id>=4&&id<=7){const i=bank*4+id-4,r=read(i);return {name:trackNames[i],hint:r.label,fadeTrack:i,enabled:r.available,active:r.active};}
    if(id===2||id===8)return {name:id===2?'Time −':'Time +',hint:selected<0?'Hold · Reset':'Hold · Use default',enabled:true,active:false};
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id,bank) {
    if(action==='Select fade time'){select(bank*4+id-4);return;}
    if(action==='Default fade time'){select(-1);return;}
    if(action==='Shorter fade'||action==='Longer fade')state.setSeconds(selected,Math.max(.5,Math.min(30,seconds()+(action==='Shorter fade'?-.5:.5))));
    else if(action==='Reset fade time')state.setSeconds(selected,selected<0?4:null);
    else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());
  }
  const meter=(i,caption=false)=>{const r=read(i);return `<span class="fade-meter ${caption?'pedal-fade-meter':''}" data-fade-meter="${i}" aria-hidden="true"><span style="width:${r.amount*100}%"></span></span>`;};
  function body(){return `<section class="fade-overview" aria-label="Fade time and track levels"><div class="fade-duration"><div><h2>${selected<0?'Default fade time':esc(trackNames[selected])+' fade time'}</h2>${selected>=0?`<small>${state.override(selected)?'Custom':'Uses default'}</small>`:''}</div><strong>${seconds().toFixed(1)}<small>s</small></strong></div><div class="fade-tracks">${trackNames.map((name,i)=>{const r=read(i);return `<div class="fade-track ${r.available?'':'empty'}"><span>${esc(name)} <small>${seconds(i).toFixed(1)}s</small></span>${meter(i)}<small data-fade-label="${i}">${r.label}</small></div>`;}).join('')}</div></section>`;}
  function caption(r){return r.fadeTrack!=null?`${meter(r.fadeTrack,true)}<small data-fade-label="${r.fadeTrack}">${r.hint}</small>${r.enabled?'<small class="fade-time-hint">Hold · Time</small>':''}`:`<small>${esc(r.hint)}</small>`;}
  function refresh(root,bank) {
    root.querySelectorAll('[data-fade-meter]').forEach(el=>{el.firstElementChild.style.width=read(Number(el.dataset.fadeMeter)).amount*100+'%';});
    root.querySelectorAll('[data-fade-label]').forEach(el=>{el.textContent=read(Number(el.dataset.fadeLabel)).label;});
    root.querySelectorAll('.fade-map [data-perf-id]').forEach(el=>{const id=Number(el.dataset.perfId);if(id<4||id>7)return;const r=read(bank*4+id-4);el.querySelector('.pedal-led').dataset.state=!r.available?'unavailable':r.active?'active':'inactive';el.setAttribute('aria-label',`${trackNames[bank*4+id-4]}: ${r.label}`);});
    root.querySelectorAll('[data-mixer-fade]').forEach(el=>{const r=read(Number(el.dataset.mixerFade));el.textContent=r.active?r.label:'';});
  }
  return {enter,toggle,select,assignments,role,run,body,caption,refresh,read,snapshot:()=>({seconds:seconds(),selected,defaultSeconds:seconds(-1),durations:trackNames.map((_,i)=>seconds(i)),overrides:trackNames.map((_,i)=>state.override(i)),tracks:trackNames.map((_,i)=>read(i))})};
};
