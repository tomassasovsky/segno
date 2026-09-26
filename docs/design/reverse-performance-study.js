// Target UX: non-destructive playback direction, independent from speed and pitch.
window.createReversePerformanceStudy = ({state, trackNames, currentTrack, transport, icon}) => {
  const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  function toggle(i){if(state.hasAudio(i))state.write(i,!state.get(i));}
  function assignments(id){return {press:id>=4&&id<=7?'Toggle direction':id===0?'Record / Play':id===1?'Stop':id===3?'Exit':'None',hold:'None'};}
  function role(id,bank){
    if(id>=4&&id<=7){const i=bank*4+id-4,available=state.hasAudio(i),reversed=state.get(i);return {name:trackNames[i],hint:available?(reversed?'Reverse':'Forward'):'Empty',direction:available?(reversed?'reverse':'forward'):null,enabled:available,active:available&&reversed};}
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    if(id===3)return {name:'Exit',hint:'',enabled:true,active:true};
    return {name:id===2?'Undo':'Clear',hint:'',enabled:false,active:false};
  }
  function run(action){if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());}
  function body(){return `<section class="reverse-overview" aria-label="Playback direction across all tracks"><h2>Playback direction</h2><div class="reverse-tracks">${trackNames.map((name,i)=>{const available=state.hasAudio(i),reversed=state.get(i);return `<div class="reverse-track ${available?(reversed?'reversed':'forward'):'empty'}"><span>${esc(name)}</span><div>${available?icon(reversed?'left':'right')+'<strong>'+(reversed?'Reverse':'Forward')+'</strong>':'<strong>Empty</strong>'}</div></div>`;}).join('')}</div></section>`;}
  function caption(r){return r.direction?`<span class="reverse-direction ${r.direction}">${icon(r.direction==='reverse'?'left':'right')}<strong>${esc(r.hint)}</strong></span>`:`<small>${esc(r.hint)}</small>`;}
  return {toggle,assignments,role,run,body,caption,snapshot:()=>({reversed:trackNames.map((_,i)=>state.get(i)),hasAudio:trackNames.map((_,i)=>state.hasAudio(i)),switchTiming:'immediate',position:'continue',pitch:'unchanged',speed:'unchanged'})};
};
