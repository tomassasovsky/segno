// Silent layer edits use the transport’s shared recorded-content history.
window.createPeelPerformanceStudy = ({state,trackNames,currentTrack,transport,bankState,history}) => {
  let selected=-1;
  const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const read=i=>state.get(i),available=()=>selected>=0&&state.hasAudio(selected);
  const editable=()=>available()&&!state.capturing(selected);
  const count=i=>Math.max(0,read(i).layers.length-1);
  const summary=i=>count(i)?count(i)+' '+(count(i)===1?'overdub':'overdubs'):'Original only';
  const canPeel=()=>editable()&&count(selected)>0;
  const canRestore=()=>editable()&&history.canRecover([selected],'undo',['Peel']);
  function select(i){selected=state.hasAudio(i)?i:-1;}
  function enter(){const i=state.hasAudio(currentTrack())?currentTrack():trackNames.findIndex((_,j)=>state.hasAudio(j));select(i);if(i>=0)bankState.set(Math.floor(i/4));}
  function nextBank(){bankState.set(1-bankState.get());select(trackNames.findIndex((_,i)=>Math.floor(i/4)===bankState.get()&&state.hasAudio(i)));}
  function direct(tracks,restore=false){
    const list=[...new Set(tracks)].filter(i=>state.hasAudio(i));
    if(!list.length||list.some(i=>state.capturing(i)||!restore&&count(i)===0))return false;
    if(restore)return history.recover(list,'undo',['Peel']);
    return history.editPart(Object.fromEntries(list.map(i=>[i,{layers:read(i).layers.slice(0,-1)}])),'layers','Peel');
  }
  function peel(){return direct([selected]);}
  function restore(){return direct([selected],true);}
  function assignments(id){return {press:id===2?'Restore peeled layer':id===8?'Peel layer':id===9?'Peel bank':id>=4&&id<=7?'Select peel track':id===0?'Record / Play':id===1?'Stop':'Exit',hold:'None'};}
  function role(id,bank){
    if(id>=4&&id<=7){const i=bank*4+id-4,has=state.hasAudio(i);return {name:trackNames[i],hint:has?summary(i):'Empty',enabled:has,active:has&&selected===i};}
    if(id===9)return {name:'Bank '+(bank?'B':'A'),hint:'Tracks '+(bank?'5–8':'1–4'),enabled:true,active:bank===1};
    if(id===8)return {name:'Peel',hint:canPeel()?read(selected).layers.at(-1).label:editable()?'Original only':available()?'Finish recording':'Select a track',enabled:canPeel(),active:false};
    if(id===2)return {name:'Undo',hint:canRestore()?history.nextEdit(selected).before[selected].layers.layers.at(-1).label:editable()?'Nothing to restore':available()?'Finish recording':'Select a track',enabled:canRestore(),active:false};
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id){if(action==='Peel layer')peel();else if(action==='Restore peeled layer')restore();else if(action==='Select peel track')select(bankState.get()*4+id-4);else if(action==='Peel bank')nextBank();else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());}
  function body(){
    if(!available())return '<section class="peel-overview"><h2>Layers</h2><p>No recorded audio in this bank</p></section>';
    const layers=read(selected).layers,overdubs=layers.slice(1),visible=overdubs.slice(-3).reverse(),hidden=Math.max(0,overdubs.length-visible.length);
    return `<section class="peel-overview" aria-label="Selected track layers"><div class="peel-reading"><h2>${esc(trackNames[selected])}</h2><strong>${summary(selected)}</strong></div><div class="peel-stack" aria-label="Newest overdub first">${visible.map((layer,i)=>`<div class="peel-layer ${i===0?'latest':''}"><span>${esc(layer.label)}</span>${i===0?'<small>Next to peel</small>':''}</div>`).join('')}${hidden?`<div class="peel-earlier">${hidden} earlier ${hidden===1?'overdub':'overdubs'}</div>`:''}<div class="peel-layer original"><span>Original</span></div></div>${state.capturing(selected)?'<p>Finish recording to edit layers</p>':''}</section>`;
  }
  const caption=r=>`<small>${esc(r.hint)}</small>`;
  return {direct,enter,assignments,role,run,body,caption,snapshot:()=>({selected,tracks:trackNames.map((_,i)=>read(i)),canPeel:canPeel(),canRestore:canRestore(),scope:'selected-track',originalProtected:true})};
};
