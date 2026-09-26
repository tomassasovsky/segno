// Silent Bounce workflow. The recipe describes a render; it is not an audio mix.
window.createBouncePerformanceStudy = ({state,trackNames,bankState,history}) => {
  let step='sources',sources=new Set(),destination=-1,keep=true,wrap=true,message='',resultBeats=0,renderOptions={mixFx:false};
  const copy=x=>JSON.parse(JSON.stringify(x)),esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
  const ids=()=>[...sources].sort((a,b)=>a-b),has=i=>state.readTrack(i).parts.length>0;
  const available=i=>has(i)&&!state.capturing(i),ready=()=>sources.size>0&&ids().every(available)&&duration()>0&&duration()<=1024;
  const beats=i=>state.readTrack(i).length.durationBeats??state.readTrack(i).length.audio.length;
  const plan=()=>state.recipe(ids(),{...renderOptions,tails:wrap?'wrap':'cut'});
  function duration(){return step==='done'?resultBeats:plan().beats||0;}
  const format=n=>n%state.beatsPerBar()===0?n/state.beatsPerBar()+' bars':n+' beats';
  const journal=()=>history.events('Bounce');
  const last=redo=>journal()[redo?'redo':'undo'].at(-1);
  const recoverable=redo=>{const event=last(redo);return !!event&&event.group.every(i=>!state.capturing(i))&&history.canRecover(event.group,redo?'redo':'undo',['Bounce']);};
  function reset(){step='sources';sources=new Set();destination=-1;keep=true;wrap=true;message='';resultBeats=0;renderOptions={mixFx:false};}
  function select(i){if(step==='sources'){if(!available(i))return;sources.has(i)?sources.delete(i):sources.add(i);}else if(step==='destination'&&!state.capturing(i))destination=i;message='';}
  function recover(redo){if(!recoverable(redo))return;const event=last(redo);if(!history.recover(event.group,redo?'redo':'undo',['Bounce']))return;const meta=event.metadata;sources=new Set(meta.sources);destination=meta.destination;keep=meta.keep;wrap=meta.wrap;resultBeats=event.after[destination].length.durationBeats;step='done';message=redo?'Bounce restored':'Bounce undone';}
  function bounce(){
    if(!ready()||destination<0||state.capturing(destination))return;
    const selected=ids(),changed=[...new Set([destination,...(keep?[]:selected)])],before=Object.fromEntries(changed.map(i=>[i,copy(state.readTrack(i))]));
    const recipe={...copy(plan()),keepSources:keep};
    const after=copy(before);
    if(!keep)for(const i of selected)after[i]={...after[i],parts:[],length:{audio:[],durationBeats:0,note:''},layers:{layers:[]},playing:false,recipe:null,imported:null};
    const old=state.readTrack(destination);
    after[destination]={...copy(old),parts:['Bounce'],length:{audio:[],durationBeats:recipe.beats,note:'Bounced from '+selected.map(i=>trackNames[i]).join(', ')},layers:{layers:[{id:'bounce:'+Date.now()+':'+destination,label:'Original',beats:recipe.beats}],},playing:!keep&&selected.some(i=>state.readTrack(i).playing),muted:false,pitch:0,reverse:false,mix:{level:1,pan:.5},fade:null,fx:[],recipe,imported:null};
    if(!history.edit(after,'Bounce',{sources:selected,destination,keep,wrap})){message='Track lengths do not fit this loop mode';return;}resultBeats=recipe.beats;step='done';message='Bounced to '+trackNames[destination];
  }
  function assignments(id){return {press:id===0?(step==='sources'?'Bounce next':step==='destination'?'Commit bounce':'None'):id===1?(step==='destination'?'Bounce back':'None'):id===2?'Undo bounce':id===8?(step==='sources'?'Bounce tails':step==='destination'?'Bounce sources':'New bounce'):id===9?'Bounce bank':id>=4&&id<=7?'Bounce select':'Exit',hold:id===2?'Redo bounce':'None'};}
  function role(id,bank){
    if(id>=4&&id<=7){const i=bank*4+id-4,selected=step==='sources'?sources.has(i):destination===i;return {name:trackNames[i],hint:state.capturing(i)?'Recording':step==='sources'?has(i)?sources.has(i)?'Selected':'':'Empty':step==='destination'?has(i)?'Replace audio':'Empty':destination===i?'Destination':'',enabled:step==='sources'?available(i):step==='destination'?!state.capturing(i):false,active:selected};}
    if(id===0)return {name:step==='sources'?'Next':step==='destination'?(destination>=0&&has(destination)?'Replace & bounce':'Bounce'):'Bounce complete',hint:step==='sources'?(ready()?'Choose destination':sources.size&&duration()>1024?'Loop exceeds length limit':'Select sources'):step==='destination'?(destination>=0?trackNames[destination]:'Choose destination'):'',enabled:step==='sources'?ready():step==='destination'&&ready()&&destination>=0&&!state.capturing(destination),active:false};
    if(id===1)return {name:'Back',hint:'Sources',enabled:step==='destination',active:false};
    if(id===2)return {name:'Undo',hint:recoverable(false)?'Whole bounce':last(false)?'Tracks changed':'Nothing to undo',recovery:recoverable(true)?'Hold · Redo':'',enabled:recoverable(false)||recoverable(true),active:false};
    if(id===8)return {name:step==='sources'?(wrap?'Wrap tails':'Cut tails'):step==='destination'?(keep?'Keep sources':'Clear sources'):'New bounce',hint:step==='sources'?(wrap?'Across loop edge':'At loop edge'):step==='destination'?'After bounce':'',enabled:true,active:step==='sources'?wrap:step==='destination'?keep:false};
    if(id===9)return {name:'Bank '+(bank?'B':'A'),hint:'Tracks '+(bank?'5–8':'1–4'),enabled:step!=='done',active:bank===1};
    return {name:'Exit',hint:'',enabled:true,active:true};
  }
  function run(action,id){if(action==='Bounce select')select(bankState.get()*4+id-4);else if(action==='Bounce next'&&ready()){step='destination';destination=-1;}else if(action==='Bounce back'){step='sources';destination=-1;}else if(action==='Commit bounce')bounce();else if(action==='Bounce bank')bankState.set(1-bankState.get());else if(action==='Bounce sources')keep=!keep;else if(action==='Bounce tails')wrap=!wrap;else if(action==='New bounce')reset();else if(action==='Undo bounce')recover(false);else if(action==='Redo bounce')recover(true);}
  function body(){
    const selected=ids(),replaced=step==='destination'&&destination>=0&&has(destination),title=step==='sources'?'Select sources':step==='destination'?'Choose destination':message;
    const sourceChips=selected.length?selected.map(i=>`<div class="bounce-source">${esc(trackNames[i])}</div>`).join(''):'<div class="bounce-placeholder">Choose tracks below</div>';
    return `<section class="bounce-overview" aria-label="Bounce route"><div class="bounce-heading"><h2>${esc(title)}</h2>${step!=='sources'?'<small>'+format(duration())+'</small>':''}</div>${step==='sources'?`<div class="bounce-sources">${sourceChips}</div>${window.SegnoSelectedRender.controls({button:state.button,prefix:'bounce-render:',options:{...renderOptions,tails:wrap?'wrap':'cut'},plan:selected.length?plan():{},beatsPerBar:state.beatsPerBar(),showTails:false})}`:`<div class="bounce-route"><div class="bounce-sources">${sourceChips}</div><div class="bounce-cable"></div><div class="bounce-target ${replaced?'replacing':''}">${destination>=0?esc(trackNames[destination]):'Destination'}${replaced?'<small>Replaces existing audio</small>':''}</div></div><div class="bounce-details"><span>${keep?'Keep sources':'Clear sources'}</span><span>${wrap?'Wrap tails':'Cut tails'}</span>${step==='done'&&destination>=0?'<span>'+(state.readTrack(destination).playing?'Playing':'Stopped')+'</span>':''}</div>`}</section>`;
  }
  return {action:id=>{if(!id.startsWith('bounce-render:')||step!=='sources')return false;renderOptions=window.SegnoSelectedRender.adjust(renderOptions,id.slice(14),plan(),state.beatsPerBar());return true;},enter:reset,assignments,role,run,body,caption:r=>`<small>${esc(r.hint)}</small>${r.recovery?'<small class="length-recovery">'+esc(r.recovery)+'</small>':''}`,snapshot:()=>({step,sources:ids(),destination,keep,wrap,message,canBounce:step==='destination'&&ready()&&destination>=0&&!state.capturing(destination),canUndo:recoverable(false),canRedo:recoverable(true),history:copy(journal()),tracks:trackNames.map((_,i)=>state.readTrack(i))})};
};
