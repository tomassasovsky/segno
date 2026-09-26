// Silent tape-speed UX for the whole recorded loop; separate from tempo following.
window.createSpeedPerformanceStudy = ({state,trackNames,currentTrack,transport}) => {
  const rates=[.5,2,4,8];
  const available=()=>trackNames.some((_,i)=>state.hasAudio(i));
  const ratio=()=>state.get();
  const label=value=>value===.5?'½×':value+'×';
  const shift=()=>Math.round(12*Math.log2(ratio()));
  const signed=value=>value>0?'+'+value:value<0?'−'+Math.abs(value):'0';
  function set(value){if(!available()||![1,...rates].includes(value))return false;return state.write(value)!==false;}
  function assignments(id){return {press:id>=4&&id<=7?'Speed '+rates[id-4]:id===2?'Normal speed':id===0?'Record / Play':id===1?'Stop':id===3?'Exit':'None',hold:'None'};}
  function role(id){
    if(id>=4&&id<=7){const value=rates[id-4];return {name:label(value),hint:value===.5?'Half speed':value===2?'Double speed':value+' times speed',speed:value,enabled:available(),active:available()&&ratio()===value};}
    if(id===2)return {name:'Normal speed',hint:'1×',enabled:available(),active:available()&&ratio()===1};
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    if(id===3)return {name:'Exit',hint:'',enabled:true,active:true};
    return {name:id===8?'Clear':'Bank',hint:'',enabled:false,active:false};
  }
  function run(action){if(action.startsWith('Speed '))set(Number(action.slice(6)));else if(action==='Normal speed')set(1);else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());}
  function body(){return `<section class="speed-overview" aria-label="Whole loop speed"><h2>All recorded tracks</h2>${available()?`<div class="speed-reading"><strong>${label(ratio())}</strong><div><span>Pitch <b>${signed(shift())} st</b></span><span>Loop duration <b>${ratio()===.5?'2×':ratio()===1?'1×':'1/'+ratio()}</b></span></div></div><div class="speed-scale" aria-hidden="true">${[.5,1,2,4,8].map(value=>`<div class="${value===ratio()?'current':''}"><span></span><small>${label(value)}</small></div>`).join('')}</div>`:'<p>No recorded audio</p>'}</section>`;}
  function caption(r){return `<small>${r.hint}</small>`;}
  const stageBody=()=>available()&&ratio()!==1?`<div class="speed-stage-state">Loop speed <strong>${label(ratio())}</strong></div>`:'';
  return {set,assignments,role,run,body,caption,stageBody,snapshot:()=>({ratio:ratio(),pitchShift:shift(),durationRatio:1/ratio(),rates:[.5,1,2,4,8],available:available(),scope:'all-recorded-tracks'})};
};
