// Silent edit model: beat references describe repeated/retained audio, not DSP.
window.createLengthPerformanceStudy = ({state,trackNames,currentTrack,transport,bankState,history}) => {
  let selected=-1,mode='multiply';
  const maxBeats=1024,esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const read=i=>state.get(i),beats=i=>read(i).durationBeats??read(i).audio.length;
  const available=()=>selected>=0&&state.hasAudio(selected);
  const editable=()=>available()&&!state.capturing(selected);
  const format=n=>{const bar=state.beatsPerBar();return n%bar===0?(n/bar)+' '+(n===bar?'bar':'bars'):n+' '+(n===1?'beat':'beats');};
  const canHalf=()=>editable()&&beats(selected)/2>=1;
  const canDouble=()=>editable()&&beats(selected)*2<=maxBeats;
  const canUndo=()=>editable()&&history.canRecover([selected],'undo',['Multiply','Divide']);
  function select(i){selected=state.hasAudio(i)?i:-1;}
  function enter(kind){mode=kind;const first=state.hasAudio(currentTrack())?currentTrack():trackNames.findIndex((_,i)=>state.hasAudio(i));select(first);if(first>=0)bankState.set(Math.floor(first/4));}
  function nextBank(){bankState.set(1-bankState.get());select(trackNames.findIndex((_,i)=>Math.floor(i/4)===bankState.get()&&state.hasAudio(i)));}
  function direct(tracks,kind,part='first'){
    const list=[...new Set(tracks)].filter(i=>state.hasAudio(i));
    if(!list.length||!['half','double','undo'].includes(kind)||list.some(i=>state.capturing(i)||kind==='half'&&beats(i)/2<1||kind==='double'&&beats(i)*2>maxBeats))return false;
    if(kind==='undo')return history.recover(list,'undo',['Multiply','Divide']);
    const changes={};for(const i of list){const old=read(i),count=beats(i),next=kind==='half'?count/2:count*2,materialized=old.audio.length===count&&Number.isInteger(count)&&(kind!=='half'||count%2===0),audio=materialized?(kind==='half'?old.audio.slice(part==='last'?count/2:0,part==='last'?count:count/2):[...old.audio,...old.audio]):[];
      changes[i]={audio,durationBeats:next,note:kind==='half'?(part==='last'?'Last ':'First ')+format(next)+' kept':'Repeated to '+format(next),region:kind==='half'?{operation:'retain',from:part==='last'?count/2:0,beats:next,source:old.region||null}:{operation:'repeat',times:2,beats:next,source:old.region||null}};
    }return history.editLength(changes,kind==='half'?'Divide':'Multiply');
  }
  function change(kind,part='first'){return direct([selected],kind,part);}
  function undo(){return direct([selected],'undo');}
  function assignments(id){return id===2?{press:mode==='multiply'?'Undo length':'Keep first half',hold:mode==='divide'?'Undo length':'None'}:{press:id===8?(mode==='multiply'?'Double length':'Keep last half'):id===9?'Length bank':id>=4&&id<=7?'Select length track':id===0?'Record / Play':id===1?'Stop':'Exit',hold:'None'};}
  function halfRange(last){const count=beats(selected),bar=state.beatsPerBar();if(!Number.isInteger(count/2))return (last?'From '+format(count/2):'Start')+' · '+format(count/2);const unit=count%(bar*2)===0?bar:1,half=count/2/unit;return half===1?(unit===1?'Beat ':'Bar ')+(last?2:1):(unit===1?'Beats ':'Bars ')+(last?(half+1)+'–'+(half*2):'1–'+half);}
  function role(id,bank){
    if(id>=4&&id<=7){const i=bank*4+id-4,has=state.hasAudio(i);return {name:trackNames[i],hint:has?format(beats(i)):'Empty',enabled:has,active:has&&selected===i};}
    if(id===9)return {name:'Bank '+(bank?'B':'A'),hint:'Tracks '+(bank?'5–8':'1–4'),enabled:true,active:bank===1};
    if(mode==='multiply'&&id===2)return {name:'Undo',hint:canUndo()?'Length edit':'Nothing to undo',enabled:canUndo(),active:false};
    if(mode==='multiply'&&id===8)return {name:'Double length',hint:canDouble()?'Repeat to '+format(beats(selected)*2):editable()?'Maximum length':available()?'Finish recording':'Select a track',enabled:canDouble(),active:false};
    if(id===2||id===8)return {name:id===2?'First half':'Last half',hint:canHalf()?halfRange(id===8):editable()?'Beat limit':available()?'Finish recording':'Select a track',recovery:id===2&&canUndo()?'Hold · Undo':'',enabled:canHalf()||id===2&&canUndo(),active:false};
    if(id===0)return {name:'Record / Play',hint:trackNames[currentTrack()],enabled:true,active:false};
    if(id===1)return {name:'Stop',hint:'All tracks',enabled:true,active:false};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id){if(action==='Keep first half')change('half','first');else if(action==='Keep last half')change('half','last');else if(action==='Double length')change('double');else if(action==='Undo length')undo();else if(action==='Length bank')nextBank();else if(action==='Select length track')select(bankState.get()*4+id-4);else if(action==='Record / Play'||action==='Stop')transport(action,currentTrack());}
  function body(){
    if(!available())return '<section class="length-overview"><h2>Loop length</h2><p>No recorded audio in this bank</p></section>';
    const value=read(selected),count=beats(selected),bar=state.beatsPerBar(),step=Math.max(bar,Math.ceil(count/bar/8)*bar);
    const cells=mode==='divide'&&canHalf()?['First half','Last half'].map((name,side)=>`<div class="length-half"><span>${name}</span><div class="length-beats">${value.audio.slice(side*count/2,side*count/2+Math.min(count/2,16)).map(n=>`<i style="height:${14+(n%4)*8}px"></i>`).join('')}</div></div>`).join(''):Array.from({length:Math.ceil(count/step)},(_,i)=>{const start=i*step,end=Math.min(count,start+step);return `<div class="length-piece"><span>${count<bar?format(count):Math.floor(start/bar)+1===Math.ceil(end/bar)?Math.ceil(end/bar):(Math.floor(start/bar)+1)+'–'+Math.ceil(end/bar)}</span><div class="length-beats">${value.audio.slice(start,Math.min(end,start+16)).map(n=>`<i style="height:${14+(n%4)*8}px"></i>`).join('')}</div></div>`;}).join('');
    return `<section class="length-overview" aria-label="Selected track length"><div class="length-reading"><h2>${esc(trackNames[selected])}</h2><strong>${format(count)}</strong></div><div class="length-tape ${mode==='divide'&&canHalf()?'divide-regions':''}" aria-label="Recorded beat order">${cells}</div><div class="length-note">${state.capturing(selected)?'Finish recording to change length':esc(value.note||'Speed and pitch unchanged')}</div></section>`;
  }
  const caption=r=>`<small>${esc(r.hint)}</small>${r.recovery?'<small class="length-recovery">'+r.recovery+'</small>':''}`;
  return {direct,enter,assignments,role,run,body,caption,snapshot:()=>({selected,mode,tracks:trackNames.map((_,i)=>read(i)),canHalf:canHalf(),canDouble:canDouble(),canUndo:canUndo(),minBeats:1,maxBeats,scope:'selected-track'})};
};
